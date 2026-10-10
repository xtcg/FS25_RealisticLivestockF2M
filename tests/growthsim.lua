-- Engine stand-ins and a small simulator for the weight model v2 (RLGrowth): pens with a real
-- feed ledger (RLBodyCondition), animals with the mod's own request, feed and price code, and an
-- hour loop that runs RLGrowth.step as the server's hourly update does. Shared by
-- tests/test_growth.lua; loads tests/economics.lua for the animals.xml subtypes.

ANIMALS_XML = REPO .. "xml/animals.xml"
loadMod("tests/economics.lua")
loadAnimalSection("function Animal:getSellPrice", "function Animal:getDailyRidingTime")

GrowthSim = {}

local FILL = { FORAGE = 1, SILAGE = 2, DRYGRASS_WINDROW = 3, GRASS_WINDROW = 4, MILK = 5, WATER = 6, CALFMILK = 7 }
GrowthSim.FILL = FILL
local FILL_NAMES = {}
for name, index in pairs(FILL) do FILL_NAMES[index] = name end
g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return FILL_NAMES[i] end,
    getFillTypeIndexByName = function(_, n) return FILL[n] end,
}

local COW_TYPE
for _, sub in ipairs(Economics.subTypes) do if sub.typeName == "COW" then COW_TYPE = sub.typeIndex end end
GrowthSim.COW_TYPE = COW_TYPE
AnimalType = { COW = COW_TYPE, HORSE = -1, SHEEP = -2, PIG = -3, CHICKEN = -4 }

local env = g_currentMission.environment
env.daysPerPeriod, env.timeAdjustment, env.currentMonotonicDay, env.currentHour, env.currentDayInPeriod = 1, 1, 1, 0, 1
g_currentMission.animalFoodSystem = { getAnimalFood = function() return nil end }
GrowthSim.env = env

--- The game's clock: one hour on, the day and the day in the period with it.
function GrowthSim.advanceHour()
    env.currentHour = env.currentHour + 1
    if env.currentHour == 24 then
        env.currentHour = 0
        env.currentMonotonicDay = env.currentMonotonicDay + 1
        env.currentDayInPeriod = env.currentDayInPeriod % env.daysPerPeriod + 1
    end
end

function GrowthSim.setDaysPerPeriod(days)
    env.daysPerPeriod, env.timeAdjustment, env.currentDayInPeriod, env.currentHour = days, 1 / days, 1, 0
end

GrowthSim.RATIONS = {
    TMR = { FORAGE = 1 }, silage = { SILAGE = 1 }, hay = { DRYGRASS_WINDROW = 1 }, grass = { GRASS_WINDROW = 1 },
    none = {}, half = { FORAGE = 0.5 },
}
GrowthSim.FOOD_FACTOR = { TMR = 1, silage = 0.8, hay = 0.65, grass = 0.4, none = 0, half = 0.5 }

--- Add a subtype the way a Cow Breeds pack or a map would (food curve borrowed from `like`).
function GrowthSim.addSubType(name, breed, gender, target, like, typeIndex)
    local _, base = Economics.find(like or (gender == "male" and "BULL_ANGUS" or "COW_ANGUS"))
    local sub = { name = name, breed = breed, gender = gender, typeIndex = typeIndex or COW_TYPE, typeName = "COW",
        minWeight = 35, targetWeight = target, reproductionMinAgeMonth = base.reproductionMinAgeMonth,
        food = base.food, milk = base.milk, sellPriceCurve = base.sellPriceCurve }
    table.insert(Economics.subTypes, sub)
    return #Economics.subTypes, sub
end

function GrowthSim.makePen(animals)
    local pen = { spec_husbandryFood = { fillLevels = {}, litersPerHour = 10 }, isServer = true, animals = animals or {} }
    function pen:getName() return "pen" end
    return pen
end

--- An individual animal of a subtype on the mod's own code, neutral genes unless given.
function GrowthSim.makeAnimal(name, fields)
    local index, sub = Economics.find(name)
    assert(sub, name)
    sub.input = sub.input or { food = { get = function(_, age) return Economics.curve(sub.food, age) end } }
    sub.sellPrice = sub.sellPrice or { get = function(_, age) return 1000 + 30 * math.min(age, 30) end }
    local animal = setmetatable({ age = 0, weight = nil, gender = sub.gender, subType = sub.name,
        subTypeIndex = index, animalTypeIndex = sub.typeIndex, health = 100, isLactating = false, isParent = false,
        isPregnant = false, reproduction = 0, input = {}, output = {}, diseases = {}, isIndividual = true,
        genetics = { metabolism = 1, quality = 1, productivity = 1, fertility = 1, health = 1 } }, { __index = Animal })
    animal.getSubType = function() return sub end
    animal.getDiseaseMultipliers = function(self) return self.diseaseMultipliers, 0 end
    animal.getInput = function(self, inputType) return self.input[inputType] or 0 end
    animal.getHealthFactor = function(self) return self.health / 100 end
    animal.isHorse = function() return false end
    for k, v in pairs(fields or {}) do animal[k] = v end
    animal.targetWeight = animal.targetWeight or RLGrowth.getConstructorTarget(sub, animal.genetics, animal.rlGrowth)
        or sub.targetWeight
    if animal.weight == nil then
        animal.weight = RLGrowth.coversSubType(sub) and RLGrowth.getNewAnimalWeight(sub, animal.genetics, animal.age)
            or sub.minWeight
    end
    return animal, sub
end

--- A newborn: its birth weight (the breed's mean x factor unless given) and the v2 state.
function GrowthSim.newborn(name, fields, birthFactor)
    local animal, sub = GrowthSim.makeAnimal(name, fields)
    local binding = RLGrowth.getBinding(sub)
    local _, _, _, gene = RLGrowth.getGeneFactors(animal.genetics.metabolism)
    RLGrowth.initBirth(animal, RLGrowth.getBirthMean(binding) * gene * (birthFactor or 1))
    return animal, sub
end

--- The food request per hour, as Animal:updateInput sets it.
function GrowthSim.refreshRequest(animal)
    local sub = animal:getSubType()
    local numPregnancies = (animal.pregnancy ~= nil and animal.pregnancy.pregnancies ~= nil) and #animal.pregnancy.pregnancies or 0
    animal.input.food = Animal._computeDailyFood(animal.age, animal.isLactating, animal.reproduction, numPregnancies,
        animal:getIntakeGene(), Economics.curve(sub.food, animal.age), 1, animal:getFeedModifier()) / 24
end

--- One feeding: the pen requests what its animals' food inputs say and eats `ration`
--- (liters per liter requested).
function GrowthSim.feed(pen, ration)
    local total = 0
    for _, animal in ipairs(pen.animals) do total = total + animal:getInput("food") end
    pen.spec_husbandryFood.litersPerHour = total
    RLBodyCondition.beginFeeding(pen)
    local requested = pen.spec_husbandryFood.litersPerHour * env.timeAdjustment
    for name, share in pairs(ration) do RLBodyCondition.recordRemoved(pen, FILL[name], share * requested) end
    RLBodyCondition.endFeeding(pen)
end

local function lactationFactor(m) if m >= 10 then return 0 end if m <= 3 then return 0.8 + m / 6 end return 0.8 + (11 - m) / 15 end

--- One hour of a pen: requests and milk at full feed, the feeding, then each animal's step.
--- @return boolean handled (of the first animal)
function GrowthSim.penHour(pen, rationName, opts)
    opts = opts or {}
    for _, animal in ipairs(pen.animals) do
        GrowthSim.refreshRequest(animal)
        local sub = animal:getSubType()
        if #sub.milk > 0 then
            local curve = Economics.curve(sub.milk, animal.age)
            local lactation = animal.isLactating and lactationFactor(animal.monthsSinceLastBirth or 0) or 0
            RLBodyCondition.applyMilk(animal, curve * lactation * animal.genetics.productivity, curve, 1)
        end
    end
    GrowthSim.advanceHour()
    if opts.noLedger then
        pen.spec_husbandryFood.rlNutritionSupply = nil
    else
        GrowthSim.feed(pen, GrowthSim.RATIONS[rationName])
    end
    local handled
    for i, animal in ipairs(pen.animals) do
        local ok = RLGrowth.step(animal, GrowthSim.FOOD_FACTOR[rationName] or 1)
        if i == 1 then handled = ok end
    end
    return handled
end

--- Run whole months: age moves on at each period change, as the game does.
function GrowthSim.months(pen, rationName, months, opts)
    for _ = 1, months do
        for _ = 1, 24 * env.daysPerPeriod do GrowthSim.penHour(pen, rationName, opts) end
        for _, animal in ipairs(pen.animals) do animal.age = animal.age + 1 end
    end
end

--- Raise one animal from birth on a ration until `stop(animal)` or maxMonths; returns the months
--- (to the hour) and the animal.
function GrowthSim.raise(name, rationName, stop, maxMonths, fields, birthFactor)
    local animal = GrowthSim.newborn(name, fields, birthFactor)
    local pen = GrowthSim.makePen({ animal })
    animal.clusterSystem = { owner = pen }
    local hours, perMonth = 0, 24 * env.daysPerPeriod
    while animal.age < (maxMonths or 120) do
        for _ = 1, perMonth do
            GrowthSim.penHour(pen, rationName)
            hours = hours + 1
            if stop(animal) then return hours / perMonth, animal end
        end
        animal.age = animal.age + 1
    end
    return hours / perMonth, animal
end
