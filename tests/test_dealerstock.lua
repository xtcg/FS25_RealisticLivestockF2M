-- Dealer stock (xml/dealerStock.xml, RLDealerStockPolicy, AnimalSystem:createNewSaleAnimal):
-- every dealer animal is generated for a purpose, at an age inside that purpose's half-open range,
-- its sex's absolute cap, the type's maxBuyAge and the buyable visuals, with a birth and pregnancy
-- history that fits; genetics never widen an age. Listings that outgrow their purpose are withdrawn.
-- D2: each comes from a source (dairy herd, rearing unit...) that supplies its breed's use, purpose
-- and sex; parents carry a birth count that fits their age; mothers milk by their last birth (the
-- game's rule); health minHealth..100 whatever the genetics; no animal showing a disease.
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

-- The identity runtime the sale-animal id goes through (not initialised here: it answers with the old counters).
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/animal/RLAnimalIdentityRuntime.lua")
loadMod("scripts/animal/RLAnimalIdentityWorld.lua")
loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animal/RLGeneticsDraw.lua")
loadMod("scripts/nutrition/RLCalfRearing.lua")
loadMod("scripts/dealer/RLDealerStockPolicy.lua")
loadMod("scripts/dealer/RLDealerSaleCatalog.lua")
AnimalType = { COW = 1, PIG = 2, SHEEP = 3, HORSE = 4, CHICKEN = 5 }
-- The game's milk rule (RLLactation) comes from tests/stubs.lua.

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

-- As AnimalSystem:getSaleAgeContext builds it.
local function ctxFor(subType, maxBuyAge)
    maxBuyAge = maxBuyAge or 72
    return { maxBuyAge = maxBuyAge,
        weaningMonth = RLCalfRearing.getWeaningMonthForSubType(subType),
        union = P.getBuyableAgeUnion(subType, maxBuyAge),
        lactates = RLLactation.startsAtBirth(subType.typeIndex, subType.name),
        lactationMonths = RLLactation.getMonths(subType), sucklingMonths = RLLactation.getSucklingMonths(subType) }
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

check("config: version 2, 8 attempts, 9 profiles", config.version == 2 and config.maxAttempts == 8
    and config.profiles.CATTLE ~= nil and config.profiles.HORSE ~= nil and config.profiles.DUCK ~= nil
    and config.profiles.GOAT ~= nil)
local profileCount, sourceless = 0, {}
for name, profile in pairs(config.profiles) do
    profileCount = profileCount + 1
    if #profile.sources == 0 or profile.minHealth ~= 90 then table.insert(sourceless, name) end
end
check("config: every profile has a source and minHealth 90 (" .. table.concat(sourceless, " ") .. ")",
    profileCount == 9 and #sourceless == 0)
local cattleProfile = config.profiles.CATTLE
check("config: cattle caps cows 48, bulls 36, slow bulls 42", cattleProfile.maxFemaleAge == 48
    and cattleProfile.maxMaleAge == 36 and cattleProfile.slowMaxMaleAge == 42 and cattleProfile.slowMaxFemaleAge == 48)
check("config: 11 cattle purposes (one id per sex)", #cattleProfile.purposes == 11)
local sourceIds = {}
for _, source in ipairs(cattleProfile.sources) do table.insert(sourceIds, source.id .. ":" .. source.traceability) end
check("config: cattle sources " .. table.concat(sourceIds, " "), table.concat(sourceIds, " ")
    == "DAIRY_HERD:RECORDED SUCKLER_HERD:RECORDED REARING_UNIT:PARTIAL BREEDING_STOCK:RECORDED")
check("config: COW_YOUNG up to 2 calvings, COW_FIRST 1", P.findPurpose({ profile = cattleProfile }, "female", "COW_YOUNG").maxParity == 2
    and P.findPurpose({ profile = cattleProfile }, "female", "COW_FIRST").maxParity == 1
    and P.findPurpose({ profile = cattleProfile }, "female", "COW_FIRST").minParity == 1)

local entry = P.getEntry(config, holstein, "COW")
check("entry: Holstein covered by CATTLE, dairy, ready-to-breed ratio 0.55, not slow",
    entry.status == P.COVERED and entry.profile.name == "CATTLE" and entry.use == "dairy"
    and entry.breedingWeightRatio == 0.55 and not entry.slow)
check("entry: breed uses - Angus beef, Simmental (pack and map alias) dual, Water Buffalo dairy and slow",
    P.getEntry(config, angusCow, "COW").use == "beef"
    and P.getEntry(config, { name = "COW_SIMMENTAL_PACK", breed = "SIMMENTAL_PACK" }, "COW").use == "dual"
    and P.getEntry(config, { name = "COW_SIMMENTAL", breed = "SIMMENTAL" }, "COW").use == "dual"
    and P.getEntry(config, { name = "COW_WATERBUFFALO", breed = "WATER_BUFFALO" }, "COW").use == "dairy"
    and P.getEntry(config, { name = "COW_WATERBUFFALO", breed = "WATER_BUFFALO" }, "COW").slow)
check("entry: goats have their own profile within the sheep type",
    P.getEntry(config, { name = "GOAT", breed = "GOAT", gender = "female" }, "SHEEP").profile.name == "GOAT"
    and P.getEntry(config, { name = "SHEEP_LANDRACE", breed = "LANDRACE" }, "SHEEP").profile.name == "SHEEP")
check("entry: Highland slow, Angus no breeding weight", P.getEntry(config, highlandBull, "COW").slow
    and P.getEntry(config, angusCow, "COW").breedingWeightRatio == nil)
check("entry: Hof Bergmann's BULL is legacy", P.getEntry(config, { name = "BULL", gender = "male" }, "COW").status == P.LEGACY)
check("entry: alpaca, quail and cats are not covered",
    P.getEntry(config, { name = "ALPACA_WHITE", breed = "ALPACA" }, "ALPACA").status == P.NOT_COVERED
    and P.getEntry(config, { name = "TOMCAT", breed = "TOMCAT" }, "CAT").status == P.NOT_COVERED)
check("entry: ducks in the chicken type use the DUCK profile",
    P.getEntry(config, { name = "DUCK_MALE", breed = "DUCK", gender = "male" }, "CHICKEN").profile.name == "DUCK"
    and P.getEntry(config, { name = "CHICKEN", breed = "CHICKEN" }, "CHICKEN").profile.name == "CHICKEN")


local layersWithRoot = { root = { flag = false }, types = {}, breeds = {}, subTypes = {} }
check("shared layer lookup keeps a false root value", RLBreedTraits.resolveNamed(layersWithRoot, "COW", nil, nil, "flag", true) == false)


-- Ages per purpose -------------------------------------------------------------------------------

local candidates, gaps = P.getCandidates(entry, holstein, ctxFor(holstein))
check("Holstein cows: " .. describe(candidates), describe(candidates)
    == "CALF_MILK[1-2] CALF_WEANED[4-7] HEIFER_REPLACEMENT[6-17] HEIFER_READY[15-23] HEIFER_IN_CALF[18-29] COW_FIRST[24-35] COW_YOUNG[30-47]")
check("Holstein cows: calves on milk offered too (for a calf rearing pen), nothing left out (" .. gapsOf(gaps) .. ")", gapsOf(gaps) == "")

candidates, gaps = P.getCandidates(P.getEntry(config, angusCow, "COW"), angusCow, ctxFor(angusCow))
check("Angus cows: not offered ready to breed without a breeding weight (" .. gapsOf(gaps) .. ")",
    gapsOf(gaps) == "CALF_MILK:NO_SOURCE HEIFER_READY:NO_BREEDING_WEIGHT")

candidates = P.getCandidates(P.getEntry(config, angusBull, "COW"), angusBull, ctxFor(angusBull))
check("Angus bulls (suckler breed, weaned at their dam at 7): " .. describe(candidates),
    describe(candidates) == "CALF_WEANED[7-7] FEEDER[7-17] BULL_YOUNG[12-29]")
candidates = P.getCandidates(P.getEntry(config, highlandBull, "COW"), highlandBull, ctxFor(highlandBull))
check("Highland bulls (slow, suckler): " .. describe(candidates), describe(candidates) == "CALF_WEANED[7-7] FEEDER[8-23] BULL_YOUNG[18-35]")
candidates = P.getCandidates(P.getEntry(config, highlandCow, "COW"), highlandCow, ctxFor(highlandCow))
check("Highland cows (slow, suckler): " .. describe(candidates), describe(candidates)
    == "CALF_WEANED[7-7] HEIFER_REPLACEMENT[7-17] HEIFER_IN_CALF[24-35] COW_FIRST[30-41] COW_YOUNG[36-47]")

-- A visual stage that cannot be bought leaves a hole; none buyable leaves nothing.
local holed = cattle("COW_HOLSTEIN", "HOLSTEIN", "female")
holed.visuals = visuals({ 0, true }, { 6, false }, { 12, true }, { 18, true })
candidates = P.getCandidates(entry, holed, ctxFor(holed))
check("hole at 6-11 months: " .. describe(candidates), describe(candidates)
    == "CALF_MILK[1-2] CALF_WEANED[4-5] HEIFER_REPLACEMENT[12-17] HEIFER_READY[15-23] HEIFER_IN_CALF[18-29] COW_FIRST[24-35] COW_YOUNG[30-47]")
local none = cattle("COW_HOLSTEIN", "HOLSTEIN", "female")
none.visuals = visuals({ 0, false }, { 6, false })
candidates, gaps = P.getCandidates(entry, none, ctxFor(none))
check("nothing buyable: no candidate, every purpose NOT_BUYABLE or off", #candidates == 0
    and gapsOf(gaps):find("COW_FIRST:NOT_BUYABLE", 1, true) ~= nil)
-- maxBuyAge below a purpose: cut, never widened.
candidates = P.getCandidates(entry, holstein, ctxFor(holstein, 30))
check("maxBuyAge 30 cuts the windows: " .. describe(candidates), describe(candidates)
    == "CALF_MILK[1-2] CALF_WEANED[4-7] HEIFER_REPLACEMENT[6-17] HEIFER_READY[15-23] HEIFER_IN_CALF[18-29] COW_FIRST[24-30] COW_YOUNG[30-30]")

-- Other species.
local function species(typeName, name, breed, gender, minAge, duration, vis)
    return { name = name, breed = breed, gender = gender, visuals = vis, supportsReproduction = gender == "female",
        reproductionMinAgeMonth = minAge, reproductionDurationMonth = duration }, typeName
end
local gilt, pigType = species("PIG", "PIG_LANDRACE", "LANDRACE", "female", 6, 4, visuals({ 0, true }, { 3, true }, { 6, true }))
candidates = P.getCandidates(P.getEntry(config, gilt, pigType), gilt, ctxFor(gilt, 60))
check("gilts: " .. describe(candidates), describe(candidates) == "WEANER[1-2] GROWER[3-5] GILT[6-9] BREEDER_YOUNG[8-17]")
local weaner = species("PIG", "PIG_LANDRACE", "LANDRACE", "female", 6, 4, visuals({ 0, true }))
candidates = P.getCandidates(P.getEntry(config, weaner, pigType), weaner, ctxFor(weaner, 60))
check("piglets weaned within their first month (weaningMonth 0), offered from 1: " .. describe(candidates),
    describe(candidates):find("^WEANER%[1%-2%]") ~= nil)
local doe, rabbitType = species("RABBIT", "RABBIT_WHITE", "WHITE", "female", 6, 1, visuals({ 0, true }))
candidates = P.getCandidates(P.getEntry(config, doe, rabbitType), doe, ctxFor(doe, 24))
check("rabbits weaned in month 1, offered from 2: " .. describe(candidates), describe(candidates) == "WEANED[2-3] BREEDER_YOUNG[6-9]")
local mare, horseType = species("HORSE", "HORSE_GRAY", "GRAY", "female", 22, 11, visuals({ 0, true }))
candidates = P.getCandidates(P.getEntry(config, mare, horseType), mare, ctxFor(mare, 240))
check("horses: no foals, none past 10 years: " .. describe(candidates), describe(candidates) == "YOUNG_HORSE[6-35] HORSE[36-119]")
local drake, chickenType = species("CHICKEN", "DUCK_MALE", "DUCK", "male", 6, 0, visuals({ 0, false }, { 6, true }))
candidates = P.getCandidates(P.getEntry(config, drake, chickenType), drake, ctxFor(drake, 24))
check("Hof Bergmann drakes (buyable from 6): " .. describe(candidates), describe(candidates) == "BREEDER_YOUNG[6-11]")
local ewe, sheepType = species("SHEEP", "SHEEP_LANDRACE", "LANDRACE", "female", 8, 5, visuals({ 0, true }, { 3, true }, { 8, true }))
candidates = P.getCandidates(P.getEntry(config, ewe, sheepType), ewe, ctxFor(ewe, 48))
check("ewes: " .. describe(candidates), describe(candidates) == "WEANED[3-11] REPLACEMENT[6-17] BREEDER_YOUNG[12-29]")


-- Sources ---------------------------------------------------------------------------------------

local function sourcesOf(e, gender, id)
    local list = {}
    for _, source in ipairs(P.getSources(e, P.findPurpose(e, gender, id), gender)) do table.insert(list, source.id) end
    return table.concat(list, ",")
end
local holsteinBull = cattle("BULL_HOLSTEIN", "HOLSTEIN", "male")
check("Holstein heifer calves: dairy herd or rearing unit; in-calf heifers: dairy herd or breeding stock",
    sourcesOf(entry, "female", "CALF_WEANED") == "DAIRY_HERD,REARING_UNIT"
    and sourcesOf(entry, "female", "HEIFER_IN_CALF") == "DAIRY_HERD,BREEDING_STOCK"
    and sourcesOf(entry, "female", "COW_YOUNG") == "DAIRY_HERD")
local holsteinBullEntry = P.getEntry(config, holsteinBull, "COW")
check("Holstein bulls: calves from the dairy herd or a rearing unit, stores only from rearing units, sires from breeding stock",
    sourcesOf(holsteinBullEntry, "male", "CALF_WEANED") == "DAIRY_HERD,REARING_UNIT"
    and sourcesOf(holsteinBullEntry, "male", "FEEDER") == "REARING_UNIT"
    and sourcesOf(holsteinBullEntry, "male", "BULL_YOUNG") == "BREEDING_STOCK")
check("Angus store bulls: suckler herd or rearing unit", sourcesOf(P.getEntry(config, angusBull, "COW"), "male", "FEEDER")
    == "SUCKLER_HERD,REARING_UNIT")

-- A cattle breed dealerStock.xml gives no use: rearing units only, the rest NO_SOURCE.
local oddCow, oddBull = cattle("COW_ODD", "ODD", "female"), cattle("BULL_ODD", "ODD", "male")
local oddEntry = P.getEntry(config, oddCow, "COW")
candidates, gaps = P.getCandidates(oddEntry, oddCow, ctxFor(oddCow))
check("breed without a use, cows: " .. describe(candidates) .. " / " .. gapsOf(gaps), oddEntry.use == nil
    and describe(candidates) == "CALF_WEANED[4-7] HEIFER_REPLACEMENT[6-17]"
    and gapsOf(gaps) == "CALF_MILK:NO_SOURCE HEIFER_READY:NO_BREEDING_WEIGHT HEIFER_IN_CALF:NO_SOURCE COW_FIRST:NO_SOURCE COW_YOUNG:NO_SOURCE")
candidates, gaps = P.getCandidates(P.getEntry(config, oddBull, "COW"), oddBull, ctxFor(oddBull))
check("breed without a use, bulls: " .. describe(candidates), describe(candidates) == "CALF_WEANED[4-7] FEEDER[6-17]"
    and gapsOf(gaps) == "CALF_MILK:NO_SOURCE BULL_YOUNG:NO_SOURCE")

-- Source shares follow their weights (1:1 here) and one source takes no draw.
local calfPurpose = P.findPurpose(entry, "female", "CALF_WEANED")
local sourceCounts = {}
math.randomseed(5)
for _ = 1, 10000 do
    local source = P.pickSource(P.getSources(entry, calfPurpose, "female"), math.random)
    sourceCounts[source.id] = (sourceCounts[source.id] or 0) + 1
end
local drew = false
P.pickSource(P.getSources(entry, P.findPurpose(entry, "female", "COW_YOUNG"), "female"), function() drew = true return 1 end)
check(string.format("heifer calves: dairy herd %d, rearing unit %d of 10000; a single source draws nothing",
    sourceCounts.DAIRY_HERD, sourceCounts.REARING_UNIT), math.abs(sourceCounts.DAIRY_HERD - 5000) < 250 and not drew)

check("goats: own source, and they milk (cows and goats do; sheep do not)",
    sourcesOf(P.getEntry(config, { name = "GOAT", breed = "GOAT", gender = "female" }, "SHEEP"), "female", "BREEDER_YOUNG") == "GOAT_HERD"
    and RLLactation.startsAtBirth(AnimalType.COW, "COW_HOLSTEIN")
    and RLLactation.startsAtBirth(AnimalType.SHEEP, "GOAT")
    and not RLLactation.startsAtBirth(AnimalType.SHEEP, "SHEEP_LANDRACE"))
local curve = {}
for m = 0, 10 do table.insert(curve, string.format("%.3f", RLLactation.getYieldFactor(m))) end
check("milk yield curve as before: " .. table.concat(curve, " "), table.concat(curve, " ")
    == "0.800 0.967 1.133 1.300 1.267 1.200 1.133 1.067 1.000 0.933 0.000")
check("unknown months since birth: dry, no yield", not RLLactation.isWithin(nil) and RLLactation.getYieldFactor(nil) == 0)
do
    local saved = AnimalType
    AnimalType = nil
    local ok, goat = pcall(RLLactation.startsAtBirth, 1, "GOAT")
    AnimalType = saved
    check("milk rule without the AnimalType global: goats still, no error", ok and goat)
end


-- Draws -----------------------------------------------------------------------------------------

math.randomseed(11)

-- Purpose shares follow the weights among the purposes left (Holstein cows: 10+15+35+20+10+8+2 = 100).
local counts, n = {}, 20000
local holsteinCandidates = P.getCandidates(entry, holstein, ctxFor(holstein))
for _ = 1, n do
    local c = P.pickCandidate(holsteinCandidates, math.random)
    counts[c.purpose.id] = (counts[c.purpose.id] or 0) + 1
end
local worst = 0
for id, weight in pairs({ CALF_MILK = 10, CALF_WEANED = 15, HEIFER_REPLACEMENT = 35, HEIFER_READY = 20, HEIFER_IN_CALF = 10, COW_FIRST = 8, COW_YOUNG = 2 }) do
    worst = math.max(worst, math.abs((counts[id] or 0) / n - weight / 100))
end
check(string.format("purpose shares within 1%% of the weights (worst %.2f%%)", worst * 100), worst < 0.01)

-- Ages lean to the middle of the window and stay inside the segments (Holstein stores: from 6;
-- a suckler breed's start at 7, weaned at their dam).
local feeder
for _, candidate in ipairs(P.getCandidates(holsteinBullEntry, holsteinBull, ctxFor(holsteinBull))) do
    if candidate.purpose.id == "FEEDER" then feeder = candidate end
end
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

-- Hof Bergmann's cattle: 7 breeds with cows and bulls, and the bull stable's BULL (bulls only, its
-- name as breed). A breed counts once per sex, so BULL keeps the 1 in 15 it had when every subtype
-- was drawn alike, instead of 1 in 8.
local hb = {}
for i = 1, 7 do
    table.insert(hb, { index = 2 * i - 1, breed = "B" .. i, gender = "female" })
    table.insert(hb, { index = 2 * i, breed = "B" .. i, gender = "male" })
end
table.insert(hb, { index = 15, name = "BULL", breed = "BULL", gender = "male" })
local stableBulls = 0
for _ = 1, n do
    if P.pickSubType(config, hb, "COW", math.random) == 15 then stableBulls = stableBulls + 1 end
end
check(string.format("bull stable bull %.1f%% of cattle (1/15 = 6.7%%)", stableBulls / n * 100),
    math.abs(stableBulls / n - 1 / 15) < 0.01)


-- Histories -------------------------------------------------------------------------------------

local function animalFrom(subType, age, plan, weight, ctx)
    local animal = { age = age, gender = subType.gender, isParent = plan.isParent,
        monthsSinceLastBirth = plan.monthsSinceLastBirth, isPregnant = plan.isPregnant, reproduction = 0,
        weight = weight or 600, targetWeight = subType.targetWeight, health = 95,
        isLactating = P.isInMilk(subType.gender, plan.isParent, plan.monthsSinceLastBirth, ctx or ctxFor(subType)),
        sale = { parity = plan.parity } }
    if plan.isPregnant then
        animal.pregnancy = { duration = plan.duration, pregnancies = { {} } }
        animal.reproduction = math.floor(plan.pregnancyMonths / plan.duration * 10000) / 100
    end
    return animal
end

local bad, planned, pregnantParents, histories = {}, 0, 0, 0
local parities = {}
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
            local parityKey = c.purpose.id .. "=" .. plan.parity
            parities[parityKey] = (parities[parityKey] or 0) + 1
            if plan.isParent ~= (plan.parity > 0) then bad["parity without birth"] = true end
            local ok, reasons = P.validate(animalFrom(subType, age, plan, nil, ctx), c.purpose, e, subType, ctx)
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
check(string.format("births: first-calvers 1 (%d), young cows 1 (%d) or 2 (%d), never more",
    parities["COW_FIRST=1"] or 0, parities["COW_YOUNG=1"] or 0, parities["COW_YOUNG=2"] or 0),
    (parities["COW_FIRST=1"] or 0) > 0 and (parities["COW_YOUNG=2"] or 0) > 0 and parities["COW_YOUNG=3"] == nil
    and parities["COW_FIRST=2"] == nil and parities["COW_YOUNG=0"] == nil)

-- Two calvings need a gestation and a recovery between them: a Holstein (bred from 12, 10 months
-- gestation, 3 to recover) has her second calf at 35 months at the earliest.
local young = P.findPurpose(entry, "female", "COW_YOUNG")
local twoBirths = 0
for _ = 1, 2000 do
    local plan = P.planReproduction(young, entry, holstein, 36, math.random)
    if plan.parity == 2 then
        twoBirths = twoBirths + 1
        if 36 - plan.monthsSinceLastBirth < 35 then bad["second calf too early"] = true end
    end
end
check(string.format("36-month cows with two calves (%d) calved the second at 35 or later", twoBirths),
    twoBirths > 0 and not bad["second calf too early"])
local onlyOne = 0
for _ = 1, 500 do
    if P.planReproduction(young, entry, holstein, 34, math.random).parity == 1 then onlyOne = onlyOne + 1 end
end
check("34-month cows: only one calving fits", onlyOne == 500)

-- Histories that cannot be: rejected with the reason.
local inCalf = P.findPurpose(entry, "female", "HEIFER_IN_CALF")
local first = P.findPurpose(entry, "female", "COW_FIRST")
local replacement = P.findPurpose(entry, "female", "HEIFER_REPLACEMENT")
local ready = P.findPurpose(entry, "female", "HEIFER_READY")
local ctx = ctxFor(holstein)
-- A healthy animal milking by its last birth unless the case says otherwise.
local function filled(animal)
    if animal.health == nil then animal.health = 95 end
    if animal.isLactating == nil then
        animal.isLactating = P.isInMilk(animal.gender, animal.isParent, animal.monthsSinceLastBirth, ctx)
    end
    return animal
end
local function reasonsOf(animal, purpose, e, subType, c)
    local ok, reasons = P.validate(filled(animal), purpose, e or entry, subType or holstein, c or ctx)
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
check("a cow of 48 months fits no purpose", select(2, P.classify(filled({ age = 48, gender = "female", isParent = true,
    monthsSinceLastBirth = 5 }), entry, holstein, ctx)) ~= nil)
check("an old listing of a 20-month open heifer is classified ready to breed",
    P.classify(filled({ age = 20, gender = "female", weight = 450, targetWeight = 670 }), entry, holstein, ctx) == ready)

-- Births, milk, health, disease and source.
check("young cow with 2 calvings at 40 months, last 4 months ago: ok", reasonsOf({ age = 40, gender = "female",
    isParent = true, monthsSinceLastBirth = 4, sale = { parity = 2 } }, young) == "ok")
check("young cow with 3 calvings: PARITY", reasonsOf({ age = 47, gender = "female", isParent = true,
    monthsSinceLastBirth = 1, sale = { parity = 3 } }, young) == R.PARITY)
check("two calvings that do not fit 31 months (second at 30, 35 earliest): PARITY", reasonsOf({ age = 31,
    gender = "female", isParent = true, monthsSinceLastBirth = 1, sale = { parity = 2 } }, young) == R.PARITY)
check("first-calver listed with 2 calvings: PARITY", reasonsOf({ age = 34, gender = "female", isParent = true,
    monthsSinceLastBirth = 1, sale = { parity = 2 } }, first) == R.PARITY)
check("open heifer listed with a calving: PARITY", reasonsOf({ age = 12, gender = "female", weight = 300,
    targetWeight = 670, sale = { parity = 1 } }, replacement) == R.PARITY)
check("old listing, calvings unknown: kept when no more than the purpose's can fit (47 months, last 1 ago: 2)",
    reasonsOf({ age = 47, gender = "female", isParent = true, monthsSinceLastBirth = 1 }, young) == "ok")
local quick = table.clone(config, 6)
quick.profiles.CATTLE.minRecoveryMonth = 0
local quickEntry = P.getEntry(quick, holstein, "COW")
check("old listing, calvings unknown: withdrawn when more could fit than the purpose allows",
    reasonsOf({ age = 35, gender = "female", isParent = true, monthsSinceLastBirth = 1 },
        P.findPurpose(quickEntry, "female", "COW_FIRST"), quickEntry) == R.PARITY)
check("old listing, calvings unknown: kept a month past its birthday, before months since calving catch up",
    reasonsOf({ age = 33, gender = "female", isParent = true, monthsSinceLastBirth = 1 },
        P.findPurpose(quickEntry, "female", "COW_FIRST"), quickEntry) == "ok")
check("first-calver 7 months after calving and dry: LACTATION", reasonsOf({ age = 30, gender = "female",
    isParent = true, monthsSinceLastBirth = 7, isLactating = false, sale = { parity = 1 } }, first) == R.LACTATION)
check("first-calver 11 months after calving, dry: ok; still in milk: LACTATION",
    reasonsOf({ age = 34, gender = "female", isParent = true, monthsSinceLastBirth = 11, isLactating = false }, first) == "ok"
    and reasonsOf({ age = 34, gender = "female", isParent = true, monthsSinceLastBirth = 11, isLactating = true }, first) == R.LACTATION)
check("heifer in milk: LACTATION", reasonsOf({ age = 12, gender = "female", weight = 300, targetWeight = 670,
    isLactating = true }, replacement) == R.LACTATION)
local goatSub = species("SHEEP", "GOAT", "GOAT", "female", 8, 5, visuals({ 0, true }))
local goatEntry = P.getEntry(config, goatSub, "SHEEP")
local goatCtx = ctxFor(goatSub, 48)
local goatBreeder = P.findPurpose(goatEntry, "female", "BREEDER_YOUNG")
check("goat that kidded 2 months ago and is dry: LACTATION; in milk: ok",
    reasonsOf({ age = 20, gender = "female", isParent = true, monthsSinceLastBirth = 2, isLactating = false,
        sale = { parity = 1 } }, goatBreeder, goatEntry, goatSub, goatCtx) == R.LACTATION
    and reasonsOf({ age = 20, gender = "female", isParent = true, monthsSinceLastBirth = 2, isLactating = true,
        sale = { parity = 1 } }, goatBreeder, goatEntry, goatSub, goatCtx) == "ok")
-- Suckler breeds (breedTraits sucklingMonths 7): the cow is dried off when her calf is weaned at 7
-- months, and the dealer sells the breed's calves only once weaned.
local angusEntry, angusCtx = P.getEntry(config, angusCow, "COW"), ctxFor(angusCow)
local packBull = cattle("BULL_CHAROLAIS_PACK", "CHAROLAIS_PACK", "male")
check("suckling period: Angus cows and bulls and the pack's Charolais 7 months, Holstein none (10-month lactation)",
    RLLactation.getSucklingMonths(angusCow) == 7 and RLLactation.getSucklingMonths(angusBull) == 7
    and RLLactation.getSucklingMonths(packBull) == 7 and RLLactation.getSucklingMonths(holstein) == nil
    and RLLactation.getMonths(angusCow) == 7 and RLLactation.getMonths(holstein) == 10 and RLLactation.getMonths(nil) == 10)
check("sale context: Angus suckling 7 (none offered younger), lactation 7; Holstein no suckling period, lactation 10",
    angusCtx.sucklingMonths == 7 and angusCtx.lactationMonths == 7
    and ctxFor(holstein).sucklingMonths == nil and ctxFor(holstein).lactationMonths == 10)
local beefCurve = {}
for m = 5, 8 do table.insert(beefCurve, string.format("%.3f", RLLactation.getYieldFactor(m, 7))) end
check("a suckler cow's yield: the same shape, ending at 7: " .. table.concat(beefCurve, " "),
    table.concat(beefCurve, " ") == "1.200 1.133 0.000 0.000" and RLLactation.isWithin(6, 7) and not RLLactation.isWithin(7, 7))
local angusFirst = P.findPurpose(angusEntry, "female", "COW_FIRST")
check("Angus cow 8 months after calving: dry is ok, still in milk is LACTATION; 6 months: in milk",
    reasonsOf({ age = 34, gender = "female", isParent = true, monthsSinceLastBirth = 8, isLactating = false,
        sale = { parity = 1 } }, angusFirst, angusEntry, angusCow, angusCtx) == "ok"
    and reasonsOf({ age = 34, gender = "female", isParent = true, monthsSinceLastBirth = 8, isLactating = true,
        sale = { parity = 1 } }, angusFirst, angusEntry, angusCow, angusCtx) == R.LACTATION
    and P.isInMilk("female", true, 6, angusCtx) and not P.isInMilk("female", true, 7, angusCtx)
    and P.isInMilk("female", true, 8, ctx))
local angusCalf = P.findPurpose(P.getEntry(config, angusBull, "COW"), "male", "CALF_WEANED")
check("an old listing of a 5-month Angus calf (offered at 4 before): AGE; at 7: ok",
    reasonsOf({ age = 5, gender = "male", weight = 180, targetWeight = 1000 }, angusCalf, P.getEntry(config, angusBull, "COW"),
        angusBull, ctxFor(angusBull)) == R.AGE
    and reasonsOf({ age = 7, gender = "male", weight = 250, targetWeight = 1000 }, angusCalf, P.getEntry(config, angusBull, "COW"),
        angusBull, ctxFor(angusBull)) == "ok")
local simmentalCalf = cattle("BULL_SIMMENTAL_PACK", "SIMMENTAL_PACK", "male")
local simmentalCandidates, simmentalGaps = P.getCandidates(P.getEntry(config, simmentalCalf, "COW"), simmentalCalf, ctxFor(simmentalCalf))
local holsteinBullCandidates = P.getCandidates(P.getEntry(config, holsteinBull, "COW"), holsteinBull, ctxFor(holsteinBull))
check("calves on milk: Holstein bull calves 1-2 months from the dairy herd; the pack's Simmental (dual, but a suckler breed) none: "
    .. describe(simmentalCandidates) .. " / " .. gapsOf(simmentalGaps),
    describe(holsteinBullCandidates):find("^CALF_MILK%[1%-2%]") ~= nil
    and sourcesOf(P.getEntry(config, holsteinBull, "COW"), "male", "CALF_MILK") == "DAIRY_HERD"
    and gapsOf(simmentalGaps):find("CALF_MILK:NO_AGE", 1, true) ~= nil
    and describe(simmentalCandidates):find("CALF_WEANED[7-7]", 1, true) ~= nil)
check("health 89: HEALTH; 90: ok", reasonsOf({ age = 12, gender = "female", weight = 300, targetWeight = 670,
    health = 89 }, replacement) == R.HEALTH and reasonsOf({ age = 12, gender = "female", weight = 300,
    targetWeight = 670, health = 90 }, replacement) == "ok")
check("showing a disease: SICK", reasonsOf({ age = 12, gender = "female", weight = 300, targetWeight = 670,
    getHasAnyDisease = function() return true end }, replacement) == R.SICK)
check("Holstein heifer from a suckler herd, or an unknown source: SOURCE; from a rearing unit: ok",
    reasonsOf({ age = 12, gender = "female", weight = 300, targetWeight = 670, sale = { source = "SUCKLER_HERD" } }, replacement) == R.SOURCE
    and reasonsOf({ age = 12, gender = "female", weight = 300, targetWeight = 670, sale = { source = "GONE" } }, replacement) == R.SOURCE
    and reasonsOf({ age = 12, gender = "female", weight = 300, targetWeight = 670, sale = { source = "REARING_UNIT" } }, replacement) == "ok")

-- On the shelf: a month later (age, months since calving and gestation each one on) a listing
-- still qualifies, until it passes its purpose's last month or 75% of its gestation.
local cow = { age = 30, gender = "female", isParent = true, monthsSinceLastBirth = 7, isPregnant = true,
    reproduction = 30, pregnancy = { duration = 10 } }
check("first-calver 30 months, 7 since calving, 3 months gone: ok", reasonsOf(cow, first) == "ok")
cow.age = 31
check("mid-month the age moved and the calving count not yet: still ok", reasonsOf(cow, first) == "ok")
cow.monthsSinceLastBirth, cow.reproduction = 8, 40
check("a month on: still ok", reasonsOf(cow, first) == "ok")
-- 10 months after calving she is dried off (Animal:advanceRecoveryPeriod).
cow.age, cow.monthsSinceLastBirth, cow.reproduction, cow.isLactating = 35, 12, 80, false
check("past 75% of gestation: withdrawn", reasonsOf(cow, first) == R.PREGNANCY_PROGRESS)

-- 28 days a month: gestation rises at least 1% a day, 28% a month, so read as months it runs
-- ahead of the calendar. A cow bred again exactly 3 months after calving, a month on the shelf:
local fast = { age = 31, gender = "female", isParent = true, monthsSinceLastBirth = 7, isPregnant = true,
    reproduction = 40, pregnancy = { duration = 10 } }
check("generated: bred 3 months after calving, 4 months gone: ok", reasonsOf(fast, first) == "ok")
fast.age, fast.monthsSinceLastBirth, fast.reproduction = 32, 8, 68
local function shelfReasons(animal, purpose)
    local ok, reasons = P.validate(filled(animal), purpose, entry, holstein, ctx, true)
    return ok and "ok" or table.concat(reasons, ",")
end
check("a 28-day month later: generation's check would say TIMELINE, the shelf check keeps it",
    reasonsOf(fast, first) == R.TIMELINE and shelfReasons(fast, first) == "ok")
fast.reproduction = 76
check("on the shelf it is still withdrawn past 75%", shelfReasons(fast, first) == R.PREGNANCY_PROGRESS)

-- weight 0 is off, like enabled="false".
local zero = table.clone(config, 6)
for _, purpose in ipairs(zero.profiles.CATTLE.purposes) do
    if purpose.id == "HEIFER_REPLACEMENT" then purpose.weight = 0 end
end
local zeroEntry = P.getEntry(zero, holstein, "COW")
local zeroCandidates, zeroGaps = P.getCandidates(zeroEntry, holstein, ctx)
local openHeifer = filled({ age = 12, gender = "female", weight = 300, targetWeight = 670 })
check("weight 0: not offered, listed as DISABLED, its listings withdrawn and not migrated into",
    not describe(zeroCandidates):find("HEIFER_REPLACEMENT", 1, true) and gapsOf(zeroGaps):find("HEIFER_REPLACEMENT:DISABLED", 1, true)
    and not P.validate(openHeifer, P.findPurpose(zeroEntry, "female", "HEIFER_REPLACEMENT"), zeroEntry, holstein, ctx)
    and P.classify(openHeifer, zeroEntry, holstein, ctx) == nil)
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
    assert(load(prelude .. slice("function AnimalSystem:_pickSaleAnimalAge", "--- What RLDealerStockPolicy needs to know of a subtype")
        .. slice("--- What RLDealerStockPolicy needs to know of a subtype", "function AnimalSystem:getSaleAnimalsByTypeIndex"), "generation"))()
    assert(load(slice("function AnimalSystem:_checkSaleListing", "function AnimalSystem:onHourChanged"), "shelf check"))()
    check("sale record saves and loads its source and parity", text:find('".sale#source"', 1, true) ~= nil
        and text:find('xmlFile:setInt(key .. ".sale#parity"', 1, true) ~= nil and text:find('xmlFile:getInt(key .. ".sale#parity")', 1, true) ~= nil)
end

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
-- Now and then a genetic disease that shows (an affected animal): it must not be listed.
g_diseaseManager = { setGeneticDiseasesForSaleAnimal = function(_, animal) animal.affected = math.random(1, 40) == 1 end }
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
    -- Now and then no offspring, so an in-calf heifer loses her pregnancy after taking her id.
    generateRandomOffspring = function() return math.random(1, 50) == 1 and 0 or 1 end,
    getHasAnyDisease = function(self) return self.affected == true end,
} }
Animal = { new = function(cfg)
    local subType = SUBTYPES[cfg.subTypeIndex]
    local self = setmetatable({}, animalMt)
    for k, v in pairs(cfg) do self[k] = v end
    self.reproduction, self.birthday = 0, {}
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

local lowGenetics, healthRange, milkBad, sourceBad, intact, parityCount = 0, true, 0, 0, true, {}
for _, animal in ipairs(generated) do
    local subType = SUBTYPES[animal.subTypeIndex]
    local e = P.getEntry(config, subType, "COW")
    if not (animal.health >= 90 and animal.health <= 100) then healthRange = false end
    if animal.genetics.health < 0.8 then lowGenetics = lowGenetics + 1 end
    if animal.isLactating ~= (animal.isParent and animal.monthsSinceLastBirth < RLLactation.getMonths(subType)) then milkBad = milkBad + 1 end
    local source = P.findSource(e, animal.sale.source)
    if source == nil or not P.supplies(source, e, P.findPurpose(e, animal.gender, animal.sale.purpose), animal.gender) then
        sourceBad = sourceBad + 1
    end
    if animal.gender == "male" and animal.isCastrated ~= false then intact = false end
    local key = tostring(animal.sale.parity)
    parityCount[key] = (parityCount[key] or 0) + 1
end
check(string.format("health 90-100 for every animal, %d of them with health genetics under 0.8", lowGenetics),
    healthRange and lowGenetics > 0)
check("in milk exactly from calving to the end of the breed's lactation (10 months; Angus and Highland 7)", milkBad == 0)
check("each from a source that supplies its breed, purpose and sex", sourceBad == 0)
check("every bull intact", intact)
check(string.format("births recorded: none %d, one %d, two %d", parityCount["0"] or 0, parityCount["1"] or 0, parityCount["2"] or 0),
    (parityCount["0"] or 0) > 0 and (parityCount["1"] or 0) > 0 and (parityCount["2"] or 0) > 0 and parityCount["nil"] == nil)
local sickRejected = tonumber(AnimalSystem._formatSaleGenerationFailures(1, false, true):match("SICK=(%d+)") or 0)
local anySick = false
for _, animal in ipairs(generated) do if animal:getHasAnyDisease() then anySick = true end end
check(string.format("none showing a disease (%d rejected before taking an id)", sickRejected), not anySick and sickRejected > 0)
local lostPregnancies = tonumber(AnimalSystem._formatSaleGenerationFailures(1, false, true):match("PREGNANCY=(%d+)") or 0)
check(string.format("farm ids: one per accepted animal plus one per pregnancy lost after it (%d = %d + %d); light heifers and affected animals took none",
    system.countries[1].farms[1].ids[1], #generated, lostPregnancies),
    system.countries[1].farms[1].ids[1] == #generated + lostPregnancies and lostPregnancies > 0)

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


-- The shelf check: old listings get a purpose and a source (MIGRATED), or are withdrawn.
local function listing(sale, extra)
    local animal = filled({ subTypeIndex = 1, age = 12, gender = "female", weight = 300, targetWeight = 670, sale = sale })
    for k, v in pairs(extra or {}) do animal[k] = v end
    return animal
end
local oldListing = listing({ day = 1 })
local keep, why = system:_checkSaleListing(oldListing)
check("listing from before purposes: given the first purpose that fits and the least traceable source of it (" .. tostring(oldListing.sale.purpose)
    .. " from " .. tostring(oldListing.sale.source) .. ")", keep and why == "MIGRATED"
    and oldListing.sale.purpose == "HEIFER_REPLACEMENT" and oldListing.sale.source == "REARING_UNIT")
local d1Listing = listing({ day = 1, purpose = "COW_YOUNG" }, { age = 40, isParent = true, monthsSinceLastBirth = 4, isLactating = true })
keep, why = system:_checkSaleListing(d1Listing)
check("listing from before sources: given one (" .. tostring(d1Listing.sale.source) .. ", the only one)",
    keep and why == "MIGRATED" and d1Listing.sale.source == "DAIRY_HERD")
keep, why = system:_checkSaleListing(listing({ day = 1, purpose = "HEIFER_REPLACEMENT", source = "REARING_UNIT", parity = 0 }))
check("current listing: kept as it is", keep and why == nil)
local fallbackListing = listing({ day = 1, purpose = "HEIFER_REPLACEMENT", source = "UNSPECIFIED", parity = 0 })
keep, why = system:_checkSaleListing(fallbackListing)
check("listing from the fallback source of a file without sources: given a named one when the file names them",
    keep and why == "MIGRATED" and fallbackListing.sale.source == "REARING_UNIT")
keep, why = system:_checkSaleListing(listing({ day = 1, purpose = "HEIFER_REPLACEMENT", source = "REARING_UNIT", parity = 0 },
    { getHasAnyDisease = function() return true end }))
check("listing that fell ill: withdrawn (SICK)", not keep and why == R.SICK)
local sickOld = listing({ day = 1 }, { getHasAnyDisease = function() return true end })
keep, why = system:_checkSaleListing(sickOld)
check("old listing that is ill: withdrawn, not given a source", not keep and sickOld.sale.source == nil)


-- The old rules can make a male of a milking type a "parent"; he is never in milk.
check("a male is never in milk", not P.isInMilk("male", true, 3, { lactates = true }))
local stableBull = { name = "BULL", breed = "BULL", gender = "male", visuals = visuals({ 0, true }),
    supportsReproduction = false, reproductionMinAgeMonth = 12, reproductionDurationMonth = 9, index = 8,
    typeIndex = 1, minWeight = 40, targetWeight = 1000, maxWeight = 1400 }
SUBTYPES[8] = stableBull
local stableType = { name = "COW", typeIndex = 1, subTypes = { 8 }, averageBuyAge = 40, maxBuyAge = 60 }
system.countries[1].farms[1].ids[10] = 0
function system:getTypeByIndex(i) return i == 1 and cowType or (i == 9 and alpacaType or (i == 10 and stableType or nil)) end
local stableParents, stableInMilk = 0, 0
for _ = 1, 400 do
    local bull = system:createNewSaleAnimal(10)
    if bull ~= nil and bull.isParent then stableParents = stableParents + 1 end
    if bull ~= nil and bull.isLactating then stableInMilk = stableInMilk + 1 end
end
check(string.format("old rules: Hof Bergmann's stable bull made a parent %d times, in milk %d times", stableParents, stableInMilk),
    stableParents > 0 and stableInMilk == 0)


-- A dealerStock.xml from before sources, and a source naming a purpose the profile lacks: warned.
do
    local path = os.tmpname()
    local handle = assert(io.open(path, "w"))
    handle:write([[<dealerStock version="1">
    <profile name="OLD" maxFemaleAgeMonth="12" maxMaleAgeMonth="12">
        <purpose id="YOUNG" gender="any" minAgeMonth="1" maxAgeMonth="6"/>
    </profile>
    <profile name="TYPO" maxFemaleAgeMonth="12" maxMaleAgeMonth="12">
        <purpose id="YOUNG" gender="female" minAgeMonth="1" maxAgeMonth="6"/>
        <source id="FARM" purposes="YOUNG YUNG YOUNG:male" traceability="SOMETIMES"/>
        <source id="FARM2" purposes="YOUNG YUNG YOUNG:male"/>
    </profile>
    <profile name="BROKEN" maxFemaleAgeMonth="12" maxMaleAgeMonth="12">
        <purpose id="YOUNG" gender="female" minAgeMonth="1" maxAgeMonth="6"/>
        <source id="X" weight="0"/>
    </profile>
    <profile name="EMPTY" maxFemaleAgeMonth="12" maxMaleAgeMonth="12"/>
</dealerStock>]])
    handle:close()
    local before = #LOG
    local parsed = P.parseConfig(loadXMLFileFromDisk(path))
    os.remove(path)
    local warnings = table.concat(LOG, "\n", before + 1)
    check("version 1 file: warned, and a profile without sources keeps selling from one UNSPECIFIED source",
        warnings:find("version 1", 1, true) ~= nil and warnings:find("profile OLD has no source", 1, true) ~= nil
        and #parsed.profiles.OLD.sources == 1 and parsed.profiles.OLD.sources[1].id == "UNSPECIFIED"
        and P.supplies(parsed.profiles.OLD.sources[1], { use = nil }, parsed.profiles.OLD.purposes[1], "male"))
    check("source naming a purpose the profile lacks (YUNG, YOUNG for males): warned",
        warnings:find("source FARM2 names purpose YUNG,", 1, true) ~= nil
        and warnings:find("source FARM2 names purpose YOUNG for male", 1, true) ~= nil)
    check("source with an unknown traceability: ignored with a warning", #parsed.profiles.TYPO.sources == 1
        and warnings:find("source FARM ignored: traceability", 1, true) ~= nil)
    check("only invalid sources: no fallback (offers nothing); no purposes: no fallback either",
        #parsed.profiles.BROKEN.sources == 0 and #parsed.profiles.EMPTY.sources == 0)
    for i = #LOG, before + 1, -1 do table.remove(LOG, i) end

    path = os.tmpname()
    handle = assert(io.open(path, "w"))
    handle:write([[<dealerStock><profile name="P" maxFemaleAgeMonth="12" maxMaleAgeMonth="12"/></dealerStock>]])
    handle:close()
    before = #LOG
    P.parseConfig(loadXMLFileFromDisk(path))
    os.remove(path)
    check("a file without a version: warned like version 1", table.concat(LOG, "\n", before + 1):find("version nil", 1, true) ~= nil)
    for i = #LOG, before + 1, -1 do table.remove(LOG, i) end
end
check("least traceable of no sources: none", P.getLeastTraceableSource({}) == nil)


-- rlDealerCatalog: one line per subtype, read-only.
loadMod("scripts/console/RLDealerConsole.lua")
local catalogLine = RLDealerConsole.describeSubType(config, system, cowType, angusCow)
check("catalog line: " .. catalogLine, catalogLine:find("status=COVERED weight=LEGACY_WEIGHT profile=CATTLE use=beef slow=false cap=48 minHealth=90 milk=true buyable=[0-72]", 1, true) ~= nil
    and catalogLine:find("COW_YOUNG[30-47]w2<SUCKLER_HERD>", 1, true) ~= nil and catalogLine:find("HEIFER_READY:NO_BREEDING_WEIGHT", 1, true) ~= nil)
local gapsLine = RLDealerConsole.describeGaps(config, cowType, { holstein, oddCow, oddBull, { name = "BULL", breed = "BULL", gender = "male" } })
check("gaps line: " .. gapsLine, gapsLine == "RLDEALER GAPS type=COW subTypes=4 covered=3 oldRules={BULL:LEGACY} breedsWithoutUse={ODD}")
check("gaps line: pig breeds need no use (their source takes any breed)",
    RLDealerConsole.describeGaps(config, { name = "PIG" }, { gilt }) == "RLDEALER GAPS type=PIG subTypes=1 covered=1 oldRules={} breedsWithoutUse={}")
local sorted = RLDealerSaleCatalog.sortedTypes({ [9] = alpacaType, [1] = cowType })
check("catalog walks a type table with holes in index order", #sorted == 2 and sorted[1] == cowType and sorted[2] == alpacaType)
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
