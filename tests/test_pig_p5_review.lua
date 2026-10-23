-- Pig P5 review fixes (2026-10-16, FS25_PigBreeds_离线准备_2026-10-16/reviews/pr60-61-2026-10-16/REVIEW.md):
-- F1 every feed's maxShare holds for what a pig eats when the trough runs short or gives less than asked
-- (meals shrink whole; what was taken above them goes back or is booked lost, never eaten); F2 the pen gate
-- reads a calendar age that moves on with model time while the pen keeps the old rules.

loadMod("tests/pigsim.lua")

local F = RLFeedProfiles
FeedSim.setMode(true)
PigSim.enable(true)
local pigConfig = F.getConfig().species.PIG

--- Each feed's share of what an animal ate (kg DM), and whether every share is within its maxShare.
local function sharesOk(a)
    local total = 0
    for _, fill in pairs(a.byFill) do total = total + fill.kg end
    if total <= 0 then return true, 0 end
    local worst = 0
    for name, fill in pairs(a.byFill) do
        local cap = F.getUsableFeed(name, pigConfig).maxShare
        if cap ~= nil then worst = math.max(worst, fill.kg / total - cap) end
    end
    return worst <= 1e-9, worst
end

local function grower(id, kg)
    local pig = PigSim.grown("PIG_LANDRACE", id, 4)
    pig.weight = kg or 60
    return pig
end

local function planFor(pen)
    local animals = RLFeed.describePen(pen, RLFeed.getRation(pen), 0.25)
    return RLFeed.planPen(pen, RLFeed.getRation(pen), animals, 0.25)
end

-- F1, planner: the base feed runs out, soybean (25%) is plentiful.
for _, base in ipairs({ 4000, 40, 4, 0.000001 }) do
    local pen = PigSim.makePen({ grower(1) }, { PIGFOOD = base, SOYBEAN = 4000 })
    local plan = planFor(pen)
    local a = plan.animals[1]
    local ok, worst = sharesOk(a)
    local soyLiters = plan.withdraw.SOYBEAN or 0
    local emptied = (plan.withdraw.PIGFOOD or 0) >= base * (1 - 1e-9)
    check(string.format("F1 plan: PIGFOOD %g L with soybean plentiful: soybean at most 25%% of what it eats (over by %.2g), a meal the "
        .. "trough cannot fill shrinks whole (FEED_SHORT)", base, worst), ok and (not emptied or a.intakeLimit == "FEED_SHORT")
        and (plan.withdraw.PIGFOOD or 0) <= base + 1e-9 and soyLiters <= 4000)
end
local onlySoy = planFor(PigSim.makePen({ grower(2) }, { SOYBEAN = 4000 })).animals[1]
check("F1 plan: only soybean (25%): no ration holds the cap, it eats none (FEED_CAP)", onlySoy.kg == 0 and onlySoy.intakeLimit == "FEED_CAP")
local twoCapped = planFor(PigSim.makePen({ grower(3) }, { SOYBEAN = 4000, POTATO = 4000 })).animals[1]
check("F1 plan: only soybean (25%) and raw potato (30%): it eats none (FEED_CAP)", twoCapped.kg == 0 and twoCapped.intakeLimit == "FEED_CAP")

-- Pigs of different weights sharing a short trough with piglet feed: every meal within every cap.
local mixed = PigSim.makePen({ grower(4, 20), grower(5, 60), grower(6, 110) }, { PIGFOOD = 3, PIGLETFOOD = 2, SOYBEAN = 4000 })
local mixedPlan = planFor(mixed)
local allOk = true
for _, a in ipairs(mixedPlan.animals) do allOk = allOk and sharesOk(a) end
check("F1 plan: three weights, a short trough with piglet feed: every pig's soybean within 25%", allOk
    and (mixedPlan.withdraw.PIGFOOD or 0) <= 3 + 1e-9 and (mixedPlan.withdraw.PIGLETFOOD or 0) <= 2 + 1e-9)

-- F1, the trough gives less than asked: meals shrink whole, the rest goes back (or is lost), never eaten.
local function stingyHour(withAddFood)
    local pig = grower(7)
    local pen = PigSim.makePen({ pig }, { PIGFOOD = 4000, SOYBEAN = 4000 })
    local remove = pen.removeFood
    function pen:removeFood(liters, index)
        if index == FeedSim.FILL.PIGFOOD then return remove(self, liters * 0.01, index) end
        return remove(self, liters, index)
    end
    if not withAddFood then pen.addFood = nil end
    local step
    local observer = function(kind, data) if kind == "STEP" then step = data end end
    RLFeed.addObserver(observer)
    local before = { PIGFOOD = pen:level("PIGFOOD"), SOYBEAN = pen:level("SOYBEAN") }
    FeedSim.hour(pen)
    RLFeed.removeObserver(observer)
    return pen, step, before
end
for _, withAdd in ipairs({ true, false }) do
    local pen, step, before = stingyHour(withAdd)
    local a = step ~= nil and step.animals[1] or nil
    local ok = a ~= nil and sharesOk({ byFill = a.feed.byFill })
    local ledger = step ~= nil and step.ledger or {}
    local closes, returned, lost = true, 0, 0
    for name, row in pairs(ledger) do
        closes = closes and math.abs(row.withdrawn - (row.eaten + row.returned + row.lost)) < 1e-9
        returned, lost = returned + row.returned, lost + row.lost
        local level = pen:level(name)
        closes = closes and level >= 0 and math.abs(before[name] - level - (row.withdrawn - row.returned)) < 1e-6
    end
    local eatenSoy = a ~= nil and a.feed.byFill.SOYBEAN ~= nil and a.feed.byFill.SOYBEAN.kg or 0
    -- The hour's eaten soybean share from the ledger (liters to kg DM), as well as the last step's.
    local function kgOf(name, liters)
        local p = F.getUsableFeed(name, pigConfig)
        return RLFeedUnits.litersToKg(liters, pigConfig.resourceScale, p.density, p.dm)
    end
    local soyKg = ledger.SOYBEAN and kgOf("SOYBEAN", ledger.SOYBEAN.eaten) or 0
    local baseKg = ledger.PIGFOOD and kgOf("PIGFOOD", ledger.PIGFOOD.eaten) or 0
    ok = ok and soyKg > 0 and soyKg / (soyKg + baseKg) <= 0.25 + 1e-9
    check(string.format("F1 removal (addFood %s): the trough gives 1%% of the PIGFOOD asked; soybean still at most 25%% of what it eats, "
        .. "withdrawn = eaten + returned + lost, stock non-negative", tostring(withAdd)), ok and closes and next(ledger) ~= nil
        and (withAdd and returned > 0 and lost == 0 or (not withAdd and lost > 0 and returned == 0)) and eatenSoy > 0)
end

-- F2 (unified nursing, 2026-10-22): there is no 28-day pen gate any more - a newborn piglet runs the mode from its
-- first hour (its milk is its sow's, here an orphan's none: it lives on what it eats). Its clock runs on model time
-- in the mode, never counted twice.
for _, days in ipairs({ 1, 3, 7 }) do
    while GrowthSim.env.currentHour ~= 0 do GrowthSim.advanceHour() end
    GrowthSim.env.currentMonotonicDay = GrowthSim.env.currentMonotonicDay + 1
    GrowthSim.setDaysPerPeriod(days)
    local hourDays = 30 / (24 * days)
    local piglet = PigSim.grown("PIG_LANDRACE", 30 + days, 0)
    local nursery = PigSim.makePen({ piglet }, { PIGFOOD = 4000, PIGLETFOOD = 4000 })
    local hours = math.ceil(28 / hourDays - 1e-9) + 1
    local entered, worstClock = nil, 0
    for h = 1, hours + 24 do
        FeedSim.keepStocked({ PIGFOOD = 4000, PIGLETFOOD = 4000 })(nursery)
        FeedSim.hour(nursery)
        if nursery.spec_husbandryFood.rlFeedPen.active and entered == nil then entered = h end
        if GrowthSim.env.currentHour == 0 and GrowthSim.env.currentDayInPeriod == 1 then piglet.age = piglet.age + 1 end
        worstClock = math.max(worstClock, math.abs(RLGrowth.getContinuousAge(piglet) * 30 - h * hourDays))
    end
    check(string.format("F2 %d-day month: a newborn piglet runs the mode from hour 1 (entered %s); its clock follows model time "
        .. "within one step (worst %.3f days)", days, tostring(entered), worstClock),
        entered == 1 and worstClock <= 0.25 + 1e-6)
end
GrowthSim.setDaysPerPeriod(1)

PigSim.enable(false)
