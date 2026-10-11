--[[
    RLMilkParity.lua
    Cattle milk by parity. The mature cow's milk (the animals.xml curve at its mature age,
    1.2 x the real lactation average) is the third lactation and later: 100%. A first lactation
    gives FIRST of it, a second SECOND (a Holstein heifer's first lactation about 80% of a mature
    cow's, a second 90-95%). The game's curve steps with age (heifer value 12-36 months, mature value
    after), which put the first calving at 59% for a Holstein and the second at once at 100%; the
    curve is now read at 36 months at the earliest and the parity sets the level instead.

    Parity is what the animal's record says: the calves it has had (animal.children). A record
    can be missing (an animal that came in with no history) or short (one bought mature), so age
    sets a floor. With calves on record: from 37 months at least the second lactation, from 50 the
    third (a heifer calving at 24 is in her first until 35 and in her second from her calving at
    37 until 48, so the floor never moves a lactation that is running). With no calf on record age
    alone decides: under 30 months the first, under 43 the second, then the third; such an animal
    can change level inside a lactation. Twins count as two calves, so a heifer with twins gives
    her second-lactation level in her first: a rare, small error.
    No engine globals: the arguments are the animal's.
]]

RLMilkParity = {}

RLMilkParity.FIRST = 0.80
RLMilkParity.SECOND = 0.92
RLMilkParity.MATURE_AGE_MONTHS = 60
RLMilkParity.FIRST_UNTIL_AGE = 30
RLMilkParity.SECOND_UNTIL_AGE = 43
RLMilkParity.RECORDED_SECOND_FROM_AGE = 37
RLMilkParity.RECORDED_THIRD_FROM_AGE = 50


--- The lactation number of an animal that is lactating now (1, 2 or 3 for the third and later).
--- @param childCount number|nil Calves on its record
--- @param ageMonths number
--- @return number
function RLMilkParity.getParity(childCount, ageMonths)
    local age = ageMonths or 0
    if (childCount or 0) <= 0 then
        if age < RLMilkParity.FIRST_UNTIL_AGE then return 1 end
        if age < RLMilkParity.SECOND_UNTIL_AGE then return 2 end
        return 3
    end
    local floor = 1
    if age >= RLMilkParity.RECORDED_THIRD_FROM_AGE then
        floor = 3
    elseif age >= RLMilkParity.RECORDED_SECOND_FROM_AGE then
        floor = 2
    end
    return math.min(math.max(childCount, floor), 3)
end


--- Level of the lactation against the mature cow's.
--- @param parity number
--- @return number
function RLMilkParity.getFactor(parity)
    if parity <= 1 then return RLMilkParity.FIRST end
    if parity == 2 then return RLMilkParity.SECOND end
    return 1
end


--- The age the milk curve is read at: from 12 months (the curve's first point) the mature age, so
--- the heifer step of the curve is not used; later ages as they are.
--- @param ageMonths number
--- @return number
function RLMilkParity.getCurveAge(ageMonths)
    if ageMonths >= 12 and ageMonths < RLMilkParity.MATURE_AGE_MONTHS then return RLMilkParity.MATURE_AGE_MONTHS end
    return ageMonths
end
