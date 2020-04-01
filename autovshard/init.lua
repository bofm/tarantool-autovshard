local yaml = require("yaml")
local log = require("log")
local fiber = require("fiber")
local uuid = require("uuid")
local vshard = require("vshard")

local fsm = require("autovshard.fsm")
local consul = require("autovshard.consul")
local util = require("autovshard.util")
local wlock = require("autovshard.wlock")
local config = require("autovshard.config")

local CONSUL_CONFIG_KEY = "autovshard_cfg_yaml"
local ERR_FIBER_CANCELLED = "fiber is cancelled"

-- events
local EVENT_START = "START"
local EVENT_STOP = "STOP"
local EVENT_LOCK_LOCKED = "LOCK_LOCKED"
local EVENT_LOCK_RELEASED = "LOCK_RELEASED"
local EVENT_NEW_CONFIG = "NEW_CONFIG"
local EVENT_CONFIG_REMOVED = "CONFIG_REMOVED"
local EVENT_CONSUL_ERROR = "CONSUL_ERROR"
local EVENT_PROMOTE = "PROMOTE"

local function lock_manager(events, lock)
    local done
    local ok, err = pcall(function()
        log.info("autovshard: lock manager started")
        while true do
            local locked
            done = fiber.channel()
            locked = lock:acquire(done)
            if locked then
                log.info("autovshard: lock acquired")
                events:put{EVENT_LOCK_LOCKED}
                done:get()
                log.info("autovshard: lock released")
                events:put{EVENT_LOCK_RELEASED}
            end
        end
    end)
    if done ~= nil then done:close() end
    if not ok and tostring(err) ~= ERR_FIBER_CANCELLED then
        log.error("autovshard: lock manager error: %s", err)
    end
    log.info("autovshard: lock manager stopped")
end

local function watch_config(events, consul_client, consul_kv_config_path)
    local _, stop_watching = consul_client:watch{
        key = consul_kv_config_path,
        on_change = function(kv)
            if kv and kv.value then
                local autovshard_cfg = util.ok_or_log_error(config.decode, kv.value)
                if autovshard_cfg then
                    autovshard_cfg = autovshard_cfg
                    events:put{EVENT_NEW_CONFIG, autovshard_cfg, kv.modify_index}
                end
            else
                -- config removed
                log.error("autovshard: config not found in Consul")
                events:put{EVENT_CONFIG_REMOVED}
            end
        end,
        on_error = function(err)
            log.error("autovshard: config watch error: %s", err)
            events:put{EVENT_CONSUL_ERROR, err}
        end,
        consistent = true,
    }
    return stop_watching
end

local Autovshard = {}
Autovshard.__index = Autovshard

function Autovshard:_validate_opts(opts)
    assert(type(opts) == "table", "opts must be a table")

    assert(type(opts.router) == "boolean", "missing or bad router parameter")
    assert(type(opts.storage) == "boolean", "missing or bad storage parameter")
    assert(opts.router or opts.storage, "at least one of [router, storage] must be true")

    -- validate box_cfg
    assert(type(opts.box_cfg) == "table", "missing or bad box_cfg parameter")
    if opts.storage then
        assert(type(opts.box_cfg.instance_uuid) == "string",
               "missing or bad box_cfg.instance_uuid parameter")
        assert(type(opts.box_cfg.replicaset_uuid) == "string",
               "missing or bad box_cfg.replicaset_uuid parameter")
    end

    assert(type(opts.cluster_name == "string"), "missing or bad cluster_name parameter")
    assert(type(opts.password) == "string", "missing or bad password parameter")
    assert(type(opts.login) == "string", "missing or bad login parameter")

    if type(opts.consul_http_address) == "table" then
        for _, a in pairs(opts.consul_http_address) do
            assert(type(a) == "string", "missing or bad consul_http_address parameter")
        end
    else
        assert(type(opts.consul_http_address) == "string",
               "missing or bad consul_http_address parameter")
    end
    assert(type(opts.consul_token) == "string" or opts.consul_token == nil,
           "bad consul_token parameter")
    assert(type(opts.consul_kv_prefix) == "string", "missing or bad consul_kv_prefix parameter")

    assert(opts.consul_session_ttl == nil or
               (type(opts.consul_session_ttl) == "number" and opts.consul_session_ttl >= 10 and
                   opts.consul_session_ttl <= 86400),
           "consul_session_ttl must be a number between 10 and 86400")
end

---@tparam table opts available options are
---@tparam table opts.box_cfg table
---@tparam string opts.cluster_name
---@tparam string opts.login
---@tparam string opts.password
---@tparam string|table opts.consul_http_address
---@tparam string opts.consul_token
---@tparam string opts.consul_kv_prefix
---@tparam boolean opts.router
---@tparam boolean opts.storage
---@tparam boolean opts.automaster
---@tparam number opts.consul_session_ttl
---
function Autovshard.new(opts)
    local self = setmetatable({}, Autovshard)
    self:_validate_opts(opts)

    -- immutable attributes
    self.box_cfg = opts.box_cfg
    self.cluster_name = opts.cluster_name
    self.password = opts.password
    self.login = opts.login
    self.consul_http_address = opts.consul_http_address
    self.consul_token = opts.consul_token
    self.consul_kv_prefix = opts.consul_kv_prefix
    self.router = opts.router and true or false
    self.storage = opts.storage and true or false
    self.automaster = opts.automaster and true or false
    self.consul_session_ttl = opts.consul_session_ttl or 15

    self.consul_kv_config_path = util.urljoin(self.consul_kv_prefix, self.cluster_name,
                                              CONSUL_CONFIG_KEY)

    self.consul_client = consul.ConsulClient.new(self.consul_http_address,
                                                 {token = self.consul_token})
    return self
end

function Autovshard:_vshard_apply_config(vshard_cfg)
    local config_yaml = yaml.encode {cfg = vshard_cfg}

    -- sanitize config, replace passwords
    -- uri: username:password@host:3301
    config_yaml = config_yaml:gsub("(uri%s*:[^:]+:)[^@]+(@)", "%1<secret>%2")

    log.info("autovshard: applying vshard config:\n" .. config_yaml)
    if self.storage then
        util.ok_or_log_error(vshard.storage.cfg, vshard_cfg, self.box_cfg.instance_uuid)
        util.ok_or_log_error(vshard.storage.rebalancer_wakeup)
    end
    if self.router then
        util.ok_or_log_error(vshard.router.cfg, vshard_cfg)
        util.ok_or_log_error(vshard.router.bootstrap)
        util.ok_or_log_error(vshard.router.discovery_wakeup)
    end
end

function Autovshard:_set_instance_read_only(autovshard_cfg)
    local _, already_read_only = pcall(function() return box.info().ro end)
    if already_read_only then return end

    local vshard_cfg = config.make_vshard_config(autovshard_cfg, self.login, self.password,
                                                 self.box_cfg)
    local changed, new_vshard_cfg = config.set_instance_read_only(vshard_cfg,
                                                                  self.box_cfg.instance_uuid)
    if changed then
        log.info("autovshard: setting instance to read-only...")
        self:_vshard_apply_config(new_vshard_cfg)
    end
end

---@return[1] channel of tables {instance_uuid = info}
---@return[2] function to stop watching
function Autovshard:_watch_rs_members_info()
    local chan = fiber.channel()

    local prefix = util.urljoin(self.consul_kv_prefix, self.box_cfg.replicaset_uuid)

    local function on_change(kvs)
        local result = {}
        for _, kv in pairs(kvs) do
            local key_base = string.sub(kv.key, string.len(prefix) + 2)
            local ok, result = pcall(uuid.fromstr, key_base)
            if not ok or result == nil then goto continue end
            local instance_uuid = key_base

            local ok, value_or_err = pcall(yaml.decode, kv.value)
            if ok then
                value = value_or_err
            else
                log.error("cannot decode Consul value key %q: value=%q, error=%q", kv.key,
                          kv.value, value_or_err)
                goto continue
            end
            result[instance_uuid] = value
            ::continue::
        end
        chan:put(result)
    end

    local _, stop_watching = self.consul_client:watch{
        key = prefix,
        on_change = on_change,
        consistent = true,
        prefix = true,
    }

    local done = fiber.channel()

    fiber.new(function()
        done:get()
        stop_watching()
        chan:close()
    end)

    return chan, function() done:close() end
end

function Autovshard:_promote_to_master(autovshard_cfg, cfg_modify_index)
    -- -- 1. set all to RO
    -- local ro_cfg = config.set_replicaset_read_only(autovshard_cfg, self.box_cfg.replicaset_uuid)
    -- -- update autovshard config in Consul
    -- local ok = util.ok_or_log_error(self.consul_client.put, self.consul_client,
    --                                 self.consul_kv_config_path, config.encode(ro_cfg),
    --                                 cfg_modify_index)
    -- if not ok then
    --     log.error(
    --         "autovshard: failed to set replicaset_uuid=%q instances to RO mode while promoting " ..
    --             "this Tarantool instance_uuid=%q to master, will retry later", self,
    --         self.box_cfg.replicaset_uuid, self.box_cfg.instance_uuid)
    -- end
    -- -- 2. wait for all to apply config
    -- while true do for c in connections do end end

    -- 3. set self to RW
    log.info("autovshard: promoting this Tarantool instance_uuid=%q to master",
             self.box_cfg.instance_uuid)
    local new_cfg = config.promote_to_master(autovshard_cfg, self.box_cfg.replicaset_uuid,
                                             self.box_cfg.instance_uuid)

    -- update autovshard config in Consul
    local ok = util.ok_or_log_error(self.consul_client.put, self.consul_client,
                                    self.consul_kv_config_path, config.encode(new_cfg),
                                    cfg_modify_index)
    if not ok then
        log.error("autovshard: failed promoting this Tarantool " ..
                      "instance_uuid=%q to master, will retry later", self.box_cfg.instance_uuid)
    end
    return ok
end

function Autovshard:_mainloop()
    -- ! To avoid deadlock DO NOT put into `self.events` channel IN THIS FIBER.
    -- * Only get events from `self.events` channel and react to the events.
    self.events = fiber.channel()

    local cfg
    local cfg_modify_index

    local lock
    local stop_locking = function() end

    local bootstrap_done = false

    local stop_watch_config = function() end
    local stop_watching_rs_members = function() end

    local function automaster() return self.automaster end
    local function is_storage() return self.storage end

    local function get_lock_parameters(cfg)
        local lock_weight = assert(config.get_master_weight(cfg, self.box_cfg.instance_uuid),
                                   "cannot get master weight")
        local lock_delay = config.get_switchover_delay(cfg, self.box_cfg.instance_uuid) or 0
        return lock_weight, lock_delay
    end

    local function maybe_update_lock(cfg)
        local lock_weight, lock_delay = get_lock_parameters(cfg)

        -- maybe update lock weight
        if lock and lock_weight ~= lock.weight then
            util.ok_or_log_error(lock.set_weight, lock, lock_weight)
        end

        -- maybe update lock delay
        if lock and lock_delay ~= lock.delay then
            util.ok_or_log_error(lock.set_delay, lock, lock_delay)
        end
    end

    local STATE_INIT = "none"
    local STATE_FOLLOWER = "FOLLOWER"
    local STATE_PROMOTING = "PROMOTING"
    local STATE_LEADER = "LEADER"
    local STATE_DETACHED = "DETACHED"
    local STATE_DONE = "DONE"

    local sm = fsm.create({
        events = {
            {name = EVENT_START, from = STATE_INIT, to = STATE_FOLLOWER}, --
            {name = EVENT_NEW_CONFIG, from = {STATE_FOLLOWER, STATE_DETACHED}, to = STATE_FOLLOWER}, --
            {name = EVENT_NEW_CONFIG, from = STATE_PROMOTING, to = STATE_PROMOTING}, --
            {name = EVENT_NEW_CONFIG, from = STATE_LEADER, to = STATE_LEADER}, --
            {name = EVENT_CONFIG_REMOVED, from = "*", to = STATE_DETACHED},
            {name = EVENT_LOCK_LOCKED, from = STATE_FOLLOWER, to = STATE_PROMOTING}, --
            {
                name = EVENT_LOCK_RELEASED,
                from = {STATE_PROMOTING, STATE_LEADER},
                to = STATE_FOLLOWER,
            }, --
            {name = EVENT_PROMOTE, from = STATE_PROMOTING, to = STATE_LEADER}, --
            {name = EVENT_CONSUL_ERROR, from = "*", to = STATE_DETACHED}, --
            {name = EVENT_STOP, from = "*", to = STATE_DONE}, --
        },
        callbacks = {
            ["on" .. EVENT_START] = function(sm, event, from, to)
                stop_watch_config = watch_config(self.events, self.consul_client,
                                                 self.consul_kv_config_path)
            end,
            ["on" .. STATE_DONE] = function(sm, event, from, to)
                self.events:close()
                stop_watch_config()
                stop_locking()
            end,
            ["on" .. STATE_FOLLOWER] = function(sm, event, from, to)
                if is_storage() and automaster() and cfg and not lock_fiber then
                    local lock_weight, lock_delay = get_lock_parameters(cfg)
                    local lock_prefix = util.urljoin(self.consul_kv_prefix, self.cluster_name,
                                                     self.box_cfg.replicaset_uuid)
                    lock = wlock.WLock.new(self.consul_client, lock_prefix, lock_weight,
                                           lock_delay,
                                           {instance_uuid = self.box_cfg.instance_uuid},
                                           self.consul_session_ttl)

                    lock_fiber = fiber.new(util.ok_or_log_error, lock_manager, self.events, lock)
                    lock_fiber:name("autovshard_lock_manager", {truncate = true})
                    stop_locking = function()
                        stop_locking = function() end
                        pcall(lock_fiber.cancel, lock_fiber)
                        lock_fiber = nil
                    end
                end
            end,
            ["on" .. STATE_PROMOTING] = function(sm, event, from, to)
                local chan
                -- chan, stop_watching_rs_members = self:_watch_rs_members_info()
                -- set_rs_read_only()
                fiber.new(function() self.events:put{EVENT_PROMOTE} end)
            end,
            ["onleave" .. STATE_PROMOTING] = function(sm, event, from, to)
                if to ~= STATE_PROMOTING then stop_watching_rs_members() end
            end,
            ["on" .. STATE_LEADER] = function(sm, event, from, to)
                if (not config.is_master(cfg, self.box_cfg.instance_uuid) or
                    config.master_count(cfg, self.box_cfg.replicaset_uuid) ~= 1) then
                    fiber.new(function()
                        self:_promote_to_master(cfg, cfg_modify_index)
                        sm:transition(event)
                    end)
                    return sm.ASYNC
                end
            end,
            ["onleave" .. STATE_LEADER] = function(sm, event, from, to)
                if to ~= STATE_LEADER then
                    fiber.new(function()
                        self:_set_instance_read_only(cfg)
                        sm:transition(event)
                    end)
                    return sm.ASYNC
                end
            end,
            ["onleave" .. STATE_DONE] = function(sm, event, from, to)
                return false -- never leave STATE_DONE
            end,
            ["on" .. STATE_DETACHED] = function(sm, event, from, to)
                if self.storage and cfg and bootstrap_done then
                    self:_set_instance_read_only(cfg)
                end
            end,
            ["onbefore" .. EVENT_NEW_CONFIG] = function(sm, event, from, to, new_cfg,
                                                        new_cfg_modify_index)
                assert(new_cfg, "autovshard: missing cfg in EVENT_NEW_CONFIG")
                assert(new_cfg_modify_index,
                       "autovshard: missing cfg_modify_index in EVENT_NEW_CONFIG")
                cfg, cfg_modify_index = new_cfg, new_cfg_modify_index
            end,
            ["on" .. EVENT_NEW_CONFIG] = function(sm, event, from, to, data)
                maybe_update_lock(cfg)
                if is_storage() and not bootstrap_done and
                    config.master_count(cfg, self.box_cfg.replicaset_uuid) ~= 1 then
                    -- For storage instances we need to check for bootstrap_done to
                    -- handle the case when this is the first ever call to
                    -- vshard.storage.cfg(cfg) on current instance.
                    -- If there is no master defined in cfg for the current
                    -- replica set, then vshard.storage.cfg call will block forever
                    -- with this messages in log:
                    --
                    -- E> ER_LOADING: Instance bootstrap hasn't finished yet
                    -- I> will retry every 1.00 second
                    --
                    -- During bootstrap we should first elect master, so we ignore
                    -- the config when no master is set for current replica set.
                    log.info("autovshard: won't apply the config, master_count != 1, " ..
                                 "cannot bootstrap with this config.")
                else
                    -- [TODO] do not apply new config if it is the same as the current one
                    local vshard_cfg = config.make_vshard_config(cfg, self.login, self.password,
                                                                 self.box_cfg)
                    self:_vshard_apply_config(vshard_cfg, cfg_modify_index)
                    -- [TODO] handle config apply error
                    bootstrap_done = true
                end
            end,
            onstatechange = function(sm, event, from, to)
                local states_with_locking = {STATE_FOLLOWER, STATE_PROMOTING, STATE_LEADER}
                if not util.has(states_with_locking, to) then --
                    stop_locking()
                end
                -- if from ~= to then log.info("self: entered state %s", to) end
                log.info("autovshard: changed state %s -> %s", from, to)
            end,
        },
    })

    function sm:event(e, ...) --
        log.info("autovshard: got event: %s", e)
        if self:can(e) then self[e](self, ...) end
    end

    while true do
        sm:event(EVENT_START)
        local msg = self.events:get()
        if msg == nil then break end
        sm:event(unpack(msg))
    end
end

function Autovshard:stop()
    if not self.started then return false end
    self.events:put{EVENT_STOP}
    self.started = false
    return true
end

function Autovshard:start()
    if self.started then return false end
    self.started = true
    fiber.create(self._mainloop, self)
    return true
end

return {Autovshard = Autovshard, _VERSION = "1.0.1"}
