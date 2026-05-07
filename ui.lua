--[[--
Settings dialogs and help text for the WebDAV Auto Sync plugin.

Pure UI layer. Each export is a one-shot dialog opener — no state, no
callbacks back into the plugin past the initial trigger. The settings
they write go through `settings.save` (or `G_reader_settings` directly
for the SpinWidget callbacks, since those write a known bare-bounded
numeric and don't need the prefix indirection).

The `plugin` argument is the WebDAVSync instance — needed only for the
two cases where a dialog re-enters another dialog (Wi-Fi prompt → setter,
Cloud import → applyCloudStorageEntry).
--]]--

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local SpinWidget = require("ui/widget/spinwidget")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local settings = require("settings")
local triggers = require("triggers")
local webdav = require("webdav")
local T = require("ffi/util").template
local _ = require("gettext")

-- ---------- WebDAV server ----------

local function set_webdav_server(_plugin)
    local text_info = _("Server address must be of the form http(s)://domain.name/path\n(e.g. https://example.com/webdav).\nUsername and password are optional.")
    local addr = settings.get("server_url", "") or ""
    local user = settings.get("username", "") or ""
    local pass = settings.get("password", "") or ""
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

-- ---------- cloud-storage import ----------

local function apply_cloud_storage_entry(_plugin, server)
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

local function import_from_cloud_storage(plugin)
    local handler = function(server)
        if not server then return end
        if server.type ~= "webdav" then
            UIManager:show(InfoMessage:new{
                text = _("Please pick a WebDAV server (other server types are not supported)."),
            })
            return
        end
        apply_cloud_storage_entry(plugin, server)
    end
    local cs = plugin.ui.cloudstorage
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

-- ---------- download folder ----------

local function set_download_folder(_plugin)
    local current = settings.get("download_folder", "")
    if type(current) ~= "string" then current = nil end
    if current == "" then current = nil end
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

-- ---------- spin widgets (cooldowns, settle delay) ----------

local function make_spin_setting(spec)
    local current = spec.get_current()
    UIManager:show(SpinWidget:new{
        title_text = spec.title,
        info_text = spec.info,
        value = current,
        value_min = spec.min,
        value_max = spec.max,
        value_step = spec.step,
        value_hold_step = spec.hold_step or (spec.step * 2),
        default_value = spec.default,
        ok_text = _("Set"),
        callback = function(spin)
            G_reader_settings:saveSetting(spec.setting_key, spin.value)
            if spec.on_set then spec.on_set(spin.value) end
        end,
    })
end

local function set_cooldown()
    make_spin_setting({
        title = _("Auto sync cooldown (seconds)"),
        info = _("Minimum seconds between auto-triggered full reconciles (device wake, KOReader startup). Manual syncs always run regardless. The book-close trigger has its own cooldown. Set to 0 to disable."),
        get_current = settings.get_cooldown,
        setting_key = "webdav_autosync_cooldown_seconds",
        min = settings.COOLDOWN_MIN,
        max = settings.COOLDOWN_MAX,
        step = settings.COOLDOWN_STEP,
        hold_step = settings.COOLDOWN_STEP * 2,
        default = settings.DEFAULT_COOLDOWN,
    })
end

local function set_close_cooldown()
    make_spin_setting({
        title = _("Close-trigger cooldown (seconds)"),
        info = _("Minimum seconds between two consecutive close-trigger syncs of the same book. Closing a different book always runs regardless. Set to 0 to disable."),
        get_current = settings.get_close_cooldown,
        setting_key = "webdav_autosync_close_cooldown_seconds",
        min = settings.CLOSE_COOLDOWN_MIN,
        max = settings.CLOSE_COOLDOWN_MAX,
        step = settings.CLOSE_COOLDOWN_STEP,
        hold_step = settings.CLOSE_COOLDOWN_STEP * 3,
        default = settings.DEFAULT_CLOSE_COOLDOWN,
    })
end

local function set_resume_settle()
    make_spin_setting({
        title = _("Wake settle delay (seconds)"),
        info = _("How long to wait after the device wakes before starting an auto-sync. Filters brief system wakes (RTC alarms, hall-sensor twitches, framework background tasks) that don't represent the user actually picking up the device. 0 disables the gate (sync runs immediately on wake)."),
        get_current = settings.get_resume_settle,
        setting_key = "webdav_autosync_resume_settle_seconds",
        min = settings.RESUME_SETTLE_MIN,
        max = settings.RESUME_SETTLE_MAX,
        step = settings.RESUME_SETTLE_STEP,
        hold_step = settings.RESUME_SETTLE_STEP * 2,
        default = settings.DEFAULT_RESUME_SETTLE,
        on_set = function(new_value)
            triggers.on_resume_settle_changed(new_value)
        end,
    })
end

-- ---------- file extensions ----------

local function set_file_extensions(_plugin)
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
                    callback = function() UIManager:close(dref[1]) end,
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
    if dref[1].onShowKeyboard then dref[1]:onShowKeyboard() end
end

-- ---------- help ----------

local HELP_TEXT = _([[
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
  - Sync reading progress on startup / on wake / on book close — when on, run progress sync at startup, on wake, and/or after closing a book. The startup and wake triggers reconcile the whole library; the book-close trigger pushes only the just-closed book (one network request). All three surface conflicts via the per-file dialog as soon as they're detected.
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

local function show_help()
    UIManager:show(TextViewer:new{
        title = _("WebDAV Sync — help"),
        text = HELP_TEXT,
    })
end

return {
    set_webdav_server = set_webdav_server,
    import_from_cloud_storage = import_from_cloud_storage,
    apply_cloud_storage_entry = apply_cloud_storage_entry,
    set_download_folder = set_download_folder,
    set_cooldown = set_cooldown,
    set_close_cooldown = set_close_cooldown,
    set_resume_settle = set_resume_settle,
    set_file_extensions = set_file_extensions,
    show_help = show_help,
}
