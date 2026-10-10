-- Real liquid-milk calibration, through the same planner and feeding path as the game.
loadMod("tests/feedsim.lua")
local config = RLFeed.getConfig()
local function near(a, b, tolerance) return math.abs(a - b) <= (tolerance or 1e-9) end
local U, M = RLFeedUnits, RLFeedMath
local milk = RLFeedProfiles.getUsableFeed("CALFMILK")
local baseLimit = M.getCalfMilkLimit(45, 45, 1, config.calfMilk)
check("calf milk: reference 10 real L/day = 1.2875 kg DM/day = 60 game L/30-day month",
    near(baseLimit, 1.2875) and near(U.kgToLiters(baseLimit * 30, 0.2, milk.density, milk.dm), 60))
check("calf milk: 8 real L/day maps to 48 game L/month, no extra resource discount",
    near(U.kgToLiters(8 * 1.03 * 0.125 * 30, 0.2, milk.density, milk.dm), 48))
check("calf milk: a smaller breed gets less, by its birth weight share ^ sizeExponent (0.75), and weaning is applied once",
    config.calfMilk.sizeExponent == 0.75 and near(M.getCalfMilkLimit(30, 45, 0.7, config.calfMilk), baseLimit * (30 / 45) ^ 0.75 * 0.7)
    and M.getCalfMilkLimit(45, 45, 0, config.calfMilk) == 0)
local bad = table.clone(config)
bad.calfMilk = table.clone(config.calfMilk)
bad.calfMilk.realLitersPerDay = -1
check("calf milk: invalid intake calibration disables the mode", RLFeedProfiles.validate(bad) == false)
bad.calfMilk.realLitersPerDay = 10
bad.calfMilk.dm = 1.1
check("calf milk: reference liquid DM above 100% is invalid", RLFeedProfiles.validate(bad) == false)
bad.calfMilk.dm = 0.125
bad.calfMilk.realLitersPerDay = 8
check("calf milk: the config fingerprint includes the allowance", RLFeedProfiles.computeHash(bad) ~= config.hash)

FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(1)
local calf = GrowthSim.newborn("BULL_HOLSTEIN")
local pen = FeedSim.makePen({calf}, {CALFMILK = 10000, FORAGE = 10000}, {rearing = true})
local function describe(a)
    return RLFeed.describeAnimal(a, RLFeed.getRation(pen), 1 / 24, 30 / 24)
end
local d1 = describe(calf)
calf.weight = calf.weight * 2
local d2 = describe(calf)
check("calf milk: current live weight increases appetite but cannot inflate the milk ceiling",
    d2.appetite > d1.appetite and near(d1.milkMaxKgPerDay, d2.milkMaxKgPerDay))
local small = GrowthSim.newborn("BULL_ANGUS")
check("calf milk: Angus allowance is smaller than Holstein", describe(small).milkMaxKgPerDay < d1.milkMaxKgPerDay)

-- Fixed state, deliberately ample appetite: the actual planner/withdrawal is capped, not only
-- the forecast text. Milk's fixed ME is paid without the calf's solid-energy discount.
local request = {animals = {d2}, forage = {}, concentrate = {},
    milk = {{name = "CALFMILK", profile = milk, liters = 10000}}, scale = 0.2, realDaysPerPeriod = 30,
    dtDays = 1.25, ration = config.ration, classes = config.classes, proteinMaintenance = config.protein.maintenance}
d2.appetite = 100
local result = RLFeedRationPlanner.plan(request)
check("calf milk: excessive appetite still respects the <=2 game L/model-day ceiling",
    near(result.withdraw.CALFMILK, U.kgToLiters(d2.milkMaxKgPerDay * 1.25, 0.2, milk.density, milk.dm))
    and result.withdraw.CALFMILK <= 2 * 1.25 and near(d2.me, d2.kg * milk.me))
request.milk[1].liters = 0.25
result = RLFeedRationPlanner.plan(request)
check("calf milk: shortage gives only the nutrition actually removed, no repricing",
    near(result.withdraw.CALFMILK, 0.25)
    and near(d2.me, U.litersToKg(0.25, 0.2, milk.density, milk.dm) * milk.me)
    and result.eatenMe < result.plannedMe)

local function scenario(days, scale)
    GrowthSim.setDaysPerPeriod(days)
    config.resourceScale = scale
    local a = GrowthSim.newborn("BULL_HOLSTEIN")
    local p = FeedSim.makePen({a}, {CALFMILK = 1e6, FORAGE = 1e6}, {rearing = true})
    local months = {}
    for m = 1, 5 do
        local before = p:level("CALFMILK")
        FeedSim.months(p, 1)
        months[m] = before - p:level("CALFMILK")
    end
    return months, a
end
local base, a = scenario(1, 0.2)
local ok = true
for _, amount in ipairs(base) do if amount > 60 + 1e-6 then ok = false end end
check(string.format("calf milk: full feeding months 1-5 = %.2f, %.2f, %.2f, %.2f, %.2f L, all <= 60, none after weaning",
    base[1], base[2], base[3], base[4], base[5]), ok and base[5] == 0 and a.health == 100)
local worst = 0
for _, days in ipairs({3, 7, 28}) do
    local amounts, other = scenario(days, 0.2)
    for i = 1, 5 do worst = math.max(worst, math.abs(amounts[i] - base[i])) end
    ok = ok and other.health == 100
end
check(string.format("calf milk: 1/3/7/28-day months agree within %.3f L (<0.25 L)", worst), worst < 0.25 and ok)
local undiscounted, b = scenario(1, 1)
ok = true
for i = 1, 5 do if not near(undiscounted[i], base[i] * 5, 1e-6) then ok = false end end
check("calf milk: resourceScale changes milk use exactly 5:1, with identical weight and health",
    ok and near(a.weight, b.weight, 1e-6) and a.health == b.health)
local saving, c = scenario(1, 0.125)
ok = near(a.weight, c.weight, 1e-6) and a.health == c.health
for i = 1, 5 do ok = ok and near(saving[i], base[i] * 0.625, 1e-6) end
check("calf milk: shipped 0.125 scale consumes 62.5% of original 0.20, without slowing growth", ok)
config.resourceScale = 0.125
GrowthSim.setDaysPerPeriod(1)
