--[[--
WebDAV client for KOReader plugin.
Uses PROPFIND to list files and GET to download.
Matches KOReader's apps/cloudstorage/webdavapi.lua: socket.http, user/password in request table.
--]]--

local ltn12 = require("ltn12")
local socket = require("socket")
local http = require("socket.http")
local logger = require("logger")
local util = require("util")
-- Use KOReader's socketutil for timeouts (same as WebDavApi)
local socketutil
local ok_su = pcall(function() socketutil = require("socketutil") end)
if not ok_su or not socketutil then socketutil = false end

--- URL encode a string (encode spaces and special characters)
local function url_encode(str)
    if not str then return "" end
    str = str:gsub("([^%w%-%.%_%~%/:])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

local function normalize_url(url)
    if not url or type(url) ~= "string" then return "" end
    url = url:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/*$", "")
    if url == "" then return "" end
    if not url:match("^https?://") then
        url = "https://" .. url
    end
    return url
end

--- Return true if URL has a non-empty host (e.g. https://host/path -> true).
local function url_has_host(url)
    local u = normalize_url(url)
    if u == "" then return false end
    local host = u:match("^https?://([^/%s]+)")
    return host and host ~= ""
end

--- PROPFIND body. Mirrors KOReader's apps/cloudstorage/webdavapi.lua at
--- v2026.03 (prefixed namespace, explicit <prop> list rather than <allprop/>),
--- extended with getetag and getlastmodified because two-way sync needs them
--- for change detection. Some strict WebDAV servers (e.g. certain ownCloud
--- builds and some hosted providers) return 400 Bad Request on <allprop/>,
--- so the explicit list isn't optional.
local PROPFIND_BODY = '<?xml version="1.0"?>' ..
    '<a:propfind xmlns:a="DAV:">' ..
        '<a:prop>' ..
            '<a:resourcetype/>' ..
            '<a:getcontentlength/>' ..
            '<a:getetag/>' ..
            '<a:getlastmodified/>' ..
        '</a:prop>' ..
    '</a:propfind>'

local MONTHS = {
    Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
    Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12,
}

--- Parse RFC 1123 HTTP-date ("Wed, 31 Oct 2025 12:34:56 GMT") to epoch seconds.
--- Result is in local-time epoch via os.time(); it's a stable comparison key, not a UTC value.
local function parse_http_date(s)
    if not s or type(s) ~= "string" then return nil end
    local day, mon, year, hour, minute, sec = s:match("(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)")
    if not day then return nil end
    local m = MONTHS[mon]
    if not m then return nil end
    local ok, t = pcall(os.time, {
        year = tonumber(year), month = m, day = tonumber(day),
        hour = tonumber(hour), min = tonumber(minute), sec = tonumber(sec),
    })
    if ok then return t end
    return nil
end

--- Parse PROPFIND XML response into list of { href, href_raw, is_collection,
--- path, etag, mtime }. Accept any namespace prefix like WebDavApi
--- (<*:response>, <*:href>, etc.).
---
--- `href_raw` is the wire-format href as the server returned it (percent-encoded);
--- `href` and `path` are the percent-DECODED forms used for filename matching
--- and local-path comparisons. Any code that issues a follow-up HTTP request
--- (e.g. PROPFIND on a child collection during recursion) MUST use `href_raw`,
--- since handing a decoded URL with literal spaces or other reserved chars
--- to socket.http produces a malformed request line that strict servers
--- (Koofr's HTTP frontend, for instance) reject with 400 Bad Request.
local function parse_propfind_response(body)
    local list = {}
    for block in (body or ""):gmatch("<[^:]*:response[^>]*>.-</[^:]*:response>") do
        local href_raw = block:match("<[^:]*:href[^>]*>([^<]+)</[^:]*:href>")
        if href_raw then
            local href = href_raw:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
            local is_collection = not not block:match("<[^:]*:collection[^/]*/>")
            -- Normalize: remove server base and leading slashes for path
            local path = href
            if path:match("^https?://") then
                path = path:gsub("^https?://[^/]+", "")
            end
            path = path:gsub("^/+", ""):gsub("/+$", "")
            if path == "" then path = "/" end
            local etag = block:match("<[^:]*:getetag[^>]*>([^<]+)</[^:]*:getetag>")
            if etag then
                etag = etag:gsub('^%s*"', ''):gsub('"%s*$', '')
            end
            local lastmod = block:match("<[^:]*:getlastmodified[^>]*>([^<]+)</[^:]*:getlastmodified>")
            local mtime = parse_http_date(lastmod)
            table.insert(list, {
                href = href,
                href_raw = href_raw,
                is_collection = is_collection,
                path = path,
                etag = etag,
                mtime = mtime,
            })
        end
    end
    return list
end

--- List a WebDAV URL (single level). Returns list of { href, is_collection, path }.
--- Matches KOReader WebDavApi: trailing slash on URL, empty body, Content-Length, user/password, socketutil.
local function list_one(url, username, password, depth)
    url = normalize_url(url)
    if not url_has_host(url) then
        return nil, nil, "host or service not provided, or not known"
    end
    -- WebDavApi: "URL *must* have a trailing /" for PROPFIND on collection
    if url:sub(-1) ~= "/" then
        url = url .. "/"
    end
    depth = depth or "1"
    local body = {}
    local request = {
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml",
            ["Depth"] = depth,
            ["Content-Length"] = #PROPFIND_BODY,
        },
        source = ltn12.source.string(PROPFIND_BODY),
        sink = ltn12.sink.table(body),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    logger.dbg("webdav_autosync: PROPFIND url=" .. url .. " depth=" .. tostring(depth))
    if socketutil and socketutil.set_timeout then
        socketutil:set_timeout()
    end
    local code, _, status = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    local body_str = table.concat(body)
    if type(code) ~= "number" or code < 200 or code > 299 then
        logger.dbg("webdav_autosync: PROPFIND url=" .. url .. " status=" .. tostring(code))
        return nil, code or status, body_str or tostring(status)
    end
    local list = parse_propfind_response(body_str)
    logger.dbg("webdav_autosync: PROPFIND url=" .. url .. " status=" .. tostring(code) .. " entries=" .. tostring(#list))
    return list, code
end

--- Fetch a single resource's WebDAV properties (Depth: 0). Returns the first
--- entry from parse_propfind_response, or nil, code/error.
--- Used after a PUT upload to re-read the server's canonical etag/mtime so
--- the cache matches what the next PROPFIND will return (avoids "I just
--- uploaded but now mtime changed → redownload" loops on servers that don't
--- echo a useful ETag from PUT).
local function get_props(url, username, password)
    url = normalize_url(url)
    if not url_has_host(url) then
        return nil, "host or service not provided, or not known"
    end
    -- Encode internally like download_file / upload_file / mkcol do — caller
    -- passes a decoded URL (e.g. build_remote_url output, or an action's
    -- remote_url). Only list_one keeps the encoded-URL contract because
    -- list_all's recursion feeds it pre-encoded `href_raw`. Pre-v1.5.4 the
    -- missing encode here meant the post-PUT property re-fetch silently
    -- 400'd on any filename containing spaces or other reserved chars; the
    -- cache then carried `etag_from_put` but no `remote_mtime`.
    url = url_encode(url)
    local body = {}
    local request = {
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml",
            ["Depth"] = "0",
            ["Content-Length"] = #PROPFIND_BODY,
        },
        source = ltn12.source.string(PROPFIND_BODY),
        sink = ltn12.sink.table(body),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    logger.dbg("webdav_autosync: PROPFIND url=" .. url .. " depth=0")
    if socketutil and socketutil.set_timeout then
        socketutil:set_timeout()
    end
    local code, _, status = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    if type(code) ~= "number" or code < 200 or code > 299 then
        logger.dbg("webdav_autosync: PROPFIND url=" .. url .. " depth=0 status=" .. tostring(code))
        return nil, code or status
    end
    local list = parse_propfind_response(table.concat(body))
    logger.dbg("webdav_autosync: PROPFIND url=" .. url .. " depth=0 status=" .. tostring(code) .. " entries=" .. tostring(#list))
    return list[1]
end

--- Hosts that returned a hard refusal to PROPFIND Depth: infinity (4xx/5xx)
--- during this KOReader process. Subsequent list_all calls for those hosts
--- skip straight to the recursive Depth: 1 fallback so we don't pay a failed
--- request per sync. Keyed by `https://host[:port]` so multi-server users
--- don't lose the fast path on a permissive server because a strict one
--- refused once. Cleared at process restart, which is fine: server config
--- changes are rare, and a stale memo only costs the recursive walk we'd
--- have done anyway pre-v1.7.0.
local infinity_unsupported = {}

--- Collect all file URLs under base_url. Returns flat list of
--- { href, href_raw, is_collection, path, href_full } for all resources.
--- `href_full` is the absolute decoded URL (compatible with existing
--- download_file/upload_file consumers, which re-encode via url_encode).
---
--- Fast path: one PROPFIND with `Depth: infinity` returns the entire
--- subtree in a single round trip. On a library with N book directories
--- and N sidecar directories that's 1 request instead of ~2N+1, dominating
--- planning time on Resume / startup. Falls back to the legacy recursive
--- Depth: 1 walk when the server refuses (some hosted providers return
--- 403, 507 Insufficient Storage, or 501 Not Implemented; we don't try
--- to enumerate them — any 4xx/5xx triggers fallback and is memoed).
--- The recursion itself uses the raw (percent-encoded) form as the request
--- URL so strict servers don't 400 on paths containing spaces or other
--- reserved chars.
local function list_all(base_url, username, password)
    base_url = normalize_url(base_url)
    local base_domain = base_url:match("^(https?://[^/]+)") or ""

    if base_domain ~= "" and not infinity_unsupported[base_domain] then
        local list, code, err = list_one(base_url, username, password, "infinity")
        if list then
            -- Same self-skip key derivation as the recursive path: the
            -- request URL's own entry must not be re-emitted as a child.
            local req_path = base_url:gsub("^https?://[^/]+", ""):gsub("^/+", ""):gsub("/+$", "")
            req_path = req_path:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
            local all = {}
            for _, e in ipairs(list) do
                local href_full = e.href
                if not href_full:match("^https?://") then
                    href_full = base_domain .. (href_full:gsub("^/+", "/"))
                end
                local e_path_norm = (e.path or ""):gsub("^/+", ""):gsub("/+$", "")
                if e_path_norm ~= req_path and e_path_norm ~= "" then
                    e.href_full = href_full
                    table.insert(all, e)
                end
            end
            logger.dbg("webdav_autosync: list_all depth=infinity entries=" .. tostring(#all))
            return all
        end
        if type(code) == "number" and code >= 400 and code < 600 then
            logger.info("webdav_autosync: list_all depth=infinity refused status=" .. tostring(code)
                .. " host=" .. base_domain .. " — falling back to recursive Depth: 1")
            infinity_unsupported[base_domain] = true
        else
            -- Non-HTTP failure (timeout, DNS, auth string from socket layer).
            -- Don't memo — the recursive fallback will likely hit the same
            -- error and surface it to the caller. Pre-v1.7.0 behavior.
            logger.dbg("webdav_autosync: list_all depth=infinity error code=" .. tostring(code)
                .. " err=" .. tostring(err) .. " — trying recursive")
        end
    end

    local all = {}
    local function recurse(url)
        local list, code, err = list_one(url, username, password, "1")
        if not list then
            return nil, code, err
        end
        -- Self-skip key: e.path is decoded, so decode the request URL's path
        -- the same way before comparing. Otherwise a recursive call (whose
        -- url is encoded) would never match its own decoded e.path entry,
        -- the parent would re-list itself, and infinite recursion would only
        -- be averted by an eventual server error.
        local url_path = url:gsub("^https?://[^/]+", ""):gsub("^/+", ""):gsub("/+$", "")
        url_path = url_path:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
        for _, e in ipairs(list) do
            local href_full = e.href
            if not href_full:match("^https?://") and base_domain ~= "" then
                href_full = base_domain .. (href_full:gsub("^/+", "/"))
            end
            local href_request = e.href_raw or e.href
            if not href_request:match("^https?://") and base_domain ~= "" then
                href_request = base_domain .. (href_request:gsub("^/+", "/"))
            end
            local e_path_norm = (e.path or ""):gsub("^/+", ""):gsub("/+$", "")
            if e_path_norm ~= url_path and e_path_norm ~= "" then
                e.href_full = href_full
                table.insert(all, e)
                if e.is_collection then
                    local ok, c, m = recurse(href_request)
                    if not ok then return nil, c, m end
                end
            end
        end
        return true
    end
    local ok, c, m = recurse(base_url)
    if not ok then return nil, c, m end
    return all
end

--- Download one file from WebDAV URL to local path. Creates parent dirs.
--- Returns true, or nil, error_message. Streams the response straight to
--- disk via ltn12.sink.file — books on a typical KOReader library can be
--- 50–500 MB and pre-v1.7.1 the response was buffered in a Lua table for
--- the entire download, OOMing on devices with limited RAM (Kindle/Kobo
--- often run with 256–512 MB total). Parent directories are created with
--- util.makePath (recursive); plain lfs.mkdir failed for nested sidecar
--- paths whose intermediate dirs hadn't been touched yet (fresh install,
--- or first time syncing into a new subfolder). Side effect of streaming:
--- a request that fails mid-transfer leaves a truncated file on disk,
--- where the old buffered approach would leave nothing — we delete it on
--- non-2xx so the next sync re-downloads cleanly rather than treating
--- the partial file as legitimate local content.
local function download_file(remote_url, local_path, username, password)
    local url = url_encode(normalize_url(remote_url))
    local dir = local_path:match("^(.+)/[^/]+$")
    if dir then
        local ok_mp, mp_err = util.makePath(dir)
        if not ok_mp then return nil, mp_err end
    end
    local f, ferr = io.open(local_path, "wb")
    if not f then return nil, ferr end
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.file(f), -- closes f on EOF/error
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    if socketutil and socketutil.set_timeout then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    end
    local code = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    logger.dbg("webdav_autosync: GET url=" .. url .. " status=" .. tostring(code))
    if type(code) ~= "number" or code ~= 200 then
        os.remove(local_path)
        return nil, "HTTP " .. tostring(code)
    end
    return true
end

--- Create a WebDAV collection (directory). Returns true on 201 (created)
--- or 405 (already exists). Returns nil, error_message otherwise.
local function mkcol(remote_url, username, password)
    local url = url_encode(normalize_url(remote_url))
    if url:sub(-1) ~= "/" then url = url .. "/" end
    local body = {}
    local request = {
        url = url,
        method = "MKCOL",
        sink = ltn12.sink.table(body),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    if socketutil and socketutil.set_timeout then
        socketutil:set_timeout()
    end
    local code = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    logger.dbg("webdav_autosync: MKCOL url=" .. url .. " status=" .. tostring(code))
    if type(code) == "number" and (code == 201 or code == 405) then
        return true
    end
    return nil, "HTTP " .. tostring(code)
end

--- Ensure every parent collection of `rel_path` exists under `server_url`.
--- Idempotent: existing collections (HTTP 405) are treated as success.
--- Returns true on success, or nil, error_message.
local function ensure_remote_dirs(server_url, rel_path, username, password)
    if not rel_path or rel_path == "" then return true end
    local parts = {}
    for segment in rel_path:gmatch("[^/]+") do
        table.insert(parts, segment)
    end
    if #parts < 2 then return true end -- no subdirectories to create
    local base = normalize_url(server_url):gsub("/+$", "")
    local accum = base
    for i = 1, #parts - 1 do
        accum = accum .. "/" .. parts[i]
        local ok, err = mkcol(accum, username, password)
        if not ok then return nil, err end
    end
    return true
end

--- Upload a local file to WebDAV via PUT. Returns true, etag_or_nil on success,
--- or nil, error_message on failure. Creates parent collections as needed.
--- Caller must pass an absolute local_path; every in-tree caller does
--- (the planner builds them as `local_folder .. "/" .. rel`, where
--- local_folder comes from the user's PathChooser pick which is always
--- absolute).
local function upload_file(remote_url, local_path, username, password)
    local f, ferr = io.open(local_path, "rb")
    if not f then return nil, ferr end
    local size = f:seek("end") or 0
    f:seek("set", 0)

    local url = url_encode(normalize_url(remote_url))
    local response_body = {}
    local request = {
        url = url,
        method = "PUT",
        headers = {
            ["Content-Length"] = tostring(size),
            ["Content-Type"] = "application/octet-stream",
        },
        source = ltn12.source.file(f),
        sink = ltn12.sink.table(response_body),
        user = (username and username ~= "") and username or nil,
        password = (password and password ~= "") and password or nil,
    }
    if socketutil and socketutil.set_timeout then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    end
    local _, code, headers = http.request(request)
    if socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    logger.dbg("webdav_autosync: PUT url=" .. url .. " size=" .. tostring(size) .. " status=" .. tostring(code))
    if type(code) ~= "number" or code < 200 or code > 299 then
        return nil, "HTTP " .. tostring(code)
    end
    local etag = headers and (headers.etag or headers.ETag)
    if etag then etag = etag:gsub('^%s*"', ''):gsub('"%s*$', '') end
    return true, etag
end

return {
    normalize_url = normalize_url,
    url_has_host = url_has_host,
    url_encode = url_encode,
    list_one = list_one,
    list_all = list_all,
    download_file = download_file,
    upload_file = upload_file,
    mkcol = mkcol,
    ensure_remote_dirs = ensure_remote_dirs,
    get_props = get_props,
    parse_http_date = parse_http_date,
}
