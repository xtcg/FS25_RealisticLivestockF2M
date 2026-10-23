-- Background accidents (RL-ACCIDENT-RATE-01), no accident cash (RL-DEATH-CASH-01) and the birth
-- ledger (BIRTH-SOLD-NEGATIVE-01, PIG-BIRTH-COUNT-01): per-model-month bands by species and age,
-- integrated over the model time a day stands for (the same risk at 1, 2 and 28 days a month),
-- the setting 0 never drawing, nothing paid, and a litter that always closes.

AnimalType = { COW = 1, PIG = 2, SHEEP = 3, HORSE = 4, CHICKEN = 5 }

local INFO = {}
local baseLogger = RmLogging.getLogger
RmLogging.getLogger = function()
    local l = baseLogger()
    l.info = function(_, fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
    return l
end
loadMod("scripts/disease/RLDiseaseRates.lua")
loadMod("scripts/animal/AnimalHealth.lua")

local H = AnimalHealth
local B = H.ACCIDENT_BANDS

local function lnq(p) return -math.log(1 - p) end

-- Bands ---------------------------------------------------------------------------------------------

check("bands: pig 0.10% to 28 days, 0.04% to 6 months, 0.02% after (a model month)",
    near(B.PIG[1][1], 28 / 30, 1e-12) and B.PIG[1][2] == 0.0010 and B.PIG[2][1] == 6 and B.PIG[2][2] == 0.0004
    and B.PIG[3][1] == math.huge and B.PIG[3][2] == 0.0002)
check("bands: sheep (and goats) 0.06% under 3 months, 0.03% after",
    B.SHEEP[1][1] == 3 and B.SHEEP[1][2] == 0.0006 and B.SHEEP[2][2] == 0.0003)
check("bands: cattle 0.04% under 6 months, 0.02% after; horse 0.02%; chicken 0.03%; other 0.03%",
    B.COW[1][1] == 6 and B.COW[1][2] == 0.0004 and B.COW[2][2] == 0.0002 and B.HORSE[1][2] == 0.0002
    and B.CHICKEN[1][2] == 0.0003 and B.OTHER[1][2] == 0.0003)

local function animal(typeIndex, age, fields)
    local a = { animalTypeIndex = typeIndex, age = age, numAnimals = 1, isDead = false, deathEnabled = true,
        farmId = "F1", uniqueId = "A1", subType = "TEST", birthday = { country = 6 }, health = 100,
        genetics = { health = 1 } }
    for k, v in pairs(fields or {}) do a[k] = v end
    a.die = function(self, reason) self.isDead, self.numAnimals, self.deathReason = true, 0, reason end
    a.getSellPrice = function() error("an accident must not price the carcass") end
    return a
end

do
    local _, key = H.getAccidentBands(animal(nil, 10), { animalTypeIndex = AnimalType.SHEEP })
    local _, other = H.getAccidentBands(animal(99, 10), nil)
    check("bands: an animal's own type, the spec's when it has none, OTHER for an unknown type", key == "SHEEP" and other == "OTHER")
end

-- Hazard ----------------------------------------------------------------------------------------------

check("hazard: one band, H = -ln(1 - p) x months", near(H.getAccidentHazard(B.COW, 10, 10.5, 1), lnq(0.0002) * 0.5, 1e-15))
check("hazard: the setting multiplies the hazard", near(H.getAccidentHazard(B.COW, 10, 10.5, 2), 2 * lnq(0.0002) * 0.5, 1e-15))
check("hazard: the setting 0 is no hazard", H.getAccidentHazard(B.PIG, 0, 1, 0) == 0)
check("hazard: a span across the pig's 28-day edge is split at it",
    near(H.getAccidentHazard(B.PIG, 0.9, 1.0, 1), lnq(0.001) * (28 / 30 - 0.9) + lnq(0.0004) * (1 - 28 / 30), 1e-15))
check("hazard: a span across two edges (0.5 .. 7 months) takes all three pig bands",
    near(H.getAccidentHazard(B.PIG, 0.5, 7, 1), lnq(0.001) * (28 / 30 - 0.5) + lnq(0.0004) * (6 - 28 / 30) + lnq(0.0002), 1e-15))

for _, days in ipairs({ 1, 2, 28 }) do
    local a = animal(AnimalType.COW, 24)
    local chance = H.getAccidentDayChance(a, {}, days)
    check(string.format("hazard: an adult cow's day at %d days a month is RLDiseaseRates.perTick's (upstream's conversion, once)", days),
        near(chance, RLDiseaseRates.perTick(0.0002, days), 1e-15))
end

-- Age span ---------------------------------------------------------------------------------------------

do
    local a = animal(AnimalType.PIG, 0, { rlGrowth = { ageMonths = 0.95 } })
    local from, to = H.getAccidentAgeSpan(a, 1 / 28)
    check("span: ends at the growth clock", near(to, 0.95, 1e-12) and near(from, 0.95 - 1 / 28, 1e-12))
    local b = animal(AnimalType.COW, 5, { rlGrowth = { ageMonths = 5.5 } })
    local f2, t2 = H.getAccidentAgeSpan(b, 1 / 28)
    check("span: mid-month, the day ends at the clock, not at the whole months",
        near(f2, 5.5 - 1 / 28, 1e-12) and near(t2, 5.5, 1e-12))
    local c = animal(AnimalType.SHEEP, 5)
    local f3, t3 = H.getAccidentAgeSpan(c, 1)
    check("span: without a clock, from the start of the whole month of age", f3 == 5 and t3 == 6)
    local d = animal(AnimalType.PIG, 0, { rlGrowth = { ageMonths = 0.01 } })
    check("span: never before birth", H.getAccidentAgeSpan(d, 1) == 0)
end

-- Cold, disease, water, health, birth: no factor ----------------------------------------------------------

do
    local base = H.getAccidentDayChance(animal(AnimalType.SHEEP, 1), { minTemp = 20 }, 1)
    local cold = H.getAccidentDayChance(animal(AnimalType.SHEEP, 1), { minTemp = -15 }, 1)
    local sick = H.getAccidentDayChance(animal(AnimalType.SHEEP, 1, { health = 5, diseases = { { title = "x" } },
        isPregnant = true, reproduction = 99, monthsSinceLastBirth = 0, rlWaterShort = 1, genetics = { health = 0.25 } }), { minTemp = 5 }, 1)
    check("factors: the cold, disease, low health, water and birth leave the accident chance as it is",
        base > 0 and base == cold and base == sick and near(base, 0.0006, 1e-15))
end

-- Equal model time, equal risk ------------------------------------------------------------------------------

-- A pig followed from birth through 7 model months on its clock, one draw a day: the chance to
-- survive is exp(-H over 0..7 months) at 1, 2 and 28 days a month, whatever the bands crossed.
do
    local expected = math.exp(-(lnq(0.001) * 28 / 30 + lnq(0.0004) * (6 - 28 / 30) + lnq(0.0002)))
    for _, days in ipairs({ 1, 2, 28 }) do
        local a = animal(AnimalType.PIG, 0, { rlGrowth = { ageMonths = 0 } })
        local survive = 1
        for _ = 1, 7 * days do
            a.rlGrowth.ageMonths = a.rlGrowth.ageMonths + 1 / days
            a.age = math.floor(a.rlGrowth.ageMonths + 1e-9)
            survive = survive * (1 - H.getAccidentDayChance(a, {}, days))
        end
        check(string.format("model time: a piglet survives 7 model months with %.9f at %d days a month (exp(-H) = %.9f)",
            survive, days, expected), near(survive, expected, 1e-12))
    end
end

-- The same through the roll itself, a fixed seed and a large sample: high test bands so the counts
-- mean something; 20000 animals a month length, each followed for one model month.
do
    local savedBands, savedRandom = H.ACCIDENT_BANDS, math.random
    H.ACCIDENT_BANDS = { COW = { { 6, 0.30 }, { math.huge, 0.10 } } }
    local function lcg(seed)
        local state = seed
        return function()
            state = (state * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
            return (state >> 11) / 2 ^ 52
        end
    end
    local n = 20000
    -- 5 .. 7 months: a month at 30%, a month at 10%.
    local p = 1 - 0.7 * 0.9
    local sd = math.sqrt(n * p * (1 - p))
    local counts = {}
    for _, days in ipairs({ 1, 2, 28 }) do
        math.random = lcg(20261017 + days)
        local deaths, paid = 0, 0
        for i = 1, n do
            local a = animal(AnimalType.COW, 5, { rlGrowth = { ageMonths = 5 }, uniqueId = tostring(i) })
            for _ = 1, 2 * days do
                if a.isDead then break end
                a.rlGrowth.ageMonths = a.rlGrowth.ageMonths + 1 / days
                a.age = math.floor(a.rlGrowth.ageMonths + 1e-9)
                local died, money = H.calculateRandomMonthlyAnimalDeaths(a, {}, days)
                deaths, paid = deaths + died, paid + money
            end
        end
        counts[days] = deaths
        check(string.format("sample: %d of %d die over two model months at %d days a month (expected %.0f, 4 sd %.0f), paid %s",
            deaths, n, days, n * p, 4 * sd, tostring(paid)), math.abs(deaths - n * p) < 4 * sd and paid == 0)
    end
    check(string.format("sample: 1 / 2 / 28 days a month agree within 4 sd of a difference (%d / %d / %d)", counts[1], counts[2], counts[28]),
        math.abs(counts[1] - counts[28]) < 4 * sd * math.sqrt(2) and math.abs(counts[2] - counts[28]) < 4 * sd * math.sqrt(2))

    -- Setting 0: never a draw, never a death, at any month length and age.
    local drawn = 0
    math.random = function() drawn = drawn + 1; return 0 end
    H.ACCIDENT_BANDS = savedBands
    local died = 0
    for _, days in ipairs({ 1, 2, 28 }) do
        for _, t in ipairs({ AnimalType.PIG, AnimalType.SHEEP, AnimalType.COW, AnimalType.HORSE, AnimalType.CHICKEN, 99 }) do
            for i = 1, 1000 do
                local a = animal(t, 0, { accidentsChance = 0, rlGrowth = { ageMonths = (i % 100) / 10 } })
                died = died + H.calculateRandomMonthlyAnimalDeaths(a, {}, days)
            end
        end
    end
    check("setting 0: 18000 animal-days at a draw of 0 (certain death otherwise) never die and never draw", died == 0 and drawn == 0)
    math.random = savedRandom
end

-- The day change: one event, the server only, nothing paid ----------------------------------------------

do
    local broadcasts = 0
    local savedServer, savedRandom = g_server, math.random
    AnimalDeathEvent = { new = function() return {} end }
    FarmManager = FarmManager or { INVALID_FARM_ID = 0 }
    local function cow()
        local a = animal(AnimalType.COW, 2)
        a.calculateLowHealthDailyAnimalDeaths = function() return 0 end
        a.calculateOldAgeMonthlyAnimalDeaths = function() return 0 end
        a.calculateRandomMonthlyAnimalDeaths = function(self, spec, d) return H.calculateRandomMonthlyAnimalDeaths(self, spec, d) end
        return a
    end
    g_server = { broadcastEvent = function() broadcasts = broadcasts + 1 end }
    INFO = {}
    math.random = function() return 0 end
    local a = cow()
    local low, old, random, money = H.evaluateDaily(a, { minTemp = -20 }, 1)
    check("day: a server accident is one death, one event, no money", random == 1 and low == 0 and old == 0 and money == 0
        and broadcasts == 1 and a.deathReason == "rl_death_accident")
    local line = INFO[#INFO] or ""
    check("day: the death line names the animal, model time, cause, chance and money",
        line:find("DEATH: cause=rl_death_accident", 1, true) ~= nil and line:find("uniqueId=A1", 1, true) ~= nil
        and line:find("daysPerPeriod=", 1, true) ~= nil and line:find("chance=", 1, true) ~= nil and line:find("money=0", 1, true) ~= nil)
    check("day: a dead animal is not rolled again", H.calculateRandomMonthlyAnimalDeaths(a, {}, 1) == 0)
    g_server = nil
    local drawn = 0
    math.random = function() drawn = drawn + 1; return 0 end
    local b = cow()
    local _, _, r2 = H.evaluateDaily(b, {}, 1)
    check("day: a client never draws an accident", r2 == 0 and drawn == 0 and not b.isDead)
    g_server, math.random = savedServer, savedRandom
end

-- Birth ledger ----------------------------------------------------------------------------------------------

-- The whole reproduction module: the child loop's GIANTS `continue` becomes a goto to the loop's end
-- (exact), every other `continue` a break (the paths below never reach them).
local f = assert(io.open(REPO .. "scripts/animal/AnimalReproduction.lua", "r"))
local source = f:read("*a")
f:close()
local loopContinue = "            continue\n\n        end\n\n        if useGrowth then"
assert(source:find(loopContinue, 1, true), "child loop continue")
source = source:gsub(loopContinue:gsub("%p", "%%%0"), "            goto rl_next_child\n\n        end\n\n        if useGrowth then")
local loopEnd = "\n    end\n\n    if deadChildrenCount > 0 and"
assert(source:find(loopEnd, 1, true), "child loop end")
source = source:gsub(loopEnd:gsub("%p", "%%%0"), "\n    ::rl_next_child::\n    end\n\n    if deadChildrenCount > 0 and")
source = source:gsub("%f[%a]continue%f[%A]", "break")
assert(load(source, "AnimalReproduction"))()

RLGrowth.coversSubType = function() return false end
RLAnimalUtil = { toKey = function(...) return table.concat({ ... }, "/") end }
RealisticLivestock = { getMapCountryIndex = function() return 6 end }
AnimalBirthEvent = { new = function(_, mother, children, parentDied) return { children = #children, parentDied = parentDied } end }
g_diseaseManager = nil
g_i18n = g_i18n or { formatMoney = function(_, v) return tostring(v) end }

local function litter(n, deadAt, freeSlots, opts)
    opts = opts or {}
    local broadcasts, stats, queued = {}, {}, {}
    g_server = { broadcastEvent = function(_, e) broadcasts[#broadcasts + 1] = e end }
    g_currentMission = g_currentMission or {}
    g_currentMission.animalSystem = { getTypeByIndex = function() return { statsBreedingName = "breedPigs" } end }
    g_currentMission.farmStats = function() return { updateStats = function(_, name, v) stats[#stats + 1] = v end } end
    local subType = { breed = "BLACK_PIED", typeIndex = AnimalType.PIG, name = "PIG_BLACK_PIED" }
    local children = {}
    for i = 1, n do
        children[i] = { genetics = { metabolism = 1, health = 1 }, subType = "PIG_BLACK_PIED", gender = i % 2 == 0 and "male" or "female",
            uniqueId = "U" .. i, getSubType = function() return subType end,
            setBirthday = function(self, b) self.birthday = b end,
            setClusterSystem = function(self, c) self.clusterSystem = c end,
            setUniqueId = function(self) self.uniqueId = "K" .. i end,
            getSellPrice = function() return 100 + i end }
        if opts.marketUnavailableChildren then
            children[i].getLegacySellPrice=function()return 100+i end
            children[i].getSellPrice=function()return nil end
        end
    end
    local cluster = { getPendingDelta = function() return 0, 0, 0 end,
        addPendingAddCluster = function(_, c) queued[#queued + 1] = c end }
    local messages = {}
    local sow = { uniqueId = "110397", farmId = "404734", subType = "PIG_BLACK_PIED", subTypeIndex = 17, breed = "BLACK_PIED",
        animalTypeIndex = AnimalType.PIG, deathEnabled = true, isParent = false, children = {}, birthday = { country = 6 },
        genetics = { health = opts.damHealth or 10 }, clusterSystem = cluster,
        impregnatedBy = { uniqueId = "-1" }, pregnancy = { expected = { day = 1, month = 7, year = 2 }, pregnancies = children },
        getSubType = function() return subType end, getAnimalTypeIndex = function() return AnimalType.PIG end,
        resolveBirthCount = function() return 0 end, addMessage = function(_, k, a) messages[k] = a or true end,
        die = function(self) self.isDead = true end }
    local spec = { maxNumAnimals = 1 + freeSlots, getNumOfAnimals = function() return 1 end, getOwnerFarmId = function() return 1 end }
    local dead = {}
    for _, i in ipairs(deadAt) do dead[i] = true end
    local index = 0
    RLBirthWeight = { draw = function() index = index + 1; return 1.4, 0, 1.45 end,
        getSurvivalChance = function() return dead[index] and 0 or 1 end }
    local savedRandom = math.random
    math.random = function() return 0.5 end
    INFO = {}
    local kept, parentDied, sold, money = AnimalReproduction.reproduce(sow, spec, 1, 7, 2, false)
    math.random = savedRandom
    local ledger
    for _, line in ipairs(INFO) do if line:find("BIRTH_LEDGER", 1, true) then ledger = line end end
    local deaths = 0
    for _, line in ipairs(INFO) do if line:find("BIRTH_DEATH", 1, true) then deaths = deaths + 1 end end
    return { kept = kept, parentDied = parentDied, sold = sold, money = money, queued = #queued, stats = stats[1],
        event = broadcasts[1], messages = messages, ledger = ledger, deathLines = deaths, children = children }
end

do
    -- PIG-BIRTH-COUNT-01 as recorded (batchD BIRTH: born 10, soldOffspring -2, soldAmount 0): 12 in
    -- the litter, 2 died at birth, room for all.
    local r = litter(12, { 3, 9 }, 50)
    check("birth: 12 in the litter, 2 died at birth -> 10 kept, 0 sold (was -2), 0 money",
        r.kept == 10 and r.sold == 0 and r.money == 0 and r.queued == 10 and r.event.children == 10)
    check("birth: the farm's breeding stats and the birth event count the 10 kept", r.stats == 10 and r.messages.PREGNANCY_MULTIPLE[1] == 10
        and r.messages.PREGNANCY_SOLD == nil and r.messages.PREGNANCY_DIED[1] == 2)
    check("birth: each death at birth has its own line and the ledger closes 12 = 2 + 0 + 10",
        r.deathLines == 2 and r.ledger ~= nil and r.ledger:find("litter=12 liveBorn=10 diedAtBirth=2 sold=0 soldMoney=0.00 kept=10", 1, true) ~= nil)

    -- BIRTH-SOLD-NEGATIVE-01 (11 alive, 1 died at birth, room for all).
    local s = litter(12, { 12 }, 20)
    check("birth: one died at birth with room for all -> sold 0, not -1", s.sold == 0 and s.kept == 11 and s.money == 0)

    -- Short of room: the dead need none; the live beyond the room are sold and paid.
    local t = litter(12, { 1, 2 }, 9)
    check("birth: 12, 2 died, room for 9 -> 1 sold (the dearest, paid its price), 9 kept (the old count said 7)", t.sold == 1 and t.kept == 9 and t.queued == 9
        and t.money == 112 and t.messages.PREGNANCY_SOLD[1] == 1)
    local u = litter(12, { 1, 2, 3 }, 9)
    check("birth: 12, 3 died, room for 9 -> 0 sold, 9 kept (the old count said 6 kept)",
        u.sold == 0 and u.kept == 9 and u.queued == 9 and u.money == 0)
    local v = litter(12, { 1, 2 }, 11)
    check("birth: 12, 2 died, room for 11 -> 0 sold, 10 kept (the old count kept 9 and sold -1)", v.sold == 0 and v.kept == 10 and v.queued == 10)
    local w = litter(5, {}, -3)
    check("birth: a pen already over its cap sells every live young, never more", w.sold == 5 and w.kept == 0 and w.queued == 0
        and w.money == 101 + 102 + 103 + 104 + 105 and w.stats == 0)
    local x = litter(4, { 1, 2, 3, 4 }, 0)
    check("birth: a whole litter dead with no room -> 0 sold, 0 kept, no money", x.sold == 0 and x.kept == 0 and x.money == 0 and x.queued == 0)

    -- Every case closes: litter = died + sold + kept, none negative, money = the sold young's prices.
    local ok = true
    for n = 1, 6 do
        for room = -2, 7 do
            for mask = 0, (1 << n) - 1 do
                local deadAt = {}
                for i = 1, n do if mask & (1 << (i - 1)) ~= 0 then deadAt[#deadAt + 1] = i end end
                local r2 = litter(n, deadAt, room)
                local live = n - #deadAt
                local expectSold = math.max(0, math.min(live, live - room))
                if r2.sold < 0 or r2.kept < 0 or r2.sold + r2.kept + #deadAt ~= n or r2.sold ~= expectSold
                    or r2.queued ~= r2.kept or (r2.sold == 0 and r2.money ~= 0) then ok = false end
            end
        end
    end
    check("birth: every litter of 1-6 with every death pattern and room -2..7 closes, nothing negative", ok)
end
local marketOverflow=litter(3,{},1,{marketUnavailableChildren=true})
check("birth: unavailable live quotes do not interrupt identities/parentage or legacy overflow disposal",marketOverflow.sold==2 and marketOverflow.kept==1 and marketOverflow.queued==1 and marketOverflow.money==205)
