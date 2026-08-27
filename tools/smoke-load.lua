-- tools/smoke-load.lua — runtime require-chain smoke test.
--
-- `make parse` only runs `luajit -bl` (parse-only, no execution) so it cannot
-- detect circular requires or other module-init failures. This script
-- actually loads each plugin module under stubbed KOReader globals to
-- exercise the full require chain.
--
-- Catches the failure mode where two modules require each other at
-- module-init (e.g. T2/T3 era runner.lua ↔ triggers.lua) which produces
-- "loop or previous error loading module" at plugin load time.
--
-- The stubs below are deliberately permissive — every undefined access
-- returns another stub, every call returns a stub. The goal is "modules
-- can be loaded without erroring", not "modules behave correctly".

package.path = "./?.lua;" .. package.path

local function stub()
    return setmetatable({}, {
        __index = function() return stub end,
        __call = function() return stub() end,
    })
end

package.preload["luasettings"] = function()
    return { open = function() return stub() end }
end
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp" end }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        dbg = function() end,
    }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["dispatcher"] = function() return { registerAction = function() end } end
package.preload["ui/uimanager"] = function() return stub() end
package.preload["ui/widget/infomessage"] = function() return { new = function() return stub() end } end
package.preload["ui/widget/buttondialogtitle"] = function() return { new = function() return stub() end } end
package.preload["ui/widget/confirmbox"] = function() return { new = function() return stub() end } end
package.preload["ui/widget/textviewer"] = function() return { new = function() return stub() end } end
package.preload["ui/widget/spinwidget"] = function() return { new = function() return stub() end } end
package.preload["ui/widget/multiinputdialog"] = function() return { new = function() return stub() end } end
package.preload["ui/widget/pathchooser"] = function() return { new = function() return stub() end } end
package.preload["ui/widget/container/widgetcontainer"] = function() return { extend = function() return { name = "stub" } end } end
package.preload["ui/event"] = function() return { new = function() return stub() end } end
package.preload["ui/network/manager"] = function() return stub() end
package.preload["ffi/util"] = function() return { template = function(s) return s end } end
package.preload["util"] = function()
    return {
        partialMD5 = function() return "" end,
        makePath = function() return true end,
    }
end
package.preload["socketutil"] = function() return nil end
package.preload["ltn12"] = function() return { source = stub(), sink = stub() } end
package.preload["socket"] = function() return stub() end
package.preload["socket.http"] = function() return { request = function() return nil end } end
package.preload["device"] = function() return nil end

G_reader_settings = setmetatable({
    has = function() return false end,
    isTrue = function() return false end,
    readSetting = function() return nil end,
    saveSetting = function() end,
    flipNilOrFalse = function() end,
}, {})

local modules = { "wdas_settings", "wdas_triggers", "wdas_runner", "wdas_ui", "wdas_sync", "wdas_webdav" }
local failed = false
for _, m in ipairs(modules) do
    local ok, err = pcall(require, m)
    if ok then
        print("ok   " .. m)
    else
        print("FAIL " .. m .. ": " .. tostring(err))
        failed = true
    end
end

if failed then
    os.exit(1)
end

-- Static namespace guard.
--
-- KOReader loads every plugin into a single Lua state, so `package.loaded` is
-- one shared namespace. Whichever plugin requires a given module name first
-- wins, and plugins load alphabetically. A module named `settings` or `sync`
-- is therefore not ours by default -- another plugin can already own it, and
-- our require() silently returns *their* table. Nothing fails at load time;
-- the device black-screens later, on the first field access.
--
-- Runtime probing cannot catch this reliably (the bad table loads fine), so
-- assert the invariant on the sources instead: every module this plugin ships
-- is prefixed, and is required only under that prefix.
local PREFIX = "wdas_"
local function check_namespace()
    local own, bad = {}, false
    local ls = io.popen("ls *.lua 2>/dev/null")
    for name in ls:lines() do
        local base = name:match("^(.+)%.lua$")
        if base ~= "main" and base ~= "_meta" then
            if not base:find("^" .. PREFIX) then
                print("FAIL namespace: " .. name .. " ships an unprefixed module name")
                bad = true
            end
            own[base] = true
        end
    end
    ls:close()

    local files = io.popen("ls *.lua 2>/dev/null")
    for name in files:lines() do
        local fh = io.open(name)
        local src = fh:read("*a")
        fh:close()
        for req in src:gmatch('require%("([%w_]+)"%)') do
            if own[PREFIX .. req] and not req:find("^" .. PREFIX) then
                print("FAIL namespace: " .. name .. ' requires "' .. req
                      .. '" -- must be "' .. PREFIX .. req .. '"')
                bad = true
            end
        end
    end
    files:close()
    return not bad
end

if not check_namespace() then
    os.exit(1)
end
print("ok   module namespace (all own modules prefixed \"" .. PREFIX .. "\")")

print("all modules loaded successfully")
