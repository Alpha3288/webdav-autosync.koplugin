--[[--
WebDAV Auto Sync plugin for KOReader.
Connect to a WebDAV server (optional credentials), choose a local folder,
and auto-download or manually pull all files.
@module koplugin.webdav_autosync
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
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
            self:doSync({ is_auto = true })
        end)
    end
end

function WebDAVSync:addToMainMenu(menu_items)
    menu_items.webdav_sync = {
        text = _("WebDAV Sync"),
        sorting_hint = "tools",
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
                text = _("Import from KOReader cloud storage"),
                keep_menu_open = true,
                callback = function()
                    self:importFromCloudStorage()
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
            {
                text = _("Two-way sync (upload local changes)"),
                checked_func = function()
                    return G_reader_settings:isTrue("webdav_autosync_two_way")
                end,
                callback = function()
                    local enabled = G_reader_settings:isTrue("webdav_autosync_two_way")
                    G_reader_settings:saveSetting("webdav_autosync_two_way", not enabled)
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

--- Open KOReader's cloud-storage picker and import the chosen WebDAV server.
--- Mirrors the pattern used by upstream plugins (statistics, vocabbuilder):
--- delegate to cloudstorage's own picker so the user can also pick a folder
--- inside the server, and store whatever it returns.
function WebDAVSync:importFromCloudStorage()
    local cs = self.ui.cloudstorage
    if not cs or not cs.onShowCloudStorageList then
        UIManager:show(InfoMessage:new{
            text = _("KOReader's Cloud storage plugin is not available."),
        })
        return
    end
    cs:onShowCloudStorageList(function(server)
        if not server then return end
        if server.type ~= "webdav" then
            UIManager:show(InfoMessage:new{
                text = _("Please pick a WebDAV server (other server types are not supported)."),
            })
            return
        end
        self:applyCloudStorageEntry(server)
    end)
end

function WebDAVSync:applyCloudStorageEntry(server)
    -- The cloudstorage callback returns: name, type, address, username,
    -- password, url. `address` is the server base, `url` is the folder path
    -- the user navigated to inside the picker.
    local server_url = (server.address or ""):gsub("/+$", "")
    local start = server.url or ""
    if start ~= "" then
        if not start:match("^/") then start = "/" .. start end
        server_url = server_url .. start
    end
    self:saveSetting("server_url", server_url)
    self:saveSetting("username", server.username or "")
    self:saveSetting("password", server.password or "")

    local label = (server.name and server.name ~= "") and server.name or (server.address or "")
    UIManager:show(InfoMessage:new{
        text = T(_("Imported WebDAV server '%1'."), label),
    })
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

function WebDAVSync:doSync(opts)
    opts = opts or {}
    local is_auto = opts.is_auto
    local turn_off_wifi = opts.turn_off_wifi

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isWifiOn and not NetworkMgr:isWifiOn() then
        UIManager:show(ConfirmBox:new{
            text = _("WiFi is not enabled. Turn on WiFi now?"),
            ok_text = _("Turn on WiFi"),
            ok_callback = function()
                NetworkMgr:turnOnWifi(function()
                    self:doSync({ is_auto = is_auto, turn_off_wifi = true })
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

    local two_way = G_reader_settings and G_reader_settings:isTrue("webdav_autosync_two_way")
    local ctx = {
        server_url = server_url,
        username = username,
        password = password,
        folder = folder,
        file_extensions = file_extensions,
        is_auto = is_auto,
        turn_off_wifi = turn_off_wifi,
    }
    if two_way then
        self:runTwoWaySync(ctx)
    else
        self:runOneWaySync(ctx)
    end
end

function WebDAVSync:runOneWaySync(ctx)
    local syncing_msg = InfoMessage:new{ text = _("Syncing…") }
    UIManager:show(syncing_msg)
    UIManager:forceRePaint()
    local ok, skip, err = sync.run_sync(ctx.server_url, ctx.username, ctx.password,
            ctx.folder, nil, ctx.file_extensions)
    UIManager:close(syncing_msg)
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
    self:turnOffWifiIfRequested(ctx)
end

function WebDAVSync:runTwoWaySync(ctx)
    local syncing_msg = InfoMessage:new{ text = _("Syncing…") }
    UIManager:show(syncing_msg)
    UIManager:forceRePaint()

    local plan_obj, err = sync.plan(ctx.server_url, ctx.username, ctx.password,
            ctx.folder, ctx.file_extensions)
    if not plan_obj then
        UIManager:close(syncing_msg)
        UIManager:show(InfoMessage:new{
            text = T(_("Sync failed: %1"), tostring(err)),
        })
        self:turnOffWifiIfRequested(ctx)
        return
    end

    local stats = {
        downloaded = 0,
        uploaded = 0,
        unchanged = plan_obj.actions.skipped_unchanged,
        baselined = plan_obj.actions.baselined,
        conflicts_skipped = 0,
        failed = 0,
        failures = {},
    }

    for _, a in ipairs(plan_obj.actions.to_download) do
        local ok, msg = sync.do_action(plan_obj, "download", a)
        if ok then
            stats.downloaded = stats.downloaded + 1
        else
            stats.failed = stats.failed + 1
            table.insert(stats.failures, a.rel .. " (" .. tostring(msg) .. ")")
        end
    end
    for _, a in ipairs(plan_obj.actions.to_upload) do
        local ok, msg = sync.do_action(plan_obj, "upload", a)
        if ok then
            stats.uploaded = stats.uploaded + 1
        else
            stats.failed = stats.failed + 1
            table.insert(stats.failures, a.rel .. " (" .. tostring(msg) .. ")")
        end
    end

    UIManager:close(syncing_msg)

    local conflicts = plan_obj.actions.conflicts
    local function finish()
        sync.save_cache(plan_obj)
        self:showTwoWaySummary(stats)
        self:turnOffWifiIfRequested(ctx)
    end

    if #conflicts == 0 or ctx.is_auto then
        if ctx.is_auto then
            stats.conflicts_skipped = #conflicts
        end
        finish()
        return
    end

    self:resolveConflictsInteractive(plan_obj, conflicts, stats, finish)
end

function WebDAVSync:resolveConflictsInteractive(plan_obj, conflicts, stats, on_done)
    local idx = 1
    local function next_one()
        if idx > #conflicts then
            on_done()
            return
        end
        local c = conflicts[idx]
        local dialog
        local function pick(action)
            UIManager:close(dialog)
            idx = idx + 1
            if action == "skip" then
                stats.conflicts_skipped = stats.conflicts_skipped + 1
                next_one()
                return
            end
            local ok, msg = sync.do_action(plan_obj, action, c)
            if ok then
                if action == "download" then
                    stats.downloaded = stats.downloaded + 1
                else
                    stats.uploaded = stats.uploaded + 1
                end
            else
                stats.failed = stats.failed + 1
                table.insert(stats.failures, c.rel .. " (" .. tostring(msg) .. ")")
            end
            next_one()
        end
        dialog = ButtonDialogTitle:new{
            title = T(_("Conflict on %1\nBoth local and remote changed since last sync."), c.rel),
            buttons = {
                {{ text = _("Keep local (upload)"),     callback = function() pick("upload")   end }},
                {{ text = _("Keep remote (download)"),  callback = function() pick("download") end }},
                {{ text = _("Skip"),                    callback = function() pick("skip")     end }},
            },
        }
        UIManager:show(dialog)
    end
    next_one()
end

function WebDAVSync:showTwoWaySummary(stats)
    local parts = {}
    table.insert(parts, T(_("%1 downloaded."), tostring(stats.downloaded)))
    table.insert(parts, T(_("%1 uploaded."), tostring(stats.uploaded)))
    if stats.unchanged > 0 then
        table.insert(parts, T(_("%1 unchanged."), tostring(stats.unchanged)))
    end
    if stats.baselined > 0 then
        table.insert(parts, T(_("%1 baselined."), tostring(stats.baselined)))
    end
    if stats.conflicts_skipped > 0 then
        table.insert(parts, T(_("%1 conflicts skipped."), tostring(stats.conflicts_skipped)))
    end
    if stats.failed > 0 then
        table.insert(parts, T(_("%1 failed."), tostring(stats.failed)))
    end
    local text = _("Sync done.") .. " " .. table.concat(parts, " ")
    if stats.failed > 0 and #stats.failures > 0 then
        text = text .. "\n\n" .. table.concat(stats.failures, "\n")
    end
    UIManager:show(InfoMessage:new{ text = text })
end

function WebDAVSync:turnOffWifiIfRequested(ctx)
    if not ctx.turn_off_wifi then return end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.turnOffWifi then
        NetworkMgr:turnOffWifi()
    end
end

return WebDAVSync
