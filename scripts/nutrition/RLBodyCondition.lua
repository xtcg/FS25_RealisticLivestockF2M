--[[
    RLBodyCondition.lua
    Body condition of cattle in the game: who is covered, the state each animal carries, the
    pen's hourly feed ledger, the hourly budget step (RLNutritionMath) and the factors the rest of
    the mod reads - carcass yield, live price, conception and milk.

    State (animal.bodyCondition, saved and streamed with the animal):
        version, reserve (0..1), capacityKg (live weight of one unit of reserve, fixed when set
        up), balanceEMA, lossRateEMA (reserve lost per month, smoothed), lastTick (game hour of
        the last step, so a step never runs twice), source ("legacy" / "calf" / "dealer" / ...).
    Weight stays the one authority for live weight; frame weight is derived from it.

    Server only advances the state: the step runs from AnimalHealth.updateHealth, which only the
    server calls. Every read here is side-effect free: an animal without state reads the reserve
    it would start with, and nothing is written until its first step.
]]

RLBodyCondition = {}

local Log = RmLogging.getLogger("RLRM")

RLBodyCondition.STATE_VERSION = 1

--- Forage categories the breed traits weight (RLBreedTraits.FORAGE_CATEGORIES), plus the rest.
RLBodyCondition.OTHER_CATEGORY = "other"


-- =============================================================================
-- Config and coverage
-- =============================================================================

function RLBodyCondition.getConfig()
    return RLBodyConditionConfig.get()
end


--- The feature is on (enabled in the config and the config valid).
function RLBodyCondition.isEnabled()
    return RLBodyCondition.getConfig().enabled == true
end


--- Whether the animal is a covered type at all, whatever its age.
--- @param animal table
--- @return boolean
function RLBodyCondition.isCoveredType(animal)
    return animal ~= nil and AnimalType ~= nil and animal.animalTypeIndex == AnimalType.COW
end


--- Whether the body condition rules run for this animal now: the feature is on, it is cattle
--- (Hof Bergmann's MILKCOW is a type of its own and stays out) and past the calf stage.
--- @param animal table
--- @return boolean
function RLBodyCondition.isEligible(animal)
    if not RLBodyCondition.isCoveredType(animal) or not RLBodyCondition.isEnabled() then return false end
    if animal.isDead then return false end
    return (animal.age or 0) >= RLBodyCondition.getConfig().calfLegacyUntilAgeMonth
end


--- Hours the console's rlBcFastForward has run on top of game time (RLBodyConditionConsole).
RLBodyCondition.debugTickOffset = 0

--- Current game hour as a number that only grows: monotonic day x 24 + hour (+ any hours the
--- console fast-forward simulated this session).
--- @return number|nil
function RLBodyCondition.getTickId()
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    if environment == nil or environment.currentMonotonicDay == nil then return nil end
    return environment.currentMonotonicDay * 24 + (environment.currentHour or 0) + RLBodyCondition.debugTickOffset
end


-- =============================================================================
-- State
-- =============================================================================

--- Slaughter reference weight (carcassYield.xml) the finishing curve is read against.
--- @param animal table
--- @return number|nil
function RLBodyCondition.getReferenceWeight(animal)
    if AnimalMoveEvent == nil or AnimalMoveEvent.getCarcassReferenceWeight == nil then return nil end
    local reference = AnimalMoveEvent.getCarcassReferenceWeight(animal, nil, animal.subTypeIndex)
    if reference == nil or reference <= 0 then return nil end
    return reference
end


--- The reserve a bull or steer on full feed has at its weight; nil for a female.
--- @param animal table
--- @param weight number|nil Defaults to the animal's weight
--- @return number|nil
function RLBodyCondition.getReserveTarget(animal, weight)
    if animal.gender ~= "male" then return nil end
    local config = RLBodyCondition.getConfig()
    local reference = RLBodyCondition.getReferenceWeight(animal)
    if reference == nil then return config.initialReserve end
    local x = (weight or animal.weight or 0) / reference
    if animal.isCastrated then x = x + config.steerFinishShift end
    return math.clamp(RLNutritionMath.interpolate(config.curves.finishingTarget, x), config.minReserve, 1)
end


--- Highest reserve a surplus fills: a bull's finishing target, a heifer's or a cow's ceiling.
function RLBodyCondition.getReserveCeiling(animal, weight)
    local config = RLBodyCondition.getConfig()
    if animal.gender == "male" then return RLBodyCondition.getReserveTarget(animal, weight) end
    return animal.isParent and config.cowReserveCeiling or config.heiferReserveCeiling
end


--- Reserve an animal starts with when its condition is first set up: initialReserve for every
--- animal (an old savegame's, a calf leaving the calf stage, a dealer's), the neutral point where
--- the yield and price factors are 1, so setting up a condition never changes a value by itself.
function RLBodyCondition.getInitialReserve(animal)
    return RLBodyCondition.getConfig().initialReserve
end


--- New state for an animal. Deterministic: the same animal always starts the same.
--- @param animal table
--- @param source string
--- @return table
function RLBodyCondition.createState(animal, source)
    local config = RLBodyCondition.getConfig()
    local subType = animal.getSubType ~= nil and animal:getSubType() or nil
    local target = animal.targetWeight or (subType ~= nil and subType.targetWeight) or animal.weight or 0

    return {
        version = RLBodyCondition.STATE_VERSION,
        reserve = RLBodyCondition.getInitialReserve(animal),
        capacityKg = math.max(config.reserveCapacityRatio * target, 1),
        balanceEMA = 0,
        lossRateEMA = 0,
        lastTick = -1,
        source = source or "legacy",
    }
end


--- The animal's state, created when it has none. Server side, from the step.
function RLBodyCondition.ensureState(animal, source)
    if animal.bodyCondition == nil then
        animal.bodyCondition = RLBodyCondition.createState(animal, source)
        Log:debug("RLBodyCondition: condition set up for %s/%s (%s) reserve=%.3f capacity=%.1f kg",
            tostring(animal.farmId), tostring(animal.uniqueId), animal.bodyCondition.source,
            animal.bodyCondition.reserve, animal.bodyCondition.capacityKg)
    end
    return animal.bodyCondition
end


--- A copy of a state (clone, move): two animals never share one table.
function RLBodyCondition.copyState(state)
    if state == nil then return nil end
    local copy = {}
    for key, value in pairs(state) do copy[key] = value end
    return copy
end


--- The reserve: the saved one, or the one the animal would start with.
--- @param animal table
--- @return number
function RLBodyCondition.getReserve(animal)
    local state = animal.bodyCondition
    if state ~= nil and state.reserve ~= nil then return state.reserve end
    return RLBodyCondition.getInitialReserve(animal)
end


--- Finish score 0..100 of a reserve.
function RLBodyCondition.getFinishScore(animal)
    return RLNutritionMath.interpolate(RLBodyCondition.getConfig().curves.finishScore, RLBodyCondition.getReserve(animal))
end


--- BCS 1..5.
function RLBodyCondition.getBCS(animal)
    return RLNutritionMath.getBCS(RLBodyCondition.getReserve(animal))
end


--- Whether the condition factors apply to this animal (feature on, cattle past the calf stage).
function RLBodyCondition.appliesTo(animal)
    return RLBodyCondition.isEligible(animal)
end


--- Carcass yield factor of the animal's finish score; 1 where the rules do not apply.
--- Read once, by AnimalMoveEvent.getCarcassYieldFactor, so meat kg, the slaughter value floor
--- and both slaughter routes see the same factor.
function RLBodyCondition.getYieldFactor(animal)
    if not RLBodyCondition.appliesTo(animal) then return 1 end
    return RLNutritionMath.interpolate(RLBodyCondition.getConfig().curves.yield, RLBodyCondition.getFinishScore(animal))
end


--- Factor on the weight part of a live price; 1 where the rules do not apply.
function RLBodyCondition.getMarketFactor(animal)
    if not RLBodyCondition.appliesTo(animal) then return 1 end
    return RLNutritionMath.interpolate(RLBodyCondition.getConfig().curves.market, RLBodyCondition.getFinishScore(animal))
end


--- Factor on a female's conception probability: BCS curve x the trend of reserve loss.
--- 1 where the rules do not apply.
function RLBodyCondition.getFertilityFactor(animal)
    if not RLBodyCondition.appliesTo(animal) or animal.gender ~= "female" then return 1 end
    local config = RLBodyCondition.getConfig()
    local state = animal.bodyCondition
    local lossRate = state ~= nil and state.lossRateEMA or 0
    return math.clamp(RLNutritionMath.interpolate(config.curves.fertility, RLBodyCondition.getBCS(animal))
        * RLNutritionMath.interpolate(config.curves.lossTrend, lossRate), 0, 1)
end


--- Probability of a conception roll passing: the old roll's (1 - (2 - fertility) x scale),
--- times the condition factor. With factor 1 this is exactly the old threshold.
--- @param fertility number Effective fertility (genetics x disease)
--- @param scale number 0.5 natural, 0.25 insemination
--- @param factor number Condition factor
--- @return number 0..1
function RLBodyCondition.getConceptionProbability(fertility, scale, factor)
    return math.clamp(1 - (2 - fertility) * scale, 0, 1) * math.clamp(factor, 0, 1)
end


--- How much more a high-yield lactating cow eats: 1 + highYieldIntake x (productivity - 1),
--- between 1 and maxIntakeFactor. 1 for any other animal.
function RLBodyCondition.getIntakeFactor(animal)
    if not animal.isLactating or not RLBodyCondition.isEligible(animal) then return 1 end
    local config = RLBodyCondition.getConfig()
    local productivity = animal.genetics ~= nil and animal.genetics.productivity or 1
    return math.clamp(1 + config.highYieldIntake * (productivity - 1), 1, config.maxIntakeFactor)
end


--- Intake capacity (kappa) for the animal's state, by subType, breed, type or the root value.
function RLBodyCondition.getIntakeCapacity(animal)
    local config = RLBodyCondition.getConfig()
    local attr = "intakeGrowing"
    if animal.isLactating then
        attr = "intakeLactating"
    elseif animal.gender == "female" and animal.isParent then
        attr = "intakeDry"
    end
    return RLBreedTraits.resolve(config.layers, animal:getSubType(), attr, config[attr])
end


-- =============================================================================
-- Pen feed ledger
-- =============================================================================

local warnedFillTypes = {}

--- Energy of a liter of a fill type: the config's, else the productionWeight of its food group.
--- @param fillTypeIndex number
--- @param animalTypeIndex number|nil
--- @return number
function RLBodyCondition.getFeedEnergy(fillTypeIndex, animalTypeIndex)
    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local energy = name ~= nil and RLBodyCondition.getConfig().feedEnergy[name:upper()] or nil
    if energy ~= nil then return energy end

    local foodSystem = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
    local animalFood = foodSystem ~= nil and animalTypeIndex ~= nil and foodSystem:getAnimalFood(animalTypeIndex) or nil
    if animalFood ~= nil then
        for _, group in pairs(animalFood.groups or {}) do
            for _, groupFillType in pairs(group.fillTypes or {}) do
                if groupFillType == fillTypeIndex then return group.productionWeight or 0 end
            end
        end
    end

    if not warnedFillTypes[fillTypeIndex] then
        warnedFillTypes[fillTypeIndex] = true
        Log:warning("RLBodyCondition: no feed energy for fill type %s, counted as 0", tostring(name or fillTypeIndex))
    end
    return 0
end


--- Start recording what a pen eats in one feeding (from the food spec's updateFeeding).
--- @param placeable table
function RLBodyCondition.beginFeeding(placeable)
    local spec = placeable.spec_husbandryFood
    if spec == nil then return end

    local meadow = placeable.spec_husbandryMeadow
    local meadowBefore = {}
    if meadow ~= nil and meadow.fillLevels ~= nil then
        for fillTypeIndex, level in pairs(meadow.fillLevels) do meadowBefore[fillTypeIndex] = level end
    end

    spec.rlFeedingWindow = { consumed = {}, meadowBefore = meadowBefore }
end


--- Record food taken from the trough inside the feeding window (from removeFood).
--- @param placeable table
--- @param fillTypeIndex number
--- @param removed number Liters the trough lost
function RLBodyCondition.recordRemoved(placeable, fillTypeIndex, removed)
    local spec = placeable.spec_husbandryFood
    local window = spec ~= nil and spec.rlFeedingWindow or nil
    if window == nil or removed == nil or removed <= 0 then return end
    window.consumed[fillTypeIndex] = (window.consumed[fillTypeIndex] or 0) + removed
end


--- Close the feeding window and keep the pen's ledger for this hour:
--- requested liters, liters eaten per fill type, and the energy they carry per forage
--- category relative to the request (what the step turns into each animal's ration share).
--- @param placeable table
function RLBodyCondition.endFeeding(placeable)
    local spec = placeable.spec_husbandryFood
    local window = spec ~= nil and spec.rlFeedingWindow or nil
    if window == nil then return end
    spec.rlFeedingWindow = nil

    local meadow = placeable.spec_husbandryMeadow
    if meadow ~= nil and meadow.fillLevels ~= nil then
        for fillTypeIndex, before in pairs(window.meadowBefore) do
            local eaten = before - (meadow.fillLevels[fillTypeIndex] or 0)
            if eaten > 0 then window.consumed[fillTypeIndex] = (window.consumed[fillTypeIndex] or 0) + eaten end
        end
    end

    local environment = g_currentMission.environment
    local requested = (spec.litersPerHour or 0) * (environment.timeAdjustment or 1)
    local forage = RLBreedTraits.getConfig().forage
    local items, energyShare, eaten = {}, {}, 0

    for fillTypeIndex, liters in pairs(window.consumed) do
        eaten = eaten + liters
        local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
        local category = (name ~= nil and forage[name:upper()]) or RLBodyCondition.OTHER_CATEGORY
        local energy = RLBodyCondition.getFeedEnergy(fillTypeIndex, spec.animalTypeIndex)
        table.insert(items, { fillType = fillTypeIndex, liters = liters, energy = energy, category = category })
        if requested > 0 then energyShare[category] = (energyShare[category] or 0) + liters * energy / requested end
    end

    spec.rlNutritionSupply = {
        tick = RLBodyCondition.getTickId(),
        requested = requested,
        eaten = eaten,
        consumed = window.consumed,
        items = items,
        energyShare = energyShare,
        valid = requested > 0,
    }
end


--- Record the share of the pen's water need it got this hour (from the water spec).
--- @param placeable table
--- @param coverage number 0..1
function RLBodyCondition.recordWater(placeable, coverage)
    local spec = placeable.spec_husbandryFood
    if spec == nil then return end
    spec.rlWaterCoverage = { tick = RLBodyCondition.getTickId(), coverage = math.clamp(coverage, 0, 1) }
end


--- The animal's share of what its pen ate this hour, in liters of full TMR ration: its food
--- request (the same liters the engine asked the trough for) over the pen's request, times each
--- fill type eaten, times that fill type's energy and the breed's digestion of its forage
--- category. Food the pen did not eat is nobody's; the shares of all animals add up to what
--- was eaten. In a calf rearing pen the animal's own liters (RLCalfRearing) replace the share.
--- @param animal table
--- @param supply table spec.rlNutritionSupply
--- @return number litersThisStep Liters of TMR ration eaten (energy and digestion applied)
--- @return number allocatedLiters Liters allocated, as eaten
--- @return number share The animal's share of the pen's request
function RLBodyCondition.getAllocatedIntake(animal, supply)
    local environment = g_currentMission.environment
    local request = (animal:getInput("food") or 0) * (environment.timeAdjustment or 1)
    if supply.requested <= 0 or request <= 0 then return 0, 0, 0 end

    local share = request / supply.requested
    local subType = animal:getSubType()
    -- In a calf rearing pen the animal ate its own share (RLCalfRearing.settle), not the pen's mix;
    -- under the weight model v2 a young calf gets less from solid feed than a weaned one
    -- (RLCalfRearing.getSolidEnergyFactor).
    local own = RLCalfRearing ~= nil and RLCalfRearing.getAllocation(animal, supply.tick) or nil
    local solidFactor = (own ~= nil and RLGrowth ~= nil and RLGrowth.covers(animal)) and RLCalfRearing.getSolidEnergyFactor(animal) or 1
    local intake, allocated = 0, 0
    for _, item in ipairs(supply.items) do
        local liters = own ~= nil and (own[item.fillType] or 0) or share * item.liters
        local digest = item.category == RLBodyCondition.OTHER_CATEGORY and 1 or RLBreedTraits.get(subType, item.category)
        if solidFactor ~= 1 and not RLCalfRearing.isMilkFillType(item.fillType) then digest = digest * solidFactor end
        allocated = allocated + liters
        intake = intake + liters * item.energy * digest
    end
    return intake, allocated, share
end


--- Liters per period an animal of this one's kind, age and state with frame weight `frame`
--- requests on full feed (getReferenceIntake): its food curve, lactation, pregnancy, the gene the
--- request is scaled by, the breed's feed trait and the body factor of that weight.
--- @param animal table
--- @param frame number kg
--- @param intakeGene number|nil Default the metabolism gene (the weight model v2 passes its own)
--- @param bodyFactor number|nil Default RLBreedTraits.getBodyFeedFactor at `frame`
--- @return number liters per period
function RLBodyCondition.getRequestAt(animal, frame, intakeGene, bodyFactor)
    local subType = animal:getSubType()
    local food = subType.input ~= nil and subType.input.food or nil
    if food == nil then return 0 end

    local numPregnancies = (animal.pregnancy ~= nil and animal.pregnancy.pregnancies ~= nil) and #animal.pregnancy.pregnancies or 0
    local modifier = RLBreedTraits.get(subType, "feed")
        * (bodyFactor or RLBreedTraits.getBodyFeedFactor(subType, frame, animal.targetWeight, animal.age))
    local foodScale = RealisticLivestock_PlaceableHusbandryFood ~= nil and RealisticLivestock_PlaceableHusbandryFood.foodScale or 1

    return Animal._computeDailyFood(animal.age, animal.isLactating, animal.reproduction, numPregnancies,
        intakeGene or animal.genetics.metabolism, food:get(animal.age), foodScale, modifier)
end
local getRequestAt = RLBodyCondition.getRequestAt


--- What an average animal of this one's kind, age and state requests on full feed in a period:
--- the food curve with lactation, pregnancy, metabolism, the breed's feed trait and the size of
--- its frame (its weight without the reserve above the reference), but without what a high-yield
--- cow eats extra.
--- @param animal table
--- @return number liters per period
function RLBodyCondition.getReferenceIntake(animal)
    -- Weight model v2: the request at its frame with the reference reserve (RLGrowth).
    if RLGrowth ~= nil and RLGrowth.covers(animal) then return RLGrowth.getReferenceIntake(animal) end
    local state = animal.bodyCondition
    local frame = animal.weight
    if state ~= nil then
        frame = frame - RLNutritionMath.getReserveWeightOffset(state.reserve, state.capacityKg,
            RLBodyCondition.getConfig().referenceReserve)
    end
    return getRequestAt(animal, frame)
end


-- =============================================================================
-- Hourly step
-- =============================================================================

--- What prices the liters an animal eats under the fixed price (fixedFeedPrice): an animal of its
--- own genes on its full-feed line at its age (RLBreedTraits.getGrownLine), intact and healthy, in
--- its state (lactating, pregnant). Its weight on the line, the liters it requests at that weight,
--- and what the line gains this month. None of it moves with the animal's own weight, reserve,
--- castration, disease or what it needs now, so the same liters always carry the same energy:
--- needing more never makes feed richer.
--- @param animal table
--- @return number referenceLiters liters per period
--- @return number referenceWeight kg
--- @return number referenceGrowthKg kg per period
function RLBodyCondition.getSupplyReference(animal)
    local weight, growth = RLBreedTraits.getGrownLine(animal:getSubType(), animal.gender, animal.targetWeight,
        animal.age, animal.genetics.metabolism)
    return getRequestAt(animal, weight), weight, growth
end


--- Progress (0..1) and fetuses of a pregnancy; 0, 0 when not pregnant.
--- @param animal table
--- @return number progress
--- @return number fetuses
function RLBodyCondition.getPregnancy(animal)
    if not animal.isPregnant or animal.pregnancy == nil or animal.pregnancy.pregnancies == nil then return 0, 0 end
    return (animal.reproduction or 0) / 100, #animal.pregnancy.pregnancies
end
local getPregnancy = RLBodyCondition.getPregnancy


--- Build the step input for an animal (no state change).
--- Feed price. By default a liter is priced by what this animal needs on full feed (its own frame's
--- request, its own weight, growth and milk; RLNutritionMath.step). With fixedFeedPrice it is
--- priced by its line (getSupplyReference) and a disease's lost growth is spent on the disease
--- (diseaseLossKg), so a sick animal neither gets poorer feed nor banks the growth it lost.
--- @param animal table
--- @param state table
--- @param intakeLiters number Liters of TMR ration eaten per period (energy and digestion applied)
--- @param waterCoverage number
--- @param dtMonths number
--- @return table input
--- @return number ownReferenceLiters What the animal itself requests on full feed (for the report)
function RLBodyCondition.buildStepInput(animal, state, intakeLiters, waterCoverage, dtMonths)
    local growthKg, healthyGrowthKg = animal:getFullFeedGain()
    local progress, fetuses = getPregnancy(animal)
    local milk = animal.rlMilk
    local subType = animal:getSubType()
    local ownReference = RLBodyCondition.getReferenceIntake(animal)

    local input = {
        dtMonths = dtMonths,
        weight = animal.weight,
        minWeight = subType.minWeight or 0,
        reserve = state.reserve,
        capacityKg = state.capacityKg,
        targetWeight = animal.targetWeight,
        potentialGrowthKg = growthKg,
        potentialMilk = milk ~= nil and milk.potential * waterCoverage or 0,
        isLactating = animal.isLactating and milk ~= nil and milk.potential > 0,
        pregnancyProgress = progress,
        numFetuses = fetuses,
        intakeLiters = intakeLiters,
        intakeCapacity = RLBodyCondition.getIntakeCapacity(animal),
        reserveTarget = RLBodyCondition.getReserveTarget(animal),
        reserveCeiling = RLBodyCondition.getReserveCeiling(animal),
        balanceEMA = state.balanceEMA,
        lossRateEMA = state.lossRateEMA,
        fixedPrice = RLBodyCondition.getConfig().fixedFeedPrice == true,
    }

    if input.fixedPrice then
        input.referenceLiters, input.referenceWeight, input.referenceGrowthKg = RLBodyCondition.getSupplyReference(animal)
        input.anchorMilk = milk ~= nil and milk.lineAnchor or 0
        input.diseaseLossKg = healthyGrowthKg - growthKg
    else
        input.referenceLiters = ownReference
        input.anchorMilk = milk ~= nil and milk.anchor or 0
    end

    return input, ownReference
end


--- The pen's feed ledger for this hour, or nil when there is none.
--- @param animal table
--- @param tick number|nil
--- @return table|nil supply spec.rlNutritionSupply of this hour
--- @return table|nil owner The pen
--- @return table|nil foodSpec
function RLBodyCondition.getLedger(animal, tick)
    local owner = animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil
    local foodSpec = owner ~= nil and owner.spec_husbandryFood or nil
    local supply = foodSpec ~= nil and foodSpec.rlNutritionSupply or nil
    if supply == nil or not supply.valid or tick == nil or supply.tick ~= tick then return nil, owner, foodSpec end
    return supply, owner, foodSpec
end


--- Whether the body condition step covers this animal this hour (it has run, or will run with
--- the pen's ledger). The rest of the hour (milk deposit) follows the same answer, so an hour is
--- either wholly the budget's or wholly the old rules'.
--- @param animal table
--- @param tick number|nil Defaults to the current hour
--- @return boolean
function RLBodyCondition.coversThisHour(animal, tick)
    if not RLBodyCondition.isEligible(animal) then return false end
    tick = tick or RLBodyCondition.getTickId()
    if tick == nil then return false end
    local state = animal.bodyCondition
    if state ~= nil and state.lastTick == tick then return true end
    -- Real-equivalent nutrition: the hour is the budget's whatever the animal ate.
    if RLFeed ~= nil and RLFeed.runsFor(animal, tick) then return true end
    return RLBodyCondition.getLedger(animal, tick) ~= nil and (animal:getInput("food") or 0) > 0
end


local lastInvalidWarning = {}

--- Run this hour's budget for an animal in its pen, if the rules cover it. Called by the server
--- from AnimalHealth.updateHealth in place of Animal:updateWeight.
--- An animal that already took this hour's step (moved to another pen in the same hour) is
--- done: true, nothing more. An animal whose pen has no ledger this hour takes the old rules for
--- the whole hour, weight and milk alike.
--- @param animal table
--- @return boolean handled False: the caller runs the old weight update instead
function RLBodyCondition.step(animal)
    if not RLBodyCondition.isEligible(animal) then return false end
    -- The weight model v2 runs its own step (RLGrowth.step, from AnimalHealth.updateHealth): the
    -- animal is handled there, never by this budget or the old weight rule.
    if RLGrowth ~= nil and RLGrowth.covers(animal) then return true end

    local tick = RLBodyCondition.getTickId()
    if tick == nil then return false end

    local state = animal.bodyCondition
    if state ~= nil and state.lastTick == tick then return true end

    local supply, owner, foodSpec = RLBodyCondition.getLedger(animal, tick)
    if supply == nil or (animal:getInput("food") or 0) <= 0 then
        local key = owner ~= nil and tostring(owner) or "?"
        if lastInvalidWarning[key] ~= tick then
            lastInvalidWarning[key] = tick
            Log:debug("RLBodyCondition: no feed ledger for this hour in %s (tick=%s), old rules this hour",
                owner ~= nil and owner.getName ~= nil and owner:getName() or "?", tostring(tick))
        end
        return false
    end

    state = RLBodyCondition.ensureState(animal, "legacy")

    local dtMonths = RLWeightMath.getHourMonths(g_currentMission.environment.daysPerPeriod)
    local water = foodSpec.rlWaterCoverage
    local waterCoverage = (water ~= nil and water.tick == tick) and water.coverage or 1

    local intakeStep, allocated = RLBodyCondition.getAllocatedIntake(animal, supply)
    local input, ownReference = RLBodyCondition.buildStepInput(animal, state, intakeStep / dtMonths, waterCoverage, dtMonths)
    local result = RLNutritionMath.step(input, RLBodyCondition.getConfig())

    if result.weight ~= result.weight or result.reserve ~= result.reserve then
        Log:warning("RLBodyCondition: step for %s/%s gave NaN, nothing applied this hour",
            tostring(animal.farmId), tostring(animal.uniqueId))
        state.lastTick = tick
        animal.rlMilkPaid = { tick = tick, litersPerHour = 0, deposited = false }
        return true
    end

    animal.weight = result.weight
    state.reserve = result.reserve
    state.balanceEMA = result.balanceEMA
    state.lossRateEMA = result.lossRateEMA
    state.lastTick = tick

    RLBodyCondition.recordHour(animal, owner, tick, { allocated = allocated, intakeStep = intakeStep, dtMonths = dtMonths,
        ownReference = ownReference, result = result, waterCoverage = waterCoverage })

    return true
end


--- What an hour's budget step leaves on the animal for the rest of the hour and the clients (the
--- body condition's and the weight model v2's alike): the milk it paid for, in output liters per
--- hour, which the pen's milk deposit takes this hour (RLBodyCondition.depositMilk); what it ate
--- against its full-feed request, its coverage and milk share (rlNutrition, the info box and the
--- state event); and the pen's mark that it stepped this hour.
--- @param animal table
--- @param owner table|nil The pen
--- @param tick number
--- @param record table { allocated, intakeStep (liters this step), dtMonths, ownReference (liters per
---        period), result (the step's), waterCoverage, paysMilk (false: this hour's milk is the old
---        rule's deposit, not the budget's), intakeSource }
function RLBodyCondition.recordHour(animal, owner, tick, record)
    local result = record.result
    local paysMilk = record.paysMilk ~= false
    local potentialPerHour = animal.rlMilk ~= nil and animal.rlMilk.potential / 24 or 0
    local milkShare = result.milkFraction * record.waterCoverage
    animal.rlMilkPaid = { tick = tick, litersPerHour = paysMilk and potentialPerHour * milkShare or 0, deposited = not paysMilk }

    animal.rlNutrition = {
        tick = tick,
        allocatedLiters = record.allocated,
        -- What it ate against what it asks for on full feed (under the fixed price not its reference).
        intakeRatio = record.ownReference > 0 and (record.intakeStep / record.dtMonths) / record.ownReference or 0,
        coverage = result.coverage,
        milkShare = (paysMilk and potentialPerHour > 0) and milkShare or nil,
        growthFraction = result.growthFraction,
        intakeSource = record.intakeSource,
    }

    if owner ~= nil then owner.rlBodyConditionStepped = tick end
end


-- =============================================================================
-- Milk
-- =============================================================================

--- Record a cow's milk at full feed (Animal:updateOutput); her output stays that potential, which
--- the old rules deposit for an hour the budget does not cover. Records nothing for an animal the
--- rules do not cover.
--- Two anchors - the milk her feed is priced for, the lactation-average milk at average
--- productivity. anchor (need-based price): with her disease, while she gives milk at all.
--- lineAnchor (fixedFeedPrice): a healthy cow's, while she would give milk without the disease, so a
--- disease lowers her milk, not her feed's energy.
--- @param animal table
--- @param potentialPerPeriod number Milk after lactation, productivity and disease
--- @param curvePerPeriod number The age curve alone
--- @param diseaseFactor number Disease milk multiplier (1 = none)
--- @param healthyPerPeriod number|nil The potential without the disease (default potentialPerPeriod)
--- @return number litersPerPeriod The potential, unchanged
function RLBodyCondition.applyMilk(animal, potentialPerPeriod, curvePerPeriod, diseaseFactor, healthyPerPeriod)
    if not RLBodyCondition.isEligible(animal) then
        animal.rlMilk = nil
        return potentialPerPeriod
    end

    local average = math.max((curvePerPeriod or 0) * RLBodyCondition.getConfig().lactationMeanFactor, 0)
    animal.rlMilk = {
        potential = potentialPerPeriod,
        anchor = potentialPerPeriod > 0 and average * (diseaseFactor or 1) or 0,
        lineAnchor = (healthyPerPeriod or potentialPerPeriod) > 0 and average or 0,
    }

    return potentialPerPeriod
end


--- Production factors other than feed (straw or bedding, a full manure or milk store): the
--- pen's own updateProduction asked with a food factor of 1, so every spec's rule applies as it
--- does to the real call - no division by the food factor. Only the stored productionFactor the
--- base spec writes is put back.
--- @param placeable table
--- @return number 0..1
function RLBodyCondition.getNonFeedProductionFactor(placeable)
    if placeable.updateProduction == nil then return 1 end
    local spec = placeable.spec_husbandry
    local saved = spec ~= nil and spec.productionFactor or nil
    local factor = placeable:updateProduction(1)
    if spec ~= nil then spec.productionFactor = saved end
    return math.clamp(factor or 0, 0, 1)
end


--- One hour's milk deposit for a store (milk tank or pallets) with the budget's share split out.
--- contributions: the liters per hour each cow put into litersPerHour when it was last summed.
--- The cows the budget covers this hour are taken out of litersPerHour before the base deposit
--- (which scales by the pen's food factor); after it - and after this hour's budget step, which
--- runs inside the chain - the liters their budgets paid for are deposited once, scaled only by
--- the non-feed production factors measured before anything was deposited.
--- @param placeable table
--- @param litersPerHour table fillType -> liters per hour (the spec's)
--- @param contributions table|nil array of {animal, fillType, liters}
--- @param superFunc function The rest of the updateOutput chain
--- @param deposit function(fillType, liters) Puts liters into the store; returns what it took
function RLBodyCondition.depositMilk(placeable, litersPerHour, contributions, superFunc, deposit)
    local tick = RLBodyCondition.getTickId()
    if contributions == nil or #contributions == 0 or tick == nil then
        superFunc()
        return
    end

    local covered, removed = {}, {}
    for _, entry in ipairs(contributions) do
        if RLBodyCondition.coversThisHour(entry.animal, tick) then
            table.insert(covered, entry)
            removed[entry.fillType] = (removed[entry.fillType] or 0) + entry.liters
        end
    end

    if #covered == 0 then
        superFunc()
        return
    end

    local nonFeed = RLBodyCondition.getNonFeedProductionFactor(placeable)

    local saved = {}
    for fillType, liters in pairs(removed) do
        if litersPerHour[fillType] ~= nil then
            saved[fillType] = litersPerHour[fillType]
            litersPerHour[fillType] = math.max(saved[fillType] - liters, 0)
        end
    end

    superFunc()

    for fillType, total in pairs(saved) do litersPerHour[fillType] = total end

    local paid = {}
    for _, entry in ipairs(covered) do
        local milk = entry.animal.rlMilkPaid
        if milk ~= nil and milk.tick == tick and not milk.deposited then
            paid[entry.fillType] = (paid[entry.fillType] or 0) + milk.litersPerHour
            milk.deposited = true
        end
    end

    local timeAdjustment = g_currentMission.environment.timeAdjustment
    local deposits = RLFeed ~= nil and RLFeed.hasObservers() and {} or nil
    for fillType, liters in pairs(paid) do
        if saved[fillType] ~= nil and liters > 0 and nonFeed > 0 then
            local requested = liters * nonFeed * timeAdjustment
            local added = deposit(fillType, requested)
            if deposits ~= nil then deposits[fillType] = { paid = liters * timeAdjustment, requested = requested, added = added } end
        end
    end
    -- Observers (TestDiagnostics): what each store was paid, asked and took this hour.
    if deposits ~= nil then RLFeed.notify("MILK", { placeable = placeable, tick = tick, nonFeed = nonFeed, deposits = deposits }) end
end


-- =============================================================================
-- Persistence and network
-- =============================================================================

--- Read a saved state (nil when the animal has none).
function RLBodyCondition.loadFromXMLFile(xmlFile, key)
    local base = key .. ".bodyCondition"
    local reserve = xmlFile:getFloat(base .. "#reserve")
    if reserve == nil then return nil end

    local version = xmlFile:getInt(base .. "#version", 1)
    if version > RLBodyCondition.STATE_VERSION then
        Log:warning("RLBodyCondition: %s has state version %d, newer than this mod's %d; dropped",
            base, version, RLBodyCondition.STATE_VERSION)
        return nil
    end

    return {
        version = version,
        reserve = math.clamp(reserve, 0, 1),
        capacityKg = math.max(xmlFile:getFloat(base .. "#capacityKg", 1), 1),
        balanceEMA = xmlFile:getFloat(base .. "#balanceEMA", 0),
        lossRateEMA = xmlFile:getFloat(base .. "#lossRateEMA", 0),
        lastTick = xmlFile:getInt(base .. "#lastTick", -1),
        source = xmlFile:getString(base .. "#source", "legacy"),
    }
end


function RLBodyCondition.saveToXMLFile(state, xmlFile, key)
    if state == nil then return end
    local base = key .. ".bodyCondition"
    xmlFile:setInt(base .. "#version", state.version or RLBodyCondition.STATE_VERSION)
    xmlFile:setFloat(base .. "#reserve", state.reserve)
    xmlFile:setFloat(base .. "#capacityKg", state.capacityKg)
    xmlFile:setFloat(base .. "#balanceEMA", state.balanceEMA or 0)
    xmlFile:setFloat(base .. "#lossRateEMA", state.lossRateEMA or 0)
    xmlFile:setInt(base .. "#lastTick", state.lastTick or -1)
    xmlFile:setString(base .. "#source", state.source or "legacy")
end


--- Write a state to a stream: a presence flag, then the fields. Order must match readStream.
function RLBodyCondition.writeStream(state, streamId)
    streamWriteBool(streamId, state ~= nil)
    if state == nil then return end
    streamWriteFloat32(streamId, state.reserve)
    streamWriteFloat32(streamId, state.capacityKg)
    streamWriteFloat32(streamId, state.balanceEMA or 0)
    streamWriteFloat32(streamId, state.lossRateEMA or 0)
    streamWriteInt32(streamId, state.lastTick or -1)
end


function RLBodyCondition.readStream(streamId)
    if not streamReadBool(streamId) then return nil end
    return {
        version = RLBodyCondition.STATE_VERSION,
        reserve = streamReadFloat32(streamId),
        capacityKg = streamReadFloat32(streamId),
        balanceEMA = streamReadFloat32(streamId),
        lossRateEMA = streamReadFloat32(streamId),
        lastTick = streamReadInt32(streamId),
        source = "stream",
    }
end


-- =============================================================================
-- Display
-- =============================================================================

--- Is a bull or steer ready to go? Weight against its slaughter reference, its finish score,
--- the slaughter age and whether it may be sold at all (a disease that bars sale) together.
--- @param animal table
--- @return string|nil key l10n key of the verdict, nil for a female or an animal not covered
--- @return number|nil reference Slaughter reference weight
function RLBodyCondition.getFinishVerdict(animal)
    if animal.gender ~= "male" or not RLBodyCondition.isEligible(animal) then return nil end

    local reference = RLBodyCondition.getReferenceWeight(animal)
    if animal.getCanBeSold ~= nil and not animal:getCanBeSold() then return "rl_ui_finishVerdictBlocked", reference end

    if AnimalMoveEvent ~= nil and AnimalMoveEvent.getCarcassConfig ~= nil then
        local carcass = AnimalMoveEvent.getCarcassConfig()
        local minAge = RLBreedTraits.resolve(carcass.layers, animal:getSubType(), "slaughterMinAgeMonth", nil)
        if minAge ~= nil and (animal.age or 0) < minAge then return "rl_ui_finishVerdictTooYoung", reference end
    end

    local score = RLBodyCondition.getFinishScore(animal)
    if score > 80 then return "rl_ui_finishVerdictOverfat", reference end

    local grown = reference ~= nil and animal.weight >= 0.95 * reference
    if grown and score >= 65 then return "rl_ui_finishVerdictReady", reference end
    if grown then return "rl_ui_finishVerdictNeedsFinish", reference end
    if score >= 65 then return "rl_ui_finishVerdictGrowing", reference end
    return "rl_ui_finishVerdictStore", reference
end

--- Text for the animal info box: "BCS 3.2 ↘" for a female, "Finish 72 (moderate)" for a male,
--- the trend arrow from the smoothed balance. nil when the rules do not cover the animal.
--- @param animal table
--- @return string|nil text
--- @return number|nil ratio 0..1 for the bar
function RLBodyCondition.getInfoText(animal)
    if not RLBodyCondition.isCoveredType(animal) or not RLBodyCondition.isEnabled() then return nil end

    if not RLBodyCondition.isEligible(animal) then
        return g_i18n:getText("rl_ui_conditionCalf"), 0
    end

    local state = animal.bodyCondition
    local balance = state ~= nil and state.balanceEMA or 0
    local trend = balance > 0.03 and " +" or (balance < -0.03 and " -" or "")

    if animal.gender == "male" then
        local score = RLBodyCondition.getFinishScore(animal)
        local band = score < 50 and "rl_ui_finishLean" or (score < 65 and "rl_ui_finishStore")
            or (score <= 80 and "rl_ui_finishReady") or (score <= 90 and "rl_ui_finishFat") or "rl_ui_finishOverfat"
        return string.format("%d (%s)%s", math.floor(score + 0.5), g_i18n:getText(band), trend), score / 100
    end

    local bcs = RLBodyCondition.getBCS(animal)
    local band = bcs < 2.5 and "rl_ui_bcsThin" or (bcs <= 3.25 and "rl_ui_bcsGood" or (bcs <= 4 and "rl_ui_bcsFleshy" or "rl_ui_bcsFat"))
    return string.format("%.1f (%s)%s", bcs, g_i18n:getText(band), trend), (bcs - 1) / 4
end


local function infoRow(animal, key, titleKey)
    animal.rlInfoRows = animal.rlInfoRows or {}
    local row = animal.rlInfoRows[key]
    if row == nil or row.titleKey ~= titleKey then
        row = { titleKey = titleKey, text = g_i18n:getText(titleKey), title = g_i18n:getText(titleKey), value = 1 }
        animal.rlInfoRows[key] = row
    end
    return row
end


--- Rows for the animal info box (Animal:addInfos). Nothing for an animal the rules do not cover.
--- @param animal table
--- @param infos table
function RLBodyCondition.addInfos(animal, infos)
    local text, ratio = RLBodyCondition.getInfoText(animal)
    if text == nil then return end

    local row = infoRow(animal, "condition", animal.gender == "male" and "rl_ui_finish" or "rl_ui_bodyCondition")
    row.ratio = math.clamp(ratio or 0, 0, 1)
    row.valueText = text
    table.insert(infos, row)

    -- Real-equivalent nutrition (calves too): real intake against plan, ration share and its
    -- limit, a bull's finishing forecast.
    if RLFeedInfoService ~= nil then
        for _, feedRow in ipairs(RLFeedInfoService.getAnimalRows(animal)) do
            row = infoRow(animal, feedRow.key, feedRow.titleKey)
            row.ratio = feedRow.ratio
            row.valueText = feedRow.valueText
            table.insert(infos, row)
        end
    end

    if not RLBodyCondition.isEligible(animal) then return end

    -- Verdict and weight against the slaughter reference are separate rows: together they do not
    -- fit one value cell of the menu's stat grid.
    local verdict, reference = RLBodyCondition.getFinishVerdict(animal)
    if verdict ~= nil then
        local weightRatio = reference ~= nil and math.clamp(animal.weight / reference, 0, 1) or 0
        row = infoRow(animal, "verdict", "rl_ui_finishVerdict")
        row.ratio = weightRatio
        row.valueText = g_i18n:getText(verdict)
        table.insert(infos, row)

        if reference ~= nil then
            row = infoRow(animal, "finishWeight", "rl_ui_finishWeight")
            row.ratio = weightRatio
            row.valueText = string.format("%.0f / %.0f kg", animal.weight, reference)
            table.insert(infos, row)
        end
    end

    local nutrition = animal.rlNutrition
    if nutrition ~= nil and nutrition.coverage ~= nil then
        row = infoRow(animal, "ration", "rl_ui_rationCoverage")
        row.ratio = math.clamp(nutrition.coverage, 0, 1)
        row.valueText = string.format("%.0f %%", nutrition.coverage * 100)
        table.insert(infos, row)

        if nutrition.milkShare ~= nil then
            row = infoRow(animal, "milk", "rl_ui_milkOfPotential")
            row.ratio = math.clamp(nutrition.milkShare, 0, 1)
            row.valueText = string.format("%.0f %%", nutrition.milkShare * 100)
            table.insert(infos, row)
        end
    end

    local subType = animal:getSubType()
    if animal.gender == "female" and subType ~= nil and (animal.age or 0) >= (subType.reproductionMinAgeMonth or 0) then
        local factor = RLBodyCondition.getFertilityFactor(animal)
        row = infoRow(animal, "conception", "rl_ui_conceptionCondition")
        row.ratio = factor
        row.valueText = string.format("%.0f %%", factor * 100)
        table.insert(infos, row)
    end
end


--- Rows for a cattle pen's info box: the condition of its covered animals and the last hour's
--- ration (on a client, from RLBodyConditionStateEvent's pen summary). One short figure per row,
--- because the info box is 340 px wide and draws key and value on the same line.
--- @param placeable table
--- @return table|nil rows List of { titleKey, text }; cow rows only with cows, bull rows only with bulls
function RLBodyCondition.getPenInfo(placeable)
    if not RLBodyCondition.isEnabled() or placeable.getAnimalTypeIndex == nil or AnimalType == nil
        or placeable:getAnimalTypeIndex() ~= AnimalType.COW then return nil end

    local cows, bcsSum, thin, fat, bulls, ready, overfat = 0, 0, 0, 0, 0, 0, 0
    for _, animal in ipairs(placeable:getClusters()) do
        if RLBodyCondition.isEligible(animal) then
            if animal.gender == "male" then
                bulls = bulls + 1
                if RLBodyCondition.getFinishVerdict(animal) == "rl_ui_finishVerdictReady" then ready = ready + 1 end
                if RLBodyCondition.getFinishScore(animal) > 80 then overfat = overfat + 1 end
            else
                local bcs = RLBodyCondition.getBCS(animal)
                cows, bcsSum = cows + 1, bcsSum + bcs
                if bcs < 2.5 then thin = thin + 1 elseif bcs > 3.75 then fat = fat + 1 end
            end
        end
    end
    if cows + bulls == 0 then return nil end

    local rows = {}
    if cows > 0 then
        table.insert(rows, { titleKey = "rl_ui_penBcs", text = string.format("%.1f", bcsSum / cows) })
        table.insert(rows, { titleKey = "rl_ui_penCowsThinFat", text = string.format("%d / %d", thin, fat) })
    end
    if bulls > 0 then
        table.insert(rows, { titleKey = "rl_ui_penBullsReady", text = string.format("%d / %d", ready, bulls) })
        table.insert(rows, { titleKey = "rl_ui_penBullsOverfat", text = string.format("%d", overfat) })
    end

    local foodSpec = placeable.spec_husbandryFood
    local summary = foodSpec ~= nil and foodSpec.rlPenSummary or nil
    local supply = foodSpec ~= nil and foodSpec.rlNutritionSupply or nil
    if supply ~= nil then
        local energy = 0
        for _, share in pairs(supply.energyShare) do energy = energy + share end
        local water = foodSpec.rlWaterCoverage
        summary = { eatenShare = supply.requested > 0 and supply.eaten / supply.requested or 0, energy = energy,
            water = water ~= nil and water.coverage or 1 }
    end

    if summary ~= nil then
        table.insert(rows, { titleKey = "rl_ui_penFeedEaten", text = string.format("%.0f %%", summary.eatenShare * 100) })
        table.insert(rows, { titleKey = "rl_ui_penRationEnergy", text = string.format("%.0f %%", summary.energy * 100) })
        table.insert(rows, { titleKey = "rl_ui_penWater", text = string.format("%.0f %%", summary.water * 100) })
    end

    return rows
end
