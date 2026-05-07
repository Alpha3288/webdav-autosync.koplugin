--[[--
Sync runner + presentation layer for the WebDAV Auto Sync plugin.

Owns:
  * `run_planned(plan_fn, ctx, opts)` — the unified planned-sync runner.
    Replaces the bodies of runTwoWaySync, runProgressSync, and
    doProgressSyncForBook. plan_fn is one of sync.plan / sync.plan_progress
    / sync.plan_progress_book.
  * `run_one_way(ctx)` — wraps sync.run_sync (legacy download-only path).
  * Conflict dialog chain (`resolve_conflicts_interactive`).
  * Per-runner stats accumulator (`init_stats_from_plan`) and the action
    loop (`run_action_loop`).
  * Chain stats helpers (`make_empty_chain_stats`, `chain_total_failed`,
    `merge_chain_stats`, `merge_plan_failure`).
  * Summary popups (`show_summary`, `show_chain_summary`,
    `describe_chain_section`).
  * Library refresh broadcast (`notify_library_refresh`).

Pure functions where possible; the few that touch UIManager do so directly
without holding any plugin reference. The only KOReader globals required
are UIManager + Event + InfoMessage + ButtonDialogTitle.
--]]--

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local Event = require("ui/event")
local logger = require("logger")
local sync = require("sync")
local triggers = require("triggers")
local T = require("ffi/util").template
local _ = require("gettext")

-- ---------- per-runner stats ----------

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

-- ---------- chain stats accumulator ----------

local function make_empty_chain_stats()
    return { progress = nil, books = nil, downloaded_rels = {} }
end

local function chain_total_failed(chain_stats)
    local n = 0
    if chain_stats.progress then n = n + (chain_stats.progress.failed or 0) end
    if chain_stats.books then n = n + (chain_stats.books.failed or 0) end
    return n
end

local function merge_chain_stats(chain_stats, stats, section)
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

local function merge_plan_failure(chain_stats, err, section, label)
    merge_chain_stats(chain_stats, {
        downloaded = 0,
        uploaded = 0,
        unchanged = 0,
        baselined = 0,
        conflicts_skipped = 0,
        failed = 1,
        failures = { label .. " (" .. tostring(err) .. ")" },
    }, section)
end

-- ---------- summary formatters ----------

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

local function show_chain_summary(stats)
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
        for _, f in ipairs(stats.progress.failures) do table.insert(failures, f) end
    end
    if stats.books and stats.books.failures then
        for _, f in ipairs(stats.books.failures) do table.insert(failures, f) end
    end
    if #failures > 0 then
        table.insert(lines, "")
        table.insert(lines, _("Failures:"))
        for _, f in ipairs(failures) do table.insert(lines, "  " .. f) end
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

local function show_summary(prefix, stats)
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
    local text = prefix .. " " .. table.concat(parts, " ")
    if stats.failed > 0 and #stats.failures > 0 then
        text = text .. "\n\n" .. table.concat(stats.failures, "\n")
    end
    UIManager:show(InfoMessage:new{ text = text })
end

-- ---------- library refresh ----------

local function notify_library_refresh(local_folder, downloaded_rels)
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
    logger.dbg(string.format("webdav_autosync: notify_library_refresh affected_books=%d total_rels=%d",
            n, #downloaded_rels))
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
end

-- ---------- conflict dialog chain ----------

local function resolve_conflicts_interactive(plan_obj, conflicts, stats, on_done)
    local idx = 1
    local function next_one()
        if idx > #conflicts then on_done() return end
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

-- ---------- wifi teardown helper ----------

local function turn_off_wifi_if_requested(ctx)
    if not ctx.turn_off_wifi then return end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.turnOffWifi then NetworkMgr:turnOffWifi() end
end

-- ---------- one-way runner ----------

local function run_one_way(ctx)
    triggers.acquire_sync_lock()
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
            ctx.local_folder, nil, ctx.file_extensions)
    if syncing_msg then UIManager:close(syncing_msg) end
    logger.info(string.format(
        "webdav_autosync: book sync done mode=one_way downloaded=%d skipped=%d failed=%d",
        downloaded, skipped, failed))
    if chain_stats then
        local failures = {}
        if err then table.insert(failures, _("book sync") .. " (" .. tostring(err) .. ")") end
        merge_chain_stats(chain_stats, {
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
    notify_library_refresh(ctx.local_folder, downloaded_rels)
    turn_off_wifi_if_requested(ctx)
    triggers.release_sync_lock()
    if ctx.on_done then ctx.on_done() end
end

-- ---------- planned runner (unified) ----------

local function run_planned(plan_fn, ctx, opts)
    opts = opts or {}
    local silent_mode = opts.silent_mode == true
    local chain_stats = opts.chain_stats
    local chain_section = opts.chain_section
    local syncing_text = opts.syncing_text or _("Syncing…")
    local summary_prefix = opts.summary_prefix or _("Sync done.")
    local plan_failure_label = opts.plan_failure_label or _("sync")
    local plan_failure_prefix = opts.plan_failure_prefix or _("Sync failed: %1")
    local on_action_failure = opts.on_action_failure
    local on_done = opts.on_done

    triggers.acquire_sync_lock()

    local syncing_msg
    if not silent_mode then
        syncing_msg = InfoMessage:new{ text = syncing_text }
        UIManager:show(syncing_msg)
        UIManager:forceRePaint()
    end

    local plan_obj, err = plan_fn(ctx)
    if not plan_obj then
        if syncing_msg then UIManager:close(syncing_msg) end
        logger.warn(string.format(
            "webdav_autosync: %s plan failed: %s", plan_failure_label, tostring(err)))
        if chain_stats then
            merge_plan_failure(chain_stats, err, chain_section, plan_failure_label)
        else
            UIManager:show(InfoMessage:new{
                text = T(plan_failure_prefix, tostring(err)),
            })
        end
        turn_off_wifi_if_requested(ctx)
        triggers.release_sync_lock()
        if on_done then on_done() end
        return
    end

    local stats = init_stats_from_plan(plan_obj)
    run_action_loop(plan_obj, stats, on_action_failure)

    if syncing_msg then UIManager:close(syncing_msg) end

    local conflicts = plan_obj.actions.conflicts
    local function finish()
        sync.save_cache(plan_obj)
        notify_library_refresh(plan_obj.local_folder, stats.downloaded_rels)
        if opts.log_done then opts.log_done(stats) end
        if chain_stats then
            merge_chain_stats(chain_stats, stats, chain_section)
        elseif (not silent_mode) or stats.failed > 0 then
            show_summary(summary_prefix, stats)
        end
        turn_off_wifi_if_requested(ctx)
        triggers.release_sync_lock()
        if on_done then on_done() end
    end

    if #conflicts == 0 then
        finish()
        return
    end

    logger.info(string.format(
        "webdav_autosync: %s surfacing conflicts count=%d",
        plan_failure_label, #conflicts))
    resolve_conflicts_interactive(plan_obj, conflicts, stats, finish)
end

return {
    run_planned = run_planned,
    run_one_way = run_one_way,
    resolve_conflicts_interactive = resolve_conflicts_interactive,
    init_stats_from_plan = init_stats_from_plan,
    run_action_loop = run_action_loop,
    make_empty_chain_stats = make_empty_chain_stats,
    chain_total_failed = chain_total_failed,
    merge_chain_stats = merge_chain_stats,
    merge_plan_failure = merge_plan_failure,
    show_summary = show_summary,
    show_chain_summary = show_chain_summary,
    notify_library_refresh = notify_library_refresh,
    turn_off_wifi_if_requested = turn_off_wifi_if_requested,
}
