loadMod("tests/dealerreplaysim.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
for _, name in ipairs({"SourceState", "SourceReproduction", "SourceOwnership", "ObservedGrowth", "OwnedStock",
    "Clock", "ListingRegistry", "Purchase", "Persistence", "SourceFarm", "StockService"}) do
    loadMod("scripts/dealer/RLDealer" .. name .. ".lua")
end
loadAnimalSection("local Animal_mt = Class(Animal)", "function Animal:delete()")
loadAnimalSection("function Animal:getSubTypeIndex", "function Animal:increaseAge")
local K, O, B, T = RLDealerOwnedStock, RLDealerSourceOwnership, RLDealerSourceReproduction, RLTradePersistence
local function copy(v) if type(v) ~= "table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local seed=DealerReplaySim.seed("HOLSTEIN","female",1)
local index=Economics.find(seed.subType.name)
local system=g_currentMission.animalSystem
system.getSubTypeByName=function(_,name) local _,sub=Economics.find(name);return sub end
system.getTypeIndexBySubTypeIndex=function(_,i) local sub=system:getSubTypeByIndex(i);return sub and sub.typeIndex end
system.types={}
g_currentMission.environment.weather={temperatureUpdater={currentMin=20}}
Animal.getDefaultMarks=function() return {} end
Animal.isHorse=function() return false end
Animal.updateInput=function(self) self.input.food=0 end
Animal.updateOutput=function(self) self.output.milk=0 end
local replay=assert(RLDealerReplay.run(seed,DealerReplaySim.history(seed,8.5),{daysPerMonth=1}))
local record=assert(RLDealerSourceState.capture(replay,100))
local animal=Animal.new({age=-1,weight=35,health=100,gender="female",subTypeIndex=index,
    genetics=copy(seed.genetics),uniqueId="REAL-DAM",farmId="SOURCE-HERD"})
for k,v in pairs(record.animal) do if k~="subTypeIndex" then animal[k]=copy(v) end end
animal.birthday={day=12,month=2,year=2025,country=4,lastAgeMonth=10}
local owner=assert(B.createOwner("OWNER-A",10,{animal}))
local sources={["listing-source"]=record}
local bindings={["listing-source"]={ownerId="OWNER-A",animalId="REAL-DAM"}}
local records={["OWNER-A"]={["REAL-DAM"]=record}}
local encoded=assert(K.export({["OWNER-A"]=owner},bindings,records,{},sources,100))
local function resolver(name) local i,sub=Economics.find(name);return sub,i end
local random=math.random;math.random=function() error("owned restore draws") end
local restored=assert(K.restore(encoded,sources,100,resolver,{isServer=true}));math.random=random
check("owned stock: full private identity and exact physiology restore without RNG",restored.sourceOwners["OWNER-A"].byId["REAL-DAM"].weight==animal.weight
    and restored.sourceBindings["listing-source"].animalId=="REAL-DAM" and not restored.recoveryRequired)
check("owned stock: cluster retains restored owner object rather than a deepcopy",restored.sourceOwners["OWNER-A"].clusterSystem.owner==restored.sourceOwners["OWNER-A"])
local bad=copy(encoded);bad.bindings={}
check("owned stock: every physiological source must bind one real animal",not K.validate(bad,sources,100))
bad=copy(encoded);bad.bindings["alias"]=copy(bindings["listing-source"])
check("owned stock: two source aliases cannot own the same animal",not K.validate(bad,{["alias"]=record,["listing-source"]=record},100))
bad=copy(encoded);bad.owners["OWNER-B"]=copy(bad.owners["OWNER-A"]);bad.owners["OWNER-B"].sourceId="OWNER-B"
check("owned stock: duplicate adult identities across owners reject",not K.validate(bad,sources,100))
bad=copy(encoded);bad.bindings["listing-source"].ownerId="missing"
check("owned stock: missing source owner rejects",not K.validate(bad,sources,100))
bad=copy(encoded);bad.owners["OWNER-A"].sourceId="other"
check("owned stock: map key must match persistent private owner identity",not K.validate(bad,sources,100))
bad=copy(encoded);bad.observedChildren["missing"]={}
check("owned stock: child physiology cannot refer to absent source owner",not K.validate(bad,sources,100))
bad=copy(encoded);bad.owners["OWNER-A"].quarantine["REAL-DAM"]="UNKNOWN"
check("owned stock: quarantine persists as recovery gate",assert(K.validate(bad,sources,100)).recoveryRequired)
local before=T.canonical(encoded)
local missing,why=K.restore(encoded,sources,100,function() return nil end,{isServer=true})
check("owned stock: unavailable subtype rejects without rewriting raw owner",missing==nil and why=="SOURCE_OWNER_MISSING_SUBTYPE" and T.canonical(encoded)==before)
local clock=assert(RLDealerClock.new(100))
local listings=assert(RLDealerListingRegistry.new("owned-test"))
local meta={lineage="DLowned-1",generation=1,parentGeneration=0,checkpointId="DLowned-1:1"}
local markers={};for _,role in ipairs(RLDealerPersistence.REQUIRED_PARTICIPANTS) do markers[role]=assert(RLDealerPersistence.marker(meta.lineage,1,{role=role})) end
local snapshot=assert(RLDealerPersistence.capture(meta,clock,listings,sources,RLDealerPurchase.export(RLDealerPurchase.new()),markers,encoded))
local unchecked=assert(RLDealerPersistence.validateSnapshot(snapshot,markers,resolver))
local dormant,reason=RLDealerStockService.fromVerifiedDocument({state="VERIFIED",sourceResolution="RESOLVED",restored=unchecked})
check("owned stock: pure checkpoint validation cannot authorize unresolved real ownership",not dormant and reason=="VERIFIED_OWNERSHIP_CHECKPOINT_REQUIRED")
local verified=assert(RLDealerPersistence.validateSnapshot(snapshot,markers,resolver,{isServer=true}))
local stock=assert(RLDealerStockService.fromVerifiedDocument({state="VERIFIED",sourceResolution="RESOLVED",restored=verified}))
local roundtrip=assert(RLDealerStockService.buildSnapshot(stock,meta,markers))
check("owned stock: checkpoint and composed runtime roundtrip retain unborn-ready private inventory",T.canonical(roundtrip)==T.canonical(snapshot)
    and stock.sourceOwners["OWNER-A"].clusterSystem.owner==stock.sourceOwners["OWNER-A"])
check("owned stock: pure feeding cannot silently advance only half the owned inventory",not RLDealerStockService.advanceSegments(stock,{},resolver,nil,function() return true end))
check("owned stock: pure publication cannot insert an unowned candidate into real inventory",not RLDealerStockService.publish(stock,"another",replay))
local child=Animal.new({age=-1,weight=35,health=100,gender="female",subTypeIndex=index,
    genetics={metabolism=2.1,quality=2.25,productivity=1.8,fertility=0,health=0.9},uniqueId="REAL-CHILD",farmId="SOURCE-HERD"})
child.age,child.birthCount,child.isParent,child.isLactating,child.isPregnant,child.reproduction=0,0,false,false,false,0
child.birthday={day=2,month=10,year=2026,country=4,lastAgeMonth=10}
assert(RLGrowth.initBirth(child,41.23456789))
local event={version=1,eventId="BIRTH-REAL",sourceId="OWNER-CHILD",damId="REAL-MOTHER",cursorMonths=100,atAgeMonths=27,
    stage="COMMITTED",evidence="OBSERVED_SOURCE_BIRTH",day=2,month=10,year=2026,sireContext={breed="HOLSTEIN"},
    selected={{uniqueId=child.uniqueId,farmId=child.farmId,subType=child.subType,genetics=copy(child.genetics)}},
    draws={{uniqueId=child.uniqueId,farmId=child.farmId,subType=child.subType,weightKg=child.weight,meanWeightKg=40,z=0}},
    result={eventId="BIRTH-REAL",evidence="OBSERVED_SOURCE_BIRTH",newborns={{uniqueId=child.uniqueId,farmId=child.farmId,subType=child.subType,birthWeightKg=child.weight,alive=true}}}}
local childOwner=assert(B.createOwner("OWNER-CHILD",10,{child}))
childOwner.birthJournal[event.eventId],childOwner.observedBirths[1]=event,copy(event)
local observed=assert(RLDealerObservedGrowth.capture(child,100,event))
local childData=assert(K.export({["OWNER-CHILD"]=childOwner},{},{},{["OWNER-CHILD"]={[child.uniqueId]=observed}},{},100))
local childRestored=assert(K.restore(childData,{},100,resolver,{isServer=true}))
check("owned stock: real calf record and original outlier genes survive complete ownership roundtrip",
    childRestored.sourceOwners["OWNER-CHILD"].byId[child.uniqueId].genetics.fertility==0
    and childRestored.observedChildren["OWNER-CHILD"][child.uniqueId].animal.rlGrowth.birthWeightKg==41.23456789)
bad=copy(childData);bad.observedChildren={}
check("owned stock: real children cannot lose their independent growth cursor",not K.validate(bad,{},100))
bad=copy(childData);bad.owners["OWNER-CHILD"].animals[1].physiology.health=90
check("owned stock: child physiology and growth record must agree beyond identity",not K.validate(bad,{},100))
bad=copy(childData);bad.owners["OWNER-CHILD"].birthJournal[event.eventId].day=3
check("owned stock: independent child proof must match owned committed birth journal",not K.validate(bad,{},100))
local oldWean=RLCalfRearing.getWeaningMonthForSubType
RLCalfRearing.getWeaningMonthForSubType=function(sub) return oldWean(sub)+1 end
local incompatible,incompatibleReason=K.restore(childData,{},100,resolver,{isServer=true})
RLCalfRearing.getWeaningMonthForSubType=oldWean
check("owned stock: changed calf rules quarantine saved inventory rather than silently reinterpret its history",
    incompatible==nil and incompatibleReason=="OWNED_STOCK_CHILD_RESOLVE:OBSERVED_RULES")
loadMod("scripts/dealer/RLDealerSourceAdapter.lua")
local A=RLDealerSourceAdapter
local function transactionFixture()
    local raw=copy(encoded.owners["OWNER-A"])
    raw.animals[2]=copy(raw.animals[1]);raw.animals[2].identity.uniqueId="REAL-DAM-2"
    local own,metadata=O.restore(raw,resolver,{isServer=true});assert(own)
    return own,metadata.recordsByAnimalId
end
local own,rs=transactionFixture()
local binding=assert(A.bind(own,{"REAL-DAM-2","REAL-DAM"},rs))
local receipt=assert(A.exportBinding(binding))
local dam1,dam2=own.byId["REAL-DAM"],own.byId["REAL-DAM-2"]
check("source adapter: batch binding sorts stable IDs and freezes complete private inventory",receipt.animalIds[1]=="REAL-DAM" and A.observe(binding)=="PRESENT")
assert(A.apply(binding));assert(A.apply(binding))
check("source adapter: repeated detach removes exact original objects once",#own.animals==0 and own.byId["REAL-DAM"]==nil and dam1.clusterSystem==nil and dam2.clusterSystem==nil and A.observe(binding)=="REMOVED")
dam1.clusterSystem={foreign=true}
check("source adapter: foreign target ownership blocks rollback without stealing an animal",not A.rollback(binding) and #own.animals==0 and dam1.clusterSystem.foreign)
dam1.clusterSystem=nil
assert(A.rollback(binding));assert(A.rollback(binding))
check("source adapter: verified compensation restores original order, identities and cluster ownership",own.animals[1]==dam1 and own.animals[2]==dam2 and own.byId[dam1.uniqueId]==dam1 and dam1.clusterSystem==own.clusterSystem)
local rebound=assert(A.rebind(own,receipt,rs))
check("source adapter: saved pre-effect evidence rebinds current actual owner without redraw",A.observe(rebound)=="PRESENT")
assert(A.apply(binding));dam1.weight=dam1.weight+1
check("source adapter: modified detached physiology cannot be restored as a successful rollback",not A.rollback(binding) and #own.animals==0)
dam1.weight=dam1.weight-1;assert(A.rollback(binding))
own.byId["REAL-DAM-2"].health=90
check("source adapter: unrelated source mutation closes a frozen transaction before detach",not A.apply(binding) and #own.animals==2)
own.byId["REAL-DAM-2"].health=100
local duplicate=A.bind(own,{"REAL-DAM","REAL-DAM"},rs)
check("source adapter: duplicated selection rejects before any source mutation",not duplicate and #own.animals==2)
own.quarantine["REAL-DAM-2"]="UNKNOWN"
check("source adapter: unresolved birth or source quarantine cannot authorize transfer",not A.bind(own,{"REAL-DAM"},rs))
own.quarantine["REAL-DAM-2"]=nil
assert(A.apply(binding))
local absent,absentReason=A.rebind(own,receipt,rs)
check("source adapter: restart after detach requires asset reconciliation rather than receipt reconstruction",not absent and absentReason=="SOURCE_RECONCILIATION_REQUIRED")
check("source adapter: malformed handles report unknown without mutating anything",A.observe({version=1})=="UNKNOWN")
loadMod("scripts/dealer/RLDealerMoneyAdapter.lua")
loadMod("scripts/dealer/RLDealerJournal.lua")
loadMod("scripts/dealer/RLDealerRuntime.lua")
local J=RLDealerJournal
local disk,writes={},0
local storage={save=function(path,data) writes=writes+1;disk[path]=T.canonical(data);return true end,
    load=function(path) local value=disk[path];if value then return assert(T.parse(value,RLDealerPersistence.LIMITS)),T.checksum(value) end end}
local recovery={version=1,clockMonths=100,sources=copy(snapshot.sources),sourceOwnership=copy(snapshot.sourceOwnership)}
local journal=assert(J.new(meta.lineage,"owned-wal-epoch"))
assert(J.checkpoint(journal,"/save",snapshot.purchase,1,storage,recovery))
local wal=assert(J.load("/save",storage))
check("owned journal: synchronous barrier includes exact source, unborn-ready owner and physiological binding evidence",
    T.canonical(wal.data.recovery)==T.canonical(recovery))
local invalidRecovery=copy(recovery);invalidRecovery.sourceOwnership.bindings={}
local writeCount=writes
check("owned journal: broken ownership evidence refuses before replacing successful WAL",
    not J.checkpoint(journal,"/save",snapshot.purchase,1,storage,invalidRecovery) and writes==writeCount and not journal.recoveryRequired)
local withMoney=copy(recovery)
withMoney.money=RLDealerMoneyAdapter.export(assert(RLDealerMoneyAdapter.new({epoch="owned-money"})))
assert(J.checkpoint(journal,"/save",snapshot.purchase,1,storage,withMoney))
check("owned journal: independent money receipt schema survives exact readback",assert(J.load("/save",storage)).data.recovery.money.epoch=="owned-money")
withMoney.money.version=100
writeCount=writes
check("owned journal: malformed money receipts cannot cross durable barrier",not J.checkpoint(journal,"/save",snapshot.purchase,1,storage,withMoney) and writes==writeCount)
RLDealerRuntime.store=stock
check("owned runtime: identical full ownership and purchase checkpoint can be compared without effects",RLDealerRuntime.compareJournal(wal,1,meta.lineage) and not stock.recoveryRequired)
local changedWal=copy(wal);changedWal.data.recovery.clockMonths=101
local matched,matchReason=RLDealerRuntime.compareJournal(changedWal,1,meta.lineage)
check("owned runtime: equal purchase journal cannot hide different source ownership evidence",not matched
    and matchReason=="WAL_ASSET_RECONCILIATION_REQUIRED" and stock.recoveryRequired
    and RLDealerRuntime.evidence.checkpointRecovery.clockMonths==100 and RLDealerRuntime.evidence.wal.data.recovery.clockMonths==101)
