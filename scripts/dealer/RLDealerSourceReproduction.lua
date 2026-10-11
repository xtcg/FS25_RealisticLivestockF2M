-- D3-5 actual source births. This private ownership adapter is deliberately separate from
-- MODEL_ASSUMED replay history. It calls the normal reproduction sampler exactly once.
RLDealerSourceReproduction = { VERSION = 1 }
local B = RLDealerSourceReproduction
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function id(x) return type(x) == "string" and x ~= "" and x ~= "-1" and #x <= 256 end
local function copy(x)
    if type(x) ~= "table" then return x end
    local c = {}; for k,v in pairs(x) do c[k] = copy(v) end; return c
end
local function fail(reason) return nil, { reason = reason } end
local function genes(g)
    if type(g) ~= "table" then return false end
    for _, k in ipairs({ "metabolism", "quality", "productivity", "fertility", "health" }) do
        if not finite(g[k]) or g[k] < 0 then return false end
    end
    return g.metabolism > 0
end
local function selectedGenes(g)
    return { metabolism = g.metabolism, quality = g.quality, productivity = g.productivity,
        fertility = g.fertility, health = g.health }
end
function B.createOwner(sourceId, capacity, animals)
    if not id(sourceId) or not finite(capacity) or capacity < 1 or capacity ~= math.floor(capacity)
        or type(animals) ~= "table" or #animals > capacity then return fail("SOURCE_OWNER") end
    local owner = { version = B.VERSION, rlDealerSourceId = sourceId, capacity = capacity, animals = {},
        byId = {}, pendingAdds = {}, sireContexts = {}, birthJournal = {}, observedBirths = {}, quarantine = {} }
    for _, animal in ipairs(animals) do
        if type(animal) ~= "table" or not id(animal.uniqueId) or not id(animal.farmId) or owner.byId[animal.uniqueId]
            or animal.clusterSystem ~= nil or animal.rlHistoryReplay == true then return fail("SOURCE_OWNERSHIP") end
        owner.animals[#owner.animals + 1], owner.byId[animal.uniqueId] = animal, animal
    end
    local cluster = { owner = owner }
    function owner:getName() return "Source " .. self.rlDealerSourceId end
    function cluster:getAnimals() return owner.animals end
    function cluster:getPendingDelta() return #owner.pendingAdds, 0, #owner.pendingAdds end
    function cluster:addPendingAddCluster(child) owner.pendingAdds[#owner.pendingAdds + 1] = child end
    owner.clusterSystem = cluster
    owner.spec = { maxNumAnimals = capacity, clusterSystem = cluster }
    function owner.spec:getNumOfAnimals() return #owner.animals end
    -- No player farm is owned by this spec. Calling its player-stats path is a defect.
    function owner.spec:getOwnerFarmId() error("source births cannot mutate player farm stats") end
    for _, animal in ipairs(owner.animals) do animal.clusterSystem = cluster end
    return owner
end

-- Pin an already selected server-owned sire, including deceased/absent sires. There is no
-- player-placeable lookup and no sire/offspring/genetics sampling in this adapter.
function B.pinSire(owner, damId, selected)
    if type(owner) ~= "table" or owner.version ~= B.VERSION or owner.byId[damId] == nil
        or owner.sireContexts[damId] ~= nil or type(selected) ~= "table" or not id(selected.uniqueId)
        or not id(selected.farmId) or not id(selected.breed) or not genes(selected.genetics) then return fail("SOURCE_SIRE") end
    owner.sireContexts[damId] = { uniqueId = selected.uniqueId, farmId = selected.farmId,
        breed = selected.breed, subType = selected.subType, genetics = selectedGenes(selected.genetics) }
    return true
end

local function preflight(owner, dam, date, context)
    if type(context) ~= "table" or context.isServer ~= true or g_server == nil then return fail("SOURCE_SERVER_ONLY") end
    if AnimalReproduction == nil or AnimalReproduction.SOURCE_BIRTH_VERSION ~= 1
        or type(AnimalReproduction.reproduce) ~= "function" then return fail("SOURCE_BIRTH_CAPABILITY") end
    if type(owner) ~= "table" or owner.version ~= B.VERSION or not id(owner.rlDealerSourceId)
        or type(dam) ~= "table" or owner.byId[dam.uniqueId] ~= dam or dam.clusterSystem ~= owner.clusterSystem
        or dam.rlHistoryReplay == true or dam.gender ~= "female" then return fail("SOURCE_OWNERSHIP") end
    if type(date) ~= "table" or not id(date.eventId) or not finite(date.day) or date.day < 1 or date.day > 31 or date.day % 1 ~= 0
        or not finite(date.month) or date.month < 1 or date.month > 12 or date.month % 1 ~= 0
        or not finite(date.year) or date.year % 1 ~= 0 or not finite(date.cursorMonths) or date.cursorMonths < 0 then return fail("SOURCE_BIRTH_DATE") end
    local previous = owner.birthJournal[date.eventId]
    if previous ~= nil then
        if previous.damId ~= dam.uniqueId or previous.cursorMonths ~= date.cursorMonths then return fail("SOURCE_BIRTH_REQUEST") end
        if previous.stage == "COMMITTED" then return { replay = copy(previous.result) } end
        owner.quarantine[dam.uniqueId] = "SOURCE_BIRTH_UNCERTAIN"
        return fail("SOURCE_BIRTH_UNCERTAIN")
    end
    if owner.quarantine[dam.uniqueId] ~= nil then return fail("SOURCE_QUARANTINE") end
    if dam.isDead == true then return fail("SOURCE_OWNERSHIP") end
    if #owner.pendingAdds ~= 0 then return fail("SOURCE_BIRTH_PENDING") end
    if type(context.persistPrepared) ~= "function" or type(context.persistCommitted) ~= "function" then return fail("SOURCE_BIRTH_DURABILITY") end
    local g, pregnancy = dam.rlGrowth, dam.pregnancy
    if not dam.isPregnant or not finite(dam.reproduction) or dam.reproduction < 100 or type(g) ~= "table"
        or not RLGrowth.isUsable(g) or g.source ~= "birth" or g.legacyAnchor ~= nil or g.weightKg ~= dam.weight
        or not finite(g.gravidKg) or g.gravidKg < 0 or not finite(date.atAgeMonths) or math.abs(date.atAgeMonths - g.ageMonths) > 1e-8
        or type(pregnancy) ~= "table" or type(pregnancy.pregnancies) ~= "table" or #pregnancy.pregnancies < 1
        or #pregnancy.pregnancies > 3 or not finite(pregnancy.duration) or pregnancy.duration <= 0
        or type(dam.birthday) ~= "table" or not finite(dam.birthday.country) or type(dam.children) ~= "table"
        or owner.sireContexts[dam.uniqueId] == nil then return fail("SOURCE_BIRTH_STATE") end
    local sub = dam:getSubType()
    if sub == nil or sub.typeIndex ~= AnimalType.COW or not RLGrowth.coversSubType(sub) or not sub.supportsReproduction then return fail("SOURCE_BIRTH_MODEL") end
    if not genes(dam.genetics) or type(dam.deathEnabled) ~= "boolean" then return fail("SOURCE_BIRTH_RULES") end
    local selected, identities = {}, {}
    for _, child in ipairs(pregnancy.pregnancies) do
        local childSub = type(child) == "table" and type(child.getSubType) == "function" and child:getSubType() or nil
        if childSub == nil or childSub.typeIndex ~= AnimalType.COW or not RLGrowth.coversSubType(childSub)
            or not id(child.uniqueId) or not id(child.farmId) or child.farmId ~= dam.farmId or owner.byId[child.uniqueId] ~= nil
            or identities[child.uniqueId] or child.rlHistoryReplay == true or not finite(child.age) or child.age >= 0 or not genes(child.genetics)
            or (RLGrowth.getBinding(childSub).profile == "WATER_BUFFALO") ~= (RLGrowth.getBinding(sub).profile == "WATER_BUFFALO") then return fail("SOURCE_BIRTH_IDENTITY") end
        identities[child.uniqueId] = true
        selected[#selected + 1] = { uniqueId = child.uniqueId, farmId = child.farmId, subType = childSub.name, genetics = selectedGenes(child.genetics) }
    end
    if context.expectedFetalContexts ~= nil then
        if type(context.expectedFetalContexts) ~= "table" or #context.expectedFetalContexts ~= #selected then return fail("SOURCE_FETAL_CONTEXT") end
        for index, expected in ipairs(context.expectedFetalContexts) do
            local child = pregnancy.pregnancies[index]
            if type(expected) ~= "table" or expected.subType ~= selected[index].subType
                or expected.breed ~= child:getSubType().breed or expected.sex ~= child.gender then return fail("SOURCE_FETAL_CONTEXT") end
        end
    end
    if #owner.animals + #owner.pendingAdds + #selected > owner.capacity then return fail("SOURCE_BIRTH_CAPACITY") end
    if math.abs(RLGrowth.getGravidTarget(dam) - g.gravidKg) > 0.001 then return fail("SOURCE_BIRTH_GRAVID") end
    return { selected = selected, beforeBodyKg = dam.weight - g.gravidKg,
        sourceContext = { mode = "DEALER_SOURCE", isServer = true, sourceId = owner.rlDealerSourceId,
            clusterSystem = owner.clusterSystem, spec = owner.spec, sireContext = copy(owner.sireContexts[dam.uniqueId]) } }
end

-- PREPARED must durably precede RNG. An interrupted/failed birth is quarantined, never
-- retried with new draws. Persistence callbacks are supplied by the authoritative journal.
function B.check(owner,dam,date,context)
    -- Controller preflight never changes a prior journal or replays a birth.
    if type(owner)=="table" and type(owner.birthJournal)=="table" and type(date)=="table"
        and owner.birthJournal[date.eventId]~=nil then return fail("SOURCE_BIRTH_REQUEST") end
    local ok,prepared,failure=pcall(preflight,owner,dam,date,context)
    if not ok then return fail("SOURCE_BIRTH_PREPARE_ERROR") end
    if not prepared then return nil,failure end
    return true
end
function B.execute(owner, dam, date, context)
    local ok, prepared, failure = pcall(preflight, owner, dam, date, context)
    if not ok then return fail("SOURCE_BIRTH_PREPARE_ERROR") end
    if prepared == nil then return nil, failure end
    if prepared.replay ~= nil then return prepared.replay end
    local event = { version = B.VERSION, eventId = date.eventId, sourceId = owner.rlDealerSourceId,
        damId = dam.uniqueId, cursorMonths = date.cursorMonths, atAgeMonths = date.atAgeMonths,
        day = date.day, month = date.month, year = date.year, stage = "PREPARED", selected = prepared.selected,
        sireContext = copy(owner.sireContexts[dam.uniqueId]) }
    owner.birthJournal[date.eventId] = event
    local persisted, result = pcall(context.persistPrepared, copy(event))
    if not persisted or result ~= true then
        event.stage = "QUARANTINED"
        owner.quarantine[dam.uniqueId] = "SOURCE_BIRTH_PREPARE_UNCERTAIN"
        return fail("SOURCE_BIRTH_PREPARE_UNCERTAIN")
    end
    local success, count, parentDied, sold, price, reject = pcall(AnimalReproduction.reproduce,
        dam, owner.spec, date.day, date.month, date.year, false, prepared.sourceContext)
    if not success or count == nil or sold ~= 0 or price ~= 0 or #owner.pendingAdds ~= count then
        event.stage, event.failure = "QUARANTINED", reject or "SOURCE_BIRTH_INCOMPLETE"
        owner.quarantine[dam.uniqueId] = "SOURCE_BIRTH_INCOMPLETE"
        return fail("SOURCE_BIRTH_INCOMPLETE")
    end
    -- Normal reproduction owns birth weight, survival, parity and lactation. This owner
    -- clears the maternal pregnancy ledger once after those normal effects have completed.
    dam.weight, dam.rlGrowth.weightKg, dam.rlGrowth.gravidKg = prepared.beforeBodyKg, prepared.beforeBodyKg, 0
    dam.rlGrowth.lactationMonths = 0
    dam.isPregnant, dam.pregnancy, dam.impregnatedBy, dam.reproduction = false, nil, nil, 0
    if parentDied then dam.isDead = true end
    local newborns = {}
    for _, child in ipairs(owner.pendingAdds) do
        if owner.byId[child.uniqueId] ~= nil then
            event.stage = "QUARANTINED"; owner.quarantine[dam.uniqueId] = "SOURCE_BIRTH_IDENTITY"
            return fail("SOURCE_BIRTH_INCOMPLETE")
        end
        owner.animals[#owner.animals + 1], owner.byId[child.uniqueId] = child, child
        newborns[#newborns + 1] = { uniqueId = child.uniqueId, farmId = child.farmId, subType = child.subType,
            birthWeightKg = child.rlGrowth.birthWeightKg, alive = not child.isDead }
    end
    owner.pendingAdds = {}
    event.draws = prepared.sourceContext.draws or {}
    event.evidence, event.stage = "OBSERVED_SOURCE_BIRTH", "COMMITTED"
    event.result = { eventId = date.eventId, damId = dam.uniqueId, newborns = newborns, parentDied = parentDied,
        children = count, sold = 0, money = 0, evidence = event.evidence }
    owner.observedBirths[#owner.observedBirths + 1] = copy(event)
    local committed, saved = pcall(context.persistCommitted, copy(event))
    if not committed or saved ~= true then
        event.stage = "QUARANTINED"; owner.quarantine[dam.uniqueId] = "SOURCE_BIRTH_COMMIT_UNCERTAIN"
        return fail("SOURCE_BIRTH_COMMIT_UNCERTAIN")
    end
    return copy(event.result)
end

-- Bridge a committed actual birth back to the continuous physiological record. This
-- consumes an exact pending endpoint and the real source mother; it cannot manufacture
-- a newborn, calving event or history entry. The private owner retains the real children.
function B.captureObserved(previousRecord, pendingReplay, owner, dam, eventId, cursorMonths)
    if type(owner) ~= "table" or owner.version ~= B.VERSION or type(dam) ~= "table" or owner.byId[dam.uniqueId] ~= dam
        or owner.quarantine[dam.uniqueId] ~= nil then return fail("SOURCE_OBSERVED_OWNERSHIP") end
    local event = owner.birthJournal[eventId]
    local boundary = type(pendingReplay) == "table" and pendingReplay.sourceBirthBoundary or nil
    if type(event) ~= "table" or event.stage ~= "COMMITTED" or event.evidence ~= "OBSERVED_SOURCE_BIRTH"
        or event.damId ~= dam.uniqueId or type(boundary) ~= "table" or boundary.version ~= 1
        or boundary.atAgeMonths ~= event.atAgeMonths or event.cursorMonths ~= cursorMonths
        or pendingReplay.animal.rlGrowth.ageMonths ~= event.atAgeMonths
        or dam.rlGrowth.ageMonths ~= event.atAgeMonths or dam.birthCount ~= pendingReplay.animal.birthCount + 1
        or dam.health ~= pendingReplay.animal.health or dam.isPregnant or dam.pregnancy ~= nil
        or dam.rlGrowth.gravidKg ~= 0 or dam.weight ~= pendingReplay.animal.weight - pendingReplay.animal.rlGrowth.gravidKg then
        return fail("SOURCE_OBSERVED_EVENT")
    end
    local fetal
    for index, prior in ipairs(pendingReplay.history.events) do
        if prior.kind == "CONCEPTION" and prior.atMonths == boundary.conceptionMonths then fetal = pendingReplay.fetalSelections[index] end
    end
    if type(fetal) ~= "table" or #fetal ~= #event.selected then
        owner.quarantine[dam.uniqueId] = "SOURCE_FETAL_CONTEXT"; return fail("SOURCE_FETAL_CONTEXT")
    end
    for index, expected in ipairs(fetal) do
        if expected.subType ~= event.selected[index].subType then
            owner.quarantine[dam.uniqueId] = "SOURCE_FETAL_CONTEXT"; return fail("SOURCE_FETAL_CONTEXT")
        end
    end
    local observations = copy(pendingReplay.observedSourceEvents or { version = 1, events = {} })
    observations.events[#observations.events + 1] = { kind = "CALVING", evidence = "OBSERVED_SOURCE_BIRTH",
        eventId = event.eventId, atAgeMonths = event.atAgeMonths, cursorMonths = event.cursorMonths,
        parity = dam.birthCount, parentDied = event.result.parentDied, newborns = copy(event.result.newborns), draws = copy(event.draws) }
    local result = { version = pendingReplay.version, animal = dam, state = RLGrowth.copyState(dam.rlGrowth),
        history = pendingReplay.history, recipe = pendingReplay.recipe, conceptionSnapshots = pendingReplay.conceptionSnapshots,
        fetalSelections = pendingReplay.fetalSelections, ledger = pendingReplay.ledger, steps = pendingReplay.steps,
        eligibility = "UNSCREENED", observedSourceEvents = observations,
        session = { version = 1, timeMonths = event.atAgeMonths, lastBirthMonths = event.atAgeMonths,
            nextEventIndex = #pendingReplay.history.events + 1 } }
    result.state.health, result.state.birthCount = dam.health, dam.birthCount
    return RLDealerSourceState.advanceCursor(previousRecord, result, cursorMonths)
end
