-- Physical-profile probes. Missing pack/map subtypes borrow base engine food/milk curves;
-- these probes verify the model, not installed-map purchase compatibility.
loadMod("tests/feedsim.lua")
loadMod("scripts/dealer/RLDealerStockPolicy.lua")
loadMod("scripts/dealer/RLDealerHistory.lua")
loadMod("scripts/dealer/RLDealerReplay.lua")
DealerReplaySim = {}
local S = DealerReplaySim
function S.seed(profile, sex, gene)
    local name = "DEALER_PROBE_" .. profile .. "_" .. sex
    local _, sub = Economics.find(name)
    if sub == nil then
        local baseName = sex == "female" and "COW_HOLSTEIN" or "BULL_ANGUS"
        local _, base = Economics.find(baseName)
        _, sub = GrowthSim.addSubType(name, profile, sex, base.targetWeight, baseName)
        sub.reproductionDurationMonth, sub.supportsReproduction = 10, sex == "female"
        sub.output = { milk = { get = function(_, age) return Economics.curve(sub.milk, age) end } }
        sub.healthIncreaseHour, sub.healthDecreaseHour = 10, 25
    end
    -- The genes the probe's breed has: a beef breed has no milk gene (RLRearingPolicy).
    local genetics = { metabolism = gene or 1, quality = 1, productivity = 1, fertility = 1, health = 1 }
    RLRearingPolicy.normalizeGenetics(sub, genetics)
    return { subType = sub, geneticsScreened = true, genetics = genetics }
end
function S.history(seed, age, template, reproduction)
    local binding = RLGrowth.getBinding(seed.subType)
    local _, _, _, gene = RLGrowth.getGeneFactors(seed.genetics.metabolism)
    local weight = RLGrowth.getBirthMean(binding) * gene
    local weaning = RLCalfRearing.getWeaningMonthForSubType(seed.subType)
    local events = { { kind = "BIRTH", atMonths = 0, weightKg = weight, context = { damBreed = seed.subType.breed } } }
    if age >= weaning then events[#events + 1] = { kind = "WEANING_START", atMonths = weaning } end
    if age >= weaning + 1 then events[#events + 1] = { kind = "WEANED", atMonths = weaning + 1 } end
    for _, e in ipairs(reproduction or {}) do events[#events + 1] = e end
    events[#events + 1] = { kind = "SALE", atMonths = age }
    table.sort(events, function(a, b) return a.atMonths < b.atMonths end)
    return { version = 1, template = RLDealerHistory.getTemplate(template or "NORMAL_REARING"),
        saleAgeMonths = age, weaningMonth = weaning, weanedAtMonths = weaning + 1,
        durationMonths = 10, events = events, source = "UNSPECIFIED", evidence = "MODEL_ASSUMED" }
end
