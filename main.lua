--[[--
WebDAV Auto Sync plugin for KOReader.
Connect to a WebDAV server (optional credentials), choose a local folder,
and auto-download or manually pull all files.
@module koplugin.webdav_autosync
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local sync = require("sync")
local T = require("ffi/util").template
local _ = require("gettext")

local WebDAVSync = WidgetContainer:extend{
    name = "webdav_autosync",
    is_doc_only = false,
}

-- Guards against running auto-sync more than once per KOReader session.
local auto_sync_started = false

function WebDAVSync:init()
    Dispatcher:registerAction("webdav_sync_now", {
        category = "none",
        event = "WebDAVSyncNow",
        title = _("WebDAV sync now"),
        general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    -- Run auto sync once at startup if enabled (only in file manager, not when opening a book)
    if G_reader_settings and G_reader_settings:isTrue("webdav_autosync_enabled")
            and not self.ui.document and not auto_sync_started then
        auto_sync_started = true
        UIManager:scheduleIn(2, function()
            self:doSync()
        end)
    end
end

function WebDAVSync:addToMainMenu(menu_items)
    menu_items.webdav_sync = {
        text = _("WebDAV Sync"),
        sub_item_table = {
            {
                text = _("Sync now"),
                callback = function()
                    self:doSync()
                end,
            },
            {
                text = _("WebDAV server"),
                keep_menu_open = true,
                callback = function()
                    self:setWebDAVServer()
                end,
            },
            {
                text = _("Choose download folder"),
                keep_menu_open = true,
                callback = function()
                    self:setDownloadFolder()
                end,
            },
            {
                text = _("Set file extensions (optional)"),
                keep_menu_open = true,
                callback = function()
                    self:setFileExtensions()
                end,
            },
            {
                text = _("Auto sync on startup"),
                checked_func = function()
                    return G_reader_settings:isTrue("webdav_autosync_enabled")
                end,
                callback = function()
                    local enabled = G_reader_settings:isTrue("webdav_autosync_enabled")
                    G_reader_settings:saveSetting("webdav_autosync_enabled", not enabled)
                end,
            },
        },
    }
end

function WebDAVSync:onWebDAVSyncNow()
    self:doSync()
    return true
end

function WebDAVSync:getSetting(key, default)
    if not G_reader_settings then return default end
    if not G_reader_settings:has("webdav_autosync_" .. key) then return default end
    return G_reader_settings:readSetting("webdav_autosync_" .. key)
end

function WebDAVSync:saveSetting(key, value)
    if G_reader_settings then
        G_reader_settings:saveSetting("webdav_autosync_" .. key, value)
    end
end

function WebDAVSync:setWebDAVServer()
    local text_info = _("Server address must be of the form http(s)://domain.name/path\n(e.g. https://example.com/webdav).\nUsername and password are optional.")
    local addr = self:getSetting("server_url", "")
    local user = self:getSetting("username", "")
    local pass = self:getSetting("password", "")
    if type(addr) ~= "string" then addr = "" end
    if type(user) ~= "string" then user = "" end
    if type(pass) ~= "string" then pass = "" end
    local dref = {}
    local plugin = self
    local ok, err = pcall(function()
        dref[1] = MultiInputDialog:new{
            title = _("WebDAV server"),
            fields = {
                { text = addr, hint = _("Server address (e.g. https://example.com/webdav)"), input_type = "string", },
                { text = user, hint = _("Username (optional)"), input_type = "string", },
                { text = pass, hint = _("Password (optional)"), input_type = "string", },
            },
            buttons = {
                {
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dref[1]) end, },
                    { text = _("Info"), callback = function() UIManager:show(InfoMessage:new{ text = text_info }) end, },
                    { text = _("Save"), callback = function()
                        local d = dref[1]
                        if not d then return end
                        local fields = d:getFields()
                        local a = (fields and fields[1]) and tostring(fields[1]) or ""
                        local u = (fields and fields[2]) and tostring(fields[2]) or ""
                        local p = (fields and fields[3]) and tostring(fields[3]) or ""
                        if a ~= "" then plugin:saveSetting("server_url", a) end
                        plugin:saveSetting("username", u)
                        plugin:saveSetting("password", p)
                        UIManager:close(d)
                    end, },
                },
            },
        }
        UIManager:show(dref[1])
        if dref[1].onShowKeyboard then dref[1]:onShowKeyboard() end
    end)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Error opening dialog: %1"), tostring(err)) })
    end
end

function WebDAVSync:setDownloadFolder()
    local current = self:getSetting("download_folder", "")
    if type(current) ~= "string" then current = nil end
    if current == "" then current = nil end
    local plugin = self
    -- Prefer home directory when no folder is set (not /mnt or data dir)
    local initial_dir = current
    if not initial_dir or initial_dir == "" then
        local ok_dev, Device = pcall(require, "device")
        if ok_dev and Device and Device.home_dir then
            initial_dir = Device.home_dir
        end
        if not initial_dir then
            local ok_ds, DataStorage = pcall(require, "datastorage")
            if ok_ds and DataStorage and DataStorage.getRealPath then
                initial_dir = DataStorage:getRealPath("") or nil
            end
        end
    end
    local PathChooser = require("ui/widget/pathchooser")
    local path_chooser
    path_chooser = PathChooser:new{
        select_file = false,
        show_files = false,
        path = initial_dir,
        onConfirm = function(dir_path)
            if dir_path and dir_path ~= "" then
                plugin:saveSetting("download_folder", dir_path)
            end
            UIManager:close(path_chooser)
        end,
    }
    UIManager:show(path_chooser)
end

function WebDAVSync:setFileExtensions()
    local current = self:getSetting("file_extensions", "")
    if type(current) ~= "string" then current = "" end
    local dref = {}
    local plugin = self
    dref[1] = MultiInputDialog:new{
        title = _("File extensions to sync"),
        fields = {
            {
                text = current,
                hint = _("Empty = all KOReader formats. e.g. epub, pdf, txt"),
                input_type = "string",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dref[1])
                    end,
                },
                {
                    text = _("OK"),
                    callback = function()
                        local d = dref[1]
                        if not d then return end
                        local fields = d:getFields()
                        plugin:saveSetting("file_extensions", (fields and fields[1]) or "")
                        UIManager:close(d)
                    end,
                },
            },
        },
    }
    UIManager:show(dref[1])
    if dref[1].onShowKeyboard then
        dref[1]:onShowKeyboard()
    end
end

function WebDAVSync:doSync(turn_off_wifi)
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isWifiOn and not NetworkMgr:isWifiOn() then
        UIManager:show(ConfirmBox:new{
            text = _("WiFi is not enabled. Turn on WiFi now?"),
            ok_text = _("Turn on WiFi"),
            ok_callback = function()
                NetworkMgr:turnOnWifi(function()
                    -- Pass true so we turn WiFi back off after sync.
                    self:doSync(true)
                end)
            end,
        })
        return
    end


    local server_url = self:getSetting("server_url", "")
    if type(server_url) == "string" then
        server_url = server_url:gsub("^%s+", ""):gsub("%s+$", "")
    else
        server_url = ""
    end
    local username = self:getSetting("username", "")
    local password = self:getSetting("password", "")
    local folder = self:getSetting("download_folder", "")
    local file_extensions = self:getSetting("file_extensions", "")
    if not folder or folder == "" then
        UIManager:show(ConfirmBox:new{
            text = _("Download folder not set. Choose folder now?"),
            ok_text = _("Choose folder"),
            ok_callback = function()
                self:setDownloadFolder()
            end,
        })
        return
    end
    if not server_url or server_url == "" then
        UIManager:show(ConfirmBox:new{
            text = _("WebDAV server not set. Set it now?"),
            ok_text = _("WebDAV server"),
            ok_callback = function()
                self:setWebDAVServer()
            end,
        })
        return
    end
    local syncing_msg = InfoMessage:new{ text = _("Syncing…") }
    UIManager:show(syncing_msg)
    UIManager:forceRePaint()
    local ok, skip, err = sync.run_sync(server_url, username, password, folder, nil, file_extensions)
    if syncing_msg then
        UIManager:close(syncing_msg)
    end
    if err then
        UIManager:show(InfoMessage:new{
            text = T(_("Sync failed: %1"), tostring(err)),
        })
    else
        local msg = T(_("Sync done. Downloaded %1 file(s)."), tostring(ok))
        if (tonumber(skip) or 0) > 0 then
            msg = msg .. " " .. T(_("%1 skipped (already exists)."), tostring(skip))
        end
        UIManager:show(InfoMessage:new{ text = msg })
    end
    if turn_off_wifi and NetworkMgr.turnOffWifi then
        NetworkMgr:turnOffWifi()
    end
end

return WebDAVSync
