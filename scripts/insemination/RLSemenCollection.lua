--[[
    RLSemenCollection.lua
    Rules for collecting semen from the player's own sires into a dewar, and for selling a
    dewar back. A collected dewar carries the sire's snapshot like a bought one, so its straws
    inseminate with that sire's genetics, and its sale value follows the same breeding-index
    formula the AI dealer charges (getStrawPrice) - a better sire's semen is worth more.

    One collection per sire per month (tracked on the animal as `semenCollectedAge`). Straws per
    collection scale with the sire's fertility and an age curve built from the same fertile-age
    limits natural breeding uses; Hof Bergmann's bull stable scales its semen by the same curve.
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
}


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

    if animal.semenCollectedAge ~= nil and animal.age <= animal.semenCollectedAge then
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


--- Straws one collection yields from this animal (0 when it cannot be collected from).
function RLSemenCollection.getStrawYield(animal)
    local base = RLSemenCollection.STRAWS_PER_COLLECTION[RLSemenCollection.getTypeName(animal) or ""]
    if base == nil then return 0 end

    local ageFactor = RLSemenCollection.getAgeOutputFactor(animal)
    local fertility = animal.genetics.fertility or 1
    if ageFactor <= 0 or fertility <= 0 then return 0 end

    local straws = math.floor(base * fertility * ageFactor + 0.5)

    return math.clamp(straws, 1, DewarData.CAPACITY)
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
