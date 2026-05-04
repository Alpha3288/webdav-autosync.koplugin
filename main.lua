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
local TextViewer = require("ui/widget/textviewer")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")
local sync = require("sync")
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

-- Single global cooldown shared across all auto trigger paths (close, Resume,
-- startup, and the chained book auto-sync). Module-local so it's shared
-- across the FileManager and ReaderUI plugin instances — KOReader broadcasts
-- Resume to both, and we want at most one sync per cool-down window.
--
-- last_close_book_rel carves out the per-book exception for the close trigger:
-- closing a *different* book hits a different `.sdr/`, so it's not redundant
-- with the prior sync and is allowed regardless of the global cooldown.
-- Closing the *same* book within the cooldown is the redundant case we skip.
local auto_sync_last_run = 0
local last_close_book_rel = nil
local DEFAULT_COOLDOWN = 120
local COOLDOWN_MIN = 0
local COOLDOWN_MAX = 1800
local COOLDOWN_STEP = 30

local function get_cooldown()
    local v = G_reader_settings and G_reader_settings:readSetting("webdav_autosync_cooldown_seconds")
    if type(v) ~= "number" then return DEFAULT_COOLDOWN end
    if v < COOLDOWN_MIN then return COOLDOWN_MIN end
    if v > COOLDOWN_MAX then return COOLDOWN_MAX end
    return v
end

local function should_run_auto()
    local cooldown = get_cooldown()
    if cooldown <= 0 then return true end
    return os.time() - auto_sync_last_run >= cooldown
end

local function should_run_close(book_rel)
    if book_rel ~= last_close_book_rel then return true end
    return should_run_auto()
end

local function mark_auto_run()
    auto_sync_last_run = os.time()
end

local function mark_close_run(book_rel)
    auto_sync_last_run = os.time()
    last_close_book_rel = book_rel
end

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
    self.ui.menu:registerToMainMenu(self)
    -- Startup is an interactive trigger: surface deferred conflicts via
    -- dialog. The runners gate themselves (toggle off, no config, offline)
    -- so the calls are safe even when nothing is configured yet. Chained
    -- via on_done — progress first, then book — so the conflict dialog
    -- chains never overlap on screen. Cooldown is consumed up here so the
    -- chain counts as a single auto-trigger slot.
    UIManager:scheduleIn(2, function()
        if not should_run_auto() then return end
        mark_auto_run()
        self:doProgressSync({
            trigger = "startup",
            interactive = true,
            on_done = function() self:maybeRunBookAutoSync() end,
        })
    end)
end

function WebDAVSync:addToMainMenu(menu_items)
    menu_items.webdav_sync = {
        text = _("WebDAV Sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync books now"),
                callback = function()
                    mark_auto_run()
                    self:doSync()
                end,
            },
            {
                text = _("Sync reading progress now"),
                callback = function()
                    mark_auto_run()
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
                text = _("Auto-sync books"),
                checked_func = function()
                    return G_reader_settings:isTrue("webdav_autosync_books_auto")
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse("webdav_autosync_books_auto")
                end,
                help_text = _("When enabled, runs book sync automatically at KOReader startup and after the device wakes from sleep. File-manager only, debounced to once per 60 seconds."),
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
                text = _("Auto-sync reading progress"),
                keep_menu_open = true,
                checked_func = function()
                    return G_reader_settings:isTrue("webdav_autosync_progress_auto")
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse("webdav_autosync_progress_auto")
                end,
                help_text = _("When enabled, syncs .sdr sidecars (reading position, bookmarks, highlights) on book close (just the closed book), device wake, and KOReader startup. Conflicts on close are deferred to the next wake or startup. Off by default."),
            },
            {
                text_func = function()
                    return T(_("Auto sync cooldown: %1 s"), tostring(get_cooldown()))
                end,
                keep_menu_open = true,
                callback = function()
                    self:setCooldown()
                end,
                help_text = _("Minimum seconds between auto-triggered syncs (book close, device wake, KOReader startup). Manual syncs and closing a different book always run regardless. 0 disables the cooldown. Default 120 s."),
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
    mark_auto_run()
    self:doSync()
    return true
end

function WebDAVSync:onWebDAVProgressSyncNow()
    mark_auto_run()
    self:doProgressSync({ manual = true })
    return true
end

-- Close trigger: scoped to just the closed book's `.sdr/` (one PROPFIND).
-- Per-book debounce: closing a *different* book always runs (different
-- sidecar dir, no overlap with the prior sync); closing the same book
-- within the cooldown is skipped. Conflicts are silently deferred — they
-- re-surface at the next interactive trigger (Resume or startup).
function WebDAVSync:onCloseDocument()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then return end

    local local_folder = self:getSetting("download_folder", "")
    if type(local_folder) ~= "string" or local_folder == "" then return end
    local trimmed = local_folder:gsub("/+$", "")

    -- Book opened from outside the synced library — no remote mapping; no-op.
    -- Don't fall back to a full-library walk on close, that defeats the
    -- whole reason this trigger is scoped.
    if doc.file:sub(1, #trimmed + 1) ~= trimmed .. "/" then return end
    local book_rel = doc.file:sub(#trimmed + 2)
    if book_rel == "" then return end

    if not should_run_close(book_rel) then return end
    mark_close_run(book_rel)
    self:doProgressSyncForBook(book_rel)
end

-- Resume: interactive for both syncs. The user is present, so conflicts pile
-- up here as dialogs. We chain progress → book auto-sync via on_done so the
-- two dialog chains can't end up stacked on screen at the same time; book
-- sync starts only once progress sync has fully resolved its conflicts.
-- Cooldown is consumed up here so the chain counts as a single auto slot.
function WebDAVSync:onResume()
    if not should_run_auto() then return end
    mark_auto_run()
    self:doProgressSync({
        trigger = "resume",
        interactive = true,
        on_done = function() self:maybeRunBookAutoSync() end,
    })
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

function WebDAVSync:setCooldown()
    UIManager:show(SpinWidget:new{
        title_text = _("Auto sync cooldown (seconds)"),
        info_text = _("Minimum seconds between auto-triggered syncs (book close, device wake, KOReader startup). Manual syncs and closing a different book always run regardless. Set to 0 to disable the cooldown."),
        value = get_cooldown(),
        value_min = COOLDOWN_MIN,
        value_max = COOLDOWN_MAX,
        value_step = COOLDOWN_STEP,
        value_hold_step = COOLDOWN_STEP * 2,
        default_value = DEFAULT_COOLDOWN,
        ok_text = _("Set"),
        callback = function(spin)
            G_reader_settings:saveSetting("webdav_autosync_cooldown_seconds", spin.value)
        end,
    })
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
        -- Auto triggers (startup, Resume) silently no-op when offline; only
        -- manual entry points pop the Wi-Fi prompt.
        if is_auto then return end
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

    local two_way = G_reader_settings and G_reader_settings:isTrue("webdav_autosync_books_two_way")
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

    if #conflicts == 0 then
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

--- Interactive book auto-sync trigger. Called from init() (startup) and as
--- the on_done callback chained from onResume's progress sync; both contexts
--- have the user present, so conflicts surface as dialogs via the existing
--- runTwoWaySync path. No `interactive` parameter is needed — runTwoWaySync
--- always pops the conflict dialog chain (the `is_auto` silent-skip branch
--- was removed when the chain was wired up). The unified auto-trigger
--- cooldown is enforced by the event handler before this is called, so we
--- don't re-check here. File-manager-only — a full library scan inside a
--- reader context would be disruptive.
function WebDAVSync:maybeRunBookAutoSync()
    if not (G_reader_settings and G_reader_settings:isTrue("webdav_autosync_books_auto")) then
        return
    end
    if self.ui.document then return end

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isOnline and not NetworkMgr:isOnline() then return end

    self:doSync({ is_auto = true })
end

--- Auto-sync `.sdr` sidecars (reading position, bookmarks, highlights).
--- opts.manual = true:           manual entry (menu / Dispatcher action). Bypass
---                                debounce, prompt for Wi-Fi, show summary.
--- opts.interactive = true:      surface conflicts as dialogs at the end.
--- Otherwise (close, suspend):   silent — execute non-conflicting actions only,
---                                leave conflicts pending for the next
---                                interactive trigger.
--- opts.on_done: optional callback invoked once the runner is done with this
---   trigger (every exit path: gated, no-op, completed, conflicts resolved).
---   Used by onResume to chain progress sync → book auto-sync without their
---   dialog chains overlapping in the UI stack.
function WebDAVSync:doProgressSync(opts)
    opts = opts or {}
    local manual = opts.manual == true
    -- `manual` already implies interactive — the explicit `or` keeps callers
    -- like `{ manual = true }` from having to set both.
    local interactive = manual or opts.interactive == true
    local on_done = opts.on_done
    local function done() if on_done then on_done() end end

    if not manual and not (G_reader_settings and G_reader_settings:isTrue("webdav_autosync_progress_auto")) then
        return done()
    end

    -- Cheap config check first: skip remaining work entirely (incl. the
    -- network probe below) on installs that aren't configured yet.
    local server_url = self:getSetting("server_url", "")
    local local_folder = self:getSetting("download_folder", "")
    if type(server_url) ~= "string" then server_url = "" end
    if type(local_folder) ~= "string" then local_folder = "" end
    server_url = server_url:gsub("^%s+", ""):gsub("%s+$", "")
    if server_url == "" or local_folder == "" then
        if manual then
            UIManager:show(InfoMessage:new{
                text = _("WebDAV server or download folder is not configured."),
            })
        end
        return done()
    end

    -- Sidecars must live next to books for the relpath mapping to work; in
    -- the `dir` and `hash` modes they're outside the synced library tree.
    -- Lua precedence here: `(G_reader_settings and readSetting(...)) or "doc"`.
    local meta_mode = G_reader_settings and G_reader_settings:readSetting("document_metadata_folder") or "doc"
    if meta_mode ~= "doc" then
        if manual then
            UIManager:show(InfoMessage:new{
                text = _("Reading-progress sync only works when KOReader's document-metadata folder is set to 'Book folder'."),
            })
        else
            logger.dbg("webdav_autosync: progress sync skipped — metadata folder is " .. tostring(meta_mode))
        end
        return done()
    end

    -- The unified auto-trigger cooldown is enforced by the event handlers
    -- (onResume, onCloseDocument, init startup) before they call us. A
    -- chained on_done call also lands here without re-checking, by design.
    -- Manual entry points bumped the cooldown timestamp at their own start.
    local NetworkMgr = require("ui/network/manager")
    if not manual then
        if NetworkMgr.isOnline and not NetworkMgr:isOnline() then return done() end
        self:runProgressSync({
            server_url = server_url,
            local_folder = local_folder,
            interactive = interactive,
            manual = false,
            on_done = on_done,
        })
        return
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

    self:runProgressSync({
        server_url = server_url,
        local_folder = local_folder,
        interactive = true,
        manual = true,
        on_done = on_done,
    })
end

--- Silent scoped progress sync for one just-closed book. Called from
--- onCloseDocument after the per-book debounce passes. One PROPFIND on
--- `<book>.sdr/`, executes non-conflicting actions, leaves any conflicts
--- pending (they'll surface at the next interactive trigger). Same gates
--- as doProgressSync: the toggle, the `doc` metadata-folder requirement,
--- server/folder configured, online.
function WebDAVSync:doProgressSyncForBook(book_rel)
    if not (G_reader_settings and G_reader_settings:isTrue("webdav_autosync_progress_auto")) then
        return
    end

    local meta_mode = G_reader_settings and G_reader_settings:readSetting("document_metadata_folder") or "doc"
    if meta_mode ~= "doc" then
        logger.dbg("webdav_autosync: close-trigger sync skipped — metadata folder is " .. tostring(meta_mode))
        return
    end

    local server_url = self:getSetting("server_url", "")
    local local_folder = self:getSetting("download_folder", "")
    if type(server_url) ~= "string" then server_url = "" end
    if type(local_folder) ~= "string" then local_folder = "" end
    server_url = server_url:gsub("^%s+", ""):gsub("%s+$", "")
    if server_url == "" or local_folder == "" then return end

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isOnline and not NetworkMgr:isOnline() then return end

    local username = self:getSetting("username", "")
    local password = self:getSetting("password", "")
    local plan_obj, err = sync.plan_progress_book(server_url, username, password, local_folder, book_rel)
    if not plan_obj then
        logger.dbg("webdav_autosync: book progress plan failed: " .. tostring(err))
        return
    end

    for _, a in ipairs(plan_obj.actions.to_download) do
        sync.do_action(plan_obj, "download", a)
    end
    for _, a in ipairs(plan_obj.actions.to_upload) do
        sync.do_action(plan_obj, "upload", a)
    end
    sync.save_cache(plan_obj)
end

function WebDAVSync:runProgressSync(opts)
    local server_url = opts.server_url
    local local_folder = opts.local_folder
    local interactive = opts.interactive
    local manual = opts.manual
    local on_done = opts.on_done
    local function done() if on_done then on_done() end end

    local username = self:getSetting("username", "")
    local password = self:getSetting("password", "")

    local syncing_msg
    if manual then
        syncing_msg = InfoMessage:new{ text = _("Syncing reading progress…") }
        UIManager:show(syncing_msg)
        UIManager:forceRePaint()
    end

    local plan_obj, err = sync.plan_progress(server_url, username, password, local_folder)
    if not plan_obj then
        if syncing_msg then UIManager:close(syncing_msg) end
        if manual then
            UIManager:show(InfoMessage:new{
                text = T(_("Progress sync failed: %1"), tostring(err)),
            })
        else
            logger.dbg("webdav_autosync: progress plan failed: " .. tostring(err))
        end
        return done()
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

    if syncing_msg then UIManager:close(syncing_msg) end

    local conflicts = plan_obj.actions.conflicts
    local function finish()
        sync.save_cache(plan_obj)
        if manual then self:showProgressSummary(stats) end
        done()
    end

    -- Silent triggers leave conflicts pending: cache rows for conflicting
    -- entries are not updated, so the next interactive planner pass re-detects
    -- them and surfaces the dialog.
    if not interactive or #conflicts == 0 then
        finish()
        return
    end

    self:resolveConflictsInteractive(plan_obj, conflicts, stats, finish)
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

• Auto-sync books
  Run book sync automatically at KOReader startup and after the device wakes from sleep. File-manager context only, debounced to once per 60 seconds.

• Two-way book sync (upload local changes)
  Affects book sync only. Off: download-only. On: also upload local additions and changes, and prompt on conflicts.

• Auto-sync reading progress
  Run progress sync automatically on book close (silent, just the closed book), device wake (interactive, full reconcile), and KOReader startup (interactive, full reconcile). Conflicts on close are held for the next interactive trigger.

• Auto sync cooldown
  Minimum seconds between auto-triggered syncs (book close, device wake, KOReader startup). Manual syncs and closing a *different* book always run regardless of the cooldown. Default 120 s. Set to 0 to disable the cooldown.

HOW TO SET IT UP

1. Open "WebDAV server" and enter the URL plus optional credentials. Or tap "Import from KOReader cloud storage" to copy them from a server you already have configured.
2. Tap "Choose download folder" and long-press the folder where you want books stored.
3. (Optional) Tap "Set file extensions" if you only want certain formats.
4. Tap "Sync books now" to do an initial download.
5. Toggle "Auto-sync books" on if you want startup/wake auto-runs.
6. Toggle "Two-way book sync" on if you also want local additions to upload.
7. Toggle "Auto-sync reading progress" on if you want reading state to round-trip across devices.

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

function WebDAVSync:showProgressSummary(stats)
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
    local text = _("Reading progress synced.") .. " " .. table.concat(parts, " ")
    if stats.failed > 0 and #stats.failures > 0 then
        text = text .. "\n\n" .. table.concat(stats.failures, "\n")
    end
    UIManager:show(InfoMessage:new{ text = text })
end

return WebDAVSync
