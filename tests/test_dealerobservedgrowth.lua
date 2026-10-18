loadMod("tests/dealerreplaysim.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/dealer/RLDealerObservedGrowth.lua")
local G,R,Sim=RLDealerObservedGrowth,RLDealerReplay,DealerReplaySim
local function clone(t) if type(t)~="table" then return t end;local o={};for k,v in pairs(t) do o[k]=clone(v) end;return o end
local function resolver(name) local i,sub=Economics.find(name);return sub,i end
-- Committed event stand-in matching the normal reproduction's observed record.
-- Actual birth sampling/ownership is tested separately in source reproduction.
local function fixture(gene,fertility,sex)
    local seed=Sim.seed("HOLSTEIN",sex or "female",gene or 1)
    local a=GrowthSim.makeAnimal(seed.subType.name,{age=0,birthCount=0,isParent=false,isPregnant=false,breed=seed.subType.breed,
        uniqueId="OBSERVED-CHILD",farmId="654321",birthday={country=4,day=2,month=10,year=2026},genetics=clone(seed.genetics)})
    a.genetics.fertility=fertility or 0
    a.rlGrowth=nil;a.bodyCondition=nil
    local weight=RLGrowth.getBirthMean(RLGrowth.getBinding(seed.subType))
    assert(RLGrowth.initBirth(a,weight))
    local event={version=1,eventId="real-birth-1",sourceId="source-A",damId="dam",cursorMonths=100,stage="COMMITTED",evidence="OBSERVED_SOURCE_BIRTH",day=2,month=10,year=2026,
        selected={{uniqueId=a.uniqueId,farmId=a.farmId,subType=a.subType,genetics=clone(a.genetics)}},
        draws={{uniqueId=a.uniqueId,farmId=a.farmId,subType=a.subType,weightKg=weight,meanWeightKg=weight,z=0}},
        result={eventId="real-birth-1",evidence="OBSERVED_SOURCE_BIRTH",newborns={{uniqueId=a.uniqueId,farmId=a.farmId,subType=a.subType,birthWeightKg=weight,alive=true}}}}
    return a,event
end
local a,event=fixture()
local random,draw,ensure=math.random,RLGrowth.drawBirthWeight,RLGrowth.ensureState
math.random=function() error("observed growth RNG") end
RLGrowth.drawBirthWeight=function() error("birth redraw") end
RLGrowth.ensureState=function() error("growth migration") end
local record=assert(G.capture(a,100,event));local restored=assert(G.restore(record,resolver))
math.random,RLGrowth.drawBirthWeight,RLGrowth.ensureState=random,draw,ensure
check("observed growth: exact actual birth weight and committed draw preserved without history fabrication", record.history==nil and record.evidence=="OBSERVED_SOURCE_BIRTH" and record.birthEvent.draws[1].weightKg==a.weight and restored.weight==a.weight and record.animal.rlGrowth.lastTick==nil)
check("observed growth: real freemartin fertility zero is not a dealer preset rejection", record.animal.genetics.fertility==0 and restored.genetics.fertility==0)
check("observed growth: capture never changes real newborn markers, growth ticks or ownership", a.rlHistoryReplay==nil and a.rlGrowth.lastTick==-1 and a.farmId=="654321")
local bad=clone(event);bad.draws[1].weightKg=bad.draws[1].weightKg+1
check("observed growth: actual birth draw mismatch refuses capture", not G.capture(a,100,bad))
bad=clone(event);bad.stage="PREPARED"
check("observed growth: unfinished birth evidence cannot authorize newborn feeding", not G.capture(a,100,bad))
bad=clone(event);bad.result.newborns[1].alive=false
check("observed growth: dead or unmatched actual newborn is retained outside feeding path", not G.capture(a,100,bad))
bad=clone(event);bad.draws[2]=clone(bad.draws[1])
check("observed growth: duplicate actual draw identity fails closed", not G.capture(a,100,bad))
local moved=clone(record);moved.animal.subTypeIndex=999;moved.animal.animalTypeIndex=999
restored=assert(G.restore(moved,resolver))
check("observed growth: exact subtype name rebinds current indices rather than stale numeric index", restored.subTypeIndex~=999 and restored.animalTypeIndex==AnimalType.COW)
local missing,failure=G.restore(record,function() return nil end)
check("observed growth: missing installed model preserves exact evidence without remapping", not missing and failure.reason=="OBSERVED_SUBTYPE" and failure.evidence==record)
for _,patch in ipairs({function(r) r.animal.isParent=true end,function(r) r.animal.isPregnant=true end,function(r) r.animal.reproduction=1 end}) do
    bad=clone(record);patch(bad)
    check("observed growth: pregnancy parent and new mating remain explicit closed gates", not G.resume(bad,{{hours=1,daysPerMonth=1}},resolver))
end
local matrix=true
for _,gene in ipairs({0.01,0.25,1,1.75,3}) do
    for _,sex in ipairs({"female","male"}) do
        local child,birth=fixture(gene,0,sex);local captured=assert(G.capture(child,100,birth))
        local grown,why=G.resume(captured,{{hours=12,daysPerMonth=1}},resolver)
        matrix=matrix and grown~=nil and grown.animal.genetics.metabolism==gene and grown.animal.genetics.fertility==0 and child.rlGrowth.ageMonths==0
    end
end
check("observed growth: actual genes outside preset range and both sexes retain physical model factors", matrix)
local times=true
for _,days in ipairs({1,3,7}) do
    local grown=assert(G.resume(record,{{hours=24*days*4.5,daysPerMonth=days}},resolver))
    times=times and math.abs(grown.cursorMonths-104.5)<1e-8 and math.abs(grown.animal.rlGrowth.ageMonths-4.5)<1e-8
        and grown.animal.age==4 and grown.animal.rlHistoryReplay==nil and grown.animal.genetics.fertility==0
        and grown.ledger.maxEnergyError<1e-6 and grown.ledger.maxMassError<1e-6
end
check("observed growth: 1/3/7-day hourly calendars cross birthdays and weaning with conserved ledgers", times)
local mixed=assert(G.resume(record,{{hours=12,daysPerMonth=1},{hours=36,daysPerMonth=3},{hours=84,daysPerMonth=7}},resolver))
local split=assert(G.resume(assert(G.resume(assert(G.resume(record,{{hours=12,daysPerMonth=1}},resolver)),{{hours=36,daysPerMonth=3}},resolver)),{{hours=84,daysPerMonth=7}},resolver))
check("observed growth: mixed actual month lengths equal persisted split continuation", mixed.cursorMonths==101.5 and mixed.animal.weight==split.animal.weight and mixed.animal.rlGrowth.reserveMassKg==split.animal.rlGrowth.reserveMassKg and mixed.animal.rlGrowth.feedAdapted==split.animal.rlGrowth.feedAdapted)
local canonical=RLTradePersistence.canonical(record)
check("observed growth: invalid later calendar leaves original newborn record untouched", not G.resume(record,{{hours=12,daysPerMonth=1},{hours=12,daysPerMonth=0}},resolver) and RLTradePersistence.canonical(record)==canonical)
-- Same planned feed budget through normal player adapter and the strict source
-- integrator, below the live birthday cap; no planner or physics stubs are used.
local observed=assert(G.resume(record,{{hours=12,daysPerMonth=1}},resolver))
local player=assert(G.restore(record,resolver));local recipe=R.getRecipe("NORMAL_REARING")
for i=1,12 do
    local dt=1/24;RLBodyCondition.applyMilk(player,0,0,1)
    local feed=assert(R.planFeed(player,recipe,dt))
    local result,input,before=RLGrowth.advanceBudget(player,{feed=feed},dt,i)
    assert(result);RLFeed.afterStep(player,player.rlGrowth,feed,result,before,dt);RLFeed.applyHealth(player,feed,result,dt);RLFeed.applyUnderweight(player,dt)
end
check("observed growth: unchanged player budget AB agrees within 0.001 kg", math.abs(player.weight-observed.animal.weight)<=0.001 and math.abs(player.rlGrowth.reserveMassKg-observed.animal.rlGrowth.reserveMassKg)<=0.001 and player.health==observed.animal.health and player.rlGrowth.feedAdapted==observed.animal.rlGrowth.feedAdapted)
local newborn,evt=fixture();local calls=0;local initialDraw=RLGrowth.drawBirthWeight
RLGrowth.drawBirthWeight=function() calls=calls+1;return evt.draws[1].weightKg,0,evt.draws[1].meanWeightKg end
local selectedWeight=RLGrowth.drawBirthWeight(newborn:getSubType(),{})
assert(RLGrowth.initBirth(newborn,selectedWeight));local once=assert(G.capture(newborn,100,evt));assert(G.resume(once,{{hours=1,daysPerMonth=1}},resolver))
RLGrowth.drawBirthWeight=initialDraw
check("observed growth: selected actual birth weight is drawn once and never redrawn by capture or feeding", calls==1)
local altered=clone(record);altered.animal.genetics.fertility=0.5
check("observed growth: actual selected newborn genes cannot be rewritten after birth",not G.validate(altered))
altered=clone(record);altered.birthEvent.day=nil;altered.animal.birthday.day=nil
check("observed growth: absent calendar evidence cannot validate by two missing dates matching",not G.validate(altered))
