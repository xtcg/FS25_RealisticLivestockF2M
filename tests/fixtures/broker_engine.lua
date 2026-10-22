loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/animal/RLTradeSourceAdapter.lua")
loadMod("scripts/animal/RLSaleSettlement.lua")
loadMod("scripts/market/RLBrokerSourceAdapter.lua")
loadMod("scripts/market/RLBrokerMoneyAdapter.lua")
-- Load the real utility (the repo's two Luau annotations are erased by the test harness).
local f=assert(io.open(REPO.."scripts/utils/RLAnimalUtil.lua"));local source=f:read("*a");f:close()
assert(load((source:gsub("::number","")),"RLAnimalUtil"))()
BrokerEngineFixture={}
function BrokerEngineFixture.source(kind)
    local source={isServer=true,uniqueId="server-source",ownerFarmId=1}
    if kind=="TRAILER" then source.spec_livestockTrailer={} else source.spec_husbandryAnimals={} end
    function source:getUniqueId()return self.uniqueId end
    function source:getOwnerFarmId()return self.ownerFarmId end
    local cs={animals={},clustersToAdd={},clustersToRemove={},nextId=10}
    source.system=cs
    function source:getClusterSystem()return self.system end
    function cs:getClusters()if self.unreadable then error("unreadable") end;return self.animals end
    function cs:addPendingRemoveCluster(a)self.clustersToRemove[a]=true;if self.onQueue then self.onQueue(a) end end
    function cs:addPendingAddCluster(a)self.clustersToAdd[a]=true end
    function cs:updateNow()
        for i=#self.animals,1,-1 do
            local a=self.animals[i]
            if self.clustersToRemove[a] then table.remove(self.animals,i);a.clusterSystem=nil;self.clustersToRemove[a]=nil end
        end
        for a in pairs(self.clustersToAdd)do
            self.animals[#self.animals+1]=a;self.nextId=self.nextId+1;a.id=self.nextId;a.clusterSystem=self;self.clustersToAdd[a]=nil
        end
        if self.onFlush then self.onFlush() end
    end
    for i=1,2 do
        local a={farmId="123456",uniqueId="1234"..i,birthday={country=2},id=i,clusterSystem=cs,
            subType="COW_HOLSTEIN",subTypeIndex=1,age=20,health=100,isDead=false,isCastrated=false,
            genetics={quality=1,health=1,fertility=1,productivity=1,metabolism=1},
            rlGrowth={version=1,ageMonths=20.25,nested={a={b={c={d={e={f={g=19}}}}}}}},
            isPregnant=true,pregnancy={duration=10,expected={year=2,month=6,day=1},pregnancies={{farmId="123456",uniqueId="20000",genetics={quality=1.25}}}}}
        function a:getNumAnimals()return 1 end
        cs.animals[i]=a
    end
    source.mission={placeableSystem={placeables=kind~="TRAILER" and {source} or {}},vehicleSystem={vehicles=kind=="TRAILER" and {source} or {}}}
    function source.mission:getIsServer()return true end
    return source,cs.animals[1],cs.animals[2]
end
function BrokerEngineFixture.money()
    local f={money=1000,stats={finances={animals=0},financesVersionCounter=0,moneyEarnedHeroAccum=0,heroStats={moneyEarned=true}}}
    g_farmManager={getFarmById=function(_,id)return id==1 and f or nil end}
    local mission={moneyChanges={},calls=0}
    function mission:getIsServer()return true end
    function mission:addMoney(amount,id,kind)
        self.calls=self.calls+1
        if self.mode=="BEFORE_THROW" then error("before") end
        if self.mode=="RETURN_EMPTY" then return end
        f.money=f.money+amount
        if self.mode=="PARTIAL" then return end
        f.stats.finances.animals=f.stats.finances.animals+amount
        f.stats.financesVersionCounter=f.stats.financesVersionCounter+1
        f.stats.moneyEarnedHeroAccum=f.stats.moneyEarnedHeroAccum+amount
        if self.onMoney then self.onMoney() end
        self.moneyChanges[kind.id]=self.moneyChanges[kind.id] or {}
        self.moneyChanges[kind.id][id]=amount
        if self.mode=="HUD_THROW" then error("hud") end
        self.moneyChanges[kind.id][id]=nil
    end
    return mission,f,{id=7,statistic="animals"}
end
