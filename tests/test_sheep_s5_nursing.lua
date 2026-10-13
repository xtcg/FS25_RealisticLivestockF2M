-- Sheep S5 nursing rules (feedProfiles.xml species SHEEP nursing) in the real-equivalent mode:
-- ewes nurse their own lambs from one finite pool on AHDB Table 28's rows, the pool is paid by the
-- ewe's budget and never stored or sold, lambs wean by age, an orphan gets no milk and is weaned
-- early only with an established solid intake, lambs at foot eat at most the creep allowance, and
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
    FeedSim.setMode(false)
    check("coverage: under the old nutrition model sheep are not on the weight model v2", not RLGrowth.covers(ewe))
    FeedSim.setMode(true)
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
    local planned = 0
    for _, d in ipairs(steps[1].dams) do planned = d.plannedKg end
    -- Twins at full feed: her row 3.00 kg a day x 19% DM over a 0.25-day step, at most.
    check(string.format("pool: twins plan at most her row's milk (%.4f <= %.4f kg DM a step)", planned, 3.00 * 0.19 * 0.25),
        planned > 0 and planned <= 3.00 * 0.19 * 0.25 + 1e-12)
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
    ready.rlGrowth.solidIntakeKg, notReady.rlGrowth.solidIntakeKg = 0.30, 0.10
    check("orphan: from 2 months an orphan eating 0.30 kg DM of solids a day is weaned; one eating 0.10 is not",
        RLFeed.isEarlyWeaned(ready) and RLFeed.getRationClass(ready) == "GROWING"
        and not RLFeed.isEarlyWeaned(notReady) and RLFeed.getRationClass(notReady) == "CALF")
    local withDam = SheepSim.grown("RAM_LANDRACE", "O4", 2.2, { motherId = "M4" })
    withDam.rlGrowth.solidIntakeKg = 0.5
    SheepSim.makePen({ SheepSim.ewe("SHEEP_LANDRACE", "M4"), withDam }, GRASS)
    check("orphan: a lamb with its ewe is never weaned early", not RLFeed.isEarlyWeaned(withDam) and RLFeed.getRationClass(withDam) == "CALF")

    -- The solid intake average follows what it eats.
    local lamb = SheepSim.grown("RAM_LANDRACE", "O5", 1.9, { motherId = "GONE" })
    local lambPen = SheepSim.makePen({ lamb })
    SheepSim.run(lambPen, 6, { GRASS_WINDROW = 3000, BARLEY = 500 })
    check(string.format("orphan: its solid intake is tracked (%.3f kg DM a day)", lamb.rlGrowth.solidIntakeKg or -1),
        (lamb.rlGrowth.solidIntakeKg or 0) > 0)
end


-- Creep ------------------------------------------------------------------------------------------

do
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "C1")
    local lamb = SheepSim.grown("RAM_LANDRACE", "CL1", 1.5, { motherId = "C1" })
    local pen = SheepSim.makePen({ ewe, lamb })
    local steps = stepEvents(pen, 10, { GRASS_WINDROW = 3000, BARLEY = 3000 })
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
    local goat = SheepSim.identify((GrowthSim.makeAnimal("GOAT", { age = 24 })), "G1")
    local mixed = SheepSim.makePen({ SheepSim.ewe("SHEEP_LANDRACE", "T2"), goat })
    FeedSim.hour(mixed)
    check("troughs: a pen with a goat (never in the mode) takes no silage or grain; its pen keeps the old rules",
        not RLFeed.acceptsFill(mixed, silage) and not RLFeed.acceptsFill(mixed, barley) and RLFeed.acceptsFill(mixed, grass)
        and mixed.spec_husbandryFood.rlFeedPen.reason == "UNCOVERED_ANIMAL")
    FeedSim.setMode(false)
    GrowthSim.advanceHour()
    check("troughs: under the old model the sheep pen takes neither", not RLFeed.acceptsFill(pen, silage) and not RLFeed.acceptsFill(pen, barley))
    FeedSim.setMode(true)
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
    check("display: a ewe lamb is read against her breed's ram lamb market weight, not a grown ewe's",
        near(RLBodyCondition.getReferenceWeight(eweLamb), RLBodyCondition.getReferenceWeight(ram), 1e-6))
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
