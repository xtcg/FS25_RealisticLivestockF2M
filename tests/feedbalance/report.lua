-- FEED-07 offline report: the real-equivalent nutrition mode (RLFeed) on the real feeding path of
-- tests/feedsim.lua (planner, trough removal, both ledgers, RLGrowth.step, health), for every
-- cattle breed with a weight profile. Read-only; run by run.py.
Report = { ledger = { steps = 0, maxEnergyError = 0, maxMassError = 0, invalid = 0 } }
local S, F = GrowthSim, FeedSim

for _, def in ipairs(REPORT_DEFINITIONS) do
    local _, sub = Economics.find(def.name)
    if not sub then
        local _
        _, sub = S.addSubType(def.name, def.breed, def.gender, def.targetWeight)
    end
    for k, v in pairs(def) do sub[k] = v end
    sub.input = { food = { get = function(_, age) return Economics.curve(sub.food, age) end } }
    sub.sellPrice = { get = function(_, age) return Economics.curve(sub.sellPriceCurve or {}, age) end }
    sub.output = { milk = { get = function(_, age) return Economics.curve(sub.milk or {}, age) end } }
    sub.healthIncreaseHour, sub.healthDecreaseHour, sub.healthThresholdFactor = 10, 25, 0.45
end

local original = RLGrowthMath.step
RLGrowthMath.step = function(input, cfg)
    local r = original(input, cfg)
    local l = Report.ledger
    l.steps = l.steps + 1
    l.maxEnergyError = math.max(l.maxEnergyError, math.abs(r.supplyNU + r.mobilizedNU + r.catabolismNU - r.paidNU - r.depositNU - r.lostNU))
    l.maxMassError = math.max(l.maxMassError, math.abs(r.weight - input.weight - r.frameGainKg - r.growthReserveKg - r.depositKg + r.mobilizedKg + r.catabolismKg))
    if r.weight ~= r.weight or r.weight <= 0 or r.reserveKg < -1e-8 or r.reserveKg > r.weight + 1e-8 then l.invalid = l.invalid + 1 end
    return r
end

local BIG = 1e7
Report.ROUTES = {
    TMR = { FORAGE = BIG }, SILAGE = { SILAGE = BIG }, HAY = { DRYGRASS_WINDROW = BIG }, GRASS = { GRASS_WINDROW = BIG },
    HAY_MAIZE = { DRYGRASS_WINDROW = BIG, MAIZE = BIG }, SILAGE_MAIZE = { SILAGE = BIG, MAIZE = BIG },
    GRASS_MAIZE = { GRASS_WINDROW = BIG, MAIZE = BIG }, HAY_WHEAT = { DRYGRASS_WINDROW = BIG, WHEAT = BIG },
    TMR_MAIZE = { FORAGE = BIG, MAIZE = BIG },
}

local function stocked(pen, stock, used)
    for name, liters in pairs(stock) do
        local level = pen:level(name)
        if level < liters then
            used[name] = (used[name] or 0) + (liters - level)
            pen:add(name, liters - level)
        end
    end
end

local function finalUse(pen, stock, used)
    for name, liters in pairs(stock) do used[name] = (used[name] or 0) + (liters - pen:level(name)) end
end

--- A bull from 7 months (weaned, its curve's weight) on a route until 95% of its slaughter
--- reference or 60 months.
function Report.finish(name, route, real, gene)
    F.setMode(real)
    local animal = S.makeAnimal(name, { age = 7, genetics = { metabolism = gene or 1, quality = 1, productivity = 1, fertility = 1, health = 1 } })
    local pen = F.makePen({ animal }, {})
    local stock = Report.ROUTES[route]
    local used = {}
    stocked(pen, stock, used)
    for k in pairs(used) do used[k] = 0 end
    local reference = RLBodyCondition.getReferenceWeight(animal)
    local start = animal.weight
    local kg, me, dmiShare, hours, minHealth, conc = 0, 0, 0, 0, 100, 0
    local perMonth = 24 * S.env.daysPerPeriod
    local reachedAt
    while animal.age < 60 and reachedAt == nil do
        for h = 1, perMonth do
            stocked(pen, stock, used)
            F.hour(pen)
            hours = hours + 1
            local record = animal.rlFeedIntake
            if real and record ~= nil and record.dtDays ~= nil then
                kg, me = kg + record.kg, me + record.me
                dmiShare = dmiShare + record.kg / record.dtDays / animal.weight
                conc = conc + (record.concShare or 0)
            end
            minHealth = math.min(minHealth, animal.health)
            if reference ~= nil and animal.weight >= 0.95 * reference then reachedAt = animal.age + h / perMonth break end
        end
        if reachedAt == nil then animal.age = animal.age + 1 end
    end
    finalUse(pen, stock, used)
    local gain = animal.weight - start
    local out = { subType = name, breed = animal:getSubType().breed, route = route, mode = real and "real" or "legacy",
        gene = gene or 1, startKg = start, endKg = animal.weight, referenceKg = reference, reached = reachedAt ~= nil,
        finishAge = reachedAt or animal.age, months = (reachedAt or animal.age) - 7, gainKg = gain, minHealth = minHealth,
        finishScore = RLBodyCondition.getFinishScore(animal), liters = used }
    if real then
        out.kgDM, out.meMJ = kg, me
        out.kgDMPerKgGain = gain > 0 and kg / gain or nil
        out.dmiPctBW = hours > 0 and dmiShare / hours * 100 or nil
        out.concShare = hours > 0 and conc / hours or nil
        local record = animal.rlFeedIntake
        out.lastLimit = record ~= nil and (record.concLimit or record.intakeLimit) or nil
        out.proteinFactor = record ~= nil and record.proteinFactor or nil
    end
    local litersTotal = 0
    for _, liters in pairs(used) do litersTotal = litersTotal + liters end
    out.litersTotal = litersTotal
    out.litersPerKgGain = gain > 0 and litersTotal / gain or nil
    return out
end

--- A cow from calving (36 months, lactating) for 12 months on a route.
function Report.dairy(name, route, real)
    F.setMode(real)
    local cow = S.makeAnimal(name, { age = 36, isParent = true, isLactating = true, monthsSinceLastBirth = 0 })
    local pen = F.makePen({ cow }, {})
    local stock = Report.ROUTES[route]
    local used = {}
    stocked(pen, stock, used)
    for k in pairs(used) do used[k] = 0 end
    local paid, potential, minReserve, kg = 0, 0, 1, 0
    local startReserve = RLBodyCondition.getReserve(cow)
    local perMonth = 24 * S.env.daysPerPeriod
    for _ = 1, 12 do
        for _ = 1, perMonth do
            stocked(pen, stock, used)
            F.hour(pen)
            local milk, record = cow.rlMilk, cow.rlMilkPaid
            if milk ~= nil and record ~= nil then
                potential = potential + milk.potential / 24 * S.env.timeAdjustment
                paid = paid + (record.deposited and 0 or record.litersPerHour) * S.env.timeAdjustment
            end
            if real and cow.rlFeedIntake ~= nil then kg = kg + (cow.rlFeedIntake.kg or 0) end
            minReserve = math.min(minReserve, RLBodyCondition.getReserve(cow))
        end
        cow.age = cow.age + 1
        if cow.isLactating then
            cow.monthsSinceLastBirth = cow.monthsSinceLastBirth + 1
            if cow.monthsSinceLastBirth >= 10 then cow.isLactating = false end
        end
    end
    finalUse(pen, stock, used)
    local litersTotal = 0
    for _, liters in pairs(used) do litersTotal = litersTotal + liters end
    return { subType = name, route = route, mode = real and "real" or "legacy", milkPaidL = paid, milkPotentialL = potential,
        milkShare = potential > 0 and paid / potential or 0, bcsStart = RLNutritionMath.getBCS(startReserve),
        bcsMin = RLNutritionMath.getBCS(minReserve), bcsEnd = RLBodyCondition.getBCS(cow), endKg = cow.weight, health = cow.health,
        kgDM = real and kg or nil, liters = used, litersTotal = litersTotal }
end

--- Calf routes from birth: STANDARD calf milk and the adult TMR; STARTER also field peas (with the
--- TMR a starter of about 19 % CP), grain after weaning.
Report.CALF_ROUTES = {
    STANDARD = { CALFMILK = BIG, FORAGE = BIG },
    STARTER = { CALFMILK = BIG, FORAGE = BIG, PEA = BIG, MAIZE = BIG },
}

--- A calf in a rearing pen from birth for `months` (6) on a route (STANDARD); opts.birthFactor,
--- opts.gene. Each month: weight, development (its growth phase in months), liters per feed, health.
function Report.calf(name, route, opts)
    opts = opts or {}
    F.setMode(true)
    local genetics = opts.gene ~= nil and { metabolism = opts.gene, quality = 1, productivity = 1, fertility = 1, health = 1 } or nil
    local calf = S.newborn(name, genetics ~= nil and { genetics = genetics } or nil, opts.birthFactor)
    local birth = calf.weight
    local pen = F.makePen({ calf }, {}, { rearing = true })
    local stock = Report.CALF_ROUTES[route or "STANDARD"]
    local months = {}
    local perMonth = 24 * S.env.daysPerPeriod
    local minHealth = calf.health
    for m = 1, opts.months or 6 do
        local used = {}
        stocked(pen, stock, used)
        for k in pairs(used) do used[k] = 0 end
        for _ = 1, perMonth do
            stocked(pen, stock, used); F.hour(pen)
            minHealth = math.min(minHealth, calf.health)
        end
        finalUse(pen, stock, used)
        calf.age = calf.age + 1
        local curve = RLGrowth.getCurve(calf)
        months[m] = { month = m, weightKg = calf.weight, curveKg = curve:value(m), milkL = used.CALFMILK or 0, tmrL = used.FORAGE or 0,
            peaL = used.PEA or 0, maizeL = used.MAIZE or 0, health = calf.health, minHealth = minHealth,
            development = calf.rlGrowth.developmentMonths, adapted = calf.rlGrowth.feedAdapted or 0 }
    end
    return { subType = name, route = route or "STANDARD", birthKg = birth, months = months }
end


--- Resource scale and month length: one route at s = 1 / shipped scale and 1 / 3 / 7 / 28 days a month.
function Report.invariance()
    local config = RLFeedProfiles.getConfig()
    local scale = config.resourceScale
    local out = {}
    for _, case in ipairs({ { scale, 1 }, { 1, 1 }, { scale, 3 }, { scale, 7 }, { scale, 28 } }) do
        config.resourceScale = case[1]
        S.setDaysPerPeriod(case[2])
        F.setMode(true)
        local animal = S.makeAnimal("BULL_ANGUS", { age = 7 })
        local pen = F.makePen({ animal }, {})
        local stock, used = Report.ROUTES.HAY_MAIZE, {}
        stocked(pen, stock, used)
        for k in pairs(used) do used[k] = 0 end
        F.months(pen, 6, { refill = function(p) stocked(p, stock, used) end })
        finalUse(pen, stock, used)
        out[#out + 1] = { scale = case[1], days = case[2], weightKg = animal.weight, hayL = used.DRYGRASS_WINDROW, maizeL = used.MAIZE,
            health = animal.health, adapted = animal.rlGrowth.feedAdapted }
    end
    config.resourceScale = scale
    S.setDaysPerPeriod(1)
    return out
end

--- The male and female cattle subtypes with a weight profile.
function Report.subTypes(gender)
    local list = {}
    for _, sub in ipairs(Economics.subTypes) do
        if sub.typeName == "COW" and sub.gender == gender and RLGrowth.getBinding(sub) ~= nil then list[#list + 1] = sub.name end
    end
    table.sort(list)
    return list
end
