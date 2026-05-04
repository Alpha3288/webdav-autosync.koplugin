--[[--
WebDAV client for KOReader plugin.
Uses PROPFIND to list files and GET to download.
Matches KOReader's apps/cloudstorage/webdavapi.lua: socket.http, user/password in request table.
--]]--

local ltn12 = require("ltn12")
local socket = require("socket")
local http = require("socket.http")
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

--- PROPFIND body: use empty/minimal like KOReader WebDavApi (some servers expect it).
local PROPFIND_BODY = '<?xml version="1.0" encoding="utf-8"?><propfind xmlns="DAV:"><allprop/></propfind>'

--- Parse PROPFIND XML response into list of { href, is_collection, path }.
--- Accept any namespace prefix like WebDavApi (<*:response>, <*:href>, etc.).
local function parse_propfind_response(body)
    local list = {}
    for block in (body or ""):gmatch("<[^:]*:response[^>]*>.-</[^:]*:response>") do
        local href = block:match("<[^:]*:href[^>]*>([^<]+)</[^:]*:href>")
        if href then
            href = href:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
            local is_collection = not not block:match("<[^:]*:collection[^/]*/>")
            -- Normalize: remove server base and leading slashes for path
            local path = href
            if path:match("^https?://") then
                path = path:gsub("^https?://[^/]+", "")
            end
            path = path:gsub("^/+", ""):gsub("/+$", "")
            if path == "" then path = "/" end
            table.insert(list, {
                href = href,
                is_collection = is_collection,
                path = path,
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
    if socketutil and socketutil.set_timeout then
        socketutil:set_timeout()
    end
    local code, _, status = socket.skip(1, http.request(request))
    if socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    local body_str = table.concat(body)
    if type(code) ~= "number" or code < 200 or code > 299 then
        return nil, code or status, body_str or tostring(status)
    end
    return parse_propfind_response(body_str), code
end

--- Recursively collect all file URLs under base_url (directories traversed).
--- Returns flat list of { href, is_collection, path } for all resources.
local function list_all(base_url, username, password)
    base_url = normalize_url(base_url)
    local base_domain = base_url:match("^(https?://[^/]+)")
    local all = {}
    local function recurse(url)
        local list, code, err = list_one(url, username, password, "1")
        if not list then
            return nil, code, err
        end
        for _, e in ipairs(list) do
            local href_full = e.href
            if not href_full:match("^https?://") and base_domain then
                href_full = base_domain .. (href_full:gsub("^/+", "/"))
            end
            -- Skip the requested URL itself
            local url_path = url:gsub("^https?://[^/]+", ""):gsub("^/+", ""):gsub("/+$", "")
            local e_path_norm = (e.path or ""):gsub("^/+", ""):gsub("/+$", "")
            if e_path_norm ~= url_path and e_path_norm ~= "" then
                e.href_full = href_full
                table.insert(all, e)
                if e.is_collection then
                    local ok, c, m = recurse(href_full)
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
--- Returns true, or nil, error_message. Same request pattern as WebDavApi:downloadFile.
local function download_file(remote_url, local_path, username, password)
    local url = url_encode(normalize_url(remote_url))
    local body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(body),
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
    if type(code) ~= "number" or code ~= 200 then
        return nil, "HTTP " .. tostring(code)
    end
    -- Use path as-is if absolute, else relative to KOReader data dir
    local lpath = local_path
    if not lpath:match("^/") then
        local ok, DataStorage = pcall(require, "datastorage")
        if ok and DataStorage and DataStorage.getRealPath then
            lpath = DataStorage:getRealPath(local_path)
        end
    end
    local dir = lpath:match("^(.+)/[^/]+$")
    if dir then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok then lfs = require("lfs") end
        if lfs and lfs.mkdir then lfs.mkdir(dir) end
    end
    local f, err = io.open(lpath, "wb")
    if not f then return nil, err end
    for _, chunk in ipairs(body) do
        f:write(chunk)
    end
    f:close()
    return true
end

return {
    normalize_url = normalize_url,
    url_has_host = url_has_host,
    list_one = list_one,
    list_all = list_all,
    download_file = download_file,
}
