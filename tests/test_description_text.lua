-- Animal descriptions are resolved where the raw <description> lines are loaded: the XML's
-- environment first, then RL's own texts, then the global texts. A key found nowhere is dropped
-- with one warning naming file, key, environment and language, never shown as "Missing ...".
-- Runs against the game's own I18N code (tests/fixtures/fs25_i18n.lua).

loadMod("tests/fixtures/fs25_i18n.lua")

local MOD, MAP = "FS25_RealisticLivestock", "FS25_TestMap"
g_currentModName = MOD
g_languageSuffix = "_en"

local function sourceOf(path)
    local handle = assert(io.open(REPO .. path, "r"))
    local text = handle:read("a")
    handle:close()
    return text
end

-- An XMLFile with one <visual> whose <description> lines are `lines`.
local function visualXml(lines, filename)
    return {
        filename = filename or "/maps/test/animals.xml",
        iterate = function(_, key, fn)
            for i, _ in ipairs(lines) do fn(i - 1, string.format("%s(%d)", key, i - 1)) end
        end,
        getString = function(_, key)
            local i = tonumber(key:match("%((%d+)%)$"))
            return i ~= nil and lines[i + 1] or nil
        end,
    }
end

local function setup()
    LOG = {}
    local global = FS25I18N.reset()
    global.texts.animal_descriptionCowFeed = "Base cow feed."
    global.texts.animal_descriptionBullFeed = "Base bull feed."
    FS25I18N.addMod(MAP, { animal_descriptionBullFeed = "Map bull feed.", map_ownDescription = "Map own text." })
    -- Inside the mod, g_i18n is the mod's own instance (mods.lua 455).
    g_i18n = FS25I18N.addMod(MOD, { animal_descriptionBullFeed = "RL bull feed.", rl_descriptionCowReproduction = "RL cow reproduction." })
    loadMod("scripts/utils/RLDescriptionText.lua")
end

local function warnings()
    local out = {}
    for _, line in ipairs(LOG) do if line:find("^warning: description text missing") then out[#out + 1] = line end end
    return out
end

setup()
check("global instance found through the mod's g_i18n", RLDescriptionText.getGlobalI18n() == FS25I18N.global)

-- Control: the base game's conversion under the map environment misses RL's key.
check("control: base convertText shows 'Missing' for an RL key under the map",
    FS25I18N.class.convertText(nil, "$l10n_rl_descriptionCowReproduction", MAP):find("^Missing") ~= nil)

local function resolve(lines, env, filename)
    return RLDescriptionText.resolve(visualXml(lines, filename), "animals.animal(0).subType(0).visuals.visual(0)", env)
end

check("map key under the map environment", resolve({ "$l10n_map_ownDescription" }, MAP) == "Map own text.")
check("map text wins over RL and global for a key the map defines",
    resolve({ "$l10n_animal_descriptionBullFeed" }, MAP) == "Map bull feed.")
check("RL key under the map environment comes from RL",
    resolve({ "$l10n_rl_descriptionCowReproduction" }, MAP) == "RL cow reproduction.")
check("base-game key under the map environment comes from the global texts",
    resolve({ "$l10n_animal_descriptionCowFeed" }, MAP) == "Base cow feed.")
check("RL key under RL's own environment (bundle and bridge phases)",
    resolve({ "$l10n_animal_descriptionBullFeed" }, MOD) == "RL bull feed.")
check("no environment (a base-game map): RL then global",
    resolve({ "$l10n_rl_descriptionCowReproduction", "$l10n_animal_descriptionCowFeed" }, nil)
        == "RL cow reproduction. Base cow feed.")
check("plain text kept as written", resolve({ "Just words.", "$l10n_animal_descriptionCowFeed" }, MAP)
    == "Just words. Base cow feed.")
check("no warning for lines that resolve", #warnings() == 0)

-- A key defined nowhere.
setup()
local text = resolve({ "$l10n_animal_descriptionCowFeed", "$l10n_animal_descriptionGhost", "$l10n_rl_descriptionCowReproduction" }, MAP, "/maps/hb/animals.xml")
check("missing line dropped, the rest joined", text == "Base cow feed. RL cow reproduction.")
check("result never carries 'Missing'", text:find("Missing", 1, true) == nil)
local w = warnings()
check("one warning for the missing key", #w == 1)
local first = w[1] or ""
check("warning names file, XML entry, key, environment and language",
    first:find("/maps/hb/animals.xml", 1, true) ~= nil
    and first:find("visual(0).description(1)", 1, true) ~= nil
    and first:find("key='animal_descriptionGhost'", 1, true) ~= nil
    and first:find("env='" .. MAP .. "'", 1, true) ~= nil
    and first:find("language='_en'", 1, true) ~= nil)
resolve({ "$l10n_animal_descriptionGhost" }, MAP, "/maps/hb/animals.xml")
check("the same file/key/environment warns once per load", #warnings() == 1)
resolve({ "$l10n_animal_descriptionGhost" }, MOD, "/maps/hb/animals.xml")
check("another environment warns again", #warnings() == 2)
check("an entry whose only line is missing gives an empty text, not 'Missing'",
    resolve({ "$l10n_animal_descriptionGhost" }, MAP, "/other.xml") == "")
check("an entry without description lines gives nil (base value kept)", resolve({}, MAP) == nil)

-- Global behaviour untouched: nothing written to any table.
check("global texts unchanged", FS25I18N.global.texts.rl_descriptionCowReproduction == nil)

-- Wiring.
local system = sourceOf("scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua")
local body = system:match("function RealisticLivestock_AnimalSystem:loadVisualData%(.-\nend\n") or ""
check("loadVisualData rebuilds store.description from the raw lines in self.customEnvironment",
    body:find("RLDescriptionText.resolve(xmlFile, key, self.customEnvironment)", 1, true) ~= nil
    and body:find("visualData.store.description = description", 1, true) ~= nil)
local main = sourceOf("scripts/main.lua")
local at = main:find('scripts/utils/RLDescriptionText.lua', 1, true)
check("main.lua sources RLDescriptionText before the animal system",
    at ~= nil and at < (main:find("scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua", 1, true) or 0))
