-- Pig P5 offline calibration (tests/pigcalib.py prints and judges it): growing pigs on the real
-- modules in the real-equivalent nutrition mode, raised from weaning in a pen of their own and
-- measured between weight crossings (model time, real-equivalent kg as fed), against the design's
-- frozen references (FS25_PigBreeds_离线准备_2026-10-16/PIG_P5_单胃营养设计.md §7). Nothing here
-- changes a parameter: every run reads the shipped files.

loadMod("tests/pigsim.lua")

PigCalib = { results = {} }
CALIB = PigCalib.results

local function config(pen) return RLFeed.getConfig(pen) end


--- Raise one pig from `startAge` months on a feeding plan until `untilKg` (or maxDays model days),
--- recording each hour's weight, model day, feed eaten (real kg as fed and MJ ME) and reserve.
--- plan(pig) -> stock table (name -> liters kept in the trough) for the next hour.
--- @return table track { { day, kg, feedKg, me, reserve, lysF }, ... }, table pig
function PigCalib.raise(name, startAge, plan, untilKg, maxDays, fields, daysPerPeriod)
    -- The clock only moves on: to the next midnight, then the month length (setDaysPerPeriod
    -- resets the hour, which would put the hour id back and settle hours twice).
    while GrowthSim.env.currentHour ~= 0 do GrowthSim.advanceHour() end
    GrowthSim.env.currentMonotonicDay = GrowthSim.env.currentMonotonicDay + 1
    GrowthSim.setDaysPerPeriod(daysPerPeriod or 1)
    local pig = PigSim.grown(name, 1, startAge, fields)
    local pen = PigSim.makePen({ pig }, {})
    local cfg = config(pen)
    local track = { { day = 0, kg = pig.weight, feedKg = 0, me = 0, reserve = pig.bodyCondition and pig.bodyCondition.reserve or nil } }
    local hours, feedKg, me = 0, 0, 0
    local hourDays = cfg.realDaysPerPeriod / (24 * GrowthSim.env.daysPerPeriod)
    local lastStep
    local observer = function(kind, data) if kind == "STEP" and data.animals[1] ~= nil then lastStep = data.animals[1].feed end end
    RLFeed.addObserver(observer)
    local active, reason
    while pig.weight < untilKg and hours * hourDays < (maxDays or 400) do
        local stock = plan(pig)
        FeedSim.keepStocked(stock)(pen)
        local before = {}
        for feedName in pairs(stock) do before[feedName] = pen:level(feedName) end
        FeedSim.hour(pen)
        active, reason = pen.spec_husbandryFood.rlFeedPen.active, pen.spec_husbandryFood.rlFeedPen.reason
        for feedName in pairs(stock) do
            local profile = RLFeedProfiles.getUsableFeed(feedName, cfg)
            local used = math.max(before[feedName] - pen:level(feedName), 0)
            if profile ~= nil and used > 0 then
                local kgDm = RLFeedUnits.litersToKg(used, cfg.resourceScale, profile.density, profile.dm)
                feedKg, me = feedKg + kgDm / profile.dm, me + kgDm * profile.me
            end
        end
        hours = hours + 1
        if GrowthSim.env.currentHour == 0 and GrowthSim.env.currentDayInPeriod == 1 then pig.age = pig.age + 1 end
        track[#track + 1] = { day = hours * hourDays, kg = pig.weight, feedKg = feedKg, me = me,
            reserve = pig.bodyCondition and pig.bodyCondition.reserve or nil, lysF = lastStep and lastStep.proteinFactor or nil,
            limit = lastStep and lastStep.intakeLimit or nil }
    end
    RLFeed.removeObserver(observer)
    track.active, track.reason, track.pen = active, reason, pen
    return track, pig
end


--- The point of a track where its weight first reaches kg (interpolated between hours).
function PigCalib.cross(track, kg)
    for i = 2, #track do
        local a, b = track[i - 1], track[i]
        if a.kg < kg and b.kg >= kg then
            local t = (kg - a.kg) / (b.kg - a.kg)
            return { day = a.day + t * (b.day - a.day), feedKg = a.feedKg + t * (b.feedKg - a.feedKg), me = a.me + t * (b.me - a.me),
                reserve = b.reserve }
        end
    end
    return nil
end


--- ADG (kg a model day), feed a day (kg as fed), FCR (kg as fed per kg gain) and ME a day between
--- two weights of a track; nil when either is not reached.
function PigCalib.window(track, fromKg, toKg)
    local a, b = PigCalib.cross(track, fromKg), PigCalib.cross(track, toKg)
    if a == nil or b == nil then return nil end
    local days = b.day - a.day
    return { fromKg = fromKg, toKg = toKg, days = days, adg = (toKg - fromKg) / days, feedPerDay = (b.feedKg - a.feedKg) / days,
        fcr = (b.feedKg - a.feedKg) / (toKg - fromKg), mePerDay = (b.me - a.me) / days, startDay = a.day, reserveEnd = b.reserve }
end


--- Phase feeding: nursery feed up to 24 kg, then `feeds` (name -> liters kept). The switch is a
--- little below PIGLETFOOD's 25 kg limit (maxWeightKg, read at the weight halfway through a step),
--- so a pig is never left in a trough of a feed it may no longer eat.
function PigCalib.phase(feeds)
    return function(pig)
        if pig.weight < 24 then return { PIGLETFOOD = 4000 } end
        return feeds
    end
end


local function record(key, value) CALIB[key] = value end


--- V1: intake against NRC 2012 Eqs. 8-10 to 8-12 at fixed weights (descriptor, and a day eaten).
function PigCalib.intake()
    local rows = {}
    for _, case in ipairs({ { "PIG_LANDRACE", "female", nil }, { "BOAR_LANDRACE", "castrate", { isCastrated = true } }, { "BOAR_LANDRACE", "male", nil } }) do
        for _, kg in ipairs({ 30, 50, 75, 100, 120 }) do
            local pig = PigSim.grown(case[1], 1, 3, case[3])
            pig.weight = kg
            local pen = PigSim.makePen({ pig }, { PIGFOOD = 4000 })
            local mono = config(pen).monogastric
            local d = RLFeed.describeAnimal(pig, RLFeed.getRation(pen), 0.25 / 30, 0.25)
            local kcal
            if case[2] == "female" then kcal = 10967 * (1 - math.exp(-math.exp(-3.803) * d.weight ^ 0.9072))
            elseif case[2] == "castrate" then kcal = 10447 * (1 - math.exp(-math.exp(-4.283) * d.weight ^ 1.0843))
            else kcal = 10638 * (1 - math.exp(-math.exp(-3.803) * d.weight ^ 0.9072)) end
            local plan = RLFeed.planPen(pen, RLFeed.getRation(pen), { d }, 0.25)
            rows[#rows + 1] = { sex = case[2], kg = kg, descriptorWeight = d.weight, energyCap = d.energyCap, nrcMJ = kcal * 4.184 / 1000,
                plannedMePerDay = plan.animals[1].plannedMe / 0.25, physicalCapKgDM = d.appetite, limit = plan.animals[1].intakeLimit,
                sexKey = d.sex, mono = mono ~= nil }
        end
    end
    record("intake", rows)
end


--- V2-V5 routes and V6 month lengths.
function PigCalib.routes()
    local out = {}
    -- V2 DanBred Landrace: entire boars and gilts, nursery feed then PIGFOOD.
    local boar = PigCalib.raise("BOAR_LANDRACE", 1.0, PigCalib.phase({ PIGFOOD = 4000 }), 106, 300)
    local gilt = PigCalib.raise("PIG_LANDRACE", 1.0, PigCalib.phase({ PIGFOOD = 4000 }), 120, 300)
    out.landraceBoar30_105 = PigCalib.window(boar, 30, 105)
    out.landraceBoar30_100 = PigCalib.window(boar, 30, 100)
    out.landraceGilt30_105 = PigCalib.window(gilt, 30, 105)
    out.landraceGilt32_118 = PigCalib.window(gilt, 32, 118)
    out.landraceGiltBirth30 = PigCalib.window(gilt, 9, 30)
    out.active = { boar = boar.reason, gilt = gilt.reason }
    -- V3 Iowa Berkshire: gilts 24 -> 122 kg, barrows 27 -> 124 kg on a corn-soy ration (PIGFOOD as its proxy).
    local bGilt = PigCalib.raise("PIG_BERKSHIRE", 1.0, PigCalib.phase({ PIGFOOD = 4000 }), 123, 360)
    local bBarrow = PigCalib.raise("BOAR_BERKSHIRE", 1.0, PigCalib.phase({ PIGFOOD = 4000 }), 125, 360, { isCastrated = true })
    out.berkshireGilt24_122 = PigCalib.window(bGilt, 24, 122)
    out.berkshireBarrow27_124 = PigCalib.window(bBarrow, 27, 124)
    -- V4 Teagasc finisher 32 -> 118 kg: a Landrace barrow beside the gilt above (mixed sexes).
    local lBarrow = PigCalib.raise("BOAR_LANDRACE", 1.0, PigCalib.phase({ PIGFOOD = 4000 }), 120, 300, { isCastrated = true })
    out.landraceBarrow32_118 = PigCalib.window(lBarrow, 32, 118)
    -- V5 lysine: barley alone from 30 kg against PIGFOOD (gilt), and barley with soybean.
    local barley = PigCalib.raise("PIG_LANDRACE", 1.0, PigCalib.phase({ BARLEY = 4000 }), 105, 400)
    local barleySoy = PigCalib.raise("PIG_LANDRACE", 1.0, PigCalib.phase({ BARLEY = 4000, SOYBEAN = 1200 }), 105, 400)
    out.giltBarley30_105 = PigCalib.window(barley, 30, 105)
    out.giltBarleySoy30_105 = PigCalib.window(barleySoy, 30, 105)
    out.giltPigfood30_105 = out.landraceGilt30_105
    -- V6 month length: a gilt at 1 / 3 / 7 / 28-day months for the same model time (60 days from weaning).
    local lengths = {}
    for _, days in ipairs({ 1, 3, 7, 28 }) do
        local track = PigCalib.raise("PIG_LANDRACE", 1.0, PigCalib.phase({ PIGFOOD = 4000 }), 1000, 60, nil, days)
        local last = track[#track]
        lengths[#lengths + 1] = { daysPerPeriod = days, day = last.day, kg = last.kg, feedKg = last.feedKg }
    end
    GrowthSim.setDaysPerPeriod(1)
    out.monthLength = lengths
    record("routes", out)
end


--- V8: pens the mode leaves to the old rules (a piglet, a pregnant gilt, a sow that farrowed).
function PigCalib.penGate()
    local rows = {}
    local function case(label, animals)
        local pen = PigSim.makePen(animals, { PIGFOOD = 1000 })
        local active, reason = RLFeed.evaluatePen(pen)
        local before = pen:level("PIGFOOD")
        FeedSim.hour(pen)
        rows[#rows + 1] = { case = label, active = active, reason = reason, modeTookLiters = (pen.spec_husbandryFood.rlFeedPen.active and before - pen:level("PIGFOOD")) or 0,
            penActiveAfter = pen.spec_husbandryFood.rlFeedPen.active }
    end
    case("growers", { PigSim.grown("PIG_LANDRACE", 1, 3), PigSim.grown("BOAR_LANDRACE", 2, 3) })
    case("piglet 0.5 months", { PigSim.grown("PIG_LANDRACE", 1, 3), PigSim.grown("PIG_LANDRACE", 2, 0.5) })
    case("pregnant gilt", { PigSim.grown("PIG_LANDRACE", 1, 9, { isPregnant = true }) })
    case("sow that farrowed", { PigSim.grown("PIG_LANDRACE", 1, 18, { isParent = true }) })
    record("penGate", rows)
end


function PigCalib.run()
    FeedSim.setMode(true)
    PigSim.enable(true)
    PigCalib.intake()
    PigCalib.penGate()
    PigCalib.routes()
    PigSim.enable(false)
end
