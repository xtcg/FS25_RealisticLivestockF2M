-- SHEEP-RAM-CONC-01 (2026-10-18): a ram's concentrate share is his route's (feedProfiles SHEEP concentrate),
-- apart from his rumen's adaptation. The default (AUTO) ram lamb grows on 20%, up to 40% as his needs want;
-- a breeding ram from 12 months on 10%, up to 25%; between the two over 14 model days by his age alone; an
-- explicit FINISH target is intensive finishing at most 80%; the share rises by at most 5 points a model
-- day. Before: AUTO drove a 10-month Suffolk ram (Landrace here) to ~95% barley, held only by the fibre floor.

loadMod("tests/sheepsim.lua")

local config = RLFeedProfiles.getConfig()
local route = config.species.SHEEP.concentrate

check("config: the SHEEP concentrate routes (20/40, 10/25, 80, 12 months, 14 days, 5 points a day), cattle and pigs none",
    route ~= nil and route.lambTarget == 0.2 and route.lambCap == 0.4 and route.ramTarget == 0.1 and route.ramCap == 0.25
    and route.finishingCap == 0.8 and route.adultFromMonth == 12 and route.transitionDays == 14 and route.targetRisePerDay == 0.05
    and config.concentrate == nil and config.species.PIG.concentrate == nil and config.species.SHEEP.valid == true)
do
    local bad = {}
    for k, v in pairs(config.species.SHEEP) do bad[k] = v end
    bad.concentrate = table.clone(route)
    bad.concentrate.ramTarget = 0.5
    check("config: a target above its cap is refused", RLFeedProfiles.validateSpecies(bad) == false)
end

FeedSim.setMode(true)
SheepSim.enable(true)
GrowthSim.setDaysPerPeriod(1)

-- Hay and barley, the 11F set-up: plenty of both.
local STOCK = { DRYGRASS_WINDROW = 60000, BARLEY = 20000 }

local function ram(id, age, adapted)
    local r = SheepSim.grown("RAM_LANDRACE", id, age)
    r.rlGrowth.feedAdapted = adapted
    return r
end

local function share(animal) return animal.rlFeedIntake ~= nil and animal.rlFeedIntake.concShare or nil end

-- A 10.5-month ram fully adapted to grain (as the 11F ram was): his route holds him at 40% at most.
local lambRam = ram("R10", 10.5, 0.9)
local pen = SheepSim.makePen({ lambRam }, STOCK)
SheepSim.run(pen, 1, STOCK)
check(string.format("ram lamb route: a fully adapted 10.5-month ram eats %.0f%% concentrate (was ~95%%), held by his route", 100 * share(lambRam)),
    share(lambRam) <= 0.4 + 1e-6 and share(lambRam) >= 0.2 - 1e-6 and lambRam.rlFeedIntake.concLimit == "TARGET"
    and near(lambRam.rlGrowth.concTarget, share(lambRam), 1e-6))

-- A breeding ram (14 months): 10%, up to 25%.
local adult = ram("R14", 14, 0.9)
local adultPen = SheepSim.makePen({ adult }, STOCK)
SheepSim.run(adultPen, 1, STOCK)
check(string.format("breeding ram route: a 14-month ram eats %.0f%% concentrate (10-25%%)", 100 * share(adult)),
    share(adult) <= 0.25 + 1e-6 and share(adult) >= 0.1 - 1e-6)

-- Across 12 months: no jump in his share and nothing done to his weight; the route moves over 14 days.
do
    local r = ram("R12", 11.8, 0.3)
    local p = SheepSim.makePen({ r }, STOCK)
    local last, maxDrop, maxRise, steps = nil, 0, 0, 0
    local weightJump = 0
    local function each()
        local s = share(r)
        if last ~= nil and s ~= nil then
            maxDrop = math.max(maxDrop, last - s)
            maxRise = math.max(maxRise, s - last)
        end
        last = s
    end
    local w = r.weight
    for _ = 1, 24 do
        SheepSim.run(p, 1, STOCK)
        each()
        weightJump = math.max(weightJump, math.abs(r.weight - w))
        w = r.weight
    end
    local hourDays = RLFeed.getHourDays()
    check(string.format("12 months: from 11.8 to 12.8 months his share moves at most %.3f a game hour (%.2f model days) - no 0.948 -> 0 jump",
        math.max(maxDrop, maxRise), hourDays),
        maxRise <= 0.05 * hourDays + 1e-6 and maxDrop <= (0.4 - 0.25) * hourDays / 14 + 0.05 + 1e-6)
    check(string.format("12 months: the largest weight change in an hour is %.2f kg (growth, no recomputed weight)", weightJump),
        weightJump < 0.6)
    check("12 months: his rumen's adaptation is not cleared at the boundary", (r.rlGrowth.feedAdapted or 0) > 0)
end

-- The route moves by his age: half way through the 14 days, half way between the routes.
do
    local r = ram("R12H", 12 + 7 / 30, 0.3)
    local got = RLFeed.getConcentrateRoute(r, RLFeed.DEFAULT_RATION, "GROWING", 0.25)
    check("transition: 7 days past 12 months the target is 15% and the cap 32.5%", near(got.target, 0.15, 1e-6) and near(got.cap, 0.325, 1e-6))
    local lambGot = RLFeed.getConcentrateRoute(ram("R11", 11.9, 0.3), RLFeed.DEFAULT_RATION, "GROWING", 0.25)
    local ramGot = RLFeed.getConcentrateRoute(ram("R13", 12.5, 0.3), RLFeed.DEFAULT_RATION, "GROWING", 0.25)
    check("transition: before 12 months the lamb route, from 12 months + 14 days the ram route",
        near(lambGot.target, 0.2, 1e-9) and near(lambGot.cap, 0.4, 1e-9) and near(ramGot.target, 0.1, 1e-9) and near(ramGot.cap, 0.25, 1e-9))
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "E1")
    check("scope: ewes, lambs on milk and other species are not routed",
        RLFeed.getConcentrateRoute(ewe, RLFeed.DEFAULT_RATION, "DRY", 0.25) == nil
        and RLFeed.getConcentrateRoute(r, RLFeed.DEFAULT_RATION, "CALF", 0.25) == nil)
end

-- An unadapted weaned ram lamb: his share rises by at most 5 points a model day toward his route.
do
    local r = ram("R5", 5, 0)
    r.rlGrowth.concTarget = nil
    local p = SheepSim.makePen({ r }, STOCK)
    SheepSim.run(p, 1, STOCK)
    local days = RLFeed.getHourDays()
    check(string.format("rise: an unadapted ram lamb starts at %.3f after a %.2f-day hour (at most 5 points a day)", share(r), days),
        share(r) <= 0.05 * days + 1e-6)
    SheepSim.run(p, 4, STOCK)
    check(string.format("rise: after 5 hours (%.2f model days) he is at %.3f, on his way to 20-40%%", 5 * days, share(r)),
        share(r) <= 0.05 * 5 * days + 1e-6 and share(r) > 0.15)
end

-- Explicit intensive finishing: up to 80%, at least 20% forage.
do
    local r = ram("RF", 6, 0.9)
    local p = SheepSim.makePen({ r }, STOCK)
    RLFeed.setRation(p, { target = "FINISH", grain = "AUTO" })
    r.rlGrowth.concTarget = 0.8
    SheepSim.run(p, 2, STOCK)
    check(string.format("intensive: a ram lamb on an explicit FINISH ration eats %.0f%% concentrate (at most 80%%)", 100 * share(r)),
        share(r) <= 0.8 + 1e-6 and share(r) > 0.4)
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
    local r = ram("RS", 8, 0.4)
    r.rlGrowth.concTarget = 0.27
    RLGrowth.saveToXMLFile(r.rlGrowth, xml, "a")
    local loaded = RLGrowth.loadFromXMLFile(xml, "a")
    check("save: a ram's routed share is saved (a reload does not restart his rise)", loaded ~= nil and near(loaded.concTarget, 0.27, 1e-6))
end

SheepSim.enable(false)
FeedSim.setMode(false)
