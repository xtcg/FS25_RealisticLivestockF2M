-- Atomic no-RNG source rearing for real private inventory. Actual calving is an
-- explicit boundary: this controller never crosses it by synthesizing a birth.
RLDealerOwnedProgress = { VERSION=1 }
local U=RLDealerOwnedProgress
local copy=RLPlain.copy
local function equal(a,b) return RLTradePersistence.canonical(a)==RLTradePersistence.canonical(b) end
local physical={"age","breed","gender","isIndividual","isCastrated","genetics","health","isParent","birthCount",
    "isPregnant","reproduction","input","output","weight","targetWeight","rlGrowth","bodyCondition","rlFeedGain",
    "rlHealthCarry","monthsSinceLastBirth","isLactating","isDead"}
local cleared={"rlHistoryReplay","rlGrowthDropped","rlGrowthCurve","rlGrowthPeek","rlFeedStepTick","rlFeedStepOwner",
    "rlFeedLastMilk","rlFeedIntake","rlFeedPlanLiters","rlMilkPaid","rlNutrition","rlMilk","rlInfoRows"}
local function install(animal,record)
    -- Preserve real identity, true pregnancy and model-backed disease objects.
    for _,key in ipairs(physical) do rawset(animal,key,copy(record.animal[key])) end
    for _,key in ipairs(cleared) do rawset(animal,key,nil) end
end
local function snapshot(store)
    local owned,why=RLDealerOwnedStock.export(store.sourceOwners,store.sourceBindings,store.sourceRecordsByOwner,
        store.observedChildren,store.farm.sources,store.farm.clock.months,store.retiredSources)
    if not owned then return nil,why end
    return {version=U.VERSION,clock=RLDealerClock.export(store.farm.clock),listings=RLDealerListingRegistry.export(store.listings),
        purchase=RLDealerPurchase.export(store.purchase),purchaseLocks=copy(store.purchase.locks),sources=copy(store.farm.sources),sourceOwnership=owned}
end
function U.advance(store,segments,ctx)
    if type(store)~="table" or type(ctx)~="table" or ctx.isServer~=true or type(store.sourceOwners)~="table" then return nil,"OWNED_PROGRESS_SERVER_REQUIRED" end
    if store.recoveryRequired or store.purchase.recoveryRequired then return nil,"RECOVERY_REQUIRED" end
    if store.sourceUpdateInProgress then return nil,"SOURCE_UPDATE_IN_PROGRESS" end
    if next(store.purchase.locks)~=nil then return nil,"TRANSACTION_IN_PROGRESS" end
    for _,key in ipairs({"resolveSubType","resolveEntry","eligible","persistBarrier"}) do
        if type(ctx[key])~="function" then return nil,"OWNED_PROGRESS_CAPABILITY:"..key end
    end
    for _,transaction in pairs(store.purchase.records) do
        if transaction.stage~="COMMITTED" and transaction.stage~="ROLLED_BACK" then return nil,"TRANSACTION_IN_PROGRESS" end
    end
    for _,row in pairs(store.listings.records) do if row.state=="RESERVED" then return nil,"TRANSACTION_IN_PROGRESS" end end
    local checkClock=RLDealerClock.export(store.farm.clock)
    local finish,calendarReason=RLDealerClock.advanceSegments(checkClock,segments)
    if not finish then return nil,calendarReason end
    for _,segment in ipairs(segments) do
        if segment.daysPerMonth<1 or segment.daysPerMonth>31 or segment.daysPerMonth%1~=0 then return nil,"MONTH_LENGTH" end
    end
    if finish==store.farm.clock.months then return {months=finish} end
    local before,why=snapshot(store);if not before then return nil,why end
    store.sourceUpdateInProgress=true
    local barrierStarted=false
    local ok,result,reason=pcall(function()
        local farm,failure=RLDealerSourceFarm.restore(RLDealerSourceFarm.export(store.farm));if not farm then return nil,failure end
        local owned;owned,failure=RLDealerOwnedStock.restore(before.sourceOwnership,before.sources,before.clock.months,
            ctx.resolveSubType,{isServer=true,resolveDiseaseModel=ctx.resolveDiseaseModel})
        if not owned then return nil,failure end
        if owned.recoveryRequired then return nil,"SOURCE_OWNERSHIP_UNCERTAIN" end
        local finish;finish,failure=RLDealerSourceFarm.advanceSegments(farm,segments,ctx.resolveSubType,ctx.resolveEntry)
        if not finish then return nil,failure end
        for sourceId,record in pairs(farm.sources) do
            local binding=owned.sourceBindings[sourceId]
            local animal=owned.sourceOwners[binding.ownerId].byId[binding.animalId]
            install(animal,record);owned.sourceRecordsByOwner[binding.ownerId][binding.animalId]=copy(record)
        end
        for ownerId,children in pairs(owned.observedChildren) do
            for animalId,record in pairs(children) do
                if record.cursorMonths~=before.clock.months then return nil,"OBSERVED_CHILD_CLOCK" end
                local nextRecord,error=RLDealerObservedGrowth.resume(record,segments,ctx.resolveSubType)
                if not nextRecord then return nil,error.reason end
                if math.abs(nextRecord.cursorMonths-finish)>1e-8 then return nil,"OBSERVED_CHILD_CLOCK" end
                -- The shared calendar uses segment-by-segment addition. Normalize
                -- only its floating-point roundoff, never an elapsed interval.
                nextRecord.cursorMonths=finish
                install(owned.sourceOwners[ownerId].byId[animalId],nextRecord)
                children[animalId]=nextRecord
            end
        end
        local staged={farm=farm,listings=copy(before.listings),purchase=store.purchase,
            sourceOwners=owned.sourceOwners,sourceBindings=owned.sourceBindings,sourceRecordsByOwner=owned.sourceRecordsByOwner,
            observedChildren=owned.observedChildren,retiredSources=owned.retiredSources}
        for _,row in ipairs(RLDealerListingRegistry.listRecords(staged.listings,"LISTED")) do
            local source=staged.farm.sources[row.payload.sourceId]
            if not source then return nil,"LISTING_SOURCE_MISSING" end
            local advanced;advanced,failure=RLDealerListingRegistry.progress(staged.listings,row.saleId,finish,
                function(payload) return payload end,function(_,current) return ctx.eligible(source,current) end)
            if not advanced then return nil,failure end
        end
        local checkpoint,skipped=RLDealerClock.checkpoint(farm.clock)
        local after;after,failure=snapshot(staged);if not after then return nil,failure end
        local current=snapshot(store)
        if not current or not equal(current,before) then
            store.recoveryRequired=true;store.sourceProgressEvidence={before=before,staged=after,current=current}
            return nil,"SOURCE_SNAPSHOT_CHANGED"
        end
        -- No physical assets or RNG changed before this complete evidence barrier.
        -- An unknown write can leave WAL ahead of the game save, so retain both.
        barrierStarted=true
        local payload=copy({purchase=after.purchase,clock=after.clock,listings=after.listings,
            recovery={version=1,clockMonths=finish,sources=after.sources,sourceOwnership=after.sourceOwnership,
                money=store.money and RLDealerMoneyAdapter.export(store.money) or nil}})
        local payloadProof=copy(payload)
        local attempted={snapshot=copy(after),payload=payloadProof}
        local saved,accepted=pcall(ctx.persistBarrier,payload)
        if not saved or accepted~=true then
            store.recoveryRequired=true;store.sourceProgressEvidence={before=before,staged=after,attempted=attempted}
            return nil,"SOURCE_PROGRESS_BARRIER_UNCERTAIN"
        end
        -- The callback owns only its detached payload, never the evidence that
        -- publication was staged against. A changed successful write is uncertain.
        if RLTradePersistence.check(payload,RLDealerPersistence.LIMITS) or not equal(payload,payloadProof) then
            store.recoveryRequired=true;store.sourceProgressEvidence={before=before,staged=after,attempted=attempted}
            return nil,"SOURCE_PROGRESS_BARRIER_PAYLOAD_CHANGED"
        end
        current=snapshot(store)
        if not current or not equal(current,before) then
            store.recoveryRequired=true;store.sourceProgressEvidence={before=before,staged=after,current=current}
            return nil,"SOURCE_SNAPSHOT_CHANGED_AFTER_BARRIER"
        end
        for _,key in ipairs({"farm","listings","sourceOwners","sourceBindings","sourceRecordsByOwner","observedChildren","retiredSources"}) do store[key]=staged[key] end
        return {months=finish,replenishAtMonths=checkpoint,skippedCheckpoints=skipped}
    end)
    store.sourceUpdateInProgress=nil
    if not ok then
        if barrierStarted then store.recoveryRequired=true;store.sourceProgressEvidence=store.sourceProgressEvidence or {before=before} end
        return nil,"OWNED_PROGRESS_ERROR"
    end
    return result,reason
end
