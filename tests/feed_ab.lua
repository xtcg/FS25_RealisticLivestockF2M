-- Cattle in the real-equivalent nutrition mode, for an exact A/B against an earlier tree
-- (tests/feed_ab.py): suckler and dairy cows with calves at foot, growing bulls on forage and
-- grain, rearing-pen calves, at 1- and 7-day months. Uses only APIs both trees have. Every
-- animal's weight, reserve, health and rumen adaptation and every pen's trough are recorded
-- once a game day.
loadMod("tests/feedsim.lua")

AB_ROWS = {}
FeedSim.setMode(true)

local function identify(animal, id)
    animal.id = id
    animal.getIdentifiers = function(self) return self.id end
    return animal
end

local function record(case, day, pen)
    for i, animal in ipairs(pen.animals) do
        local state = animal.rlGrowth or {}
        local condition = animal.bodyCondition or {}
        AB_ROWS[#AB_ROWS + 1] = { case = case .. "/d" .. day .. "/a" .. i, weight = animal.weight, health = animal.health,
            carry = animal.rlHealthCarry or 0, reserve = condition.reserve or -1, reserveKg = state.reserveMassKg or -1,
            development = state.developmentMonths or -1, adapted = state.feedAdapted or -1, shortDays = state.feedShortDays or -1,
            planLiters = animal.rlFeedPlanLiters or -1 }
    end
    local levels = {}
    for index, level in pairs(pen.spec_husbandryFood.fillLevels) do levels[#levels + 1] = index .. "=" .. string.format("%.17g", level) end
    table.sort(levels)
    AB_ROWS[#AB_ROWS + 1] = { case = case .. "/d" .. day .. "/pen", trough = table.concat(levels, ";"),
        factor = pen.spec_husbandryFood.rlFeedFactor or -1 }
end

local function run(case, days, pen, stock, daysPerPeriod)
    GrowthSim.setDaysPerPeriod(daysPerPeriod)
    local refill = FeedSim.keepStocked(stock)
    local perDay = 24
    for day = 1, days do
        for _ = 1, perDay do
            refill(pen)
            FeedSim.hour(pen)
        end
        record(case, day, pen)
        if GrowthSim.env.currentDayInPeriod == 1 then
            for _, animal in ipairs(pen.animals) do
                animal.age = animal.age + 1
                if animal.isLactating then animal.monthsSinceLastBirth = (animal.monthsSinceLastBirth or 0) + 1 end
            end
        end
    end
end

for _, days in ipairs({ 1, 7 }) do
    -- Suckler cow, twins at foot, on silage with grain.
    local cow = identify((GrowthSim.makeAnimal("COW_ANGUS", { age = 48, isParent = true, isLactating = true, monthsSinceLastBirth = 1 })), "D1")
    local c1 = identify((GrowthSim.newborn("BULL_ANGUS", { motherId = "D1" })), "C1")
    local c2 = identify((GrowthSim.newborn("COW_ANGUS", { motherId = "D1" })), "C2")
    run("suckler" .. days, 20, FeedSim.makePen({ cow, c1, c2 }), { SILAGE = 2e4, BARLEY = 4e3 }, days)

    -- Dairy cow with her calf, TMR.
    local dairy = identify((GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 40, isParent = true, isLactating = true, monthsSinceLastBirth = 0 })), "D2")
    local calf = identify((GrowthSim.newborn("BULL_HOLSTEIN", { motherId = "D2" })), "C3")
    run("dairy" .. days, 20, FeedSim.makePen({ dairy, calf }), { FORAGE = 3e4 }, days)

    -- Growing bulls and a steer on hay, maize and peas; a pen target share.
    local b1 = GrowthSim.makeAnimal("BULL_ANGUS", { age = 9 })
    local b2 = GrowthSim.makeAnimal("BULL_HOLSTEIN", { age = 12, isCastrated = true })
    local pen = FeedSim.makePen({ b1, b2 })
    RLFeed.setRation(pen, { target = "AUTO", grain = "MAIZE", share = 0.5, substitute = true })
    run("bulls" .. days, 30, pen, { DRYGRASS_WINDROW = 2e4, MAIZE = 3e3, PEA = 500 }, days)

    -- Heifers on short grass (shortage).
    local h1 = GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 14 })
    run("short" .. days, 15, FeedSim.makePen({ h1 }), { GRASS_WINDROW = 20 }, days)

    -- Rearing pen calves on calf milk and grain.
    local r1 = GrowthSim.newborn("BULL_HOLSTEIN")
    local r2 = GrowthSim.newborn("COW_HOLSTEIN")
    run("rearing" .. days, 20, FeedSim.makePen({ r1, r2 }, {}, { rearing = true }), { CALFMILK = 2e3, FORAGE = 3e3, WHEAT = 500 }, days)
end
