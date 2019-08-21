local fiber = require("fiber")
local clock = require("clock")

describe("test util", function()
    local util = require("autovshard.util")

    it("urljoin", function() assert.are.equal("aa/b/c", util.urljoin("/aa/", "b/", "/c/")) end)

    it("ok_or_log_error", function()
        assert.are.same({8, 9}, {util.ok_or_log_error(function() return 8, 9 end)})
        assert.is_nil(util.ok_or_log_error(function()
            error("oh")
            return 8
        end))
    end)

    it("rate limiter", function()
        local n = 0
        local function incr() n = n + 1 end

        local incr1 = util.rate_limited(incr, 100, 10)
        local f = fiber.create(function() while not fiber.testcancel() do incr1() end end)
        fiber.sleep(1)
        f:cancel()
        assert.truthy(n >= 90, "cnt=" .. n .. " must be > 90")
        assert.truthy(n <= 110, "cnt=" .. n .. " must be < 110")

        n = 0
        local incr2 = util.rate_limited(incr, 10, 0)
        incr2()
        local t = clock.monotonic()
        incr2()
        incr2()
        local ela = clock.monotonic() - t
        assert.truthy(ela > 0.2, ela)
        assert.truthy(ela < 0.3, ela)

        -- test initial burst
        n = 0
        local incr3 = util.rate_limited(incr, 1, 100, 100)
        t = clock.monotonic()
        for _ = 1, 100 do incr3() end
        ela = clock.monotonic() - t
        assert.truthy(ela < 0.1, ela)
    end)

    it("table_set simple", function()
        local t = {}
        util.table_set(t, {"a", "b", "c"}, 2)
        util.table_set(t, {"a", "b", "z"}, 5)
        assert.are.same({a = {b = {c = 2, z = 5}}}, t)
    end)

    it("deepcompare", function()
        local a
        local b
        a = {1, 2, a = 1, b = 2, c = {d = 4}}
        b = {b = 2, a = 1, c = {d = 4}, 1, 2}
        assert.is_true(util.deepcompare(a, b))

        a = 1
        b = 1
        assert.is_true(util.deepcompare(a, b))

        a = "a"
        b = "a"
        assert.is_true(util.deepcompare(a, b))

        a = {1, 2, a = 1, b = 2, c = {d = 4}}
        b = {1, 2, a = 1, b = 2, c = {d = 99}}
        assert.is_false(util.deepcompare(a, b))

        a = {1, 2, a = 1, b = 2, c = {d = 4}}
        b = {1, 2, a = 1, b = 2, c = {d = ""}}
        assert.is_false(util.deepcompare(a, b))

        a = {1, 2, a = 1, b = 2, c = {d = 4}}
        b = {1, 2, a = 1, b = 2, c = {9, 8}}
        assert.is_false(util.deepcompare(a, b))
    end)
end)
