--[[--
EPUB metadata extraction for KOReader plugin.
Extracts book title from EPUB files by reading the content.opf metadata.
--]]--

--- Sanitize a string to be safe for use as a filename
--- Removes or replaces characters that are invalid in filenames
local function sanitize_filename(str)
    if not str or str == "" then return nil end
    -- Remove leading/trailing whitespace
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    if str == "" then return nil end
    -- Replace invalid filename characters with underscores
    -- Windows: \ / : * ? " < > |
    -- Also remove control characters
    str = str:gsub('[\\/:*?"<>|%c]', "_")
    -- Collapse multiple spaces/underscores
    str = str:gsub("%s+", " ")
    str = str:gsub("_+", "_")
    -- Limit length to 200 characters (reasonable for most filesystems)
    if #str > 200 then
        str = str:sub(1, 200)
    end
    return str
end

--- Extract title from EPUB file
--- Returns sanitized title string, or nil if extraction fails
local function extract_title(epub_path)
    -- Check if file exists and is readable
    local f = io.open(epub_path, "rb")
    if not f then return nil end
    f:close()

    -- Try to use KOReader's zip library
    local ok_zip, zip = pcall(require, "ffi/zip")
    if not ok_zip then
        -- Fallback: try alternative zip library
        ok_zip, zip = pcall(require, "zip")
    end
    if not ok_zip or not zip then
        return nil
    end

    -- Open EPUB as ZIP archive
    local zfile = zip.open(epub_path)
    if not zfile then
        return nil
    end

    -- Read container.xml to find OPF file location
    local container_data = zfile:open("META-INF/container.xml")
    if not container_data then
        zfile:close()
        return nil
    end

    local container_xml = container_data:read("*a")
    container_data:close()

    -- Extract OPF path from container.xml
    -- Look for: <rootfile full-path="..." media-type="application/oebps-package+xml"/>
    local opf_path = container_xml:match('full%-path="([^"]+)"')
    if not opf_path then
        zfile:close()
        return nil
    end

    -- Read the OPF file
    local opf_data = zfile:open(opf_path)
    if not opf_data then
        zfile:close()
        return nil
    end

    local opf_xml = opf_data:read("*a")
    opf_data:close()
    zfile:close()

    -- Extract title from OPF metadata
    -- Look for: <dc:title>Book Title</dc:title>
    -- Handle various namespace prefixes (dc:, DC:, etc.)
    local title = opf_xml:match("<[dD][cC]:title[^>]*>([^<]+)</[dD][cC]:title>")

    if not title or title == "" then
        return nil
    end

    -- Decode HTML entities if present
    title = title:gsub("&amp;", "&")
    title = title:gsub("&lt;", "<")
    title = title:gsub("&gt;", ">")
    title = title:gsub("&quot;", '"')
    title = title:gsub("&apos;", "'")

    return sanitize_filename(title)
end

return {
    extract_title = extract_title,
    sanitize_filename = sanitize_filename,
}
