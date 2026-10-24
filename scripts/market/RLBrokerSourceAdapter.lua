-- Broker single-animal engine seam. Reuses the queue mechanics, never a SALE/HB
-- transaction kind. Portable evidence is complete data; this version explicitly
-- refuses to reconstruct live Animal objects after reload.
RLBrokerSourceAdapter = {}
local A = RLBrokerSourceAdapter
local ignored = { id=true,idFull=true,clusterSystem=true,isDirty=true,rlGrowthCurve=true,rlInfoRows=true }
local function data(value, root, active)
    local kind=type(value)
    if kind~="table" then
        if kind=="function" or kind=="userdata" or kind=="thread" then error("NON_PORTABLE_FIELD") end
        if kind=="number" and (value~=value or math.abs(value)==math.huge) then error("NON_FINITE_FIELD") end
        return value
    end
    active=active or {};if active[value] then error("CYCLIC_ANIMAL_STATE") end;active[value]=true
    local out={}
    -- Raw fields retain Disease records/models and all pregnancy/growth data;
    -- no truncation, tostring(table), metatable execution or live system link.
    for key,item in next,value do
        if not (root and (ignored[key] or type(item)=="function")) then
            if type(key)~="string" and type(key)~="number" then error("NON_PORTABLE_KEY") end
            out[key]=data(item,false,active)
        end
    end
    active[value]=nil;return out
end
local function copy(value) return assert(RLMarketData.copy(value)) end
local function fingerprint(value) return assert(RLMarketData.fingerprint(value)) end
local function fields(animal) return data(animal,true,{}) end
local function members(system)
    local list=system:getClusters()
    if type(list)~="table" then error("SOURCE_UNREADABLE") end
    local count=0
    for key in pairs(list) do
        if type(key)~="number" or key<1 or key%1~=0 or key>#list then error("SOURCE_MEMBERS_NOT_DENSE") end
        count=count+1
    end
    if count~=#list then error("SOURCE_MEMBERS_NOT_DENSE") end
    local out={};for i,item in ipairs(list) do out[i]=item end;return out
end
function A.worldMembership(source,kind,mission)
    if type(mission)~="table" or type(mission.getIsServer)~="function" or not mission:getIsServer() then return false end
    local system=kind=="PEN" and mission.placeableSystem or kind=="TRAILER" and mission.vehicleSystem
    local list=system and (kind=="PEN" and system.placeables or system.vehicles)
    if type(list)~="table" then return false end
    local count=0
    for _,member in pairs(list) do if member==source then count=count+1 end end
    return count==1
end
local function contextValid(h)
    local source,o=h.binding.source,h.options
    if source:getOwnerFarmId()~=o.farmId then return false,"SOURCE_OWNER_CHANGED" end
    if tostring(o.resolveSourceId(source))~=o.sourceId then return false,"SOURCE_ID_CHANGED" end
    if h.binding.kind=="TRAILER" then
        if o.channel~="BROKER_DELIVERY" or type(o.verifyLocation)~="function" or type(o.locationEvidence)~="table"
            or type(o.locationEvidence.pointId)~="string" or o.locationEvidence.pointId==""
            or o.verifyLocation(source,o.farmId,copy(o.locationEvidence))~=true then return false,"SELF_DELIVERY_LOCATION_UNVERIFIED" end
    elseif o.channel~="BROKER_PICKUP" then return false,"PEN_REQUIRES_PICKUP" end
    if o.verifyMembership(source,h.binding.kind)~=true then return false,"SOURCE_NOT_IN_WORLD" end
    return true
end
local function intact(h, includeSelected)
    local ok,why=contextValid(h);if not ok then return false,why end
    if select(1,RLTradeSourceAdapter.getSupport(h.binding.source))~=h.binding.clusterSystem then return false,"SOURCE_CHANGED" end
    local list=members(h.binding.clusterSystem);local seen={}
    for _,animal in ipairs(list) do seen[animal]=(seen[animal] or 0)+1 end
    for animal,expected in pairs(h.otherStates) do
        if seen[animal]~=1 or fingerprint(fields(animal))~=expected then return false,"OTHER_MEMBER_CHANGED" end
    end
    if includeSelected and fingerprint(fields(h.binding.animals[1]))~=h.selectedState then return false,"ANIMAL_FIELDS_CHANGED" end
    return true
end
local function observe(h)
    if not h.binding then return {status="UNKNOWN",reason="RELOAD_RESTORE_UNSUPPORTED",keepLocked=true} end
    local outcome=RLTradeSourceAdapter.observe(h.binding)
    local ok,why=intact(h,false)
    local queues=h.binding.clusterSystem
    if not outcome.known or not outcome.sameSystem or not outcome.othersIntact or not ok then
        return {status="UNKNOWN",reason=why or outcome.reason or "SOURCE_CHANGED",keepLocked=true}
    end
    if next(queues.clustersToAdd)~=nil or next(queues.clustersToRemove)~=nil then return {status="UNKNOWN",reason="QUEUE_CHANGED",keepLocked=true} end
    if #outcome.removed==1 then return {status="APPLIED",removedKey=h.evidence.identityKey,keepLocked=true} end
    if #outcome.survivors==1 then return {status="NOT_APPLIED",keepLocked=h.attempted==true} end
    return {status="UNKNOWN",reason="MEMBERSHIP_UNKNOWN",keepLocked=true}
end
local function protected(fn,...)
    local ok,result,why=pcall(fn,...)
    if not ok then return nil,"SOURCE_ADAPTER_ERROR" end
    return result,why
end
function A.prepare(source,key,options)
    return protected(function()
        if type(options)~="table" or type(options.farmId)~="number" or options.farmId<1 or options.farmId%1~=0
            or type(options.sourceId)~="string" or options.sourceId=="" or type(source.getOwnerFarmId)~="function" then return nil,"SOURCE_CONTEXT_REQUIRED" end
        local binding,why=RLTradeSourceAdapter.bind(source,{key});if not binding then return nil,why end
        if options.kind~=binding.kind then return nil,"SOURCE_KIND_MISMATCH" end
        local resolve=options.resolveSourceId or function(s)
            return type(s.getUniqueId)=="function" and s:getUniqueId() or s.uniqueId
        end
        local actualId=resolve(source)
        if (type(actualId)~="string" and type(actualId)~="number") or tostring(actualId)~=options.sourceId then return nil,"SOURCE_ID_UNVERIFIED" end
        local frozen={farmId=options.farmId,sourceId=options.sourceId,kind=options.kind,channel=options.channel,
            locationEvidence=options.locationEvidence and copy(options.locationEvidence),verifyLocation=options.verifyLocation,resolveSourceId=resolve}
        local mission=options.mission or g_currentMission
        frozen.verifyMembership=options.verifyMembership or function(s,kind) return A.worldMembership(s,kind,mission) end
        if type(frozen.verifyMembership)~="function" then return nil,"SOURCE_MEMBERSHIP_VERIFIER_REQUIRED" end
        local h={binding=binding,options=frozen,otherStates={},busy=false}
        local valid;valid,why=contextValid(h);if not valid then return nil,why end
        local portableMembers={};local seen={}
        for _,animal in ipairs(members(binding.clusterSystem)) do
            local identity=RLTradeSourceAdapter.identityKey(animal)
            if identity==nil or seen[identity] then return nil,"SOURCE_IDENTITY_NOT_UNIQUE" end
            seen[identity]=true
            local state=fields(animal)
            portableMembers[#portableMembers+1]={identityKey=identity,state=state,engineId=animal.id,engineIdFull=animal.idFull}
            if animal==binding.animals[1] then h.selectedState=fingerprint(state)
            else h.otherStates[animal]=fingerprint(state) end
        end
        h.evidence={version=1,kind="BROKER_SOURCE",sourceKind=binding.kind,sourceId=options.sourceId,
            ownerFarmId=options.farmId,identityKey=key,animal=fields(binding.animals[1]),members=portableMembers,
            queues={add={},remove={}},locationEvidence=options.locationEvidence and copy(options.locationEvidence),
            reloadRestoreSupported=false}
        h.evidence.fingerprint=fingerprint(h.evidence)
        return h
    end)
end
function A.portableEvidence(h)
    if type(h)~="table" or type(h.evidence)~="table" then return nil,"NO_SOURCE_EVIDENCE" end
    return copy(h.evidence)
end
function A.remove(h,persistPrepared)
    if not h or not h.binding then return {status="UNKNOWN",reason="RELOAD_RESTORE_UNSUPPORTED",keepLocked=true} end
    if h.busy then return {status="UNKNOWN",reason="SOURCE_REENTRY",keepLocked=true} end
    if h.removalReceipt then return copy(h.removalReceipt) end
    h.busy,h.attempted=true,true
    local ok,result=pcall(function()
        local valid,why=intact(h,true)
        if not valid or not RLTradeSourceAdapter.recheck(h.binding) then return {status="NOT_APPLIED",reason=why or "SOURCE_RECHECK_FAILED",keepLocked=true} end
        if type(persistPrepared)~="function" or persistPrepared(A.portableEvidence(h))~=true then
            return {status="NOT_APPLIED",reason="PREPARED_NOT_DURABLE",keepLocked=true}
        end
        valid,why=intact(h,true)
        if not valid then return {status="NOT_APPLIED",reason=why,keepLocked=true} end
        RLTradeSourceAdapter.apply(h.binding)
        return observe(h)
    end)
    h.busy=false
    h.removalReceipt=ok and result or {status="UNKNOWN",reason="SOURCE_REMOVE_ERROR",keepLocked=true}
    return copy(h.removalReceipt)
end
function A.observe(h)
    local result=protected(observe,h)
    return result or {status="UNKNOWN",reason="SOURCE_OBSERVATION_ERROR",keepLocked=true}
end
function A.verifyRestored(h)
    if not h or not h.binding then return false,"RELOAD_RESTORE_UNSUPPORTED" end
    local okay,why=protected(function()
        local valid,err=intact(h,true);if not valid then return false,err end
        if not RLTradeSourceAdapter.verifyRestored(h.binding) then return false,"RESTORE_NOT_VERIFIED" end
        local outcome=observe(h)
        return outcome.status=="NOT_APPLIED",outcome.reason
    end)
    return okay==true,why
end
function A.restore(h)
    if not h or not h.binding then return {status="UNKNOWN",reason="RELOAD_RESTORE_UNSUPPORTED",keepLocked=true} end
    if h.busy then return {status="UNKNOWN",reason="SOURCE_REENTRY",keepLocked=true} end
    if h.restoreReceipt then return copy(h.restoreReceipt) end
    h.busy=true
    local ok,result=pcall(function()
        local valid,why=intact(h,true);if not valid then return {status="UNKNOWN",reason=why,keepLocked=true} end
        local outcome=observe(h)
        if outcome.status=="UNKNOWN" then
            if outcome.reason~="QUEUE_CHANGED" then return outcome end
            local system=h.binding.clusterSystem
            if next(system.clustersToAdd)~=nil then return outcome end
            for animal,value in pairs(system.clustersToRemove) do
                if animal~=h.binding.animals[1] or value~=true then return outcome end
            end
        end
        if not RLTradeSourceAdapter.rollback(h.binding) then return {status="UNKNOWN",reason="SOURCE_ROLLBACK_UNCERTAIN",keepLocked=true} end
        local restored,err=A.verifyRestored(h)
        return {status=restored and "APPLIED" or "UNKNOWN",reason=err,keepLocked=not restored}
    end)
    h.busy=false;h.restoreReceipt=ok and result or {status="UNKNOWN",reason="SOURCE_RESTORE_ERROR",keepLocked=true}
    return copy(h.restoreReceipt)
end
