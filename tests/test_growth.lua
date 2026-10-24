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
    check("config: knots must rise in month and in kg (a flat stretch would hold development there), birth above 0",
        RLWeightProfiles.parseKnots("3:100 6:90", 40) == nil and RLWeightProfiles.parseKnots("6:100 3:120", 40) == nil
        and RLWeightProfiles.parseKnots("3:100 6:100", 40) == nil and RLWeightProfiles.parseKnots("3:100", 0) == nil
        and RLWeightProfiles.parseKnots("3:100 6:200", 40) ~= nil and RLWeightProfiles.parseKnots("3:x", 40) == nil)
    local profileXml = {
        iterate = function(_, key, fn) if key == "weightProfiles.profile" then fn(0, "p0") end end,
        getString = function(_, key, default)
            local values = { ["p0#name"] = "testbreed", ["p0.female#knots"] = "3:100 60:500", ["p0.male#knots"] = "3:110 60:700" }
            return values[key] or default
        end,
        getFloat = function(_, key, default)
            local values = { ["p0#birthFemaleKg"] = 30, ["p0#maleBirthFactor"] = 0 }
            if values[key] ~= nil then return values[key] end
            return default
        end,
        getBool = function(_, _, default) return default end,
    }
    local logBefore = #LOG
    local parsedProfile = RLWeightProfiles.parse(profileXml).profiles.TESTBREED
    while #LOG > logBefore do table.remove(LOG) end
    check("config: a profile's own maleBirthFactor of 0 makes the profile invalid (its animals keep the old rules)",
        parsedProfile.invalid ~= nil and parsedProfile.knots.male == nil)
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
        bull.rlGrowth.frameTargetKg, oldTarget), near(bull.rlGrowth.frameTargetKg, 1120, 1e-9) and near(bull.targetWeight, 1120, 1e-9)
        and oldTarget == 1300 and bull.rlGrowth.source == "generated" and bull.rlGrowth.legacyAnchor == nil)
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
        if du > 1 / 24 + 1e-6 then fasterThanCurve = true end
    end
    local lag = 24 - starved[24 * 24].u
    local lost = 6 - atEnd.u
    check(string.format("nutrition: fed again it grows on from its own development, no jump (largest hourly gain %.2f kg, frame %.2f; full feed %.2f, %.2f), no catch-up beyond its speed; %.2f months behind at 24 months (3 starved + %.2f of frame lost)",
        maxStep, maxFrame, fullMax, fullMaxFrame, lag, lost), maxFrame <= fullMaxFrame * (1 + 1e-6) and maxStep <= fullMax * 1.1
        and not fasterThanCurve and math.abs(lag - (3 + lost)) < 0.05)
    check(string.format("nutrition: on half its ration it grows, slower (%.0f kg at 24 months against %.0f on full feed)",
        half[24 * 24].weight, full[24 * 24].weight), half[24 * 24].weight < full[24 * 24].weight * 0.95
        and half[24 * 24].weight > half[6 * 24].weight and half[24 * 24].u < full[24 * 24].u)

    -- Frame and development never drift apart: an animal fed a changing share of its ration for five
    -- years, then fully, ends with exactly its adult frame, its development where its curve has its frame.
    local weight = curve:value(0)
    local _, reserveKg = M.split(weight, config.referenceReserve, kappa)
    local u, dt, worst = 0, 1 / 24, 0
    for step = 1, 140 * 24 do
        local share = 0.35 + 0.6 * (0.5 + 0.5 * math.sin(step / 37))
        local r = M.step({ dtMonths = dt, weight = weight, reserveKg = reserveKg, development = u, curve = curve, kappa = kappa,
            frameFloorKg = 10, speed = 1, intakeLiters = 100 * (step > 60 * 24 and 1.2 or share), referenceLiters = 100,
            intakeCapacity = 1, reserveCeiling = 0.45 }, config)
        weight, reserveKg, u = r.weight, r.reserveKg, r.development
        local frame = weight - reserveKg
        worst = math.max(worst, math.abs(curve:value(u) - frame * (1 + config.referenceReserve * kappa)))
    end
    local adultFrame = 1000 / (1 + config.referenceReserve * kappa)
    check(string.format("nutrition: frame and development stay together under a varying ration (largest gap %.2g kg) and the adult frame is reached exactly (%.6f / %.6f kg)",
        worst, weight - reserveKg, adultFrame), worst < 1e-6 and near(weight - reserveKg, adultFrame, 1e-6) and u == curve.endMonth)
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

    -- In multiplayer the server puts a client's payload copy into the target pen: it takes the live
    -- animal's state, anchor and last step's hour included, so it does not step again this hour.
    local payload = GrowthSim.makeAnimal("BULL_ANGUS", { age = 0 })
    payload.rlGrowth.lastTick = -1
    payload.weight = after - 3
    G.takeLiveState(payload, bull)
    payload.clusterSystem = { owner = GrowthSim.makePen({ payload }) }
    check("adapter: a moved payload copy takes the server animal's weight and state, and is not stepped twice in the hour",
        payload.weight == after and payload.rlGrowth ~= bull.rlGrowth and payload.rlGrowth.lastTick == bull.rlGrowth.lastTick
        and G.step(payload, 1) == true and payload.weight == after)

    -- Moved to a pen without a ledger in the same hour: done, no second step by any rule.
    bull.clusterSystem = { owner = GrowthSim.makePen() }
    check("adapter: an animal moved within the hour is not stepped again", RLGrowth.step(bull, 1) and bull.weight == after)
    bull.clusterSystem = { owner = pen }

    -- An hour without a ledger: the same budget, intake from the pen's food factor.
    GrowthSim.penHour(pen, "TMR", { noLedger = true })
    check("adapter: an hour without a feed ledger is still the v2 budget (intake from the food factor), never an old rule",
        bull.rlNutrition.intakeSource == "foodFactor" and bull.weight > after and bull.rlGrowth.lastTick == RLBodyCondition.getTickId())

    -- A lactating cow in an hour without a ledger: the milk stores keep the old rule all hour (the
    -- first store decided before the step), and her budget pays for the milk that rule deposited.
    local cow = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 40, isParent = true, isLactating = true, monthsSinceLastBirth = 2 })
    local cowPen = GrowthSim.makePen({ cow })
    cow.clusterSystem = { owner = cowPen }
    GrowthSim.penHour(cowPen, "TMR")
    local coveredWithLedger = RLBodyCondition.coversThisHour(cow)
    GrowthSim.penHour(cowPen, "TMR", { noLedger = true })
    local tick = RLBodyCondition.getTickId()
    check("milk: an hour without a ledger is the old milk rule for every store of that hour; with one, the budget's",
        coveredWithLedger and not RLBodyCondition.coversThisHour(cow, tick) and cow.rlGrowth.lastTick == tick
        and cow.bodyCondition.lastTick ~= tick and cow.rlMilkPaid.litersPerHour == 0 and cow.rlMilkPaid.deposited == true)
    local input = G.buildStepInput(cow, cow.rlGrowth, 100, 0.6, 1 / 24)
    check("milk: without a ledger the budget pays for the milk the old rule deposits (the food factor's share)",
        near(input.potentialMilk, cow.rlMilk.potential * 0.6, 1e-9))

    local yearling = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
    yearling.clusterSystem = { owner = GrowthSim.makePen({ yearling }) }
    check("adapter: the old budget step reports a covered animal as handled (the v2 step owns it), never the old weight rule",
        RLBodyCondition.step(yearling) == true and yearling.rlGrowth.lastTick == -1)

    check("adapter: the body condition mirrors the reserve as its index r = R / K",
        near(bull.bodyCondition.reserve, bull.rlGrowth.reserveMassKg / ((bull.weight - bull.rlGrowth.reserveMassKg) * G.getKappa()), 1e-9))

    local legacy = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
    legacy.isIndividual = nil
    check("adapter: a vanilla cluster (not an individual animal) is not covered", not G.covers(legacy) and G.covers(bull))
    local config2 = G.getConfig()
    config2.enabled = false
    local off = not G.covers(bull) and G.getTargetWeight(bull:getSubType(), bull.genetics) == nil
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
    -- An old savegame's animal grew on the old line, which at some ages is far from its new curve
    -- (a Highland bull at 24 months: 78%). Its price, food request and underweight check stay
    -- exactly where the old rules had them on load, and fade into its curve over migrationBlendMonths.
    local function legacyView(name, age, weight)
        local animal, sub = GrowthSim.makeAnimal(name, { age = age, weight = weight })
        animal.isIndividual = nil
        animal.targetWeight = G.getLegacyTarget(sub, 1)
        animal.rlGrowth = nil
        GrowthSim.refreshRequest(animal)
        return animal:getSellPrice(), animal.input.food
    end
    local _, sub = Economics.find("BULL_HIGHLAND_CATTLE")
    local oldWeight = G.getLegacyLine(sub, "male", 1, 24)
    local p0, f0 = legacyView("BULL_HIGHLAND_CATTLE", 24, oldWeight)
    local bull = GrowthSim.makeAnimal("BULL_HIGHLAND_CATTLE", { age = 24, weight = oldWeight })
    local state = G.ensureState(bull)
    GrowthSim.refreshRequest(bull)
    local p1, f1 = bull:getSellPrice(), bull.input.food
    local health = bull.health
    bull:applyUnderweightPenalty()
    check(string.format("migration: an old-line Highland bull (%.0f kg at 24 months, %.0f%% of its new curve, anchor %.3f) keeps its price (%.2f / %.2f) and food request (%.3f / %.3f) on load, and is not underweight",
        oldWeight, oldWeight / G.getCurve(bull):value(24) * 100, state.legacyAnchor, p1, p0, f1, f0),
        near(p1, p0, 1e-6) and near(f1, f0, 1e-9) and bull.health == health and state.legacyAnchor > 1.2)

    local pen = GrowthSim.makePen({ bull })
    bull.clusterSystem = { owner = pen }
    local lastPrice, maxStep = p1, 0
    for _ = 1, 14 do
        GrowthSim.months(pen, "TMR", 1)
        local price = bull:getSellPrice()
        maxStep = math.max(maxStep, math.abs(price / lastPrice - 1))
        lastPrice = price
    end
    check(string.format("migration: the anchor fades out within %d months (factor now %.3f), the price moving at most %.1f%% a month on the way",
        settings.migrationBlendMonths, G.getAnchorFactor(bull, bull.rlGrowth), maxStep * 100),
        G.getAnchorFactor(bull, bull.rlGrowth) == 1 and maxStep < 0.08)
    local lag = bull.age - bull.rlGrowth.developmentMonths
    local share = bull.weight / G.getCurve(bull):value(bull.age)
    check(string.format("migration: left behind its curve by the change of model, it caught up on full feed meanwhile (development %.1f at %d months, %.0f%% of its curve), not counted stunted",
        bull.rlGrowth.developmentMonths, bull.age, share * 100), lag < 0.6 and share > 0.97 and G.getMigrationCatchUp(bull, bull.rlGrowth) == 0)

    -- An old cow past her curve's plateau month catches up only what is left to the plateau.
    local oldCow = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 100, weight = 726 })
    local oldState = G.ensureState(oldCow)
    local expected = (G.getCurve(oldCow).endMonth - oldState.developmentMonths) / settings.migrationBlendMonths
    check(string.format("migration: past the plateau month the catch-up closes only the lag to the plateau (%.3f months a month)",
        G.getMigrationCatchUp(oldCow, oldState)), near(G.getMigrationCatchUp(oldCow, oldState), math.min(expected, G.CATCH_UP_MAX), 1e-9)
        and expected < G.CATCH_UP_MAX)

    -- Growth lost for want of feed, by contrast, never catches up (no anchor, no catch-up).
    local fed = GrowthSim.makeAnimal("BULL_HIGHLAND_CATTLE", { age = 12 })
    check("migration: a born or generated animal never catches up", G.getMigrationCatchUp(fed, fed.rlGrowth) == 0)

    -- A low-metabolism animal's request gene moves from the old m to the new maintenance factor.
    local low = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 30, weight = 600,
        genetics = { metabolism = 0.3, quality = 1, productivity = 1, fertility = 1, health = 1 } })
    G.ensureState(low)
    local atLoad = low:getIntakeGene()
    low.rlGrowth.anchorElapsedMonths = 12
    local later = low:getIntakeGene()
    check(string.format("migration: a 0.3-metabolism cow's food gene is the old %.2f on load and the new %.3f a year on, no jump",
        atLoad, later), near(atLoad, 0.3, 1e-12) and near(later, 1 + 0.15 * (0.3 - 1) / 0.75, 1e-12))

    local born = GrowthSim.newborn("BULL_HIGHLAND_CATTLE")
    check("migration: a newborn or a dealer's animal has no anchor", born.rlGrowth.legacyAnchor == nil
        and GrowthSim.makeAnimal("BULL_HIGHLAND_CATTLE", { age = 24 }).rlGrowth.legacyAnchor == nil)

    -- Read before it is taken over (a trailer, a client): what it would get is worked out again
    -- when its age moves on, so its take-over does not start fading before it happens.
    local waiting = GrowthSim.makeAnimal("BULL_HIGHLAND_CATTLE", { age = 24, weight = oldWeight })
    local peekAt24 = G.peekState(waiting)
    waiting.age = 25
    local peekAt25 = G.peekState(waiting)
    check("migration: an animal not yet taken over is read as taken over at its current age",
        peekAt24 ~= peekAt25 and peekAt25.anchorElapsedMonths == 0 and G.getAnchorRemaining(waiting, peekAt25) == 1
        and near(peekAt25.legacyAnchor, G.getCurve(waiting):value(25) / G.getLegacyLine(sub, "male", 1, 25), 1e-12)
        and waiting.rlGrowth == nil)

    -- The fade runs on the months its steps covered, not on its whole-month age: ageing on its
    -- birthday changes nothing.
    local fading = GrowthSim.makeAnimal("BULL_HIGHLAND_CATTLE", { age = 20, weight = G.getLegacyLine(sub, "male", 1, 20) })
    local fadingState = G.ensureState(fading)
    fadingState.anchorElapsedMonths = 3
    local before = G.getAnchorRemaining(fading, fadingState)
    fading.age = 21
    check("migration: a birthday does not step the fade (it counts the months the steps covered)",
        before == G.getAnchorRemaining(fading, fadingState) and before == 0.75)

    -- Saved with a state it cannot use: it grew under the model, so it is taken over again with
    -- no legacy anchor.
    local dropped = GrowthSim.makeAnimal("BULL_HIGHLAND_CATTLE", { age = 24, weight = oldWeight, rlGrowthDropped = true })
    check("migration: an animal whose saved state was unusable is taken over again without an anchor",
        G.ensureState(dropped).legacyAnchor == nil and dropped.rlGrowth.source == "rederived")

    -- Target weight: a high-metabolism bull's old target (x1.24) is what the slaughter reference,
    -- finishing and the slaughter-value floor read on load; it moves to the size gene's (x1.096).
    local genes = { metabolism = 1.6, quality = 1, productivity = 1, fertility = 1, health = 1 }
    local _, angus = Economics.find("BULL_ANGUS")
    local oldBull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 20, weight = G.getLegacyLine(angus, "male", 1.6, 20), genetics = genes })
    local loadTarget = oldBull.targetWeight
    local loadReference = AnimalMoveEvent.getCarcassReferenceWeight(oldBull, nil, oldBull.subTypeIndex)
    local bullPen = GrowthSim.makePen({ oldBull })
    oldBull.clusterSystem = { owner = bullPen }
    GrowthSim.months(bullPen, "TMR", 6)
    local midTarget = oldBull.targetWeight
    GrowthSim.months(bullPen, "TMR", 7)
    check(string.format("migration: a 1.6 bull's target weight is the old %.0f kg on load (slaughter reference %.0f), %.0f half way, the size gene's %.0f a year on",
        loadTarget, loadReference, midTarget, oldBull.targetWeight), near(loadTarget, 1240, 1e-9)
        and near(loadReference, 1240 * RLBreedTraits.resolve(AnimalMoveEvent.getCarcassConfig().layers, angus, "maleMaturity", 1), 1e-6)
        and midTarget < loadTarget and midTarget > 1096 and near(oldBull.targetWeight, 1000 * (1 + 0.12 * 0.6 / 0.75), 1e-9)
        and GrowthSim.makeAnimal("BULL_ANGUS", { age = 20, genetics = genes }).targetWeight == oldBull.targetWeight)

    -- Underweight: on load the old rule's threshold exactly.
    local heifer = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 24, weight = 500 })
    local _, holstein = Economics.find("COW_HOLSTEIN")
    check(string.format("migration: on load the underweight threshold is the old rule's (%.1f kg), not the curve's (%.1f)",
        G.getUnderweightThreshold(heifer), settings.underweightRatio * G.getCurve(heifer):value(24)),
        near(G.getUnderweightThreshold(heifer), G.getLegacyUnderweight(holstein, 24), 1e-9))
end

do
    -- Every cattle subtype, ages 0-60, genes 0.3-1.7, on the old line or 20% off it: on load the
    -- price and the food request are the old rules' exactly, nothing is NaN.
    local function legacy(name, age, metabolism, weight)
        local animal, sub = GrowthSim.makeAnimal(name, { age = age, weight = weight,
            genetics = { metabolism = metabolism, quality = 1, productivity = 1, fertility = 1, health = 1 } })
        animal.isIndividual = nil
        animal.targetWeight = G.getLegacyTarget(sub, metabolism)
        GrowthSim.refreshRequest(animal)
        return animal:getSellPrice(), animal.input.food
    end
    local cases, mismatches, bad = 0, {}, 0
    for _, sub in ipairs(Economics.subTypes) do
        if sub.typeName == "COW" and G.getBinding(sub) ~= nil then
            for _, age in ipairs({ 0, 1, 4, 9, 15, 22, 30, 45, 60 }) do
                for _, m in ipairs({ 0.3, 1, 1.7 }) do
                    for _, off in ipairs({ 0.8, 1, 1.2 }) do
                        local weight = math.max(G.getLegacyLine(sub, sub.gender, m, age) * off, 1)
                        local p0, f0 = legacy(sub.name, age, m, weight)
                        local animal = GrowthSim.makeAnimal(sub.name, { age = age, weight = weight,
                            genetics = { metabolism = m, quality = 1, productivity = 1, fertility = 1, health = 1 } })
                        local state = G.ensureState(animal)
                        GrowthSim.refreshRequest(animal)
                        local p1, f1 = animal:getSellPrice(), animal.input.food
                        cases = cases + 1
                        if state.developmentMonths ~= state.developmentMonths or p1 ~= p1 or f1 ~= f1 then bad = bad + 1 end
                        -- Anchors are bounded (0.5..2): far outside that the old values cannot be met.
                        local inBounds = state.legacyAnchor > G.ANCHOR_MIN and state.legacyAnchor < G.ANCHOR_MAX
                        if inBounds and (math.abs(p1 / p0 - 1) > 1e-9 or math.abs(f1 / f0 - 1) > 1e-9) then
                            mismatches[#mismatches + 1] = string.format("%s@%d m%.1f x%.1f %.1f/%.1f", sub.name, age, m, off, p1, p0)
                        end
                    end
                end
            end
        end
    end
    check(string.format("migration: %d old-save animals (every subtype, ages 0-60, genes 0.3-1.7, on and 20%% off the old line) load at the old price and food request exactly (%s)",
        cases, table.concat(mismatches, ", ")), #mismatches == 0 and bad == 0 and cases >= 14 * 81)

    local extremes = true
    for _, weight in ipairs({ 0.5, 1, 5000 }) do
        local animal = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12, weight = weight })
        local pen = GrowthSim.makePen({ animal })
        animal.clusterSystem = { owner = pen }
        GrowthSim.penHour(pen, "TMR")
        GrowthSim.penHour(pen, "none")
        local price = animal:getSellPrice()
        if animal.weight ~= animal.weight or animal.weight <= 0 or price ~= price
            or animal.rlGrowth.developmentMonths ~= animal.rlGrowth.developmentMonths then extremes = false end
    end
    check("migration: an absurd saved weight (0.5 kg, 5000 kg) steps and prices without NaN", extremes)
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

    -- An initial reserve off the reference one puts a newborn's development where its frame is.
    local savedInitial = config.initialReserve
    config.initialReserve = 0.30
    local offCalf = GrowthSim.makeAnimal("BULL_HOLSTEIN", { age = 0 })
    G.initBirth(offCalf, 48)
    local offFrame = offCalf.weight - offCalf.rlGrowth.reserveMassKg
    config.initialReserve = savedInitial
    check(string.format("birth: with an initial reserve off the reference one the newborn's development follows its frame (%.3f months)",
        offCalf.rlGrowth.developmentMonths), offCalf.rlGrowth.developmentMonths > 0
        and near(G.getCurve(offCalf):value(offCalf.rlGrowth.developmentMonths), offFrame * (1 + config.referenceReserve * G.getKappa()), 1e-6))

    local calf = GrowthSim.makeAnimal("BULL_HOLSTEIN", { age = 0, genetics = { metabolism = 1.5, quality = 1, productivity = 1, fertility = 1, health = 1 } })
    G.initBirth(calf, 39.5)
    check(string.format("birth: a newborn keeps its own draw (%.1f kg, not the mean), development 0, the neutral reserve, its adult weight from its genes (%.0f kg)",
        calf.weight, calf.targetWeight), calf.weight == 39.5 and calf.rlGrowth.birthWeightKg == 39.5
        and calf.rlGrowth.developmentMonths < 1e-9 and near(calf.targetWeight, 1100 * (1 + 0.12 * 0.5 / 0.75), 1e-9)
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
        setBool = function(_, k, v) store[k] = v end,
        getBool = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
    }
    local state = G.newState({ birthWeightKg = 41.2, frameTargetKg = 1043.5, developmentMonths = 13.25, reserveMassKg = 41.7,
        speedFactor = 0.95, intakeFactor = 1.07, weightKg = 512.25, ageMonths = 14.5, legacyAnchor = 1.25,
        anchorElapsedMonths = 9, source = "derived", lastTick = 4711 })
    G.saveToXMLFile(state, xml, "a")
    local loaded = G.loadFromXMLFile(xml, "a")
    local same = true
    for k, v in pairs(state) do if loaded[k] ~= v then same = false end end
    check("persistence: a saved state loads back unchanged (birth, adult, development, reserve mass, stage factors)", same)
    local none, noneSaved = G.loadFromXMLFile(xml, "b")
    check("persistence: an animal saved without a state loads none (it gets one from its weight)", none == nil and noneSaved == false)
    store["a.growth#reserveMassKg"] = -5
    local unusable, unusableSaved = G.loadFromXMLFile(xml, "a")
    check("persistence: an unusable state is dropped, not used, and said to have been there", unusable == nil and unusableSaved == true)
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
        and a.weightKg == 512.25 and a.ageMonths == 14.5 and a.legacyAnchor == 1.25 and a.anchorElapsedMonths == 9
        and b == nil and readAt == #stream)

    -- A streamed state is checked like a saved one: NaN or nonsense is dropped, an anchor bounded.
    stream, readAt = {}, 0
    local bad = G.copyState(state)
    bad.developmentMonths = 0 / 0
    G.writeStream(bad, 1)
    local wild = G.copyState(state)
    wild.legacyAnchor = 50
    G.writeStream(wild, 1)
    local droppedNaN, bounded = G.readStream(1), G.readStream(1)
    check("network: a streamed state with NaN is dropped, a wild anchor kept within its bounds",
        droppedNaN == nil and bounded.legacyAnchor == G.ANCHOR_MAX)

    -- A state from a client is kept within its animal's breed.
    local bought = GrowthSim.makeAnimal("BULL_ANGUS", { age = 13 })
    local wildState = G.copyState(state)
    wildState.frameTargetKg, wildState.birthWeightKg, wildState.speedFactor, wildState.developmentMonths = 1e5, 900, 1e4, 500
    G.sanitizeState(bought, wildState)
    check("network: a received state is kept within its breed (adult at most 2x, birth 3x, stage factors 3, development the curve)",
        wildState.frameTargetKg == 2000 and near(wildState.birthWeightKg, 32.11284 * 3, 1e-6) and wildState.speedFactor == 3
        and wildState.developmentMonths == 60)
    local clientState = G.copyState(state)
    clientState.anchorElapsedMonths = -1e30
    G.sanitizeState(bought, clientState, true)
    local serverState = G.copyState(state)
    serverState.anchorElapsedMonths = -1e30
    G.sanitizeState(bought, serverState, false)
    check("network: a legacy anchor a client sends is dropped; one from the server keeps its clock within the blend",
        clientState.legacyAnchor == nil and clientState.anchorElapsedMonths == nil
        and serverState.legacyAnchor == 1.25 and serverState.anchorElapsedMonths == 0)

    -- A state saved without the weight it was set for keeps its saved split on its first step.
    local noWeight = G.copyState(state)
    noWeight.weightKg = nil
    local holder = { weight = 600, rlGrowth = noWeight }
    check("persistence: a state without its weight on record keeps its saved development and reserve",
        G.resync(holder, noWeight) == false and noWeight.developmentMonths == 13.25 and noWeight.reserveMassKg == 41.7
        and noWeight.weightKg == 600)

    local copy = G.copyState(state)
    copy.reserveMassKg = 0
    check("clone: a copied state is a separate table", state.reserveMassKg == 41.7 and G.copyState(nil) == nil)

    -- Reloaded, its adult weight is the saved one, whatever the file says now.
    local reloaded = GrowthSim.makeAnimal("BULL_ANGUS", { age = 13, weight = 512.25, rlGrowth = G.copyState(state) })
    local fresh = GrowthSim.makeAnimal("BULL_ANGUS", { age = 13 })
    check("persistence: a reloaded animal keeps its saved adult weight (traceable), not one re-read from its gene",
        G.getCurve(reloaded).endWeight == 1043.5 and G.getCurve(fresh).endWeight == 1000 and reloaded.targetWeight == 1000)
end


do
    -- The hourly state event carries the v2 state to clients, also for a calf the old body
    -- condition did not cover and in an hour without a ledger.
    local stream, readAt = {}, 0
    local function w(_, v) stream[#stream + 1] = v end
    local function r() readAt = readAt + 1; return stream[readAt] end
    local saved = { streamWriteBool, streamWriteFloat32, streamWriteInt32, streamWriteUInt16, streamReadBool, streamReadFloat32,
        streamReadInt32, streamReadUInt16, NetworkUtil, RLAnimalUtil, streamWriteString, streamReadString, streamWriteUInt8, streamReadUInt8 }
    streamWriteBool, streamWriteFloat32, streamWriteInt32, streamWriteUInt16, streamWriteString, streamWriteUInt8 = w, w, w, w, w, w
    streamReadBool, streamReadFloat32, streamReadInt32, streamReadUInt16, streamReadString, streamReadUInt8 = r, r, r, r, r, r
    NetworkUtil = { writeNodeObject = function(_, object) stream[#stream + 1] = object end, readNodeObject = function() return r() end }
    RLAnimalUtil = {
        writeStreamIdentifiers = function(animal) stream[#stream + 1] = animal.uniqueId end,
        readStreamIdentifiers = function() return { uniqueId = r(), farmId = 1, country = 1 } end,
        find = function(animals, _, uniqueId) for _, a in ipairs(animals) do if a.uniqueId == uniqueId then return a end end end,
    }
    loadMod("scripts/events/RLBodyConditionStateEvent.lua")

    local calf = GrowthSim.newborn("BULL_ANGUS", { uniqueId = "9" })
    local serverPen = GrowthSim.makePen({ calf })
    calf.clusterSystem = { owner = serverPen }
    function serverPen:getClusters() return { calf } end
    GrowthSim.months(serverPen, "TMR", 1)
    GrowthSim.penHour(serverPen, "TMR", { noLedger = true })
    RLBodyConditionStateEvent.new(serverPen, RLBodyCondition.getTickId()):writeStream(1)

    local clientCalf = GrowthSim.newborn("BULL_ANGUS", { uniqueId = "9" })
    local clientPen = GrowthSim.makePen()
    function clientPen:getClusterSystem() return { animals = { clientCalf } } end
    stream[1] = clientPen
    local savedServer = g_server
    g_server = nil
    RLBodyConditionStateEvent.emptyNew():readStream(1, makeConnection(1, true))
    g_server = savedServer
    check("network: the hourly event gives a client the server's v2 state (development, reserve kg, age clock) and the hour, also for a calf in an hour without a ledger",
        clientCalf.weight == calf.weight and clientCalf.rlGrowth.developmentMonths == calf.rlGrowth.developmentMonths
        and clientCalf.rlGrowth.reserveMassKg == calf.rlGrowth.reserveMassKg and clientCalf.rlGrowth.ageMonths == calf.rlGrowth.ageMonths
        and clientCalf.rlNutrition.tick == RLBodyCondition.getTickId() and clientCalf.targetWeight == calf.targetWeight
        and readAt == #stream)
    streamWriteBool, streamWriteFloat32, streamWriteInt32, streamWriteUInt16, streamReadBool, streamReadFloat32,
        streamReadInt32, streamReadUInt16, NetworkUtil, RLAnimalUtil, streamWriteString, streamReadString, streamWriteUInt8,
        streamReadUInt8 = table.unpack(saved, 1, 14)
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
        pack.weight, pack.rlGrowth.frameTargetKg, oldPack.weight), near(pack:getSellPrice(), oldPack:getSellPrice(), 1e-6)
        and pack.rlGrowth.frameTargetKg == 1260)
    check(string.format("target: a pack bull grows to the design's %.0f kg, its target weight stays the pack's %.0f (slaughter reference %.1f kg, the design's arrival 790 kg at 20 months)",
        pack.rlGrowth.frameTargetKg, pack.targetWeight, pack.targetWeight * 0.75), pack.targetWeight == 1050
        and near(G.getCurve(pack):value(20), 790, 1e-9))

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

    -- Growth that fell behind does not catch up; a calf starved three months and fed again is not
    -- counted underweight for it.
    local calf = GrowthSim.newborn("BULL_ANGUS")
    local calfPen = GrowthSim.makePen({ calf })
    calf.clusterSystem = { owner = calfPen }
    GrowthSim.months(calfPen, "TMR", 3)
    GrowthSim.months(calfPen, "none", 3)
    GrowthSim.months(calfPen, "TMR", 6)
    local share = calf.weight / G.getCurve(calf):value(calf.age)
    calf.health = 80
    calf:applyUnderweightPenalty()
    check(string.format("underweight: a calf starved three months then fed is behind its curve for good (%.0f%% at %d months) but not underweight",
        share * 100, calf.age), share < 0.8 and calf.health == 80)

    -- A covered subtype with no old growth line (no mature age): the price reads the weight itself.
    local _, flat = GrowthSim.addSubType("COW_FLATLINE", "HOLSTEIN", "female", 650, "COW_HOLSTEIN")
    flat.reproductionMinAgeMonth = 0
    local flatCow = GrowthSim.makeAnimal("COW_FLATLINE", { age = 30, weight = 512 })
    local weightForPrice = G.getPriceWeight(flatCow, flat)
    local state = G.ensureState(flatCow)
    check("price: a covered subtype without an old growth line is priced on its weight, its anchor 1",
        weightForPrice == 512 and state.legacyAnchor == 1)
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
    local priceBefore = (function()
        local legacy = GrowthSim.makeAnimal("MILK_COW", { age = 30, weight = 400 })
        legacy.isIndividual, legacy.animalTypeIndex, legacy.targetWeight = nil, MILKCOW_TYPE, 432
        return legacy:getSellPrice()
    end)()
    local state = G.ensureState(cow)
    check(string.format("milkcow: an individual MILKCOW keeps its weight (%.0f kg) and grows on the Holstein curve from it (development %.1f months, adult %.0f kg); its target weight stays the subtype's (%.0f)",
        before, state.developmentMonths, state.frameTargetKg, cow.targetWeight), cow.weight == before and state.developmentMonths < 30
        and state.frameTargetKg == 730 and cow.targetWeight == 432)
    local health = cow.health
    cow:applyUnderweightPenalty()
    check(string.format("milkcow: taken over, its price stays where the old rules had it (%.1f / %.1f) and its underweight check is the old rule's, not the Holstein curve's",
        cow:getSellPrice(), priceBefore), near(cow:getSellPrice(), priceBefore, 1e-6) and cow.health == health
        and near(G.getUnderweightThreshold(cow), G.getLegacyUnderweight(milkSub, 30), 1e-9))
    GrowthSim.months(pen, "TMR", 2)
    check(string.format("milkcow: its budget counts the milk it gives (read only, %.0f l a period) and it keeps growing toward the curve (%.0f kg)",
        250, cow.weight), cow.weight > before and RLBodyCondition.isEligible(cow) == false and cow.rlMilkPaid ~= nil)

    -- Milk as cans from a pallet barn counts too.
    milkSub.output = { pallets = { fillType = 99 } }
    local isPallet = Animal.isLactationPalletFillType
    Animal.isLactationPalletFillType = function(fillType) return fillType == 99 end
    local canCow = GrowthSim.makeAnimal("MILK_COW", { age = 30, weight = 500 })
    canCow.animalTypeIndex = MILKCOW_TYPE
    canCow.output = { pallets = 6 }
    local canInput = G.buildStepInput(canCow, G.ensureState(canCow), 100, 1, 1 / 24)
    Animal.isLactationPalletFillType = isPallet
    milkSub.output = nil
    check("milkcow: milk it gives as cans from a pallet barn is read into its budget too",
        near(canInput.potentialMilk, 6 * 24, 1e-9))

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
    check(string.format("routing: a covered calf outside a pen running the unified model is held (%+.2f kg), never the old weight rule; an uncovered one the old rule",
        gain), gain == 0 and v2Calls == 0 and calls == 1)

    -- No game hour to count a step in: a covered animal is held too (no old rule, no target).
    local strong = GrowthSim.makeAnimal("BULL_ANGUS", { age = 3, genetics = { metabolism = 1.5, quality = 1, productivity = 1, fertility = 1, health = 1 } })
    local usedTarget
    local sub = strong:getSubType()
    sub.healthThresholdFactor, sub.healthIncreaseHour, sub.healthDecreaseHour = 0.5, 1, 1
    strong.updateWeight = function(_, _, target) usedTarget = target end
    local day = GrowthSim.env.currentMonotonicDay
    GrowthSim.env.currentMonotonicDay = nil
    AnimalHealth.updateHealth(strong, 1)
    GrowthSim.env.currentMonotonicDay = day
    check("routing: with no game hour a covered animal is held - the old rule never runs", usedTarget == nil)
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

    -- fixedFeedPrice under v2: a liter priced by an average animal on its breed's curve at this
    -- one's age. TMR bulls finish in the same month; slow forage still falls far behind (off).
    config.fixedFeedPrice = true
    local fixedTmr = GrowthSim.raise("BULL_ANGUS", "TMR", function(a) return a.weight >= reference end, 90)
    local fixedHay = GrowthSim.raise("BULL_ANGUS", "hay", function(a) return a.weight >= reference end, 90)
    config.fixedFeedPrice = false
    check(string.format("calibration: with fixedFeedPrice an Angus on TMR finishes as without (%.1f / %.1f months), on hay much later (%.1f / %.1f): it stays off",
        fixedTmr, tmr, fixedHay, hay), math.abs(fixedTmr - tmr) < 0.2 and fixedHay > hay + 5)
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

do
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 8 })
    bull.rlGrowth.frameTargetKg = 1234.5
    local plain = { targetWeight = 321, isIndividual = false }
    check(string.format("display target: a covered animal shows its curve plateau (%s kg, target %s kg), any other its target weight",
        tostring(G.getDisplayTarget(bull)), tostring(bull.targetWeight)),
        G.getDisplayTarget(bull) == 1234.5 and bull.targetWeight ~= 1234.5
        and G.getDisplayTarget(plain) == 321 and G.getDisplayTarget(nil) == nil)
end

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
