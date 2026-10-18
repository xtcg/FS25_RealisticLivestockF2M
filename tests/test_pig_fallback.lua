-- PIG-PIGLET-LEGACY-GROWTH-01 (2026-10-18): a breeding pen (a sow and her litter) keeps the old feeding
-- rules (PIG_BREEDING_LEGACY), but its covered pigs' weight follows their own P4 curve on the weight
-- model's budget at the pen's food factor (RLFeed.stepFallback), never the old fixed gain that put piglets
-- at about 19 kg at 29 days and 80-110 kg at 2.7 months. The 28-day takeover goes on from the weight the
-- piglet has. No sow milk budget yet (a later batch): this is a curve bridge, not a sow model.

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
check("gate: the sow's pen keeps the old feeding rules (PIG_BREEDING_LEGACY)", active == false and reason == "PIG_BREEDING_LEGACY")
run(pen, hoursFor(26), STOCK)
local female, male = young[1], young[2]
local gapF, expectF = curveGap(female)
local gapM = curveGap(male)
check(string.format("Landrace 26 days: gilt %.2f kg (curve %.2f), boar %.2f kg - on the P4 curve within 3%%", female.weight, expectF, male.weight),
    math.abs(gapF) < 0.03 and math.abs(gapM) < 0.03 and female.weight > 6.8 and female.weight < 8.3 and male.weight > female.weight)
check("budget: the piglets were stepped by the budget (fallback record), their age clock moved once an hour",
    female.rlFeedFallback ~= nil and female.rlFeedFallback.share == 1 and math.abs(RLGrowth.getContinuousAge(female) - hoursFor(26) / 24) < 1e-6)
check("sow: an adult sow stays near her own curve, no old-rule jump", math.abs(curveGap(sow)) < 0.05)

-- The defect, reproduced with the old weight rule in the same pen.
do
    local saved = RLFeed.stepFallback
    RLFeed.stepFallback = function() return false end
    local oldPen, _, oldYoung = breedingPen("LANDRACE", 12)
    run(oldPen, hoursFor(29), STOCK)
    RLFeed.stepFallback = saved
    check(string.format("old rule (reproduced): a 29-day piglet on the old fixed gain reaches %.1f kg, far above its curve", oldYoung[1].weight),
        oldYoung[1].weight > 12)
end

-- 28-day takeover: the litter moves to a pen of its own and runs the mode, from the weight it has.
run(pen, hoursFor(29) - hoursFor(26), STOCK)
local before = {}
for i, p in ipairs(young) do before[i] = p.weight end
local weaned = PigSim.makePen(young, STOCK)
local okW, whyW = RLFeed.evaluatePen(weaned)
run(weaned, 1, STOCK)
local maxJump = 0
for i, p in ipairs(young) do maxJump = math.max(maxJump, math.abs(p.weight - before[i])) end
check("takeover: at 29 days the weaned litter's pen runs the mode (" .. tostring(whyW) .. ")", okW == true)
check(string.format("takeover: no jump at the switch (largest change in the first hour %.3f kg) and still on the curve (%.1f%%)", maxJump, 100 * curveGap(female)),
    maxJump < 0.5 and math.abs(curveGap(female)) < 0.05)

-- Left with the sow to 2.7 months: on its curve, not 80-110 kg.
do
    local pen2, _, young2 = breedingPen("LANDRACE", 10)
    run(pen2, hoursFor(2.7 * 30), STOCK)
    local gap, expected = curveGap(young2[1])
    check(string.format("2.7 months with the sow: %.1f kg (curve %.1f), not the old 80-110 kg", young2[1].weight, expected),
        math.abs(gap) < 0.05 and young2[1].weight < 45)
end

-- Other breeds' P4 anchors.
do
    local penB, _, youngB = breedingPen("BERKSHIRE", 8)
    run(penB, hoursFor(22.9), STOCK)
    local penP, _, youngP = breedingPen("BLACK_PIED", 8)
    run(penP, hoursFor(28), STOCK)
    check(string.format("Berkshire 22.9 days %.2f / %.2f kg (6.48 / 6.55), Black Pied 28 days %.2f / %.2f kg (7.0 / 7.2)",
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

-- Short of feed in the sow pen: the budget pays its share, growth falls behind the curve.
do
    local sowS = PigSim.grown("PIG_LANDRACE", 1, 18, { isParent = true })
    local youngS = litter(1, 4, "LANDRACE", 300)
    local penS = PigSim.makePen({ sowS, youngS[1], youngS[2], youngS[3], youngS[4] }, {})
    run(penS, hoursFor(20), nil)
    check("food factor: an empty trough gives no growth on the fallback (the piglet falls behind its curve)",
        youngS[1].rlFeedFallback ~= nil and youngS[1].rlFeedFallback.share == 0 and curveGap(youngS[1]) < -0.2)
end

-- Sheep and cattle never take this path.
do
    local ewe = GrowthSim.makeAnimal("SHEEP_LANDRACE", { age = 24 })
    local cow = GrowthSim.makeAnimal("COW_ANGUS", { age = 24 })
    check("scope: sheep and cattle are not stepped by the pig fallback", RLFeed.stepFallback(ewe, 1) == false and RLFeed.stepFallback(cow, 1) == false)
end

PigSim.enable(false)
FeedSim.setMode(false)
