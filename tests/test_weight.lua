-- Weight arithmetic (scripts/animal/RLWeightMath.lua) and the fixed feed price of the body
-- condition budget (fixedFeedPrice in xml/bodyCondition.xml): the old weight rule over any period
-- length, a growth line that never loses weight with age, a newborn's weight spread, and what a
-- liter eaten is worth under either price.

ANIMALS_XML = REPO .. "xml/animals.xml"
loadMod("tests/economics.lua")

local env = g_currentMission.environment
env.timeAdjustment, env.currentMonotonicDay, env.currentHour = 1, 1, 0

local COW_TYPE
for _, sub in ipairs(Economics.subTypes) do if sub.typeName == "COW" then COW_TYPE = sub.typeIndex end end

-- The old rule as it was (dev 71c0ce8, Animal:updateWeight): growth per period / (24 x days per
-- period), the losses per game hour. The reference for "unchanged at 1 day per period".
local function oldHour(sub, weight, target, age, metabolism, foodFactor, daysPerPeriod)
    local minWeight, adultMonth = sub.minWeight, RLBreedTraits.getMatureAge(sub)
    local increase = ((target - minWeight) / adultMonth) / (24 * daysPerPeriod)
        * (sub.gender == "female" and RLBreedTraits.getFemaleGrowth(sub) or 1) * (1 + ((adultMonth - age) / 75)) * foodFactor
    if increase < 0 then metabolism = 1 + (1 - metabolism) end
    increase = increase * metabolism
    if increase > 0 then increase = increase * RLBreedTraits.get(sub, "growth") end
    local decrease = 0
    if weight > target then decrease = (weight - target) / (metabolism * 25) end
    if foodFactor == 0 then
        if weight < target then
            decrease = (target - weight) / ((1 - (metabolism - 1)) * 150)
        elseif weight > target then
            decrease = decrease + ((weight - target) / ((1 - (metabolism - 1)) * 150))
        end
    end
    return math.max(weight + increase - decrease, 0.001)
end

-- The old growth line (dev 71c0ce8, RLBreedTraits.getGrownWeight).
local function oldGrownWeight(subType, gender, targetWeight, age, metabolism)
    local minWeight = subType.minWeight or 0
    local matureAge = RLBreedTraits.getMatureAge(subType)
    if matureAge <= 0 or targetWeight <= minWeight then return minWeight end
    local baseGain = (targetWeight - minWeight) / matureAge
    local sex = gender == "female" and RLBreedTraits.getFemaleGrowth(subType) or 1
    local growth = RLBreedTraits.get(subType, "growth")
    local weight, month = minWeight, 0
    while month < age do
        local step = math.min(1, age - month)
        local gain = baseGain * sex * (1 + (matureAge - month) / 75)
        gain = gain > 0 and gain * metabolism * growth or gain * (2 - metabolism)
        weight = math.min(math.max(weight + gain * step, minWeight), targetWeight)
        month = month + step
    end
    return weight
end

--- An intact, healthy animal of a subtype on the old rule (Animal:updateWeight).
local function makeAnimal(name, fields)
    local index, sub = Economics.find(name)
    local animal = setmetatable({ age = 0, weight = sub.minWeight, targetWeight = sub.targetWeight, gender = sub.gender,
        subTypeIndex = index, animalTypeIndex = sub.typeIndex, health = 100, isLactating = false,
        genetics = { metabolism = 1, quality = 1, productivity = 1, fertility = 1, health = 1 } }, { __index = Animal })
    animal.getSubType = function() return sub end
    animal.getDiseaseMultipliers = function() return nil, 0 end
    animal.getGrowthNutrition = function(_, foodFactor) return foodFactor end
    for k, v in pairs(fields or {}) do animal[k] = v end
    return animal, sub
end

--- One game month of the old rule at a period length; age held, as in the audit.
local function month(animal, foodFactor, days)
    env.daysPerPeriod = days
    for _ = 1, 24 * days do animal:updateWeight(foodFactor) end
    env.daysPerPeriod = 1
    return animal.weight
end


-- The old rule: unchanged hour by hour at 1 day per period ------------------------------------

do
    local worst = 0
    for _, case in ipairs({
        { 500, 1000, 12, 1, 0 }, { 500, 1000, 12, 1.5, 0 }, { 500, 1000, 12, 0.3, 0 }, -- starving below target
        { 1200, 1000, 40, 1, 0 }, { 1200, 1000, 40, 1.7, 0 },                          -- starving above it
        { 1100, 1000, 40, 1, 1 }, { 1100, 1000, 40, 0.4, 1 },                          -- above it, fed
        { 300, 1000, 8, 1, 1 }, { 300, 1000, 8, 1.6, 0.5 }, { 35, 600, 0, 1, 1 },      -- growing
    }) do
        local weight, target, age, metabolism, foodFactor = table.unpack(case)
        local animal = makeAnimal("BULL_ANGUS", { weight = weight, targetWeight = target, age = age,
            genetics = { metabolism = metabolism } })
        local expected = weight
        for _ = 1, 24 do
            expected = oldHour(animal:getSubType(), expected, target, age, metabolism, foodFactor, 1)
            animal:updateWeight(foodFactor)
            worst = math.max(worst, math.abs(animal.weight - expected) / expected)
        end
    end
    check(string.format("old rule: at 1 day per period every hour is the old weight (worst %.1e)", worst), worst < 1e-12)
end


-- The old rule: one month is one month whatever the period length ---------------------------

do
    local results = {}
    for _, days in ipairs({ 1, 3, 7, 28 }) do
        results[#results + 1] = month(makeAnimal("BULL_ANGUS", { weight = 500, targetWeight = 1000, age = 12 }), 0, days)
    end
    check(string.format("old rule: a 500 kg animal starving a month keeps %.3f kg at 1 day per period (audit 413.556), "
        .. "%.3f / %.3f / %.3f at 3 / 7 / 28 (were 193.249 / 0.001 / 0.001)", results[1], results[2], results[3], results[4]),
        near(results[1], 413.556, 0.001) and near(results[2], results[1], 1e-6) and near(results[3], results[1], 1e-6)
        and near(results[4], results[1], 1e-6))
end

do
    local fat, starvingFat = {}, {}
    for _, days in ipairs({ 1, 3, 7, 28 }) do
        fat[#fat + 1] = month(makeAnimal("BULL_ANGUS", { weight = 1200, targetWeight = 1000, age = 200 }), 1, days)
        starvingFat[#starvingFat + 1] = month(makeAnimal("BULL_ANGUS", { weight = 1200, targetWeight = 1000, age = 200 }), 0, days)
    end
    local same = true
    for i = 2, 4 do same = same and near(fat[i], fat[1], 1e-6) and near(starvingFat[i], starvingFat[1], 1e-6) end
    check(string.format("old rule: an animal 200 kg over its target returns to it at the same rate for 1/3/7/28 days per "
        .. "period (fed %.2f, starving %.2f kg after a month)", fat[1], starvingFat[1]), same
        and fat[1] > 1000 and fat[1] < 1200 and starvingFat[1] < fat[1])
end

do
    -- Growth already was per period; with the losses integrated the whole month agrees too.
    local weights = {}
    for _, days in ipairs({ 1, 3, 7, 28 }) do
        local calf = makeAnimal("BULL_ANGUS", { age = 2, weight = 90 })
        for _ = 1, 4 do month(calf, 1, days); calf.age = calf.age + 1 end
        weights[#weights + 1] = calf.weight
    end
    check(string.format("old rule: a calf fed 4 months weighs the same at 1/3/7/28 days per period (%.3f %.3f %.3f %.3f)",
        weights[1], weights[2], weights[3], weights[4]), near(weights[2], weights[1], 1e-6)
        and near(weights[3], weights[1], 1e-6) and near(weights[4], weights[1], 1e-6))
end


-- Age: structural growth never turns into a loss ---------------------------------------------

do
    local animal = makeAnimal("COW_HOLSTEIN", { age = 300 })
    animal.weight = animal.targetWeight
    local before = animal.weight
    for _ = 1, 24 do animal:updateWeight(1) end
    local old = before
    for _ = 1, 24 do old = oldHour(animal:getSubType(), old, animal.targetWeight, 300, 1, 1, 1) end
    check(string.format("age: a fed 25-year-old cow at her target keeps her weight for a month (%.3f kg; the old rule took "
        .. "her to %.3f)", animal.weight, old), animal.weight == before and old < before)

    local growing = makeAnimal("COW_HOLSTEIN", { age = 300, weight = 600 })
    for _ = 1, 24 do growing:updateWeight(1) end
    check("age: an old animal below its target no longer loses weight when fed", growing.weight == 600)
end

do
    local lineOk, sameOk, gainOk, details = true, true, true, {}
    for _, sub in ipairs(Economics.subTypes) do
        local matureAge = RLBreedTraits.getMatureAge(sub)
        if matureAge > 0 and sub.targetWeight > sub.minWeight then
            for _, metabolism in ipairs({ 0.25, 1, 1.75 }) do
                local target = sub.targetWeight * (1 + 0.4 * (metabolism - 1))
                local last = 0
                for age = 0, 300, 3 do
                    local weight = RLBreedTraits.getGrownWeight(sub, sub.gender, target, age, metabolism)
                    if weight < last - 1e-9 or weight > target + 1e-9 then lineOk = false; details[#details + 1] = sub.name end
                    last = weight
                    if RLBreedTraits.getLineGain(sub, sub.gender, target, age, metabolism) < 0 then gainOk = false end
                    -- Wherever the old age factor was not yet negative the line is the old one.
                    if age <= matureAge + 75 then
                        local old = oldGrownWeight(sub, sub.gender, target, age, metabolism)
                        if math.abs(weight - old) > 1e-9 * math.max(old, 1) then sameOk = false; details[#details + 1] = sub.name .. "@" .. age end
                    end
                end
            end
        end
    end
    check("age: every subtype's growth line rises to its target and stays there up to 300 months (" .. table.concat(details, " ") .. ")", lineOk)
    check("age: the line's monthly gain is never negative", gainOk)
    check("age: up to mature age + 75 months the line is exactly the old one", sameOk)
end

do
    local _, sub = Economics.find("BULL_ANGUS")
    local weight, gain = RLBreedTraits.getGrownLine(sub, "male", 1000, 12, 1)
    local after = RLBreedTraits.getGrownWeight(sub, "male", 1000, 13, 1)
    local grownWeight, grownGain = RLBreedTraits.getGrownLine(sub, "male", 1000, 200, 1)
    check("line: the gain getGrownLine gives is the next month's, and nothing once grown",
        near(weight + gain, after, 1e-9) and gain > 0 and near(grownWeight, 1000, 1e-9) and grownGain == 0)
end


-- A newborn's weight: minWeight is the line's birth weight, not a floor -----------------------

do
    local _, sub = Economics.find("BULL_ANGUS")
    local function draw(age, roll) return RLBreedTraits.getNewAnimalWeight(sub, "male", sub.targetWeight, age, 1, function() return roll end) end
    check(string.format("birth: a newborn drawn at 85%% weighs %.2f kg = 0.85 x minWeight %.1f (was lifted to minWeight)",
        draw(0, 85), sub.minWeight), near(draw(0, 85), 0.85 * sub.minWeight, 1e-9) and near(draw(0, 115), 1.15 * sub.minWeight, 1e-9))
end


-- Feed price: the need-based price and the fixed one -----------------------------------------

local M = RLNutritionMath
local config = RLBodyConditionConfig.get()

check("price: the shipped file keeps the need-based price (fixedFeedPrice false)", config.fixedFeedPrice == false)

do
    local function supply(growth, extra)
        local input = { dtMonths = 1, weight = 600, reserve = 0.45, capacityKg = 200, minWeight = 35, targetWeight = 1000,
            potentialGrowthKg = growth, intakeLiters = 100, referenceLiters = 100, intakeCapacity = 1, reserveCeiling = 0.45 }
        for k, v in pairs(extra or {}) do input[k] = v end
        return M.step(input, config).supplyNU
    end
    local fixed = { referenceWeight = 600, referenceGrowthKg = 10 }
    check(string.format("price: need-based, the same 100 liters are worth %.2f NU to an animal growing 10 kg and %.2f to one "
        .. "growing 20 (audit 945.54 / 1345.54)", supply(10), supply(20)), near(supply(10), 945.54, 0.01) and near(supply(20), 1345.54, 0.01))
    check(string.format("price: fixed, they are worth %.2f NU to both", supply(10, fixed)),
        near(supply(10, fixed), supply(20, fixed), 1e-9) and near(supply(10, fixed), supply(10), 1e-9))
    check("price: fixed, a heavier animal gets nothing more for the same liters",
        near(supply(10, { weight = 800, referenceWeight = 600, referenceGrowthKg = 10 }), supply(10, fixed), 1e-9))
end

do
    -- A disease's lost growth is paid like growth and gains nothing: the same full ration lays
    -- down the same reserve and the same frame share as before, the rest is spent on the disease.
    local base = { dtMonths = 1, weight = 400, reserve = 0.45, capacityKg = 200, minWeight = 35, targetWeight = 1000,
        intakeLiters = 100, referenceLiters = 100, intakeCapacity = 1.1, reserveCeiling = 0.6,
        referenceWeight = 400, referenceGrowthKg = 20 }
    local function run(growth, disease)
        local input = {}
        for k, v in pairs(base) do input[k] = v end
        input.potentialGrowthKg, input.diseaseLossKg = growth, disease
        return M.step(input, config)
    end
    local healthy, sick, unaccounted = run(20, 0), run(10, 10), run(10, 0)
    check(string.format("price: fixed, a disease taking half the growth halves the frame gain (%.1f / %.1f kg) and the reserve "
        .. "laid down stays the healthy one's (%.2f / %.2f kg; %.2f if the lost growth were free)", sick.frameGainKg,
        healthy.frameGainKg, sick.reserveKg, healthy.reserveKg, unaccounted.reserveKg),
        near(sick.frameGainKg, healthy.frameGainKg / 2, 1e-9) and near(sick.reserveKg, healthy.reserveKg, 1e-9)
        and unaccounted.reserveKg > healthy.reserveKg + 1)
end

do
    -- Ledger and bounds hold under the fixed price, with a disease taking part of the growth.
    local seed = 7
    local function rand() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
    local ledgerOk, weightOk = true, true
    for _ = 1, 2000 do
        local input = { dtMonths = rand() < 0.5 and 1 / 24 or rand(), weight = 200 + rand() * 800, reserve = rand(),
            capacityKg = 50 + rand() * 200, targetWeight = 300 + rand() * 900, potentialGrowthKg = rand() * 40,
            diseaseLossKg = rand() < 0.5 and rand() * 20 or 0, potentialMilk = rand() < 0.3 and rand() * 500 or 0,
            anchorMilk = rand() * 400, isLactating = rand() < 0.3, pregnancyProgress = rand(), numFetuses = rand() < 0.3 and 1 or 0,
            intakeLiters = rand() * 600, referenceLiters = 300, referenceWeight = 200 + rand() * 800,
            referenceGrowthKg = rand() * 40, intakeCapacity = 0.9 + rand() * 0.7, minWeight = rand() * 300,
            reserveTarget = rand() < 0.5 and rand() or nil, reserveCeiling = rand(), balanceEMA = 0, lossRateEMA = 0 }
        local r = M.step(input, config)
        local inflow = r.supplyNU + r.mobilizedNU + r.catabolismNU
        local outflow = r.paidNU + r.depositNU + r.lostNU
        if math.abs(inflow - outflow) > 1e-6 * math.max(inflow, 1) then ledgerOk = false end
        local expected = input.weight + r.frameGainKg + r.reserveKg - r.ageLossKg - r.catabolismKg - r.excessDecayKg
        if math.abs(r.weight - expected) > 1e-9 * input.weight then weightOk = false end
    end
    check("price: fixed, supply + mobilised + catabolism = paid + deposited + lost, for any input", ledgerOk)
    check("price: fixed, weight moves by frame gain + reserve kg - losses, nothing else", weightOk)
end


-- Feed price through the adapter -------------------------------------------------------------

local FILL = { FORAGE = 1, SILAGE = 2, DRYGRASS_WINDROW = 3, GRASS_WINDROW = 4 }
local FILL_NAMES = {}
for name, index in pairs(FILL) do FILL_NAMES[index] = name end
g_fillTypeManager = { getFillTypeNameByIndex = function(_, i) return FILL_NAMES[i] end }
AnimalType = { COW = COW_TYPE, HORSE = -1 }
g_currentMission.animalFoodSystem = { getAnimalFood = function() return nil end }

local function advanceHour()
    env.currentHour = env.currentHour + 1
    if env.currentHour == 24 then env.currentHour = 0; env.currentMonotonicDay = env.currentMonotonicDay + 1 end
end

--- A covered animal in its own pen, its request as Animal:updateInput sets it.
local function makeCovered(name, fields)
    local animal, sub = makeAnimal(name, fields)
    sub.input = sub.input or { food = { get = function(_, age) return Economics.curve(sub.food, age) end } }
    animal.input = {}
    animal.isParent, animal.isPregnant, animal.reproduction = false, false, 0
    animal.getGrowthNutrition = nil
    animal.getInput = function(self, inputType) return self.input[inputType] or 0 end
    local pen = { spec_husbandryFood = { fillLevels = {}, litersPerHour = 0 }, isServer = true }
    function pen:getName() return "pen" end
    animal.clusterSystem = { owner = pen }
    return animal, sub, pen
end

--- One hour in its own pen eating `eaten` (default all) of its request of `fill` (default TMR).
local function hour(animal, pen, eaten, fill)
    local sub = animal:getSubType()
    animal.input.food = Animal._computeDailyFood(animal.age, animal.isLactating, animal.reproduction, 0,
        animal.genetics.metabolism, Economics.curve(sub.food, animal.age), 1, animal:getFeedModifier()) / 24
    pen.spec_husbandryFood.litersPerHour = animal.input.food
    advanceHour()
    RLBodyCondition.beginFeeding(pen)
    RLBodyCondition.recordRemoved(pen, FILL[fill or "FORAGE"], (eaten or 1) * animal.input.food * env.timeAdjustment)
    RLBodyCondition.endFeeding(pen)
    RLBodyCondition.step(animal)
    return animal.rlNutrition
end

--- Months a bull takes from birth to its slaughter reference on one feed: the old rule as a calf,
--- the budget from 6 months (as tests/test_bodycondition.lua raises them).
local ROUTES = { TMR = { "FORAGE", "TMR" }, silage = { "SILAGE", "silage" }, hay = { "DRYGRASS_WINDROW", "hay" },
    grass = { "GRASS_WINDROW", "grass" } }
local function raise(name, route, maxMonths)
    local fill, ration = ROUTES[route][1], Economics.RATIONS[ROUTES[route][2]]
    local animal, sub, pen = makeCovered(name)
    pen.spec_husbandryFood.rlForageShares = ration[2]
    local reference = Economics.reference(sub)
    local hours = 0
    while animal.weight < reference and animal.age < maxMonths do
        for _ = 1, 24 do
            if animal.age < config.calfLegacyUntilAgeMonth then
                advanceHour()
                animal:updateWeight(ration[1])
            else
                hour(animal, pen, 1, fill)
            end
            hours = hours + 1
            if animal.weight >= reference then break end
        end
        if animal.weight < reference then animal.age = animal.age + 1 end
    end
    return hours / 24
end

do
    config.fixedFeedPrice = true

    -- A steer and a bull, both healthy, of the same genes, age and weight, eating the same liters.
    local bull, _, bullPen = makeCovered("BULL_ANGUS", { age = 12, weight = 380 })
    local steer, _, steerPen = makeCovered("BULL_ANGUS", { age = 12, weight = 380, isCastrated = true })
    hour(bull, bullPen); hour(steer, steerPen)
    local bullInput = RLBodyCondition.buildStepInput(bull, bull.bodyCondition, 100, 1, 1 / 24)
    local steerInput = RLBodyCondition.buildStepInput(steer, steer.bodyCondition, 100, 1, 1 / 24)
    local bullSupply = M.step(bullInput, config).supplyNU
    local steerSupply = M.step(steerInput, config).supplyNU
    check(string.format("adapter: fixed, a steer's liters are worth what a bull's are (%.3f / %.3f NU), not 15%% more",
        steerSupply, bullSupply), near(steerSupply, bullSupply, 1e-9))

    -- A sick bull (half its growth) gets the same feed value, spends the rest on the disease and
    -- lays down no more reserve than a healthy one.
    local healthy, _, healthyPen = makeCovered("BULL_ANGUS", { age = 12, weight = 380 })
    local sick, _, sickPen = makeCovered("BULL_ANGUS", { age = 12, weight = 380 })
    sick.getDiseaseMultipliers = function() return { weightGain = 0.5 }, 1 end
    for _ = 1, 24 * 3 do hour(healthy, healthyPen); hour(sick, sickPen) end
    local sickInput = RLBodyCondition.buildStepInput(sick, sick.bodyCondition, 100, 1, 1 / 24)
    local healthyInput = RLBodyCondition.buildStepInput(healthy, healthy.bodyCondition, 100, 1, 1 / 24)
    check(string.format("adapter: fixed, a sick bull grows less (%.1f / %.1f kg in 3 months) and is no fatter (reserve %.3f / %.3f)",
        sick.weight - 380, healthy.weight - 380, sick.bodyCondition.reserve, healthy.bodyCondition.reserve),
        sick.weight < healthy.weight and sick.bodyCondition.reserve <= healthy.bodyCondition.reserve + 1e-9
        and sickInput.diseaseLossKg > 0 and near(sickInput.referenceGrowthKg, healthyInput.referenceGrowthKg, 1e-9))

    -- A cow's feed is priced for the milk of a healthy cow while she is lactating.
    local cow = makeCovered("COW_HOLSTEIN", { age = 48, weight = 730, isParent = true, isLactating = true })
    RLBodyCondition.applyMilk(cow, 0, 300, 0)
    check("adapter: a milking cow whose disease stops her milk keeps the need-based anchor 0 and the fixed anchor of a healthy cow",
        cow.rlMilk.anchor == 0 and near(cow.rlMilk.lineAnchor, 300 * config.lactationMeanFactor, 1e-9))

    config.fixedFeedPrice = false
end

do
    -- Under the need-based price nothing of the fixed price's input is set.
    local bull, _, pen = makeCovered("BULL_ANGUS", { age = 12, weight = 380 })
    hour(bull, pen)
    local input = RLBodyCondition.buildStepInput(bull, bull.bodyCondition, 100, 1, 1 / 24)
    check("adapter: need-based, the step is priced by the animal's own request and need",
        input.referenceWeight == nil and input.diseaseLossKg == nil
        and near(input.referenceLiters, RLBodyCondition.getReferenceIntake(bull), 1e-12))
end

do
    -- The fixed price does not depend on the period length either.
    config.fixedFeedPrice = true
    local weights = {}
    for _, days in ipairs({ 1, 3, 7 }) do
        env.daysPerPeriod, env.timeAdjustment = days, 1 / days
        local bull, _, pen = makeCovered("BULL_LIMOUSIN", { age = 8, weight = 300 })
        for _ = 1, 6 do
            for _ = 1, 24 * days do hour(bull, pen, 0.8) end
            bull.age = bull.age + 1
        end
        weights[#weights + 1] = bull.weight
    end
    env.daysPerPeriod, env.timeAdjustment = 1, 1
    config.fixedFeedPrice = false
    check(string.format("time: fixed price, 1, 3 and 7 days per period give the same weight after 6 months (%.1f %.1f %.1f)",
        weights[1], weights[2], weights[3]),
        math.abs(weights[2] / weights[1] - 1) < 0.01 and math.abs(weights[3] / weights[1] - 1) < 0.01)
end

do
    -- What the fixed price changes: nothing for bulls on full TMR, which stay on their line; slow
    -- forage routes fall behind their line, and once the line is grown its feed carries no growth
    -- any more. This is why fixedFeedPrice ships off until the growth curves are replaced.
    local tmrOk, details = true, {}
    for _, name in ipairs(Economics.BULLS) do
        local need = raise(name, "TMR", 120)
        config.fixedFeedPrice = true
        local fixed = raise(name, "TMR", 120)
        config.fixedFeedPrice = false
        details[#details + 1] = string.format("%s %.1f/%.1f", name:gsub("BULL_", ""), need, fixed)
        if math.abs(fixed - need) > 0.05 then tmrOk = false end
    end
    check("fixed price: every bull on TMR reaches its slaughter reference in the same month (" .. table.concat(details, ", ") .. ")", tmrOk)

    local needHay, needGrass = raise("BULL_ANGUS", "hay", 120), raise("BULL_HIGHLAND_CATTLE", "grass", 120)
    config.fixedFeedPrice = true
    local fixedHay, fixedGrass = raise("BULL_ANGUS", "hay", 120), raise("BULL_HIGHLAND_CATTLE", "grass", 120)
    config.fixedFeedPrice = false
    check(string.format("fixed price: behind their line, an Angus on hay takes %.1f months (need-based %.1f) and a Highland on "
        .. "grass %.1f (need-based %.1f): it stops growing once its line is grown", fixedHay, needHay, fixedGrass, needGrass),
        fixedHay > needHay and fixedGrass > needGrass + 6)
end

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
