loadMod("tests/dealerownedfixture.lua")
loadMod("scripts/core/RLConstants.lua")
loadAnimalSection("function Animal:getIdentifiers()", "function Animal:compareIdentifiers")
loadMod("scripts/dealer/RLDealerHandoff.lua")
loadMod("scripts/dealer/RLDealerSourceFactory.lua")
local F,S,O=RLDealerSourceFactory,RLDealerSourceState,RLDealerSourceOwnership
local function copy(v) if type(v)~="table" then return v end;local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out end
local function canonical(v) return RLTradePersistence.canonical(v) end
local function fixture(pregnant)
    local _,baseCtx=DealerOwnedFixture.new()
    local seed=DealerReplaySim.seed("HOLSTEIN","female",1)
    local entry=RLDealerStockPolicy.getEntry(RLDealerStockPolicy.getConfig(),seed.subType,"COW")
    local purpose=RLDealerStockPolicy.findPurpose(entry,"female",pregnant and "HEIFER_IN_CALF" or "HEIFER_READY")
    local history=DealerReplaySim.history(seed,pregnant and 20.25 or 20.5,pregnant and "NORMAL_PRODUCTION" or nil,
        pregnant and {{kind="CONCEPTION",atMonths=17.125,parity=1}} or nil)
    history.source="DAIRY_HERD"
    local candidate,failure=RLDealerReplay.evaluate(seed,history,entry,purpose,
        {maxBuyAge=72,weaningMonth=3,union={{0,72}},lactates=true},
        {daysPerMonth=1,pregnancySubTypes=pregnant and {[4]={seed.subType}} or nil})
    assert(candidate,failure and failure.reason)
    local prepared={version=1,requestId="ADMISSION-1",sourceOwnerId="SOURCE-OWNER",capacity=5,
        adult={uniqueId="DAM-SELECTED",farmId="HERD-SELECTED",subType=seed.subType.name,
            birthday={day=12,month=2,year=2025,country=4,lastAgeMonth=10},deathEnabled=true,diseases={},
            name="Selected mother",marks={},variation=1,motherId="GRAND-DAM",fatherId="GRAND-SIRE",children={}},
        evidence={version=1,requestId="ADMISSION-1",selectionId="SELECTED-ONCE"}}
    if pregnant then
        prepared.pregnancy={duration=10,expected={day=4,month=5,year=2027},fetuses={{uniqueId="FETUS-SELECTED",
            farmId=prepared.adult.farmId,subType=seed.subType.name,
            genetics={metabolism=2.1,quality=2.25,productivity=1.8,fertility=0,health=0.9}}}}
        prepared.sire={uniqueId="SIRE-SELECTED",farmId="SIRE-HERD",breed="HOLSTEIN",subType=seed.subType.name,
            genetics={metabolism=1,quality=1,productivity=1,fertility=1,health=1}}
    end
    g_server={}
    return candidate,prepared,{isServer=true,currentCursorMonths=200,resolveSubType=baseCtx.resolveSubType}
end
for _,pregnant in ipairs({false,true}) do
    local candidate,p,ctx=fixture(pregnant)
    local before=canonical(p);local originalWeight=candidate.animal.weight
    local random,ensure,sanitize=math.random,RLGrowth.ensureState,RLGrowth.sanitizeState
    math.random=function() error("factory RNG forbidden") end
    RLGrowth.ensureState=function() error("factory migration forbidden") end
    RLGrowth.sanitizeState=function() error("factory sanitize forbidden") end
    local value,failure=F.materialize(candidate,p,ctx)
    math.random,RLGrowth.ensureState,RLGrowth.sanitizeState=random,ensure,sanitize
    assert(value,failure and failure.reason)
    local animal,owner=value.animal,value.owner
    check("source factory: "..tostring(pregnant).." assembles detached real owner with exact candidate physiology",animal.weight==originalWeight
        and canonical(animal.rlGrowth)==canonical(candidate.animal.rlGrowth) and animal.uniqueId==p.adult.uniqueId
        and animal.farmId==p.adult.farmId and animal.clusterSystem==owner.clusterSystem and owner.byId[animal.uniqueId]==animal
        and not animal.rlHistoryReplay and animal.sale==nil and animal.name==p.adult.name and animal.deathEnabled==true)
    check("source factory: "..tostring(pregnant).." retains explicit identity birthday and unchanged prepared evidence",canonical(p)==before
        and canonical(animal.birthday)==canonical(p.adult.birthday) and value.requestId==p.requestId
        and canonical(value.preparedEvidence)==before and value.ownership.sourceId==p.sourceOwnerId)
    check("source factory: "..tostring(pregnant).." strict owner codec roundtrips exact source record",O.restore(value.ownership,ctx.resolveSubType,{isServer=true})~=nil
        and canonical(value.recordsByAnimalId[animal.uniqueId])==canonical(value.sourceRecord) and S.validate(value.sourceRecord))
    if pregnant then
        local child=animal.pregnancy.pregnancies[1]
        check("source factory: fixed fetus identity and inherited outlier genes survive without birth sampling",child.uniqueId=="FETUS-SELECTED"
            and child.farmId==p.adult.farmId and child.age==-1 and child.rlGrowth==nil
            and child.genetics.metabolism==2.1 and child.genetics.quality==2.25 and child.genetics.fertility==0
            and child.fatherId=="SIRE-SELECTED" and owner.sireContexts[animal.uniqueId].uniqueId=="SIRE-SELECTED"
            and canonical(animal.pregnancy.expected)==canonical(p.pregnancy.expected))
    end
    value.preparedEvidence.adult.name="changed";value.ownership.animals[1].identity.name="changed"
    check("source factory: "..tostring(pregnant).." returned portable snapshots do not alias prepared or real identity",p.adult.name=="Selected mother"
        and animal.name=="Selected mother" and candidate.animal.weight==originalWeight)
end
local cases={
    {"native missing-owner identity fallback",function(c,p,x) p.adult.uniqueId="1";p.adult.farmId="1" end},
    {"native fetal identity fallback",function(c,p,x) p.adult.farmId="1";p.pregnancy.fetuses[1].farmId="1";p.pregnancy.fetuses[1].uniqueId="1" end},
    {"native sire identity fallback",function(c,p,x) p.sire.uniqueId="1";p.sire.farmId="1" end},
    {"unverified candidate",function(c,p,x) c.eligibility="UNSCREENED" end},
    {"missing D2 evaluated metadata",function(c,p,x) c.animal.sale=nil end},
    {"model disease cannot flatten",function(c,p,x) c.animal.diseases={{isCarrier=true,model={title="MODEL"}}} end},
    {"dead historical candidate",function(c,p,x) c.animal.isDead=true end},
    {"missing current subtype",function(c,p,x) x.resolveSubType=function() return nil end end},
    {"mismatched subtype registry",function(c,p,x) x.resolveSubType=function(name) return {name="WRONG"},1 end end},
    {"foreign request provenance",function(c,p,x) p.evidence.requestId="FOREIGN" end},
    {"unexpected persistence callback",function(c,p,x) p.persist=function() error("callback") end end},
    {"adult genetic override",function(c,p,x) p.adult.genetics=copy(c.animal.genetics) end},
    {"duplicate fetus identity",function(c,p,x) p.pregnancy.fetuses[1].uniqueId=p.adult.uniqueId end},
    {"foreign fetus herd",function(c,p,x) p.pregnancy.fetuses[1].farmId="FOREIGN" end},
    {"wrong fetal subtype",function(c,p,x) p.pregnancy.fetuses[1].subType="MISSING" end},
    {"invalid inherited metabolism",function(c,p,x) p.pregnancy.fetuses[1].genetics.metabolism=0 end},
    {"missing sire",function(c,p,x) p.sire=nil end},
    {"undersized private capacity",function(c,p,x) p.capacity=1 end},
    {"missing birthday",function(c,p,x) p.adult.birthday=nil end},
    {"missing fixed death rule",function(c,p,x) p.adult.deathEnabled=nil end},
    {"disease override",function(c,p,x) p.adult.diseases={{isCarrier=true,title="FOREIGN"}} end},
    {"nonserver context",function(c,p,x) x.isServer=false end}}
for _,case in ipairs(cases) do
    local c,p,x=fixture(true);case[2](c,p,x)
    local constructor=Animal.new;local shells=0
    Animal.new=function(...) shells=shells+1;return constructor(...) end
    local value,failure=F.materialize(c,p,x);Animal.new=constructor
    check("source factory: "..case[1].." refuses before constructing any private animals",not value and type(failure.reason)=="string" and shells==0)
end

local c,p,x=fixture(false)
c.animal.diseases={{title="CARRIER",isCarrier=true,monthsElapsed=0.375}}
p.adult.diseases=copy(c.animal.diseases)
local carrier,failure=F.materialize(c,p,x);assert(carrier,failure and failure.reason)
check("source factory: portable carrier disease state preserves exact metadata without model downgrade",carrier.animal.diseases[1].monthsElapsed==0.375
    and carrier.ownership.animals[1].diseases[1].kind=="PLAIN")
local savedResolve=x.resolveSubType
x.resolveSubType=function(name) local sub,index=savedResolve(name);return sub,index end
local ctor=Animal.new;Animal.new=function() error("constructor failure") end
local failed,denied=F.materialize(c,p,x);Animal.new=ctor
check("source factory: constructor failure returns no owner or partial publication",not failed and denied.reason=="SOURCE_FACTORY_ASSEMBLY_ERROR")
local stale=copy(p);stale.adult.birthday.day=31;stale.adult.birthday.month=2
local bad,reason=F.materialize(c,stale,x)
check("source factory: impossible fixed calendar date refuses instead of drawing replacement birthday",not bad and reason.reason=="SOURCE_FACTORY_ADULT")
for _,mutation in ipairs({"birthday","fetalIdentity","fetalGenes"}) do
    local candidate,prepared,ctx=fixture(true)
    local frozen=canonical(prepared);local resolver=ctx.resolveSubType;local mutated=false
    ctx.resolveSubType=function(name)
        if not mutated then
            mutated=true
            if mutation=="birthday" then prepared.adult.birthday.day=13
            elseif mutation=="fetalIdentity" then prepared.pregnancy.fetuses[1].uniqueId="CALLBACK-IDENTITY"
            else prepared.pregnancy.fetuses[1].genetics.metabolism=3.1 end
        end
        return resolver(name)
    end
    local assembled,denied=F.materialize(candidate,prepared,ctx)
    check("source factory: resolver mutation of original "..mutation.." cannot change frozen selection",mutated
        and (not assembled and denied~=nil or assembled and canonical(assembled.preparedEvidence)==frozen
            and assembled.animal.birthday.day==12 and assembled.animal.pregnancy.pregnancies[1].uniqueId=="FETUS-SELECTED"
            and assembled.animal.pregnancy.pregnancies[1].genetics.metabolism==2.1))
    check("source factory: external "..mutation.." mutation remains visible rather than being overwritten",canonical(prepared)~=frozen)
end

local invalidCountry,invalidCountryPrepared,invalidCountryCtx=fixture(false)
invalidCountryPrepared.adult.birthday.country=99999
local countryConstructor=Animal.new;local countryShells=0
Animal.new=function(...) countryShells=countryShells+1;return countryConstructor(...) end
local countryValue,countryFailure=F.materialize(invalidCountry,invalidCountryPrepared,invalidCountryCtx)
Animal.new=countryConstructor
check("source factory: nonexistent fixed country refuses before constructing even a nonpregnant mother",not countryValue
    and countryFailure.reason=="SOURCE_FACTORY_ADULT" and countryShells==0)
for _,placeholder in ipairs({"adult","fixedFetus"}) do
    local candidate,prepared,ctx=fixture(true)
    if placeholder=="adult" then prepared.adult.uniqueId="1-1"
    else prepared.pregnancy.fetuses[1].uniqueId="1-1" end
    local constructor=Animal.new;local shells=0
    Animal.new=function(...) shells=shells+1;return constructor(...) end
    local result,failure=F.materialize(candidate,prepared,ctx);Animal.new=constructor
    check("source factory: "..placeholder.." placeholder 1-1 cannot materialize an owned identity",not result
        and type(failure.reason)=="string" and shells==0)
end
