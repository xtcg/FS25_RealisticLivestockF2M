-- Complete private-stock admission. Pure factory output is never published alone.
-- This service stays dormant until authoritative identity allocation/world scanning
-- and a synchronous durable whole-stock barrier are supplied by its caller.
RLDealerOwnedAdmission={VERSION=1}
local A=RLDealerOwnedAdmission
local copy=RLPlain.copy
local equal=RLPlain.equal
local lifetime={CALF_MILK="UNWEANED",CALF_WEANED="GROWING",HEIFER_REPLACEMENT="REPLACEMENT",FEEDER="STORE",
    HEIFER_READY="BREEDING",HEIFER_IN_CALF="BREEDING",BULL_YOUNG="BREEDING",COW_FIRST="PRODUCTION",COW_YOUNG="PRODUCTION"}
local function snapshot(s)
    local owned,why=RLDealerOwnedStock.export(s.sourceOwners,s.sourceBindings,s.sourceRecordsByOwner,
        s.observedChildren,s.farm.sources,s.farm.clock.months,s.retiredSources)
    if not owned then return nil,why end
    return {farm=RLDealerSourceFarm.export(s.farm),listings=RLDealerListingRegistry.export(s.listings),
        purchase=RLDealerPurchase.export(s.purchase),purchaseLocks=copy(s.purchase.locks),sourceOwnership=owned,
        money=s.money and RLDealerMoneyAdapter.export(s.money) or nil,recoveryRequired=s.recoveryRequired==true}
end
local function hold(s,before,staged,current,why)
    s.recoveryRequired=true
    s.sourceAdmissionEvidence={before=before,staged=staged,current=current,reason=why}
    return nil,why
end
-- checkGlobalIdentities(encodedOwnership) must scan the authoritative world as
-- well as the supplied private inventory, including unborn IDs. Existing private
-- owners are the inventory itself, not external conflicts. A mock returning
-- true does not establish engine identity safety. The barrier must synchronously
-- persist its whole payload; an asynchronous game-save request is insufficient.
function A.admit(store,sourceId,candidate,prepared,ctx)
    if type(store)~="table" or type(ctx)~="table" or ctx.isServer~=true or g_server==nil
        or type(store.sourceOwners)~="table" then return nil,"OWNED_ADMISSION_SERVER_REQUIRED" end
    if store.recoveryRequired or store.purchase.recoveryRequired then return nil,"RECOVERY_REQUIRED" end
    if store.sourceUpdateInProgress then return nil,"SOURCE_UPDATE_IN_PROGRESS" end
    if next(store.purchase.locks)~=nil then return nil,"TRANSACTION_IN_PROGRESS" end
    for _,record in pairs(store.purchase.records) do
        if record.stage~="COMMITTED" and record.stage~="ROLLED_BACK" then return nil,"TRANSACTION_IN_PROGRESS" end
    end
    for _,row in pairs(store.listings.records) do if row.state=="RESERVED" then return nil,"TRANSACTION_IN_PROGRESS" end end
    for _,key in ipairs({"resolveSubType","checkGlobalIdentities","persistBarrier"}) do
        if type(ctx[key])~="function" then return nil,"OWNED_ADMISSION_CAPABILITY:"..key end
    end
    if type(sourceId)~="string" or #sourceId==0 or #sourceId>256 or type(prepared)~="table"
        or RLTradePersistence.check(prepared) or type(prepared.requestId)~="string" then return nil,"ADMISSION_REQUEST" end
    local before,why=snapshot(store);if not before then return nil,why end
    local preparedProof=copy(prepared)
    store.sourceUpdateInProgress=true
    local attempted,stagedSnapshot,published=false,nil,false
    local previousEvidence=store.sourceAdmissionEvidence
    local ok,result,reason=pcall(function()
        local existing
        for _,row in pairs(before.listings.records) do
            local proof=row.payload.admission
            if proof and proof.requestId==preparedProof.requestId then
                if existing then return nil,"ADMISSION_DUPLICATE_PROVENANCE" end
                existing=row
            end
        end
        local proofCursor=existing and existing.payload.admission.originalSourceRecord.cursorMonths or before.farm.clock.months
        local original,failure=RLDealerSourceState.capture(candidate,proofCursor)
        if not original then return nil,failure.reason end
        if type(candidate)~="table" or candidate.eligibility~="VERIFIED_CANDIDATE" then return nil,"CANDIDATE_REQUIRED" end
        local screened;screened,why=RLDealerReplay.screen(candidate);if not screened then return nil,why end
        if existing then
            local proof=existing.payload.admission
            if proof.version~=A.VERSION or existing.payload.sourceId~=sourceId or not equal(proof.prepared,preparedProof)
                or not equal(proof.originalSourceRecord,original) then return nil,"ADMISSION_REQUEST_CONFLICT" end
            return copy(existing),"IDEMPOTENT"
        end
        if before.farm.sources[sourceId] or (before.sourceOwnership.retiredSources or {})[sourceId] then return nil,"SOURCE_ID" end
        for _,row in pairs(before.listings.records) do if row.payload.sourceId==sourceId then return nil,"SOURCE_ID" end end
        local value;value,failure=RLDealerSourceFactory.materialize(candidate,preparedProof,{isServer=true,
            currentCursorMonths=before.farm.clock.months,resolveSubType=ctx.resolveSubType})
        if not value then return nil,failure.reason end
        if not equal(value.preparedEvidence,preparedProof) or not equal(value.sourceRecord,original) then return nil,"ADMISSION_FACTORY_PROOF" end
        local encoded=copy(before.sourceOwnership)
        local owner=encoded.owners[value.sourceOwnerId]
        if owner then
            if owner.capacity~=value.ownership.capacity then return nil,"ADMISSION_OWNER_CAPACITY" end
            for _,animal in ipairs(value.ownership.animals) do owner.animals[#owner.animals+1]=copy(animal) end
            for animalId,sire in pairs(value.ownership.sireContexts) do
                if owner.sireContexts[animalId] then return nil,"ADMISSION_SIRE_CONFLICT" end
                owner.sireContexts[animalId]=copy(sire)
            end
        else encoded.owners[value.sourceOwnerId]=copy(value.ownership) end
        encoded.bindings[sourceId]={ownerId=value.sourceOwnerId,animalId=value.animal.uniqueId}
        local farm=copy(before.farm)
        local added;added,why=RLDealerSourceFarm.add(farm,sourceId,value.sourceRecord);if not added then return nil,why end
        local validation;validation,why=RLDealerOwnedStock.validate(encoded,farm.sources,farm.clock.months)
        if not validation then return nil,why end
        if validation.recoveryRequired then return nil,"SOURCE_OWNERSHIP_UNCERTAIN" end
        for _,entry in pairs(encoded.owners) do
            local occupied=#entry.animals
            for _,animal in ipairs(entry.animals) do occupied=occupied+#(animal.pregnancy and animal.pregnancy.fetuses or {}) end
            if occupied>entry.capacity then return nil,"ADMISSION_OWNER_BIRTH_CAPACITY" end
        end
        local owned;owned,why=RLDealerOwnedStock.restore(encoded,farm.sources,farm.clock.months,ctx.resolveSubType,
            {isServer=true,resolveDiseaseModel=ctx.resolveDiseaseModel})
        if not owned then return nil,why end
        if owned.recoveryRequired then return nil,"SOURCE_OWNERSHIP_UNCERTAIN" end
        local purpose=original.animal.sale and original.animal.sale.purpose
        if not lifetime[purpose] then return nil,"PURPOSE_LIFETIME" end
        local listings=copy(before.listings)
        local row;row,why=RLDealerListingRegistry.createDraft(listings,{sourceId=sourceId,purpose=purpose,source=original.history.source,
            admission={version=A.VERSION,requestId=preparedProof.requestId,prepared=copy(preparedProof),originalSourceRecord=copy(original)}},
            lifetime[purpose],farm.clock.months)
        if not row then return nil,why end
        row,why=RLDealerListingRegistry.list(listings,row.saleId,farm.clock.months);if not row then return nil,why end
        local staged={farm=farm,listings=listings,purchase=store.purchase,money=store.money}
        for _,key in ipairs({"sourceOwners","sourceBindings","sourceRecordsByOwner","observedChildren","retiredSources"}) do staged[key]=owned[key] end
        stagedSnapshot,why=snapshot(staged);if not stagedSnapshot then return nil,why end
        local safe;safe,why=ctx.checkGlobalIdentities(copy(stagedSnapshot.sourceOwnership))
        if safe~=true then return nil,why or "ADMISSION_GLOBAL_IDENTITY" end
        local current=snapshot(store)
        if not current or not equal(before,current) or store.sourceUpdateInProgress~=true then return hold(store,before,stagedSnapshot,current,"SOURCE_SNAPSHOT_CHANGED") end
        local candidateNow=RLDealerSourceState.capture(candidate,proofCursor)
        if not equal(prepared,preparedProof) or not equal(candidateNow,original) then return nil,"ADMISSION_INPUT_CHANGED" end
        attempted=true
        local payload={purchase=copy(stagedSnapshot.purchase),clock=copy(farm.clock),listings=copy(listings),
            recovery={version=1,clockMonths=farm.clock.months,sources=copy(farm.sources),sourceOwnership=copy(stagedSnapshot.sourceOwnership),money=copy(stagedSnapshot.money)}}
        local payloadProof=copy(payload)
        local saved,accepted=pcall(ctx.persistBarrier,payload)
        if not saved or accepted~=true then return hold(store,before,stagedSnapshot,nil,"SOURCE_ADMISSION_BARRIER_UNCERTAIN") end
        if not equal(payload,payloadProof) then return hold(store,before,stagedSnapshot,nil,"SOURCE_ADMISSION_BARRIER_PAYLOAD_CHANGED") end
        safe,why=ctx.checkGlobalIdentities(copy(stagedSnapshot.sourceOwnership))
        if safe~=true then return hold(store,before,stagedSnapshot,nil,why or "ADMISSION_GLOBAL_IDENTITY_AFTER_BARRIER") end
        current=snapshot(store)
        if not current or not equal(before,current) or store.sourceUpdateInProgress~=true then return hold(store,before,stagedSnapshot,current,"SOURCE_SNAPSHOT_CHANGED_AFTER_BARRIER") end
        candidateNow=RLDealerSourceState.capture(candidate,proofCursor)
        if not equal(prepared,preparedProof) or not equal(candidateNow,original) then
            return hold(store,before,stagedSnapshot,current,"ADMISSION_INPUT_CHANGED_AFTER_BARRIER")
        end
        for _,key in ipairs({"farm","listings","sourceOwners","sourceBindings","sourceRecordsByOwner","observedChildren","retiredSources"}) do store[key]=staged[key] end
        published=true
        return copy(row)
    end)
    -- Detect callback-induced original mutation on every exit, including an
    -- exception or rejection before the first barrier was attempted.
    if not published and store.sourceAdmissionEvidence==previousEvidence then
        local readOK,current=pcall(snapshot,store)
        if not readOK or not current or not equal(current,before) or store.sourceUpdateInProgress~=true then
            hold(store,before,stagedSnapshot,readOK and current or nil,"SOURCE_SNAPSHOT_CHANGED")
            if result then result,reason=nil,"SOURCE_SNAPSHOT_CHANGED" end
        elseif attempted and not store.recoveryRequired then hold(store,before,stagedSnapshot,current,"SOURCE_ADMISSION_ERROR") end
    end
    store.sourceUpdateInProgress=nil
    if not ok then return nil,"OWNED_ADMISSION_ERROR" end
    return result,reason
end
