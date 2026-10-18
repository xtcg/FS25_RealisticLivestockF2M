-- Sheep S5 calibration scenarios: the inputs and the order each group runs them in, on the library
-- (tests/sheepcalib.lua). tests/sheepcalib.py runs every group in a Lua state of its own (no
-- configuration change or energy cache carries from one to the next) and sets CALIB_GROUP.
--   main: the history (the scenarios as they ran before, in their order: their trajectories must
--         not change) and then the newer ones.

SheepCalibScenarios = {}

local FILL = FeedSim.FILL
local reference, fatClass, litersPerKgFresh = SheepCalib.reference, SheepCalib.fatClass, SheepCalib.litersPerKgFresh
local raiseWithDam, storeLambs, eweYear = SheepCalib.raiseWithDam, SheepCalib.storeLambs, SheepCalib.eweYear
local GRASS, INTENSIVE, HOUSED = SheepCalib.GRASS, SheepCalib.INTENSIVE, SheepCalib.HOUSED

--- The history, in the order it always ran.
function SheepCalibScenarios.main()
    -- R1 / V1: early lambs, creep then ad lib concentrate; lowland and terminal breeds; singles and twins.
    for _, breed in ipairs({ "LANDRACE", "TEXEL", "SUFFOLK", "SWISS_MOUNTAIN" }) do
        for _, litter in ipairs({ 1, 2 }) do
            local lambs, ewe, pool = raiseWithDam(breed, litter, INTENSIVE, { maxMonths = 6 })
            CALIB["R1/" .. breed .. "/" .. litter] = { lambs = lambs, ewe = ewe, milkPool = pool }
        end
    end
    -- R2 / V2: grass and milk only.
    for _, breed in ipairs({ "LANDRACE", "TEXEL", "STEINSCHAF", "BLACK_WELSH", "BLACKFACE" }) do
        for _, litter in ipairs({ 1, 2 }) do
            local lambs, ewe, pool = raiseWithDam(breed, litter, GRASS, { maxMonths = 9 })
            CALIB["R2/" .. breed .. "/" .. litter] = { lambs = lambs, ewe = ewe, milkPool = pool }
        end
    end
    -- R3 / V3: weaned ram lambs on a fixed grass allowance (Teagasc's autumn grazing: the sward, not
    -- the lamb, limits grass; GRASS_ALLOWANCE kg DM a head a day, set so grass alone gives about the
    -- trial's 114 g) with 0 / 0.25 / 0.5 kg fresh barley a head a day; and on unlimited grass.
    local GRASS_ALLOWANCE = 0.95
    for _, kg in ipairs({ 0, 0.25, 0.5 }) do
        local barley = kg * litersPerKgFresh("BARLEY") * 1.25
        local p = RLFeedProfiles.getUsableFeed("GRASS_WINDROW")
        local grass = GRASS_ALLOWANCE / (p.dm) * litersPerKgFresh("GRASS_WINDROW") * 1.25
        local refill = function(pen) pen:add("BARLEY", barley * #pen.animals); pen:add("GRASS_WINDROW", grass * #pen.animals) end
        CALIB["R3/" .. kg] = { lambs = storeLambs("LANDRACE", { "male", "male" }, {}, 42, { refill = refill, age = 4, weight = 30 }) }
    end
    CALIB["R3/grassAdLib"] = { lambs = storeLambs("LANDRACE", { "male" }, GRASS, 42, { age = 4, weight = 30 }) }
    -- R4 / V4 / V6: housed store lambs, silage and ad lib concentrate; rams, wethers and ewe lambs.
    CALIB["R4"] = { lambs = storeLambs("LANDRACE", { "male", "wether", "female" }, HOUSED, 60, { age = 5, weight = 32 }) }
    -- V5: kept on ad lib concentrate past the reference.
    CALIB["V5"] = { lambs = storeLambs("LANDRACE", { "male", "female" }, HOUSED, 120, { age = 5, weight = 32 }) }

    -- Ewe cycle: twins on grass to weaning, then dry on grass.
    do
        local _, eweLog = raiseWithDam("LANDRACE", 2, GRASS, { maxMonths = 6 })
        CALIB["EWE/grass/twins"] = { ewe = eweLog }
    end

    -- The year as fed so far (AUTO, grass and the housed silage): the D6 gates.
    CALIB["EWE/year/twins"] = eweYear()

    -- Feeding control (cause diagnosis, never gates; S5 checklist F.4). The adjusted plans are fixed
    -- here from AHDB "Feeding the ewe" before they were first run, and not tuned to any BCS:
    --   L, lactation supplement: Table 32's 70 kg ewe rearing twins at three weeks gets 1 kg of an
    --     18% CP compound a day where grass is short ("supplementation becomes the practical
    --     management tool in early lactation"); the game's nearest is 0.5 kg barley + 0.5 kg peas
    --     (CP 12% / 24%: 18%), in the trough for the first two months of lactation, grass ad lib;
    --   R, recovery: weaning to mating "offer best grazing to ewes with lowest BCS", leaner ewes eat
    --     up to 30% more; the game's lever is the pen's target: FINISH (eat freely; AUTO grows a dry
    --     ewe back to the reference reserve, BCS 3, and no further) on the same grass;
    --   L+R both. Baseline and controls run the same code and the same ewe.
    CALIB["EWE/control/L lactation supplement"] = eweYear({ lactationConc = { BARLEY = 0.5, PEA = 0.5 }, lactationConcMonths = 2 })
    CALIB["EWE/control/R recovery free intake"] = eweYear({ recoveryTarget = "FINISH" })
    CALIB["EWE/control/L+R"] = eweYear({ lactationConc = { BARLEY = 0.5, PEA = 0.5 }, lactationConcMonths = 2, recoveryTarget = "FINISH" })

    -- Energy against AHDB Feeding the ewe (AFRC 1993), at the tables' own weights. Table 8: housed
    -- pregnant ewes, ME MJ a day, by live weight, litter and weeks to lambing (a diet of 11 MJ/kg DM,
    -- no weight loss). The model's requirement: maintenance + pregnancy of RLFeed.describeAnimal for a
    -- Landrace ewe of that weight without her gravid mass, at the pregnancy's progress 1 - weeks x 7 /
    -- 150 days. Table 29's lactation rows are a linear sum in the model (maintenance x W^0.75 +
    -- meMJPerKg x milk - reserveMobilizeMEPerKg x loss), so they are worked out in the judge from the
    -- config values printed here; one nursing ewe checks that sum against describeAnimal.
    do
        GrowthSim.setDaysPerPeriod(1)
        local days = RLFeed.getConfig().realDaysPerPeriod
        local _, ramSub = Economics.find("RAM_LANDRACE")
        -- The model's maintenance and pregnancy (MJ a day) of a Landrace ewe of w kg without her lambs,
        -- n lambs, at a pregnancy progress (0..1).
        local function need(w, n, progress)
            local ewe = SheepSim.ewe("SHEEP_LANDRACE", "T8")
            SheepSim.makePen({ ewe })
            local pregnancies = {}
            for i = 1, n do pregnancies[i] = { getSubType = function() return ramSub end } end
            ewe.isPregnant, ewe.pregnancy, ewe.reproduction = n > 0, n > 0 and { pregnancies = pregnancies } or nil, 100 * progress
            ewe.rlGrowth, ewe.rlGrowthPeek = nil, nil
            ewe.weight = w + RLGrowth.getGravidTarget(ewe)
            local a = RLFeed.describeAnimal(ewe, { target = "AUTO" }, 0.25 / days, 0.25)
            return a.needs.maintenance + a.needs.pregnancy, a.needs.maintenance, a.needs.pregnancy
        end
        local function weeksToProgress(weeks) return 1 - weeks * 7 / 150 end
        local function grid()
            local cells = {}
            for _, w in ipairs({ 50, 60, 70, 80 }) do
                for _, n in ipairs({ 1, 2, 3 }) do
                    for _, weeks in ipairs({ 7, 5, 3, 1 }) do
                        local total, maintenance, pregnancy = need(w, n, weeksToProgress(weeks))
                        cells[#cells + 1] = { w = w, n = n, weeks = weeks, model = total, maintenance = maintenance, pregnancy = pregnancy }
                    end
                end
            end
            return cells
        end
        -- New check points between the table's: 55 / 65 / 75 kg and 6 / 4 / 2 weeks (the judge
        -- interpolates the table there; triplets only at 75 kg, the table having 70 and 80).
        local function between()
            local cells = {}
            for _, w in ipairs({ 55, 65, 75 }) do
                for _, n in ipairs({ 1, 2, 3 }) do
                    if n < 3 or w == 75 then
                        for _, weeks in ipairs({ 6, 4, 2 }) do
                            cells[#cells + 1] = { w = w, n = n, weeks = weeks, model = need(w, n, weeksToProgress(weeks)) }
                        end
                    end
                end
            end
            return cells
        end
        -- Through the pregnancy at 70 kg: every 1% of progress, per litter (continuity, no negative cost).
        local function series()
            local out = {}
            for _, n in ipairs({ 1, 2, 3 }) do
                local row = {}
                for i = 0, 100 do
                    local total, _, pregnancy = need(70, n, i / 100)
                    row[#row + 1] = { total, pregnancy }
                end
                out[n] = row
            end
            return out
        end
        local probe = SheepSim.ewe("SHEEP_LANDRACE", "T8c")
        SheepSim.makePen({ probe })
        local cfg = RLFeed.getEnergyConfig(probe)
        local shipped = cfg.pregnancyThirdLambFactor
        local cells, betweenCells, curve = grid(), between(), series()
        -- The previous model (every lamb at 0.55), kept for comparison.
        cfg.pregnancyThirdLambFactor = nil
        local oldCells, oldBetween = grid(), between()
        cfg.pregnancyThirdLambFactor = shipped
        local nonPregnant = need(70, 0, 0)
        local sheep = RLFeedProfiles.getConfig().species.SHEEP
        -- One nursing ewe (twins, first month: Table 28's 3.0 kg): describeAnimal's maintenance + milk.
        local ewe = SheepSim.ewe("SHEEP_LANDRACE", "T29")
        local pen = SheepSim.makePen({ ewe, SheepSim.lamb("RAM_LANDRACE", "T29", "T29a"), SheepSim.lamb("SHEEP_LANDRACE", "T29", "T29b") })
        FeedSim.hour(pen)
        ewe.rlGrowth, ewe.rlGrowthPeek = nil, nil
        ewe.weight = 70
        local a = RLFeed.describeAnimal(ewe, { target = "AUTO" }, 0.25 / days, 0.25)
        CALIB["ENERGY"] = { table8 = cells, table8Old = oldCells, between = betweenCells, betweenOld = oldBetween, series = curve,
            nonPregnant70 = nonPregnant, thirdLambFactor = shipped, maintenancePerKgMetabolic = sheep.requirements.maintenanceMEPerKgMetabolic,
            pregnancyFactor = sheep.requirements.pregnancyFactor, milkMePerKg = sheep.milk.meMJPerKg,
            mobilizePerKg = sheep.requirements.reserveMobilizeMEPerKg, depositPerKg = sheep.requirements.reserveDepositMEPerKg,
            nursing70 = { weight = 70, milk = RLFeed.getDamMilk(ewe), model = a.needs.maintenance + a.needs.milk } }
    end

    -- Ewe late pregnancy: the last two of five months on hay, silage, silage and barley; single, twins.
    do
        GrowthSim.setDaysPerPeriod(1)
        local _, ramSub = Economics.find("RAM_LANDRACE")
        local stocks = { hay = { DRYGRASS_WINDROW = 4000 }, silage = { SILAGE = 4000 }, silageBarley = { SILAGE = 4000, BARLEY = 4000 } }
        for name, stock in pairs(stocks) do
            for _, n in ipairs({ 1, 2 }) do
                local ewe = SheepSim.ewe("SHEEP_LANDRACE", "PG")
                local pregnancies = {}
                for i = 1, n do pregnancies[i] = { getSubType = function() return ramSub end } end
                ewe.isPregnant, ewe.pregnancy, ewe.reproduction = true, { pregnancies = pregnancies }, 60
                local pen = SheepSim.makePen({ ewe })
                for h = 1, 48 do
                    ewe.reproduction = 60 + 40 * h / 48
                    SheepSim.run(pen, 1, stock)
                end
                local r = ewe.rlFeedIntake
                CALIB["PREG/" .. name .. "/" .. n] = { bcsAtTerm = RLBodyCondition.getBCS(ewe), gravidKg = ewe.rlGrowth.gravidKg or 0,
                    dmPerDay = r.kg / r.dtDays, mePerDay = r.me / r.dtDays }
            end
        end
    end

    -- Sensitivity (reported, never judged): one value at a time, the rest as shipped. The ewe milk
    -- proxies (damMilk dm / me / cp: no source gives them for this milk; GE 5.013 MJ a kg as drunk is
    -- Sebek & Everts 1993 on fat 75, protein 53, lactose 48 g/kg, so me 25 x dm 0.19 = 4.75 MJ is ME/GE
    -- 0.9475, an assumption), the lamb maintenance candidate (0.466 / 0.482 in the trial) and the
    -- growth cost calibration value: R2 Landrace twins on grass (milk matters most there), R1 Landrace
    -- single on creep, R4 ram.
    do
        local sheep = RLFeedProfiles.getConfig().species.SHEEP
        local milk, physiology, requirements = sheep.damMilk, sheep.physiology, sheep.requirements
        local base = { dm = milk.dm, me = milk.me, cp = milk.cp, young = physiology.youngMaintenanceMEPerKgMetabolic,
            growth = requirements.growthMEPerKgAt500 }
        local GE = 5.013
        local function setMilk(v)
            milk.dm, milk.me, milk.cp = v.dm or base.dm, v.me or base.me, v.cp or base.cp
            physiology.youngMaintenanceMEPerKgMetabolic = v.young or base.young
            requirements.growthMEPerKgAt500 = v.growth or base.growth
        end
        local variants = {
            { "shipped", {} },
            { "milk ME/GE 0.85", { me = 0.85 * GE / base.dm } }, { "milk ME/GE 0.90", { me = 0.90 * GE / base.dm } },
            { "milk ME/GE 1.00", { me = 1.00 * GE / base.dm } },
            { "milk DM 0.17 (same ME a kg as drunk)", { dm = 0.17, me = base.me * base.dm / 0.17 } },
            { "milk DM 0.21 (same ME a kg as drunk)", { dm = 0.21, me = base.me * base.dm / 0.21 } },
            { "milk CP 0.24", { cp = 0.24 } }, { "milk CP 0.32", { cp = 0.32 } },
            { "lamb maintenance 0.466", { young = 0.466 } }, { "lamb maintenance 0.482", { young = 0.482 } },
            { "growth cost 30", { growth = 30 } }, { "growth cost 36", { growth = 36 } },
        }
        for _, v in ipairs(variants) do
            setMilk(v[2])
            local r2 = raiseWithDam("LANDRACE", 2, GRASS, { maxMonths = 9 })
            local r1 = raiseWithDam("LANDRACE", 1, INTENSIVE, { maxMonths = 6 })
            local r4 = storeLambs("LANDRACE", { "male" }, HOUSED, 60, { age = 5, weight = 32 })
            CALIB["SENS/" .. v[1]] = { r2RamAge = r2[1].ageAtRef, r2RamAt3 = r2[1].at3, r1RamAge = r1[1].ageAtRef, r1RamAt3 = r1[1].at3,
                r4Adg = r4[1].adg }
        end
        setMilk({})
    end

    -- The ram : wether : ewe lamb ratio (V6) taken apart: the ewe lamb's own curve (S4: her gain is
    -- 0.76 of the ram's), the growth cost by sex (0.80 / 1.00 / 1.25, a calibration value) and the
    -- fat offset of the finishing target (wether +0.09, ewe lamb +0.18), each switched off alone and
    -- all together, on R4.
    do
        local sheep = RLFeedProfiles.getConfig().species.SHEEP
        local physiology = sheep.physiology
        local body = RLBodyConditionConfig.get().species.SHEEP
        -- Her curve: the Landrace profile's female knots swapped for the male ones (birth knot included).
        local knots = RLGrowth.getConfig().profiles["SHEEP:LANDRACE"].knots
        local base = { male = physiology.growthCostMale, castrate = physiology.growthCostCastrate, female = physiology.growthCostFemale,
            steer = body.steerFinishShift, femaleShift = body.femaleFinishShift, femaleKnots = knots.female }
        local function set(v)
            physiology.growthCostMale = v.noCost and 1 or base.male
            physiology.growthCostCastrate = v.noCost and 1 or base.castrate
            physiology.growthCostFemale = v.noCost and 1 or base.female
            body.steerFinishShift = v.noShift and 0 or base.steer
            -- A tiny shift keeps her on the finishing rules (0 would take her off them).
            body.femaleFinishShift = v.noShift and 1e-9 or base.femaleShift
            knots.female = v.ramCurve and knots.male or base.femaleKnots
            RLGrowth.resetCaches()
        end
        for _, v in ipairs({ { "shipped", {} }, { "no sex growth cost", { noCost = true } }, { "no fat offset", { noShift = true } },
            { "ewe lamb on the ram's curve", { ramCurve = true } }, { "none of the three", { noCost = true, noShift = true, ramCurve = true } } }) do
            set(v[2])
            local lambs = storeLambs("LANDRACE", { "male", "wether", "female" }, HOUSED, 60, { age = 5, weight = 32 })
            CALIB["V6PARTS/" .. v[1]] = { lambs = lambs }
        end
        set({})
    end

    -- Growth cost beyond R4 (reported; no trial data to judge it against): store lambs of four breeds
    -- from 25 and 40 kg, housed on ad lib concentrate and on silage with 0.5 kg barley a day.
    do
        for _, breed in ipairs({ "LANDRACE", "TEXEL", "SUFFOLK", "BLACKFACE" }) do
            for _, start in ipairs({ { 25, 4 }, { 40, 6 } }) do
                local adlib = storeLambs(breed, { "male" }, HOUSED, 60, { age = start[2], weight = start[1] })
                local barley = 0.5 * litersPerKgFresh("BARLEY") * 1.25
                local refill = function(pen) pen:add("BARLEY", barley * #pen.animals) end
                local limited = storeLambs(breed, { "male" }, { SILAGE = 4000 }, 60, { age = start[2], weight = start[1], refill = refill })
                CALIB["GROWTH/" .. breed .. "/" .. start[1]] = { adlib = adlib[1], limited = limited[1] }
            end
        end
    end

    -- Month length: R1 Landrace twins at 1, 3, 7 and 28 days.
    for _, days in ipairs({ 3, 7, 28 }) do
        local lambs = raiseWithDam("LANDRACE", 2, INTENSIVE, { maxMonths = 6, days = days })
        CALIB["R1/LANDRACE/2/days" .. days] = { lambs = lambs }
    end
    GrowthSim.setDaysPerPeriod(1)

    -- V10: a 300-sheep pen (100 ewes with twins) for 24 game hours at a 28-day month.
    do
        GrowthSim.setDaysPerPeriod(28)
        local animals = {}
        for i = 1, 100 do
            animals[#animals + 1] = SheepSim.ewe("SHEEP_LANDRACE", "PE" .. i)
            animals[#animals + 1] = SheepSim.lamb("RAM_LANDRACE", "PE" .. i, "PL" .. i .. "a")
            animals[#animals + 1] = SheepSim.lamb("SHEEP_LANDRACE", "PE" .. i, "PL" .. i .. "b")
        end
        local pen = SheepSim.makePen(animals)
        local clock = os.clock()
        SheepSim.run(pen, 24, INTENSIVE)
        local seconds = os.clock() - clock
        CALIB["V10"] = { animals = #animals, hours = 24, msPerHour = seconds / 24 * 1000, active = pen.spec_husbandryFood.rlFeedPen.active }
        GrowthSim.setDaysPerPeriod(1)
    end

end


-- Batch 2 (S5 checklist F.5): management the game's feeds allow. Ewe milk, the shared grass and the
-- intake coefficients are untouched; every stock below is the trough's hourly top-up in game
-- liters (ample supply, not a ration): what each animal eats is the planner's.
local CLOVER = { CLOVER_WINDROW = 4000 }
local RECOVERY_CAP = { bcs = 3.25, target = "MAINTAIN" }   -- reserve index 0.5625 (AUTO: 0.50, BCS 3.0)

function SheepCalibScenarios.management()
    -- Hill lambs on clover: the hill R2, CLOVER_WINDROW in place of GRASS_WINDROW, neutral genes.
    for _, breed in ipairs({ "STEINSCHAF", "BLACK_WELSH", "BLACKFACE" }) do
        for _, litter in ipairs({ 1, 2 }) do
            local lambs, ewe, pool = raiseWithDam(breed, litter, CLOVER, { maxMonths = 9 })
            CALIB["MGMT/R2clover/" .. breed .. "/" .. litter] = { lambs = lambs, ewe = ewe, milkPool = pool }
        end
    end
    -- One ewe's year: grass, barley and peas on offer through the 90 days of lactation; from
    -- weaning FINISH until she reaches BCS 3.25, then MAINTAIN (the player's switch); both.
    CALIB["MGMT/EWE/lactation intensified"] = eweYear({ lactationStock = INTENSIVE, lactationStockMonths = 3 })
    CALIB["MGMT/EWE/controlled recovery"] = eweYear({ recoveryTarget = "FINISH", recoveryCap = RECOVERY_CAP })
    CALIB["MGMT/EWE/joint"] = eweYear({ lactationStock = INTENSIVE, lactationStockMonths = 3, recoveryTarget = "FINISH",
        recoveryCap = RECOVERY_CAP })
end


-- Batch 3: R4 rebuilt beside the original. The study's conditions (Keady and Hanrahan 2014/2015,
-- summarised in Teagasc's "Finishing store lambs" 2016; castrates, 39 kg, 54 days from the
-- conference paper): Suffolk-cross lowland lambs, so Suffolk as the breed proxy; housed; the
-- concentrate (160 g CP/kg) raised to ad lib within 10 days (the game's adaptation stays 14 days:
-- recorded, not matched); 0.5 kg fresh high-value silage a head a day as the only forage; about
-- 1.5 kg concentrate a day eaten. 54 model days exactly: a 5-day month, 216 hours of 0.25 days.
-- Age 7 months is an assumption (store lambs bought in autumn); the trial's age is not given.
local STUDY = { breed = "SUFFOLK", weight = 39, age = 7, days = 54, daysPerPeriod = 5 }

--- The study recipe as the game can feed it (a proxy): barley ad lib, peas at most 0.5 kg fresh a
--- head a day (1/3 of 1.5 kg: CP 12% / 24% gives 16%), silage 0.5 kg fresh a head a day. The
--- trough holds each hour's allowance of peas and silage.
local function studyRecipe()
    return { BARLEY = 4000 }, function(pen)
        local hourDays = RLFeed.getHourDays()
        local n = #pen.animals
        pen.spec_husbandryFood.fillLevels[FILL.PEA] = 0.5 * hourDays * litersPerKgFresh("PEA") * n
        pen.spec_husbandryFood.fillLevels[FILL.SILAGE] = 0.5 * hourDays * litersPerKgFresh("SILAGE") * n
    end
end

function SheepCalibScenarios.r4Study(prefix)
    prefix = prefix or "R4STUDY"
    for _, sex in ipairs({ "wether", "male", "female" }) do
        local game = storeLambs(STUDY.breed, { sex }, HOUSED, STUDY.days,
            { age = STUDY.age, weight = STUDY.weight, daysPerPeriod = STUDY.daysPerPeriod })
        local stock, refill = studyRecipe()
        local recipe = storeLambs(STUDY.breed, { sex }, stock, STUDY.days,
            { age = STUDY.age, weight = STUDY.weight, daysPerPeriod = STUDY.daysPerPeriod, refill = refill })
        CALIB[prefix .. "/" .. sex .. "/game diet"] = { lambs = game }
        CALIB[prefix .. "/" .. sex .. "/study recipe"] = { lambs = recipe }
    end
    -- The age is an assumption: castrates at 5, 6 and 7 months, both diets (reported only).
    for _, age in ipairs({ 5, 6, 7 }) do
        local game = storeLambs(STUDY.breed, { "wether" }, HOUSED, STUDY.days,
            { age = age, weight = STUDY.weight, daysPerPeriod = STUDY.daysPerPeriod })
        local stock, refill = studyRecipe()
        local recipe = storeLambs(STUDY.breed, { "wether" }, stock, STUDY.days,
            { age = age, weight = STUDY.weight, daysPerPeriod = STUDY.daysPerPeriod, refill = refill })
        CALIB[prefix .. "AGE/" .. age] = { game = game[1], recipe = recipe[1] }
    end
end


--- Step length (convergence; numerical, not a production change): the judged lamb routes at
--- another sub-step, in a state of their own.
local function stepGroup(stepDays)
    return function()
        RLFeedProfiles.getConfig().stepDays = stepDays
        for _, breed in ipairs({ "LANDRACE", "TEXEL", "SUFFOLK", "SWISS_MOUNTAIN" }) do
            CALIB["R1/" .. breed .. "/1"] = { lambs = (raiseWithDam(breed, 1, INTENSIVE, { maxMonths = 6 })) }
        end
        for _, breed in ipairs({ "LANDRACE", "TEXEL", "STEINSCHAF", "BLACK_WELSH", "BLACKFACE" }) do
            for _, litter in ipairs({ 1, 2 }) do
                CALIB["R2/" .. breed .. "/" .. litter] = { lambs = (raiseWithDam(breed, litter, GRASS, { maxMonths = 9 })) }
            end
        end
        CALIB.stepDays = stepDays
    end
end


--- Candidate parameters (diagnosis only; production keeps its values): each in a state of its own,
--- so no changed config meets a cached energy config. The same scenarios run in "candidate:base".
local function candidateRuns(withEwe)
    CALIB["R4"] = { lambs = storeLambs("LANDRACE", { "male", "wether", "female" }, HOUSED, 60, { age = 5, weight = 32 }) }
    SheepCalibScenarios.r4Study("R4STUDY")
    for _, breed in ipairs({ "LANDRACE", "TEXEL" }) do
        CALIB["R1/" .. breed .. "/1"] = { lambs = (raiseWithDam(breed, 1, INTENSIVE, { maxMonths = 6 })) }
    end
    if withEwe then
        CALIB["EWE/year/twins"] = eweYear()
        CALIB["MGMT/EWE/lactation intensified"] = eweYear({ lactationStock = INTENSIVE, lactationStockMonths = 3 })
        CALIB["MGMT/EWE/controlled recovery"] = eweYear({ recoveryTarget = "FINISH", recoveryCap = RECOVERY_CAP })
        CALIB["MGMT/EWE/joint"] = eweYear({ lactationStock = INTENSIVE, lactationStockMonths = 3, recoveryTarget = "FINISH",
            recoveryCap = RECOVERY_CAP })
    end
end

local function sheepSection() return RLFeedProfiles.getConfig().species.SHEEP end

SheepCalibScenarios.CANDIDATES = {
    base = function() end,
    ["growth cost 30"] = function() sheepSection().requirements.growthMEPerKgAt500 = 30 end,
    ["growth cost 36"] = function() sheepSection().requirements.growthMEPerKgAt500 = 36 end,
    ["growing intake 0.087"] = function() sheepSection().intake.growingPerKgMetabolic = 0.087 end,
    -- A grown ewe that has lambed lays reserve down at 100 MJ a kg (AHDB's other example), planner
    -- and settlement alike (both read RLFeed.getEnergyConfig); lambs and every other animal keep 50.
    ["ewe reserve deposit 100"] = function()
        local get = RLFeed.getEnergyConfig
        local copies = setmetatable({}, { __mode = "k" })
        RLFeed.getEnergyConfig = function(subject)
            local cfg = get(subject)
            if subject ~= nil and subject.gender == "female" and subject.isParent and (subject.age or 0) >= 12 then
                local copy = copies[cfg]
                if copy == nil then
                    copy = {}
                    for k, v in pairs(cfg) do copy[k] = v end
                    copy.depositNUPerKg = 100
                    copies[cfg] = copy
                end
                return copy
            end
            return cfg
        end
    end,
}


SheepCalibScenarios.GROUPS = {
    main = function()
        SheepCalibScenarios.main()
        SheepCalibScenarios.management()
        SheepCalibScenarios.r4Study("R4STUDY")
    end,
    ["step:0.125"] = stepGroup(0.125),
    ["step:0.0625"] = stepGroup(0.0625),
    ["step:0.03125"] = stepGroup(0.03125),
    ["step:0.015625"] = stepGroup(0.015625),
}
for name, apply in pairs(SheepCalibScenarios.CANDIDATES) do
    SheepCalibScenarios.GROUPS["candidate:" .. name] = function()
        apply()
        candidateRuns(name == "base" or name == "ewe reserve deposit 100")
    end
end

--- Run a group (CALIB_GROUP, default main).
function SheepCalibScenarios.run(group)
    local fn = SheepCalibScenarios.GROUPS[group or "main"]
    assert(fn ~= nil, "unknown calibration group " .. tostring(group))
    fn()
end
