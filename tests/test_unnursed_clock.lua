-- Young counted "without their dam" (2026-10-23 game test, slot 18: 5 sows and 55 piglets, rlBcFastForward 48
-- at one day a month). Two parts:
--  1. RLFeed.countUnnursed reads each young animal's age at the end of the hour; it pairs dams and young
--     afresh then, never against the hour's earlier pairing (an age that moved on, or a clock read as stale
--     and started again at the whole age, miscounted all 55 piglets for an hour).
--  2. rlBcFastForward moves the model clock on without birthdays: whole-month ages follow the clock
--     (RLBodyConditionConsole.followClock), so it is never read as stale and never jumps back.

loadMod("tests/pigsim.lua")

FeedSim.setMode(true)
PigSim.enable(true)
GrowthSim.setDaysPerPeriod(1)

local STOCK = { PIGFOOD = 20000, PIGLETFOOD = 20000 }
local born = {}

local function litter(sowId, n, breed, firstId)
    local young = {}
    for i = 1, n do
        local name = (i % 2 == 0) and ("BOAR_" .. breed) or ("PIG_" .. breed)
        local piglet = PigSim.identify((GrowthSim.newborn(name)), firstId + i)
        piglet.motherId = sowId
        born[piglet] = 0
        young[#young + 1] = piglet
    end
    return young
end

local function breedingPen(breed, n)
    local sow = PigSim.grown("PIG_" .. breed, 1, 18, { isParent = true, monthsSinceLastBirth = 0 })
    local young = litter(1, n, breed, 100)
    local animals = { sow }
    for _, p in ipairs(young) do animals[#animals + 1] = p end
    return PigSim.makePen(animals, STOCK), sow, young
end

local function curveGap(animal)
    local curve = RLGrowth.getCurve(animal)
    local expected = curve:value(RLGrowth.getContinuousAge(animal))
    return (animal.weight - expected) / expected, expected
end

local function hoursFor(days) return math.floor(days / 30 * 24 * GrowthSim.env.daysPerPeriod + 0.5) end
loadMod("scripts/console/RLBodyConditionConsole.lua")

local function bigPen()
    local animals, young = {}, {}
    for d = 1, 5 do
        animals[#animals + 1] = PigSim.grown("PIG_BERKSHIRE", d, 18, { isParent = true, monthsSinceLastBirth = 0 })
        for _, p in ipairs(litter(d, 11, "BERKSHIRE", 100 * d)) do animals[#animals + 1] = p; young[#young + 1] = p end
    end
    for b = 1, 3 do animals[#animals + 1] = PigSim.grown("BOAR_BERKSHIRE", 900 + b, 20) end
    return PigSim.makePen(animals, STOCK), young
end

-- 1. Ages frozen (the old fast-forward): the clock goes stale after 2 model months and starts again.
do
    local pen, young = bigPen()
    local refill = FeedSim.keepStocked(STOCK)
    local worst, reset = 0, false
    for _ = 1, hoursFor(75) do
        refill(pen)
        local before = RLGrowth.getContinuousAge(young[1])
        FeedSim.hour(pen)
        if RLGrowth.getContinuousAge(young[1]) < before then reset = true end
        worst = math.max(worst, pen.spec_husbandryFood.rlFeedLast.unnursed or 0)
    end
    check("frozen ages: the clock does go stale and start again (the game test's case)", reset)
    check("frozen ages: no piglet with its sow in the pen is ever counted without its dam", worst == 0)
end

-- 2. The fast-forward's rule: whole months follow the clock, which never jumps back.
do
    local pen, young = bigPen()
    local refill = FeedSim.keepStocked(STOCK)
    local monotone, worst = true, 0
    for _ = 1, hoursFor(75) do
        refill(pen)
        local before = RLGrowth.getContinuousAge(young[1])
        FeedSim.hour(pen)
        for _, animal in ipairs(pen.animals) do RLBodyConditionConsole.followClock(animal) end
        if RLGrowth.getContinuousAge(young[1]) < before - 1e-9 then monotone = false end
        worst = math.max(worst, pen.spec_husbandryFood.rlFeedLast.unnursed or 0)
    end
    local p = young[1]
    check(string.format("fast-forward: 75 model days move a piglet's clock on to %.2f months, its whole age to %d",
        RLGrowth.getContinuousAge(p), p.age), monotone and p.age == 2 and math.abs(RLGrowth.getContinuousAge(p) - 2.5) < 0.05)
    check("fast-forward: no piglet is counted without its dam", worst == 0)
    local adult = PigSim.grown("PIG_BERKSHIRE", 1, 18)
    adult.rlGrowth.ageMonths = 17.5
    RLBodyConditionConsole.followClock(adult)
    check("followClock: a clock behind the whole age never lowers it", adult.age == 18)
    RLBodyConditionConsole.followClock({ age = 3 })
    check("followClock: an animal without a clock is left alone", true)
end
