--[[
    RLSemenCollection.lua
    Rules for collecting semen from the player's own sires into a dewar, and for selling a
    dewar back. A collected dewar carries the sire's snapshot like a bought one, so its straws
    inseminate with that sire's genetics, and its sale value follows the same breeding-index
    formula the AI dealer charges (getStrawPrice) - a better sire's semen is worth more.

    One collection per sire per calendar month (tracked on the animal as `semenCollectedMonth`, a
    running month index; saves from before it carry `semenCollectedAge`, the sire's age in months,
    which still blocks that month). Straws per collection = the species' base x the sire's
    fertility gene x an age curve built from the same fertile-age limits natural breeding uses x
    his body condition, rounded; no random part, so the dialog shows the exact count. Hof
    Bergmann's bull stable scales its semen by the same age curve. Each collection costs a service
    fee (fixed part + processing per straw), scaled with the difficulty like livestock prices.
    A month's semen goes one way only: once a semen-storing
    building (Hof Bergmann's bull stable) has taken a sire's output that month, it cannot be
    collected into a dewar; once collected, the building gets no semen from it until next month.
]]

RLSemenCollection = {}

local Log = RmLogging.getLogger("RLRM")

--- Straws from one collection by a sire of average fertility at peak age, per animal type.
--- Species absent here (poultry, rabbits, pets) have no AI trade in RLRM's world.
RLSemenCollection.STRAWS_PER_COLLECTION = {
    COW = 300,   -- a bull ejaculate is diluted into several hundred straws
    SHEEP = 100, -- rams and bucks
    PIG = 20,    -- boar semen is sold as liquid doses, far fewer per collection
    HORSE = 12,  -- stallion doses
}

--- Minimum collection age (months) for subtypes without a reproduction age (Hof Bergmann's BULL).
RLSemenCollection.DEFAULT_MIN_AGE = { COW = 12, SHEEP = 8, PIG = 8, HORSE = 24 }

--- Last fertile month per type, before the fertility-gene multiplier. Mirrors the sire limits in
--- AnimalReproduction so a sire too old to breed naturally is too old to collect from.
RLSemenCollection.MAX_FERTILE_AGE = { COW = 132, SHEEP = 72, PIG = 48, HORSE = 300 }

--- Collection service fee per species, on HARD (x RLLivestockPrices.getMultiplier like the prices):
--- a fixed part for the visit (collection, semen check) plus processing per straw (dilution,
--- filling, freezing). Starting values for game balance, not real-world costs: an average bull's
--- 300 straws cost 400 against about 760 if sold and about 1080 to buy, so own use saves clearly,
--- selling an average sire's semen nets about half its value, and a poor sire's does not pay.
RLSemenCollection.FEE = {
    COW = { base = 100, perStraw = 1 },
    SHEEP = { base = 30, perStraw = 1 },
    PIG = { base = 10, perStraw = 1 },
    HORSE = { base = 10, perStraw = 1 },
}

--- Sire body condition (BCS 1..5) -> factor on straws per collection. Thin bulls produce less
--- semen; at factor 0 (BCS 1.5 and below) collection is refused. The fat side is kept mild: a
--- grown bull on full feed follows the finishing target (bodyCondition.xml) to BCS 4-4.6, and a
--- pen has no separate sire ration to hold him leaner, so only an extreme 5 costs straws.
--- Read only where the body condition rules apply to the sire and his species' condition touches
--- reproduction (cattle); every other sire reads 1.
RLSemenCollection.CONDITION_CURVE = {
    { 1.5, 0 }, { 2.0, 0.7 }, { 2.5, 1 }, { 4.5, 1 }, { 5.0, 0.9 },
}

--- Share of the dealer's price a dewar sells for: a breeder selling straws privately keeps
--- roughly 70-90% of retail after sale commission and storage. Below 1 so buying and reselling
--- never profits.
RLSemenCollection.SELL_SHARE = 0.7

--- Dealer price factor for the player's own semen. The dealer's sires come from farms of quality
--- 1.35 to 1.75 whose price factor is 0.75-1.25 x quality, 1.55 on average; the player's semen is
--- priced like an average AI stud's, so the same genetics resell at about 70% of the dealer's
--- price instead of losing the stud premium on top.
RLSemenCollection.COLLECTED_PRICE_FACTOR = 1.55

--- Breeding index weights. Real sire indices (Net Merit, TPI, beef $indices) are weighted sums of
--- the traits a breed is kept for: dairy sires are ranked mostly on their daughters' milk, then
--- fertility and health; meat and wool sires on carcass merit and growth/feed efficiency.
RLSemenCollection.INDEX_WEIGHTS = {
    DAIRY = { productivity = 0.40, fertility = 0.20, health = 0.20, quality = 0.10, metabolism = 0.10 },
    MEAT = { quality = 0.35, metabolism = 0.25, fertility = 0.20, health = 0.10, productivity = 0.10 },
}

--- Breeds kept for milk; every other breed is weighted as a meat (or wool) breed.
RLSemenCollection.DAIRY_BREEDS = { HOLSTEIN = true, SWISS_BROWN = true, WATER_BUFFALO = true, GOAT = true }

--- Semen price rises with the cube of the index: a sire 25% above average is worth about twice as
--- much, one a third below average about a third, much as elite and ordinary bulls differ in the
--- straw market.
RLSemenCollection.INDEX_PRICE_EXPONENT = 3

--- Refusal reasons, as i18n keys.
RLSemenCollection.REFUSAL = {
    NOT_MALE = "rl_semen_refuseNotMale",
    SPECIES = "rl_semen_refuseSpecies",
    INFERTILE = "rl_semen_refuseInfertile",
    TOO_YOUNG = "rl_semen_refuseTooYoung",
    TOO_OLD = "rl_semen_refuseTooOld",
    COLLECTED = "rl_semen_refuseCollected",
    PRODUCED = "rl_semen_refuseProduced",
    SICK = "rl_semen_refuseSick",
    CONDITION = "rl_semen_refuseCondition",
    NO_YIELD = "rl_semen_refuseNoYield",
}

--- Refusal the server sends when the farm cannot pay the fee (not an animal rule: getRefusal
--- never returns it).
RLSemenCollection.REFUSAL_NO_MONEY = "rl_semen_refuseNoMoney"


--- The animal type name ("COW", "SHEEP", ...) of an animal, or nil.
function RLSemenCollection.getTypeName(animal)
    local animalSystem = g_currentMission.animalSystem
    local subType = animal.getSubType ~= nil and animal:getSubType() or nil
    local animalType = subType ~= nil and animalSystem:getTypeByIndex(subType.typeIndex) or nil
    return animalType ~= nil and animalType.name or nil
end


--- Whether an animal is male. The subtype counts too: Hof Bergmann's BULL was loaded as female
--- before the bridge marked it male, and existing animals keep the gender they were saved with.
function RLSemenCollection.isMale(animal)
    if animal.gender == "male" then return true end
    local subType = animal.getSubType ~= nil and animal:getSubType() or nil
    return subType ~= nil and subType.gender == "male"
end


--- Collection age window for an animal: first month and last fertile month.
--- @return number|nil minAge, number|nil maxAge
function RLSemenCollection.getAgeWindow(animal)
    local typeName = RLSemenCollection.getTypeName(animal)
    local subType = animal:getSubType()
    local minAge = subType.reproductionMinAgeMonth or RLSemenCollection.DEFAULT_MIN_AGE[typeName]

    local maxAge = RLMapBridge ~= nil and RLMapBridge.getMaxFertilityAge ~= nil
        and RLMapBridge.getMaxFertilityAge(subType.name) or nil
    maxAge = maxAge or RLSemenCollection.MAX_FERTILE_AGE[typeName]
    if maxAge ~= nil then maxAge = maxAge * (animal.genetics.fertility or 1) end

    return minAge, maxAge
end


--- A running month count (12 per engine year), the same as RLPastureSeason.getMonthIndex; nil
--- without an environment.
--- @param environment table|nil Defaults to the mission's
--- @return number|nil
function RLSemenCollection.getMonthIndex(environment)
    environment = environment or (g_currentMission ~= nil and g_currentMission.environment or nil)
    if environment == nil or environment.currentPeriod == nil then return nil end
    return (environment.currentYear or 0) * 12 + environment.currentPeriod - 1
end


--- Whether this sire has been collected from in the current month: the calendar month on record,
--- or for a sire collected before that record existed, his age then (he ages once a month).
function RLSemenCollection.isCollectedThisMonth(animal)
    local month = RLSemenCollection.getMonthIndex()
    if animal.semenCollectedMonth ~= nil and month ~= nil then
        return animal.semenCollectedMonth >= month
    end
    return animal.semenCollectedAge ~= nil and animal.age ~= nil and animal.age <= animal.semenCollectedAge
end


--- Record a collection in the current month on the sire.
function RLSemenCollection.markCollected(animal)
    animal.semenCollectedMonth = RLSemenCollection.getMonthIndex()
    animal.semenCollectedAge = animal.age
end


--- Undo markCollected (the dewar failed to load), restoring what was on record before.
function RLSemenCollection.restoreCollected(animal, month, age)
    animal.semenCollectedMonth = month
    animal.semenCollectedAge = age
end


--- Why this animal cannot be collected from right now, or nil when it can.
--- @return string|nil refusal One of RLSemenCollection.REFUSAL
function RLSemenCollection.getRefusal(animal)
    if not RLSemenCollection.isMale(animal) then return RLSemenCollection.REFUSAL.NOT_MALE end

    local typeName = RLSemenCollection.getTypeName(animal)
    if typeName == nil or RLSemenCollection.STRAWS_PER_COLLECTION[typeName] == nil then
        return RLSemenCollection.REFUSAL.SPECIES
    end

    if animal.isCastrated or (animal.genetics.fertility or 0) <= 0 then
        return RLSemenCollection.REFUSAL.INFERTILE
    end

    local minAge, maxAge = RLSemenCollection.getAgeWindow(animal)
    if minAge ~= nil and animal.age < minAge then return RLSemenCollection.REFUSAL.TOO_YOUNG end
    if maxAge ~= nil and animal.age >= maxAge then return RLSemenCollection.REFUSAL.TOO_OLD end

    if RLSemenCollection.isCollectedThisMonth(animal) then
        return RLSemenCollection.REFUSAL.COLLECTED
    end

    -- A month's semen goes one way: stored by a semen building (Hof Bergmann's bull stable)
    -- or collected into a dewar, whichever comes first.
    if animal.semenProducedAge ~= nil and animal.age <= animal.semenProducedAge then
        return RLSemenCollection.REFUSAL.PRODUCED
    end

    if RLDiseaseSaleGate ~= nil and not RLDiseaseSaleGate.check(animal) then
        return RLSemenCollection.REFUSAL.SICK
    end

    if RLSemenCollection.getConditionFactor(animal) <= 0 then
        return RLSemenCollection.REFUSAL.CONDITION
    end

    if RLSemenCollection.getStrawYield(animal) < 1 then
        return RLSemenCollection.REFUSAL.NO_YIELD
    end

    return nil
end


--- Output factor over the fertile life: half at the first month, full from 1.5x that age,
--- then falling from 70% of the cutoff age (maxAge) toward 30% just before it. Output itself
--- stops at the cutoff: getAgeOutputFactor is 0 from maxAge on.
function RLSemenCollection.getAgeFactor(age, minAge, maxAge)
    if minAge == nil or maxAge == nil or maxAge <= minAge then return 1 end

    local peakStart = math.min(minAge * 1.5, maxAge)
    local declineStart = math.max(maxAge * 0.7, peakStart)

    if age < peakStart then
        return 0.5 + 0.5 * (age - minAge) / math.max(peakStart - minAge, 1)
    elseif age <= declineStart then
        return 1
    end
    return 1 - 0.7 * (age - declineStart) / math.max(maxAge - declineStart, 1)
end


--- Share of a sire's peak semen output at its current age: getAgeFactor inside the collection
--- age window, 0 outside it. Dewar straws and a semen-storing building's output (Hof Bergmann's
--- bull stable) both follow it, so a sire yields the same share either way.
function RLSemenCollection.getAgeOutputFactor(animal)
    local minAge, maxAge = RLSemenCollection.getAgeWindow(animal)
    if minAge ~= nil and animal.age < minAge then return 0 end
    if maxAge ~= nil and animal.age >= maxAge then return 0 end
    return math.clamp(RLSemenCollection.getAgeFactor(animal.age, minAge, maxAge), 0, 1)
end


--- Factor of the sire's body condition on his straws (CONDITION_CURVE), 1 where the body
--- condition rules do not apply to him or his species' condition leaves reproduction alone
--- (fertilityEffect 0: sheep, pigs).
function RLSemenCollection.getConditionFactor(animal)
    if RLBodyCondition == nil or not RLBodyCondition.appliesTo(animal) then return 1 end
    local config = RLBodyCondition.getConfig(animal)
    if config ~= nil and config.fertilityEffect == 0 then return 1 end
    return math.max(RLNutritionMath.interpolate(RLSemenCollection.CONDITION_CURVE, RLBodyCondition.getBCS(animal)), 0)
end


--- The factors behind one collection's straws.
--- @return table { base, fertility, age, condition, straws }; straws 0 when nothing can be collected
function RLSemenCollection.getYieldBreakdown(animal)
    local result = { base = RLSemenCollection.STRAWS_PER_COLLECTION[RLSemenCollection.getTypeName(animal) or ""] or 0,
        fertility = animal.genetics.fertility or 1, age = RLSemenCollection.getAgeOutputFactor(animal),
        condition = RLSemenCollection.getConditionFactor(animal), straws = 0 }

    if result.base > 0 and result.age > 0 and result.fertility > 0 and result.condition > 0 then
        -- One dewar holds the lot: the largest base (300) x the gene ceiling stays under CAPACITY.
        result.straws = math.min(math.floor(result.base * result.fertility * result.age * result.condition + 0.5),
            DewarData.CAPACITY)
    end
    return result
end


--- Straws one collection yields from this animal: 0 when it cannot be collected from, and no
--- straw is made up when the rounded yield is under one (getRefusal refuses then).
function RLSemenCollection.getStrawYield(animal)
    return RLSemenCollection.getYieldBreakdown(animal).straws
end


--- Service fee of a collection of `straws` from a sire of this type, 0 for a type without one.
function RLSemenCollection.getCollectionFee(typeName, straws)
    local fee = RLSemenCollection.FEE[typeName or ""]
    if fee == nil or straws == nil or straws <= 0 then return 0 end
    local multiplier = RLLivestockPrices ~= nil and RLLivestockPrices.getMultiplier() or 1
    return (fee.base + fee.perStraw * straws) * multiplier
end


--- The fee of collecting from this animal now.
function RLSemenCollection.getFee(animal)
    return RLSemenCollection.getCollectionFee(RLSemenCollection.getTypeName(animal), RLSemenCollection.getStrawYield(animal))
end


--- A refusal's text for the player; an already collected sire also hears the month he can be
--- collected from again, a young one the age.
function RLSemenCollection.getRefusalText(refusal, animal)
    local text = g_i18n:getText(refusal)
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil

    if refusal == RLSemenCollection.REFUSAL.COLLECTED and environment ~= nil and environment.currentPeriod ~= nil then
        local nextPeriod = environment.currentPeriod % 12 + 1
        text = text .. " " .. string.format(g_i18n:getText("rl_semen_nextCollection"), g_i18n:formatPeriod(nextPeriod))
    elseif refusal == RLSemenCollection.REFUSAL.TOO_YOUNG and animal ~= nil then
        local minAge = RLSemenCollection.getAgeWindow(animal)
        if minAge ~= nil then text = text .. " " .. string.format(g_i18n:getText("rl_semen_minAge"), minAge) end
    end

    return text
end


--- The confirmation text before a collection: the sire, the straws and their factors, his
--- breeding index and the fee.
function RLSemenCollection.getPreviewText(animal)
    local breakdown = RLSemenCollection.getYieldBreakdown(animal)
    local name = animal.getName ~= nil and animal:getName() or nil
    if name == nil or name == "" then name = tostring(animal.uniqueId) end

    return string.format(g_i18n:getText("rl_semen_preview"), name, breakdown.straws,
        breakdown.base, breakdown.fertility, breakdown.age, breakdown.condition,
        RLSemenCollection.getBreedingIndex(animal),
        g_i18n:formatMoney(RLSemenCollection.getFee(animal), 0, true, true))
end


--- Conception rate of a collection: the same roll the AI dealer gives its bulls.
function RLSemenCollection.rollSuccess(animal)
    return math.clamp((math.random(35, 50) * (animal.genetics.fertility or 1)) / 100, 0.5, 1)
end


--- The dewar snapshot of a collected sire, in the shape DewarData:setAnimal stores.
function RLSemenCollection.createSnapshot(animal)
    return {
        country = animal.birthday.country,
        farmId = animal.farmId,
        uniqueId = animal.uniqueId,
        name = animal:getName(),
        typeIndex = animal.animalTypeIndex,
        subTypeIndex = animal.subTypeIndex,
        genetics = table.clone(animal.genetics, 3),
        success = RLSemenCollection.rollSuccess(animal),
        collected = true,
    }
end


--- A sire's breeding index: the weighted mean of its genes for what its breed is kept for, 1 for
--- an average sire. Genes the species lacks (productivity for pigs and horses) are left out and
--- the other weights share their part.
--- @param sire table Animal or dewar snapshot with `.genetics` and `.subTypeIndex`
--- @return number index
function RLSemenCollection.getBreedingIndex(sire)
    local genetics = sire ~= nil and sire.genetics or nil
    if genetics == nil then return 1 end

    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    local subType = animalSystem ~= nil and sire.subTypeIndex ~= nil and animalSystem:getSubTypeByIndex(sire.subTypeIndex) or nil
    local isDairy = subType ~= nil and RLSemenCollection.DAIRY_BREEDS[subType.breed or ""] == true
    local weights = RLSemenCollection.INDEX_WEIGHTS[isDairy and "DAIRY" or "MEAT"]

    local sum, weightSum = 0, 0
    for gene, weight in pairs(weights) do
        local value = genetics[gene]
        if type(value) == "number" then
            sum = sum + value * weight
            weightSum = weightSum + weight
        end
    end

    return weightSum > 0 and sum / weightSum or 1
end


--- The dealer's price for one straw of a sire:
---   priceFactor x PRICE_PER_STRAW x conception rate x breedingIndex ^ INDEX_PRICE_EXPONENT
---   x the difficulty price multiplier (RLLivestockPrices: 1 on HARD, 1.8 NORMAL, 3 EASY)
--- @param sire table Animal or dewar snapshot with `.success`, `.genetics`, `.subTypeIndex`
--- @param priceFactor number The breeding farm's semen price factor
--- @return number price
function RLSemenCollection.getStrawPrice(sire, priceFactor)
    local index = RLSemenCollection.getBreedingIndex(sire)
    return math.max((priceFactor or 1) * DewarData.PRICE_PER_STRAW * ((sire ~= nil and sire.success) or 0)
        * index ^ RLSemenCollection.INDEX_PRICE_EXPONENT * RLLivestockPrices.getMultiplier(), 0)
end


--- What a dewar sells for: the AI dealer's price for its straws times SELL_SHARE. Bought semen
--- keeps its breeder's price factor; the player's own semen is priced like an average AI stud's.
--- @param snapshot table Dewar animal snapshot
--- @param straws number
--- @return number value
function RLSemenCollection.getSellValue(snapshot, straws)
    if snapshot == nil or straws == nil or straws <= 0 then return 0 end

    local priceFactor = RLSemenCollection.COLLECTED_PRICE_FACTOR
    if not snapshot.collected then
        local animalSystem = g_currentMission.animalSystem
        priceFactor = animalSystem.getFarmSemenPrice ~= nil
            and animalSystem:getFarmSemenPrice(snapshot.country, snapshot.farmId) or 1
    end

    return straws * RLSemenCollection.getStrawPrice(snapshot, priceFactor) * RLSemenCollection.SELL_SHARE
end


Log:debug("RLSemenCollection: loaded")
