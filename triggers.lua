--[[--
Auto-trigger plumbing for the WebDAV Auto Sync plugin.

Owns:
  * Resume defer / cancel / fire-time gating (Kindle unscheduled-wake filter).
  * Online-defer polling (NetworkMgr.isOnline + hasDefaultRoute).
  * Single-process in-flight lock (book sync, progress sync, close-trigger
    sync all share it; held across the conflict dialog chain).
  * `dispatch_auto_chain` — the 3-branch (both / progress only / books only)
    chain orchestrator used by both startup and Resume. Builds a
    chain_stats accumulator, threads it through doProgressSync /
    maybeRunBookAutoSync, and shows ONE merged summary IFF total failed > 0
    when the chain completes.
  * `schedule_startup_sync` — the once-per-process post-init scheduleIn(2)
    handoff into run_startup_sync.

Calls back into the plugin via the instance bound at init time
(`triggers.bind(plugin)`). All module-locals are shared between the FM and
Reader plugin instances because Lua's `require` returns the same module
table on subsequent calls — this matches the pre-refactor module-local
behavior in main.lua (sync_in_flight, pending_resume_sync_fn,
startup_sync_scheduled).
--]]--

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("gettext")
local settings = require("settings")

local AUTO_TRIGGER_NET_RETRY_INTERVAL_SECS = 5
local AUTO_TRIGGER_NET_RETRY_MAX = 6  -- ~30 s total

local plugin = nil
local pending_resume_sync_fn = nil
local sync_in_flight = false
local startup_sync_scheduled = false

local function bind(p) plugin = p end

-- ---------- in-flight lock ----------

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

local function acquire_sync_lock() sync_in_flight = true end
local function release_sync_lock() sync_in_flight = false end

-- ---------- Kindle unscheduled-wake classifier ----------

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

local function is_unscheduled_kindle_wake()
    local state = read_powerd_state()
    if state == nil then return false end
    return state == "screenSaver" or state == "suspended"
end

-- ---------- Resume defer plumbing ----------

local function cancel_pending_resume_sync(reason)
    if not pending_resume_sync_fn then return end
    UIManager:unschedule(pending_resume_sync_fn)
    pending_resume_sync_fn = nil
    logger.dbg("webdav_autosync: trigger=resume cancelled reason=" .. reason)
end

-- ---------- online-defer polling ----------

local function defer_until_online(label, retries_left, retry_fn)
    local NetworkMgr = require("ui/network/manager")
    local online = (NetworkMgr.isOnline == nil) or NetworkMgr:isOnline()
    local has_route = (NetworkMgr.hasDefaultRoute == nil) or NetworkMgr:hasDefaultRoute()
    if online and has_route then return false end
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

-- ---------- chain orchestrator ----------

local function dispatch_auto_chain(opts)
    local runner = require("runner")
    local trigger = opts.trigger
    local progress_on = opts.progress_on
    local books_on = opts.books_on
    if progress_on and books_on then
        local chain_stats = runner.make_empty_chain_stats()
        plugin:doProgressSync({
            trigger = trigger,
            silent_mode = true,
            chain_stats = chain_stats,
            on_done = function()
                plugin:maybeRunBookAutoSync({
                    silent_mode = true,
                    chain_stats = chain_stats,
                    on_done = function()
                        if runner.chain_total_failed(chain_stats) > 0 then
                            runner.show_chain_summary(chain_stats)
                        end
                    end,
                })
            end,
        })
    elseif progress_on then
        plugin:doProgressSync({ trigger = trigger, silent_mode = true })
    else
        plugin:maybeRunBookAutoSync({ silent_mode = true })
    end
end

-- ---------- fire-time gating: Resume ----------

local function run_resume_sync(retries_left, opts)
    opts = opts or {}
    local progress_on = settings.event_enabled("progress_on_resume")
    local books_on = settings.event_enabled("books_on_resume")
    if not progress_on and not books_on then
        logger.dbg("webdav_autosync: trigger=resume skip reason=disabled")
        return
    end
    if not settings.should_run_auto() then
        logger.dbg("webdav_autosync: trigger=resume skip reason=cooldown")
        return
    end
    if not opts.skip_unscheduled_check and is_unscheduled_kindle_wake() then
        logger.dbg("webdav_autosync: trigger=resume skip reason=unscheduled-wake state="
            .. tostring(read_powerd_state()))
        return
    end
    if defer_until_online("trigger=resume",
            retries_left or AUTO_TRIGGER_NET_RETRY_MAX,
            function(n) run_resume_sync(n, opts) end) then
        return
    end
    settings.mark_auto_run()
    logger.info(string.format(
        "webdav_autosync: trigger=resume progress=%s books=%s",
        tostring(progress_on), tostring(books_on)))
    dispatch_auto_chain({
        trigger = "resume",
        progress_on = progress_on,
        books_on = books_on,
    })
end

-- ---------- fire-time gating: startup ----------

local function run_startup_sync(retries_left)
    local progress_on = settings.event_enabled("progress_on_startup")
    local books_on = settings.event_enabled("books_on_startup")
    if not progress_on and not books_on then
        logger.dbg("webdav_autosync: trigger=startup skip reason=disabled")
        return
    end
    if not settings.should_run_auto() then
        logger.dbg("webdav_autosync: trigger=startup skip reason=cooldown")
        return
    end
    if defer_until_online("trigger=startup",
            retries_left or AUTO_TRIGGER_NET_RETRY_MAX,
            run_startup_sync) then
        return
    end
    settings.mark_auto_run()
    logger.info(string.format(
        "webdav_autosync: trigger=startup progress=%s books=%s",
        tostring(progress_on), tostring(books_on)))
    dispatch_auto_chain({
        trigger = "startup",
        progress_on = progress_on,
        books_on = books_on,
    })
end

local function schedule_startup_sync()
    if startup_sync_scheduled then
        logger.dbg("webdav_autosync: init skip startup-sync (already scheduled this process)")
        return
    end
    startup_sync_scheduled = true
    logger.dbg("webdav_autosync: init scheduling startup sync in 2s")
    UIManager:scheduleIn(2, function() run_startup_sync() end)
end

-- ---------- lifecycle hooks ----------

local function on_resume()
    local progress_on = settings.event_enabled("progress_on_resume")
    local books_on = settings.event_enabled("books_on_resume")
    if not progress_on and not books_on then
        logger.dbg("webdav_autosync: trigger=resume skip reason=disabled")
        return
    end
    local delay = settings.get_resume_settle()
    if delay <= 0 then
        run_resume_sync(nil, { skip_unscheduled_check = true })
        return
    end
    if pending_resume_sync_fn then
        logger.dbg("webdav_autosync: trigger=resume skip reason=already-scheduled")
        return
    end
    local fn
    fn = function()
        pending_resume_sync_fn = nil
        run_resume_sync()
    end
    pending_resume_sync_fn = fn
    logger.dbg("webdav_autosync: trigger=resume defer secs=" .. tostring(delay))
    UIManager:scheduleIn(delay, fn)
end

local function on_suspend()
    cancel_pending_resume_sync("suspend")
end

local function on_resume_settle_changed(new_value)
    if new_value <= 0 then
        cancel_pending_resume_sync("setting changed to 0")
    end
end

return {
    bind = bind,
    schedule_startup_sync = schedule_startup_sync,
    on_resume = on_resume,
    on_suspend = on_suspend,
    on_resume_settle_changed = on_resume_settle_changed,
    acquire_sync_lock = acquire_sync_lock,
    release_sync_lock = release_sync_lock,
    check_in_flight = check_in_flight,
}
