local fiber = require("fiber")

require("package.reload")

vshard = require("vshard")

local box_cfg = {
    listen = 3301,
    feedback_enabled = false,
    instance_uuid = assert(os.getenv("TARANTOOL_INSTANCE_UUID"),
                           "TARANTOOL_INSTANCE_UUID env variable must be set"),
    replicaset_uuid = assert(os.getenv("TARANTOOL_REPLICASET_UUID"),
                             "TARANTOOL_REPLICASET_UUID env variable must be set"),
}

autovshard = require("autovshard").Autovshard.new{
    box_cfg = box_cfg,
    cluster_name = "mycluster",
    login = "storage",
    password = "storage",
    consul_http_address = "http://consul:8500",
    consul_token = nil,
    consul_kv_prefix = "autovshard",
    router = true,
    storage = true,
    automaster = true,
}

autovshard:start()
package.reload:register(autovshard, autovshard.stop)
-- box.ctl.on_shutdown(function() autovshard:stop() end)  -- tarantool 2.x only

-- public storage API
function put(x, bucket_id, ...)
    --
    return box.space.test:put(box.tuple.new(x, bucket_id, ...))
end

function get(x) --
    return box.space.test:get(x)
end

function delete(x) --
    return box.space.test:delete(x)
end

local function err_if_not_started()
    -- check if tarantool instance bootstrap is done
    box.info()
    -- check if vshard cfg is applied
    vshard.storage.buckets_count()
end
repeat fiber.sleep(0.1) until pcall(err_if_not_started)

if not box.info().ro then
    -- perform write operation

    -- Not using box.once because it is not compatible with package.reload.
    -- box.once calls box.ctl.wait_rw() internally.
    -- And box.ctl.wait_rw blocks forever on subsequent calls on a RW instance.

    box.schema.user.grant('guest', 'super', nil, nil, {if_not_exists = true})

    local s = box.schema.space.create("test", {
        format = { --
            {'id', 'unsigned'}, --
            {'bucket_id', 'unsigned'}, --
            {'data', 'scalar'}, --
        },
        if_not_exists = true,
    })
    s:create_index("pk", {parts = {'id'}, if_not_exists = true})
    s:create_index("bucket_id", {parts = {'bucket_id'}, unique = false, if_not_exists = true})
end
