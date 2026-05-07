--[[--
Configuration surface for the WebDAV Auto Sync plugin.

Pure functions. No UIManager, no network, no widget access. Owns:
  * Cooldown / settle bounds and the bounded readers that clamp them.
  * Prefixed get/save against G_reader_settings (every key here is
    `webdav_autosync_<name>`).
  * Master + per-event gating booleans.
  * Auto-trigger and close-trigger cooldown bookkeeping.
  * State-file accessors for the persistent cooldown timestamps and the
    `last_close_book_rel` carve-out (kept in
    <settings_dir>/webdav_autosync_state.lua under their own keys, alongside
    the per-file `files` table the planners read/write).

The state file is shared with sync.lua's planner cache. Both modules build the
same path from DataStorage and open it via LuaSettings; the keys are disjoint
(`files` vs the timestamp keys here), so concurrent open/flush is safe.
--]]--

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

local STATE_FILE_PATH = DataStorage:getSettingsDir() .. "/webdav_autosync_state.lua"

local DEFAULT_COOLDOWN = 300
local COOLDOWN_MIN = 0
local COOLDOWN_MAX = 1800
local COOLDOWN_STEP = 30

local DEFAULT_CLOSE_COOLDOWN = 30
local CLOSE_COOLDOWN_MIN = 0
local CLOSE_COOLDOWN_MAX = 600
local CLOSE_COOLDOWN_STEP = 10

-- Resume settle delay. Default 15 s matches KindlePowerD:checkUnexpectedWakeup
-- (frontend/device/kindle/powerd.lua@v2026.03 lines 258-269 — the canonical
-- "this was an unscheduled wake" classifier reads powerd state 15 s after
-- wakeup). 0 disables both the defer and the Kindle state gate; sync runs
-- inline on Resume (pre-1.7.8 behavior).
local DEFAULT_RESUME_SETTLE = 15
local RESUME_SETTLE_MIN = 0
local RESUME_SETTLE_MAX = 60
local RESUME_SETTLE_STEP = 5

local function bounded(value, lo, hi, default)
    if type(value) ~= "number" then return default end
    if value < lo then return lo end
    if value > hi then return hi end
    return value
end

local function get_cooldown()
    local v = G_reader_settings and G_reader_settings:readSetting("webdav_autosync_cooldown_seconds")
    return bounded(v, COOLDOWN_MIN, COOLDOWN_MAX, DEFAULT_COOLDOWN)
end

local function get_close_cooldown()
    local v = G_reader_settings and G_reader_settings:readSetting("webdav_autosync_close_cooldown_seconds")
    return bounded(v, CLOSE_COOLDOWN_MIN, CLOSE_COOLDOWN_MAX, DEFAULT_CLOSE_COOLDOWN)
end

local function get_resume_settle()
    local v = G_reader_settings and G_reader_settings:readSetting("webdav_autosync_resume_settle_seconds")
    return bounded(v, RESUME_SETTLE_MIN, RESUME_SETTLE_MAX, DEFAULT_RESUME_SETTLE)
end

local function get(key, default)
    if not G_reader_settings then return default end
    if not G_reader_settings:has("webdav_autosync_" .. key) then return default end
    return G_reader_settings:readSetting("webdav_autosync_" .. key)
end

local function save(key, value)
    if G_reader_settings then
        G_reader_settings:saveSetting("webdav_autosync_" .. key, value)
    end
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

-- State-file accessors. Open a fresh LuaSettings on every call; flush
-- immediately on write so cooldown timestamps survive abrupt termination.
-- The shared file format is documented in CLAUDE.md → "Trigger taxonomy
-- and cooldowns".
local function read_state(key)
    local s = LuaSettings:open(STATE_FILE_PATH)
    return s:readSetting(key)
end

local function write_state(updates)
    local s = LuaSettings:open(STATE_FILE_PATH)
    for k, v in pairs(updates) do
        s:saveSetting(k, v)
    end
    s:flush()
end

local function read_timestamp(key)
    local v = read_state(key)
    return (type(v) == "number") and v or 0
end

local function read_string(key)
    local v = read_state(key)
    return (type(v) == "string") and v or nil
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
    write_state({ last_auto_run_at = os.time() })
end

local function mark_close_run(book_rel)
    write_state({
        last_close_run_at = os.time(),
        last_close_book_rel = book_rel,
    })
end

return {
    DEFAULT_COOLDOWN = DEFAULT_COOLDOWN,
    COOLDOWN_MIN = COOLDOWN_MIN,
    COOLDOWN_MAX = COOLDOWN_MAX,
    COOLDOWN_STEP = COOLDOWN_STEP,
    DEFAULT_CLOSE_COOLDOWN = DEFAULT_CLOSE_COOLDOWN,
    CLOSE_COOLDOWN_MIN = CLOSE_COOLDOWN_MIN,
    CLOSE_COOLDOWN_MAX = CLOSE_COOLDOWN_MAX,
    CLOSE_COOLDOWN_STEP = CLOSE_COOLDOWN_STEP,
    DEFAULT_RESUME_SETTLE = DEFAULT_RESUME_SETTLE,
    RESUME_SETTLE_MIN = RESUME_SETTLE_MIN,
    RESUME_SETTLE_MAX = RESUME_SETTLE_MAX,
    RESUME_SETTLE_STEP = RESUME_SETTLE_STEP,
    get_cooldown = get_cooldown,
    get_close_cooldown = get_close_cooldown,
    get_resume_settle = get_resume_settle,
    get = get,
    save = save,
    is_master_on = is_master_on,
    event_enabled = event_enabled,
    read_state = read_state,
    write_state = write_state,
    should_run_auto = should_run_auto,
    should_run_close = should_run_close,
    mark_auto_run = mark_auto_run,
    mark_close_run = mark_close_run,
}
