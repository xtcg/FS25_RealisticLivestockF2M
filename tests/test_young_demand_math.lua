-- RLYoungDemandMath (batch B of the unified nursing design, 2026-10-22): a young animal's demand is
-- its own; a dam pays for all of hers and they share one ratio; a dairy dam's young drink first.

loadMod("scripts/nutrition/RLYoungDemandMath.lua")
local M = RLYoungDemandMath
local function near(a, b, eps) return a ~= nil and b ~= nil and math.abs(a - b) <= (eps or 1e-12) end

-- Demand -------------------------------------------------------------------------------------------

check("demand: the stage's milk share of maintenance + growth", near(M.getDemandME(8, 12, 0.75), 15))
check("demand: weaned (share 0) or nothing needed: none", M.getDemandME(8, 12, 0) == 0 and M.getDemandME(0, 0, 1) == 0)
check("demand: share above 1 or below 0 is clamped, negative needs count as none",
    near(M.getDemandME(8, 12, 1.5), 20) and M.getDemandME(8, 12, -1) == 0 and near(M.getDemandME(-3, 5, 1), 5))
do
    -- N01: same age (same share), different actual weights -> different needs -> different demands.
    local light = M.getDemandME(2.0 * 40 ^ 0.75 / 40 ^ 0.75 * 6, 8, 0.9)
    local heavy = M.getDemandME(2.0 * 60 ^ 0.75 / 40 ^ 0.75 * 6, 8, 0.9)
    check("demand: a heavier young of the same age needs more", heavy > light)
    check("demand: a newborn and a nearly weaned young of the same needs differ by their share",
        M.getDemandME(10, 10, 1) > M.getDemandME(10, 10, 0.2))
end

-- Milk units --------------------------------------------------------------------------------------

do
    local cattle = { dm = 0.125, me = 22.5, cp = 0.25 }
    local m = M.toMilk(22.5, cattle)
    check("milk: 22.5 MJ of cattle milk is 1 kg DM, 8 real kg, 0.25 kg CP, no lysine",
        near(m.kgDM, 1) and near(m.kgReal, 8) and near(m.cpKg, 0.25) and m.lysKg == 0 and m.me == 22.5)
    local sow = { dm = 0.19, me = 26, cp = 0.29, sidLys = 0.02 }
    local s = M.toMilk(13, sow)
    check("milk: sow milk carries its SID lysine", near(s.kgDM, 0.5) and near(s.lysKg, 0.01) and near(s.kgReal, 0.5 / 0.19))
    check("milk: no ME, no milk", M.toMilk(0, cattle).kgDM == 0 and M.toMilk(-5, cattle).kgReal == 0)
    check("cost: real kg x the dam's ME a kg", near(M.getDamCost(8, 5.0), 40) and M.getDamCost(-1, 5) == 0)
end

-- Coverage and sharing (N01, N03) ------------------------------------------------------------------

check("coverage: paid / demand within 0..1, nil without a demand",
    near(M.getCoverage(30, 50), 0.6) and M.getCoverage(80, 50) == 1 and M.getCoverage(-1, 50) == 0
    and M.getCoverage(10, 0) == nil and M.getCoverage(10, nil) == nil)
do
    local received, total = M.share({ 10, 20 }, 0.6)
    check("share: 10 and 20 at 60% get 6 and 12 (not 9 each)", near(received[1], 6) and near(received[2], 12) and near(total, 18))
    local swapped = M.share({ 20, 10 }, 0.6)
    check("share: the order of the young changes nobody's amount", near(swapped[1], received[2]) and near(swapped[2], received[1]))
    local full = M.share({ 10, 20 }, 1)
    check("share: a dam that pays all gives each its whole demand", near(full[1], 10) and near(full[2], 20))
    -- N03: a second, third young raise the dam's demand; under the same paid amount each gets less.
    local paid = 30
    local one = M.share({ 20 }, M.getCoverage(paid, 20))
    local two = M.share({ 20, 20 }, M.getCoverage(paid, 40))
    local three = M.share({ 20, 20, 20 }, M.getCoverage(paid, 60))
    check("share: more young share the same payment (no free milk): 20 / 15+15 / 10+10+10",
        near(one[1], 20) and near(two[1], 15) and near(two[2], 15) and near(three[1], 10) and near(three[3], 10))
end

-- Dairy split (D01) ---------------------------------------------------------------------------------

do
    local toYoung, q, collectable, drunk = M.splitDairy(12, { 3, 5 })
    check("dairy: 12 made, young need 3 and 5: each drinks its need, 4 collectable",
        q == 1 and near(toYoung[1], 3) and near(toYoung[2], 5) and near(collectable, 4) and near(drunk, 8))
    toYoung, q, collectable, drunk = M.splitDairy(6, { 3, 5 })
    check("dairy: 6 made: 75% each (2.25, 3.75), nothing collectable",
        near(q, 0.75) and near(toYoung[1], 2.25) and near(toYoung[2], 3.75) and collectable == 0 and near(drunk, 6))
    toYoung, q, collectable = M.splitDairy(8, { 3, 5 })
    check("dairy: exactly enough: all to the young, none left", q == 1 and collectable == 0)
    toYoung, q, collectable = M.splitDairy(9, {})
    check("dairy: no young: all collectable, no ratio", q == nil and collectable == 9 and #toYoung == 0)
    local _, _, c2, d2 = M.splitDairy(12, { 3, 5 })
    check("dairy: made = drunk + collectable (nothing counted twice)", near(c2 + d2, 12))
end
