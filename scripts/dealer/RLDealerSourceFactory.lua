-- Pure server-side assembly of a VERIFIED_CANDIDATE. No allocation, sampling,
-- publication, callbacks or durability claims occur here. All objects stay detached
-- from engine/player inventories; caller must journal the complete result separately.
-- prepared v1 (strict plain data):
-- {version,requestId,sourceOwnerId,capacity,adult={uniqueId,farmId,subType,birthday,
-- deathEnabled,diseases,name?,marks?,variation?,motherId?,fatherId?,children?},
-- pregnancy?={duration,expected,fetuses={{uniqueId,farmId,subType,genetics,weightKg?}}},
-- sire?={uniqueId,farmId,breed,subType?,genetics},
-- evidence={version=1,requestId,selectionId}}.
-- Birthday includes day/month/year/country/lastAgeMonth. Expected includes day/month/year.
-- selectionId identifies already completed selection, NOT a persisted/committed claim.
-- Failure returns nil,{reason}; discarded detached shells authorize neither retry RNG
-- nor publication. Diseases currently accept only exact portable candidate records;
-- model-backed Disease instances are explicitly unsupported, never flattened.
-- ctx={isServer=true,currentCursorMonths,resolveSubType(name)->sub,index}.
-- Returns {version,requestId,sourceOwnerId,owner,animal,sourceRecord,
-- recordsByAnimalId,ownership,preparedEvidence}; no result is externally installed.
RLDealerSourceFactory={VERSION=1}
local F=RLDealerSourceFactory
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function id(v) return type(v)=="string" and #v>0 and #v<=256 and v~="-1" and v~="0" and v~="0-0" end
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function keys(v,allowed)
    if type(v)~="table" then return false end
    for key in pairs(v) do if not allowed[key] then return false end end
    return true
end
local function dense(v)
    if type(v)~="table" then return false end
    local n=0;for key in pairs(v) do if not finite(key) or key%1~=0 or key<1 or key>#v then return false end;n=n+1 end
    return n==#v
end
local function integer(v,low,high) return finite(v) and v%1==0 and v>=low and (not high or v<=high) end
local function calendar(v,birthday)
    if not keys(v,{day=true,month=true,year=true,country=birthday,lastAgeMonth=birthday})
        or not integer(v.day,1,31) or not integer(v.month,1,12) or not integer(v.year,0) then return false end
    local days=RLConstants and RLConstants.DAYS_PER_MONTH
    if days and days[v.month] and v.day>days[v.month] then return false end
    return not birthday or integer(v.country,1) and integer(v.lastAgeMonth,1,12)
        and RLConstants and type(RLConstants.AREA_CODES)=="table" and RLConstants.AREA_CODES[v.country]~=nil
end
local function genes(v)
    if not keys(v,{metabolism=true,quality=true,productivity=true,fertility=true,health=true}) then return false end
    for _,key in ipairs({"metabolism","quality","productivity","fertility","health"}) do if not finite(v[key]) or v[key]<0 then return false end end
    return v.metabolism>0
end
local function fail(reason) return nil,{reason=reason} end
local function resolve(name,ctx)
    local sub,index=ctx.resolveSubType(name)
    index=index or (sub and sub.subTypeIndex)
    if type(sub)~="table" or sub.name~=name or sub.typeIndex~=AnimalType.COW or not RLGrowth.coversSubType(sub)
        or not integer(index,1) then return nil end
    return {sub=sub,index=index}
end
local function preflight(candidate,p,ctx)
    if type(ctx)~="table" or ctx.isServer~=true or g_server==nil or type(ctx.resolveSubType)~="function"
        or not finite(ctx.currentCursorMonths) or ctx.currentCursorMonths<0 then return fail("SOURCE_FACTORY_SERVER") end
    if type(candidate)~="table" or candidate.eligibility~="VERIFIED_CANDIDATE" then return fail("SOURCE_FACTORY_CANDIDATE") end
    local screened,why=RLDealerReplay.screen(candidate);if not screened then return fail(why) end
    local sale=candidate.animal.sale
    if type(sale)~="table" or not id(sale.purpose) or sale.source~=candidate.history.source
        or sale.parity~=candidate.animal.birthCount then return fail("SOURCE_FACTORY_CANDIDATE") end
    for _,disease in pairs(candidate.animal.diseases or {}) do
        if type(disease)~="table" or disease.model~=nil or getmetatable(disease)~=nil then return fail("SOURCE_FACTORY_DISEASE_MODEL") end
    end
    local record,error=RLDealerSourceState.capture(candidate,ctx.currentCursorMonths);if not record then return nil,error end
    if record.animal.isDead or record.ageMonths~=record.history.saleAgeMonths or record.observedSourceEvents~=nil then return fail("SOURCE_FACTORY_CANDIDATE") end
    if type(p)~="table" or RLTradePersistence.check(p) or not keys(p,{version=true,requestId=true,sourceOwnerId=true,capacity=true,adult=true,pregnancy=true,sire=true,evidence=true})
        or p.version~=F.VERSION or not id(p.requestId) or not id(p.sourceOwnerId) or not integer(p.capacity,1)
        or not keys(p.evidence,{version=true,requestId=true,selectionId=true}) or p.evidence.version~=1
        or p.evidence.requestId~=p.requestId or not id(p.evidence.selectionId) then return fail("SOURCE_FACTORY_PREPARED") end
    local a=p.adult
    if not keys(a,{uniqueId=true,farmId=true,subType=true,birthday=true,deathEnabled=true,diseases=true,name=true,marks=true,variation=true,motherId=true,fatherId=true,children=true})
        or not id(a.uniqueId) or not id(a.farmId) or a.subType~=record.animal.subType or not calendar(a.birthday,true)
        or type(a.deathEnabled)~="boolean" or not dense(a.diseases) or not equal(a.diseases,record.animal.diseases or {})
        or (a.name~=nil and type(a.name)~="string") or (a.marks~=nil and type(a.marks)~="table")
        or (a.variation~=nil and not integer(a.variation,1)) or (a.children~=nil and not dense(a.children))
        or (a.motherId~=nil and type(a.motherId)~="string") or (a.fatherId~=nil and type(a.fatherId)~="string") then return fail("SOURCE_FACTORY_ADULT") end
    local adult=resolve(a.subType,ctx);if not adult then return fail("SOURCE_FACTORY_SUBTYPE") end
    if adult.sub.breed~=record.animal.breed or adult.sub.gender~=record.animal.gender then return fail("SOURCE_FACTORY_SUBTYPE") end
    local resolved,error=RLDealerSourceState.restore(record,function(name) local value=resolve(name,ctx);return value and value.sub end)
    if not resolved then return nil,error end
    local fetuses={}
    if record.animal.isPregnant then
        local pregnancy,sire=p.pregnancy,p.sire
        if not keys(pregnancy,{duration=true,expected=true,fetuses=true}) or pregnancy.duration~=record.history.durationMonths
            or not calendar(pregnancy.expected,false) or not dense(pregnancy.fetuses) or #pregnancy.fetuses<1 or #pregnancy.fetuses>3
            or 1+#pregnancy.fetuses>p.capacity then return fail("SOURCE_FACTORY_PREGNANCY") end
        if not keys(sire,{uniqueId=true,farmId=true,breed=true,subType=true,genetics=true}) or not id(sire.uniqueId)
            or not id(sire.farmId) or not id(sire.breed) or not genes(sire.genetics) or (sire.subType~=nil and not id(sire.subType)) then return fail("SOURCE_FACTORY_SIRE") end
        local life=RLDealerReplay.getSourceLifecycle(record.history,record.observedSourceEvents,record.ageMonths)
        local selection
        for index,event in ipairs(record.history.events) do if event.kind=="CONCEPTION" and event.atMonths==life.conceptionMonths then selection=record.fetalSelections[index] end end
        if not selection or #selection~=#pregnancy.fetuses then return fail("SOURCE_FACTORY_FETAL") end
        local seen={[a.uniqueId]=true}
        for index,child in ipairs(pregnancy.fetuses) do
            if not keys(child,{uniqueId=true,farmId=true,subType=true,genetics=true,weightKg=true}) or not id(child.uniqueId)
                or seen[child.uniqueId] or child.farmId~=a.farmId or not genes(child.genetics)
                or (child.weightKg~=nil and (not finite(child.weightKg) or child.weightKg<=0)) then return fail("SOURCE_FACTORY_FETAL") end
            seen[child.uniqueId]=true
            local binding=resolve(child.subType,ctx);local expected=selection[index]
            if not binding or binding.sub.name~=expected.subType or binding.sub.breed~=expected.breed or binding.sub.gender~=expected.sex then return fail("SOURCE_FACTORY_FETAL") end
            fetuses[index]=binding
        end
    elseif p.pregnancy~=nil or p.sire~=nil then return fail("SOURCE_FACTORY_PREGNANCY") end
    return {record=record,adult=adult,fetuses=fetuses}
end
function F.materialize(candidate,prepared,ctx)
    -- Resolver callbacks may inspect external state. Assemble only the selection
    -- supplied at entry, never a caller table changed during model resolution.
    if type(prepared)~="table" or RLTradePersistence.check(prepared) then return fail("SOURCE_FACTORY_PREPARED") end
    prepared=copy(prepared)
    local ok,validated,error=pcall(preflight,candidate,prepared,ctx)
    if not ok then return fail("SOURCE_FACTORY_VALIDATION_ERROR") end
    if not validated then return nil,error end
    local assembled,result,failure=pcall(function()
        local p,a=prepared,prepared.adult
        local record=validated.record
        local function shell(binding,uniqueId,farmId,selectedGenes,weight)
            local animal=Animal.new({age=-1,health=100,gender=binding.sub.gender,subTypeIndex=binding.index,
                genetics=copy(selectedGenes),weight=weight,uniqueId=uniqueId,farmId=farmId})
            if animal:getSubType().name~=binding.sub.name or animal.uniqueId~=uniqueId or animal.farmId~=farmId
                or not equal(animal.genetics,selectedGenes) or animal.clusterSystem~=nil then error("source shell registry/identity changed") end
            return animal
        end
        local animal=shell(validated.adult,a.uniqueId,a.farmId,record.animal.genetics,record.animal.weight)
        for _,key in ipairs({"birthday","deathEnabled","name","marks","variation","motherId","fatherId","children"}) do
            if a[key]~=nil then rawset(animal,key,copy(a[key])) end
        end
        if p.pregnancy then
            animal.pregnancy={duration=p.pregnancy.duration,expected=copy(p.pregnancy.expected),pregnancies={}}
            for index,spec in ipairs(p.pregnancy.fetuses) do
                local child=shell(validated.fetuses[index],spec.uniqueId,spec.farmId,spec.genetics,spec.weightKg or 1)
                child.motherId,child.fatherId=animal:getIdentifiers(),p.sire.uniqueId
                animal.pregnancy.pregnancies[index]=child
            end
        end
        local installed,denied=RLDealerHandoff.install(record,animal,{isServer=true});if not installed then return nil,denied end
        -- Handoff's -1 is a live invalid-tick sentinel. A private detached source
        -- canonical ledger has no live tick; retain its exact historical values.
        animal.rlGrowth.lastTick=record.animal.rlGrowth.lastTick
        if animal.bodyCondition then animal.bodyCondition.lastTick=record.animal.bodyCondition and record.animal.bodyCondition.lastTick end
        local owner,denied=RLDealerSourceReproduction.createOwner(p.sourceOwnerId,p.capacity,{animal});if not owner then return nil,denied end
        if p.sire then local pinned,why=RLDealerSourceReproduction.pinSire(owner,animal.uniqueId,p.sire);if not pinned then return nil,why end end
        local records={[animal.uniqueId]=record}
        local ownership,why=RLDealerSourceOwnership.export(owner,records);if not ownership then return nil,why end
        return {version=F.VERSION,requestId=p.requestId,sourceOwnerId=p.sourceOwnerId,owner=owner,animal=animal,
            sourceRecord=record,recordsByAnimalId=records,ownership=ownership,preparedEvidence=copy(p)}
    end)
    if not assembled then return fail("SOURCE_FACTORY_ASSEMBLY_ERROR") end
    return result,failure
end
