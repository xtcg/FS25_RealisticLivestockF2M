-- FEED-11: the calf on milk in the real-equivalent mode. NRC 2001's young calf for maintenance and
-- the energy in its gain (into the adult values by weaning: animals past it, and every animal from
-- 8 months, keep the adult budget exactly), one function for the plan and the step's settlement;
-- the milk allowance apart from the solids its rumen takes; the rumen's solid-energy discount on
-- forage only, a starter concentrate at its own worth; field peas as the starter's protein, capped
-- by their maxShare like wheat; and a calf on the starter route reaching its curve at 6 months.

loadMod("tests/feedsim.lua")

local config = RLFeed.getConfig()
local calfCfg = config.calf
local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end


-- Config ------------------------------------------------------------------------------------------

do
    local pea = RLFeedProfiles.getUsableFeed("PEA")
    check("config: field peas are a concentrate for every stage, 24% CP, ME from TDN 87, at most 40% of the ration",
        pea ~= nil and pea.role == "CONCENTRATE" and pea.cp == 0.24 and pea.stages.PRE_WEANING and pea.stages.WEANING and pea.stages.WEANED
        and near(pea.me, RLFeedUnits.getMEFromTDN(87)) and pea.maxShare == 0.40)
    check("config: wheat keeps its 30% cap as a feed cap (the ration's wheatMaxShare)",
        RLFeedProfiles.getUsableFeed("WHEAT").maxShare == config.ration.wheatMaxShare)
    check("config: NRC 2001 young calf values (maintenance 0.42 MJ/kg^0.75, NEg 0.84 W^0.355 LWG^1.2, kg 0.69 milk / 0.57 dry)",
        calfCfg.maintenanceMEPerKgMetabolic == 0.42 and calfCfg.negCoefficient == 0.84 and calfCfg.negWeightExponent == 0.355
        and calfCfg.negGainExponent == 1.2 and calfCfg.kgMilk == 0.69 and calfCfg.kgSolid == 0.57)
    local function feed(fields)
        local p = { name = "X", role = "CONCENTRATE", status = "TYPICAL", meBasis = "TDN_NRC2000", density = 0.5, dm = 0.9, tdn = 80,
            cp = 0.1, ndf = 0.2, peFactor = 0.4, starch = 0.5, sugar = 0, stages = { WEANED = true } }
        for k, v in pairs(fields) do p[k] = v end
        if p.tdn ~= nil then p.me = RLFeedUnits.getMEFromTDN(p.tdn) end
        return RLFeedProfiles.validateFeed(p)
    end
    check("config: a feed cap must be a share in (0, 1]", feed({ maxShare = 0.4 }) and not feed({ maxShare = 0 }) and not feed({ maxShare = 1.5 }))
    local bad = table.clone(config, 2)
    bad.calf = table.clone(config.calf)
    bad.calf.maintenanceMEPerKgMetabolic = 0.6
    check("config: a calf's maintenance above the adult's is refused", RLFeedProfiles.validate(bad) == false)
    bad.calf.maintenanceMEPerKgMetabolic = 0.42
    bad.calf.kgMilk = 1.2
    check("config: an efficiency above 1 is refused", RLFeedProfiles.validate(bad) == false)
    bad.calf.kgMilk = 0.69
    bad.calfMilk = table.clone(config.calfMilk)
    bad.calfMilk.sizeExponent = 0.8
    check("config: the fingerprint includes the calf values and the milk size rule", RLFeedProfiles.computeHash(bad) ~= config.hash)
end


-- The calf budget: NRC 2001, into the adult values by weaning ------------------------------------

do
    local adult = RLFeedMath.getGrowthCost(50, config.requirements)
    local expected = 0.84 * 50 ^ 0.355 * 0.8 ^ 0.2 / 0.69 * 4.184
    check(string.format("calf cost: a 50 kg calf on milk gaining 0.8 kg a day pays NRC's %.2f MJ ME a kg (adult floor %.0f)", expected, adult),
        near(RLFeedMath.getCalfGrowthCost(50, 0.8, 1, calfCfg, adult), expected, 1e-9) and expected > adult)
    local half = 0.84 * 50 ^ 0.355 * 0.8 ^ 0.2 / (0.57 + 0.12 * 0.5) * 4.184
    check("calf cost: half on milk, the efficiency and the cost halfway to dry feed and the adult cost",
        near(RLFeedMath.getCalfGrowthCost(50, 0.8, 0.5, calfCfg, adult), adult + (half - adult) * 0.5, 1e-9))
    check("calf cost: weaned (milkMax 0) is the adult cost exactly", RLFeedMath.getCalfGrowthCost(50, 0.8, 0, calfCfg, adult) == adult)

    FeedSim.setMode(true)
    GrowthSim.setDaysPerPeriod(1)
    local calf = GrowthSim.newborn("BULL_HOLSTEIN")
    local dtMonths, dtDays = config.stepDays / 30, config.stepDays
    local factor = RLFeed.getCalfMaintenanceFactor(calf, dtMonths)
    check(string.format("calf maintenance: a newborn's is NRC's milk-fed calf (x%.4f of the adult)", factor),
        near(factor, 0.42 / 0.50, 2e-3) and factor < 1)
    local d = RLFeed.describeAnimal(calf, RLFeed.DEFAULT_RATION, dtMonths, dtDays)
    local _, _, gene = RLGrowth.getGeneFactors(calf.genetics.metabolism)
    local _, _, maintenanceGene = RLGrowth.getGeneFactors(calf.genetics.metabolism)
    check("calf maintenance: the plan's maintenance a day is that factor x the adult value x kg^0.75",
        near(d.needs.maintenance, 0.50 * factor * calf.weight ^ 0.75 * maintenanceGene, 1e-6))

    -- The settlement uses the same values.
    local state = RLGrowth.ensureState(calf)
    local input = RLGrowth.buildStepInput(calf, state, 0, 1, dtMonths, true)
    local base = input.maintenanceFactor
    RLFeed.applyStepInput(calf, input, { me = 1, proteinFactor = 1, target = "FINISH" }, dtMonths)
    check("calf budget: the step's settlement takes the plan's growth cost and maintenance factor",
        input.growthCostPerKg == RLFeed.getGrowthCost(calf, dtMonths) and near(input.maintenanceFactor, base * factor, 1e-12)
        and input.growthCostPerKg > RLFeedMath.getGrowthCost(calf.weight, config.requirements))

    local older = GrowthSim.makeAnimal("BULL_HOLSTEIN", { age = 8 })
    local heifer = GrowthSim.makeAnimal("COW_ANGUS", { age = 5 })
    check("calf budget: from weaning (and at 8 months) the adult maintenance and growth cost exactly",
        RLFeed.getCalfMaintenanceFactor(older, dtMonths) == 1 and RLFeed.getGrowthCost(older, dtMonths) == RLFeedMath.getGrowthCost(older.weight, config.requirements)
        and RLFeed.getCalfMaintenanceFactor(heifer, dtMonths) == 1 and RLFeed.getGrowthCost(heifer, dtMonths) == RLFeedMath.getGrowthCost(heifer.weight, config.requirements))
    local od = RLFeed.describeAnimal(older, RLFeed.DEFAULT_RATION, dtMonths, dtDays)
    check("calf budget: an older animal has no solid cap of a calf and eats concentrate as before", od.solidCap == nil and od.concEligible and od.class ~= "CALF")
end


-- Intake: the milk allowance apart from the solids -------------------------------------------------

do
    FeedSim.setMode(true)
    local calf = GrowthSim.newborn("BULL_HOLSTEIN")
    local dtDays = config.stepDays
    local d = RLFeed.describeAnimal(calf, RLFeed.DEFAULT_RATION, dtDays / 30, dtDays)
    local milkMax, solidMax = RLCalfRearing.getCaps(calf, 0.5 * dtDays / 30)
    local _, _, gene = RLGrowth.getGeneFactors(calf.genetics.metabolism)
    check("intake: a calf's total appetite is the growing value; its rumen takes solidMax x calfSolidPerKgMetabolic x kg^0.75",
        near(d.appetite, config.intake.growingPerKgMetabolic * (calf.weight) ^ 0.75 * gene, 0.05 * d.appetite)
        and near(d.solidCap, solidMax * RLFeedMath.getCalfSolidCapacity(calf.weight + 0, config.intake, RLCalfRearing.getWeaningX(calf), gene), 0.05 * d.solidCap))
    local milk = RLFeedProfiles.getUsableFeed("CALFMILK")
    local request = { animals = { d }, forage = { { name = "FORAGE", profile = RLFeedProfiles.getUsableFeed("FORAGE"), liters = 1e6 } },
        concentrate = {}, milk = { { name = "CALFMILK", profile = milk, liters = 1e6 } }, scale = config.resourceScale, realDaysPerPeriod = 30,
        dtDays = dtDays, ration = config.ration, classes = config.classes, proteinMaintenance = config.protein.maintenance }
    RLFeedRationPlanner.plan(request)
    check(string.format("intake: a newborn drinks its whole allowance (%.3f kg DM a day), not the old calf appetite's %.3f",
        d.milkMaxKgPerDay, 0.060 * calf.weight ^ 0.75 * gene), near(d.milkPlanKg / dtDays, d.milkMaxKgPerDay, 1e-12)
        and d.milkMaxKgPerDay > 0.060 * calf.weight ^ 0.75 * gene)
    check("intake: its solids are its rumen's capacity, beside the milk", d.forageKg > 0 and d.forageKg <= d.solidCap * dtDays + 1e-12)
    check("intake: the TMR it eats counts at its rumen's solid energy", near(d.byFill.FORAGE.factor, d.solidEnergy) and d.solidEnergy < 1)
end


-- The starter: peas at their own worth, capped ---------------------------------------------------

do
    FeedSim.setMode(true)
    GrowthSim.setDaysPerPeriod(1)
    local calf = GrowthSim.newborn("BULL_HOLSTEIN")
    calf.age = 1.5
    local pen = FeedSim.makePen({ calf }, { CALFMILK = 1e5, FORAGE = 1e5, PEA = 1e5 }, { rearing = true })
    RLGrowth.ensureState(calf).feedAdapted = 1
    local steps = {}
    local function observe(kind, data) if kind == "STEP" then steps[#steps + 1] = data.animals[1].feed.byFill end end
    RLFeed.addObserver(observe)
    FeedSim.untilStep(pen)
    RLFeed.removeObserver(observe)
    local record = calf.rlFeedIntake
    local pea, tmr = record.byFill.PEA, record.byFill.FORAGE
    local step = steps[1] or {}
    local solidEnergy = step.FORAGE ~= nil and step.FORAGE.factor or 1
    check(string.format("starter: a calf on milk eats peas with the TMR (%.0f%% of its solids) at the peas' own ME, the TMR at %.2f",
        pea ~= nil and pea.kg / (pea.kg + tmr.kg) * 100 or 0, solidEnergy),
        pea ~= nil and pea.kg > 0 and #steps > 0 and step.PEA.factor == 1 and solidEnergy < 1
        and near(pea.me, pea.kg * RLFeedProfiles.getUsableFeed("PEA").me, 1e-9 * pea.me))
    local solids = pea.kg + tmr.kg
    local cp = (pea.kg * 0.24 + tmr.kg * 0.16) / solids
    check(string.format("starter: TMR and peas make a starter of %.1f%% CP (the 18-22%% range)", cp * 100), cp >= 0.18 and cp <= 0.22)
    check("starter: no grain before weaning (grains are for weaned animals)", record.byFill.MAIZE == nil)

    -- Weaned: peas at most 40% of the ration, the limit named.
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
    local hay = FeedSim.makePen({ bull }, { DRYGRASS_WINDROW = 1e6, PEA = 1e6 })
    RLGrowth.ensureState(bull).feedAdapted = 1
    RLFeed.setRation(hay, { target = "FINISH", grain = "AUTO", share = 0.6 })
    FeedSim.untilStep(hay)
    local r = bull.rlFeedIntake
    check(string.format("cap: asked for 60%%, a bull on hay and peas eats %.1f%% peas (FEED_CAP)", r.byFill.PEA.kg / r.kg * 100),
        r.byFill.PEA.kg <= 0.40 * r.kg + 1e-9 and r.byFill.PEA.kg >= 0.40 * r.kg - 1e-6 and r.concLimit == "FEED_CAP")
end


-- Six months from birth: the starter route against the calf's curve ------------------------------

do
    FeedSim.setMode(true)
    GrowthSim.setDaysPerPeriod(1)
    local function raise(stock)
        local calf = GrowthSim.newborn("BULL_HOLSTEIN")
        local pen = FeedSim.makePen({ calf }, {}, { rearing = true })
        local minHealth = calf.health
        FeedSim.months(pen, 6, { refill = function(p)
            for name, liters in pairs(stock) do if p:level(name) < liters then p:add(name, liters - p:level(name)) end end
            minHealth = math.min(minHealth, calf.health)
        end })
        return calf, minHealth
    end
    local starter, starterHealth = raise({ CALFMILK = 1e5, FORAGE = 1e5, PEA = 1e5, MAIZE = 1e5 })
    local standard, standardHealth = raise({ CALFMILK = 1e5, FORAGE = 1e5 })
    local curve = RLGrowth.getCurve(starter):value(6)
    local phase = starter.rlGrowth.developmentMonths
    check(string.format("route: a Holstein bull calf on milk, TMR and peas is %.1f kg at 6 months (curve %.1f, %+.1f%%), phase %.2f, health 100",
        starter.weight, curve, (starter.weight / curve - 1) * 100, phase),
        phase >= 5.5 and math.abs(starter.weight / curve - 1) <= 0.05 and starterHealth == 100 and starter.health == 100)
    check(string.format("route: on milk and TMR alone it is slower (%.1f kg, phase %.2f), still healthy", standard.weight,
        standard.rlGrowth.developmentMonths), standard.weight < starter.weight and standardHealth == 100)
end
