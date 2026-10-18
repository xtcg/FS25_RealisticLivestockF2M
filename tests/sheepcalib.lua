-- Sheep S5 offline calibration library (FS25_SheepBreeds_离线准备 sheep-finishing-design-v1 §5, S5
-- checklist §C8): the simulations the scenarios run on the real modules - lambs raised with their
-- ewe (raiseWithDam), weaned store lambs (storeLambs), one ewe's year from mating to the next
-- mating (eweYear) - and their measurements (tests/sheepcalib_metrics.lua). Scenario inputs and
-- groups are in tests/sheepcalib_scenarios.lua; tests/sheepcalib.py runs each group in a Lua state
-- of its own, prints CALIB and judges it. Real-world targets are in the design; this only measures.

loadMod("tests/sheepsim.lua")
loadMod("tests/sheepcalib_metrics.lua")

CALIB = {}
SheepCalib = {}
local SHEEP = SheepSim.TYPE
local FILL = FeedSim.FILL

FeedSim.setMode(true)
SheepSim.enable(true)

-- Pack breeds (FS25_SheepBreedsRLRM): subtypes as the pack adds them, food curve borrowed from the
-- base Landrace (the real-equivalent mode does not read it).
local function addSheep(name, breed, gender, target)
    local _, base = Economics.find(gender == "male" and "RAM_LANDRACE" or "SHEEP_LANDRACE")
    local sub = { name = name, breed = breed, gender = gender, typeIndex = SHEEP, typeName = "SHEEP", minWeight = 5,
        targetWeight = target, reproductionMinAgeMonth = base.reproductionMinAgeMonth, food = base.food, milk = {},
        sellPriceCurve = base.sellPriceCurve, healthIncreaseHour = 10, healthDecreaseHour = 25, healthThresholdFactor = 0.45, output = {} }
    table.insert(Economics.subTypes, sub)
end
-- Ewe target = the pack ewe's curve adult; ram target = market weight / maleMaturity (carcassYield.xml).
local PACK = { TEXEL = { 76, 100 }, SUFFOLK = { 88, 100 }, BLACKFACE = { 59, 78 } }
for breed, w in pairs(PACK) do
    addSheep("SHEEP_" .. breed, breed, "female", w[1])
    addSheep("RAM_" .. breed, breed, "male", w[2])
end

local function reference(animal) return RLBodyCondition.getReferenceWeight(animal) end
local function fatClass(animal)
    local config = RLBodyCondition.getConfig(animal)
    local r = RLBodyCondition.getReserve(animal)
    local name = "?"
    for _, class in ipairs(config.fatClasses or {}) do if r >= class.minReserve then name = class.name end end
    return name, r
end

local FW = function(name) local p = RLFeedProfiles.getUsableFeed(name) return p end
--- Liters of a fill type per kg fresh weight.
local function litersPerKgFresh(name) local p = FW(name) return RLFeedProfiles.getConfig().resourceScale / p.density end

--- Concentrate (kg fresh) an animal ate since `mark`.
local function concEaten(animal, record, names)
    local total = 0
    for _, name in ipairs(names) do
        local fill = record.byFill[name]
        if fill ~= nil then total = total + fill.liters / litersPerKgFresh(name) end
    end
    return total
end

--- A recorder of each lamb's concentrate (kg fresh) from the STEP events.
local DM = {}
local function concRecorder(names)
    local eaten = {}
    local fn = function(kind, data)
        if kind ~= "STEP" then return end
        for _, e in ipairs(data.animals) do
            local dm = DM[e.animal] or { kg = 0, days = 0 }
            DM[e.animal] = dm
            dm.kg, dm.days = dm.kg + (e.feed.kg or 0), dm.days + (e.feed.dtDays or 0)
            local add = 0
            for _, name in ipairs(names) do
                local fill = e.feed.byFill[name]
                if fill ~= nil then add = add + fill.liters / litersPerKgFresh(name) end
            end
            eaten[e.animal] = (eaten[e.animal] or 0) + add
        end
    end
    RLFeed.addObserver(fn)
    return eaten, function() RLFeed.removeObserver(fn) end
end


--- A recorder of a ewe's milk pool from the STEP events, by month of her lambs' life (1-based):
--- potential (her Table 28 row at full feed, kg as drunk), paid (what her budget paid, kg as drunk)
--- and taken (what her lambs drank of it, kg as drunk).
local function milkRecorder(ewe, perMonthDays)
    local months = {}
    local elapsed = 0
    local fn = function(kind, data)
        if kind ~= "STEP" then return end
        local m = math.floor(elapsed / perMonthDays + 1e-9) + 1
        local row = months[m] or { potential = 0, paid = 0, taken = 0 }
        months[m] = row
        for _, e in ipairs(data.animals) do
            if e.animal == ewe then row.potential = row.potential + RLFeed.getDamMilk(ewe) * data.stepDays end
        end
        for _, d in ipairs(data.dams or {}) do
            if d.animal == ewe then row.paid, row.taken = row.paid + d.paidLiters, row.taken + d.allocatedLiters end
        end
        elapsed = elapsed + data.stepDays
    end
    RLFeed.addObserver(fn)
    return months, function() RLFeed.removeObserver(fn) end
end


--- Raise lambs with their ewe from birth on a stock until each reaches its reference (or maxMonths).
--- @return table per lamb: { sex, ageAtRef, fatAtRef, reserveAtRef, adg, refKg, weightAt3, preWeanConc, preWeanGain }
local function raiseWithDam(breed, litter, stock, opts)
    opts = opts or {}
    GrowthSim.setDaysPerPeriod(opts.days or 1)
    local ewe = SheepSim.ewe("SHEEP_" .. breed, "E", { age = 36 })
    local animals, lambs = { ewe }, {}
    for i = 1, litter do
        local sex = (opts.sexes or { "male", "female", "male" })[i]
        local name = (sex == "female" and "SHEEP_" or "RAM_") .. breed
        local lamb = SheepSim.lamb(name, "E", "L" .. i, { isCastrated = opts.castrate and sex == "male" or nil })
        lamb.rlSex = opts.castrate and sex == "male" and "wether" or sex
        animals[#animals + 1] = lamb
        lambs[#lambs + 1] = lamb
    end
    local pen = SheepSim.makePen(animals)
    if opts.ration ~= nil then RLFeed.setRation(pen, opts.ration) end
    local eaten, stop = concRecorder({ "BARLEY", "PEA", "WHEAT", "MAIZE", "OAT" })
    local milk, stopMilk = milkRecorder(ewe, RLFeed.getConfig(ewe).realDaysPerPeriod)
    -- Model time, the crossing of each lamb's market weight, intake and the ledger (SheepMetrics).
    local tracker = SheepMetrics.track(lambs, { reference = reference })
    tracker.add(ewe)
    local perMonth = 24 * GrowthSim.env.daysPerPeriod
    local results = {}
    for _, lamb in ipairs(lambs) do results[lamb] = { sex = lamb.rlSex, birth = lamb.weight } end
    local eweLog = { { 0, RLBodyCondition.getBCS(ewe), ewe.weight } }
    local hours = 0
    while hours < (opts.maxMonths or 9) * perMonth do
        SheepSim.run(pen, 1, stock)
        hours = hours + 1
        local months = hours / perMonth
        for _, lamb in ipairs(lambs) do
            local r = results[lamb]
            if r.at3 == nil and months >= 3 then
                r.at3 = lamb.weight
                r.preWeanConc = eaten[lamb] or 0
                r.creepFCR = r.preWeanConc / math.max(lamb.weight - r.birth, 1e-9)
                r.at2 = r.at2 or lamb.weight
            end
            if r.at2 == nil and months >= 2 then r.at2 = lamb.weight end
            if r.ageAtRef == nil and lamb.weight >= reference(lamb) then
                r.ageAtRef = months
                r.refKg = reference(lamb)
                r.fatAtRef, r.reserveAtRef = fatClass(lamb)
                r.adg = (lamb.weight - r.birth) / (months * 30)
                r.concToRef = eaten[lamb] or 0
            end
        end
        if hours % perMonth == 0 then eweLog[#eweLog + 1] = { months, RLBodyCondition.getBCS(ewe), ewe.weight } end
        local done = true
        for _, lamb in ipairs(lambs) do if results[lamb].ageAtRef == nil then done = false end end
        if done and months >= 3 then break end
    end
    stop()
    stopMilk()
    tracker.stop()
    local out = {}
    for _, lamb in ipairs(lambs) do
        local r = results[lamb]
        -- ageAtRef is the game hour's end (months of game hours); model is the lamb's own model time.
        r.ageAtRefGameHour = r.ageAtRef
        r.model = SheepMetrics.export(tracker.rec[lamb])
        r.health = lamb.health
        r.finalWeight = lamb.weight
        r.adg0to3 = r.at3 ~= nil and (r.at3 - r.birth) / 90 or nil
        r.adg0to2 = r.at2 ~= nil and (r.at2 - r.birth) / 60 or nil
        out[#out + 1] = r
    end
    local pool = {}
    for m = 1, 3 do pool[m] = milk[m] or { potential = 0, paid = 0, taken = 0 } end
    return out, eweLog, pool, SheepMetrics.export(tracker.rec[ewe])
end


--- Weaned store lambs (32 kg unless given) on a stock for `days` model days (the hours that make
--- them at opts.daysPerPeriod, default 1; the days actually run are counted from the steps): ADG on
--- those days, fat, intake, concentrate, three FCRs (live gain x 0.49 and x 0.491, both proxies, and
--- the game's saleable meat gained).
local function storeLambs(breed, sexes, stock, days, opts)
    opts = opts or {}
    GrowthSim.setDaysPerPeriod(opts.daysPerPeriod or 1)
    local lambs = {}
    for i, sex in ipairs(sexes) do
        local name = (sex == "female" and "SHEEP_" or "RAM_") .. breed
        local lamb = SheepSim.grown(name, "S" .. i, opts.age or 5, { isCastrated = sex == "wether" or nil })
        lamb.weight = opts.weight or 32
        lamb.rlSex = sex
        lambs[#lambs + 1] = lamb
    end
    local pen = SheepSim.makePen(lambs)
    if opts.ration ~= nil then RLFeed.setRation(pen, opts.ration) end
    local eaten, stop = concRecorder({ "BARLEY", "PEA", "WHEAT", "MAIZE", "OAT" })
    local tracker = SheepMetrics.track(lambs, { reference = reference })
    local start, meat0 = {}, {}
    for _, lamb in ipairs(lambs) do start[lamb], meat0[lamb] = lamb.weight, SheepMetrics.saleableMeat(lamb) end
    local hourDays = RLFeed.getHourDays()
    local hours = math.floor(days / hourDays + 0.5)
    local refill = opts.refill
    local track = {}
    for h = 1, hours do
        if refill ~= nil then refill(pen, h) end
        SheepSim.run(pen, 1, stock)
        for _, lamb in ipairs(lambs) do
            local t = track[lamb] or {}
            track[lamb] = t
            if t.refAt == nil and lamb.weight >= reference(lamb) then t.refAt = h * hourDays t.xFat = RLBodyCondition.getReserve(lamb) end
        end
    end
    stop()
    tracker.stop()
    local out = {}
    for _, lamb in ipairs(lambs) do
        local gain = lamb.weight - start[lamb]
        local conc = eaten[lamb] or 0
        local fat, r = fatClass(lamb)
        local dm = DM[lamb] or { kg = 0, days = 1 }
        local model = SheepMetrics.export(tracker.rec[lamb])
        local actualDays = model.elapsedModelDays
        local meatGain = meat0[lamb] ~= nil and SheepMetrics.saleableMeat(lamb) ~= nil and SheepMetrics.saleableMeat(lamb) - meat0[lamb] or nil
        out[#out + 1] = { sex = lamb.rlSex, adg = gain / actualDays, adgNominal = gain / days, nominalDays = days, actualDays = actualDays,
            hours = hours, daysPerPeriod = opts.daysPerPeriod or 1, model = model, meatGain = meatGain,
            fcrLive049 = SheepMetrics.fcrOnLive(conc, gain, 0.49), fcrLive0491 = SheepMetrics.fcrOnLive(conc, gain, 0.491),
            fcrMeat = SheepMetrics.fcrOnMeat(conc, meatGain), dmPerDay = dm.kg / math.max(dm.days, 1e-9), dmPctBW = dm.kg / math.max(dm.days, 1e-9) / ((lamb.weight + start[lamb]) / 2) * 100, gain = gain, conc = conc, concPerCarcassKg = gain > 0 and conc / (gain * 0.49) or -1,
            fat = fat, reserve = r, x = lamb.weight / reference(lamb), ref = reference(lamb), yield = RLBodyCondition.getYieldFactor(lamb),
            health = lamb.health, refAt = track[lamb] ~= nil and track[lamb].refAt or nil, weight = lamb.weight }
    end
    return out
end


local GRASS = { GRASS_WINDROW = 4000 }
local INTENSIVE = { GRASS_WINDROW = 4000, BARLEY = 4000, PEA = 1000 }
local HOUSED = { SILAGE = 4000, BARLEY = 4000, PEA = 1000 }

-- Ewe year, one ewe without a break, from mating to the next mating (lowland Landrace, twins).
-- Month 0: mated, at the reference reserve (BCS 3: the setup, not judged). Five months pregnant
-- on grass, the last two housed on silage (gestation 5 months, Hof Bergmann animals.xml); at
-- month 5 the twins are born as the game does it (pregnancy over, monthsSinceLastBirth 0, a
-- parent; a ewe is never isLactating, RLLactation.startsAtBirth); three months on grass with her
-- lambs; at month 8 they leave (weaning); dry on grass to the next mating at month 12. The same
-- ewe throughout: never rebuilt, her condition never reset. Each month: weight, BCS, reserve,
-- gravid mass, what she ate (kg DM, MJ ME a day) and her energy balance against her requirement,
-- her milk at full feed (Table 28), what her budget paid and what her lambs took (kg a day as
-- drunk), the lambs' weights and the concentrate each ate.
--
-- plan (fixed before any run, never adjusted to the result; S5 checklist F.4 / F.5):
--   lactationConc: kg fresh a ewe a day of each concentrate in the trough in the first
--     lactationConcMonths months of lactation (the pen's trough, so her lambs may take some);
--   lactationStock: the trough's hourly top-up (game liters, ample supply, not a ration) for the
--     lactationStockMonths months of lactation (default 3: 90 days) in place of grass alone;
--   recoveryTarget: the pen's ration target from weaning to mating (nil: AUTO);
--   recoveryCap: { bcs, target }: from weaning, a player's switch - once she reaches bcs on
--     FINISH the pen goes to target (a scenario's operation on a weaned ewe that has lambed; no
--     production rule switches anything).
-- Energy is the budget's own per-step ledger (SheepMetrics), never intake minus a mid-month need.
local function eweYear(plan)
    plan = plan or {}
    GrowthSim.setDaysPerPeriod(1)
    local perMonth = 24 * GrowthSim.env.daysPerPeriod
    local days = RLFeedProfiles.getConfig().realDaysPerPeriod
    local hourDays = RLFeed.getHourDays()
    local _, ramSub = Economics.find("RAM_LANDRACE")
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "CY")
    RLGrowth.setReserveIndex(ewe, RLBodyCondition.getConfig(ewe).referenceReserve)
    RLBodyCondition.ensureState(ewe, "calib").reserve = RLBodyCondition.getConfig(ewe).referenceReserve
    local pen = SheepSim.makePen({ ewe })
    local lambs = {}
    local CONC = { BARLEY = true, PEA = true, WHEAT = true, MAIZE = true, OAT = true }
    local function freshConc(byFill)
        local kg = 0
        for name, fill in pairs(byFill or {}) do
            if CONC[name] then kg = kg + fill.liters / litersPerKgFresh(name) end
        end
        return kg
    end
    local function blank() return { kg = 0, me = 0, days = 0, potential = 0, paid = 0, taken = 0, eweConc = 0, lambConc = 0 } end
    local month = blank()
    local fn = function(kind, data)
        if kind ~= "STEP" then return end
        for _, e in ipairs(data.animals) do
            if e.animal == ewe then
                month.kg, month.me, month.days = month.kg + e.feed.kg, month.me + e.feed.me, month.days + e.feed.dtDays
                month.potential = month.potential + RLFeed.getDamMilk(ewe) * data.stepDays
                month.eweConc = month.eweConc + freshConc(e.feed.byFill)
            else
                month.lambConc = month.lambConc + freshConc(e.feed.byFill)
            end
        end
        for _, d in ipairs(data.dams or {}) do
            if d.animal == ewe then month.paid, month.taken = month.paid + d.paidLiters, month.taken + d.allocatedLiters end
        end
    end
    RLFeed.addObserver(fn)
    local tracker = SheepMetrics.track({ ewe }, { bucketDays = 30 })
    local log, marks, needs = {}, {}, {}
    local function requirement()
        local a = RLFeed.describeAnimal(ewe, { target = "AUTO" }, 0.25 / days, 0.25)
        return a.needs.maintenance + a.needs.pregnancy + a.needs.milk, a.needs
    end
    local function perDay(b, key) return b ~= nil and b.days > 0 and (b[key] or 0) / b.days or nil end
    local function row(m)
        local d = math.max(month.days, 1e-9)
        local need = needs[m]
        local b = tracker.rec[ewe].ledger[m]
        local ledger = {}
        for _, key in ipairs({ "supplyNU", "demandNU", "paidNU", "unmetNU", "depositNU", "mobilizedNU", "catabolismNU", "lostNU" }) do
            ledger[key] = perDay(b, key)
        end
        local lambIntake
        if #lambs > 0 then
            lambIntake = { freshKg = 0, troughFreshKg = 0, milkFreshKg = 0, dmKg = 0, meMJ = 0, concFreshKg = 0 }
            for _, lamb in ipairs(lambs) do
                local lb = tracker.rec[lamb] ~= nil and tracker.rec[lamb].ledger[m - 5] or nil
                for key in pairs(lambIntake) do lambIntake[key] = lambIntake[key] + (perDay(lb, key) or 0) / #lambs end
            end
        end
        log[#log + 1] = { month = m, bcs = RLBodyCondition.getBCS(ewe), weight = ewe.weight, gravid = ewe.rlGrowth.gravidKg or 0,
            reserveKg = ewe.rlGrowth.reserveMassKg, dmPerDay = month.kg / d, mePerDay = month.me / d,
            milkPotential = month.potential / d, milkPaid = month.paid / d,
            lambsTook = month.taken / d, need = need, eweConcPerDay = month.eweConc / d, lambConcPerDay = month.lambConc / d,
            lambKg = #lambs > 0 and (lambs[1].weight + lambs[2].weight) / 2 or nil, ledger = ledger,
            eweIntake = { freshKg = perDay(b, "freshKg"), troughFreshKg = perDay(b, "troughFreshKg"), milkFreshKg = perDay(b, "milkFreshKg"),
                dmKg = perDay(b, "dmKg"), meMJ = perDay(b, "meMJ"), concFreshKg = perDay(b, "concFreshKg") },
            lambIntake = lambIntake, target = RLFeed.getRation(pen).target }
        month = blank()
    end
    log[1] = { month = 0, bcs = RLBodyCondition.getBCS(ewe), weight = ewe.weight, gravid = 0, reserveKg = ewe.rlGrowth.reserveMassKg }
    ewe.isPregnant, ewe.pregnancy, ewe.reproduction = true, { pregnancies = { { getSubType = function() return ramSub end },
        { getSubType = function() return ramSub end } } }, 0
    local lambBirth
    for m = 1, 12 do
        local stock = (m == 4 or m == 5) and { SILAGE = 4000 } or GRASS
        if m == 6 then
            -- Lambing, as AnimalReproduction does it for a ewe.
            ewe.isPregnant, ewe.pregnancy, ewe.reproduction = false, nil, 0
            ewe.monthsSinceLastBirth, ewe.isParent, ewe.birthCount = 0, true, (ewe.birthCount or 1) + 1
            lambs = { SheepSim.lamb("RAM_LANDRACE", "CY", "CY1"), SheepSim.lamb("SHEEP_LANDRACE", "CY", "CY2") }
            lambBirth = (lambs[1].weight + lambs[2].weight) / 2
            pen = SheepSim.makePen({ ewe, lambs[1], lambs[2] })
            tracker.add(lambs[1])
            tracker.add(lambs[2])
        elseif m == 9 then
            pen = SheepSim.makePen({ ewe })
            if plan.recoveryTarget ~= nil then RLFeed.setRation(pen, { target = plan.recoveryTarget }) end
        end
        if plan.lactationStock ~= nil and m >= 6 and m < 6 + (plan.lactationStockMonths or 3) then stock = plan.lactationStock end
        local supplement = plan.lactationConc ~= nil and m >= 6 and m < 6 + (plan.lactationConcMonths or 0)
        for h = 1, perMonth do
            if supplement then
                -- Each hour the trough holds that hour's allowance (a day's ration spread over the day).
                for name, kg in pairs(plan.lactationConc) do
                    pen.spec_husbandryFood.fillLevels[FILL[name]] = kg * hourDays * litersPerKgFresh(name)
                end
            end
            if m <= 5 then ewe.reproduction = 100 * ((m - 1) * perMonth + h) / (5 * perMonth) end
            SheepSim.run(pen, 1, stock)
            -- The player's switch (recoveryCap): weaned, she has lambed, not in milk.
            local cap = plan.recoveryCap
            if cap ~= nil and m >= 9 and ewe.isParent and not ewe.isLactating and RLFeed.getRation(pen).target == "FINISH"
                and RLBodyCondition.getBCS(ewe) >= cap.bcs - 1e-9 then
                RLFeed.setRation(pen, { target = cap.target })
                marks.capSwitch = { month = m - 1 + h / perMonth, bcs = RLBodyCondition.getBCS(ewe), reserve = RLBodyCondition.getReserve(ewe) }
            end
            if h == math.floor(perMonth / 2) then needs[m] = requirement() end
            -- Her requirement one week before lambing (Table 8's last column).
            if m == 5 and h == perMonth - math.floor(perMonth * 7 / days + 0.5) then
                local _, n = requirement()
                marks.lateNeed, marks.lateNeedWeight = n.maintenance + n.pregnancy, ewe.weight - (ewe.rlGrowth.gravidKg or 0)
            end
            if m == 6 and h == math.floor(perMonth / 2) then
                local _, n = requirement()
                marks.lactNeed, marks.lactMilk, marks.lactWeight = n.maintenance + n.milk, RLFeed.getDamMilk(ewe), ewe.weight
            end
        end
        if ewe.monthsSinceLastBirth ~= nil and m >= 6 then ewe.monthsSinceLastBirth = ewe.monthsSinceLastBirth + 1 end
        row(m)
        if m == 5 then marks.lambing, marks.gravidAtTerm = RLBodyCondition.getBCS(ewe), ewe.rlGrowth.gravidKg or 0 end
        if m == 8 then
            marks.weaning = RLBodyCondition.getBCS(ewe)
            marks.lambsAtWeaning = (lambs[1].weight + lambs[2].weight) / 2
        end
        if m == 12 then marks.mating = RLBodyCondition.getBCS(ewe) end
    end
    RLFeed.removeObserver(fn)
    tracker.stop()
    local milkPaid, milkPotential = 0, 0
    for _, r in ipairs(log) do
        if r.month >= 6 and r.month <= 8 then milkPaid, milkPotential = milkPaid + r.milkPaid * 30, milkPotential + r.milkPotential * 30 end
    end
    return { log = log, lambingBcs = marks.lambing, weaningBcs = marks.weaning, matingBcs = marks.mating,
        gravidKg = marks.gravidAtTerm, lateNeed = marks.lateNeed, lateNeedWeight = marks.lateNeedWeight, lactNeed = marks.lactNeed,
        lactMilk = marks.lactMilk, lactWeight = marks.lactWeight, startBcs = log[1].bcs, lambBirthKg = lambBirth,
        lambsAtWeaningKg = marks.lambsAtWeaning, lambAdgToWeaning = (marks.lambsAtWeaning - lambBirth) / 90,
        milkPaidKg = milkPaid, milkPotentialKg = milkPotential, plan = plan, capSwitch = marks.capSwitch,
        eweModel = SheepMetrics.export(tracker.rec[ewe]), lambModels = { SheepMetrics.export(tracker.rec[lambs[1]]),
            SheepMetrics.export(tracker.rec[lambs[2]]) } }
end

SheepCalib.reference, SheepCalib.fatClass, SheepCalib.litersPerKgFresh = reference, fatClass, litersPerKgFresh
SheepCalib.raiseWithDam, SheepCalib.storeLambs, SheepCalib.eweYear = raiseWithDam, storeLambs, eweYear
SheepCalib.GRASS, SheepCalib.INTENSIVE, SheepCalib.HOUSED = GRASS, INTENSIVE, HOUSED
