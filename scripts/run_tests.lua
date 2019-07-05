local fio = require("fio")
local script_dir = debug.getinfo(1, "S").source:sub(2):match(".*/")
if script_dir == nil then error("cannot determine script dir") end
local tnt = require "tests.tnt"
local root = fio.abspath(fio.pathjoin(script_dir, '..'))

local paths = {
    root .. "/app/?.lua",
    root .. "/?.lua",
    root .. "/?/init.lua",
    root .. "/app/?/init.lua",
    root .. "/.rocks/share/lua/5.1/?.lua",
    root .. "/.rocks/share/lua/5.1/?/init.lua",
}

local cpaths = {
    root .. "/.rocks/lib/lua/5.1/?.so;",
    root .. "/.rocks/lib/lua/?.so;",
    root .. "/.rocks/lib64/lua/5.1/?.so;",
}
package.path = table.concat(paths, ';') .. ';' .. package.path
package.cpath = table.concat(cpaths, ';') .. ';' .. package.cpath

tnt.cfg{wal_mode = 'none', checkpoint_interval = 0}

require("package.reload")

local code, err = pcall(function() return require "busted.runner"{standalone = false} end)

-- [todo] coverage

if not code then
    print("\n========== Tarantool logs =================")
    print(tnt.log())
end

tnt.finish()

os.exit(code)
