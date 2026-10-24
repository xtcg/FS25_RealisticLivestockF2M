-- U14-WATER-01 (2026-10-18): water first, then intake. A pen's water coverage is read off its water
-- spec before the hour's feeding (the engine draws water after the food), never an older hour's or 1 for
-- want of a record; short of water an animal's dry intake falls to the feedProfiles water curve within
-- six model hours and comes back over model days; health loss for water is kept apart from feed.

loadMod("tests/pigsim.lua")

local F, M = RLFeedProfiles, RLFeedMath
local config = F.getConfig()
local water = config.water

-- Config and curve ----------------------------------------------------------------------------------

check("config: the water group (fullFrom 0.9, 0.6 at 0.5, 0.2 with none, 6 h down, 2 days back) is read and valid",
    config.valid == true and water.fullFrom == 0.9 and water.halfCoverage == 0.5 and water.halfIntake == 0.6
    and water.minIntake == 0.2 and water.dropHours == 6 and water.recoveryDays == 2
    and config.species.SHEEP.water.minIntake == 0.2 and config.species.PIG.water.minIntake == 0.2)
do
    local bad = {}
    for k, v in pairs(config) do bad[k] = v end
    bad.water = table.clone(water)
    bad.water.halfIntake = 0.1
    check("config: a curve whose half point is below its floor is refused", F.validate(bad) == false)
    bad.water = table.clone(water)
    bad.water.dropHours = 3
    check("config: the fingerprint includes the water group", F.computeHash(bad) ~= config.hash)
end
check("curve: no hold from 0.9, 0.6 at 0.5, 0.2 with no water, linear between",
    M.getWaterIntakeTarget(1, water) == 1 and M.getWaterIntakeTarget(0.9, water) == 1 and near(M.getWaterIntakeTarget(0.5, water), 0.6, 1e-12)
    and near(M.getWaterIntakeTarget(0, water), 0.2, 1e-12) and near(M.getWaterIntakeTarget(0.7, water), 0.8, 1e-12)
    and near(M.getWaterIntakeTarget(0.25, water), 0.4, 1e-12))
check("ramp: with no water the share falls to 0.2 within 6 model hours (0.6 after 3), never below its target",
    near(M.stepWaterIntake(1, 0, 0.125, water), 0.6, 1e-12) and near(M.stepWaterIntake(1, 0, 0.25, water), 0.2, 1e-12)
    and near(M.stepWaterIntake(1, 0, 3, water), 0.2, 1e-12) and near(M.stepWaterIntake(1, 0.5, 1, water), 0.6, 1e-12))
check("ramp: back at 0.4 a model day once water is back (0.2 -> 1 in 2 days), the same split into steps",
    near(M.stepWaterIntake(0.2, 1, 1, water), 0.6, 1e-12) and M.stepWaterIntake(0.2, 1, 2, water) == 1
    and near(M.stepWaterIntake(M.stepWaterIntake(0.2, 1, 0.5, water), 1, 0.5, water), 0.6, 1e-12)
    and M.stepWaterIntake(nil, 1, 0.25, water) == 1)

-- The pen's coverage ----------------------------------------------------------------------------------

FeedSim.setMode(true)
PigSim.enable(true)

local function grower(id)
    local pig = PigSim.grown("PIG_LANDRACE", id, 4)
    pig.weight = 60
    pig.rlGrowth = RLGrowth.createGeneratedState(pig)
    return pig
end

local dry = grower(1)
local pen = FeedSim.addWater(PigSim.makePen({ dry }, { PIGFOOD = 4000 }), 10, 0)
local wet = grower(2)
local control = FeedSim.addWater(PigSim.makePen({ wet }, { PIGFOOD = 4000 }), 10, 1e6)

check("supply: a stock-fed pen with no water stock covers 0, read off its water spec", RLFeed.getWaterSupply(pen) == 0
    and select(2, RLFeed.getWaterSupply(pen)) == "STOCK")
check("supply: half the hour's need in stock covers half", (function()
    pen.waterLevel = 5
    local c = RLFeed.getWaterSupply(pen)
    pen.waterLevel = 0
    return near(c, 0.5, 1e-12)
end)())
local auto = FeedSim.addWater(PigSim.makePen({}, {}), 10, 0, true)
check("supply: an automatic supply covers all; a pen without a water spec has no water modelled",
    RLFeed.getWaterSupply(auto) == 1 and select(2, RLFeed.getWaterSupply(auto)) == "AUTOMATIC"
    and RLFeed.getWaterSupply(PigSim.makePen({}, {})) == 1 and select(2, RLFeed.getWaterSupply(PigSim.makePen({}, {}))) == "NONE")

-- A record of the last hour (coverage 1, before the water was cut) is not this hour's.
pen.spec_husbandryFood.rlWaterCoverage = { tick = RLBodyCondition.getTickId(), coverage = 1 }
GrowthSim.advanceHour()
check("cache: an older hour's record is not taken; the hour reads the pen's water now",
    RLFeed.getHourWater(pen, RLBodyCondition.getTickId()) == 0)

-- First hour after a load: no record at all, no water. The hour runs on 0, not on 1.
pen.spec_husbandryFood.rlWaterCoverage = nil
local steps = {}
local function observer(kind, data)
    if kind == "STEP" and data.placeable == pen then
        for _, row in ipairs(data.animals) do steps[#steps + 1] = row.feed end
    end
end
RLFeed.addObserver(observer)
FeedSim.hour(pen)
FeedSim.hour(control)
local first = steps[1]
local record = dry.rlFeedIntake
check("first hour: the step's water is 0 (worked out before the feeding), not 1", first ~= nil and first.water == 0
    and record.water == 0 and pen.spec_husbandryFood.rlFeedLast.water == 0)
check("first hour: at one day a month the first 0.25-day step already takes the share to 0.2, held by WATER",
    first ~= nil and near(first.waterIntake, 0.2, 1e-9) and record.intakeLimit == "WATER" and near(record.waterIntake, 0.2, 1e-9)
    and near(dry.rlGrowth.waterIntake, 0.2, 1e-9))
check("first hour: it eats about a fifth of what a watered pig eats (" .. string.format("%.3f / %.3f kg DM", record.kg, wet.rlFeedIntake.kg) .. ")",
    record.kg < 0.25 * wet.rlFeedIntake.kg and record.kg > 0.15 * wet.rlFeedIntake.kg)
check("health: lost for water (reason WATER), counted apart from feed", record.healthReason == "WATER" and record.healthLostWater > 0
    and record.healthLostFeed == 0 and dry.health < 100)
RLFeed.removeObserver(observer)

local dryBefore, wetBefore = dry.weight, wet.weight
for _ = 1, 2 do FeedSim.hour(pen); FeedSim.hour(control) end
check("two dry hours: it gains far less than the watered pig (" .. string.format("%.2f vs %.2f kg", dry.weight - dryBefore, wet.weight - wetBefore) .. ")",
    dry.weight - dryBefore < 0.5 * (wet.weight - wetBefore))

-- Water back: the share comes back over model days, not at once.
pen.waterLevel = 1e6
FeedSim.hour(pen)
check("recovery: the hour the water is back the coverage is 1 but the share is still recovering (0.2 + 0.4 x 1.25 days)",
    dry.rlFeedIntake.water == 1 and near(dry.rlGrowth.waterIntake, 0.7, 1e-6) and dry.rlFeedIntake.intakeLimit == "WATER")
FeedSim.hour(pen)
check("recovery: back to all of its intake within 2 model days, nothing more kept", dry.rlGrowth.waterIntake == nil
    and dry.rlFeedIntake.intakeLimit ~= "WATER")

-- The same model time at 28 days a month: the share falls within 6 model hours there too.
GrowthSim.setDaysPerPeriod(28)
local long = grower(3)
local longPen = FeedSim.addWater(PigSim.makePen({ long }, { PIGFOOD = 4000 }), 10, 0)
local hours = 0
repeat
    FeedSim.hour(longPen)
    hours = hours + 1
until long.rlGrowth.waterIntake ~= nil or hours > 20
local hourDays = RLFeed.getHourDays()
check("28 days a month: the first 6-model-hour step after the cut (game hour " .. hours .. ", " .. string.format("%.2f", hours * hourDays * 24)
    .. " model hours of clock) takes it to 0.2",
    long.rlGrowth.waterIntake ~= nil and near(long.rlGrowth.waterIntake, 0.2, 1e-9) and near(RLFeed.getStepDays() * 24, 6, 1e-9)
    and long.rlFeedIntake.steps == 1 and near(long.rlFeedIntake.dtDays, 0.25, 1e-9))
GrowthSim.setDaysPerPeriod(1)

-- Young on milk: the milk they drink carries their water (milkMax of the diet counts as covered).
do
    local dryAgain = grower(5)
    local dryPen = FeedSim.addWater(PigSim.makePen({ dryAgain }, { PIGFOOD = 100 }), 10, 0)
    local onMilk = RLFeed.getAnimalWater(dryAgain, 1, 0.25)
    local half = RLFeed.getAnimalWater(dryAgain, 0.5, 0.25)
    local none = RLFeed.getAnimalWater(dryAgain, 0, 0.25)
    check("milk: on full milk a dry pen still covers it, on half milk half, weaned none", onMilk == 1 and near(half, 0.5, 1e-12) and none == 0
        and dryPen ~= nil)
end

-- Saved with the animal.
do
    local written = {}
    local xml = {
        setInt = function(_, k, v) written[k] = v end, setFloat = function(_, k, v) written[k] = v end,
        setString = function(_, k, v) written[k] = v end, setBool = function(_, k, v) written[k] = v end,
        getFloat = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
        getInt = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
        getString = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
        getBool = function(_, k, d) local v = written[k]; if v == nil then return d end return v end,
    }
    local a = grower(4)
    a.rlGrowth.waterIntake = 0.35
    RLGrowth.saveToXMLFile(a.rlGrowth, xml, "a")
    local loaded = RLGrowth.loadFromXMLFile(xml, "a")
    check("save: the water share is saved with the growth state (a reload neither resets nor repeats the shortage)",
        loaded ~= nil and near(loaded.waterIntake, 0.35, 1e-9))
    written = {}
    a.rlGrowth.waterIntake = nil
    RLGrowth.saveToXMLFile(a.rlGrowth, xml, "a")
    check("save: full water, nothing written", written["a.growth#waterIntake"] == nil)
end

-- Cattle without a water spec in the sims (the A/B probes) are untouched: their share stays 1.
do
    local cow = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local cattle = FeedSim.makePen({ cow }, { FORAGE = 50000 })
    for _ = 1, 3 do FeedSim.hour(cattle) end
    check("cattle: a pen without a water spec keeps its full intake (no WATER limit, no share kept)",
        cow.rlGrowth.waterIntake == nil and cow.rlFeedIntake ~= nil and cow.rlFeedIntake.intakeLimit ~= "WATER" and cow.rlFeedIntake.water == 1)
end

PigSim.enable(false)
