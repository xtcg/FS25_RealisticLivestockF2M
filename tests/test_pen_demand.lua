-- Pen totals after a herd change (RL_PlaceableHusbandry.refreshInputAndOutput): the hourly hook sets
-- a pen's food, water and milk liters per hour after the hour's feeding, so animals bought or moved
-- into a pen used to wait an hour for the pen to ask food for them. Driven through the engine's hour
-- (feeding, then health), the RLRM hourly hook, the real food, water and milk spec overrides and
-- the onHusbandryAnimalsUpdate event an AnimalClusterSystem flush raises. Health rates, genetics
-- and requests are the ones of the 2026-10-08 game logs (EC0BC01_milk_stage1, EC0BC01_calf_moved_h1).

g_currentModDirectory = REPO
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
RLMapBridge = { activeBridges = { { resolvedConfigPath = "mod_support/FS25_HofBergmann/v1.5/" } } }

local FILL = { FORAGE = 1, ROUNDBALE = 2, DRYGRASS_WINDROW = 3, SILAGE = 4, GRASS_WINDROW = 5, CLOVER_WINDROW = 6,
    SUGARBEET_CUT = 7, CALFMILK = 8, MILK = 9 }
local FILL_NAMES = {}
for name, index in pairs(FILL) do FILL_NAMES[index] = name end
g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return FILL_NAMES[i] end,
    getFillTypeIndexByName = function(_, n) return FILL[n] end,
}
-- Hof Bergmann's COW food groups (character/animalFood.xml, SERIAL, in file order).
local GROUPS = {
    { productionWeight = 1.00, fillTypes = { FILL.FORAGE, FILL.ROUNDBALE } },
    { productionWeight = 0.65, fillTypes = { FILL.DRYGRASS_WINDROW } },
    { productionWeight = 0.80, fillTypes = { FILL.SILAGE } },
    { productionWeight = 0.40, fillTypes = { FILL.GRASS_WINDROW, FILL.CLOVER_WINDROW } },
    { productionWeight = 0.85, fillTypes = { FILL.SUGARBEET_CUT } },
    { productionWeight = 1.20, fillTypes = { FILL.CALFMILK } },
}

-- The engine's AnimalFoodSystem (FS25 v1.23.1): no request, no consumption, factor 0.
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

local env = { daysPerPeriod = 1, timeAdjustment = 1, currentMonotonicDay = 1, currentHour = 0,
    weather = { temperatureUpdater = { currentMin = 15 } } }
g_currentMission = {
    environment = env,
    isMissionStarted = true,
    missionDynamicInfo = { isMultiplayer = false },
    animalFoodSystem = setmetatable({}, AnimalFoodSystem),
    animalSystem = { getTypeByIndex = function(_, i) return i == 1 and { name = "COW", subTypes = {} } or nil end,
        getSubTypeByIndex = function() return nil end },
}
g_i18n = { getText = function(_, key) return key end }
table.addElement = function(t, value)
    for _, v in ipairs(t) do if v == value then return end end
    t[#t + 1] = value
end
RmSafeUtils.safeAnimalCall = function(_, _, fn) fn() end

-- The engine's registration helpers: an overwritten function gets the previous one as superFunc.
SpecializationUtil = { registerFunction = function() end, registerOverwrittenFunction = function() end }
Utils = {
    appendedFunction = function(old, new)
        if old == nil then return new end
        return function(...) old(...); new(...) end
    end,
    overwrittenFunction = function(old, new) return function(self, ...) return new(self, old, ...) end end,
}

-- Base game spec functions the RLRM files wrap. The engine's own food listener sums cluster age
-- curves; RLRM must never reach it.
local baseFoodListenerCalls = 0
PlaceableHusbandryFood = { onHusbandryAnimalsUpdate = function() baseFoodListenerCalls = baseFoodListenerCalls + 1 end }
PlaceableHusbandryWater = { onHusbandryAnimalsUpdate = function() end }
PlaceableHusbandryMilk = { onHusbandryAnimalsUpdate = function() end }

-- The engine's hour (PlaceableHusbandry:onHourChanged): feeding first, then updateOutput, where
-- PlaceableHusbandryAnimals runs every animal's updateHealth with the pen's food factor. RLRM's
-- hourly hook is appended to it when the RLRM file loads.
PlaceableHusbandry = {}
function PlaceableHusbandry:onHourChanged()
    if self.isServer then
        local foodFactor = self:updateFeeding()
        self.lastFoodFactor = foodFactor
        for _, animal in pairs(self.animals) do AnimalHealth.updateHealth(animal, foodFactor) end
    end
end

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/bridge/RLHusbandryProfiles.lua")
loadMod("scripts/nutrition/RLCalfRearing.lua")
loadMod("scripts/animal/AnimalHealth.lua")
loadAnimalSection("Animal.SEMEN_FILL_TYPE_NAMES", "\nfunction Animal:getInput")
loadMod("scripts/animals/husbandry/placeables/PlaceableHusbandry.lua")
loadMod("scripts/animals/husbandry/placeables/PlaceableHusbandryWater.lua")
loadMod("scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryMilk.lua")
loadMod("scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryFood.lua")
AnimalType = { COW = 1 }

-- Hof Bergmann's cattle health: +10 / -25 per hour around a 0.45 food factor.
local SUB_COW = { name = "COW_HOLSTEIN", breed = "HOLSTEIN", gender = "female",
    healthThresholdFactor = 0.45, healthIncreaseHour = 10, healthDecreaseHour = 25,
    input = { food = {}, water = {} }, output = { milk = { fillType = FILL.MILK } } }

--- An animal with fixed per-hour input and output (Animal:updateInput / updateOutput leave them).
--- Adults carry no animal type, so the body condition rules leave them on the old weight path.
local function makeAnimal(id, age, healthGenetics, food, water, milk)
    return { uniqueId = id, farmId = 1, birthday = { country = 1 }, age = age, health = 100, numAnimals = 1,
        animalTypeIndex = age < 6 and 1 or nil, subTypeIndex = 1, gender = "female", isLactating = milk ~= nil,
        genetics = { health = healthGenetics }, input = { food = food, water = water }, output = { milk = milk or 0 },
        getSubType = function() return SUB_COW end,
        getInput = function(self, kind) return self.input[kind] or 0 end,
        getOutput = function(self, kind) return self.output[kind] or 0 end,
        updateInput = function() end, updateOutput = function() end,
        updateWeight = function() end, applyUnderweightPenalty = function() end }
end

local function chain(base, ...)
    local f = base
    for _, override in ipairs({ ... }) do
        local super = f
        f = function(self, ...) return override(self, super, ...) end
    end
    return f
end

local DAIRY = "placeables/animalHusbandry/cowHusbandryOldFarm/cowHusbandryOldFarm.xml"
local IGLOO = "placeables/animalHusbandry/calfIglus/calfIglu02.xml"
local BOX = "placeables/animalHusbandry/bullStable/bullCalfZone02.xml"

--- A pen with the food, water (automatic) and milk specs, whose updateInputAndOutput and feeding
--- run the RLRM overrides over the engine's functions, as the specialization chain does in game.
local function makePen(path, animals, levels, isServer)
    local p = { configFileName = "/mods/FS25_HofBergmann/" .. path, isServer = isServer ~= false, animals = animals,
        spec_husbandryAnimals = { animalTypeIndex = 1 },
        spec_husbandryFood = { fillLevels = {}, animalTypeIndex = 1, litersPerHour = 0 },
        spec_husbandryWater = { litersPerHour = 0, automaticWaterSupply = true },
        spec_husbandryMilk = { hasMilkProduction = true, litersPerHour = { [FILL.MILK] = 0 }, activeFillTypes = {} } }
    p.spec_husbandryAnimals.getClusters = function() return p.animals end
    p.spec_husbandryAnimals.clusterSystem = { getClusters = function() return p.animals end }
    for name, liters in pairs(levels or {}) do p.spec_husbandryFood.fillLevels[FILL[name]] = liters end
    function p:getName() return path end
    function p:getOwnerFarmId() return 1 end
    function p:getAvailableFood(fillTypeIndex) return self.spec_husbandryFood.fillLevels[fillTypeIndex] end
    p.updateInputAndOutput = chain(PlaceableHusbandry.updateInputAndOutput, PlaceableHusbandryFood.updateInputAndOutput,
        PlaceableHusbandryWater.updateInputAndOutput, PlaceableHusbandryMilk.updateInputAndOutput)
    local function baseRemove(self, delta, fillTypeIndex)
        local old = self.spec_husbandryFood.fillLevels[fillTypeIndex]
        self.spec_husbandryFood.fillLevels[fillTypeIndex] = math.max(old - delta, 0)
        return old - self.spec_husbandryFood.fillLevels[fillTypeIndex]
    end
    function p:removeFood(delta, fillTypeIndex)
        return RealisticLivestock_PlaceableHusbandryFood.removeFood(self, baseRemove, delta, fillTypeIndex)
    end
    -- PlaceableHusbandryFood:updateFeeding (engine): consume the pen's liters per hour, remove them.
    local function baseFeeding(self)
        local spec, consumed = self.spec_husbandryFood, {}
        local factor = g_currentMission.animalFoodSystem:consumeFoodSerially(spec.litersPerHour * env.timeAdjustment,
            GROUPS, self, consumed)
        for fillTypeIndex, delta in pairs(consumed) do self:removeFood(delta, fillTypeIndex) end
        return factor
    end
    function p:updateFeeding() return RealisticLivestock_PlaceableHusbandryFood.updateFeeding(self, baseFeeding) end
    -- The engine's hour with RLRM's hook appended (Utils.appendedFunction at load).
    p.onHourChanged = PlaceableHusbandry.onHourChanged
    -- Totals as RealisticLivestock_FSBaseMission:onStartMission sets them after load.
    if p.isServer then p:updateInputAndOutput(p.animals) end
    return p
end

local function level(p, name) return p.spec_husbandryFood.fillLevels[FILL[name]] end
local function foodRequest(p) return p.spec_husbandryFood.litersPerHour end

--- One game hour on every pen, in the engine's order (pens one after another).
local function hour(...)
    env.currentHour = env.currentHour + 1
    if env.currentHour == 24 then env.currentHour, env.currentMonotonicDay = 0, env.currentMonotonicDay + 1 end
    for _, p in ipairs({ ... }) do p:onHourChanged() end
end

--- The animals of a pen changed: its AnimalClusterSystem flushes and publishes
--- AnimalClusterUpdateEvent, and PlaceableHusbandryAnimals:updatedClusters raises
--- onHusbandryAnimalsUpdate on every spec listener, on the server and on clients.
local function flush(p)
    for _, spec in ipairs({ PlaceableHusbandryFood, PlaceableHusbandryWater, PlaceableHusbandryMilk }) do
        spec.onHusbandryAnimalsUpdate(p, p.animals)
    end
end
local function move(animal, from, to)
    for i, a in ipairs(from.animals) do if a == animal then table.remove(from.animals, i) break end end
    table.insert(to.animals, animal)
    flush(from)
    flush(to)
end

-- Buying into an empty pen ---------------------------------------------------------------------------

-- The cow bought on 2026-10-08 (EC0BC01_milk_stage1): 15.4 L/h, health genetics 1.275109, into a cow
-- barn with 27000 L TMR that had no animals the hour before.
local function buyCow(refresh)
    g_currentMission.isMissionStarted = refresh
    local barn = makePen(DAIRY, {}, { FORAGE = 27000 })
    hour(barn)
    local cow = makeAnimal("310693", 13, 1.275109, 15.4, 4)
    table.insert(barn.animals, cow)
    flush(barn)
    local requestAfterBuy = foodRequest(barn)
    hour(barn)
    local first, factor, eaten = cow.health, barn.lastFoodFactor, 27000 - level(barn, "FORAGE")
    hour(barn)
    g_currentMission.isMissionStarted = true
    return requestAfterBuy, first, factor, eaten, cow.health
end

local request, first, factor, eaten, second = buyCow(false)
check(string.format("old behaviour reproduced: bought cow's first hour in a pen empty the hour before asks 0 L, factor 0, health 100 -> %d -> %d (game log 100 -> 68 -> 80)",
    first, second), request == 0 and factor == 0 and eaten == 0 and first == 68 and second == 80)

request, first, factor, eaten, second = buyCow(true)
check(string.format("buy: the pen asks the cow's 15.4 L/h at once, first hour eats it at factor 1, health stays %d/%d",
    first, second), near(request, 15.4) and near(eaten, 15.4) and factor == 1 and first == 100 and second == 100)
check("buy: RLRM never runs the base game's cluster-curve food sum", baseFoodListenerCalls == 0)

-- Moving a calf between rearing pens -----------------------------------------------------------------

-- The calf moved on 2026-10-09 (EC0BC01_calf_moved_h1): 2 months, 7.4225 L/h, health genetics 1.219292,
-- from Calf igloo 02 to Calf rearing box B (bulls), which held 119.18 L CALFMILK and no solid feed.
local function moveCalf(refresh)
    local calf = makeAnimal("610001", 2, 1.219292, 7.4225, 1)
    local igloo = makePen(IGLOO, { calf }, { CALFMILK = 31.73, FORAGE = 31.38 })
    local box = makePen(BOX, {}, { CALFMILK = 119.18 })
    hour(igloo, box)
    g_currentMission.isMissionStarted = refresh
    move(calf, igloo, box)
    local requests = { igloo = foodRequest(igloo), box = foodRequest(box),
        iglooMilk = level(igloo, "CALFMILK"), iglooSolid = level(igloo, "FORAGE") }
    hour(igloo, box)
    g_currentMission.isMissionStarted = true
    return calf, igloo, box, requests
end

local calf, igloo, box, requests = moveCalf(false)
check(string.format("old behaviour reproduced: box B asks 0 L, the empty igloo still 7.42 L, the calf drinks nothing, health 100 -> %d (game log 69)",
    calf.health), requests.box == 0 and near(requests.igloo, 7.4225) and calf.rlCalfFeed.factor == 0
    and near(level(box, "CALFMILK"), 119.18) and calf.health == 69)

calf, igloo, box, requests = moveCalf(true)
check("move: box B asks the calf's 7.42 L/h at once and the igloo it left asks nothing",
    near(requests.box, 7.4225) and requests.igloo == 0)
check(string.format("move: first hour in box B the calf drinks its 2-month milk share (%.3f L = 0.7 of the request), factor 0.84, health stays 100",
    119.18 - level(box, "CALFMILK")), near(119.18 - level(box, "CALFMILK"), 7.4225 * 0.7, 1e-6)
    and near(calf.rlCalfFeed.factor, 0.84) and calf.health == 100)
check("move: the igloo it left eats nothing after the move",
    level(igloo, "CALFMILK") == requests.iglooMilk and level(igloo, "FORAGE") == requests.iglooSolid)

-- Moving into an occupied pen and out of a pen that keeps animals -------------------------------------

local stayer = makeAnimal("stayer", 30, 1, 12, 5, 0.5)
local mover = makeAnimal("mover", 30, 1, 15, 6, 0.8)
local barnA = makePen(DAIRY, { stayer, mover }, { FORAGE = 1000 })
local barnB = makePen(DAIRY, { makeAnimal("resident", 30, 1, 10, 4, 0.4) }, { FORAGE = 1000 })
hour(barnA, barnB)
check("steady pens: food, water and milk per hour are the sums of their animals",
    near(foodRequest(barnA), 27) and near(barnA.spec_husbandryWater.litersPerHour, 11)
    and near(barnA.spec_husbandryMilk.litersPerHour[FILL.MILK], 1.3) and near(foodRequest(barnB), 10))
move(mover, barnA, barnB)
check("move between occupied pens: food, water and milk follow the animal at once",
    near(foodRequest(barnA), 12) and near(barnA.spec_husbandryWater.litersPerHour, 5)
    and near(barnA.spec_husbandryMilk.litersPerHour[FILL.MILK], 0.5)
    and near(foodRequest(barnB), 25) and near(barnB.spec_husbandryWater.litersPerHour, 10)
    and near(barnB.spec_husbandryMilk.litersPerHour[FILL.MILK], 1.2))
local aBefore, bBefore = level(barnA, "FORAGE"), level(barnB, "FORAGE")
hour(barnA, barnB)
check("move between occupied pens: next hour the pen left eats only for the animal still there, the new pen for both",
    near(aBefore - level(barnA, "FORAGE"), 12) and near(bBefore - level(barnB, "FORAGE"), 25)
    and barnA.lastFoodFactor == 1 and barnB.lastFoodFactor == 1)

-- No change to the hourly totals -------------------------------------------------------------------

local snapshot = { foodRequest(barnA), barnA.spec_husbandryWater.litersPerHour, barnA.spec_husbandryMilk.litersPerHour[FILL.MILK] }
flush(barnA)
check("a flush without a herd change (an animal's dirty flag) leaves the hourly totals as they are",
    near(foodRequest(barnA), snapshot[1], 1e-12) and near(barnA.spec_husbandryWater.litersPerHour, snapshot[2], 1e-12)
    and near(barnA.spec_husbandryMilk.litersPerHour[FILL.MILK], snapshot[3], 1e-12))

-- Where the refresh does not run --------------------------------------------------------------------

local client = makePen(DAIRY, {}, { FORAGE = 100 }, false)
table.insert(client.animals, makeAnimal("seen by a client", 30, 1, 12, 5))
flush(client)
check("client: the flush a client receives leaves the server-only totals alone", foodRequest(client) == 0)

g_currentMission.isMissionStarted = false
local loading = makePen(DAIRY, {}, { FORAGE = 100 })
table.insert(loading.animals, makeAnimal("loaded", 30, 1, 12, 5))
flush(loading)
check("save load: the listener does nothing before the mission starts (onStartMission sets every pen)",
    foodRequest(loading) == 0)
g_currentMission.isMissionStarted = true

local broken = makePen(DAIRY, { makeAnimal("broken", 30, 1, 12, 5) }, { FORAGE = 100 })
broken.updateInputAndOutput = function() error("boom") end
local logged = #LOG
flush(broken)
check("a failing refresh is logged and does not stop the flush", #LOG == logged + 1
    and LOG[#LOG]:find("refreshInputAndOutput", 1, true) ~= nil)
table.remove(LOG)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
