--[[
    RLLactation.lua
    The game's milk rule in one place: which mothers start milking when they give birth (cattle and
    goats), how long they milk (MONTHS after the birth; a suckler breed until its calves are weaned)
    and the yield curve over those months.
    Births (AnimalReproduction.reproduce, AnimalBirthEvent), the monthly tick
    (Animal:advanceRecoveryPeriod), the milk yield (Animal:getLactationFactor), the pen feed forecast
    and the dealer (RLDealerStockPolicy.isInMilk, a suckler breed's youngest age) all read it.

    Pure but for getSucklingMonths / getMonths, which read the breed traits config (RLBreedTraits);
    AnimalType is read at call time only.
]]

RLLactation = {}

--- Months a mother milks after giving birth: she stops when monthsSinceLastBirth reaches it.
RLLactation.MONTHS = 10


--- Whether a mother of this type and subtype starts milking when she gives birth: cattle and goats.
--- @param animalTypeIndex number|nil
--- @param subTypeName string|nil
--- @return boolean
function RLLactation.startsAtBirth(animalTypeIndex, subTypeName)
    return (AnimalType ~= nil and animalTypeIndex == AnimalType.COW) or subTypeName == "GOAT"
end


--- A suckler breed's suckling period (breedTraits sucklingMonths): its calves are weaned from their
--- dam at this age and she is dried off then. nil for any other breed (dairy breeds,
--- whose calves are taken off early, and other species). At most MONTHS.
--- @param subType table|nil
--- @return number|nil months
function RLLactation.getSucklingMonths(subType)
    if subType == nil or RLBreedTraits == nil or RLBreedTraits.getConfig == nil or RLBreedTraits.resolve == nil then return nil end
    local months = RLBreedTraits.resolve(RLBreedTraits.getConfig().layers, subType, "sucklingMonths", nil)
    if type(months) ~= "number" or months ~= months or months <= 0 then return nil end
    return math.min(math.max(months, 1), RLLactation.MONTHS)
end


--- Months a mother of this subtype milks after giving birth: a suckler breed's suckling period,
--- else MONTHS.
--- @param subType table|nil
--- @return number
function RLLactation.getMonths(subType)
    return RLLactation.getSucklingMonths(subType) or RLLactation.MONTHS
end


--- Whether a mother is still milking this long after her last birth; an unknown time is dry.
--- @param monthsSinceLastBirth number|nil
--- @param months number|nil Her lactation length (getMonths); nil: MONTHS
function RLLactation.isWithin(monthsSinceLastBirth, months)
    return monthsSinceLastBirth ~= nil and monthsSinceLastBirth < (months or RLLactation.MONTHS)
end


--- Yield through the lactation, a fixed shape that the lactation length only ends: 0.8 at birth
--- rising to 1.3 at 3 months, then 0.8 + (11 - months) / 15 (1.267 at 4, 0.933 at 9); 0 from the
--- end of the lactation on, or unknown.
--- @param monthsSinceLastBirth number|nil
--- @param months number|nil Her lactation length (getMonths); nil: MONTHS
--- @return number
function RLLactation.getYieldFactor(monthsSinceLastBirth, months)
    if not RLLactation.isWithin(monthsSinceLastBirth, months) then return 0 end
    if monthsSinceLastBirth <= 3 then return 0.8 + monthsSinceLastBirth / 6 end
    return 0.8 + (11 - monthsSinceLastBirth) / 15
end
