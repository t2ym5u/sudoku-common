-- module_guard.lua — a plugin never runs on shared modules older than its own.
--
-- Every plugin ships its own copy of its shared library in common/, but Lua
-- caches a module by name alone: one `package.loaded["screen_base"]` serves
-- every plugin on the device, and whichever plugin requires a name first
-- decides which copy all the others get. An outdated plugin still installed
-- (one retired from the catalogue, or simply never updated) can therefore
-- hand its ancient screen_base to every up-to-date game, which then crashes
-- on the first method its copy lacks ("attempt to call method 'getGutter'").
--
-- main.lua loads this file by path -- never through require, so no other
-- copy can stand in for it -- and brackets each stretch of code that may
-- require shared modules:
--
--   local guard = <this file>(_dir .. "common/", "game_common_version.lua")
--   guard.enter()   -- drop any outdated copy from package.loaded
--   ... require("plugin_base") etc. ...
--   guard.leave()   -- record the copies this plugin just loaded
--
-- once around main.lua's top level and once around each lazyrequire().
--
-- The registry, package.loaded["game_common_registry"], records for each
-- module name the copy a guard-aware plugin loaded:
--   registry[name] = { lib = "game-common", v = 1014000, mod = <the module> }
-- enter() keeps a cached module only when the registry vouches for that very
-- table (`mod`, so a slot overwritten since is not trusted) as coming from
-- the same library at this plugin's version or newer -- or, for a name listed
-- in the version file's `shared`, from the other library (stats_exporter is
-- a verbatim copy in both game-common and sudoku-common). Anything else is
-- dropped, so the next require loads this plugin's own copy: main.lua and
-- lazyrequire() put this plugin's directories first on package.path. A
-- module loaded by an old plugin, which knows nothing of the registry, is
-- never in it, so it is always replaced. Between guard-aware plugins the
-- newest copy wins whatever the load order: an older plugin keeps a newer
-- registered copy, a newer plugin replaces an older one.
--
-- Dropping a slot does not touch what is already running: a plugin that
-- required the old copy keeps its reference (and classes built on an old
-- PluginBase keep their metatables). That suits every shared module but one:
--
-- i18n holds the one translation table every plugin extends from its
-- main.lua at load time. A fresh copy would know none of the strings the
-- plugins loaded before it added, so it is replaced and refilled: the old
-- copy's table (the `S` upvalue of its extend(), found with debug.getupvalue;
-- every i18n.lua ever shipped, sudoku's included, has that shape) is merged
-- into the new one, the new copy's own entries winning so its shared strings
-- stay current. If the old table cannot be found the old copy is kept: its
-- API -- _(s), .lang(), .extend() -- has never changed.
--
-- The other stateful modules need nothing: games_menu keeps its list in the
-- menu item, not in the module; stats_exporter's one-shot legacy-key merge
-- is idempotent; party, seen_history, plugin_base and the rest hold no
-- module-level state.
--
-- Modules required later, outside a bracket (a function requiring one at
-- run time), are not registered; the next enter() reloads them from that
-- plugin's own common/. Harmless for these stateless modules.

local REGISTRY = "game_common_registry"

-- "1.14.0" -> 1014000; anything unreadable sorts first.
local function versionNumber(s)
    local a, b, c = tostring(s or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    if not a then return 0 end
    return tonumber(a) * 1000000 + tonumber(b) * 1000 + (tonumber(c) or 0)
end

-- The translation table an i18n copy's extend() closes over.
local function stringTable(mod)
    local fn = type(mod) == "table" and rawget(mod, "extend")
    if type(fn) ~= "function" or type(debug) ~= "table" or not debug.getupvalue then return nil end
    local first
    for i = 1, 32 do
        local name, v = debug.getupvalue(fn, i)
        if name == nil then break end
        if type(v) == "table" then
            if name == "S" then return v end
            first = first or v
        end
    end
    return first
end

local function noop() end
local NOOP = { enter = noop, leave = noop }

local function new(common_dir, version_file)
    local chunk = loadfile(common_dir .. version_file)
    local ok, info = pcall(chunk or error)
    if not (ok and type(info) == "table" and type(info.modules) == "table") then
        return NOOP
    end
    local lib, v = info.lib, versionNumber(info.version)
    local names, shared = info.modules, info.shared or {}
    local present
    local depth = 0 -- a lazyrequire() reached from inside another one

    local function registry()
        local r = package.loaded[REGISTRY]
        if type(r) ~= "table" then
            r = {}
            package.loaded[REGISTRY] = r
        end
        return r
    end

    local function upToDate(r, name, mod)
        local e = r[name]
        if type(e) ~= "table" or e.mod ~= mod then return false end
        if e.lib == lib then return (tonumber(e.v) or 0) >= v end
        return shared[name] == true
    end

    -- Swap an outdated i18n for this plugin's, carrying its strings over.
    local function replaceI18n(r, old)
        local old_S = stringTable(old)
        if not old_S then return end
        package.loaded.i18n = nil
        local ok_new, fresh = pcall(require, "i18n")
        if not (ok_new and type(fresh) == "table" and type(fresh.extend) == "function") then
            package.loaded.i18n = old
            return
        end
        local new_S = stringTable(fresh)
        if new_S and new_S ~= old_S then
            for k, entry in pairs(old_S) do
                if new_S[k] == nil then new_S[k] = entry end
            end
        elseif not new_S then
            fresh.extend(old_S)
        end
        r.i18n = { lib = lib, v = v, mod = fresh }
    end

    local guard = {}

    function guard.enter()
        depth = depth + 1
        if depth > 1 then return end
        local r = registry()
        present = {}
        for _, name in ipairs(names) do
            local mod = package.loaded[name]
            if mod ~= nil and not upToDate(r, name, mod) then
                if name == "i18n" then
                    replaceI18n(r, mod)
                else
                    -- The registry must not keep the dropped copy alive.
                    package.loaded[name], r[name] = nil, nil
                end
            end
            present[name] = package.loaded[name] ~= nil
        end
    end

    function guard.leave()
        if depth > 0 then depth = depth - 1 end
        if depth > 0 or not present then return end
        local r = registry()
        for _, name in ipairs(names) do
            local mod = package.loaded[name]
            if mod ~= nil and not present[name] then
                r[name] = { lib = lib, v = v, mod = mod }
            end
        end
        present = nil
    end

    return guard
end

return setmetatable({ new = new, versionNumber = versionNumber, stringTable = stringTable, REGISTRY = REGISTRY }, {
    __call = function(_, common_dir, version_file) return new(common_dir, version_file) end,
})
