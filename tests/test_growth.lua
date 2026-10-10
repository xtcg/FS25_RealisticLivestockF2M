-- Weight model v2 (scripts/animal/RLGrowth*.lua, xml/weightProfiles.xml): the 44 continuous
-- reference curves, the metabolism gene's three bounded effects, the unified birth weight, the
-- saved state and its migration, development delayed by underfeeding and resumed without a jump,
-- the lifecycle events that change no weight, the calf's milk-to-solid energy transition, the
-- MILKCOW stand-in, and that prices and feed requests of an animal on its curve stay calibrated.

loadMod("tests/growthsim.lua")

local G = RLGrowth
local M = RLGrowthMath
local config = RLBodyConditionConfig.get()
local settings = G.getSettings()
local profiles = G.getConfig().profiles

-- The design's profile values (FS25_CowBreeds_离线准备_2026-10-07/all-cattle-weight-profiles-v2.json).
local DESIGN = {
    HOLSTEIN = { 730, 1100, 45.114 }, SWISS_BROWN = { 670, 1000, 41.205 }, ANGUS = { 610, 1000, 30.012 },
    LIMOUSIN = { 780, 1200, 45.63 }, HEREFORD = { 660, 950, 37.422 }, HIGHLAND = { 500, 780, 27 },
    WATER_BUFFALO = { 590, 720, 36.462 }, REDHOLSTEIN_PACK = { 710, 960, 42 }, AYRSHIRE_PACK = { 480, 760, 30 },
    JERSEY_PACK = { 440, 668, 25 }, GUERNSEY_PACK = { 536, 820, 30 }, KERRY_PACK = { 450, 600, 27 },
    SHORTHORNMILKERS_PACK = { 664, 990, 37 }, REDANGUS_PACK = { 720, 1120, 35.5 }, CHAROLAIS_PACK = { 840, 1260, 39.3 },
    SHORTHORN_PACK = { 640, 1120, 35.5 }, IRISHMOILED_PACK = { 600, 800, 30 }, BRITISHBLUE_PACK = { 820, 1160, 42 },
    BELTEDGALLOWAY_PACK = { 580, 850, 32.2 }, SIMMENTAL_PACK = { 770, 1220, 37.4 }, MONTBELIARDE = { 690, 940, 40 },
    VOSGIENNE = { 610, 810, 39.6 },
}
-- The seven confirmed beef admission points: weight at the reference arrival month (admission-approval.json).
local ADMISSION = { REDANGUS_PACK = { 9, 340 }, CHAROLAIS_PACK = { 9.5, 350 }, SIMMENTAL_PACK = { 8.5, 360 },
    SHORTHORN_PACK = { 8, 300 }, BRITISHBLUE_PACK = { 8.5, 300 }, IRISHMOILED_PACK = { 7, 250 }, BELTEDGALLOWAY_PACK = { 7, 220 } }


-- Config -------------------------------------------------------------------------------------

do
    local count, valuesOk, mismatch = 0, true, {}
    for name, design in pairs(DESIGN) do
        local profile = profiles[name]
        if profile == nil or profile.invalid ~= nil then
            valuesOk = false; mismatch[#mismatch + 1] = name
        else
            count = count + 1
            local female, male = profile.knots.female, profile.knots.male
            if not near(female[#female][2], design[1], 1e-9) or not near(male[#male][2], design[2], 1e-9)
                or not near(female[1][2], design[3], 1e-9) or not near(male[1][2], design[3] * 1.07, 1e-9) then
                valuesOk = false; mismatch[#mismatch + 1] = name
            end
        end
    end
    check(string.format("config: the shipped file is valid and on, with the design's 22 breeds x 2 sexes (adults, birth means; %s)",
        table.concat(mismatch, " ")), G.getConfig().enabled == true and G.getConfig().invalidReason == nil
        and G.isEnabled() and count == 22 and valuesOk)

    local admissionOk = true
    for name, point in pairs(ADMISSION) do
        local curve = G.getNominalCurve({ profile = name, sex = "male" })
        if not near(curve:value(point[1]), point[2], 1e-9) then admissionOk = false end
    end
    check("config: every confirmed beef admission weight is a knot of its bull curve, met exactly", admissionOk)

    check("config: Holstein calves at the birth branch's 6.18% of the cow (45.11 / 48.27 kg)",
        near(G.getBirthMean({ profile = "HOLSTEIN", sex = "female" }), 0.0618 * 730, 1e-9)
        and near(G.getBirthMean({ profile = "HOLSTEIN", sex = "male" }), 0.0618 * 730 * 1.07, 1e-9))
end

do
    local bad = table.clone(settings)
    bad.castratedSpeed = 0
    check("config: a setting out of range is rejected", RLWeightProfiles.validateSettings(bad) == false)
    bad = table.clone(settings)
    bad.birthWeightCV, bad.birthTruncateSD = 0.4, 2.5
    check("config: a spread that could draw a birth weight under 10% of the mean is rejected",
        RLWeightProfiles.validateSettings(bad) == false)
    check("config: knots must rise in month and never fall in kg",
        RLWeightProfiles.parseKnots("3:100 6:90", 40) == nil and RLWeightProfiles.parseKnots("6:100 3:120", 40) == nil
        and RLWeightProfiles.parseKnots("3:100 6:200", 40) ~= nil and RLWeightProfiles.parseKnots("3:x", 40) == nil)
    local parsed = RLWeightProfiles.parse(nil)
    check("config: no file leaves the model off", parsed.enabled == false)
end


-- Curves ---------------------------------------------------------------------------------------

do
    -- Every profile and sex x 7 metabolism genes x 3 birth sizes: the probe's 924 curve cases.
    local cases, monotone, maxJump, maxKink, plateauOk, knotsOk = 0, true, 0, 0, true, true
    for name in pairs(DESIGN) do
        for _, sex in ipairs({ "female", "male" }) do
            local binding = { profile = name, sex = sex }
            local adult = G.getAdultReference(binding)
            for _, m in ipairs({ 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75 }) do
                local size, _, _, birthGene = G.getGeneFactors(m)
                for _, birthFactor in ipairs({ 0.75, 1, 1.25 }) do
                    cases = cases + 1
                    local curve = G.buildCurve(binding, adult * size, G.getBirthMean(binding) * birthGene * birthFactor)
                    local last = curve:value(0)
                    for i = 1, 84 * 20 do
                        local value = curve:value(i / 20)
                        if value < last - 1e-9 then monotone = false end
                        last = value
                    end
                    for _, knot in ipairs(curve:getKnots()) do
                        local t = knot[1]
                        if t > 0 then
                            maxJump = math.max(maxJump, math.abs(curve:value(t + 1e-7) - curve:value(t - 1e-7)))
                            local left = (curve:value(t) - curve:value(t - 1e-5)) / 1e-5
                            local right = (curve:value(t + 1e-5) - curve:value(t)) / 1e-5
                            maxKink = math.max(maxKink, math.abs(left - right))
                        end
                    end
                    if not near(curve:value(curve.endMonth + 50), adult * size, 1e-9) or curve:slope(curve.endMonth + 1) ~= 0 then
                        plateauOk = false
                    end
                    if not near(curve:value(0), G.getBirthMean(binding) * birthGene * birthFactor, 1e-9) then knotsOk = false end
                end
            end
        end
    end
    check(string.format("curves: %d curves (44 profiles x 7 genes x 3 birth sizes) never fall", cases), cases == 924 and monotone)
    check(string.format("curves: weight continuous (largest step across a knot %.2g kg) and gain continuous (largest kink %.2g kg/month)",
        maxJump, maxKink), maxJump < 1e-4 and maxKink < 0.003)
    check("curves: flat at the adult weight after the plateau month, and they start at the actual birth weight", plateauOk and knotsOk)
end

do
    local curve = G.getNominalCurve({ profile = "ANGUS", sex = "male" })
    local ok = true
    for _, w in ipairs({ 32.2, 50, 215, 400, 663, 950, 999.9 }) do
        if math.abs(curve:value(curve:inverse(w)) - w) > 1e-6 then ok = false end
    end
    check("curves: the inverse gives the month a weight is reached", ok and curve:inverse(10) == 0 and curve:inverse(2000) == 60)

    -- The birth difference fades out by birthFadeMonths: the 6-month knot and later are the reference x size.
    local binding = { profile = "HOLSTEIN", sex = "female" }
    local light = G.buildCurve(binding, 730, 30)
    local heavy = G.buildCurve(binding, 730, 60)
    check("curves: a light or heavy calf's curve meets the reference by 6 months (none of it reset at a month)",
        near(light:value(6), 197.1, 1e-9) and near(heavy:value(6), 197.1, 1e-9) and light:value(3) < heavy:value(3)
        and light:value(0) == 30 and heavy:value(0) == 60)
end


-- Genes ----------------------------------------------------------------------------------------

do
    local s1, v1, e1, b1 = G.getGeneFactors(0.25)
    local s2, v2, e2, b2 = G.getGeneFactors(1.75)
    local s0, v0, e0, b0 = G.getGeneFactors(1)
    check(string.format("genes: metabolism 0.25 / 1.75 -> size %.2f/%.2f, speed %.2f/%.2f, maintenance %.2f/%.2f, birth %.4f/%.4f",
        s1, s2, v1, v2, e1, e2, b1, b2), near(s1, 0.88, 1e-12) and near(s2, 1.12, 1e-12) and near(v1, 0.9, 1e-12)
        and near(v2, 1.1, 1e-12) and near(e1, 0.85, 1e-12) and near(e2, 1.15, 1e-12) and near(b1, 0.9625, 1e-12)
        and near(b2, 1.0375, 1e-12) and s0 == 1 and v0 == 1 and e0 == 1 and b0 == 1)
    local s3 = G.getGeneFactors(3)
    check("genes: a gene beyond the dealer's range is clamped, not extrapolated", near(s3, 1.12, 1e-12))

    -- The old rule: adult x (1 + 0.4 x (m - 1)) and growth x m again on top.
    local oldTarget = 1000 + (1000 * 1.75 - 1000) / 2.5
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { genetics = { metabolism = 1.75, quality = 1, productivity = 1, fertility = 1, health = 1 } })
    check(string.format("genes: a 1.75 bull's adult weight is %.0f kg (x1.12), not the old %.0f (x1.3), and nothing multiplies its growth by m",
        bull.targetWeight, oldTarget), near(bull.targetWeight, 1120, 1e-9) and oldTarget == 1300)
end


-- Pure step: ledger and bounds -------------------------------------------------------------------

do
    local seed = 4242
    local function rand() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
    local curve = G.getNominalCurve({ profile = "HOLSTEIN", sex = "female" })
    local kappa = G.getKappa()
    local ledgerOk, massOk, boundsOk, directionOk = true, true, true, true
    for _ = 1, 600 do
        local lactating = rand() < 0.4
        local weight = 50 + rand() * 800
        local input = {
            dtMonths = 1 / 24 * (1 + math.floor(rand() * 3)), weight = weight, reserveKg = weight * rand() * 0.2,
            development = rand() * 70, curve = curve, kappa = kappa, frameFloorKg = 20, speed = 0.9 + rand() * 0.2,
            diseaseFactor = rand() < 0.2 and rand() or 1, maintenanceFactor = 0.85 + rand() * 0.3,
            potentialMilk = lactating and rand() * 500 or 0, anchorMilk = lactating and rand() * 450 or 0,
            isLactating = lactating, pregnancyProgress = rand(), numFetuses = rand() < 0.3 and 1 or 0,
            intakeLiters = rand() * 1.5 * 300, referenceLiters = 300, intakeCapacity = 0.9 + rand() * 0.7,
            reserveCeiling = rand(), fixedPrice = rand() < 0.5, referenceWeight = weight * (0.8 + rand() * 0.4),
            referenceGrowthNU = rand() * 900,
        }
        local r = M.step(input, config)
        local left = r.supplyNU + r.mobilizedNU + r.catabolismNU
        local right = r.paidNU + r.depositNU + r.lostNU
        if math.abs(left - right) > 1e-6 * math.max(1, left) then ledgerOk = false end
        local expected = input.weight + r.frameGainKg + r.growthReserveKg + r.depositKg - r.mobilizedKg - r.catabolismKg
        if math.abs(r.weight - expected) > 1e-9 or math.abs(r.weight - r.frameKg - r.reserveKg) > 1e-9 then massOk = false end
        if r.reserveKg < 0 or r.frameKg < 20 - 1e-9 or r.weight <= 0 or r.development < 0 or r.development > curve.endMonth
            or r.milkFraction < 0 or r.milkFraction > 1 + 1e-9 or r.growthFraction < 0 or r.growthFraction > 1 + 1e-9 then
            boundsOk = false
        end
        if r.depositNU > 1e-9 and r.mobilizedNU > 1e-9 then directionOk = false end
    end
    check("step: supply + mobilised + catabolised = paid + deposited + lost, for any input", ledgerOk)
    check("step: weight = frame + reserve and moves by exactly its parts", massOk)
    check("step: reserve >= 0, frame above its floor, development 0..plateau, shares 0..1", boundsOk)
    check("step: never lays down and draws reserve in the same step", directionOk)
end

do
    -- Full feed on the curve: the step reproduces the curve exactly (genes 1, neutral reserve).
    local curve = G.getNominalCurve({ profile = "ANGUS", sex = "male" })
    local kappa = G.getKappa()
    local frame, reserveKg = M.split(curve:value(0), config.referenceReserve, kappa)
    local weight, u, maxDiff = curve:value(0), 0, 0
    local dt = 1 / 24
    for step = 1, 70 * 24 do
        local input = { dtMonths = dt, weight = weight, reserveKg = reserveKg, development = u, curve = curve, kappa = kappa,
            frameFloorKg = 1, speed = 1, intakeLiters = 100, referenceLiters = 100, intakeCapacity = 1,
            reserveCeiling = config.referenceReserve }
        local r = M.step(input, config)
        weight, reserveKg, u = r.weight, r.reserveKg, r.development
        maxDiff = math.max(maxDiff, math.abs(weight - curve:value(step * dt)))
    end
    check(string.format("step: an animal fed exactly its demand follows its curve to the plateau (largest gap %.2g kg, ends %.6f kg)",
        maxDiff, weight), maxDiff < 1e-6 and near(weight, 1000, 1e-6) and u == curve.endMonth)
end


-- Underfeeding delays development; fed again, growth resumes from where it is ---------------------

do
    local curve = G.getNominalCurve({ profile = "ANGUS", sex = "male" })
    local kappa = G.getKappa()
    local function run(feedAt)
        local weight = curve:value(0)
        local _, reserveKg = M.split(weight, config.referenceReserve, kappa)
        local u, dt, trace = 0, 1 / 24, {}
        for step = 1, 24 * 24 do
            local month = (step - 1) * dt
            local input = { dtMonths = dt, weight = weight, reserveKg = reserveKg, development = u, curve = curve, kappa = kappa,
                frameFloorKg = 10, speed = 1, intakeLiters = 100 * feedAt(month), referenceLiters = 100, intakeCapacity = 1.1,
                reserveCeiling = 0.6 }
            local r = M.step(input, config)
            trace[step] = { weight = r.weight, u = r.development, gain = r.weight - weight, frameGain = r.frameKg - (weight - reserveKg) }
            weight, reserveKg, u = r.weight, r.reserveKg, r.development
        end
        return trace
    end
    local full = run(function() return 1 end)
    local starved = run(function(month) return (month >= 6 and month < 9) and 0 or 1 end)
    local half = run(function(month) return month >= 6 and 0.5 or 1 end)

    local atStart, atEnd = starved[6 * 24], starved[9 * 24]
    check(string.format("nutrition: three months without feed do not develop the frame (development %.2f -> %.2f months) and lose weight (%.0f -> %.0f kg)",
        atStart.u, atEnd.u, atStart.weight, atEnd.weight), atEnd.u <= atStart.u + 1e-9 and atEnd.weight < atStart.weight)

    -- Fed again: no jump to its calendar age, and never faster than its curve allows. The frame it
    -- broke down while starving moved its development back too, so it is that much further behind.
    -- Its frame grows no faster than its curve; its weight only as much faster as refilling the
    -- reserve at its monthly rate adds.
    local maxStep, fullMax, maxFrame, fullMaxFrame, fasterThanCurve = 0, 0, 0, 0, false
    for step = 1, 24 * 24 do
        fullMax = math.max(fullMax, full[step].gain)
        fullMaxFrame = math.max(fullMaxFrame, full[step].frameGain)
    end
    for step = 9 * 24 + 1, 24 * 24 do
        maxStep = math.max(maxStep, math.abs(starved[step].gain))
        maxFrame = math.max(maxFrame, starved[step].frameGain)
        local du = starved[step].u - starved[step - 1].u
        if du > 1 / 24 * 1.0 + 1e-9 then fasterThanCurve = true end
    end
    local lag = 24 - starved[24 * 24].u
    local lost = 6 - atEnd.u
    check(string.format("nutrition: fed again it grows on from its own development, no jump (largest hourly gain %.2f kg, frame %.2f; full feed %.2f, %.2f), no catch-up beyond its speed; %.2f months behind at 24 months (3 starved + %.2f of frame lost)",
        maxStep, maxFrame, fullMax, fullMaxFrame, lag, lost), maxFrame <= fullMaxFrame + 1e-9 and maxStep <= fullMax * 1.1
        and not fasterThanCurve and math.abs(lag - (3 + lost)) < 0.05)
    check(string.format("nutrition: on half its ration it grows, slower (%.0f kg at 24 months against %.0f on full feed)",
        half[24 * 24].weight, full[24 * 24].weight), half[24 * 24].weight < full[24 * 24].weight * 0.95
        and half[24 * 24].weight > half[6 * 24].weight and half[24 * 24].u < full[24 * 24].u)
end


-- Through the game adapter -----------------------------------------------------------------------

do
    local bull = GrowthSim.newborn("BULL_ANGUS")
    local pen = GrowthSim.makePen({ bull })
    bull.clusterSystem = { owner = pen }
    local handled = GrowthSim.penHour(pen, "TMR")
    local after = bull.weight
    check("adapter: a covered calf takes the v2 step from its first hour, the state stepped once per hour",
        handled and bull.rlGrowth.lastTick == RLBodyCondition.getTickId() and bull.rlGrowth.source == "birth"
        and RLGrowth.step(bull, 1) == true and bull.weight == after)

    -- Moved to a pen without a ledger in the same hour: done, no second step by any rule.
    bull.clusterSystem = { owner = GrowthSim.makePen() }
    check("adapter: an animal moved within the hour is not stepped again", RLGrowth.step(bull, 1) and bull.weight == after)
    bull.clusterSystem = { owner = pen }

    -- An hour without a ledger: the same budget, intake from the pen's food factor.
    GrowthSim.penHour(pen, "TMR", { noLedger = true })
    check("adapter: an hour without a feed ledger is still the v2 budget (intake from the food factor), never an old rule",
        bull.rlNutrition.intakeSource == "foodFactor" and bull.weight > after and bull.rlGrowth.lastTick == RLBodyCondition.getTickId())

    check("adapter: the body condition mirrors the reserve as its index r = R / K",
        near(bull.bodyCondition.reserve, bull.rlGrowth.reserveMassKg / ((bull.weight - bull.rlGrowth.reserveMassKg) * G.getKappa()), 1e-9))

    local legacy = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
    legacy.isIndividual = nil
    check("adapter: a vanilla cluster (not an individual animal) is not covered", not G.covers(legacy) and G.covers(bull))
    local config2 = G.getConfig()
    config2.enabled = false
    local off = not G.covers(bull) and G.getConstructorTarget(bull:getSubType(), bull.genetics) == nil
    config2.enabled = true
    RLBodyConditionConfig.config.enabled = false
    local bcOff = not G.covers(bull)
    RLBodyConditionConfig.config.enabled = true
    check("adapter: with the model or the body condition switched off, nothing is covered (the old rules)", off and bcOff)
end

do
    -- Period length: 1, 3 and 7 days per period give the same 6 months.
    local weights = {}
    for _, days in ipairs({ 1, 3, 7 }) do
        GrowthSim.setDaysPerPeriod(days)
        local bull = GrowthSim.makeAnimal("BULL_LIMOUSIN", { age = 8 })
        local pen = GrowthSim.makePen({ bull })
        bull.clusterSystem = { owner = pen }
        GrowthSim.months(pen, "silage", 6)
        weights[#weights + 1] = bull.weight
    end
    GrowthSim.setDaysPerPeriod(1)
    check(string.format("time: 1, 3 and 7 days per period give the same weight after 6 months (%.2f %.2f %.2f)",
        weights[1], weights[2], weights[3]),
        math.abs(weights[2] / weights[1] - 1) < 0.002 and math.abs(weights[3] / weights[1] - 1) < 0.002)
end


-- Migration: an old savegame's animal keeps its weight --------------------------------------------

do
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 20, weight = 550.123 })
    bull.bodyCondition = RLBodyCondition.createState(bull, "legacy")
    bull.bodyCondition.reserve = 0.6
    local before = bull.weight
    local state = G.ensureState(bull)
    local frame = bull.weight - state.reserveMassKg
    local curve = G.getCurve(bull)
    check(string.format("migration: weight kept exactly (%.3f kg), the old reserve index kept as r = R / K (%.4f), development where the curve has its frame (%.2f months)",
        bull.weight, state.reserveMassKg / (frame * G.getKappa()), state.developmentMonths),
        bull.weight == before and near(state.reserveMassKg / (frame * G.getKappa()), 0.6, 1e-12)
        and near(curve:value(state.developmentMonths), frame * (1 + config.referenceReserve * G.getKappa()), 1e-6)
        and state.source == "derived" and state.frameTargetKg == bull.targetWeight)

    local calf = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 2, weight = 90 })
    local calfState = G.ensureState(calf)
    local calfFrame = calf.weight - calfState.reserveMassKg
    check("migration: an animal with no condition on record starts at the neutral reserve",
        near(calfState.reserveMassKg / (calfFrame * G.getKappa()), config.initialReserve, 1e-12) and calf.weight == 90)

    -- An old cow far above her new adult weight (the old gene rule made her x1.3) is not slimmed.
    local cow = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 70, isParent = true, weight = 949,
        genetics = { metabolism = 1.75, quality = 1, productivity = 1, fertility = 1, health = 1 } })
    local pen = GrowthSim.makePen({ cow })
    cow.clusterSystem = { owner = pen }
    cow.bodyCondition = RLBodyCondition.createState(cow, "legacy")
    GrowthSim.months(pen, "TMR", 6)
    local low = cow.weight
    check(string.format("migration: a cow above her new adult weight (%.0f > %.0f kg) is not slimmed by the change (%.0f kg after 6 months dry on TMR), and grows no frame",
        949, cow.targetWeight, low), low >= 949 - 1e-6 and cow.rlGrowth.developmentMonths == G.getCurve(cow).endMonth)
end

do
    -- A weight changed outside the model (the old rules while it was off, the console) is taken as it is.
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
    local pen = GrowthSim.makePen({ bull })
    bull.clusterSystem = { owner = pen }
    GrowthSim.penHour(pen, "TMR")
    local u = bull.rlGrowth.developmentMonths
    bull.weight = bull.weight - 40
    GrowthSim.penHour(pen, "TMR")
    check(string.format("migration: a weight changed elsewhere is split again and its development moved back (%.2f -> %.2f months)",
        u, bull.rlGrowth.developmentMonths), bull.rlGrowth.source == "resync" and bull.rlGrowth.developmentMonths < u - 0.5
        and near(bull.rlGrowth.weightKg, bull.weight, 1e-9))
end


-- Birth ------------------------------------------------------------------------------------------

do
    local _, cowSub = Economics.find("COW_HOLSTEIN")
    local _, bullSub = Economics.find("BULL_HOLSTEIN")
    local _, angusBull = Economics.find("BULL_ANGUS")
    local function mean(sub, ctx) return G.getBirthMeanFor(sub, ctx) end
    local thin = { bodyCondition = { reserve = 0.25 } }
    local fat = { bodyCondition = { reserve = 0.95 } }
    check(string.format("birth: a single Holstein heifer from an average dam %.3f kg, a bull calf %.3f", mean(cowSub, {}), mean(bullSub, {})),
        near(mean(cowSub, {}), 45.114, 1e-9) and near(mean(bullSub, {}), 48.27198, 1e-6))
    check("birth: twins 85% each, triplets 75%, a heifer's first calf 93%",
        near(mean(cowSub, { litterSize = 2 }), 45.114 * 0.85, 1e-9) and near(mean(cowSub, { litterSize = 3 }), 45.114 * 0.75, 1e-9)
        and near(mean(cowSub, { firstBirth = true }), 45.114 * 0.93, 1e-9))
    check(string.format("birth: a thin dam's calf lighter (x%.3f), a fat dam's at most x%.2f; a dam without a reserve on record x1",
        G.getDamFactor(thin), settings.damFactorMax), near(G.getDamFactor(thin), 1 + 0.25 * (0.25 - 0.45), 1e-12)
        and G.getDamFactor(fat) == settings.damFactorMax and G.getDamFactor({}) == 1 and G.getDamFactor(nil) == 1)
    check("birth: a cross takes the mean of both breeds for the calf's sex; buffalo never crosses with cattle",
        near(mean(bullSub, { damBreed = "HOLSTEIN", sireBreed = "ANGUS" }), (48.27198 + 32.11284) / 2, 1e-4)
        and near(mean(bullSub, { damBreed = "HOLSTEIN", sireBreed = "WATER_BUFFALO" }), 48.27198, 1e-6)
        and near(mean(angusBull, { damBreed = "ANGUS", sireBreed = "CHAROLAISE" }), (32.11284 + 39.3 * 1.07) / 2, 1e-4))
    check("birth: the calf's own metabolism gene moves its mean by 5% of its distance from 1",
        near(mean(cowSub, { metabolism = 1.75 }), 45.114 * 1.0375, 1e-9) and near(mean(cowSub, { metabolism = 0.25 }), 45.114 * 0.9625, 1e-9))

    local seed = 7
    local function rand() seed = (seed * 1103515245 + 12345) % 2147483648; return (seed + 0.5) / 2147483648 end
    local n, sum, sumSq, inRange = 20000, 0, 0, true
    for _ = 1, n do
        local weight, z, m = G.drawBirthWeight(cowSub, {}, rand)
        sum = sum + weight; sumSq = sumSq + weight * weight
        if math.abs(z) > settings.birthTruncateSD + 1e-12 or not near(weight, m * (1 + settings.birthWeightCV * z), 1e-9) then inRange = false end
    end
    local avg = sum / n
    local cv = math.sqrt(sumSq / n - avg * avg) / avg
    check(string.format("birth: 20000 draws around 45.11 kg: mean %.2f, CV %.3f (truncated normal of CV 0.10), none past 2.5 SD", avg, cv),
        math.abs(avg / 45.114 - 1) < 0.005 and math.abs(cv - 0.0985) < 0.004 and inRange)

    local calf = GrowthSim.makeAnimal("BULL_HOLSTEIN", { age = 0, genetics = { metabolism = 1.5, quality = 1, productivity = 1, fertility = 1, health = 1 } })
    G.initBirth(calf, 39.5)
    check(string.format("birth: a newborn keeps its own draw (%.1f kg, not the mean), development 0, the neutral reserve, its adult weight from its genes (%.0f kg)",
        calf.weight, calf.targetWeight), calf.weight == 39.5 and calf.rlGrowth.birthWeightKg == 39.5
        and calf.rlGrowth.developmentMonths == 0 and near(calf.targetWeight, 1100 * (1 + 0.12 * 0.5 / 0.75), 1e-9)
        and near(calf.rlGrowth.reserveMassKg / ((39.5 - calf.rlGrowth.reserveMassKg) * G.getKappa()), config.initialReserve, 1e-12))

    -- A light calf is not lifted to the mean: not in its first hour, not at 6 months.
    local light = GrowthSim.newborn("COW_ANGUS", nil, 0.75)
    local normal = GrowthSim.newborn("COW_ANGUS", nil, 1)
    local pen = GrowthSim.makePen({ light, normal })
    light.clusterSystem, normal.clusterSystem = { owner = pen }, { owner = pen }
    local start = light.weight
    GrowthSim.penHour(pen, "TMR")
    local firstHour = light.weight - start
    GrowthSim.months(pen, "TMR", 6)
    check(string.format("birth: a light calf (%.1f kg) grows on from its own weight (+%.2f kg in its first hour) and meets the reference by 6 months without a reset (%.0f / %.0f kg)",
        start, firstHour, light.weight, normal.weight), firstHour > 0 and firstHour < 1.5
        and math.abs(light.weight / normal.weight - 1) < 0.03)
end


-- Lifecycle: no event changes the weight ----------------------------------------------------------

do
    local function hourGains(animal, pen, rationName, hours)
        local gains = {}
        for i = 1, hours do
            local before = animal.weight
            GrowthSim.penHour(pen, rationName)
            gains[i] = animal.weight - before
        end
        return gains
    end

    -- Castration of a growing bull: no step in weight, its development slows to castratedSpeed
    -- over about transitionMonths.
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 8 })
    local twin = GrowthSim.makeAnimal("BULL_ANGUS", { age = 8 })
    local pen = GrowthSim.makePen({ bull, twin })
    bull.clusterSystem, twin.clusterSystem = { owner = pen }, { owner = pen }
    GrowthSim.months(pen, "TMR", 1)
    local before = hourGains(bull, pen, "TMR", 1)[1]
    bull.isCastrated = true
    local atSwitch = hourGains(bull, pen, "TMR", 1)[1]
    GrowthSim.months(pen, "TMR", 1)
    local speedAfterMonth = bull.rlGrowth.speedFactor
    GrowthSim.months(pen, "TMR", 4)
    check(string.format("lifecycle: castration changes no weight (hourly gain %.3f -> %.3f kg), the steer's speed eases to %.2f (%.3f a month on)",
        before, atSwitch, settings.castratedSpeed, speedAfterMonth), math.abs(atSwitch - before) < 0.05 * before
        and speedAfterMonth < 0.91 and speedAfterMonth > 0.899 and bull.weight < twin.weight
        and bull.rlGrowth.developmentMonths < twin.rlGrowth.developmentMonths)

    -- Calving and drying off: the switch hour changes no weight.
    local cow = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 30, isParent = true })
    local cowPen = GrowthSim.makePen({ cow })
    cow.clusterSystem = { owner = cowPen }
    GrowthSim.months(cowPen, "TMR", 1)
    local w0 = cow.weight
    local g0 = hourGains(cow, cowPen, "TMR", 1)[1]
    cow.isLactating, cow.monthsSinceLastBirth = true, 0
    local w1 = cow.weight
    local g1 = hourGains(cow, cowPen, "TMR", 1)[1]
    check(string.format("lifecycle: calving changes no weight by itself (%.2f kg before the hour, %.3f -> %.3f kg an hour after)", w1 - w0 - g0, g0, g1),
        math.abs(g1) < 1 and w1 == w0 + g0)

    -- Weaning age in a rearing pen: the solid feed's worth changes hour by hour, no step - also not
    -- in the first hour of a new period, which runs before the day change ages the animal.
    local calf = GrowthSim.newborn("COW_HOLSTEIN")
    local calfPen = GrowthSim.makePen({ calf })
    calf.clusterSystem = { owner = calfPen }
    local young, last, maxJump = nil, RLCalfRearing.getSolidEnergyFactor(calf), 0
    for month = 0, 5 do
        for hour = 1, 24 do
            GrowthSim.penHour(calfPen, "TMR")
            -- The day change ages the animal after the period's first hour (Animal:onDayChanged).
            if hour == 1 and month > 0 then calf.age = calf.age + 1 end
            local value = RLCalfRearing.getSolidEnergyFactor(calf)
            maxJump = math.max(maxJump, math.abs(value - last))
            last = value
        end
        if month == 0 then young = RLCalfRearing.getSolidEnergyFactor(calf) end
    end
    check(string.format("calves: a liter of solid feed is worth %.2f to a 1-month calf, rising to %.2f after weaning, with no step at any hour (largest %.4f)",
        young, last, maxJump), young < 0.6 and last == 1 and maxJump < 0.01)

    local twinCalf = GrowthSim.newborn("COW_HOLSTEIN")
    twinCalf.age = 2
    twinCalf.rlGrowth.ageMonths = 2.5
    local legacyCalf = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 2 })
    legacyCalf.isIndividual = nil
    local capsV2 = { RLCalfRearing.getCaps(twinCalf) }
    local capsOld = { RLCalfRearing.getCaps(legacyCalf) }
    check("calves: under v2 the milk and solid caps also move within the month; without it, by whole months as before",
        capsV2[1] < capsOld[1] and capsV2[2] > capsOld[2])
end


-- Persistence and network ------------------------------------------------------------------------

do
    local store = {}
    local xml = {
        setFloat = function(_, k, v) store[k] = v end, setInt = function(_, k, v) store[k] = v end,
        setString = function(_, k, v) store[k] = v end,
        getFloat = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
        getInt = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
        getString = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
    }
    local state = G.newState({ birthWeightKg = 41.2, frameTargetKg = 1043.5, developmentMonths = 13.25, reserveMassKg = 41.7,
        speedFactor = 0.95, intakeFactor = 1.07, weightKg = 512.25, ageMonths = 14.5, source = "birth", lastTick = 4711 })
    G.saveToXMLFile(state, xml, "a")
    local loaded = G.loadFromXMLFile(xml, "a")
    local same = true
    for k, v in pairs(state) do if loaded[k] ~= v then same = false end end
    check("persistence: a saved state loads back unchanged (birth, adult, development, reserve mass, stage factors)", same)
    check("persistence: an animal saved without a state loads none (it gets one from its weight)", G.loadFromXMLFile(xml, "b") == nil)
    store["a.growth#reserveMassKg"] = -5
    check("persistence: an unusable state is dropped, not used", G.loadFromXMLFile(xml, "a") == nil)
    store["a.growth#reserveMassKg"] = 41.7
    store["a.growth#version"] = 99
    check("persistence: a newer state version is dropped, not misread", G.loadFromXMLFile(xml, "a") == nil)

    local stream, readAt = {}, 0
    local function w(v) stream[#stream + 1] = v end
    local function r() readAt = readAt + 1; return stream[readAt] end
    streamWriteBool, streamWriteFloat32 = function(_, v) w(v) end, function(_, v) w(v) end
    streamReadBool, streamReadFloat32 = function() return r() end, function() return r() end
    G.writeStream(state, 1)
    G.writeStream(nil, 1)
    local a, b = G.readStream(1), G.readStream(1)
    check("network: a state and no state both round-trip, in order",
        a.birthWeightKg == 41.2 and a.frameTargetKg == 1043.5 and a.developmentMonths == 13.25 and a.reserveMassKg == 41.7
        and a.weightKg == 512.25 and b == nil and readAt == #stream)

    local copy = G.copyState(state)
    copy.reserveMassKg = 0
    check("clone: a copied state is a separate table", state.reserveMassKg == 41.7 and G.copyState(nil) == nil)

    -- Reloaded, its adult weight is the saved one, whatever the file says now.
    local _, sub = Economics.find("BULL_ANGUS")
    check("persistence: a reloaded animal keeps its saved adult weight (traceable), not one re-read from its gene",
        G.getConstructorTarget(sub, { metabolism = 1 }, state) == 1043.5
        and G.getConstructorTarget(sub, { metabolism = 1 }, nil) == 1000)
end


-- Prices and feed stay calibrated for an animal on its curve ---------------------------------------

do
    local function oldPrice(name, age, metabolism)
        local i, sub = Economics.find(name)
        local animal = GrowthSim.makeAnimal(name, { age = age, genetics = { metabolism = metabolism, quality = 1, productivity = 1, fertility = 1, health = 1 } })
        animal.isIndividual = nil
        animal.targetWeight = G.getLegacyTarget(sub, metabolism)
        animal.weight = RLBreedTraits.getGrownWeight(sub, animal.gender, animal.targetWeight, age, metabolism)
        return animal:getSellPrice(), Animal._computeDailyFood(age, false, 0, 0, metabolism, Economics.curve(sub.food, age), 1, animal:getFeedModifier())
    end
    local function newPrice(name, age, metabolism)
        local _, sub = Economics.find(name)
        local animal = GrowthSim.makeAnimal(name, { age = age, genetics = { metabolism = metabolism, quality = 1, productivity = 1, fertility = 1, health = 1 } })
        return animal:getSellPrice(), Animal._computeDailyFood(age, false, 0, 0, animal:getIntakeGene(), Economics.curve(sub.food, age), 1, animal:getFeedModifier()),
            animal
    end
    local priceOk, feedOk, details = true, true, {}
    for _, name in ipairs({ "BULL_ANGUS", "COW_HOLSTEIN", "BULL_HIGHLAND_CATTLE", "COW_WATERBUFFALO" }) do
        for _, age in ipairs({ 3, 9, 15, 24, 40 }) do
            local p0, f0 = oldPrice(name, age, 1)
            local p1, f1 = newPrice(name, age, 1)
            if math.abs(p1 / p0 - 1) > 1e-9 then priceOk = false; details[#details + 1] = string.format("%s@%d %.1f/%.1f", name, age, p0, p1) end
            if math.abs(f1 / f0 - 1) > 1e-9 then feedOk = false; details[#details + 1] = string.format("%s@%d feed %.1f/%.1f", name, age, f0, f1) end
        end
    end
    check("price: an animal on its v2 curve fetches what one on the old line did, at every age (" .. table.concat(details, ", ") .. ")", priceOk)
    check("feed: and asks for the same food at average genes", feedOk)

    -- A pack breed (no price line): its share of its curve is put on the old line with the pack's own target.
    local _, packSub = GrowthSim.addSubType("BULL_CHAROLAIS_PACK", "CHAROLAIS_PACK", "male", 1050, "BULL_ANGUS")
    local pack = GrowthSim.makeAnimal("BULL_CHAROLAIS_PACK", { age = 12 })
    local oldPack = GrowthSim.makeAnimal("BULL_CHAROLAIS_PACK", { age = 12 })
    oldPack.isIndividual = nil
    oldPack.targetWeight = 1050
    oldPack.weight = RLBreedTraits.getGrownWeight(packSub, "male", 1050, 12, 1)
    check(string.format("price: a pack bull on its v2 curve (%.0f kg, adult %.0f) is priced as one on the pack's old line (%.0f kg)",
        pack.weight, pack.targetWeight, oldPack.weight), near(pack:getSellPrice(), oldPack:getSellPrice(), 1e-6)
        and pack.targetWeight == 1260)

    -- Heavier or lighter than its curve: priced and fed by the same share as before.
    local heavy = GrowthSim.makeAnimal("BULL_ANGUS", { age = 15 })
    local base = heavy:getSellPrice()
    heavy.weight = heavy.weight * 1.1
    check("price: an animal 10% above its curve is worth more, as on the old line", heavy:getSellPrice() > base)

    -- A high-metabolism animal asks for its maintenance factor more food, not the full gene.
    local _, f1, hi = newPrice("BULL_ANGUS", 15, 1.75)
    local _, fBase = newPrice("BULL_ANGUS", 15, 1)
    local _, fOld = oldPrice("BULL_ANGUS", 15, 1.75)
    check(string.format("feed: a 1.75 bull asks for %.0f%% of an average one's food (the old rule %.0f%%)", f1 / fBase * 100, fOld / fBase * 100),
        math.abs(f1 / fBase - 1.15) < 0.02 and fOld / fBase > 1.7 and hi:getIntakeGene() == 1.15)

    -- Underweight: below underweightRatio of its curve, not of the old minWeight rule.
    local thin = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
    local threshold = G.getUnderweightThreshold(thin)
    thin.weight = threshold * 0.9
    thin.health = 80
    thin:applyUnderweightPenalty()
    local fine = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
    fine.health = 80
    fine:applyUnderweightPenalty()
    check(string.format("underweight: a bull below %.0f%% of its curve (%.0f kg at 12 months) loses health, one on its curve none",
        settings.underweightRatio * 100, threshold), thin.health < 80 and fine.health == 80
        and near(threshold, settings.underweightRatio * G.getCurve(thin):value(12), 1e-9))
end


-- Hof Bergmann's MILKCOW: a stand-in on the Holstein female curve, where it is an individual -----

do
    local MILKCOW_TYPE = 77
    local getType = g_currentMission.animalSystem.getTypeByIndex
    g_currentMission.animalSystem.getTypeByIndex = function(system, index)
        if index == MILKCOW_TYPE then return { name = "MILKCOW" } end
        return getType(system, index)
    end
    local _, milkSub = GrowthSim.addSubType("MILK_COW", "MILK_COW", "female", 432, "COW_HOLSTEIN", MILKCOW_TYPE)
    milkSub.rlWeightFieldsGiven = false
    G.resetCaches()
    local binding, resolution = G.getBinding(milkSub)
    check("milkcow: the MILKCOW type resolves to the Holstein female curve as a stand-in (its own breed name is not read)",
        resolution == "PROXY" and binding.profile == "HOLSTEIN" and binding.sex == "female")

    local cow = GrowthSim.makeAnimal("MILK_COW", { age = 30, weight = 400 })
    cow.animalTypeIndex = MILKCOW_TYPE
    cow.output.milk = 250 / 24
    local pen = GrowthSim.makePen({ cow })
    cow.clusterSystem = { owner = pen }
    local before = cow.weight
    local state = G.ensureState(cow)
    check(string.format("milkcow: an individual MILKCOW keeps its weight (%.0f kg) and grows on the Holstein curve from it (development %.1f months; adult %.0f kg, not the subtype's fallback 432)",
        before, state.developmentMonths, cow.targetWeight), cow.weight == before and state.developmentMonths < 30 and cow.targetWeight == 730)
    GrowthSim.months(pen, "TMR", 2)
    check(string.format("milkcow: its budget counts the milk it gives (read only, %.0f l a period) and it keeps growing toward the curve (%.0f kg)",
        250, cow.weight), cow.weight > before and RLBodyCondition.isEligible(cow) == false and cow.rlMilkPaid ~= nil)

    local cluster = GrowthSim.makeAnimal("MILK_COW", { age = 30, weight = 400 })
    cluster.isIndividual = nil
    check("milkcow: held as a vanilla cluster it is not covered: the adapter does nothing", not G.covers(cluster))

    local bindingConfig = G.getConfig().bindings.MILKCOW
    bindingConfig.enabled = false
    G.resetCaches()
    local offBinding, offResolution = G.getBinding(milkSub)
    bindingConfig.enabled = true
    G.resetCaches()
    check("milkcow: with its binding off the type is not covered", offBinding == nil and offResolution == "NOT_COVERED")

    local record = RLWeightProfiles.describe(milkSub)
    check("milkcow: the report lists it as a stand-in and what the game offers for it (no weights in its file, no reproduction)",
        record.resolution == "PROXY" and record.capability.weightFields == false and record.capability.reproduction == false
        and record.curve.adultKg == 730)
    g_currentMission.animalSystem.getTypeByIndex = getType
end


-- The hourly update routes covered cattle to v2 and nothing else ------------------------------------

do
    loadMod("scripts/animal/AnimalHealth.lua")
    local calls = 0
    local function routed(animal)
        local sub = animal:getSubType()
        sub.healthThresholdFactor, sub.healthIncreaseHour, sub.healthDecreaseHour = 0.5, 1, 1
        animal.updateWeight = function() calls = calls + 1 end
        local pen = GrowthSim.makePen({ animal })
        animal.clusterSystem = { owner = pen }
        GrowthSim.refreshRequest(animal)
        GrowthSim.advanceHour()
        GrowthSim.feed(pen, GrowthSim.RATIONS.TMR)
        local before = animal.weight
        AnimalHealth.updateHealth(animal, 1)
        return animal.weight - before
    end
    calls = 0
    local gain = routed(GrowthSim.makeAnimal("BULL_ANGUS", { age = 3 }))
    local v2Calls = calls
    local legacy = GrowthSim.makeAnimal("BULL_ANGUS", { age = 3 })
    legacy.isIndividual = nil
    calls = 0
    routed(legacy)
    check(string.format("routing: a covered calf takes the v2 step (+%.2f kg) and never the old weight rule; an uncovered one the old rule",
        gain), gain > 0 and v2Calls == 0 and calls == 1)
end


-- Calibration through the game adapter ---------------------------------------------------------------

do
    -- Bulls from birth on TMR reach their slaughter reference when their curve does, finished.
    local agesOk, finishOk, details = true, true, {}
    for _, name in ipairs(Economics.BULLS) do
        local _, sub = Economics.find(name)
        local reference = Economics.reference(sub)
        local curveMonths = G.getNominalCurve(G.getBinding(sub)):inverse(reference)
        local months, bull = GrowthSim.raise(name, "TMR", function(a) return a.weight >= reference end, 60)
        local score = RLBodyCondition.getFinishScore(bull)
        details[#details + 1] = string.format("%s %.1f/%.1f F%.0f", name:gsub("BULL_", ""), curveMonths, months, score)
        if math.abs(months - curveMonths) > 0.5 then agesOk = false end
        if score < 65 or score > 80 or RLBodyCondition.getYieldFactor(bull) ~= 1 then finishOk = false end
    end
    check("calibration: every bull on TMR from birth reaches its slaughter reference within 0.5 months of its curve ("
        .. table.concat(details, ", ") .. ")", agesOk)
    check("calibration: and arrives in the moderate finish band (yield factor 1)", finishOk)

    local _, angus = Economics.find("BULL_ANGUS")
    local reference = Economics.reference(angus)
    local tmr = GrowthSim.raise("BULL_ANGUS", "TMR", function(a) return a.weight >= reference end, 90)
    local silage = GrowthSim.raise("BULL_ANGUS", "silage", function(a) return a.weight >= reference end, 90)
    local hay = GrowthSim.raise("BULL_ANGUS", "hay", function(a) return a.weight >= reference end, 90)
    local grass, grassBull = GrowthSim.raise("BULL_HIGHLAND_CATTLE", "grass", function(a) return a.weight >= Economics.reference(a:getSubType()) end, 90)
    check(string.format("calibration: forage takes longer, never stalls (Angus TMR %.1f, silage %.1f, hay %.1f months; Highland on grass %.1f, F%.0f)",
        tmr, silage, hay, grass, RLBodyCondition.getFinishScore(grassBull)), tmr < silage and silage < hay and hay < 40
        and grass < 40 and RLBodyCondition.getFinishScore(grassBull) >= 65)
end

do
    local function lactationFactor(m) if m >= 10 then return 0 end if m <= 3 then return 0.8 + m / 6 end return 0.8 + (11 - m) / 15 end
    --- Three calvings 13 months apart: lactating 10 months on `lactRation`, dry 3 on `dryRation`.
    local function dairy(name, productivity, lactRation, dryRation)
        local cow, sub = GrowthSim.makeAnimal(name, { age = 48, isParent = true, genetics = { metabolism = 1, quality = 1,
            productivity = productivity, fertility = 1, health = 1 } })
        cow.weight = cow.targetWeight
        local pen = GrowthSim.makePen({ cow })
        cow.clusterSystem = { owner = pen }
        cow.bodyCondition = RLBodyCondition.createState(cow, "test")
        local potential, given, minBCS, maxBCS, calving = 0, 0, 5, 1, nil
        for cycle = 1, 3 do
            for m = 0, 12 do
                cow.monthsSinceLastBirth, cow.isLactating, cow.isPregnant = m, m < 10, m >= 3
                cow.reproduction = m >= 3 and (m - 3) * 10 or 0
                cow.pregnancy = m >= 3 and { pregnancies = { {} } } or nil
                if m == 0 then calving = RLBodyCondition.getBCS(cow) end
                for _ = 1, 24 do
                    GrowthSim.penHour(pen, cow.isLactating and lactRation or dryRation)
                    if cycle == 3 then
                        local paid = cow.rlMilkPaid
                        given = given + ((paid ~= nil and paid.tick == RLBodyCondition.getTickId()) and paid.litersPerHour or 0)
                        potential = potential + Economics.curve(sub.milk, cow.age) * lactationFactor(m) * productivity / 24
                    end
                end
                if cycle == 3 then
                    minBCS = math.min(minBCS, RLBodyCondition.getBCS(cow)); maxBCS = math.max(maxBCS, RLBodyCondition.getBCS(cow))
                end
            end
        end
        return given / potential, minBCS, maxBCS, calving
    end
    for _, name in ipairs({ "COW_HOLSTEIN", "COW_SWISS_BROWN" }) do
        local share, low, high, calving = dairy(name, 1, "TMR", "hay")
        check(string.format("dairy: %s on TMR, dry on hay: %.1f%% of the milk, BCS %.2f..%.2f, %.2f at calving (as before v2)",
            name, share * 100, low, high, calving), share >= 0.95 and low >= 2.0 and high < 4.0 and calving >= 2.9 and calving <= 3.6)
    end
    local high, low = dairy("COW_HOLSTEIN", 1.75, "TMR", "hay")
    local silage, silageLow = dairy("COW_HOLSTEIN", 1, "silage", "hay")
    check(string.format("dairy: a 1.75 cow runs thin (BCS %.2f) and on silage a cow gives less milk (%.0f%%) and stops at BCS ~2.2 (%.2f)",
        low, silage * 100, silageLow), low < 2.6 and silage < 0.95 and silage > 0.75 and silageLow >= 2.1 and high > 0.7)
    local share, gLow, _, gCalving = dairy("COW_HIGHLAND_CATTLE", 1, "grass", "grass")
    check(string.format("suckler: a Highland herd on grass keeps BCS %.2f (calving %.2f), %.0f%% of its milk", gLow, gCalving, share * 100),
        gLow >= 2.2 and gCalving >= 2.4 and share > 0.7)
end

do
    -- Heifers from birth on TMR: the AHDB targets the female curves were built on.
    local months, heifer = GrowthSim.raise("COW_HOLSTEIN", "TMR", function(a) return a.age >= 14 end, 14)
    local at14 = heifer.weight
    check(string.format("calibration: a Holstein heifer on TMR weighs %.0f kg at 14 months, 55%% of the cow's %.0f (AHDB breeding target)",
        at14, heifer.targetWeight), math.abs(at14 / 730 - 0.55) < 0.04)
end


-- Report ---------------------------------------------------------------------------------------------

do
    local longest = 0
    for _, sub in ipairs(Economics.subTypes) do
        if sub.typeName == "COW" then
            local record = RLWeightProfiles.describe(sub)
            local line = RLWeightProfiles.emit(record)
            longest = math.max(longest, #line)
        end
    end
    local record = RLWeightProfiles.describe(select(2, Economics.find("BULL_ANGUS")))
    check(string.format("report: each cattle subtype's record carries its v2 curve (Angus bull adult %s kg, birth %s kg, plateau at %s months), one log line each (longest %d)",
        tostring(record.curve.adultKg), tostring(record.curve.birthKg), tostring(record.curve.plateauMonth), longest),
        record.curve.active and record.curve.adultKg == 1000 and record.curve.plateauMonth == 60 and #record.curve.knots == 8
        and longest < RLPenLog.MAX_LINE)
end

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
