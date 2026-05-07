--[[--
WebDAV Auto Sync plugin for KOReader.
Connect to a WebDAV server (optional credentials), choose a local folder,
and auto-download or manually pull all files.
@module koplugin.webdav_autosync
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local TextViewer = require("ui/widget/textviewer")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")
local settings = require("settings")
local triggers = require("triggers")
local runner = require("runner")
local sync = require("sync")
local webdav = require("webdav")
local T = require("ffi/util").template
local _ = require("gettext")

local WebDAVSync = WidgetContainer:extend{
    name = "webdav_autosync",
    -- `is_doc_only = false` is deliberate: we need lifecycle events
    -- (CloseDocument/Suspend/Resume) from the reader AND the file-manager
    -- context for book auto-sync. KOReader instantiates the plugin once
    -- per UI surface, so onSuspend/onResume fire on both instances; the
    -- module-local debounce timestamps below are shared, so duplicate
    -- broadcasts collapse into a single sync.
    is_doc_only = false,
}

function WebDAVSync:init()
    Dispatcher:registerAction("webdav_sync_now", {
        category = "none",
        event = "WebDAVSyncNow",
        title = _("WebDAV sync books now"),
        general = true,
    })
    Dispatcher:registerAction("webdav_progress_sync_now", {
        category = "none",
        event = "WebDAVProgressSyncNow",
        title = _("WebDAV sync reading progress now"),
        general = true,
    })
    triggers.bind(self)
    self.ui.menu:registerToMainMenu(self)
    local ui_kind = (self.ui and self.ui.document) and "reader" or "filemanager"
    logger.dbg("webdav_autosync: init ui=" .. ui_kind)
    triggers.schedule_startup_sync()
end

function WebDAVSync:addToMainMenu(menu_items)
    menu_items.webdav_sync = {
        text = _("WebDAV Sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync books now"),
                callback = function()
                    settings.mark_auto_run()
                    self:doSync()
                end,
            },
            {
                text = _("Sync reading progress now"),
                callback = function()
                    settings.mark_auto_run()
                    self:doProgressSync({ manual = true })
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
                text = _("Two-way book sync (upload local changes)"),
                checked_func = function()
                    return G_reader_settings:isTrue("webdav_autosync_books_two_way")
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse("webdav_autosync_books_two_way")
                end,
                help_text = _("Affects book sync only. Off: download-only. On: also upload local additions and changes; conflicts (a file changed on both sides) prompt per file."),
            },
            {
                text = _("Auto sync triggers"),
                sub_item_table = {
                    {
                        text = _("Enable auto sync"),
                        checked_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_master")
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse("webdav_autosync_master")
                        end,
                        help_text = _("Master switch for every automatic trigger below. Off: nothing fires automatically (manual sync still works). On: each individual trigger toggle takes effect."),
                        separator = true,
                    },
                    {
                        text = _("Sync books on startup"),
                        enabled_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_master")
                        end,
                        checked_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_books_on_startup")
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse("webdav_autosync_books_on_startup")
                        end,
                        help_text = _("Run book sync once when KOReader starts. File-manager context only."),
                    },
                    {
                        text = _("Sync books on wake"),
                        enabled_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_master")
                        end,
                        checked_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_books_on_resume")
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse("webdav_autosync_books_on_resume")
                        end,
                        help_text = _("Run book sync after the device wakes from sleep. File-manager context only."),
                        separator = true,
                    },
                    {
                        text = _("Sync reading progress on startup"),
                        enabled_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_master")
                        end,
                        checked_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_progress_on_startup")
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse("webdav_autosync_progress_on_startup")
                        end,
                        help_text = _("Reconcile every .sdr sidecar (reading position, bookmarks, highlights) once when KOReader starts. Conflicts pop a per-file dialog."),
                    },
                    {
                        text = _("Sync reading progress on wake"),
                        enabled_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_master")
                        end,
                        checked_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_progress_on_resume")
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse("webdav_autosync_progress_on_resume")
                        end,
                        help_text = _("Reconcile every .sdr sidecar after the device wakes from sleep. Conflicts pop a per-file dialog."),
                    },
                    {
                        text = _("Sync reading progress on book close"),
                        enabled_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_master")
                        end,
                        checked_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_progress_on_close")
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse("webdav_autosync_progress_on_close")
                        end,
                        help_text = _("Push the just-closed book's .sdr sidecar (one network request, scoped to that book). Silent — conflicts are held for the next wake/startup trigger."),
                        separator = true,
                    },
                    {
                        text_func = function()
                            return T(_("Auto sync cooldown: %1 s"), tostring(settings.get_cooldown()))
                        end,
                        enabled_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_master")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:setCooldown()
                        end,
                        help_text = _("Minimum seconds between auto-triggered full reconciles (device wake, KOReader startup). Manual syncs always run regardless. The book-close trigger has its own cooldown below. 0 disables. Default 300 s."),
                    },
                    {
                        text_func = function()
                            return T(_("Close-trigger sync cooldown: %1 s"), tostring(settings.get_close_cooldown()))
                        end,
                        enabled_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_master")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:setCloseCooldown()
                        end,
                        help_text = _("Minimum seconds between two consecutive close-trigger syncs of the same book. Closing a different book always runs regardless (each book's .sdr/ is independent). 0 disables. Default 30 s."),
                    },
                    {
                        text_func = function()
                            local secs = settings.get_resume_settle()
                            if secs <= 0 then
                                return _("Wake settle delay: 0 s (disabled)")
                            end
                            return T(_("Wake settle delay: %1 s"), tostring(secs))
                        end,
                        enabled_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_master")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:setResumeSettle()
                        end,
                        help_text = _("How long to wait after the device wakes before starting an auto-sync. Filters brief system wakes (RTC alarms, hall-sensor twitches, framework background tasks) so they don't burn the cooldown. 0 disables the gate (sync runs immediately on wake — pre-1.7.8 behavior). Default 15 s."),
                    },
                },
            },
            {
                text = _("Help"),
                keep_menu_open = true,
                callback = function()
                    self:showHelp()
                end,
            },
        },
    }
end

function WebDAVSync:onWebDAVSyncNow()
    settings.mark_auto_run()
    logger.info("webdav_autosync: trigger=manual_books")
    self:doSync()
    return true
end

function WebDAVSync:onWebDAVProgressSyncNow()
    settings.mark_auto_run()
    logger.info("webdav_autosync: trigger=manual_progress")
    self:doProgressSync({ manual = true })
    return true
end

-- Close trigger: scoped to just the closed book's `.sdr/` (one PROPFIND).
-- Per-book debounce: closing a *different* book always runs (different
-- sidecar dir, no overlap with the prior sync); closing the same book
-- within the cooldown is skipped. Conflicts are silently deferred — they
-- re-surface at the next interactive trigger (Resume or startup).
function WebDAVSync:onCloseDocument()
    if not settings.event_enabled("progress_on_close") then
        logger.dbg("webdav_autosync: trigger=close skip reason=disabled")
        return
    end
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then
        logger.dbg("webdav_autosync: trigger=close skip reason=no-document")
        return
    end

    local local_folder = settings.get("download_folder", "")
    if type(local_folder) ~= "string" or local_folder == "" then
        logger.dbg("webdav_autosync: trigger=close skip reason=no-download-folder")
        return
    end
    local trimmed = local_folder:gsub("/+$", "")

    -- Book opened from outside the synced library — no remote mapping; no-op.
    -- Don't fall back to a full-library walk on close, that defeats the
    -- whole reason this trigger is scoped.
    if doc.file:sub(1, #trimmed + 1) ~= trimmed .. "/" then
        logger.dbg("webdav_autosync: trigger=close skip reason=outside-library file=" .. tostring(doc.file))
        return
    end
    local book_rel = doc.file:sub(#trimmed + 2)
    if book_rel == "" then
        logger.dbg("webdav_autosync: trigger=close skip reason=empty-relpath")
        return
    end

    if not settings.should_run_close(book_rel) then
        logger.dbg("webdav_autosync: trigger=close skip reason=debounce book=" .. book_rel)
        return
    end
    settings.mark_close_run(book_rel)
    logger.info("webdav_autosync: trigger=close book=" .. book_rel)
    self:doProgressSyncForBook(book_rel)
end

function WebDAVSync:onResume()
    triggers.on_resume()
end

function WebDAVSync:onSuspend()
    triggers.on_suspend()
end

function WebDAVSync:setWebDAVServer()
    local text_info = _("Server address must be of the form http(s)://domain.name/path\n(e.g. https://example.com/webdav).\nUsername and password are optional.")
    local addr = settings.get("server_url", "")
    local user = settings.get("username", "")
    local pass = settings.get("password", "")
    if type(addr) ~= "string" then addr = "" end
    if type(user) ~= "string" then user = "" end
    if type(pass) ~= "string" then pass = "" end
    local dref = {}
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
                        a = a:gsub("^%s+", ""):gsub("%s+$", "")
                        -- Reject typo'd URLs at save time so subsequent syncs
                        -- don't fail with a cryptic "Server URL has no host"
                        -- popup. Empty leaves the existing URL untouched (user
                        -- editing only credentials). Non-empty must parse to
                        -- something with a host — webdav.url_has_host runs the
                        -- same normalize_url(...) the sync paths use, so what
                        -- passes here is what they accept.
                        if a ~= "" and not webdav.url_has_host(a) then
                            UIManager:show(InfoMessage:new{
                                text = _("Server URL must include a host (e.g. https://example.com/webdav)."),
                            })
                            return
                        end
                        if a ~= "" then settings.save("server_url", a) end
                        settings.save("username", u)
                        settings.save("password", p)
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
--- Two routes depending on KOReader version:
---   * Pre-2026.03: the cloudstorage plugin is attached to self.ui, expose
---     onShowCloudStorageList(callback). Same path statistics.koplugin and
---     vocabbuilder.koplugin used to take.
---   * 2026.03+: plugins/cloudstorage.koplugin was removed; statistics and
---     vocabbuilder migrated to SyncService:new{} with onConfirm. We do the
---     same. The onConfirm callback receives a server table with the same
---     shape as the legacy callback (name, type, address, username,
---     password, url) so applyCloudStorageEntry handles both uniformly.
function WebDAVSync:importFromCloudStorage()
    local handler = function(server)
        if not server then return end
        if server.type ~= "webdav" then
            UIManager:show(InfoMessage:new{
                text = _("Please pick a WebDAV server (other server types are not supported)."),
            })
            return
        end
        self:applyCloudStorageEntry(server)
    end

    local cs = self.ui.cloudstorage
    if cs and cs.onShowCloudStorageList then
        cs:onShowCloudStorageList(handler)
        return
    end

    local ok, SyncService = pcall(require, "frontend/apps/cloudstorage/syncservice")
    if ok and SyncService then
        local picker = SyncService:new{}
        picker.onClose = function(this) UIManager:close(this) end
        picker.onConfirm = handler
        UIManager:show(picker)
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("KOReader's Cloud storage feature is not available."),
    })
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
    settings.save("server_url", server_url)
    settings.save("username", server.username or "")
    settings.save("password", server.password or "")

    local label = (server.name and server.name ~= "") and server.name or (server.address or "")
    UIManager:show(InfoMessage:new{
        text = T(_("Imported WebDAV server '%1'."), label),
    })
end

function WebDAVSync:setDownloadFolder()
    local current = settings.get("download_folder", "")
    if type(current) ~= "string" then current = nil end
    if current == "" then current = nil end
    -- Prefer home directory when no folder is set (not /mnt or data dir)
    local initial_dir = current
    if not initial_dir or initial_dir == "" then
        local ok_dev, Device = pcall(require, "device")
        if ok_dev and Device and Device.home_dir then
            initial_dir = Device.home_dir
        end
        if not initial_dir then
            local ok_ds, DataStorage = pcall(require, "datastorage")
            if ok_ds and DataStorage and DataStorage.getFullDataDir then
                initial_dir = DataStorage:getFullDataDir() or nil
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
                settings.save("download_folder", dir_path)
            end
            UIManager:close(path_chooser)
        end,
    }
    UIManager:show(path_chooser)
end

function WebDAVSync:setCooldown()
    UIManager:show(SpinWidget:new{
        title_text = _("Auto sync cooldown (seconds)"),
        info_text = _("Minimum seconds between auto-triggered full reconciles (device wake, KOReader startup). Manual syncs always run regardless. The book-close trigger has its own cooldown. Set to 0 to disable."),
        value = settings.get_cooldown(),
        value_min = settings.COOLDOWN_MIN,
        value_max = settings.COOLDOWN_MAX,
        value_step = settings.COOLDOWN_STEP,
        value_hold_step = settings.COOLDOWN_STEP * 2,
        default_value = settings.DEFAULT_COOLDOWN,
        ok_text = _("Set"),
        callback = function(spin)
            G_reader_settings:saveSetting("webdav_autosync_cooldown_seconds", spin.value)
        end,
    })
end

function WebDAVSync:setCloseCooldown()
    UIManager:show(SpinWidget:new{
        title_text = _("Close-trigger cooldown (seconds)"),
        info_text = _("Minimum seconds between two consecutive close-trigger syncs of the same book. Closing a different book always runs regardless. Set to 0 to disable."),
        value = settings.get_close_cooldown(),
        value_min = settings.CLOSE_COOLDOWN_MIN,
        value_max = settings.CLOSE_COOLDOWN_MAX,
        value_step = settings.CLOSE_COOLDOWN_STEP,
        value_hold_step = settings.CLOSE_COOLDOWN_STEP * 3,
        default_value = settings.DEFAULT_CLOSE_COOLDOWN,
        ok_text = _("Set"),
        callback = function(spin)
            G_reader_settings:saveSetting("webdav_autosync_close_cooldown_seconds", spin.value)
        end,
    })
end

function WebDAVSync:setResumeSettle()
    UIManager:show(SpinWidget:new{
        title_text = _("Wake settle delay (seconds)"),
        info_text = _("How long to wait after the device wakes before starting an auto-sync. Filters brief system wakes (RTC alarms, hall-sensor twitches, framework background tasks) that don't represent the user actually picking up the device. 0 disables the gate (sync runs immediately on wake)."),
        value = settings.get_resume_settle(),
        value_min = settings.RESUME_SETTLE_MIN,
        value_max = settings.RESUME_SETTLE_MAX,
        value_step = settings.RESUME_SETTLE_STEP,
        value_hold_step = settings.RESUME_SETTLE_STEP * 2,
        default_value = settings.DEFAULT_RESUME_SETTLE,
        ok_text = _("Set"),
        callback = function(spin)
            G_reader_settings:saveSetting("webdav_autosync_resume_settle_seconds", spin.value)
            triggers.on_resume_settle_changed(spin.value)
        end,
    })
end

function WebDAVSync:setFileExtensions()
    local current = settings.get("file_extensions", "")
    if type(current) ~= "string" then current = "" end
    local dref = {}
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
                        settings.save("file_extensions", (fields and fields[1]) or "")
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
    local silent_mode = opts.silent_mode == true
    local chain_stats = opts.chain_stats
    local on_done = opts.on_done

    if triggers.check_in_flight("book sync", not is_auto) then
        if on_done then on_done() end
        return
    end

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isWifiOn and not NetworkMgr:isWifiOn() then
        if is_auto then
            logger.dbg("webdav_autosync: book sync skip reason=offline (auto)")
            if on_done then on_done() end
            return
        end
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

    local server_url = settings.get("server_url", "")
    if type(server_url) == "string" then
        server_url = server_url:gsub("^%s+", ""):gsub("%s+$", "")
    else
        server_url = ""
    end
    local username = settings.get("username", "")
    local password = settings.get("password", "")
    local local_folder = settings.get("download_folder", "")
    local file_extensions = settings.get("file_extensions", "")
    if not local_folder or local_folder == "" then
        UIManager:show(ConfirmBox:new{
            text = _("Download folder not set. Choose folder now?"),
            ok_text = _("Choose folder"),
            ok_callback = function() self:setDownloadFolder() end,
        })
        return
    end
    if server_url == "" then
        UIManager:show(ConfirmBox:new{
            text = _("WebDAV server not set. Set it now?"),
            ok_text = _("WebDAV server"),
            ok_callback = function() self:setWebDAVServer() end,
        })
        return
    end

    local two_way = G_reader_settings and G_reader_settings:isTrue("webdav_autosync_books_two_way")
    local ctx = {
        server_url = server_url,
        username = username,
        password = password,
        local_folder = local_folder,
        file_extensions = file_extensions,
        is_auto = is_auto,
        turn_off_wifi = turn_off_wifi,
        silent_mode = silent_mode,
        chain_stats = chain_stats,
        on_done = on_done,
    }
    if two_way then
        logger.info("webdav_autosync: book sync start mode=two_way is_auto=" .. tostring(is_auto == true))
        runner.run_planned(
            function(c) return sync.plan(c.server_url, c.username, c.password,
                    c.local_folder, c.file_extensions) end,
            ctx,
            {
                silent_mode = silent_mode,
                chain_stats = chain_stats,
                chain_section = "books",
                syncing_text = _("Syncing…"),
                summary_prefix = _("Sync done."),
                plan_failure_label = _("book sync"),
                plan_failure_prefix = _("Sync failed: %1"),
                on_done = on_done,
                log_done = function(stats)
                    logger.info(string.format(
                        "webdav_autosync: book sync done mode=two_way downloaded=%d uploaded=%d unchanged=%d baselined=%d conflicts_skipped=%d failed=%d",
                        stats.downloaded, stats.uploaded, stats.unchanged, stats.baselined,
                        stats.conflicts_skipped, stats.failed))
                end,
            })
    else
        logger.info("webdav_autosync: book sync start mode=one_way is_auto=" .. tostring(is_auto == true))
        runner.run_one_way(ctx)
    end
end

function WebDAVSync:maybeRunBookAutoSync(opts)
    opts = opts or {}
    local function done() if opts.on_done then opts.on_done() end end
    if self.ui.document then
        logger.dbg("webdav_autosync: book auto-sync skip reason=reader-context")
        return done()
    end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        logger.dbg("webdav_autosync: book auto-sync skip reason=offline")
        return done()
    end
    self:doSync({
        is_auto = true,
        silent_mode = opts.silent_mode,
        chain_stats = opts.chain_stats,
        on_done = opts.on_done,
    })
end

function WebDAVSync:doProgressSync(opts)
    opts = opts or {}
    local manual = opts.manual == true
    local on_done = opts.on_done
    local silent_mode = opts.silent_mode == true
    local chain_stats = opts.chain_stats
    local function done() if on_done then on_done() end end

    if triggers.check_in_flight("progress sync", manual) then return done() end

    local server_url = settings.get("server_url", "")
    local local_folder = settings.get("download_folder", "")
    if type(server_url) ~= "string" then server_url = "" end
    if type(local_folder) ~= "string" then local_folder = "" end
    server_url = server_url:gsub("^%s+", ""):gsub("%s+$", "")
    if server_url == "" or local_folder == "" then
        logger.dbg("webdav_autosync: progress sync skip reason=not-configured")
        if manual then
            UIManager:show(InfoMessage:new{
                text = _("WebDAV server or download folder is not configured."),
            })
        end
        return done()
    end

    local meta_mode = G_reader_settings and G_reader_settings:readSetting("document_metadata_folder") or "doc"
    if meta_mode ~= "doc" then
        logger.dbg("webdav_autosync: progress sync skip reason=metadata-folder-mode mode=" .. tostring(meta_mode))
        if manual then
            UIManager:show(InfoMessage:new{
                text = _("Reading-progress sync only works when KOReader's document-metadata folder is set to 'Book folder'."),
            })
        end
        return done()
    end

    local NetworkMgr = require("ui/network/manager")
    local function dispatch()
        local username = settings.get("username", "")
        local password = settings.get("password", "")
        logger.info("webdav_autosync: progress sync start")
        local ctx = {
            server_url = server_url,
            username = username,
            password = password,
            local_folder = local_folder,
        }
        runner.run_planned(
            function(c) return sync.plan_progress(c.server_url, c.username, c.password, c.local_folder) end,
            ctx,
            {
                silent_mode = silent_mode,
                chain_stats = chain_stats,
                chain_section = "progress",
                syncing_text = _("Syncing reading progress…"),
                summary_prefix = _("Reading progress synced."),
                plan_failure_label = _("progress sync"),
                plan_failure_prefix = _("Progress sync failed: %1"),
                on_done = on_done,
                log_done = function(stats)
                    logger.info(string.format(
                        "webdav_autosync: progress sync done downloaded=%d uploaded=%d unchanged=%d baselined=%d conflicts_skipped=%d failed=%d",
                        stats.downloaded, stats.uploaded, stats.unchanged, stats.baselined,
                        stats.conflicts_skipped, stats.failed))
                end,
            })
    end

    if not manual then
        if NetworkMgr.isOnline and not NetworkMgr:isOnline() then
            logger.dbg("webdav_autosync: progress sync skip reason=offline (auto)")
            return done()
        end
        return dispatch()
    end

    if NetworkMgr.isWifiOn and not NetworkMgr:isWifiOn() then
        UIManager:show(ConfirmBox:new{
            text = _("WiFi is not enabled. Turn on WiFi now?"),
            ok_text = _("Turn on WiFi"),
            ok_callback = function()
                NetworkMgr:turnOnWifi(function()
                    self:doProgressSync({ manual = true, on_done = on_done })
                end)
            end,
            cancel_callback = done,
        })
        return
    end

    dispatch()
end

function WebDAVSync:doProgressSyncForBook(book_rel)
    if triggers.check_in_flight("close-trigger sync", false) then return end

    local meta_mode = G_reader_settings and G_reader_settings:readSetting("document_metadata_folder") or "doc"
    if meta_mode ~= "doc" then
        logger.dbg("webdav_autosync: close-trigger sync skip reason=metadata-folder-mode mode=" .. tostring(meta_mode))
        return
    end

    local server_url = settings.get("server_url", "")
    local local_folder = settings.get("download_folder", "")
    if type(server_url) ~= "string" then server_url = "" end
    if type(local_folder) ~= "string" then local_folder = "" end
    server_url = server_url:gsub("^%s+", ""):gsub("%s+$", "")
    if server_url == "" or local_folder == "" then
        logger.dbg("webdav_autosync: close-trigger sync skip reason=not-configured book=" .. tostring(book_rel))
        return
    end

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        logger.dbg("webdav_autosync: close-trigger sync skip reason=offline book=" .. tostring(book_rel))
        return
    end

    local username = settings.get("username", "")
    local password = settings.get("password", "")
    logger.info("webdav_autosync: close-trigger sync start book=" .. tostring(book_rel))

    local ctx = {
        server_url = server_url,
        username = username,
        password = password,
        local_folder = local_folder,
        book_rel = book_rel,
    }
    runner.run_planned(
        function(c) return sync.plan_progress_book(c.server_url, c.username, c.password,
                c.local_folder, c.book_rel) end,
        ctx,
        {
            silent_mode = true,
            syncing_text = _("Syncing reading progress…"),
            summary_prefix = _("Reading progress synced."),
            plan_failure_label = _("progress sync"),
            plan_failure_prefix = _("Progress sync failed: %1"),
            on_action_failure = function(kind, rel, msg)
                logger.warn("webdav_autosync: close-trigger " .. kind .. " failed rel=" .. rel .. " err=" .. tostring(msg))
            end,
            log_done = function(stats)
                logger.info(string.format(
                    "webdav_autosync: close-trigger sync done book=%s downloaded=%d uploaded=%d unchanged=%d baselined=%d conflicts_skipped=%d failed=%d",
                    tostring(book_rel), stats.downloaded, stats.uploaded,
                    stats.unchanged, stats.baselined,
                    stats.conflicts_skipped, stats.failed))
            end,
        })
end

function WebDAVSync:showHelp()
    local text = _([[
WebDAV Sync syncs files (and optionally per-book reading progress) between your KOReader device and a WebDAV server.

WHAT EACH MENU ITEM DOES

• Sync books now
  Run a one-shot book-file sync. Downloads matching files from the server. With "Two-way book sync" on, also uploads local additions and changes; conflicts pop a per-file dialog.

• Sync reading progress now
  Run a one-shot reconcile of every .sdr sidecar (reading position, bookmarks, highlights, custom metadata, custom cover). Conflicts pop a per-file dialog.

• WebDAV server
  Set the server URL, username, and password. Shared by book and progress sync.

• Import from KOReader cloud storage
  Copy a server you already configured under KOReader's built-in Cloud storage feature.

• Choose download folder
  Where book files (and their .sdr sidecars) live locally.

• Set file extensions (optional)
  Comma- or space-separated list (e.g. epub, pdf, txt). Empty = all KOReader-supported formats. Applies to book sync only; progress sync ignores this setting.

• Two-way book sync (upload local changes)
  Affects book sync only. Off: download-only. On: also upload local additions and changes, and prompt on conflicts.

• Auto sync triggers (submenu)
  - Enable auto sync — master switch. Off: nothing fires automatically (manual sync still works). On: each individual trigger toggle below takes effect.
  - Sync books on startup / on wake — when on, run book sync at KOReader startup and/or when the device wakes. File-manager context only.
  - Sync reading progress on startup / on wake / on book close — when on, run progress sync at startup, on wake, and/or after closing a book. The startup and wake triggers reconcile the whole library; the book-close trigger pushes only the just-closed book (one network request) and silently defers any conflict to the next startup/wake.
  - Auto sync cooldown — minimum seconds between auto-triggered full reconciles (wake / startup). Manual syncs always run regardless. Default 300 s. Set to 0 to disable.
  - Close-trigger sync cooldown — minimum seconds between two close-trigger syncs of the *same* book. Closing a *different* book always runs regardless. Default 30 s. Set to 0 to disable.

HOW TO SET IT UP

1. Open "WebDAV server" and enter the URL plus optional credentials. Or tap "Import from KOReader cloud storage" to copy them from a server you already have configured.
2. Tap "Choose download folder" and long-press the folder where you want books stored.
3. (Optional) Tap "Set file extensions" if you only want certain formats.
4. Tap "Sync books now" to do an initial download.
5. (Optional) Toggle "Two-way book sync" on if you also want local additions to upload.
6. Open "Auto sync triggers", flip "Enable auto sync" on, then turn on the specific event toggles you want (book / progress, on startup / wake / close).

NOTES

• Reading-progress sync requires KOReader's "Document → Metadata folder" setting to stay at "Book folder" (the default). Other modes place .sdr directories outside the synced library tree and the plugin can't map them to a remote path.
• Book sync and progress sync share the same WebDAV server, credentials, and download folder, but can be enabled independently.
• Conflicts are always resolved by the user — the plugin never picks a winner automatically.
• Auto triggers silently no-op when offline; manual triggers prompt to enable Wi-Fi if needed.]])
    UIManager:show(TextViewer:new{
        title = _("WebDAV Sync — help"),
        text = text,
    })
end

return WebDAVSync
