-- Actual source newborn growth. This record never claims MODEL_ASSUMED history,
-- candidate eligibility, price or a sale listing. Owner keeps the real child.
RLDealerObservedGrowth = { VERSION=1, KIND="OBSERVED_NEWBORN_REARING", MAX_STEPS=100000 }
local G=RLDealerObservedGrowth
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function id(v) return (type(v)=="string" and #v>0) or finite(v) end
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local function near(a,b) return finite(a) and finite(b) and math.abs(a-b)<1e-8 end
local function fail(reason,record) return nil,{reason=reason,evidence=record} end
local function equal(a,b)
    if type(a)~=type(b) then return false end;if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end;return true
end
local fields={"age","subType","subTypeIndex","animalTypeIndex","breed","gender","isIndividual","isCastrated",
    "genetics","health","isParent","birthCount","isPregnant","reproduction","diseases","input","output",
    "weight","targetWeight","rlGrowth","bodyCondition","rlFeedGain","rlHealthCarry","rlMilk","monthsSinceLastBirth",
    "isLactating","farmId","uniqueId","birthday","isDead","deathEnabled","mother","father"}
local function genes(g)
    if type(g)~="table" then return false end
    for _,k in ipairs({"metabolism","quality","productivity","fertility","health"}) do if not finite(g[k]) or g[k]<0 then return false end end
    return g.metabolism>0
end
local function identity(a)
    return type(a)=="table" and id(a.uniqueId) and a.uniqueId~="0-0" and a.uniqueId~="1-1" and id(a.farmId)
        and type(a.birthday)=="table" and id(a.birthday.country)
end
local function plain(v)
    return RLTradePersistence.check(v,{maxNodes=200000,maxString=262144,maxDepth=32})==nil
end
local function array(t)
    if type(t)~="table" then return false end;local n=0
    for k,v in pairs(t) do if type(k)~="number" or k<1 or k%1~=0 or k>#t or type(v)~="table" then return false end;n=n+1 end
    return n==#t
end
local function actualBirth(a,event)
    if not identity(a) or type(event)~="table" or event.version~=1 or event.stage~="COMMITTED"
        or event.evidence~="OBSERVED_SOURCE_BIRTH" or not id(event.eventId) or not id(event.sourceId)
        or not finite(event.cursorMonths) or type(event.result)~="table" or event.result.eventId~=event.eventId
        or event.result.evidence~=event.evidence or type(event.draws)~="table" or type(event.selected)~="table"
        or not array(event.selected) or not array(event.draws) or not array(event.result.newborns)
        or not finite(event.day) or event.day<1 or event.day>31 or event.day%1~=0
        or not finite(event.month) or event.month<1 or event.month>12 or event.month%1~=0
        or not finite(event.year) or event.year%1~=0 then return false end
    local selected,draw,born,ns,nd,nb=nil,nil,nil,0,0,0
    for _,v in ipairs(event.selected) do if v.uniqueId==a.uniqueId and v.farmId==a.farmId then selected=v;ns=ns+1 end end
    for _,v in ipairs(event.draws) do if v.uniqueId==a.uniqueId and v.farmId==a.farmId then draw=v;nd=nd+1 end end
    for _,v in ipairs(event.result.newborns) do if v.uniqueId==a.uniqueId and v.farmId==a.farmId then born=v;nb=nb+1 end end
    return ns==1 and nd==1 and nb==1 and selected.subType==a.subType and draw.subType==a.subType and born.subType==a.subType
        and equal(selected.genetics,a.genetics)
        and born.alive==true and finite(draw.z) and finite(draw.meanWeightKg) and draw.meanWeightKg>0
        and draw.weightKg==a.rlGrowth.birthWeightKg and born.birthWeightKg==draw.weightKg
        and a.birthday.day==event.day and a.birthday.month==event.month and a.birthday.year==event.year
end
function G.validate(r)
    if type(r)~="table" or not plain(r) or r.version~=G.VERSION or r.kind~=G.KIND
        or r.evidence~="OBSERVED_SOURCE_BIRTH" or r.history~=nil or r.eligibility~=nil then return nil,"OBSERVED_SCHEMA" end
    local a,s=r.animal,r.animal and r.animal.rlGrowth
    if type(a)~="table" or type(s)~="table" or not identity(a) or not genes(a.genetics) or a.rlHistoryReplay~=nil
        or s.version~=RLGrowth.STATE_VERSION or not RLGrowth.isUsable(s) or s.source~="birth" or s.lastTick~=nil
        or s.legacyAnchor~=nil or s.anchorElapsedMonths~=nil or s.weightKg~=a.weight or not finite(a.weight) or a.weight<=0
        or (s.gravidKg or 0)~=0 or s.reserveMassKg>=a.weight or not finite(a.health) or a.health<=0 or a.health>100
        or not finite(r.cursorMonths) or not finite(r.birthCursorMonths) or r.birthCursorMonths<0 or r.cursorMonths<r.birthCursorMonths
        or not near(s.ageMonths,r.cursorMonths-r.birthCursorMonths) or a.age~=math.floor(s.ageMonths+1e-10)
        or a.isDead==true or a.isPregnant==true or a.isParent==true or (a.birthCount or 0)~=0 or (a.reproduction or 0)~=0
        or a.isLactating==true or a.pregnancy~=nil then return nil,"OBSERVED_STATE_OR_REPRODUCTION_GATE" end
    if not actualBirth(a,r.birthEvent) or r.birthEvent.cursorMonths~=r.birthCursorMonths then return nil,"OBSERVED_BIRTH_EVIDENCE" end
    if not finite(r.weaningMonth) or r.weaningMonth<0 or not equal(r.recipe,RLDealerReplay.getRecipe("NORMAL_REARING"))
        or not finite(r.steps) or r.steps<0 or r.steps%1~=0 or type(r.ledger)~="table"
        or not finite(r.ledger.feedMe) or r.ledger.feedMe<0 or not finite(r.ledger.maxEnergyError) or r.ledger.maxEnergyError<0
        or r.ledger.maxEnergyError>1e-6 or not finite(r.ledger.maxMassError) or r.ledger.maxMassError<0 or r.ledger.maxMassError>1e-6 then return nil,"OBSERVED_FEED_RECORD" end
    if a.bodyCondition and (type(a.bodyCondition)~="table" or a.bodyCondition.lastTick~=nil or a.bodyCondition.version~=RLBodyCondition.STATE_VERSION
        or not finite(a.bodyCondition.reserve) or not finite(a.bodyCondition.capacityKg)
        or not near(a.bodyCondition.reserve*a.bodyCondition.capacityKg,s.reserveMassKg)) then return nil,"OBSERVED_BODY_STATE" end
    return true
end
function G.capture(animal,cursor,event)
    if type(event)~="table" or type(animal)~="table" or type(animal.getSubType)~="function" or type(animal.rlGrowth)~="table" then return fail("OBSERVED_NEWBORN") end
    local s=animal.rlGrowth
    if animal.age~=0 or s.ageMonths~=0 or animal.weight~=s.birthWeightKg or s.weightKg~=animal.weight
        or (s.lastTick~=nil and s.lastTick~=-1) or animal.rlHistoryReplay~=nil or animal.isParent==true or animal.isPregnant==true
        or animal.pregnancy~=nil or cursor~=event.cursorMonths then return fail("OBSERVED_NEWBORN") end
    local sub=animal:getSubType()
    if not sub or sub.name~=animal.subType or sub.typeIndex~=AnimalType.COW or not RLGrowth.coversSubType(sub)
        or sub.breed~=animal.breed or sub.gender~=animal.gender then return fail("OBSERVED_SUBTYPE") end
    local a={};for _,k in ipairs(fields) do a[k]=animal[k] end
    if not plain(a) or not plain(event) then return fail("OBSERVED_DATA") end
    a=copy(a);a.rlGrowth.lastTick=nil
    if a.bodyCondition then
        if a.bodyCondition.lastTick~=nil and a.bodyCondition.lastTick~=-1 then return fail("OBSERVED_NEWBORN") end
        a.bodyCondition.lastTick=nil
    end
    local r={version=G.VERSION,kind=G.KIND,evidence="OBSERVED_SOURCE_BIRTH",birthEvent=copy(event),birthCursorMonths=cursor,
        cursorMonths=cursor,animal=a,weaningMonth=RLCalfRearing.getWeaningMonthForSubType(sub),
        recipe=RLDealerReplay.getRecipe("NORMAL_REARING"),steps=0,ledger={feedMe=0,maxEnergyError=0,maxMassError=0}}
    local ok,why=G.validate(r);if not ok then return fail(why) end
    return r
end
function G.restore(record,resolver)
    local ok,why=G.validate(record);if not ok then return fail(why,record) end
    if type(resolver)~="function" then return fail("OBSERVED_RESOLVER",record) end
    local ran,sub,index=pcall(resolver,record.animal.subType)
    if not ran or type(sub)~="table" or sub.name~=record.animal.subType or sub.breed~=record.animal.breed
        or sub.gender~=record.animal.gender or sub.typeIndex~=AnimalType.COW or not RLGrowth.coversSubType(sub) then return fail("OBSERVED_SUBTYPE",record) end
    index=index or sub.subTypeIndex or sub.index
    if not finite(index) or index<1 or index%1~=0 then return fail("OBSERVED_CURRENT_INDICES",record) end
    if not RLCalfRearing.isEnabled() or RLCalfRearing.getWeaningMonthForSubType(sub)~=record.weaningMonth
        or not finite(sub.healthIncreaseHour) or sub.healthIncreaseHour<0 or not finite(sub.healthDecreaseHour) or sub.healthDecreaseHour<0 then return fail("OBSERVED_RULES",record) end
    local a=copy(record.animal);a.subTypeIndex,a.animalTypeIndex=index,sub.typeIndex
    a.getSubType=function() return sub end;setmetatable(a,{__index=Animal})
    local binding=RLGrowth.getBinding(sub);local size=RLGrowth.getGeneFactors(a.genetics.metabolism, a)
    local curve=RLGrowth.buildCurve(binding,a.rlGrowth.frameTargetKg,a.rlGrowth.birthWeightKg)
    if not near(a.rlGrowth.frameTargetKg,RLGrowth.getAdultReference(binding)*size)
        or a.rlGrowth.developmentMonths>curve.endMonth then return fail("OBSERVED_PHYSICAL_FRAME",record) end
    return a
end
local function feedStep(a,recipe,dt,ledger)
    RLBodyCondition.applyMilk(a,0,0,1)
    local feed,why=RLDealerReplay.planFeed(a,recipe,dt);if not feed then return nil,why end
    if not finite(feed.me) or feed.me<0 or not finite(feed.kg) or feed.kg<0 or not finite(feed.cp) or feed.cp<0
        or not finite(feed.proteinFactor) or feed.proteinFactor<0 or feed.proteinFactor>1 then return nil,"OBSERVED_FEED" end
    local result,input,before=RLGrowth.advanceHistoricalBudget(a,{feed=feed},dt)
    if not result then return nil,input end
    local energy=math.abs((result.supplyNU or 0)+(result.mobilizedNU or 0)+(result.catabolismNU or 0)
        -(result.paidNU or 0)-(result.depositNU or 0)-(result.lostNU or 0))
    local mass=math.abs(result.weight-before-result.frameGainKg-result.growthReserveKg-result.depositKg+result.mobilizedKg+result.catabolismKg)
    if not finite(energy) or not finite(mass) or energy>1e-6 or mass>1e-6 then return nil,"OBSERVED_LEDGER" end
    ledger.feedMe=ledger.feedMe+feed.me;ledger.maxEnergyError=math.max(ledger.maxEnergyError,energy);ledger.maxMassError=math.max(ledger.maxMassError,mass)
    RLFeed.afterStep(a,a.rlGrowth,feed,result,before,dt);RLFeed.applyHealth(a,feed,result,dt);RLFeed.applyUnderweight(a,dt)
    if a.health<=0 or not finite(a.health) then return nil,"OBSERVED_HEALTH_GATE" end
    return true
end
function G.resume(record,segments,resolver)
    if type(segments)~="table" then return fail("OBSERVED_SEGMENTS",record) end
    local n=0;for k in pairs(segments) do if type(k)~="number" or k<1 or k%1~=0 or k>#segments then return fail("OBSERVED_SEGMENTS",record) end;n=n+1 end
    if n~=#segments then return fail("OBSERVED_SEGMENTS",record) end
    local total=0
    for _,segment in ipairs(segments) do
        if type(segment)~="table" or not finite(segment.hours) or segment.hours<0 or not finite(segment.daysPerMonth)
            or segment.daysPerMonth<1 or segment.daysPerMonth>31 or segment.daysPerMonth%1~=0 then return fail("OBSERVED_CALENDAR",record) end
        total=total+segment.hours/(24*segment.daysPerMonth)
    end
    if not finite(total) then return fail("OBSERVED_CALENDAR",record) end
    local a,failure=G.restore(record,resolver);if not a then return nil,failure end
    local r=copy(record);a.rlHistoryReplay=true
    for _,segment in ipairs(segments) do
        local time=a.rlGrowth.ageMonths;local target=time+segment.hours/(24*segment.daysPerMonth)
        while time<target-1e-10 do
            a.age=math.floor(time+1e-10)
            local hour=math.floor((time-a.age)*24*segment.daysPerMonth+1e-8)+1
            local finish=math.min(target,a.age+hour/(24*segment.daysPerMonth),a.age+1)
            for _,boundary in ipairs({r.weaningMonth,r.weaningMonth+1}) do if boundary>time+1e-10 then finish=math.min(finish,boundary) end end
            local ok,why=feedStep(a,r.recipe,finish-time,r.ledger);if not ok then return fail(why,record) end
            time=finish;r.steps=r.steps+1
            if r.steps-record.steps>G.MAX_STEPS then return fail("OBSERVED_STEP_LIMIT",record) end
        end
        a.age=math.floor(a.rlGrowth.ageMonths+1e-10)
    end
    a.rlHistoryReplay=nil;a.rlGrowth.lastTick=nil;if a.bodyCondition then a.bodyCondition.lastTick=nil end
    r.cursorMonths=record.cursorMonths+total
    local portable={};for _,k in ipairs(fields) do portable[k]=a[k] end;r.animal=portable
    local ok,why=G.validate(r);if not ok then return fail(why,record) end
    return r
end
