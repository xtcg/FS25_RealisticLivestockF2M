-- U43-AGE-01 under the real-equivalent nutrition mode (sheep, RLFeed's model-time steps of
-- stepDays): a full model month adds 1.0 to a grown ram (its birthday in mid-month, as a dealer
-- animal's) and to a lamb born in the game, at 1, 2 and 28 days per month. The batch G case: the
-- ram's clock at 19.983 under one-day months, then a two-day month with its birthday on day 2.

loadMod("tests/sheepsim.lua")

FeedSim.setMode(true)
SheepSim.enable(true)
GrowthSim.setDaysPerPeriod(1)

local env = GrowthSim.env
local STOCK = { GRASS_WINDROW = 6000, DRYGRASS_WINDROW = 6000 }

local ram = SheepSim.grown("RAM_LANDRACE", "R1", 19.983)
local lamb = SheepSim.lamb("SHEEP_LANDRACE", "none", "L1")
local pen = SheepSim.makePen({ ram, lamb }, STOCK)
local refill = FeedSim.keepStocked(STOCK)

-- One hour; the lamb ages at the month change (born on the 1st), the ram on `ramBirthdayDay`.
local function run(hours, ramBirthdayDay)
    for _ = 1, hours do
        refill(pen)
        FeedSim.hour(pen)
        if env.currentHour == 0 then
            if env.currentDayInPeriod == 1 then lamb.age = lamb.age + 1 end
            if env.currentDayInPeriod == math.min(ramBirthdayDay, env.daysPerPeriod) then ram.age = ram.age + 1 end
        end
    end
end

local function age(animal) return RLGrowth.getContinuousAge(animal) end

for _, days in ipairs({ 1, 2, 28 }) do
    GrowthSim.setDaysPerPeriod(days)
    local r0, l0 = age(ram), age(lamb)
    run(24 * days, 2)
    local dr, dl = age(ram) - r0, age(lamb) - l0
    check(string.format("U43 sheep %d-day month: ram %+.6f (from %.3f, birthday on day 2), lamb %+.6f", days, dr, r0, dl),
        math.abs(dr - 1) <= 1e-5 and math.abs(dl - 1) <= 1e-5 and pen.spec_husbandryFood.rlFeedPen.active)
end
GrowthSim.setDaysPerPeriod(1)
FeedSim.setMode(false)
SheepSim.enable(false)
