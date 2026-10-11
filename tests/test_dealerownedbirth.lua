loadMod("tests/dealerbirthfixture.lua")
loadMod("scripts/dealer/RLDealerOwnedBirth.lua")
DealerBirthFixture.setupController()
local F,C,K,T=DealerOwnedFixture,RLDealerOwnedBirth,RLDealerOwnedStock,RLTradePersistence
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local function encode(s) return assert(K.export(s.sourceOwners,s.sourceBindings,s.sourceRecordsByOwner,s.observedChildren,s.farm.sources,s.farm.clock.months,s.retiredSources)) end
local function setup()
    local stock,ctx,saleId=F.new({pregnant=true,child=true})
    stock.sourceOwners.OWNER.byId.DAM.deathEnabled=true
    ctx.birthDate=function(id,cursor,age) return {eventId="BIRTH-"..id,day=4,month=5,year=2027} end
    local phases={}
    ctx.persistBarrier=function(payload,phase,event)
        phases[#phases+1]={phase=phase,event=event,payload=copy(payload)}
        return K.validate(payload.recovery.sourceOwnership,payload.recovery.sources,payload.recovery.clockMonths)~=nil
    end
    return stock,ctx,saleId,phases
end
local function advance(stock,segments,ctx,mortality)
    local random,draw,survival=math.random,RLGrowth.drawBirthWeight,RLBirthWeight.getSurvivalChance
    local draws,survivalChecks=0,0
    math.random=function() return mortality and 0.99 or 0.2 end
    RLGrowth.drawBirthWeight=function(...) draws=draws+1;return draw(...) end
    RLBirthWeight.getSurvivalChance=function() survivalChecks=survivalChecks+1;return mortality and survivalChecks==2 and 0 or 1 end
    local ok,result,reason=pcall(C.advance,stock,segments,ctx)
    math.random,RLGrowth.drawBirthWeight,RLBirthWeight.getSurvivalChance=random,draw,survival
    assert(ok,result)
    return result,reason,draws
end
local stock,ctx,saleId,phases=setup()
local result,why,draws=advance(stock,{{hours=24*7,daysPerMonth=1}},ctx);assert(result,why)
check("owned birth: actual term crossing feeds remaining interval and both generations",result.births==1 and draws==1 and result.months==107
    and stock.sourceOwners.OWNER.byId.DAM.birthCount==1 and stock.sourceOwners.OWNER.byId.FETUS.rlGrowth.ageMonths==0.125
    and stock.observedChildren.OWNER.CHILD.animal.rlGrowth.ageMonths==7 and stock.farm.sources.source.observedSourceEvents.events[1].cursorMonths==106.875)
check("owned birth: whole inventory PREPARED COMMITTED COMPLETE barriers follow real draw",#phases==3 and phases[1].phase=="PREPARED"
    and phases[2].phase=="COMMITTED" and phases[3].phase=="COMPLETE"
    and phases[1].payload.recovery.sourceOwnership.owners.OWNER.birthJournal["BIRTH-source"].stage=="PREPARED"
    and phases[2].payload.recovery.sourceOwnership.observedChildren.OWNER.FETUS~=nil)
check("owned birth: successful whole inventory survives strict restore",K.restore(encode(stock),stock.farm.sources,107,ctx.resolveSubType,{isServer=true})~=nil)
for _,failedPhase in ipairs({"PREPARED","COMMITTED","COMPLETE"}) do
    local s,c=setup();local before=T.canonical(encode(s));local writes={}
    c.persistBarrier=function(payload,phase) writes[#writes+1]=copy(payload);return phase~=failedPhase end
    local value,reason,count=advance(s,{{hours=24*7,daysPerMonth=1}},c)
    check("owned birth: "..failedPhase.." unknown barrier holds original assets and recovery evidence",not value and s.recoveryRequired
        and T.canonical(encode(s))==before and s.sourceBirthEvidence~=nil and count==(failedPhase=="PREPARED" and 0 or 1))
    local attempted=s.sourceBirthEvidence.attempted
    check("owned birth: "..failedPhase.." keeps exact last attempted portable evidence",attempted.phase==failedPhase
        and T.check(attempted.snapshot)==nil and (failedPhase=="COMPLETE" or attempted.event.eventId=="BIRTH-source")
        and attempted.snapshot.clock.months==(failedPhase=="COMPLETE" and 107 or 106.875))
    local retry,retryReason,retryDraws=advance(s,{{hours=24*7,daysPerMonth=1}},c)
    check("owned birth: "..failedPhase.." hold cannot redraw on retry",not retry and retryReason=="RECOVERY_REQUIRED" and retryDraws==0)
    local last=writes[#writes];local restored=K.restore(last.recovery.sourceOwnership,last.recovery.sources,last.recovery.clockMonths,c.resolveSubType,{isServer=true})
    check("owned birth: "..failedPhase.." durable evidence restores exact recorded ownership",restored~=nil
        and (failedPhase~="PREPARED" or restored.recoveryRequired))
end
stock,ctx=setup();stock.sourceOwners.OWNER.capacity=2;stock.sourceOwners.OWNER.spec.maxNumAnimals=2
local before=T.canonical(encode(stock));result,why,draws=advance(stock,{{hours=24*7,daysPerMonth=1}},ctx)
check("owned birth: aggregate capacity refuses before RNG or any ownership change",not result and why=="SOURCE_BIRTH_CAPACITY" and draws==0
    and not stock.recoveryRequired and T.canonical(encode(stock))==before)
-- Add a second true mother at the exact same source cursor and in the same owner.
local function twoMothers()
local stock,ctx,saleId,phases=setup()
local donor=setup();local second=donor.sourceOwners.OWNER.byId.DAM
second.clusterSystem=nil;second.uniqueId="DAM-B";second.pregnancy.pregnancies[1].uniqueId="FETUS-B"
local owner=stock.sourceOwners.OWNER
second.clusterSystem=owner.clusterSystem;owner.animals[#owner.animals+1]=second;owner.byId[second.uniqueId]=second
owner.sireContexts[second.uniqueId]=copy(owner.sireContexts.DAM)
stock.farm.sources["source-b"]=copy(stock.farm.sources.source)
stock.sourceBindings["source-b"]={ownerId="OWNER",animalId="DAM-B"}
stock.sourceRecordsByOwner.OWNER["DAM-B"]=copy(stock.farm.sources.source)
return stock,ctx,saleId,phases
end
stock,ctx,saleId,phases=twoMothers()
result,why,draws=advance(stock,{{hours=24*7,daysPerMonth=1}},ctx);assert(result,why)
check("owned birth: same cursor mothers each calve once with independent fixed offspring",result.births==2 and draws==2 and #phases==5
    and owner~=stock.sourceOwners.OWNER and stock.sourceOwners.OWNER.byId.FETUS~=nil and stock.sourceOwners.OWNER.byId["FETUS-B"]~=nil
    and phases[1].event.damId=="DAM" and phases[3].event.damId=="DAM-B"
    and stock.sourceOwners.OWNER.byId["DAM-B"].birthCount==1)
-- Mixed calendars cross exactly the same due age as separate persisted calls.
local mixed,mixedCtx=setup();local split,splitCtx=setup()
local segments={{hours=24*6,daysPerMonth=1},{hours=24*3,daysPerMonth=3},{hours=24*7,daysPerMonth=7}}
assert(advance(mixed,segments,mixedCtx))
assert(advance(split,{segments[1]},splitCtx));assert(advance(split,{segments[2],segments[3]},splitCtx))
check("owned birth: mixed month lengths match split persisted continuation",T.canonical(encode(mixed))==T.canonical(encode(split)))
-- A low-health twin pregnancy supplies the normal mortality path without inventing a death.
stock,ctx,saleId,phases=setup()
local seed=DealerReplaySim.seed("HOLSTEIN","female",1);seed.genetics.health=0.25
local history=DealerReplaySim.history(seed,20.25,"NORMAL_PRODUCTION",{{kind="CONCEPTION",atMonths=17.125,parity=1}})
local replay=assert(RLDealerReplay.run(seed,history,{daysPerMonth=1,entry=ctx.resolveEntry(),pregnancySubTypes={[4]={seed.subType,seed.subType}}}))
local record=assert(RLDealerSourceState.capture(replay,100));local dam=stock.sourceOwners.OWNER.byId.DAM
for key,value in pairs(record.animal) do if key~="subTypeIndex" then dam[key]=copy(value) end end
local fetus=Animal.new({age=-1,weight=35,health=100,gender="female",subTypeIndex=Economics.find(seed.subType.name),
    genetics=copy(seed.genetics),uniqueId="FETUS-DEAD",farmId=dam.farmId})
dam.pregnancy.pregnancies[2]=fetus;dam.deathEnabled=true
stock.farm.sources.source=record;stock.sourceRecordsByOwner.OWNER.DAM=record
result,why,draws=advance(stock,{{hours=24*7,daysPerMonth=1}},ctx,true);assert(result,why)
check("owned birth: actual maternal mortality retires body while living twin keeps feeding",result.births==1 and draws==2
    and stock.retiredSources.source.record.animal.isDead and stock.farm.sources.source==nil
    and stock.sourceOwners.OWNER.byId.DAM.isDead and stock.sourceOwners.OWNER.byId.FETUS.rlGrowth.ageMonths==0.125
    and stock.listings.records[saleId].state=="WITHDRAWN" and stock.retiredSources.source.record.cursorMonths==106.875)

for _,failPhase in ipairs({"PREPARED","COMMITTED"}) do
    local s,c=twoMothers();local before=T.canonical(encode(s));local committed=0;local last
    c.persistBarrier=function(payload,phase,event)
        last=copy(payload)
        if phase=="COMMITTED" then committed=committed+1 end
        return not (event and event.damId=="DAM-B" and phase==failPhase)
    end
    local value,reason,count=advance(s,{{hours=24*7,daysPerMonth=1}},c)
    local evidence=s.sourceBirthEvidence and s.sourceBirthEvidence.staged
    check("owned birth: first mother committed second "..failPhase.." uncertainty preserves both evidence paths",not value and s.recoveryRequired
        and T.canonical(encode(s))==before and count==(failPhase=="PREPARED" and 1 or 2)
        and evidence.sourceOwners.OWNER.birthJournal["BIRTH-source"].stage=="COMMITTED"
        and evidence.sourceOwners.OWNER.byId.FETUS~=nil and evidence.sourceOwners.OWNER.quarantine["DAM-B"]~=nil)
    local recovered=K.restore(last.recovery.sourceOwnership,last.recovery.sources,last.recovery.clockMonths,c.resolveSubType,{isServer=true})
    check("owned birth: same cursor partial "..failPhase.." durable snapshot restores first calf without re-creating it",recovered~=nil
        and recovered.sourceOwners.OWNER.byId.FETUS~=nil and (failPhase~="PREPARED" or recovered.recoveryRequired))
    local retry,retryReason,retryDraws=advance(s,{{hours=24*7,daysPerMonth=1}},c)
    check("owned birth: same cursor partial "..failPhase.." retry never repeats first birth",not retry and retryReason=="RECOVERY_REQUIRED" and retryDraws==0)
end
stock,ctx=twoMothers();stock.sourceOwners.OWNER.capacity=4;stock.sourceOwners.OWNER.spec.maxNumAnimals=4
local aggregateBefore=T.canonical(encode(stock));result,why,draws=advance(stock,{{hours=24*7,daysPerMonth=1}},ctx)
check("owned birth: two mothers reserve aggregate full litters before the first RNG",not result and why=="SOURCE_BIRTH_CAPACITY"
    and draws==0 and not stock.recoveryRequired and T.canonical(encode(stock))==aggregateBefore)
stock,ctx,saleId,phases=twoMothers()
assert(advance(stock,{{hours=24*7,daysPerMonth=1}},ctx))
local intermediate=phases[2].payload.recovery
local partial=assert(K.validate(intermediate.sourceOwnership,intermediate.sources,intermediate.clockMonths))
check("owned birth: first COMMITTED same-cursor checkpoint remains recovery held until second mother catches up",partial.recoveryRequired
    and intermediate.sources.source.cursorMonths==106.875 and intermediate.sources["source-b"].cursorMonths==100)
local partialOwned=assert(K.restore(intermediate.sourceOwnership,intermediate.sources,intermediate.clockMonths,ctx.resolveSubType,{isServer=true}))
local partialStore,partialWhy=RLDealerStockService.fromVerifiedDocument({state="VERIFIED",sourceResolution="RESOLVED",restored={
    clock=phases[2].payload.clock,listings=phases[2].payload.listings,purchase=phases[2].payload.purchase,
    sources=intermediate.sources,ownedStock=partialOwned,ownershipResolution="RESOLVED",recoveryRequired=true}})
check("owned birth: verified partial inventory exposes held exact ownership despite mismatched physiological cursor",partialStore~=nil
    and partialStore.recoveryRequired and partialStore.sourceOwners.OWNER.byId.FETUS~=nil
    and partialStore.farm.sources["source-b"].cursorMonths==100)
for _,days in ipairs({1,3,7}) do
    local exact,exactCtx,_,exactPhases=setup()
    local termHours=165*days
    local hourly={}
    for hour=1,termHours do hourly[hour]={hours=1,daysPerMonth=days} end
    local value,reason,count=advance(exact,hourly,exactCtx);assert(value,reason)
    check("owned birth: "..days.." day calendar exact term hours births with zero calf elapsed time",value.births==1 and count==1
        and math.abs(value.months-106.875)<1e-10 and exact.sourceOwners.OWNER.byId.FETUS.rlGrowth.ageMonths==0
        and math.abs(exact.observedChildren.OWNER.FETUS.cursorMonths-106.875)<1e-10 and #exactPhases==3)
    local early,earlyCtx,_,earlyPhases=setup()
    local earlyHourly={}
    for hour=1,termHours-1 do earlyHourly[hour]={hours=1,daysPerMonth=days} end
    value,reason,count=advance(early,earlyHourly,earlyCtx);assert(value,reason)
    check("owned birth: "..days.." day calendar one hour before term cannot round into a birth",value.births==0 and count==0
        and early.sourceOwners.OWNER.byId.FETUS==nil and early.sourceOwners.OWNER.byId.DAM.isPregnant
        and early.farm.clock.months<106.875 and #earlyPhases==1 and earlyPhases[1].phase=="COMPLETE")
end
stock,ctx,saleId,phases=setup()
local zeroOwner=stock.sourceOwners.OWNER;local zeroDam=zeroOwner.byId.DAM;local zeroBefore=T.canonical(encode(stock))
local zeroResult,zeroWhy,zeroDraws=advance(stock,{},ctx);assert(zeroResult,zeroWhy)
local zeroAgain,zeroAgainWhy,zeroAgainDraws=advance(stock,{{hours=0,daysPerMonth=3}},ctx);assert(zeroAgain,zeroAgainWhy)
check("owned birth: zero elapsed calendar performs no writes RNG or private owner reconstruction",zeroResult.births==0 and zeroAgain.births==0
    and zeroDraws==0 and zeroAgainDraws==0 and #phases==0 and stock.sourceOwners.OWNER==zeroOwner and zeroOwner.byId.DAM==zeroDam
    and stock.farm.clock.months==100 and T.canonical(encode(stock))==zeroBefore)
stock,ctx,saleId=setup()
stock.purchase.locks[saleId]={owner="TRANSIENT-REQUEST",deadline=1000}
local lockedOwner=stock.sourceOwners.OWNER;local lockedBefore=T.canonical(encode(stock));local lockWrites=0
ctx.persistBarrier=function() lockWrites=lockWrites+1;return true end
result,why,draws=advance(stock,{{hours=24*7,daysPerMonth=1}},ctx)
check("owned birth: transient purchase lock without journal refuses before any sampling",not result and why=="TRANSACTION_IN_PROGRESS"
    and next(stock.purchase.records)==nil and draws==0 and lockWrites==0 and stock.sourceOwners.OWNER==lockedOwner
    and T.canonical(encode(stock))==lockedBefore and not stock.recoveryRequired)
for _,mutation in ipairs({"capacity","purchaseLocks"}) do
    local s,c,sale=setup();local originalOwner=s.sourceOwners.OWNER;local writes=0
    c.persistBarrier=function() writes=writes+1;return true end
    c.eligible=function()
        if mutation=="capacity" then originalOwner.capacity=11
        else s.purchase.locks[sale]={owner="FOREIGN-REQUEST",deadline=2000} end
        return true
    end
    -- A first non-birth segment evaluates listing eligibility, then the planned
    -- pregnancy would calve in the second segment. Foreign mutation must stop
    -- the PREPARED barrier before the reproduction sampler can run.
    local value,reason,count=advance(s,{{hours=1,daysPerMonth=1},{hours=24*7-1,daysPerMonth=1}},c)
    check("owned birth: eligible foreign "..mutation.." before first barrier holds without RNG or writes",not value and reason=="SOURCE_SNAPSHOT_CHANGED"
        and s.recoveryRequired and s.sourceBirthEvidence~=nil and s.sourceBirthEvidence.before~=nil
        and s.sourceBirthEvidence.staged~=nil and writes==0 and count==0 and s.sourceOwners.OWNER==originalOwner and s.farm.clock.months==100)
    check("owned birth: foreign "..mutation.." remains available for reconciliation",mutation=="capacity" and originalOwner.capacity==11
        or mutation=="purchaseLocks" and s.purchase.locks[sale].owner=="FOREIGN-REQUEST")
end
