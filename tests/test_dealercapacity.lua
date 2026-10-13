loadMod("tests/dealerownedfixture.lua")
loadAnimalSection("function Animal:getNumAnimals()", "function Animal:getSubTypeIndex()")
loadMod("scripts/animal/RLTradeSourceAdapter.lua")
loadMod("scripts/bridge/RLHusbandryProfiles.lua")
loadMod("scripts/dealer/RLDealerWorld.lua")
loadMod("scripts/dealer/RLDealerCapacity.lua")
local C=RLDealerCapacity
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local function fixture(kind)
    local stock,base,saleId=DealerOwnedFixture.new()
    local mission=g_currentMission
    mission.getIsServer=function() return true end
    local system=mission.animalSystem
    local animalType={typeIndex=AnimalType.COW,subTypes={}}
    system.getTypeByIndex=function(_,index) if index==AnimalType.COW then return animalType end end
    local cluster={animals={},clustersToAdd={},clustersToRemove={}}
    cluster.getClusters=function(self) return self.animals end
    cluster.addPendingAddCluster=function() error("capacity must not enqueue") end
    cluster.addPendingRemoveCluster=function() error("capacity must not enqueue") end
    cluster.updateNow=function() error("capacity must not flush") end
    local target={isServer=true,getClusterSystem=function() return cluster end,configFileName="/capacity/test.xml"}
    if kind=="TRAILER" then target.spec_livestockTrailer={clusterSystem=cluster,animalTypeIndexToPlaces={[AnimalType.COW]={slots={1,2},usedSlots=0}}}
    else target.spec_husbandryAnimals={animalTypeIndex=AnimalType.COW,maxNumAnimals=2,clusterSystem=cluster} end
    -- Engine stand-ins reproduce GDN FS25 LivestockTrailer getMax/getNum/free
    -- (source lines 363/346/387) and PlaceableHusbandryAnimals (672/659/679).
    function target:getCurrentAnimalType()
        local a=cluster.animals[1]
        return a and system:getTypeByIndex(a:getSubType().typeIndex) or nil
    end
    function target:getSupportsAnimalSubType(index)
        local sub=system:getSubTypeByIndex(index)
        if not sub then return false end
        if self.spec_husbandryAnimals then return sub.typeIndex==self.spec_husbandryAnimals.animalTypeIndex end
        return self.spec_livestockTrailer.animalTypeIndexToPlaces[sub.typeIndex]~=nil
    end
    function target:getMaxNumOfAnimals(t)
        if self.spec_husbandryAnimals then return self.spec_husbandryAnimals.maxNumAnimals end
        local current=self:getCurrentAnimalType()
        if (t==nil and current==nil) or (current~=nil and t~=current) then return 0 end
        local place=self.spec_livestockTrailer.animalTypeIndexToPlaces[(t or current).typeIndex]
        return place and #place.slots or 0
    end
    function target:getNumOfAnimals()
        if self.spec_husbandryAnimals then local n=0;for _,a in ipairs(cluster.animals) do n=n+a.numAnimals end;return n end
        if #cluster.animals==0 then return 0 end
        return self.spec_livestockTrailer.animalTypeIndexToPlaces[cluster.animals[1]:getSubType().typeIndex].usedSlots or 0
    end
    function target:getNumOfFreeAnimalSlots(index)
        if self.spec_husbandryAnimals then return math.max(self:getMaxNumOfAnimals()-self:getNumOfAnimals(),0) end
        local sub=system:getSubTypeByIndex(index)
        return self:getMaxNumOfAnimals(system:getTypeByIndex(sub.typeIndex))-self:getNumOfAnimals()
    end
    mission.placeableSystem={placeables=kind=="TRAILER" and {} or {target},pendingPlaceableLoadingData={},placeablesToDelete={}}
    mission.vehicleSystem={vehicles=kind=="TRAILER" and {target} or {},pendingVehicleLoadingData={},pendingVehicleSavegameLoadings={},vehiclesToDelete={}}
    RLHusbandryProfiles.config={profiles={},husbandries={},constructions={}}
    local world=assert(RLDealerWorld.new({isServer=true,mission=mission}))
    local ctx={isServer=true,mission=mission,stock=stock,resolveSubType=base.resolveSubType,allOwners=world.allOwners}
    local listings={RLDealerListingRegistry.get(stock.listings,saleId)}
    return ctx,target,cluster,listings,{currentClock=100},animalType
end
local function duplicateSource(ctx,listings)
    local stock=ctx.stock
    local donor=DealerOwnedFixture.new()
    local animal=donor.sourceOwners.OWNER.byId.DAM
    animal.uniqueId="DAM-2";animal.clusterSystem=stock.sourceOwners.OWNER.clusterSystem
    stock.sourceOwners.OWNER.animals[2]=animal;stock.sourceOwners.OWNER.byId[animal.uniqueId]=animal
    stock.farm.sources.second=copy(stock.farm.sources.source)
    stock.sourceBindings.second={ownerId="OWNER",animalId=animal.uniqueId}
    stock.sourceRecordsByOwner.OWNER[animal.uniqueId]=copy(stock.farm.sources.second)
    local row=assert(RLDealerListingRegistry.createDraft(stock.listings,{sourceId="second"},"GROWING",100))
    listings[2]=assert(RLDealerListingRegistry.list(stock.listings,row.saleId,100))
end
for _,kind in ipairs({"PEN","TRAILER"}) do
    local ctx,target,cluster,listings,context=fixture(kind)
    local validate=assert(C.new(ctx))
    local random,new,ensure,apply=math.random,Animal.new,RLGrowth.ensureState,RLHusbandryProfiles.apply
    math.random=function() error("capacity RNG") end;Animal.new=function() error("capacity shell") end
    RLGrowth.ensureState=function() error("capacity migration") end;RLHusbandryProfiles.apply=function() error("capacity apply") end
    local ok,why=validate(target,listings,context)
    math.random,Animal.new,RLGrowth.ensureState,RLHusbandryProfiles.apply=random,new,ensure,apply
    check("dealer capacity: "..kind.." real source passes without sampling/materialization/migration/profile apply",ok and #cluster.animals==0)
    duplicateSource(ctx,listings)
    ok,why=validate(target,listings,context)
    check("dealer capacity: "..kind.." complete two-head batch exactly fills two slots",ok)
    local resident={numAnimals=1,clusterSystem=cluster,getNumAnimals=function() return 1 end,
        getSubType=function() return ctx.resolveSubType(ctx.stock.farm.sources.source.animal.subType) end}
    cluster.animals={resident}
    if target.spec_livestockTrailer then target.spec_livestockTrailer.animalTypeIndexToPlaces[AnimalType.COW].usedSlots=1 end
    ok,why=validate(target,listings,context)
    check("dealer capacity: "..kind.." whole batch refuses one remaining slot despite each single fitting",not ok and why:find("NOT_ENOUGH_SPACE",1,true))
end
local cases={
    {"not server",function(c,t,q,l,x)c.mission.getIsServer=function()return false end end,"SERVER_REQUIRED"},
    {"stale clock",function(c,t,q,l,x)x.currentClock=99 end,"SOURCE_CLOCK"},
    {"source recovery",function(c)c.stock.recoveryRequired=true end,"RECOVERY_REQUIRED"},
    {"source fence",function(c)c.stock.sourceUpdateInProgress=true end,"SOURCE_UPDATE_IN_PROGRESS"},
    {"missing source",function(c)c.stock.farm.sources.source=nil end,"OWNED_STOCK_SOURCE_MISMATCH"},
    {"duplicate listing",function(c,t,q,l)l[2]=copy(l[1]) end,"DUPLICATE_OR_INVALID_LISTING"},
    {"forged payload",function(c,t,q,l)l[1].payload.sourceId="foreign" end,"LISTING_NOT_CURRENT"},
    {"expired",function(c,t,q,l)c.stock.listings.records[l[1].saleId].expiresAtMonths=100 end,"LISTING_NOT_CURRENT"},
    {"world incomplete",function(c)c.allOwners=function()return {} end end,"WORLD_OWNERS_INCOMPLETE"},
    {"world duplicate",function(c,t)c.allOwners=function()return {t,t} end end,"WORLD_OWNERS_INCOMPLETE"},
    {"add queue even false",function(c,t,q)q.clustersToAdd[{}]=false end,"OWNER_QUEUE_BUSY"},
    {"remove queue",function(c,t,q)q.clustersToRemove[{}]=true end,"OWNER_QUEUE_BUSY"},
    {"unsupported subtype",function(c,t)t.getSupportsAnimalSubType=function()return false end end,"ANIMAL_NOT_SUPPORTED"},
    {"unreadable maximum",function(c,t)t.getMaxNumOfAnimals=function()return math.huge end end,"NOT_ENOUGH_SPACE"},
    {"inflated free",function(c,t)t.getNumOfFreeAnimalSlots=function()return 3 end end,"CAPACITY_INCONSISTENT"},
    {"unknown subtype",function(c)c.resolveSubType=function()return nil end end,"SOURCE_SUBTYPE_OR_PHYSIOLOGY"},
    {"construction not ready",function(c,t)t.spec_constructible={stateIndex=1,stateMachine={{name="SETUP",inputs={{remainingAmount=1}}}},stateTransitions={[1]=2}} end,"PEN_NOT_BUILT"},
    {"profile age",function(c,t)t.rlPenRule={female=true,minAge=9} end,"PEN_RULES"},
    {"profile sex",function(c,t)t.rlPenRule={female=false} end,"PEN_RULES"},
    {"profile breed",function(c,t)t.rlPenRule={female=true,breeds={ANGUS=true}} end,"PEN_RULES"},
    {"map age",function(c,t)t.spec_husbandryAnimals.subtypeFilterAgeMin=9 end,"AGE_TOO_YOUNG"},
    {"map visual",function(c,t)t.rlPenRule={female=true};t.spec_husbandryAnimals.subtypeFilterAllowedSubTypes={}
        t.spec_husbandryAnimals.rlPenProfileApplied=true end,"PEN_RULES"}}
for _,case in ipairs(cases) do
    local c,t,q,l,x=fixture("PEN");case[2](c,t,q,l,x)
    local validate=assert(C.new(c));local ok,why=validate(t,l,x)
    check("dealer capacity: "..case[1].." conservatively refuses",not ok and why:find(case[3],1,true))
end
do
    local c,t,q,l,x,animalType=fixture("TRAILER")
    t.getCurrentAnimalType=function()return {typeIndex=999} end
    local ok,why=assert(C.new(c))(t,l,x)
    check("dealer capacity: trailer current engine animalType must exactly match whole batch",not ok and why:find("TRAILER_CURRENT_TYPE",1,true))
end
do
    local c,t,q,l,x=fixture("PEN")
    local actual=t.getNumOfFreeAnimalSlots
    t.getNumOfFreeAnimalSlots=function(self,index)c.stock.sourceOwners.OWNER.capacity=11;return actual(self,index) end
    local ok,why=assert(C.new(c))(t,l,x)
    check("dealer capacity: foreign getter changing authoritative ownership cannot pass frozen source proof",not ok and why:find("SOURCE_SNAPSHOT_CHANGED",1,true))
end
do
    local c,t,q,l,x=fixture("PEN")
    RLHusbandryProfiles.config=nil;RLMapBridge={activeBridges={}}
    t.spec_constructible={stateIndex=1,stateMachine={{name="DONE",inputs={}}},stateTransitions={}}
    local logs=#LOG
    local ok,why=assert(C.new(c))(t,l,x)
    check("dealer capacity: first lookup with nil config and pen caches writes nothing on the pen and never logs; the parsed config is memoized",
        ok and RLHusbandryProfiles.config~=nil and RLHusbandryProfiles.readDepth==0
        and t.rlPenRule==nil and t.rlPenConstruction==nil and t.spec_husbandryAnimals.rlPenProfileApplied==nil and #LOG==logs)
    RLHusbandryProfiles.checkAnimal(t,{subTypeIndex=select(2,c.resolveSubType(c.stock.farm.sources.source.animal.subType)),age=8,gender="female"})
    check("dealer capacity: legacy profile path still populates original lookup caches",RLHusbandryProfiles.config~=nil and t.rlPenRule==false and t.rlPenConstruction==false)
end
do
    -- A pen whose profile is not applied yet still has the map's own (narrower) filter: the read checks
    -- the fields apply would write, so it admits what a purchase (which applies first) admits.
    local c,t,q,l,x=fixture("PEN")
    t.rlPenRule={female=true};t.spec_husbandryAnimals.subtypeFilterAllowedSubTypes={}
    local index=select(2,c.resolveSubType(c.stock.farm.sources.source.animal.subType))
    local cowType=g_currentMission.animalSystem:getTypeByIndex(AnimalType.COW)
    cowType.subTypes={index}
    local ok,why=assert(C.new(c))(t,l,x)
    check("dealer capacity: a profile not yet applied is read as apply would write it, not the map's default filter",ok==true
        and t.spec_husbandryAnimals.rlPenProfileApplied==nil and next(t.spec_husbandryAnimals.subtypeFilterAllowedSubTypes)==nil)
end
do
    local depth=RLHusbandryProfiles.readDepth
    local okCall=pcall(RLHusbandryProfiles.read,function() error("boom") end)
    check("dealer capacity: a read scope closes when its body throws",not okCall and RLHusbandryProfiles.readDepth==depth)
end
for _,fault in ipairs({"replace","pending","cluster"}) do
    local c,t,q,l,x=fixture("PEN")
    local resident={numAnimals=1,clusterSystem=q,getNumAnimals=function()return 1 end}
    q.animals={resident}
    local actual=t.getNumOfFreeAnimalSlots
    t.getNumOfFreeAnimalSlots=function(self,index)
        local free=actual(self,index)
        if fault=="replace" then q.animals[1]={numAnimals=1,clusterSystem=q,getNumAnimals=function()return 1 end} end
        if fault=="pending" then q.clustersToAdd[{}]=false end
        if fault=="cluster" then local other=copy(q);t.getClusterSystem=function()return other end end
        return free
    end
    local ok,why=assert(C.new(c))(t,l,x)
    check("dealer capacity: getter "..fault.." cannot pass same-count destination witness",not ok)
end
do
    local c,t,q,l,x=fixture("PEN")
    local resident={numAnimals=1,clusterSystem=q,getNumAnimals=function()return 1 end}
    q.animals={resident}
    local allOwners,calls=c.allOwners,0
    c.allOwners=function()
        calls=calls+1
        if calls==2 then q.animals[1]={numAnimals=1,clusterSystem=q,getNumAnimals=function()return 1 end} end
        return allOwners()
    end
    local ok,why=assert(C.new(c))(t,l,x)
    check("dealer capacity: final world getter replacing same-count member is held",not ok and why:find("DESTINATION_MEMBERS_CHANGED",1,true))
end
-- Reuse only the composition test's setup, not its assertions or fake capacity
-- callback. Actual PurchaseAdapter/Target/Source/Money/Journal compose below.
do
    local profiles=RLHusbandryProfiles
    local file=assert(io.open(REPO.."tests/test_dealerpurchaseadapter.lua","r"))
    local source=file:read("*a");file:close()
    local boundary=assert(source:find("local stock,adapter,w,request,principal=fixture()",1,true))
    local purchaseFixture=assert(load(source:sub(1,boundary-1).."\nreturn fixture", "purchase composition fixture"))()
    local stock,adapter,w,request,principal=purchaseFixture()
    RLHusbandryProfiles=profiles
    local mission=w.context.mission
    mission.placeableSystem={placeables={w.dest},pendingPlaceableLoadingData={},placeablesToDelete={}}
    mission.vehicleSystem={vehicles={},pendingVehicleLoadingData={},pendingVehicleSavegameLoadings={},vehiclesToDelete={}}
    local system=mission.animalSystem
    local animalType={typeIndex=AnimalType.COW}
    system.getTypeByIndex=function(_,index) return index==AnimalType.COW and animalType or nil end
    w.dest.spec_husbandryAnimals={animalTypeIndex=AnimalType.COW,maxNumAnimals=3,clusterSystem=w.cluster}
    w.dest.getMaxNumOfAnimals=function(self)return self.spec_husbandryAnimals.maxNumAnimals end
    w.dest.getNumOfAnimals=function()return #w.cluster.animals end
    w.dest.getNumOfFreeAnimalSlots=function(self)return self:getMaxNumOfAnimals()-self:getNumOfAnimals() end
    w.dest.getSupportsAnimalSubType=function(_,index)local sub=system:getSubTypeByIndex(index);return sub and sub.typeIndex==AnimalType.COW end
    local sourceRecord=stock.farm.sources["source-1"]
    local resident=Animal.new({age=-1,weight=35,health=100,gender="female",subTypeIndex=w.source[1].subTypeIndex,
        genetics=copy(w.source[1].genetics),uniqueId="CAPACITY-RESIDENT",farmId="TARGET-HERD"})
    for k,v in pairs(sourceRecord.animal) do if k~="subTypeIndex" then resident[k]=copy(v) end end
    resident.birthday={day=12,month=2,year=2025,country=4,lastAgeMonth=10};resident.clusterSystem=w.cluster
    w.cluster.animals={resident}
    local checks=0
    local validate=assert(C.new({isServer=true,mission=mission,stock=stock,resolveSubType=w.context.resolveSubType,allOwners=w.context.allOwners}))
    w.context.validateCapacity=function(...)
        checks=checks+1
        assert(#w.owner.animals==2 and #w.cluster.animals==1,"capacity must run before transfer")
        return validate(...)
    end
    local result,why=RLDealerPurchase.execute(stock.purchase,request,principal,adapter)
    check("dealer capacity integration: actual PurchaseAdapter buys whole batch into exact remaining slots",result
        and result.status=="COMMITTED" and checks==4 and #w.cluster.animals==3 and #w.owner.animals==0
        and w.farm.money==800 and w.calls==1)
    check("dealer capacity integration: existing target member and both purchased stable identities survive",w.cluster.animals[1]==resident
        and #w.cluster.animals==3 and resident.uniqueId=="CAPACITY-RESIDENT" and w.cluster.animals[2].farmId=="SOURCE-HERD" and w.cluster.animals[3].farmId=="SOURCE-HERD"
        and w.cluster.animals[2].uniqueId~=w.cluster.animals[3].uniqueId)
end
