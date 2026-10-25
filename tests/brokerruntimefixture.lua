loadMod("tests/brokerdemandfixture.lua")
loadMod("tests/fixtures/broker_engine.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
for _,name in ipairs({"RLMarketSchema","RLMarketSpecies","RLMarketSnapshot","RLMarketEnginePrice","RLMarketResourceLock",
    "RLAnimalAcquisition","RLBrokerEligibility","RLBrokerQuota","RLBrokerMonth","RLBrokerPricePolicy","RLBrokerOrderService","RLBrokerTransaction",
    "RLBrokerCattlePolicy","RLBrokerRuntime"}) do loadMod("scripts/market/"..name..".lua") end
local D=RLMarketData
local function cp(v) return assert(D.copy(v)) end
local function setup()
    RLMarketResourceLock.instance=nil
    local s,a,b=BrokerEngineFixture.source("PEN")
    local m,f,mt=BrokerEngineFixture.money()
    m.placeableSystem=s.mission.placeableSystem;m.vehicleSystem=s.mission.vehicleSystem
    m.missionDynamicInfo={isMultiplayer=false};m.environment={currentYear=1,currentPeriod=2,daysPerPeriod=1,currentDayInPeriod=1}
    m.farm=1;m.permission=true
    function m:getFarmId() return self.farm end
    function m:getHasPlayerPermission() return self.permission end
    local subtype={name="BULL_ANGUS",breed="ANGUS",typeIndex=1}
    m.animalSystem={getSubTypeByIndex=function() return subtype end,getTypeByIndex=function() return {name="COW"} end,
        getAnimalTransportFee=function() return 25 end}
    g_currentMission=m;g_diseaseManager={diseasesEnabled=false}
    RLDealerStockPolicy={getConfig=function() return {} end,getEntry=function() return {use="beef"} end}
    RLGrowth={getContinuousAge=function(x) return x.age end,covers=function() return true end,getBinding=function() return {} end,
        getFrameTarget=function() return 800 end,getBirthWeight=function() return 30 end,
        buildCurve=function() return {value=function() return 100 end} end}
    RLCalfRearing={STAGE_WEANED="WEANED",getStage=function() return "WEANED" end}
    AnimalMoveEvent={getMeatPerHead=function() return 1 end,getCarcassReferenceWeight=function(a) return a.targetWeight end}
    RLAnimalIdentityCheckpoint={state="READY"}
    MoneyType={SOLD_ANIMALS=mt}
    RLAnimalBuyService={computeBuyPrice=function(x) return x:getSellPrice()*1.3 end}
    for _,x in ipairs({a,b}) do
        x.age=6;x.subType="BULL_ANGUS";x.weight=100;x.targetWeight=800;x.gender="male";x.diseases={};x.isPregnant=false;x.isLactating=false;x.pregnancy=nil
        x.rlGrowth={developmentMonths=6};x.getSubType=function() return subtype end
        x.getSellPrice=function() return 1000 end
    end
    local disk,monthDisk,writes={},nil,0
    local store={write=function(doc) writes=writes+1;disk=cp(doc);return true end,read=function() return cp(disk) end}
    local ms={read=function() if not monthDisk then return nil,"NOT_FOUND" end return cp(monthDisk) end,
        write=function(doc) monthDisk=cp(doc);return true end}
    local r=assert(RLBrokerRuntime.new({mission=m,lineage="Ltest",epoch="e1",balance=BrokerDemandFixture.balance(),
        transactionStore=store,monthStore=ms,nowMs=function() return m.time or 1000 end}))
    RLBrokerRuntime.current=r
    r.state="READY"
    local orders=assert(r:listOrders());assert(#orders==1)
    local req={orderId=orders[1].orderId,animalKey=RLTradeSourceAdapter.identityKey(a),sourceRef=s.uniqueId,transportMode="PICKUP"}
    return {r=r,m=m,f=f,s=s,a=a,b=b,req=req,store=store,monthStore=ms,writes=function() return writes end}
end

BrokerRuntimeFixture={setup=setup}
