-- RLDescriptionText.lua
-- Resolves the <description> lines of one animal <visual> entry, for
-- RealisticLivestock_AnimalSystem:loadVisualData.
--
-- The base game converts each line with g_i18n:convertText(line, self.customEnvironment),
-- which falls back to the global table and otherwise returns the string "Missing '<key>'
-- in l10n_<lang>.xml". The animal system's environment is the map's during Phase 2, so an
-- RL key used by a map or pack XML (rl_descriptionCowReproduction, the RL bull/ram/boar
-- texts) is looked up in the map's table and the global table only, never in RL's own.
--
-- Lookup order for a "$l10n_<key>" line:
--   1. the environment the XML is loaded under (customEnv), its own texts only;
--   2. RL's environment, for a key RL's translation files define;
--   3. the global (base-game) texts;
--   4. otherwise the line is dropped and one warning names file, key and environment.
--
-- Engine behaviour this relies on (FS25 v1.23.1 dataS/scripts/I18N.lua 150-210, mods.lua 455):
-- I18N:hasText(key, env) and I18N:getText(key, env) both fall back to the global texts, and
-- a mod environment's `texts` table has `__index = <global texts>`, so neither call nor a plain
-- index answers "does this environment define the key". Steps 1-2 use rawget on the
-- environment's own table for that. Inside a mod, g_i18n is that mod's I18N (metatable
-- `__index = <global I18N>`), so the global instance is taken from the metatable.
--
-- Plain text lines are kept as they are. The global I18N behaviour is not changed.

RLDescriptionText = {}

local Log = RmLogging.getLogger("RLRM")
local modName = g_currentModName

local L10N_PREFIX = "$l10n_"

-- One warning per (file, key, environment) for the map load; FS25 re-sources mod files on
-- every load, so this starts empty each time.
local warned = {}


--- The game's global I18N instance (not this mod's g_i18n wrapper).
--- @return table|nil
function RLDescriptionText.getGlobalI18n()
    local i18n = g_i18n
    if i18n == nil then return nil end
    local mt = getmetatable(i18n)
    local parent = mt ~= nil and mt.__index or nil
    if type(parent) == "table" and parent.modEnvironments ~= nil and parent.texts ~= nil then
        return parent
    end
    return i18n
end


--- Whether environment `envName` itself defines `key` (no global fallback).
--- @return boolean
local function envDefines(i18n, envName, key)
    if envName == nil or i18n.modEnvironments == nil then return false end
    local env = i18n.modEnvironments[envName]
    return env ~= nil and type(env.texts) == "table" and rawget(env.texts, key) ~= nil
end


--- Text for `key`, or nil with the source that would have been used.
--- @param key string l10n key without the "$l10n_" prefix
--- @param customEnv string|nil environment the XML is loaded under
--- @return string|nil text
--- @return string|nil source "env" | "rl" | "global"
function RLDescriptionText.lookup(key, customEnv)
    local i18n = RLDescriptionText.getGlobalI18n()
    if i18n == nil then return nil, nil end

    if envDefines(i18n, customEnv, key) then
        return i18n:getText(key, customEnv), "env"
    end

    if customEnv ~= modName and envDefines(i18n, modName, key) then
        return i18n:getText(key, modName), "rl"
    end

    if rawget(i18n.texts, key) ~= nil and i18n:hasText(key) then
        return i18n:getText(key), "global"
    end

    return nil, nil
end


--- One description line as the player should see it.
--- @param line string raw XML value
--- @param customEnv string|nil
--- @param filename string|nil XML file, for the warning
--- @param descKey string|nil XML key of the line, for the warning
--- @return string|nil text nil when the key is defined nowhere
function RLDescriptionText.resolveLine(line, customEnv, filename, descKey)
    if line == nil then return nil end
    if string.sub(line, 1, #L10N_PREFIX) ~= L10N_PREFIX then return line end

    local key = string.sub(line, #L10N_PREFIX + 1)
    local text = RLDescriptionText.lookup(key, customEnv)
    if text ~= nil then return text end

    local id = string.format("%s|%s|%s", tostring(filename), key, tostring(customEnv))
    if not warned[id] then
        warned[id] = true
        Log:warning("description text missing: file='%s' entry='%s' key='%s' env='%s' rl='%s' language='%s'",
            tostring(filename), tostring(descKey), key, tostring(customEnv), tostring(modName),
            tostring(g_languageSuffix))
    end
    return nil
end


--- All <description> lines under `key`, resolved and joined as the base game joins them.
--- @param xmlFile table XMLFile
--- @param key string the <visual> entry's key
--- @param customEnv string|nil
--- @return string|nil description nil when the entry has no description lines
function RLDescriptionText.resolve(xmlFile, key, customEnv)
    local filename = xmlFile.filename
    local parts, seen = {}, 0
    xmlFile:iterate(key .. ".description", function(_, descKey)
        local line = xmlFile:getString(descKey)
        if line ~= nil then
            seen = seen + 1
            local text = RLDescriptionText.resolveLine(line, customEnv, filename, descKey)
            if text ~= nil then table.insert(parts, text) end
        end
    end)
    if seen == 0 then return nil end
    return table.concat(parts, " ")
end
