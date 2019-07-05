local yaml = require("yaml")
local fiber = require("fiber")
local log = require("log")

local _
local util = {}

-- token bucket rate limiter
function util.rate_limited(fn, rate, burst, initial_burst)
    assert(rate > 0, "rate must be > 0")
    assert(rate < 1000, "too high rate, this will not work well")
    assert(burst >= 0 and burst <= 1000, "burst must be between 0 and 1000")
    initial_burst = initial_burst or 0
    assert(initial_burst <= burst, "initial_burst must be <= burst")

    local throttle = fiber.channel(burst)
    for _ = 1, initial_burst do throttle:put(1) end

    fiber.create(function()
        local sleep_time = 1 / rate
        while throttle:put(1) do fiber.sleep(sleep_time) end
    end)

    local weakrefs = setmetatable({}, {__mode = "v"})

    fiber.new(function()
        while weakrefs.f do fiber.sleep(1) end
        throttle:close()
    end)

    local function wrapper(...)
        throttle:get()
        return fn(...)
    end

    weakrefs.f = wrapper

    return wrapper
end

local function loop(stopped, fn, ...) repeat fn(...) until stopped() end

util.loop = loop

function util.fiber_loop(id, fn, ...)
    local stop_flag = false
    local function stopped() return stop_flag end

    local function stop() stop_flag = true end

    local f = fiber.create(util.loop, stopped, fn, ...)
    f:name("loop_" .. id, {truncate = true})
    return f, stop
end

function util.table_update(t1, t2) for k, v in pairs(t2) do t1[k] = v end end

function util.urljoin(...)
    local parts = {...}
    local new_parts = {}
    for _, part in ipairs(parts) do
        part = part:gsub("/*$", ""):gsub("^/*", "")
        table.insert(new_parts, part)
    end
    return table.concat(new_parts, "/")
end

function util.pluck(records, key)
    local res = {}
    for k, v in pairs(records) do table.insert(res, v[key]) end
    return res
end

function util.has(t, member)
    for _, m in pairs(t) do if m == member then return true end end
    return false
end

function util.keys(t)
    local keys = {}
    for key, _ in pairs(t) do table.insert(keys, key) end
    return keys
end

function util.table_set(t, path, value)
    for i, k in ipairs(path) do
        if i == #path then
            t[k] = value
        else
            local v = t[k]
            if v == nil then
                v = {}
                t[k] = v
            end
            t = v
        end
    end
end

function util.table_get(t, path, default)
    for _, k in ipairs(path) do
        t = t[k]
        if t == nil then return default end
    end
    return t
end

local function partial(f, first_arg, ...)
    if first_arg == nil then return f end
    return partial(function(...) return f(first_arg, ...) end, ...)
end

util.partial = partial

function util.compose(...)
    local fs = {...}
    local function recurse(i, ...)
        if i == 1 then return fs[i](...) end
        return recurse(i - 1, fs[i](...))
    end
    return function(...) return recurse(#fs, ...) end
end

function util.ok_or_log_error(fn, ...) return select(2, xpcall(fn, log.error, ...)) end

function util.select(channels, timeout)
    local first_channel, first_message
    local cond = fiber.cond()
    local fibers = {}
    for _, c in ipairs(channels) do
        table.insert(fibers, fiber.new(function()
            local msg = c:get()
            if not first_channel then first_message, first_channel = msg, c end
            cond:signal()
        end))
    end
    local got_signal = cond:wait(timeout)
    for _, f in ipairs(fibers) do pcall(f.cancel, f) end
    if got_signal then return first_channel, first_message end
    return nil, "timeout"
end

function util.string_replace(s, what, with, n)
    while true do
        local b, e = s:find(what, 1, true)
        if b == nil then
            return s
        else
            s = s:sub(1, b - 1) .. with .. s:sub(e + 1)
        end
    end
end

local function with_mt_serialize(t, serialize, recursion_lvl)
    recursion_lvl = recursion_lvl or 0
    assert(recursion_lvl <= 20, "too deep table")
    if recursion_lvl == 0 then t = table.deepcopy(t) end
    for k, v in pairs(t) do
        if type(v) == "table" then --
            with_mt_serialize(v, serialize, recursion_lvl + 1)
        end
    end
    return setmetatable(t, {__serialize = serialize})
end

function util.yaml_encode_pretty_mapping(t) --
    return yaml.encode(with_mt_serialize(t, "mapping"))
end

return util
