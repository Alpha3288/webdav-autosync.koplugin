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

-- Two independent cooldowns:
--   * full-reconcile  — gated by `webdav_autosync_last_auto_run_at` +
--     `get_cooldown()`. Covers Resume, startup, and the chained book
--     auto-sync. Default 300 s.
--   * close-trigger   — gated by `webdav_autosync_last_close_run_at` +
--     `get_close_cooldown()`. Covers the scoped close trigger (one
--     PROPFIND on the just-closed book's `.sdr/`). Default 30 s.
--
-- The two timestamps are independent: a close-triggered sync does NOT push
-- back the next full reconcile, and a Resume/startup sync does NOT push back
-- the next close trigger. That keeps each path's debounce limited to its own
-- redundancy case (same book closed twice in quick succession; multiple
-- wakes in quick succession) without one suppressing the other.
--
-- Both timestamps (and the close-trigger's `last_close_book_rel` carve-out)
-- live in the plugin's state file `<settings_dir>/webdav_autosync_state.lua`
-- under their own keys, alongside the per-file `files` table the planners
-- use. Pre-v1.7.3 they were module-local Lua values that defaulted to 0 on
-- every process start, which made the *startup* trigger always pass
-- `should_run_auto()` regardless of how recently the previous KOReader
-- session had synced — exactly the "two startups in quick succession" case
-- the cooldown is supposed to catch. The same was true for the close
-- timestamp and `last_close_book_rel` (close-then-restart-then-close-of-
-- same-book bypassed the carve-out). Persisting fixes all three.
--
-- Why the state file and not `G_reader_settings`: these are sync-state
-- runtime values, not user configuration. Wiping the state file (e.g. to
-- force a fresh baseline) should reset the cooldowns too — that's what
-- happens automatically when they live alongside the per-file cache rows.
-- The cost is one extra explicit flush per `mark_*_run` (G_reader_settings
-- piggybacks on KOReader's lifecycle flush); we accept that for tighter
-- crash-recovery (timestamps are durable as soon as a sync runs).
--
-- last_close_book_rel carves out the per-book exception for the close
-- trigger: closing a *different* book hits a different `.sdr/`, so it's not
-- redundant with the prior sync and is allowed regardless of the close
-- cooldown. Closing the *same* book within the cooldown is the redundant
-- case we skip.
--
-- Set true the first time init() schedules its startup sync this KOReader
-- process. Each FileManager↔ReaderUI transition re-instantiates the plugin
-- and re-runs init(); without this guard, opening a book or closing it back
-- to the file manager would re-fire a full-library progress sync (and the
-- chained book sync on the close-into-FM transition) every time the
-- in-process scheduling slot was free. Distinct from the cooldown — the
-- cooldown is the cross-trigger throttle (whether ANY sync ran recently),
-- this boolean is "did the startup-specific scheduleIn fire already in
-- THIS process". Module-local because we want to fire startup at most once
-- per process even if the persistent cooldown would otherwise admit it
-- (e.g. user toggled cooldown to 0).
local startup_sync_scheduled = false
local DEFAULT_COOLDOWN = 300
local COOLDOWN_MIN = 0
local COOLDOWN_MAX = 1800
local COOLDOWN_STEP = 30
local DEFAULT_CLOSE_COOLDOWN = 30
local CLOSE_COOLDOWN_MIN = 0
local CLOSE_COOLDOWN_MAX = 600
local CLOSE_COOLDOWN_STEP = 10
-- Resume settle delay setting bounds. Default 15 s matches KOReader's
-- KindlePowerD:checkUnexpectedWakeup window (the canonical "this was an
-- unscheduled wake" classifier reads powerd state 15 s after wakeup).
-- 0 disables the gate entirely — sync runs inline on Resume, which is
-- the pre-1.7.8 behavior. Max kept modest because longer delays just
-- annoy the user without catching meaningfully more unscheduled wakes.
local DEFAULT_RESUME_SETTLE = 15
local RESUME_SETTLE_MIN = 0
local RESUME_SETTLE_MAX = 60
local RESUME_SETTLE_STEP = 5

local function get_cooldown()
    local v = G_reader_settings and G_reader_settings:readSetting("webdav_autosync_cooldown_seconds")
    if type(v) ~= "number" then return DEFAULT_COOLDOWN end
    if v < COOLDOWN_MIN then return COOLDOWN_MIN end
    if v > COOLDOWN_MAX then return COOLDOWN_MAX end
    return v
end

local function get_close_cooldown()
    local v = G_reader_settings and G_reader_settings:readSetting("webdav_autosync_close_cooldown_seconds")
    if type(v) ~= "number" then return DEFAULT_CLOSE_COOLDOWN end
    if v < CLOSE_COOLDOWN_MIN then return CLOSE_COOLDOWN_MIN end
    if v > CLOSE_COOLDOWN_MAX then return CLOSE_COOLDOWN_MAX end
    return v
end

local function get_resume_settle()
    local v = G_reader_settings and G_reader_settings:readSetting("webdav_autosync_resume_settle_seconds")
    if type(v) ~= "number" then return DEFAULT_RESUME_SETTLE end
    if v < RESUME_SETTLE_MIN then return RESUME_SETTLE_MIN end
    if v > RESUME_SETTLE_MAX then return RESUME_SETTLE_MAX end
    return v
end

local function read_timestamp(key)
    local v = sync.read_state(key)
    return (type(v) == "number") and v or 0
end

local function read_string(key)
    local v = sync.read_state(key)
    return (type(v) == "string") and v or nil
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
    return os.time() - read_timestamp("last_auto_run_at") >= cooldown
end

local function should_run_close(book_rel)
    if book_rel ~= read_string("last_close_book_rel") then return true end
    local cooldown = get_close_cooldown()
    if cooldown <= 0 then return true end
    return os.time() - read_timestamp("last_close_run_at") >= cooldown
end

local function mark_auto_run()
    sync.write_state({ last_auto_run_at = os.time() })
end

local function mark_close_run(book_rel)
    sync.write_state({
        last_close_run_at = os.time(),
        last_close_book_rel = book_rel,
    })
end

-- Wi-Fi reconnect after Suspend is async on KOReader devices that bring
-- the network up lazily (Kindle, Kobo); isOnline() (a real-time DNS
-- probe at frontend/ui/network/manager.lua:588) returns false for
-- several seconds after onResume fires. KOReader's willRerunWhenOnline
-- and runWhenOnline helpers don't fit our case: when isConnected() (the
-- cached flag) is true but isOnline() (DNS) currently fails, they call
-- beforeWifiAction *without* the callback (manager.lua@v2026.03 lines
-- 679-680, "Avoid infinite recursion, beforeWifiAction only guarantees
-- isConnected, not isOnline") — the caller is left waiting on an event
-- nobody will fire. Those helpers are also tied to the
-- wifi_enable_action state machine, which an auto trigger has no
-- business engaging — manual triggers prompt via ConfirmBox; auto
-- triggers should be invisible. Hence: poll isOnline() ourselves with
-- bounded retries. Same approach for Resume and post-init startup;
-- each retry re-runs the full handler from the top so toggle/cooldown
-- changes during the wait take effect immediately.
local AUTO_TRIGGER_NET_RETRY_INTERVAL_SECS = 5
local AUTO_TRIGGER_NET_RETRY_MAX = 6  -- ~30 s total

-- Resume settle delay. Resume on Kindle (and likely other lipc-driven
-- platforms) fires for *every* powerd-reported wake, including the brief
-- unscheduled wakes the system schedules for its own background tasks
-- (RTC alarms, hall-sensor twitches, USB/network housekeeping). Without
-- a settle delay, our sync runs in those tiny wake windows and burns
-- the cooldown for nothing.
--
-- KOReader's own classifier (frontend/device/kindle/powerd.lua:258-269,
-- `KindlePowerD:checkUnexpectedWakeup`) waits 15 s after wakeup and reads
-- `getPowerdState()`: if state is still "screenSaver" or "suspended", the
-- wake was unscheduled. We mirror that window by default (see
-- `DEFAULT_RESUME_SETTLE`); user-configurable via `setResumeSettle`.
--
-- Two complementary mechanisms gate at fire time:
--   1. Cross-platform — onSuspend cancels the pending defer before it
--      fires. On Kindle the back-to-sleep edge after a brief unscheduled
--      wake usually goes screenSaver → suspended without firing
--      `goingToScreenSaver`, so onSuspend may not fire; in that case the
--      CPU is suspended before our scheduled task can run. Either way,
--      the deferred fn does not execute while the device is asleep.
--   2. Kindle-only — at fire time, read powerd state. If it's still
--      "screenSaver" or "suspended" after the settle delay, the wake was
--      unscheduled and we explicitly skip (see is_unscheduled_kindle_wake).
--
-- Setting the delay to 0 disables both gates: onResume runs sync inline
-- (skipping the Kindle state check). That's the pre-1.7.8 behavior —
-- offered as an opt-out for users who'd rather see immediate sync UI on
-- wake at the cost of unnecessary work on brief system wakes.

-- Module-local because the plugin is instantiated twice (FileManager and
-- ReaderUI). Resume / Suspend broadcast to both instances; we want a single
-- shared pending fn so the second instance's onResume sees that one is
-- already scheduled, and either instance's onSuspend can cancel it.
local pending_resume_sync_fn = nil

-- Read Kindle's powerd state via `KindlePowerD:getPowerdState()` (a
-- thin wrapper around `lipc.get_string_property("com.lab126.powerd",
-- "state")`). Returns nil on non-Kindle, when lipc isn't available, or
-- on error. The state strings we care about are "screenSaver" and
-- "suspended" — anything else (e.g. "active", "ready") means the user
-- has actually engaged with the device.
local function read_powerd_state()
    local ok_dev, Device = pcall(require, "device")
    if not ok_dev or not Device then return nil end
    if not Device.isKindle or not Device:isKindle() then return nil end
    local powerd = Device.getPowerDevice and Device:getPowerDevice()
    if not powerd or not powerd.getPowerdState then return nil end
    local ok, state = pcall(function() return powerd:getPowerdState() end)
    if not ok then return nil end
    return state
end

-- True iff we're on Kindle AND powerd reports the device is back in
-- screensaver/suspended after the settle delay — the canonical "this
-- was an unscheduled wake" signal. Non-Kindle devices fall through
-- (read_powerd_state returns nil → returns false; the cross-platform
-- defer/cancel mechanism is the only gate there).
local function is_unscheduled_kindle_wake()
    local state = read_powerd_state()
    if state == nil then return false end
    return state == "screenSaver" or state == "suspended"
end

local function cancel_pending_resume_sync(reason)
    if not pending_resume_sync_fn then return end
    UIManager:unschedule(pending_resume_sync_fn)
    pending_resume_sync_fn = nil
    logger.dbg("webdav_autosync: trigger=resume cancelled reason=" .. reason)
end

-- Stats accumulator for the chain (progress sync → book auto-sync) used
-- on Resume and on the startup hook in init(). When `chain_stats` is set
-- on a runner call, the runner stores its counts in the matching section
-- (`progress` or `books`) and the per-run summary popup is suppressed;
-- the orchestrator shows ONE merged summary at chain end via
-- `showChainSummary`, with each sync on its own line so the user can
-- tell which counts came from which sync.
--
-- A nil section means the runner never reported (e.g., reader-context
-- skip for book auto-sync, in-flight skip, offline). Plan-level failures
-- still set a section — `mergeChainStats` is called with a synthetic
-- stats table so the merged summary surfaces the failure.
--
-- `downloaded_rels` is union'd across both sections — the post-chain
-- library-refresh broadcast doesn't care which sync produced which file.
local function make_empty_chain_stats()
    return {
        progress = nil,
        books = nil,
        downloaded_rels = {},
    }
end

-- Sum of `failed` across both sections (treating nil section as 0).
-- Used by silent_mode chain orchestrators to decide whether to show
-- the merged summary popup at all — silent_mode only shows on failure.
local function chain_total_failed(chain_stats)
    local n = 0
    if chain_stats.progress then n = n + (chain_stats.progress.failed or 0) end
    if chain_stats.books then n = n + (chain_stats.books.failed or 0) end
    return n
end

-- Per-runner stats accumulator initialized from a fresh plan_obj. The
-- plan tells us up front how many entries were classified as
-- skipped_unchanged or baselined; everything else starts at zero and is
-- bumped by run_action_loop / resolveConflictsInteractive. Used by
-- runTwoWaySync, runProgressSync, doProgressSyncForBook (the three
-- "planned" runners). runOneWaySync has its own shape (sync.run_sync
-- returns counts directly).
local function init_stats_from_plan(plan_obj)
    return {
        downloaded = 0,
        uploaded = 0,
        unchanged = plan_obj.actions.skipped_unchanged,
        baselined = plan_obj.actions.baselined,
        conflicts_skipped = 0,
        failed = 0,
        failures = {},
        downloaded_rels = {},
    }
end

-- Iterate the planner's to_download and to_upload action arrays,
-- mutating `stats` in place. Per-rel HTTP failures populate
-- stats.failures with "<rel> (<msg>)" strings — same format the
-- conflict resolver uses, so the merged display is consistent.
-- on_action_failure is an optional callback (kind, rel, msg) → ()
-- used by the close-trigger runner to emit logger.warn lines per
-- failure (it has no other UI surface for them).
local function run_action_loop(plan_obj, stats, on_action_failure)
    for _, a in ipairs(plan_obj.actions.to_download) do
        local ok, msg = sync.do_action(plan_obj, "download", a)
        if ok then
            stats.downloaded = stats.downloaded + 1
            table.insert(stats.downloaded_rels, a.rel)
        else
            stats.failed = stats.failed + 1
            table.insert(stats.failures, a.rel .. " (" .. tostring(msg) .. ")")
            if on_action_failure then on_action_failure("download", a.rel, msg) end
        end
    end
    for _, a in ipairs(plan_obj.actions.to_upload) do
        local ok, msg = sync.do_action(plan_obj, "upload", a)
        if ok then
            stats.uploaded = stats.uploaded + 1
        else
            stats.failed = stats.failed + 1
            table.insert(stats.failures, a.rel .. " (" .. tostring(msg) .. ")")
            if on_action_failure then on_action_failure("upload", a.rel, msg) end
        end
    end
end

local function defer_until_online(label, retries_left, retry_fn)
    local NetworkMgr = require("ui/network/manager")
    -- isOnline() is just a DNS probe (canResolveHostnames at
    -- manager.lua:314, `socket.dns.toip("dns.msftncsi.com")`) — DNS
    -- can succeed against cached records before the kernel routing
    -- table is populated. We've seen the resulting failure mode in
    -- the wild: isOnline() returns true on the first retry after
    -- Resume, the sync proceeds, and the very next PROPFIND fails
    -- with "Network is unreachable" (the OS-level errno from a
    -- routeless socket). hasDefaultRoute (manager.lua:285) catches
    -- that — it does a UDP setpeername on a documentation-range IP
    -- (203.0.113.1 / 2001:db8::1) which returns false in exactly
    -- the no-route state. Require both. Defensive existence checks
    -- match the pattern used elsewhere; on a hypothetical older
    -- KOReader build that lacks one or the other, the missing check
    -- is treated as pass.
    local online = (NetworkMgr.isOnline == nil) or NetworkMgr:isOnline()
    local has_route = (NetworkMgr.hasDefaultRoute == nil) or NetworkMgr:hasDefaultRoute()
    if online and has_route then
        return false  -- caller proceeds inline
    end
    if retries_left <= 0 then
        logger.dbg(string.format(
            "webdav_autosync: %s skip reason=offline-give-up online=%s has_route=%s",
            label, tostring(online), tostring(has_route)))
        return true
    end
    logger.dbg(string.format(
        "webdav_autosync: %s defer reason=offline online=%s has_route=%s retries_left=%d",
        label, tostring(online), tostring(has_route), retries_left))
    UIManager:scheduleIn(AUTO_TRIGGER_NET_RETRY_INTERVAL_SECS,
        function() retry_fn(retries_left - 1) end)
    return true
end

-- In-flight guard. Both book sync and progress sync mutate the same
-- on-disk LuaSettings cache (webdav_autosync_state.lua). If a sync
-- is paused on the conflict dialog and the user kicks off a second
-- sync from the menu, both runs load cache_files independently, mutate
-- their own copy, and the second flush clobbers the first's writes —
-- with the visible failure mode of cache rows reverting and files being
-- re-classified as "changed" on the next run. The guard is a single
-- module-local boolean covering every sync flow (book one-way, book
-- two-way, progress full-library, progress scoped close).
--
-- Held across the conflict dialog chain so a tap on "Sync books now"
-- mid-conflict is rejected with a user-visible message rather than
-- racing on save_cache. Cleared on every runner exit path.
--
-- Limitation: if a conflict dialog is dismissed via back-button or
-- tap-outside (rather than picking a button), `finish()` is never
-- called, the flag stays set, and subsequent auto syncs no-op until
-- KOReader restarts. The cache flush leaks the same way regardless,
-- so this isn't a regression — it's the same shape of pre-existing
-- limitation, made visible by the new flag.
local sync_in_flight = false

local function check_in_flight(label, manual)
    if not sync_in_flight then return false end
    logger.info("webdav_autosync: " .. label .. " skip reason=already-in-flight")
    if manual then
        UIManager:show(InfoMessage:new{
            text = _("A WebDAV sync is already in progress."),
        })
    end
    return true
end

local function acquire_sync_lock()
    sync_in_flight = true
end

local function release_sync_lock()
    sync_in_flight = false
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
        local function run_startup_sync(retries_left)
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
            if defer_until_online("trigger=startup",
                retries_left or AUTO_TRIGGER_NET_RETRY_MAX,
                run_startup_sync) then
                return
            end
            mark_auto_run()
            logger.info(string.format(
                "webdav_autosync: trigger=startup progress=%s books=%s",
                tostring(progress_on), tostring(books_on)))
            -- Startup runs in silent_mode like Resume: no "Syncing…"
            -- InfoMessage during the run, no summary popup at the end
            -- unless something failed. Conflict dialogs still surface
            -- (handled inside the runners). The chain branch shows a
            -- single merged summary IFF total failed > 0.
            if progress_on and books_on then
                local chain_stats = make_empty_chain_stats()
                self:doProgressSync({
                    trigger = "startup",
                    silent_mode = true,
                    chain_stats = chain_stats,
                    on_done = function()
                        self:maybeRunBookAutoSync({
                            silent_mode = true,
                            chain_stats = chain_stats,
                            on_done = function()
                                if chain_total_failed(chain_stats) > 0 then
                                    self:showChainSummary(chain_stats)
                                end
                            end,
                        })
                    end,
                })
            elseif progress_on then
                self:doProgressSync({
                    trigger = "startup",
                    silent_mode = true,
                })
            else
                self:maybeRunBookAutoSync({ silent_mode = true })
            end
        end
        run_startup_sync()
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
                        help_text = _("Minimum seconds between auto-triggered full reconciles (device wake, KOReader startup). Manual syncs always run regardless. The book-close trigger has its own cooldown below. 0 disables. Default 300 s."),
                    },
                    {
                        text_func = function()
                            return T(_("Close-trigger sync cooldown: %1 s"), tostring(get_close_cooldown()))
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
                            local secs = get_resume_settle()
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
-- Cooldown is consumed in runResumeSync so the chain counts as a single auto
-- slot.
--
-- Resume defers the actual sync work by `get_resume_settle()` seconds to
-- filter out brief unscheduled wakes (see big comment block above). The
-- cheap toggle gate runs here so we don't even schedule when both sync
-- types are off. Toggles, cooldown, and the Kindle powerd-state gate all
-- re-run at fire time in runResumeSync — they may have changed during the
-- wait. Setting the delay to 0 bypasses the defer and the Kindle state
-- gate (pre-1.7.8 behavior).
function WebDAVSync:onResume()
    local progress_on = event_enabled("progress_on_resume")
    local books_on = event_enabled("books_on_resume")
    if not progress_on and not books_on then
        logger.dbg("webdav_autosync: trigger=resume skip reason=disabled")
        return
    end
    local delay = get_resume_settle()
    if delay <= 0 then
        -- User opted out of the settle gate. Run inline, skipping the
        -- Kindle unscheduled-wake check (which only makes sense after a
        -- non-zero settle delay).
        self:runResumeSync(nil, { skip_unscheduled_check = true })
        return
    end
    -- Both plugin instances (FM and Reader) receive Resume; collapse to a
    -- single pending defer. Repeated Resume broadcasts inside the settle
    -- window (e.g. unscheduled wake → real user wake before t+delay) leave
    -- the original defer in place; whichever wake is "real" will pass the
    -- fire-time Kindle state gate.
    if pending_resume_sync_fn then
        logger.dbg("webdav_autosync: trigger=resume skip reason=already-scheduled")
        return
    end
    local fn
    fn = function()
        pending_resume_sync_fn = nil
        self:runResumeSync()
    end
    pending_resume_sync_fn = fn
    logger.dbg("webdav_autosync: trigger=resume defer secs=" .. tostring(delay))
    UIManager:scheduleIn(delay, fn)
end

-- Cancel any pending deferred Resume sync if the device suspends again
-- before the settle delay elapses. Does NOT initiate any sync work — the
-- onSuspend handler exists solely as the cancel hook for the Resume
-- defer. Don't reintroduce a sync-on-suspend codepath here.
function WebDAVSync:onSuspend()
    cancel_pending_resume_sync("suspend")
end

-- Fire-time gating + sync. Re-checks toggles and cooldown (they may have
-- changed in the settle window) and applies the Kindle unscheduled-wake
-- gate, then enters the existing online-defer / sync chain. The retries
-- arg threads through online-defer's recursive callback; KOReader's
-- Resume broadcast has no payload, so onResume itself doesn't take it.
-- opts.skip_unscheduled_check: set true when called inline from onResume's
-- delay==0 path; the Kindle state check would (incorrectly) skip every
-- Resume there because powerd is still in screenSaver right at wake.
function WebDAVSync:runResumeSync(retries_left, opts)
    opts = opts or {}
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
    -- Kindle-only: the settle delay matches KindlePowerD's own classifier
    -- window, so reading powerd state here gives the same verdict KOReader
    -- itself uses for `Kindle (un)scheduled wakeup` — no inference needed.
    -- Non-Kindle devices fall through (state==nil); they're protected by
    -- the cross-platform defer + onSuspend cancel + CPU-suspended-during-
    -- sleep mechanism.
    if not opts.skip_unscheduled_check and is_unscheduled_kindle_wake() then
        logger.dbg("webdav_autosync: trigger=resume skip reason=unscheduled-wake state="
            .. tostring(read_powerd_state()))
        return
    end
    if defer_until_online("trigger=resume",
        retries_left or AUTO_TRIGGER_NET_RETRY_MAX,
        function(n) self:runResumeSync(n, opts) end) then
        return
    end
    mark_auto_run()
    logger.info(string.format(
        "webdav_autosync: trigger=resume progress=%s books=%s",
        tostring(progress_on), tostring(books_on)))
    -- Resume runs in silent_mode: no "Syncing…" popups, and the summary
    -- popup fires only if something failed. Conflicts still pop the dialog
    -- chain. When both progress and book sync run, accumulate into
    -- chain_stats and show ONE merged summary IFF total failures > 0.
    if progress_on and books_on then
        local chain_stats = make_empty_chain_stats()
        self:doProgressSync({
            trigger = "resume",
            silent_mode = true,
            chain_stats = chain_stats,
            on_done = function()
                self:maybeRunBookAutoSync({
                    silent_mode = true,
                    chain_stats = chain_stats,
                    on_done = function()
                        if chain_total_failed(chain_stats) > 0 then
                            self:showChainSummary(chain_stats)
                        end
                    end,
                })
            end,
        })
    elseif progress_on then
        self:doProgressSync({
            trigger = "resume",
            silent_mode = true,
        })
    else
        self:maybeRunBookAutoSync({ silent_mode = true })
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
        info_text = _("Minimum seconds between auto-triggered full reconciles (device wake, KOReader startup). Manual syncs always run regardless. The book-close trigger has its own cooldown. Set to 0 to disable."),
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

function WebDAVSync:setCloseCooldown()
    UIManager:show(SpinWidget:new{
        title_text = _("Close-trigger cooldown (seconds)"),
        info_text = _("Minimum seconds between two consecutive close-trigger syncs of the same book. Closing a different book always runs regardless. Set to 0 to disable."),
        value = get_close_cooldown(),
        value_min = CLOSE_COOLDOWN_MIN,
        value_max = CLOSE_COOLDOWN_MAX,
        value_step = CLOSE_COOLDOWN_STEP,
        value_hold_step = CLOSE_COOLDOWN_STEP * 3,
        default_value = DEFAULT_CLOSE_COOLDOWN,
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
        value = get_resume_settle(),
        value_min = RESUME_SETTLE_MIN,
        value_max = RESUME_SETTLE_MAX,
        value_step = RESUME_SETTLE_STEP,
        value_hold_step = RESUME_SETTLE_STEP * 2,
        default_value = DEFAULT_RESUME_SETTLE,
        ok_text = _("Set"),
        callback = function(spin)
            G_reader_settings:saveSetting("webdav_autosync_resume_settle_seconds", spin.value)
            -- If the user just set it to 0 while a defer is pending, kill
            -- the pending fn so it doesn't fire later under the now-stale
            -- "user wants the gate" assumption. Cheap and surprise-free.
            if spin.value <= 0 then
                cancel_pending_resume_sync("setting changed to 0")
            end
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
    -- silent_mode: auto-trigger UI (no syncing message, no summary on
    -- success). Default false (manual UI: full popups). All auto callers
    -- (startup, resume, close) pass true.
    local silent_mode = opts.silent_mode == true
    local chain_stats = opts.chain_stats
    local on_done = opts.on_done

    if check_in_flight("book sync", not is_auto) then
        if on_done then on_done() end
        return
    end

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isWifiOn and not NetworkMgr:isWifiOn() then
        -- Auto triggers (startup, Resume) silently no-op when offline; only
        -- manual entry points pop the Wi-Fi prompt.
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
        silent_mode = silent_mode,
        chain_stats = chain_stats,
        on_done = on_done,
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
    acquire_sync_lock()
    -- silent_mode = true is the auto-trigger UI: no "Syncing…" InfoMessage
    -- during the run, no summary popup at the end UNLESS something failed.
    -- Conflict resolution dialogs and plan-failure popups are unaffected
    -- (they're always shown — they need user attention).
    local silent_mode = ctx.silent_mode == true
    local chain_stats = ctx.chain_stats
    local syncing_msg
    if not silent_mode then
        syncing_msg = InfoMessage:new{ text = _("Syncing…") }
        UIManager:show(syncing_msg)
        UIManager:forceRePaint()
    end
    local downloaded, skipped, failed, err, downloaded_rels = sync.run_sync(
            ctx.server_url, ctx.username, ctx.password,
            ctx.folder, nil, ctx.file_extensions)
    if syncing_msg then UIManager:close(syncing_msg) end
    logger.info(string.format(
        "webdav_autosync: book sync done mode=one_way downloaded=%d skipped=%d failed=%d",
        downloaded, skipped, failed))
    if chain_stats then
        -- Map one-way fields onto the chain stats schema. one-way has no
        -- upload / baseline / conflict notion (strict download-only) and
        -- `err` is a single string covering plan/list-level failure
        -- rather than a per-rel breakdown — fold it as one synthetic
        -- failures entry. `failed` stays a per-rel HTTP failure count;
        -- the synthetic entry from `err` adds to that conceptually but
        -- isn't counted twice (the section line shows `failed` and the
        -- failures list at the bottom shows the synthetic message).
        local failures = {}
        if err then
            table.insert(failures, _("book sync") .. " (" .. tostring(err) .. ")")
        end
        self:mergeChainStats(chain_stats, {
            downloaded = downloaded,
            uploaded = 0,
            unchanged = skipped,
            baselined = 0,
            conflicts_skipped = 0,
            failed = failed,
            failures = failures,
            downloaded_rels = downloaded_rels,
        }, "books")
    elseif (not silent_mode) or failed > 0 or err then
        -- Standalone path: show summary always when not silent_mode, or
        -- only on failure when silent_mode. A run that downloaded 4 and
        -- failed on 1 still reports "4 downloaded" alongside the failure.
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
    end
    -- Files that did get written still trigger a refresh, even when err is set.
    self:notifyLibraryRefresh(ctx.folder, downloaded_rels)
    self:turnOffWifiIfRequested(ctx)
    release_sync_lock()
    if ctx.on_done then ctx.on_done() end
end

function WebDAVSync:runTwoWaySync(ctx)
    acquire_sync_lock()
    -- See runOneWaySync for silent_mode semantics — same here.
    local silent_mode = ctx.silent_mode == true
    local chain_stats = ctx.chain_stats
    local syncing_msg
    if not silent_mode then
        syncing_msg = InfoMessage:new{ text = _("Syncing…") }
        UIManager:show(syncing_msg)
        UIManager:forceRePaint()
    end

    local plan_obj, err = sync.plan(ctx.server_url, ctx.username, ctx.password,
            ctx.folder, ctx.file_extensions)
    if not plan_obj then
        if syncing_msg then UIManager:close(syncing_msg) end
        logger.warn("webdav_autosync: book sync plan failed: " .. tostring(err))
        if chain_stats then
            self:mergeChainStats(chain_stats, {
                downloaded = 0,
                uploaded = 0,
                unchanged = 0,
                baselined = 0,
                conflicts_skipped = 0,
                failed = 1,
                failures = { _("book sync") .. " (" .. tostring(err) .. ")" },
            }, "books")
        else
            -- Plan failure is *always* surfaced (even in silent_mode):
            -- the user needs to know the sync didn't even start.
            UIManager:show(InfoMessage:new{
                text = T(_("Sync failed: %1"), tostring(err)),
            })
        end
        self:turnOffWifiIfRequested(ctx)
        release_sync_lock()
        if ctx.on_done then ctx.on_done() end
        return
    end

    local stats = init_stats_from_plan(plan_obj)

    run_action_loop(plan_obj, stats)

    if syncing_msg then UIManager:close(syncing_msg) end

    local conflicts = plan_obj.actions.conflicts
    local function finish()
        sync.save_cache(plan_obj)
        self:notifyLibraryRefresh(plan_obj.local_folder, stats.downloaded_rels)
        logger.info(string.format(
            "webdav_autosync: book sync done mode=two_way downloaded=%d uploaded=%d unchanged=%d baselined=%d conflicts_skipped=%d failed=%d",
            stats.downloaded, stats.uploaded, stats.unchanged, stats.baselined,
            stats.conflicts_skipped, stats.failed))
        if chain_stats then
            self:mergeChainStats(chain_stats, stats, "books")
        elseif (not silent_mode) or stats.failed > 0 then
            self:showTwoWaySummary(stats)
        end
        self:turnOffWifiIfRequested(ctx)
        release_sync_lock()
        if ctx.on_done then ctx.on_done() end
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

--- Store a per-runner stats table into chain_stats under `section`
--- ("progress" or "books"). Replaces (not adds) — each runner reports
--- its section once. Downloaded rels are union'd across sections for
--- the eventual single library-refresh broadcast.
---
--- Stats shape from progress / two-way book runners is identical; the
--- one-way book runner maps its differently-shaped result into a
--- synthetic stats table at the call site (skipped → unchanged, single
--- err string → one synthetic failures entry).
function WebDAVSync:mergeChainStats(chain_stats, stats, section)
    chain_stats[section] = {
        downloaded = stats.downloaded,
        uploaded = stats.uploaded or 0,
        unchanged = stats.unchanged or 0,
        baselined = stats.baselined or 0,
        conflicts_skipped = stats.conflicts_skipped or 0,
        failed = stats.failed,
        failures = stats.failures or {},
    }
    if stats.downloaded_rels then
        for _, r in ipairs(stats.downloaded_rels) do
            table.insert(chain_stats.downloaded_rels, r)
        end
    end
end

--- Build one ", "-joined description line for a chain section. Always
--- includes downloaded + uploaded; other counts only when non-zero so a
--- typical no-op run reads "0 downloaded, 0 uploaded" (the user wanted
--- explicit reassurance the sync ran).
local function describe_chain_section(section)
    local parts = {}
    table.insert(parts, T(_("%1 downloaded"), tostring(section.downloaded)))
    table.insert(parts, T(_("%1 uploaded"), tostring(section.uploaded)))
    if section.unchanged > 0 then
        table.insert(parts, T(_("%1 unchanged"), tostring(section.unchanged)))
    end
    if section.baselined > 0 then
        table.insert(parts, T(_("%1 baselined"), tostring(section.baselined)))
    end
    if section.conflicts_skipped > 0 then
        table.insert(parts, T(_("%1 conflicts skipped"), tostring(section.conflicts_skipped)))
    end
    if section.failed > 0 then
        table.insert(parts, T(_("%1 failed"), tostring(section.failed)))
    end
    return table.concat(parts, ", ")
end

--- Merged summary popup for the Resume / startup chain. Each sync gets
--- its own line so the user can see which counts belong to which; any
--- per-rel failure messages from either section are listed once at the
--- bottom under a "Failures:" heading. Sections that didn't run (nil)
--- are omitted.
function WebDAVSync:showChainSummary(stats)
    local lines = { _("Sync done.") }

    local has_section = false
    if stats.progress then
        has_section = true
        table.insert(lines, "")
        table.insert(lines, _("Reading progress sync:") .. " " .. describe_chain_section(stats.progress) .. ".")
    end
    if stats.books then
        if not has_section then table.insert(lines, "") end
        has_section = true
        table.insert(lines, _("Book sync:") .. " " .. describe_chain_section(stats.books) .. ".")
    end

    local failures = {}
    if stats.progress and stats.progress.failures then
        for _, f in ipairs(stats.progress.failures) do
            table.insert(failures, f)
        end
    end
    if stats.books and stats.books.failures then
        for _, f in ipairs(stats.books.failures) do
            table.insert(failures, f)
        end
    end
    if #failures > 0 then
        table.insert(lines, "")
        table.insert(lines, _("Failures:"))
        for _, f in ipairs(failures) do
            table.insert(lines, "  " .. f)
        end
    end

    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
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
--- opts.silent_mode:          forwarded to doSync; auto-trigger UI when
---                            true (no syncing message, no success summary).
--- opts.chain_stats:          when set, doSync's runner accumulates into it
---                            instead of showing its own summary.
--- opts.on_done:              called on every exit path (no-op skip, sync
---                            done) so the chain orchestrator can show its
---                            merged summary regardless of which branch fires.
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
    local silent_mode = opts.silent_mode == true
    local chain_stats = opts.chain_stats
    local function done() if on_done then on_done() end end

    if check_in_flight("progress sync", manual) then return done() end

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
            silent_mode = silent_mode,
            chain_stats = chain_stats,
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
        silent_mode = silent_mode,
        chain_stats = chain_stats,
    })
end

--- Scoped progress sync for one just-closed book. Called from
--- onCloseDocument after the per-book debounce passes. One PROPFIND on
--- `<book>.sdr/`, executes non-conflicting actions, runs the conflict
--- dialog chain if needed, and surfaces a summary popup ONLY on failure.
--- Same gates as doProgressSync: the toggle, the `doc` metadata-folder
--- requirement, server/folder configured, online.
---
--- Auto-trigger UI policy (silent_mode): silent on success, popup only
--- on failure. Conflicts now surface immediately via the same dialog
--- chain as the interactive triggers — they're no longer deferred.
--- Pre-1.8.0 the close trigger swallowed conflicts and left them for
--- the next Resume/startup; the user asked for them to be surfaced now
--- so the change is visible at the moment they happen (the user just
--- closed the book; a dialog right after is cheap).
function WebDAVSync:doProgressSyncForBook(book_rel)
    -- Gating (master + progress_on_close) is enforced by onCloseDocument
    -- before this runs; we don't re-check here.

    if check_in_flight("close-trigger sync", false) then return end

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

    -- Past the cheap config gates: from here on we'll touch the cache and the
    -- network, so claim the in-flight lock. Released on every exit below.
    acquire_sync_lock()

    local username = self:getSetting("username", "")
    local password = self:getSetting("password", "")
    logger.info("webdav_autosync: close-trigger sync start book=" .. tostring(book_rel))
    local plan_obj, err = sync.plan_progress_book(server_url, username, password, local_folder, book_rel)
    if not plan_obj then
        logger.warn("webdav_autosync: close-trigger plan failed book=" .. tostring(book_rel) .. " err=" .. tostring(err))
        -- Plan failure is *always* surfaced — the user needs to know the
        -- close-trigger sync didn't run. Same policy as the other runners.
        UIManager:show(InfoMessage:new{
            text = T(_("Progress sync failed: %1"), tostring(err)),
        })
        release_sync_lock()
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
            logger.warn("webdav_autosync: close-trigger download failed rel=" .. a.rel .. " err=" .. tostring(msg))
        end
    end
    for _, a in ipairs(plan_obj.actions.to_upload) do
        local ok, msg = sync.do_action(plan_obj, "upload", a)
        if ok then
            stats.uploaded = stats.uploaded + 1
        else
            stats.failed = stats.failed + 1
            table.insert(stats.failures, a.rel .. " (" .. tostring(msg) .. ")")
            logger.warn("webdav_autosync: close-trigger upload failed rel=" .. a.rel .. " err=" .. tostring(msg))
        end
    end

    local conflicts = plan_obj.actions.conflicts
    local function finish()
        sync.save_cache(plan_obj)
        self:notifyLibraryRefresh(plan_obj.local_folder, stats.downloaded_rels)
        logger.info(string.format(
            "webdav_autosync: close-trigger sync done book=%s downloaded=%d uploaded=%d unchanged=%d baselined=%d conflicts_skipped=%d failed=%d",
            tostring(book_rel), stats.downloaded, stats.uploaded,
            stats.unchanged, stats.baselined,
            stats.conflicts_skipped, stats.failed))
        -- silent_mode policy: summary popup only when something failed.
        if stats.failed > 0 then
            self:showProgressSummary(stats)
        end
        release_sync_lock()
    end

    if #conflicts == 0 then
        finish()
        return
    end

    logger.info("webdav_autosync: close-trigger sync surfacing conflicts count=" .. tostring(#conflicts))
    self:resolveConflictsInteractive(plan_obj, conflicts, stats, finish)
end

--- Run a full-library progress sync. Surfaces plan errors, runs the
--- conflict dialog chain, and shows a summary at the end.
--- opts.silent_mode:          auto-trigger UI when true — no "Syncing
---                            reading progress…" InfoMessage during the
---                            run, no summary popup at the end UNLESS
---                            something failed. Default false (manual UI).
--- opts.chain_stats:          optional accumulator. When set, this run's
---                            counts are stored in it (under "progress")
---                            and the per-run summary popup is suppressed;
---                            the chain orchestrator shows ONE merged
---                            summary at chain end. Plan failure folds in
---                            as one synthetic failure entry.
--- Silent close-trigger syncs go through doProgressSyncForBook instead.
function WebDAVSync:runProgressSync(opts)
    local server_url = opts.server_url
    local local_folder = opts.local_folder
    local on_done = opts.on_done
    local silent_mode = opts.silent_mode == true
    local chain_stats = opts.chain_stats
    local function done() if on_done then on_done() end end

    acquire_sync_lock()
    local username = self:getSetting("username", "")
    local password = self:getSetting("password", "")

    local syncing_msg
    if not silent_mode then
        syncing_msg = InfoMessage:new{ text = _("Syncing reading progress…") }
        UIManager:show(syncing_msg)
        UIManager:forceRePaint()
    end

    logger.info("webdav_autosync: progress sync start")
    local plan_obj, err = sync.plan_progress(server_url, username, password, local_folder)
    if not plan_obj then
        if syncing_msg then UIManager:close(syncing_msg) end
        logger.warn("webdav_autosync: progress plan failed: " .. tostring(err))
        if chain_stats then
            self:mergeChainStats(chain_stats, {
                downloaded = 0,
                uploaded = 0,
                unchanged = 0,
                baselined = 0,
                conflicts_skipped = 0,
                failed = 1,
                failures = { _("progress sync") .. " (" .. tostring(err) .. ")" },
            }, "progress")
        else
            -- Plan failure is *always* surfaced (even in silent_mode):
            -- the user needs to know the sync didn't even start.
            UIManager:show(InfoMessage:new{
                text = T(_("Progress sync failed: %1"), tostring(err)),
            })
        end
        release_sync_lock()
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

    if syncing_msg then UIManager:close(syncing_msg) end

    local conflicts = plan_obj.actions.conflicts
    local function finish()
        sync.save_cache(plan_obj)
        self:notifyLibraryRefresh(plan_obj.local_folder, stats.downloaded_rels)
        logger.info(string.format(
            "webdav_autosync: progress sync done downloaded=%d uploaded=%d unchanged=%d baselined=%d conflicts_skipped=%d failed=%d",
            stats.downloaded, stats.uploaded, stats.unchanged, stats.baselined,
            stats.conflicts_skipped, stats.failed))
        if chain_stats then
            self:mergeChainStats(chain_stats, stats, "progress")
        elseif (not silent_mode) or stats.failed > 0 then
            self:showProgressSummary(stats)
        end
        release_sync_lock()
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
