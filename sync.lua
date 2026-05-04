--[[--
Sync logic.

One-way mode (legacy `run_sync`): list remote, download files matching the
extension filter, skip files that already exist locally.

Two-way mode for book files (`plan`/`do_action`/`save_cache`): diff remote
tree, local folder, and a per-plugin cache to compute downloads, uploads,
and conflicts. Caller drives execution and conflict resolution; the cache
is updated after each successful action.

Progress mode (`plan_progress`): same machinery as two-way, but the indices
only contain `.sdr` sidecar files (reading position, bookmarks, highlights,
custom metadata, custom cover). Used by the close/suspend/resume/startup
event hooks in main.lua.

The cache lives at <settings_dir>/webdav_autosync_state.lua via LuaSettings,
keyed by relpath (file path under the download folder / under the server URL
base) -> { remote_etag, remote_mtime, local_mtime, local_size }. Book and
sidecar relpaths share the same table; their key spaces never collide.
--]]--

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local webdav = require("webdav")


--- File extensions KOReader supports (default when user leaves filter empty).
local KOREADER_DEFAULT_EXTENSIONS = {
    "epub", "pdf", "djvu", "xps", "cbt", "cbz", "cb7", "fb2", "pdb",
    "txt", "html", "htm", "rtf", "chm", "doc", "mobi", "zip", "md",
}

local function load_lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then return lfs end
    return require("lfs")
end

--- Parse extension filter string (comma/space separated) into lowercase set.
--- Returns nil when str is nil or "" (meaning: use default KOReader formats).
local function parse_extensions(str)
    if not str or str:match("^%s*$") then
        return nil
    end
    local set = {}
    for ext in str:gmatch("[^,%s]+") do
        ext = ext:lower():gsub("^%.", "")
        if ext ~= "" then
            set[ext] = true
        end
    end
    if next(set) == nil then
        return nil
    end
    return set
end

--- Check if path has an extension in the allowed set (or default KOReader set).
local function extension_allowed(path, extensions_set)
    local ext = path:match("%.(%w+)$")
    if not ext then return false end
    ext = ext:lower()
    if extensions_set then
        return extensions_set[ext] == true
    end
    for _, e in ipairs(KOREADER_DEFAULT_EXTENSIONS) do
        if e == ext then return true end
    end
    return false
end

--- Get base path from WebDAV URL (path part only, no trailing slash).
local function base_path_from_url(url)
    url = webdav.normalize_url(url)
    local path = url:match("^https?://[^/]+(.+)$") or ""
    path = path:gsub("^/+", ""):gsub("/+$", "")
    return path
end

--- Strip the server's base path prefix from a remote resource path.
local function rel_from_remote_path(path, base)
    local rel = (path or ""):gsub("^/+", "")
    if base ~= "" and rel:sub(1, #base) == base then
        rel = rel:sub(#base + 1):gsub("^/+", "")
    end
    return rel
end

--- Recursively collect local files under `folder`. Returns table keyed by
--- relpath -> { path = absolute, mtime = number, size = number }. The
--- predicate decides which entries to keep; it receives (entry_name, relpath).
local function walk_local(folder, predicate)
    local lfs = load_lfs()
    local out = {}
    local function recurse(dir, prefix)
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok or not iter then return end
        for entry in iter, state do
            if entry ~= "." and entry ~= ".." then
                local full = dir .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    local rel = prefix == "" and entry or (prefix .. "/" .. entry)
                    if attr.mode == "directory" then
                        recurse(full, rel)
                    elseif attr.mode == "file" and predicate(entry, rel) then
                        out[rel] = {
                            path = full,
                            mtime = attr.modification,
                            size = attr.size,
                        }
                    end
                end
            end
        end
    end
    recurse(folder:gsub("/+$", ""), "")
    return out
end

--- Honours the extension filter so we only consider files we'd ever sync as books.
local function walk_local_files(folder, extensions_set)
    return walk_local(folder, function(entry) return extension_allowed(entry, extensions_set) end)
end

--- True when any segment of `rel` is a `.sdr` directory; identifies sidecar
--- payload files (metadata.<ext>.lua, custom_metadata.lua, custom cover) that
--- live under `<book>.sdr/`.
local function is_sidecar_path(rel)
    for segment in rel:gmatch("[^/]+") do
        if segment:match("%.sdr$") then return true end
    end
    return false
end

--- Sidecar paths the plugin will actually sync. Excludes KOReader's `.old`
--- backup copies (e.g. `metadata.epub.lua.old`) — those are local
--- write-ahead snapshots, not progress state, and round-tripping them just
--- doubles every transfer for no benefit.
local function is_syncable_sidecar(rel)
    return is_sidecar_path(rel) and not rel:match("%.old$")
end

--- Collect every regular file inside any `*.sdr/` directory under `folder`,
--- minus `.old` backup files.
local function walk_local_sidecars(folder)
    return walk_local(folder, function(_, rel) return is_syncable_sidecar(rel) end)
end

local function open_cache()
    local path = DataStorage:getSettingsDir() .. "/webdav_autosync_state.lua"
    return LuaSettings:open(path)
end

local function load_cache_files(cache)
    local files = cache:readSetting("files")
    if type(files) ~= "table" then files = {} end
    return files
end

--- True when remote-side fingerprints differ from cache entry.
local function remote_changed(remote, cached)
    if not cached then return true end
    if remote.etag and cached.remote_etag and remote.etag ~= cached.remote_etag then
        return true
    end
    if remote.mtime and cached.remote_mtime and remote.mtime ~= cached.remote_mtime then
        return true
    end
    -- If we have no etag and no mtime we cannot tell; assume unchanged.
    if not remote.etag and not remote.mtime then return false end
    -- We have one signal that matches and the other absent: treat as unchanged.
    if (remote.etag and cached.remote_etag and remote.etag == cached.remote_etag)
            or (remote.mtime and cached.remote_mtime and remote.mtime == cached.remote_mtime) then
        return false
    end
    -- Cache lacks the signal we have: be conservative and treat as changed.
    return true
end

--- True when local-side fingerprints differ from cache entry.
local function local_changed(loc, cached)
    if not cached then return true end
    if loc.mtime ~= cached.local_mtime then return true end
    if loc.size ~= cached.local_size then return true end
    return false
end

local function build_remote_url(server_url, rel)
    local base = webdav.normalize_url(server_url):gsub("/+$", "")
    local path = rel:gsub("^/+", "")
    return base .. "/" .. path
end

local function update_cache_entry(cache_files, rel, remote, loc, etag_override)
    cache_files[rel] = {
        remote_etag = (etag_override ~= nil) and etag_override or (remote and remote.etag),
        remote_mtime = remote and remote.mtime or nil,
        local_mtime = loc and loc.mtime or nil,
        local_size = loc and loc.size or nil,
    }
end

--- Restat a local file after a successful download or upload so the cache
--- reflects what's actually on disk now.
local function stat_local(path)
    local lfs = load_lfs()
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    return { path = path, mtime = attr.modification, size = attr.size }
end

--- Run a one-way sync (legacy behaviour). Lists remote, downloads anything
--- matching the extension filter that doesn't already exist locally.
--- Returns: count_downloaded, count_skipped, error_message (nil on success).
local function run_sync(server_url, username, password, local_folder, progress_cb, extensions_filter)
    if not server_url or type(server_url) ~= "string" then
        return 0, 0, "Server URL is not set"
    end
    server_url = server_url:gsub("^%s+", ""):gsub("%s+$", "")
    if server_url == "" then
        return 0, 0, "Server URL is not set"
    end
    if not webdav.url_has_host(server_url) then
        return 0, 0, "Server URL has no host (e.g. use https://example.com/webdav)"
    end
    if not local_folder or local_folder == "" then
        return 0, 0, "Download folder is not set"
    end
    local_folder = local_folder:gsub("/+$", "")
    local list, code, err = webdav.list_all(server_url, username, password)
    if not list then
        return 0, 0, "List failed: " .. tostring(code) .. " " .. tostring(err)
    end
    local base = base_path_from_url(server_url)
    local extensions_set = parse_extensions(extensions_filter)
    local files = {}
    for _, e in ipairs(list) do
        if not e.is_collection and extension_allowed(e.path or "", extensions_set) then
            table.insert(files, e)
        end
    end
    local count_ok = 0
    local count_fail = 0
    local count_skipped = 0
    local failed_files = {}
    for i, e in ipairs(files) do
        local remote_url = e.href_full or e.href
        if not remote_url:match("^https?://") then
            remote_url = webdav.normalize_url(server_url):match("^(https?://[^/]+)") .. (remote_url:gsub("^/+", "/"))
        end
        local rel = rel_from_remote_path(e.path, base)
        local local_path = local_folder .. "/" .. rel

        local f = io.open(local_path, "r")
        if f then
            f:close()
            count_skipped = count_skipped + 1
        else
            if progress_cb then progress_cb(i, #files, rel) end
            local ok, msg = webdav.download_file(remote_url, local_path, username, password)
            if ok then
                count_ok = count_ok + 1
            else
                count_fail = count_fail + 1
                local filename = rel:match("([^/]+)$") or rel
                table.insert(failed_files, filename .. " (" .. tostring(msg) .. ")")
            end
        end
    end
    if (tonumber(count_fail) or 0) > 0 then
        local error_msg = tostring(count_fail) .. " file(s) failed:\n" .. table.concat(failed_files, "\n")
        return count_ok, count_fail, error_msg
    end
    return count_ok, count_skipped, nil
end

--- Diff remote, local, and cache indices into action lists. Used by both
--- `plan` (book-file two-way) and `plan_progress` (sidecar two-way) — they
--- only differ in which files they include in the indices. Returns the
--- actions table plus a flag indicating whether silent baselining touched
--- the cache (so the caller can flush).
local function diff_indices(remote_index, local_index, cache_files, server_url, local_folder)
    local actions = {
        to_download = {},
        to_upload = {},
        conflicts = {},
        skipped_unchanged = 0,
        skipped_remote_gone = 0,
        skipped_local_gone = 0,
        baselined = 0,
    }

    -- Union of relpaths across remote, local, and cache (so we notice tombstones).
    local seen = {}
    for rel in pairs(remote_index) do seen[rel] = true end
    for rel in pairs(local_index) do seen[rel] = true end
    for rel in pairs(cache_files) do seen[rel] = true end

    local cache_dirty = false

    for rel in pairs(seen) do
        local r = remote_index[rel]
        local l = local_index[rel]
        local c = cache_files[rel]
        local local_path = local_folder .. "/" .. rel

        if r and not l then
            if c then
                -- File was synced before and is now gone locally. No-deletion
                -- policy: don't re-download. Keep cache entry so we keep skipping.
                actions.skipped_local_gone = actions.skipped_local_gone + 1
            else
                table.insert(actions.to_download, {
                    rel = rel,
                    remote_url = r.href,
                    local_path = local_path,
                    remote = r,
                })
            end
        elseif l and not r then
            if c then
                -- File existed remotely, now gone. No-deletion: don't re-upload.
                actions.skipped_remote_gone = actions.skipped_remote_gone + 1
            else
                local remote_url = build_remote_url(server_url, rel)
                table.insert(actions.to_upload, {
                    rel = rel,
                    remote_url = remote_url,
                    local_path = l.path,
                    ["local"] = l,
                })
            end
        elseif r and l then
            if not c then
                -- First encounter: silently baseline (no transfer, no conflict).
                update_cache_entry(cache_files, rel, r, l)
                cache_dirty = true
                actions.baselined = actions.baselined + 1
            else
                local rc = remote_changed(r, c)
                local lc = local_changed(l, c)
                if rc and lc then
                    table.insert(actions.conflicts, {
                        rel = rel,
                        remote_url = r.href,
                        local_path = local_path,
                        remote = r,
                        ["local"] = l,
                    })
                elseif rc then
                    table.insert(actions.to_download, {
                        rel = rel,
                        remote_url = r.href,
                        local_path = local_path,
                        remote = r,
                    })
                elseif lc then
                    local remote_url = build_remote_url(server_url, rel)
                    table.insert(actions.to_upload, {
                        rel = rel,
                        remote_url = remote_url,
                        local_path = l.path,
                        ["local"] = l,
                    })
                else
                    actions.skipped_unchanged = actions.skipped_unchanged + 1
                end
            end
        end
        -- r and l both nil means a stale cache entry; we leave it (no harm).
    end

    return actions, cache_dirty
end

--- Build a remote-resource index from a list_all result. `keep` decides which
--- entries to include (called with the relpath). Returns table keyed by
--- relpath -> { href, etag, mtime }.
local function build_remote_index(list, server_url, keep)
    local base = base_path_from_url(server_url)
    local origin = webdav.normalize_url(server_url):match("^(https?://[^/]+)")
    local index = {}
    for _, e in ipairs(list) do
        if not e.is_collection then
            local rel = rel_from_remote_path(e.path or "", base)
            if rel ~= "" and keep(rel, e) then
                local href_full = e.href_full or e.href
                if not href_full:match("^https?://") then
                    href_full = origin .. (href_full:gsub("^/+", "/"))
                end
                index[rel] = {
                    href = href_full,
                    etag = e.etag,
                    mtime = e.mtime,
                }
            end
        end
    end
    return index
end

--- Validate inputs shared by plan / plan_progress. Returns local_folder
--- (trimmed) on success, or nil + error string.
local function validate_two_way_inputs(server_url, local_folder)
    if not server_url or server_url == "" then
        return nil, "Server URL is not set"
    end
    if not webdav.url_has_host(server_url) then
        return nil, "Server URL has no host (e.g. use https://example.com/webdav)"
    end
    if not local_folder or local_folder == "" then
        return nil, "Download folder is not set"
    end
    return local_folder:gsub("/+$", "")
end

--- Plan a two-way sync of book files (filtered by the extensions filter).
--- See diff_indices for the action taxonomy. Returns a plan table the caller
--- drives via do_action and save_cache, or nil + error message.
local function plan(server_url, username, password, local_folder, extensions_filter)
    local trimmed_folder, verr = validate_two_way_inputs(server_url, local_folder)
    if not trimmed_folder then return nil, verr end
    local_folder = trimmed_folder

    local list, code, err = webdav.list_all(server_url, username, password)
    if not list then
        return nil, "List failed: " .. tostring(code) .. " " .. tostring(err)
    end

    local extensions_set = parse_extensions(extensions_filter)
    local remote_index = build_remote_index(list, server_url, function(_, e)
        return extension_allowed(e.path or "", extensions_set)
    end)
    local local_index = walk_local_files(local_folder, extensions_set)

    local cache = open_cache()
    local cache_files = load_cache_files(cache)

    local actions, cache_dirty = diff_indices(remote_index, local_index, cache_files,
            server_url, local_folder)

    if cache_dirty then
        cache:saveSetting("files", cache_files)
        cache:flush()
    end

    return {
        server_url = server_url,
        username = username,
        password = password,
        local_folder = local_folder,
        cache = cache,
        cache_files = cache_files,
        actions = actions,
    }
end

--- Compute the `.sdr` directory relpath for a book file relpath. KOReader's
--- `doc` metadata-folder mode (the only mode this plugin supports) names the
--- sidecar directory by replacing the file's extension with `.sdr`:
---     Books/MyBook.epub  ->  Books/MyBook.sdr
--- A file with no extension keeps its name and gets `.sdr` appended.
local function sidecar_rel_for_book(book_rel)
    local stem = book_rel:gsub("%.[^/.]+$", "")
    return stem .. ".sdr"
end

--- Plan a scoped progress sync for a single book — one PROPFIND on
--- `<book>.sdr/`, one local walk under that directory. Used by the
--- CloseDocument trigger so closing a book costs one network request
--- instead of a full library walk. The shared `cache_files` table can
--- still hold relpaths from other books — they fall through diff_indices
--- with `r = nil, l = nil` and are left alone.
---
--- Returns the same plan-object shape as `plan_progress`, so the caller
--- consumes it via the same `do_action` / `save_cache` /
--- `resolveConflictsInteractive` machinery.
local function plan_progress_book(server_url, username, password, local_folder, book_rel)
    local trimmed_folder, verr = validate_two_way_inputs(server_url, local_folder)
    if not trimmed_folder then return nil, verr end
    local_folder = trimmed_folder

    if not book_rel or book_rel == "" then
        return nil, "book relpath missing"
    end

    local sdr_rel = sidecar_rel_for_book(book_rel)
    local sdr_url = build_remote_url(server_url, sdr_rel)

    -- Single PROPFIND, depth 1. 404 means "no remote sidecar yet" —
    -- treat as an empty remote so a fresh book's first close uploads
    -- via ensure_remote_dirs + PUT.
    local list, code, err = webdav.list_one(sdr_url, username, password, "1")
    if not list then
        if code == 404 then
            list = {}
        else
            return nil, "List failed: " .. tostring(code) .. " " .. tostring(err)
        end
    end

    local remote_index = build_remote_index(list, server_url, function(rel)
        return is_syncable_sidecar(rel)
    end)

    -- Walk only the sdr subdirectory locally; rewrite relpaths back to
    -- be relative to local_folder so cache keys match what
    -- plan_progress (full walk) writes.
    local local_index = {}
    local sub_files = walk_local(local_folder .. "/" .. sdr_rel, function() return true end)
    for sub_rel, info in pairs(sub_files) do
        local full_rel = sdr_rel .. "/" .. sub_rel
        if is_syncable_sidecar(full_rel) then
            local_index[full_rel] = info
        end
    end

    local cache = open_cache()
    local cache_files = load_cache_files(cache)

    local actions, cache_dirty = diff_indices(remote_index, local_index, cache_files,
            server_url, local_folder)

    if cache_dirty then
        cache:saveSetting("files", cache_files)
        cache:flush()
    end

    return {
        server_url = server_url,
        username = username,
        password = password,
        local_folder = local_folder,
        cache = cache,
        cache_files = cache_files,
        actions = actions,
    }
end

--- Plan a two-way sync of `.sdr` sidecar content (reading position, bookmarks,
--- highlights, custom metadata, custom cover). Same shape as `plan`; only the
--- file selection differs (sidecar paths, no extension filter). The cache is
--- shared with `plan` — sidecar relpaths and book-file relpaths are disjoint.
local function plan_progress(server_url, username, password, local_folder)
    local trimmed_folder, verr = validate_two_way_inputs(server_url, local_folder)
    if not trimmed_folder then return nil, verr end
    local_folder = trimmed_folder

    local list, code, err = webdav.list_all(server_url, username, password)
    if not list then
        return nil, "List failed: " .. tostring(code) .. " " .. tostring(err)
    end

    local remote_index = build_remote_index(list, server_url, function(rel)
        return is_syncable_sidecar(rel)
    end)
    local local_index = walk_local_sidecars(local_folder)

    local cache = open_cache()
    local cache_files = load_cache_files(cache)

    local actions, cache_dirty = diff_indices(remote_index, local_index, cache_files,
            server_url, local_folder)

    if cache_dirty then
        cache:saveSetting("files", cache_files)
        cache:flush()
    end

    return {
        server_url = server_url,
        username = username,
        password = password,
        local_folder = local_folder,
        cache = cache,
        cache_files = cache_files,
        actions = actions,
    }
end

--- Execute one planned action. `kind` is "download" or "upload". Updates
--- the in-memory cache; caller flushes via save_cache when done with a batch.
--- Returns true on success, or nil, error_message.
local function do_action(p, kind, action)
    if kind == "download" then
        local ok, msg = webdav.download_file(action.remote_url, action.local_path, p.username, p.password)
        if not ok then return nil, msg end
        local loc = stat_local(action.local_path)
        update_cache_entry(p.cache_files, action.rel, action.remote, loc)
        return true
    elseif kind == "upload" then
        -- Make sure parent collections exist on the server.
        local _, derr = webdav.ensure_remote_dirs(p.server_url, action.rel, p.username, p.password)
        if derr then return nil, derr end
        local ok, etag_from_put = webdav.upload_file(action.remote_url, action.local_path, p.username, p.password)
        if not ok then return nil, etag_from_put end
        -- Re-fetch props so cache reflects the server's post-PUT state. Without
        -- this, the next sync would see remote.mtime differ from cached
        -- remote_mtime and re-download the file we just uploaded.
        local props = webdav.get_props(action.remote_url, p.username, p.password)
        local remote_after = {
            etag = (props and props.etag) or etag_from_put,
            mtime = props and props.mtime,
        }
        local loc = stat_local(action.local_path) or action["local"]
        update_cache_entry(p.cache_files, action.rel, remote_after, loc)
        return true
    end
    return nil, "unknown action"
end

local function save_cache(p)
    if not p or not p.cache then return end
    p.cache:saveSetting("files", p.cache_files)
    p.cache:flush()
end

return {
    run_sync = run_sync,
    plan = plan,
    plan_progress = plan_progress,
    plan_progress_book = plan_progress_book,
    do_action = do_action,
    save_cache = save_cache,
    KOREADER_DEFAULT_EXTENSIONS = KOREADER_DEFAULT_EXTENSIONS,
}
