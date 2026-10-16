-- Pigs in the real-equivalent nutrition mode (pig P5): engine stand-ins for a pig pen with Hof
-- Bergmann 1.5's pig food (character/animalFood.xml: five SERIAL groups - base feed, grain, protein,
-- roots, piglet feed), the weight profiles' PIG type switched on for the test, and helpers for
-- growing pigs, sows and piglets. Builds on tests/feedsim.lua (its hour loop runs any pen).
-- Shared by tests/test_pig_p5.lua and the offline calibration (tests/pigcalib.lua).

loadMod("tests/feedsim.lua")

PigSim = {}

local FILL = FeedSim.FILL
for _, name in ipairs({ "PIGFOOD", "PIGFOOD_SLOP", "RYE", "SORGHUM", "CANOLA", "SUNFLOWER", "SOYBEAN", "SPENTGRAIN", "POTATO",
    "SUGARBEET", "CARROT", "PARSNIP", "BEETROOT", "PIGLETFOOD" }) do
    if FILL[name] == nil then
        local index = 0
        for _, i in pairs(FILL) do index = math.max(index, i) end
        FILL[name] = index + 1
    end
end
local FILL_NAMES = {}
for name, index in pairs(FILL) do FILL_NAMES[index] = name end
g_fillTypeManager.getFillTypeNameByIndex = function(_, i) return FILL_NAMES[i] end
g_fillTypeManager.getFillTypeIndexByName = function(_, n) return FILL[n] end
g_fillTypeManager.getFillTypeByIndex = function(_, index) return { title = FILL_NAMES[index] } end

local PIG
for _, sub in ipairs(Economics.subTypes) do
    if sub.typeName == "PIG" and PIG == nil then PIG = sub.typeIndex end
end
PigSim.TYPE = PIG
AnimalType.PIG = PIG
g_currentMission.animalSystem.subTypes = Economics.subTypes

local function group(title, weight, names)
    local fillTypes = {}
    for _, name in ipairs(names) do table.insert(fillTypes, FILL[name]) end
    return { title = title, productionWeight = weight, eatWeight = 1, fillTypes = fillTypes }
end
-- Hof Bergmann 1.5 (character/animalFood.xml): PIG, SERIAL.
local pigFood = { consumptionType = 1, groups = {
    group("pigBase", 1.0, { "PIGFOOD", "PIGFOOD_SLOP" }),
    group("pigGrain", 0.6, { "WHEAT", "BARLEY", "RYE", "MAIZE", "SORGHUM", "CANOLA", "SUNFLOWER", "GRAINGRIST" }),
    group("pigProtein", 0.8, { "SOYBEAN", "SPENTGRAIN" }),
    group("pigEarth", 0.6, { "POTATO", "SUGARBEET", "SUGARBEET_CUT", "CARROT", "PARSNIP", "BEETROOT" }),
    group("pigletFood", 2.0, { "PIGLETFOOD" }),
} }
PigSim.food = pigFood

local foodSystem = g_currentMission.animalFoodSystem
local previous = foodSystem.getAnimalFood
function foodSystem:getAnimalFood(typeIndex)
    if typeIndex == PIG then return pigFood end
    return previous(self, typeIndex)
end
local previousIndex = foodSystem.mission.animalSystem.getTypeIndexByName
foodSystem.mission.animalSystem.getTypeIndexByName = function(system, name)
    if name == "PIG" then return PIG end
    return previousIndex(system, name)
end

for _, sub in ipairs(Economics.subTypes) do
    if sub.typeIndex == PIG then
        sub.healthIncreaseHour, sub.healthDecreaseHour, sub.healthThresholdFactor = 10, 25, 0.45
        sub.output = sub.output or {}
    end
end


--- Switch the PIG curves on (the shipped file has them off) or back off.
function PigSim.enable(on)
    RLWeightProfiles.getConfig().types.PIG.enabled = on ~= false
    RLGrowth.resetCaches()
end


--- A pig pen: like FeedSim.makePen, of the PIG type with its own groups.
function PigSim.makePen(animals, stock, opts)
    local pen = FeedSim.makePen(animals, {}, opts)
    local spec = pen.spec_husbandryFood
    spec.animalTypeIndex = PIG
    spec.fillLevels, spec.supportedFillTypes = {}, {}
    for _, g in ipairs(pigFood.groups) do
        for _, index in ipairs(g.fillTypes) do spec.fillLevels[index], spec.supportedFillTypes[index] = 0, true end
    end
    function pen:getAnimalTypeIndex() return PIG end
    for name, liters in pairs(stock or {}) do pen:add(name, liters) end
    return pen
end


local function identify(animal, id)
    animal.id = id
    animal.getIdentifiers = function(self) return self.id end
    return animal
end
PigSim.identify = identify


--- A growing pig of a subtype at a continuous age (months), its weight its curve's.
function PigSim.grown(name, id, age, fields)
    local f = { age = math.floor(age) }
    for k, v in pairs(fields or {}) do f[k] = v end
    local animal = identify((GrowthSim.makeAnimal(name, f)), id)
    if animal.rlGrowth ~= nil then animal.rlGrowth.ageMonths = age end
    return animal
end


--- Run hours with the trough kept stocked; ages move on at each month change.
function PigSim.run(pen, hours, stock, each)
    local refill = stock ~= nil and FeedSim.keepStocked(stock) or nil
    local env = GrowthSim.env
    for h = 1, hours do
        if refill ~= nil then refill(pen) end
        FeedSim.hour(pen)
        if env.currentHour == 0 and env.currentDayInPeriod == 1 then
            for _, animal in ipairs(pen.animals) do animal.age = animal.age + 1 end
        end
        if each ~= nil then each(h) end
    end
end
