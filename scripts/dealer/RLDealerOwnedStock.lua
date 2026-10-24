-- Complete private source inventory. Historical sale candidates and actual born
-- children retain different physiological schemas, bound to the same real owner.
RLDealerOwnedStock = { VERSION = 1 }
local K = RLDealerOwnedStock
local copy=RLPlain.copy
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
local physiologyFields={"age","health","monthsSinceLastBirth","birthCount","gender","breed","isIndividual",
    "isParent","isPregnant","isLactating","isCastrated","reproduction","weight","targetWeight","genetics",
    "rlGrowth","bodyCondition","rlFeedGain","rlHealthCarry","input","output"}
local function samePhysiology(record,animal)
    for _,key in ipairs(physiologyFields) do
        local actual=animal.physiology[key]
        if key=="rlGrowth" or key=="bodyCondition" then actual=detachedState(actual) end
        if not equal(record.animal[key],actual) then return false end
    end
    return true
end
local function keys(t, allowed)
    if type(t) ~= "table" then return false end
    for k in pairs(t) do if not allowed[k] then return false end end
    return true
end
function K.validate(data, sources, months, legacyMilk)
    if type(data) ~= "table" or RLTradePersistence.check(data, RLDealerPersistence.LIMITS)
        or not keys(data, {version=true, owners=true, bindings=true, observedChildren=true, retiredSources=true})
        or data.version ~= K.VERSION or type(data.owners) ~= "table" or type(data.bindings) ~= "table"
        or type(data.observedChildren) ~= "table" or (data.retiredSources ~= nil and type(data.retiredSources) ~= "table") or type(sources) ~= "table"
        or type(months) ~= "number" or months ~= months or months < 0 or months == math.huge then
        return nil, "OWNED_STOCK_SCHEMA"
    end
    local animals, seen, bound = {}, {}, {}
    local recovery = false
    for sourceId, record in pairs(sources) do
        local ok = RLDealerSourceState.validate(record, legacyMilk)
        if not id(sourceId) or not ok or record.cursorMonths > months then return nil, "OWNED_STOCK_SOURCE" end
        if record.cursorMonths < months then recovery=true end
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
    for ownerId, owner in pairs(data.owners) do
        if not id(ownerId) or type(owner) ~= "table" or owner.sourceId ~= ownerId then return nil, "OWNED_STOCK_OWNER_ID" end
        local ok, why = RLDealerSourceOwnership.validate(owner, legacyMilk)
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
        local pending=false
        for _,event in pairs(data.owners[binding.ownerId].birthJournal) do
            if event.stage~="COMMITTED" and event.damId==binding.animalId
                and event.atAgeMonths==animal.physiology.rlGrowth.ageMonths then pending=true end
        end
        if not pending and not samePhysiology(record,animal) then return nil,"OWNED_STOCK_SOURCE_PHYSIOLOGY" end
        bound[binding.ownerId][binding.animalId] = true
    end
    for sourceId in pairs(sources) do
        if data.bindings[sourceId] == nil then return nil, "OWNED_STOCK_SOURCE_UNBOUND" end
    end
    -- A real maternal death leaves an owned body and immutable source provenance.
    -- It must no longer participate in active feeding or sale bindings.
    for sourceId, retired in pairs(data.retiredSources or {}) do
        if not id(sourceId) or not keys(retired,{ownerId=true,animalId=true,record=true,reason=true,eventId=true})
            or not id(retired.ownerId) or not id(retired.animalId) or not id(retired.eventId)
            or retired.reason ~= "SOURCE_MATERNAL_MORTALITY" or sources[sourceId] ~= nil or data.bindings[sourceId] ~= nil then
            return nil,"OWNED_STOCK_RETIRED_SCHEMA"
        end
        local animal=animals[retired.ownerId] and animals[retired.ownerId][retired.animalId]
        local record=retired.record
        local valid=RLDealerSourceState.validate(record, legacyMilk)
        if not valid or record.cursorMonths>months or record.animal.isDead~=true or animal==nil
            or animal.identity.isDead~=true or not equal(record,animal.sourceRecord)
            or not samePhysiology(record,animal) or bound[retired.ownerId][retired.animalId] then
            return nil,"OWNED_STOCK_RETIRED_MISMATCH"
        end
        local event=data.owners[retired.ownerId].birthJournal[retired.eventId]
        local observation
        for _,entry in ipairs(record.observedSourceEvents and record.observedSourceEvents.events or {}) do
            if entry.eventId==retired.eventId then observation=entry end
        end
        if not event or event.stage~="COMMITTED" or event.evidence~="OBSERVED_SOURCE_BIRTH"
            or event.damId~=retired.animalId or event.result.parentDied~=true or not observation
            or observation.parentDied~=true or observation.atAgeMonths~=event.atAgeMonths
            or observation.cursorMonths~=event.cursorMonths or record.cursorMonths~=event.cursorMonths
            or not equal(observation.draws,event.draws) or not equal(observation.newborns,event.result.newborns) then
            return nil,"OWNED_STOCK_RETIRED_PROOF"
        end
        bound[retired.ownerId][retired.animalId]=true
    end
    for ownerId, records in pairs(data.observedChildren) do
        if animals[ownerId] == nil or type(records) ~= "table" then return nil, "OWNED_STOCK_CHILD_OWNER" end
        for animalId, record in pairs(records) do
            local animal = animals[ownerId][animalId]
            local ok, why = RLDealerObservedGrowth.validate(record, legacyMilk)
            if not ok then return nil, "OWNED_STOCK_CHILD:" .. tostring(why) end
            if record.cursorMonths < months then recovery=true end
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
                or not equal(record.animal.output, animal.physiology.output) or not samePhysiology(record,animal)
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
function K.export(owners, bindings, recordsByOwner, observedChildren, sources, months, retiredSources)
    if type(owners) ~= "table" or type(recordsByOwner) ~= "table" then return nil, "OWNED_STOCK_OWNERS_REQUIRED" end
    if retiredSources~=nil and type(retiredSources)~="table" then return nil,"OWNED_STOCK_RETIRED_SCHEMA" end
    local encoded = {}
    for ownerId, owner in pairs(owners) do
        local data, failure = RLDealerSourceOwnership.export(owner, recordsByOwner[ownerId] or {})
        if not data then return nil, failure.reason end
        encoded[ownerId] = data
    end
    local data = {version=K.VERSION, owners=encoded, bindings=bindings, observedChildren=observedChildren or {}}
    if retiredSources ~= nil and next(retiredSources) ~= nil then data.retiredSources=retiredSources end
    local ok, why = K.validate(data, sources, months); if not ok then return nil, why end
    return copy(data)
end
-- Pure metadata transition for a fully observed actual maternal death. The caller
-- persists and publishes this alongside the complete owner snapshot. Real animals
-- and their cluster references are never copied or discarded here.
function K.stageRetirement(store,sourceId,eventId)
    if type(store)~="table" or type(store.farm)~="table" or type(store.sourceBindings)~="table" then return nil,"OWNED_STOCK_RETIRED_SCHEMA" end
    local binding=store.sourceBindings[sourceId]
    if not binding then return nil,"OWNED_STOCK_RETIRED_SOURCE" end
    local before,why=K.export(store.sourceOwners,store.sourceBindings,store.sourceRecordsByOwner,
        store.observedChildren,store.farm.sources,store.farm.clock.months,store.retiredSources)
    if not before then return nil,why end
    if store.recoveryRequired or store.purchase.recoveryRequired then return nil,"RECOVERY_REQUIRED" end
    if next(store.purchase.locks)~=nil then return nil,"TRANSACTION_IN_PROGRESS" end
    for _,owner in pairs(before.owners) do
        if next(owner.quarantine)~=nil then return nil,"RECOVERY_REQUIRED" end
        for _,event in pairs(owner.birthJournal) do if event.stage~="COMMITTED" then return nil,"RECOVERY_REQUIRED" end end
    end
    for _,transaction in pairs(store.purchase.records) do
        if transaction.stage~="COMMITTED" and transaction.stage~="ROLLED_BACK" then return nil,"TRANSACTION_IN_PROGRESS" end
    end
    local sources,bindings,retired,listings=copy(store.farm.sources),copy(store.sourceBindings),copy(store.retiredSources or {}),copy(store.listings)
    for saleId,row in pairs(listings.records) do
        if row.payload.sourceId==sourceId then
            if row.state=="RESERVED" then return nil,"TRANSACTION_IN_PROGRESS" end
            if row.state=="LISTED" then
                local withdrawn;withdrawn,why=RLDealerListingRegistry.withdraw(listings,saleId,store.farm.clock.months,"SOURCE_MATERNAL_MORTALITY")
                if not withdrawn then return nil,why end
            elseif row.state=="DRAFT" then
                local withdrawn;withdrawn,why=RLDealerListingRegistry.quarantine(listings,saleId,store.farm.clock.months,"SOURCE_MATERNAL_MORTALITY")
                if not withdrawn then return nil,why end
            end
        end
    end
    retired[sourceId]={ownerId=binding.ownerId,animalId=binding.animalId,record=sources[sourceId],
        reason="SOURCE_MATERNAL_MORTALITY",eventId=eventId}
    sources[sourceId],bindings[sourceId]=nil,nil
    local encoded;encoded,why=K.export(store.sourceOwners,bindings,store.sourceRecordsByOwner,store.observedChildren,
        sources,store.farm.clock.months,retired)
    if not encoded then return nil,why end
    return {sources=sources,sourceBindings=bindings,retiredSources=retired,listings=listings,sourceOwnership=encoded}
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
        observedChildren=copy(data.observedChildren), retiredSources=copy(data.retiredSources or {}), recoveryRequired=validated.recoveryRequired}
end
