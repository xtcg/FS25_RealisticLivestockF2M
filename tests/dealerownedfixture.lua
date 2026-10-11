loadMod("tests/dealerreplaysim.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
for _,name in ipairs({"SourceState","SourceReproduction","SourceOwnership","ObservedGrowth","OwnedStock","Clock",
    "SourceFarm","ListingRegistry","Purchase","Persistence","StockService","Journal","OwnedProgress"}) do
    loadMod("scripts/dealer/RLDealer"..name..".lua")
end
loadAnimalSection("local Animal_mt = Class(Animal)", "function Animal:delete()")
loadAnimalSection("function Animal:getSubTypeIndex", "function Animal:increaseAge")
DealerOwnedFixture={}
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
Animal.getDefaultMarks=function() return {} end
Animal.isHorse=function() return false end
Animal.updateInput=function(self) self.input.food=0 end
Animal.updateOutput=function(self) self.output.milk=0 end
function DealerOwnedFixture.new(opts)
    opts=opts or {}
    local seed=DealerReplaySim.seed("HOLSTEIN","female",1)
    local index=Economics.find(seed.subType.name)
    local system=g_currentMission.animalSystem
    system.getSubTypeByName=function(_,name) local _,sub=Economics.find(name);return sub end
    system.getTypeIndexBySubTypeIndex=function(_,i) local sub=system:getSubTypeByIndex(i);return sub and sub.typeIndex end
    system.types={};g_currentMission.environment.weather={temperatureUpdater={currentMin=20}}
    local history=DealerReplaySim.history(seed,opts.pregnant and 20.25 or 8.5,opts.pregnant and "NORMAL_PRODUCTION" or nil,
        opts.pregnant and {{kind="CONCEPTION",atMonths=17.125,parity=1}} or nil)
    local replay=assert(RLDealerReplay.run(seed,history,{daysPerMonth=1,
        entry={breedingWeightRatio=0.55,profile={minRecoveryMonth=3}},pregnancySubTypes={[4]={seed.subType}}}))
    local record=assert(RLDealerSourceState.capture(replay,100))
    local function shell(id,genes)
        return Animal.new({age=-1,weight=35,health=100,gender="female",subTypeIndex=index,
            genetics=genes or copy(seed.genetics),uniqueId=id,farmId="SOURCE-HERD"})
    end
    local dam=shell("DAM")
    for k,v in pairs(record.animal) do if k~="subTypeIndex" then dam[k]=copy(v) end end
    dam.birthday={day=12,month=2,year=2025,country=4,lastAgeMonth=10}
    if opts.pregnant then dam.pregnancy={duration=10,expected={day=4,month=5,year=2027},pregnancies={shell("FETUS")}} end
    local animals={dam};local child,event,observed
    if opts.child then
        child=shell("CHILD",{metabolism=2.1,quality=2.25,productivity=1.8,fertility=0,health=0.9})
        child.age,child.birthCount,child.isParent,child.isPregnant,child.isLactating,child.reproduction=0,0,false,false,false,0
        child.birthday={day=2,month=10,year=2026,country=4,lastAgeMonth=10}
        assert(RLGrowth.initBirth(child,41.23456789))
        event={version=1,eventId="BIRTH",sourceId="OWNER",damId="PAST-DAM",cursorMonths=100,atAgeMonths=27,
            stage="COMMITTED",evidence="OBSERVED_SOURCE_BIRTH",day=2,month=10,year=2026,sireContext={breed="HOLSTEIN"},
            selected={{uniqueId=child.uniqueId,farmId=child.farmId,subType=child.subType,genetics=copy(child.genetics)}},
            draws={{uniqueId=child.uniqueId,farmId=child.farmId,subType=child.subType,weightKg=child.weight,meanWeightKg=40,z=0}},
            result={eventId="BIRTH",evidence="OBSERVED_SOURCE_BIRTH",newborns={{uniqueId=child.uniqueId,farmId=child.farmId,subType=child.subType,birthWeightKg=child.weight,alive=true}}}}
        observed=assert(RLDealerObservedGrowth.capture(child,100,event));animals[#animals+1]=child
    end
    local owner=assert(RLDealerSourceReproduction.createOwner("OWNER",10,animals))
    if opts.pregnant then assert(RLDealerSourceReproduction.pinSire(owner,"DAM",{uniqueId="SIRE",farmId="SIRE-HERD",breed="HOLSTEIN",genetics=copy(seed.genetics)})) end
    if event then owner.birthJournal.BIRTH,event.sourceId=event,"OWNER";owner.observedBirths[1]=copy(event) end
    local stock=assert(RLDealerStockService.new("owned-progress",100))
    stock.farm.sources.source=record;stock.sourceOwners={OWNER=owner};stock.sourceBindings={source={ownerId="OWNER",animalId="DAM"}}
    stock.sourceRecordsByOwner={OWNER={DAM=record}};stock.observedChildren=observed and {OWNER={CHILD=observed}} or {}
    local row=assert(RLDealerListingRegistry.createDraft(stock.listings,{sourceId="source"},"GROWING",100))
    row=assert(RLDealerListingRegistry.list(stock.listings,row.saleId,100))
    local ctx={isServer=true,resolveSubType=function(name) local i,sub=Economics.find(name);return sub,i end,
        resolveEntry=function() return {breedingWeightRatio=0.55,profile={minRecoveryMonth=3}} end,
        eligible=function() return true end,persistBarrier=function() return true end}
    return stock,ctx,row.saleId
end
