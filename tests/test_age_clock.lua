-- U43-AGE-01: the continuous age runs on model time alone. A full model month adds exactly 1.0
-- month to an adult, a dealer-sourced and an in-game-born animal alike, at 1, 2 and 28 days per
-- month and across a change of the month length (at a month start and in mid-month); the birthday
-- (Animal:onDayChanged's whole months) never adds to it a second time and never holds it back;
-- a save, a same-hour move and a pool day keep to the same model time.

loadMod("tests/growthsim.lua")
loadMod("scripts/core/RLConstants.lua")
loadMod("scripts/utils/RLCalendar.lua")
loadAnimalSection("--- One day for this animal", "-- Reproduction delegates")
loadAnimalSection("function Animal:increaseAge", "function Animal:getAge")

local G = RLGrowth
local env = GrowthSim.env
env.currentPeriod, env.currentYear = 1, 1
AnimalReproduction = AnimalReproduction or {}
AnimalReproduction.processDaily = function() return 0, 0, 0, 0 end
AnimalHealth = AnimalHealth or {}
AnimalHealth.evaluateDaily = function() return 0, 0, 0, 0 end
Animal.setRecentlyBoughtByAI = function() end

local TOL = 1e-5

-- The game's order of an hour: the clock moves (a day change, with it a period change, fires the
-- day for every animal first), then the pen feeds and every animal takes its step.
local function hour(pen)
    for _, animal in ipairs(pen.animals) do GrowthSim.refreshRequest(animal) end
    GrowthSim.advanceHour()
    if env.currentHour == 0 then
        if env.currentDayInPeriod == 1 then env.currentPeriod = env.currentPeriod % 12 + 1 end
        local day, month, year = RLCalendar.getDate(env)
        for _, animal in ipairs(pen.animals) do
            animal:onDayChanged(nil, true, day, month, year, env.currentDayInPeriod, env.daysPerPeriod, false)
        end
    end
    GrowthSim.feed(pen, GrowthSim.RATIONS.TMR)
    for _, animal in ipairs(pen.animals) do G.step(animal, 1) end
end

local function hours(pen, n) for _ = 1, n do hour(pen) end end
local function modelMonth(pen) hours(pen, 24 * env.daysPerPeriod) end

local function withBirthday(animal, day)
    local month = RLCalendar.getMonthAndYear(env)
    animal.birthday = { day = day, month = month, year = 0, country = 1, lastAgeMonth = month }
    return animal
end

-- Three animals in one pen: an adult (an old save's, its clock taken over from its whole months),
-- a dealer-sourced heifer (generated on its curve, a birthday late in the month as Animal.new draws
-- them) and a calf born in the game on the first day of the month.
local function herd()
    GrowthSim.setDaysPerPeriod(1)
    env.currentPeriod = 1
    local adult = withBirthday(GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 20 }), 20)
    adult.rlGrowth.ageMonths = 20.0
    local dealer = withBirthday(GrowthSim.makeAnimal("COW_ANGUS", { age = 13 }), 28)
    local calf = withBirthday((GrowthSim.newborn("COW_ANGUS", { age = 0 })), 1)
    local pen = GrowthSim.makePen({ adult, dealer, calf })
    for _, animal in ipairs(pen.animals) do animal.clusterSystem = { owner = pen } end
    return pen, { adult = adult, dealer = dealer, calf = calf }
end

local function clocks(set)
    local out = {}
    for name, animal in pairs(set) do out[name] = G.getContinuousAge(animal) end
    return out
end

local function gains(before, after)
    local worst, text = 0, {}
    for _, name in ipairs({ "adult", "dealer", "calf" }) do
        local d = after[name] - before[name]
        worst = math.max(worst, math.abs(d - 1))
        text[#text + 1] = string.format("%s %+.6f", name, d)
    end
    return worst, table.concat(text, ", ")
end

-- 1 -> 2 -> 28 -> 1 days per month, each switched at a month start: every month +1.0 for all three.
do
    local pen, set = herd()
    local worst, lines = 0, {}
    for _, days in ipairs({ 1, 2, 28, 1 }) do
        GrowthSim.setDaysPerPeriod(days)
        for _ = 1, 2 do
            local before = clocks(set)
            modelMonth(pen)
            local w, text = gains(before, clocks(set))
            worst = math.max(worst, w)
            lines[#lines + 1] = days .. "d: " .. text
        end
    end
    check("U43 1->2->28->1 days per month: a full model month adds 1.0 to the adult, the dealer heifer and the calf "
        .. string.format("(worst %.2e) %s", worst, table.concat(lines, "; ")), worst <= TOL)
    -- The whole months stay the calendar's: a birthday late in the month is not reached in the month
    -- that the switch 28 -> 1 day starts on its first day (the old rule, display only), so the adult
    -- and the heifer have 7; the calf (born on the 1st) 8. Their continuous ages above are not touched.
    check(string.format("U43 the whole months still follow the birthday (adult %d, calf %d, dealer %d)", set.adult.age, set.calf.age, set.dealer.age),
        set.adult.age == 27 and set.calf.age == 8 and set.dealer.age == 20)
end

-- The joint test's case (batch G): a month of two days, the adult's birthday on the second game day.
-- The old clamp held its clock at age + 0.999 until that birthday and lost half a month (+0.52).
do
    local pen, set = herd()
    modelMonth(pen)
    GrowthSim.setDaysPerPeriod(2)
    local before = clocks(set)
    modelMonth(pen)
    local after = clocks(set)
    check(string.format("U43 2-day month after 1-day months: adult %+.4f, dealer %+.4f, calf %+.4f (batch G saw +0.52 / +0.98)",
        after.adult - before.adult, after.dealer - before.dealer, after.calf - before.calf),
        math.abs(after.adult - before.adult - 1) <= TOL and math.abs(after.dealer - before.dealer - 1) <= TOL
        and math.abs(after.calf - before.calf - 1) <= TOL)
end

-- A change of the month length in mid-month: each hour takes the length it ran under, nothing
-- before it is recomputed, and a birthday on the way adds nothing.
do
    local pen, set = herd()
    GrowthSim.setDaysPerPeriod(2)
    local before = clocks(set)
    hours(pen, 24)                       -- day 1 of a 2-day month: 0.5 months
    GrowthSim.env.daysPerPeriod, GrowthSim.env.timeAdjustment = 28, 1 / 28    -- switched on the spot, day 2 of 28
    hours(pen, 24 * 14)                  -- 14 days of a 28-day month: 0.5 months
    local after = clocks(set)
    local ok, text = true, {}
    for _, name in ipairs({ "adult", "dealer", "calf" }) do
        local d = after[name] - before[name]
        ok = ok and math.abs(d - 1) <= TOL
        text[#text + 1] = string.format("%s %+.6f", name, d)
    end
    check("U43 a mid-month switch 2 -> 28 days: half a month under each length adds 1.0, " .. table.concat(text, ", "), ok)
end

-- The birthday itself (the whole months) adds nothing, and does not pull the clock up or down.
do
    local pen, set = herd()
    GrowthSim.setDaysPerPeriod(28)
    hours(pen, 24 * 3)
    local animal = set.dealer
    local before, ageBefore = G.getContinuousAge(animal), animal.age
    animal:onDayChanged(nil, true, 28, RLCalendar.getMonthAndYear(env) % 12 + 1, 1, 28, 28, false)
    check(string.format("U43 a birthday moves the whole months (%d -> %d), the continuous age stays %.6f -> %.6f",
        ageBefore, animal.age, before, G.getContinuousAge(animal)),
        animal.age == ageBefore + 1 and G.getContinuousAge(animal) == before)
end

-- A save in mid-month: the clock goes through the save as a 32-bit float and runs on.
do
    local pen, set = herd()
    GrowthSim.setDaysPerPeriod(2)
    hours(pen, 30)
    local saved = {}
    for name, animal in pairs(set) do
        local f = string.unpack("f", string.pack("f", animal.rlGrowth.ageMonths))
        saved[name] = animal.rlGrowth.ageMonths
        animal.rlGrowth.ageMonths = f
    end
    hours(pen, 48)
    local ok, worst = true, 0
    for name, animal in pairs(set) do
        local d = G.getContinuousAge(animal) - saved[name]
        worst = math.max(worst, math.abs(d - 1))
    end
    check(string.format("U43 reload in mid-month (float32): the next model month adds 1.0 (worst %.2e)", worst), worst <= TOL)
end

-- A move in the same hour: the new pen does not step it again, its clock moves once.
do
    local pen, set = herd()
    GrowthSim.setDaysPerPeriod(2)
    hours(pen, 5)
    local calf = set.calf
    local before = G.getContinuousAge(calf)
    local other = GrowthSim.makePen({ calf })
    calf.clusterSystem = { owner = other }
    GrowthSim.feed(other, GrowthSim.RATIONS.TMR)
    G.step(calf, 1)
    check("U43 a same-hour move: the second pen's step in that hour adds no age", G.getContinuousAge(calf) == before)
    calf.clusterSystem = { owner = pen }
    local start = G.getContinuousAge(calf)
    modelMonth(pen)
    check("U43 after the move the next model month adds 1.0", math.abs(G.getContinuousAge(calf) - start - 1) <= TOL)
end

-- A sale pool animal is never stepped: each day it takes the day's model months, its birthday nothing more.
do
    GrowthSim.setDaysPerPeriod(2)
    env.currentPeriod = 1
    local pooled = withBirthday(GrowthSim.makeAnimal("COW_ANGUS", { age = 10 }), 16)
    local start = G.getContinuousAge(pooled)
    for _ = 1, 4 do
        GrowthSim.env.currentDayInPeriod = GrowthSim.env.currentDayInPeriod % 2 + 1
        if GrowthSim.env.currentDayInPeriod == 1 then env.currentPeriod = env.currentPeriod % 12 + 1 end
        local day, month, year = RLCalendar.getDate(env)
        pooled:onDayChanged(nil, true, day, month, year, env.currentDayInPeriod, 2, true)
    end
    check(string.format("U43 a pool animal: four days of a 2-day month add 2.0 (%.6f); its birthday (the 16th) came once (%d)",
        G.getContinuousAge(pooled) - start, pooled.age), math.abs(G.getContinuousAge(pooled) - start - 2) <= 1e-9 and pooled.age == 11)
end

-- A clock left far behind (not stepped while the model was off) starts again at the whole months;
-- one within a month of them is not touched.
do
    local cow = GrowthSim.makeAnimal("COW_ANGUS", { age = 30 })
    cow.rlGrowth.ageMonths = 18.25
    check("U43 a stale clock (12 months behind) reads the whole months", G.getContinuousAge(cow) == 30)
    G.advanceClock(cow.rlGrowth, cow.age, 0.5)
    check("U43 ... and runs on from them", cow.rlGrowth.ageMonths == 30.5)
    cow.rlGrowth.ageMonths = 29.4
    check("U43 a clock a little behind its whole months (a birthday early in the month) is its own", G.getContinuousAge(cow) == 29.4)
    cow.rlGrowth.ageMonths = 31.6
    check("U43 a clock a little ahead (a birthday late in the month) is its own", G.getContinuousAge(cow) == 31.6)
end

-- Steps whose length is not exact in binary land on the whole month, not just under it: 120 steps of
-- 0.25 days (RLFeed) or 48 hours of a 2-day month end at 1.0, so a floor (the dam's milk month) reads
-- the new month at once (sheep calibration MILK gates).
do
    local cow = GrowthSim.makeAnimal("COW_ANGUS", { age = 0 })
    cow.rlGrowth.ageMonths = 0
    for _ = 1, 120 do G.advanceClock(cow.rlGrowth, 0, 0.25 / 30) end
    local a = cow.rlGrowth.ageMonths
    cow.rlGrowth.ageMonths = 0
    for h = 1, 48 * 3 do G.advanceClock(cow.rlGrowth, math.floor((h - 1) / 48), 1 / 48) end
    check(string.format("U43 120 steps of 0.25 days end on 1.0 (%.17g), 144 hours of a 2-day month on 3.0 (%.17g)", a, cow.rlGrowth.ageMonths),
        a == 1 and math.floor(a) == 1 and cow.rlGrowth.ageMonths == 3)
end
