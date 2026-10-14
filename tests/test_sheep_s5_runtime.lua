-- Sheep S5 run rules: whether a sheep takes the nutrition mode's step in an hour is decided by its
-- pen that hour, not by its profile coverage (RLGrowth.covers). In a pen that runs the mode it is
-- stepped by the pen alone; in one that does not (a goat in it, no trough, the species config
-- invalid, the mode off) it takes the old weight rule, its state kept, and the next step in the
-- mode splits the weight it left again (RLGrowth.resync). Every hour is settled once, also when
-- a sheep changes pens within the hour. An orphan lamb weaned early stays weaned.

loadMod("tests/sheepsim.lua")

local FILL = FeedSim.FILL
local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end

FeedSim.setMode(true)
SheepSim.enable(true)
GrowthSim.setDaysPerPeriod(1)

local GRASS = { GRASS_WINDROW = 3000 }

--- Count, per hour, the steps the mode took for an animal and the old weight rules it took.
local function watch(animal)
    local counts = { steps = 0, legacy = 0 }
    local original = animal.updateWeight
    animal.updateWeight = function(self, ...)
        counts.legacy = counts.legacy + 1
        return Animal.updateWeight(self, ...)
    end
    local function observe(kind, data)
        if kind ~= "STEP" then return end
        for _, e in ipairs(data.animals) do if e.animal == animal then counts.steps = counts.steps + 1 end end
    end
    RLFeed.addObserver(observe)
    counts.stop = function()
        RLFeed.removeObserver(observe)
        animal.updateWeight = original
    end
    counts.reset = function() counts.steps, counts.legacy = 0, 0 end
    return counts
end

--- One pen hour without moving the clock (a second pen's feeding in the same game hour).
local function sameHour(pen, stock)
    local advance = GrowthSim.advanceHour
    GrowthSim.advanceHour = function() end
    if stock ~= nil then FeedSim.keepStocked(stock)(pen) end
    FeedSim.hour(pen)
    GrowthSim.advanceHour = advance
end

local function setOwner(animal, pen) animal.clusterSystem = { owner = pen } end


-- Pure sheep -> a goat joins -> the goat leaves --------------------------------------------------

do
    local lamb = SheepSim.grown("RAM_LANDRACE", "R1", 4.0)
    local pen = SheepSim.makePen({ lamb }, GRASS)
    local counts = watch(lamb)
    local hours, both = {}, false
    local function hour(phase)
        counts.reset()
        SheepSim.run(pen, 1, GRASS)
        if counts.steps > 0 and counts.legacy > 0 then both = true end
        hours[#hours + 1] = { phase = phase, steps = counts.steps, legacy = counts.legacy, weight = lamb.weight,
            active = pen.spec_husbandryFood.rlFeedPen.active, reason = pen.spec_husbandryFood.rlFeedPen.reason }
    end
    for _ = 1, 3 do hour("pure") end
    local pureOk = true
    for _, h in ipairs(hours) do pureOk = pureOk and h.active and h.steps > 0 and h.legacy == 0 end
    check("mixed pen: a pure sheep pen runs the mode; the lamb is stepped by it and never takes the old weight rule", pureOk)
    local state = lamb.rlGrowth
    check("mixed pen: in the mode each hour's step is the lamb's last step (lastTick is the hour)",
        state.lastTick == RLBodyCondition.getTickId())

    local goat = SheepSim.identify((GrowthSim.makeAnimal("GOAT", { age = 24 })), "RG")
    table.insert(pen.animals, goat)
    setOwner(goat, pen)
    local development, ageClock, reserve, lastTick = state.developmentMonths, state.ageMonths, state.reserveMassKg, state.lastTick
    local weightIn = lamb.weight
    for _ = 1, 3 do hour("goat") end
    local goatOk = true
    for i = 4, 6 do goatOk = goatOk and not hours[i].active and hours[i].reason == "UNCOVERED_ANIMAL" and hours[i].steps == 0 and hours[i].legacy == 1 end
    check("mixed pen: with a goat the pen leaves the mode; the lamb takes the old weight rule once an hour, no step", goatOk)
    check(string.format("mixed pen: its state is kept as it was (development %.4f, age clock %.4f, reserve %.3f kg, last step %s); only the weight moves (%.2f -> %.2f kg)",
        development, ageClock, reserve, tostring(lastTick), weightIn, lamb.weight),
        state.developmentMonths == development and state.ageMonths == ageClock and state.reserveMassKg == reserve
        and state.lastTick == lastTick and lamb.weight ~= weightIn)
    check("mixed pen: profile coverage is unchanged by the goat (covers is the profile, the pen decides the run)",
        RLGrowth.covers(lamb) and not RLFeed.runsFor(lamb))

    table.remove(pen.animals)
    local weightOut = lamb.weight
    hour("back")
    check(string.format("mixed pen: once the goat leaves the pen runs the mode again; the first step takes the lamb's weight as it is (%s), %.3f -> %.3f kg",
        tostring(state.source), weightOut, lamb.weight),
        hours[7].active and hours[7].steps > 0 and hours[7].legacy == 0 and state.source == "resync"
        and math.abs(lamb.weight - weightOut) < 0.5 and state.weightKg == lamb.weight and state.lastTick == RLBodyCondition.getTickId())
    -- The weight path: no hour moves the lamb by more than an hour's gain, at any switch.
    local worst = 0
    for i = 2, #hours do worst = math.max(worst, math.abs(hours[i].weight - hours[i - 1].weight)) end
    check(string.format("mixed pen: the weight runs on through both switches (largest hourly change %.3f kg)", worst), worst < 0.5)
    check("mixed pen: no hour took both the step and the old weight rule", not both)
    counts.stop()
end


-- Moving between pens within one hour: the hour is settled once ----------------------------------

do
    local lamb = SheepSim.grown("RAM_LANDRACE", "R2", 4.0)
    local pure = SheepSim.makePen({ lamb }, GRASS)
    SheepSim.run(pure, 2, GRASS)
    local counts = watch(lamb)
    counts.reset()
    SheepSim.run(pure, 1, GRASS)
    local weight, health = lamb.weight, lamb.health
    check("same hour: the lamb was stepped in its pure pen this hour", counts.steps > 0 and lamb.rlGrowth.lastTick == RLBodyCondition.getTickId())
    -- Moved into a pen with a goat in the same hour: that pen takes neither its health nor the old rule.
    local goat = SheepSim.identify((GrowthSim.makeAnimal("GOAT", { age = 24 })), "RG2")
    local mixed = SheepSim.makePen({ goat }, GRASS)
    table.insert(mixed.animals, lamb)
    setOwner(lamb, mixed)
    counts.reset()
    lamb.health = health - 10
    local healthBefore = lamb.health
    sameHour(mixed, GRASS)
    check(string.format("same hour: stepped in the mode, then moved into a mixed pen: no old weight rule and no health on top (weight %.3f -> %.3f)",
        weight, lamb.weight), counts.legacy == 0 and lamb.weight == weight and lamb.health == healthBefore)

    -- Next hour in the mixed pen: the old rule, once; then moved into a fresh pure pen in that hour.
    counts.reset()
    SheepSim.run(mixed, 1, GRASS)
    check("same hour: the next hour in the mixed pen takes the old weight rule once", counts.legacy == 1 and counts.steps == 0)
    local legacyWeight, legacyTick = lamb.weight, lamb.rlGrowth.lastTick
    for i, a in ipairs(mixed.animals) do if a == lamb then table.remove(mixed.animals, i) break end end
    local fresh = SheepSim.makePen({ lamb }, GRASS)
    counts.reset()
    sameHour(fresh, GRASS)
    check("same hour: old rule in the mixed pen, then moved into a pen in the mode: that pen does not step it again this hour",
        counts.steps == 0 and counts.legacy == 0 and lamb.weight == legacyWeight and lamb.rlGrowth.lastTick == legacyTick)
    counts.reset()
    SheepSim.run(fresh, 1, GRASS)
    check("same hour: the next hour the pen in the mode steps it (its weight taken as it is)",
        counts.steps > 0 and counts.legacy == 0 and lamb.rlGrowth.source == "resync")
    counts.stop()
end


-- No trough, an invalid species config, the mode off: the old weight rule, then back --------------

do
    local lamb = SheepSim.grown("RAM_LANDRACE", "R3", 4.0)
    local pen = SheepSim.makePen({ lamb }, GRASS)
    SheepSim.run(pen, 2, GRASS)
    local counts = watch(lamb)

    -- A pen without a trough (no feeding at all): the husbandry still updates its animals.
    local bare = { isServer = true, getClusters = function() return { lamb } end, getAnimalTypeIndex = function() return SheepSim.TYPE end }
    setOwner(lamb, bare)
    local lastTick, development = lamb.rlGrowth.lastTick, lamb.rlGrowth.developmentMonths
    for _ = 1, 3 do
        GrowthSim.advanceHour()
        AnimalHealth.updateHealth(lamb, 0.8)
    end
    check("no trough: the lamb takes the old weight rule once an hour, its state kept",
        counts.legacy == 3 and counts.steps == 0 and lamb.rlGrowth.lastTick == lastTick and lamb.rlGrowth.developmentMonths == development)
    setOwner(lamb, pen)
    counts.reset()
    local before = lamb.weight
    SheepSim.run(pen, 1, GRASS)
    check(string.format("no trough: back in a pen with one, the next step resyncs (%.3f -> %.3f kg)", before, lamb.weight),
        counts.steps > 0 and counts.legacy == 0 and lamb.rlGrowth.source == "resync" and math.abs(lamb.weight - before) < 0.5)

    -- The species config invalid: sheep are not covered at all; the pen keeps the old rules.
    local section = RLFeedProfiles.getConfig().species.SHEEP
    section.valid = false
    counts.reset()
    SheepSim.run(pen, 2, GRASS)
    check("config invalid: the pen leaves the mode and the lamb takes the old weight rule (not covered), once an hour",
        not pen.spec_husbandryFood.rlFeedPen.active and not RLGrowth.covers(lamb) and counts.legacy == 2 and counts.steps == 0)
    section.valid = true
    counts.reset()
    before = lamb.weight
    SheepSim.run(pen, 1, GRASS)
    check(string.format("config invalid: once valid again the step takes the weight as it is (%.3f -> %.3f kg)", before, lamb.weight),
        counts.steps > 0 and counts.legacy == 0 and lamb.rlGrowth.source == "resync" and math.abs(lamb.weight - before) < 0.5)

    -- The mode off: the same.
    FeedSim.setMode(false)
    counts.reset()
    SheepSim.run(pen, 2, GRASS)
    check("mode off: no step, the old weight rule once an hour", not RLGrowth.covers(lamb) and counts.legacy == 2 and counts.steps == 0)
    FeedSim.setMode(true)
    counts.reset()
    before = lamb.weight
    SheepSim.run(pen, 1, GRASS)
    check(string.format("mode off: switched on again, the step takes the weight as it is (%.3f -> %.3f kg)", before, lamb.weight),
        counts.steps > 0 and counts.legacy == 0 and lamb.rlGrowth.source == "resync" and math.abs(lamb.weight - before) < 0.5)
    counts.stop()
end


-- Early weaning: creep as fed, days in a row, kept once weaned ----------------------------------

do
    local nursing = RLFeed.getNursing(SheepSim.grown("RAM_LANDRACE", "W0", 2.2))
    check("weaning: the creep threshold is 250 g a day as fed for 3.5 model days, from 2 months",
        near(nursing.readyCreepKgPerDay, 0.25) and near(nursing.readyDays, 3.5) and near(nursing.earlyWeaningMonth, 2))

    -- The conversion: DM eaten back to fresh weight by the feed's own DM (barley 0.90).
    local lamb = SheepSim.grown("RAM_LANDRACE", "W1", 2.2, { motherId = "GONE" })
    SheepSim.makePen({ lamb }, GRASS)
    local result = { weight = lamb.weight }
    local function creepStep(kgDM, days)
        local feed = { dtDays = days or 0.25, concShare = 0.2, byFill = { BARLEY = { kg = kgDM * (days or 0.25) } } }
        RLFeed.afterStep(lamb, lamb.rlGrowth, feed, result, nil, nil)
    end
    creepStep(0.222)
    check(string.format("weaning: 0.222 kg DM of barley a day is 0.247 kg as fed, under 250 g: not counted (creep days %.2f)", lamb.rlGrowth.creepDays or -1),
        (lamb.rlGrowth.creepDays or -1) == 0)
    creepStep(0.226)
    check(string.format("weaning: 0.226 kg DM of barley a day is 0.251 kg as fed: one step counted (%.2f days)", lamb.rlGrowth.creepDays or -1),
        near(lamb.rlGrowth.creepDays, 0.25) and not RLFeed.isEarlyWeaned(lamb))
    local grassOnly = { dtDays = 0.25, concShare = 0, byFill = { GRASS_WINDROW = { kg = 0.5 } } }
    RLFeed.afterStep(lamb, lamb.rlGrowth, grassOnly, result, nil, nil)
    check("weaning: a step on grass alone starts the count again", (lamb.rlGrowth.creepDays or -1) == 0)
    for _ = 1, 13 do creepStep(0.3) end
    check(string.format("weaning: 13 steps in a row (3.25 days) are not enough (%.2f)", lamb.rlGrowth.creepDays),
        not RLFeed.isEarlyWeaned(lamb) and not lamb.rlGrowth.weanedEarly)
    creepStep(0.3)
    check("weaning: the 14th step (3.5 days) weans it, and the state keeps it", RLFeed.isEarlyWeaned(lamb) and lamb.rlGrowth.weanedEarly == true)
    RLFeed.afterStep(lamb, lamb.rlGrowth, grassOnly, result, nil, nil)
    check("weaning: a shortage afterwards leaves it weaned (underfed, not back on milk)", RLFeed.isEarlyWeaned(lamb)
        and RLFeed.getRationClass(lamb) == "GROWING")

    -- Put back with its ewe it stays weaned: she does not count it, and makes no milk for it.
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "WM")
    lamb.motherId = "WM"
    local back = SheepSim.makePen({ ewe, lamb }, GRASS)
    FeedSim.hour(back)
    local _, suckling = RLFeed.getNursingDams(back.animals)
    check("weaning: put back with its ewe it does not suckle again (she nurses none, milk 0)",
        RLFeed.isEarlyWeaned(lamb) and suckling[ewe] == nil and RLFeed.getDamMilk(ewe) == 0 and RLFeed.getRationClass(ewe) == "DRY")

    -- Too young: the count may build, the weaning waits for earlyWeaningMonth.
    local young = SheepSim.grown("RAM_LANDRACE", "W2", 1.6, { motherId = "GONE" })
    SheepSim.makePen({ young }, GRASS)
    young.rlGrowth.creepDays = 5
    check("weaning: under 2 months it is not weaned, however long it has eaten creep", not RLFeed.isEarlyWeaned(young))

    -- One sub-step on creep (a 28-day month: a step every 5-6 hours) is never enough.
    GrowthSim.setDaysPerPeriod(28)
    local slow = SheepSim.grown("RAM_LANDRACE", "W3", 2.1, { motherId = "GONE" })
    local slowPen = SheepSim.makePen({ slow })
    FeedSim.untilStep(slowPen, { refill = FeedSim.keepStocked({ GRASS_WINDROW = 3000, BARLEY = 500 }) })
    check(string.format("weaning: one 0.25-day step on creep is not enough (%.2f days)", slow.rlGrowth.creepDays or -1),
        near(slow.rlGrowth.creepDays, 0.25, 1e-6) and not RLFeed.isEarlyWeaned(slow))
    GrowthSim.setDaysPerPeriod(1)

    -- The same model days at any month length: an orphan from 2.1 months on creep.
    local function daysToWean(days)
        GrowthSim.setDaysPerPeriod(days)
        local orphan = SheepSim.grown("RAM_LANDRACE", "W4", 2.1, { motherId = "GONE" })
        local orphanPen = SheepSim.makePen({ orphan })
        local hourDays = RLFeed.getHourDays()
        local hours = 0
        while not (orphan.rlGrowth.weanedEarly == true) and hours < 24 * days do
            SheepSim.run(orphanPen, 1, { GRASS_WINDROW = 3000, BARLEY = 500 })
            hours = hours + 1
        end
        GrowthSim.setDaysPerPeriod(1)
        return hours * hourDays, orphan.rlGrowth.creepDays
    end
    local d1 = daysToWean(1)
    local d3 = daysToWean(3)
    local d7 = daysToWean(7)
    local d28 = daysToWean(28)
    check(string.format("weaning: model days on creep to weaning at 1 / 3 / 7 / 28-day months: %.2f / %.2f / %.2f / %.2f (3.5, to the hour)",
        d1, d3, d7, d28), d1 >= 3.5 and d1 < 3.5 + 1.25 + 1e-9 and math.abs(d3 - 3.5) <= 0.42 + 1e-9
        and math.abs(d7 - 3.5) <= 0.25 + 0.18 + 1e-9 and math.abs(d28 - 3.5) <= 0.25 + 0.05 + 1e-9)

    -- Saved and loaded: the count and the weaned state.
    local stored = {}
    local xml = {
        setInt = function(_, k, v) stored[k] = v end, setFloat = function(_, k, v) stored[k] = v end,
        setString = function(_, k, v) stored[k] = v end, setBool = function(_, k, v) stored[k] = v end,
        getInt = function(_, k, d) return stored[k] or d end, getFloat = function(_, k, d) return stored[k] or d end,
        getString = function(_, k, d) return stored[k] or d end, getBool = function(_, k, d) local v = stored[k] if v == nil then return d end return v end,
    }
    RLGrowth.saveToXMLFile(lamb.rlGrowth, xml, "w")
    local loaded = RLGrowth.loadFromXMLFile(xml, "w")
    check("weaning: a weaned-early lamb is still weaned after a save and load", loaded ~= nil and loaded.weanedEarly == true)
    stored = {}
    young.rlGrowth.creepDays = 2.75
    RLGrowth.saveToXMLFile(young.rlGrowth, xml, "y")
    loaded = RLGrowth.loadFromXMLFile(xml, "y")
    check("weaning: a count in progress survives a save and load; not weaned", loaded ~= nil and near(loaded.creepDays, 2.75, 1e-6)
        and loaded.weanedEarly == nil)

    -- Streamed (a client sees it weaned).
    local buffer, pos = {}, 0
    streamWriteBool = function(_, v) buffer[#buffer + 1] = v end
    streamWriteFloat32 = function(_, v) buffer[#buffer + 1] = v end
    streamReadBool = function() pos = pos + 1 return buffer[pos] end
    streamReadFloat32 = function() pos = pos + 1 return buffer[pos] end
    RLGrowth.writeStream(lamb.rlGrowth, nil)
    local streamed = RLGrowth.readStream(nil)
    check("weaning: the weaned state is streamed", streamed ~= nil and streamed.weanedEarly == true)

    -- Past milk age the count and the flag are cleared (a weaned lamb by age).
    local older = SheepSim.grown("RAM_LANDRACE", "W5", 4.2, { motherId = "GONE" })
    SheepSim.makePen({ older }, GRASS)
    older.rlGrowth.creepDays, older.rlGrowth.weanedEarly = 4, true
    RLFeed.afterStep(older, older.rlGrowth, grassOnly, { weight = older.weight }, nil, nil)
    check("weaning: past milk age both are cleared", older.rlGrowth.creepDays == nil and older.rlGrowth.weanedEarly == nil)
end
