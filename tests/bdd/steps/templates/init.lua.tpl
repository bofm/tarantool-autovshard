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

