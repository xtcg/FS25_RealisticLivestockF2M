-- The midnight clock (JT-CLOCK-01, joint test 2026-10-18 C4): the engine's Environment:updateTimeValues
-- (FS25 v1.23.1) takes the hour from dayTime + 0.36 s, so a frame in a day's last 0.36 s sets hour 0
-- and raises HOUR_CHANGED before the day rolls (dayTime <= 24 h); the frame the day rolls raises it
-- again. The raw tick (monotonic day x 24 + hour) went 791 -> 768 -> 792 and the pens settled that
-- hour twice: 650 hourly callbacks for 648 hours, 0.089285714 model days too many on the pen clocks
-- of a 28-day month, extra age and weight on the pigs on the old rules. Here a pig pen in the mode and
-- a breeding pen (sow + piglets; in the mode too since the unified nursing design) run under the engine's own
-- frame-by-frame clock: midnights with a pre-roll frame (several), a save and load inside the pre-roll,
-- a month length switch, and repeated callbacks in an hour must settle exactly as clean midnights do.

loadMod("tests/pigsim.lua")
FeedSim.setMode(true)
PigSim.enable(true)

-- Engine stand-ins for the RLRM husbandry hook file.
Utils = {
    appendedFunction = function(old, new)
        if old == nil then return new end
        return function(...) old(...); new(...) end
    end,
    overwrittenFunction = function(old, new) return function(self, ...) return new(self, old, ...) end end,
}
SpecializationUtil = { registerFunction = function() end }
PlaceableHusbandry = { registerFunctions = function() end, onHourChanged = function() end }
-- Placeable:hourChanged (FS25 v1.23.1 Placeable.lua): raise onHourChanged on the specializations.
Placeable = { hourChanged = function(self, hour) self:onHourChanged(hour) end }
loadMod("scripts/animals/husbandry/placeables/PlaceableHusbandry.lua")

local env = GrowthSim.env
local DAY_MS, HOUR_MS = 86400000, 3600000
local PRE_ROLL_MS = 86399769.1274929 -- the C4 log's pre-roll frame (tick 768 / 1200)
local rawTick = function() return env.currentMonotonicDay * 24 + env.currentHour end

-- The game hour and helper ---------------------------------------------------------------------------

local function setClock(day, hour, dayTime)
    env.currentMonotonicDay, env.currentHour, env.dayTime = day, hour, dayTime
end
setClock(32, 23, 82800000)
local before = RLBodyCondition.getTickId()
setClock(32, 0, PRE_ROLL_MS)
local preRoll, preRollRaw = RLBodyCondition.getTickId(), rawTick()
setClock(33, 0, 1000)
local rolled = RLBodyCondition.getTickId()
setClock(33, 1, HOUR_MS + 1000)
local after = RLBodyCondition.getTickId()
check(string.format("tick: 23:00 %d, pre-roll %d (raw %d), rolled %d, 01:00 %d - never back, the pre-roll is the next day's hour 0",
    before, preRoll, preRollRaw, rolled, after), before == 791 and preRollRaw == 768 and preRoll == 792 and rolled == 792 and after == 793)
setClock(33, 0, 0)
local midnightExact = RLBodyCondition.getTickId()
setClock(33, 0, 11 * HOUR_MS)
check("tick: hour 0 just after the roll (dayTime 0) is not a pre-roll", midnightExact == 792 and not RLBodyCondition.isMidnightPreRoll(env))
-- A save loaded inside the pre-roll: Environment:setEnvironmentTime sets hour floor(dayTime/h + 0.0001) = 24.
setClock(32, 24, PRE_ROLL_MS)
check("tick: a save loaded inside the pre-roll (hour 24) is the same hour", RLBodyCondition.getTickId() == 792)
RLBodyCondition.debugTickOffset = 5
setClock(32, 0, PRE_ROLL_MS)
check("tick: the console fast-forward offset still adds on the pre-roll", RLBodyCondition.getTickId() == 797)
RLBodyCondition.debugTickOffset = 0

-- Placeable:hourChanged: a husbandry once an hour, other placeables as the engine raises them.
local function counter(isHusbandry)
    local p = { calls = 0, spec_husbandry = isHusbandry and {} or nil }
    function p:onHourChanged() self.calls = self.calls + 1 end
    return p
end
local barn, silo = counter(true), counter(false)
local function raise() Placeable.hourChanged(barn, env.currentHour); Placeable.hourChanged(silo, env.currentHour) end
setClock(32, 23, 82800000 + 1000); raise()
setClock(32, 0, PRE_ROLL_MS); raise()
setClock(32, 0, PRE_ROLL_MS + 120); raise()
setClock(33, 0, 600); raise()
setClock(33, 0, 600); raise()
setClock(33, 1, HOUR_MS + 1000); raise()
check(string.format("hook: 23:00, two pre-roll frames, the roll, a repeat, 01:00 - the barn runs %d hours (3), a silo %d callbacks (6)",
    barn.calls, silo.calls), barn.calls == 3 and silo.calls == 6)

-- The engine's clock, frame by frame ---------------------------------------------------------------

--- Environment:updateTimeValues' hour and day part (FS25 v1.23.1), with its order: hour detected, day
--- rolled and month length switched, then HOUR_CHANGED, then DAY_CHANGED. The month length here
--- switches at the next month (the engine waits for the season; the order within the frame is the same).
local function frame(world, dayTime)
    env.dayTime = dayTime
    local timeHours = math.floor(env.dayTime / HOUR_MS + 0.0001)
    local hourChanged, dayChanged, periodChanged = false, false, false
    if timeHours ~= env.currentHour then
        env.currentHour = timeHours
        if env.currentHour == 24 then env.currentHour = 0 end
        hourChanged = true
    end
    if env.dayTime > DAY_MS then
        env.dayTime = env.dayTime - DAY_MS
        env.currentMonotonicDay = env.currentMonotonicDay + 1
        env.currentDayInPeriod = env.currentDayInPeriod + 1
        dayChanged = true
        if env.currentDayInPeriod > env.daysPerPeriod then
            env.currentDayInPeriod, env.currentPeriod = 1, (env.currentPeriod or 1) % 12 + 1
            periodChanged = true
            if world.plannedDaysPerPeriod ~= nil and world.plannedDaysPerPeriod ~= env.daysPerPeriod then
                env.daysPerPeriod, env.timeAdjustment = world.plannedDaysPerPeriod, 1 / world.plannedDaysPerPeriod
            end
        end
    end
    if hourChanged then
        world.callbacks = world.callbacks + 1
        for _, pen in ipairs(world.pens) do Placeable.hourChanged(pen, env.currentHour) end
    end
    -- PigSim.run's month: every animal a whole month older at the new month.
    if periodChanged then
        for _, pen in ipairs(world.pens) do for _, animal in ipairs(pen.animals) do animal.age = animal.age + 1 end end
    end
end

-- FeedSim.hour moves the clock itself; here the engine's frames do.
GrowthSim.advanceHour = function() end

local healthCalls = {}
local updateHealthOnly = AnimalHealth.updateHealthOnly
AnimalHealth.updateHealthOnly = function(animal, ...)
    healthCalls[animal] = (healthCalls[animal] or 0) + 1
    return updateHealthOnly(animal, ...)
end

local STOCK = { PIGFOOD = 4000 }

--- A world: a grower pen in the mode and a breeding pen on the old rules, as husbandry placeables.
local function makeWorld()
    env.daysPerPeriod, env.timeAdjustment, env.currentDayInPeriod, env.currentPeriod = 3, 1 / 3, 1, 3
    setClock(30, 0, 1000)
    local growers = PigSim.makePen({ PigSim.grown("PIG_LANDRACE", 1, 4), PigSim.grown("PIG_LANDRACE", 2, 3.5) }, STOCK)
    local breeding = PigSim.makePen({ PigSim.grown("PIG_LANDRACE", 3, 18, { isParent = true }),
        PigSim.grown("PIG_LANDRACE", 4, 0.4), PigSim.grown("PIG_LANDRACE", 5, 0.4) }, STOCK)
    local world = { pens = { growers, breeding }, callbacks = 0, hours = 0 }
    for _, pen in ipairs(world.pens) do
        pen.spec_husbandry = {}
        local refill = FeedSim.keepStocked(STOCK)
        function pen:onHourChanged()
            world.hours = world.hours + 1
            refill(self)
            self.eaten = (self.eaten or 0) + STOCK.PIGFOOD - self:level("PIGFOOD")
            FeedSim.hour(self)
            self.eaten = self.eaten - (STOCK.PIGFOOD - self:level("PIGFOOD"))
        end
    end
    for _, animal in ipairs(world.pens[1].animals) do healthCalls[animal] = 0 end
    for _, animal in ipairs(world.pens[2].animals) do healthCalls[animal] = 0 end
    return world
end

--- A save and load (RLFeed.savePen/loadPen keep the pen clock's pending model days, at most a step;
--- every hour mark is runtime only) and Environment:setEnvironmentTime's hour.
local function reload(world)
    for _, pen in ipairs(world.pens) do
        local spec = pen.spec_husbandryFood
        local pending = spec.rlFeedClock ~= nil and spec.rlFeedClock.pendingDays or nil
        spec.rlFeedClock = pending ~= nil and { pendingDays = math.min(pending, RLFeed.getStepDays()) } or nil
        spec.rlFeedPen, spec.rlFeedWindow, pen.rlHourTick = nil, nil, nil
        for _, animal in ipairs(pen.animals) do animal.rlFeedStepTick, animal.rlLegacyHourTick, animal.rlFeedStepOwner = nil, nil, nil end
    end
    env.currentHour = math.floor(env.dayTime / HOUR_MS + 0.0001)
end

--- Run `days` days from 00:00 + 1 s: a frame 1 s after each hour and 2 s after midnight; at midnight `preRolls` frames in the
--- day's last 0.36 s first (none: the clean midnight), a reload after the first of them on `reloadDay`
--- (with no pre-roll: at 23:00 + 1 s, before the clean midnight).
local function run(world, days, opts)
    opts = opts or {}
    for day = 1, days do
        for hour = 1, 23 do frame(world, hour * HOUR_MS + 1000) end
        if opts.preRolls == nil and opts.reloadDay == day then reload(world) end
        if opts.preRolls ~= nil and (opts.onDays == nil or opts.onDays[day]) then
            for i = 1, opts.preRolls do
                frame(world, PRE_ROLL_MS + (i - 1) * 100)
                if opts.reloadDay == day and i == 1 then reload(world) end
            end
        end
        if opts.switchOnDay == day then world.plannedDaysPerPeriod = opts.switchTo end
        frame(world, DAY_MS + 1000)
        -- The next frame: after a load inside the pre-roll the hour stood at 24 and changes only now.
        frame(world, 2000)
    end
end

local function fingerprint(world)
    local parts = { string.format("hours=%d day=%d hour=%d dpp=%d", world.hours, env.currentMonotonicDay, env.currentHour, env.daysPerPeriod) }
    for p, pen in ipairs(world.pens) do
        local clock = pen.spec_husbandryFood.rlFeedClock
        parts[#parts + 1] = string.format("pen%d pending=%.17g eaten=%.17g", p, clock ~= nil and clock.pendingDays or -1, pen.eaten or 0)
        for _, a in ipairs(pen.animals) do
            local state = a.rlGrowth or {}
            parts[#parts + 1] = string.format("  %s age=%d ageMonths=%.17g weight=%.17g health=%.17g lastTick=%s calls=%d",
                tostring(a.id), a.age, state.ageMonths or -1, a.weight or -1, a.health or -1, tostring(state.lastTick), healthCalls[a] or 0)
        end
    end
    return table.concat(parts, "\n")
end

local function scenario(days, opts)
    local world = makeWorld()
    run(world, days, opts)
    return world, fingerprint(world)
end

-- 3-day months, then 1-day months: planned on day 7, the switch takes at the next month (after day 9).
local DAYS = 12
local SWITCH = { switchOnDay = 7, switchTo = 1 }
local function with(base, extra)
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

local clean, cleanPrint = scenario(DAYS, SWITCH)
check(string.format("clean: %d days x 24 h = %d callbacks, each pen settles every hour (%d pen-hours)", DAYS, clean.callbacks, clean.hours),
    clean.callbacks == DAYS * 24 and clean.hours == DAYS * 24 * 2)
check("clean: the month length switched to 1 day", env.daysPerPeriod == 1)
local cleanPending = clean.pens[1].spec_husbandryFood.rlFeedClock.pendingDays

local pre, prePrint = scenario(DAYS, with(SWITCH, { preRolls = 1 }))
check(string.format("pre-roll every midnight: %d engine callbacks (+%d), %d pen-hours as clean", pre.callbacks, pre.callbacks - clean.callbacks, pre.hours),
    pre.callbacks == clean.callbacks + DAYS and pre.hours == clean.hours)
check("pre-roll every midnight: pen clocks, food, every pig's age clock, weight, health and health calls as clean (bit for bit)",
    prePrint == cleanPrint)

-- The 3-day months end after days 3, 6 and 9: the length switches at the end of day 9.
local multi, multiPrint = scenario(DAYS, with(SWITCH, { preRolls = 3, onDays = { [3] = true, [9] = true, [10] = true } }))
check(string.format("three pre-roll frames at a month's end, the month length switch and the first 1-day month: %d callbacks, same settlement as clean",
    multi.callbacks), multi.callbacks == clean.callbacks + 9 and multiPrint == cleanPrint)

local _, reloadPrint = scenario(DAYS, with(SWITCH, { reloadDay = 4 }))
local loaded, loadedPrint = scenario(DAYS, with(SWITCH, { preRolls = 2, onDays = { [4] = true }, reloadDay = 4 }))
check("save and load inside a pre-roll: the hour settles once, as a save and load before a clean midnight",
    loadedPrint == reloadPrint and loaded.hours == clean.hours)

-- Control: the old behaviour (raw tick, every callback runs) - the defect this guards against.
local getTickId, claimHour = RLBodyCondition.getTickId, RLBodyCondition.claimHour
RLBodyCondition.getTickId = function() return rawTick() + RLBodyCondition.debugTickOffset end
RLBodyCondition.claimHour = function() return true end
local old, oldPrint = scenario(DAYS, with(SWITCH, { preRolls = 1, onDays = { [2] = true, [5] = true } }))
RLBodyCondition.getTickId, RLBodyCondition.claimHour = getTickId, claimHour
local oldPending = old.pens[1].spec_husbandryFood.rlFeedClock.pendingDays
local oldPiglet, cleanPiglet = old.pens[2].animals[2], clean.pens[2].animals[2]
check(string.format("control (old code, 2 pre-roll midnights): %d pen-hours (+%d), grower clock pending %.6f vs %.6f, piglet age clock +%.6f months",
    old.hours, old.hours - clean.hours, oldPending, cleanPending, oldPiglet.rlGrowth.ageMonths - cleanPiglet.rlGrowth.ageMonths),
    old.hours == clean.hours + 4 and oldPrint ~= cleanPrint and oldPiglet.rlGrowth.ageMonths > cleanPiglet.rlGrowth.ageMonths)
