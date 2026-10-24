-- Synchronous single-head Broker coordinator. This is a pure injected protocol;
-- it does not register engine hooks or claim a filesystem checkpoint is atomic.
RLBrokerTransaction={}
local T=RLBrokerTransaction
local D=RLMarketData
local function text(v)return type(v)=="string" and v:match("%S")~=nil end
local function integer(v,min)return type(v)=="number" and v==v and v%1==0 and v>=min and v<2^52 end
local function copy(v)return assert(D.copy(v))end
local function fp(v)return D.fingerprint(v)end
local function exact(a,b)local x=fp(a);return x~=nil and x==fp(b)end
local function invoke(fn,...)local ok,a,b=pcall(fn,...);if not ok then return nil,"BROKER_CALLBACK_ERROR" end;return a,b end
local terminal={COMMITTED=true,ROLLED_BACK=true}
local states={PREPARED=true,REMOVED=true,PAYMENT_PENDING=true,COMMITTED=true,ROLLED_BACK=true,UNKNOWN=true}
function T.requestId(epoch,sequence)
    if not text(epoch) or not integer(sequence,1) then return nil,"INVALID_REQUEST_ID" end
    return epoch..":broker-tx:"..string.format("%.0f",sequence)
end
local function namespaced(id,epoch)
    if not text(id) or not text(epoch) then return false end
    local prefix=epoch..":broker-tx:"
    local suffix=id:sub(#prefix+1)
    return id:sub(1,#prefix)==prefix and suffix:match("^[1-9][0-9]*$")~=nil and integer(tonumber(suffix),1)
end
local function binding(principal,credential,request)return fp({principal=principal,credential=credential,request=request})end
local function resources(plan,evidence,principal)
    if type(plan)~="table" or type(plan.request)~="table" or type(principal)~="table" then return nil,"INVALID_PLAN" end
    local snapshot=plan.currentSnapshot
    if type(snapshot)~="table" or snapshot.identityKey~=plan.request.animalKey or not text(snapshot.speciesKey)
        or not text(snapshot.breedId) then return nil,"INVALID_PLAN_ANIMAL" end
    if type(evidence)~="table" or evidence.version~=1 or evidence.kind~="BROKER_SOURCE" or not text(evidence.sourceId)
        or evidence.identityKey~=snapshot.identityKey or evidence.ownerFarmId~=principal.farmId
        or (evidence.sourceKind~="PEN" and evidence.sourceKind~="TRAILER") or type(evidence.animal)~="table"
        or type(evidence.members)~="table" or type(evidence.queues)~="table" or evidence.reloadRestoreSupported~=false then return nil,"INVALID_SOURCE_EVIDENCE" end
    if (plan.request.transportMode=="PICKUP" and evidence.sourceKind~="PEN") or (plan.request.transportMode=="SELF_DELIVERY" and evidence.sourceKind~="TRAILER") then return nil,"SOURCE_TRANSPORT_MISMATCH" end
    if type(evidence.queues.add)~="table" or type(evidence.queues.remove)~="table" or next(evidence.queues.add)~=nil or next(evidence.queues.remove)~=nil then return nil,"SOURCE_QUEUE_NOT_EMPTY" end
    if evidence.sourceKind=="TRAILER" and (type(evidence.locationEvidence)~="table" or not text(evidence.locationEvidence.pointId)) then return nil,"SOURCE_LOCATION_REQUIRED" end
    local seen,count,selected={},0,0
    for index,member in pairs(evidence.members)do
        if not integer(index,1) or index>#evidence.members or type(member)~="table" or not text(member.identityKey) or seen[member.identityKey]
            or type(member.state)~="table" or not integer(member.engineId,0) then return nil,"INVALID_SOURCE_MEMBER" end
        seen[member.identityKey]=true;count=count+1
        if member.identityKey==evidence.identityKey then
            if not exact(member.state,evidence.animal) then return nil,"SOURCE_SELECTED_STATE_MISMATCH" end
            selected=selected+1
        end
    end
    if count~=#evidence.members or selected~=1 then return nil,"INCOMPLETE_SOURCE_MEMBERS" end
    local portable=copy(evidence);portable.fingerprint=nil
    if evidence.fingerprint~=fp(portable) then return nil,"INVALID_SOURCE_FINGERPRINT" end
    local list,reason=RLBrokerQuota.resources(plan.monthId,plan.request.orderId,snapshot.speciesKey,snapshot.breedId)
    if list==nil then return nil,reason end
    for _,pair in ipairs({{"ANIMAL",snapshot.identityKey},{"WALLET",string.format("%.0f",principal.farmId)},{"CONTAINER",evidence.sourceKind..":"..evidence.sourceId}})do
        list[#list+1]=assert(RLMarketResourceLock.resource(pair[1],pair[2]))
    end
    table.sort(list);return list
end
T.resources=resources
local function validPlan(plan,principal,credential,request)
    return type(plan)=="table" and exact(plan.request,request) and plan.credential==credential
        and plan.principalKey==fp(principal) and text(plan.monthId) and type(plan.order)=="table"
        and plan.order.orderId==request.orderId and plan.order.monthId==plan.monthId and type(plan.money)=="table"
        and type(plan.money.netToPlayer)=="number" and plan.money.netToPlayer>0 and plan.money.netToPlayer<math.huge
        and type(plan.expiresAt)=="number" and plan.expiresAt>=0 and plan.expiresAt<math.huge
end
-- Used by the persistence envelope as its payload validator. It validates the
-- whole quota ledger and every record/resource/action cross reference.
function T.validateDocument(saved)
    local doc,reason=D.copy(saved)
    if type(doc)~="table" or doc.schemaVersion~=1 or doc.kind~="BROKER_TRANSACTIONS" or not text(doc.serverEpoch)
        or not integer(doc.sequence,0) or type(doc.records)~="table" or type(doc.quota)~="table" then return false,reason or "INVALID_BROKER_DOCUMENT" end
    local allowed={schemaVersion=true,kind=true,serverEpoch=true,sequence=true,records=true,quota=true}
    for key in pairs(doc)do if not allowed[key] then return false,"UNKNOWN_BROKER_DOCUMENT_FIELD" end end
    local probe=RLBrokerQuota.new();if not probe:restore(doc.quota) then return false,"INVALID_BROKER_QUOTA" end
    local lockProbe=RLMarketResourceLock.new()
    for id,r in pairs(doc.records)do
        if type(r)~="table" or r.requestId~=id or not namespaced(id,r.serverEpoch) or not states[r.state]
            or not text(r.stage) or type(r.principal)~="table" or not text(r.principal.userId) or not integer(r.principal.farmId,1)
            or not text(r.credential) or type(r.request)~="table" or r.requestFingerprint~=binding(r.principal,r.credential,r.request)
            or not validPlan(r.plan,r.principal,r.credential,r.request) or type(r.paymentReceipts)~="table" then return false,"INVALID_BROKER_RECORD" end
        local recordFields={requestId=true,serverEpoch=true,principal=true,credential=true,request=true,requestFingerprint=true,plan=true,resources=true,sourceEvidence=true,paymentReceipts=true,state=true,stage=true,removal=true,restoration=true,rollbackProof=true,outcome=true,historicalSettled=true,reconciliationEvidence=true}
        for field in pairs(r)do if not recordFields[field] then return false,"UNKNOWN_BROKER_RECORD_FIELD" end end
        local requestFields={orderId=true,animalKey=true,sourceRef=true,transportMode=true}
        for field in pairs(r.request)do if not requestFields[field] then return false,"UNKNOWN_BROKER_REQUEST_FIELD" end end
        if not text(r.request.orderId) or not text(r.request.animalKey) or not text(r.request.sourceRef) or (r.request.transportMode~="PICKUP" and r.request.transportMode~="SELF_DELIVERY") then return false,"INVALID_BROKER_REQUEST" end
        local expected=resources(r.plan,r.sourceEvidence,r.principal)
        if expected==nil or not exact(expected,r.resources) then return false,"INVALID_BROKER_RESOURCES" end
        local q=doc.quota.requests[id]
        if type(q)~="table" or q.monthId~=r.plan.monthId or q.orderId~=r.request.orderId
            or q.speciesKey~=r.plan.currentSnapshot.speciesKey or q.breedId~=r.plan.currentSnapshot.breedId then return false,"BROKER_QUOTA_SCOPE_MISMATCH" end
        if (r.state=="COMMITTED" and q.state~="COMMITTED") or (r.state=="ROLLED_BACK" and q.state~="RELEASED")
            or (not terminal[r.state] and q.state=="RELEASED") then return false,"BROKER_QUOTA_STATE_MISMATCH" end
        local receipt=r.paymentReceipts[id..":payment"]
        for paymentId,p in pairs(r.paymentReceipts)do
            if paymentId~=id..":payment" or type(p)~="table" or p.version~=1 or p.kind~="BROKER" or p.paymentId~=paymentId
                or type(p.action)~="table" or p.action.kind~="BROKER" or p.action.paymentId~=paymentId or p.action.requestId~=id
                or p.action.farmId~=r.principal.farmId or p.action.netAmount~=r.plan.money.netToPlayer
                or p.actionFingerprint~=fp(p.action) or (p.status~="APPLIED" and p.status~="NOT_APPLIED" and p.status~="UNKNOWN")
                or (p.stage~="BEFORE" and p.stage~="AFTER") or type(p.before)~="table" then return false,"INVALID_BROKER_PAYMENT" end
            if p.stage=="AFTER" and type(p.after)~="table" then return false,"INVALID_BROKER_PAYMENT_AFTER" end
        end
        if r.state=="COMMITTED" and (type(receipt)~="table" or receipt.status~="APPLIED" or receipt.stage~="AFTER"
            or type(r.removal)~="table" or r.removal.status~="APPLIED" or r.removal.removedKey~=r.request.animalKey) then return false,"INCOMPLETE_BROKER_COMMIT" end
        if r.state=="ROLLED_BACK" and (type(r.restoration)~="table" or r.restoration.verified~=true or type(r.rollbackProof)~="table" or r.rollbackProof.status~="NOT_APPLIED") then return false,"INCOMPLETE_BROKER_ROLLBACK" end
        if terminal[r.state] then
            if type(r.outcome)~="table" or r.outcome.status~=r.state or r.outcome.requestId~=id then return false,"INVALID_BROKER_OUTCOME" end
        elseif not lockProbe:acquire(id,r.resources) then return false,"CONFLICTING_BROKER_RECORDS" end
    end
    for id in pairs(doc.quota.requests)do if doc.records[id]==nil then return false,"ORPHAN_BROKER_QUOTA_REQUEST" end end
    return true
end
function T.new(deps)
    if type(deps)~="table" or not text(deps.serverEpoch) then return nil,"SERVER_EPOCH_REQUIRED" end
    for _,key in ipairs({"authorize","prepareSource","createMoneyAdapter","nowMs","ready","saveFence"})do
        if type(deps[key])~="function" then return nil,"MISSING_BROKER_DEPENDENCY_"..key end
    end
    for _,key in ipairs({"orderService","locks","quota","source","store"})do if type(deps[key])~="table" then return nil,"MISSING_BROKER_DEPENDENCY_"..key end end
    local records,sequence,busy,recovery,lastTime={},0,false,false,nil
    local runtime={}
    local function document(quota)return {schemaVersion=1,kind="BROKER_TRANSACTIONS",serverEpoch=deps.serverEpoch,sequence=sequence,records=copy(records),quota=quota or deps.quota:export()}end
    local function persist(quota)
        sequence=sequence+1
        local doc=document(quota)
        local valid=T.validateDocument(doc);if not valid then recovery=true;return false end
        local wrote=invoke(deps.store.write,copy(doc))
        if wrote~=true then recovery=true;return false end
        local read=invoke(deps.store.read)
        if not exact(doc,read) then recovery=true;return false end
        return true
    end
    local function authorized(principal,request)
        if type(principal)~="table" or not text(principal.userId) or not integer(principal.farmId,1) then return false end
        return invoke(deps.authorize,copy(principal),copy(request))==true
    end
    local function unknown(r,reason)
        recovery=true;r.state="UNKNOWN";r.stage=reason or "UNKNOWN"
        deps.locks:markUnknown(r.requestId);deps.quota:markUnknown(r.requestId)
        return {status="UNKNOWN",requestId=r.requestId,reason=r.stage,keepLocked=true}
    end
    local function releaseUnprepared(id,reason)deps.locks:release(id);return nil,reason end
    local function clockValid(expiresAt)
        local now=invoke(deps.nowMs)
        if type(now)~="number" or now~=now or now<0 or now==math.huge or (lastTime and now<lastTime) then return false,"NON_MONOTONIC_BROKER_CLOCK" end
        lastTime=now
        return now<expiresAt,"BROKER_QUOTE_EXPIRED"
    end
    -- Terminal quota transitions are staged separately, so a failed terminal
    -- barrier never releases a live reservation before durable evidence exists.
    local function finish(r,state,reason,reconciled)
        local staged=RLBrokerQuota.new();if not staged:restore(deps.quota:export()) then return unknown(r,"QUOTA_STAGE_FAILED") end
        local accepted
        if state=="COMMITTED" then
            accepted=staged:reconcileCommit(r.requestId,reconciled or {requestId=r.requestId,monthId=r.plan.monthId,outcome="COMMITTED",animalRemoved=true,moneyApplied=true,proofRef="LIVE_OBSERVED:"..r.requestId})
            -- An already committed counter can occur only in explicit recovery.
        else accepted=staged:release(r.requestId,true) end
        if not accepted then return unknown(r,"QUOTA_TERMINAL_FAILED") end
        r.state=state;r.stage=state;r.outcome={status=state,requestId=r.requestId,reason=reason}
        if not persist(staged:export()) then return unknown(r,"TERMINAL_DURABILITY_UNKNOWN") end
        if state=="COMMITTED" then
            if reconciled then accepted=deps.quota:reconcileCommit(r.requestId,reconciled) else accepted=deps.quota:commit(r.requestId) end
        else accepted=deps.quota:release(r.requestId,reconciled~=nil) end
        if not accepted then return unknown(r,"LIVE_QUOTA_TERMINAL_FAILED") end
        deps.locks:release(r.requestId,reconciled~=nil)
        return copy(r.outcome)
    end
    local function rollback(r,handle,reason,proof)
        if recovery then return unknown(r,"DURABILITY_UNKNOWN") end
        local restored=invoke(deps.source.restore,handle)
        if type(restored)~="table" or restored.status~="APPLIED" or invoke(deps.source.verifyRestored,handle)~=true then return unknown(r,"RESTORE_UNKNOWN") end
        r.restoration={verified=true,kind="EXACT_LIVE_OBJECT"};r.rollbackProof=copy(proof)
        return finish(r,"ROLLED_BACK",reason)
    end
    function runtime:lookup(principal,requestId,credential,request)
        local actor,req=D.copy(principal),D.copy(request)
        if actor==nil or req==nil or not authorized(actor,req) then return nil,"BROKER_PERMISSION_DENIED" end
        local r=records[requestId]
        if r==nil then return nil,"UNKNOWN_BROKER_REQUEST" end
        if binding(actor,credential,req)~=r.requestFingerprint then return nil,"BROKER_REQUEST_MISMATCH" end
        if terminal[r.state] then local result=copy(r.outcome);result.historicalSettled=r.historicalSettled;return result end
        return {status="UNKNOWN",requestId=requestId,keepLocked=true,reason="RECONCILIATION_REQUIRED"}
    end
    local function confirm(principal,id,credential,request)
        local actor,req=D.copy(principal),D.copy(request)
        if actor==nil or req==nil or not text(id) or not text(credential) or not authorized(actor,req) then return nil,"BROKER_PERMISSION_DENIED" end
        if records[id] then return runtime:lookup(actor,id,credential,req) end
        if not namespaced(id,deps.serverEpoch) then return nil,"STALE_BROKER_EPOCH" end
        if recovery or invoke(deps.ready)~=true or invoke(deps.saveFence)~=true then return nil,"BROKER_NOT_READY" end
        local plan,reason=deps.orderService:validateConfirmation(copy(actor),credential,copy(req))
        if not validPlan(plan,actor,credential,req) then return nil,reason or "INVALID_BROKER_PLAN" end
        local handle,why=invoke(deps.prepareSource,copy(plan),copy(actor))
        if handle==nil then return nil,why or "BROKER_SOURCE_UNAVAILABLE" end
        local evidence=invoke(deps.source.portableEvidence,handle)
        local names,failure=resources(plan,evidence,actor)
        if names==nil then return nil,failure end
        local acquired,locked=deps.locks:acquire(id,names);if not acquired then return nil,locked end
        local final,invalid=deps.orderService:validateConfirmation(copy(actor),credential,copy(req))
        if not validPlan(final,actor,credential,req) then return releaseUnprepared(id,invalid or "INVALID_BROKER_PLAN") end
        local current,currentReason=invoke(deps.prepareSource,copy(final),copy(actor))
        if current==nil then return releaseUnprepared(id,currentReason or "BROKER_SOURCE_UNAVAILABLE") end
        local portable=invoke(deps.source.portableEvidence,current)
        local finalNames=resources(final,portable,actor)
        if not exact(names,finalNames) then return releaseUnprepared(id,"BROKER_SOURCE_CHANGED") end
        if invoke(deps.ready)~=true or invoke(deps.saveFence)~=true then return releaseUnprepared(id,"BROKER_NOT_READY") end
        local timely,expired=clockValid(final.expiresAt)
        if not timely then return releaseUnprepared(id,expired) end
        local reserved,reserveReason=deps.quota:reserve(id,final.monthId,req.orderId,final.currentSnapshot.speciesKey,final.currentSnapshot.breedId,deps.locks)
        if reserved==nil then return releaseUnprepared(id,reserveReason) end
        local r={requestId=id,serverEpoch=deps.serverEpoch,principal=actor,credential=credential,request=req,
            requestFingerprint=binding(actor,credential,req),plan=copy(final),resources=names,sourceEvidence=copy(portable),paymentReceipts={},state="PREPARED",stage="PREPARED"}
        records[id]=r
        if not persist() then return unknown(r,"PREPARED_DURABILITY_UNKNOWN") end
        local sourceCallbackActive=true
        local removed=invoke(deps.source.remove,current,function(proof)
            if not busy or not sourceCallbackActive or r.state~="PREPARED" or r.stage~="PREPARED" or not exact(proof,r.sourceEvidence) then return false end
            r.stage="REMOVE_BARRIER";return persist()
        end)
        sourceCallbackActive=false
        if recovery then return unknown(r,"REMOVE_DURABILITY_UNKNOWN") end
        if type(removed)~="table" or removed.status=="UNKNOWN" then return unknown(r,"REMOVE_UNKNOWN") end
        if removed.status=="NOT_APPLIED" then return rollback(r,current,"REMOVAL_NOT_APPLIED",removed) end
        local observed=invoke(deps.source.observe,current)
        if removed.status~="APPLIED" or type(observed)~="table" or observed.status~="APPLIED" then return unknown(r,"REMOVAL_NOT_PROVEN") end
        r.removal=copy(observed);r.state="REMOVED";r.stage="REMOVED"
        if not persist() then return unknown(r,"REMOVED_DURABILITY_UNKNOWN") end
        local moneyCallbackActive=false
        local money=invoke(deps.createMoneyAdapter,function(receipt)
            if not busy or not moneyCallbackActive or (r.state~="REMOVED" and r.state~="PAYMENT_PENDING") then return false end
            local p=D.copy(receipt)
            if type(p)~="table" or p.paymentId~=id..":payment" then return false end
            local prior=r.paymentReceipts[p.paymentId]
            if (p.stage=="BEFORE" and prior~=nil) or (p.stage=="AFTER" and (type(prior)~="table" or prior.stage~="BEFORE"))
                or (p.stage~="BEFORE" and p.stage~="AFTER") then return false end
            r.paymentReceipts[p.paymentId]=p;r.state="PAYMENT_PENDING";r.stage="PAYMENT_"..p.stage
            return persist()
        end)
        if type(money)~="table" or type(money.pay)~="function" then return unknown(r,"MONEY_ADAPTER_UNAVAILABLE") end
        moneyCallbackActive=true
        local payment=invoke(money.pay,money,{paymentId=id..":payment",requestId=id,farmId=actor.farmId,netAmount=final.money.netToPlayer})
        moneyCallbackActive=false
        if recovery then return unknown(r,"PAYMENT_DURABILITY_UNKNOWN") end
        if type(payment)~="table" or payment.status=="UNKNOWN" then return unknown(r,"PAYMENT_UNKNOWN") end
        if payment.status=="NOT_APPLIED" then return rollback(r,current,"PAYMENT_NOT_APPLIED",payment) end
        local finalRemoval=invoke(deps.source.observe,current)
        if payment.status~="APPLIED" or type(finalRemoval)~="table" or finalRemoval.status~="APPLIED" then return unknown(r,"FINAL_ASSET_PROOF_UNKNOWN") end
        r.removal=copy(finalRemoval)
        return finish(r,"COMMITTED")
    end
    function runtime:confirm(...)
        if busy then return nil,"BROKER_SYNCHRONOUS_FENCE" end
        busy=true
        local ok,result,reason=pcall(confirm,...)
        busy=false
        if not ok then
            -- Unexpected dependency errors after acquisition must never unlock.
            recovery=true
            for _,r in pairs(records)do if not terminal[r.state] then unknown(r,"BROKER_COORDINATOR_ERROR") end end
            return nil,"BROKER_COORDINATOR_ERROR"
        end
        return result,reason
    end
    function runtime:export()return document()end
    function runtime:getStatus()return recovery and "RECOVERY_REQUIRED" or "READY" end
    function runtime:restore(saved,validatedCheckpoint)
        if busy or next(records)~=nil then return false,"BROKER_STORE_NOT_EMPTY" end
        local doc=D.copy(saved);local proof=D.copy(validatedCheckpoint)
        if type(proof)~="table" or proof.verified~=true or not text(proof.checkpointRef) or proof.documentFingerprint~=fp(doc) then return false,"VALIDATED_CHECKPOINT_REQUIRED" end
        local valid,reason=T.validateDocument(doc);if not valid then return false,reason end
        -- Validate all global holds before touching the shared lock store.
        local probe=RLMarketResourceLock.new()
        if not probe:restore(deps.locks:snapshot()) then return false,"INVALID_EXISTING_LOCKS" end
        for id,r in pairs(doc.records)do if not terminal[r.state] and not probe:acquire(id,r.resources) then return false,"RECOVERY_RESOURCE_CONFLICT" end end
        if next(deps.quota:export().pools)~=nil then return false,"QUOTA_STORE_NOT_EMPTY" end
        if not deps.quota:restore(doc.quota) then return false,"INVALID_BROKER_QUOTA" end
        for id,r in pairs(doc.records)do
            if terminal[r.state] then r.historicalSettled=proof.checkpointRef
            else deps.locks:acquire(id,r.resources);deps.locks:markUnknown(id);r.state="UNKNOWN";r.stage="RESTORED_REQUIRES_RECONCILIATION";recovery=true end
        end
        records,sequence=doc.records,doc.sequence
        return true
    end
    -- Evidence is accepted only through the trusted server verifier, never a
    -- client status. A restored source cannot be reconstructed by this module.
    function runtime:reconcile(id,evidence)
        if busy then return nil,"BROKER_SYNCHRONOUS_FENCE" end
        if type(deps.verifyReconciliation)~="function" then return nil,"RECONCILIATION_VERIFIER_REQUIRED" end
        busy=true
        local function reconcile()
            local r=records[id];local proof=D.copy(evidence)
            if r==nil or terminal[r.state] or type(proof)~="table" or proof.requestId~=id or proof.monthId~=r.plan.monthId or not text(proof.proofRef)
                or invoke(deps.verifyReconciliation,copy(r),copy(proof))~=true then return nil,"RECONCILIATION_PROOF_REQUIRED" end
            if proof.outcome=="COMMITTED" and proof.animalRemoved==true and proof.moneyApplied==true then
                -- Verifier supplies complete observations, not booleans alone.
                if type(proof.paymentReceipt)~="table" or type(proof.removal)~="table" then return nil,"RECONCILIATION_RECEIPTS_REQUIRED" end
                r.paymentReceipts[id..":payment"]=copy(proof.paymentReceipt);r.removal=copy(proof.removal)
            elseif proof.outcome=="ROLLED_BACK" and proof.animalRestored==true and proof.moneyNotApplied==true then
                r.restoration={verified=true,kind="EXPLICIT_CHECKPOINT_RECONCILIATION"}
                r.rollbackProof={status="NOT_APPLIED",proofRef=proof.proofRef}
            else return nil,"RECONCILIATION_PROOF_REQUIRED" end
            r.reconciliationEvidence=copy(proof)
            return finish(r,proof.outcome,"EXPLICIT_RECONCILIATION",proof)
        end
        local ok,result,reason=pcall(reconcile)
        busy=false
        if not ok then recovery=true;return nil,"RECONCILIATION_ERROR" end
        if result~=nil then
            recovery=false;for _,entry in pairs(records)do if not terminal[entry.state] then recovery=true end end
        end
        return result,reason
    end
    return runtime
end
