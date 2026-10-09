--[[
    RLWeightMath.lua
    Pure weight arithmetic shared by the old weight rule (Animal:updateWeight), the growth line
    (RLBreedTraits.getGrownLine) and the body condition budget (RLBodyCondition). No engine
    globals, no randomness.

    Time. A weight change is a rate per period (one in-game month) integrated over the months a
    step covers, so the same month gives the same weight whatever the days per period. One game
    hour is 1 / (24 x daysPerPeriod) months.

    The old rule's two losses - an animal above its target weight returning to it, and a starving
    animal losing weight - were written per game hour, so a month of 7 days lost seven times what a
    month of 1 day did (a 500 kg animal starving for one month: 413.6 kg at 1 day, 0.001 kg at 7).
    They are now integrated exactly over the step, at the hourly rates they had at
    REFERENCE_DAYS_PER_PERIOD (the game's default, 1 day): at 1 day per period every hour is the
    same as before, and any other period length gives the same month. The one exception is the
    step in which a growing animal crosses its target: it adds its growth without the return (as
    the old hour did), so with shorter steps the return starts a fraction of an hour sooner - a
    one-off difference of a few grams (tests/test_weight.lua).

    Age. Structural growth never turns into a loss with age: the growth line's age factor
    1 + (matureAge - age) / 75 runs down to 0 at matureAge + 75 months and stays there. A healthy,
    fed old animal keeps its weight.
]]

RLWeightMath = {}

--- Days per period the old hourly rates were set for. At this period length the old rule's
--- weight is unchanged hour by hour.
RLWeightMath.REFERENCE_DAYS_PER_PERIOD = 1

--- Months over which the age factor of the growth line falls by 1.
RLWeightMath.AGE_FACTOR_MONTHS = 75

--- Hours (at the reference period length) in which an animal above its target loses 1 / (this x
--- metabolism) of the excess, and a starving one 1 / (this x (2 - metabolism)) of its gap.
RLWeightMath.EXCESS_HOURS = 25
RLWeightMath.STARVATION_HOURS = 150

--- Lowest weight the old rule leaves an animal at.
RLWeightMath.MIN_WEIGHT = 0.001


--- Months one game hour covers at a period length.
--- @param daysPerPeriod number|nil
--- @return number
function RLWeightMath.getHourMonths(daysPerPeriod)
    return 1 / (24 * math.max(daysPerPeriod or 1, 1))
end


--- Age factor of the growth line: 1 + (matureAge - age) / 75, never below 0.
--- @param age number Months
--- @param matureAge number Months
--- @return number
function RLWeightMath.getAgeGrowthFactor(age, matureAge)
    return math.max(1 + (matureAge - age) / RLWeightMath.AGE_FACTOR_MONTHS, 0)
end


--- One step of the old weight rule: growth for the step and the old rule's two losses - an animal
--- above its target returns to it, a starving animal loses weight (above its target faster still;
--- below it, by its gap to the target, as before) - never below MIN_WEIGHT.
---
--- Exact over the step at the reference hourly rates, and the same for the step taken whole or in
--- parts: above the target the excess E follows the old hourly recurrence E -> E x (1 - r) + g
--- (g the growth per reference hour), whose value after n hours is E* + (E - E*) x (1 - r)^n with
--- E* = g / r, for any n. Below the target growth adds as before, also in the step that takes the
--- animal over it. At 1 day per period n is 1 and every step is the old one.
--- @param weight number kg
--- @param targetWeight number kg
--- @param gainKg number Growth this step (>= 0)
--- @param metabolism number Metabolism gene
--- @param starving boolean The pen's food factor is 0
--- @param dtMonths number Months the step covers
--- @return number weight kg
function RLWeightMath.stepLegacy(weight, targetWeight, gainKg, metabolism, starving, dtMonths)
    local hours = dtMonths * 24 * RLWeightMath.REFERENCE_DAYS_PER_PERIOD
    local gain = math.max(gainKg, 0)
    local starvationRate = 1 / (math.max(2 - metabolism, 0.01) * RLWeightMath.STARVATION_HOURS)

    if weight > targetWeight and hours > 0 then
        local rate = 1 / (math.max(metabolism, 0.01) * RLWeightMath.EXCESS_HOURS)
        if starving then rate = rate + starvationRate end
        rate = math.min(rate, 1)
        local settled = gain / hours / rate
        local excess = settled + (weight - targetWeight - settled) * (1 - rate) ^ hours
        return math.max(targetWeight + excess, RLWeightMath.MIN_WEIGHT)
    end

    local decrease = 0
    if starving and weight < targetWeight then
        decrease = (targetWeight - weight) * ((1 + starvationRate) ^ hours - 1)
    end

    return math.max(weight + gain - decrease, RLWeightMath.MIN_WEIGHT)
end
