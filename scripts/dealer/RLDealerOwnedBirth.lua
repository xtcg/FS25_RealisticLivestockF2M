-- Calendar continuation across actual source calving. No engine hook is installed.
-- Pure feeding is staged; every real birth has a whole-inventory PREPARED/COMMITTED
-- barrier. Once a barrier is attempted, failure retains evidence and closes recovery.
RLDealerOwnedBirth={VERSION=1}
local C=RLDealerOwnedBirth
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local function equal(a,b) return RLTradePersistence.canonical(a)==RLTradePersistence.canonical(b) end
local fields={"age","breed","gender","isIndividual","isCastrated","genetics","health","isParent","birthCount",
    "isPregnant","reproduction","input","output","weight","targetWeight","rlGrowth","bodyCondition","rlFeedGain",
    "rlHealthCarry","monthsSinceLastBirth","isLactating","isDead"}
local function install(animal,record)
    for _,key in ipairs(fields) do rawset(animal,key,copy(record.animal[key])) end
    animal.rlHistoryReplay=nil
end
local function snapshot(store)
    local owned,why=RLDealerOwnedStock.export(store.sourceOwners,store.sourceBindings,store.sourceRecordsByOwner,
        store.observedChildren,store.farm.sources,store.farm.clock.months,store.retiredSources)
    if not owned then return nil,why end
    return {clock=RLDealerClock.export(store.farm.clock),listings=RLDealerListingRegistry.export(store.listings),
        purchase=RLDealerPurchase.export(store.purchase),purchaseLocks=copy(store.purchase.locks),sources=copy(store.farm.sources),sourceOwnership=owned}
end
local function pending(record,age,days,sourceId,ctx)
    local replay,why=RLDealerSourceState.restore(record,ctx.resolveSubType)
    if not replay then return nil,why.reason end
    local ok,entry=pcall(ctx.resolveEntry,record.animal.subType,sourceId)
    if not ok then return nil,"SOURCE_RULES" end
    local result;result,why=RLDealerReplay.runToSourceBirth(replay,age,{daysPerMonth=days,entry=entry})
    if not result then return nil,why.reason end
    return result
end
local function fetalContexts(replay)
    for index,event in ipairs(replay.history.events) do
        if event.kind=="CONCEPTION" and event.atMonths==replay.sourceBirthBoundary.conceptionMonths then return replay.fetalSelections[index] end
    end
end
function C.advance(store,segments,ctx)
    if type(store)~="table" or type(ctx)~="table" or ctx.isServer~=true or type(store.sourceOwners)~="table" then return nil,"OWNED_BIRTH_SERVER_REQUIRED" end
    if store.recoveryRequired or store.purchase.recoveryRequired then return nil,"RECOVERY_REQUIRED" end
    if store.sourceUpdateInProgress then return nil,"SOURCE_UPDATE_IN_PROGRESS" end
    if next(store.purchase.locks)~=nil then return nil,"TRANSACTION_IN_PROGRESS" end
    for _,key in ipairs({"resolveSubType","resolveEntry","eligible","persistBarrier","birthDate"}) do
        if type(ctx[key])~="function" then return nil,"OWNED_BIRTH_CAPABILITY:"..key end
    end
    for _,transaction in pairs(store.purchase.records) do
        if transaction.stage~="COMMITTED" and transaction.stage~="ROLLED_BACK" then return nil,"TRANSACTION_IN_PROGRESS" end
    end
    for _,row in pairs(store.listings.records) do if row.state=="RESERVED" then return nil,"TRANSACTION_IN_PROGRESS" end end
    local clock=RLDealerClock.export(store.farm.clock)
    local finish,why=RLDealerClock.advanceSegments(clock,segments)
    if not finish then return nil,why end
    for _,segment in ipairs(segments) do
        if segment.daysPerMonth<1 or segment.daysPerMonth>31 or segment.daysPerMonth%1~=0 then return nil,"MONTH_LENGTH" end
    end
    if finish==store.farm.clock.months then return {months=finish,births=0} end
    local before;before,why=snapshot(store);if not before then return nil,why end
    store.sourceUpdateInProgress=true
    local stage,barrierStarted,births,lastBarrier,invariantReason=nil,false,0,nil,nil
    local ok,result,reason=pcall(function()
        local farm,failure=RLDealerSourceFarm.restore(store.farm);if not farm then return nil,failure end
        local owned;owned,failure=RLDealerOwnedStock.restore(before.sourceOwnership,before.sources,before.clock.months,
            ctx.resolveSubType,{isServer=true,resolveDiseaseModel=ctx.resolveDiseaseModel})
        if not owned then return nil,failure end
        if owned.recoveryRequired then return nil,"SOURCE_OWNERSHIP_UNCERTAIN" end
        stage={farm=farm,listings=copy(store.listings),purchase=copy(store.purchase)}
        for _,key in ipairs({"sourceOwners","sourceBindings","sourceRecordsByOwner","observedChildren","retiredSources"}) do stage[key]=owned[key] end
        local function barrier(phase,event)
            local evidence,error=snapshot(stage);if not evidence then return nil,error end
            local current=snapshot(store)
            if not current or not equal(current,before) then invariantReason="SOURCE_SNAPSHOT_CHANGED";return nil,invariantReason end
            barrierStarted=true
            lastBarrier={phase=phase,event=copy(event),snapshot=copy(evidence)}
            local payload=copy({purchase=evidence.purchase,clock=evidence.clock,listings=evidence.listings,
                recovery={version=1,clockMonths=evidence.clock.months,sources=evidence.sources,sourceOwnership=evidence.sourceOwnership,
                    money=store.money and RLDealerMoneyAdapter.export(store.money) or nil}})
            local payloadProof=copy(payload)
            lastBarrier.payload=payloadProof
            local saved,accepted=pcall(ctx.persistBarrier,payload,phase,copy(event))
            if not saved or accepted~=true then return nil,"SOURCE_BIRTH_BARRIER_UNCERTAIN" end
            if RLTradePersistence.check(payload,RLDealerPersistence.LIMITS) or not equal(payload,payloadProof) then
                invariantReason="SOURCE_BIRTH_BARRIER_PAYLOAD_CHANGED"
                return nil,invariantReason
            end
            current=snapshot(store)
            if not current or not equal(current,before) then invariantReason="SOURCE_SNAPSHOT_CHANGED_AFTER_BARRIER";return nil,invariantReason end
            return true
        end
        -- Every existing pregnancy can calve only once in this update. Check aggregate
        -- capacity before any RNG, without assuming a death will free a place.
        local schedule,capacity,events={},{},{}
        local keys={};for sourceId in pairs(farm.sources) do keys[#keys+1]=sourceId end;table.sort(keys)
        for _,sourceId in ipairs(keys) do
            local record=farm.sources[sourceId]
            local life,error=RLDealerReplay.getSourceLifecycle(record.history,record.observedSourceEvents,record.ageMonths)
            if not life then return nil,error end
            if life.conceptionMonths~=nil then
                local age=life.conceptionMonths+record.history.durationMonths
                local cursor=record.birthOriginMonths+age
                if cursor<=finish then
                    if cursor<=farm.clock.months then return nil,"SOURCE_BIRTH_CURSOR" end
                    local binding=stage.sourceBindings[sourceId]
                    local owner=stage.sourceOwners[binding.ownerId]
                    local dam=owner.byId[binding.animalId]
                    if type(dam.pregnancy)~="table" or type(dam.pregnancy.pregnancies)~="table" then return nil,"SOURCE_BIRTH_STATE" end
                    capacity[binding.ownerId]=(capacity[binding.ownerId] or #owner.animals)+#dam.pregnancy.pregnancies
                    if capacity[binding.ownerId]>owner.capacity then return nil,"SOURCE_BIRTH_CAPACITY" end
                    local date=ctx.birthDate(sourceId,cursor,age)
                    if type(date)~="table" then return nil,"SOURCE_BIRTH_DATE" end
                    date=copy(date);date.cursorMonths,date.atAgeMonths=cursor,age
                    events[binding.ownerId]=events[binding.ownerId] or {}
                    if type(date.eventId)~="string" or events[binding.ownerId][date.eventId] or owner.birthJournal[date.eventId] then return nil,"SOURCE_BIRTH_REQUEST" end
                    events[binding.ownerId][date.eventId]=true
                    schedule[#schedule+1]={sourceId=sourceId,cursor=cursor,age=age,date=date}
                end
            end
        end
        table.sort(schedule,function(a,b) if a.cursor~=b.cursor then return a.cursor<b.cursor end;return a.sourceId<b.sourceId end)
        local nextBirth=1
        local feedContext={isServer=true,resolveSubType=ctx.resolveSubType,resolveEntry=ctx.resolveEntry,
            resolveDiseaseModel=ctx.resolveDiseaseModel,eligible=ctx.eligible,persistBarrier=function() return true end}
        local elapsed=0
        for _,segment in ipairs(segments) do
            elapsed=elapsed+segment.hours/(24*segment.daysPerMonth)
            local endpoint=before.clock.months+elapsed
            local upcoming=schedule[nextBirth]
            -- Align only accumulated floating-point roundoff to a known term that
            -- the complete requested interval actually reaches. Never integrate
            -- to term-minus-epsilon or infer an earlier birth from a short interval.
            if upcoming and upcoming.cursor>endpoint and upcoming.cursor<=finish
                and upcoming.cursor-endpoint<1e-10 then endpoint=upcoming.cursor end
            while schedule[nextBirth] and schedule[nextBirth].cursor<=endpoint do
                local boundary=schedule[nextBirth].cursor
                local delta=boundary-stage.farm.clock.months
                local due={}
                while schedule[nextBirth] and schedule[nextBirth].cursor==boundary do due[#due+1]=schedule[nextBirth];nextBirth=nextBirth+1 end
                local pendingBySource={}
                for _,item in ipairs(due) do
                    local replay,error=pending(stage.farm.sources[item.sourceId],item.age,segment.daysPerMonth,item.sourceId,ctx)
                    if not replay then return nil,error end
                    pendingBySource[item.sourceId]=replay
                    local binding=stage.sourceBindings[item.sourceId]
                    local owner=stage.sourceOwners[binding.ownerId];local dam=owner.byId[binding.animalId]
                    install(dam,replay)
                    local valid,denied=RLDealerSourceReproduction.check(owner,dam,item.date,{isServer=true,
                        persistPrepared=function() return true end,persistCommitted=function() return true end,expectedFetalContexts=fetalContexts(replay)})
                    install(dam,stage.farm.sources[item.sourceId])
                    if not valid then return nil,denied.reason end
                end
                -- Due dams retain their prior recorded bodies until their own journal
                -- exists. Other animals, including previously born calves, reach term.
                for sourceId,record in pairs(stage.farm.sources) do
                    if not pendingBySource[sourceId] then
                        local replay,error=RLDealerSourceState.restore(record,ctx.resolveSubType);if not replay then return nil,error.reason end
                        local progressed;progressed,error=RLDealerReplay.resume(replay,record.ageMonths+delta,
                            {daysPerMonth=segment.daysPerMonth,entry=ctx.resolveEntry(record.animal.subType,sourceId)})
                        if not progressed then return nil,error.reason end
                        local moved;moved,error=RLDealerSourceState.advanceCursor(record,progressed,boundary);if not moved then return nil,error.reason end
                        stage.farm.sources[sourceId]=moved
                        local binding=stage.sourceBindings[sourceId]
                        install(stage.sourceOwners[binding.ownerId].byId[binding.animalId],moved)
                        stage.sourceRecordsByOwner[binding.ownerId][binding.animalId]=copy(moved)
                    end
                end
                for ownerId,children in pairs(stage.observedChildren) do
                    for animalId,record in pairs(children) do
                        if record.cursorMonths~=stage.farm.clock.months then return nil,"OBSERVED_CHILD_CLOCK" end
                        local moved,error=RLDealerObservedGrowth.resume(record,{{hours=delta*24*segment.daysPerMonth,daysPerMonth=segment.daysPerMonth}},ctx.resolveSubType)
                        if not moved then return nil,error.reason end
                        if math.abs(moved.cursorMonths-boundary)>1e-8 then return nil,"OBSERVED_CHILD_CLOCK" end
                        moved.cursorMonths=boundary;children[animalId]=moved
                        install(stage.sourceOwners[ownerId].byId[animalId],moved)
                    end
                end
                stage.farm.clock.months=boundary
                for _,item in ipairs(due) do
                    local sourceId=item.sourceId;local prior=stage.farm.sources[sourceId];local replay=pendingBySource[sourceId]
                    local binding=stage.sourceBindings[sourceId];local owner=stage.sourceOwners[binding.ownerId];local dam=owner.byId[binding.animalId]
                    install(dam,replay)
                    local born,error=RLDealerSourceReproduction.execute(owner,dam,item.date,{isServer=true,expectedFetalContexts=fetalContexts(replay),
                        persistPrepared=function(event) return barrier("PREPARED",event) end,
                        persistCommitted=function(event)
                            local observed,denied=RLDealerSourceReproduction.captureObserved(prior,replay,owner,dam,event.eventId,boundary)
                            if not observed then return false,denied.reason end
                            stage.farm.sources[sourceId]=observed;stage.sourceRecordsByOwner[binding.ownerId][binding.animalId]=copy(observed)
                            stage.observedChildren[binding.ownerId]=stage.observedChildren[binding.ownerId] or {}
                            for _,newborn in ipairs(event.result.newborns) do
                                local child,failed=RLDealerObservedGrowth.capture(owner.byId[newborn.uniqueId],boundary,event)
                                if not child then return false,failed.reason end
                                stage.observedChildren[binding.ownerId][newborn.uniqueId]=child
                            end
                            if event.result.parentDied then
                                local retired,failed=RLDealerOwnedStock.stageRetirement(stage,sourceId,event.eventId)
                                if not retired then return false,failed end
                                stage.farm.sources=retired.sources;stage.sourceBindings=retired.sourceBindings
                                stage.retiredSources=retired.retiredSources;stage.listings=retired.listings
                            end
                            return barrier("COMMITTED",event)
                        end})
                    if not born then return nil,error.reason end
                    births=births+1
                end
            end
            local hours=(endpoint-stage.farm.clock.months)*24*segment.daysPerMonth
            if hours>0 then
                local progressed,error=RLDealerOwnedProgress.advance(stage,{{hours=hours,daysPerMonth=segment.daysPerMonth}},feedContext)
                if not progressed then return nil,error end
            end
        end
        for _,row in ipairs(RLDealerListingRegistry.listRecords(stage.listings,"LISTED")) do
            local source=stage.farm.sources[row.payload.sourceId]
            if not source then return nil,"LISTING_SOURCE_MISSING" end
            local progressed,error=RLDealerListingRegistry.progress(stage.listings,row.saleId,stage.farm.clock.months,
                function(payload) return payload end,function(_,current) return ctx.eligible(source,current) end)
            if not progressed then return nil,error end
        end
        -- Intermediate pure feeding does not consume this controller's one newest
        -- replenishment checkpoint. Only the completed whole interval publishes it.
        stage.farm.clock.lastCheckpoint=before.clock.lastCheckpoint
        local checkpoint,skipped=RLDealerClock.checkpoint(stage.farm.clock)
        local saved,error=barrier("COMPLETE");if not saved then return nil,error end
        for _,key in ipairs({"farm","listings","sourceOwners","sourceBindings","sourceRecordsByOwner","observedChildren","retiredSources"}) do store[key]=stage[key] end
        return {months=store.farm.clock.months,births=births,replenishAtMonths=checkpoint,skippedCheckpoints=skipped}
    end)
    store.sourceUpdateInProgress=nil
    if barrierStarted or invariantReason then
        if not ok or not result then
            store.recoveryRequired=true;store.sourceBirthEvidence={before=before,staged=stage,attempted=lastBarrier}
        end
    end
    if not ok then return nil,"OWNED_BIRTH_ERROR" end
    if not result and invariantReason then return nil,invariantReason end
    return result,reason
end
