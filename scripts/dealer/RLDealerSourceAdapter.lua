-- Exact private-source detachment. This adapter owns no listing or money effects.
-- Recovery never recreates an animal from a transaction receipt or redraws it.
RLDealerSourceAdapter = { VERSION = 1 }
local A = RLDealerSourceAdapter
local function copy(v)
    if type(v) ~= "table" then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    return RLTradePersistence.canonical(a)==RLTradePersistence.canonical(b)
end
local function encode(owner, records)
    local ok, data = pcall(RLDealerSourceOwnership.export,owner,records)
    if ok then return data end
end
local function validHandle(b)
    return type(b)=="table" and b.version==A.VERSION and type(b.owner)=="table"
        and type(b.spec)=="table" and type(b.cluster)=="table" and b.owner.animals==b.animals
        and b.owner.byId==b.byId and b.owner.clusterSystem==b.cluster and b.owner.spec==b.spec
        and b.owner.spec.clusterSystem==b.cluster and b.cluster.owner==b.owner
end
function A.bind(owner, ids, records)
    if type(owner)~="table" or type(ids)~="table" or type(records)~="table" or #ids<1 then return nil,"SOURCE_BINDING" end
    local n=0;for k in pairs(ids) do
        if type(k)~="number" or k<1 or k%1~=0 or k>#ids then return nil,"SOURCE_BATCH" end;n=n+1
    end
    if n~=#ids then return nil,"SOURCE_BATCH" end
    local before=encode(owner,records);if not before then return nil,"SOURCE_OWNER_INVALID" end
    if next(owner.quarantine)~=nil then return nil,"SOURCE_QUARANTINED" end
    for _,event in pairs(owner.birthJournal) do
        if event.stage~="COMMITTED" then return nil,"SOURCE_BIRTH_UNCERTAIN" end
    end
    local selected, entries, animalIds={}, {}, {}
    for _,id in ipairs(ids) do
        local animal=owner.byId[id]
        if type(id)~="string" or selected[id] or animal==nil or records[id]==nil
            or owner.quarantine[id]~=nil or animal.isDead==true then return nil,"SOURCE_BATCH" end
        selected[id]=true;animalIds[#animalIds+1]=id
    end
    table.sort(animalIds)
    for _,id in ipairs(animalIds) do entries[#entries+1]={id=id,animal=owner.byId[id]} end
    local after=copy(before);after.animals={}
    for _,animal in ipairs(before.animals) do
        if not selected[animal.identity.uniqueId] then after.animals[#after.animals+1]=copy(animal) end
    end
    local originals={};for i,animal in ipairs(owner.animals) do originals[i]=animal end
    local binding={version=A.VERSION,owner=owner,records=records,animals=owner.animals,byId=owner.byId,
        cluster=owner.clusterSystem,spec=owner.spec,entries=entries,originals=originals,
        before=before,after=after,animalIds=animalIds}
    if not validHandle(binding) then return nil,"SOURCE_OWNER_HANDLE" end
    return binding
end
function A.observe(binding)
    if not validHandle(binding) then return "UNKNOWN","SOURCE_OWNER_HANDLE" end
    local current=encode(binding.owner,binding.records)
    if not current then return "UNKNOWN","SOURCE_OWNER_INVALID" end
    if equal(current,binding.before) then
        for _,entry in ipairs(binding.entries) do
            if binding.byId[entry.id]~=entry.animal or entry.animal.clusterSystem~=binding.cluster then return "UNKNOWN","SOURCE_OBJECT_CHANGED" end
        end
        return "PRESENT"
    end
    if equal(current,binding.after) then
        for _,entry in ipairs(binding.entries) do
            if binding.byId[entry.id]~=nil then return "UNKNOWN","SOURCE_OBJECT_CHANGED" end
        end
        return "REMOVED"
    end
    return "UNKNOWN","SOURCE_INVENTORY_CHANGED"
end
function A.apply(binding)
    local state,why=A.observe(binding)
    if state=="REMOVED" then return true end
    if state~="PRESENT" then return nil,why end
    local selected={};for _,entry in ipairs(binding.entries) do selected[entry.id]=true end
    for i=#binding.animals,1,-1 do
        local animal=binding.animals[i]
        if selected[animal.uniqueId] then
            table.remove(binding.animals,i);binding.byId[animal.uniqueId]=nil;animal.clusterSystem=nil
        end
    end
    if A.observe(binding)~="REMOVED" then return nil,"SOURCE_DETACH_UNCERTAIN" end
    return true
end
function A.rollback(binding)
    local state,why=A.observe(binding)
    if state=="PRESENT" then return true end
    if state~="REMOVED" then return nil,why end
    -- Only the original detached objects can return. A target must first undo
    -- and verify its own attachment; foreign ownership must never be overwritten.
    local fake={version=binding.owner.version,rlDealerSourceId=binding.owner.rlDealerSourceId,
        capacity=binding.owner.capacity,animals={},byId={},pendingAdds={},clusterSystem=nil,
        sireContexts=binding.owner.sireContexts,birthJournal=binding.owner.birthJournal,
        observedBirths=binding.owner.observedBirths,quarantine=binding.owner.quarantine}
    for _,entry in ipairs(binding.entries) do
        if entry.animal.clusterSystem~=nil or binding.byId[entry.id]~=nil then return nil,"SOURCE_ROLLBACK_OWNERSHIP" end
        fake.animals[#fake.animals+1]=entry.animal;fake.byId[entry.id]=entry.animal
    end
    local detached=encode(fake,binding.records)
    if not detached then return nil,"SOURCE_ROLLBACK_CHANGED" end
    local expected={};local selected={};for _,id in ipairs(binding.animalIds) do selected[id]=true end
    for _,animal in ipairs(binding.before.animals) do if selected[animal.identity.uniqueId] then expected[animal.identity.uniqueId]=animal end end
    for _,animal in ipairs(detached.animals) do
        if not equal(animal,expected[animal.identity.uniqueId]) then return nil,"SOURCE_ROLLBACK_CHANGED" end
    end
    for i=#binding.animals,1,-1 do binding.animals[i]=nil end
    for i,animal in ipairs(binding.originals) do
        binding.animals[i]=animal;binding.byId[animal.uniqueId]=animal;animal.clusterSystem=binding.cluster
    end
    if A.observe(binding)~="PRESENT" then return nil,"SOURCE_ROLLBACK_UNCERTAIN" end
    return true
end
function A.exportBinding(binding)
    local state,why=A.observe(binding);if state=="UNKNOWN" then return nil,why end
    return {version=A.VERSION,ownerId=binding.owner.rlDealerSourceId,animalIds=copy(binding.animalIds),
        before=copy(binding.before),after=copy(binding.after),state=state}
end
function A.rebind(owner,evidence,records)
    if type(evidence)~="table" or RLTradePersistence.check(evidence) or evidence.version~=A.VERSION
        or type(owner)~="table" or owner.rlDealerSourceId~=evidence.ownerId then return nil,"SOURCE_REBIND" end
    local current=encode(owner,records)
    if not current then return nil,"SOURCE_OWNER_INVALID" end
    if not equal(current,evidence.before) then return nil,"SOURCE_RECONCILIATION_REQUIRED" end
    local binding,why=A.bind(owner,evidence.animalIds,records)
    if not binding then return nil,why end
    if not equal(binding.after,evidence.after) then return nil,"SOURCE_REBIND_EVIDENCE" end
    return binding
end
