-- Pen rules for Hof Bergmann's cattle husbandries (RLHusbandryProfiles), checked against the map's
-- own filter (HusbandrySubtypeFilter.lua, which wraps AnimalBuyEvent.validate) when the map script
-- is at hand: set RLRM_HB_FILTER to its path, or keep the r3 evidence copy next to the repo. The
-- map script is not part of this repository; without it the same cases run against RLRM's mirror
-- of the map check (RLHusbandryProfiles.checkMapFilter), which the [HB] checks prove equal to it.

g_currentModDirectory = REPO
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
RLMapBridge = { activeBridges = { { resolvedConfigPath = "mod_support/FS25_HofBergmann/v1.5/" } } }

-- Every log record, so the RLPEN lines can be read back (RLPEN_DUMP=path appends them as log lines).
RECORDS = {}
local emit = RLPenLog.emit
RLPenLog.emit = function(kind, data, warn)
    local line = emit(kind, data, warn)
    RECORDS[#RECORDS + 1] = { kind = kind, data = data, line = line, warn = warn == true }
    DUMP(line)
    return line
end
local function records(kind)
    local list = {}
    for _, r in ipairs(RECORDS) do if r.kind == kind then list[#list + 1] = r end end
    return list
end

-- Cattle subtypes as RLRM registers them on Hof Bergmann (the map's own BULL included), with the
-- visual stages of RLRM's animals.xml (0, 6, 12, 18 months).
local SUBS = {
    { name = "COW_HOLSTEIN", gender = "female", breed = "HOLSTEIN" },
    { name = "BULL_HOLSTEIN", gender = "male", breed = "HOLSTEIN" },
    { name = "COW_SWISS_BROWN", gender = "female", breed = "SWISS_BROWN" },
    { name = "BULL_SWISS_BROWN", gender = "male", breed = "SWISS_BROWN" },
    { name = "COW_ANGUS", gender = "female", breed = "ANGUS" },
    { name = "BULL_ANGUS", gender = "male", breed = "ANGUS" },
    { name = "COW_LIMOUSIN", gender = "female", breed = "LIMOUSIN" },
    { name = "BULL_LIMOUSIN", gender = "male", breed = "LIMOUSIN" },
    { name = "COW_HEREFORD", gender = "female", breed = "HEREFORD" },
    { name = "BULL_HEREFORD", gender = "male", breed = "HEREFORD" },
    { name = "COW_WATERBUFFALO", gender = "female", breed = "WATER_BUFFALO" },
    { name = "BULL_WATERBUFFALO", gender = "male", breed = "WATER_BUFFALO" },
    { name = "COW_HIGHLAND_CATTLE", gender = "female", breed = "COW_HIGHLAND_CATTLE" }, -- the map's, DLC off
    { name = "BULL", gender = "male", breed = "BULL" },                                 -- the map's bull
    -- FS25_CowBreedsRLRM: its six dairy breeds' cows, a dairy bull, and two of its beef/dual breeds
    { name = "COW_REDHOLSTEIN_PACK", gender = "female", breed = "REDHOLSTEIN_PACK" },
    { name = "COW_AYRSHIRE_PACK", gender = "female", breed = "AYRSHIRE_PACK" },
    { name = "COW_JERSEY_PACK", gender = "female", breed = "JERSEY_PACK" },
    { name = "COW_GUERNSEY_PACK", gender = "female", breed = "GUERNSEY_PACK" },
    { name = "COW_KERRY_PACK", gender = "female", breed = "KERRY_PACK" },
    { name = "COW_SHORTHORNMILKERS_PACK", gender = "female", breed = "SHORTHORNMILKERS_PACK" },
    { name = "BULL_JERSEY_PACK", gender = "male", breed = "JERSEY_PACK" },
    { name = "COW_CHAROLAIS_PACK", gender = "female", breed = "CHAROLAIS_PACK" },
    { name = "COW_SIMMENTAL_PACK", gender = "female", breed = "SIMMENTAL_PACK" },
}
local VISUALS = { { minAge = 0, visualAnimalIndex = 5 }, { minAge = 6, visualAnimalIndex = 9 },
    { minAge = 12, visualAnimalIndex = 1 }, { minAge = 18, visualAnimalIndex = 1 } }
local BY_NAME, COW_TYPE = {}, { name = "COW", subTypes = {} }
for i, sub in ipairs(SUBS) do
    sub.subTypeIndex, sub.typeIndex, sub.reproductionMinAgeMonth, sub.visuals = i, 1, 12, VISUALS
    BY_NAME[sub.name] = i
    COW_TYPE.subTypes[i] = i
end
g_currentMission = { animalSystem = {
    getSubTypeByIndex = function(_, i) return SUBS[i] end,
    getSubTypeByName = function(_, n) return SUBS[BY_NAME[n]] end,
    getTypeByIndex = function(_, i) return i == 1 and COW_TYPE or nil end,
    getVisualByAge = function(_, i, age)
        local found
        for _, v in ipairs(SUBS[i].visuals) do if age >= v.minAge then found = v end end
        return found
    end,
} }
g_i18n = { getText = function(_, key) return key end }

-- The base game's buy check stands in for capacity, farm and money: it answers what the test sets.
BASE_BUY_ERROR = nil
AnimalBuyEvent = { BUY_ERROR_ANIMAL_NOT_SUPPORTED = 4, BUY_ERROR_NOT_ENOUGH_SPACE = 5, BUY_ERROR_NOT_ENOUGH_MONEY = 6,
    validate = function() return BASE_BUY_ERROR end }
AnimalMoveEvent = { MOVE_ERROR_ANIMAL_NOT_SUPPORTED = 3, validate = function() return nil end }
PlaceableHusbandryAnimals = {}

-- The map's script, loaded as the game does (before RLRM).
local hbPath = os.getenv("RLRM_HB_FILTER")
    or (REPO .. "../FS25_日志驱动测试_2026-10-07/r3/evidence/ENV03_buy_blocked/HusbandrySubtypeFilter.lua")
local hbChunk = loadfile(hbPath)
local HB = hbChunk ~= nil
if HB then
    Logging = { info = function() end, warning = function() end }
    XMLValueType = { STRING = 1, INT = 2 }
    hbChunk()
end
check(HB and "[HB] map filter loaded from " .. hbPath or "map filter not found - cases run on RLRM's mirror only", true)

loadMod("scripts/bridge/RLHusbandryProfiles.lua")
RLDiseaseSaleGate = { check = function() return true end }
loadMod("scripts/utils/RLMoveDestinationHelper.lua")

-- A pen as the map loads it: its XML attributes through the map's onLoad (when present), then
-- RLRM's profile on top (Placeable.finalizePlacement).
local MAP = {
    igloo = { "placeables/animalHusbandry/calfIglus/calfIglu01.xml", "Calf igloo 01",
        { subtype = "COW_SWISS_BROWN COW_HOLSTEIN COW_LIMOUSIN COW_ANGUS", ageMonthMax = 5 }, 1 },
    boxA = { "placeables/animalHusbandry/bullStable/bullCalfZone01.xml", "Calf rearing box A (bulls)",
        { subtype = "BULL", ageMonthMax = 5 }, 3 },
    boxB = { "placeables/animalHusbandry/bullStable/bullCalfZone02.xml", "Calf rearing box B (bulls)",
        { subtype = "BULL", ageMonthMax = 5 }, 3 },
    bulls = { "placeables/animalHusbandry/bullStable/bullStable.xml", "Bull barn", { subtype = "BULL", ageMonthMin = 6 }, 6 },
    dairy = { "placeables/animalHusbandry/cowHusbandryOldFarm/cowHusbandryOldFarm.xml", "Cow barn (farm)",
        { subtype = "COW_SWISS_BROWN COW_HOLSTEIN COW_LIMOUSIN COW_ANGUS" }, 30 },
    mixed = { "placeables/animalHusbandry/cowHusbandryFarm02/cowHusbandryFarm02.xml", "Cow barn with pasture (farm 2)",
        { subtype = "COW_SWISS_BROWN COW_HOLSTEIN COW_LIMOUSIN COW_ANGUS" }, 5 },
    pasture = { "placeables/constructibles/constructible_cowPasture.xml", "Cow pasture (buildable)", {}, 20 },
    mapOnly = { "placeables/animalHusbandry/someMapBarn.xml", "Map barn without a profile", { ageMonthMin = 6 }, 10 },
}

local function pen(key, farmId)
    local def = MAP[key]
    local p = { configFileName = "/mods/FS25_HofBergmann/" .. def[1], spec_husbandryAnimals = { animalTypeIndex = 1 },
        animals = {}, maxAnimals = def[4], farmId = farmId or 1 }
    function p:getName() return def[2] end
    function p:getOwnerFarmId() return self.farmId end
    function p:getNumOfAnimals() return #self.animals end
    function p:getMaxNumOfAnimals() return self.maxAnimals end
    function p:getNumOfFreeAnimalSlots() return self.maxAnimals - #self.animals end
    function p:getSupportsAnimalSubType(i)
        local allowed = self.spec_husbandryAnimals.subtypeFilterAllowedSubTypes
        return allowed == nil or allowed[i] == true
    end
    p.spec_husbandryAnimals.clusterSystem = { getClusters = function() return p.animals end }
    if HB then
        local attrs = {}
        for name, value in pairs(def[3]) do attrs["placeable.husbandry.animals#" .. name] = value end
        p.xmlFile = { getValue = function(_, k) return attrs[k] end }
        PlaceableHusbandryAnimals.onLoad(p)
    else
        local spec = p.spec_husbandryAnimals
        spec.subtypeFilterAgeMin, spec.subtypeFilterAgeMax = def[3].ageMonthMin, def[3].ageMonthMax
    end
    RLHusbandryProfiles.apply(p)
    return p
end

local function cow(name, age, castrated)
    local sub = SUBS[BY_NAME[name]]
    return { subTypeIndex = sub.subTypeIndex, age = age, gender = sub.gender, isCastrated = castrated == true,
        farmId = 1, uniqueId = name .. "-" .. age .. (castrated and "s" or ""), birthday = { country = 1 } }
end

--- What the map's buy check says (the real one, else the mirror).
local function mapAllows(p, animal)
    if HB then return AnimalBuyEvent.validate(p, animal.subTypeIndex, animal.age, 1, 0, 0, 1) == nil end
    return (RLHusbandryProfiles.checkMapFilter(p, animal.subTypeIndex, animal.age))
end

--- The server's buy decision, as AnimalBuyEvent:run takes it: the (map-wrapped) validate, then the pen rules.
local function serverBuy(p, animal)
    local errorCode
    if HB then errorCode = AnimalBuyEvent.validate(p, animal.subTypeIndex, animal.age, 1, 0, 0, 1)
    elseif RLHusbandryProfiles.checkMapFilter(p, animal.subTypeIndex, animal.age) then errorCode = BASE_BUY_ERROR
    else errorCode = AnimalBuyEvent.BUY_ERROR_ANIMAL_NOT_SUPPORTED end
    if errorCode == nil and not RLHusbandryProfiles.checkAnimal(p, animal) then errorCode = AnimalBuyEvent.BUY_ERROR_ANIMAL_NOT_SUPPORTED end
    return errorCode
end

local function allows(p, animal) return (RLHusbandryProfiles.checkAnimal(p, animal)) end

--- Accepted by every layer: the pen rules and the map's buy check (the GUI only shows these).
local function accepts(p, animal) return allows(p, animal) and serverBuy(p, animal) == nil end

local function acceptsAges(p, name, ages, castrated)
    for _, age in ipairs(ages) do if not accepts(p, cow(name, age, castrated)) then return false, age end end
    return true
end
local function refusesAges(p, name, ages, castrated)
    for _, age in ipairs(ages) do
        local a = cow(name, age, castrated)
        if allows(p, a) or serverBuy(p, a) == nil then return false, age end
    end
    return true
end

local function allowedNames(p)
    local names = {}
    for i in pairs(p.spec_husbandryAnimals.subtypeFilterAllowedSubTypes or {}) do names[#names + 1] = SUBS[i].name end
    table.sort(names)
    return table.concat(names, " ")
end

-- Config ---------------------------------------------------------------------------------------

local config = RLHusbandryProfiles.getConfig()
local numProfiles = 0
for _ in pairs(config.profiles) do numProfiles = numProfiles + 1 end
check("config: shipped v1.5 husbandryProfiles.xml read (6 profiles, 14 buildings)",
    numProfiles == 6 and #config.husbandries == 14)
check("config: igloo NURSERY 0-1, boxes GROUP_CALF 0-5 (both rearing), MIXED from 3, DAIRY/BULL from 6",
    config.profiles.NURSERY.maxAge == 1 and config.profiles.NURSERY.rearing
    and config.profiles.GROUP_CALF.maxAge == 5 and config.profiles.GROUP_CALF.rearing and config.profiles.GROUP_CALF.female
    and config.profiles.MIXED.minAge == 3 and config.profiles.DAIRY.minAge == 6 and config.profiles.BULL.minAge == 6
    and not config.profiles.DAIRY.rearing)

-- The ENV-03 refusal and its fix ------------------------------------------------------------------

if HB then
    -- The map's own reading of "min 6, no max": the next visual stage (12) is the cap.
    local old = pen("bulls")
    old.spec_husbandryAnimals.subtypeFilterAgeMax = nil
    check("[HB] reproduced: min 6 with a nil max refuses 12/13/17/24/30-month bulls (next visual stage 12)",
        not mapAllows(old, cow("BULL_ANGUS", 12)) and not mapAllows(old, cow("BULL_ANGUS", 13))
        and not mapAllows(old, cow("BULL", 17)) and not mapAllows(old, cow("BULL_ANGUS", 24))
        and not mapAllows(old, cow("BULL_ANGUS", 30)) and mapAllows(old, cow("BULL_ANGUS", 11)))
    local mixedOld = pen("mixed")
    mixedOld.spec_husbandryAnimals.subtypeFilterAgeMax = nil
    check("[HB] the same cap would have hit MIXED from 3 at 6 months",
        mapAllows(mixedOld, cow("COW_ANGUS", 5)) and not mapAllows(mixedOld, cow("COW_ANGUS", 6)))
end

local bulls = pen("bulls")
check("bull barn: open maximum written to the map (no next-visual-stage cap)",
    bulls.spec_husbandryAnimals.subtypeFilterAgeMin == 6
    and bulls.spec_husbandryAnimals.subtypeFilterAgeMax == RLHusbandryProfiles.OPEN_MAX_AGE)
check("bull barn: 5 refused; 6, 11, 12, 13, 17, 24, 30 accepted by the map and the pen rules",
    refusesAges(bulls, "BULL_ANGUS", { 5 }) and acceptsAges(bulls, "BULL_ANGUS", { 6, 11, 12, 13, 17, 24, 30 })
    and acceptsAges(bulls, "BULL", { 13, 17 }) and acceptsAges(bulls, "BULL_HOLSTEIN", { 13 }))
check("bull barn: cows and steers refused at any age",
    refusesAges(bulls, "COW_HOLSTEIN", { 6, 24 }) and refusesAges(bulls, "BULL_ANGUS", { 6, 30 }, true))
check("bull barn: every breed's intact bull, the map's BULL too",
    allowedNames(bulls) == "BULL BULL_ANGUS BULL_HEREFORD BULL_HOLSTEIN BULL_JERSEY_PACK BULL_LIMOUSIN BULL_SWISS_BROWN BULL_WATERBUFFALO")

local dairy = pen("dairy")
check("dairy barn: dairy-breed cows only (Holstein, Swiss Brown and the Cow Breeds pack's six)",
    allowedNames(dairy) == "COW_AYRSHIRE_PACK COW_GUERNSEY_PACK COW_HOLSTEIN COW_JERSEY_PACK COW_KERRY_PACK"
        .. " COW_REDHOLSTEIN_PACK COW_SHORTHORNMILKERS_PACK COW_SWISS_BROWN")
check("dairy barn: pack dairy cows from 6 accepted by the map and the pen rules; 5 refused",
    acceptsAges(dairy, "COW_JERSEY_PACK", { 6, 24, 60 }) and acceptsAges(dairy, "COW_REDHOLSTEIN_PACK", { 24 })
    and acceptsAges(dairy, "COW_AYRSHIRE_PACK", { 24 }) and acceptsAges(dairy, "COW_GUERNSEY_PACK", { 24 })
    and acceptsAges(dairy, "COW_KERRY_PACK", { 24 }) and acceptsAges(dairy, "COW_SHORTHORNMILKERS_PACK", { 24 })
    and refusesAges(dairy, "COW_JERSEY_PACK", { 5 }))
check("dairy barn: pack beef cows (Charolais, Simmental) and a pack dairy bull refused",
    refusesAges(dairy, "COW_CHAROLAIS_PACK", { 24 }) and refusesAges(dairy, "COW_SIMMENTAL_PACK", { 24 })
    and refusesAges(dairy, "BULL_JERSEY_PACK", { 24 }) and refusesAges(dairy, "BULL_JERSEY_PACK", { 24 }, true))
check("dairy barn: Holstein / Swiss Brown from 6 (6, 12, 24, 60) accepted; 5 refused",
    acceptsAges(dairy, "COW_HOLSTEIN", { 6, 12, 24, 60 }) and acceptsAges(dairy, "COW_SWISS_BROWN", { 24 })
    and refusesAges(dairy, "COW_HOLSTEIN", { 5 }))
check("dairy barn: Angus cow, Holstein bull and steer refused",
    refusesAges(dairy, "COW_ANGUS", { 24 }) and refusesAges(dairy, "BULL_HOLSTEIN", { 24 })
    and refusesAges(dairy, "BULL_HOLSTEIN", { 24 }, true))

-- Calf housing ---------------------------------------------------------------------------------------

local igloo = pen("igloo")
check("igloo: NURSERY, every cattle subtype, map max 1",
    igloo.spec_husbandryAnimals.subtypeFilterAgeMax == 1 and igloo.spec_husbandryAnimals.subtypeFilterAgeMin == nil
    and allowedNames(igloo) == "BULL BULL_ANGUS BULL_HEREFORD BULL_HOLSTEIN BULL_JERSEY_PACK BULL_LIMOUSIN BULL_SWISS_BROWN BULL_WATERBUFFALO COW_ANGUS COW_AYRSHIRE_PACK COW_CHAROLAIS_PACK COW_GUERNSEY_PACK COW_HEREFORD COW_HIGHLAND_CATTLE COW_HOLSTEIN COW_JERSEY_PACK COW_KERRY_PACK COW_LIMOUSIN COW_REDHOLSTEIN_PACK COW_SHORTHORNMILKERS_PACK COW_SIMMENTAL_PACK COW_SWISS_BROWN COW_WATERBUFFALO")
check("H01 igloo: 0 and 1 month accepted (heifer, bull calf, steer); 2 and 5 refused",
    acceptsAges(igloo, "COW_HOLSTEIN", { 0, 1 }) and acceptsAges(igloo, "BULL_ANGUS", { 0, 1 })
    and acceptsAges(igloo, "BULL_HOLSTEIN", { 1 }, true)
    and refusesAges(igloo, "COW_HOLSTEIN", { 2, 5 }) and refusesAges(igloo, "BULL_ANGUS", { 2, 5 }))

for _, key in ipairs({ "boxA", "boxB" }) do
    local box = pen(key)
    check("H02 " .. key .. ": GROUP_CALF, heifers, bull calves and steers 0-5 accepted",
        acceptsAges(box, "COW_HOLSTEIN", { 0, 2, 3, 5 }) and acceptsAges(box, "COW_ANGUS", { 2, 5 })
        and acceptsAges(box, "BULL_ANGUS", { 0, 2, 5 }) and acceptsAges(box, "BULL_HEREFORD", { 2, 5 }, true)
        and acceptsAges(box, "BULL", { 3 }))
    check("H02 " .. key .. ": 6 months and older refused (any sex)",
        refusesAges(box, "COW_HOLSTEIN", { 6, 12 }) and refusesAges(box, "BULL_ANGUS", { 6 })
        and refusesAges(box, "BULL_ANGUS", { 6 }, true))
end

local mixed = pen("mixed")
check("MIXED: weaned calves from 3 (2 refused, 3 accepted), cows and steers at any later age",
    refusesAges(mixed, "COW_ANGUS", { 2 }) and acceptsAges(mixed, "COW_ANGUS", { 3, 6, 12, 30 })
    and acceptsAges(mixed, "BULL_HEREFORD", { 3, 40 }, true))
check("MIXED: intact bulls until mature (3 and 11 accepted, 12 refused)",
    acceptsAges(mixed, "BULL_ANGUS", { 3, 11 }) and refusesAges(mixed, "BULL_ANGUS", { 12, 20 }))

local pasture = pen("pasture")
check("pasture: calves, cows, steers and bulls under 12 months; not a 12-month intact bull",
    acceptsAges(pasture, "BULL_ANGUS", { 1, 11 }) and acceptsAges(pasture, "COW_HEREFORD", { 50 })
    and acceptsAges(pasture, "BULL_HOLSTEIN", { 30 }, true) and refusesAges(pasture, "BULL_ANGUS", { 12 }))
local ok, reason, detail = RLHusbandryProfiles.checkAnimal(pasture, cow("BULL_ANGUS", 20))
check("pasture: refusal says pen rules, maturity in the detail",
    not ok and reason == RLHusbandryProfiles.REJECT_PEN_RULES and detail:find("mature at 12") ~= nil)

-- H03: a heifer's whole path on the home farm, and a pen for every 2-5-month animal ------------------

local home = { igloo = pen("igloo"), boxA = pen("boxA"), boxB = pen("boxB"), bulls = pen("bulls"), dairy = pen("dairy") }
local farm2 = { mixed = pen("mixed", 15), pasture = pen("pasture", 15) }
g_currentMission.placeableSystem = { placeables = { home.igloo, home.boxA, home.boxB, home.bulls, home.dairy, farm2.mixed, farm2.pasture } }

local function homeDestinations(animal)
    local names = {}
    for _, d in ipairs(RLMoveDestinationHelper.getValidDestinations(nil, 1, animal.subTypeIndex, { animal })) do
        local result = RLMoveDestinationHelper.buildMoveValidationResult({ animal }, d, 1)
        if #result.valid == 1 then names[#names + 1] = d.name end
    end
    return table.concat(names, " | ")
end
check("H03 Holstein heifer: 0-1 igloo + boxes, 2-5 boxes only, 6+ dairy barn only",
    homeDestinations(cow("COW_HOLSTEIN", 1)) == "Calf igloo 01 | Calf rearing box A (bulls) | Calf rearing box B (bulls)"
    and homeDestinations(cow("COW_HOLSTEIN", 2)) == "Calf rearing box A (bulls) | Calf rearing box B (bulls)"
    and homeDestinations(cow("COW_HOLSTEIN", 5)) == "Calf rearing box A (bulls) | Calf rearing box B (bulls)"
    and homeDestinations(cow("COW_HOLSTEIN", 6)) == "Cow barn (farm)")
local everyYoung = true
for _, name in ipairs({ "COW_HOLSTEIN", "COW_ANGUS", "COW_HEREFORD", "BULL_ANGUS", "BULL_HOLSTEIN", "BULL" }) do
    for age = 2, 5 do
        for _, castrated in ipairs({ false, true }) do
            local a = cow(name, age, castrated and SUBS[BY_NAME[name]].gender == "male")
            if not homeDestinations(a):find("Calf rearing box") then everyYoung = false end
        end
    end
end
check("H03 every 2-5-month heifer, bull calf and steer has a home-farm pen (the rearing boxes)", everyYoung)
check("H03 the farm 2 barn is not offered to farm 1 (owned by farm 15)",
    not homeDestinations(cow("COW_ANGUS", 4)):find("farm 2", 1, true))
check("H03 intact bull: box until 5, bull barn from 6",
    homeDestinations(cow("BULL_ANGUS", 5)) == "Calf rearing box A (bulls) | Calf rearing box B (bulls)"
    and homeDestinations(cow("BULL_ANGUS", 6)) == "Bull barn")

-- GUI = server ------------------------------------------------------------------------------------

local agree, disagreements = true, {}
for _, p in ipairs({ home.igloo, home.boxA, home.bulls, home.dairy, farm2.mixed, farm2.pasture }) do
    for _, sub in ipairs(SUBS) do
        for age = 0, 30 do
            for _, castrated in ipairs({ false, true }) do
                if not (castrated and sub.gender == "female") then
                    local a = cow(sub.name, age, castrated)
                    local gui = RLMoveDestinationHelper.acceptsAny(p, { a }) and p:getSupportsAnimalSubType(a.subTypeIndex)
                    local server = serverBuy(p, a) == nil
                    if gui ~= server then agree = false; disagreements[#disagreements + 1] = p:getName() .. " " .. sub.name .. " " .. age end
                end
            end
        end
    end
end
check("H08 GUI destination list = server buy decision for every profiled pen, subtype, sex and age 0-30"
    .. (HB and " (real map check)" or ""), agree)

if HB then
    local same = true
    for _, p in ipairs({ home.igloo, home.boxA, home.bulls, home.dairy, farm2.mixed, farm2.pasture }) do
        for _, sub in ipairs(SUBS) do
            for age = 0, 30 do
                if mapAllows(p, cow(sub.name, age)) ~= (RLHusbandryProfiles.checkMapFilter(p, sub.subTypeIndex, age)) then same = false end
            end
        end
    end
    local raw = pen("mapOnly")
    for age = 0, 30 do
        if mapAllows(raw, cow("COW_HOLSTEIN", age)) ~= (RLHusbandryProfiles.checkMapFilter(raw, BY_NAME.COW_HOLSTEIN, age)) then same = false end
    end
    check("[HB] RLRM's mirror of the map check equals the map's own on every pen, subtype and age 0-30", same)
end

-- Pens without a profile, and the base game's own refusals ----------------------------------------

local mapOnly = pen("mapOnly")
ok, reason = RLHusbandryProfiles.checkAnimal(mapOnly, cow("COW_HOLSTEIN", 5))
check("no profile: the map's own age window still holds for RLRM moves", not ok and reason == "AGE_TOO_YOUNG"
    and mapOnly.spec_husbandryAnimals.subtypeFilterAllowedSubTypes == nil and mapOnly.spec_husbandryAnimals.subtypeFilterAgeMax == nil)
check("no profile: the map's native next-visual-stage cap is left alone (12-month cow refused by its buy check)",
    not mapAllows(mapOnly, cow("COW_HOLSTEIN", 12)) and mapAllows(mapOnly, cow("COW_HOLSTEIN", 6)))
check("no profile, no map filter: anything goes",
    allows({ configFileName = "/data/placeables/cowBarn.xml", spec_husbandryAnimals = { animalTypeIndex = 1 } }, cow("BULL_ANGUS", 40)))
check("not a husbandry: no opinion", allows({ configFileName = "x.xml" }, cow("BULL_ANGUS", 40)))
BASE_BUY_ERROR = AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_MONEY
check("base refusals pass through: not enough money stays NOT_ENOUGH_MONEY for an accepted bull",
    serverBuy(bulls, cow("BULL_ANGUS", 13)) == AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_MONEY)
BASE_BUY_ERROR = AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_SPACE
check("base refusals pass through: a full pen stays NOT_ENOUGH_SPACE",
    serverBuy(home.dairy, cow("COW_HOLSTEIN", 24)) == AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_SPACE)
BASE_BUY_ERROR = nil
check("pen refusal is the map's or the pen rules' NOT_SUPPORTED, never a pass",
    serverBuy(home.igloo, cow("COW_HOLSTEIN", 2)) == AnimalBuyEvent.BUY_ERROR_ANIMAL_NOT_SUPPORTED)

-- Idempotent apply, and the same state after a reload ----------------------------------------------

local function snapshot(p)
    local s = p.spec_husbandryAnimals
    return table.concat({ tostring(s.subtypeFilterAgeMin), tostring(s.subtypeFilterAgeMax), allowedNames(p) }, "/")
end
local again = pen("mixed")
local first = snapshot(again)
again.spec_husbandryAnimals.rlPenProfileApplied = false
RLHusbandryProfiles.apply(again)
RLHusbandryProfiles.apply(again)
check("apply is idempotent (forced re-apply and repeat give the same fields)", snapshot(again) == first)
check("a reloaded pen (map onLoad, then the profile) ends in the same fields", snapshot(pen("mixed")) == first
    and snapshot(pen("bulls")) == snapshot(bulls) and snapshot(pen("igloo")) == snapshot(igloo))

local windows = { configFileName = "C:\\Mods\\FS25_HofBergmann\\placeables\\animalHusbandry\\calfIglus\\calfIglu01.xml",
    spec_husbandryAnimals = { animalTypeIndex = 1 } }
check("config path matched with backslashes and any case", RLHusbandryProfiles.getRule(windows) ~= nil
    and RLHusbandryProfiles.getRule(windows).name == "NURSERY")

-- Records ----------------------------------------------------------------------------------------------

local applied
for _, r in ipairs(records("PROFILE_APPLIED")) do
    if r.data.pen.name == "Bull barn" then applied = r end
end
check("PROFILE_APPLIED: profile, source file, rule, map fields before/after and no next-visual cap after",
    applied ~= nil and applied.data.profile == "BULL" and applied.data.source == "mod_support/FS25_HofBergmann/v1.5/husbandryProfiles.xml"
    and applied.data.rule.minAge == 6 and applied.data.mapAfter.maxAge == "OPEN"
    and applied.data.mapAfter.nextVisualStageCap == false
    and (not HB or applied.data.mapBefore.nextVisualStageCap == true)
    and applied.line:find('^RLPEN {') ~= nil and applied.line:find('"kind":"PROFILE_APPLIED"', 1, true) ~= nil)

RECORDS = {}
RLHusbandryProfiles.logDecision("BUY_CHECK", home.igloo, cow("COW_HOLSTEIN", 2), { errorCode = 4 })
local rec = records("BUY_CHECK")[1]
check("BUY_CHECK: says the pen rules refused (age 2 > 1), with the map's own verdict beside it",
    rec ~= nil and rec.data.verdict.profile == "NURSERY" and rec.data.verdict.rlrm.ok == false
    and rec.data.verdict.rlrm.detail == "age 2 > 1" and rec.data.verdict.map.ok == false
    and rec.data.verdict.map.code == RLHusbandryProfiles.MAP_AGE_MAX and rec.data.animal.age == 2
    and rec.data.animal.key == "1 COW_HOLSTEIN-2 1" and rec.data.pen.name == "Calf igloo 01")

-- H05: outgrown residents stay; logged at load, told once when they cross the limit ---------------

local messages = {}
local function resident(name, age)
    local a = cow(name, age)
    a.addMessage = function(self, id, args) messages[#messages + 1] = { animal = self, id = id, args = args } end
    return a
end
local oldCalf = resident("COW_HOLSTEIN", 3)
home.igloo.animals = { oldCalf }
RECORDS = {}
local count = RLHusbandryProfiles.checkResidents(home.igloo, "LOAD")
local overage = records("OVERAGE_RESIDENT")
check("H05 load: a 3-month calf in an igloo stays, is logged OVERAGE_RESIDENT with the boxes as destinations, no message",
    count == 1 and #home.igloo.animals == 1 and home.igloo.animals[1] == oldCalf and #overage == 1
    and overage[1].warn and overage[1].data.trigger == "LOAD" and overage[1].data.maxAge == 1
    and #overage[1].data.destinations == 2 and overage[1].data.destinations[1].name == "Calf rearing box A (bulls)"
    and #messages == 0)
RECORDS = {}
RLHusbandryProfiles.checkResidents(home.igloo, "DAY")
check("H05 next day: still logged, not re-announced", #records("OVERAGE_RESIDENT") == 1
    and records("OVERAGE_RESIDENT")[1].warn == false and #messages == 0)

local growing = resident("BULL_ANGUS", 1)
home.igloo.animals = { growing }
RLHusbandryProfiles.checkResidents(home.igloo, "DAY")
check("H05 a 1-month calf is not outgrown", #messages == 0)
growing.age = 2
RLHusbandryProfiles.checkResidents(home.igloo, "DAY")
RLHusbandryProfiles.checkResidents(home.igloo, "DAY")
check("H05 at 2 months the owner is told once, with the pens that take it",
    #messages == 1 and messages[1].id == "PEN_OUTGROWN" and messages[1].args[1] == "Calf igloo 01"
    and messages[1].args[2] == 1 and messages[1].args[3] == "Calf rearing box A (bulls), Calf rearing box B (bulls)"
    and #home.igloo.animals == 1 and growing.age == 2)
home.boxA.animals = { resident("COW_ANGUS", 1), resident("COW_ANGUS", 1), resident("COW_ANGUS", 1) }
home.boxB.animals = { resident("COW_ANGUS", 1), resident("COW_ANGUS", 1), resident("COW_ANGUS", 1) }
local stuck = resident("COW_ANGUS", 2)
home.igloo.animals = { stuck }
messages = {}
RLHusbandryProfiles.checkResidents(home.igloo, "DAY")
check("H05 with both boxes full the message says no pen has room",
    #messages == 1 and messages[1].args[3] == "rl_ui_penOutgrownNoPen")
home.boxA.animals, home.boxB.animals, home.igloo.animals = {}, {}, {}
check("H05 a pen without maxAge has no outgrown animals", RLHusbandryProfiles.checkResidents(home.bulls, "DAY") == 0)

-- Move screen: a pen refusal is its own reason and takes no slot. --------------------------------

local result = RLMoveDestinationHelper.buildMoveValidationResult(
    { cow("BULL_ANGUS", 20), cow("COW_ANGUS", 20) }, { name = "p", placeable = pen("pasture"), freeSlots = 1, isEPP = false }, 1)
check("move screen: mature bull rejected as PEN_RULES, the cow takes the one slot",
    #result.valid == 1 and #result.rejected == 1 and result.rejected[1].reason == RLHusbandryProfiles.REJECT_PEN_RULES)

-- A record too long for the log line is replaced by a marker, never cut. ------------------------

RECORDS = {}
local long = {}
for i = 1, 1000 do long[i] = "x" .. i end
local line = RLPenLog.emit("PEN_REPORT", { pen = { name = "big" }, list = long })
check("RLPEN: an over-long record becomes a LINE_TOO_LONG marker naming the record and its length",
    #line <= RLPenLog.MAX_LINE and line:find('"kind":"LINE_TOO_LONG"', 1, true) ~= nil
    and line:find('"record":"PEN_REPORT"', 1, true) ~= nil)
