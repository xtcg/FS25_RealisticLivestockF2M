-- D3-4/5 strict server-owned source snapshots. No RNG, migration or physiology repair.
-- The portable record is data for persistence adapters; it is not a trusted client payload.
RLDealerSourceState = { VERSION = 1, HANDOFF_TOLERANCE_KG = 0.001 }
local S = RLDealerSourceState
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function fail(reason) return nil, { reason = reason } end
local function near(a, b) return finite(a) and finite(b) and math.abs(a - b) <= 1e-8 end
local function portable(value, seen, depth)
    local kind = type(value)
    if kind == "number" then return finite(value) end
    if kind == "string" or kind == "boolean" or kind == "nil" then return true end
    if kind ~= "table" or getmetatable(value) ~= nil or depth > 24 or seen[value] then return false end
    seen[value] = true
    for k, v in pairs(value) do
        if (type(k) ~= "string" and (not finite(k) or k < 1 or k ~= math.floor(k)))
            or not portable(v, seen, depth + 1) then seen[value] = nil; return false end
    end
    seen[value] = nil
    return true
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local fields = { "age", "subType", "subTypeIndex", "animalTypeIndex", "breed", "gender", "isIndividual",
    "isCastrated", "genetics", "health", "isParent", "birthCount", "isPregnant", "reproduction", "diseases",
    "input", "output", "weight", "targetWeight", "rlGrowth", "bodyCondition", "rlFeedGain", "rlHealthCarry",
    "monthsSinceLastBirth", "isLactating", "isDead", "sale" }
local function selection(record)
    local active
    for i, e in ipairs(record.history.events) do
        if e.atMonths <= record.ageMonths + 1e-10 then
            if e.kind == "CONCEPTION" then active = i elseif e.kind == "CALVING" then active = nil end
        end
    end
    if record.observedSourceEvents ~= nil then
        local life = RLDealerReplay.getSourceLifecycle(record.history, record.observedSourceEvents, record.ageMonths)
        if life == nil or life.conceptionMonths == nil then active = nil end
    end
    return active ~= nil and record.fetalSelections[active] or nil, active
end

function S.validate(r, legacyMilk)
    if type(r) ~= "table" or not portable(r, {}, 0) then return false, "SOURCE_DATA" end
    if r.version ~= S.VERSION or r.replayVersion ~= RLDealerReplay.VERSION then return false, "SOURCE_VERSION" end
    if not finite(r.cursorMonths) or r.cursorMonths < 0 or not finite(r.birthOriginMonths)
        or not near(r.cursorMonths - r.birthOriginMonths, r.ageMonths) then return false, "SOURCE_CURSOR" end
    if type(r.history) ~= "table" or r.history.version ~= RLDealerHistory.VERSION
        or type(r.history.template) ~= "table" or r.history.template.version ~= RLDealerHistory.TEMPLATE_VERSION
        or type(r.recipe) ~= "table" or not equal(r.recipe, RLDealerReplay.getRecipe(r.history.template.id)) then
        return false, "SOURCE_RECIPE"
    end
    if not RLDealerReplay.validateHistory(r.history) then
        return false, "SOURCE_HISTORY"
    end
    if not finite(r.steps) or r.steps < 0 or r.steps ~= math.floor(r.steps) then return false, "SOURCE_STEPS" end
    local a, h = r.animal, r.history
    if type(a) ~= "table" or type(a.rlGrowth) ~= "table" or type(h.events) ~= "table"
        or type(h.events[1]) ~= "table" or h.events[1].kind ~= "BIRTH"
        or type(h.source) ~= "string" or h.source == "" then return false, "SOURCE_STATE" end
    local g = a.rlGrowth
    if g.version ~= RLGrowth.STATE_VERSION or not RLGrowth.isUsable(g) or g.source ~= "birth"
        or g.legacyAnchor ~= nil or g.anchorElapsedMonths ~= nil or g.lastTick ~= nil
        or not finite(g.weightKg) or g.weightKg <= 0 or g.weightKg ~= a.weight
        or not near(g.ageMonths, r.ageMonths) or not finite(r.ageMonths) or r.ageMonths < 0
        or not finite(g.gravidKg or 0) or (g.gravidKg or 0) < 0
        or g.reserveMassKg >= g.weightKg - (g.gravidKg or 0)
        or g.birthWeightKg ~= h.events[1].weightKg or a.age ~= math.floor(r.ageMonths + 1e-10)
        or not finite(a.health) or a.health < 0 or a.health > 100
        or type(a.subType) ~= "string" or type(a.gender) ~= "string"
        or not finite(a.birthCount) or a.birthCount < 0 or a.birthCount ~= math.floor(a.birthCount)
        or type(a.isParent) ~= "boolean" or a.isParent ~= (a.birthCount > 0)
        or type(a.isPregnant) ~= "boolean" or not finite(a.reproduction) or a.reproduction < 0 or a.reproduction >= 100 then
        return false, "SOURCE_STATE"
    end
    -- The genes its breed has (the dealer is cattle-only; RLRearingPolicy: beef cattle have no milk
    -- gene, and must not have one).
    local use = RLRearingPolicy ~= nil and RLRearingPolicy.getUseNamed("COW", a.breed, a.subType) or nil
    for _, key in ipairs({ "metabolism", "quality", "productivity", "fertility", "health" }) do
        local required = RLRearingPolicy == nil or RLRearingPolicy.hasTraitNamed("COW", use, key)
        if type(a.genetics) ~= "table" then return false, "SOURCE_GENETICS" end
        if not required and a.genetics[key] ~= nil then
            -- Read-only compatibility check for authenticated pre-rearing checkpoints.
            -- Normal validation remains strict; migration happens on a detached copy.
            if not legacyMilk or not finite(a.genetics[key]) or a.genetics[key] < 0.25 or a.genetics[key] > 1.75 then
                return false, "SOURCE_GENETICS"
            end
        end
        if required and (not finite(a.genetics[key]) or a.genetics[key] < 0.25 or a.genetics[key] > 1.75) then
            return false, "SOURCE_GENETICS"
        end
    end
    if type(r.fetalSelections) ~= "table" or type(r.conceptionSnapshots) ~= "table" or type(r.ledger) ~= "table"
        or not finite(r.ledger.maxEnergyError) or r.ledger.maxEnergyError < 0 or r.ledger.maxEnergyError > 1e-6
        or not finite(r.ledger.maxMassError) or r.ledger.maxMassError < 0 or r.ledger.maxMassError > 1e-6
        or not finite(r.ledger.feedMe) or r.ledger.feedMe < 0 or not finite(r.ledger.milkLiters) or r.ledger.milkLiters < 0 then
        return false, "SOURCE_CONTEXT"
    end
    local last, births, active, lastBirth, nextEvent = -1, 0, nil, nil, 1
    for index, event in ipairs(h.events) do
        if type(event) ~= "table" or not finite(event.atMonths) or event.atMonths < last then return false, "SOURCE_HISTORY" end
        last = event.atMonths
        if event.atMonths <= r.ageMonths + 1e-10 then
            nextEvent = index + 1
            if event.kind == "CONCEPTION" then
                local snap, fetuses = r.conceptionSnapshots[index], r.fetalSelections[index]
                if active ~= nil or type(snap) ~= "table" or not near(snap.ageMonths, event.atMonths)
                    or not RLGrowth.isUsable(snap) or (snap.gravidKg or 0) ~= 0 or type(fetuses) ~= "table"
                    or #fetuses < 1 or #fetuses > 3 then return false, "SOURCE_MATING" end
                for _, fetal in ipairs(fetuses) do
                    if type(fetal) ~= "table" or type(fetal.subType) ~= "string" or type(fetal.sex) ~= "string" then return false, "SOURCE_FETAL" end
                end
                active = event.atMonths
            elseif event.kind == "CALVING" then
                if active == nil then return false, "SOURCE_HISTORY" end
                active, births, lastBirth = nil, births + 1, event.atMonths
            end
        end
    end
    local life, lifeReason = RLDealerReplay.getSourceLifecycle(h, r.observedSourceEvents, r.ageMonths)
    if life == nil then return false, lifeReason end
    births, active, lastBirth, nextEvent = life.birthCount, life.conceptionMonths, life.lastBirthMonths, life.nextEventIndex
    if (a.isDead == true) ~= (life.isDead == true) then return false, "SOURCE_MORTALITY" end
    if r.observedSourceEvents ~= nil then
        for _, event in ipairs(r.observedSourceEvents.events) do
            if not near(event.cursorMonths - event.atAgeMonths, r.birthOriginMonths) then return false, "SOURCE_CURSOR" end
        end
    end
    if births ~= a.birthCount or a.isPregnant ~= (active ~= nil)
        or (active ~= nil and (not finite(h.durationMonths) or h.durationMonths <= 0
            or not near(a.reproduction, 100 * (r.ageMonths - active) / h.durationMonths)))
        or (active == nil and ((g.gravidKg or 0) ~= 0 or a.reproduction ~= 0)) then return false, "SOURCE_PREGNANCY" end
    if r.session ~= nil and (type(r.session) ~= "table" or r.session.version ~= 1
        or not near(r.session.timeMonths, r.ageMonths) or r.session.nextEventIndex ~= nextEvent
        or r.session.lastBirthMonths ~= lastBirth or r.session.conceptionMonths ~= active) then
        return false, "SOURCE_SESSION"
    end
    if a.bodyCondition ~= nil and (type(a.bodyCondition) ~= "table" or a.bodyCondition.lastTick ~= nil
        or a.bodyCondition.version ~= RLBodyCondition.STATE_VERSION or not finite(a.bodyCondition.reserve)
        or not finite(a.bodyCondition.capacityKg) or a.bodyCondition.capacityKg <= 0
        or not near(a.bodyCondition.reserve * a.bodyCondition.capacityKg, g.reserveMassKg)) then
        return false, "SOURCE_CONDITION"
    end
    return true
end

function S.capture(result, cursorMonths)
    if type(result) ~= "table" or type(result.animal) ~= "table" then return fail("SOURCE_RESULT") end
    local animal = {}
    for _, key in ipairs(fields) do animal[key] = result.animal[key] end
    local r = { version = S.VERSION, replayVersion = result.version, cursorMonths = cursorMonths,
        ageMonths = animal.rlGrowth ~= nil and animal.rlGrowth.ageMonths or nil,
        history = result.history, recipe = result.recipe, animal = animal,
        conceptionSnapshots = result.conceptionSnapshots, fetalSelections = result.fetalSelections,
        ledger = result.ledger, steps = result.steps, eligibility = result.eligibility, session = result.session,
        observedSourceEvents = result.observedSourceEvents }
    if finite(cursorMonths) and finite(r.ageMonths) then r.birthOriginMonths = cursorMonths - r.ageMonths end
    local ok, why = S.validate(r)
    if not ok then return fail(why) end
    return copy(r)
end

local function resolve(r, resolver)
    if type(resolver) ~= "function" then return nil, "SOURCE_RESOLVER" end
    local sub = resolver(r.animal.subType)
    if type(sub) ~= "table" or sub.name ~= r.animal.subType or sub.gender ~= r.animal.gender
        or sub.breed ~= r.animal.breed or sub.typeIndex ~= r.animal.animalTypeIndex
        or AnimalType == nil or sub.typeIndex ~= AnimalType.COW or not RLGrowth.coversSubType(sub) then
        return nil, "SOURCE_SUBTYPE"
    end
    return sub
end
function S.restore(record, resolver)
    local ok, why = S.validate(record)
    if not ok then return fail(why) end
    local sub; sub, why = resolve(record, resolver)
    if sub == nil then return fail(why) end
    local r, a = copy(record), copy(record.animal)
    if sub.subTypeIndex ~= nil then a.subTypeIndex = sub.subTypeIndex end
    a.animalTypeIndex = sub.typeIndex
    local size = RLGrowth.getGeneFactors(a.genetics.metabolism, a)
    local binding = RLGrowth.getBinding(sub)
    local curve = RLGrowth.buildCurve(binding, a.rlGrowth.frameTargetKg, a.rlGrowth.birthWeightKg)
    if not near(a.rlGrowth.frameTargetKg, RLGrowth.getAdultReference(binding) * size)
        or a.rlGrowth.developmentMonths > curve.endMonth then return fail("SOURCE_GENETIC_FRAME") end
    a.getSubType, a.rlHistoryReplay = function() return sub end, true
    setmetatable(a, { __index = Animal })
    local fetal = selection(r)
    if fetal ~= nil then
        local children = {}
        for _, context in ipairs(fetal) do
            local child = resolver(context.subType)
            if child == nil or child.name ~= context.subType or child.breed ~= context.breed or child.gender ~= context.sex
                or child.typeIndex ~= AnimalType.COW or not RLGrowth.coversSubType(child)
                or (RLGrowth.getBinding(child).profile == "WATER_BUFFALO") ~= (RLGrowth.getBinding(sub).profile == "WATER_BUFFALO") then
                return fail("SOURCE_FETAL")
            end
            local selected = child
            children[#children + 1] = { getSubType = function() return selected end }
        end
        a.pregnancy = { pregnancies = children, duration = r.history.durationMonths }
    end
    if math.abs(RLGrowth.getGravidTarget(a) - (a.rlGrowth.gravidKg or 0)) > S.HANDOFF_TOLERANCE_KG then return fail("SOURCE_GRAVID") end
    local state = copy(a.rlGrowth)
    state.health, state.birthCount = a.health, a.birthCount
    return { version = r.replayVersion, animal = a, state = state, history = r.history,
        recipe = r.recipe, conceptionSnapshots = r.conceptionSnapshots, fetalSelections = r.fetalSelections,
        ledger = r.ledger, steps = r.steps, eligibility = r.eligibility, session = r.session,
        observedSourceEvents = r.observedSourceEvents }
end

-- Accept only an already advanced result. This module never replays from birth to move a cursor.
function S.advanceCursor(record, result, cursorMonths)
    local ok, why = S.validate(record)
    if not ok then return fail(why) end
    if not finite(cursorMonths) or cursorMonths < record.cursorMonths then return fail("SOURCE_CURSOR_REWIND") end
    local nextRecord, failure = S.capture(result, cursorMonths)
    if nextRecord == nil then return nil, failure end
    if not near(nextRecord.birthOriginMonths, record.birthOriginMonths) then return fail("SOURCE_CURSOR_DELTA") end
    for _, key in ipairs({ "history", "recipe" }) do
        if not equal(nextRecord[key], record[key]) then return fail("SOURCE_PROVENANCE") end
    end
    if not equal(nextRecord.animal.genetics, record.animal.genetics)
        or nextRecord.animal.subType ~= record.animal.subType
        or nextRecord.animal.rlGrowth.birthWeightKg ~= record.animal.rlGrowth.birthWeightKg
        or nextRecord.animal.rlGrowth.frameTargetKg ~= record.animal.rlGrowth.frameTargetKg then return fail("SOURCE_PROVENANCE") end
    for _, key in ipairs({ "conceptionSnapshots", "fetalSelections" }) do
        for index, value in pairs(record[key]) do
            if not equal(nextRecord[key][index], value) then return fail("SOURCE_PROVENANCE") end
        end
    end
    if record.observedSourceEvents ~= nil then
        if nextRecord.observedSourceEvents == nil then return fail("SOURCE_PROVENANCE") end
        for index, event in ipairs(record.observedSourceEvents.events) do
            if not equal(nextRecord.observedSourceEvents.events[index], event) then return fail("SOURCE_PROVENANCE") end
        end
    end
    if cursorMonths == record.cursorMonths and not equal(nextRecord, record) then return fail("SOURCE_CURSOR_REPLAY") end
    return nextRecord
end

-- Returns fields for a transaction's prepared transfer; never mutates source or destination.
-- tick is supplied ONLY if the authoritative owner knows that live hour is already complete.
-- Historical milk does not represent paid live milk: bodyCondition.lastTick stays -1.
function S.prepareHandoff(record, target, completedLiveTick)
    local ok, why = S.validate(record)
    if not ok then return fail(why) end
    if record.animal.isDead == true then return fail("HANDOFF_SOURCE_DEAD") end
    if type(target) ~= "table" or type(target.getSubType) ~= "function" then return fail("HANDOFF_TARGET") end
    if completedLiveTick ~= nil and (not finite(completedLiveTick) or completedLiveTick < 0
        or completedLiveTick ~= math.floor(completedLiveTick)) then return fail("HANDOFF_TICK") end
    local sub = target:getSubType()
    if sub == nil or sub.name ~= record.animal.subType or sub.gender ~= record.animal.gender or sub.breed ~= record.animal.breed then
        return fail("HANDOFF_SUBTYPE")
    end
    local payload = copy(record.animal)
    local fetal = selection(record)
    if fetal ~= nil then
        local pregnancy = target.pregnancy
        if type(pregnancy) ~= "table" or pregnancy.duration ~= record.history.durationMonths
            or type(pregnancy.pregnancies) ~= "table" or #pregnancy.pregnancies ~= #fetal then return fail("HANDOFF_OFFSPRING") end
        local identities = {}
        for i, context in ipairs(fetal) do
            local child = pregnancy.pregnancies[i]
            local childSub = child ~= nil and type(child.getSubType) == "function" and child:getSubType() or nil
            if childSub == nil or childSub.name ~= context.subType or childSub.breed ~= context.breed or childSub.gender ~= context.sex
                or (type(child.uniqueId) ~= "string" and not finite(child.uniqueId))
                or child.uniqueId == "" or identities[child.uniqueId] then return fail("HANDOFF_OFFSPRING") end
            identities[child.uniqueId] = true
        end
        -- Real offspring remain owned by the transaction; physiological proxies never transfer.
    elseif target.pregnancy ~= nil then return fail("HANDOFF_OFFSPRING") end
    payload.rlGrowth.lastTick = completedLiveTick or -1
    if payload.bodyCondition ~= nil then payload.bodyCondition.lastTick = -1 end
    payload.rlHistoryReplay, payload.rlGrowthCurve, payload.rlGrowthPeek = nil, nil, nil
    if math.abs(payload.weight - record.animal.weight) > S.HANDOFF_TOLERANCE_KG then return fail("HANDOFF_WEIGHT") end
    return payload
end
