describe("test consul", function()
    local fiber = require("fiber")
    local log = require("log")
    local clock = require("clock")

    local consul = require("autovshard.consul")
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
    end)

    before_each(function()
        local c = require("http.client").new()
        local resp = c:delete(os.getenv("CONSUL_HTTP_ADDR") .. "/v1/kv/test?recurse=")
        consul_client = consul.ConsulClient.new(os.getenv("CONSUL_HTTP_ADDR"))
        assert(resp.status == 200, resp)
    end)

    it("request 1", function()
        local r = consul_client.request{method = "GET", url = "status/leader"}
        assert.are.equal(200, r.status, r)
    end)

    it("request 2", function()
        local r = consul_client.request{
            method = "GET",
            url_path = {"status/leader"},
            body = "",
            params = {pretty = ""},
            headers = {test = "x"},
        }
        assert.are.equal(200, r.status, r)
    end)

    it("session", function()
        local s = consul_client:session(15)
        assert.truthy(s.id)
        assert.truthy(type(s.id) == "string")
        assert.truthy(s.ttl > 0)
        assert.are.equal(s.behavior, "delete")
        local ok, session_json = s:renew()
        assert.is_true(ok)
        assert.are.equal(session_json.ID, s.id)
        assert.is_true(s:delete())
        assert.truthy(type(s.id) == "string")
    end)

    describe("kv", function()
        it("tests put get delete", function()
            assert.truthy(consul_client.put)
            assert.truthy(consul_client.get)

            assert.truthy(consul_client:put("test/put_get_delete_key", "test_put_get_delete_value"))

            -- cas = 0
            assert.is_true(consul_client:put("test/put_get_delete_key2",
                                             "test_put_get_delete_value", 0))

            -- should fail to put with cas=0 if the key exists
            assert.is_false(consul_client:put("test/put_get_delete_key2",
                                              "test_put_get_delete_value", 0))

            local kv, index = consul_client:get("test/put_get_delete_key")
            assert.are.equal("test_put_get_delete_value", kv.value)
            assert.are.equal("test/put_get_delete_key", kv.key)
            assert.is_true(index > 0)

            assert.is_false(consul_client:delete("test/put_get_delete_key", 999))
            assert.is_true(consul_client:delete("test/put_get_delete_key"))
            assert.is_true(consul_client:delete("test/put_get_delete_key"))
            assert.is_true(consul_client:delete("non_existent_key"))
            assert.is_true(consul_client:delete("non_existent_key", 999))
        end)

        it("tests get blocking", function()
            assert.is_nil(consul_client:get("test/blocking_key"))
            local kv, index1 = consul_client:get("test/blocking_key")
            assert.is_nil(kv)
            assert.is_true(index1 > 0)
            local t = clock.monotonic()
            fiber.create(function()
                fiber.sleep(0.2)
                consul_client:put("test/blocking_key", "test_blocking_value")
            end)
            local kv, index2 = consul_client:get("test/blocking_key", 2, index1)
            local elapsed = clock.monotonic() - t
            assert.truthy(elapsed >= 0.2, elapsed)
            assert.truthy(elapsed < 1, elapsed)
            assert.are.equal("test_blocking_value", kv.value)
            assert.is_true(index2 > index1, string.format("index1=%s, index2=%s", index1, index2))
        end)

        it("watch", function()
            fiber.create(function()
                fiber.sleep(0.2)
                consul_client:put("test/watch_key", "test_watch_value")
            end)

            local changes = {}

            local expected_changes = {"no_key", "test_watch_value1", "test_watch_value2", "no_key"}

            local function on_change(kv)
                if kv == nil then
                    table.insert(changes, "no_key")
                else
                    table.insert(changes, kv.value)
                end
            end

            assert.is_nil(consul_client:get("test/watch_key"))
            local fib, stop_watch = consul_client:watch{
                key = "test/watch_key",
                on_change = on_change,
                index = 1,
                rate_limit = 100,
                rate_limit_burst = 100,
                rate_limit_init_burst = 100,
            }
            assert.truthy(fib)
            assert.truthy(stop_watch)
            fiber.sleep(0.01)
            assert.are.equal("suspended", fib:status())
            consul_client:put("test/watch_key", "test_watch_value1")
            fiber.sleep(0.01)
            consul_client:put("test/watch_key", "test_watch_value2")
            fiber.sleep(0.01)
            consul_client:delete("test/watch_key")
            fiber.sleep(0.01)
            assert.are.equal("suspended", fib:status())
            stop_watch()
            fiber.sleep(0.01)
            consul_client:put("test/watch_key", "test_watch_value3")
            fiber.sleep(0.01)
            assert.are.equal("dead", fib:status())
            assert.are.same(expected_changes, changes)
        end)
    end)

    it("multiple addresses", function()
        xzz = 1
        local addresses = {"http://localhost:60666", assert(os.getenv("CONSUL_HTTP_ADDR"))}
        local client = consul.ConsulClient.new(addresses)
        local put = function() return client:put("a", "1") end
        assert.has_error(put)
        -- should swithch to the next address if got error
        assert.is_true(put())
        -- should not swithch to the next address if no errors
        assert.is_true(put())
        assert.is_nil(client:get("no-such-key"))
        -- should not swithch to the next address if not found a key
        assert.is_true(put())
    end)
end)
