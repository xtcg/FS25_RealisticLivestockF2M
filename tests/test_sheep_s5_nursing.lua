-- Sheep S5 nursing rules (feedProfiles.xml species SHEEP nursing) in the real-equivalent mode:
-- ewes nurse their own lambs from one finite pool on AHDB Table 28's rows, the pool is paid by the
-- ewe's budget and never stored or sold, lambs wean by age, an orphan gets no milk and is weaned
-- early only after days in a row on creep feed, lambs at foot eat at most the creep allowance, and
-- the feeds added for sheep are taken only by pens that eat them. Behaviour, not calibration.

loadMod("tests/sheepsim.lua")

local FILL = FeedSim.FILL
local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end

FeedSim.setMode(true)
SheepSim.enable(true)
GrowthSim.setDaysPerPeriod(1)

local GRASS = { GRASS_WINDROW = 3000 }

local function stepEvents(pen, hours, stock)
    local steps = {}
    local function observe(kind, data) if kind == "STEP" then steps[#steps + 1] = data end end
    RLFeed.addObserver(observe)
    SheepSim.run(pen, hours or 1, stock or GRASS)
    RLFeed.removeObserver(observe)
    return steps
end


-- Coverage ---------------------------------------------------------------------------------------

do
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "E1")
    local l1, l2 = SheepSim.lamb("RAM_LANDRACE", "E1", "L1"), SheepSim.lamb("SHEEP_LANDRACE", "E1", "L2")
    local pen = SheepSim.makePen({ ewe, l1, l2 }, GRASS)
    FeedSim.hour(pen)
    local state = pen.spec_husbandryFood.rlFeedPen
    check("coverage: a ewe with twins runs the mode (sheep curves on, real-equivalent model)", state.active and state.reason == "OK")
    check("coverage: lambs on milk, the ewe in milk, a ewe without lambs dry",
        RLFeed.getRationClass(l1) == "CALF" and RLFeed.getRationClass(ewe) == "LACTATING"
        and RLFeed.getRationClass(SheepSim.ewe("SHEEP_LANDRACE", "E9")) == "DRY")

    local orphan = SheepSim.lamb("RAM_LANDRACE", "E7", "L7")
    local orphanPen = SheepSim.makePen({ orphan }, GRASS)
    FeedSim.hour(orphanPen)
    check("coverage: a lamb without its ewe keeps the pen in the mode (no milk made for it, no SUCKLING_CALF)",
        orphanPen.spec_husbandryFood.rlFeedPen.active and RLFeed.getRationClass(orphan) == "CALF")

    SheepSim.enable(false)
    local off = SheepSim.makePen({ SheepSim.ewe("SHEEP_LANDRACE", "E8") }, GRASS)
    FeedSim.hour(off)
    check("coverage: with the sheep curves off a sheep pen keeps the old rules (UNCOVERED_ANIMAL)",
        not off.spec_husbandryFood.rlFeedPen.active and off.spec_husbandryFood.rlFeedPen.reason == "UNCOVERED_ANIMAL")
    SheepSim.enable(true)
    check("coverage: sheep are on the weight model v2 with no mode setting", RLGrowth.covers(ewe))
end


-- The ewe's milk: AHDB Table 28 rows ------------------------------------------------------------

do
    local function damWith(name, lambs, lambAge)
        local ewe = SheepSim.ewe(name, "D")
        local animals = { ewe }
        for i = 1, lambs do
            local lamb = SheepSim.grown(i % 2 == 0 and "SHEEP_LANDRACE" or "RAM_LANDRACE", "Y" .. i, lambAge, { motherId = "D" })
            animals[#animals + 1] = lamb
        end
        SheepSim.makePen(animals, GRASS)
        return ewe
    end
    local single, twins, triplets = damWith("SHEEP_LANDRACE", 1, 0.5), damWith("SHEEP_LANDRACE", 2, 0.5), damWith("SHEEP_LANDRACE", 3, 0.5)
    local kg1 = RLFeed.getDamMilk(single)
    local kg2, n2 = RLFeed.getDamMilk(twins)
    local kg3, n3 = RLFeed.getDamMilk(triplets)
    check(string.format("milk: lowland ewe month 1 single %.2f, twins %.2f, triplets held at the twin row %.2f kg a day", kg1, kg2, kg3),
        kg1 == 2.10 and kg2 == 3.00 and n2 == 2 and kg3 == 3.00 and n3 == 3)
    check("milk: month 2 and 3 of twins (2.25, 1.50); hill breed twins month 1 (1.90)",
        RLFeed.getDamMilk(damWith("SHEEP_LANDRACE", 2, 1.5)) == 2.25 and RLFeed.getDamMilk(damWith("SHEEP_LANDRACE", 2, 2.5)) == 1.50
        and RLFeed.getDamMilk(damWith("SHEEP_STEINSCHAF", 2, 0.5)) == 1.90)
    check("milk: weaned lambs (3 months) leave the ewe dry", RLFeed.getDamMilk(damWith("SHEEP_LANDRACE", 2, 3.2)) == 0
        and RLFeed.getRationClass(damWith("SHEEP_LANDRACE", 2, 3.2)) == "DRY")
end


-- The pool: paid by the ewe, shared by her lambs, never stored ---------------------------------

do
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "P1")
    local l1, l2 = SheepSim.lamb("RAM_LANDRACE", "P1", "PL1"), SheepSim.lamb("SHEEP_LANDRACE", "P1", "PL2")
    local stranger = SheepSim.lamb("RAM_LANDRACE", "P9", "PL9")
    local pen = SheepSim.makePen({ ewe, l1, l2, stranger }, GRASS)
    local steps = stepEvents(pen, 6)
    local ok, checked, strangerMilk = true, 0, 0
    for _, data in ipairs(steps) do
        local drunk = 0
        for _, entry in ipairs(data.animals) do
            local milk = entry.feed.damMilk
            if milk ~= nil and entry.animal.motherId == "P1" then drunk = drunk + milk.kg end
            if entry.animal == stranger and milk ~= nil then strangerMilk = strangerMilk + milk.kg end
        end
        for _, d in ipairs(data.dams) do
            checked = checked + 1
            ok = ok and near(drunk, d.allocatedKg, 1e-9) and d.allocatedKg <= d.paidKg + 1e-9 and d.calves == 2
        end
    end
    check(string.format("pool: every step her lambs drink what she paid, never more (%d steps)", checked), ok and checked > 0)
    check("pool: another ewe's lamb gets none of her milk (no fostering)", strangerMilk == 0)
    check("pool: the ewe's milk is never stored or sold (milk to the store 0)",
        ewe.rlFeedIntake.milkLiters == 0 and ewe.rlMilkPaid.litersPerHour == 0 and ewe.rlFeedIntake.milkPaidLiters > 0)
    local planned, demand = 0, 0
    for _, d in ipairs(steps[1].dams) do planned = d.plannedKg end
    for _, e in ipairs(steps[1].animals) do
        if e.animal.motherId == "P1" then demand = demand + (e.feed.nursingDemandKg or 0) end
    end
    -- Unified nursing (2026-10-22): the twins plan their own demand - no ewe milk table caps it; she
    -- pays for it (or the share she can).
    check(string.format("pool: twins plan their own demand from her (%.4f of %.4f kg DM a step), no milk table cap", planned, demand),
        planned > 0 and planned <= demand + 1e-12 and planned >= 0.5 * demand)
end


-- Orphans ----------------------------------------------------------------------------------------

do
    local young = SheepSim.grown("RAM_LANDRACE", "O1", 1.0, { motherId = "GONE" })
    local pen = SheepSim.makePen({ young }, GRASS)
    local steps = stepEvents(pen, 3)
    local milk = 0
    for _, data in ipairs(steps) do for _, e in ipairs(data.animals) do if e.feed.damMilk ~= nil then milk = milk + e.feed.damMilk.kg end end end
    check("orphan: a one-month orphan drinks no milk and is not weaned early (it lives on what it eats)",
        milk == 0 and not RLFeed.isEarlyWeaned(young) and RLFeed.getRationClass(young) == "CALF")

    local ready = SheepSim.grown("RAM_LANDRACE", "O2", 2.2, { motherId = "GONE" })
    local notReady = SheepSim.grown("RAM_LANDRACE", "O3", 2.2, { motherId = "GONE" })
    SheepSim.makePen({ ready, notReady }, GRASS)
    ready.rlGrowth.creepDays, notReady.rlGrowth.creepDays = 3.5, 3.0
    check("orphan: from 2 months an orphan 3.5 days in a row on creep is weaned; one 3 days on it is not",
        RLFeed.isEarlyWeaned(ready) and RLFeed.getRationClass(ready) == "GROWING"
        and not RLFeed.isEarlyWeaned(notReady) and RLFeed.getRationClass(notReady) == "CALF")
    local withDam = SheepSim.grown("RAM_LANDRACE", "O4", 2.2, { motherId = "M4" })
    withDam.rlGrowth.creepDays = 10
    SheepSim.makePen({ SheepSim.ewe("SHEEP_LANDRACE", "M4"), withDam }, GRASS)
    check("orphan: a lamb with its ewe is never weaned early", not RLFeed.isEarlyWeaned(withDam) and RLFeed.getRationClass(withDam) == "CALF")

    -- Grass alone never makes an orphan ready, however long it eats it.
    local onGrass = SheepSim.grown("RAM_LANDRACE", "O6", 2.1, { motherId = "GONE" })
    local grassPen = SheepSim.makePen({ onGrass })
    local steps = stepEvents(grassPen, 6, GRASS)
    local grassKg = 0
    for _, data in ipairs(steps) do for _, e in ipairs(data.animals) do grassKg = grassKg + e.feed.kg end end
    check(string.format("orphan: on grass alone (%.2f kg DM eaten) it is never ready (creep days %s)", grassKg, tostring(onGrass.rlGrowth.creepDays)),
        grassKg > 0 and (onGrass.rlGrowth.creepDays or 0) == 0 and not RLFeed.isEarlyWeaned(onGrass))

    -- Creep days count model days in a row on creep; one step without it starts again.
    local lamb = SheepSim.grown("RAM_LANDRACE", "O5", 2.1, { motherId = "GONE" })
    local lambPen = SheepSim.makePen({ lamb })
    local creep = { GRASS_WINDROW = 3000, BARLEY = 500 }
    SheepSim.run(lambPen, 1, creep)
    local first = lamb.rlGrowth.creepDays or 0
    check(string.format("orphan: one hour (1.25 model days) on creep is not enough (%.2f days)", first),
        first > 0 and first < 3.5 and not RLFeed.isEarlyWeaned(lamb))
    lamb.rlGrowth.creepDays = 2.5
    lambPen.spec_husbandryFood.fillLevels[FILL.BARLEY] = 0
    SheepSim.run(lambPen, 1, GRASS)
    check("orphan: a step without creep starts the count again", (lamb.rlGrowth.creepDays or -1) == 0)
    local hours = 0
    while not RLFeed.isEarlyWeaned(lamb) and hours < 10 do
        SheepSim.run(lambPen, 1, creep)
        hours = hours + 1
    end
    check(string.format("orphan: weaned after %d hours in a row on creep (%.2f model days)", hours, lamb.rlGrowth.creepDays or -1),
        hours == 3 and lamb.rlGrowth.creepDays >= 3.5)
    lambPen.spec_husbandryFood.fillLevels[FILL.BARLEY] = 0
    SheepSim.run(lambPen, 1, GRASS)
    check("orphan: once ready it stays weaned when the creep runs out", RLFeed.isEarlyWeaned(lamb))
end


-- Creep ------------------------------------------------------------------------------------------

do
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "C1")
    -- On hay at 2.5 months its dam's milk and the forage leave a gap creep feed fills (on grass a
    -- younger lamb at a ewe paying its whole demand needs none).
    local lamb = SheepSim.grown("RAM_LANDRACE", "CL1", 2.5, { motherId = "C1" })
    local pen = SheepSim.makePen({ ewe, lamb })
    local steps = stepEvents(pen, 10, { DRYGRASS_WINDROW = 3000, BARLEY = 3000 })
    local worst = 0
    for _, data in ipairs(steps) do
        for _, e in ipairs(data.animals) do
            if e.animal == lamb then
                local barley = e.feed.byFill.BARLEY
                if barley ~= nil then worst = math.max(worst, barley.kg / e.feed.dtDays) end
            end
        end
    end
    check(string.format("creep: a lamb at foot eats at most 0.35 kg DM of concentrate a day (most %.3f)", worst), worst > 0 and worst <= 0.35 + 1e-9)
end


-- Troughs: the feeds added for sheep ------------------------------------------------------------

do
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "T1")
    local pen = SheepSim.makePen({ ewe })
    local silage, barley, grass = FILL.SILAGE, FILL.BARLEY, FILL.GRASS_WINDROW
    check("troughs: the sheep pen lists silage and grain beside the map's grass group",
        pen.spec_husbandryFood.supportedFillTypes[grass] and SheepSim.food.groups[2].rlSpecies == "SHEEP" and SheepSim.food.groups[2].rlGrain)
    FeedSim.hour(pen)
    check("troughs: with sheep running the mode the pen takes silage and grain", RLFeed.acceptsFill(pen, silage) and RLFeed.acceptsFill(pen, barley)
        and RLFeed.acceptsFill(pen, grass))
    local goat = SheepSim.identify((SheepSim.uncovered()), "G1")
    local mixed = SheepSim.makePen({ SheepSim.ewe("SHEEP_LANDRACE", "T2"), goat })
    FeedSim.hour(mixed)
    check("troughs: a pen with an uncovered animal (never in the mode) takes no silage or grain; its pen keeps the old rules",
        not RLFeed.acceptsFill(mixed, silage) and not RLFeed.acceptsFill(mixed, barley) and RLFeed.acceptsFill(mixed, grass)
        and mixed.spec_husbandryFood.rlFeedPen.reason == "UNCOVERED_ANIMAL")
    -- A sheep in that pen is held (RLFeed.holdUnsettled): no budget, no old weight rule, so its
    -- development clock and weight stand still. Its age clock runs on model time (U43-AGE-01): six
    -- hours of a one-day month.
    local mixedLamb = SheepSim.grown("RAM_LANDRACE", "T3", 2.0)
    local mixedPen = SheepSim.makePen({ mixedLamb, goat }, GRASS)
    local development, ageClock, weight = mixedLamb.rlGrowth.developmentMonths, mixedLamb.rlGrowth.ageMonths, mixedLamb.weight
    local lastTick = mixedLamb.rlGrowth.lastTick
    SheepSim.run(mixedPen, 6, GRASS)
    check(string.format("mixed pen: a lamb with an uncovered animal is held (development %.4f -> %.4f, age clock %.4f -> %.4f, last step %s, weight %.2f -> %.2f)",
        development, mixedLamb.rlGrowth.developmentMonths, ageClock, mixedLamb.rlGrowth.ageMonths, tostring(mixedLamb.rlGrowth.lastTick), weight, mixedLamb.weight),
        not mixedPen.spec_husbandryFood.rlFeedPen.active and mixedLamb.rlGrowth.developmentMonths == development
        and math.abs(mixedLamb.rlGrowth.ageMonths - (ageClock + 6 / 24)) < 1e-9 and mixedLamb.rlGrowth.lastTick == lastTick
        and mixedLamb.weight == weight)
    GrowthSim.advanceHour()
    SheepSim.enable(false)
    pen.spec_husbandryFood.rlSpeciesFeedOpen = nil
    check("troughs: with the sheep curves off neither", not RLFeed.acceptsFill(pen, silage))
    SheepSim.enable(true)
    pen.spec_husbandryFood.rlSpeciesFeedOpen = nil
    local cows = FeedSim.makePen({ GrowthSim.makeAnimal("COW_ANGUS", { age = 30 }) })
    check("troughs: cattle pens take grain in the mode as before", RLFeed.acceptsFill(cows, barley))
end


-- Month length -----------------------------------------------------------------------------------

do
    local function oneMonth(days)
        GrowthSim.setDaysPerPeriod(days)
        local ewe = SheepSim.ewe("SHEEP_LANDRACE", "M1")
        local lamb = SheepSim.lamb("RAM_LANDRACE", "M1", "ML1")
        local pen = SheepSim.makePen({ ewe, lamb })
        SheepSim.run(pen, 24 * days, { GRASS_WINDROW = 3000, BARLEY = 500 })
        return lamb.weight, ewe.weight
    end
    local l1, e1 = oneMonth(1)
    local l7, e7 = oneMonth(7)
    local l28, e28 = oneMonth(28)
    GrowthSim.setDaysPerPeriod(1)
    local function rel(a, b) return math.abs(a - b) / b end
    check(string.format("month length: a lamb's and its ewe's first month the same at 1, 7 and 28 days (lamb %.2f / %.2f / %.2f kg)", l1, l7, l28),
        rel(l7, l1) < 0.01 and rel(l28, l1) < 0.01 and rel(e7, e1) < 0.01 and rel(e28, e1) < 0.01)
end


-- Display (S5b): fat class, verdict, pen rows, the lamb-without-ewe notification -------------------

do
    GrowthSim.setDaysPerPeriod(1)
    local ram = SheepSim.grown("RAM_LANDRACE", "F1", 3.5)
    local eweLamb = SheepSim.grown("SHEEP_LANDRACE", "F2", 3.5)
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "F3")
    local pen = SheepSim.makePen({ ram, eweLamb, ewe }, GRASS)
    local function setReserve(animal, r)
        RLGrowth.setReserveIndex(animal, r)
        RLBodyCondition.ensureState(animal, "test").reserve = r
    end
    setReserve(ram, 0.42)
    setReserve(eweLamb, 0.62)
    check("display: a lamb shows its EUROP fat class (3L at reserve 0.42, 4L at 0.62), a ewe her BCS",
        RLBodyCondition.getFatClass(ram) == "3L" and RLBodyCondition.getFatClass(eweLamb) == "4L" and RLBodyCondition.getFatClass(ewe) == nil
        and RLBodyCondition.getInfoText(ram):sub(1, 2) == "3L")
    local tup = SheepSim.ewe("RAM_LANDRACE", "F4")
    check("display: a grown ram shows BCS, as a ewe does", RLBodyCondition.getFatClass(tup) == nil
        and RLBodyCondition.getInfoText(tup):find("rl_ui_bcs") ~= nil)
    check("display: a ewe lamb is read against her breed's ram lamb market weight, not a grown ewe's",
        near(RLBodyCondition.getReferenceWeight(eweLamb), RLBodyCondition.getReferenceWeight(ram), 1e-6))
    -- A maiden ewe past 12 months is a ewe hogg: no fat class, the heifer's ceiling, no verdict.
    local hogg = SheepSim.grown("SHEEP_LANDRACE", "F6", 24)
    SheepSim.makePen({ hogg }, GRASS)
    local config = RLBodyCondition.getConfig(hogg)
    check(string.format("display: a 24-month maiden ewe keeps the heifer's rules (ceiling %s, target %s, verdict %s)",
        tostring(RLBodyCondition.getReserveCeiling(hogg)), tostring(RLBodyCondition.getReserveTarget(hogg)), tostring(RLBodyCondition.getFinishVerdict(hogg))),
        RLBodyCondition.getFatClass(hogg) == nil and RLBodyCondition.getReserveTarget(hogg) == nil
        and RLBodyCondition.getReserveCeiling(hogg) == config.heiferReserveCeiling and RLBodyCondition.getFinishVerdict(hogg) == nil
        and RLBodyCondition.getInfoText(hogg):find("rl_ui_bcs") ~= nil
        and RLFeed.getAnimalTarget(hogg, { target = "AUTO" }, RLFeed.getRationClass(hogg)) == "GROW")
    local older = SheepSim.grown("SHEEP_LANDRACE", "F7", 11.5)
    SheepSim.makePen({ older }, GRASS)
    local lambCeiling = RLBodyCondition.getReserveCeiling(older, RLBodyCondition.getReferenceWeight(older))
    check(string.format("display: an 11-month ewe lamb still reads the finishing target (ceiling %.3f at her market weight)", lambCeiling or -1),
        lambCeiling ~= nil and lambCeiling > config.heiferReserveCeiling and RLBodyCondition.getFatClass(older) ~= nil)
    ram.weight = RLBodyCondition.getReferenceWeight(ram)
    eweLamb.weight = ram.weight
    check("display: a lamb at its market weight in 3L is ready, one in 4L over-fat",
        RLBodyCondition.getFinishVerdict(ram) == "rl_ui_finishVerdictReady" and RLBodyCondition.getFinishVerdict(eweLamb) == "rl_ui_finishVerdictOverfat")
    check("display: meat follows the class (3L 1.00, 4L 0.97)", RLBodyCondition.getYieldFactor(ram) == 1 and near(RLBodyCondition.getYieldFactor(eweLamb), 0.97, 1e-9))
    local rows = RLBodyCondition.getPenInfo(pen)
    local byKey = {}
    for _, row in ipairs(rows or {}) do byKey[row.titleKey] = row.text end
    check("display: a sheep pen lists its ewes' BCS and its lambs ready / over-fat",
        byKey.rl_ui_penBcs ~= nil and byKey.rl_ui_penEwesThinFat ~= nil and byKey.rl_ui_penLambsReady == "1 / 2" and byKey.rl_ui_penLambsOverfat == "1")

    local notes = {}
    FSBaseMission = FSBaseMission or { INGAME_NOTIFICATION_CRITICAL = 1, INGAME_NOTIFICATION_INFO = 2 }
    g_currentMission.addIngameNotification = function(_, kind, text) notes[#notes + 1] = text end
    g_currentMission.getIsClient = function() return true end
    local mother = SheepSim.ewe("SHEEP_LANDRACE", "N1")
    local lamb = SheepSim.lamb("RAM_LANDRACE", "N1", "NL1")
    local withEwe = SheepSim.makePen({ mother, lamb }, GRASS)
    SheepSim.run(withEwe, 2, GRASS)
    local before = #notes
    local away = SheepSim.makePen({ lamb }, GRASS)
    SheepSim.run(away, 3, GRASS)
    check(string.format("display: a lamb on milk moved away from its ewe is told once (%d notification)", #notes - before),
        #notes - before == 1 and notes[#notes]:find("rl_feed_lambNoDam") ~= nil)
    g_currentMission.addIngameNotification, g_currentMission.getIsClient = nil, nil
end


-- Saving: a lamb's creep days (an orphan's readiness) are kept with its state ---------------------

do
    local lamb = SheepSim.grown("RAM_LANDRACE", "SV1", 1.5, { motherId = "GONE" })
    lamb.rlGrowth.creepDays = 2.75
    local stored = {}
    local xml = {
        setInt = function(_, k, v) stored[k] = v end, setFloat = function(_, k, v) stored[k] = v end,
        setString = function(_, k, v) stored[k] = v end, setBool = function(_, k, v) stored[k] = v end,
        getInt = function(_, k, d) return stored[k] or d end, getFloat = function(_, k, d) return stored[k] or d end,
        getString = function(_, k, d) return stored[k] or d end, getBool = function(_, k, d) local v = stored[k] if v == nil then return d end return v end,
    }
    RLGrowth.saveToXMLFile(lamb.rlGrowth, xml, "a")
    local loaded = RLGrowth.loadFromXMLFile(xml, "a")
    check("saving: a lamb's creep days survive a save and load", loaded ~= nil and near(loaded.creepDays, 2.75, 1e-9))
    stored["a.growth#creepDays"] = -1
    check("saving: negative creep days make the state unusable (derived again), never trusted", RLGrowth.loadFromXMLFile(xml, "a") == nil)
end
