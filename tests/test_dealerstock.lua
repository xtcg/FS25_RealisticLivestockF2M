-- Dealer stock (xml/dealerStock.xml, RLDealerStockPolicy, AnimalSystem:createNewSaleAnimal):
-- every dealer animal is generated for a purpose, at an age inside that purpose's half-open range,
-- its sex's absolute cap, the type's maxBuyAge and the buyable visuals, with a birth and pregnancy
-- history that fits; genetics never widen an age. Listings that outgrow their purpose are withdrawn.
-- Weight: no dealer animal is heavier than its own target weight (legacy weight rule).

XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

TYPES = { [1] = { name = "COW" }, [2] = { name = "PIG" }, [3] = { name = "SHEEP" }, [4] = { name = "HORSE" } }
g_currentMission = { animalSystem = { getTypeByIndex = function(_, i) return TYPES[i] end } }
RLConstants = { GENETICS_MIN = 0.25, GENETICS_MAX = 1.75 }
RmLogging.LOG_LEVEL = { ERROR = 1, WARNING = 2, INFO = 3, DEBUG = 4, TRACE = 5 }
local getLogger = RmLogging.getLogger
RmLogging.getLogger = function(...) local log = getLogger(...); log.level = 0; return log end

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animal/RLGeneticsDraw.lua")
loadMod("scripts/nutrition/RLCalfRearing.lua")
loadMod("scripts/dealer/RLDealerStockPolicy.lua")

local P = RLDealerStockPolicy
local R = P.REASON
local config = P.getConfig()

-- Lua 5.4's math.random raises on a fractional bound; the game's floors it (offspring genes).
local random = math.random
math.random = function(lo, hi)
    if lo == nil then return random() end
    if hi == nil then return random(math.floor(lo)) end
    return random(math.floor(lo), math.floor(hi))
end

local function visuals(...)
    local list = {}
    for _, v in ipairs({ ... }) do
        table.insert(list, { minAge = v[1], store = { canBeBought = v[2] } })
    end
    return list
end
local CATTLE_VISUALS = visuals({ 0, true }, { 6, true }, { 12, true }, { 18, true })

local function cattle(name, breed, gender)
    return { typeIndex = 1, name = name, breed = breed, gender = gender, visuals = CATTLE_VISUALS,
        supportsReproduction = gender == "female", reproductionMinAgeMonth = 12, reproductionDurationMonth = 10,
        minWeight = 40, targetWeight = gender == "female" and 670 or 1000, maxWeight = 1400 }
end
local holstein = cattle("COW_HOLSTEIN", "HOLSTEIN", "female")
local angusCow = cattle("COW_ANGUS", "ANGUS", "female")
local angusBull = cattle("BULL_ANGUS", "ANGUS", "male")
local highlandBull = cattle("BULL_HIGHLAND_CATTLE", "HIGHLAND", "male")
local highlandCow = cattle("COW_HIGHLAND_CATTLE", "HIGHLAND", "female")

local function ctxFor(subType, maxBuyAge)
    maxBuyAge = maxBuyAge or 72
    return { maxBuyAge = maxBuyAge, weaningMonth = RLCalfRearing.getWeaningMonthForSubType(subType),
        union = P.getBuyableAgeUnion(subType, maxBuyAge) }
end

local function describe(candidates)
    local parts = {}
    for _, c in ipairs(candidates) do
        local segs = {}
        for _, s in ipairs(c.segments) do table.insert(segs, s[1] .. "-" .. s[2]) end
        table.insert(parts, c.purpose.id .. "[" .. table.concat(segs, ",") .. "]")
    end
    return table.concat(parts, " ")
end

local function gapsOf(gaps)
    local parts = {}
    for _, g in ipairs(gaps) do table.insert(parts, g.purpose.id .. ":" .. g.reason) end
    return table.concat(parts, " ")
end


-- Config ---------------------------------------------------------------------------------------

check("config: version 1, 8 attempts, 8 profiles", config.version == 1 and config.maxAttempts == 8
    and config.profiles.CATTLE ~= nil and config.profiles.HORSE ~= nil and config.profiles.DUCK ~= nil)
local cattleProfile = config.profiles.CATTLE
check("config: cattle caps cows 48, bulls 36, slow bulls 42", cattleProfile.maxFemaleAge == 48
    and cattleProfile.maxMaleAge == 36 and cattleProfile.slowMaxMaleAge == 42 and cattleProfile.slowMaxFemaleAge == 48)
check("config: 11 cattle purposes (one id per sex)", #cattleProfile.purposes == 11)

local entry = P.getEntry(config, holstein, "COW")
check("entry: Holstein covered by CATTLE, ready-to-breed ratio 0.55, not slow",
    entry.status == P.COVERED and entry.profile.name == "CATTLE" and entry.breedingWeightRatio == 0.55 and not entry.slow)
check("entry: Highland slow, Angus no breeding weight", P.getEntry(config, highlandBull, "COW").slow
    and P.getEntry(config, angusCow, "COW").breedingWeightRatio == nil)
check("entry: Hof Bergmann's BULL is legacy", P.getEntry(config, { name = "BULL", gender = "male" }, "COW").status == P.LEGACY)
check("entry: alpaca, quail and cats are not covered",
    P.getEntry(config, { name = "ALPACA_WHITE", breed = "ALPACA" }, "ALPACA").status == P.NOT_COVERED
    and P.getEntry(config, { name = "TOMCAT", breed = "TOMCAT" }, "CAT").status == P.NOT_COVERED)
check("entry: ducks in the chicken type use the DUCK profile",
    P.getEntry(config, { name = "DUCK_MALE", breed = "DUCK", gender = "male" }, "CHICKEN").profile.name == "DUCK"
    and P.getEntry(config, { name = "CHICKEN", breed = "CHICKEN" }, "CHICKEN").profile.name == "CHICKEN")


-- Ages per purpose -------------------------------------------------------------------------------

local candidates, gaps = P.getCandidates(entry, holstein, ctxFor(holstein))
check("Holstein cows: " .. describe(candidates), describe(candidates)
    == "CALF_WEANED[4-7] HEIFER_REPLACEMENT[6-17] HEIFER_READY[15-23] HEIFER_IN_CALF[18-29] COW_FIRST[24-35] COW_YOUNG[30-47]")
check("Holstein cows: unweaned calves off (" .. gapsOf(gaps) .. ")", gapsOf(gaps) == "CALF_MILK:DISABLED")

candidates, gaps = P.getCandidates(P.getEntry(config, angusCow, "COW"), angusCow, ctxFor(angusCow))
check("Angus cows: not offered ready to breed without a breeding weight (" .. gapsOf(gaps) .. ")",
    gapsOf(gaps) == "CALF_MILK:DISABLED HEIFER_READY:NO_BREEDING_WEIGHT")

candidates = P.getCandidates(P.getEntry(config, angusBull, "COW"), angusBull, ctxFor(angusBull))
check("Angus bulls: " .. describe(candidates), describe(candidates) == "CALF_WEANED[4-7] FEEDER[6-17] BULL_YOUNG[12-29]")
candidates = P.getCandidates(P.getEntry(config, highlandBull, "COW"), highlandBull, ctxFor(highlandBull))
check("Highland bulls (slow): " .. describe(candidates), describe(candidates) == "CALF_WEANED[4-7] FEEDER[8-23] BULL_YOUNG[18-35]")
candidates = P.getCandidates(P.getEntry(config, highlandCow, "COW"), highlandCow, ctxFor(highlandCow))
check("Highland cows (slow): " .. describe(candidates), describe(candidates)
    == "CALF_WEANED[4-7] HEIFER_REPLACEMENT[6-17] HEIFER_IN_CALF[24-35] COW_FIRST[30-41] COW_YOUNG[36-47]")

-- A visual stage that cannot be bought leaves a hole; none buyable leaves nothing.
local holed = cattle("COW_HOLSTEIN", "HOLSTEIN", "female")
holed.visuals = visuals({ 0, true }, { 6, false }, { 12, true }, { 18, true })
candidates = P.getCandidates(entry, holed, ctxFor(holed))
check("hole at 6-11 months: " .. describe(candidates), describe(candidates)
    == "CALF_WEANED[4-5] HEIFER_REPLACEMENT[12-17] HEIFER_READY[15-23] HEIFER_IN_CALF[18-29] COW_FIRST[24-35] COW_YOUNG[30-47]")
local none = cattle("COW_HOLSTEIN", "HOLSTEIN", "female")
none.visuals = visuals({ 0, false }, { 6, false })
candidates, gaps = P.getCandidates(entry, none, ctxFor(none))
check("nothing buyable: no candidate, every purpose NOT_BUYABLE or off", #candidates == 0
    and gapsOf(gaps):find("COW_FIRST:NOT_BUYABLE", 1, true) ~= nil)
-- maxBuyAge below a purpose: cut, never widened.
candidates = P.getCandidates(entry, holstein, ctxFor(holstein, 30))
check("maxBuyAge 30 cuts the windows: " .. describe(candidates), describe(candidates)
    == "CALF_WEANED[4-7] HEIFER_REPLACEMENT[6-17] HEIFER_READY[15-23] HEIFER_IN_CALF[18-29] COW_FIRST[24-30] COW_YOUNG[30-30]")

-- Other species.
local function species(typeName, name, breed, gender, minAge, duration, vis)
    return { name = name, breed = breed, gender = gender, visuals = vis, supportsReproduction = gender == "female",
        reproductionMinAgeMonth = minAge, reproductionDurationMonth = duration }, typeName
end
local gilt, pigType = species("PIG", "PIG_LANDRACE", "LANDRACE", "female", 6, 4, visuals({ 0, true }, { 3, true }, { 6, true }))
candidates = P.getCandidates(P.getEntry(config, gilt, pigType), gilt, ctxFor(gilt, 60))
check("gilts: " .. describe(candidates), describe(candidates) == "WEANER[1-2] GROWER[3-5] GILT[6-9] BREEDER_YOUNG[8-17]")
local mare, horseType = species("HORSE", "HORSE_GRAY", "GRAY", "female", 22, 11, visuals({ 0, true }))
candidates = P.getCandidates(P.getEntry(config, mare, horseType), mare, ctxFor(mare, 240))
check("horses: no foals, none past 10 years: " .. describe(candidates), describe(candidates) == "YOUNG_HORSE[6-35] HORSE[36-119]")
local drake, chickenType = species("CHICKEN", "DUCK_MALE", "DUCK", "male", 6, 0, visuals({ 0, false }, { 6, true }))
candidates = P.getCandidates(P.getEntry(config, drake, chickenType), drake, ctxFor(drake, 24))
check("Hof Bergmann drakes (buyable from 6): " .. describe(candidates), describe(candidates) == "BREEDER_YOUNG[6-11]")
local ewe, sheepType = species("SHEEP", "SHEEP_LANDRACE", "LANDRACE", "female", 8, 5, visuals({ 0, true }, { 3, true }, { 8, true }))
candidates = P.getCandidates(P.getEntry(config, ewe, sheepType), ewe, ctxFor(ewe, 48))
check("ewes: " .. describe(candidates), describe(candidates) == "WEANED[3-11] REPLACEMENT[6-17] BREEDER_YOUNG[12-29]")


-- Draws -----------------------------------------------------------------------------------------

math.randomseed(11)

-- Purpose shares follow the weights among the purposes left (Holstein cows: 15+35+20+10+8+2 = 90).
local counts, n = {}, 20000
local holsteinCandidates = P.getCandidates(entry, holstein, ctxFor(holstein))
for _ = 1, n do
    local c = P.pickCandidate(holsteinCandidates, math.random)
    counts[c.purpose.id] = (counts[c.purpose.id] or 0) + 1
end
local worst = 0
for id, weight in pairs({ CALF_WEANED = 15, HEIFER_REPLACEMENT = 35, HEIFER_READY = 20, HEIFER_IN_CALF = 10, COW_FIRST = 8, COW_YOUNG = 2 }) do
    worst = math.max(worst, math.abs((counts[id] or 0) / n - weight / 90))
end
check(string.format("purpose shares within 1%% of the weights (worst %.2f%%)", worst * 100), worst < 0.01)

-- Ages lean to the middle of the window and stay inside the segments.
local feeder = P.getCandidates(P.getEntry(config, angusBull, "COW"), angusBull, ctxFor(angusBull))[2]
local ageCounts, inside = {}, true
for _ = 1, n do
    local age = P.pickAge(feeder, math.random)
    ageCounts[age] = (ageCounts[age] or 0) + 1
    if age < 6 or age > 17 then inside = false end
end
check(string.format("store bulls 6-17 months, middle (11-12: %d) drawn more than edges (6: %d, 17: %d)",
    ageCounts[11] + ageCounts[12], ageCounts[6], ageCounts[17]),
    inside and ageCounts[11] > 3 * ageCounts[6] and ageCounts[12] > 3 * ageCounts[17])

-- A breed is drawn as often as any other, however many subtypes (aliases) it has.
local pool = {
    { index = 1, breed = "A", gender = "female" }, { index = 2, breed = "A", gender = "female" },
    { index = 3, breed = "A", gender = "female" }, { index = 4, breed = "A", gender = "male" },
    { index = 5, breed = "B", gender = "female" }, { index = 6, breed = "B", gender = "male" },
}
local picks = {}
for _ = 1, n do
    local index = P.pickSubType(config, pool, "COW", math.random)
    picks[index] = (picks[index] or 0) + 1
end
local breedA = (picks[1] + picks[2] + picks[3] + picks[4]) / n
check(string.format("breed A (4 subtypes) %.1f%% vs breed B (2) - each about half; A's females %.1f%%", breedA * 100,
    (picks[1] + picks[2] + picks[3]) / n * 100), math.abs(breedA - 0.5) < 0.015
    and math.abs((picks[1] + picks[2] + picks[3]) / n - 0.25) < 0.015)


-- Histories -------------------------------------------------------------------------------------

local function animalFrom(subType, age, plan, weight)
    local animal = { age = age, gender = subType.gender, isParent = plan.isParent,
        monthsSinceLastBirth = plan.monthsSinceLastBirth, isPregnant = plan.isPregnant, reproduction = 0,
        weight = weight or 600, targetWeight = subType.targetWeight }
    if plan.isPregnant then
        animal.pregnancy = { duration = plan.duration, pregnancies = { {} } }
        animal.reproduction = math.floor(plan.pregnancyMonths / plan.duration * 10000) / 100
    end
    return animal
end

local bad, planned, pregnantParents, histories = {}, 0, 0, 0
for _, subType in ipairs({ holstein, highlandCow, angusBull, highlandBull, gilt, ewe }) do
    local typeName = subType.typeIndex == 1 and "COW" or (subType == gilt and "PIG" or "SHEEP")
    local e = P.getEntry(config, subType, typeName)
    local ctx = ctxFor(subType, 72)
    local list = P.getCandidates(e, subType, ctx)
    for _ = 1, 4000 do
        local c = P.pickCandidate(list, math.random)
        local age = P.pickAge(c, math.random)
        local plan, reason = P.planReproduction(c.purpose, e, subType, age, math.random)
        histories = histories + 1
        if plan ~= nil then
            planned = planned + 1
            if plan.isParent and plan.isPregnant then pregnantParents = pregnantParents + 1 end
            local ok, reasons = P.validate(animalFrom(subType, age, plan), c.purpose, e, subType, ctx)
            if not ok then bad[c.purpose.id .. ":" .. reasons[1]] = true end
            if subType.gender == "male" and (plan.isParent or plan.isPregnant) then bad["male parent"] = true end
            if c.purpose.pregnant == "always" and plan.pregnancyMonths > 0.75 * plan.duration then bad["late"] = true end
        end
    end
end
local badList = {}
for key in pairs(bad) do table.insert(badList, key) end
table.sort(badList)
check(string.format("every planned history validates (%d of %d planned, %d pregnant cows with a calf before): %s",
    planned, histories, pregnantParents, table.concat(badList, " ")), #badList == 0 and pregnantParents > 0)

-- Histories that cannot be: rejected with the reason.
local inCalf = P.findPurpose(entry, "female", "HEIFER_IN_CALF")
local first = P.findPurpose(entry, "female", "COW_FIRST")
local replacement = P.findPurpose(entry, "female", "HEIFER_REPLACEMENT")
local ready = P.findPurpose(entry, "female", "HEIFER_READY")
local ctx = ctxFor(holstein)
local function reasonsOf(animal, purpose, e, subType)
    local ok, reasons = P.validate(animal, purpose, e or entry, subType or holstein, ctx)
    return ok and "ok" or table.concat(reasons, ",")
end
local heifer = { age = 20, gender = "female", isParent = false, monthsSinceLastBirth = 12, isPregnant = true,
    reproduction = 50, pregnancy = { duration = 10 }, weight = 500, targetWeight = 670 }
check("in-calf heifer 20 months, 5 months gone: ok", reasonsOf(heifer, inCalf) == "ok")
heifer.reproduction = 80
check("80% gone: too close to calving", reasonsOf(heifer, inCalf) == R.PREGNANCY_PROGRESS)
heifer.reproduction = 0
check("pregnant but no progress (old dealer pregnancy): rejected", reasonsOf(heifer, inCalf) == R.PREGNANCY_PROGRESS)
heifer.reproduction, heifer.age = 70, 18
check("conceived at 11 months, before the breeding age (12, slack 1): rejected",
    reasonsOf({ age = 17, gender = "female", isPregnant = true, reproduction = 70, pregnancy = { duration = 10 } },
        P.findPurpose(entry, "female", "HEIFER_IN_CALF")) == R.AGE .. "," .. R.TIMELINE)
check("replacement heifer pregnant: rejected", reasonsOf({ age = 14, gender = "female", isPregnant = true, reproduction = 30,
    pregnancy = { duration = 10 } }, replacement) == R.PREGNANCY)
check("first-calver that calved at 20 months (12 + 10 = 22 earliest, slack 1): rejected",
    reasonsOf({ age = 30, gender = "female", isParent = true, monthsSinceLastBirth = 10 }, first) == R.TIMELINE)
check("first-calver pregnant 1 month after calving: rejected", reasonsOf({ age = 30, gender = "female", isParent = true,
    monthsSinceLastBirth = 2, isPregnant = true, reproduction = 10, pregnancy = { duration = 10 } }, first) == R.TIMELINE)
check("heifer ready to breed under 55% of her target: TOO_LIGHT", reasonsOf({ age = 16, gender = "female",
    weight = 360, targetWeight = 670 }, ready) == R.TOO_LIGHT)
local bullEntry = P.getEntry(config, angusBull, "COW")
check("castrated young bull: rejected as a sire", reasonsOf({ age = 20, gender = "male", isCastrated = true },
    P.findPurpose(bullEntry, "male", "BULL_YOUNG"), bullEntry, angusBull) == R.CASTRATED)
check("a cow of 48 months fits no purpose", select(2, P.classify({ age = 48, gender = "female", isParent = true,
    monthsSinceLastBirth = 5 }, entry, holstein, ctx)) ~= nil)
check("an old listing of a 20-month open heifer is classified ready to breed",
    P.classify({ age = 20, gender = "female", weight = 450, targetWeight = 670 }, entry, holstein, ctx) == ready)

-- On the shelf: a month later (age, months since calving and gestation each one on) a listing
-- still qualifies, until it passes its purpose's last month or 75% of its gestation.
local cow = { age = 30, gender = "female", isParent = true, monthsSinceLastBirth = 7, isPregnant = true,
    reproduction = 30, pregnancy = { duration = 10 } }
check("first-calver 30 months, 7 since calving, 3 months gone: ok", reasonsOf(cow, first) == "ok")
cow.age = 31
check("mid-month the age moved and the calving count not yet: still ok", reasonsOf(cow, first) == "ok")
cow.monthsSinceLastBirth, cow.reproduction = 8, 40
check("a month on: still ok", reasonsOf(cow, first) == "ok")
cow.age, cow.monthsSinceLastBirth, cow.reproduction = 35, 12, 80
check("past 75% of gestation: withdrawn", reasonsOf(cow, first) == R.PREGNANCY_PROGRESS)
cow.age, cow.reproduction = 36, 70
check("at 36 months: withdrawn (first-calvers are 24-35)", reasonsOf(cow, first) == R.AGE)


-- The real createNewSaleAnimal ------------------------------------------------------------------
-- The generation block of the AnimalSystem file, with the game around it stubbed.

do
    local handle = assert(io.open(REPO .. "scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua", "r"))
    local text = handle:read("a")
    handle:close()
    check("no elite exemption or old sale-age limit left", text:find("isEliteForSale", 1, true) == nil
        and text:find("getMaxSaleAge", 1, true) == nil)
    local function slice(from, to)
        local a = assert(text:find(from, 1, true), from)
        local b = assert(text:find(to, a, true), to)
        return text:sub(a, b - 1)
    end
    AnimalSystem = {}
    local prelude = [[
        local Log = RmLogging.getLogger()
        local saleGenerationBailLatches = {}
        local warnedReshapeReturnedNil = false
        local function noteSaleGenerationBail(site) LOG[#LOG + 1] = "bail: " .. site end
        local function getDaysInMonth() return 1 end
    ]]
    assert(load(prelude .. slice("function AnimalSystem:_pickSaleAnimalAge", "--- Ages the dealer may offer a subtype at")
        .. slice("--- Ages the dealer may offer a subtype at", "function AnimalSystem:getSaleAnimalsByTypeIndex"), "generation"))()
end

AnimalType = { COW = 1, PIG = 2, SHEEP = 3, HORSE = 4, CHICKEN = 5 }
table.find = table.find or function(t, value)
    for k, v in pairs(t) do if v == value then return k end end
    return nil
end
RLAnimalUtil = { generateUniqueId = function(farmId, id) return string.format("%d-%d", farmId, id) end,
    getAnimalTypeDisplayName = function(t) return t.name end }
RealisticLivestock = { getMapCountryIndex = function() return 1 end }
RLDealerQualityResolver = { getActiveIndex = function() return 1 end }
RLDealerQualityModel = { reshapeGenetics = function(g) return g, false end, getPreset = function() return { key = "standard" } end }
RLCalendar = { getMonthAndYear = function() return 3, 2 end }
g_diseaseManager = { setGeneticDiseasesForSaleAnimal = function() end }
AnimalReproduction = { _clearOrphanedPregnancy = function(animal)
    animal.pregnancy, animal.reproduction, animal.isPregnant = nil, 0, false end }
g_currentMission.environment = { currentMonotonicDay = 40 }
g_currentMission.animalNameSystem = { getRandomName = function() return "Name" end }

local SUBTYPES = { holstein, cattle("BULL_HOLSTEIN", "HOLSTEIN", "male"), angusCow, angusBull, highlandCow, highlandBull }
for i, subType in ipairs(SUBTYPES) do subType.index = i end
local cowType = { name = "COW", typeIndex = 1, subTypes = { 1, 2, 3, 4, 5, 6 }, averageBuyAge = 12, maxBuyAge = 72 }
local system = setmetatable({
    countries = { { farms = { { id = 123456, quality = 1, ids = { [1] = 0 } } } } },
}, { __index = AnimalSystem })
function system:getTypeByIndex(i) return i == 1 and cowType or nil end
function system:getSubTypeByIndex(i) return SUBTYPES[i] end
function system:getVisualByAge() return { visualAnimal = { variations = { 1 } } } end

local animalMt = { __index = {
    getIdentifiers = function() return "id" end,
    setGenetics = function(self, g) self.genetics = g end,
    generateRandomOffspring = function() return 1 end,
} }
Animal = { new = function(cfg)
    local subType = SUBTYPES[cfg.subTypeIndex]
    local self = setmetatable({}, animalMt)
    for k, v in pairs(cfg) do self[k] = v end
    self.reproduction, self.isCastrated, self.birthday = 0, false, {}
    self.subType = subType
    if subType ~= nil and cfg.genetics ~= nil then
        local target = subType.targetWeight
        self.targetWeight = target + ((target * cfg.genetics.metabolism) - target) / 2.5
        self.weight = RLBreedTraits.getNewAnimalWeight(subType, self.gender, self.targetWeight, self.age, cfg.genetics.metabolism)
    end
    return self
end }

local generated, nilCount, overCap, outside, heavy, pregnantBad = {}, 0, 0, 0, 0, 0
local purposeCount = {}
for _ = 1, 6000 do
    local animal = system:createNewSaleAnimal(1)
    if animal == nil then
        nilCount = nilCount + 1
    else
        table.insert(generated, animal)
        local subType = SUBTYPES[animal.subTypeIndex]
        local e = P.getEntry(config, subType, "COW")
        local purpose = P.findPurpose(e, animal.gender, animal.sale.purpose)
        purposeCount[animal.sale.purpose] = (purposeCount[animal.sale.purpose] or 0) + 1
        if animal.age >= P.getCap(e, animal.gender) then overCap = overCap + 1 end
        if not P.validate(animal, purpose, e, subType, ctxFor(subType)) then outside = outside + 1 end
        if animal.weight > animal.targetWeight + 1e-9 then heavy = heavy + 1 end
        if animal.isPregnant ~= (animal.pregnancy ~= nil) then pregnantBad = pregnantBad + 1 end
    end
end
local ids = {}
for key, count in pairs(purposeCount) do table.insert(ids, key .. "=" .. count) end
table.sort(ids)
check(string.format("6000 cattle generated: %d failed places; {%s}", nilCount, table.concat(ids, " ")),
    nilCount < 60 and #generated > 5900)
check("none at or over its sex's cap (cows 48, bulls 36, Highland bulls 42), whatever the genetics", overCap == 0)
check("each one qualifies for the purpose it is listed as", outside == 0)
check("none heavier than its own target weight", heavy == 0)
check("pregnant exactly when it carries a pregnancy", pregnantBad == 0)

local maxBull, maxHighland, maxCow = 0, 0, 0
for _, animal in ipairs(generated) do
    if animal.gender == "male" then
        if SUBTYPES[animal.subTypeIndex].breed == "HIGHLAND" then maxHighland = math.max(maxHighland, animal.age)
        else maxBull = math.max(maxBull, animal.age) end
    else
        maxCow = math.max(maxCow, animal.age)
    end
end
check(string.format("oldest: bull %d, Highland bull %d, cow %d months", maxBull, maxHighland, maxCow),
    maxBull <= 29 and maxHighland <= 35 and maxCow <= 47)

local inCalfCount, progressOk = 0, true
for _, animal in ipairs(generated) do
    if animal.sale.purpose == "HEIFER_IN_CALF" then
        inCalfCount = inCalfCount + 1
        local progress = animal.reproduction / 100
        if not (progress > 0 and progress <= 0.75) then progressOk = false end
    end
end
check(string.format("in-calf heifers (%d) are 10-70%% through gestation, not just conceived", inCalfCount),
    inCalfCount > 0 and progressOk)

-- A purpose that can never be made consistent leaves the place empty after maxAttempts, with the reason.
AnimalSystem._formatSaleGenerationFailures(1, true, false)  -- the run above retried some light heifers
local strict = table.clone(config, 6)
strict.maxAttempts = 3
for _, purpose in ipairs(strict.profiles.CATTLE.purposes) do purpose.enabled = false end
P.config = strict
check("all purposes off: nothing generated", system:createNewSaleAnimal(1) == nil)
check("failure reasons counted: " .. AnimalSystem._formatSaleGenerationFailures(1, false, false),
    AnimalSystem._formatSaleGenerationFailures(1, true, false) == "NO_PURPOSE=3 SLOT_LEFT_EMPTY=1")
P.config = config

-- Old rules for a type the file does not cover: still generated, no purpose.
local alpaca = { name = "ALPACA_WHITE", breed = "ALPACA", gender = "female", visuals = visuals({ 0, false }, { 3, true }),
    supportsReproduction = false, reproductionMinAgeMonth = 8, reproductionDurationMonth = 11, index = 7,
    minWeight = 5, targetWeight = 60, maxWeight = 90 }
SUBTYPES[7] = alpaca
local alpacaType = { name = "ALPACA", typeIndex = 9, subTypes = { 7 }, averageBuyAge = 12, maxBuyAge = 60 }
system.countries[1].farms[1].ids[9] = 0
function system:getTypeByIndex(i) return i == 1 and cowType or (i == 9 and alpacaType or nil) end
local alpacaAnimal = system:createNewSaleAnimal(9)
check("not covered (alpaca): old rules, no purpose, buyable age", alpacaAnimal ~= nil and alpacaAnimal.sale.purpose == nil
    and alpacaAnimal.age >= 3 and alpacaAnimal.age <= 60)


-- rlDealerCatalog: one line per subtype, read-only.
loadMod("scripts/console/RLDealerConsole.lua")
local catalogLine = RLDealerConsole.describeSubType(config, system, cowType, angusCow)
check("catalog line: " .. catalogLine, catalogLine:find("status=COVERED weight=LEGACY_WEIGHT profile=CATTLE slow=false cap=48 buyable=[0-72]", 1, true) ~= nil
    and catalogLine:find("COW_YOUNG[30-47]w2", 1, true) ~= nil and catalogLine:find("HEIFER_READY:NO_BREEDING_WEIGHT", 1, true) ~= nil)
check("catalog line, not covered: " .. RLDealerConsole.describeSubType(config, system, alpacaType, alpaca),
    RLDealerConsole.describeSubType(config, system, alpacaType, alpaca):find("status=NOT_COVERED", 1, true) ~= nil)


-- Weight (legacy rule) ---------------------------------------------------------------------------

local bull = { typeIndex = 1, name = "BULL_ANGUS", breed = "ANGUS", gender = "male", minWeight = 35, maxWeight = 1400 }
local function weight(age, roll) return RLBreedTraits.getNewAnimalWeight(bull, "male", 1000, age, 1, function() return roll end) end
local line = RLBreedTraits.getGrownWeight(bull, "male", 1000, 12, 1)
check(string.format("weight: a 12-month bull %.0f kg on the line, 85%%-115%% of it", line),
    near(weight(12, 85), line * 0.85) and near(weight(12, 115), line * 1.15))
check("weight: a grown bull at 1.15 is its target 1000, not 1150", near(weight(120, 115), 1000) and near(weight(120, 85), 850))
check("weight: a small target caps below the subtype's maxWeight", near(RLBreedTraits.getNewAnimalWeight(bull, "male", 700, 120, 1,
    function() return 115 end), 700))

math.random = random
for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
