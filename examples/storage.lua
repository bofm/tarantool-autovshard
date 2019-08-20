fiber = require("fiber")

require("package.reload")

vshard = require("vshard")
autovshard = require("autovshard")

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

function get(x)
    return box.space.test:get(x)
end

function delete(x)
    return box.space.test:delete(x)
end


-- wait for tarantool master instance bootstrap
box.ctl.wait_rw()

-- perform write operation
box.once("schema.v1.grant.guest.super", box.schema.user.grant, "guest", "super")
box.once("schema.v1.space.test", function()
    --
    local s = box.schema.space.create("test")
    s:format({
        { 'id', 'unsigned' },
        { 'bucket_id', 'unsigned' },
        { 'data', 'scalar' },
    })
    s:create_index("pk", { parts = { 'id' } })
    s:create_index("bucket_id", { parts = { 'bucket_id' }, unique = false })
end)
