loadMod("tests/dealerreplaysim.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/dealer/RLDealerSourceState.lua")
loadMod("scripts/dealer/RLDealerSourceReproduction.lua")
loadMod("scripts/dealer/RLDealerSourceOwnership.lua")
loadAnimalSection("local Animal_mt = Class(Animal)", "function Animal:delete()")
loadAnimalSection("function Animal:getSubTypeIndex", "function Animal:increaseAge")
local O, B, S, R, Sim = RLDealerSourceOwnership, RLDealerSourceReproduction, RLDealerSourceState, RLDealerReplay, DealerReplaySim
local function clone(x) if type(x) ~= "table" then return x end; local c={};for k,v in pairs(x) do c[k]=clone(v) end;return c end
local function success(value,failure) assert(value,failure~=nil and failure.reason or "nil");return value end
local seed = Sim.seed("HOLSTEIN", "female", 1)
local index = Economics.find(seed.subType.name)
local system = g_currentMission.animalSystem
system.getSubTypeByName = function(_,name) local _,sub=Economics.find(name);return sub end
system.getTypeIndexBySubTypeIndex = function(_,i) local sub=system:getSubTypeByIndex(i);return sub~=nil and sub.typeIndex end
system.types = {}
g_currentMission.environment.weather={temperatureUpdater={currentMin=20}}
Animal.getDefaultMarks=function() return {} end
Animal.isHorse=function() return false end
Animal.updateInput=function(self) self.input.food=0 end
Animal.updateOutput=function(self) self.output.milk=0 end
local function resolver(name) local i,sub=Economics.find(name);return sub,i end
local function shell(uniqueId,genes)
    return Animal.new({age=-1,weight=35,health=100,gender="female",subTypeIndex=index,
        genetics=genes or clone(seed.genetics),uniqueId=uniqueId,farmId="ORIGINAL-HERD"})
end
local function fixture(pregnant)
    local entry={breedingWeightRatio=0.55,profile={minRecoveryMonth=3}}
    local history=Sim.history(seed,pregnant and 20.25 or 8.5,pregnant and "NORMAL_PRODUCTION" or nil,
        pregnant and {{kind="CONCEPTION",atMonths=17.125,parity=1}} or nil)
    local replay=success(R.run(seed,history,{daysPerMonth=1,entry=entry,pregnancySubTypes={[4]={seed.subType}}}))
    local record=success(S.capture(replay,200))
    local dam=shell("DAM-FIXED")
    for k,v in pairs(record.animal) do if k~="subTypeIndex" then dam[k]=clone(v) end end
    dam.birthday={day=12,month=2,year=2025,country=4,lastAgeMonth=10}
    dam.name,dam.children,dam.motherId,dam.fatherId,dam.deathEnabled="Persistent source dam",{},"GRAND-DAM","GRAND-SIRE",true
    if pregnant then
        local child=shell("UNBORN-FIXED",{metabolism=2.1,quality=2.25,productivity=1.8,fertility=0,health=0.9})
        child.motherId,child.fatherId="DAM-FIXED","SIRE-FIXED"
        dam.pregnancy={duration=10,expected={day=4,month=5,year=2027},pregnancies={child}}
    end
    local owner=success(B.createOwner("SOURCE-FIXED",10,{dam}))
    success(B.pinSire(owner,dam.uniqueId,{uniqueId="SIRE-FIXED",farmId="SIRE-HERD",breed="HOLSTEIN",genetics=clone(seed.genetics)}))
    return owner,dam,record,replay
end
local owner,dam,record=fixture(true)
local data=success(O.export(owner,{[dam.uniqueId]=record}))
local checksum=RLTradePersistence.checksum(data)
local random,ensure,sanitize=math.random,RLGrowth.ensureState,RLGrowth.sanitizeState
math.random=function() error("ownership restore may not draw") end
RLGrowth.ensureState=function() error("ownership restore may not migrate") end
RLGrowth.sanitizeState=function() error("ownership restore may not repair") end
local restored,metadata=O.restore(data,resolver,{isServer=true})
restored=success(restored,metadata)
math.random,RLGrowth.ensureState,RLGrowth.sanitizeState=random,ensure,sanitize
local live=restored.byId[dam.uniqueId]
check("source ownership: real negative-age shells restore exact adult physiology and herd identity without RNG/migration",
    live.weight==dam.weight and live.rlGrowth.reserveMassKg==dam.rlGrowth.reserveMassKg
    and live.uniqueId=="DAM-FIXED" and live.farmId=="ORIGINAL-HERD" and live.name==dam.name
    and live.motherId=="GRAND-DAM" and live.fatherId=="GRAND-SIRE" and live.birthday.country==4
    and live.clusterSystem==restored.clusterSystem and restored.spec:getNumOfAnimals()==1)
local unborn=live.pregnancy.pregnancies[1]
check("source ownership: true unborn identity, outlier genes and freemartin fertility survive independent codec",
    unborn.uniqueId=="UNBORN-FIXED" and unborn.farmId=="ORIGINAL-HERD" and unborn.genetics.metabolism==2.1
    and unborn.genetics.quality==2.25 and unborn.genetics.fertility==0 and unborn.age==-1 and unborn.rlGrowth==nil
    and live.pregnancy.duration==10 and live.pregnancy.expected.year==2027
    and restored.sireContexts[dam.uniqueId].uniqueId=="SIRE-FIXED")
check("source ownership: validation and restore do not rewrite persisted metadata",RLTradePersistence.checksum(data)==checksum
    and metadata.recordsByAnimalId[dam.uniqueId].history.saleAgeMonths==20.25)
unborn.genetics.metabolism=3
check("source ownership: restored genes and original serialized data have independent ownership",data.animals[1].pregnancy.fetuses[1].physiology.genetics.metabolism==2.1)
local refused,failure=O.restore(data,function() return nil end,{isServer=true})
check("source ownership: missing mod preserves complete raw owner and unborn contexts in quarantine",
    refused==nil and failure.reason=="SOURCE_OWNER_MISSING_SUBTYPE"
    and failure.quarantine.animals[1].pregnancy.fetuses[1].identity.uniqueId=="UNBORN-FIXED")
local corrupt=clone(data);corrupt.animals[1].pregnancy.fetuses[1].identity.uniqueId=corrupt.animals[1].identity.uniqueId
check("source ownership: duplicated adult/unborn identity refuses strictly",not O.validate(corrupt))
local stale=clone(data);stale.animals[1].physiology.rlGrowth.weightKg=stale.animals[1].physiology.rlGrowth.weightKg+1
check("source ownership: physiology corruption cannot invoke migration or weight repair",not O.validate(stale))
local reindex=101
local originalByIndex=system.getSubTypeByIndex
system.getSubTypeByIndex=function(self,i) if i==reindex then return seed.subType end;return originalByIndex(self,i) end
local moved=success(O.restore(data,function(name) local sub=resolver(name);return sub,reindex end,{isServer=true}))
check("source ownership: exact name resolution adopts current map subtype index after registry reorder",
    moved.byId[dam.uniqueId].subTypeIndex==reindex and moved.byId[dam.uniqueId]:getSubType().name==seed.subType.name)
system.getSubTypeByIndex=originalByIndex
-- True newborn data needs actual normal-birth evidence rather than an assumed history.
local newborn=shell("REAL-BORN",{metabolism=2.1,quality=2.25,productivity=1.8,fertility=0,health=0.9})
newborn.age,newborn.birthday,newborn.isPregnant,newborn.birthCount=0,{day=4,month=10,year=2026,country=4,lastAgeMonth=10},false,0
newborn.rlGrowth=success(RLGrowth.createBirthState(newborn,41.23456789));newborn.weight=newborn.rlGrowth.weightKg
newborn.isParent,newborn.isLactating,newborn.reproduction=false,false,0
local bornOwner=success(B.createOwner("SOURCE-BORN",10,{newborn}))
local event={version=1,eventId="REAL-BIRTH",sourceId="SOURCE-BORN",damId="SOURCE-DAM",stage="COMMITTED",
    atAgeMonths=27,cursorMonths=100,evidence="OBSERVED_SOURCE_BIRTH",sireContext={breed="HOLSTEIN"},
    selected={{uniqueId=newborn.uniqueId,farmId=newborn.farmId,subType=newborn.subType,genetics=clone(newborn.genetics)}},
    draws={{uniqueId=newborn.uniqueId,farmId=newborn.farmId,subType=newborn.subType,weightKg=newborn.weight,z=0,meanWeightKg=40}},
    result={newborns={{uniqueId=newborn.uniqueId,farmId=newborn.farmId,subType=newborn.subType,birthWeightKg=newborn.weight,alive=true}}}}
bornOwner.birthJournal[event.eventId],bornOwner.observedBirths[1]=event,clone(event)
local bornData=success(O.export(bornOwner,{}))
local bornRestored=success(O.restore(bornData,resolver,{isServer=true}))
check("source ownership: real-born source calves retain actual B_i and outlier genes without fake assumed history",
    bornRestored.byId["REAL-BORN"].weight==41.23456789 and bornRestored.byId["REAL-BORN"].rlGrowth.birthWeightKg==41.23456789
    and bornRestored.byId["REAL-BORN"].genetics.fertility==0 and bornData.animals[1].sourceRecord==nil)
local uncertain=clone(bornData);uncertain.birthJournal["REAL-BIRTH"].stage="PREPARED"
local uncertainOwner=success(O.restore(uncertain,resolver,{isServer=true}))
check("source ownership: PREPARED journal restores quarantine and cannot authorize automatic birth replay",
    uncertainOwner.quarantine["SOURCE-DAM"]=="SOURCE_BIRTH_UNCERTAIN" and uncertainOwner.byId["REAL-BORN"]~=nil)
local encoded=success(RLTradePersistence.canonical(data))
local decoded=success(RLTradePersistence.parse(encoded))
local decodedOwner=success(O.restore(decoded,resolver,{isServer=true}))
check("source ownership: canonical save format retains exact kg, fetal genes and identities",
    decodedOwner.byId[dam.uniqueId].weight==dam.weight
    and decodedOwner.byId[dam.uniqueId].pregnancy.pregnancies[1].genetics.quality==2.25
    and RLTradePersistence.checksum(decoded)==checksum)
local pendingOwner,pendingDam,prior,pregnantReplay=fixture(true)
local boundary=success(R.runToSourceBirth(pregnantReplay,27.125,{daysPerMonth=1,entry={breedingWeightRatio=0.55,profile={minRecoveryMonth=3}}}))
for _,key in ipairs({"age","health","weight","targetWeight","rlGrowth","bodyCondition","rlFeedGain","rlHealthCarry","input","output","reproduction"}) do pendingDam[key]=clone(boundary.animal[key]) end
pendingOwner.birthJournal["PENDING-BIRTH"]={version=1,eventId="PENDING-BIRTH",sourceId=pendingOwner.rlDealerSourceId,damId=pendingDam.uniqueId,
    stage="PREPARED",atAgeMonths=27.125,cursorMonths=206.875,sireContext=clone(pendingOwner.sireContexts[pendingDam.uniqueId]),
    selected={{uniqueId="UNBORN-FIXED",farmId="ORIGINAL-HERD",subType=seed.subType.name,genetics=clone(pendingDam.pregnancy.pregnancies[1].genetics)}}}
local pendingData=success(O.export(pendingOwner,{[pendingDam.uniqueId]=prior}))
local recoveredPending=success(O.restore(pendingData,resolver,{isServer=true}))
check("source ownership: PREPARED can persist exact term physiology plus prior ledger and true unborn IDs",
    recoveredPending.byId[pendingDam.uniqueId].reproduction==100
    and recoveredPending.byId[pendingDam.uniqueId].rlGrowth.ageMonths==27.125
    and recoveredPending.quarantine[pendingDam.uniqueId]=="SOURCE_BIRTH_UNCERTAIN"
    and recoveredPending.byId[pendingDam.uniqueId].pregnancy.pregnancies[1].uniqueId=="UNBORN-FIXED")
local unknown=clone(pendingData);unknown.birthJournal["PENDING-BIRTH"].stage="UNKNOWN"
local unknownOwner,unknownFailure=O.restore(unknown,resolver,{isServer=true})
check("source ownership: unknown journal stage preserves full owner as quarantine rather than guessing completion",
    unknownOwner==nil and unknownFailure.reason=="SOURCE_OWNER_JOURNAL"
    and unknownFailure.quarantine.animals[1].pregnancy.fetuses[1].identity.uniqueId=="UNBORN-FIXED")
loadMod("scripts/disease/RLDiseaseRecord.lua")
loadMod("scripts/disease/Disease.lua")
local model={title="SOURCE_CARRIER",archetype="GENETIC",endpoint="lifelong",animals={"COW"}}
local diseaseOwner,diseaseDam,diseaseRecord=fixture(false)
local disease=Disease.new(model,true,1);disease.monthsElapsed=1.23456789
 diseaseDam.diseases={disease}
local diseaseData=success(O.export(diseaseOwner,{[diseaseDam.uniqueId]=diseaseRecord}))
local diseaseRestored=success(O.restore(diseaseData,resolver,{isServer=true,resolveDiseaseModel=function(title) return title==model.title and model or nil end}))
check("source ownership: actual disease objects use strict model-keyed metadata and retain carrier state",
    diseaseRestored.byId[diseaseDam.uniqueId].diseases[1].model==model
    and diseaseRestored.byId[diseaseDam.uniqueId].diseases[1].isCarrier==true
    and diseaseRestored.byId[diseaseDam.uniqueId].diseases[1].monthsElapsed==1.23456789)
local absentDisease,diseaseFailure=O.restore(diseaseData,resolver,{isServer=true,resolveDiseaseModel=function() return nil end})
check("source ownership: missing disease models quarantine without dropping inherited carrier data",
    absentDisease==nil and diseaseFailure.reason=="SOURCE_OWNER_MISSING_DISEASE"
    and diseaseFailure.quarantine.animals[1].diseases[1].title==model.title)
