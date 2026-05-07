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
local logger = require("logger")
local settings = require("settings")
local triggers = require("triggers")
local runner = require("runner")
local sync = require("sync")
local ui = require("ui")
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
                callback = function() ui.set_webdav_server(self) end,
            },
            {
                text = _("Import from KOReader cloud storage"),
                keep_menu_open = true,
                callback = function() ui.import_from_cloud_storage(self) end,
            },
            {
                text = _("Choose download folder"),
                keep_menu_open = true,
                callback = function() ui.set_download_folder(self) end,
            },
            {
                text = _("Set file extensions (optional)"),
                keep_menu_open = true,
                callback = function() ui.set_file_extensions(self) end,
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
                        help_text = _("Push the just-closed book's .sdr sidecar (one network request, scoped to that book). Silent — conflicts surface immediately via the per-file dialog."),
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
                            ui.set_cooldown()
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
                            ui.set_close_cooldown()
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
                            ui.set_resume_settle()
                        end,
                        help_text = _("How long to wait after the device wakes before starting an auto-sync. Filters brief system wakes (RTC alarms, hall-sensor twitches, framework background tasks) so they don't burn the cooldown. 0 disables the gate (sync runs immediately on wake — pre-1.7.8 behavior). Default 15 s."),
                    },
                },
            },
            {
                text = _("Help"),
                keep_menu_open = true,
                callback = function() ui.show_help() end,
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
-- within the cooldown is skipped. Conflicts surface immediately via the
-- per-file dialog (1.8.0+ — pre-1.8.0 they were deferred to the next
-- interactive trigger).
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
            ok_callback = function() ui.set_download_folder(self) end,
        })
        return
    end
    if server_url == "" then
        UIManager:show(ConfirmBox:new{
            text = _("WebDAV server not set. Set it now?"),
            ok_text = _("WebDAV server"),
            ok_callback = function() ui.set_webdav_server(self) end,
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

return WebDAVSync
