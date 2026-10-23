-- Pregnancy, calving and early lactation of a cow (RLGrowth): the calf, membranes and fluids are
-- weight she carries (not frame, not reserve) and calving takes them off in one step; after it
-- appetite lags behind milk, she draws her reserve for a while and rebuilds it.

loadMod("tests/feedsim.lua")

local G = RLGrowth
local settings = G.getSettings()
local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end

local function pregnant(cow, progress, fetuses)
    cow.isPregnant, cow.reproduction = progress > 0, progress * 100
    cow.pregnancy = progress > 0 and { pregnancies = (fetuses == 2) and { {}, {} } or { {} } } or nil
end

-- Gravid mass ---------------------------------------------------------------------------------

do
    local cow = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 48, isParent = true })
    local calf = G.getBirthMean(G.getBinding(cow:getSubType()))
    pregnant(cow, 0, 1)
    local none = G.getGravidTarget(cow)
    pregnant(cow, 0.5, 1); local half = G.getGravidTarget(cow)
    pregnant(cow, 0.9, 1); local late = G.getGravidTarget(cow)
    pregnant(cow, 1, 1); local term = G.getGravidTarget(cow)
    pregnant(cow, 1, 2); local twins = G.getGravidTarget(cow)
    check(string.format("gravid: none when not pregnant, %.1f kg at half, %.1f at 90%%, %.1f at term (%.1f x a %.1f kg calf)",
        half, late, term, settings.gravidTermRatio, calf),
        none == 0 and half < 0.2 * term and late < term and late > 0.6 * term and near(term, settings.gravidTermRatio * calf, 0.5))
    check(string.format("gravid: twins carry more (%.1f kg) but not twice a single calf's, each calf being lighter", twins),
        twins > term and twins < 2 * term)
    cow.isParent = false; pregnant(cow, 1, 1)
    check("gravid: a heifer's first calf is lighter", G.getGravidTarget(cow) < term)
end

-- Calving: one drop, no tissue ---------------------------------------------------------------

do
    GrowthSim.setDaysPerPeriod(1)
    local cow = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 48, isParent = true, isLactating = false })
    cow.weight = cow.targetWeight
    local pen = FeedSim.makePen({ cow }, { DRYGRASS_WINDROW = 4000 })
    cow.clusterSystem = { owner = pen }
    cow.bodyCondition = RLBodyCondition.createState(cow, "test")
    pregnant(cow, 0.5, 1)
    GrowthSim.penHour(pen, "hay")
    local startTissue = cow.weight - cow.rlGrowth.gravidKg
    for step = 1, 8 do
        pregnant(cow, 0.5 + step * 0.0625, 1)
        for _ = 1, 24 do GrowthSim.penHour(pen, "hay") end
    end
    local state = cow.rlGrowth
    local weightBefore, gravid, reserveBefore = cow.weight, state.gravidKg, state.reserveMassKg
    check(string.format("pregnancy: her weight rises by the gravid mass (%.1f kg) in the last half, her tissue does not (%+.1f kg)",
        gravid, weightBefore - gravid - startTissue),
        gravid > 60 and weightBefore - startTissue > gravid - 5 and math.abs(weightBefore - gravid - startTissue) < 0.25 * gravid)

    -- The birth: the game ends the pregnancy and resets the months since calving.
    pregnant(cow, 0, 1)
    cow.isParent, cow.isLactating, cow.monthsSinceLastBirth = true, true, 0
    GrowthSim.penHour(pen, "hay")
    local drop = weightBefore - cow.weight
    check(string.format("calving: the hour after the birth her weight falls by the gravid mass (%.1f of %.1f kg) and by almost nothing more",
        drop, gravid), drop > gravid - 1.5 and drop < gravid + 3)
    check(string.format("calving: no tissue is lost - her reserve mass stays (%.1f -> %.1f kg) and the carried mass is 0",
        reserveBefore, state.reserveMassKg), near(reserveBefore, state.reserveMassKg, 1.5) and state.gravidKg == 0)
    check("calving: the months-since-calving clock starts at the birth", state.lactationMonths ~= nil and state.lactationMonths < 0.1)
end

-- Appetite after calving ----------------------------------------------------------------------

do
    local cow = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 48, isParent = true, isLactating = true })
    local state = { lactationMonths = 0 }
    local weeks = settings.lactationWeeksPerMonth
    local at0 = G.getLactationFactor(cow, state)
    state.lactationMonths = 1; local at1 = G.getLactationFactor(cow, state)
    state.lactationMonths = 3; local at3 = G.getLactationFactor(cow, state)
    state.lactationMonths = 6; local at6 = G.getLactationFactor(cow, state)
    local nrc0 = 1 - math.exp(-settings.lactationIntakeRate * settings.lactationIntakeOffset)
    state.lactationMonths = 0
    local mild = G.getLactationFactor(cow, state, true)
    check(string.format("lactation: appetite is %.2f of full at calving (NRC 2001 %.2f), %.2f at one month, %.2f at three, %.2f at six; the old mode %.2f",
        at0, nrc0, at1, at3, at6, mild),
        near(at0, nrc0, 0.01) and at0 < at1 and at1 < at3 and at3 < at6 and at6 > 0.93 and mild > at0 and mild < 1)
    cow.isLactating = false
    check("lactation: a dry cow's appetite is untouched", G.getLactationFactor(cow, state) == 1)
    cow.isLactating, cow.monthsSinceLastBirth = true, 3
    check("lactation: with no clock yet the game's months since calving are used", near(G.getLactationMonths(cow, nil), 3.5))
    local lactating = G.getMilkMobilizeShare(cow, { lactationMonths = 0 })
    local later = G.getMilkMobilizeShare(cow, { lactationMonths = 6 })
    check(string.format("lactation: a fresh cow may fund %.2f of her milk from her reserve, %.2f from month %g on",
        lactating, later, settings.earlyMilkMobilizeMonths),
        near(lactating, settings.earlyMilkMobilizeShare, 1e-6) and near(later, RLBodyCondition.getConfig().milkMobilizeShare, 1e-6))
end

-- A whole cycle, the real-equivalent mode: a dip after calving, then the recovery ------------------

do
    local function cycle(strength)
        settings.lactationIntakeStrength = strength
        FeedSim.setMode(true)
        GrowthSim.setDaysPerPeriod(1)
        local cow = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 48, isParent = true, isLactating = true,
            genetics = { metabolism = 1, quality = 1, productivity = 1, fertility = 1, health = 1 } })
        cow.weight = cow.targetWeight
        local pen = FeedSim.makePen({ cow }, { FORAGE = 4000 })
        cow.clusterSystem = { owner = pen }
        cow.bodyCondition = RLBodyCondition.createState(cow, "test")
        cow.monthsSinceLastBirth = 0
        local opts = { refill = FeedSim.keepStocked({ FORAGE = 4000 }) }
        local function feedHour() opts.refill(pen); FeedSim.hour(pen, opts) end
        -- Settle the reserve she calves with: pregnant, dry, on the same ration, then the birth.
        cow.isLactating = false
        for hour = 1, 3 * 24 do
            pregnant(cow, math.min(hour / (3 * 24) * 0.999, 0.999), 1)
            feedHour()
        end
        local atCalving = RLBodyCondition.getBCS(cow)
        local tissueAtCalving = cow.weight - (cow.rlGrowth.gravidKg or 0)
        pregnant(cow, 0, 1)
        cow.isLactating, cow.monthsSinceLastBirth = true, 0
        local low, lowMonth = 9, 0
        local bcs = {}
        for month = 1, 8 do
            for quarter = 1, 4 do
                for _ = 1, 6 do feedHour() end
                local b = RLBodyCondition.getBCS(cow)
                if b < low then low, lowMonth = b, month - 1 + quarter / 4 end
            end
            cow.monthsSinceLastBirth = month
            bcs[month] = RLBodyCondition.getBCS(cow)
        end
        return atCalving, low, lowMonth, bcs, tissueAtCalving - (cow.weight - (cow.rlGrowth.gravidKg or 0))
    end
    local saved = settings.lactationIntakeStrength
    local c0, low0 = cycle(0)
    local c1, low1, lowMonth, bcs, tissueLoss = cycle(saved)
    settings.lactationIntakeStrength = saved
    check(string.format("cycle (real mode): with the lag the cow dips from BCS %.2f to %.2f at month %.2f (without: %.2f to %.2f)",
        c1, low1, lowMonth, c0, low0), low1 < c1 - 0.08 and low0 > c0 - 0.05 and lowMonth < 2.5)
    check(string.format("cycle (real mode): she builds the reserve back as intake catches up (BCS %.2f at month 8, %.2f at its lowest)",
        bcs[8], low1), bcs[8] > low1 + 0.05)
end

-- Persistence ---------------------------------------------------------------------------------

do
    local store = {}
    local xml = {
        setFloat = function(_, k, v) store[k] = v end, setInt = function(_, k, v) store[k] = v end,
        setString = function(_, k, v) store[k] = v end,
        getFloat = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
        getInt = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
        getString = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
        setBool = function(_, k, v) store[k] = v end,
        getBool = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
    }
    local state = G.newState({ birthWeightKg = 41.2, frameTargetKg = 730, developmentMonths = 30, reserveMassKg = 60,
        weightKg = 810, gravidKg = 62.5, lactationMonths = 1.75, source = "derived", lastTick = 5 })
    G.saveToXMLFile(state, xml, "a")
    local loaded = G.loadFromXMLFile(xml, "a")
    check("persistence: the carried gravid mass and the months since calving load back", loaded ~= nil
        and loaded.gravidKg == 62.5 and loaded.lactationMonths == 1.75)
    local old = G.newState({ birthWeightKg = 41.2, frameTargetKg = 730, developmentMonths = 30, reserveMassKg = 60, weightKg = 810 })
    G.saveToXMLFile(old, xml, "b")
    local loadedOld = G.loadFromXMLFile(xml, "b")
    check("persistence: an older save without them loads with neither (the cow's pregnancy then fixes the first)",
        loadedOld ~= nil and loadedOld.gravidKg == nil and loadedOld.lactationMonths == nil)
end

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
