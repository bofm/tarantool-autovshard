-- Wlock
-- `W` stands for 2 things:
--   1. Weight. Wlock has weight. A contenter with higher weight gets the lock.
--   2. Wait. Wlock can be configured to wait for `delay` before acquiring the
--      lock which is already held by other contender with lower weight.
--
local json = require("json")
local fiber = require("fiber")
local log = require("log")
local uuid = require("uuid")

local util = require("autovshard.util")
local _

local M = {}

local CONSUL_LOCK_KEY = "lock"
local CONSUL_SESSION_TTL = 15
local RETRY_TIMEOUT = 10

local WLock = {}
M.WLock = WLock
WLock.__index = WLock

---@param consul_client any
---@param kv_prefix string
---@param weight number lock weight
---@param delay number delay in seconds to wait before taking the lock away from other contender
---@param info any a json/yaml serializable object to attach to the lock for information purpose
function WLock.new(consul_client, kv_prefix, weight, delay, info)
    self = setmetatable({}, WLock)
    self.consul_client = consul_client
    self.prefix = kv_prefix
    self.weight = weight
    self.delay = delay or 0
    self.info = info
    return self
end

function WLock:_get_lock_kv(kvs)
    if kvs == nil then return end
    local LOCK_KEY = util.urljoin(self.prefix, CONSUL_LOCK_KEY)
    for _, kv in ipairs(kvs) do if kv.key == LOCK_KEY then return kv end end
end

-- @param kvs consul KV's
-- @param prefix consul kv prefix
-- @treturn[1] table contender_weights - a mapping of weights by contender
-- @treturn[2] ?string holder session id of the current lock holder
-- @treturn[3] number max_weight maximum weight of all the contenders
function M.parse_kvs(kvs, prefix)
    local LOCK_KEY = util.urljoin(prefix, CONSUL_LOCK_KEY)

    local max_weight = 0
    local holder

    -- a map of session_id to weight
    local contender_weights = {}

    if kvs == nil then return contender_weights, holder, max_weight end

    local lock_value

    for _, kv in ipairs(kvs) do
        if kv.key == LOCK_KEY then
            -- the kv's value must be LockValue
            local ok, value = pcall(json.decode, kv.value)
            if ok then
                lock_value = value
            else
                log.error("cannot decode Consul lock key %q: value=%q, error=%q", kv.key, kv.value,
                          lock_value)
            end
        else
            -- need to check if the last key part is a valid UUID and if the key is
            -- locked with the session with the same id as the last key part
            local session_id = string.sub(kv.key, string.len(prefix) + 2)
            if pcall(uuid.fromstr, session_id) and kv.session == session_id then
                local ok, value = pcall(json.decode, kv.value)
                if not ok then
                    log.error("cannot decode Consul key %q: value=%q, error=%q", kv.key, kv.value,
                              value)
                end
                if ok and type(value.weight) ~= "number" then
                    log.error("missing weight in Consul contender key %q: value=%q", kv.key,
                              kv.value)
                end
                if ok and value and value.weight and type(value.weight) == "number" then
                    contender_weights[session_id] = value.weight
                    max_weight = math.max(max_weight, value.weight)
                end
            end
        end
    end

    if lock_value and lock_value.holder and contender_weights[lock_value.holder] then
        holder = lock_value.holder
    end

    return contender_weights, holder, max_weight
end

function WLock:_create_session(done_ch, info)
    info = info or self.info
    local session
    while not done_ch:is_closed() do
        session = util.ok_or_log_error(self.consul_client.session, self.consul_client,
                                       CONSUL_SESSION_TTL, "delete")
        if session then
            log.info("created Consul session %q", session.id)
            -- put contender key with acquire
            if self:_put_contender_key(session.id) then break end
        end
        done_ch:get(RETRY_TIMEOUT)
    end

    -- renew session in the background
    fiber.create(util.ok_or_log_error, self._renew_session_periodically, self, done_ch, session)
    return session
end

function WLock:_renew_session_periodically(done_ch, session)
    local timeout = 0.66 * CONSUL_SESSION_TTL
    local weight = self.weight
    while true do
        done_ch:get(timeout)
        if done_ch:is_closed() then break end
        if not util.ok_or_log_error(session.renew, session) then
            log.error("could not renew Consul session %q", session.id)
            -- if renew fails then we release the lock and return
            done_ch:close()
        end

        if self.weight ~= weight then
            if self:_put_contender_key(session.id) then
                weight = self.weight
            else
                log.error("could not could not put contentder key for Consul session %q",
                          session.id)
                done_ch:close()
            end
        end
    end
    if util.ok_or_log_error(session.delete, session) then
        log.info("released lock and deleted Consul session %q", session.id)
    end
end

function WLock:_wait_ready_to_lock(done_ch, session_id)
    -- watch kv prefix and check if we can should attempt to acquire the lock
    local ready_to_lock = fiber.channel()
    local delay_f

    local function start_delay_fiber(kvs)
        delay_f = fiber.new(function()
            done_ch:get(self.delay)
            if done_ch:is_closed() then return end
            ready_to_lock:put(kvs)
        end)
        delay_f:name("lock_delay", {truncate = true})
        log.info("started lock delay %s seconds with Consul session %q", self.delay, session_id)
    end

    local function stop_delay_fiber()
        if delay_f ~= nil then
            pcall(delay_f.cancel, delay_f)
            delay_f = nil
        end
    end

    local function on_change(kvs)
        local contender_weights, holder, max_weight = M.parse_kvs(kvs, self.prefix)

        -- check if we should preceed with the lock
        local can_lock = (contender_weights[session_id] or 0) >= max_weight and
                             (not holder or (contender_weights[holder] or 0) < max_weight)

        if can_lock then
            if holder and self.delay > 0 and not delay_f then
                start_delay_fiber(kvs)
            else
                stop_delay_fiber()
                ready_to_lock:put(kvs)
            end
        else
            stop_delay_fiber()
        end
    end

    local _, stop_watching = self.consul_client:watch{
        key = self.prefix,
        prefix = true,
        on_change = on_change,
        consistent = true,
    }

    -- stop watching when we are done
    local watchdog = fiber.create(function()
        done_ch:get()
        stop_watching()
    end)

    -- wait until we are ready to lock or until done_ch is closed
    local ch, kvs = util.select({done_ch, ready_to_lock})

    -- cleanup
    stop_watching()
    pcall(watchdog.cancel, watchdog)
    ready_to_lock:close()
    stop_delay_fiber()
    -----------

    if ch == ready_to_lock then --
        log.info("ready to lock with Consul session %q", session_id)
    end
    return kvs
end

function WLock:_put_lock_key(session_id, kvs)
    local lock_key = util.urljoin(self.prefix, CONSUL_LOCK_KEY)
    local value = json.encode({holder = session_id, info = self.info})
    local lock_kv = self:_get_lock_kv(kvs)
    local cas = 0
    if lock_kv then cas = lock_kv.modify_index end
    local put_ok = util.ok_or_log_error(self.consul_client.put, self.consul_client, lock_key,
                                        value, cas)
    if put_ok then
        log.info("acquired lock for Consul session %q", session_id)
        return true
    else
        return false
    end
end

function WLock:_put_contender_key(session_id)
    local key = util.urljoin(self.prefix, session_id)
    local value = json.encode({weight = self.weight, info = self.info})
    local acquire = session_id
    local put_ok = util.ok_or_log_error(self.consul_client.put, self.consul_client, key, value,
                                        nil, acquire)
    if put_ok then
        log.info("put Consul contender key: session=%q weight=%q", session_id, self.weight)
    end
    return put_ok
end

function WLock:_hold_lock(done_ch, session_id)
    -- ? maybe merge this watch section into the previous one
    -- [todo]: delete lock key on cleanup
    -- [todo]: retry when monitoring lock

    -- watch lock key prefix
    local _, stop_watching = self.consul_client:watch{
        key = self.prefix,
        prefix = true,
        on_change = function(kvs)
            -- wait until the lock session is invalidated or the lock key is changed
            local _, holder, _ = M.parse_kvs(kvs, self.prefix)
            -- check if we are still the holder
            if holder ~= session_id then
                log.info("lost lock for Consul session %q: holder changed", session_id)
                done_ch:close()
            end
        end,
        on_error = function(err)
            log.error("lock watch error for Consul session %q: %s", session_id, err)
            done_ch:close()
        end,
        consistent = true,
    }

    -- stop watching when we are done
    fiber.create(function()
        done_ch:get()
        stop_watching()
    end)
end

function WLock:set_weight(weight) self.weight = weight end

function WLock:set_delay(delay) self.delay = delay end

-- @param done_ch "done channel". It will be closed when the lock is released or invalidated.
--  And vice-versa, if `done_ch` is closed, the lock gets released.
-- @param info any info to attach to the contender key in Consul
-- @treturn boolean whether the lock has been acquired
function WLock:acquire(done_ch, info)
    -- [todo] delete lock key if there are no session keys
    -- "Done channel" must be closed if the lock is released or lost (probably due
    -- to Consul session invalidation or a network error).
    -- "Done channel" can also be closed by user. The function should return immediately
    -- in this case.
    assert(done_ch, "'done channel' must be passed as 1st parameter")
    local locked = false
    while not done_ch:is_closed() do
        -- We need to create session so that other contenders could take into
        -- account our weight.
        local session = self:_create_session(done_ch, info)
        if done_ch:is_closed() then break end
        local kvs = self:_wait_ready_to_lock(done_ch, session.id)
        if done_ch:is_closed() then break end
        if self:_put_lock_key(session.id, kvs) then
            self:_hold_lock(done_ch, session.id)
            locked = true
            break
        end
    end
    return locked
end

return M
