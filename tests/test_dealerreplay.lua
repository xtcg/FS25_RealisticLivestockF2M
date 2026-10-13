loadMod("tests/dealerreplaysim.lua")
local R, S, G = RLDealerReplay, DealerReplaySim, RLGrowth
local seed = S.seed("HOLSTEIN", "female", 1)
local h = S.history(seed, 8.5)
local random = math.random
math.random = function() error("replay may not consume RNG") end
local result = assert(R.run(seed, h, { daysPerMonth = 1 }))
math.random = random
check("replay: birth-origin state reaches exact fractional sale without live tick or migration",
    near(result.state.ageMonths, 8.5, 1e-10) and result.state.source == "birth"
    and result.state.lastTick == nil and result.state.legacyAnchor == nil and result.steps == 204)
check("replay: actual feed produces healthy reachable growth with conserved mass and energy",
    result.state.health == 100 and result.state.developmentMonths > 8.4 and R.screen(result)
    and result.ledger.maxEnergyError < 1e-8 and result.ledger.maxMassError < 1e-8 and result.ledger.feedMe > 0)
check("replay: input genes, history and game clock are untouched",
    seed.genetics.metabolism == 1 and seed.rlGrowth == nil and h.events[1].weightKg == result.state.birthWeightKg
    and GrowthSim.env.currentHour == 0 and GrowthSim.env.currentMonotonicDay == 1)
local seven = assert(R.run(seed, h, { daysPerMonth = 7 }))
check("reference: 1/7-day month results remain close without changing physical feed values",
    math.abs(result.state.weightKg - seven.state.weightKg) < 0.1 and math.abs(result.state.reserveMassKg - seven.state.reserveMassKg) < 0.1)
local schedule = { 1, 3, 7, 1, 7, 3, 1, 3, 7 }
local changing = assert(R.run(seed, h, { daysPerMonth = schedule }))
check("clock: changing month lengths covers each actual interval and fractional last month",
    changing.steps == 24 * (1 + 3 + 7 + 1 + 7 + 3 + 1 + 3) + 84 and near(changing.state.ageMonths, 8.5, 1e-10))
local newborn = assert(R.run(seed, S.history(seed, 2), { daysPerMonth = 1 }))
local ok, reason = R.screen(newborn)
check("screen: uncalibrated calf reserve closes milk-fed products", not ok and reason == "CALF_RESERVE_UNCALIBRATED")
local entry = { breedingWeightRatio = 0.55, profile = { minRecoveryMonth = 3 } }
local production = S.history(seed, 30.25, "NORMAL_PRODUCTION", {
    { kind = "CONCEPTION", atMonths = 17.125, parity = 1 },
    { kind = "CALVING", atMonths = 27.125, parity = 1 },
})
local productionOptions = { daysPerMonth = 1, entry = entry, pregnancySubTypes = { [4] = { seed.subType } } }
local cow = assert(R.run(seed, production, productionOptions))
check("production: real pregnancy/calving and paid lactation preserve birth state and health",
    cow.state.birthCount == 1 and cow.state.gravidKg == 0 and near(cow.state.lactationMonths, 3.125, 1e-9)
    and cow.ledger.milkLiters > 0 and cow.state.health == 100 and cow.conceptionSnapshots[4].gravidKg == 0)
local rules = R.getBreedingRules(cow.animal, entry)
check("breeding: development gate uses individual curve adult rather than legacy price target",
    near(rules.minDevelopmentMonths, G.getCurve(cow.animal):inverse(cow.state.frameTargetKg * 0.55), 1e-10)
    and R.getBreedingRules(cow.animal, { profile = entry.profile }) == nil)
local badOptions = { daysPerMonth = 1, entry = entry, breedingRules = table.clone(rules), pregnancySubTypes = productionOptions.pregnancySubTypes }
badOptions.breedingRules.minDevelopmentMonths = 50
local bad, failure = R.run(seed, production, badOptions)
check("history: failed past mating rejects before calving or sale", bad == nil and failure.reason == "BREEDING_DEVELOPMENT" and failure.atMonths == 17.125)
bad, failure = R.run(seed, production, { daysPerMonth = 1, entry = entry })
check("history: pregnancy requires selected physical fetal context without allocating offspring", bad == nil and failure.reason == "FETAL_CONTEXT")
local unScreened = table.clone(seed)
unScreened.geneticsScreened = false
bad, failure = R.run(unScreened, h, { daysPerMonth = 1 })
check("screen: genetics screening is required before expensive replay", bad == nil and failure.reason == "GENETICS_NOT_SCREENED")
unScreened.geneticsScreened, unScreened.diseases = true, { { isCarrier = false } }
bad, failure = R.run(unScreened, h, { daysPerMonth = 1 })
check("screen: affected genetic disease rejects before physiology", bad == nil and failure.reason == "GENETIC_DISEASE")
local replayAnimal = result.animal
local before = replayAnimal.weight
replayAnimal.weight = before + 1
local budget, why = G.advanceHistoricalBudget(replayAnimal, { intakeLiters = 0 }, 1 / 24)
check("strict budget: outside weight edits reject without migration or reserve repair",
    budget == nil and why == "HISTORY_STATE" and replayAnimal.weight == before + 1 and replayAnimal.rlGrowth.weightKg == before)
replayAnimal.weight = before
budget, why = G.advanceHistoricalBudget(replayAnimal, {}, 0 / 0)
check("strict budget: invalid interval rejects before advancing age", budget == nil and why == "HISTORY_INTERVAL" and replayAnimal.rlGrowth.ageMonths == 8.5)
local originalPlan = R.planFeed
R.planFeed = function() return { me = 0 / 0, kg = 1, cp = 0.2, proteinFactor = 1 } end
bad, failure = R.run(seed, h, { daysPerMonth = 1 })
R.planFeed = originalPlan
check("replay: nonfinite supply rejects without changing caller state", bad == nil and failure.reason == "FEED_RESULT" and seed.rlGrowth == nil)
local policy = RLDealerStockPolicy
local resolved = policy.getEntry(policy.getConfig(), seed.subType, "COW")
local purpose = policy.findPurpose(resolved, "female", "HEIFER_READY")
local readyHistory = S.history(seed, 20.5)
readyHistory.source = "DAIRY_HERD"
local candidate, refusal = R.evaluate(seed, readyHistory, resolved, purpose,
    { maxBuyAge = 72, weaningMonth = 3, union = { { 0, 72 } }, lactates = true }, { daysPerMonth = 1 })
check("candidate: D2 purpose/source gates combine with v2 physiological readiness",
    candidate ~= nil and candidate.eligibility == "VERIFIED_CANDIDATE" and candidate.state.lastTick == nil)
local originalRatio = resolved.breedingWeightRatio
resolved.breedingWeightRatio = nil
candidate, refusal = R.evaluate(seed, readyHistory, resolved, purpose,
    { maxBuyAge = 72, weaningMonth = 3, union = { { 0, 72 } }, lactates = true }, { daysPerMonth = 1 })
resolved.breedingWeightRatio = originalRatio
check("candidate: missing breed readiness rule cannot fall back to dairy threshold",
    candidate == nil and refusal.reason == "MISSING_BREEDING_RULES")
local invalid = table.clone(h)
invalid.events = { h.events[1], "corrupt", h.events[#h.events] }
bad, failure = R.run(seed, invalid, { daysPerMonth = 1 })
check("history: corrupt event data rejects without physiology", bad == nil and failure.reason == "INVALID_HISTORY")
bad, failure = R.run(seed, h, { daysPerMonth = { 1 } })
check("clock: absent month length rejects instead of reusing the current game's month", bad == nil and failure.reason == "MONTH_LENGTH")
local buffalo = S.seed("WATER_BUFFALO", "female", 1)
bad, failure = R.run(seed, production, { daysPerMonth = 1, entry = entry, pregnancySubTypes = { [4] = { buffalo.subType } } })
check("pregnancy: cattle/buffalo crossing is not a supported fetal context", bad == nil and failure.reason == "FETAL_CONTEXT")
budget, why = G.advanceHistoricalBudget(replayAnimal, {}, 0.75)
check("strict clock: caller must split at birthdays", budget == nil and why == "HISTORY_BOUNDARY" and replayAnimal.rlGrowth.ageMonths == 8.5)
local missing = table.clone(seed)
missing.subType = table.clone(seed.subType)
missing.subType.healthDecreaseHour = nil
bad, failure = R.run(missing, h, { daysPerMonth = 1 })
check("coverage: missing clinical-health rules cannot silently suppress shortages", bad == nil and failure.reason == "HEALTH_RULES")
missing.subType.healthDecreaseHour, missing.subType.output = 25, nil
bad, failure = R.run(missing, production, productionOptions)
check("coverage: postpartum history cannot silently lose its milk budget", bad == nil and failure.reason == "MILK_RULES")
local moderate = true
for _, profile in ipairs({ "HOLSTEIN", "SIMMENTAL_PACK", "HIGHLAND", "WATER_BUFFALO" }) do
    local probe = S.seed(profile, "male", 1.75)
    local normal = assert(R.run(probe, S.history(probe, 12.5), { daysPerMonth = 1 }))
    local slow = assert(R.run(probe, S.history(probe, 12.5, "MODERATE_SLOW_REARING"), { daysPerMonth = 1 }))
    local lag = normal.state.developmentMonths - slow.state.developmentMonths
    moderate = moderate and lag >= -1e-8 and lag < 0.5 and slow.state.health == 100 and R.screen(slow)
end
check("recipe: modest physical intake offer avoids the severe lag of the rejected hay recipe", moderate)
invalid = table.clone(production)
invalid.template = RLDealerHistory.getTemplate("NORMAL_REARING")
bad, failure = R.run(seed, invalid, productionOptions)
check("history: edited rearing-only template cannot silently claim a production history", bad == nil and failure.reason == "INVALID_HISTORY")
local profiles, failures, count = {}, {}, 0
-- Cattle profiles only: the file also holds other types' curves (SHEEP:<breed> since sheep S4), which the dealer does not use.
for name, profile in pairs(G.getConfig().profiles) do
    if profile.typeName == nil or profile.typeName == "COW" then profiles[#profiles + 1] = name end
end
table.sort(profiles)
for _, profile in ipairs(profiles) do
    for _, sex in ipairs({ "female", "male" }) do
        for _, gene in ipairs({ 0.25, 1, 1.75 }) do
            local probe = S.seed(profile, sex, gene)
            local r, e = R.run(probe, S.history(probe, 6.25), { daysPerMonth = 1 })
            count = count + 1
            if r == nil or r.ledger.maxEnergyError > 1e-8 or r.ledger.maxMassError > 1e-8
                or r.state.health < 90 or r.state.source ~= "birth" then failures[#failures + 1] = profile .. sex .. gene .. (e ~= nil and e.reason or "") end
        end
    end
end
check("reference: all 22 physical breeds x both sexes x gene extremes replay without repair (" .. table.concat(failures, ",") .. ")",
    count == 132 and #failures == 0)
