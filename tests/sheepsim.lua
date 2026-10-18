-- Sheep in the real-equivalent nutrition mode (S5): engine stand-ins for a sheep pen with Hof
-- Bergmann 1.5's sheep food (one SERIAL group: grass, hay, clover) plus the feeds RLFeed adds for
-- the species (silage, grain, peas), the weight profiles' SHEEP type switched on for the test, and
-- helpers for ewes, lambs and goats. Builds on tests/feedsim.lua (its hour loop runs any pen).
-- Shared by tests/test_sheep_s5_nursing.lua and the offline calibration (tests/sheepcalib.lua).

loadMod("tests/feedsim.lua")

SheepSim = {}

local FILL = FeedSim.FILL
local SHEEP
for _, sub in ipairs(Economics.subTypes) do
    if sub.typeName == "SHEEP" and SHEEP == nil then SHEEP = sub.typeIndex end
end
SheepSim.TYPE = SHEEP
AnimalType.SHEEP = SHEEP
-- The animal system's subtype list (a ewe lamb's market reference is her breed's ram's).
g_currentMission.animalSystem.subTypes = Economics.subTypes

local function group(title, weight, names)
    local fillTypes = {}
    for _, name in ipairs(names) do table.insert(fillTypes, FILL[name]) end
    return { title = title, productionWeight = weight, eatWeight = 1, fillTypes = fillTypes }
end
-- Hof Bergmann 1.5 (character/animalFood.xml): SHEEP has one SERIAL group.
local sheepFood = { consumptionType = 1, groups = { group("grass", 1.0, { "GRASS_WINDROW", "DRYGRASS_WINDROW", "CLOVER_WINDROW" }) } }
SheepSim.food = sheepFood

local foodSystem = g_currentMission.animalFoodSystem
local cowFood = foodSystem:getAnimalFood(GrowthSim.COW_TYPE)
foodSystem.mission.animalSystem.getTypeIndexByName = function(_, name)
    if name == "COW" then return GrowthSim.COW_TYPE end
    if name == "SHEEP" then return SHEEP end
    return nil
end
function foodSystem:getAnimalFood(typeIndex)
    if typeIndex == GrowthSim.COW_TYPE then return cowFood end
    if typeIndex == SHEEP then return sheepFood end
    return nil
end
g_fillTypeManager.getFillTypeByIndex = function(_, index) return { title = g_fillTypeManager:getFillTypeNameByIndex(index) } end
RLFeed.registerSpeciesFeeds(foodSystem)

for _, sub in ipairs(Economics.subTypes) do
    if sub.typeIndex == SHEEP then
        sub.healthIncreaseHour, sub.healthDecreaseHour, sub.healthThresholdFactor = 10, 25, 0.45
        sub.output = sub.output or {}
    end
end


--- Switch the SHEEP curves on (the shipped file has them off) or back off.
function SheepSim.enable(on)
    local config = RLWeightProfiles.getConfig()
    config.types.SHEEP.enabled = on ~= false
    RLGrowth.resetCaches()
end


--- A sheep pen: like FeedSim.makePen, of the SHEEP type with its own groups.
function SheepSim.makePen(animals, stock, opts)
    local pen = FeedSim.makePen(animals, {}, opts)
    local spec = pen.spec_husbandryFood
    spec.animalTypeIndex = SHEEP
    spec.fillLevels, spec.supportedFillTypes = {}, {}
    for _, g in ipairs(sheepFood.groups) do
        for _, index in ipairs(g.fillTypes) do spec.fillLevels[index], spec.supportedFillTypes[index] = 0, true end
    end
    function pen:getAnimalTypeIndex() return SHEEP end
    for name, liters in pairs(stock or {}) do pen:add(name, liters) end
    return pen
end


local function identify(animal, id)
    animal.id = id
    animal.getIdentifiers = function(self) return self.id end
    return animal
end
SheepSim.identify = identify

--- A grown ewe that has lambed (age in months, default 36), with an id.
function SheepSim.ewe(name, id, fields)
    local f = { age = 36, isParent = true }
    for k, v in pairs(fields or {}) do f[k] = v end
    return identify((GrowthSim.makeAnimal(name, f)), id)
end

--- A newborn lamb of a dam (birth weight the breed's mean x factor).
function SheepSim.lamb(name, motherId, id, fields, birthFactor)
    local f = { motherId = motherId }
    for k, v in pairs(fields or {}) do f[k] = v end
    return identify((GrowthSim.newborn(name, f, birthFactor)), id)
end

--- A grown animal of a subtype at an age, its weight its curve's (continuous age kept on it).
function SheepSim.grown(name, id, age, fields)
    local f = { age = math.floor(age) }
    for k, v in pairs(fields or {}) do f[k] = v end
    local animal = identify((GrowthSim.makeAnimal(name, f)), id)
    if animal.rlGrowth ~= nil then animal.rlGrowth.ageMonths = age end
    return animal
end


--- Run hours with the trough kept stocked; ages move on at each month change.
--- @param pen table
--- @param hours number
--- @param stock table|nil name -> liters kept in the trough
--- @param each function|nil Called after every hour with the hour count
function SheepSim.run(pen, hours, stock, each)
    local refill = stock ~= nil and FeedSim.keepStocked(stock) or nil
    local env = GrowthSim.env
    for h = 1, hours do
        if refill ~= nil then refill(pen) end
        FeedSim.hour(pen)
        -- A new month on the game's clock (its first hour has just run): every animal a month older.
        if env.currentHour == 0 and env.currentDayInPeriod == 1 then
            for _, animal in ipairs(pen.animals) do animal.age = animal.age + 1 end
        end
        if each ~= nil then each(h) end
    end
end
