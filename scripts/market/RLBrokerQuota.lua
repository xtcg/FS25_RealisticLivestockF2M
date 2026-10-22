-- Market-wide monthly head counts. No money budget, no farm multiplier, no RNG.
-- Coordinator enumerates these resource names with animal/wallet/container locks
-- before reserve. All mutation below is synchronous and invokes no callbacks.
RLBrokerQuota = {}
local Q=RLBrokerQuota
local function text(v) return type(v)=="string" and v:match("%S")~=nil end
local function integer(v,min) return RLMarketMoney.finite(v) and v%1==0 and v>=min and v<2^52 end
local function breedMatches(species,breed) return text(breed) and breed:sub(1,#species+1)==species..":" and #breed>#species+1 end
function Q.resources(monthId,orderId,species,breed)
    if not text(monthId) or not text(orderId) or not text(species) or not breedMatches(species,breed) then return nil,"INVALID_QUOTA_SCOPE" end
    local result={}
    for _,parts in ipairs({{"order",orderId},{"species",species},{"breed",breed}}) do
        result[#result+1]=assert(RLMarketResourceLock.resource("QUOTA",assert(RLMarketData.fingerprint({monthId,parts[1],parts[2]}))))
    end
    table.sort(result)
    return result
end
function Q.new()
    local pools,requests={},{}
    local ledger={}
    function ledger:initialize(monthId,definition)
        if not text(monthId) then return false,"INVALID_MONTH" end
        local copy,reason=RLMarketData.copy(definition)
        if copy==nil or type(copy)~="table" or type(copy.orders)~="table" or type(copy.species)~="table" then return false,reason or "INVALID_QUOTA_DEFINITION" end
        for species,limits in pairs(copy.species) do
            if not text(species) or type(limits)~="table" or not integer(limits.monthlyHeadCap,1)
                or not integer(limits.perBreedHeadCap,1) or limits.perBreedHeadCap>limits.monthlyHeadCap then return false,"INVALID_SPECIES_CAP" end
        end
        for orderId,order in pairs(copy.orders) do
            if not text(orderId) or type(order)~="table" or copy.species[order.speciesKey]==nil
                or not integer(order.quantityTotal,1) or (order.breedScope~="ANY" and order.breedScope~="SPECIFIC") then return false,"INVALID_ORDER_CAP" end
            if order.breedScope=="SPECIFIC" then
                if not breedMatches(order.speciesKey,order.requiredBreedId) or order.quantityTotal>copy.species[order.speciesKey].perBreedHeadCap then return false,"INVALID_SPECIFIC_CAP" end
            elseif order.requiredBreedId~=nil then return false,"ANY_HAS_HIDDEN_BREED" end
            if order.quantityTotal>copy.species[order.speciesKey].monthlyHeadCap then return false,"ORDER_EXCEEDS_SPECIES_CAP" end
        end
        local fingerprint=assert(RLMarketData.fingerprint(copy))
        if pools[monthId] then return pools[monthId].fingerprint==fingerprint,pools[monthId].fingerprint~=fingerprint and "MONTH_ALREADY_INITIALIZED" or nil end
        pools[monthId]={definition=copy,fingerprint=fingerprint,committed={order={},species={},breed={}},reserved={order={},species={},breed={}}}
        return true
    end
    function ledger:available(monthId,orderId,species,breed)
        local pool=pools[monthId]
        if not pool then return nil,"UNKNOWN_QUOTA_MONTH" end
        local order=pool.definition.orders[orderId]
        if order==nil or order.speciesKey~=species then return nil,"QUOTA_ORDER_MISMATCH" end
        local limit=pool.definition.species[species]
        if breed~=nil and (not breedMatches(species,breed) or (order.breedScope=="SPECIFIC" and breed~=order.requiredBreedId)) then return nil,"QUOTA_BREED_MISMATCH" end
        local function remaining(kind,key,total)
            return total-(pool.committed[kind][key] or 0)-(pool.reserved[kind][key] or 0)
        end
        local result={order=remaining("order",orderId,order.quantityTotal),species=remaining("species",species,limit.monthlyHeadCap)}
        if breed~=nil then result.breed=remaining("breed",breed,limit.perBreedHeadCap);result.available=math.min(result.order,result.species,result.breed)
        else result.breedNote="BREED_LIMIT_DEPENDS_ON_SELECTED_ANIMAL" end
        return result
    end
    local function delta(pool,bucket,request,amount)
        for _,pair in ipairs({{"order",request.orderId},{"species",request.speciesKey},{"breed",request.breedId}}) do
            local map=pool[bucket][pair[1]];map[pair[2]]=(map[pair[2]] or 0)+amount
            if map[pair[2]]==0 then map[pair[2]]=nil end
        end
    end
    function ledger:reserve(requestId,monthId,orderId,species,breed,locks)
        if not text(requestId) then return nil,"INVALID_QUOTA_REQUEST" end
        local resources,reason=Q.resources(monthId,orderId,species,breed)
        if resources==nil then return nil,reason end
        local fingerprint=assert(RLMarketData.fingerprint({monthId,orderId,species,breed}))
        local previous=requests[requestId]
        if previous then
            if previous.fingerprint~=fingerprint then return nil,"QUOTA_REQUEST_MISMATCH" end
            return assert(RLMarketData.copy(previous))
        end
        if type(locks)~="table" or type(locks.owner)~="function" then return nil,"QUOTA_LOCKS_REQUIRED" end
        for _,resource in ipairs(resources) do if locks:owner(resource)~=requestId then return nil,"QUOTA_LOCKS_REQUIRED" end end
        local capacity,why=self:available(monthId,orderId,species,breed)
        if capacity==nil then return nil,why end
        if capacity.available<1 then return nil,"QUOTA_EXHAUSTED" end
        local request={requestId=requestId,monthId=monthId,orderId=orderId,speciesKey=species,breedId=breed,fingerprint=fingerprint,state="RESERVED"}
        requests[requestId]=request;delta(pools[monthId],"reserved",request,1)
        return assert(RLMarketData.copy(request))
    end
    function ledger:commit(requestId)
        local request=requests[requestId]
        if request==nil then return false,"UNKNOWN_QUOTA_REQUEST" end
        if request.state=="COMMITTED" then return true end
        if request.state~="RESERVED" then return false,"QUOTA_RECONCILIATION_REQUIRED" end
        delta(pools[request.monthId],"reserved",request,-1);delta(pools[request.monthId],"committed",request,1)
        request.state="COMMITTED"
        return true
    end
    function ledger:markUnknown(requestId)
        if requests[requestId]==nil or requests[requestId].state~="RESERVED" then return false,"INVALID_QUOTA_STATE" end
        requests[requestId].state="UNKNOWN";return true
    end
    function ledger:reconcileCommit(requestId,evidence)
        local request=requests[requestId]
        if request==nil then return false,"UNKNOWN_QUOTA_REQUEST" end
        local proof,reason=RLMarketData.copy(evidence)
        if proof==nil then return false,reason end
        if type(proof)~="table" or proof.requestId~=requestId or proof.monthId~=request.monthId
            or proof.outcome~="COMMITTED" or proof.animalRemoved~=true or proof.moneyApplied~=true
            or not text(proof.proofRef) then return false,"QUOTA_COMMIT_PROOF_REQUIRED" end
        if request.state=="COMMITTED" then return true end
        if request.state~="UNKNOWN" then return false,"INVALID_QUOTA_STATE" end
        -- The server coordinator supplies evidence it independently verified;
        -- this pure store never infers payment from balance or repeats removal.
        delta(pools[request.monthId],"reserved",request,-1)
        delta(pools[request.monthId],"committed",request,1)
        request.state,request.reconciliationEvidence="COMMITTED",proof
        return true
    end
    function ledger:release(requestId,reconciled)
        local request=requests[requestId]
        if request==nil then return false,"UNKNOWN_QUOTA_REQUEST" end
        if request.state=="RELEASED" then return true end
        if request.state=="COMMITTED" then return false,"QUOTA_ALREADY_COMMITTED" end
        if request.state=="UNKNOWN" and reconciled~=true then return false,"QUOTA_RECONCILIATION_REQUIRED" end
        delta(pools[request.monthId],"reserved",request,-1);request.state="RELEASED";return true
    end
    function ledger:export() return assert(RLMarketData.copy({schemaVersion=1,pools=pools,requests=requests})) end
    -- Restore recomputes every counter from terminal/reserved evidence, rejecting
    -- drift instead of trusting saved totals or silently repairing a broken pool.
    function ledger:restore(saved)
        if next(pools) or next(requests) then return false,"QUOTA_STORE_NOT_EMPTY" end
        local data,reason=RLMarketData.copy(saved)
        if data==nil or type(data)~="table" or data.schemaVersion~=1 or type(data.pools)~="table" or type(data.requests)~="table" then return false,reason or "INVALID_QUOTA_STORE" end
        local candidate=Q.new()
        for monthId,pool in pairs(data.pools) do
            if type(pool)~="table" or pool.fingerprint~=RLMarketData.fingerprint(pool.definition) then return false,"INVALID_QUOTA_STORE" end
            local accepted=candidate:initialize(monthId,pool.definition)
            if not accepted then return false,"INVALID_QUOTA_STORE" end
        end
        local computed=candidate:export()
        local ids={};for id in pairs(data.requests) do if not text(id) then return false,"INVALID_QUOTA_STORE" end;ids[#ids+1]=id end;table.sort(ids)
        for _,id in ipairs(ids) do
            local request=data.requests[id]
            if type(request)~="table" or request.requestId~=id or (request.state~="RESERVED" and request.state~="UNKNOWN" and request.state~="COMMITTED" and request.state~="RELEASED") then return false,"INVALID_QUOTA_STORE" end
            local resources=Q.resources(request.monthId,request.orderId,request.speciesKey,request.breedId)
            if resources==nil or candidate:available(request.monthId,request.orderId,request.speciesKey,request.breedId)==nil
                or request.fingerprint~=RLMarketData.fingerprint({request.monthId,request.orderId,request.speciesKey,request.breedId}) then return false,"INVALID_QUOTA_STORE" end
            computed.requests[id]=request
            if request.state=="COMMITTED" then delta(computed.pools[request.monthId],"committed",request,1)
            elseif request.state~="RELEASED" then delta(computed.pools[request.monthId],"reserved",request,1) end
        end
        for monthId,pool in pairs(data.pools) do
            if RLMarketData.fingerprint(pool.committed)~=RLMarketData.fingerprint(computed.pools[monthId].committed)
                or RLMarketData.fingerprint(pool.reserved)~=RLMarketData.fingerprint(computed.pools[monthId].reserved) then return false,"QUOTA_COUNTER_DRIFT" end
        end
        for _,request in pairs(computed.requests) do
            local pool=computed.pools[request.monthId]
            local order=pool.definition.orders[request.orderId]
            local species=pool.definition.species[request.speciesKey]
            if (pool.committed.order[request.orderId] or 0)+(pool.reserved.order[request.orderId] or 0)>order.quantityTotal
                or (pool.committed.species[request.speciesKey] or 0)+(pool.reserved.species[request.speciesKey] or 0)>species.monthlyHeadCap
                or (pool.committed.breed[request.breedId] or 0)+(pool.reserved.breed[request.breedId] or 0)>species.perBreedHeadCap then return false,"QUOTA_COUNTER_OVERFLOW" end
        end
        for _,request in pairs(computed.requests) do if request.state=="RESERVED" then request.state="UNKNOWN" end end
        pools,requests=computed.pools,computed.requests
        return true
    end
    return ledger
end
