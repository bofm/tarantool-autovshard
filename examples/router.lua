local fiber = require("fiber")

require("package.reload")

vshard = require("vshard")

local box_cfg = {
    listen = 3301,
    wal_mode = "none",
    feedback_enabled = false,
    replication_connect_quorum = 0,
    replication_connect_timeout=1,
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

local function err_if_not_started()
    -- check if tarantool instance bootstrap is done
    box.info()
    -- check if vshard cfg is applied
    vshard.router.bucket_count()
end
repeat fiber.sleep(0.1) until pcall(err_if_not_started)

if not box.info().ro then --
    box.schema.user.grant('guest', 'super', nil, nil, {if_not_exists = true})
end
