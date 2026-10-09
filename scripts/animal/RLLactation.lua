--[[
    RLLactation.lua
    The game's milk rule in one place: which mothers start milking when they give birth (cattle and
    goats), how long they milk (MONTHS after the birth) and the yield curve over those months.
    Births (AnimalReproduction.reproduce, AnimalBirthEvent), the monthly tick
    (Animal:advanceRecoveryPeriod), the milk yield (Animal:getLactationFactor), the pen feed forecast
    and the dealer (RLDealerStockPolicy.isInMilk) all read it.

    Pure: reads AnimalType at call time only.
]]

RLLactation = {}

--- Months a mother milks after giving birth: she stops when monthsSinceLastBirth reaches it.
RLLactation.MONTHS = 10

--- Months from the birth to the peak of the yield curve.
RLLactation.PEAK_MONTH = 3


--- Whether a mother of this type and subtype starts milking when she gives birth: cattle and goats.
--- @param animalTypeIndex number|nil
--- @param subTypeName string|nil
--- @return boolean
function RLLactation.startsAtBirth(animalTypeIndex, subTypeName)
    return animalTypeIndex == AnimalType.COW or subTypeName == "GOAT"
end


--- Whether a mother is still milking this long after her last birth.
function RLLactation.isWithin(monthsSinceLastBirth)
    return (monthsSinceLastBirth or 0) < RLLactation.MONTHS
end


--- Yield through the lactation: 0.8 at birth, rising to 1.3 at the peak (3 months), then falling
--- by 1/15 a month to 0.8 + 1/15 in the last month; 0 from MONTHS on.
--- @return number
function RLLactation.getYieldFactor(monthsSinceLastBirth)
    if not RLLactation.isWithin(monthsSinceLastBirth) then return 0 end
    if monthsSinceLastBirth <= RLLactation.PEAK_MONTH then return 0.8 + monthsSinceLastBirth / 6 end
    return 0.8 + (RLLactation.MONTHS + 1 - monthsSinceLastBirth) / 15
end
