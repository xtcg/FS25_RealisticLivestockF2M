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


--- Whether a mother of this type and subtype starts milking when she gives birth: cattle and goats.
--- @param animalTypeIndex number|nil
--- @param subTypeName string|nil
--- @return boolean
function RLLactation.startsAtBirth(animalTypeIndex, subTypeName)
    return (AnimalType ~= nil and animalTypeIndex == AnimalType.COW) or subTypeName == "GOAT"
end


--- Whether a mother is still milking this long after her last birth; an unknown time is dry.
function RLLactation.isWithin(monthsSinceLastBirth)
    return monthsSinceLastBirth ~= nil and monthsSinceLastBirth < RLLactation.MONTHS
end


--- Yield through the lactation, a fixed shape that MONTHS only ends: 0.8 at birth rising to 1.3 at
--- 3 months, then 0.8 + (11 - months) / 15 (1.267 at 4, 0.933 at 9); 0 from MONTHS on, or unknown.
--- @return number
function RLLactation.getYieldFactor(monthsSinceLastBirth)
    if not RLLactation.isWithin(monthsSinceLastBirth) then return 0 end
    if monthsSinceLastBirth <= 3 then return 0.8 + monthsSinceLastBirth / 6 end
    return 0.8 + (11 - monthsSinceLastBirth) / 15
end
