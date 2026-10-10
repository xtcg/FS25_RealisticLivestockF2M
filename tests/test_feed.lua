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
    local calf = plannerAnimal({ class = "CALF", stage = "PRE_WEANING", concEligible = false, milkMax = 0.9, solidMax = 0.3, solidEnergy = 0.5,
        appetite = 1.2, fill = 0.5 })
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


-- Grain choice, milk bridge, MILKCOW ---------------------------------------------------------------

do
    local function wheatOnly(substitute)
        local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
        local pen = FeedSim.makePen({ bull }, { DRYGRASS_WINDROW = 1e5, MAIZE = 1e4 })
        RLFeed.setRation(pen, { grain = "WHEAT", substitute = substitute, share = 0.2 })
        for _ = 1, 3 do FeedSim.hour(pen) end
        return bull.rlFeedIntake
    end
    local strict, open = wheatOnly(false), wheatOnly(true)
    check("grain: wheat chosen without substitution and none in stock - no maize is fed instead, the shortage is named",
        strict.byFill.MAIZE == nil and strict.concLimit == "NO_CONCENTRATE")
    check("grain: with substitution allowed, maize stands in for the missing wheat", open.byFill.MAIZE ~= nil and open.byFill.MAIZE.kg > 0)
    local order = RLFeed.getConcentrateOrder({ grain = "WHEAT", substitute = true })
    check("grain: the chosen grain first, then the others (AUTO's order), then other concentrates; NONE offers nothing",
        order[1] == "WHEAT" and order[2] == "MAIZE" and #RLFeed.getConcentrateOrder({ grain = "NONE" }) == 0)

    local cow = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 48, isParent = true, isLactating = true, monthsSinceLastBirth = 2 })
    local sub = cow:getSubType()
    local mature = Economics.curve(sub.milk, 60)
    local realKg, mePerLiter = RLFeed.getMilkBridge(cow, mature * RLBodyCondition.getConfig().lactationMeanFactor)
    check(string.format("milk: a Holstein at the lactation average gives her breed's 30 kg a real day (%.2f); a game liter of her milk needs %.2f MJ",
        realKg, mePerLiter), within(realKg, 30, 1e-9) and within(mePerLiter, 30 * 30 / (mature * 1.08) * 5.0, 1e-9))

    local savedSystem = g_currentMission.animalSystem
    local types = { [7] = { name = "MILKCOW" } }
    g_currentMission.animalSystem = setmetatable({ getTypeByIndex = function(_, i) return types[i] or savedSystem:getTypeByIndex(i) end },
        { __index = savedSystem })
    local milkcowPen = FeedSim.makePen({}, {})
    milkcowPen.getAnimalTypeIndex = function() return 7 end
    local active, reason = RLFeed.evaluatePen(milkcowPen)
    g_currentMission.animalSystem = savedSystem
    check("MILKCOW: Hof Bergmann's milk cow keeps the old rules as its own capability (MILKCOW_LEGACY)", active == false and reason == "MILKCOW_LEGACY")
end


-- Clients, events, log, report -----------------------------------------------------------------------

do
    local stream, readAt = {}, 0
    local function w(_, v) stream[#stream + 1] = v end
    local function r() readAt = readAt + 1; return stream[readAt] end
    streamWriteBool, streamWriteFloat32, streamWriteString, streamWriteUInt8, streamWriteUInt16 = w, w, w, w, w
    streamReadBool, streamReadFloat32, streamReadString, streamReadUInt8, streamReadUInt16 = r, r, r, r, r

    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local pen = FeedSim.makePen({ bull }, {})
    RLFeed.setRation(pen, { target = "FINISH", grain = "MAIZE", share = 0.3, substitute = false })
    FeedSim.months(pen, 1, { refill = FeedSim.keepStocked({ DRYGRASS_WINDROW = 1e5, MAIZE = 1e4 }) })
    RLFeed.writePenStream(pen, 1)
    RLFeed.writeAnimalStream(bull, 1)
    local penData = RLFeed.readPenStream(1)
    local animalData = RLFeed.readAnimalStream(1)
    local month = pen.spec_husbandryFood.rlFeedMonth or pen.spec_husbandryFood.rlFeedPrevious
    check("network: a pen's mode, ration and feed month reach clients as the server has them",
        readAt == #stream and penData.active == true and penData.reason == "OK" and penData.ration.grain == "MAIZE"
        and penData.ration.share == 0.3 and penData.ration.substitute == false
        and (month == nil or within(penData.byFill.MAIZE.liters, month.byFill.MAIZE.liters, 1e-6)))
    local record = bull.rlFeedIntake
    check("network: an animal's real intake a day, ME, concentrate share, limits and target reach clients",
        animalData ~= nil and within(animalData.kgPerDay, record.kg / record.dtDays, 1e-9) and within(animalData.mePerDay, record.me / record.dtDays, 1e-9)
        and animalData.target == "FINISH" and animalData.class == "GROWING" and within(animalData.concShare, record.concShare, 1e-9))

    -- The ration event: a client asks, the server checks, applies and tells everyone.
    loadMod("scripts/events/RLFeedRationEvent.lua")
    local broadcasts = {}
    g_server = { broadcastEvent = function(_, event) broadcasts[#broadcasts + 1] = event end }
    local permitted = true
    RLPermissionHelper = { authorizeConnection = function() return permitted, permitted and nil or "NO_PERMISSION", "tester" end }
    pen.getOwnerFarmId = function() return 1 end
    local event = RLFeedRationEvent.new(pen, { target = "MAINTAIN", grain = "AUTO", share = nil, substitute = true })
    event:run(makeConnection(5, false))
    check("event: a permitted client's ration is applied on the server and sent on to every client",
        RLFeed.getRation(pen).target == "MAINTAIN" and #broadcasts == 1 and broadcasts[1].ration.target == "MAINTAIN")
    permitted = false
    local logged = #LOG
    RLFeedRationEvent.new(pen, { target = "GROW" }):run(makeConnection(6, false))
    check("event: a client without the permission changes nothing", RLFeed.getRation(pen).target == "MAINTAIN" and #broadcasts == 1)
    permitted = true
    RLFeedRationEvent.new(pen, { target = "EAT_EVERYTHING" }):run(makeConnection(5, false))
    check("event: a ration with a value out of range is dropped, not fixed up", RLFeed.getRation(pen).target == "MAINTAIN" and #broadcasts == 1)
    while #LOG > logged do table.remove(LOG) end
    g_server = nil

    -- FEED_DAY: a pen's day in the mode in one log line.
    local before = #LOG
    local lines = {}
    local savedEmit = RLPenLog.emit
    RLPenLog.emit = function(kind, data) lines[#lines + 1] = { kind = kind, data = data } return "" end
    RLFeed.setRation(pen, { target = "FINISH", grain = "MAIZE", share = 0.3 })
    local refill = FeedSim.keepStocked({ DRYGRASS_WINDROW = 1e5, MAIZE = 1e4 })
    pen.spec_husbandryFood.rlFeedDay = nil
    for _ = 1, 24 do refill(pen); FeedSim.hour(pen) end
    RLFeed.onPenDayChanged(pen)
    RLPenLog.emit = savedEmit
    while #LOG > before do table.remove(LOG) end
    local day = lines[1] ~= nil and lines[1].data or {}
    check("log: FEED_DAY gives the pen's day - hours, liters, real DM and ME per feed, coverage, the ration and each animal",
        lines[1] ~= nil and lines[1].kind == "FEED_DAY" and day.active == true and day.hours == 24 and day.fills.MAIZE ~= nil
        and day.fills.MAIZE.liters > 0 and day.fills.DRYGRASS_WINDROW.kgDM > 0 and day.ration.grain == "MAIZE" and #day.animals == 1
        and day.animals[1].target == "FINISH" and pen.spec_husbandryFood.rlFeedDay == nil)

    -- The report runs on the server's pens (read-only).
    loadMod("scripts/console/RLFeedConsole.lua")
    g_currentMission.husbandrySystem = { placeables = { pen } }
    local printed = {}
    local savedPrint = print
    print = function(text) printed[#printed + 1] = text end
    local okReport, message = pcall(RLFeedConsole.report, RLFeedConsole, "animals")
    print = savedPrint
    if not okReport then LOG[#LOG + 1] = "report: " .. tostring(message) end
    check("console: rlFeedReport lists the pen, its feeds with months left and its animal", okReport and message == "rlFeedReport: 1 pen(s)"
        and (function() for _, line in ipairs(printed) do if line:find("MAIZE", 1, true) and line:find("left", 1, true) then return true end end end)())
    g_currentMission.husbandrySystem = nil
end


-- The old rules never eat the grain group; the mode's pens feed through the engine's call -------------

do
    local engineCalls = 0
    local savedUtils = Utils
    Utils = { appendedFunction = function(first, second) return function(...) first(...); second(...) end end }
    AnimalFoodSystem = {
        loadMapData = function() end,
        consumeFood = function() engineCalls = engineCalls + 1 return 0.5 end,
        consumeFoodGroup = function(_, _, amount) return 0 end,
    }
    local mode = RLFeed.mode
    loadMod("scripts/feed/RLFeed.lua")
    RLFeed.mode = mode
    local grainGroup
    for _, g in ipairs(FeedSim.cowFood.groups) do if g.rlGrain then grainGroup = g end end
    check("legacy: the engine's group consumption leaves the grain group untouched (amount returned, nothing taken)",
        AnimalFoodSystem.consumeFoodGroup(nil, grainGroup, 12, nil, {}) == 12
        and AnimalFoodSystem.consumeFoodGroup(nil, FeedSim.cowFood.groups[1], 12, nil, {}) == 0)
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local pen = FeedSim.makePen({ bull }, { FORAGE = 1e4 })
    RLFeed.beginFeeding(pen)
    local consumed = {}
    local factor = AnimalFoodSystem.consumeFood(nil, GrowthSim.COW_TYPE, 99, pen, consumed)
    check("engine: in a pen running the mode, consumeFood is the planner's - its liters per fill type, its food factor",
        engineCalls == 0 and consumed[FILL.FORAGE] ~= nil and consumed[FILL.FORAGE] > 0 and factor > 0.99)
    local other = FeedSim.makePen({}, {})
    AnimalFoodSystem.consumeFood(nil, GrowthSim.COW_TYPE, 99, other, {})
    check("engine: any other pen keeps the engine's own consumption", engineCalls == 1)
    AnimalFoodSystem, Utils = nil, savedUtils
end


-- Panels and forecast (RLFeedInfoService) -------------------------------------------------------------

loadMod("scripts/gui/rlmenu/services/RLPenFeedForecast.lua")
loadMod("scripts/gui/rlmenu/services/RLDetailPaneHelper.lua")

do
    local I = RLFeedInfoService
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local pen = FeedSim.makePen({ bull }, {})
    pen.spec_husbandryFood.capacity = 50000
    local refill = FeedSim.keepStocked({ DRYGRASS_WINDROW = 8000, MAIZE = 200 })
    for _ = 1, 48 do refill(pen); FeedSim.hour(pen) end
    pen:add("ROUNDBALE", 5)
    local rows = I.getFeedRows(pen)
    local byName = {}
    for _, row in ipairs(rows) do byName[row.name] = row end
    check("panel: one row per feed - hay and maize eaten with their DM share, wheat shown at zero stock, the unconfigured bale flagged",
        byName.DRYGRASS_WINDROW ~= nil and byName.DRYGRASS_WINDROW.status == "EATEN" and byName.MAIZE.status == "EATEN"
        and byName.DRYGRASS_WINDROW.dmShare > 0.5 and byName.WHEAT ~= nil and byName.WHEAT.status == "EMPTY" and byName.WHEAT.stock == 0
        and byName.ROUNDBALE ~= nil and byName.ROUNDBALE.status == "UNCONFIGURED" and byName.FORAGE == nil and byName.CALFMILK == nil)
    local months, first = I.getMonthsLeft(pen)
    check(string.format("forecast: each feed at its own planned liters a month - maize runs out first (%.2f months), not a pooled liter count",
        months or -1), first ~= nil and first.name == "MAIZE" and months < byName.DRYGRASS_WINDROW.monthsLeft
        and RLPenFeedForecast.getMonthsRemaining(pen, 1e6) == math.floor(months)
        and within(RLPenFeedForecast.getDaysRemaining(pen, 1e6), months * GrowthSim.env.daysPerPeriod, 1e-9))

    local infos = I.adjustFoodInfos(pen, {})
    check("panel: the pen's food rows in the mode are its feeds (stock, planned liters a month), not the map's groups",
        #infos == #rows and (function()
            for _, info in ipairs(infos) do
                if info.rlFeedRow.name == "MAIZE" then
                    return info.valueText ~= nil and info.rlFeedRow.plannedPerMonth > 0 and info.value == info.rlFeedRow.stock and not info.disabled
                end
            end
        end)())

    local penRows = I.getPenInfoRows(pen)
    check("panel: the pen info box shows the mode, the ration, the energy fed and the feed that runs out first",
        #penRows == 4 and penRows[1].titleKey == "rl_feed_penMode" and penRows[4].titleKey == "rl_feed_penFirstOut")

    local animalRows = I.getAnimalRows(bull)
    local keys = {}
    for _, row in ipairs(animalRows) do keys[row.key] = row end
    local finishState, finishMonths = I.getFinishForecast(bull, I.getAnimalInfo(bull))
    check(string.format("panel: a bull's rows - real DM intake against plan, concentrate share and its limit, finishing forecast (%s, %.1f months)",
        tostring(finishState), finishMonths or -1), keys.feedIntake ~= nil and keys.feedIntake.valueText ~= nil and keys.feedLimit ~= nil
        and keys.feedFinish ~= nil and finishState == "MONTHS" and finishMonths > 0)
    bull.rlFeedIntake.gainPerMonth = 0.2
    local state = I.getFinishForecast(bull, I.getAnimalInfo(bull))
    check("panel: a bull that hardly gains is shown stalled (feed more), never an endless month count", state == "STALLED")

    -- The old rules: the grain group's row says it is not eaten, and goes while it holds nothing.
    FeedSim.setMode(false)
    local legacyPen = FeedSim.makePen({ (GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })) }, { FORAGE = 100 })
    FeedSim.hour(legacyPen)
    local base = {}
    for _, group in ipairs(FeedSim.cowFood.groups) do table.insert(base, { title = group.title, value = group.rlGrain and 0 or 1 }) end
    local adjusted = I.adjustFoodInfos(legacyPen, base)
    local stocked = {}
    for _, group in ipairs(FeedSim.cowFood.groups) do table.insert(stocked, { title = group.title, value = group.rlGrain and 300 or 1 }) end
    local adjustedStocked = I.adjustFoodInfos(legacyPen, stocked)
    check("panel: under the old rules an empty grain row is left out, a stocked one is marked as not eaten",
        #adjusted == #FeedSim.cowFood.groups - 1 and adjustedStocked[#adjustedStocked].title:find("rl_feed_grainNotEaten", 1, true) ~= nil
        and adjustedStocked[#adjustedStocked].disabled == true and #I.getPenInfoRows(legacyPen) == 0)
    FeedSim.setMode(true)

    -- The menu clones food rows beyond its five slots.
    local function element(children)
        local e = { elements = children or {}, visible = true }
        function e:setVisible(v) self.visible = v end
        return e
    end
    local layout = { invalidated = 0 }
    function layout:invalidateLayout() self.invalidated = self.invalidated + 1 end
    local function makeRow()
        local row = element({ element({ element(), element() }), element({ element() }) })
        row.parent = layout
        function row:clone(parent) local copy = makeRow(); copy.parent = parent; return copy end
        return row
    end
    local frame = { foodRow = {}, foodLabel = {}, foodValue = {}, foodStatusBar = {} }
    for i = 1, 5 do
        frame.foodRow[i] = makeRow()
        frame.foodLabel[i], frame.foodValue[i], frame.foodStatusBar[i] = frame.foodRow[i].elements[1].elements[1],
            frame.foodRow[i].elements[1].elements[2], frame.foodRow[i].elements[2].elements[1]
    end
    RLDetailPaneHelper.ensureFoodRows(frame, 8)
    check("menu: food rows past the five slots are cloned with their label, value and bar, and the layout redone",
        #frame.foodRow == 8 and frame.foodLabel[8] == frame.foodRow[8].elements[1].elements[1]
        and frame.foodStatusBar[8] == frame.foodRow[8].elements[2].elements[1] and layout.invalidated == 1)
end


-- Review fixes -----------------------------------------------------------------------------------------

do
    -- A feed's stages are enforced: a forage only weaned animals may eat is not fed to a calf.
    local hay = F.getUsableFeed("DRYGRASS_WINDROW")
    local weanedHay = {}
    for k, v in pairs(hay) do weanedHay[k] = v end
    weanedHay.stages = { WEANED = true }
    local calf = plannerAnimal({ class = "CALF", stage = "PRE_WEANING", concEligible = false, milkMax = 0.9, solidMax = 0.3,
        solidEnergy = 0.5, appetite = 1.2, fill = 0.5 })
    local bull = plannerAnimal()
    plan({ calf, bull }, { { name = "DRYGRASS_WINDROW", profile = weanedHay, liters = 1e6 } }, {}, { entry("CALFMILK", 1e6) })
    check("stages: a forage for weaned animals only is not fed to a calf on milk; the bull beside it eats it",
        calf.byFill.DRYGRASS_WINDROW == nil and calf.byFill.CALFMILK ~= nil and bull.byFill.DRYGRASS_WINDROW ~= nil)

    -- Protein for milk follows the cow's milk: a suckler cow is not held back like a dairy cow on hay.
    local protein = config.protein
    check("protein: a lactating cow's need moves from the dry cow's with her real milk (8 kg: below 12%, 30 kg: 16%)",
        RLFeedMath.getProteinNeed("LACTATING", 48, protein, 0, 8) < 0.12 and within(RLFeedMath.getProteinNeed("LACTATING", 48, protein, 0, 30), 0.16, 1e-9)
        and within(RLFeedMath.getProteinNeed("LACTATING", 48, protein, 0, 45), 0.16, 1e-9))

    -- Calf rearing off: a calf on milk still keeps its normal pen on the old rules.
    local rearing = RLCalfRearing.config
    RLCalfRearing.config = table.clone(RLCalfRearing.getConfig())
    RLCalfRearing.config.enabled = false
    local cow = GrowthSim.makeAnimal("COW_ANGUS", { age = 48, isParent = true, isLactating = true, monthsSinceLastBirth = 0 })
    local newborn = GrowthSim.newborn("BULL_ANGUS")
    local pen = FeedSim.makePen({ cow, newborn }, { FORAGE = 5000 })
    local active, reason = RLFeed.evaluatePen(pen)
    RLCalfRearing.config = rearing
    check("calves: with calf rearing switched off, a suckling calf still keeps its pen on the old rules (SUCKLING_CALF)",
        active == false and reason == "SUCKLING_CALF")

    -- A planned fill with nothing removed was not eaten.
    local steer = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local blocked = FeedSim.makePen({ steer }, { FORAGE = 5000 })
    blocked.removeFood = function() return 0 end
    FeedSim.hour(blocked)
    check("ledger: a fill type the trough lost nothing of is not credited (no free nutrition)",
        steer.rlFeedIntake.kg == 0 and steer.rlFeedIntake.me == 0)

    -- A failing plan leaves the pen's hour on the old rules, logged.
    local savedPlan = RLFeedRationPlanner.plan
    RLFeedRationPlanner.plan = function() error("broken plan") end
    local failing = FeedSim.makePen({ (GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })) }, { FORAGE = 5000 })
    RLFeed.beginFeeding(failing)
    local ok = pcall(function()
        local consumed = {}
        local okPlan, message = pcall(RLFeed.consume, failing, consumed)
        if not okPlan then RLFeed.onPlanError(failing, message) end
    end)
    RLFeedRationPlanner.plan = savedPlan
    local logged = false
    for i = #LOG, 1, -1 do if LOG[i]:find("ration plan failed", 1, true) then logged = true; table.remove(LOG, i) end end
    check("errors: a plan that fails leaves the pen's hour on the old rules (ERROR), logged once",
        ok and failing.spec_husbandryFood.rlFeedPen.active == false and failing.spec_husbandryFood.rlFeedPen.reason == "ERROR"
        and failing.spec_husbandryFood.rlFeedWindow == nil and logged and RLFeed.getStepFeed(failing.animals[1]) == nil)

    -- Under the old rules the trough takes no new grain; in the mode it does.
    FeedSim.setMode(false)
    local legacyPen = FeedSim.makePen({}, {})
    local refusesGrain = not RLFeed.acceptsFill(legacyPen, FILL.MAIZE) and RLFeed.acceptsFill(legacyPen, FILL.FORAGE)
    FeedSim.setMode(true)
    check("grain: under the old rules a cattle trough takes no new grain (never eaten there); in the mode it does",
        refusesGrain and RLFeed.acceptsFill(legacyPen, FILL.MAIZE))

    -- A month counted under other feed data ends; the next hour starts a new one.
    local animal = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local monthPen = FeedSim.makePen({ animal }, { FORAGE = 1e5 })
    for _ = 1, 3 do FeedSim.hour(monthPen) end
    local before = monthPen.spec_husbandryFood.rlFeedMonth
    config.resourceScale = 0.3
    FeedSim.hour(monthPen)
    config.resourceScale = 0.2
    local after = monthPen.spec_husbandryFood.rlFeedMonth
    check("month: feed data changed mid-month - the old month is kept as counted (incomplete), a new one starts",
        after ~= before and monthPen.spec_husbandryFood.rlFeedPrevious == before and before.complete == false and after.hours == 1
        and after.scale == 0.3)

    -- Feed rows only while the pen runs the mode, and only this hour's record.
    local shown = #RLFeedInfoService.getAnimalRows(animal) > 0
    FeedSim.setMode(false)
    local hiddenOff = #RLFeedInfoService.getAnimalRows(animal) == 0
    FeedSim.setMode(true)
    animal.rlFeedIntake.tick = animal.rlFeedIntake.tick - 5
    local hiddenStale = #RLFeedInfoService.getAnimalRows(animal) == 0
    check("panel: an animal's feed rows show only while its pen runs the mode, from a record of this hour", shown and hiddenOff and hiddenStale)

    -- Shares above 0.8 are out of range.
    local _, okShare = RLFeed.sanitizeRation({ share = 0.95 })
    check("ration: a concentrate share target above 0.8 is refused", okShare == false)
end

FeedSim.setMode(false)
