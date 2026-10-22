-- Read-only preflight and ephemeral single-animal credentials. This service
-- never reserves quota, removes an animal, pays money or advances physiology.
-- Confirmation here only produces a server plan for the transaction coordinator.
RLBrokerOrderService={}
local S=RLBrokerOrderService
local function text(v) return type(v)=="string" and v:match("%S")~=nil end
local function copy(v) return assert(RLMarketData.copy(v)) end
function S.new(deps)
    if type(deps)~="table" or not text(deps.serverEpoch) then return nil,"SERVER_EPOCH_REQUIRED" end
    for _,key in ipairs({"authorize","readOrder","capture","eligibilityContext","price","nowMs","previewReady","settlementReady"}) do
        if type(deps[key])~="function" then return nil,"MISSING_BROKER_DEPENDENCY_"..key end
    end
    local credentials,sequence,lastTime={},0,nil
    local service={}
    local function now()
        local time=deps.nowMs()
        if not RLMarketMoney.finite(time) or time<0 or (lastTime~=nil and time<lastTime) then return nil,"NON_MONOTONIC_QUOTE_CLOCK" end
        lastTime=time;return time
    end
    local function canonicalRequest(request)
        local data,reason=RLMarketData.copy(request)
        if data==nil then return nil,reason end
        if type(data)~="table" or not text(data.orderId) or not text(data.animalKey) or not text(data.sourceRef)
            or (data.transportMode~="PICKUP" and data.transportMode~="SELF_DELIVERY") then return nil,"INVALID_BROKER_REQUEST" end
        local count=0;for _ in pairs(data) do count=count+1 end
        if count~=4 then return nil,"UNKNOWN_BROKER_REQUEST_FIELD" end
        return data
    end
    local function preflight(principal,request)
        local actor,invalidActor=RLMarketData.copy(principal)
        if type(actor)~="table" or not text(actor.userId) or not RLMarketMoney.finite(actor.farmId)
            or actor.farmId<=0 or actor.farmId%1~=0 then return nil,invalidActor or "INVALID_BROKER_PRINCIPAL" end
        principal=actor
        local req,reason=canonicalRequest(request)
        if req==nil then return nil,reason end
        if deps.authorize(copy(principal),copy(req))~=true then return nil,"BROKER_PERMISSION_DENIED" end
        local order,why=deps.readOrder(req.orderId)
        if order==nil then return nil,why or "ORDER_UNAVAILABLE" end
        order,why=RLMarketData.copy(order)
        if order==nil then return nil,why end
        if type(order)~="table" or order.orderId~=req.orderId or type(order.rules)~="table"
            or not text(order.rules.revision) then return nil,"INVALID_PUBLISHED_ORDER" end
        local compiled=RLBrokerConditionPackage.compile(order.rules)
        if compiled==nil or compiled.revision~=order.rules.revision then return nil,"PUBLISHED_RULES_REVISION_MISMATCH" end
        for _,key in ipairs({"monthId","configRevision","priceRevision","classRevision","traitMappingRevision"}) do
            if not text(order[key]) then return nil,"INVALID_PUBLISHED_ORDER_"..key end
        end
        if order.formulaVersion==nil or order.priceBasis==nil then return nil,"INCOMPLETE_ORDER_PRICE_BASIS" end
        local snapshot,location=deps.capture(copy(principal),copy(req))
        if snapshot==nil then return nil,location or "ANIMAL_UNAVAILABLE" end
        local valid,invalid=RLMarketSchema.validateSnapshot(snapshot)
        if not valid then return nil,invalid end
        if snapshot.identityKey~=req.animalKey then return nil,"ANIMAL_SCOPE_MISMATCH" end
        if snapshot.classRevision~=order.classRevision or snapshot.traitMappingRevision~=order.traitMappingRevision then return nil,"ORDER_MAPPING_REVISION_MISMATCH" end
        snapshot=copy(snapshot);location=copy(location)
        if deps.previewReady(copy(snapshot),copy(order),copy(req))~=true then return nil,"BROKER_PREVIEW_NOT_READY" end
        local context=copy(deps.eligibilityContext(copy(principal),copy(req),copy(snapshot),copy(order),copy(location)))
        local eligibility=RLBrokerEligibility.evaluate(snapshot,order.rules,context)
        local result={request=req,snapshot=snapshot,order=order,location=location,eligibility=eligibility,
            context=context,sourceRef=req.sourceRef}
        -- Complete diagnostics are still returned when ineligible, with no
        -- attempt to manufacture a tradable zero price for an unknown capability.
        if not eligibility.eligible then return result end
        local price,failure=deps.price(copy(snapshot),copy(order),copy(context))
        if price==nil then result.priceReason=failure or "BROKER_PRICE_UNAVAILABLE";return result end
        result.price=price
        return RLMarketData.copy(result)
    end
    local function guarded(fn,...)
        local ok,result,reason=pcall(fn,...)
        if not ok then return nil,"BROKER_SERVICE_ERROR" end
        return result,reason
    end
    function service:preflight(principal,request)
        return guarded(function()
            local result,reason=preflight(principal,request)
            if result==nil then return nil,reason end
            return RLMarketData.copy(result)
        end)
    end
    local function selected(result)
        if result.price==nil then return nil,result.priceReason or "BROKER_PRICE_UNAVAILABLE" end
        local price=result.price
        if price.sourceVerified~=true or price.settlementReady~=true then return nil,"SOURCE_PROOF_REQUIRED" end
        local pickup=result.request.transportMode=="PICKUP"
        if not (pickup and price.pickupAvailable or not pickup and price.selfDeliveryAvailable) then return nil,"NONPOSITIVE_BROKER_NET" end
        if type(result.location)~="table" or result.location[result.request.transportMode]~=true then return nil,"TRANSPORT_SOURCE_UNSUPPORTED" end
        local money=pickup and price.pickup or price.selfDelivery
        if type(money)~="table" or not RLMarketMoney.finite(money.netToPlayer) or money.netToPlayer<=0 then return nil,"INVALID_SETTLEMENT_AMOUNT" end
        local recomputed=assert(RLMarketMoney.new()):breakdown(money.bodyAmount,money.fees,money.bonuses,"IN")
        if recomputed==nil or money.currencyBasis~="CURRENT" or money.settlementDirection~="IN"
            or recomputed.netToPlayer~=money.netToPlayer or recomputed.totalFees~=money.totalFees
            or recomputed.totalBonuses~=money.totalBonuses then return nil,"INVALID_SETTLEMENT_BREAKDOWN" end
        return money
    end
    local function settlement(result,money)
        return {money=money,orderId=result.request.orderId,monthId=result.order.monthId,transportMode=result.request.transportMode,
            rulesRevision=result.order.rules.revision,classRevision=result.snapshot.classRevision,
            traitMappingRevision=result.snapshot.traitMappingRevision,priceRevision=result.order.priceRevision,
            configRevision=result.order.configRevision,formulaVersion=result.order.formulaVersion,
            priceBasis=result.order.priceBasis,sourceVerified=result.price.sourceVerified}
    end
    function service:preview(principal,request)
        return guarded(function()
            local principalKey,why=RLMarketData.fingerprint(principal)
            if principalKey==nil then return nil,why end
            local time,reason=now();if time==nil then return nil,reason end
            for id,credential in pairs(credentials) do
                if time>=credential.expiresAt then credentials[id]=nil
                end
            end
            local result,failure=preflight(principal,request)
            if result==nil then return nil,failure end
            if not result.eligibility.eligible then return nil,"BROKER_INELIGIBLE",result end
            local money,invalid=selected(result);if money==nil then return nil,invalid end
            local issued,clockFailure=now();if issued==nil then return nil,clockFailure end
            -- One pending confirmation per caller/session. Issuing the next
            -- valid credential replaces their previous selection atomically.
            for id,old in pairs(credentials) do if old.principalKey==principalKey then credentials[id]=nil end end
            if sequence>=2147483647 then return nil,"QUOTE_SEQUENCE_EXHAUSTED" end
            sequence=sequence+1
            local id=deps.serverEpoch..":broker:"..sequence
            local record={credential=id,serverEpoch=deps.serverEpoch,principalKey=principalKey,
                requestFingerprint=assert(RLMarketData.fingerprint(result.request)),request=result.request,
                settlementFingerprint=assert(RLMarketData.fingerprint(settlement(result,money))),
                eligibilityFingerprint=assert(RLMarketData.fingerprint(result.eligibility)),
                snapshot=result.snapshot,monthId=result.order.monthId,money=money,expiresAt=issued+15000}
            credentials[id]=assert(RLMarketData.copy(record))
            return RLMarketData.copy(record)
        end)
    end
    function service:validateConfirmation(principal,credentialId,request)
        return guarded(function()
            local credential=credentials[credentialId]
            if credential==nil then return nil,"UNKNOWN_OR_EXPIRED_BROKER_QUOTE" end
            if RLMarketData.fingerprint(principal)~=credential.principalKey then return nil,"BROKER_PERMISSION_DENIED" end
            local req,why=canonicalRequest(request);if req==nil then return nil,why end
            if RLMarketData.fingerprint(req)~=credential.requestFingerprint then return nil,"BROKER_QUOTE_REQUEST_MISMATCH" end
            local time,reason=now();if time==nil then return nil,reason end
            if time>=credential.expiresAt then return nil,"BROKER_QUOTE_EXPIRED" end
            local result,failure=preflight(principal,req)
            if result==nil then return nil,failure end
            if not result.eligibility.eligible then return nil,"BROKER_NO_LONGER_ELIGIBLE" end
            local money,invalid=selected(result);if money==nil then return nil,invalid end
            if RLMarketData.fingerprint(settlement(result,money))~=credential.settlementFingerprint then return nil,"BROKER_REQUOTE_REQUIRED" end
            if deps.settlementReady(copy(result.snapshot),copy(result.order),copy(req))~=true then return nil,"BROKER_SETTLEMENT_NOT_READY" end
            local finalTime,clockFailure=now();if finalTime==nil then return nil,clockFailure end
            if finalTime>=credential.expiresAt then return nil,"BROKER_QUOTE_EXPIRED" end
            return RLMarketData.copy({request=req,currentSnapshot=result.snapshot,order=result.order,money=money,
                credential=credentialId,monthId=result.order.monthId,settlementFingerprint=credential.settlementFingerprint,
                sourceRef=req.sourceRef,principalKey=credential.principalKey,expiresAt=credential.expiresAt})
        end)
    end
    return service
end
