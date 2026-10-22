-- Sows and litters (unified nursing design N07, 2026-10-22; replaces the PIG-PIGLET-LEGACY-GROWTH-01 bridge): a
-- breeding pen runs the real-equivalent mode. A sow pays her piglets' own demand (RLYoungDemandMath) in her budget,
-- each piglet drinks its demand x her paid share with its ME and SID lysine, takes creep feed by age, and is weaned
-- at 28 days in the same model - no algorithm switch, no jump. The old fixed gain (19 kg at 29 days, 80-110 kg at
-- 2.7 months) never returns. After weaning a pig grows on its weaner diet (its lysine and intake limits).

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

-- Hours with the trough kept stocked; each young pig's whole months move on from its own birth hour (the
-- game ages it on its birthday), the adults' are left alone.
local function run(p, hours, stock)
    local refill = stock ~= nil and FeedSim.keepStocked(stock) or nil
    for _ = 1, hours do
        if refill ~= nil then refill(p) end
        FeedSim.hour(p)
        for _, animal in ipairs(p.animals) do
            if born[animal] ~= nil then
                born[animal] = born[animal] + 1
                animal.age = math.floor(born[animal] / (24 * GrowthSim.env.daysPerPeriod))
            end
        end
    end
end

-- Landrace, 26 days with the sow ----------------------------------------------------------------------

local pen, sow, young = breedingPen("LANDRACE", 12)
local active, reason = RLFeed.evaluatePen(pen)
check("gate: the sow's pen runs the mode (no PIG_BREEDING_LEGACY)", active == true and reason == "OK")
run(pen, hoursFor(26), STOCK)
local female, male = young[1], young[2]
local gapF, expectF = curveGap(female)
local gapM = curveGap(male)
check(string.format("Landrace 26 days on sow milk: gilt %.2f kg (curve %.2f), boar %.2f kg - on the P4 curve within 3%%", female.weight, expectF, male.weight),
    math.abs(gapF) < 0.03 and math.abs(gapM) < 0.03 and female.weight > 6.8 and female.weight < 8.3 and male.weight > female.weight)
local r = female.rlFeedIntake
check(string.format("milk: the piglets drink their sow's milk (%.3f kg DM a day, its SID lysine counted), she pays %.1f%% of their demand",
    r.damMilkKg / r.dtDays, 100 * (sow.rlNutrition.nursingCoverage or 0)),
    r.damMilkKg > 0 and r.class == "CALF" and sow.rlNutrition.nursingCoverage ~= nil and sow.rlNutrition.nursingCoverage > 0.95
    and math.abs(RLGrowth.getContinuousAge(female) - hoursFor(26) / 24) < 1e-6 and female.rlFeedFallback == nil)
check("sow: an adult sow stays near her own curve while nursing twelve", math.abs(curveGap(sow)) < 0.05)

-- Weaning at 28 days in the same pen and model: no jump.
do
    local maxJump, last = 0, female.weight
    for _ = 1, hoursFor(6) do
        run(pen, 1, STOCK)
        maxJump = math.max(maxJump, math.abs(female.weight - last))
        last = female.weight
    end
    check(string.format("weaning: at 28 days the piglet is weaned in the same model, no jump (largest hourly change %.3f kg), no milk after",
        maxJump), maxJump < 0.5 and female.rlFeedIntake.damMilkKg == 0 and RLFeed.getRationClass(female) == "GROWING")
end

-- Left with the sow to 2.7 months: on the weaner diet, never the old 80-110 kg.
do
    local pen2, _, young2 = breedingPen("LANDRACE", 10)
    run(pen2, hoursFor(2.7 * 30), STOCK)
    local gap, expected = curveGap(young2[1])
    check(string.format("2.7 months: %.1f kg (curve %.1f, the weaner diet sets the rest), not the old 80-110 kg", young2[1].weight, expected),
        young2[1].weight < 45 and gap > -0.4)
end

-- Other breeds' P4 anchors, on sow milk.
do
    local penB, _, youngB = breedingPen("BERKSHIRE", 8)
    run(penB, hoursFor(22.9), STOCK)
    local penP, _, youngP = breedingPen("BLACK_PIED", 8)
    run(penP, hoursFor(26), STOCK)
    check(string.format("Berkshire 22.9 days %.2f / %.2f kg, Black Pied 26 days %.2f / %.2f kg: on their curves within 4%%",
        youngB[1].weight, youngB[2].weight, youngP[1].weight, youngP[2].weight),
        math.abs(curveGap(youngB[1])) < 0.04 and math.abs(curveGap(youngB[2])) < 0.04
        and math.abs(curveGap(youngP[1])) < 0.04 and math.abs(curveGap(youngP[2])) < 0.04)
end

-- An old overweight piglet keeps its weight: nothing is cut, it grows on from where it is.
do
    local penO, _, youngO = breedingPen("LANDRACE", 2)
    run(penO, hoursFor(20), STOCK)
    local heavy = youngO[1]
    heavy.weight = 19
    run(penO, 1, STOCK)
    check(string.format("migration: a 19 kg piglet (old rule) is not cut: %.2f kg an hour later", heavy.weight),
        heavy.weight >= 19 and heavy.weight < 19.6)
end

-- A sow with nothing to eat: she pays what her reserve allows, her litter shares it and falls behind.
do
    local sowS = PigSim.grown("PIG_LANDRACE", 1, 18, { isParent = true })
    local youngS = litter(1, 4, "LANDRACE", 300)
    local penS = PigSim.makePen({ sowS, youngS[1], youngS[2], youngS[3], youngS[4] }, {})
    run(penS, hoursFor(20), nil)
    local q = sowS.rlNutrition ~= nil and sowS.rlNutrition.nursingCoverage or nil
    local q1, q2 = youngS[1].rlNutrition.nursingCoverage, youngS[2].rlNutrition.nursingCoverage
    check(string.format("short: an unfed sow pays %.0f%% of her litter's demand, each piglet gets that share (%.3f / %.3f), they fall behind (%.0f%%)",
        100 * (q or -1), q1 or -1, q2 or -1, 100 * curveGap(youngS[1])),
        q ~= nil and q < 0.95 and math.abs(q1 - q) < 1e-6 and math.abs(q2 - q) < 1e-6 and curveGap(youngS[1]) < -0.03)
end

-- Sheep and cattle never take the old pig bridge.
do
    local ewe = GrowthSim.makeAnimal("SHEEP_LANDRACE", { age = 24 })
    local cow = GrowthSim.makeAnimal("COW_ANGUS", { age = 24 })
    check("scope: sheep and cattle are not stepped by the pig fallback", RLFeed.stepFallback(ewe, 1) == false and RLFeed.stepFallback(cow, 1) == false)
end

PigSim.enable(false)
FeedSim.setMode(false)
