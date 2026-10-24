-- D3-2: pure, model-assumed histories. No generation RNG, physiology mutation or offspring.
-- Feeding recipes are identifiers for D3-3 calibration, not a claim of validated supply.
RLDealerHistory = { VERSION = 1, TEMPLATE_VERSION = 1 }
local H = RLDealerHistory
local TEMPLATES = {
    NORMAL_REARING = { mode = "NORMAL", production = false },
    MODERATE_SLOW_REARING = { mode = "MODERATE_SLOW", production = false },
    NORMAL_PRODUCTION = { mode = "NORMAL", production = true },
}
local finite=RLPlain.finite
local function integer(x) return finite(x) and x >= 0 and x == math.floor(x) end
local copy=RLPlain.copy

function H.getTemplate(id)
    local template = TEMPLATES[id]
    if template == nil then return nil end
    local out = copy(template)
    out.id, out.version, out.calibrated = id, H.TEMPLATE_VERSION, false
    return out
end

-- ctx: saleAgeMonths, selectedBirthWeightKg, birthContext, templateId, weaningMonth.
-- The already-selected D2 plan is expanded backwards with the minimum recovery cycle.
-- This is one feasible assumed schedule, never recorded farm evidence.
function H.build(plan, entry, subType, source, purpose, ctx)
    if type(plan) ~= "table" or type(ctx) ~= "table" or entry == nil or entry.profile == nil
        or subType == nil or source == nil or purpose == nil then return nil, "INVALID_CONTEXT" end
    local age, duration, parity = ctx.saleAgeMonths, plan.duration, plan.parity
    if not finite(age) or age < 0 or not integer(parity) or not finite(duration) or duration < 0
        or type(plan.isParent) ~= "boolean" or type(plan.isPregnant) ~= "boolean"
        or plan.isParent ~= (parity > 0) then return nil, "INVALID_PLAN" end
    if not RLDealerStockPolicy.supplies(source, entry, purpose, subType.gender) then return nil, "NO_SOURCE" end
    if (purpose.parent == "never" and plan.isParent) or (purpose.parent == "always" and not plan.isParent)
        or (purpose.pregnant == "never" and plan.isPregnant) or (purpose.pregnant == "always" and not plan.isPregnant)
        or (parity > 0 and (parity < purpose.minParity or parity > purpose.maxParity)) then
        return nil, "PURPOSE_PLAN"
    end
    local template = H.getTemplate(ctx.templateId)
    if template == nil then return nil, "UNKNOWN_TEMPLATE" end
    if (parity > 0 or plan.isPregnant) and not template.production then return nil, "TEMPLATE_PRODUCTION" end
    local birth = ctx.selectedBirthWeightKg
    local weaning = RLDealerStockPolicy.getWeaningMonth(entry, ctx)
    if not finite(birth) or birth <= 0 or type(ctx.birthContext) ~= "table"
        or not finite(weaning) or weaning < 0 then return nil, "INVALID_BIRTH_OR_WEANING" end
    local recovery = entry.profile.minRecoveryMonth
    if not finite(recovery) or recovery < 0 then return nil, "INVALID_RECOVERY" end
    if (parity > 0 or plan.isPregnant) and (subType.gender ~= "female" or not subType.supportsReproduction
        or duration <= 0 or duration ~= subType.reproductionDurationMonth) then return nil, "NO_REPRODUCTION" end
    local events = { { kind = "BIRTH", atMonths = 0, weightKg = birth, context = copy(ctx.birthContext) } }
    local function add(kind, at, number)
        events[#events + 1] = { kind = kind, atMonths = at, parity = number }
    end
    if weaning <= age then add("WEANING_START", weaning) end
    if weaning + 1 <= age then add("WEANED", weaning + 1) end
    local lastBirth
    if parity > 0 then
        if not finite(plan.monthsSinceLastBirth) or plan.monthsSinceLastBirth < 1 then return nil, "INVALID_PLAN" end
        lastBirth = age - plan.monthsSinceLastBirth
        for n = 1, parity do
            local calving = lastBirth - (parity - n) * (duration + recovery)
            local conception = calving - duration
            if conception < RLDealerStockPolicy.getBreedingAge(entry, subType) then return nil, "TIMELINE" end
            add("CONCEPTION", conception, n)
            add("CALVING", calving, n)
        end
    end
    if plan.isPregnant then
        local progress = plan.pregnancyMonths
        if not finite(progress) or progress < 1 or progress >= duration
            or not finite(entry.profile.maxPregnancyProgress)
            or progress > duration * entry.profile.maxPregnancyProgress then return nil, "INVALID_PREGNANCY" end
        local conception = age - progress
        if conception < RLDealerStockPolicy.getBreedingAge(entry, subType)
            or (lastBirth ~= nil and conception < lastBirth + recovery) then return nil, "TIMELINE" end
        add("CONCEPTION", conception, parity + 1)
    elseif plan.pregnancyMonths ~= 0 then return nil, "INVALID_PREGNANCY" end
    add("SALE", age)
    local order = { BIRTH = 1, CALVING = 2, WEANING_START = 3, WEANED = 4, CONCEPTION = 5, SALE = 6 }
    table.sort(events, function(a, b)
        if a.atMonths == b.atMonths then return order[a.kind] < order[b.kind] end
        return a.atMonths < b.atMonths
    end)
    return { version = H.VERSION, source = source.id, traceability = source.traceability,
        evidence = "MODEL_ASSUMED", template = template, saleAgeMonths = age,
        weaningMonth = weaning, weanedAtMonths = weaning + 1, durationMonths = duration,
        events = events, plan = copy(plan) }
end

-- Replay must stop at each of these boundaries, including birthdays. No multi-month shortcut.
function H.boundaries(history)
    local seen, out = {}, {}
    local function add(x) if not seen[x] then seen[x] = true; out[#out + 1] = x end end
    for month = 0, math.floor(history.saleAgeMonths) do add(month) end
    for _, event in ipairs(history.events) do add(event.atMonths) end
    table.sort(out)
    return out
end

-- Continuous-age feeding descriptor. D3-3 resolves the recipe through the shared real-feed
-- budget and RLCalfRearing curves; these labels never scale an animal's weight or genes.
function H.feedingAt(history, age)
    if not finite(age) or age < 0 or age > history.saleAgeMonths then return nil, "AGE" end
    local stage = age < history.weaningMonth and "PRE_WEANING"
        or (age < history.weanedAtMonths and "WEANING" or "WEANED")
    local parity, lastBirth, conception = 0, nil, nil
    for _, event in ipairs(history.events) do
        if event.atMonths > age then break end
        if event.kind == "CALVING" then parity, lastBirth, conception = event.parity, event.atMonths, nil end
        if event.kind == "CONCEPTION" then conception = event.atMonths end
    end
    return { mode = history.template.mode, stage = stage, weaningX = age - history.weaningMonth,
        parity = parity, monthsSinceLastBirth = lastBirth ~= nil and age - lastBirth or nil,
        pregnancyMonths = conception ~= nil and age - conception or nil }
end

-- Snapshot is taken immediately BEFORE conception by the reference replay. No migration,
-- weight repair, clamping or derivation is permitted. Rules are required breed configuration;
-- this batch deliberately supplies no universal dairy/beef/buffalo threshold defaults.
function H.validateConception(event, state, rules)
    if rules == nil or not finite(rules.minAgeMonths) or rules.minAgeMonths < 0
        or not finite(rules.minWeightRatio) or rules.minWeightRatio <= 0 or rules.minWeightRatio > 1
        or not finite(rules.minDevelopmentMonths) or rules.minDevelopmentMonths < 0
        or not finite(rules.minReserveFraction) or not finite(rules.maxReserveFraction)
        or rules.minReserveFraction < 0 or rules.maxReserveFraction >= 1
        or rules.maxReserveFraction < rules.minReserveFraction then return false, "MISSING_BREEDING_RULES" end
    if event == nil or event.kind ~= "CONCEPTION" or not finite(event.atMonths)
        or state == nil or not finite(state.ageMonths) or math.abs(state.ageMonths - event.atMonths) > 1e-9
        or not finite(state.weightKg) or state.weightKg <= 0 or not finite(state.frameTargetKg)
        or state.frameTargetKg <= 0 or not finite(state.reserveMassKg) or state.reserveMassKg < 0
        or state.reserveMassKg >= state.weightKg or not finite(state.developmentMonths)
        or state.developmentMonths < 0 or not finite(state.gravidKg) or state.gravidKg ~= 0 then
        return false, "INVALID_CONCEPTION_SNAPSHOT"
    end
    if event.atMonths < rules.minAgeMonths then return false, "BREEDING_AGE" end
    if state.weightKg < rules.minWeightRatio * state.frameTargetKg then return false, "BREEDING_WEIGHT" end
    if state.developmentMonths < rules.minDevelopmentMonths then return false, "BREEDING_DEVELOPMENT" end
    local fraction = state.reserveMassKg / state.weightKg
    if fraction < rules.minReserveFraction or fraction > rules.maxReserveFraction then return false, "BREEDING_RESERVE" end
    return true
end

-- All past conceptions must pass; a qualifying sale snapshot cannot substitute for them.
function H.validateMatings(history, snapshots, rules)
    if type(history) ~= "table" or type(history.events) ~= "table" or type(snapshots) ~= "table" then
        return false, "INVALID_HISTORY_SNAPSHOTS"
    end
    for index, event in ipairs(history.events) do
        if event.kind == "CONCEPTION" then
            local ok, reason = H.validateConception(event, snapshots[index], rules)
            if not ok then return false, reason, index end
        end
    end
    return true
end
