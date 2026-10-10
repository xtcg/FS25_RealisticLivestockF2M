-- Real-equivalent nutrition (scripts/feed, xml/feedProfiles.xml): the profile file and its
-- checks, the one unit conversion, the ration planner's rules (DM shares, fibre before grain,
-- wheat cap, adaptation, shortages, mixed pens), and the mode in a pen with the weight model v2:
-- resource-scale and month-length invariance, fixed feed energy, the maintenance health
-- contract, calves, the trough's grain and saving.

loadMod("tests/feedsim.lua")

local F = RLFeedProfiles
local config = F.getConfig()
local FILL = FeedSim.FILL
local env = GrowthSim.env

local function within(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= tolerance end
local function relative(a, b) return math.abs(a - b) / math.max(math.abs(b), 1e-12) end


-- Config ---------------------------------------------------------------------------------------

do
    check(string.format("config: the shipped file is valid (hash %s), scale 0.20, 30 model days a month", config.hash),
        config.valid == true and config.resourceScale == 0.20 and config.realDaysPerPeriod == 30)
    local wheat, maize, hay, tmr = F.getUsableFeed("WHEAT"), F.getUsableFeed("MAIZE"), F.getUsableFeed("DRYGRASS_WINDROW"), F.getUsableFeed("FORAGE")
    check("config: OSU values for maize (88/9/88) and wheat (89/14/84), ME by the NRC 2000 TDN equation",
        maize.dm == 0.88 and maize.cp == 0.09 and maize.tdn == 88 and wheat.dm == 0.89 and wheat.cp == 0.14 and wheat.tdn == 84
        and within(maize.me, 88 * 0.04409 * 0.82 * 4.184, 1e-9) and within(maize.me, 13.311, 0.001))
    check("config: densities are the engine's massPerLiter (TMR 0.30, hay 0.07, wheat 0.78, maize 0.80)",
        tmr.density == 0.30 and hay.density == 0.07 and wheat.density == 0.78 and maize.density == 0.80)
    check("config: TMR is one complete ration, grains are concentrates for weaned animals, milk for calves only",
        tmr.role == "COMPLETE" and wheat.role == "CONCENTRATE" and wheat.stages.WEANED and not wheat.stages.PRE_WEANING
        and F.getUsableFeed("CALFMILK").role == "MILK" and not F.getUsableFeed("CALFMILK").stages.WEANED)
    check("config: unconfigured feeds (Hof Bergmann's ROUNDBALE, GRAINGRIST) are listed but never usable",
        F.getFeed("ROUNDBALE") ~= nil and F.getUsableFeed("ROUNDBALE") == nil and F.getUsableFeed("GRAINGRIST") == nil)
    check("config: the hash is stable for the same values", F.computeHash(config) == config.hash)

    local function feed(fields)
        local p = { name = "X", role = "FORAGE", status = "TYPICAL", meBasis = "TDN_NRC2000", density = 0.5, dm = 0.5, tdn = 60,
            cp = 0.1, ndf = 0.5, peFactor = 1, starch = 0, sugar = 0, stages = { WEANED = true } }
        for k, v in pairs(fields) do p[k] = v end
        if p.meBasis == "TDN_NRC2000" and p.tdn ~= nil and p.me == nil then p.me = RLFeedUnits.getMEFromTDN(p.tdn) end
        return F.validateFeed(p)
    end
    check("config: a feed with density 0, dm above 1, a share outside 0..1, no stage or an unknown role is refused (not clamped)",
        feed({}) == true and feed({ density = 0 }) == false and feed({ dm = 1.2 }) == false and feed({ cp = 1.5 }) == false
        and feed({ stages = {} }) == false and feed({ role = "SNACK" }) == false and feed({ tdn = 0, me = 0 }) == false)
    check("config: NEm/NEg are not ME - only TDN_NRC2000 or ME_DIRECT give energy",
        feed({ meBasis = "NEM", me = 8 }) == false and feed({ meBasis = "ME_DIRECT", me = 11 }) == true)
    local bad = table.clone(config, 2)
    bad.requirements = table.clone(config.requirements)
    bad.requirements.reserveDepositMEPerKg = 30
    check("config: a reserve that gives back more than it costs is refused (free energy)", F.validate(bad) == false)
    bad = table.clone(config, 2)
    bad.resourceScale = 0
    check("config: a resource scale outside (0, 1] is refused", F.validate(bad) == false)
end


-- Units (the design's worked examples) ---------------------------------------------------------------

do
    local U = RLFeedUnits
    local tmr, hay, wheat = F.getUsableFeed("FORAGE"), F.getUsableFeed("DRYGRASS_WINDROW"), F.getUsableFeed("WHEAT")
    check("units: 600 kg at 12 kg DM a real day = 72 kg DM of game feed a month: 533.33 L of TMR or 1210.08 L of hay",
        within(U.getMonthlyLiters(12, 1, 0.2, 30, tmr.density, tmr.dm), 533.33, 0.01)
        and within(U.getMonthlyLiters(12, 1, 0.2, 30, hay.density, hay.dm), 1210.08, 0.01))
    check("units: 70% hay + 30% wheat by DM: 847.06 L hay and 31.11 L wheat a month (not 70:30 by volume)",
        within(U.getMonthlyLiters(12, 0.7, 0.2, 30, hay.density, hay.dm), 847.06, 0.01)
        and within(U.getMonthlyLiters(12, 0.3, 0.2, 30, wheat.density, wheat.dm), 31.11, 0.01))
    local ok = true
    for i = 1, 200 do
        local kg, rho, dm, s = (i * 7.31) % 50 + 0.01, 0.05 + (i % 17) / 10, 0.1 + (i % 9) / 10, 0.05 + (i % 19) / 20
        if relative(U.litersToKg(U.kgToLiters(kg, s, rho, dm), s, rho, dm), kg) > 1e-12 then ok = false end
    end
    check("units: liters -> DM -> liters round-trips for 200 densities, dry matters and scales", ok)
    check("units: an hour stands for 30 / (24 d) model days (1.25 at one day a month, 0.178571 at seven)",
        within(U.getHourDays(30, 1), 1.25, 1e-12) and within(U.getHourDays(30, 7), 30 / 168, 1e-12))
end


-- Planner (pure) -----------------------------------------------------------------------------------

local function entry(name, liters) return { name = name, profile = F.getUsableFeed(name), liters = liters } end
local function plannerAnimal(fields)
    local a = { appetite = 10, fill = 6, class = "GROWING", target = "FINISH", concEligible = true, adapted = 0.8,
        needs = { maintenance = 60, pregnancy = 0, growth = 60, milk = 0, deposit = 20 }, proteinNeed = 0.12, milkMax = 0 }
    for k, v in pairs(fields or {}) do a[k] = v end
    return a
end
local function plan(animals, forage, conc, milk, extra)
    local request = { animals = animals, forage = forage or {}, concentrate = conc or {}, milk = milk or {}, scale = 0.2,
        realDaysPerPeriod = 30, dtDays = 1, ration = config.ration, classes = config.classes,
        proteinMaintenance = config.protein.maintenance, concentrateWanted = true }
    for k, v in pairs(extra or {}) do request[k] = v end
    return RLFeedRationPlanner.plan(request)
end

do
    local a = plannerAnimal()
    local result = plan({ a }, { entry("DRYGRASS_WINDROW", 1e6) }, { entry("MAIZE", 1e6) }, nil, { share = 0.3 })
    local hayKg = a.byFill.DRYGRASS_WINDROW.kg
    local maizeKg = a.byFill.MAIZE.kg
    check(string.format("planner: a 30%% target is 30%% of the DM eaten (%.3f) - in liters %.1f : %.1f, nowhere near 70:30",
        maizeKg / (hayKg + maizeKg), result.withdraw.DRYGRASS_WINDROW, result.withdraw.MAIZE),
        within(maizeKg / (hayKg + maizeKg), 0.3, 1e-9) and result.withdraw.DRYGRASS_WINDROW / result.withdraw.MAIZE > 20)

    -- The map's SERIAL order would never reach the grain group while hay is left; the planner does.
    local b = plannerAnimal()
    plan({ b }, { entry("DRYGRASS_WINDROW", 1e6) }, { entry("MAIZE", 1e6) })
    check("planner: grain is eaten beside roughage (the trough's serial order does not hide it)", (b.byFill.MAIZE or {}).kg ~= nil and b.byFill.MAIZE.kg > 0)

    local c = plannerAnimal()
    local result2 = plan({ c }, {}, { entry("MAIZE", 1e6) })
    check("planner: no roughage, no grain - an empty forage trough does not run on pure grain, and the grain stays",
        c.kg == 0 and result2.withdraw.MAIZE == nil)

    local d = plannerAnimal({ adapted = 1 })
    plan({ d }, { entry("DRYGRASS_WINDROW", 1e6) }, { entry("WHEAT", 1e6) }, nil, { share = 0.8 })
    check(string.format("planner: wheat at most 30%% of the ration (%.3f) whatever the target", d.cEaten), d.cEaten <= 0.3 + 1e-9 and d.concLimit == "WHEAT")

    local e = plannerAnimal({ adapted = 1 })
    plan({ e }, { entry("DRYGRASS_WINDROW", 1e6) }, { entry("MAIZE", 1e6) }, nil, { share = 0.9 })
    local hay, maize = F.getUsableFeed("DRYGRASS_WINDROW"), F.getUsableFeed("MAIZE")
    local fermentable = (1 - e.cEaten) * hay.fermentable + e.cEaten * maize.fermentable
    local pe = (1 - e.cEaten) * hay.peNdf + e.cEaten * maize.peNdf
    check(string.format("planner: maize is held where starch + sugar reaches the growing class's 55%% (%.3f) and effective fibre stays >= 12%% (%.3f)",
        fermentable, pe), fermentable <= 0.55 + 1e-9 and pe >= 0.12 - 1e-9 and e.concLimit == "STARCH")

    local f = plannerAnimal({ adapted = 0 })
    plan({ f }, { entry("DRYGRASS_WINDROW", 1e6) }, { entry("MAIZE", 1e6) }, nil, { share = 0.6 })
    check(string.format("planner: an animal not adapted to grain eats at most stepAllowance (+ half a day's ramp: %.4f) of it", f.cEaten),
        within(f.cEaten, config.ration.stepAllowance + 0.5 * config.ration.adaptationMaxShare / config.ration.adaptationDays, 1e-9)
        and f.concLimit == "ADAPTATION")

    -- Forage short by half: every animal half of its plan, the grain held to its share of the forage.
    local g1, g2 = plannerAnimal(), plannerAnimal({ appetite = 5, fill = 3 })
    local hayEntry = entry("DRYGRASS_WINDROW", 0)
    local needKg = 0
    for _, a2 in ipairs({ plannerAnimal(), plannerAnimal({ appetite = 5, fill = 3 }) }) do
        plan({ a2 }, { entry("DRYGRASS_WINDROW", 1e6) }, { entry("MAIZE", 1e6) }, nil, { share = 0.3 })
        needKg = needKg + a2.byFill.DRYGRASS_WINDROW.kg
    end
    hayEntry.liters = RLFeedUnits.kgToLiters(needKg / 2, 0.2, hay.density, hay.dm)
    local short = plan({ g1, g2 }, { hayEntry }, { entry("MAIZE", 1e6) }, nil, { share = 0.3 })
    check(string.format("planner: half the forage it needs - each animal gets half its forage (%.3f / %.3f of plan), grain stays at 30%% of what it ate",
        g1.forageEaten / g1.forageKg, g2.forageEaten / g2.forageKg),
        within(g1.forageEaten / g1.forageKg, 0.5, 1e-6) and within(g2.forageEaten / g2.forageKg, 0.5, 1e-6)
        and within(g1.cEaten, 0.3, 1e-6) and short.eatenMe < short.plannedMe)
    check("planner: what was not eaten carries nothing - the ME eaten is the feeds' own ME x the DM eaten",
        within(g1.me, g1.byFill.DRYGRASS_WINDROW.kg * hay.me + g1.byFill.MAIZE.kg * maize.me * RLFeedMath.getUtilisation(g1.cEaten, g1.adapted, config.ration), 1e-9))

    -- Mixed pen: a calf on milk gets no grain; a lactating cow and a bull get their own amounts.
    local calf = plannerAnimal({ class = "CALF", concEligible = false, milkMax = 0.9, solidMax = 0.3, solidEnergy = 0.5, appetite = 1.2, fill = 0.5 })
    local cow = plannerAnimal({ class = "LACTATING", target = "GROW", appetite = 22, fill = 9,
        needs = { maintenance = 65, pregnancy = 0, growth = 0, milk = 150, deposit = 0 }, proteinNeed = 0.16 })
    local bull = plannerAnimal({ appetite = 10, fill = 6 })
    plan({ calf, cow, bull }, { entry("FORAGE", 1e6) }, { entry("MAIZE", 1e6) }, { entry("CALFMILK", 1e6) }, { share = 0.2 })
    check("planner: mixed pen - the calf drinks milk and gets no adult grain, the cow and the bull eat their own amounts",
        calf.byFill.CALFMILK ~= nil and calf.byFill.MAIZE == nil and cow.byFill.CALFMILK == nil and bull.byFill.CALFMILK == nil
        and cow.byFill.MAIZE ~= nil and bull.byFill.MAIZE ~= nil and math.abs(cow.kg - bull.kg) > 1)

    -- AUTO: grain that only dilutes protein for a cow eating to her needs is not fed.
    local dairy = plannerAnimal({ class = "LACTATING", target = "GROW", appetite = 25, fill = 9,
        needs = { maintenance = 65, pregnancy = 0, growth = 0, milk = 150, deposit = 0 }, proteinNeed = 0.16 })
    plan({ dairy }, { entry("FORAGE", 1e6) }, { entry("MAIZE", 1e6) })
    local steer = plannerAnimal({ adapted = 0.8 })
    plan({ steer }, { entry("DRYGRASS_WINDROW", 1e6) }, { entry("MAIZE", 1e6) })
    check(string.format("planner: AUTO feeds no maize to a cow on full TMR (%.2f) but some to a bull on hay (%.2f)", dairy.cEaten, steer.cEaten),
        dairy.cEaten == 0 and steer.cEaten > 0.1)
end


-- The mode in a pen ------------------------------------------------------------------------------

FeedSim.setMode(true)

do
    FeedSim.setMode(false)
    local animal = GrowthSim.makeAnimal("BULL_ANGUS", { age = 10 })
    local pen = FeedSim.makePen({ animal }, { FORAGE = 5000 })
    FeedSim.hour(pen)
    local legacy = pen.spec_husbandryFood.rlFeedPen
    check("mode: off by default - a pen keeps the old rules (MODE_OFF), its grain is never eaten",
        legacy.active == false and legacy.reason == "MODE_OFF")
    FeedSim.setMode(true)
    pen:add("MAIZE", 1000)
    FeedSim.hour(pen)
    check("mode: on - a covered cattle pen runs it (OK) and its animal has an hour of real DM and ME",
        pen.spec_husbandryFood.rlFeedPen.active and animal.rlFeedIntake ~= nil and animal.rlFeedIntake.kg > 0 and animal.rlFeedIntake.me > 0)

    local cow = GrowthSim.makeAnimal("COW_ANGUS", { age = 48, isParent = true, isLactating = true, monthsSinceLastBirth = 0 })
    local calf = GrowthSim.newborn("BULL_ANGUS")
    local mixed = FeedSim.makePen({ cow, calf }, { FORAGE = 5000 })
    FeedSim.hour(mixed)
    check("mode: a calf on milk outside a rearing pen keeps the whole pen on the old rules (SUCKLING_CALF), no mixed rules",
        mixed.spec_husbandryFood.rlFeedPen.active == false and mixed.spec_husbandryFood.rlFeedPen.reason == "SUCKLING_CALF"
        and cow.rlFeedIntake == nil)

    local cluster = GrowthSim.makeAnimal("BULL_ANGUS", { age = 10 })
    cluster.isIndividual = false
    local uncovered = FeedSim.makePen({ cluster }, { FORAGE = 5000 })
    FeedSim.hour(uncovered)
    check("mode: an animal the weight model does not cover keeps its pen on the old rules (UNCOVERED_ANIMAL)",
        uncovered.spec_husbandryFood.rlFeedPen.reason == "UNCOVERED_ANIMAL")

    local unknown = FeedSim.makePen({ (GrowthSim.makeAnimal("BULL_ANGUS", { age = 10 })) }, { FORAGE = 5000, ROUNDBALE = 10 })
    FeedSim.hour(unknown)
    check("mode: an unconfigured feed in the trough does not switch the pen to the old rules - it is left uneaten and listed",
        unknown.spec_husbandryFood.rlFeedPen.active and unknown:level("ROUNDBALE") == 10
        and unknown.spec_husbandryFood.rlFeedLast.unconfigured[1] == "ROUNDBALE")
end

do
    check("grain: the cattle troughs' grain group is the map's grains no cattle group lists (MAIZE BARLEY OAT WHEAT), registered once",
        (function()
            local groups, grain = FeedSim.cowFood.groups, nil
            local count = 0
            for _, g in ipairs(groups) do if g.rlGrain then grain, count = g, count + 1 end end
            RLFeed.registerCattleGrains(g_currentMission.animalFoodSystem)
            for _, g in ipairs(groups) do if g.rlGrain then count = count + 1 end end
            return grain ~= nil and count == 2 and #grain.fillTypes == 4 and grain.productionWeight == 0
        end)())
end


-- Resource scale and month length ------------------------------------------------------------------

--- Raise a bull from 7 months for `months` on hay + maize (and wheat), stocked; returns the animal, pen and
--- the liters each fill type lost.
local function scenario(scale, days, months, fields)
    config.resourceScale = scale
    GrowthSim.setDaysPerPeriod(days)
    local animal = GrowthSim.makeAnimal("BULL_ANGUS", fields or { age = 7 })
    local pen = FeedSim.makePen({ animal }, {})
    local used = {}
    local stock = { DRYGRASS_WINDROW = 1e6, MAIZE = 1e6, WHEAT = 1e6 }
    local refill = function(p)
        for name, liters in pairs(stock) do
            local level = p:level(name)
            if level < liters then
                used[name] = (used[name] or 0) + (liters - level)
                p:add(name, liters - level)
            end
        end
    end
    refill(pen)
    for name in pairs(stock) do used[name] = 0 end
    FeedSim.months(pen, months, { refill = refill })
    for name, liters in pairs(stock) do used[name] = used[name] + (liters - pen:level(name)) end
    config.resourceScale = 0.2
    GrowthSim.setDaysPerPeriod(1)
    return animal, pen, used
end

do
    local a1, _, used1 = scenario(1, 1, 4)
    local a2, _, used2 = scenario(0.2, 1, 4)
    local ratioOk = true
    for name, liters in pairs(used1) do
        if liters > 0 and relative(used2[name] * 5, liters) > 1e-9 then ratioOk = false end
    end
    check(string.format("scale: the same ration and history at s = 1 and 0.2 - the trough loses exactly 5:1 per fill type (hay %.1f : %.1f L)",
        used1.DRYGRASS_WINDROW, used2.DRYGRASS_WINDROW), ratioOk and used1.DRYGRASS_WINDROW > 0)
    check(string.format("scale: ... and weight, development, reserve and adaptation are the same (%.6f / %.6f kg)", a1.weight, a2.weight),
        relative(a1.weight, a2.weight) < 1e-9 and relative(a1.rlGrowth.developmentMonths, a2.rlGrowth.developmentMonths) < 1e-9
        and relative(a1.rlGrowth.reserveMassKg, a2.rlGrowth.reserveMassKg) < 1e-9
        and within(a1.rlGrowth.feedAdapted, a2.rlGrowth.feedAdapted, 1e-9) and within(a1.rlFeedIntake.me, a2.rlFeedIntake.me, 1e-9))

    local base, _, baseUsed = scenario(0.2, 1, 3)
    local worst, worstFeed = 0, 0
    for _, days in ipairs({ 3, 7, 28 }) do
        local a, _, used = scenario(0.2, days, 3)
        worst = math.max(worst, math.abs(a.weight - base.weight))
        for name, liters in pairs(baseUsed) do
            if liters > 0 then worstFeed = math.max(worstFeed, relative(used[name], liters)) end
        end
    end
    check(string.format("months: 1, 3, 7 and 28 days a month give the same 3 months: weight within %.4f kg (< 0.5), feed within %.4f%% (< 0.1%%)",
        worst, worstFeed * 100), worst < 0.5 and worstFeed < 0.001)
end

do
    -- Fixed energy: the same liters eaten carry the same ME whatever the animal needs.
    local energies = {}
    for _, fields in ipairs({ { age = 12 }, { age = 12, genetics = { metabolism = 1.6, quality = 1, productivity = 1, fertility = 1, health = 1 } },
        { age = 30 } }) do
        local animal = GrowthSim.makeAnimal("BULL_ANGUS", fields)
        local pen = FeedSim.makePen({ animal }, { DRYGRASS_WINDROW = 1e6 })
        FeedSim.hour(pen)
        local record = animal.rlFeedIntake
        energies[#energies + 1] = record.me / record.byFill.DRYGRASS_WINDROW.liters
    end
    check(string.format("fixed energy: a liter of hay carries %.4f MJ for a young, a high-metabolism and an older bull alike",
        energies[1]), within(energies[1], energies[2], 1e-9) and within(energies[1], energies[3], 1e-9)
        and within(energies[1], F.getUsableFeed("DRYGRASS_WINDROW").me * 0.07 * 0.85 / 0.2, 1e-9))
end


-- Health: maintenance, buffers, shortage ---------------------------------------------------------

do
    -- A healthy dry cow on MAINTAIN for 9 months: weight and development held, no health lost, at 1
    -- and 7 days a month.
    local results = {}
    for _, days in ipairs({ 1, 7 }) do
        GrowthSim.setDaysPerPeriod(days)
        local cow = GrowthSim.makeAnimal("COW_ANGUS", { age = 48, isParent = true })
        local pen = FeedSim.makePen({ cow }, {})
        RLFeed.setRation(pen, { target = "MAINTAIN" })
        local w0, u0 = cow.weight, cow.rlGrowth.developmentMonths
        FeedSim.months(pen, 9, { refill = FeedSim.keepStocked({ DRYGRASS_WINDROW = 1e5 }) })
        results[days] = { dw = cow.weight - w0, du = cow.rlGrowth.developmentMonths - u0, health = cow.health,
            dmi = cow.rlFeedIntake.kg / cow.rlFeedIntake.dtDays, weight = cow.weight }
    end
    GrowthSim.setDaysPerPeriod(1)
    check(string.format("maintain: a dry cow held 9 months on hay keeps her weight (%+.2f kg) and development (%+.3f), health 100 (1 and 7 days a month)",
        results[1].dw, results[1].du), math.abs(results[1].dw) < 2 and math.abs(results[1].du) < 0.05 and results[1].health == 100
        and math.abs(results[7].dw) < 2 and results[7].health == 100 and math.abs(results[7].weight - results[1].weight) < 0.5)
    check(string.format("maintain: she eats for maintenance only (%.2f kg DM a day, %.2f%% of her weight), not a fixed share of full intake",
        results[1].dmi, results[1].dmi / results[1].weight * 100), results[1].dmi / results[1].weight < 0.015 and results[1].dmi > 5)

    -- Calendar lag alone does not cost health: a bull held on maintenance far behind its curve.
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local pen = FeedSim.makePen({ bull }, {})
    RLFeed.setRation(pen, { target = "MAINTAIN" })
    FeedSim.months(pen, 8, { refill = FeedSim.keepStocked({ DRYGRASS_WINDROW = 1e5 }) })
    local curve = RLGrowth.getCurve(bull)
    check(string.format("maintain: a bull held 8 months (%.0f kg, %.0f%% of his curve at %d months) loses no health for the calendar",
        bull.weight, bull.weight / curve:value(bull.age) * 100, bull.age), bull.health == 100 and bull.weight / curve:value(bull.age) < 0.75)

    -- Two model days without feed: the reserve and a short frame draw cover it, no health lost;
    -- weeks without: health falls.
    GrowthSim.setDaysPerPeriod(7)
    local steer = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local empty = FeedSim.makePen({ steer }, {})
    local gapHours = math.floor(2 / RLFeedUnits.getHourDays(30, 7))
    for _ = 1, gapHours do FeedSim.hour(empty) end
    check(string.format("buffer: %d hours (2 model days) with an empty trough are drawn from the body (reserve %.3f), health still 100 (%s)",
        gapHours, steer.bodyCondition.reserve, tostring(steer.rlFeedIntake.healthReason)), steer.health == 100 and steer.bodyCondition.reserve < 0.45
        and steer.rlFeedIntake.healthReason == "BUFFERED")
    for _ = 1, 24 * 7 do FeedSim.hour(empty) end
    check(string.format("shortage: a month without feed - past the buffer, health down to %d (%s)", steer.health, tostring(steer.rlFeedIntake.healthReason)),
        steer.health < 100 and steer.rlFeedIntake.healthReason == "SHORT")
    local before = steer.health
    FeedSim.months(empty, 1, { refill = FeedSim.keepStocked({ FORAGE = 5000 }) })
    check(string.format("shortage: fed again, health recovers (%d -> %d) and the built-up shortfall goes (%.2f days)", before, steer.health,
        steer.rlGrowth.feedShortDays or -1), steer.health > before and (steer.rlGrowth.feedShortDays or 1) == 0)
    GrowthSim.setDaysPerPeriod(1)

    -- Health is integrated per month: 1 and 7 days a month lose the same over the same model time.
    local losses = {}
    for _, days in ipairs({ 1, 7 }) do
        GrowthSim.setDaysPerPeriod(days)
        local a = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
        a.bodyCondition = { reserve = 0.06, capacityKg = 100, balanceEMA = 0, lossRateEMA = 0, lastTick = -1, version = 1 }
        a.rlGrowth = nil
        local p = FeedSim.makePen({ a }, {})
        for _ = 1, 24 * days do FeedSim.hour(p) end
        losses[days] = 100 - a.health - (a.rlHealthCarry or 0)
    end
    GrowthSim.setDaysPerPeriod(1)
    check(string.format("health: a starving month costs the same at 1 and 7 days a month (%.2f / %.2f points)", losses[1], losses[7]),
        losses[1] > 1 and math.abs(losses[1] - losses[7]) < 0.05 * losses[1])
end


-- Adaptation, calves ---------------------------------------------------------------------------------

do
    local adapted = {}
    for _, days in ipairs({ 1, 7 }) do
        GrowthSim.setDaysPerPeriod(days)
        local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
        local pen = FeedSim.makePen({ bull }, {})
        RLFeed.setRation(pen, { share = 0.6 })
        local refill = FeedSim.keepStocked({ GRASS_WINDROW = 1e6, MAIZE = 1e5 })
        refill(pen)
        FeedSim.hour(pen)
        local first = bull.rlFeedIntake.concShare
        FeedSim.months(pen, 1, { refill = refill })
        adapted[days] = { first = first, after = bull.rlFeedIntake.concShare, state = bull.rlGrowth.feedAdapted }
    end
    GrowthSim.setDaysPerPeriod(1)
    check(string.format("adaptation: a bull new to grain starts at %.2f of the ration and is at the 60%% target a month on (%.2f)",
        adapted[1].first, adapted[1].after), within(adapted[1].first, 0.2, 0.02) and within(adapted[1].after, 0.6, 1e-6))
    check(string.format("adaptation: the same in model time at 1 and 7 days a month (adapted %.3f / %.3f)", adapted[1].state, adapted[7].state),
        within(adapted[1].state, adapted[7].state, 0.01))

    local calf = GrowthSim.newborn("BULL_HOLSTEIN")
    local pen = FeedSim.makePen({ calf }, {}, { rearing = true })
    local refill = FeedSim.keepStocked({ CALFMILK = 5000, FORAGE = 5000, MAIZE = 2000 })
    local before = {}
    for month = 1, 5 do
        refill(pen)
        FeedSim.months(pen, 1, { refill = refill })
        before[month] = { weight = calf.weight, milk = calf.rlFeedIntake.byFill.CALFMILK ~= nil, maize = calf.rlFeedIntake.byFill.MAIZE ~= nil,
            class = calf.rlFeedIntake.class }
    end
    check("calves: in a rearing pen a calf drinks milk and eats solids from birth, no adult grain until weaned, then grain",
        before[1].milk and not before[1].maize and before[2].milk and not before[3].maize and before[5].class == "GROWING")
    check(string.format("calves: growth is continuous through weaning (%.0f, %.0f, %.0f, %.0f, %.0f kg)", before[1].weight, before[2].weight,
        before[3].weight, before[4].weight, before[5].weight), before[2].weight > before[1].weight and before[3].weight > before[2].weight
        and before[4].weight > before[3].weight and before[5].weight > before[4].weight and calf.health == 100)
end


-- Saving ---------------------------------------------------------------------------------------------

do
    local animal = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
    local pen = FeedSim.makePen({ animal }, {})
    RLFeed.setRation(pen, { target = "GROW", grain = "WHEAT", share = 0.2, substitute = false })
    FeedSim.months(pen, 1, { refill = FeedSim.keepStocked({ DRYGRASS_WINDROW = 1e5, WHEAT = 1e4 }) })
    local saved = {}
    local xml = {
        setString = function(_, k, v) saved[k] = v end, setFloat = function(_, k, v) saved[k] = v end,
        setInt = function(_, k, v) saved[k] = v end, setBool = function(_, k, v) saved[k] = v end,
        getString = function(_, k, d) local v = saved[k]; if v == nil then return d end return v end,
        getFloat = function(_, k, d) local v = saved[k]; if v == nil then return d end return v end,
        getInt = function(_, k, d) local v = saved[k]; if v == nil then return d end return v end,
        getBool = function(_, k, d) local v = saved[k]; if v == nil then return d end return v end,
        iterate = function(_, path, fn) local i = 0 while saved[string.format("%s(%d)#name", path, i)] ~= nil do fn(i, string.format("%s(%d)", path, i)) i = i + 1 end end,
    }
    RLFeed.savePen(pen, xml, "food")
    local copy = FeedSim.makePen({}, {})
    RLFeed.loadPen(copy, xml, "food")
    local spec, copySpec = pen.spec_husbandryFood, copy.spec_husbandryFood
    check("save: a pen's ration (target, grain, share, substitution) comes back as it was",
        copySpec.rlFeedRation.target == "GROW" and copySpec.rlFeedRation.grain == "WHEAT" and copySpec.rlFeedRation.share == 0.2
        and copySpec.rlFeedRation.substitute == false)
    local month = spec.rlFeedMonth or spec.rlFeedPrevious
    local copyMonth = copySpec.rlFeedMonth or copySpec.rlFeedPrevious
    check("save: its feed month (liters, DM, ME per fill type, the scale and feed data it was counted under) comes back unchanged",
        copyMonth ~= nil and copyMonth.hash == config.hash and copyMonth.scale == 0.2
        and within(copyMonth.byFill.WHEAT.liters, month.byFill.WHEAT.liters, 1e-9) and within(copyMonth.byFill.WHEAT.me, month.byFill.WHEAT.me, 1e-9))

    -- The rumen's adaptation is part of the weight model's saved and streamed state.
    local state = animal.rlGrowth
    local written = {}
    local stateXml = {
        setInt = function(_, k, v) written[k] = v end, setFloat = function(_, k, v) written[k] = v end,
        setString = function(_, k, v) written[k] = v end,
        getFloat = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
        getInt = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
        getString = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
    }
    RLGrowth.saveToXMLFile(state, stateXml, "a")
    local loaded = RLGrowth.loadFromXMLFile(stateXml, "a")
    check(string.format("save: the animal's adaptation to grain (%.3f) is saved with its growth state", state.feedAdapted or -1),
        loaded ~= nil and state.feedAdapted ~= nil and within(loaded.feedAdapted, state.feedAdapted, 1e-6))
    local copyAnimal = RLGrowth.copyState(state)
    check("save: a moved or cloned animal keeps its adaptation (it continues in its new pen)", copyAnimal.feedAdapted == state.feedAdapted)
end

FeedSim.setMode(false)
