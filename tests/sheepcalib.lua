-- Sheep S5 offline calibration (FS25_SheepBreeds_离线准备 sheep-finishing-design-v1 §5, S5 checklist
-- §C8): the routes R1-R4 and the gates V1-V6 on the real modules, a ewe's lactation and recovery,
-- and the cost of a 300-sheep pen. Fills CALIB (scenario -> metrics); tests/sheepcalib.py prints it
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
    local out = {}
    for _, lamb in ipairs(lambs) do
        local r = results[lamb]
        r.health = lamb.health
        r.finalWeight = lamb.weight
        r.adg0to3 = r.at3 ~= nil and (r.at3 - r.birth) / 90 or nil
        r.adg0to2 = r.at2 ~= nil and (r.at2 - r.birth) / 60 or nil
        out[#out + 1] = r
    end
    return out, eweLog
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
        local lambs, ewe = raiseWithDam(breed, litter, INTENSIVE, { maxMonths = 6 })
        CALIB["R1/" .. breed .. "/" .. litter] = { lambs = lambs, ewe = ewe }
    end
end
-- R2 / V2: grass and milk only.
for _, breed in ipairs({ "LANDRACE", "TEXEL", "STEINSCHAF", "BLACK_WELSH", "BLACKFACE" }) do
    for _, litter in ipairs({ 1, 2 }) do
        local lambs, ewe = raiseWithDam(breed, litter, GRASS, { maxMonths = 9 })
        CALIB["R2/" .. breed .. "/" .. litter] = { lambs = lambs, ewe = ewe }
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

-- Month length: R1 Landrace twins at 1, 7 and 28 days.
for _, days in ipairs({ 7, 28 }) do
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
