require("package.reload")

vshard = require("vshard")

local box_cfg = {listen = 3301, feedback_enabled = false}

autovshard = require("autovshard").Autovshard.new{
    box_cfg = box_cfg,
    cluster_name = "mycluster",
    login = "storage",
    password = "storage",
    consul_http_address = "http://consul:8500",
    consul_token = nil,
    consul_kv_prefix = "autovshard",
    router = true,
    storage = false,
}
autovshard:start()
package.reload:register(autovshard, autovshard.stop)

function test(x)
    local bucket_id = vshard.router.bucket_id(x)
    return vshard.router.callrw(bucket_id, "tostring", {"test ok"})
end

function get(x)
    local bucket_id = vshard.router.bucket_id(x)
    return vshard.router.callrw(bucket_id, "get", {x})
end

function put(x, ...)
    local bucket_id = vshard.router.bucket_id(x)
    return vshard.router.callrw(bucket_id, "put", {x, bucket_id, ...})
end

function delete(x, ...)
    local bucket_id = vshard.router.bucket_id(x)
    return vshard.router.callrw(bucket_id, "delete", {x, bucket_id, ...})
end


box.ctl.wait_rw()

box.once("schema.v1.grant.guest.super", box.schema.user.grant, "guest", "super")
