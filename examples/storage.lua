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
-- box.ctl.on_shutdown(function() autovshard:stop() end)

box.ctl.wait_ro()
vshard.storage.sync()
pcall(vshard.router.bootstrap)
box.once("schema.v1.grant.guest.super", box.schema.user.grant, "guest", "super")
box.once("schema.v1.space.test", function()
    --
    local s = box.schema.space.create("test")
    s:create_index("pk")
    -- s:create_index("bucket_id")
end)

function put(x, bucket_id)
    --
    return box.space.test:put(box.tuple.new(x, bucket_id))
end

function get(x) return box.space.test:get(x) end
