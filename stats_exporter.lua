-- stats_exporter.lua — cross-plugin play-session tracker
--
-- VERBATIM COPY of game-common/stats_exporter.lua. The two shared
-- libraries are mutually exclusive per plugin (a sudoku variant mounts
-- sudoku-common and never sees game-common), but both write the same
-- game_stats.lua, so the schema has to stay identical. The copies are
-- diffed by scripts/check_sudoku_common_drift.sh — edit game-common's
-- and re-copy, never edit this one alone.
--
-- Each plugin writes one record per session via plugin_base.lua (automatic).
-- Dashboard (and any other reader) calls StatsExporter:readAll().
--
-- Record schema per plugin:
--   sessions    (int)    — total number of play sessions
--   last_played (int)    — os.time() of the last session end
--   time_played (int)    — accumulated seconds across all sessions

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

-- Sessions used to be recorded under self.name, which ReaderUI/FileManager
-- rewrite to "reader<id>" / "filemanager<id>" right after a plugin is built
-- (see PluginBase:getPluginId). Every game's stats were therefore split in
-- two rows, neither of which matched its plugin id. Fold those rows back
-- into the plugin id, once per run.
local function mergeLegacyKeys(s)
    local data = s.data
    if not data then return end
    local merges = {}
    for key, rec in pairs(data) do
        local id = key:match("^reader(.+)$") or key:match("^filemanager(.+)$")
        if id and type(rec) == "table" and rec.sessions then
            merges[#merges + 1] = { key = key, id = id, rec = rec }
        end
    end
    -- Applied after the traversal: adding keys to a table being iterated
    -- with pairs() is undefined behaviour in Lua.
    for _, m in ipairs(merges) do
        local cur = data[m.id] or {}
        cur.sessions    = (cur.sessions or 0) + (m.rec.sessions or 0)
        cur.time_played = (cur.time_played or 0) + (m.rec.time_played or 0)
        cur.last_played = math.max(cur.last_played or 0, m.rec.last_played or 0)
        data[m.id] = cur
        data[m.key] = nil
    end
    if #merges > 0 then s:flush() end
end

local STATS_FILE  -- resolved lazily so DataStorage is ready
local migrated = false
local function open()
    if not STATS_FILE then
        STATS_FILE = DataStorage:getSettingsDir() .. "/game_stats.lua"
    end
    local s = LuaSettings:open(STATS_FILE)
    if not migrated then
        migrated = true
        mergeLegacyKeys(s)
    end
    return s
end

local StatsExporter = {}

-- Write (merge) data for one plugin.
function StatsExporter:record(plugin_name, data)
    local s = open()
    local existing = s:readSetting(plugin_name) or {}
    for k, v in pairs(data) do existing[k] = v end
    s:saveSetting(plugin_name, existing)
    s:flush()
end

-- Read one field (or the whole record) for a plugin.
-- Returns nil if no data exists yet.
function StatsExporter:get(plugin_name, key)
    local d = open():readSetting(plugin_name)
    if not d then return nil end
    return key and d[key] or d
end

-- Drop one plugin's record. Called from PluginBase:deletePluginSettings()
-- when KOReader deletes the plugin, so Dashboard stops listing a game that
-- is no longer installed.
function StatsExporter:remove(plugin_name)
    local s = open()
    s:delSetting(plugin_name)
    s:flush()
end

-- Return the full stats table (all plugins).
function StatsExporter:readAll()
    return open().data or {}
end

return StatsExporter
