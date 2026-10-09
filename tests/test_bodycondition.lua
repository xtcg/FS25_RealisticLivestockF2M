-- Body condition of cattle (scripts/nutrition, xml/bodyCondition.xml): the budget's ledger and
-- bounds, the calibration against the old growth line and milk yield, the feed ledger, the
-- factors the rest of the mod reads, and saving / streaming the state.

ANIMALS_XML = REPO .. "xml/animals.xml"
loadMod("tests/economics.lua")

local M = RLNutritionMath

-- Engine stand-ins --------------------------------------------------------------------------

local FILL = { FORAGE = 1, SILAGE = 2, DRYGRASS_WINDROW = 3, GRASS_WINDROW = 4, MILK = 5, WATER = 6, PIGFOOD = 7 }
local FILL_NAMES = {}
for name, index in pairs(FILL) do FILL_NAMES[index] = name end
g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return FILL_NAMES[i] end,
    getFillTypeIndexByName = function(_, n) return FILL[n] end,
}

local COW_TYPE
for _, sub in ipairs(Economics.subTypes) do if sub.typeName == "COW" then COW_TYPE = sub.typeIndex end end
AnimalType = { COW = COW_TYPE, HORSE = -1 }

local env = g_currentMission.environment
env.daysPerPeriod, env.timeAdjustment, env.currentMonotonicDay, env.currentHour = 1, 1, 1, 0
g_currentMission.animalFoodSystem = { getAnimalFood = function() return nil end }

local function advanceHour()
    env.currentHour = env.currentHour + 1
    if env.currentHour == 24 then env.currentHour = 0; env.currentMonotonicDay = env.currentMonotonicDay + 1 end
end

local function setDaysPerPeriod(days)
    env.daysPerPeriod, env.timeAdjustment = days, 1 / days
end

local config = RLBodyConditionConfig.get()

-- A pen and an animal on the real adapter ----------------------------------------------------

--- Rations as liters eaten per liter requested, by fill type.
local RATIONS = {
    TMR = { FORAGE = 1 }, silage = { SILAGE = 1 }, hay = { DRYGRASS_WINDROW = 1 }, grass = { GRASS_WINDROW = 1 },
    none = {},
}

local function makePen(animals)
    local pen = { spec_husbandryFood = { fillLevels = {}, litersPerHour = 10 }, isServer = true, animals = animals }
    function pen:getName() return "pen" end
    return pen
end

--- One feeding: the pen requests what its animals' food inputs say (as the engine does) and eats
--- `ration` (liters per liter requested) of it.
local function feed(pen, ration)
    if pen.animals ~= nil then
        local total = 0
        for _, animal in ipairs(pen.animals) do total = total + animal:getInput("food") end
        pen.spec_husbandryFood.litersPerHour = total
    end
    RLBodyCondition.beginFeeding(pen)
    local requested = pen.spec_husbandryFood.litersPerHour * env.timeAdjustment
    for name, share in pairs(ration) do RLBodyCondition.recordRemoved(pen, FILL[name], share * requested) end
    RLBodyCondition.endFeeding(pen)
end

local function makeAnimal(name, fields)
    local index, sub = Economics.find(name)
    sub.input = sub.input or { food = { get = function(_, age) return Economics.curve(sub.food, age) end } }
    local animal = setmetatable({ age = 0, weight = sub.minWeight, targetWeight = sub.targetWeight, gender = sub.gender,
        subTypeIndex = index, animalTypeIndex = sub.typeIndex, health = 100, isLactating = false, isParent = false,
        isPregnant = false, reproduction = 0, input = {},
        genetics = { metabolism = 1, quality = 1, productivity = 1, fertility = 1, health = 1 } }, { __index = Animal })
    animal.getSubType = function() return sub end
    animal.getDiseaseMultipliers = function() return nil, 0 end
    animal.getInput = function(self, inputType) return self.input[inputType] or 0 end
    for k, v in pairs(fields or {}) do animal[k] = v end
    return animal, sub
end

--- The animal's food request per hour, as Animal:updateInput sets it.
local function refreshRequest(animal)
    local sub = animal:getSubType()
    local numPregnancies = (animal.pregnancy ~= nil and animal.pregnancy.pregnancies ~= nil) and #animal.pregnancy.pregnancies or 0
    animal.input.food = Animal._computeDailyFood(animal.age, animal.isLactating, animal.reproduction, numPregnancies,
        animal.genetics.metabolism, Economics.curve(sub.food, animal.age), 1, animal:getFeedModifier()) / 24
end

local function lactationFactor(m) if m >= 10 then return 0 end if m <= 3 then return 0.8 + m / 6 end return 0.8 + (11 - m) / 15 end

--- One hour for one animal in its pen: its request and milk at full feed (as updateInput and
--- updateOutput record them), the feeding, then the step. Returns the liters of milk its budget
--- paid for this hour (output liters per hour).
local function hour(animal, pen, ration, sub)
    pen.animals = pen.animals or { animal }
    refreshRequest(animal)
    if sub ~= nil and #sub.milk > 0 then
        local curve = Economics.curve(sub.milk, animal.age)
        local lactation = animal.isLactating and lactationFactor(animal.monthsSinceLastBirth or 0) or 0
        RLBodyCondition.applyMilk(animal, curve * lactation * animal.genetics.productivity, curve, 1)
    end
    advanceHour()
    feed(pen, ration)
    local handled = RLBodyCondition.step(animal)
    if not handled then animal:updateWeight(1) end
    local paid = animal.rlMilkPaid
    return (paid ~= nil and paid.tick == RLBodyCondition.getTickId()) and paid.litersPerHour or 0, handled
end

--- Raise a bull on the new rules from a weaned calf on the old line until its slaughter reference.
local function raiseNew(name, rationName, maxMonths)
    local animal, sub = makeAnimal(name)
    local pen = makePen({ animal })
    animal.clusterSystem = { owner = pen }
    pen.spec_husbandryFood.rlForageShares = Economics.RATIONS[rationName] and Economics.RATIONS[rationName][2]
    local reference = Economics.reference(sub)
    local hours = 0
    while animal.weight < reference and animal.age < (maxMonths or 120) do
        for _ = 1, 24 do
            if animal.age < config.calfLegacyUntilAgeMonth then
                advanceHour()
                animal:updateWeight(Economics.RATIONS[rationName][1])
            else
                hour(animal, pen, RATIONS[rationName])
            end
            hours = hours + 1
            if animal.weight >= reference then break end
        end
        if animal.weight < reference then animal.age = animal.age + 1 end
    end
    return hours / 24, animal, reference
end

-- Config -------------------------------------------------------------------------------------

check("config: shipped xml/bodyCondition.xml is valid and enabled", config.enabled == true and config.invalidReason == nil)
check("config: values read from the file", near(config.maintenancePerKgMetabolic, 4.5, 1e-6)
    and near(config.feedEnergy.SILAGE, 0.82, 1e-6) and near(config.curves.yield[1][2], 0.92, 1e-6))

local _, sub = Economics.find("COW_HOLSTEIN")
check("config: Holstein lactating intake from its breed element",
    near(RLBreedTraits.resolve(config.layers, sub, "intakeLactating", config.intakeLactating), 0.93, 1e-6)
    and near(RLBreedTraits.resolve(config.layers, select(2, Economics.find("COW_SWISS_BROWN")), "intakeLactating",
        config.intakeLactating), config.intakeLactating, 1e-6))

do
    local bad = table.clone(config); bad.curves = config.curves; bad.layers = config.layers
    bad.depositNUPerKg = bad.mobilizeNUPerKg
    local ok, reason = RLBodyConditionConfig.validate(bad)
    check("config: deposit cost must exceed what mobilising returns", ok == false and reason:find("depositNUPerKg") ~= nil)

    bad = table.clone(config); bad.layers = config.layers
    bad.curves = table.clone(config.curves); bad.curves.yield = { { 50, 1 }, { 20, 0.9 } }
    ok = RLBodyConditionConfig.validate(bad)
    check("config: an unsorted curve is rejected", ok == false)

    local parsed = RLBodyConditionConfig.parse(nil)
    check("config: no file gives the defaults, enabled", parsed.enabled and parsed.maintenancePerKgMetabolic == 4.5)
end

-- Pure step: ledger and bounds ---------------------------------------------------------------

local seed = 12345
local function rand() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end

local ledgerOk, boundsOk, directionOk, weightOk = true, true, true, true
for i = 1, 400 do
    local lactating = rand() < 0.5
    local input = {
        dtMonths = 1 / 24 * (1 + math.floor(rand() * 3)), weight = 300 + rand() * 500, reserve = rand(),
        capacityKg = 60 + rand() * 160, targetWeight = 500 + rand() * 600, potentialGrowthKg = rand() * 40,
        potentialMilk = lactating and rand() * 500 or 0,
        anchorMilk = lactating and rand() * 450 or 0, isLactating = lactating,
        pregnancyProgress = rand(), numFetuses = rand() < 0.3 and 1 or 0, intakeLiters = rand() * 1.5 * 300,
        referenceLiters = 300, intakeCapacity = 0.9 + rand() * 0.7, minWeight = rand() * 300,
        reserveTarget = rand() < 0.5 and rand() or nil, reserveCeiling = rand(),
    }
    local r = M.step(input, config)
    local left = r.supplyNU + r.mobilizedNU + r.catabolismNU
    local right = r.paidNU + r.depositNU + r.lostNU
    if math.abs(left - right) > 1e-6 * math.max(1, left) then ledgerOk = false end
    if r.reserve < 0 or r.reserve > 1 or r.weight <= 0 or r.milkFraction < 0 or r.milkFraction > 1 + 1e-9 then boundsOk = false end
    if r.depositNU > 1e-9 and r.mobilizedNU > 1e-9 then directionOk = false end
    local expected = input.weight + r.frameGainKg + r.reserveKg - r.catabolismKg - r.excessDecayKg
    if math.abs(r.weight - expected) > 1e-6 then weightOk = false end
end
check("step: supply + mobilised + catabolism = paid + deposited + lost, for any input", ledgerOk)
check("step: reserve stays 0..1, weight positive, milk share 0..1", boundsOk)
check("step: never stores and mobilises reserve in the same step", directionOk)
check("step: weight moves by frame gain + reserve kg - losses, nothing else", weightOk)

do
    local base = { dtMonths = 1 / 24, weight = 600, reserve = config.minReserve, capacityKg = 140, targetWeight = 700,
        potentialGrowthKg = 20, potentialMilk = 400, anchorMilk = 400, isLactating = true,
        pregnancyProgress = 0, numFetuses = 0, intakeLiters = 0, referenceLiters = 300, intakeCapacity = 1, reserveCeiling = 0.75 }
    local r = M.step(base, config)
    check("step: no food and no reserve: no gain, no milk, no reserve, maintenance unmet",
        r.frameGainKg == 0 and r.milkFraction == 0 and r.reserve <= base.reserve and r.maintenanceDeficitNU >= 0
        and r.weight < base.weight)

    base.reserve = 0.6
    local a, b = M.step(base, config), M.step(base, config)
    check("step: deterministic", a.weight == b.weight and a.reserve == b.reserve)
    check("step: a starving cow with reserve loses at most lossRatePerMonth of it",
        base.reserve - a.reserve <= config.lossRatePerMonth * base.dtMonths + 1e-12 and a.reserve < base.reserve)

    base.intakeLiters, base.isLactating, base.potentialMilk, base.anchorMilk, base.potentialGrowthKg = 900, false, 0, 0, 0
    base.reserve = 0.74
    r = M.step(base, config)
    check("step: a surplus fills the reserve only to the ceiling and loses the rest",
        r.reserve <= 0.75 + 1e-12 and r.lostNU > 0)
end

-- Curves -------------------------------------------------------------------------------------

local function yield(score) return M.interpolate(config.curves.yield, score) end
check("curves: yield 1 across the moderate band 65..80, lower when lean or overfat",
    yield(65) == 1 and yield(72) == 1 and yield(80) == 1 and yield(40) < 1 and yield(95) < 1)
check("curves: yield continuous at 80 and 90", math.abs(yield(79.9) - yield(80.1)) < 0.001
    and math.abs(yield(89.9) - yield(90.1)) < 0.002)
check("curves: finish score 65 at the initial reserve 0.45, BCS 2.8",
    M.interpolate(config.curves.finishScore, 0.45) == 65 and near(M.getBCS(0.45), 2.8, 1e-9))

-- Conception ---------------------------------------------------------------------------------

local sameAsOld = true
for f = -0.5, 2.5, 0.05 do
    for _, scale in ipairs({ 0.5, 0.25 }) do
        local old = (2 - f) * scale
        local new = 1 - RLBodyCondition.getConceptionProbability(f, scale, 1)
        -- the roll passes on random() >= threshold, random() in [0, 1)
        local oldPass, newPass = math.min(math.max(old, 0), 1), new
        if math.abs(oldPass - newPass) > 1e-9 then sameAsOld = false end
    end
end
check("conception: with condition factor 1 both rolls keep the old threshold", sameAsOld)
check("conception: condition factor 0 never passes", RLBodyCondition.getConceptionProbability(1.5, 0.25, 0) == 0)

do
    local cow = makeAnimal("COW_HOLSTEIN", { age = 40, isParent = true, weight = 730 })
    cow.bodyCondition = RLBodyCondition.createState(cow, "test")
    local normal = RLBodyCondition.getFertilityFactor(cow)
    cow.bodyCondition.reserve = 0.1
    local thin = RLBodyCondition.getFertilityFactor(cow)
    cow.bodyCondition.reserve = 0.5
    cow.bodyCondition.lossRateEMA = 0.12
    local losing = RLBodyCondition.getFertilityFactor(cow)
    check("conception: normal BCS keeps the roll, a thin or fast-losing cow less",
        normal == 1 and thin < 0.5 and near(losing, 0.75, 1e-9))
    local bull = makeAnimal("BULL_ANGUS", { age = 20, weight = 600 })
    check("conception: a male's factor is 1", RLBodyCondition.getFertilityFactor(bull) == 1)
end

-- Coverage -----------------------------------------------------------------------------------

do
    local calf = makeAnimal("BULL_ANGUS", { age = 3, weight = 100 })
    local pig = makeAnimal("BOAR_LANDRACE", { age = 10, weight = 100 })
    local bull = makeAnimal("BULL_ANGUS", { age = 12, weight = 400 })
    check("coverage: cattle past the calf stage only", not RLBodyCondition.isEligible(calf)
        and not RLBodyCondition.isEligible(pig) and RLBodyCondition.isEligible(bull))
    check("coverage: factors are 1 for an animal not covered", RLBodyCondition.getYieldFactor(pig) == 1
        and RLBodyCondition.getMarketFactor(calf) == 1 and RLBodyCondition.getIntakeFactor(pig) == 1)
    check("coverage: reading a covered animal creates no state", RLBodyCondition.getFinishScore(bull) > 0
        and bull.bodyCondition == nil)
end

-- Feed ledger --------------------------------------------------------------------------------

do
    local pen = makePen()
    pen.spec_husbandryFood.litersPerHour = 100
    pen.spec_husbandryMeadow = { fillLevels = { [FILL.GRASS_WINDROW] = 500 } }

    RLBodyCondition.recordRemoved(pen, FILL.FORAGE, 999)               -- outside a feeding: ignored
    RLBodyCondition.beginFeeding(pen)
    RLBodyCondition.recordRemoved(pen, FILL.FORAGE, 40)
    RLBodyCondition.recordRemoved(pen, FILL.DRYGRASS_WINDROW, 20)
    pen.spec_husbandryMeadow.fillLevels[FILL.GRASS_WINDROW] = 470          -- the meadow lost 30 l
    RLBodyCondition.endFeeding(pen)

    local supply = pen.spec_husbandryFood.rlNutritionSupply
    check("ledger: trough removals in the feeding plus the meadow's loss, nothing outside it",
        supply.valid and near(supply.eaten, 90, 1e-9) and near(supply.consumed[FILL.FORAGE], 40, 1e-9)
        and near(supply.consumed[FILL.GRASS_WINDROW], 30, 1e-9))
    check("ledger: energy per liter requested by forage category",
        near(supply.energyShare.silage, 0.40, 1e-9) and near(supply.energyShare.hay, 20 * 0.70 / 100, 1e-9)
        and near(supply.energyShare.grass, 30 * 0.55 / 100, 1e-9))

    local holstein = makeAnimal("BULL_HOLSTEIN", { age = 12, weight = 400, input = { food = 10 } })
    local highland = makeAnimal("BULL_HIGHLAND_CATTLE", { age = 12, weight = 300, input = { food = 10 } })
    local hIntake, hAllocated, hShare = RLBodyCondition.getAllocatedIntake(holstein, supply)
    local gIntake = RLBodyCondition.getAllocatedIntake(highland, supply)
    check("ledger: an animal gets its request's share of each liter eaten, read through its breed's traits",
        near(hShare, 0.1, 1e-12) and near(hAllocated, 9, 1e-9)
        and near(hIntake, 0.1 * (40 * 1.10 + 20 * 0.70 * 0.95 + 30 * 0.55 * 0.90), 1e-9)
        and near(gIntake, 0.1 * (40 * 1.00 + 20 * 0.70 * 1.15 + 30 * 0.55 * 1.25), 1e-9))
end

-- Supply follows the liters the animal actually ate ------------------------------------------

do
    local function oneHour(request, penRequest, eatenShare)
        local bull = makeAnimal("BULL_ANGUS", { age = 12, weight = 380 })
        local pen = makePen()
        bull.clusterSystem = { owner = pen }
        bull.input.food = request
        pen.spec_husbandryFood.litersPerHour = penRequest
        advanceHour()
        feed(pen, { FORAGE = eatenShare })
        RLBodyCondition.step(bull)
        return bull.rlNutrition.intakeRatio, bull.weight
    end
    local reference = RLBodyCondition.getReferenceIntake(makeAnimal("BULL_ANGUS", { age = 12, weight = 380 })) / 24
    local base = oneHour(reference, reference * 4, 1)
    local doubled = oneHour(reference * 2, reference * 8, 1)
    local crowded = oneHour(reference, reference * 40, 1)
    local half = oneHour(reference, reference * 4, 0.5)
    check(string.format("supply: twice the liters eaten is twice the energy (%.2f -> %.2f), whatever the pen's size (%.2f); half the trough, half (%.2f)",
        base, doubled, crowded, half), near(doubled, 2 * base, 1e-9) and near(crowded, base, 1e-9) and near(half, base / 2, 1e-9)
        and near(base, RLBreedTraits.get(select(2, Economics.find("BULL_ANGUS")), "silage"), 1e-6))
end

-- Step through the adapter -------------------------------------------------------------------

do
    local bull = makeAnimal("BULL_ANGUS", { age = 12, weight = 380 })
    local pen = makePen({ bull })
    bull.clusterSystem = { owner = pen }
    refreshRequest(bull)
    advanceHour()
    feed(pen, RATIONS.TMR)
    local handled = RLBodyCondition.step(bull)
    local afterFirst = bull.weight
    local handledAgain = RLBodyCondition.step(bull)
    check("adapter: a step sets up the state, and runs once per game hour",
        handled and handledAgain and bull.bodyCondition ~= nil and bull.weight == afterFirst
        and bull.bodyCondition.lastTick == RLBodyCondition.getTickId())

    -- Moved to a pen with no ledger in the same hour: already done, no old-rule gain on top.
    local other = makePen()
    bull.clusterSystem = { owner = other }
    check("adapter: an animal moved within the hour is not stepped again, by either rule",
        RLBodyCondition.step(bull) == true and bull.weight == afterFirst and RLBodyCondition.coversThisHour(bull))
    bull.clusterSystem = { owner = pen }

    advanceHour()
    local before = bull.weight
    check("adapter: no feed ledger for this hour: the old rules for the whole hour",
        RLBodyCondition.step(bull) == false and bull.weight == before and not RLBodyCondition.coversThisHour(bull))

    local bigBull = makeAnimal("BULL_ANGUS", { age = 12, weight = 300 })
    local state = RLBodyCondition.createState(bigBull, "t")
    check("adapter: every animal starts at the neutral reserve (yield and price factor 1)",
        state.reserve == config.initialReserve and RLBodyCondition.getYieldFactor(bigBull) == 1
        and RLBodyCondition.getMarketFactor(bigBull) == 1)
end

-- Calibration: bulls on full feed keep the old growth line -------------------------------------

local agesOk, finishOk, details = true, true, {}
for _, name in ipairs(Economics.BULLS) do
    local i, sub = Economics.find(name)
    local oldMonths = Economics.raise(i, Economics.RATIONS.TMR, Economics.reference(sub))
    local newMonths, bull = raiseNew(name, "TMR")
    local score = RLBodyCondition.getFinishScore(bull)
    details[#details + 1] = string.format("%s %.1f/%.1f F%.0f", name, oldMonths, newMonths, score)
    if math.abs(newMonths - oldMonths) > 0.5 then agesOk = false end
    if score < 65 or score > 80 or RLBodyCondition.getYieldFactor(bull) ~= 1 then finishOk = false end
end
check("calibration: every bull on TMR reaches its slaughter reference within 0.5 months of the old line ("
    .. table.concat(details, ", ") .. ")", agesOk)
check("calibration: and arrives in the moderate finish band (yield factor 1)", finishOk)

do
    local i, sub = Economics.find("BULL_ANGUS")
    local oldHay = Economics.raise(i, Economics.RATIONS.hay, Economics.reference(sub))
    local newHay = raiseNew("BULL_ANGUS", "hay")
    local oldSilage = Economics.raise(i, Economics.RATIONS.silage, Economics.reference(sub))
    local newSilage = raiseNew("BULL_ANGUS", "silage")
    check(string.format("calibration: forage routes stay close to the old ones (Angus silage %.1f/%.1f, hay %.1f/%.1f)",
        oldSilage, newSilage, oldHay, newHay), newSilage - oldSilage <= 1.5 and newHay - oldHay <= 2.5 and newHay >= oldHay - 0.5)

    local months, highland = raiseNew("BULL_HIGHLAND_CATTLE", "grass", 60)
    check(string.format("calibration: a Highland on grass keeps growing and finishes (%.1f months)", months),
        months < 60 and RLBodyCondition.getReserve(highland) > 0.4)
end

do
    -- Finishing past the reference: the reserve keeps rising and the yield factor falls.
    local _, bull, reference = raiseNew("BULL_ANGUS", "TMR")
    local pen = bull.clusterSystem.owner
    local yieldAt = RLBodyCondition.getYieldFactor(bull)
    for _ = 1, 24 * 12 do hour(bull, pen, RATIONS.TMR) end
    bull.age = bull.age + 12
    check(string.format("calibration: a year past finish the bull is fatter (F %.0f) and yields less per kg",
        RLBodyCondition.getFinishScore(bull)), bull.weight > reference * 1.15
        and RLBodyCondition.getFinishScore(bull) > 80 and RLBodyCondition.getYieldFactor(bull) < yieldAt)
end

-- Calibration: period length does not change the result ---------------------------------------

do
    local weights = {}
    for _, days in ipairs({ 1, 3, 7 }) do
        setDaysPerPeriod(days)
        local pen = makePen()
        local bull = makeAnimal("BULL_LIMOUSIN", { age = 8, weight = 300 })
        bull.clusterSystem = { owner = pen }
        for _ = 1, 6 do
            for _ = 1, 24 * days do hour(bull, pen, RATIONS.silage) end
            bull.age = bull.age + 1
        end
        weights[#weights + 1] = bull.weight
    end
    setDaysPerPeriod(1)
    check(string.format("time: 1, 3 and 7 days per period give the same weight after 6 months (%.1f %.1f %.1f)",
        weights[1], weights[2], weights[3]),
        math.abs(weights[2] / weights[1] - 1) < 0.01 and math.abs(weights[3] / weights[1] - 1) < 0.01)
end

-- Calibration: dairy cycles ------------------------------------------------------------------

--- Three calvings 13 months apart: lactating 10 months on `lactRation`, dry 3 on `dryRation`.
local function dairy(name, productivity, lactRation, dryRation)
    local pen = makePen()
    local cow, sub = makeAnimal(name, { age = 48, isParent = true, genetics = { metabolism = 1, quality = 1,
        productivity = productivity, fertility = 1, health = 1 } })
    cow.weight = cow.targetWeight
    cow.clusterSystem = { owner = pen }
    cow.bodyCondition = RLBodyCondition.createState(cow, "test")
    local potential, given, minBCS, maxBCS, calving = 0, 0, 5, 1, {}
    for cycle = 1, 3 do
        for m = 0, 12 do
            cow.monthsSinceLastBirth = m
            cow.isLactating = m < 10
            cow.isPregnant = m >= 3
            cow.reproduction = m >= 3 and (m - 3) * 10 or 0
            cow.pregnancy = m >= 3 and { pregnancies = { {} } } or nil
            if m == 0 then calving[cycle] = RLBodyCondition.getBCS(cow) end
            local ration = cow.isLactating and lactRation or dryRation
            for _ = 1, 24 do
                local liters = hour(cow, pen, ration, sub)
                if cycle == 3 then
                    given = given + liters
                    potential = potential + Economics.curve(sub.milk, cow.age) * lactationFactor(m) * productivity / 24
                end
            end
            if cycle == 3 then
                minBCS = math.min(minBCS, RLBodyCondition.getBCS(cow)); maxBCS = math.max(maxBCS, RLBodyCondition.getBCS(cow))
            end
        end
    end
    return given / potential, minBCS, maxBCS, calving[3]
end

-- A Swiss Brown gives less milk for her feed than a Holstein, so she carries more condition.
for _, name in ipairs({ "COW_HOLSTEIN", "COW_SWISS_BROWN" }) do
    local share, low, high, calving = dairy(name, 1, RATIONS.TMR, RATIONS.hay)
    check(string.format("dairy: %s on TMR, dry on hay: %.1f%% of the milk, BCS %.2f..%.2f, %.2f at calving",
        name, share * 100, low, high, calving), share >= 0.95 and low >= 2.0 and high < 4.0 and calving >= 2.9 and calving <= 3.6)
end

do
    local average = dairy("COW_HOLSTEIN", 1, RATIONS.TMR, RATIONS.hay)
    local high, low = dairy("COW_HOLSTEIN", 1.75, RATIONS.TMR, RATIONS.hay)
    check(string.format("dairy: a 1.75 cow gives more milk than an average one (%.2f x) but runs thin (BCS %.2f)",
        high * 1.75, low), high * 1.75 > average * 1.2 and low < 2.6)
    local silage, silageLow = dairy("COW_HOLSTEIN", 1, RATIONS.silage, RATIONS.hay)
    check(string.format("dairy: on silage a cow gives less milk (%.0f%%) and stops at BCS ~2.2 (%.2f)", silage * 100,
        silageLow), silage < 0.95 and silage > 0.75 and silageLow >= 2.1)
end

do
    local share, low, high, calving = dairy("COW_HIGHLAND_CATTLE", 1, RATIONS.grass, RATIONS.grass)
    local tmrShare, _, tmrHigh = dairy("COW_ANGUS", 1, RATIONS.TMR, RATIONS.TMR)
    check(string.format("suckler: a Highland herd on grass keeps BCS %.2f..%.2f (calving %.2f), an Angus on TMR gets fat (%.2f)",
        low, high, calving, tmrHigh), low >= 2.2 and calving >= 2.4 and share > 0.7 and tmrHigh >= 3.9 and tmrShare > 0.99)
end

do
    -- A dry cow keeps her condition on hay and fattens on TMR.
    local results = {}
    for _, rationName in ipairs({ "hay", "TMR" }) do
        local pen = makePen()
        local cow = makeAnimal("COW_HOLSTEIN", { age = 60, isParent = true, weight = 730 })
        cow.clusterSystem = { owner = pen }
        cow.bodyCondition = RLBodyCondition.createState(cow, "test")
        for _ = 1, 24 * 3 do hour(cow, pen, RATIONS[rationName]) end
        results[rationName] = cow.bodyCondition.reserve - config.initialReserve
    end
    check(string.format("dairy: a dry cow holds her condition on hay (%+.3f) and fattens on TMR (%+.3f)",
        results.hay, results.TMR), math.abs(results.hay) < 0.03 and results.TMR > 0.1)
end

-- Carcass yield and live price ---------------------------------------------------------------

do
    local bull = makeAnimal("BULL_ANGUS", { age = 20, weight = 600 })
    bull.bodyCondition = RLBodyCondition.createState(bull, "test")
    bull.bodyCondition.reserve = 0.52
    local moderate = AnimalMoveEvent.getCarcassYieldFactor(bull, nil, bull.subTypeIndex)
    bull.bodyCondition.reserve = 0.95
    local overfat = AnimalMoveEvent.getCarcassYieldFactor(bull, nil, bull.subTypeIndex)
    check("carcass: the condition factor is applied once in the shared yield entry",
        near(overfat / moderate, M.interpolate(config.curves.yield, M.interpolate(config.curves.finishScore, 0.95)), 1e-9))
    check("carcass: the reference weight helper gives target x maturity",
        near(AnimalMoveEvent.getCarcassReferenceWeight(bull, nil, bull.subTypeIndex), Economics.reference(select(2, Economics.find("BULL_ANGUS"))), 1e-9))
end

-- Persistence and network --------------------------------------------------------------------

do
    local store = {}
    local xml = {
        setFloat = function(_, k, v) store[k] = v end, setInt = function(_, k, v) store[k] = v end,
        setString = function(_, k, v) store[k] = v end,
        getFloat = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
        getInt = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
        getString = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
    }
    local state = { version = 1, reserve = 0.61, capacityKg = 146, balanceEMA = -0.05, lossRateEMA = 0.02, lastTick = 777, source = "calf" }
    RLBodyCondition.saveToXMLFile(state, xml, "a")
    local loaded = RLBodyCondition.loadFromXMLFile(xml, "a")
    local same = true
    for k, v in pairs(state) do if loaded[k] ~= v then same = false end end
    check("persistence: a saved state loads back unchanged", same)
    check("persistence: an animal saved without state loads none", RLBodyCondition.loadFromXMLFile(xml, "b") == nil)
    store["a.bodyCondition#version"] = 99
    check("persistence: a newer state version is dropped, not misread", RLBodyCondition.loadFromXMLFile(xml, "a") == nil)

    local stream = {}
    local readAt = 0
    local function w(v) stream[#stream + 1] = v end
    local function r() readAt = readAt + 1; return stream[readAt] end
    streamWriteBool, streamWriteFloat32, streamWriteInt32 = function(_, v) w(v) end, function(_, v) w(v) end, function(_, v) w(v) end
    streamReadBool, streamReadFloat32, streamReadInt32 = function() return r() end, function() return r() end, function() return r() end
    RLBodyCondition.writeStream(state, 1)
    RLBodyCondition.writeStream(nil, 1)
    local a, b = RLBodyCondition.readStream(1), RLBodyCondition.readStream(1)
    check("network: state and no-state both round-trip, in order",
        a.reserve == 0.61 and a.capacityKg == 146 and a.lastTick == 777 and b == nil and readAt == #stream)

    local copy = RLBodyCondition.copyState(state)
    copy.reserve = 0.1
    check("clone: a copied state is a separate table", state.reserve == 0.61 and RLBodyCondition.copyState(nil) == nil)
end

-- Milk deposit -------------------------------------------------------------------------------

do
    SpecializationUtil = { registerOverwrittenFunction = function() end }
    Utils = { appendedFunction = function(a) return a end, overwrittenFunction = function(a) return a end }
    PlaceableHusbandryMilk = { registerOverwrittenFunctions = function() end, onHusbandryAnimalsUpdate = function() end }
    loadMod("scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryMilk.lua")

    local cow, sub = makeAnimal("COW_HOLSTEIN", { age = 48, isParent = true, isLactating = true, weight = 730,
        monthsSinceLastBirth = 2 })
    local pen = makePen({ cow })
    cow.clusterSystem = { owner = pen }
    pen.spec_husbandry = { productionFactor = 0.33 }
    pen.spec_husbandryMilk = { hasMilkProduction = true, litersPerHour = {} }
    local strawFactor = 0.9                                       -- no straw: the base spec's x 0.9
    function pen:updateProduction(foodFactor) self.spec_husbandry.productionFactor = foodFactor; return foodFactor * strawFactor end
    function pen:getHusbandryFreeCapacity() return 1000 end
    function pen:getOwnerFarmId() return 1 end
    local deposited, baseSaw
    function pen:addHusbandryFillLevelFromTool(_, liters) deposited = deposited + liters end

    --- One hour in the engine's order: feeding (and water), then updateOutput, where the milk store
    --- deposits BEFORE the animals spec runs updateHealth (the budget step) inside the chain.
    local function milkHour(ration, water, withLedger, foodFactor)
        refreshRequest(cow)
        local curve = Economics.curve(sub.milk, cow.age)
        local potential = curve * lactationFactor(cow.monthsSinceLastBirth)
        RLBodyCondition.applyMilk(cow, potential, curve, 1)
        -- litersPerHour as summed at the end of the last hour: the cow's potential plus another animal's 3 l/h
        pen.spec_husbandryMilk.litersPerHour[FILL.MILK] = potential / 24 + 3
        pen.spec_husbandryMilk.rlMilkContributions = { { animal = cow, fillType = FILL.MILK, liters = potential / 24 } }
        advanceHour()
        if withLedger then
            feed(pen, ration)
            RLBodyCondition.recordWater(pen, water)
        end
        deposited, baseSaw = 0, nil
        local productionFactor = foodFactor * strawFactor
        RLBodyCondition.depositMilk(pen, pen.spec_husbandryMilk.litersPerHour, pen.spec_husbandryMilk.rlMilkContributions,
            function()
                baseSaw = pen.spec_husbandryMilk.litersPerHour[FILL.MILK]
                deposited = deposited + productionFactor * 1 * baseSaw * env.timeAdjustment
                if not RLBodyCondition.step(cow) then cow:updateWeight(foodFactor) end
            end,
            function(_, liters) deposited = deposited + liters end)
        return deposited, baseSaw, potential / 24
    end

    local normal, normalBase, potential = milkHour(RATIONS.TMR, 1, true, 1)
    local paid = cow.rlMilkPaid.litersPerHour
    check(string.format("milk: the base deposit gets only the other animals' liters, the cow's budget pays this hour (%.3f of %.3f l/h)",
        paid, potential), near(normalBase, 3, 1e-9) and paid > 0.9 * potential
        and near(normal, 3 * strawFactor + paid * strawFactor, 1e-9) and pen.spec_husbandryMilk.litersPerHour[FILL.MILK] == potential + 3)

    local dry = milkHour(RATIONS.TMR, 0, true, 0)
    check("milk: in the hour the water stops, the cow gives no milk that same hour", near(dry, 0, 1e-12))
    local back = milkHour(RATIONS.TMR, 1, true, 1)
    check("milk: in the hour the water is back, she gives her milk that same hour",
        near(back, 3 * strawFactor + cow.rlMilkPaid.litersPerHour * strawFactor, 1e-9) and cow.rlMilkPaid.litersPerHour > 0)

    local starving = milkHour(RATIONS.none, 1, true, 0)
    check("milk: with no food the straw factor still applies to milk from reserve (no division by the food factor)",
        near(starving, cow.rlMilkPaid.litersPerHour * strawFactor, 1e-12) and pen.spec_husbandry.productionFactor == 0.33)

    local legacy, legacyBase = milkHour(RATIONS.TMR, 1, false, 0.8)
    check("milk: an hour without a ledger is wholly the old rules: her full potential, scaled by the food factor",
        near(legacyBase, potential + 3, 1e-9) and near(legacy, 0.8 * strawFactor * (potential + 3), 1e-9))

    -- A second store in the same hour (e.g. moved between pens) does not deposit her milk again.
    local before = deposited
    RLBodyCondition.depositMilk(pen, pen.spec_husbandryMilk.litersPerHour, pen.spec_husbandryMilk.rlMilkContributions,
        function() end, function(_, liters) deposited = deposited + liters end)
    milkHour(RATIONS.TMR, 1, true, 1)
    local first = deposited
    RLBodyCondition.depositMilk(pen, pen.spec_husbandryMilk.litersPerHour, pen.spec_husbandryMilk.rlMilkContributions,
        function() end, function(_, liters) deposited = deposited + liters end)
    check("milk: an hour's paid milk is deposited once", deposited == first and before ~= nil)

    local goat = makeAnimal("BOAR_LANDRACE", { age = 20 })
    check("milk: output stays the full-feed potential; an animal not covered records nothing",
        RLBodyCondition.applyMilk(cow, 400, 378, 1) == 400 and near(cow.rlMilk.anchor, 378 * config.lactationMeanFactor, 1e-9)
        and RLBodyCondition.applyMilk(goat, 50, 50, 1) == 50 and goat.rlMilk == nil)
end

-- Weight floor and config checks -------------------------------------------------------------

do
    local input = { dtMonths = 1, weight = 60, minWeight = 58, reserve = 0.5, capacityKg = 140, targetWeight = 700,
        potentialGrowthKg = 0, potentialMilk = 0, anchorMilk = 0, isLactating = false,
        pregnancyProgress = 0, numFetuses = 0, intakeLiters = 0, referenceLiters = 100, intakeCapacity = 1,
        reserveCeiling = 0.5 }
    local r = M.step(input, config)
    local expected = input.weight + r.frameGainKg + r.reserveKg - r.catabolismKg - r.excessDecayKg
    check(string.format("floor: a starving animal near its minimum weight stops there (%.2f kg), and the weight still adds up",
        r.weight), r.weight >= input.minWeight - 1e-9 and near(r.weight, expected, 1e-9)
        and near(r.supplyNU + r.mobilizedNU + r.catabolismNU, r.paidNU + r.depositNU + r.lostNU, 1e-9))

    local bad = table.clone(config); bad.layers = config.layers
    bad.curves = table.clone(config.curves); bad.curves.yield = { { 0, 0 / 0 }, { 50, 1 } }
    local ok1 = RLBodyConditionConfig.validate(bad)
    bad.curves = config.curves
    bad.layers = { root = {}, types = {}, breeds = { COW = { HOLSTEIN = { intakeLactating = 0 / 0 } } }, subTypes = {} }
    local ok2 = RLBodyConditionConfig.validate(bad)
    check("config: a NaN in a curve or a breed value is rejected", ok1 == false and ok2 == false)
end

-- Console test commands ----------------------------------------------------------------------

do
    loadMod("scripts/console/RLBodyConditionConsole.lua")
    local printed = {}
    local realPrint = print
    print = function(text) printed[#printed + 1] = text end

    local pen = makePen()
    local cows = { makeAnimal("COW_HOLSTEIN", { age = 60, isParent = true, weight = 730, uniqueId = "1" }),
        (makeAnimal("BULL_ANGUS", { age = 12, weight = 380, uniqueId = "2" })) }
    for _, animal in ipairs(cows) do
        animal.clusterSystem = { owner = pen }
        animal.updateInput, animal.setDirty = function() end, function() end
        refreshRequest(animal)
    end
    pen.animals = cows
    function pen:getAnimalTypeIndex() return AnimalType.COW end
    function pen:getClusters() return cows end
    function pen:hourChanged()
        feed(self, RATIONS.hay)
        for _, animal in ipairs(cows) do RLBodyCondition.step(animal) end
    end
    g_currentMission.husbandrySystem = { placeables = { pen } }

    local before = cows[1].weight
    local message = RLBodyConditionConsole:set("bcs", "4", "1")
    local state = cows[1].bodyCondition
    check("console: rlBcSet sets one animal's BCS and moves its weight by the reserve",
        message:find("1 animal") ~= nil and near(state.reserve, 0.75, 1e-9)
        and near(cows[1].weight - before, state.capacityKg * (0.75 - config.initialReserve), 1e-6) and cows[2].bodyCondition == nil)
    RLBodyConditionConsole:set("finish", "80", "all")
    check("console: rlBcSet finish reads the finish curve backwards", near(cows[2].bodyCondition.reserve, 0.60, 1e-9))

    local tick = RLBodyCondition.getTickId()
    local result = RLBodyConditionConsole:fastForward("48")
    check("console: rlBcFastForward runs one budget step per simulated hour",
        RLBodyCondition.getTickId() == tick + 48 and cows[1].bodyCondition.lastTick == tick + 48 and result:find("48 hours") ~= nil
        and cows[1].bodyCondition.reserve < 0.75)

    printed = {}
    RLBodyConditionConsole:report("animals")
    local text = table.concat(printed, "\n")
    check("console: rlBcReport shows the ledger and each animal",
        text:find("feed ledger tick") ~= nil and text:find("BCS") ~= nil and text:find("F ") ~= nil and #printed >= 5)

    print = realPrint
    RLBodyCondition.debugTickOffset = 0
end

-- Finish verdict -----------------------------------------------------------------------------

do
    local _, sub = Economics.find("BULL_ANGUS")
    local reference = Economics.reference(sub)
    local function verdict(weight, reserve, fields)
        local bull = makeAnimal("BULL_ANGUS", { age = 18, weight = weight })
        for k, v in pairs(fields or {}) do bull[k] = v end
        bull.bodyCondition = RLBodyCondition.createState(bull, "t")
        bull.bodyCondition.reserve = reserve
        return (RLBodyCondition.getFinishVerdict(bull))
    end
    check("verdict: a 300 kg bull at finish 72 is still growing, not ready",
        verdict(300, 0.52) == "rl_ui_finishVerdictGrowing")
    check("verdict: at its reference and finish 72 it is ready; lean it needs finishing; overfat past its best",
        verdict(reference, 0.52) == "rl_ui_finishVerdictReady" and verdict(reference, 0.30) == "rl_ui_finishVerdictNeedsFinish"
        and verdict(reference * 1.2, 0.80) == "rl_ui_finishVerdictOverfat")
    check("verdict: an animal that may not be sold is never ready",
        verdict(reference, 0.52, { getCanBeSold = function() return false end }) == "rl_ui_finishVerdictBlocked")
end

-- Display rows -------------------------------------------------------------------------------

do
    local savedI18n = g_i18n
    g_i18n = { getText = function(_, key) return key end }
    local _, sub = Economics.find("BULL_ANGUS")
    local reference = Economics.reference(sub)

    -- The menu's stat grid has one short value cell per row: verdict and weight are two rows.
    local bull = makeAnimal("BULL_ANGUS", { age = 18, weight = reference })
    bull.bodyCondition = RLBodyCondition.createState(bull, "t")
    bull.bodyCondition.reserve = 0.52
    bull.rlNutrition = { coverage = 0.9 }
    local infos = {}
    RLBodyCondition.addInfos(bull, infos)
    local byTitle = {}
    for _, row in ipairs(infos) do byTitle[row.title] = row end
    check("display: a bull's verdict row holds the verdict alone",
        byTitle.rl_ui_finishVerdict ~= nil and byTitle.rl_ui_finishVerdict.valueText == "rl_ui_finishVerdictReady")
    check("display: the weight against the slaughter reference is its own row",
        byTitle.rl_ui_finishWeight ~= nil
        and byTitle.rl_ui_finishWeight.valueText == string.format("%.0f / %.0f kg", reference, reference)
        and near(byTitle.rl_ui_finishWeight.ratio, 1, 1e-9))
    check("display: a bull's rows are finish, verdict, weight and ration in that order",
        #infos == 4 and infos[1].title == "rl_ui_finish" and infos[2].title == "rl_ui_finishVerdict"
        and infos[3].title == "rl_ui_finishWeight" and infos[4].title == "rl_ui_rationCoverage")

    -- The pen info box: one short figure per row, cow rows only with cows, bull rows only with bulls.
    local cow = makeAnimal("COW_HOLSTEIN", { age = 60, isParent = true, weight = 730 })
    cow.bodyCondition = RLBodyCondition.createState(cow, "t")
    local pen = makePen()
    local animals = { cow }
    function pen:getAnimalTypeIndex() return AnimalType.COW end
    function pen:getClusters() return animals end
    local function keys(rows)
        local out = {}
        for _, row in ipairs(rows or {}) do out[#out + 1] = row.titleKey end
        return table.concat(out, ",")
    end
    check("display: a cow pen shows average BCS and thin / fat cows, no bull rows",
        keys(RLBodyCondition.getPenInfo(pen)) == "rl_ui_penBcs,rl_ui_penCowsThinFat")
    animals = { bull }
    local rows = RLBodyCondition.getPenInfo(pen)
    check("display: a bull barn shows bulls ready and overfat, no cow rows",
        keys(rows) == "rl_ui_penBullsReady,rl_ui_penBullsOverfat" and rows[1].text == "1 / 1" and rows[2].text == "0")
    animals = { cow, bull }
    pen.spec_husbandryFood.rlPenSummary = { eatenShare = 0.98, energy = 0.82, water = 1 }
    rows = RLBodyCondition.getPenInfo(pen)
    local short = true
    for _, row in ipairs(rows) do short = short and #row.text <= 8 end
    check("display: a mixed pen with a ration summary shows all seven rows, each a short figure",
        keys(rows) == "rl_ui_penBcs,rl_ui_penCowsThinFat,rl_ui_penBullsReady,rl_ui_penBullsOverfat,"
            .. "rl_ui_penFeedEaten,rl_ui_penRationEnergy,rl_ui_penWater"
        and rows[5].text == "98 %" and rows[6].text == "82 %" and rows[7].text == "100 %" and short)
    animals = {}
    check("display: a pen without covered cattle has no rows", RLBodyCondition.getPenInfo(pen) == nil)
    g_i18n = savedI18n
end

-- Network events -----------------------------------------------------------------------------

do
    local stream, readAt = {}, 0
    local function w(_, v) stream[#stream + 1] = v end
    local function r() readAt = readAt + 1; return stream[readAt] end
    streamWriteBool, streamWriteFloat32, streamWriteInt32, streamWriteUInt8, streamWriteUInt16, streamWriteString = w, w, w, w, w, w
    streamReadBool, streamReadFloat32, streamReadInt32, streamReadUInt8, streamReadUInt16, streamReadString = r, r, r, r, r, r
    NetworkUtil = { writeNodeObject = function(_, object) stream[#stream + 1] = object end, readNodeObject = function() return r() end }
    RLAnimalUtil = {
        writeStreamIdentifiers = function(animal) stream[#stream + 1] = animal.uniqueId end,
        readStreamIdentifiers = function() return { uniqueId = r(), farmId = 1, country = 1 } end,
        find = function(animals, _, uniqueId) for _, a in ipairs(animals) do if a.uniqueId == uniqueId then return a end end end,
    }
    loadMod("scripts/events/RLBodyConditionStateEvent.lua")
    loadMod("scripts/events/RLBodyConditionConfigEvent.lua")

    -- Server side: one stepped cow.
    local cow = makeAnimal("COW_HOLSTEIN", { age = 48, isParent = true, weight = 730, uniqueId = "7" })
    local serverPen = makePen({ cow })
    cow.clusterSystem = { owner = serverPen }
    function serverPen:getClusters() return { cow } end
    hour(cow, serverPen, RATIONS.TMR)
    local tick = RLBodyCondition.getTickId()

    RLBodyConditionStateEvent.new(serverPen, tick):writeStream(1)

    -- Client side: same animal, stale state.
    local clientCow = makeAnimal("COW_HOLSTEIN", { age = 48, isParent = true, weight = 700, uniqueId = "7" })
    local clientPen = makePen()
    function clientPen:getClusterSystem() return { animals = { clientCow } } end
    stream[1] = clientPen                                       -- the node object resolves to the client's pen
    local serverConn = makeConnection(1, true)
    local savedServer = g_server
    g_server = nil
    RLBodyConditionStateEvent.emptyNew():readStream(1, serverConn)
    check("network: the hourly state event gives the client the server's weight, reserve and budget",
        clientCow.weight == cow.weight and clientCow.bodyCondition.reserve == cow.bodyCondition.reserve
        and near(clientCow.rlNutrition.coverage, cow.rlNutrition.coverage, 1e-12) and clientPen.spec_husbandryFood.rlPenSummary ~= nil)

    -- A client sending it to the server changes nothing.
    stream, readAt = {}, 0
    RLBodyConditionStateEvent.new(serverPen, tick):writeStream(1)
    stream[1] = clientPen
    clientCow.weight = 1
    g_server = {}
    RLBodyConditionStateEvent.emptyNew():readStream(1, makeConnection(2, false))
    check("network: a state event from a client is ignored", clientCow.weight == 1)

    -- Config: the joining client takes the server's values.
    stream, readAt = {}, 0
    local serverConfig = table.clone(config)
    serverConfig.curves, serverConfig.feedEnergy, serverConfig.layers = config.curves, config.feedEnergy, config.layers
    serverConfig.maintenancePerKgMetabolic = 5.5
    RLBodyConditionConfigEvent.new(serverConfig):writeStream(1)
    local own = RLBodyConditionConfig.config
    g_server = nil
    RLBodyConditionConfigEvent.emptyNew():readStream(1, serverConn)
    local received = RLBodyConditionConfig.config
    check("network: a joining client uses the server's body condition config",
        received.enabled and received.maintenancePerKgMetabolic == 5.5 and near(received.feedEnergy.SILAGE, 0.82, 1e-9)
        and received.layers.breeds.COW.HOLSTEIN.intakeLactating == 0.93 and #received.curves.yield == #config.curves.yield
        and readAt == #stream)
    RLBodyConditionConfig.config = own
    g_server = savedServer
end
