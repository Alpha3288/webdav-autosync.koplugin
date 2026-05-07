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

local modules = { "settings", "triggers", "runner", "ui", "sync", "webdav" }
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
print("all modules loaded successfully")
