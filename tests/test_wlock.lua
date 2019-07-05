local json = require("json")
local util = require("autovshard.util")

describe("test wlock", function()
    local wlock = require("autovshard.wlock")
    local consul = require("autovshard.consul")

    local fiber = require("fiber")
    local log = require("log")

    local consul_client

    local function wait_consul()
        local http_client = require("http.client").new()
        local response
        local t = fiber.time()
        while fiber.time() - t < 10 do
            fiber.sleep(0.1)
            response = http_client:get(os.getenv("CONSUL_HTTP_ADDR") .. "/v1/status/leader",
                                       {timeout = 0.2})
            if response.status == 200 then
                log.info("Consul is up")
                return
            end
            log.error("Consul is DOWN")
        end
        error("Consul did not start")
    end

    setup(function()
        assert(os.getenv("CONSUL_HTTP_ADDR"), "CONSUL_HTTP_ADDR env variable is not set")
        consul_client = require("autovshard.consul").ConsulClient.new(
                            assert(os.getenv("CONSUL_HTTP_ADDR")))
    end)

    before_each(function()
        local c = require("http.client").new()
        local resp = c:delete(os.getenv("CONSUL_HTTP_ADDR") .. "/v1/kv/test?recurse=")
        assert(resp.status == 200, resp)
        assert(consul_client)
    end)

    it("parse_kvs", function()
        local kvs = {
            consul.KV.new{
                create_index = 0,
                modify_index = 0,
                lock_index = 0,
                key = "test/aaaaaaaa-aaaa-aaaa-aaaa-000000000001",
                flags = 0,
                value = '{"weight": 10}',
                session = "aaaaaaaa-aaaa-aaaa-aaaa-000000000001",
            }, consul.KV.new{
                create_index = 0,
                modify_index = 0,
                lock_index = 0,
                key = "test/aaaaaaaa-aaaa-aaaa-aaaa-000000000002",
                flags = 0,
                value = '{"weight": 20}',
                session = "aaaaaaaa-aaaa-aaaa-aaaa-000000000002",
            }, consul.KV.new{
                create_index = 0,
                modify_index = 0,
                lock_index = 0,
                key = "test/lock",
                flags = 0,
                value = '{"holder": "aaaaaaaa-aaaa-aaaa-aaaa-000000000002"}',
                session = nil,
            },
        }
        local contender_weights, holder, max_weight = wlock.parse_kvs(kvs, "test")
        assert.are.same({
            ["aaaaaaaa-aaaa-aaaa-aaaa-000000000001"] = 10,
            ["aaaaaaaa-aaaa-aaaa-aaaa-000000000002"] = 20,
        }, contender_weights, "parsed contender_weights are wrong")

        assert.are.same("aaaaaaaa-aaaa-aaaa-aaaa-000000000002", holder, "bad holder")
        assert.are.equal(20, max_weight, "bad max_weight")

    end)

    it("lock-unlock", function()
        local l1 = wlock.WLock.new(consul_client, "test/wlock", 10, 0)
        local l1_locked = fiber.cond()
        local l1_acquire_ok

        local done = fiber.channel()

        fiber.new(util.ok_or_log_error, function()
            l1_acquire_ok = l1:acquire(done)
            l1_locked:broadcast()
        end)
        l1_locked:wait(3)
        assert.is_true(l1_acquire_ok, "l1 should have acquired the lock")

        local l1_released = false
        fiber.new(util.ok_or_log_error, function()
            done:get()
            l1_released = true
        end)

        fiber.sleep(0.01)
        assert.is_false(l1_released, "l1 should not be released")

        -- create another lock with higher weight
        local l2 = wlock.WLock.new(consul_client, "test/wlock", 20, 0)
        local l2_locked = fiber.cond()
        local l2_acquire_ok

        local done2 = fiber.channel()
        fiber.new(function()
            l2_acquire_ok = l2:acquire(done2)
            l2_locked:broadcast()
        end)
        l2_locked:wait(3)
        assert.is_true(l2_acquire_ok, "l2 lock did not lock")
        -- make sure the lock with lower weight released
        fiber.sleep(0.1)
        assert.is_true(l1_released, "l1 should be released")
        done:close()
        done2:close()
    end)

    describe("lock-weight", function()
        local l1, l2, done1, done2, c

        setup(function()
            l1 = wlock.WLock.new(consul_client, "test/wlock", 10)
            l2 = wlock.WLock.new(consul_client, "test/wlock", 20)
            done1 = fiber.channel()
            done2 = fiber.channel()
            c = fiber.channel()
        end)

        teardown(function()
            done1:close()
            done2:close()
            c:close()
            l1, l2, done1, done2, c = nil, nil, nil, nil, nil
        end)

        it("weight", function()
            pending("set_weight takes too long")
            assert.truthy(c)
            local l1_locked
            local f1 = fiber.new(function(c, done1)
                l1_locked = l1:acquire(done1)
                c:put{l1, "locked"}
                done1:get()
                c:put{l1, "released"}
            end, c, done1)

            local l2_locked
            local f2 = fiber.new(function(c, done2)
                l2_locked = l2:acquire(done2)
                c:put{l2, "locked"}
                done2:get()
                c:put{l2, "released"}
            end, c, done2)

            local l, event = unpack(c:get(1))
            assert.are.equal(l, l2)
            assert.are.equal(event, "locked")
            assert.is_true(l2_locked)
            assert.is_nil(c:get(1))

            l1:set_weight(30)
            local msg = c:get(1)
            assert.truthy(msg)
            l, event = unpack(msg)
            assert.are.equal(l, l1)
            assert.are.equal(event, "locked")

            l, event = unpack(c:get(1))
            assert.are.equal(l, l2)
            assert.are.equal(event, "released")
        end)
    end)
end)
