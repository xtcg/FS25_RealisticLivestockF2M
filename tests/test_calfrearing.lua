-- Calf rearing (scripts/nutrition/RLCalfRearing.lua, xml/calfRearing.xml): milk and solid feed by
-- age in the rearing pens (igloo, rearing boxes), through the engine's SERIAL food consumption with
-- Hof Bergmann's cattle food groups, the real food spec override, per-animal settlement, the
-- health hook, the body condition share and the daily records.

g_currentModDirectory = REPO
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
RLMapBridge = { activeBridges = { { resolvedConfigPath = "mod_support/FS25_HofBergmann/v1.5/" } } }

-- Fill types and Hof Bergmann's COW food groups (character/animalFood.xml, SERIAL, in file order).
local FILL = { FORAGE = 1, ROUNDBALE = 2, DRYGRASS_WINDROW = 3, SILAGE = 4, GRASS_WINDROW = 5, CLOVER_WINDROW = 6,
    SUGARBEET_CUT = 7, CALFMILK = 8 }
local FILL_NAMES = {}
for name, index in pairs(FILL) do FILL_NAMES[index] = name end
g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return FILL_NAMES[i] end,
    getFillTypeIndexByName = function(_, n) return FILL[n] end,
}
local GROUPS = {
    { productionWeight = 1.00, fillTypes = { FILL.FORAGE, FILL.ROUNDBALE } },
    { productionWeight = 0.65, fillTypes = { FILL.DRYGRASS_WINDROW } },
    { productionWeight = 0.80, fillTypes = { FILL.SILAGE } },
    { productionWeight = 0.40, fillTypes = { FILL.GRASS_WINDROW, FILL.CLOVER_WINDROW } },
    { productionWeight = 0.85, fillTypes = { FILL.SUGARBEET_CUT } },
    { productionWeight = 1.20, fillTypes = { FILL.CALFMILK } },
}

-- The engine's AnimalFoodSystem (FS25 v1.23.1 dataS/scripts/animals/husbandry/AnimalFoodSystem.lua).
AnimalFoodSystem = {}
AnimalFoodSystem.__index = AnimalFoodSystem
function AnimalFoodSystem.consumeFoodGroup(_, foodGroup, amount, foodOwner, consumedFood)
    for _, fillTypeIndex in pairs(foodGroup.fillTypes) do
        local currentFillLevel = foodOwner:getAvailableFood(fillTypeIndex)
        if currentFillLevel ~= nil then
            local deltaConsumed = math.min(currentFillLevel, math.min(amount, currentFillLevel))
            amount = math.max(amount - deltaConsumed, 0)
            consumedFood[fillTypeIndex] = deltaConsumed
            if amount == 0 then return amount end
        end
    end
    return amount
end
function AnimalFoodSystem:consumeFoodSerially(amount, foodGroups, foodOwner, consumedFood)
    local total, productionWeight = amount, 0
    if amount > 0 then
        for _, foodGroup in ipairs(foodGroups) do
            local before = amount
            amount = self:consumeFoodGroup(foodGroup, amount, foodOwner, consumedFood)
            productionWeight = productionWeight + (before - amount) / total * foodGroup.productionWeight
        end
    end
    return productionWeight
end
function AnimalFoodSystem:getAnimalFood() return { groups = GROUPS } end

-- The override is installed when the module loads, so load it again now that the engine class exists.
loadMod("scripts/nutrition/RLCalfRearing.lua")
loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/bridge/RLHusbandryProfiles.lua")

local env = { daysPerPeriod = 1, timeAdjustment = 1, currentMonotonicDay = 1, currentHour = 0 }
local SUB_HOLSTEIN = { name = "COW_HOLSTEIN", typeIndex = 1, breed = "HOLSTEIN", gender = "female", input = { food = {} } }
local SUB_ANGUS = { name = "BULL_ANGUS", typeIndex = 1, breed = "ANGUS", gender = "male", input = { food = {} } }
g_currentMission = {
    environment = env,
    animalFoodSystem = setmetatable({}, AnimalFoodSystem),
    animalSystem = { getTypeByIndex = function(_, i) return i == 1 and { name = "COW", subTypes = {} } or nil end,
        getSubTypeByIndex = function() return nil end },
}
AnimalType = { COW = 1 }
g_i18n = { getText = function(_, key) return key end }
PlaceableHusbandryFood = {}
Utils = { appendedFunction = function(a, b) return b end, overwrittenFunction = function(a, b) return b end }
loadMod("scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryFood.lua")

-- RLPEN_DUMP=path appends every record as a log line (analyzer fixtures).
RECORDS = {}
local emit = RLPenLog.emit
RLPenLog.emit = function(kind, data, warn)
    RECORDS[#RECORDS + 1] = { kind = kind, data = data }
    local line = emit(kind, data, warn)
    DUMP(line)
    return line
end
local function records(kind)
    local list = {}
    for _, r in ipairs(RECORDS) do if r.kind == kind then list[#list + 1] = r end end
    return list
end

local REQUEST = 10 -- liters per hour per animal

local function calf(age, sub, id)
    return { age = age, farmId = 1, uniqueId = id or ("c" .. age), birthday = { country = 1 }, animalTypeIndex = 1,
        numAnimals = 1, health = 50, subTypeIndex = 1, gender = (sub or SUB_HOLSTEIN).gender,
        getSubType = function() return sub or SUB_HOLSTEIN end,
        getInput = function(_, kind) return kind == "food" and REQUEST or 0 end }
end

local function pen(path, animals, levels)
    local p = { configFileName = "/mods/FS25_HofBergmann/" .. path, isServer = true, animals = animals,
        spec_husbandryAnimals = { animalTypeIndex = 1 },
        spec_husbandryFood = { fillLevels = {}, animalTypeIndex = 1, litersPerHour = 0 } }
    p.spec_husbandryAnimals.clusterSystem = { getClusters = function() return p.animals end }
    for name, liters in pairs(levels or {}) do p.spec_husbandryFood.fillLevels[FILL[name]] = liters end
    function p:getName() return path end
    function p:getOwnerFarmId() return 1 end
    function p:getAvailableFood(fillTypeIndex) return self.spec_husbandryFood.fillLevels[fillTypeIndex] end
    return p
end
local BOX = "placeables/animalHusbandry/bullStable/bullCalfZone01.xml"
local IGLOO = "placeables/animalHusbandry/calfIglus/calfIglu01.xml"
local DAIRY = "placeables/animalHusbandry/cowHusbandryOldFarm/cowHusbandryOldFarm.xml"

--- One hour's feeding through the real food spec override; the base function it wraps is the
--- engine's: consume the pen's request serially, then remove what was consumed from the trough.
local function feedHour(p)
    env.currentHour = env.currentHour + 1
    if env.currentHour == 24 then env.currentHour, env.currentMonotonicDay = 0, env.currentMonotonicDay + 1 end
    local spec = p.spec_husbandryFood
    spec.litersPerHour = #p.animals * REQUEST
    local before = {}
    for ft, level in pairs(spec.fillLevels) do before[ft] = level end
    local factor = RealisticLivestock_PlaceableHusbandryFood.updateFeeding(p, function(self)
        local consumed = {}
        local f = g_currentMission.animalFoodSystem:consumeFoodSerially(spec.litersPerHour * env.timeAdjustment, GROUPS, self, consumed)
        for ft, delta in pairs(consumed) do
            RealisticLivestock_PlaceableHusbandryFood.removeFood(self, function(_, d, t)
                local old = spec.fillLevels[t]
                spec.fillLevels[t] = math.max(old - d, 0)
                return old - spec.fillLevels[t]
            end, delta, ft)
        end
        return f
    end)
    local eaten = {}
    for ft, level in pairs(before) do eaten[FILL_NAMES[ft]] = level - spec.fillLevels[ft] end
    return factor, eaten
end

local function factorOf(animal) return RLCalfRearing.getFoodFactor(animal, -1) end

-- Config and stages --------------------------------------------------------------------------------

local config = RLCalfRearing.getConfig()
check("config: shipped xml/calfRearing.xml valid, weaning at 3 months, CALFMILK is milk",
    config.enabled and config.invalidReason == nil and config.weaningMonth == 3 and RLCalfRearing.isMilkFillType(FILL.CALFMILK)
    and not RLCalfRearing.isMilkFillType(FILL.FORAGE))
local stages = {}
for age = 0, 6 do stages[#stages + 1] = RLCalfRearing.getStage(calf(age)) end
check("stages: 0-2 PRE_WEANING, 3 WEANING, 4-6 WEANED (housing at 2 is not a feeding stage)",
    table.concat(stages, " ") == "PRE_WEANING PRE_WEANING PRE_WEANING WEANING WEANED WEANED WEANED")
local m0, s0 = RLCalfRearing.getCaps(calf(0))
local m3, s3 = RLCalfRearing.getCaps(calf(3))
local m4, s4 = RLCalfRearing.getCaps(calf(4))
check("caps: newborn milk 1 / solid 0.1, weaning milk 0.35 / solid 0.9, weaned milk 0 / solid 1",
    near(m0, 1) and near(s0, 0.1) and near(m3, 0.35) and near(s3, 0.9) and near(m4, 0) and near(s4, 1))
check("config: a file whose solidMax never reaches 1 is refused", not RLCalfRearing.validate({ weaningMonth = 3,
    milkFillTypes = { CALFMILK = true }, curves = { milkMax = { { 0, 1 } }, solidMax = { { 0, 0.5 } } } }))
check("rearing pens: igloo and boxes yes, dairy barn no",
    RLCalfRearing.appliesToPen(pen(IGLOO, {})) and RLCalfRearing.appliesToPen(pen(BOX, {}))
    and not RLCalfRearing.appliesToPen(pen(DAIRY, {})))

-- H04: milk before weaning, solids after ------------------------------------------------------------

local c1 = calf(1)
local igloo = pen(IGLOO, { c1 }, { CALFMILK = 100 })
local _, eaten = feedHour(igloo)
check("H04 1-month calf on milk alone: drinks 0.9 of its request, factor 1.08 (fully fed)",
    near(eaten.CALFMILK, 9) and near(factorOf(c1), 1.08))

local c2 = calf(2)
local box = pen(BOX, { c2 }, { CALFMILK = 100, FORAGE = 100 })
_, eaten = feedHour(box)
check("H04 2-month calf moved to a box with milk and TMR: 6 L TMR + 4 L milk, factor 1.08 (milk still there)",
    near(eaten.FORAGE, 6) and near(eaten.CALFMILK, 4) and near(factorOf(c2), 1.08))
box = pen(BOX, { c2 }, { CALFMILK = 100, DRYGRASS_WINDROW = 100 })
_, eaten = feedHour(box)
check("H04 2-month calf on hay and milk: 6 L hay + 4 L milk, factor 0.87",
    near(eaten.DRYGRASS_WINDROW, 6) and near(eaten.CALFMILK, 4) and near(factorOf(c2), 0.87))
box = pen(BOX, { c2 }, { CALFMILK = 100 })
feedHour(box)
check("H04 2-month calf on milk alone: 0.7 of the request, factor 0.84", near(factorOf(c2), 0.84))

local c3 = calf(3)
box = pen(BOX, { c3 }, { CALFMILK = 100 })
_, eaten = feedHour(box)
check("H04 3-month (weaning) calf on milk alone is underfed: 3.5 L, factor 0.42",
    near(eaten.CALFMILK, 3.5) and near(factorOf(c3), 0.42))
box = pen(BOX, { c3 }, { CALFMILK = 100, FORAGE = 100 })
_, eaten = feedHour(box)
check("H04 3-month calf with TMR: 9 L TMR + 1 L milk, fully fed", near(eaten.FORAGE, 9) and near(eaten.CALFMILK, 1)
    and near(factorOf(c3), 1.02))

local c4 = calf(4)
box = pen(BOX, { c4 }, { CALFMILK = 100 })
_, eaten = feedHour(box)
check("H04 4-month (weaned) calf drinks no milk: the milk stays in the trough, factor 0",
    near(eaten.CALFMILK, 0) and near(factorOf(c4), 0) and near(box.spec_husbandryFood.fillLevels[FILL.CALFMILK], 100))
box = pen(BOX, { c4 }, { CALFMILK = 100, DRYGRASS_WINDROW = 100 })
_, eaten = feedHour(box)
check("H04 4-month calf eats hay only, the solid feed the trough takes: factor 0.65 (hay's weight)",
    near(eaten.DRYGRASS_WINDROW, 10) and near(eaten.CALFMILK, 0) and near(factorOf(c4), 0.65))

local c0 = calf(0)
igloo = pen(IGLOO, { c0 }, { FORAGE = 100 })
feedHour(igloo)
check("H04 newborn without milk: 1 L TMR, factor 0.1 (underfed)", near(factorOf(c0), 0.1))

-- A mixed-age pen: shares follow each animal's caps -------------------------------------------------

local young, weaned = calf(1, nil, "young"), calf(4, nil, "weaned")
box = pen(BOX, { young, weaned }, { CALFMILK = 100, FORAGE = 100 })
local penFactor
penFactor, eaten = feedHour(box)
local a, b = young.rlCalfFeed, weaned.rlCalfFeed
local sum = 0
for _, feed in ipairs({ a, b }) do for _, liters in pairs(feed.items) do sum = sum + liters end end
check("mixed box (1 and 4 months): the weaned calf gets no milk, the young one all of it",
    near(b.milk, 0) and near(a.milk, eaten.CALFMILK) and near(eaten.CALFMILK, 7) and near(eaten.FORAGE, 13))
check("mixed box: TMR shared by solid caps (young 3 L, weaned 10 L); factors 1.14 and 1.0",
    near(a.solid, 3) and near(b.solid, 10) and near(factorOf(young), 1.14) and near(factorOf(weaned), 1.0))
check("H06 what the animals are given adds up to what the trough lost (nothing counted twice)",
    near(sum, eaten.CALFMILK + eaten.FORAGE))

-- Outside rearing pens nothing changes ------------------------------------------------------------------

local inBarn = calf(1, nil, "barn")
local barn = pen(DAIRY, { inBarn }, { FORAGE = 100 })
penFactor, eaten = feedHour(barn)
check("dairy barn: a calf eats as before (engine consumption, pen factor kept)",
    near(eaten.FORAGE, 10) and near(penFactor, 1) and inBarn.rlCalfFeed == nil and factorOf(inBarn) == -1
    and barn.spec_husbandryFood.rlCalfCaps == nil)
RLCalfRearing.config.enabled = false
local off = calf(4, nil, "off")
box = pen(BOX, { off }, { CALFMILK = 100 })
_, eaten = feedHour(box)
check("feature off: a rearing pen feeds like any pen (weaned calf drinks milk)", near(eaten.CALFMILK, 10) and off.rlCalfFeed == nil)
RLCalfRearing.config.enabled = true

-- Health and the body condition budget use the animal's own share ----------------------------------

loadMod("scripts/animal/AnimalHealth.lua")
local weighed
local h = calf(4, nil, "health")
h.genetics = { health = 1 }
h.getSubType = function() return { healthThresholdFactor = 0.5, healthIncreaseHour = 1, healthDecreaseHour = 1 } end
h.updateWeight = function(_, factor) weighed = factor end
h.applyUnderweightPenalty = function() end
box = pen(BOX, { h }, { CALFMILK = 100 })
feedHour(box)
AnimalHealth.updateHealth(h, 1.2)
check("health: a weaned calf with only milk gets its own factor 0, not the pen's (health falls, growth 0)",
    weighed == 0 and h.health < 50)
env.currentHour = env.currentHour + 1
check("health: next hour without a feeding the pen's factor applies again", RLCalfRearing.getFoodFactor(h, 0.7) == 0.7
    and h.rlCalfFeed == nil)

local yearling = calf(7, nil, "resident")
yearling.getSubType = function() return SUB_HOLSTEIN end
local baby = calf(1, nil, "baby")
box = pen(BOX, { yearling, baby }, { CALFMILK = 100, FORAGE = 100 })
feedHour(box)
local supply = box.spec_husbandryFood.rlNutritionSupply
local intake, allocated = RLBodyCondition.getAllocatedIntake(yearling, supply)
local function budget(litersOf)
    local total = 0
    for _, item in ipairs(supply.items) do
        local digest = item.category == RLBodyCondition.OTHER_CATEGORY and 1 or RLBreedTraits.get(SUB_HOLSTEIN, item.category)
        total = total + litersOf(item) * item.energy * digest
    end
    return total
end
local own = budget(function(item) return yearling.rlCalfFeed.items[item.fillType] or 0 end)
local pooled = budget(function(item) return item.liters / 2 end)
check("body condition: a 7-month resident of a box is budgeted on its own share (10 L TMR, no milk), not half the pen's mix",
    near(allocated, 10) and near(yearling.rlCalfFeed.milk, 0) and near(intake, own) and not near(intake, pooled))

-- Daily records -------------------------------------------------------------------------------------

RECORDS = {}
local grower = calf(2, nil, "grower")
box = pen(BOX, { grower }, { CALFMILK = 500, FORAGE = 500 })
for _ = 1, 24 do feedHour(box) end
RLCalfRearing.onPenDayChanged(box)
local day = records("CALF_FEED_DAY")[1]
local stage = records("FEED_STAGE")[1]
check("CALF_FEED_DAY: 24 hours, milk and TMR eaten, no water spec, the calf's stage and mean factor",
    day ~= nil and day.data.hours == 24 and near(day.data.milk, 96) and near(day.data.solid, 144)
    and day.data.water == "NONE" and day.data.animals[1].stage == "PRE_WEANING" and near(day.data.animals[1].meanFactor, 1.08)
    and day.data.consumed.CALFMILK ~= nil)
check("FEED_STAGE: first sight records PRE_WEANING", stage ~= nil and stage.data.from == nil and stage.data.to == "PRE_WEANING")
RECORDS = {}
RLCalfRearing.onPenDayChanged(box)
check("FEED_STAGE: no record while the stage holds, no feeding record for a day without feedings",
    #records("FEED_STAGE") == 0 and #records("CALF_FEED_DAY") == 0)
grower.age = 3
RLCalfRearing.onPenDayChanged(box)
stage = records("FEED_STAGE")[1]
check("FEED_STAGE: PRE_WEANING -> WEANING when the calf reaches 3 months", stage ~= nil
    and stage.data.from == "PRE_WEANING" and stage.data.to == "WEANING" and near(stage.data.milkMax, 0.35))

-- Breed layers ----------------------------------------------------------------------------------------

RLCalfRearing.config.layers = { root = {}, types = {}, breeds = { COW = { ANGUS = { weaningMonth = 5 } } }, subTypes = {} }
check("weaningMonth by breed: an Angus calf is still PRE_WEANING at 4, a Holstein WEANED",
    RLCalfRearing.getStage(calf(4, SUB_ANGUS)) == "PRE_WEANING" and RLCalfRearing.getStage(calf(4)) == "WEANED")
