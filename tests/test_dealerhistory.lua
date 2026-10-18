loadMod("scripts/dealer/RLDealerStockPolicy.lua")
loadMod("scripts/dealer/RLDealerHistory.lua")
local H, P = RLDealerHistory, RLDealerStockPolicy
local entry = { use = "dairy", profile = { minRecoveryMonth = 3, maxPregnancyProgress = 0.75 } }
local sub = { gender = "female", supportsReproduction = true, reproductionMinAgeMonth = 12,
    reproductionDurationMonth = 10 }
local source = { id = "UNSPECIFIED", anyUse = true, traceability = "UNKNOWN" }
local purpose = { id = "COW_YOUNG", parent = "always", pregnant = "always", minParity = 1, maxParity = 2 }
local ctx = { saleAgeMonths = 40.25, selectedBirthWeightKg = 41.5, birthContext = { damBreed = "HOLSTEIN" },
    templateId = "NORMAL_PRODUCTION", weaningMonth = 3 }
local plan = { isParent = true, parity = 2, monthsSinceLastBirth = 4, isPregnant = true,
    pregnancyMonths = 1, duration = 10 }
local history = assert(H.build(plan, entry, sub, source, purpose, ctx))
local calvings, conceptions = {}, {}
for i, event in ipairs(history.events) do
    if event.kind == "CALVING" then calvings[#calvings + 1] = event.atMonths end
    if event.kind == "CONCEPTION" then conceptions[#conceptions + 1] = { index = i, event = event } end
end
check("history: two calvings and ongoing pregnancy preserve D2 intervals at continuous sale age",
    calvings[1] == 23.25 and calvings[2] == 36.25 and #conceptions == 3
    and conceptions[1].event.atMonths == 13.25 and conceptions[3].event.atMonths == 39.25)
check("history: unknown origin is assumed, traceability separate from versioned uncalibrated template",
    history.source == "UNSPECIFIED" and history.traceability == "UNKNOWN"
    and history.evidence == "MODEL_ASSUMED" and history.template.version == 1 and not history.template.calibrated)
ctx.birthContext.damBreed, plan.parity = "CHANGED", 99
check("history: selected birth/context and plan are independent snapshots without redraw",
    history.events[1].weightKg == 41.5 and history.events[1].context.damBreed == "HOLSTEIN" and history.plan.parity == 2)
plan = history.plan
local a, b, c = H.feedingAt(history, 2.9), H.feedingAt(history, 3.5), H.feedingAt(history, 4)
check("feeding: actual continuous weaning transitions use whole transition month",
    a.stage == "PRE_WEANING" and b.stage == "WEANING" and b.weaningX == 0.5 and c.stage == "WEANED")
local afterBirth = H.feedingAt(history, 36.25)
check("feeding: calving clears pregnancy and refreshes parity and time since birth",
    afterBirth.parity == 2 and afterBirth.monthsSinceLastBirth == 0 and afterBirth.pregnancyMonths == nil)
local boundaries = H.boundaries(history)
local found = {}
for _, x in ipairs(boundaries) do found[x] = true end
check("replay: boundaries include birthdays, conception, calving, weaning and fractional sale",
    found[0] and found[3] and found[4] and found[13.25] and found[23.25] and found[40] and found[40.25])
local rules = { minAgeMonths = 12, minWeightRatio = 0.55, minDevelopmentMonths = 12,
    minReserveFraction = 0.05, maxReserveFraction = 0.11 }
local snapshots = {}
for _, v in ipairs(conceptions) do
    snapshots[v.index] = { ageMonths = v.event.atMonths, weightKg = 550, frameTargetKg = 1000,
        reserveMassKg = 44, developmentMonths = 12, gravidKg = 0 }
end
check("mating: all three historical conceptions qualify with explicit breed rules", H.validateMatings(history, snapshots, rules))
local first = snapshots[conceptions[1].index]
first.weightKg = 549
local ok, reason, index = H.validateMatings(history, snapshots, rules)
check("mating: past underweight conception rejects despite later qualifying snapshots",
    not ok and reason == "BREEDING_WEIGHT" and index == conceptions[1].index)
first.weightKg, first.developmentMonths = 550, 11.99
ok, reason = H.validateMatings(history, snapshots, rules)
check("mating: development is independent of total weight", not ok and reason == "BREEDING_DEVELOPMENT")
first.developmentMonths, first.reserveMassKg = 12, 62
ok, reason = H.validateMatings(history, snapshots, rules)
check("mating: reserve mass fraction is screened rather than reserve index", not ok and reason == "BREEDING_RESERVE")
first.reserveMassKg, first.gravidKg = 44, 1
check("mating: fetus mass cannot qualify a conception snapshot", not H.validateMatings(history, snapshots, rules))
first.gravidKg = 0
check("mating: missing thresholds and snapshots fail closed",
    not H.validateMatings(history, snapshots, nil) and not H.validateMatings(history, {}, rules))
ctx.templateId = "NORMAL_REARING"
check("history: rearing template cannot silently carry production", H.build(plan, entry, sub, source, purpose, ctx) == nil)
ctx.templateId = "NORMAL_PRODUCTION"
local original = plan.monthsSinceLastBirth
plan.monthsSinceLastBirth = 20
check("history: conception before breeding age fails", H.build(plan, entry, sub, source, purpose, ctx) == nil)
plan.monthsSinceLastBirth = original
plan.pregnancyMonths = 2
check("history: recovery conflict fails", H.build(plan, entry, sub, source, purpose, ctx) == nil)
plan.pregnancyMonths = 1
local passed, count = true, 0
for age = 23, 47 do
    for _, choose in ipairs({ function(lo) return lo end, function(_, hi) return hi end }) do
        local candidate = P.planReproduction(purpose, entry, sub, age, choose)
        if candidate ~= nil then
            ctx.saleAgeMonths = age + 0.75
            local h = H.build(candidate, entry, sub, source, purpose, ctx)
            passed, count = passed and h ~= nil, count + 1
        end
    end
end
check("history: D2 minimum/maximum reproduction draws expand across all young-cow ages", passed and count == 19)
local template = H.getTemplate("MODERATE_SLOW_REARING")
template.mode = "CHANGED"
check("feeding: templates are independent and unknown versions cannot be guessed",
    H.getTemplate("MODERATE_SLOW_REARING").mode == "MODERATE_SLOW" and H.getTemplate("unknown") == nil)
check("mating: absent snapshot collection rejects without an exception", not H.validateMatings(history, nil, rules))
local bull = { gender = "male", supportsReproduction = false, reproductionDurationMonth = 0 }
local bullPurpose = { id = "FEEDER", parent = "never", pregnant = "never" }
local bullPlan = { isParent = false, parity = 0, isPregnant = false, pregnancyMonths = 0, duration = 0 }
ctx.templateId, ctx.saleAgeMonths = "MODERATE_SLOW_REARING", 8.5
local random = math.random
math.random = function() error("history must not consume RNG") end
local male = H.build(bullPlan, entry, bull, source, bullPurpose, ctx)
math.random = random
check("history: male slow rearing builds without reproductive events or any RNG",
    male ~= nil and #male.events == 4 and H.feedingAt(male, 8).mode == "MODERATE_SLOW")
ctx.saleAgeMonths = 0 / 0
check("history: NaN sale age rejected", H.build(bullPlan, entry, bull, source, bullPurpose, ctx) == nil)
ctx.saleAgeMonths = 8.5
ctx.templateId = "NORMAL_PRODUCTION"
check("history: reproductive female plan cannot be used for a male", H.build(plan, entry, bull, source, bullPurpose, ctx) == nil)
