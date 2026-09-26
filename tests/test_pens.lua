-- Pen rules for Hof Bergmann's cattle husbandries (RLHusbandryProfiles).

g_currentModDirectory = REPO
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
RLMapBridge = { activeBridges = { { resolvedConfigPath = "mod_support/FS25_HofBergmann/v1.5/" } } }

local SUBS = {
    { name = "COW_HOLSTEIN", gender = "female", breed = "HOLSTEIN" },
    { name = "BULL_HOLSTEIN", gender = "male", breed = "HOLSTEIN" },
    { name = "COW_ANGUS", gender = "female", breed = "ANGUS" },
    { name = "BULL_ANGUS", gender = "male", breed = "ANGUS" },
    { name = "COW_HEREFORD", gender = "female", breed = "HEREFORD" },
    { name = "BULL_HEREFORD", gender = "male", breed = "HEREFORD" },
    { name = "COW_WATERBUFFALO", gender = "female", breed = "WATER_BUFFALO" },
    { name = "BULL_WATERBUFFALO", gender = "male", breed = "WATER_BUFFALO" },
    { name = "COW_HIGHLAND_CATTLE", gender = "female", breed = "COW_HIGHLAND_CATTLE" }, -- the map's, DLC off
    { name = "BULL", gender = "male", breed = "BULL" },                                 -- the map's bull
}
local BY_NAME, COW_TYPE = {}, { name = "COW", subTypes = {} }
for i, sub in ipairs(SUBS) do
    sub.subTypeIndex, sub.typeIndex, sub.reproductionMinAgeMonth = i, 1, 12
    BY_NAME[sub.name] = i
    COW_TYPE.subTypes[i] = i
end
g_currentMission = { animalSystem = {
    getSubTypeByIndex = function(_, i) return SUBS[i] end,
    getTypeByIndex = function(_, i) return i == 1 and COW_TYPE or nil end,
} }

loadMod("scripts/bridge/RLHusbandryProfiles.lua")

local function pen(path)
    return { configFileName = "/mods/FS25_HofBergmann/" .. path, spec_husbandryAnimals = { animalTypeIndex = 1 },
        getName = function() return path end }
end
local function cow(name, age, castrated)
    local sub = SUBS[BY_NAME[name]]
    return { subTypeIndex = sub.subTypeIndex, age = age, gender = sub.gender, isCastrated = castrated == true }
end
local function allowedNames(p)
    RLHusbandryProfiles.apply(p)
    local names = {}
    for i in pairs(p.spec_husbandryAnimals.subtypeFilterAllowedSubTypes or {}) do names[#names + 1] = SUBS[i].name end
    table.sort(names)
    return table.concat(names, " ")
end
local function allows(p, a) return (RLHusbandryProfiles.checkAnimal(p, a)) end

local config = RLHusbandryProfiles.getConfig()
local numProfiles = 0
for _ in pairs(config.profiles) do numProfiles = numProfiles + 1 end
check("config: shipped v1.5 husbandryProfiles.xml read (6 profiles, 14 buildings)",
    numProfiles == 6 and #config.husbandries == 14)

local igloo = pen("placeables/animalHusbandry/calfIglus/calfIglu03.xml")
check("calf igloo: every subtype, both sexes, age <= 5",
    allowedNames(igloo) == "BULL BULL_ANGUS BULL_HEREFORD BULL_HOLSTEIN BULL_WATERBUFFALO COW_ANGUS COW_HEREFORD COW_HIGHLAND_CATTLE COW_HOLSTEIN COW_WATERBUFFALO"
    and igloo.spec_husbandryAnimals.subtypeFilterAgeMax == 5 and igloo.spec_husbandryAnimals.subtypeFilterAgeMin == nil)
check("calf igloo: 3-month Angus bull calf and 2-month steer calf in",
    allows(igloo, cow("BULL_ANGUS", 3)) and allows(igloo, cow("BULL_HOLSTEIN", 2, true)))
check("calf igloo: 6-month heifer out", not allows(igloo, cow("COW_HOLSTEIN", 6)))

local bullCalves = pen("placeables/animalHusbandry/bullStable/bullCalfZone01.xml")
check("bull calf box: males only, age <= 5",
    allowedNames(bullCalves) == "BULL BULL_ANGUS BULL_HEREFORD BULL_HOLSTEIN BULL_WATERBUFFALO"
    and allows(bullCalves, cow("BULL_HEREFORD", 4)) and allows(bullCalves, cow("BULL_ANGUS", 4, true))
    and not allows(bullCalves, cow("COW_ANGUS", 2)) and not allows(bullCalves, cow("BULL_ANGUS", 7)))

local bulls = pen("placeables/animalHusbandry/dairyFarm/bullStableDairyFarm.xml")
check("bull barn: every breed's intact bull from 6 months, the map's BULL too",
    allowedNames(bulls) == "BULL BULL_ANGUS BULL_HEREFORD BULL_HOLSTEIN BULL_WATERBUFFALO"
    and allows(bulls, cow("BULL_ANGUS", 30)) and allows(bulls, cow("BULL", 20)))
check("bull barn: no steers, no 5-month bull, no cows",
    not allows(bulls, cow("BULL_ANGUS", 30, true)) and not allows(bulls, cow("BULL_ANGUS", 5))
    and not allows(bulls, cow("COW_HOLSTEIN", 30)))

local dairy = pen("placeables/animalHusbandry/cowHusbandryOldFarm/cowHusbandryOldFarm.xml")
check("dairy barn: Holstein cows only (Swiss Brown not in this test's subtypes), from 6 months",
    allowedNames(dairy) == "COW_HOLSTEIN" and dairy.spec_husbandryAnimals.subtypeFilterAgeMin == 6)
check("dairy barn: 24-month Holstein in; Angus cow, Holstein bull and 3-month heifer out",
    allows(dairy, cow("COW_HOLSTEIN", 24)) and not allows(dairy, cow("COW_ANGUS", 24))
    and not allows(dairy, cow("BULL_HOLSTEIN", 24)) and not allows(dairy, cow("COW_HOLSTEIN", 3)))

local mixed = pen("placeables/animalHusbandry/cowHusbandryFarm02/cowHusbandryFarm02.xml")
check("mixed barn: cows, steers and young bulls from 6 months; mature bulls and calves out",
    allows(mixed, cow("COW_HEREFORD", 30)) and allows(mixed, cow("BULL_HEREFORD", 40, true))
    and allows(mixed, cow("BULL_ANGUS", 11)) and not allows(mixed, cow("BULL_ANGUS", 12))
    and not allows(mixed, cow("COW_ANGUS", 3)))

local pasture = pen("placeables/constructibles/constructible_cowPasture.xml")
check("pasture: calves, cows, steers and bulls under 12 months; not a 12-month intact bull",
    allows(pasture, cow("BULL_ANGUS", 1)) and allows(pasture, cow("COW_HEREFORD", 50))
    and allows(pasture, cow("BULL_HOLSTEIN", 30, true)) and allows(pasture, cow("BULL_ANGUS", 11))
    and not allows(pasture, cow("BULL_ANGUS", 12)))
local ok, reason, detail = RLHusbandryProfiles.checkAnimal(pasture, cow("BULL_ANGUS", 20))
check("pasture: refusal says pen rules, maturity in the detail",
    not ok and reason == RLHusbandryProfiles.REJECT_PEN_RULES and detail:find("mature at 12") ~= nil)

local buffalo = pen("placeables/animalHusbandry/cowPastures/cowPasture01.xml")
check("buffalo pasture: buffalo of both sexes only",
    allowedNames(buffalo) == "BULL_WATERBUFFALO COW_WATERBUFFALO"
    and allows(buffalo, cow("BULL_WATERBUFFALO", 4)) and not allows(buffalo, cow("COW_ANGUS", 30)))

local highland = pen("placeables/animalHusbandry/cowPastures/cowPasture02.xml")
check("highland pasture: the map's Highland cow when the DLC is off",
    allowedNames(highland) == "COW_HIGHLAND_CATTLE" and allows(highland, cow("COW_HIGHLAND_CATTLE", 40)))

local windows = { configFileName = "C:\\Mods\\FS25_HofBergmann\\placeables\\animalHusbandry\\calfIglus\\calfIglu01.xml",
    spec_husbandryAnimals = { animalTypeIndex = 1 } }
check("config path matched with backslashes and any case", RLHusbandryProfiles.getRule(windows) ~= nil
    and RLHusbandryProfiles.getRule(windows).name == "CALF")

local mapOnly = { configFileName = "/mods/FS25_HofBergmann/placeables/animalHusbandry/dairyFarm/modernCowStable1.xml",
    spec_husbandryAnimals = { animalTypeIndex = 1, subtypeFilterAgeMin = 12 } }
ok, reason = RLHusbandryProfiles.checkAnimal(mapOnly, cow("COW_HOLSTEIN", 6))
check("no profile: the map's own age window still holds for RLRM moves", not ok and reason == "AGE_TOO_YOUNG"
    and mapOnly.spec_husbandryAnimals.subtypeFilterAllowedSubTypes == nil)
check("no profile, no map filter: anything goes",
    allows({ configFileName = "/data/placeables/cowBarn.xml", spec_husbandryAnimals = { animalTypeIndex = 1 } }, cow("BULL_ANGUS", 40)))
check("not a husbandry: no opinion", allows({ configFileName = "x.xml" }, cow("BULL_ANGUS", 40)))

-- Move screen: a pen refusal is its own reason and takes no slot.
RLDiseaseSaleGate = { check = function() return true end }
loadMod("scripts/utils/RLMoveDestinationHelper.lua")
local result = RLMoveDestinationHelper.buildMoveValidationResult(
    { cow("BULL_ANGUS", 20), cow("COW_ANGUS", 20) }, { name = "p", placeable = pen("placeables/constructibles/constructible_cowPasture.xml"), freeSlots = 1, isEPP = false }, 1)
check("move screen: mature bull rejected as PEN_RULES, the cow takes the one slot",
    #result.valid == 1 and #result.rejected == 1 and result.rejected[1].reason == RLHusbandryProfiles.REJECT_PEN_RULES)
