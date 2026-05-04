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
local Event = require("ui/event")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")
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
-- Set true the first time init() schedules its startup sync this KOReader
-- process. Each FileManager↔ReaderUI transition re-instantiates the plugin
-- and re-runs init(); without this guard, opening a book or closing it back
-- to the file manager would re-fire a full-library progress sync (and the
-- chained book sync on the close-into-FM transition) every time the cooldown
-- window had already elapsed.
local startup_sync_scheduled = false
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

-- Master gate: when off, no auto trigger (startup, Resume, close) does
-- anything. Manual entry points (menu items, Dispatcher actions) bypass.
local function is_master_on()
    return G_reader_settings and G_reader_settings:isTrue("webdav_autosync_master")
end

-- Per-event toggle, gated by the master. The master being off forces every
-- event toggle to read as off — handlers don't need to check both. Manual
-- runs do not pass through here.
local function event_enabled(event_key)
    if not is_master_on() then return false end
    return G_reader_settings:isTrue("webdav_autosync_" .. event_key)
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
    local ui_kind = (self.ui and self.ui.document) and "reader" or "filemanager"
    logger.dbg("webdav_autosync: init ui=" .. ui_kind)
    -- Startup is an interactive trigger: surface deferred conflicts via
    -- dialog. Per-event toggles gate the call site (no need to invoke a
    -- runner whose toggle is off); the runners still bail on no-config /
    -- offline / wrong metadata-folder mode internally. Chained via on_done
    -- — progress first, then book — so the conflict dialog chains never
    -- overlap on screen. Cooldown is consumed up here so the chain counts
    -- as a single auto-trigger slot.
    --
    -- Only schedule once per KOReader process — see the comment on
    -- startup_sync_scheduled above. Subsequent init() calls (from the
    -- FM↔Reader transition's fresh plugin instance) skip this block.
    if startup_sync_scheduled then
        logger.dbg("webdav_autosync: init skip startup-sync (already scheduled this process) ui=" .. ui_kind)
        return
    end
    startup_sync_scheduled = true
    logger.dbg("webdav_autosync: init scheduling startup sync in 2s ui=" .. ui_kind)
    UIManager:scheduleIn(2, function()
        local progress_on = event_enabled("progress_on_startup")
        local books_on = event_enabled("books_on_startup")
        if not progress_on and not books_on then
            logger.dbg("webdav_autosync: trigger=startup skip reason=disabled")
            return
        end
        if not should_run_auto() then
            logger.dbg("webdav_autosync: trigger=startup skip reason=cooldown")
            return
        end
        mark_auto_run()
        logger.info(string.format(
            "webdav_autosync: trigger=startup progress=%s books=%s",
            tostring(progress_on), tostring(books_on)))
        if progress_on then
            self:doProgressSync({
                trigger = "startup",
                on_done = function()
                    if books_on then self:maybeRunBookAutoSync() end
                end,
            })
        else
            self:maybeRunBookAutoSync()
        end
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
                            return T(_("Auto sync cooldown: %1 s"), tostring(get_cooldown()))
                        end,
                        enabled_func = function()
                            return G_reader_settings:isTrue("webdav_autosync_master")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:setCooldown()
                        end,
                        help_text = _("Minimum seconds between auto-triggered syncs (book close, device wake, KOReader startup). Manual syncs and closing a different book always run regardless. 0 disables the cooldown. Default 120 s."),
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
    mark_auto_run()
    logger.info("webdav_autosync: trigger=manual_books")
    self:doSync()
    return true
end

function WebDAVSync:onWebDAVProgressSyncNow()
    mark_auto_run()
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
    if not event_enabled("progress_on_close") then
        logger.dbg("webdav_autosync: trigger=close skip reason=disabled")
        return
    end
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then
        logger.dbg("webdav_autosync: trigger=close skip reason=no-document")
        return
    end

    local local_folder = self:getSetting("download_folder", "")
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

    if not should_run_close(book_rel) then
        logger.dbg("webdav_autosync: trigger=close skip reason=debounce book=" .. book_rel)
        return
    end
    mark_close_run(book_rel)
    logger.info("webdav_autosync: trigger=close book=" .. book_rel)
    self:doProgressSyncForBook(book_rel)
end

-- Resume: interactive for both syncs. The user is present, so conflicts pile
-- up here as dialogs. We chain progress → book auto-sync via on_done so the
-- two dialog chains can't end up stacked on screen at the same time; book
-- sync starts only once progress sync has fully resolved its conflicts.
-- Cooldown is consumed up here so the chain counts as a single auto slot.
function WebDAVSync:onResume()
    local progress_on = event_enabled("progress_on_resume")
    local books_on = event_enabled("books_on_resume")
    if not progress_on and not books_on then
        logger.dbg("webdav_autosync: trigger=resume skip reason=disabled")
        return
    end
    if not should_run_auto() then
        logger.dbg("webdav_autosync: trigger=resume skip reason=cooldown")
        return
    end
    mark_auto_run()
    logger.info(string.format(
        "webdav_autosync: trigger=resume progress=%s books=%s",
        tostring(progress_on), tostring(books_on)))
    if progress_on then
        self:doProgressSync({
            trigger = "resume",
            on_done = function()
                if books_on then self:maybeRunBookAutoSync() end
            end,
        })
    else
        self:maybeRunBookAutoSync()
    end
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
        if is_auto then
            logger.dbg("webdav_autosync: book sync skip reason=offline (auto)")
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
        logger.info("webdav_autosync: book sync start mode=two_way is_auto=" .. tostring(is_auto == true))
        self:runTwoWaySync(ctx)
    else
        logger.info("webdav_autosync: book sync start mode=one_way is_auto=" .. tostring(is_auto == true))
        self:runOneWaySync(ctx)
    end
end

function WebDAVSync:runOneWaySync(ctx)
    local syncing_msg = InfoMessage:new{ text = _("Syncing…") }
    UIManager:show(syncing_msg)
    UIManager:forceRePaint()
    local downloaded, skipped, failed, err, downloaded_rels = sync.run_sync(
            ctx.server_url, ctx.username, ctx.password,
            ctx.folder, nil, ctx.file_extensions)
    UIManager:close(syncing_msg)
    logger.info(string.format(
        "webdav_autosync: book sync done mode=one_way downloaded=%d skipped=%d failed=%d",
        downloaded, skipped, failed))
    -- Always show whatever counts we have, even on partial failure: a
    -- run that downloaded 4 files and failed on 1 should still report
    -- "4 downloaded" alongside the failure summary.
    local parts = {}
    table.insert(parts, T(_("Downloaded %1 file(s)."), tostring(downloaded)))
    if skipped > 0 then
        table.insert(parts, T(_("%1 skipped (already exists)."), tostring(skipped)))
    end
    if failed > 0 then
        table.insert(parts, T(_("%1 failed."), tostring(failed)))
    end
    local text = _("Sync done.") .. " " .. table.concat(parts, " ")
    if err then text = text .. "\n\n" .. tostring(err) end
    UIManager:show(InfoMessage:new{ text = text })
    -- Files that did get written still trigger a refresh, even when err is set.
    self:notifyLibraryRefresh(ctx.folder, downloaded_rels)
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
        logger.warn("webdav_autosync: book sync plan failed: " .. tostring(err))
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
        downloaded_rels = {},
    }

    for _, a in ipairs(plan_obj.actions.to_download) do
        local ok, msg = sync.do_action(plan_obj, "download", a)
        if ok then
            stats.downloaded = stats.downloaded + 1
            table.insert(stats.downloaded_rels, a.rel)
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
        self:notifyLibraryRefresh(plan_obj.local_folder, stats.downloaded_rels)
        logger.info(string.format(
            "webdav_autosync: book sync done mode=two_way downloaded=%d uploaded=%d unchanged=%d baselined=%d conflicts_skipped=%d failed=%d",
            stats.downloaded, stats.uploaded, stats.unchanged, stats.baselined,
            stats.conflicts_skipped, stats.failed))
        self:showTwoWaySummary(stats)
        self:turnOffWifiIfRequested(ctx)
    end

    if #conflicts == 0 then
        finish()
        return
    end

    logger.info("webdav_autosync: book sync surfacing conflicts count=" .. tostring(#conflicts))
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
            logger.dbg("webdav_autosync: conflict resolution rel=" .. c.rel .. " choice=" .. action)
            if action == "skip" then
                stats.conflicts_skipped = stats.conflicts_skipped + 1
                next_one()
                return
            end
            local ok, msg = sync.do_action(plan_obj, action, c)
            if ok then
                if action == "download" then
                    stats.downloaded = stats.downloaded + 1
                    if stats.downloaded_rels then
                        table.insert(stats.downloaded_rels, c.rel)
                    end
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

--- Tell KOReader's file-browser / history / collections views to redraw after
--- we replaced sidecar contents (or downloaded a new/changed book file) on
--- disk. Without this the file manager keeps showing stale state — e.g. the
--- old percent-finished / "reading" badge from before a progress sync pulled
--- in newer reading state from another device.
---
--- Two events, in order:
---   1. `InvalidateMetadataCache` per affected book — drops the SQLite-cached
---      metadata row used by `coverbrowser.koplugin` so cover mosaic / list
---      modes re-extract on next render.
---   2. `BookMetadataChanged` (no arg) — handled by `FileManager` (re-walks the
---      current dir and re-reads sidecars), `FileManagerHistory`, `Collection`,
---      and `FileSearcher`. Reader-side handlers (`ReaderCoptListener`,
---      `ReaderFooter`) gate on `prop_updated`, so passing nil makes them no-op
---      — safe to broadcast even with a book open.
---
--- `downloaded_rels` mixes sidecar relpaths (`Books/Foo.sdr/metadata.epub.lua`)
--- and book-file relpaths (`Books/Foo.epub`). Sidecar paths get mapped back to
--- their book file via `<stem>.<ext>`; book paths are used as-is. Sidecar
--- entries other than `metadata.<ext>.lua` (cover, custom_metadata) don't
--- carry the book extension on their own — they fall through to just the
--- global `BookMetadataChanged` and let the file manager re-walk.
function WebDAVSync:notifyLibraryRefresh(local_folder, downloaded_rels)
    if not downloaded_rels or #downloaded_rels == 0 then return end
    if type(local_folder) ~= "string" or local_folder == "" then return end
    local trimmed = local_folder:gsub("/+$", "")

    local seen = {}
    for _, rel in ipairs(downloaded_rels) do
        local book_path
        local stem, ext = rel:match("^(.+)%.sdr/metadata%.([^.]+)%.lua$")
        if stem and ext then
            book_path = trimmed .. "/" .. stem .. "." .. ext
        elseif not rel:match("%.sdr/") then
            book_path = trimmed .. "/" .. rel
        end
        if book_path and not seen[book_path] then
            seen[book_path] = true
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", book_path))
        end
    end

    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    logger.dbg(string.format("webdav_autosync: notifyLibraryRefresh affected_books=%d total_rels=%d",
            n, #downloaded_rels))
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
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
--- cooldown and per-event toggles are enforced by the event handler before
--- this is called, so we don't re-check them here. File-manager-only — a
--- full library scan inside a reader context would be disruptive.
function WebDAVSync:maybeRunBookAutoSync()
    if self.ui.document then
        logger.dbg("webdav_autosync: book auto-sync skip reason=reader-context")
        return
    end

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        logger.dbg("webdav_autosync: book auto-sync skip reason=offline")
        return
    end

    self:doSync({ is_auto = true })
end

--- Full-library progress (`.sdr` sidecar) sync. Always interactive in the
--- UI sense: shows a syncing message, surfaces failures, runs the conflict
--- dialog chain, and shows a summary. The silent close trigger goes through
--- doProgressSyncForBook instead.
--- opts.manual = true:        manual entry (menu / Dispatcher action). Prompts
---                            to enable Wi-Fi if needed; auto triggers
---                            (init, Resume) silently no-op when offline.
--- opts.on_done:              optional callback invoked once the runner is done
---                            with this trigger (every exit path: gated, no-op,
---                            completed, conflicts resolved). Used by onResume
---                            to chain progress sync → book auto-sync without
---                            their dialog chains overlapping in the UI stack.
function WebDAVSync:doProgressSync(opts)
    opts = opts or {}
    local manual = opts.manual == true
    local on_done = opts.on_done
    local function done() if on_done then on_done() end end

    -- The per-event toggle gating happens in the event handlers (init,
    -- onResume) before they call us; manual entry points bypass the toggles
    -- entirely. So no toggle check here.

    -- Cheap config check first: skip remaining work entirely (incl. the
    -- network probe below) on installs that aren't configured yet.
    local server_url = self:getSetting("server_url", "")
    local local_folder = self:getSetting("download_folder", "")
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

    -- Sidecars must live next to books for the relpath mapping to work; in
    -- the `dir` and `hash` modes they're outside the synced library tree.
    -- Lua precedence here: `(G_reader_settings and readSetting(...)) or "doc"`.
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

    -- The unified auto-trigger cooldown is enforced by the event handlers
    -- (onResume, onCloseDocument, init startup) before they call us. A
    -- chained on_done call also lands here without re-checking, by design.
    -- Manual entry points bumped the cooldown timestamp at their own start.
    local NetworkMgr = require("ui/network/manager")
    if not manual then
        if NetworkMgr.isOnline and not NetworkMgr:isOnline() then
            logger.dbg("webdav_autosync: progress sync skip reason=offline (auto)")
            return done()
        end
        self:runProgressSync({
            server_url = server_url,
            local_folder = local_folder,
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
    -- Gating (master + progress_on_close) is enforced by onCloseDocument
    -- before this runs; we don't re-check here.

    local meta_mode = G_reader_settings and G_reader_settings:readSetting("document_metadata_folder") or "doc"
    if meta_mode ~= "doc" then
        logger.dbg("webdav_autosync: close-trigger sync skip reason=metadata-folder-mode mode=" .. tostring(meta_mode))
        return
    end

    local server_url = self:getSetting("server_url", "")
    local local_folder = self:getSetting("download_folder", "")
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

    local username = self:getSetting("username", "")
    local password = self:getSetting("password", "")
    logger.info("webdav_autosync: close-trigger sync start book=" .. tostring(book_rel))
    local plan_obj, err = sync.plan_progress_book(server_url, username, password, local_folder, book_rel)
    if not plan_obj then
        logger.warn("webdav_autosync: close-trigger plan failed book=" .. tostring(book_rel) .. " err=" .. tostring(err))
        return
    end

    local downloaded, uploaded, failed = 0, 0, 0
    local downloaded_rels = {}
    for _, a in ipairs(plan_obj.actions.to_download) do
        local ok, msg = sync.do_action(plan_obj, "download", a)
        if ok then
            downloaded = downloaded + 1
            table.insert(downloaded_rels, a.rel)
        else
            failed = failed + 1
            logger.warn("webdav_autosync: close-trigger download failed rel=" .. a.rel .. " err=" .. tostring(msg))
        end
    end
    for _, a in ipairs(plan_obj.actions.to_upload) do
        local ok, msg = sync.do_action(plan_obj, "upload", a)
        if ok then
            uploaded = uploaded + 1
        else
            failed = failed + 1
            logger.warn("webdav_autosync: close-trigger upload failed rel=" .. a.rel .. " err=" .. tostring(msg))
        end
    end
    sync.save_cache(plan_obj)
    self:notifyLibraryRefresh(plan_obj.local_folder, downloaded_rels)
    logger.info(string.format(
        "webdav_autosync: close-trigger sync done book=%s downloaded=%d uploaded=%d unchanged=%d baselined=%d conflicts=%d failed=%d",
        tostring(book_rel), downloaded, uploaded,
        plan_obj.actions.skipped_unchanged, plan_obj.actions.baselined,
        #plan_obj.actions.conflicts, failed))
end

--- Run a full-library progress sync. Always interactive: shows the
--- syncing InfoMessage, surfaces plan errors, runs the conflict dialog
--- chain, and shows a summary at the end. Silent close-trigger syncs go
--- through doProgressSyncForBook instead, so this path never needs a
--- "silent" mode. All current entry points (init, onResume, manual menu,
--- WebDAVProgressSyncNow Dispatcher action) reach here interactively.
function WebDAVSync:runProgressSync(opts)
    local server_url = opts.server_url
    local local_folder = opts.local_folder
    local on_done = opts.on_done
    local function done() if on_done then on_done() end end

    local username = self:getSetting("username", "")
    local password = self:getSetting("password", "")

    local syncing_msg = InfoMessage:new{ text = _("Syncing reading progress…") }
    UIManager:show(syncing_msg)
    UIManager:forceRePaint()

    logger.info("webdav_autosync: progress sync start")
    local plan_obj, err = sync.plan_progress(server_url, username, password, local_folder)
    if not plan_obj then
        UIManager:close(syncing_msg)
        logger.warn("webdav_autosync: progress plan failed: " .. tostring(err))
        UIManager:show(InfoMessage:new{
            text = T(_("Progress sync failed: %1"), tostring(err)),
        })
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
        -- resolveConflictsInteractive appends conflict-resolved downloads here
        -- when present; we feed the whole list to notifyLibraryRefresh.
        downloaded_rels = {},
    }

    for _, a in ipairs(plan_obj.actions.to_download) do
        local ok, msg = sync.do_action(plan_obj, "download", a)
        if ok then
            stats.downloaded = stats.downloaded + 1
            table.insert(stats.downloaded_rels, a.rel)
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
        self:notifyLibraryRefresh(plan_obj.local_folder, stats.downloaded_rels)
        logger.info(string.format(
            "webdav_autosync: progress sync done downloaded=%d uploaded=%d unchanged=%d baselined=%d conflicts_skipped=%d failed=%d",
            stats.downloaded, stats.uploaded, stats.unchanged, stats.baselined,
            stats.conflicts_skipped, stats.failed))
        self:showProgressSummary(stats)
        done()
    end

    if #conflicts == 0 then
        finish()
        return
    end

    logger.info("webdav_autosync: progress sync surfacing conflicts count=" .. tostring(#conflicts))
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

• Two-way book sync (upload local changes)
  Affects book sync only. Off: download-only. On: also upload local additions and changes, and prompt on conflicts.

• Auto sync triggers (submenu)
  - Enable auto sync — master switch. Off: nothing fires automatically (manual sync still works). On: each individual trigger toggle below takes effect.
  - Sync books on startup / on wake — when on, run book sync at KOReader startup and/or when the device wakes. File-manager context only.
  - Sync reading progress on startup / on wake / on book close — when on, run progress sync at startup, on wake, and/or after closing a book. The startup and wake triggers reconcile the whole library; the book-close trigger pushes only the just-closed book (one network request) and silently defers any conflict to the next startup/wake.
  - Auto sync cooldown — minimum seconds between auto-triggered syncs. Manual syncs and closing a *different* book always run regardless. Default 120 s. Set to 0 to disable.

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
