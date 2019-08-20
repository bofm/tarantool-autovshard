fiber = require("fiber")

require("package.reload")

vshard = require("vshard")
autovshard = require("autovshard")

local box_cfg = {
    listen = 3301,
    feedback_enabled = false,
    instance_uuid = "$instance_uuid",
    replicaset_uuid = "$replicaset_uuid",
    replication_connect_quorum = 0,
    replication_connect_timeout = 20,
}

autovshard = require("autovshard").Autovshard.new{
    box_cfg = box_cfg,
    cluster_name = "$cluster_name",
    login = "storage",
    password = "storage",
    consul_http_address = "$consul_http_address",
    consul_token = nil,
    consul_kv_prefix = "autovshard",
    consul_session_ttl = $consul_session_ttl,
    router = $router,
    storage = $storage,
    automaster = $automaster,
}

autovshard:start()
package.reload:register(autovshard, autovshard.stop)
-- box.ctl.on_shutdown(function() autovshard:stop() end)  -- tarantool 2.x only

-- public storage API
if $storage then
    storage = {}

    function storage.put(x, bucket_id, ...)
        --
        return box.space.test:put(box.tuple.new(x, bucket_id, ...))
    end

    function storage.get(x)
        return box.space.test:get(x)
    end

    function storage.delete(x)
        return box.space.test:delete(x)
    end
end

if $router then
    router = {}

    function router.test(x)
        local bucket_id = vshard.router.bucket_id(x)
        return vshard.router.callrw(bucket_id, "tostring", {"test ok"})
    end

    function router.get(x)
        local bucket_id = vshard.router.bucket_id(x)
        return vshard.router.callrw(bucket_id, "get", {x})
    end

    function router.put(x, ...)
        local bucket_id = vshard.router.bucket_id(x)
        return vshard.router.callrw(bucket_id, "put", {x, bucket_id, ...})
    end

    function router.delete(x, ...)
        local bucket_id = vshard.router.bucket_id(x)
        return vshard.router.callrw(bucket_id, "delete", {x, bucket_id, ...})
    end
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
