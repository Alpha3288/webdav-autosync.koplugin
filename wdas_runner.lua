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
local sync = require("wdas_sync")
local triggers = require("wdas_triggers")
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
        deleted_remote = 0,
        deleted_local = 0,
        restored = 0,
        deferred_deletions = 0,
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
        deleted_remote = stats.deleted_remote or 0,
        deleted_local = stats.deleted_local or 0,
        restored = stats.restored or 0,
        deferred_deletions = stats.deferred_deletions or 0,
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
    if (section.deleted_remote or 0) > 0 then
        table.insert(parts, T(_("%1 deleted on server"), tostring(section.deleted_remote)))
    end
    if (section.deleted_local or 0) > 0 then
        table.insert(parts, T(_("%1 deleted locally"), tostring(section.deleted_local)))
    end
    if (section.restored or 0) > 0 then
        table.insert(parts, T(_("%1 restored"), tostring(section.restored)))
    end
    if (section.deferred_deletions or 0) > 0 then
        table.insert(parts, T(_("%1 deletions deferred"), tostring(section.deferred_deletions)))
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
    if (stats.deleted_remote or 0) > 0 then
        table.insert(parts, T(_("%1 deleted on server."), tostring(stats.deleted_remote)))
    end
    if (stats.deleted_local or 0) > 0 then
        table.insert(parts, T(_("%1 deleted locally."), tostring(stats.deleted_local)))
    end
    if (stats.restored or 0) > 0 then
        table.insert(parts, T(_("%1 restored."), tostring(stats.restored)))
    end
    if (stats.deferred_deletions or 0) > 0 then
        table.insert(parts, T(_("%1 deletions deferred."), tostring(stats.deferred_deletions)))
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

-- ---------- deletion dialog chain ----------

-- Map a deletion entry + user choice onto a sync.do_action call. For each
-- entry `kind`:
--   local_gone  (file vanished on device, still on server)
--     Delete  -> delete_remote (propagate the delete to the server)
--     Restore -> download      (bring the file back to the device)
--   remote_gone (file vanished on server, still on device)
--     Delete  -> delete_local  (remove the local file)
--     Restore -> upload        (push the file back to the server)
local function deletion_action_kind(entry, choice)
    if entry.kind == "local_gone" then
        return choice == "delete" and "delete_remote" or "download"
    end
    -- remote_gone
    return choice == "delete" and "delete_local" or "upload"
end

-- Bump the right stats counter after a successful delete/restore.
local function record_deletion_result(stats, entry, choice)
    if choice == "restore" then
        stats.restored = stats.restored + 1
        if entry.kind == "local_gone" and stats.downloaded_rels then
            table.insert(stats.downloaded_rels, entry.rel)
        end
    elseif entry.kind == "local_gone" then
        stats.deleted_remote = stats.deleted_remote + 1
    else
        stats.deleted_local = stats.deleted_local + 1
    end
end

-- Translate the plugin's open-document absolute path into a rel under the
-- download folder, or nil when there is no open document / it lives outside
-- the folder. Used to protect the open book (and its `<book>.sdr/`) from
-- deletion propagation.
local function open_document_rel(local_folder, open_document_path)
    if type(open_document_path) ~= "string" or open_document_path == "" then return nil end
    if type(local_folder) ~= "string" or local_folder == "" then return nil end
    local root = local_folder:gsub("/+$", "")
    if open_document_path:sub(1, #root + 1) ~= root .. "/" then return nil end
    local rel = open_document_path:sub(#root + 2)
    if rel == "" then return nil end
    return rel
end

-- True when a deletion entry's rel belongs to the open book — either the book
-- file itself or any file under its `<book>.sdr/` sidecar directory.
local function deletion_touches_open_book(rel, book_rel)
    if not book_rel then return false end
    if rel == book_rel then return true end
    local stem = book_rel:gsub("%.[^/.]+$", "")
    local sdr_prefix = stem .. ".sdr/"
    return rel:sub(1, #sdr_prefix) == sdr_prefix
end

-- Filter out deletions that touch the currently open document. Filtered
-- entries simply re-surface on the next sync. Returns the kept list.
local function filter_open_document_deletions(deletions, local_folder, open_document_path)
    local book_rel = open_document_rel(local_folder, open_document_path)
    if not book_rel then return deletions end
    local kept = {}
    for _, d in ipairs(deletions) do
        if deletion_touches_open_book(d.rel, book_rel) then
            logger.dbg("webdav_autosync: deletion skip reason=document-open rel=" .. d.rel)
        else
            table.insert(kept, d)
        end
    end
    return kept
end

-- Build the batch-dialog title: entries grouped by direction, up to ~8
-- relpaths listed per group then "…and K more".
local function describe_deletion_group(header, entries)
    local MAX_LISTED = 8
    local lines = { T(_("%1 (%2):"), header, tostring(#entries)) }
    for i = 1, math.min(#entries, MAX_LISTED) do
        table.insert(lines, "  " .. entries[i].rel)
    end
    if #entries > MAX_LISTED then
        table.insert(lines, T(_("…and %1 more"), tostring(#entries - MAX_LISTED)))
    end
    return table.concat(lines, "\n")
end

local function build_deletions_title(deletions)
    local local_gone, remote_gone = {}, {}
    for _, d in ipairs(deletions) do
        if d.kind == "local_gone" then
            table.insert(local_gone, d)
        else
            table.insert(remote_gone, d)
        end
    end
    local sections = {}
    if #local_gone > 0 then
        table.insert(sections, describe_deletion_group(_("Deleted on device"), local_gone))
    end
    if #remote_gone > 0 then
        table.insert(sections, describe_deletion_group(_("Deleted on server"), remote_gone))
    end
    return _("Files deleted since last sync.") .. "\n\n" .. table.concat(sections, "\n\n")
end

-- Apply one choice ("delete" | "restore") to one deletion entry, updating
-- stats. Returns nothing; failures append to stats.failures.
local function apply_deletion(plan_obj, entry, choice, stats)
    local action_kind = deletion_action_kind(entry, choice)
    logger.dbg("webdav_autosync: deletion apply rel=" .. entry.rel
        .. " kind=" .. entry.kind .. " choice=" .. choice .. " action=" .. action_kind)
    local ok, msg = sync.do_action(plan_obj, action_kind, entry)
    if ok then
        record_deletion_result(stats, entry, choice)
    else
        stats.failed = stats.failed + 1
        table.insert(stats.failures, entry.rel .. " (" .. tostring(msg) .. ")")
        logger.warn("webdav_autosync: deletion " .. choice .. " failed rel=" .. entry.rel
            .. " err=" .. tostring(msg))
    end
end

-- Per-file review chain: one ButtonDialogTitle per deletion offering
-- Delete / Restore / Later. Calls on_done when the list is exhausted.
--
-- Dismissing a dialog (outside tap / Back key) counts as Later for the
-- current entry. ButtonDialog defaults dismissable=true and its onClose
-- only runs tap_close_callback and closes the widget — without routing
-- dismissal into the chain, on_done would never fire and the sync lock
-- would stay held. The `handled` flag makes "continuation runs exactly
-- once per dialog" an explicit invariant; button callbacks close the
-- dialog themselves (UIManager:close only dispatches CloseWidget, it does
-- NOT re-trigger tap_close_callback), while the dismiss path leaves the
-- closing to onClose.
local function review_deletions_each(plan_obj, deletions, stats, on_done)
    local idx = 1
    local function next_one()
        if idx > #deletions then on_done() return end
        local entry = deletions[idx]
        local dialog
        local handled = false
        local function pick(choice, dismissed)
            if handled then return end
            handled = true
            if not dismissed then UIManager:close(dialog) end
            idx = idx + 1
            if choice == "later" then
                stats.deferred_deletions = stats.deferred_deletions + 1
                logger.dbg("webdav_autosync: deletion review rel=" .. entry.rel
                    .. " choice=later" .. (dismissed and " reason=dismissed" or ""))
            else
                apply_deletion(plan_obj, entry, choice, stats)
            end
            next_one()
        end
        local header = entry.kind == "local_gone"
            and _("Deleted on device — propagate to server?")
            or _("Deleted on server — apply locally?")
        dialog = ButtonDialogTitle:new{
            title = header .. "\n" .. entry.rel,
            buttons = {
                {{ text = _("Delete"),  callback = function() pick("delete")  end }},
                {{ text = _("Restore"), callback = function() pick("restore") end }},
                {{ text = _("Later"),   callback = function() pick("later")   end }},
            },
            tap_close_callback = function() pick("later", true) end,
        }
        UIManager:show(dialog)
    end
    next_one()
end

-- Batch deletion dialog. Surfaces one ButtonDialogTitle summarizing every
-- detected deletion, with Delete all / Restore all / Review each / Later.
-- Runs BEFORE conflict resolution; always surfaces (not gated by
-- silent_mode). Every exit path — including Later and dismissal (outside
-- tap / Back key, which routes to the Later path via tap_close_callback) —
-- calls on_done so the auto-chain orchestrator never stalls. The `handled`
-- flag guarantees the continuation runs exactly once; see
-- review_deletions_each for the dismissal/close mechanics.
local function resolve_deletions_interactive(plan_obj, deletions, stats, on_done)
    local dialog
    local handled = false
    local function choose(choice, dismissed)
        if handled then return end
        handled = true
        if not dismissed then UIManager:close(dialog) end
        if choice == "delete" or choice == "restore" then
            logger.info("webdav_autosync: deletion resolve choice="
                .. (choice == "delete" and "delete_all" or "restore_all"))
            for _, entry in ipairs(deletions) do
                apply_deletion(plan_obj, entry, choice, stats)
            end
            on_done()
        elseif choice == "review" then
            logger.info("webdav_autosync: deletion resolve choice=review")
            review_deletions_each(plan_obj, deletions, stats, on_done)
        else -- later (button or dismissal)
            logger.info("webdav_autosync: deletion resolve choice=later"
                .. (dismissed and " reason=dismissed" or ""))
            stats.deferred_deletions = stats.deferred_deletions + #deletions
            on_done()
        end
    end
    dialog = ButtonDialogTitle:new{
        title = build_deletions_title(deletions),
        buttons = {
            {{ text = _("Delete all"),  callback = function() choose("delete")  end }},
            {{ text = _("Restore all"), callback = function() choose("restore") end }},
            {{ text = _("Review each"), callback = function() choose("review")  end }},
            {{ text = _("Later"),       callback = function() choose("later")   end }},
        },
        tap_close_callback = function() choose("later", true) end,
    }
    UIManager:show(dialog)
end

-- ---------- conflict dialog chain ----------

-- Dismissing a conflict dialog (outside tap / Back key) counts as Skip for
-- the current conflict — same contract as the deletion dialogs: every exit
-- path must continue the chain or a stray tap would leave the sync lock
-- held and stall a chained sync. See review_deletions_each for the
-- dismissal/close mechanics (handled flag, who closes the widget).
local function resolve_conflicts_interactive(plan_obj, conflicts, stats, on_done)
    local idx = 1
    local function next_one()
        if idx > #conflicts then on_done() return end
        local c = conflicts[idx]
        local dialog
        local handled = false
        local function pick(action, dismissed)
            if handled then return end
            handled = true
            if not dismissed then UIManager:close(dialog) end
            idx = idx + 1
            logger.dbg("webdav_autosync: conflict resolution rel=" .. c.rel .. " choice=" .. action
                .. (dismissed and " reason=dismissed" or ""))
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
            tap_close_callback = function() pick("skip", true) end,
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

    local function do_conflicts()
        if #conflicts == 0 then
            finish()
            return
        end
        logger.info(string.format(
            "webdav_autosync: %s surfacing conflicts count=%d",
            plan_failure_label, #conflicts))
        resolve_conflicts_interactive(plan_obj, conflicts, stats, finish)
    end

    -- Deletions run before conflicts (action loop → deletions → conflicts →
    -- summary). Filter out any entry touching the currently open document
    -- first — those re-surface next sync.
    local deletions = filter_open_document_deletions(
        plan_obj.actions.deletions or {}, plan_obj.local_folder, opts.open_document_path)
    if #deletions == 0 then
        do_conflicts()
        return
    end

    local local_gone, remote_gone = 0, 0
    for _, d in ipairs(deletions) do
        if d.kind == "local_gone" then local_gone = local_gone + 1
        else remote_gone = remote_gone + 1 end
    end
    logger.info(string.format(
        "webdav_autosync: deletions detected local_gone=%d remote_gone=%d",
        local_gone, remote_gone))
    resolve_deletions_interactive(plan_obj, deletions, stats, do_conflicts)
end

return {
    run_planned = run_planned,
    run_one_way = run_one_way,
    resolve_conflicts_interactive = resolve_conflicts_interactive,
    resolve_deletions_interactive = resolve_deletions_interactive,
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
