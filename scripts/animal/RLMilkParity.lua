--[[
    RLMilkParity.lua
    Cattle milk by parity. The mature cow's milk (the animals.xml curve at its mature age,
    1.2 x the real lactation average) is the third lactation and later: 100%. A first lactation
    gives FIRST of it, a second SECOND (a Holstein heifer's first lactation about 80% of a mature
    cow's, a second 90-95%). The game's curve steps with age (heifer value 12-36 months, mature value
    after), which put the first calving at 59% for a Holstein and the second at once at 100%; the
    curve is now read at 36 months at the earliest and the parity sets the level instead.

    Parity is the number of calves on the animal's record (animal.children): the record is the one
    anchor, age does not decide a lactation's level. An animal with no record at all (dealer stock,
    a mature cow that came in, an old savegame's animal) gets its record filled once, from its age
    (under 30 months one calf, under 43 two, then three): empty entries, kept, saved and streamed
    like any child, so its count is what the lactation numbers from then on. A record is never
    topped up against age: a heifer that calves late stays in her first lactation. Twins count as
    two calves and a calf born dead leaves no entry, so a heifer with twins gives her
    second-lactation level in her first and a cow whose first calf died one level less later: rare,
    small errors.
    No engine globals: the arguments are the animal's.
]]

RLMilkParity = {}

RLMilkParity.FIRST = 0.80
RLMilkParity.SECOND = 0.92
RLMilkParity.MATURE_AGE_MONTHS = 60
RLMilkParity.FIRST_UNTIL_AGE = 30
RLMilkParity.SECOND_UNTIL_AGE = 43


--- The calves an animal of this age with no record is taken to have had (its record is filled to this).
--- @param ageMonths number
--- @return number 1, 2 or 3
function RLMilkParity.getImpliedCalves(ageMonths)
    local age = ageMonths or 0
    if age < RLMilkParity.FIRST_UNTIL_AGE then return 1 end
    if age < RLMilkParity.SECOND_UNTIL_AGE then return 2 end
    return 3
end


--- The lactation number of an animal that is lactating now (1, 2 or 3 for the third and later).
--- @param childCount number|nil Calves on its record
--- @return number
function RLMilkParity.getParity(childCount)
    return math.min(math.max(childCount or 0, 1), 3)
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
