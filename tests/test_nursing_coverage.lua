-- Unified nursing, batch C (2026-10-22 design): beef cows (and the same contract for ewes and sows) pay
-- their young's own demand in their budget; their young share one paid ratio, each its own amount. No milk
-- gene, curve or table caps it, no whole-pen fallback, no free milk from another dam. Matrix cases N01, N03,
-- N04, N05, N06, G01 and C03 for beef cattle (sheep and pigs: test_sheep_s5_nursing, test_pig_fallback).

loadMod("tests/feedsim.lua")

local config = RLFeed.getConfig()
local function near(a, b, eps) return a ~= nil and b ~= nil and math.abs(a - b) <= (eps or 1e-9) end
FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(1)

local function identify(animal, id)
    animal.id = id
    animal.getIdentifiers = function(self) return self.id end
    return animal
end
local function dam(id, fields)
    local f = { age = 48, isParent = true, isLactating = true, monthsSinceLastBirth = 1 }
    for k, v in pairs(fields or {}) do f[k] = v end
    return identify((GrowthSim.makeAnimal("COW_ANGUS", f)), id)
end
local function calf(motherId, id, age, weight, name)
    local c = identify((GrowthSim.makeAnimal(name or "BULL_ANGUS", { age = math.floor(age), motherId = motherId })), id)
    if c.rlGrowth ~= nil then c.rlGrowth.ageMonths = age end
    if weight ~= nil then c.weight = weight; RLGrowth.resync(c, RLGrowth.ensureState(c)) end
    return c
end
local function describe(pen)
    local d, by = RLFeed.describePen(pen, RLFeed.getRation(pen), config.stepDays), {}
    for _, a in ipairs(d) do by[a.animal] = a end
    return d, by
end
local function steps(pen, hours, refill)
    local out = {}
    local function observe(kind, data) if kind == "STEP" then out[#out + 1] = data end end
    RLFeed.addObserver(observe)
    for _ = 1, hours do
        if refill ~= nil then refill(pen) end
        FeedSim.hour(pen)
    end
    RLFeed.removeObserver(observe)
    return out
end
local STOCK = { FORAGE = 1e5 }
local refill = FeedSim.keepStocked(STOCK)


-- N01: two calves of one dam, different weights at the same age -------------------------------------

do
    local cow = dam("N1")
    local light, heavy = calf("N1", "N1a", 2, 70), calf("N1", "N1b", 2, 95)
    local pen = FeedSim.makePen({ cow, light, heavy }, STOCK)
    FeedSim.hour(pen)
    local _, by = describe(pen)
    check(string.format("N01 demand: the heavier calf of the same age needs more (%.3f > %.3f kg DM a day)",
        by[heavy].nursingMaxKgPerDay, by[light].nursingMaxKgPerDay), by[heavy].nursingMaxKgPerDay > by[light].nursingMaxKgPerDay)
    check("N01 dam: her milk is exactly her two calves' demands (real kg)",
        near(by[cow].milkKgPerDay, (by[light].nursingMaxKgPerDay + by[heavy].nursingMaxKgPerDay) / config.damMilk.dm, 1e-9))

    -- Short of feed (20 L of TMR an hour for the three): both get the same share of their own demand.
    local s = steps(pen, 12, function(p) p.spec_husbandryFood.fillLevels[FeedSim.FILL.FORAGE] = 20 end)
    local worst, sample = 0, nil
    for _, data in ipairs(s) do
        local got = {}
        for _, e in ipairs(data.animals) do
            if e.feed.damMilk ~= nil and (e.feed.nursingDemandKg or 0) > 0 then got[#got + 1] = e.feed.damMilk.kg / e.feed.nursingDemandKg end
        end
        if #got == 2 then worst = math.max(worst, math.abs(got[1] - got[2])); sample = got[1] end
    end
    check(string.format("N01 share: the two calves always got the same share of their own demand (worst gap %.2e, last %.3f)", worst, sample or -1),
        sample ~= nil and sample > 0.05 and sample < 0.98 and worst < 1e-9)

    -- Array order: the same pen described in the other order gives each the same demand and pool share.
    local cow2 = dam("N2")
    local a2, b2 = calf("N2", "N2a", 2, 70), calf("N2", "N2b", 2, 95)
    local penA = FeedSim.makePen({ cow2, a2, b2 }, STOCK)
    local cow3 = dam("N3")
    local a3, b3 = calf("N3", "N3a", 2, 70), calf("N3", "N3b", 2, 95)
    local penB = FeedSim.makePen({ b3, a3, cow3 }, STOCK)
    for _ = 1, 3 do FeedSim.hour(penA); FeedSim.hour(penB) end
    check(string.format("N01 order: the litter listed the other way round settles the same (%.6f / %.6f kg)", a2.weight, a3.weight),
        near(a2.weight, a3.weight, 1e-9) and near(b2.weight, b3.weight, 1e-9) and near(cow2.weight, cow3.weight, 1e-9))
end


-- N02 / N03: fed well, no cap; twins cost her their demand, never free milk -----------------------

do
    local cowS, cowT = dam("S1"), dam("T1")
    local single = calf("S1", "S1a", 1, 60)
    local t1, t2 = calf("T1", "T1a", 1, 60), calf("T1", "T1b", 1, 60)
    local penS = FeedSim.makePen({ cowS, single }, STOCK)
    local penT = FeedSim.makePen({ cowT, t1, t2 }, STOCK)
    FeedSim.hour(penS); FeedSim.hour(penT)
    local _, byS = describe(penS)
    local _, byT = describe(penT)
    check(string.format("N03 twins: her milk need doubles with two calves of one demand (%.2f vs %.2f MJ a day)", byT[cowT].needs.milk, byS[cowS].needs.milk),
        near(byT[cowT].needs.milk, 2 * byS[cowS].needs.milk, 1e-6) and byT[cowT].appetite > byS[cowS].appetite)
    steps(penS, 24, refill); steps(penT, 24, refill)
    check(string.format("N02 fed: a well-fed beef cow pays all her calf's demand (%.3f), the calf receives all of it (%.3f), nothing collected",
        cowS.rlNutrition.nursingCoverage or -1, single.rlNutrition.nursingCoverage or -1),
        (cowS.rlNutrition.nursingCoverage or 0) > 0.98 and near(cowS.rlNutrition.nursingCoverage, single.rlNutrition.nursingCoverage, 1e-6)
        and cowS.rlFeedIntake.milkLiters == 0 and cowS.rlMilkPaid.litersPerHour == 0)
    check("N02 fed: twins of a well-fed cow also get their whole demand",
        (t1.rlNutrition.nursingCoverage or 0) > 0.98 and near(t1.rlNutrition.nursingCoverage, t2.rlNutrition.nursingCoverage, 1e-9))
end


-- N04: a dam short of feed pays less; fed again, the ratio comes back (no stuck share) --------------

do
    local cow = dam("H1")
    local c = calf("H1", "H1a", 1.5)
    local pen = FeedSim.makePen({ cow, c }, STOCK)
    steps(pen, 6, refill)
    steps(pen, 12, function(p) p.spec_husbandryFood.fillLevels[FeedSim.FILL.FORAGE] = 10 end)
    local short = cow.rlNutrition.nursingCoverage
    local calfShort = c.rlNutrition.nursingCoverage
    steps(pen, 6, refill)
    local back = cow.rlNutrition.nursingCoverage
    check(string.format("N04 short: underfed (10 L an hour) she pays %.0f%% of her calf's demand, the calf gets the same share (%.0f%%)", 100 * (short or -1),
        100 * (calfShort or -1)), short ~= nil and short > 0.2 and short < 0.95 and near(short, calfShort, 2e-3))
    check(string.format("N04 recovery: fed again she pays %.0f%% within hours (never stuck at the old share)", 100 * (back or -1)),
        back ~= nil and back > 0.95)
end


-- N05: no calf, a weaned calf, a sold calf: no nursing cost -------------------------------------------

do
    local cow = dam("W1")
    local pen = FeedSim.makePen({ cow }, STOCK)
    steps(pen, 3, refill)
    check("N05 no calf: a beef cow that calved but has no calf here is DRY: no milk paid, no nursing record",
        cow.rlFeedIntake.class == "DRY" and cow.rlFeedIntake.milkPaidLiters == 0 and cow.rlNutrition.nursingCoverage == nil)

    local cow2 = dam("W2")
    local c2 = calf("W2", "W2a", 2)
    local pen2 = FeedSim.makePen({ cow2, c2 }, STOCK)
    steps(pen2, 3, refill)
    local paidBefore = cow2.rlFeedIntake.milkPaidLiters
    pen2.animals = { cow2 }
    steps(pen2, 3, refill)
    check(string.format("N05 sold: her calf gone, the next hours cost her nothing (paid %.3f before, %.3f after)", paidBefore,
        cow2.rlFeedIntake.milkPaidLiters), paidBefore > 0 and cow2.rlFeedIntake.milkPaidLiters == 0 and cow2.rlFeedIntake.class == "DRY")

    local cow3 = dam("W3")
    local c3 = calf("W3", "W3a", 7.2)
    local pen3 = FeedSim.makePen({ cow3, c3 }, STOCK)
    steps(pen3, 3, refill)
    check("N05 weaned: a calf past its breed's suckling months drinks nothing and costs her nothing",
        c3.rlFeedIntake.damMilkKg == 0 and cow3.rlFeedIntake.milkPaidLiters == 0)
end


-- N06: another cow's calf, a calf apart from its dam ---------------------------------------------------

do
    local cow = dam("F1")
    local own, stranger = calf("F1", "F1a", 1), calf("F9", "F9a", 1)
    local pen = FeedSim.makePen({ cow, own, stranger }, STOCK)
    steps(pen, 6, refill)
    check("N06 no fostering: a calf whose dam is not here drinks none of another cow's milk; the pen keeps the mode",
        pen.spec_husbandryFood.rlFeedPen.active and stranger.rlFeedIntake.damMilkKg == 0 and own.rlFeedIntake.damMilkKg > 0)
end


-- G01: an old milk value on a beef dam changes nothing ---------------------------------------------------

do
    local function raise(p)
        local cow = dam("G" .. p)
        cow.genetics.productivity = p -- an old save's value, never read for a beef cow
        local c = calf("G" .. p, "G" .. p .. "c", 1)
        local pen = FeedSim.makePen({ cow, c }, STOCK)
        steps(pen, 48, refill)
        return cow, c
    end
    local lowCow, lowCalf = raise(0.25)
    local highCow, highCalf = raise(1.75)
    check(string.format("G01: beef dams with an old milk value of 0.25 and 1.75 raise the same calf (%.6f / %.6f kg) and pay the same",
        lowCalf.weight, highCalf.weight), near(lowCalf.weight, highCalf.weight, 1e-9) and near(lowCow.weight, highCow.weight, 1e-9)
        and near(lowCow.rlFeedIntake.milkPaidLiters, highCow.rlFeedIntake.milkPaidLiters, 1e-12))
end


-- C03: the same model time at 1, 3, 7 and 28 days a month ---------------------------------------------------

do
    local results = {}
    for _, days in ipairs({ 1, 3, 7, 28 }) do
        GrowthSim.setDaysPerPeriod(days)
        local cow = dam("M" .. days)
        local c = calf("M" .. days, "M" .. days .. "c", 1)
        local pen = FeedSim.makePen({ cow, c }, STOCK)
        -- Half a model month, whatever the month length.
        for _ = 1, 12 * days do refill(pen); FeedSim.hour(pen) end
        results[#results + 1] = { days = days, calf = c.weight, cow = cow.weight }
    end
    GrowthSim.setDaysPerPeriod(1)
    local worstCalf, worstCow = 0, 0
    for _, r in ipairs(results) do
        worstCalf = math.max(worstCalf, math.abs(r.calf - results[1].calf))
        worstCow = math.max(worstCow, math.abs(r.cow - results[1].cow))
    end
    check(string.format("C03: half a model month at 1/3/7/28 days a month: calf within %.4f kg, cow within %.4f kg", worstCalf, worstCow),
        worstCalf < 0.05 and worstCow < 0.25)
end

