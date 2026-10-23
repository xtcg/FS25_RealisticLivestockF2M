-- Provenance is independent of current owner/container and of animal physiology.
-- Actual purchase amounts stay in their original settlement currency. A later
-- difficulty multiplier never rewrites what the player actually paid.
RLAnimalAcquisition = {}
local A = RLAnimalAcquisition
local function text(v) return type(v)=="string" and v:match("%S")~=nil end
local function nonnegative(v) return RLMarketMoney.finite(v) and v>=0 end
function A.validate(receipt)
    local r,reason=RLMarketData.copy(receipt)
    if r==nil then return nil,reason end
    if type(r)~="table" or r.schemaVersion~=1 or not text(r.animalKey) then return nil,"INVALID_ACQUISITION" end
    if r.originStatus=="OWN_BIRTH_PROVEN" then
        if not text(r.birthEvidenceRef) or not nonnegative(r.bornAtAbsoluteMonths) then return nil,"MISSING_BIRTH_PROOF" end
    elseif r.originStatus=="PURCHASE_RECORDED" then
        for _,key in ipairs({"purchaseReceiptId","purchaseRequestId","sellerChannel","currencyUnit","acquiredSnapshotDigest",
            "configRevision","priceRevision"}) do if not text(r[key]) then return nil,"INVALID_RECEIPT_"..key end end
        if not text(r.formulaVersion) and not (nonnegative(r.formulaVersion) and r.formulaVersion%1==0) then return nil,"INVALID_RECEIPT_formulaVersion" end
        if not nonnegative(r.bodyAmount) or not nonnegative(r.mandatoryFees) or not nonnegative(r.totalPaid)
            or r.totalPaid~=r.bodyAmount+r.mandatoryFees or not nonnegative(r.acquiredAtAbsoluteMonths)
            or not nonnegative(r.difficultyAtPurchase) or r.difficultyAtPurchase==0 or r.currencyBasis~="CURRENT"
            or not nonnegative(r.buyerOwnerFarmId) or r.buyerOwnerFarmId%1~=0 or r.buyerOwnerFarmId==0 then
            return nil,"INVALID_RECEIPT_AMOUNTS"
        end
        if type(r.acquiredState)~="table" or (r.acquiredState.weightKg~=nil and not nonnegative(r.acquiredState.weightKg))
            or (r.acquiredState.stage~=nil and not text(r.acquiredState.stage)) then return nil,"MISSING_ACQUIRED_STATE" end
        if type(r.provenanceChain)~="table" then return nil,"MISSING_PROVENANCE_CHAIN" end
    elseif r.originStatus~="LEGACY_UNKNOWN" and r.originStatus~="QUARANTINED" then
        return nil,"INVALID_ORIGIN_STATUS"
    end
    return r
end
-- Store schema 2 keeps complete batch retry evidence. Receipt schema remains 1.
-- Each animal belongs to exactly one request; purchase requests additionally bind
-- the actual whole-batch spend. No schema-1 store migration is guessed here.
local function dense(list)
    if type(list)~="table" then return false end
    local count=0
    for key in pairs(list) do
        if type(key)~="number" or key%1~=0 or key<1 or key>#list then return false end
        count=count+1
    end
    return count==#list
end
local function evidence(requestId,receipts,actualTotalPaid,kind,settlementOrder)
    if not text(requestId) then return nil,"INVALID_ACQUISITION_REQUEST" end
    local copied,reason=RLMarketData.copy(receipts)
    if copied==nil then return nil,reason end
    if not dense(copied) or #copied==0 or #copied>1000 then return nil,"INVALID_ACQUISITION_BATCH" end
    if kind~="PURCHASE_BATCH" and kind~="PROVENANCE" then return nil,"INVALID_ACQUISITION_KIND" end
    if kind=="PURCHASE_BATCH" and not nonnegative(actualTotalPaid) then return nil,"INVALID_BATCH_TOTAL" end
    if kind=="PROVENANCE" and (#copied~=1 or actualTotalPaid~=nil) then return nil,"INVALID_PROVENANCE_BATCH" end
    local accepted,seenKeys,seenReceiptIds,byKey,originalOrder={},{},{},{},{}
    for _,receipt in ipairs(copied) do
        local r,failure=A.validate(receipt)
        if r==nil then return nil,failure end
        if seenKeys[r.animalKey] then return nil,"DUPLICATE_BATCH_ANIMAL" end
        seenKeys[r.animalKey]=true
        if kind=="PURCHASE_BATCH" then
            if r.originStatus~="PURCHASE_RECORDED" then return nil,"BATCH_REQUIRES_PURCHASE_RECEIPTS" end
            if r.purchaseRequestId~=requestId then return nil,"ACQUISITION_REQUEST_MISMATCH" end
            if seenReceiptIds[r.purchaseReceiptId] then return nil,"DUPLICATE_PURCHASE_RECEIPT" end
            seenReceiptIds[r.purchaseReceiptId]=true
        elseif r.originStatus=="PURCHASE_RECORDED" then return nil,"PURCHASE_REQUIRES_BATCH_EVIDENCE" end
        accepted[#accepted+1]=r
        byKey[r.animalKey]=r;originalOrder[#originalOrder+1]=r.animalKey
    end
    table.sort(accepted,function(a,b) return a.animalKey<b.animalKey end)
    local e={schemaVersion=1,requestId=requestId,kind=kind,animalKeys={},receiptFingerprints={}}
    if kind=="PURCHASE_BATCH" then
        e.actualTotalPaid=actualTotalPaid
        e.settlementBasis="BODY_AND_FEES_IN_PAYMENT_ORDER"
        e.settlementOrder=settlementOrder and RLMarketData.copy(settlementOrder) or originalOrder
        if not dense(e.settlementOrder) or #e.settlementOrder~=#accepted then return nil,"INVALID_SETTLEMENT_ORDER" end
        local seen,body,fees={},0,0
        for _,key in ipairs(e.settlementOrder) do
            local r=byKey[key]
            if r==nil or seen[key] then return nil,"INVALID_SETTLEMENT_ORDER" end
            seen[key]=true
            body=body+r.bodyAmount;fees=fees+r.mandatoryFees
        end
        e.bodySubtotal,e.feeSubtotal=body,fees
        if not nonnegative(body) or not nonnegative(fees) or body+fees~=actualTotalPaid then return nil,"BATCH_TOTAL_MISMATCH" end
    end
    for _,r in ipairs(accepted) do
        e.animalKeys[#e.animalKeys+1]=r.animalKey
        e.receiptFingerprints[r.animalKey]=assert(RLMarketData.fingerprint(r))
        if kind=="PURCHASE_BATCH" then
            -- A single batch settles one owner's money in one currency.
            local first=accepted[1]
            if r.currencyUnit~=first.currencyUnit or r.currencyBasis~=first.currencyBasis
                or r.buyerOwnerFarmId~=first.buyerOwnerFarmId then return nil,"MIXED_BATCH_SETTLEMENT" end
        end
    end
    e.fingerprint=assert(RLMarketData.fingerprint(e))
    return e,accepted
end
function A.new()
    local animals,requests,receiptIds={},{},{}
    local ledger={}
    local function record(requestId,receipts,actualTotalPaid,kind)
        local previousRequest=requests[requestId]
        local e,accepted=evidence(requestId,receipts,actualTotalPaid,kind,previousRequest and previousRequest.settlementOrder)
        if e==nil then return false,accepted end
        if previousRequest then
            local same=previousRequest.fingerprint==e.fingerprint
            return same,not same and "ACQUISITION_REQUEST_MISMATCH" or nil
        end
        -- Validate every collision before committing any animal or request.
        for _,r in ipairs(accepted) do
            if animals[r.animalKey]~=nil then return false,"PROVENANCE_ALREADY_RECORDED" end
            if r.purchaseReceiptId~=nil and receiptIds[r.purchaseReceiptId] then return false,"PURCHASE_RECEIPT_ALREADY_RECORDED" end
        end
        for _,r in ipairs(accepted) do
            animals[r.animalKey]=r
            if r.originStatus=="PURCHASE_RECORDED" then receiptIds[r.purchaseReceiptId]=true end
        end
        requests[requestId]=e
        return true
    end
    function ledger:recordBatch(requestId,receipts,actualTotalPaid)
        return record(requestId,receipts,actualTotalPaid,"PURCHASE_BATCH")
    end
    function ledger:record(requestId,receipt)
        local r,reason=A.validate(receipt)
        if r==nil then return false,reason end
        if r.originStatus=="PURCHASE_RECORDED" then return self:recordBatch(requestId,{r},r.totalPaid) end
        return record(requestId,{r},nil,"PROVENANCE")
    end
    function ledger:lookup(animalKey)
        if not text(animalKey) then return nil,"INVALID_ANIMAL_KEY" end
        return assert(RLMarketData.copy(animals[animalKey] or {schemaVersion=1,animalKey=animalKey,originStatus="LEGACY_UNKNOWN"}))
    end
    function ledger:export() return assert(RLMarketData.copy({schemaVersion=2,animals=animals,requests=requests})) end
    function ledger:restore(saved)
        if next(animals) or next(requests) then return false,"ACQUISITION_STORE_NOT_EMPTY" end
        local copied,reason=RLMarketData.copy(saved)
        if copied==nil then return false,reason end
        if type(copied)~="table" or copied.schemaVersion~=2 or type(copied.animals)~="table" or type(copied.requests)~="table" then return false,"INVALID_ACQUISITION_STORE" end
        for key in pairs(copied) do if key~="schemaVersion" and key~="animals" and key~="requests" then return false,"INVALID_ACQUISITION_STORE" end end
        local restoredAnimals,restoredRequests,restoredReceiptIds,referenced={},{},{},{}
        for key,receipt in pairs(copied.animals) do
            local valid=A.validate(receipt)
            if valid==nil or key~=valid.animalKey then return false,"INVALID_ACQUISITION_STORE" end
            if valid.originStatus=="PURCHASE_RECORDED" then
                if restoredReceiptIds[valid.purchaseReceiptId] then return false,"INVALID_ACQUISITION_STORE" end
                restoredReceiptIds[valid.purchaseReceiptId]=true
            end
            restoredAnimals[key]=valid
        end
        for id,stored in pairs(copied.requests) do
            if not text(id) or type(stored)~="table" or stored.requestId~=id or stored.schemaVersion~=1
                or not dense(stored.animalKeys) or #stored.animalKeys==0 then return false,"INVALID_ACQUISITION_STORE" end
            local receipts={}
            for _,key in ipairs(stored.animalKeys) do
                if not text(key) or referenced[key] or restoredAnimals[key]==nil then return false,"INVALID_ACQUISITION_STORE" end
                referenced[key]=true
                receipts[#receipts+1]=restoredAnimals[key]
            end
            local rebuilt=evidence(id,receipts,stored.actualTotalPaid,stored.kind,stored.settlementOrder)
            if rebuilt==nil or RLMarketData.fingerprint(rebuilt)~=RLMarketData.fingerprint(stored) then return false,"INVALID_ACQUISITION_STORE" end
            restoredRequests[id]=rebuilt
        end
        for key in pairs(restoredAnimals) do if not referenced[key] then return false,"INVALID_ACQUISITION_STORE" end end
        animals,requests,receiptIds=restoredAnimals,restoredRequests,restoredReceiptIds
        return true
    end
    return ledger
end
function A.sourceCap(receipt,current,policy)
    local r,reason=A.validate(receipt)
    if r==nil then return nil,reason end
    local acceptedCurrent,currentReason=RLMarketData.copy(current)
    if type(acceptedCurrent)~="table" then return nil,currentReason or "SOURCE_CONTEXT_MISMATCH" end
    current=acceptedCurrent
    local acceptedPolicy,policyReason=RLMarketData.copy(policy)
    if policy~=nil and type(acceptedPolicy)~="table" then return nil,policyReason or "SOURCE_POLICY_REQUIRED" end
    policy=acceptedPolicy
    if current.animalKey~=r.animalKey then return nil,"SOURCE_CONTEXT_MISMATCH" end
    if r.originStatus=="OWN_BIRTH_PROVEN" then return {limited=false,reason="OWN_BIRTH_PROVEN"} end
    if r.originStatus~="PURCHASE_RECORDED" then return nil,"SOURCE_PROOF_REQUIRED" end
    if type(current)~="table" or current.animalKey~=r.animalKey or current.currencyUnit~=r.currencyUnit
        or not nonnegative(current.absoluteMonths) or current.absoluteMonths<r.acquiredAtAbsoluteMonths
        or (current.weightKg~=nil and not nonnegative(current.weightKg)) then return nil,"SOURCE_CONTEXT_MISMATCH" end
    if type(policy)~="table" then return nil,"SOURCE_POLICY_REQUIRED" end
    for _,key in ipairs({"minimumHoldingMonths","minimumGainKg","minimumGainRate","minimumSpreadAbs","minimumSpreadRate"}) do
        if not nonnegative(policy[key]) then return nil,"INVALID_SOURCE_POLICY" end
    end
    if policy.minimumSpreadRate>1 or policy.minimumHoldingMonths<=0 or policy.minimumGainKg<=0 or policy.minimumGainRate<=0 then
        return nil,"INVALID_SOURCE_POLICY"
    end
    local old=r.acquiredState
    local hasWeight=nonnegative(current.weightKg) and nonnegative(old.weightKg) and old.weightKg>0
    local gain=hasWeight and current.weightKg-old.weightKg or nil
    -- Both elapsed risk AND material weight gain are required by this policy.
    -- Rename, revision, owner, clock step and difficulty alone release nothing.
    local release=current.absoluteMonths-r.acquiredAtAbsoluteMonths>=policy.minimumHoldingMonths
        and hasWeight and gain>=policy.minimumGainKg and gain/old.weightKg>=policy.minimumGainRate
    if release then return {limited=false,reason="MATERIAL_CHANGE_PROVEN"} end
    return { limited=true,maximumBeforeTransport=math.max(0,r.totalPaid-math.max(policy.minimumSpreadAbs,r.totalPaid*policy.minimumSpreadRate)),
        reason="RECENT_PURCHASE_CAP",purchaseReceiptId=r.purchaseReceiptId }
end
