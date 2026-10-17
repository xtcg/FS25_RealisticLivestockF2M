-- Sheep S5 life stages: one rule says whether a female is a ewe lamb being finished
-- (RLBodyCondition.isFinishingYoungFemale: female, never lambed, continuous age under the body
-- section's youngUntilMonth 12). The finishing target, its market reference, the reserve ceiling,
-- the verdict, AUTO's FINISH and the fat class shown all follow it. From 12 months a maiden ewe is
-- a ewe hogg (heiferReserveCeiling, BCS); a ewe that has lambed is a ewe (cowReserveCeiling).
-- Crossing a boundary changes what later steps aim for and what is shown, never the weight or
-- reserve by itself.

loadMod("tests/sheepsim.lua")

local B = RLBodyCondition
local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end

FeedSim.setMode(true)
SheepSim.enable(true)
GrowthSim.setDaysPerPeriod(1)

local GRASS = { GRASS_WINDROW = 3000 }

local function auto(animal) return RLFeed.getAnimalTarget(animal, { target = "AUTO" }, RLFeed.getRationClass(animal)) end
local function stage(animal)
    return { finishing = B.isFinishingYoungFemale(animal), target = B.getReserveTarget(animal), ceiling = B.getReserveCeiling(animal),
        fat = B.getFatClass(animal), auto = auto(animal), verdict = B.getFinishVerdict(animal), reference = B.getReferenceWeight(animal) }
end


-- 11.99 / 12 / 24 months, and the continuous clock ------------------------------------------------

do
    local ram = SheepSim.grown("RAM_LANDRACE", "LR", 6)
    local lamb = SheepSim.grown("SHEEP_LANDRACE", "L1", 11.99)
    local hogg = SheepSim.grown("SHEEP_LANDRACE", "L2", 12.0)
    local older = SheepSim.grown("SHEEP_LANDRACE", "L3", 24)
    SheepSim.makePen({ ram, lamb, hogg, older }, GRASS)
    local config = B.getConfig(lamb)
    local a, h, o = stage(lamb), stage(hogg), stage(older)
    check(string.format("stages: an 11.99-month ewe lamb is finished (target %.3f, fat %s, AUTO %s, verdict %s)",
        a.target or -1, tostring(a.fat), a.auto, tostring(a.verdict)),
        a.finishing and a.target ~= nil and a.ceiling == a.target and a.fat ~= nil and a.auto == "FINISH" and a.verdict ~= nil)
    check("stages: the ewe lamb's market reference is her breed's ram lamb's",
        near(a.reference, B.getReferenceWeight(ram), 1e-6))
    -- AUTO: still FINISH in her 14-day lamb -> hogg window (SHEEP-RAM-CONC-01, RLFeed.getYoungTransition), GROW after it.
    for _, case in ipairs({ { "12-month", h, "FINISH" }, { "24-month", o, "GROW" } }) do
        local s = case[2]
        check(string.format("stages: a %s maiden ewe is a ewe hogg (ceiling %.2f = heiferReserveCeiling, no target, no fat class, AUTO %s, no verdict)",
            case[1], s.ceiling or -1, s.auto),
            not s.finishing and s.target == nil and s.ceiling == config.heiferReserveCeiling and s.fat == nil and s.auto == case[3]
            and s.verdict == nil)
    end
    check("stages: a ewe hogg's reference is her own (no ram lamb's market weight, no femaleFinishShift)",
        h.reference == nil or not near(h.reference, B.getReferenceWeight(ram), 1e-6))
    check("stages: a ewe hogg shows BCS", B.getInfoText(hogg):find("rl_ui_bcs") ~= nil and B.getInfoText(lamb):find("rl_ui_bcs") == nil)

    -- The continuous clock decides, not the whole months: at age 11 with its clock at 11.999 it is
    -- still a lamb; whole months 12 with the clock not yet past, a hogg.
    lamb.rlGrowth.ageMonths = 11.999
    check("stages: the clock at 11.999 months (whole months 11) still a ewe lamb", B.isFinishingYoungFemale(lamb) and B.getFatClass(lamb) ~= nil)
    local twelve = SheepSim.grown("SHEEP_LANDRACE", "L4", 12.0)
    SheepSim.makePen({ twelve }, GRASS)
    twelve.rlGrowth.ageMonths = nil
    check("stages: whole months 12 without a clock (taken over) is a hogg", not B.isFinishingYoungFemale(twelve) and B.getFatClass(twelve) == nil)

    -- Ram lambs: finished at any age, but the fat class is young stock only.
    local tup = SheepSim.grown("RAM_LANDRACE", "LR2", 24)
    SheepSim.makePen({ tup }, GRASS)
    check("stages: a ram lamb shows a fat class and eats freely; a grown ram BCS, still FINISH under AUTO",
        B.getFatClass(ram) ~= nil and auto(ram) == "FINISH" and B.getFatClass(tup) == nil and auto(tup) == "FINISH")
end


-- First lambing ----------------------------------------------------------------------------------

do
    local maiden = SheepSim.grown("SHEEP_LANDRACE", "P1", 20)
    local young = SheepSim.grown("SHEEP_LANDRACE", "P2", 11.5)
    SheepSim.makePen({ maiden, young }, GRASS)
    local config = B.getConfig(maiden)
    local before = { maiden = B.getReserveCeiling(maiden), young = stage(young) }
    local weights = { maiden = maiden.weight, young = young.weight }
    local reserves = { maiden = B.getReserve(maiden), young = B.getReserve(young) }
    maiden.isParent, young.isParent = true, true
    local after = stage(young)
    check(string.format("first lambing: a maiden ewe's ceiling moves from heiferReserveCeiling %.2f to cowReserveCeiling %.2f", before.maiden, B.getReserveCeiling(maiden)),
        before.maiden == config.heiferReserveCeiling and B.getReserveCeiling(maiden) == config.cowReserveCeiling)
    check("first lambing: a ewe lamb that lambs at 11.5 months leaves the finishing rules (ewe rules, BCS, no fat class)",
        before.young.finishing and not after.finishing and after.fat == nil and after.target == nil and after.ceiling == config.cowReserveCeiling
        and after.auto == "GROW")
    check("first lambing: lambing changes neither weight nor reserve by itself",
        maiden.weight == weights.maiden and young.weight == weights.young and B.getReserve(maiden) == reserves.maiden
        and B.getReserve(young) == reserves.young)
end


-- Crossing 12 months on the hour: no step in weight or reserve, only the target and the display ---

do
    local lamb = SheepSim.grown("SHEEP_LANDRACE", "X1", 11.9)
    local pen = SheepSim.makePen({ lamb })
    RLGrowth.setReserveIndex(lamb, 0.60)
    B.ensureState(lamb, "test").reserve = 0.60
    local stock = { SILAGE = 4000, BARLEY = 4000 }
    local rows = {}
    -- Her whole months move on at the month change (the clock waits at 11.999 until then).
    local crossed
    for h = 1, 30 do
        local w, r, fin = lamb.weight, B.getReserve(lamb), B.isFinishingYoungFemale(lamb)
        SheepSim.run(pen, 1, stock)
        rows[h] = { dw = lamb.weight - w, dr = B.getReserve(lamb) - r, before = fin, after = B.isFinishingYoungFemale(lamb),
            age = RLGrowth.getContinuousAge(lamb) }
        if crossed == nil and fin and not rows[h].after then crossed = h end
        if crossed ~= nil and h >= crossed + 1 then break end
    end
    local text = {}
    for h = math.max((crossed or #rows) - 2, 1), #rows do
        local row = rows[h]
        text[#text + 1] = string.format("(%.3f m, %+.3f kg, %+.4f r)", row.age, row.dw, row.dr)
    end
    check("crossing: the ewe lamb becomes a ewe hogg within the run " .. table.concat(text, " "), crossed ~= nil)
    if crossed ~= nil then
        local prev = rows[math.max(crossed - 1, 1)]
        local row = rows[crossed]
        check(string.format("crossing: the hour she crosses moves weight %+.3f kg and reserve %+.4f, as the hour before (%+.3f kg, %+.4f): no jump",
            row.dw, row.dr, prev.dw, prev.dr), math.abs(row.dw - prev.dw) < 0.1 and math.abs(row.dr - prev.dr) < 0.01)
        check(string.format("crossing: above the hogg's ceiling (reserve %.3f > %.2f) her reserve is not cut to it", B.getReserve(lamb),
            B.getConfig(lamb).heiferReserveCeiling), B.getReserve(lamb) > B.getConfig(lamb).heiferReserveCeiling)
        -- Fed freely through her 14-day lamb -> hogg window (SHEEP-RAM-CONC-01), grown (GROW) after it.
        local inWindow = auto(lamb)
        lamb.age = 12
        lamb.rlGrowth.ageMonths = 12 + 15 / 30
        check("crossing: afterwards AUTO feeds her freely through the window, then grows her (GROW), no fat class",
            inWindow == "FINISH" and auto(lamb) == "GROW" and B.getFatClass(lamb) == nil)
    end
end


-- Pregnancy cost by litter: a third and further lamb at physiology pregnancyThirdLambFactor ---------

do
    local M = RLGrowthMath
    local half = { pregnancyThirdLambFactor = 0.5 }
    check("pregnancy load: 1 / 2 / 3 / 4 lambs count 1 / 2 / 2.5 / 3 at a third-lamb factor of 0.5",
        M.getPregnancyLoad(1, half) == 1 and M.getPregnancyLoad(2, half) == 2 and M.getPregnancyLoad(3, half) == 2.5
        and M.getPregnancyLoad(4, half) == 3 and M.getPregnancyLoad(nil, half) == 0)
    check("pregnancy load: without a factor (cattle, the body condition config) every fetus counts 1",
        M.getPregnancyLoad(3, {}) == 3 and M.getPregnancyLoad(2, {}) == 2)
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "PL1")
    local cow = GrowthSim.makeAnimal("COW_ANGUS", { age = 30 })
    SheepSim.makePen({ ewe })
    FeedSim.makePen({ cow })
    local sheepCfg, cowCfg = RLFeed.getEnergyConfig(ewe), RLFeed.getEnergyConfig(cow)
    check(string.format("pregnancy load: sheep read 0.50 from their physiology, cattle count every fetus (%s, %s)",
        tostring(sheepCfg.pregnancyThirdLambFactor), tostring(cowCfg.pregnancyThirdLambFactor)),
        sheepCfg.pregnancyThirdLambFactor == 0.5 and M.getPregnancyLoad(3, cowCfg) == 3)
end
