-- One synchronous resource protocol for all animal transaction channels. A held
-- UNKNOWN operation never expires on a quote/lease timer. Resource names contain
-- the complete birth-herd identity, never a display tag or a species suffix.
RLMarketResourceLock = {}
local L = RLMarketResourceLock
local text=RLPlain.text
function L.resource(kind, key)
    if kind~="ANIMAL" and kind~="WALLET" and kind~="CONTAINER" and kind~="QUOTA" then return nil,"INVALID_RESOURCE_KIND" end
    if not text(key) then return nil,"INVALID_RESOURCE_KEY" end
    return kind..":"..#key..":"..key
end
function L.new()
    local held, owners = {}, {}
    local locks = {}
    function locks:acquire(transactionId, resources)
        if not text(transactionId) or type(resources)~="table" then return false,"INVALID_LOCK_REQUEST" end
        local normalized, seen, count = {}, {}, 0
        for index, resource in pairs(resources) do
            if type(index)~="number" or index%1~=0 or index<1 or index>#resources or not text(resource) then return false,"INVALID_RESOURCES" end
            count=count+1
            if seen[resource] then return false,"DUPLICATE_RESOURCE" end
            seen[resource]=true;normalized[#normalized+1]=resource
        end
        if count~=#resources or count==0 then return false,"INVALID_RESOURCES" end
        table.sort(normalized)
        local fingerprint=assert(RLMarketData.fingerprint(normalized))
        if owners[transactionId] then
            if owners[transactionId].fingerprint~=fingerprint then return false,"LOCK_REQUEST_MISMATCH" end
            if owners[transactionId].state=="UNKNOWN" then return false,"RECONCILIATION_REQUIRED" end
            return true
        end
        -- Check the entire globally ordered set before changing any ownership.
        for _, resource in ipairs(normalized) do
            if held[resource] then return false,"RESOURCE_BUSY",resource end
        end
        owners[transactionId]={resources=normalized,fingerprint=fingerprint,state="HELD"}
        for _, resource in ipairs(normalized) do held[resource]=transactionId end
        return true
    end
    function locks:markUnknown(transactionId)
        if not owners[transactionId] then return false,"LOCK_NOT_HELD" end
        owners[transactionId].state="UNKNOWN"
        return true
    end
    function locks:release(transactionId, reconciled)
        local owner=owners[transactionId]
        if owner==nil then return true end
        if owner.state=="UNKNOWN" and reconciled~=true then return false,"RECONCILIATION_REQUIRED" end
        for _, resource in ipairs(owner.resources) do held[resource]=nil end
        owners[transactionId]=nil
        return true
    end
    function locks:owner(resource) return held[resource] end
    function locks:snapshot() return assert(RLMarketData.copy({schemaVersion=1,owners=owners})) end
    function locks:restore(saved)
        if next(owners)~=nil then return false,"LOCK_STORE_NOT_EMPTY" end
        local data,reason=RLMarketData.copy(saved)
        if data==nil then return false,reason end
        if type(data)~="table" or data.schemaVersion~=1 or type(data.owners)~="table" then return false,"INVALID_LOCK_SNAPSHOT" end
        local restored, resources = {}, {}
        for transactionId, owner in pairs(data.owners) do
            if not text(transactionId) or type(owner)~="table" or (owner.state~="HELD" and owner.state~="UNKNOWN")
                or type(owner.resources)~="table" then return false,"INVALID_LOCK_SNAPSHOT" end
            local probe=L.new()
            local accepted=probe:acquire(transactionId,owner.resources)
            if not accepted or owner.fingerprint~=RLMarketData.fingerprint(owner.resources) then return false,"INVALID_LOCK_SNAPSHOT" end
            for _, resource in ipairs(owner.resources) do
                if resources[resource]~=nil then return false,"CONFLICTING_RECOVERY_LOCKS" end
                resources[resource]=transactionId
            end
            -- No proof of a running stack survives reload: all recovered holds
            -- require reconciliation by their transaction coordinator.
            owner.state="UNKNOWN";restored[transactionId]=owner
        end
        held,owners=resources,restored
        return true
    end
    return locks
end
function L.shared()
    if L.instance==nil then L.instance=L.new() end
    return L.instance
end
