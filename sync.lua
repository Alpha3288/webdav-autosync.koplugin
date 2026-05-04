--[[--
Sync logic: list all files from WebDAV and download to local folder.
--]]--

local webdav = require("webdav")
local epub_metadata = require("epub_metadata")


--- File extensions KOReader supports (default when user leaves filter empty).
local KOREADER_DEFAULT_EXTENSIONS = {
    "epub", "pdf", "djvu", "xps", "cbt", "cbz", "cb7", "fb2", "pdb",
    "txt", "html", "htm", "rtf", "chm", "doc", "mobi", "zip", "md",
}

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

--- Run full sync: list all resources, download every file to local_folder.
--- local_folder: path on device (e.g. /mnt/onboard/books or relative path).
--- extensions_filter: optional string (e.g. "epub, pdf"); empty/nil = all KOReader formats.
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
        -- Relative path from base (strip base from e.path)
        local rel = e.path:gsub("^/+", "")
        if base ~= "" and rel:sub(1, #base) == base then
            rel = rel:sub(#base + 1):gsub("^/+", "")
        end
        local local_path = local_folder .. "/" .. rel

        -- Check if file already exists locally
        local file_exists = false
        local f = io.open(local_path, "r")
        if f then
            f:close()
            file_exists = true
        end

        if file_exists then
            count_skipped = count_skipped + 1
        else
            if progress_cb then progress_cb(i, #files, rel) end
            local ok, msg = webdav.download_file(remote_url, local_path, username, password)
            if ok then
                count_ok = count_ok + 1

                -- For EPUB files, try to rename based on metadata title
                local ext = local_path:match("%.([^%.]+)$")
                if ext and ext:lower() == "epub" then
                    local title = epub_metadata.extract_title(local_path)
                    if title and title ~= "" then
                        -- Build new path with title as filename
                        local dir = local_path:match("^(.+)/[^/]+$") or local_folder
                        local new_path = dir .. "/" .. title .. ".epub"

                        -- Rename file (this will overwrite if duplicate exists)
                        local rename_ok = os.rename(local_path, new_path)
                        if not rename_ok then
                            -- If rename fails, try using io operations
                            local old_f = io.open(local_path, "rb")
                            local new_f = io.open(new_path, "wb")
                            if old_f and new_f then
                                new_f:write(old_f:read("*a"))
                                old_f:close()
                                new_f:close()
                                os.remove(local_path)
                            end
                        end
                    end
                end
            else
                count_fail = count_fail + 1
                -- Get just the filename for cleaner error messages
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

return {
    run_sync = run_sync,
    KOREADER_DEFAULT_EXTENSIONS = KOREADER_DEFAULT_EXTENSIONS,
}
