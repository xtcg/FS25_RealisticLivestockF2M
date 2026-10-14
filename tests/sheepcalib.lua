-- Sheep S5 offline calibration (FS25_SheepBreeds_离线准备 sheep-finishing-design-v1 §5, S5 checklist
-- §C8): the routes R1-R4 and the gates V1-V6 on the real modules, a ewe's year from mating to the
-- next mating, her energy against AHDB Tables 8 and 29, the milk pool (Table 28 potential, what
-- the ewe paid, what the lambs took), sensitivity runs for the proxy and calibration values, and
-- the cost of a 300-sheep pen. Fills CALIB (scenario -> metrics); tests/sheepcalib.py prints it
-- and judges the gates. Real-world targets are in the design; this file only measures.

loadMod("tests/sheepsim.lua")

CALIB = {}
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
    local out = {}
    for _, lamb in ipairs(lambs) do
        local r = results[lamb]
        r.health = lamb.health
        r.finalWeight = lamb.weight
        r.adg0to3 = r.at3 ~= nil and (r.at3 - r.birth) / 90 or nil
        r.adg0to2 = r.at2 ~= nil and (r.at2 - r.birth) / 60 or nil
        out[#out + 1] = r
    end
    local pool = {}
    for m = 1, 3 do pool[m] = milk[m] or { potential = 0, paid = 0, taken = 0 } end
    return out, eweLog, pool
end


--- Weaned store lambs (32 kg unless given) on a stock for `days` model days: ADG, fat, concentrate.
local function storeLambs(breed, sexes, stock, days, opts)
    opts = opts or {}
    GrowthSim.setDaysPerPeriod(1)
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
    local start = {}
    for _, lamb in ipairs(lambs) do start[lamb] = lamb.weight end
    local hours = math.floor(days / 1.25 + 0.5)
    local refill = opts.refill
    local track = {}
    for h = 1, hours do
        if refill ~= nil then refill(pen, h) end
        SheepSim.run(pen, 1, stock)
        for _, lamb in ipairs(lambs) do
            local t = track[lamb] or {}
            track[lamb] = t
            if t.refAt == nil and lamb.weight >= reference(lamb) then t.refAt = h * 1.25 t.xFat = RLBodyCondition.getReserve(lamb) end
        end
    end
    stop()
    local out = {}
    for _, lamb in ipairs(lambs) do
        local gain = lamb.weight - start[lamb]
        local conc = eaten[lamb] or 0
        local fat, r = fatClass(lamb)
        local dm = DM[lamb] or { kg = 0, days = 1 }
        out[#out + 1] = { sex = lamb.rlSex, adg = gain / days, dmPerDay = dm.kg / math.max(dm.days, 1e-9), dmPctBW = dm.kg / math.max(dm.days, 1e-9) / ((lamb.weight + start[lamb]) / 2) * 100, gain = gain, conc = conc, concPerCarcassKg = gain > 0 and conc / (gain * 0.49) or -1,
            fat = fat, reserve = r, x = lamb.weight / reference(lamb), ref = reference(lamb), yield = RLBodyCondition.getYieldFactor(lamb),
            health = lamb.health, refAt = track[lamb] ~= nil and track[lamb].refAt or nil, weight = lamb.weight }
    end
    return out
end


local GRASS = { GRASS_WINDROW = 4000 }
local INTENSIVE = { GRASS_WINDROW = 4000, BARLEY = 4000, PEA = 1000 }
local HOUSED = { SILAGE = 4000, BARLEY = 4000, PEA = 1000 }

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

-- Ewe year, one ewe without a break, from mating to the next mating (lowland Landrace, twins).
-- Month 0: mated, at the reference reserve (BCS 3: the setup, not judged). Five months pregnant
-- on grass, the last two housed on silage (gestation 5 months, Hof Bergmann animals.xml); at
-- month 5 the twins are born as the game does it (pregnancy over, monthsSinceLastBirth 0, a
-- parent; a ewe is never isLactating, RLLactation.startsAtBirth); three months on grass with her
-- lambs; at month 8 they leave (weaning); dry on grass to the next mating at month 12. The same
-- ewe throughout: never rebuilt, her condition never reset. Each month: weight, BCS, gravid mass,
-- what she ate (kg DM, MJ ME a day), her milk at full feed (Table 28), what her budget paid and
-- what her lambs took (kg a day as drunk), and her requirement at the month's middle.
do
    GrowthSim.setDaysPerPeriod(1)
    local perMonth = 24 * GrowthSim.env.daysPerPeriod
    local days = RLFeedProfiles.getConfig().realDaysPerPeriod
    local _, ramSub = Economics.find("RAM_LANDRACE")
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "CY")
    RLGrowth.setReserveIndex(ewe, RLBodyCondition.getConfig(ewe).referenceReserve)
    RLBodyCondition.ensureState(ewe, "calib").reserve = RLBodyCondition.getConfig(ewe).referenceReserve
    local pen = SheepSim.makePen({ ewe })
    local lambs = {}
    local month = { kg = 0, me = 0, days = 0, potential = 0, paid = 0, taken = 0 }
    local fn = function(kind, data)
        if kind ~= "STEP" then return end
        for _, e in ipairs(data.animals) do
            if e.animal == ewe then
                month.kg, month.me, month.days = month.kg + e.feed.kg, month.me + e.feed.me, month.days + e.feed.dtDays
                month.potential = month.potential + RLFeed.getDamMilk(ewe) * data.stepDays
            end
        end
        for _, d in ipairs(data.dams or {}) do
            if d.animal == ewe then month.paid, month.taken = month.paid + d.paidLiters, month.taken + d.allocatedLiters end
        end
    end
    RLFeed.addObserver(fn)
    local log, marks, needs = {}, {}, {}
    local function requirement()
        local dtMonths = 0.25 / days
        local a = RLFeed.describeAnimal(ewe, { target = "AUTO" }, dtMonths, 0.25)
        return a.needs.maintenance + a.needs.pregnancy + a.needs.milk, a.needs
    end
    local function row(m)
        local d = math.max(month.days, 1e-9)
        log[#log + 1] = { month = m, bcs = RLBodyCondition.getBCS(ewe), weight = ewe.weight, gravid = ewe.rlGrowth.gravidKg or 0,
            dmPerDay = month.kg / d, mePerDay = month.me / d, milkPotential = month.potential / d, milkPaid = month.paid / d,
            lambsTook = month.taken / d, need = needs[m] }
        month = { kg = 0, me = 0, days = 0, potential = 0, paid = 0, taken = 0 }
    end
    log[1] = { month = 0, bcs = RLBodyCondition.getBCS(ewe), weight = ewe.weight, gravid = 0 }
    ewe.isPregnant, ewe.pregnancy, ewe.reproduction = true, { pregnancies = { { getSubType = function() return ramSub end },
        { getSubType = function() return ramSub end } } }, 0
    for m = 1, 12 do
        local stock = (m == 4 or m == 5) and { SILAGE = 4000 } or GRASS
        if m == 6 then
            -- Lambing, as AnimalReproduction does it for a ewe.
            ewe.isPregnant, ewe.pregnancy, ewe.reproduction = false, nil, 0
            ewe.monthsSinceLastBirth, ewe.isParent, ewe.birthCount = 0, true, (ewe.birthCount or 1) + 1
            lambs = { SheepSim.lamb("RAM_LANDRACE", "CY", "CY1"), SheepSim.lamb("SHEEP_LANDRACE", "CY", "CY2") }
            pen = SheepSim.makePen({ ewe, lambs[1], lambs[2] })
        elseif m == 9 then
            pen = SheepSim.makePen({ ewe })
        end
        for h = 1, perMonth do
            if m <= 5 then ewe.reproduction = 100 * ((m - 1) * perMonth + h) / (5 * perMonth) end
            SheepSim.run(pen, 1, stock)
            if h == math.floor(perMonth / 2) then needs[m] = requirement() end
            -- Her requirement one week before lambing (Table 8's last column).
            if m == 5 and h == perMonth - math.floor(perMonth * 7 / days + 0.5) then
                local total, n = requirement()
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
        if m == 8 then marks.weaning = RLBodyCondition.getBCS(ewe) end
        if m == 12 then marks.mating = RLBodyCondition.getBCS(ewe) end
    end
    RLFeed.removeObserver(fn)
    CALIB["EWE/year/twins"] = { log = log, lambingBcs = marks.lambing, weaningBcs = marks.weaning, matingBcs = marks.mating,
        gravidKg = marks.gravidAtTerm, lateNeed = marks.lateNeed, lateNeedWeight = marks.lateNeedWeight, lactNeed = marks.lactNeed,
        lactMilk = marks.lactMilk, lactWeight = marks.lactWeight, startBcs = log[1].bcs,
        lambWeights = { lambs[1].weight, lambs[2].weight } }
end

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
    local cells = {}
    for _, w in ipairs({ 50, 60, 70, 80 }) do
        for _, n in ipairs({ 1, 2, 3 }) do
            for _, weeks in ipairs({ 7, 5, 3, 1 }) do
                local ewe = SheepSim.ewe("SHEEP_LANDRACE", "T8")
                SheepSim.makePen({ ewe })
                local pregnancies = {}
                for i = 1, n do pregnancies[i] = { getSubType = function() return ramSub end } end
                ewe.isPregnant, ewe.pregnancy, ewe.reproduction = true, { pregnancies = pregnancies }, 100 * (1 - weeks * 7 / 150)
                ewe.rlGrowth, ewe.rlGrowthPeek = nil, nil
                ewe.weight = w + RLGrowth.getGravidTarget(ewe)
                local a = RLFeed.describeAnimal(ewe, { target = "AUTO" }, 0.25 / days, 0.25)
                cells[#cells + 1] = { w = w, n = n, weeks = weeks, model = a.needs.maintenance + a.needs.pregnancy,
                    maintenance = a.needs.maintenance }
            end
        end
    end
    local sheep = RLFeedProfiles.getConfig().species.SHEEP
    -- One nursing ewe (twins, first month: Table 28's 3.0 kg): describeAnimal's maintenance + milk.
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "T29")
    local pen = SheepSim.makePen({ ewe, SheepSim.lamb("RAM_LANDRACE", "T29", "T29a"), SheepSim.lamb("SHEEP_LANDRACE", "T29", "T29b") })
    FeedSim.hour(pen)
    ewe.rlGrowth, ewe.rlGrowthPeek = nil, nil
    ewe.weight = 70
    local a = RLFeed.describeAnimal(ewe, { target = "AUTO" }, 0.25 / days, 0.25)
    CALIB["ENERGY"] = { table8 = cells, maintenancePerKgMetabolic = sheep.requirements.maintenanceMEPerKgMetabolic,
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
