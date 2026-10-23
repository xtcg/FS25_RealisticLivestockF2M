loadMod("tests/brokerdemandfixture.lua")
loadMod("scripts/market/RLMarketResourceLock.lua")
loadMod("scripts/market/RLBrokerQuota.lua")
local F,D=BrokerDemandFixture,RLBrokerDemand
local balance,catalog=F.balance(),F.catalog()
local before=assert(RLMarketData.fingerprint({balance,catalog}))
local oldRandom=math.random
math.random=function()error("global RNG must not be touched")end
local first=assert(D.generate("market-seed",250,"generator:1",balance,catalog))
math.random=oldRandom
check("demand: independent RNG and deterministic replay",first.revision==assert(D.generate("market-seed",250,"generator:1",balance,catalog)).revision)
check("demand: standalone frozen snapshot validates",D.validateSnapshot(first)~=nil)
check("demand: contracts never mutate candidate inputs",before==RLMarketData.fingerprint({balance,catalog}))
check("demand: synthetic evidence remains explicitly test-only",first.testOnly==true)
local reversed=F.copy(catalog);local entries={}
for i=#reversed.entries,1,-1 do entries[#entries+1]=reversed.entries[i]end
reversed.entries=entries
check("demand: table/list candidate order cannot alter RNG results",assert(D.generate("market-seed",250,"generator:1",balance,reversed)).revision==first.revision)
local function layout(s)
    local counts,groups,base,seen={}, {},{},{}
    local extras,elite=0,0
    for _,o in ipairs(s.orders)do
        counts[o.speciesKey]=(counts[o.speciesKey]or 0)+1
        groups[o.speciesKey]=groups[o.speciesKey]or{};groups[o.speciesKey][o.purposeGroup]=true
        if seen[o.semanticKey] then return false end;seen[o.semanticKey]=true
        if o.slotType=="EXTRA"then extras=extras+1;if o.breedScope~="SPECIFIC"then return false end
        else base[o.speciesKey]=base[o.speciesKey]or{};if base[o.speciesKey][o.purposeGroup]then return false end;base[o.speciesKey][o.purposeGroup]=true end
        if o.purposeGroup~="GROWER"and o.breedScope~="SPECIFIC"then return false end
        if o.tier=="elite"then elite=elite+1 end
        if o.quantityTotal<1 or o.quantityTotal>s.quotaDefinition.species[o.speciesKey].monthlyHeadCap then return false end
    end
    for species,g in pairs(groups)do local n=0;for _ in pairs(g)do n=n+1 end;if n>2 or counts[species]>(species=="PIG"and 2 or 3)then return false end end
    return #s.orders>=5 and #s.orders<=7 and extras==2 and elite<=1
end
for seed=1,24 do
    local s=assert(D.generate(seed,120+seed,"generator:1",balance,catalog))
    check("demand: 5-7/layout/shared caps independent sample "..seed,layout(s)
        and s.quotaDefinition.species.COW.monthlyHeadCap==8 and s.quotaDefinition.species.COW.perBreedHeadCap==4
        and s.quotaDefinition.species.SHEEP.monthlyHeadCap==24 and s.quotaDefinition.species.PIG.monthlyHeadCap==32
        and RLBrokerQuota.new():initialize(s.monthId,s.quotaDefinition))
end
local missing=F.copy(catalog);for _,e in ipairs(missing.entries)do e.verified=false end
local unavailable=assert(D.generate("none",250,1,balance,missing))
check("demand: candidates without U51 admission produce diagnostics not fake orders",#unavailable.orders==0 and #unavailable.diagnostics>0)
missing=F.copy(catalog);for _,e in ipairs(missing.entries)do e.evidenceRef=nil end
check("demand: admission needs a real evidence reference",#assert(D.generate("none",250,1,balance,missing)).orders==0)
missing=F.copy(catalog);for _,e in ipairs(missing.entries)do e.packageRevision="stale" end
check("demand: changed package cannot reuse old reachability evidence",#assert(D.generate("none",250,1,balance,missing)).orders==0)
local one={schemaVersion=1,configRevision="only:1",calendarOriginMonth=1,testOnly=true,entries={F.entry("cattleStore","COW","ALPHA","SPECIFIC","standard")}}
local duplicate=F.copy(one);local clone=F.copy(one.entries[1]);clone.package.id="new-title";clone.package=assert(RLBrokerConditionPackage.compile(clone.package));clone.packageRevision=clone.package.revision;clone.priceBasis.basisId="different-price-policy";duplicate.entries[2]=clone
local single=assert(D.generate(12,1,1,balance,duplicate))
check("demand: price policy/title changes do not create another semantic order",#single.orders==1 and #single.diagnostics>0)
check("demand: few candidates do not fabricate basic/extra guarantees",#single.orders<5)
local scaled=F.copy(balance);scaled.capacityScale=.5
local small=assert(D.generate("scaled",3,1,scaled,catalog))
check("demand: species/breed heads scale once with fixed rounding",small.quotaDefinition.species.COW.monthlyHeadCap==4 and small.quotaDefinition.species.COW.perBreedHeadCap==2)
for _,o in ipairs(small.orders)do check("demand: scaled order remains within shared caps "..o.orderId,o.quantityTotal<=small.quotaDefinition.species[o.speciesKey].perBreedHeadCap)end
local bogus=F.copy(balance);bogus.scaledSpecies.COW.monthlyHeadCap=99999
check("demand: cannot inject extra public cap via precomputed scaledSpecies",assert(D.generate("scaled",3,1,bogus,catalog)).quotaDefinition.species.COW.monthlyHeadCap==8)
local damaged=F.copy(first);damaged.schemaVersion=2
check("demand: unknown saved schema rejected",D.validateSnapshot(damaged)==nil)
damaged=F.copy(first);damaged.orders[1].quantityTotal=999
check("demand: changed frozen rule/cap rejected",D.validateSnapshot(damaged)==nil)
check("demand: invalid month rejected",D.generate("seed",.5,1,balance,catalog)==nil)
local prior=assert(D.generate("history",10,1,balance,catalog))
local nextMonth=assert(D.generate("history",11,1,balance,catalog,prior))
check("demand: previous published month is a deterministic explicit input",nextMonth.revision==assert(D.generate("history",11,1,balance,catalog,prior)).revision)
local future=assert(D.generate("history",15,1,balance,catalog,prior))
local diagnosed=false;for _,d in ipairs(future.diagnostics)do if d.code=="PREVIOUS_MONTH_NOT_PUBLISHED"then diagnosed=true end end
check("demand: jumping months never treats older history as last month",diagnosed)

local noSecond=F.copy(balance);noSecond.species.COW.secondSlotChance=0;noSecond.species.SHEEP.secondSlotChance=0
local fullSecond=F.copy(balance);fullSecond.species.COW.secondSlotChance=1;fullSecond.species.SHEEP.secondSlotChance=1
local five=assert(D.generate("slots",42,1,noSecond,catalog));local seven=assert(D.generate("slots",42,1,fullSecond,catalog))
check("demand: configured conditional second slots give 3+2 vs 5+2",#five.orders==5 and #seven.orders==7)
local function findSlot(snapshot,slot)for _,order in ipairs(snapshot.orders)do if order.slotId==slot then return order end end end
check("demand: optional slot draws do not perturb another slot's substreams",
    findSlot(five,"BASE:COW:1").semanticKey==findSlot(seven,"BASE:COW:1").semanticKey
    and findSlot(five,"BASE:SHEEP:1").semanticKey==findSlot(seven,"BASE:SHEEP:1").semanticKey)
local eliteBalance=F.copy(noSecond)
for _,s in pairs(eliteBalance.species)do s.groupWeights={0,0,1}end
eliteBalance.eliteConditionalChance=1
local elite=assert(D.generate("elite",42,1,eliteBalance,catalog));local count=0
for _,order in ipairs(elite.orders)do if order.tier=="elite"then count=count+1 end end
check("demand: elite occupies an existing slot with global maximum one",count==1 and #elite.orders==5)
eliteBalance.eliteConditionalChance=0
local ordinary=assert(D.generate("elite",42,1,eliteBalance,catalog));count=0
for _,order in ipairs(ordinary.orders)do if order.tier=="elite"then count=count+1 end end
check("demand: zero elite conditional chance never publishes elite",count==0)
local seasonal={schemaVersion=1,configRevision="season:1",calendarOriginMonth=1,testOnly=true,entries={
    F.entry("cattleStore","COW","AAA","SPECIFIC","standard"),F.entry("cattleFinished","COW","BBB","SPECIFIC","standard")}}
seasonal.entries[1].seasonWeights={0,0,0,0,0,0,0,0,0,0,0,0}
local seasonBalance=F.copy(noSecond);seasonBalance.species={COW=seasonBalance.species.COW};seasonBalance.species.COW.groupWeights={999,1,0}
local season=assert(D.generate("season",0,1,seasonBalance,seasonal))
check("demand: zero seasonal feasibility filtered before group weights normalize",#season.orders==1 and season.orders[1].purposeGroup=="FINISHED")
local repeatCatalog={schemaVersion=1,configRevision="repeat:1",calendarOriginMonth=1,testOnly=true,entries={
    F.entry("cattleStore","COW","AAA","SPECIFIC","standard"),F.entry("cattleStore","COW","BBB","SPECIFIC","standard")}}
local priorCatalog=F.copy(repeatCatalog);priorCatalog.entries[2]=nil
local difference=false
for seed=1,12 do
    local previous=assert(D.generate(seed,10,1,seasonBalance,priorCatalog))
    local plain=assert(D.generate(seed,11,1,seasonBalance,repeatCatalog))
    local repeated=assert(D.generate(seed,11,1,seasonBalance,repeatCatalog,previous))
    if plain.orders[1].requiredBreedId~=repeated.orders[1].requiredBreedId then difference=true end
end
check("demand: prior public same-target breed history reduces repeat opportunity",difference)
local fat=F.entry("lambFinished","SHEEP","AAA","SPECIFIC","standard")
local reorderedFat=F.copy(fat.package)
for _,condition in ipairs(reorderedFat.conditions)do if condition.field=="s.production.fatClass"then condition.values={"3H","2","3L"}end end
reorderedFat=assert(RLBrokerConditionPackage.compile(reorderedFat))
check("demand: semantic equality normalizes unordered fat-class sets",D.semanticKey(reorderedFat)==D.semanticKey(fat.package))
local forged=F.copy(first)
for _,o in ipairs(forged.orders)do
    if o.speciesKey=="PIG"then
        local oldId=o.orderId;o.slotType="BASE";o.slotId="BASE:PIG:2";o.orderId=forged.monthId..":"..o.slotId
        forged.quotaDefinition.orders[o.orderId]=forged.quotaDefinition.orders[oldId];forged.quotaDefinition.orders[oldId]=nil
        break
    end
end
forged.revision=nil;forged.revision=assert(RLMarketData.fingerprint(forged))
check("demand: valid fingerprint cannot invent pig's forbidden second base slot",D.validateSnapshot(forged)==nil)

-- Independent review: the absolute clock and season calendar are distinct.
-- Match the existing engine period projection, including Jan/Feb in next year.
loadMod("scripts/utils/RLCalendar.lua")
local engineCatalog=F.copy(catalog);engineCatalog.calendarOriginMonth=3
for _,position in ipairs({{year=2,period=10},{year=2,period=11},{year=2,period=12},{year=3,period=1}})do
    local month=RLCalendar.getMonthAndYear({currentYear=position.year,currentPeriod=position.period})
    local absolute=position.year*12+position.period-1
    local actual=assert(D.generate("engine-clock",absolute,1,balance,engineCatalog))
    check("demand: explicit origin matches real calendar projection "..absolute,actual.calendarMonth==month and D.validateSnapshot(actual)~=nil)
end
local noOrigin=F.copy(catalog);noOrigin.calendarOriginMonth=nil
check("demand: cannot guess January for an unspecified clock origin",D.generate("calendar",1,1,balance,noOrigin)==nil)
local disabled={schemaVersion=1,configRevision="zero:1",calendarOriginMonth=1,testOnly=true,entries={}}
disabled.entries[1]=F.entry("cattleStore","COW","AAA","SPECIFIC","standard")
for _,breed in ipairs({"AAA","BBB","CCC","DDD"})do disabled.entries[#disabled.entries+1]=F.entry("lambGrower","SHEEP",breed,"SPECIFIC","standard")end
local zeroBalance=F.copy(noSecond);zeroBalance.species={COW=zeroBalance.species.COW,SHEEP=zeroBalance.species.SHEEP}
zeroBalance.species.COW.groupWeights={0,1,0};zeroBalance.species.SHEEP.groupWeights={1,0,0}
for seed=1,8 do
    local out=assert(D.generate(seed,1,1,zeroBalance,disabled))
    local extra=0;for _,order in ipairs(out.orders)do if order.slotType=="EXTRA"then extra=extra+1 end end
    check("demand: disabled-only species cannot waste viable extra slot "..seed,extra==2)
end
local zeroScope=F.copy(noSecond);zeroScope.species={COW=zeroScope.species.COW};zeroScope.species.COW.groupWeights={1,1,0}
zeroScope.growerAnyWeight=0;zeroScope.growerSpecificWeight=1
local scopeCatalog={schemaVersion=1,configRevision="scope:1",calendarOriginMonth=1,testOnly=true,entries={
    F.entry("cattleStore","COW","AAA","ANY","standard"),F.entry("cattleFinished","COW","BBB","SPECIFIC","standard")}}
local out=assert(D.generate("scope-zero",1,1,zeroScope,scopeCatalog))
check("demand: disabled ANY-only base group filtered before group selection",out.orders[1].purposeGroup=="FINISHED")
