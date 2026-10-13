-- Execute the real helper before the unrelated GIANTS ::number extension.
do
    local f=assert(io.open(REPO.."scripts/utils/RLAnimalUtil.lua"));local source=f:read("*a");f:close()
    local start=assert(source:find("function RLAnimalUtil.toKey(",1,true))
    local finish=assert(source:find("\nend",start,true))
    RLAnimalUtil={};assert(load(source:sub(start,finish+3)))()
end
loadMod("scripts/animal/RLTradeSourceAdapter.lua")
loadMod("scripts/core/RLConstants.lua")
loadMod("scripts/dealer/RLDealerWorld.lua")
local W = RLDealerWorld
local function animal(id) return {uniqueId=id,farmId="HERD",birthday={country=4},age=10} end
local function encoded(a) return {identity={uniqueId=a.uniqueId,farmId=a.farmId,birthday=a.birthday}} end
local function private(a) return {version=1,owners={OWNER={animals=a and {encoded(a)} or {}}}} end
local function fixture()
    local m={getIsServer=function() return true end,
        placeableSystem={placeables={},pendingPlaceableLoadingData={},placeablesToDelete={},placeablesToLoad=0},
        vehicleSystem={vehicles={},pendingVehicleLoadingData={},pendingVehicleSavegameLoadings={},vehiclesToDelete={},vehiclesToLoad=0},
        animalSystem={animals={},aiAnimals={}}}
    local function owner(kind, a)
        local c={animals={},clustersToAdd={},clustersToRemove={},getClusters=function(self) return self.animals end,
            addPendingAddCluster=function() error("must not enqueue") end,
            addPendingRemoveCluster=function() error("must not enqueue") end,updateNow=function() error("must not flush") end}
        local o={isServer=true,getClusterSystem=function() return c end}
        o[kind=="PEN" and "spec_husbandryAnimals" or "spec_livestockTrailer"]={}
        if a then c.animals[1]=a;a.clusterSystem=c end
        local list=kind=="PEN" and m.placeableSystem.placeables or m.vehicleSystem.vehicles
        list[#list+1]=o
        return o,c
    end
    g_currentMission=m
    return m,assert(W.new({isServer=true,mission=m})),owner
end
check("world: constructor requires server", W.new({mission={}})==nil)
do
    local _,w,owner=fixture();local a=animal("1");a.farmId="1";owner("PEN",a)
    check("world: native missing-owner fallback is not a stable identity",w.checkGlobalIdentities(private())==nil)
end
do
    local _,w=fixture();g_currentMission={}
    check("world: detached mission rejected for both callbacks",w.allOwners()==nil and w.checkGlobalIdentities(private())==nil)
end
for _,phase in ipairs({"owners","identities"}) do
    local _,w,owner=fixture();local o,c=owner("PEN",animal("A"));local calls=0
    local c2={animals={},clustersToAdd={[{}]=true},clustersToRemove={},getClusters=c.getClusters,
        addPendingAddCluster=c.addPendingAddCluster,addPendingRemoveCluster=c.addPendingRemoveCluster,updateNow=c.updateNow}
    o.getClusterSystem=function() calls=calls+1;return calls==1 and c or c2 end
    local value=phase=="owners" and w.allOwners() or w.checkGlobalIdentities(private())
    check("world: owner resolving to different busy cluster held "..phase,value==nil)
end
for _,mutation in ipairs({"pending","replace","registry","backlink","mission"}) do
    local m,w,owner=fixture();local _,c=owner("PEN",animal("A"))
    c.getClusters=function(self)
        if mutation=="pending" then self.clustersToAdd[animal("P")]=true
        elseif mutation=="replace" then local a=animal("NEW");a.clusterSystem=self;self.animals[1]=a
        elseif mutation=="registry" then m.placeableSystem.placeables[2]={}
        elseif mutation=="backlink" then self.animals[1].clusterSystem={}
        else g_currentMission={} end
        return self.animals
    end
    check("world: getClusters synchronous mutation held "..mutation,w.checkGlobalIdentities(private())==nil)
end
do
    local m,w,owner=fixture();local _,c=owner("PEN",animal("A"));local helper=RLAnimalUtil.toKey
    RLAnimalUtil.toKey=function(...)
        m.vehicleSystem.vehicles[1]={};c.clustersToRemove[c.animals[1]]=true
        return helper(...)
    end
    check("world: identity helper registry/pending mutation held",w.checkGlobalIdentities(private())==nil)
    RLAnimalUtil.toKey=helper
end
for _,mutation in ipairs({"identity","fetus","rideable","legacy"}) do
    local m,w,owner=fixture();local a=animal("A");owner("PEN",a)
    a.pregnancy={pregnancies={{age=-1}}}
    local riding={isServer=true,spec_rideable={cluster=animal("R")}}
    m.vehicleSystem.vehicles[1]=riding
    m.animalSystem.animals[4]={animal("L")}
    local helper=RLAnimalUtil.toKey
    RLAnimalUtil.toKey=function(farm,id,country)
        if id=="PRIVATE" then
            if mutation=="identity" then a.uniqueId="PRIVATE"
            elseif mutation=="fetus" then a.pregnancy.pregnancies[1]={age=-1}
            elseif mutation=="rideable" then riding.spec_rideable.cluster=animal("PRIVATE")
            else m.animalSystem.animals[4][1]=animal("PRIVATE") end
        end
        return helper(farm,id,country)
    end
    check("world: late identity helper mutation held "..mutation,w.checkGlobalIdentities(private(animal("PRIVATE")))==nil)
    RLAnimalUtil.toKey=helper
end
for _,value in ipairs({"0","0-0","1-1","-1",""}) do
    local _,w,owner=fixture();owner("PEN",animal(value))
    check("world: placeholder identity rejected "..value,w.checkGlobalIdentities(private())==nil)
end
do
    local _,w,owner=fixture();local a=animal("DEAD");a.isDead=true;owner("PEN",a)
    check("world: dead animals still reserve global identity",w.checkGlobalIdentities(private(a))==nil)
    a.birthday.country=9999
    check("world: nonexistent country rejected",w.checkGlobalIdentities(private())==nil)
end
do
    local m,w,owner=fixture();local p=owner("PEN",animal("A"));local t=owner("TRAILER",animal("B"))
    m.placeableSystem.placeables[2]={};m.vehicleSystem.vehicles[2]={}
    local all=assert(w.allOwners())
    check("world: complete pen/trailer inventory without farm filtering",#all==2 and all[1]==p and all[2]==t)
    local random=math.random;math.random=function() error("must not draw") end
    check("world: pure scan accepts distinct private inventory",w.checkGlobalIdentities(private(animal("PRIVATE")))==true)
    math.random=random
    local _,why=w.checkGlobalIdentities(private(animal("A")))
    check("world: private/world conflict uses actual identity helper",why and why:find("HERD A 4",1,true)~=nil)
end
for _,entry in ipairs({{"placeableSystem","pendingPlaceableLoadingData"},{"placeableSystem","placeablesToDelete"},
    {"vehicleSystem","pendingVehicleLoadingData"},{"vehicleSystem","pendingVehicleSavegameLoadings"},{"vehicleSystem","vehiclesToDelete"}}) do
    for _,missing in ipairs({false,true}) do
        local m,w=fixture();m[entry[1]][entry[2]]=missing and nil or {true}
        -- Avoid Lua's nil-valued ternary.
        if missing then m[entry[1]][entry[2]]=nil end
        check("world: loading/deletion field fails closed "..entry[2]..tostring(missing),w.allOwners()==nil and w.checkGlobalIdentities(private())==nil)
    end
end
for _,system in ipairs({"placeableSystem","vehicleSystem"}) do
    local m,w=fixture();m[system][system=="placeableSystem" and "placeablesToLoad" or "vehiclesToLoad"]=1
    check("world: load counter "..system,w.allOwners()==nil)
end
for _,queue in ipairs({"clustersToAdd","clustersToRemove"}) do
    local _,w,owner=fixture();local _,c=owner("PEN",animal("A"));c[queue][animal("Q")]=false
    check("world: any pending queue holds "..queue,w.allOwners()==nil)
end
do
    local m,w,owner=fixture();local a=animal("A");local p,c=owner("PEN",a)
    c.getClusters=function() return {} end
    check("world: getClusters/animals mismatch",w.checkGlobalIdentities(private())==nil)
    c.getClusters=function() error("read failure") end
    check("world: unreadable member API",w.checkGlobalIdentities(private())==nil)
    c.getClusters=function(self) return self.animals end
    m.placeableSystem.placeables[2]=p
    check("world: repeated registry object",w.allOwners()==nil)
end
for _,domain in ipairs({"rideable","animals","aiAnimals"}) do
    local m,w=fixture();local a=animal("A")
    if domain=="rideable" then m.vehicleSystem.vehicles[1]={isServer=true,spec_rideable={cluster=a}}
    else m.animalSystem[domain][4]={a} end
    check("world: scans external domain "..domain,w.checkGlobalIdentities(private(a))==nil)
    check("world: external unique domain accepted "..domain,w.checkGlobalIdentities(private())==true)
end
do
    local m,w,owner=fixture();local a=animal("A");owner("PEN",a)
    m.vehicleSystem.vehicles[1]={isServer=true,spec_rideable={cluster=a}}
    local _,why=w.checkGlobalIdentities(private())
    check("world: rideable/pen alias held with both domains",why and why:find("OBJECT_ALIAS:OWNER:1/ANIMAL:1:RIDEABLE:1",1,true)~=nil)
end
do
    local _,w,owner=fixture();local a=animal("A");a.pregnancy={pregnancies={{age=-1}}};owner("PEN",a)
    check("world: ordinary unassigned fetus accepted",w.checkGlobalIdentities(private())==true)
    a.pregnancy.pregnancies[1].farmId="PRESET"
    check("world: unassigned fetus may carry preset herd",w.checkGlobalIdentities(private())==true)
    a.pregnancy.pregnancies[1].uniqueId="FIXED"
    check("world: world fixed fetus without birth country held",w.checkGlobalIdentities(private())==nil)
    a.pregnancy.pregnancies[1].birthday={country=4}
    check("world: fixed fetus with complete identity accepted",w.checkGlobalIdentities(private())==true)
    local b=animal("FIXED");b.farmId="PRESET"
    check("world: real fetus conflicts private inventory",w.checkGlobalIdentities(private(b))==nil)
end
do
    local _,w=fixture();local p=private(animal("P"));p.owners.OTHER={animals={encoded(animal("P"))}}
    check("world: private inventory globally unique",w.checkGlobalIdentities(p)==nil)
    p.owners.OTHER=nil;p.owners.OWNER.animals[2]=p.owners.OWNER.animals[1]
    check("world: private object alias rejected",w.checkGlobalIdentities(p)==nil)
end
for _,bad in ipairs({{}, {version=2,owners={}}, {version=1,owners={OWNER={animals={[2]={}}}}}}) do
    local _,w=fixture();check("world: malformed private schema",w.checkGlobalIdentities(bad)==nil)
end
-- Use actual private owner codec/engine fetus shell, not a handwritten birthday.
loadMod("tests/dealerownedfixture.lua")
local ownedMission=g_currentMission
do
    local f=assert(io.open(REPO.."scripts/animal/AnimalReproduction.lua"));local source=f:read("*a");f:close()
    assert(load(assert(source:match("AnimalReproduction = { SOURCE_BIRTH_VERSION = %d+ }"))))()
end
do
    local s=DealerOwnedFixture.new({pregnant=true})
    local payload=assert(RLDealerOwnedStock.export(s.sourceOwners,s.sourceBindings,s.sourceRecordsByOwner,s.observedChildren,s.farm.sources,s.farm.clock.months,s.retiredSources))
    local m,w=fixture()
    check("world: real owned pregnant codec accepted with pinned source birth rule",w.checkGlobalIdentities(payload)==true)
    m.animalSystem.animals[1]={{uniqueId="FETUS",farmId="SOURCE-HERD",birthday={country=4}}}
    check("world: private unborn dam-country key conflicts actual exterior",w.checkGlobalIdentities(payload)==nil)
    m.animalSystem.animals={};local version=AnimalReproduction.SOURCE_BIRTH_VERSION;AnimalReproduction.SOURCE_BIRTH_VERSION=2
    check("world: unknown source birth version cannot infer unborn country",w.checkGlobalIdentities(payload)==nil)
    AnimalReproduction.SOURCE_BIRTH_VERSION=version
end

do
    local m,w=fixture();m.getIsServer=function() return false end
    check("world: server authority rechecked",w.allOwners()==nil)
end
do
    local m,w=fixture();m.vehicleSystem.vehicles={[2]={}}
    check("world: sparse authoritative registry rejected",w.allOwners()==nil)
end
do
    local m,w,owner=fixture();owner("PEN",animal("A"));owner("TRAILER",animal("A"))
    check("world: duplicate identity across real owners rejected",w.checkGlobalIdentities(private())==nil)
    m.animalSystem.aiAnimals=nil
    check("world: missing legacy registry rejected",w.checkGlobalIdentities(private())==nil)
end
loadMod("scripts/core/RLConstants.lua")
loadAnimalSection("function Animal:getIdentifiers()", "function Animal:compareIdentifiers")
loadMod("scripts/dealer/RLDealerHandoff.lua")
loadMod("scripts/dealer/RLDealerSourceFactory.lua")
do
    g_currentMission=ownedMission
    local _,baseCtx=DealerOwnedFixture.new()
    local seed=DealerReplaySim.seed("HOLSTEIN","female",1)
    local entry=RLDealerStockPolicy.getEntry(RLDealerStockPolicy.getConfig(),seed.subType,"COW")
    local purpose=RLDealerStockPolicy.findPurpose(entry,"female","HEIFER_IN_CALF")
    local history=DealerReplaySim.history(seed,20.25,"NORMAL_PRODUCTION",{{kind="CONCEPTION",atMonths=17.125,parity=1}})
    history.source="DAIRY_HERD"
    local candidate=assert(RLDealerReplay.evaluate(seed,history,entry,purpose,
        {maxBuyAge=72,weaningMonth=3,union={{0,72}},lactates=true},{daysPerMonth=1,pregnancySubTypes={[4]={seed.subType}}}))
    local p={version=1,requestId="FACTORY-WORLD",sourceOwnerId="FACTORY",capacity=5,
        adult={uniqueId="NEW-DAM",farmId="NEW-HERD",subType=seed.subType.name,
            birthday={day=12,month=2,year=2025,country=4,lastAgeMonth=10},deathEnabled=true,diseases={}},
        evidence={version=1,requestId="FACTORY-WORLD",selectionId="FIXED"},
        pregnancy={duration=10,expected={day=4,month=5,year=2027},fetuses={{uniqueId="NEW-FETUS",farmId="NEW-HERD",
            subType=seed.subType.name,genetics={metabolism=2.1,quality=2.25,productivity=1.8,fertility=0,health=0.9}}}},
        sire={uniqueId="SIRE",farmId="SIRE-HERD",breed="HOLSTEIN",subType=seed.subType.name,
            genetics={metabolism=1,quality=1,productivity=1,fertility=1,health=1}}}
    g_server={}
    local material=assert(RLDealerSourceFactory.materialize(candidate,p,{isServer=true,currentCursorMonths=200,resolveSubType=baseCtx.resolveSubType}))
    local m,w=fixture();local payload={version=1,owners={FACTORY=material.ownership}}
    check("world: actual factory pregnant ownership accepted",w.checkGlobalIdentities(payload)==true)
    m.animalSystem.animals[4]={{uniqueId="NEW-FETUS",farmId="NEW-HERD",birthday={country=4}}}
    check("world: actual factory fetus conflicts exterior by authoritative dam country",w.checkGlobalIdentities(payload)==nil)
    m.animalSystem.animals={}
    local child=payload.owners.FACTORY.animals[1].pregnancy.fetuses[1]
    child.identity.birthday={country=2}
    check("world: private fetus cannot contradict source birth country",w.checkGlobalIdentities(payload)==nil)
    child.identity.birthday=nil
    payload.owners["0-0 provenance owner"]=payload.owners.FACTORY;payload.owners.FACTORY=nil
    check("world: provenance owner names are not animal identity placeholders",w.checkGlobalIdentities(payload)==true)
    local malformed=private();malformed.owners.OWNER.animals[1]=animal("FAKE-ENCODED")
    check("world: missing encoded identity cannot fall through to live schema",w.checkGlobalIdentities(malformed)==nil)
end
