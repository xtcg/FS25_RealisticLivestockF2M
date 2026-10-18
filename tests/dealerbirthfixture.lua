-- Actual shared reproduction fixture. A surviving first twin and dead last twin
-- permit stock-Lua's break translation of GIANTS continue without changing this path.
loadMod("tests/dealerownedfixture.lua")
loadMod("scripts/animal/RLBirthWeight.lua")
local file=assert(io.open(REPO.."scripts/animal/AnimalReproduction.lua","r"))
local code=file:read("*a");file:close()
assert(load(code:gsub("%f[%a]continue%f[%A]","break"),"actual source birth"))()
DealerBirthFixture={}
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local function methods(a)
    a.rlHistoryReplay=nil
    a.getAnimalTypeIndex=function(self) return self.animalTypeIndex end
    a.resolveBirthCount=function(self) return self.birthCount or 0 end
    a.setBirthday=function(self,date) self.birthday=date end
    a.setClusterSystem=function(self,cluster) self.clusterSystem=cluster;self.sale=nil end
    a.setUniqueId=function() error("source identity redraw") end
    a.getSellPrice=function() error("source price") end
    a.addMessage=function() error("source player message") end
    a.die=function() error("source player death") end
    return a
end
function DealerBirthFixture.new(maternalDeath)
    local stock,ctx,saleId=DealerOwnedFixture.new({pregnant=true})
    local owner=stock.sourceOwners.OWNER;local dam=methods(owner.byId.DAM)
    local seed=DealerReplaySim.seed("HOLSTEIN","female",1);seed.genetics.health=0.25
    local history=DealerReplaySim.history(seed,20.25,"NORMAL_PRODUCTION",{{kind="CONCEPTION",atMonths=17.125,parity=1}})
    local initial=assert(RLDealerReplay.run(seed,history,{daysPerMonth=1,entry=ctx.resolveEntry(),
        pregnancySubTypes={[4]={seed.subType,seed.subType}}}))
    local prior=assert(RLDealerSourceState.capture(initial,100))
    local pending=assert(RLDealerReplay.runToSourceBirth(initial,27.125,{daysPerMonth=1,entry=ctx.resolveEntry()}))
    for key,value in pairs(pending.animal) do if type(value)~="function" and key~="pregnancy" and key~="sale" and key~="rlHistoryReplay" then dam[key]=copy(value) end end
    dam.deathEnabled=true
    dam.children={}
    local index=Economics.find(seed.subType.name)
    local children={}
    for i=1,2 do children[i]=methods(Animal.new({age=-1,weight=35,health=100,gender="female",subTypeIndex=index,
        genetics=copy(seed.genetics),uniqueId="FETUS-"..i,farmId=dam.farmId})) end
    dam.pregnancy={duration=10,expected={day=4,month=5,year=2027},pregnancies=children}
    local selectedChildren={children[1],children[2]}
    local cursor=106.875
    local date={eventId="ACTUAL-BIRTH",atAgeMonths=27.125,cursorMonths=cursor,day=4,month=5,year=2027}
    g_server={broadcastEvent=function() error("source broadcast") end}
    RealisticLivestock={getMapCountryIndex=function() error("source country redraw") end}
    local random,survival=math.random,RLBirthWeight.getSurvivalChance
    local survivalChecks=0
    RLBirthWeight.getSurvivalChance=function()
        survivalChecks=survivalChecks+1
        return maternalDeath and survivalChecks==2 and 0 or 1
    end
    math.random=function() return maternalDeath and 0.99 or 0.2 end
    local ok,result,failure=pcall(RLDealerSourceReproduction.execute,owner,dam,date,{isServer=true,
        persistPrepared=function() return true end,persistCommitted=function() return true end})
    math.random,RLBirthWeight.getSurvivalChance=random,survival
    assert(ok,result);assert(result,failure and failure.reason)
    local observed=assert(RLDealerSourceReproduction.captureObserved(prior,pending,owner,dam,date.eventId,cursor))
    stock.farm.clock.months=cursor;stock.farm.sources.source=observed
    stock.sourceRecordsByOwner.OWNER.DAM=observed;stock.observedChildren.OWNER={}
    for _,child in ipairs(owner.animals) do if child~=dam then
        stock.observedChildren.OWNER[child.uniqueId]=assert(RLDealerObservedGrowth.capture(child,cursor,owner.birthJournal[date.eventId]))
    end end
    return stock,ctx,saleId,date.eventId,selectedChildren,result
end
-- Controller tests restore new private shells, so install the same real method
-- boundary on Animal itself rather than only on pre-restoration fixture objects.
function DealerBirthFixture.setupController()
    local selected=methods({})
    for key,value in pairs(selected) do if type(value)=="function" then Animal[key]=value end end
    g_server={broadcastEvent=function() error("source broadcast") end}
    RealisticLivestock={getMapCountryIndex=function() error("source country redraw") end}
end
