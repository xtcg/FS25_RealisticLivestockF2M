-- Health and low-health death under the real-equivalent nutrition mode (feedProfiles.xml health):
-- calibrated per-model-day rates, the health gene on the rates only, one death curve for every gene,
-- risk built up over model time and drawn once a day, and the same result at 1, 3, 7 and 28 days a
-- month. Game balance values, checked as configured.

loadMod("tests/feedsim.lua")
loadMod("scripts/disease/RLDiseaseRates.lua")

local F, M = RLFeedProfiles, RLFeedMath
local config = F.getConfig()
local health = config.health

-- Config ------------------------------------------------------------------------------------------

check("config: feedProfiles.xml is valid with the health calibration", config.valid == true)
check("config: rates 6.4 lost / 8 regained a model day, gene effect 1/3",
    near(health.lossPerDay, 6.4, 1e-9) and near(health.gainPerDay, 8, 1e-9) and near(health.geneticsRateEffect, 1 / 3, 1e-5))
check("config: the species sections inherit the root's health calibration",
    config.species.SHEEP.lowHealthDeath == config.lowHealthDeath and near(config.species.PIG.health.lossPerDay, 6.4, 1e-9))
do
    local bad = {}
    for k, v in pairs(config) do bad[k] = v end
    bad.lowHealthDeath = { { 0, 1 }, { 40, 0.01 }, { 60, 0.02 }, { 80, 0 } }
    local ok = F.validate(bad)
    check("config: a death curve that rises with health is refused", ok == false)
    bad.lowHealthDeath = config.lowHealthDeath
    bad.health = table.clone(health)
    bad.health.geneticsRateEffect = 1.2
    check("config: a gene effect that could stop health changing is refused", F.validate(bad) == false)
    bad.health = health
    bad.lowHealthDeath = { { 0, 1 }, { 80, 0 } }
    check("config: the fingerprint includes the death curve", F.computeHash(bad) ~= config.hash)
end

-- Rates -------------------------------------------------------------------------------------------

local rows = {}
for _, gene in ipairs({ 1.75, 1, 0.25 }) do
    local loss, gain = -M.getHealthPerDay(-1, gene, health), M.getHealthPerDay(1, gene, health)
    rows[gene] = { loss = loss, gain = gain }
end
check(string.format("rates: a wholly unpaid model day costs %.2f / %.2f / %.2f at genes 1.75 / 1 / 0.25 (4.8 / 6.4 / 8)",
    rows[1.75].loss, rows[1].loss, rows[0.25].loss),
    near(rows[1.75].loss, 4.8, 1e-5) and near(rows[1].loss, 6.4, 1e-5) and near(rows[0.25].loss, 8, 1e-5))
check(string.format("rates: a fed model day regains %.2f / %.2f / %.2f (10 / 8 / 6)", rows[1.75].gain, rows[1].gain, rows[0.25].gain),
    near(rows[1.75].gain, 10, 1e-5) and near(rows[1].gain, 8, 1e-5) and near(rows[0.25].gain, 6, 1e-5))
check("rates: at one day a month (1.25 model days an hour) 6 / 8 / 10 lost and 12.5 / 10 / 7.5 regained an hour",
    near(rows[1.75].loss * 1.25, 6, 1e-5) and near(rows[0.25].loss * 1.25, 10, 1e-5)
    and near(rows[1.75].gain * 1.25, 12.5, 1e-5) and near(rows[0.25].gain * 1.25, 7.5, 1e-5))
check("rates: the spread is 1.67x either way, not upstream's 7x",
    near(rows[0.25].loss / rows[1.75].loss, 5 / 3, 1e-5) and near(rows[1.75].gain / rows[0.25].gain, 5 / 3, 1e-5))
check("rates: half the maintenance unpaid costs half as fast", near(M.getHealthPerDay(-0.5, 1, health), -3.2, 1e-5))

-- Death curve -------------------------------------------------------------------------------------

local points = config.lowHealthDeath
local function perDay(h, age) return M.getLowHealthDeathPerDay(points, h, age or 24, health) end
check("death: 0 at 80 and above, 0.1% at 60, 1% at 40, 5% at 20, certain at 0 (a model day)",
    perDay(100) == 0 and perDay(80) == 0 and near(perDay(60), 0.001, 1e-12) and near(perDay(40), 0.01, 1e-12)
    and near(perDay(20), 0.05, 1e-12) and perDay(0) == 1)
check("death: linear between the points (50 -> 0.55%)", near(perDay(50), 0.0055, 1e-12))
check("death: under 6 months reads 10 health worse (70 -> the 60 chance)", near(perDay(70, 3), 0.001, 1e-12) and perDay(70, 6) > 0
    and perDay(70, 6) < 0.001)

local function riskOf(gene, h)
    local a = GrowthSim.makeAnimal("BULL_ANGUS", { age = 18 })
    a.health, a.genetics.health = h, gene
    a.rlGrowth.lowHealthHazard = nil
    RLFeed.addDeathRisk(a, 1 / 30)
    return a.rlGrowth.lowHealthHazard
end
check("death: the same health gives the same risk at genes 1.75 and 0.25", riskOf(1.75, 40) == riskOf(0.25, 40) and riskOf(1, 40) > 0)
check("death: a healthy step still sets the counter, at 0 (the day change knows the mode ran)", riskOf(1, 100) == 0)

-- Risk over model time ----------------------------------------------------------------------------

-- One game month at health 40: each step adds its model days, each day change draws once. The
-- chance to survive the month is the same at every month length.
for _, days in ipairs({ 1, 3, 7, 28 }) do
    local survive = 1
    local stepsPerDay = 30 / days / 0.25
    for _ = 1, days do
        local hazard = nil
        for _ = 1, math.floor(stepsPerDay + 1e-9) do hazard = M.addDeathHazard(hazard, 0.01, 0.25) end
        -- 28 days: 30/28 model days a day is 4.29 steps; the fraction is carried by the pen clock, here
        -- spread evenly.
        local rest = stepsPerDay - math.floor(stepsPerDay + 1e-9)
        if rest > 1e-9 then hazard = M.addDeathHazard(hazard, 0.01, 0.25 * rest) end
        survive = survive * (1 - M.getHazardChance(hazard))
    end
    check(string.format("risk: a month at health 40 is survived with %.6f at %d days a month (0.99^30 = %.6f)", survive, days, 0.99 ^ 30),
        near(survive, 0.99 ^ 30, 1e-9))
end
check("risk: health 0 is certain death at the day change", M.getHazardChance(M.addDeathHazard(0, 1, 0.25)) == 1)

-- The day change -------------------------------------------------------------------------------------

do
    g_server = g_server or {}
    local savedBroadcast, savedRandom = g_server.broadcastEvent, math.random
    g_server.broadcastEvent = function() end
    AnimalDeathEvent = AnimalDeathEvent or { new = function() return {} end }
    local function cow(h, gene)
        local a = GrowthSim.makeAnimal("BULL_ANGUS", { age = 24 })
        a.health, a.genetics.health, a.numAnimals, a.deathEnabled = h, gene, 1, true
        a.die = function(self) self.isDead = true end
        a.calculateLowHealthDailyAnimalDeaths = function(self, hazard) return AnimalHealth.calculateLowHealthDailyAnimalDeaths(self, hazard) end
        a.calculateOldAgeMonthlyAnimalDeaths = function() return 0 end
        a.calculateRandomMonthlyAnimalDeaths = function() return 0, 0 end
        return a
    end

    local draws = 0
    math.random = function() draws = draws + 1; return 0 end
    local fed = cow(30, 0.25)
    fed.rlGrowth.lowHealthHazard = 0
    local low = AnimalHealth.evaluateDaily(fed, nil, 1)
    check("day: an animal the mode stepped at no risk is not drawn on the old genetic curve (health 30, gene 0.25)",
        low == 0 and draws == 0 and fed.rlGrowth.lowHealthHazard == nil)

    local chance = 0.3
    local hazard = -math.log(1 - chance)
    local a = cow(60, 1.75)
    a.rlGrowth.lowHealthHazard = hazard
    math.random = function() return chance + 1e-6 end
    check("day: a draw above the built-up chance survives, and the counter is cleared",
        AnimalHealth.evaluateDaily(a, nil, 1) == 0 and a.rlGrowth.lowHealthHazard == nil and not a.isDead)
    a.rlGrowth.lowHealthHazard = hazard
    math.random = function() return chance - 1e-6 end
    check("day: a draw below the built-up chance dies of low health (at health 60, whatever the gene)",
        AnimalHealth.evaluateDaily(a, nil, 1) == 1 and a.isDead)

    local off = cow(10, 1)
    off.deathEnabled = false
    off.rlGrowth.lowHealthHazard = 20
    AnimalHealth.evaluateDaily(off, nil, 1)
    check("day: with death off the counter is still cleared (no backlog when it is switched on)", off.rlGrowth.lowHealthHazard == nil)

    local legacy = cow(30, 1)
    legacy.rlGrowth.lowHealthHazard = nil
    math.random = function() return 0 end
    check("day: an animal the mode did not step keeps the old rule", AnimalHealth.evaluateDaily(legacy, nil, 1) == 1)

    math.random, g_server.broadcastEvent = savedRandom, savedBroadcast
end

-- Saved with the animal -------------------------------------------------------------------------------

do
    local a = GrowthSim.makeAnimal("BULL_ANGUS", { age = 18 })
    a.rlGrowth.lowHealthHazard = 0.123
    local written = {}
    local xml = {
        setInt = function(_, k, v) written[k] = v end, setFloat = function(_, k, v) written[k] = v end,
        setString = function(_, k, v) written[k] = v end, setBool = function(_, k, v) written[k] = v end,
        getFloat = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
        getInt = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
        getString = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
        getBool = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
    }
    RLGrowth.saveToXMLFile(a.rlGrowth, xml, "a")
    local loaded = RLGrowth.loadFromXMLFile(xml, "a")
    check("save: the built-up risk is saved with the growth state (a reload neither drops nor repeats it)",
        loaded ~= nil and near(loaded.lowHealthHazard, 0.123, 1e-9))
    check("save: a moved animal keeps its risk (the server's state goes with it)", RLGrowth.copyState(a.rlGrowth).lowHealthHazard == 0.123)
    written = {}
    a.rlGrowth.lowHealthHazard = nil
    RLGrowth.saveToXMLFile(a.rlGrowth, xml, "a")
    check("save: no risk, nothing written", written["a.growth#lowHealthHazard"] == nil)
end

-- In a pen: starve, then feed again, at 1, 3, 7 and 28 days a month --------------------------------

do
    FeedSim.setMode(true)
    local results = {}
    for _, days in ipairs({ 1, 3, 7, 28 }) do
        GrowthSim.setDaysPerPeriod(days)
        local runs = {}
        for _, gene in ipairs({ 1.75, 1, 0.25 }) do
            local a = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
            a.genetics.health = gene
            a.bodyCondition = { reserve = 0.06, capacityKg = 100, balanceEMA = 0, lossRateEMA = 0, lastTick = -1, version = 1 }
            local pen = FeedSim.makePen({ a }, {})
            -- A third of a month without feed, then a month on forage.
            for _ = 1, 8 * days do FeedSim.hour(pen) end
            local starved = a.health
            FeedSim.months(pen, 1, { refill = FeedSim.keepStocked({ FORAGE = 5000 }) })
            runs[gene] = { starved = starved, fed = a.health }
        end
        results[days] = runs
    end
    GrowthSim.setDaysPerPeriod(1)
    local worst = 0
    for _, days in ipairs({ 3, 7, 28 }) do
        for _, gene in ipairs({ 1.75, 1, 0.25 }) do
            worst = math.max(worst, math.abs(results[days][gene].starved - results[1][gene].starved),
                math.abs(results[days][gene].fed - results[1][gene].fed))
        end
    end
    local r = results[1]
    check(string.format("pen: 10 model days unfed leave health %.1f / %.1f / %.1f at genes 1.75 / 1 / 0.25 (better genes lose less)",
        r[1.75].starved, r[1].starved, r[0.25].starved),
        r[1.75].starved > r[1].starved and r[1].starved > r[0.25].starved and r[0.25].starved > 0)
    check(string.format("pen: a month fed again brings every gene back to 100 (%.1f / %.1f / %.1f)", r[1.75].fed, r[1].fed, r[0.25].fed),
        r[1.75].fed == 100 and r[1].fed == 100 and r[0.25].fed == 100)
    check(string.format("pen: 1, 3, 7 and 28 days a month end within 0.1 health of each other (worst %.4f)", worst), worst <= 0.1)
end
