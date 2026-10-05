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


--- Current game hour as a number that only grows: monotonic day x 24 + hour.
--- @return number|nil
function RLBodyCondition.getTickId()
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    if environment == nil or environment.currentMonotonicDay == nil then return nil end
    return environment.currentMonotonicDay * 24 + (environment.currentHour or 0)
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


--- Reserve an animal starts with when its condition is first set up.
function RLBodyCondition.getInitialReserve(animal)
    local config = RLBodyCondition.getConfig()
    if animal.gender == "male" then return RLBodyCondition.getReserveTarget(animal) or config.initialReserve end
    return config.initialReserve
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
    local energyShare, eaten = {}, 0

    if requested > 0 then
        for fillTypeIndex, liters in pairs(window.consumed) do
            eaten = eaten + liters
            local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
            local category = (name ~= nil and forage[name:upper()]) or RLBodyCondition.OTHER_CATEGORY
            local energy = RLBodyCondition.getFeedEnergy(fillTypeIndex, spec.animalTypeIndex)
            energyShare[category] = (energyShare[category] or 0) + liters * energy / requested
        end
    end

    spec.rlNutritionSupply = {
        tick = RLBodyCondition.getTickId(),
        requested = requested,
        eaten = eaten,
        consumed = window.consumed,
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


--- What the pen's ration this hour supports for this animal (1 = a full TMR ration): the
--- energy eaten per liter requested, each forage category weighted by the breed's trait.
--- @param animal table
--- @param supply table spec.rlNutritionSupply
--- @return number
function RLBodyCondition.getSupplyRatio(animal, supply)
    local subType = animal:getSubType()
    local ratio = 0
    for category, share in pairs(supply.energyShare) do
        local digest = category == RLBodyCondition.OTHER_CATEGORY and 1 or RLBreedTraits.get(subType, category)
        ratio = ratio + share * digest
    end
    return ratio
end


-- =============================================================================
-- Hourly step
-- =============================================================================

--- The old growth line at full feed for one period: base gain x sex x age x metabolism x
--- castration x breed growth x disease weight gain (Animal:updateWeight's increase with
--- nutrition 1, and without the lactating x 0.75 the budget now replaces). An age-driven loss is
--- returned apart.
--- @param animal table
--- @return number growthKg per period (>= 0)
--- @return number ageLossKg per period (>= 0)
function RLBodyCondition.getPotentialGrowth(animal)
    local subType = animal:getSubType()
    local adultMonth = RLBreedTraits.getMatureAge(subType)
    if adultMonth <= 0 then return 0, 0 end

    local metabolism = animal.genetics.metabolism or 1
    local base = (animal.targetWeight - subType.minWeight) / adultMonth
    local increase = base * (animal.gender == "female" and RLBreedTraits.getFemaleGrowth(subType) or 1)
        * (1 + ((adultMonth - animal.age) / 75))

    if increase < 0 then return 0, -increase * (2 - metabolism) end

    increase = increase * metabolism
    if animal.isCastrated then increase = increase * 1.15 end
    increase = increase * RLBreedTraits.get(subType, "growth")

    local multipliers = animal:getDiseaseMultipliers("updateWeight")
    if multipliers ~= nil then increase = increase * multipliers.weightGain end

    return increase, 0
end


--- Fetuses and progress of a pregnancy.
local function getPregnancy(animal)
    if not animal.isPregnant or animal.pregnancy == nil or animal.pregnancy.pregnancies == nil then return 0, 0 end
    return (animal.reproduction or 0) / 100, #animal.pregnancy.pregnancies
end


--- Build the step input for an animal (no state change).
--- @param animal table
--- @param state table
--- @param supplyRatio number
--- @param waterCoverage number
--- @param dtMonths number
--- @return table
function RLBodyCondition.buildStepInput(animal, state, supplyRatio, waterCoverage, dtMonths)
    local growthKg, ageLossKg = RLBodyCondition.getPotentialGrowth(animal)
    local progress, fetuses = getPregnancy(animal)
    local milk = animal.rlMilk

    return {
        dtMonths = dtMonths,
        weight = animal.weight,
        reserve = state.reserve,
        capacityKg = state.capacityKg,
        targetWeight = animal.targetWeight,
        potentialGrowthKg = growthKg,
        ageLossKg = ageLossKg,
        potentialMilk = milk ~= nil and milk.potential * waterCoverage or 0,
        anchorMilk = milk ~= nil and milk.anchor or 0,
        isLactating = animal.isLactating and milk ~= nil and milk.potential > 0,
        pregnancyProgress = progress,
        numFetuses = fetuses,
        supplyRatio = supplyRatio,
        intakeCapacity = RLBodyCondition.getIntakeCapacity(animal),
        intakeFactor = RLBodyCondition.getIntakeFactor(animal),
        reserveTarget = RLBodyCondition.getReserveTarget(animal),
        reserveCeiling = RLBodyCondition.getReserveCeiling(animal),
        balanceEMA = state.balanceEMA,
        lossRateEMA = state.lossRateEMA,
    }
end


local lastInvalidWarning = {}

--- Run this hour's budget for an animal in its pen, if the rules cover it. Called by the server
--- from AnimalHealth.updateHealth in place of Animal:updateWeight.
--- @param animal table
--- @return boolean handled False: the caller runs the old weight update instead
function RLBodyCondition.step(animal)
    if not RLBodyCondition.isEligible(animal) then return false end

    local owner = animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil
    local foodSpec = owner ~= nil and owner.spec_husbandryFood or nil
    local supply = foodSpec ~= nil and foodSpec.rlNutritionSupply or nil
    local tick = RLBodyCondition.getTickId()

    if supply == nil or not supply.valid or tick == nil or supply.tick ~= tick then
        local key = owner ~= nil and tostring(owner) or "?"
        if lastInvalidWarning[key] ~= tick then
            lastInvalidWarning[key] = tick
            Log:debug("RLBodyCondition: no feed ledger for this hour in %s (supply=%s tick=%s), old weight rules this hour",
                owner ~= nil and owner.getName ~= nil and owner:getName() or "?", tostring(supply ~= nil and supply.tick),
                tostring(tick))
        end
        return false
    end

    local state = RLBodyCondition.ensureState(animal, "legacy")
    if state.lastTick == tick then return true end

    local environment = g_currentMission.environment
    local dtMonths = 1 / (24 * math.max(environment.daysPerPeriod or 1, 1))
    local water = foodSpec.rlWaterCoverage
    local waterCoverage = (water ~= nil and water.tick == tick) and water.coverage or 1

    local supplyRatio = RLBodyCondition.getSupplyRatio(animal, supply)
    local input = RLBodyCondition.buildStepInput(animal, state, supplyRatio, waterCoverage, dtMonths)
    local result = RLNutritionMath.step(input, RLBodyCondition.getConfig())

    if result.weight ~= result.weight or result.reserve ~= result.reserve then
        Log:warning("RLBodyCondition: step for %s/%s gave NaN, old weight rules this hour",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return false
    end

    animal.weight = result.weight
    state.reserve = result.reserve
    state.balanceEMA = result.balanceEMA
    state.lossRateEMA = result.lossRateEMA
    state.lastTick = tick

    animal.rlMilkSupport = result.milkFraction * waterCoverage
    animal.rlNutrition = {
        tick = tick,
        supplyRatio = supplyRatio,
        milkFraction = result.milkFraction,
        growthFraction = result.growthFraction,
        unmetNU = result.unmetNU,
        demandNU = result.demandNU,
    }

    return true
end


-- =============================================================================
-- Milk
-- =============================================================================

--- Record a cow's milk at full feed (Animal:updateOutput) and return what she gives: the
--- potential x the share of it her last budget paid for. Records nothing and returns the
--- potential unchanged for an animal the rules do not cover.
--- @param animal table
--- @param potentialPerPeriod number Milk after lactation, productivity and disease
--- @param curvePerPeriod number The age curve alone
--- @param diseaseFactor number Disease milk multiplier (1 = none)
--- @return number litersPerPeriod
function RLBodyCondition.applyMilk(animal, potentialPerPeriod, curvePerPeriod, diseaseFactor)
    if not RLBodyCondition.isEligible(animal) then
        animal.rlMilk = nil
        return potentialPerPeriod
    end

    local anchor = 0
    if potentialPerPeriod > 0 then
        anchor = curvePerPeriod * RLBodyCondition.getConfig().lactationMeanFactor * (diseaseFactor or 1)
    end

    animal.rlMilk = { potential = potentialPerPeriod, anchor = anchor, managed = true }

    return potentialPerPeriod * math.clamp(animal.rlMilkSupport or 1, 0, 1)
end


--- Whether this animal's milk output went through the budget (its liters are already scaled
--- by feed and water, so the deposit must not scale them by the pen's food factor again).
function RLBodyCondition.isMilkManaged(animal)
    return animal.rlMilk ~= nil and animal.rlMilk.managed == true and RLBodyCondition.isEligible(animal)
end


--- Production factors other than feed (straw, a full store): productionFactor / foodFactor.
--- With no food at all the ratio is unknown; a store with room then counts as 1.
--- @param foodFactor number
--- @param productionFactor number
--- @param hasRoom boolean
--- @return number
function RLBodyCondition.getNonFeedProductionFactor(foodFactor, productionFactor, hasRoom)
    if (foodFactor or 0) > 1e-6 then return math.clamp((productionFactor or 0) / foodFactor, 0, 1) end
    return hasRoom and 1 or 0
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
