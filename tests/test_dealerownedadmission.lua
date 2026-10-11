loadMod("tests/dealerownedfixture.lua")
loadMod("scripts/core/RLConstants.lua")
loadAnimalSection("function Animal:getIdentifiers()", "function Animal:compareIdentifiers")
loadMod("scripts/dealer/RLDealerHandoff.lua")
loadMod("scripts/dealer/RLDealerSourceFactory.lua")
loadMod("scripts/dealer/RLDealerOwnedAdmission.lua")
local A,K=RLDealerOwnedAdmission,RLDealerOwnedStock
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local function equal(a,b) return RLTradePersistence.canonical(a)==RLTradePersistence.canonical(b) end
local function owned(s) return assert(K.export(s.sourceOwners,s.sourceBindings,s.sourceRecordsByOwner,s.observedChildren,s.farm.sources,s.farm.clock.months,s.retiredSources)) end
local function fixture(opts,pregnantCandidate)
    local s,ctx=DealerOwnedFixture.new(opts)
    local seed=DealerReplaySim.seed("HOLSTEIN","female",1)
    local entry=RLDealerStockPolicy.getEntry(RLDealerStockPolicy.getConfig(),seed.subType,"COW")
    local purpose=RLDealerStockPolicy.findPurpose(entry,"female",pregnantCandidate and "HEIFER_IN_CALF" or "HEIFER_READY")
    local history=DealerReplaySim.history(seed,pregnantCandidate and 20.25 or 20.5,pregnantCandidate and "NORMAL_PRODUCTION" or nil,
        pregnantCandidate and {{kind="CONCEPTION",atMonths=17.125,parity=1}} or nil);history.source="DAIRY_HERD"
    local candidate=assert(RLDealerReplay.evaluate(seed,history,entry,purpose,
        {maxBuyAge=72,weaningMonth=3,union={{0,72}},lactates=true},{daysPerMonth=1,pregnancySubTypes=pregnantCandidate and {[4]={seed.subType}} or nil}))
    local p={version=1,requestId="ADMISSION-1",sourceOwnerId="NEW-OWNER",capacity=10,
        adult={uniqueId="NEW-DAM",farmId="NEW-HERD",subType=seed.subType.name,
            birthday={day=12,month=2,year=2025,country=4,lastAgeMonth=10},deathEnabled=true,diseases={}},
        evidence={version=1,requestId="ADMISSION-1",selectionId="FIXED-SELECTION"}}
    if pregnantCandidate then
        p.pregnancy={duration=10,expected={day=4,month=5,year=2027},fetuses={{uniqueId="FIXED-FETUS",farmId=p.adult.farmId,
            subType=seed.subType.name,genetics={metabolism=2.1,quality=2.25,productivity=1.8,fertility=0,health=0.9}}}}
        p.sire={uniqueId="FIXED-SIRE",farmId="SIRE-HERD",breed="HOLSTEIN",subType=seed.subType.name,
            genetics={metabolism=1,quality=1,productivity=1,fertility=1,health=1}}
    end
    ctx.checkGlobalIdentities=function() return true end
    g_server={}
    return s,candidate,p,ctx
end

do
    local s,c,p,ctx=fixture({child=true,pregnant=true})
    local before=owned(s);p.sourceOwnerId="OWNER"
    local calls,scans=0,0
    ctx.checkGlobalIdentities=function(encoded) scans=scans+1;return #encoded.owners.OWNER.animals==3 end
    ctx.persistBarrier=function(payload)
        calls=calls+1
        check("owned admission: barrier contains whole stock while original objects remain unpublished",s.farm.sources.new==nil
            and payload.recovery.sources.source~=nil and payload.recovery.sources.new~=nil
            and #payload.recovery.sourceOwnership.owners.OWNER.animals==3)
        return true
    end
    local rng=math.random;math.random=function() error("admission must not sample") end
    local row,why=A.admit(s,"new",c,p,ctx);math.random=rng
    assert(row,why)
    local after=owned(s)
    check("owned admission: same owner merge preserves real child physiology and complete journals",#s.sourceOwners.OWNER.animals==3
        and equal(before.owners.OWNER.animals[1],after.owners.OWNER.animals[1])
        and equal(before.owners.OWNER.animals[2],after.owners.OWNER.animals[2])
        and equal(before.observedChildren,after.observedChildren) and equal(before.owners.OWNER.birthJournal,after.owners.OWNER.birthJournal)
        and equal(before.owners.OWNER.observedBirths,after.owners.OWNER.observedBirths)
        and equal(before.owners.OWNER.sireContexts,after.owners.OWNER.sireContexts))
    check("owned admission: all real members bind restored cluster and source records together",s.sourceOwners.OWNER.byId["NEW-DAM"].clusterSystem==s.sourceOwners.OWNER.clusterSystem
        and s.sourceBindings.new.ownerId=="OWNER" and s.sourceRecordsByOwner.OWNER["NEW-DAM"]~=nil and row.state=="LISTED"
        and calls==1 and scans==2 and s.sourceUpdateInProgress==nil)
    check("owned admission: durable proof contains full prepared and immutable original source record",equal(row.payload.admission.prepared,p)
        and equal(row.payload.admission.originalSourceRecord,s.farm.sources.new))
end
do
    local _,c,p,ctx=fixture()
    local s=assert(RLDealerStockService.newOwned("empty-admission",100))
    local row,why=A.admit(s,"first",c,p,ctx)
    check("owned admission: explicit empty owned store accepts whole first owner",row~=nil and s.sourceOwners[p.sourceOwnerId]~=nil and s.farm.sources.first~=nil)
    local legacy=assert(RLDealerStockService.new("legacy-admission",100))
    row,why=A.admit(legacy,"first",c,p,ctx)
    check("owned admission: legacy store cannot silently convert to owned inventory",not row and why=="OWNED_ADMISSION_SERVER_REQUIRED")
end
do
    local s,c,p,ctx=fixture();local writes=0
    ctx.persistBarrier=function() writes=writes+1;return true end
    local row=assert(A.admit(s,"new",c,p,ctx))
    local factory=RLDealerSourceFactory.materialize
    RLDealerSourceFactory.materialize=function() error("retry materialized") end
    ctx.checkGlobalIdentities=function() error("retry scanned") end
    for _,state in ipairs({"LISTED","WITHDRAWN","SOLD"}) do
        s.listings.records[row.saleId].state=state
        local retry,why=A.admit(s,"new",c,p,ctx)
        check("owned admission: exact retry survives "..state.." without materialization or barrier",retry and retry.saleId==row.saleId and why=="IDEMPOTENT" and writes==1)
    end
    RLDealerSourceFactory.materialize=factory
    local changed=copy(p);changed.adult.deathEnabled=false
    local retry,why=A.admit(s,"new",c,changed,ctx)
    check("owned admission: same request changed prepared rejects rather than checksum dedupe",not retry and why=="ADMISSION_REQUEST_CONFLICT")
    retry,why=A.admit(s,"different",c,p,ctx)
    check("owned admission: same request different source rejects",not retry and why=="ADMISSION_REQUEST_CONFLICT")
    c.animal.sale.price=123
    retry,why=A.admit(s,"new",c,p,ctx)
    check("owned admission: same request changed candidate immutable proof rejects",not retry and why=="ADMISSION_REQUEST_CONFLICT")
end
do
    local s,c,p,ctx=fixture();local row=assert(A.admit(s,"new",c,p,ctx))
    assert(RLDealerOwnedProgress.advance(s,{{hours=1,daysPerMonth=1}},ctx))
    local retry,why=A.admit(s,"new",c,p,ctx)
    check("owned admission: later clock retry compares original admission cursor",retry and retry.saleId==row.saleId and why=="IDEMPOTENT")
end
do
    local s,c,p,ctx=fixture({pregnant=true});p.sourceOwnerId="OWNER";p.capacity=2;s.sourceOwners.OWNER.capacity=2
    local writes=0;ctx.persistBarrier=function() writes=writes+1;return true end
    local row,why=A.admit(s,"new",c,p,ctx)
    check("owned admission: merged capacity reserves every existing real unborn without predicted mortality",not row
        and why=="ADMISSION_OWNER_BIRTH_CAPACITY" and writes==0 and s.farm.sources.new==nil)
end
local gates={
    {"transient locks",function(s) s.purchase.locks.any={owner="prepare"} end,"TRANSACTION_IN_PROGRESS"},
    {"pending transaction",function(s) s.purchase.records.any={stage="PREPARED"} end,"TRANSACTION_IN_PROGRESS"},
    {"reserved listing",function(s) s.listings.records[next(s.listings.records)].state="RESERVED" end,"TRANSACTION_IN_PROGRESS"},
    {"source fence",function(s) s.sourceUpdateInProgress=true end,"SOURCE_UPDATE_IN_PROGRESS"},
    {"recovery gate",function(s) s.recoveryRequired=true end,"RECOVERY_REQUIRED"},
    {"missing world scanner",function(s,c,p,x) x.checkGlobalIdentities=nil end,"OWNED_ADMISSION_CAPABILITY:checkGlobalIdentities"},
    {"global duplicate",function(s,c,p,x) x.checkGlobalIdentities=function() return nil,"WORLD_DUPLICATE" end end,"WORLD_DUPLICATE"},
    {"private identity duplicate",function(s,c,p,x) p.adult.farmId="SOURCE-HERD";p.adult.uniqueId="DAM" end,"OWNED_STOCK_DUPLICATE_IDENTITY"},
    {"same owner full",function(s,c,p,x) p.sourceOwnerId="OWNER";p.capacity=1;s.sourceOwners.OWNER.capacity=1 end,"OWNED_STOCK_OWNER:SOURCE_OWNER_DATA"},
    {"owner capacity mismatch",function(s,c,p,x) p.sourceOwnerId="OWNER";p.capacity=9 end,"ADMISSION_OWNER_CAPACITY"}}
for _,test in ipairs(gates) do
    local s,c,p,x=fixture();test[2](s,c,p,x)
    local writes=0;x.persistBarrier=function()writes=writes+1;return true end
    local row,why=A.admit(s,"new",c,p,x)
    check("owned admission: "..test[1].." refuses without partial publication",not row and why==test[3] and s.farm.sources.new==nil and writes==0)
end
for _,mode in ipairs({"false","throw","postscan","postscan-throw","mutate-before","locks-before-false","locks-before-throw","mutate-after","input-after","payload-after","fence-after","reenter"}) do
    local s,c,p,x=fixture();local calls=0
    x.checkGlobalIdentities=function()
        calls=calls+1
        if mode=="mutate-before" then s.sourceOwners.OWNER.capacity=11 end
        if mode=="locks-before-false" or mode=="locks-before-throw" then
            s.purchase.locks.foreign={owner="foreign"}
            if mode=="locks-before-throw" then error("foreign callback fault") end
            return false
        end
        if mode=="postscan" and calls==2 then return nil,"WORLD_CHANGED" end
        if mode=="postscan-throw" and calls==2 then error("world scan fault") end
        return true
    end
    x.persistBarrier=function(payload)
        if mode=="false" then return false end
        if mode=="throw" then error("disk fault") end
        if mode=="mutate-after" then s.sourceOwners.OWNER.capacity=11 end
        if mode=="input-after" then p.adult.deathEnabled=false end
        if mode=="payload-after" then payload.recovery.sourceOwnership.owners[p.sourceOwnerId].capacity=99 end
        if mode=="fence-after" then s.sourceUpdateInProgress=nil end
        if mode=="reenter" then
            local retry,why=A.admit(s,"new",c,p,x)
            check("owned admission: barrier reentry blocked by source fence",not retry and why=="SOURCE_UPDATE_IN_PROGRESS")
        end
        return true
    end
    local row,why=A.admit(s,"new",c,p,x)
    if mode~="reenter" then
        check("owned admission: "..mode.." holds complete evidence without publication",not row and s.recoveryRequired
            and s.sourceAdmissionEvidence and s.farm.sources.new==nil and s.sourceUpdateInProgress==nil)
        if mode=="false" or mode=="throw" then
            check("owned admission: "..mode.." preserves original unknown-barrier diagnosis",s.sourceAdmissionEvidence.reason=="SOURCE_ADMISSION_BARRIER_UNCERTAIN")
        end
        local retry,error=A.admit(s,"new",c,p,x)
        check("owned admission: "..mode.." cannot retry uncertain barrier",not retry and error=="RECOVERY_REQUIRED")
    else check("owned admission: reentry rejection preserves outer publication",row~=nil and not s.recoveryRequired) end
end

-- Actual Factory -> whole-stock Admission -> real shared reproduction -> rearing
-- -> strict whole-owner restore. Only identity world scan/durability are mocked.
loadMod("tests/dealerbirthfixture.lua")
loadMod("scripts/dealer/RLDealerOwnedBirth.lua")
DealerBirthFixture.setupController()
do
    local _,candidate,prepared,ctx=fixture(nil,true)
    local store=assert(RLDealerStockService.newOwned("admission-real-birth",100))
    ctx.birthDate=function(sourceId,cursor,age) return {eventId="ADMITTED-BIRTH",day=4,month=5,year=2027} end
    local barriers={}
    ctx.persistBarrier=function(payload,phase)
        barriers[#barriers+1]=phase or "ADMISSION"
        return K.validate(payload.recovery.sourceOwnership,payload.recovery.sources,payload.recovery.clockMonths)~=nil
    end
    local random,draw,survival=math.random,RLGrowth.drawBirthWeight,RLBirthWeight.getSurvivalChance
    local draws=0
    math.random=function() return 0.2 end
    RLGrowth.drawBirthWeight=function(...) draws=draws+1;return draw(...) end
    RLBirthWeight.getSurvivalChance=function() return 1 end
    local ok,row,result,why=pcall(function()
        local listed,failed=A.admit(store,"admitted-source",candidate,prepared,ctx);assert(listed,failed)
        check("owned admission integration: materialization retains unborn fixed identity without birth draw",draws==0
            and store.sourceOwners[prepared.sourceOwnerId].byId[prepared.adult.uniqueId].pregnancy.pregnancies[1].uniqueId=="FIXED-FETUS")
        local advanced,reason=RLDealerOwnedBirth.advance(store,{{hours=24*7,daysPerMonth=1}},ctx)
        return listed,advanced,reason
    end)
    math.random,RLGrowth.drawBirthWeight,RLBirthWeight.getSurvivalChance=random,draw,survival
    assert(ok,row);assert(result,why)
    local owner=store.sourceOwners[prepared.sourceOwnerId]
    local dam,child=owner.byId[prepared.adult.uniqueId],owner.byId["FIXED-FETUS"]
    local event=owner.birthJournal["ADMITTED-BIRTH"]
    check("owned admission integration: actual term birth samples B_i once and keeps fixed mother/fetus identity",result.births==1 and draws==1
        and dam.uniqueId=="NEW-DAM" and dam.farmId=="NEW-HERD" and child.uniqueId=="FIXED-FETUS" and child.farmId==dam.farmId
        and dam.birthCount==1 and child.genetics.fertility==0 and equal(child.genetics,prepared.pregnancy.fetuses[1].genetics)
        and child.rlGrowth.birthWeightKg==event.draws[1].weightKg and child.rlGrowth.birthWeightKg==event.result.newborns[1].birthWeightKg)
    check("owned admission integration: mother and observed child finish remaining 0.125 month at shared cursor",result.months==107
        and store.farm.sources["admitted-source"].cursorMonths==107 and store.observedChildren[prepared.sourceOwnerId][child.uniqueId].cursorMonths==107
        and child.rlGrowth.ageMonths==0.125 and dam.rlGrowth.ageMonths==27.25 and event.cursorMonths==106.875
        and event.stage=="COMMITTED" and event.evidence=="OBSERVED_SOURCE_BIRTH"
        and equal(barriers,{"ADMISSION","PREPARED","COMMITTED","COMPLETE"}))
    local encoded=owned(store)
    local restored,failure=K.restore(encoded,store.farm.sources,107,ctx.resolveSubType,{isServer=true})
    assert(restored,failure)
    local restoredOwner=restored.sourceOwners[prepared.sourceOwnerId]
    local restoredChild=restoredOwner.byId["FIXED-FETUS"]
    check("owned admission integration: full restore retains exact born physiology and once-recorded draw",equal(encoded,
        assert(K.export(restored.sourceOwners,restored.sourceBindings,restored.sourceRecordsByOwner,restored.observedChildren,
            store.farm.sources,107,restored.retiredSources))) and restoredChild.genetics.fertility==0
        and restoredChild.rlGrowth.birthWeightKg==event.draws[1].weightKg and restoredChild.clusterSystem==restoredOwner.clusterSystem)
    local listings=assert(RLDealerListingRegistry.restore(RLDealerListingRegistry.export(store.listings)))
    local provenance=listings.records[row.saleId].payload.admission
    check("owned admission integration: original complete admission provenance persists after birth and withdrawal",equal(provenance.prepared,prepared)
        and provenance.originalSourceRecord.cursorMonths==100 and provenance.originalSourceRecord.animal.isPregnant
        and listings.records[row.saleId].state=="WITHDRAWN" and provenance.requestId==prepared.requestId)
    local retry,retryReason=A.admit(store,"admitted-source",candidate,prepared,ctx)
    check("owned admission integration: postbirth original candidate retry returns same historical listing without redraw",retry
        and retry.saleId==row.saleId and retryReason=="IDEMPOTENT" and #barriers==4)
end
