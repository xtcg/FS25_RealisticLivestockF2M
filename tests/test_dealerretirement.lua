loadMod("tests/dealerbirthfixture.lua")
local F,K,U,T=DealerBirthFixture,RLDealerOwnedStock,RLDealerOwnedProgress,RLTradePersistence
local function encode(s) return assert(K.export(s.sourceOwners,s.sourceBindings,s.sourceRecordsByOwner,
    s.observedChildren,s.farm.sources,s.farm.clock.months,s.retiredSources)) end
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local stock,ctx,saleId,eventId,children,result=F.new(true)
local owner,dam=stock.sourceOwners.OWNER,stock.sourceOwners.OWNER.byId.DAM
check("retirement: real shared birth creates living twin and actual maternal mortality",result.parentDied and result.children==1
    and dam.isDead and owner.byId[children[1].uniqueId]==children[1] and children[2].isDead)
local before=T.canonical(encode(stock));local listingBefore=T.canonical(stock.listings)
local staged,why=K.stageRetirement(stock,"source",eventId);assert(staged,why)
check("retirement: staging preserves input real objects and every source/listing field",T.canonical(encode(stock))==before
    and T.canonical(stock.listings)==listingBefore and stock.sourceOwners.OWNER==owner and owner.byId.DAM==dam)
check("retirement: archive retains immutable record, journal, owned body and live child",staged.sources.source==nil and staged.sourceBindings.source==nil
    and staged.retiredSources.source.record.animal.isDead and staged.retiredSources.source.eventId==eventId
    and staged.sourceOwnership.owners.OWNER.birthJournal[eventId].result.parentDied
    and #staged.sourceOwnership.owners.OWNER.animals==2 and owner.byId.DAM==dam)
check("retirement: death withdraws active listing with the maternal mortality reason",staged.listings.records[saleId].state=="WITHDRAWN")
local restored=assert(K.restore(staged.sourceOwnership,staged.sources,stock.farm.clock.months,ctx.resolveSubType,{isServer=true}))
check("retirement: full ownership roundtrip preserves body and exact newborn weight",restored.sourceOwners.OWNER.byId.DAM.isDead
    and restored.sourceOwners.OWNER.byId[children[1].uniqueId].weight==children[1].weight
    and restored.retiredSources.source.record.cursorMonths==106.875 and not restored.recoveryRequired)
local originalAge=staged.retiredSources.source.record.ageMonths
stock.farm.sources=staged.sources
for _,key in ipairs({"sourceBindings","retiredSources","listings"}) do stock[key]=staged[key] end
local writes=0;ctx.persistBarrier=function(payload) writes=writes+1;return K.validate(payload.recovery.sourceOwnership,payload.recovery.sources,payload.recovery.clockMonths)~=nil end
local progressed,failure=U.advance(stock,{{hours=24,daysPerMonth=1}},ctx);assert(progressed,failure)
check("retirement: live calf continues feeding while dead record stays at death cursor",stock.farm.clock.months==107.875
    and stock.observedChildren.OWNER[children[1].uniqueId].animal.rlGrowth.ageMonths==1
    and stock.retiredSources.source.record.cursorMonths==106.875
    and stock.retiredSources.source.record.ageMonths==originalAge and stock.sourceOwners.OWNER.byId.DAM.rlGrowth.ageMonths==originalAge and writes==1)
check("retirement: progressed full inventory remains restorable",K.restore(encode(stock),stock.farm.sources,stock.farm.clock.months,ctx.resolveSubType,{isServer=true})~=nil)
local bad=copy(encode(stock));bad.retiredSources.source.eventId="FOREIGN-BIRTH"
check("retirement: foreign birth proof refuses restoration",not K.validate(bad,stock.farm.sources,stock.farm.clock.months))
bad=copy(encode(stock));bad.retiredSources.alias=copy(bad.retiredSources.source)
check("retirement: alias cannot bind the same dead body twice",not K.validate(bad,stock.farm.sources,stock.farm.clock.months))
bad=copy(encode(stock));bad.retiredSources.source.record.observedSourceEvents.events[1].draws[1].weightKg=41
check("retirement: altered observed birth mass rejects archive",not K.validate(bad,stock.farm.sources,stock.farm.clock.months))
local alive,_,_,aliveEvent=F.new(false);local aliveBefore=T.canonical(encode(alive))
check("retirement: living mother cannot retire under a calving event",not K.stageRetirement(alive,"source",aliveEvent)
    and T.canonical(encode(alive))==aliveBefore)
local missing,missingCtx,_,missingEvent=F.new(true);local missingBefore=T.canonical(encode(missing))
check("retirement: unrelated event cannot retire actual dead mother",not K.stageRetirement(missing,"source","UNRELATED")
    and T.canonical(encode(missing))==missingBefore)
local D,V=RLDealerPersistence,RLDealerStockService
local meta={lineage="DLretired-1",generation=1,parentGeneration=0,checkpointId="DLretired-1:1"}
local markers={}
for _,role in ipairs(D.REQUIRED_PARTICIPANTS) do markers[role]=assert(D.marker(meta.lineage,1,{role=role})) end
local checkpoint,checkpointWhy=V.buildSnapshot(stock,meta,markers);assert(checkpoint,checkpointWhy)
local verified,verifyWhy=D.validateSnapshot(checkpoint,markers,ctx.resolveSubType,{isServer=true});assert(verified,verifyWhy)
local loaded,loadWhy=V.fromVerifiedDocument({state="VERIFIED",sourceResolution="RESOLVED",restored=verified});assert(loaded,loadWhy)
check("retirement: complete dealer checkpoint validates retired listing and restores owned body with live child",loaded.retiredSources.source.record.animal.isDead
    and loaded.sourceOwners.OWNER.byId.DAM.isDead and loaded.sourceOwners.OWNER.byId[children[1].uniqueId].rlGrowth.ageMonths==1
    and loaded.listings.records[saleId].state=="WITHDRAWN" and not loaded.recoveryRequired)
