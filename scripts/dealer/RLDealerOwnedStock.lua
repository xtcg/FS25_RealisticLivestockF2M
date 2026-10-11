-- Complete private source inventory. Historical sale candidates and actual born
-- children retain different physiological schemas, bound to the same real owner.
RLDealerOwnedStock = { VERSION = 1 }
local K = RLDealerOwnedStock
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function id(v) return type(v) == "string" and #v > 0 and #v <= 256 end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    return RLTradePersistence.canonical(a) == RLTradePersistence.canonical(b)
end
local function detachedState(state)
    local out = copy(state)
    if type(out) == "table" and out.lastTick == -1 then out.lastTick = nil end
    return out
end
local function keys(t, allowed)
    if type(t) ~= "table" then return false end
    for k in pairs(t) do if not allowed[k] then return false end end
    return true
end
function K.validate(data, sources, months)
    if type(data) ~= "table" or RLTradePersistence.check(data, RLDealerPersistence.LIMITS)
        or not keys(data, {version=true, owners=true, bindings=true, observedChildren=true})
        or data.version ~= K.VERSION or type(data.owners) ~= "table" or type(data.bindings) ~= "table"
        or type(data.observedChildren) ~= "table" or type(sources) ~= "table"
        or type(months) ~= "number" or months ~= months or months < 0 or months == math.huge then
        return nil, "OWNED_STOCK_SCHEMA"
    end
    local animals, seen, bound = {}, {}, {}
    for sourceId, record in pairs(sources) do
        local ok = RLDealerSourceState.validate(record)
        if not id(sourceId) or not ok or record.cursorMonths > months then return nil, "OWNED_STOCK_SOURCE" end
    end
    local function identity(a)
        local key = RLTradePersistence.canonical({farmId=a.identity.farmId, uniqueId=a.identity.uniqueId})
        if seen[key] then return nil, "OWNED_STOCK_DUPLICATE_IDENTITY" end
        seen[key] = true
        for _, child in ipairs(a.pregnancy and a.pregnancy.fetuses or {}) do
            local ok, why = identity(child); if not ok then return nil, why end
        end
        return true
    end
    local recovery = false
    for ownerId, owner in pairs(data.owners) do
        if not id(ownerId) or type(owner) ~= "table" or owner.sourceId ~= ownerId then return nil, "OWNED_STOCK_OWNER_ID" end
        local ok, why = RLDealerSourceOwnership.validate(owner)
        if not ok then return nil, "OWNED_STOCK_OWNER:" .. tostring(why) end
        animals[ownerId], bound[ownerId] = {}, {}
        for _, animal in ipairs(owner.animals) do
            ok, why = identity(animal); if not ok then return nil, why end
            animals[ownerId][animal.identity.uniqueId] = animal
        end
        if next(owner.quarantine) ~= nil then recovery = true end
        for _, event in pairs(owner.birthJournal) do
            if event.cursorMonths > months then return nil, "OWNED_STOCK_FUTURE_BIRTH" end
            if event.stage ~= "COMMITTED" then recovery = true end
        end
    end
    for sourceId, binding in pairs(data.bindings) do
        if not id(sourceId) or not keys(binding, {ownerId=true, animalId=true})
            or not id(binding.ownerId) or not id(binding.animalId) then return nil, "OWNED_STOCK_BINDING" end
        local animal = animals[binding.ownerId] and animals[binding.ownerId][binding.animalId]
        local record = sources[sourceId]
        if animal == nil or record == nil or animal.sourceRecord == nil or not equal(record, animal.sourceRecord)
            or bound[binding.ownerId][binding.animalId] then return nil, "OWNED_STOCK_SOURCE_MISMATCH" end
        bound[binding.ownerId][binding.animalId] = true
    end
    for sourceId in pairs(sources) do
        if data.bindings[sourceId] == nil then return nil, "OWNED_STOCK_SOURCE_UNBOUND" end
    end
    for ownerId, records in pairs(data.observedChildren) do
        if animals[ownerId] == nil or type(records) ~= "table" then return nil, "OWNED_STOCK_CHILD_OWNER" end
        for animalId, record in pairs(records) do
            local animal = animals[ownerId][animalId]
            local ok, why = RLDealerObservedGrowth.validate(record)
            if not ok then return nil, "OWNED_STOCK_CHILD:" .. tostring(why) end
            if animal == nil or animal.sourceRecord ~= nil or bound[ownerId][animalId]
                or record.cursorMonths > months or record.animal.uniqueId ~= animalId
                or record.animal.farmId ~= animal.identity.farmId or record.animal.subType ~= animal.subType
                or not equal(record.animal.birthday, animal.identity.birthday)
                or not equal(record.animal.rlGrowth, detachedState(animal.physiology.rlGrowth))
                or not equal(record.animal.bodyCondition, detachedState(animal.physiology.bodyCondition))
                or not equal(record.animal.genetics, animal.physiology.genetics)
                or record.animal.weight ~= animal.physiology.weight
                or record.animal.health ~= animal.physiology.health
                or not equal(record.animal.input, animal.physiology.input)
                or not equal(record.animal.output, animal.physiology.output)
                or not equal(record.birthEvent, data.owners[ownerId].birthJournal[record.birthEvent.eventId]) then
                return nil, "OWNED_STOCK_CHILD_MISMATCH"
            end
            bound[ownerId][animalId] = true
        end
    end
    for ownerId, entries in pairs(animals) do
        for animalId in pairs(entries) do
            if not bound[ownerId][animalId] then return nil, "OWNED_STOCK_ANIMAL_UNBOUND" end
        end
    end
    return {recoveryRequired=recovery}
end
function K.export(owners, bindings, recordsByOwner, observedChildren, sources, months)
    if type(owners) ~= "table" or type(recordsByOwner) ~= "table" then return nil, "OWNED_STOCK_OWNERS_REQUIRED" end
    local encoded = {}
    for ownerId, owner in pairs(owners) do
        local data, failure = RLDealerSourceOwnership.export(owner, recordsByOwner[ownerId] or {})
        if not data then return nil, failure.reason end
        encoded[ownerId] = data
    end
    local data = {version=K.VERSION, owners=encoded, bindings=bindings, observedChildren=observedChildren or {}}
    local ok, why = K.validate(data, sources, months); if not ok then return nil, why end
    return copy(data)
end
function K.restore(data, sources, months, resolver, context)
    local validated, why = K.validate(data, sources, months)
    if not validated then return nil, why end
    local owners, records = {}, {}
    for _, children in pairs(data.observedChildren) do
        for _, record in pairs(children) do
            local child, failure = RLDealerObservedGrowth.restore(record, resolver)
            if not child then return nil, "OWNED_STOCK_CHILD_RESOLVE:" .. failure.reason end
        end
    end
    for ownerId, encoded in pairs(data.owners) do
        local owner, metadata = RLDealerSourceOwnership.restore(encoded, resolver, context)
        if not owner then return nil, metadata.reason end
        owners[ownerId], records[ownerId] = owner, metadata.recordsByAnimalId
        if next(owner.quarantine) ~= nil then validated.recoveryRequired = true end
    end
    -- Objects above are new private objects, unpublished until the whole restore
    -- succeeds. Never deepcopy them: the cluster system holds owner references.
    return {sourceOwners=owners, sourceBindings=copy(data.bindings), sourceRecordsByOwner=records,
        observedChildren=copy(data.observedChildren), recoveryRequired=validated.recoveryRequired}
end
