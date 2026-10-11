-- D3-1: a historical birth consumes the normal draw, and explicit supplied budgets
-- reach the same state as the player adapters. No history is claimed by derived states.
loadMod("tests/feedsim.lua")
local G = RLGrowth

local function sameState(a, b)
    if not near(a.weight, b.weight, 0.001) then return false end
    for _, key in ipairs({ "birthWeightKg", "frameTargetKg", "developmentMonths", "reserveMassKg",
        "speedFactor", "intakeFactor", "weightKg", "ageMonths", "gravidKg", "lactationMonths" }) do
        if not near(a.rlGrowth[key] or 0, b.rlGrowth[key] or 0, 1e-9) then return false end
    end
    return near(a.bodyCondition.reserve, b.bodyCondition.reserve, 1e-9)
        and near(a.bodyCondition.balanceEMA, b.bodyCondition.balanceEMA, 1e-9)
end

local cases, births, independent = 0, true, true
for name, profile in pairs(G.getConfig().profiles) do
    for _, sex in ipairs({ "female", "male" }) do
        local subtypeName = "D3_" .. name .. "_" .. sex
        GrowthSim.addSubType(subtypeName, name, sex, profile.knots[sex][#profile.knots[sex]][2])
        for _, gene in ipairs({ 0.25, 1, 1.75 }) do
            local child = GrowthSim.makeAnimal(subtypeName)
            child.genetics.metabolism = gene
            local oldWeight, oldState, oldTarget = child.weight, child.rlGrowth, child.targetWeight
            -- Fixed uniforms go through the production sampler, including litter/parity context.
            local drawn = G.drawBirthWeight(child:getSubType(), {
                metabolism = gene, litterSize = 2, firstBirth = true,
            }, function() return 0.5 end)
            local state = G.createBirthState(child, drawn)
            local second = G.createBirthState(child, drawn)
            births = births and state ~= nil and state.birthWeightKg == drawn and state.weightKg == drawn
                and state.ageMonths == 0 and state.source == "birth" and state.legacyAnchor == nil
                and state.anchorElapsedMonths == nil and state.lastTick == -1
                and near(state.frameTargetKg, G.getAdultReference(G.getBinding(child:getSubType()))
                    * G.getGeneFactors(gene), 1e-9)
            independent = independent and state ~= second and child.weight == oldWeight
                and child.rlGrowth == oldState and child.targetWeight == oldTarget
            state.reserveMassKg = -1
            independent = independent and second.reserveMassKg >= 0
            cases = cases + 1
        end
    end
end
check("birth factory: all 22 breeds, both sexes and gene extremes consume the selected birth (132 cases)",
    births and cases == 132)
check("birth factory: no animal mutation or shared individual state", independent)

local child = GrowthSim.makeAnimal("COW_HOLSTEIN")
local random = math.random
math.random = function() error("factory must not draw") end
local ok, state = pcall(G.createBirthState, child, 42)
math.random = random
check("birth factory: consumes no random numbers", ok and state.birthWeightKg == 42)
check("birth factory: rejects invalid weights without clamping",
    G.createBirthState(child, 0) == nil and G.createBirthState(child, -1) == nil
    and G.createBirthState(child, 0/0) == nil and G.createBirthState(child, math.huge) == nil)
local unknown = { getSubType = function() return { breed = "UNKNOWN_D3", gender = "female", typeName = "COW" } end,
    genetics = { metabolism = 1 } }
local _, reason = G.createBirthState(unknown, 42)
check("birth factory: unknown cattle cannot acquire a v2 birth from a source assumption", reason == "MODEL_COVERAGE")

-- Compare the actual hourly adapter with explicit supply over multiple ticks, including
-- differing month lengths. Feeding is fixed by the environment; no deficit backfill.
for _, days in ipairs({ 1, 3, 7 }) do
    GrowthSim.setDaysPerPeriod(days)
    local player = GrowthSim.newborn("BULL_ANGUS")
    local historical = GrowthSim.newborn("BULL_ANGUS")
    local dt, equal = 1 / (24 * days), true
    for _ = 1, 12 do
        GrowthSim.advanceHour()
        GrowthSim.refreshRequest(player)
        local liters = player:getInput("food") * GrowthSim.env.timeAdjustment * 0.65
        local tick = RLBodyCondition.getTickId()
        G.step(player, 0.65)
        local result = G.advanceBudget(historical, { intakeLiters = liters / dt, milkShare = 0.65 }, dt, tick)
        equal = equal and result ~= nil and sameState(player, historical)
    end
    check("shared legacy budget: supplied history equals player hours, " .. days .. " days/month", equal)
end

-- Real-equivalent feeding uses the SAME supplied ME and physiology, including pregnancy
-- and lactation costs. stepFeed is the actual player adapter used by RLFeed.
for _, phase in ipairs({ "growing", "pregnant", "lactating" }) do
    local fields = { age = 36, monthsSinceLastBirth = 1, isParent = phase == "lactating",
        isLactating = phase == "lactating", isPregnant = phase == "pregnant", reproduction = 60,
        pregnancy = phase == "pregnant" and { pregnancies = { {} }, duration = 10 } or nil }
    local player = GrowthSim.makeAnimal("COW_HOLSTEIN", fields)
    local historical = GrowthSim.makeAnimal("COW_HOLSTEIN", fields)
    local equal = true
    for tick = 1, 12 do
        for _, animal in ipairs({ player, historical }) do
            RLBodyCondition.applyMilk(animal, phase == "lactating" and 300 or 0, 300, 1)
        end
        local feed = { me = 100, kg = 10, cp = 1.5, proteinFactor = 0.9, target = "GROW",
            water = 0.8, dtDays = 0.25 }
        local result = G.stepFeed(player, feed, 1/120, tick)
        local direct = G.advanceBudget(historical, { feed = feed }, 1/120, tick)
        equal = equal and result ~= nil and direct ~= nil and sameState(player, historical)
            and result.supplyNU == direct.supplyNU
    end
    check("shared real-feed budget: identical fixed supply and state, " .. phase, equal)
end

local unchanged = GrowthSim.newborn("BULL_ANGUS")
local beforeWeight, beforeAge = unchanged.weight, unchanged.rlGrowth.ageMonths
local rejected = true
for _, dt in ipairs({ 0, -1, math.huge, 0/0 }) do
    local result, _, _, _, why = G.advanceBudget(unchanged, {}, dt, 99)
    rejected = rejected and result == nil and why == "HISTORY_INTERVAL"
        and unchanged.weight == beforeWeight and unchanged.rlGrowth.ageMonths == beforeAge
        and unchanged.rlGrowth.lastTick == -1
end
check("shared integrator: invalid intervals reject before changing weight or time", rejected)
