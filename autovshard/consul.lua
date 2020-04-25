local json = require("json")
local yaml = require("yaml")
local digest = require("digest")
local http = require("http.client")
local fiber = require("fiber")
local log = require("log")

local util = require("autovshard.util")

local _

-- in seconds
local DEFAULT_WAIT = 20
local HTTP_TIMEOUT = 2
local RETRY_TIMEOUT = 2
local DEFAULT_WATCH_RATE_LIMIT = 1
local DEFAULT_WATCH_RATE_LIMIT_BURST = 10
local DEFAULT_WATCH_RATE_LIMIT_INIT_BURST = 5

local KV = {}
KV.__index = KV

local kv_valid_keys = {
    create_index = 0,
    modify_index = 0,
    lock_index = 0,
    key = 0,
    flags = 0,
    value = 0,
    session = 0,
}

function KV.__eq(self, other)
    for k, _ in pairs(kv_valid_keys) do if self[k] ~= other[k] then return false end end
    return true
end

function KV.new(kv)
    assert(type(kv) == "table", "KV.new parameter must be a table")
    assert(kv.key, "missing 'key' field")
    for k, _ in pairs(kv) do assert(kv_valid_keys[k], string.format("unexpected key: %s", k)) end
    return setmetatable(table.copy(kv), KV)
end

function KV.from_consul_response(kv)
    --[[
    https://www.consul.io/api/kv.html
    Sample response:
    {
        "CreateIndex": 100,
        "ModifyIndex": 200,
        "LockIndex": 200,
        "Key": "zip",
        "Flags": 0,
        "Value": "dGVzdA==",
        "Session": "adf4238a-882b-9ddc-4a9d-5b6758e4159e"
    }
    ]] --

    local value
    if kv.Value ~= nil then --
        value = digest.base64_decode(kv.Value)
    end

    return KV.new{
        create_index = kv.CreateIndex,
        modify_index = kv.ModifyIndex,
        lock_index = kv.LockIndex,
        key = kv.Key,
        flags = kv.Flags,
        value = value,
        session = kv.Session,
    }
end

local function url_params(params)
    local res = {}
    local sep = "?"
    for k, v in pairs(params) do
        table.insert(res, sep)
        table.insert(res, k)
        table.insert(res, "=")
        table.insert(res, v)
        sep = "&"
    end
    return table.concat(res)
end

local ConsulClient = {}
ConsulClient.__index = ConsulClient

function ConsulClient:put(key, value, cas, acquire)
    local response = self.request{
        method = "PUT",
        url_path = {"kv", key},
        body = value,
        params = {cas = cas or nil, acquire = acquire or nil},
    }
    if response.status == 200 then
        local body = json.decode(response.body)
        return body == true
    else
        error(string.format("consul kv put error: %s", yaml.encode(response)))
    end
end

function ConsulClient:delete(key, cas)
    local response = self.request{
        method = "DELETE",
        url_path = {"kv", key},
        params = {cas = cas or nil},
    }
    if response.status == 200 then
        local body = json.decode(response.body)
        assert(type(body) == "boolean")
        return body == true
    else
        error(string.format("consul kv delete error: %s", yaml.encode(response)))
    end
end

function ConsulClient:get(key, wait_seconds, index, prefix, consistent)
    wait_seconds = (wait_seconds or 0)

    -- https://www.consul.io/api/features/blocking.html
    -- A small random amount of additional wait time is added to the supplied
    -- maximum wait time to spread out the wake up time of any concurrent
    -- requests. This adds up to wait / 16 additional time to the maximum
    -- duration.
    wait_seconds = wait_seconds + wait_seconds / 16

    local response = self.request{
        method = "GET",
        url_path = {"kv", key},
        params = {
            wait = wait_seconds and (wait_seconds .. "s") or nil,
            index = index or nil,
            recurse = prefix and "" or nil,
            consistent = consistent and "" or nil,
        },
        timeout = (wait_seconds or 0) + HTTP_TIMEOUT,
    }

    local new_index
    if response and response.headers and response.headers["x-consul-index"] then
        new_index = tonumber(response.headers["x-consul-index"])
    end
    -- log.info("new_index %s", new_index)
    -- if response and response.headers then
    --     for k, v in pairs(response.headers) do
    --         log.info("response.headers %s %s", k, v)
    --     end
    -- end

    if new_index then
        if new_index <= 0 then
            -- https://www.consul.io/api/features/blocking.html
            -- Sanity check index is greater than zero
            error(string.format('Consul kv "%s" modify index=%d <= 0', key, new_index))
        elseif index and new_index < index then
            -- https://www.consul.io/api/features/blocking.html
            -- Implementations must check to see if a returned index is lower than
            -- the previous value, and if it is, should reset index to 0
            new_index = 0
        end
    end

    if response.status == 200 then
        local body = json.decode(response.body)
        assert(type(body) == "table")
        assert(body[1], string.format("empty array in the response, %s", body))
        assert(body[1].Value, string.format("missing Value field in the response, %s", body))
        local result
        if prefix then
            result = {}
            for _, kv in ipairs(body) do
                table.insert(result, KV.from_consul_response(kv))
            end
        else
            result = KV.from_consul_response(body[1])
        end
        return result, new_index
    elseif response.status == 404 then
        return nil, new_index
    else
        error(string.format("consul kv get error: %s", yaml.encode(response)))
    end
end

local function watch_error(err) log.error("error in Consul watch: " .. tostring(err)) end

--- Watch consul key
-- @tparam table opts available options are:
-- @tparam string opts.key key
-- @tparam bool opts.prefix watch key prefix
-- @tparam number opts.wait_seconds long polling wait time
-- @tparam function opts.on_change
-- @tparam ?function opts.on_error
-- @tparam ?number opts.rate_limit
-- @tparam ?number opts.rate_limit_burst
-- @tparam ?index opts.index index for CAS operation
-- @return[1] fiber
-- @treturn[2] function a function to stop the watch fiber
function ConsulClient:watch(opts)
    if not type(opts.key) == "string" then error("bad or missing key") end
    if not type(opts.on_change) == "function" then error("on_change missing or not a function") end
    if opts.on_error and type(opts.on_change) ~= "function" then
        error("on_error is not a function")
    end
    local wait_seconds = opts.wait_seconds or DEFAULT_WAIT

    -- see Rate Limit section on https://www.consul.io/api/features/blocking.html
    local rate_limit = opts and opts.rate_limit or DEFAULT_WATCH_RATE_LIMIT
    local rate_limit_burst = opts and opts.rate_limit_burst or DEFAULT_WATCH_RATE_LIMIT_BURST
    local rate_limit_init_burst = opts and opts.rate_limit_init_burst or
                                      DEFAULT_WATCH_RATE_LIMIT_INIT_BURST

    local key = opts.key
    local on_change = opts.on_change
    local on_error = opts.on_error or watch_error

    local prev_kv = {}
    local prev_index = opts.index
    local done_ch = fiber.channel()

    local got_error

    local function error_handler(err)
        got_error = true
        on_error(err)
    end

    local function get()
        if got_error then
            prev_index = 0
            done_ch:get(RETRY_TIMEOUT)
            if done_ch:is_closed() then return end
        end
        local kv, index = self:get(key, wait_seconds, prev_index, opts.prefix, opts.consistent)
        if done_ch:is_closed() then return end
        local changed = index ~= prev_index
        prev_kv, prev_index = kv, index
        if changed then on_change(kv, index) end
        got_error = false
    end

    get = util.rate_limited(get, rate_limit, rate_limit_burst, rate_limit_init_burst)

    local watcher = fiber.create(function()
        repeat xpcall(get, error_handler) until done_ch:is_closed()
    end)
    watcher:name("consul_watch_" .. key, {truncate = true})

    return watcher, util.partial(done_ch.close, done_ch)
end

local function make_request(http_client, http_addresses, default_headers)
    assert(type(http_addresses) == "table", "baseurl must be a table")

    local function is_bad_response(response)
        return not response or not response.headers or
                   (response.status and response.status >= 500 and response.status < 600)
    end

    local address_count = #http_addresses
    local next_address = util.cycle(http_addresses)
    local address = next_address()

    return function(options)
        assert(options.method, "method must be set")
        local url
        if options.url then
            url = util.urljoin(address, "v1", options.url)
        elseif options.url_path then
            assert(type(options.url_path) == "table" and #options.url_path > 0,
                   "url_path must be a non-empty array")
            url = util.urljoin(address, "v1", unpack(options.url_path))
        else
            error("url or url_path must be set")
        end
        local headers = table.copy(default_headers)
        if options.headers then headers = util.table_update(headers, options.headers) end
        if options.params then url = url .. url_params(options.params) end
        local body = options.body
        if options.json then
            body = json.encode(options.json)
            headers["Content-Type"] = "application/json"
        end
        local opts = {timeout = options.timeout or HTTP_TIMEOUT, headers = headers}
        if options.opts then util.table_update(opts, options.opts) end
        -- log.info(require("yaml").encode({"request", options.method, url, {body = body}, opts}))
        local response = util.ok_or_log_error(http_client.request, http_client, options.method,
                                              url, body, opts)
        if address_count > 1 and is_bad_response(response) then --
            log.error("Got bad Consul HTTP response from %q. Will try another address.", address)
            address = next_address()
        end
        return response
    end
end

--- Create Consul client
-- @tparam ?string|table consul_http_address
-- @tparam table opts available options are:
-- @tparam string opts.token
-- @return consul client
function ConsulClient.new(consul_http_address, opts)
    if consul_http_address == nil then
        consul_http_address = {"http://localhost:8500"}
    elseif type(consul_http_address) == "table" then
        -- ok
    elseif type(consul_http_address) == "string" then
        consul_http_address = {consul_http_address}
    else
        error("bad consul_http_address: " .. tostring(consul_http_address))
    end
    if opts and type(opts) ~= "table" then error("opts must be a table or nil") end

    local c = {}

    c.token = opts and opts.token
    local default_headers = {["X-Consul-Token"] = opts and opts.token or nil}
    c.http_client = http.new({1})
    c.http_address = consul_http_address
    c.request = make_request(c.http_client, consul_http_address, default_headers)
    assert(c.request)
    return setmetatable(c, ConsulClient)
end

local Session = {}
Session.__index = Session

function ConsulClient:session(ttl, behavior)
    local session = setmetatable({}, Session)
    session.consul = assert(self)
    session.behavior = behavior or "delete"
    session.ttl = assert(ttl, "bad session ttl")

    local response = self.request{
        method = "PUT",
        url = "session/create",
        json = {["TTL"] = session.ttl .. "s", ["Behavior"] = session.behavior},
    }
    if response.status == 200 then
        local body = json.decode(response.body)
        assert(type(body.ID) == "string", string.format(
                   "could not create Consul session, missing or bad ID field in the response, %s",
                   body))
        session.id = body.ID
    else
        error(string.format("could not create Consul session, unknown response: %s %s",
                            response.status, response.reason))
    end

    return session
end

local function rstrip_s(str)
    if string.sub(str, string.len(str)) == "s" then --
        return string.sub(str, 1, string.len(str) - 1)
    end
    return str
end

function Session:renew()
    local response = self.consul.request{method = "PUT", url_path = {"session/renew", self.id}}
    if response.status == 200 then
        return true, json.decode(response.body)[1]
    elseif response.status == 404 then
        return false, json.decode(response.body)[1]
    else
        error(string.format("could not renew Consul session %s, unknown response: %s %s", self.id,
                            response.status, response.reason))
    end
    local session_json = json.decode(response.body)[1]
    assert(session_json.ID == self.id)
    -- Note: Consul may return a TTL value higher than the one specified during session creation.
    -- This indicates the server is under high load and is requesting clients renew less often.
    self.ttl =
        tonumber(rstrip_s(assert(session_json.TTL, "missing TTL in session renew response")))
    return session_json
end

function Session:delete()
    local response = self.consul.request{method = "PUT", url_path = {"session/destroy", self.id}}
    if response.status ~= 200 then
        error(string.format("could not delete Consul session %s, unknown response: %s %s", self.id,
                            response.status, response.reason))
    end
    local ok, response_json = pcall(json.decode, response.body)
    return ok and response_json == true
end

return {ConsulClient = ConsulClient, Session = Session, KV = KV}
