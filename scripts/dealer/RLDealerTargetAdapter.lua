-- Real pen/trailer target queue adapter. No money, source ownership or durability.
-- The transaction owner must coordinate its receipts with WAL and source state.
RLDealerTargetAdapter = {}
local A=RLDealerTargetAdapter
-- Engine state of the pen, not the animal: ids, cluster link, dirty flag, and the 3D visual a pen gives each
-- animal (AnimalClusterHusbandry:updateVisuals sets visualAnimalIndex and Animal:createVisual's visualAnimal,
-- which links back to the animal; both appear as soon as the animal is in the pen).
local finite=RLPlain.finite
local dense=RLPlain.dense
local copy=RLPlain.copy
local function key(a)
    if type(a)~="table" or (type(a.farmId)~="string" and not finite(a.farmId)) or a.farmId==""
        or (type(a.uniqueId)~="string" and not finite(a.uniqueId)) or a.uniqueId=="" or a.uniqueId=="0-0" or a.uniqueId=="1-1"
        or type(a.birthday)~="table" or (type(a.birthday.country)~="string" and not finite(a.birthday.country))
        or a.birthday.country=="" then return nil end
    return RLTradeSourceAdapter.identityKey(a)
end
A.identityKey=key
local function frozen(a) return RLAnimalState.capture(a,{ignoreNestedMethods=true}) end
local equal=RLPlain.equal
-- The animal still matches its snapshot. Volatile keys of an older saved snapshot are ignored, and a texture
-- variation the pen picked for an animal that had none (updateVisuals) is not a change.
local function intact(a,saved)
    local now=frozen(a)
    if now==nil or type(saved)~="table" then return false end
    local base={};for k,v in pairs(saved) do if not RLAnimalState.isVolatile(k) then base[k]=v end end
    if base.variation==nil then now.variation=nil end
    return equal(now,base)
end
local function healthy(a)
    if key(a)==nil or a.isDead or a.isSold or a.beingRidden then return false end
    if type(a.getNumAnimals)~="function" then return false end
    local ok,n=pcall(a.getNumAnimals,a);return ok and n==1
end
function A.getSupport(destination)
    local c,kind=RLTradeSourceAdapter.getSupport(destination)
    if not c then return nil,tostring(kind):gsub("SOURCE","TARGET") end
    return c,kind
end
local function members(c)
    local ok,list=pcall(c.getClusters,c)
    if not ok or not dense(list) or not dense(c.animals) or #list~=#c.animals then return nil,"TARGET_UNREADABLE" end
    local count,identities={},{}
    for i,a in ipairs(list) do
        if a~=c.animals[i] or not healthy(a) or a.clusterSystem~=c then return nil,"TARGET_UNSAFE_MEMBER" end
        local k=key(a)
        if count[a] or identities[k] then return nil,"TARGET_DUPLICATE_IDENTITY" end
        count[a]=true;identities[k]=a
    end
    local out={};for i,a in ipairs(list) do out[i]=a end
    return out,nil,count,identities
end
local function owner(dest)
    if type(dest.getOwnerFarmId)~="function" then return nil,"TARGET_OWNER_UNREADABLE" end
    local ok,id=pcall(dest.getOwnerFarmId,dest)
    if not ok or not finite(id) then return nil,"TARGET_OWNER_UNREADABLE" end
    return id
end
local function sameSystem(b)
    local c=A.getSupport(b.destination);local farm=owner(b.destination)
    return c==b.clusterSystem and farm==b.ownerFarmId
end
local function queueState(b,allowAdds,allowRemoves)
    local c=b.clusterSystem
    if type(c.clustersToAdd)~="table" or type(c.clustersToRemove)~="table" then return false,"TARGET_QUEUE_UNREADABLE" end
    for a,value in pairs(c.clustersToAdd) do
        if not allowAdds or not b.ownedAdds[a] or value~=true then return false,"FOREIGN_ADD_QUEUE" end
    end
    for a,value in pairs(c.clustersToRemove) do
        if not allowRemoves or not b.ownedRemoves[a] or value~=true then return false,"FOREIGN_REMOVE_QUEUE" end
    end
    return true
end
function A.bind(destination,batch,owners)
    local c,kind=A.getSupport(destination);if not c then return nil,kind end
    local farm,why=owner(destination);if farm==nil then return nil,why end
    if not dense(batch) or #batch<1 then return nil,"BAD_BATCH" end
    if next(c.clustersToAdd)~=nil or next(c.clustersToRemove)~=nil then return nil,"TARGET_QUEUE_BUSY" end
    local list,reason,_,byKey=members(c);if not list then return nil,reason end
    local b={destination=destination,clusterSystem=c,kind=kind,ownerFarmId=farm,entries={},others={},ownedAdds={},ownedRemoves={},receipt={stage="BOUND"}}
    local seen={}
    for i,a in ipairs(batch) do
        local k=key(a)
        if not healthy(a) or a.isIndividual~=true or a.clusterSystem~=nil or a.sale~=nil then return nil,"BATCH_NOT_PREPARED" end
        if seen[k] or byKey[k] then return nil,"BATCH_IDENTITY_CONFLICT" end
        local s=frozen(a);if not s then return nil,"BATCH_STATE_UNREADABLE" end
        seen[k]=true;b.entries[i]={animal=a,key=k,snapshot=s}
    end
    for i,a in ipairs(list) do
        local s=frozen(a);if not s then return nil,"TARGET_STATE_UNREADABLE" end
        b.others[i]={animal=a,key=key(a),snapshot=s}
    end
    if owners~=nil then
        local world;world,why=A.scanOwners(owners);if not world then return nil,why end
        if not world.owners[destination] then return nil,"TARGET_NOT_SCANNED" end
        for _,e in ipairs(b.entries) do if world.byKey[e.key] then return nil,"WORLD_IDENTITY_CONFLICT:" .. e.key end end
        b.worldOwners=owners
    end
    return b
end
function A.observe(b)
    if not sameSystem(b) then return {known=false,reason="TARGET_CHANGED"} end
    if b.worldOwners then
        local world,reason=A.scanOwners(b.worldOwners)
        if not world then return {known=false,reason=reason} end
        for _,e in ipairs(b.entries) do
            if world.byKey[e.key] and world.byKey[e.key].destination~=b.destination then return {known=false,reason="BATCH_IN_OTHER_OWNER"} end
        end
    end
    local list,why,count,byKey=members(b.clusterSystem)
    if not list then return {known=false,reason=why} end
    local out={known=true,added={},missing={},othersIntact=true,fieldsIntact=true,queuesClean=queueState(b,false,false)}
    local expected={}
    for i,e in ipairs(b.entries) do
        if e.animal~=nil and count[e.animal] then
            if byKey[e.key]~=e.animal or key(e.animal)~=e.key then return {known=false,reason="BATCH_IDENTITY_CHANGED"} end
            out.added[#out.added+1]=i;expected[e.animal]=true
            if e.animal.clusterSystem~=b.clusterSystem or not intact(e.animal,e.snapshot) then out.fieldsIntact=false end
        elseif byKey[e.key]~=nil then return {known=false,reason="BATCH_IDENTITY_CONFLICT"}
        else out.missing[#out.missing+1]=i end
    end
    for _,e in ipairs(b.others) do
        expected[e.animal]=true
        if not count[e.animal] or byKey[e.key]~=e.animal or not intact(e.animal,e.snapshot) then out.othersIntact=false end
    end
    for _,a in ipairs(list) do if not expected[a] then out.othersIntact=false end end
    return out
end
local function ready(b,allowAdds,allowRemoves)
    local observed=A.observe(b)
    if not observed.known then return nil,observed.reason end
    if not observed.othersIntact or not observed.fieldsIntact then return nil,"TARGET_FIELDS_OR_MEMBERS_CHANGED" end
    for _,i in ipairs(observed.missing) do
        local e=b.entries[i]
        if e.animal and (key(e.animal)~=e.key or not healthy(e.animal) or not intact(e.animal,e.snapshot)) then return nil,"BATCH_CHANGED" end
    end
    local ok,why=queueState(b,allowAdds,allowRemoves);if not ok then return nil,why end
    return observed
end
function A.apply(b)
    if b.receipt.applied then return nil,"ALREADY_APPLIED" end
    local o,why=ready(b,false,false);if not o then return nil,why end
    if #o.added~=0 then return nil,"BATCH_ALREADY_PRESENT" end
    for _,e in ipairs(b.entries) do if not e.animal or not intact(e.animal,e.snapshot) or e.animal.clusterSystem~=nil then return nil,"BATCH_CHANGED" end end
    b.receipt.applied=true;b.receipt.stage="APPLYING"
    for _,e in ipairs(b.entries) do
        b.ownedAdds[e.animal]=true
        local ok,err=pcall(b.clusterSystem.addPendingAddCluster,b.clusterSystem,e.animal)
        if not ok then return nil,"ADD_QUEUE_THREW:" .. tostring(err) end
    end
    o,why=ready(b,true,false);if not o then return nil,why end
    for _,e in ipairs(b.entries) do if b.clusterSystem.clustersToAdd[e.animal]~=true then return nil,"ADD_QUEUE_REFUSED" end end
    local flushed,err=pcall(b.clusterSystem.updateNow,b.clusterSystem)
    o=A.observe(b)
    if not flushed then return nil,"ADD_FLUSH_THREW:" .. tostring(err),o end
    if not o.known or not o.othersIntact or not o.fieldsIntact or not o.queuesClean or #o.added~=#b.entries then return nil,"ADD_NOT_VERIFIED",o end
    b.receipt.stage="APPLIED";return true,o
end
function A.rollback(b)
    local o,why=ready(b,true,true);if not o then return nil,why end
    -- Clear only exact entries claimed by this binding. Unknown false/foreign
    -- queue values were rejected before any modification.
    for a in pairs(b.ownedAdds) do b.clusterSystem.clustersToAdd[a]=nil end
    for a in pairs(b.ownedRemoves) do b.clusterSystem.clustersToRemove[a]=nil end
    for _,i in ipairs(o.added) do
        local a=b.entries[i].animal;b.ownedRemoves[a]=true
        local ok,err=pcall(b.clusterSystem.addPendingRemoveCluster,b.clusterSystem,a)
        if not ok then return nil,"REMOVE_QUEUE_THREW:" .. tostring(err) end
    end
    local current;current,why=ready(b,false,true);if not current then return nil,why end
    for _,i in ipairs(o.added) do if b.clusterSystem.clustersToRemove[b.entries[i].animal]~=true then return nil,"REMOVE_QUEUE_REFUSED" end end
    if #o.added>0 then
        local ok,err=pcall(b.clusterSystem.updateNow,b.clusterSystem)
        if not ok then return nil,"REMOVE_FLUSH_THREW:" .. tostring(err) end
    end
    local verified;verified,why=A.verifyRestored(b)
    if not verified then return nil,why end
    b.receipt.stage="ROLLED_BACK";return true
end
function A.verifyRestored(b)
    local o=A.observe(b)
    if not o.known then return nil,o.reason end
    if not o.othersIntact or not o.fieldsIntact or not o.queuesClean or #o.added~=0 then return nil,"TARGET_NOT_RESTORED" end
    for _,e in ipairs(b.entries) do
        if e.animal and (e.animal.clusterSystem~=nil or not intact(e.animal,e.snapshot)) then return nil,"BATCH_NOT_RESTORED" end
    end
    return true
end
-- Pure complete-world scan. The caller supplies every pen and livestock trailer;
-- an omitted owner cannot be proved absent by this helper.
function A.scanOwners(owners)
    if not dense(owners) then return nil,"OWNERS_UNREADABLE" end
    local scan={byKey={},owners={}};local seen={}
    for _,destination in ipairs(owners) do
        if seen[destination] then return nil,"DUPLICATE_OWNER" end;seen[destination]=true
        local c,why=A.getSupport(destination);if not c then return nil,why end
        local list;list,why=members(c);if not list then return nil,why end
        scan.owners[destination]=true
        for _,a in ipairs(list) do
            local k=key(a);if scan.byKey[k] then return nil,"WORLD_IDENTITY_CONFLICT:" .. k end
            scan.byKey[k]={animal=a,destination=destination,clusterSystem=c}
        end
    end
    return scan
end
function A.exportBinding(b)
    local out={version=1,kind=b.kind,ownerFarmId=b.ownerFarmId,entries={},others={}}
    for i,e in ipairs(b.entries) do out.entries[i]={key=e.key,snapshot=copy(e.snapshot)} end
    for i,e in ipairs(b.others) do out.others[i]={key=e.key,snapshot=copy(e.snapshot)} end
    return out
end
function A.rebind(destination,evidence,owners)
    if RLTradePersistence==nil or RLTradePersistence.check(evidence,{maxNodes=200000,maxString=262144,maxDepth=32}) then return nil,"BAD_BINDING_EVIDENCE" end
    if type(evidence)~="table" or evidence.version~=1 or not dense(evidence.entries) or #evidence.entries==0 or not dense(evidence.others) then return nil,"BAD_BINDING_EVIDENCE" end
    local scan,why=A.scanOwners(owners);if not scan then return nil,why end
    if not scan.owners[destination] then return nil,"TARGET_NOT_SCANNED" end
    local c,kind=A.getSupport(destination);if not c then return nil,kind end
    local farm=owner(destination)
    if farm~=evidence.ownerFarmId or kind~=evidence.kind then return nil,"TARGET_OWNER_CHANGED" end
    if next(c.clustersToAdd)~=nil or next(c.clustersToRemove)~=nil then return nil,"TARGET_QUEUE_BUSY" end
    local b={destination=destination,clusterSystem=c,kind=kind,ownerFarmId=farm,entries={},others={},ownedAdds={},ownedRemoves={},worldOwners=owners,receipt={stage="REBOUND",applied=true}}
    local seen={}
    for _,section in ipairs({"entries","others"}) do
        for i,saved in ipairs(evidence[section]) do
            if type(saved)~="table" or type(saved.snapshot)~="table" or key(saved.snapshot)~=saved.key or seen[saved.key] then return nil,"BAD_BINDING_EVIDENCE" end
            seen[saved.key]=true
            local live=scan.byKey[saved.key]
            if live and live.destination~=destination then return nil,"BATCH_IN_OTHER_OWNER" end
            if section=="others" and not live then return nil,"OTHER_MEMBER_MISSING" end
            if live and not intact(live.animal,saved.snapshot) then return nil,"REBOUND_STATE_CHANGED" end
            b[section][i]={animal=live and live.animal or nil,key=saved.key,snapshot=copy(saved.snapshot)}
        end
    end
    local o=A.observe(b);if not o.known or not o.othersIntact or not o.fieldsIntact then return nil,"REBOUND_MEMBERS_CHANGED" end
    return b
end
