-- Pure monthly demand selection. No live inventory, game RNG, physiology or cash.
-- Admission is explicit per breed + exact compiled package. A caller must obtain
-- MODEL_REACHABILITY evidence independently (U51); candidate structure is not proof.
RLBrokerDemand = {}
local D=RLBrokerDemand
D.VERSION=1
local speciesOrder={"COW","SHEEP","PIG"}
local groups={"GROWER","FINISHED","BREEDING"}
local groupIndex={GROWER=1,FINISHED=2,BREEDING=3}
local function text(v) return type(v)=="string" and v:match("%S")~=nil end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function integer(v,min) return finite(v) and v>=min and v<2^52 and v%1==0 end
local function requireValue(ok,reason) if not ok then error(reason,0) end end
local function copy(v) local value,why=RLMarketData.copy(v);requireValue(value~=nil,why);return value end
local function fp(v) return assert(RLMarketData.fingerprint(v)) end
local function dense(v)
    if type(v)~="table" then return false end
    local count,max=0,0
    for k in pairs(v) do if not integer(k,1) then return false end;count=count+1;max=math.max(max,k) end
    return count==max
end
local function version(v) return text(v) or integer(v,1) end
local function breedMatches(species,breed)
    return text(breed) and breed:sub(1,#species+1)==species..":" and #breed>#species+1 and not breed:find("[%s%c]")
end
local function diagnostic(out,code,scope) out[#out+1]={code=code,scope=scope} end
function D.validateBalance(balance)
    -- Reuse the single U91 validator, including its recomputed scaledSpecies.
    local config,why=RLMarketConfig.validate({schemaVersion=1,mode="legacy",layers={root={},types={},breeds={},subTypes={}},
        curves={},profiles={},rules={},templates={},brokerBalance=balance})
    if not config then return nil,why end
    return config.brokerBalance
end
function D.semanticKey(rules)
    local p=copy(rules)
    -- Display/template IDs and price policy IDs are not independent demand.
    p.id,p.revision,p.candidate=nil,nil,nil
    table.sort(p.allowedProductionClasses)
    for _,condition in ipairs(p.conditions) do if condition.op=="set" then table.sort(condition.values) end end
    table.sort(p.conditions,function(a,b)return fp(a)<fp(b)end)
    return fp(p)
end
local function randomUnit(seed,month,slot,ver,stream)
    local input=fp({seed,month,slot,ver,stream})
    local state=1
    for i=1,#input do state=(state*131+input:byte(i))%2147483647 end
    if state==0 then state=1 end
    state=(state*16807)%2147483647
    return (state-1)/2147483646
end
D.randomUnit=randomUnit
local function pick(items,weight,unit)
    local maximum=0
    for _,item in ipairs(items) do maximum=math.max(maximum,weight(item)) end
    if maximum<=0 then return nil end
    local sum=0;for _,item in ipairs(items) do sum=sum+weight(item)/maximum end
    local target=unit*sum
    for _,item in ipairs(items) do target=target-weight(item)/maximum;if target<0 then return item end end
    return items[#items]
end
local function season(entry,month)
    if entry.seasonWeights then return entry.seasonWeights[month] end
    local p=entry.rules
    if p.speciesKey=="SHEEP" and (p.kind=="eweReplacement" or p.kind=="ramSire") then
        return (month>=7 and month<=9) and 2 or (month==10 and 1.2 or 0.4)
    end
    if p.speciesKey=="COW" and (p.kind=="cattleReplacement" or p.kind=="cattlePregnant" or p.kind=="cattleLactating") then return month<=4 and 1.5 or 0.7 end
    return 1
end
local function sire(p) return p.kind=="cattleSire" or p.kind=="pigSire" or p.kind=="ramSire" end
local function headCategory(p)
    if sire(p) then return p.tier=="elite" and "eliteSireHeads" or "sireHeads" end
    return p.purposeGroup=="GROWER" and "growerHeads" or p.purposeGroup=="FINISHED" and "finishedHeads" or "replacementHeads"
end
local function quantity(entry,balance)
    if entry.orderHeads~=nil then return math.max(1,math.floor(entry.orderHeads*balance.capacityScale+0.5)),{kind="OVERRIDE",unscaledHeads=entry.orderHeads} end
    local key=headCategory(entry.rules)
    return balance.scaledSpecies[entry.rules.speciesKey][key],{kind=key}
end
local function compileCatalog(catalog,balance,diagnostics)
    requireValue(type(catalog)=="table" and catalog.schemaVersion==1 and dense(catalog.entries) and text(catalog.configRevision),"INVALID_ADMISSION_CATALOG")
    requireValue(catalog.testOnly==nil or type(catalog.testOnly)=="boolean","INVALID_TEST_CATALOG_FLAG")
    local entries=copy(catalog.entries)
    table.sort(entries,function(a,b) return fp(a)<fp(b) end)
    local candidates,seen={},{}
    for i,entry in ipairs(entries) do
        local p,why
        if type(entry)=="table" then p,why=RLBrokerConditionPackage.compile(entry.package) else why="INVALID_ENTRY" end
        if p==nil then diagnostic(diagnostics,"INVALID_PACKAGE:"..tostring(why),tostring(i))
        elseif balance.species[p.speciesKey]==nil or entry.speciesKey~=p.speciesKey or not breedMatches(p.speciesKey,entry.breedId)
            or (p.breedScope=="SPECIFIC" and p.requiredBreedId~=entry.breedId) then diagnostic(diagnostics,"ADMISSION_SCOPE_MISMATCH",p.id)
        elseif p.tier=="elite" and not sire(p) then diagnostic(diagnostics,"INVALID_ELITE_PURPOSE",p.id)
        elseif entry.verified~=true or not text(entry.evidenceRef) or entry.verificationType~="MODEL_REACHABILITY"
            or entry.packageRevision~=p.revision then diagnostic(diagnostics,"MODEL_REACHABILITY_UNVERIFIED",p.id)
        elseif not version(entry.classRevision) or not version(entry.traitMappingRevision) or not version(entry.formulaVersion) or not version(entry.priceRevision) or type(entry.priceBasis)~="table"
            or not text(entry.priceBasis.basisId) or (entry.priceBasis.currencyBasis~="HARD" and entry.priceBasis.currencyBasis~="CURRENT") then diagnostic(diagnostics,"MISSING_VERSIONED_BASIS",p.id)
        else
            local valid=entry.breedWeight==nil or (finite(entry.breedWeight) and entry.breedWeight>0)
            if entry.seasonWeights~=nil then
                valid=valid and dense(entry.seasonWeights) and #entry.seasonWeights==12
                if valid then for _,w in ipairs(entry.seasonWeights) do if not finite(w) or w<0 then valid=false end end end
            end
            valid=valid and (entry.orderHeads==nil or integer(entry.orderHeads,1))
            if not valid then diagnostic(diagnostics,"INVALID_CANDIDATE_WEIGHT_OR_QUANTITY",p.id)
            else
                entry.rules=p;entry.semanticKey=D.semanticKey(p)
                local total=quantity(entry,balance)
                local caps=balance.scaledSpecies[p.speciesKey]
                if not integer(total,1) or total>caps.monthlyHeadCap or (p.breedScope=="SPECIFIC" and total>caps.perBreedHeadCap) then diagnostic(diagnostics,"ORDER_EXCEEDS_SHARED_CAP",p.id)
                elseif not seen[entry.semanticKey] then seen[entry.semanticKey]=true;candidates[#candidates+1]=entry end
            end
        end
    end
    table.sort(candidates,function(a,b) return a.semanticKey<b.semanticKey end)
    return candidates
end
-- Validate a queued hot reload without publishing it. Unsupported individual
-- capability entries are diagnostics, while malformed top-level input is rejected.
function D.validateInputs(balance,catalog)
    local ok,result=pcall(function()
        local b=assert(D.validateBalance(balance));local c=copy(catalog)
        requireValue(type(c)=="table" and integer(c.calendarOriginMonth,1) and c.calendarOriginMonth<=12,"CALENDAR_ORIGIN_REQUIRED")
        local diagnostics={};compileCatalog(c,b,diagnostics)
        return {balance=b,catalog=c,diagnostics=diagnostics}
    end)
    if not ok then return nil,tostring(result) end
    return result
end
local function generate(seed,month,ver,balance,catalog,previous)
    requireValue(text(seed) or finite(seed),"INVALID_MARKET_SEED")
    requireValue(integer(month,0) and version(ver),"INVALID_GENERATOR_SCOPE")
    balance=assert(D.validateBalance(balance));catalog=copy(catalog)
    -- Explicit projection: origin is the calendar month at absolute index zero.
    -- Engine year*12+(period-1) uses 3 (March); calendar year*12+(month-1) uses 1.
    requireValue(type(catalog)=="table" and integer(catalog.calendarOriginMonth,1) and catalog.calendarOriginMonth<=12,"CALENDAR_ORIGIN_REQUIRED")
    local out={schemaVersion=1,absoluteMonth=month,monthId="BROKER:"..string.format("%.0f",month),
        calendarOriginMonth=catalog.calendarOriginMonth,calendarMonth=(month+catalog.calendarOriginMonth-1)%12+1,
        seedFingerprint=fp(seed),generatorVersion=ver,balance=balance,balanceRevision=balance.revision,configRevision=catalog.configRevision,
        testOnly=catalog.testOnly==true,orders={},diagnostics={},quotaDefinition={species={},orders={}}}
    for _,species in ipairs(speciesOrder) do
        local caps=balance.scaledSpecies[species]
        if caps then out.quotaDefinition.species[species]={monthlyHeadCap=caps.monthlyHeadCap,perBreedHeadCap=caps.perBreedHeadCap} end
    end
    local candidates=compileCatalog(catalog,balance,out.diagnostics)
    local recent={}
    if previous~=nil then
        local prev,why=D.validateSnapshot(previous)
        requireValue(prev~=nil,why)
        requireValue(prev.seedFingerprint==fp(seed),"PREVIOUS_MARKET_SEED_MISMATCH")
        requireValue(not prev.testOnly or catalog.testOnly==true,"TEST_HISTORY_NOT_PUBLISHABLE")
        if prev.absoluteMonth==month-1 then
            for _,order in ipairs(prev.orders) do if order.breedScope=="SPECIFIC" then recent[fp({order.speciesKey,order.requiredBreedId,order.breedingObjective or order.rules.kind})]=true end end
        else diagnostic(out.diagnostics,"PREVIOUS_MONTH_NOT_PUBLISHED",tostring(month-1)) end
    end
    local selected,counts,usedGroups,usedBreeds,baseGroups,extraSpecies={}, {},{}, {},{},{}
    local eliteCount=0
    local function candidateWeight(e)
        local repeated=recent[fp({e.rules.speciesKey,e.breedId,e.rules.breedingObjective or e.rules.kind})]
        local value=(e.breedWeight or 1)*season(e,out.calendarMonth)*(repeated and balance.previousMonthRepeatFactor or 1)
        requireValue(finite(value),"CANDIDATE_WEIGHT_OVERFLOW")
        return value
    end
    local function feasible(entry,extra,species)
        local p=entry.rules;local scope=balance.species[p.speciesKey]
        if species and p.speciesKey~=species then return false end
        if scope.groupWeights[groupIndex[p.purposeGroup]]<=0 then return false end
        if not extra and p.purposeGroup=="GROWER" then
            local modeWeight=p.breedScope=="ANY" and balance.growerAnyWeight or balance.growerSpecificWeight
            if modeWeight<=0 then return false end
        end
        if candidateWeight(entry)<=0 then return false end
        if selected[entry.semanticKey] or (counts[p.speciesKey] or 0)>=scope.maxOrders then return false end
        if p.tier=="elite" and (eliteCount>=balance.maxEliteOrders or balance.eliteConditionalChance==0) then return false end
        if extra and p.breedScope~="SPECIFIC" then return false end
        if not extra and baseGroups[p.speciesKey] and baseGroups[p.speciesKey][p.purposeGroup] then return false end
        local gs=usedGroups[p.speciesKey] or {};local n=0;for _ in pairs(gs) do n=n+1 end
        return gs[p.purposeGroup] or n<balance.maxPurposeGroupsPerSpecies
    end
    local function choose(slot,extra,species)
        if #out.orders>=balance.maxTotalOrders then diagnostic(out.diagnostics,"TOTAL_ORDER_LIMIT",slot);return end
        local pool={};for _,e in ipairs(candidates) do if feasible(e,extra,species) then pool[#pool+1]=e end end
        if extra then
            local fresh={};for _,e in ipairs(pool) do if not usedBreeds[e.rules.requiredBreedId] then fresh[#fresh+1]=e end end
            if #fresh>0 then pool=fresh end
            if balance.preferDistinctExtraSpecies then
                local distinct={};for _,e in ipairs(pool) do if not extraSpecies[e.rules.speciesKey] then distinct[#distinct+1]=e end end
                if #distinct>0 then pool=distinct end
            end
        end
        if #pool==0 then diagnostic(out.diagnostics,"NO_ADMITTED_CANDIDATE",slot);return end
        if species==nil then
            local available={};for _,s in ipairs(speciesOrder) do for _,e in ipairs(pool) do if e.rules.speciesKey==s then available[#available+1]=s;break end end end
            species=pick(available,function() return 1 end,randomUnit(seed,month,slot,ver,"species"))
        end
        local availableGroups={}
        for index,group in ipairs(groups) do
            for _,e in ipairs(pool) do if e.rules.speciesKey==species and e.rules.purposeGroup==group then availableGroups[#availableGroups+1]={name=group,weight=balance.species[species].groupWeights[index]};break end end
        end
        local group=pick(availableGroups,function(g)return g.weight end,randomUnit(seed,month,slot,ver,"group"))
        if not group then diagnostic(out.diagnostics,"NO_POSITIVE_GROUP_WEIGHT",slot);return end
        local matching={};for _,e in ipairs(pool) do if e.rules.speciesKey==species and e.rules.purposeGroup==group.name then matching[#matching+1]=e end end
        if group.name=="GROWER" and not extra then
            local modes={};for _,mode in ipairs({"ANY","SPECIFIC"}) do for _,e in ipairs(matching) do if e.rules.breedScope==mode then modes[#modes+1]=mode;break end end end
            local mode=pick(modes,function(m)return m=="ANY" and balance.growerAnyWeight or balance.growerSpecificWeight end,randomUnit(seed,month,slot,ver,"breedScope"))
            local filtered={};for _,e in ipairs(matching) do if e.rules.breedScope==mode then filtered[#filtered+1]=e end end;matching=filtered
        elseif group.name=="BREEDING" then
            local eliteAvailable=false;for _,e in ipairs(matching) do if e.rules.tier=="elite" then eliteAvailable=true end end
            local elite=eliteAvailable and randomUnit(seed,month,slot,ver,"tier")<balance.eliteConditionalChance
            local filtered={};for _,e in ipairs(matching) do if (e.rules.tier=="elite")==elite then filtered[#filtered+1]=e end end;matching=filtered
        end
        local chosen=pick(matching,candidateWeight,randomUnit(seed,month,slot,ver,"breed"))
        if not chosen then diagnostic(out.diagnostics,"NO_POSITIVE_CANDIDATE_WEIGHT",slot);return end
        local p=chosen.rules;local heads,basis=quantity(chosen,balance)
        local order={orderId=out.monthId..":"..slot,monthId=out.monthId,slotId=slot,slotType=extra and "EXTRA" or "BASE",
            speciesKey=species,purposeGroup=p.purposeGroup,breedScope=p.breedScope,requiredBreedId=p.requiredBreedId,
            allowedProductionClasses=copy(p.allowedProductionClasses),breedingObjective=p.breedingObjective,tier=p.tier,
            rules=copy(p),packageRevision=p.revision,semanticKey=chosen.semanticKey,quantityTotal=heads,quantityBasis=basis,
            classRevision=chosen.classRevision,traitMappingRevision=chosen.traitMappingRevision,configRevision=catalog.configRevision,
            formulaVersion=chosen.formulaVersion,priceRevision=chosen.priceRevision,priceBasis=copy(chosen.priceBasis),admissionEvidence={speciesKey=species,breedId=chosen.breedId,packageRevision=p.revision,
                verificationType=chosen.verificationType,evidenceRef=chosen.evidenceRef},status="OPEN"}
        out.orders[#out.orders+1]=order
        out.quotaDefinition.orders[order.orderId]={speciesKey=species,breedScope=p.breedScope,requiredBreedId=p.requiredBreedId,quantityTotal=heads}
        selected[chosen.semanticKey]=true;counts[species]=(counts[species] or 0)+1
        usedGroups[species]=usedGroups[species] or {};usedGroups[species][p.purposeGroup]=true
        if extra then extraSpecies[species]=true else baseGroups[species]=baseGroups[species] or {};baseGroups[species][p.purposeGroup]=true end
        if p.requiredBreedId then usedBreeds[p.requiredBreedId]=true end
        if sire(p) and p.tier=="elite" then eliteCount=eliteCount+1 end
    end
    for _,species in ipairs(speciesOrder) do
        local scope=balance.species[species]
        if scope then
            choose("BASE:"..species..":1",false,species)
            if scope.baseMax>scope.baseMin and randomUnit(seed,month,"BASE:"..species..":2",ver,"presence")<scope.secondSlotChance then choose("BASE:"..species..":2",false,species) end
        end
    end
    for i=1,balance.extraOrders do choose("EXTRA:"..i,true) end
    out.revision=fp(out)
    return out
end
function D.generate(seed,month,ver,balance,catalog,previous)
    local ok,result=pcall(generate,seed,month,ver,balance,catalog,previous)
    if not ok then return nil,tostring(result) end
    return result
end
-- Self-contained frozen rules remain explainable after templates disappear. A
-- full fingerprint detects mutation; this is not an authority signature or save proof.
function D.validateSnapshot(raw)
    local ok,result=pcall(function()
        local s=copy(raw)
        requireValue(type(s)=="table" and s.schemaVersion==1,"UNSUPPORTED_DEMAND_SCHEMA")
        local revision=s.revision;s.revision=nil;requireValue(revision==fp(s),"DEMAND_REVISION_MISMATCH");s.revision=revision
        requireValue(integer(s.absoluteMonth,0) and s.monthId=="BROKER:"..string.format("%.0f",s.absoluteMonth)
            and integer(s.calendarOriginMonth,1) and s.calendarOriginMonth<=12
            and s.calendarMonth==(s.absoluteMonth+s.calendarOriginMonth-1)%12+1 and text(s.seedFingerprint) and version(s.generatorVersion)
            and text(s.configRevision) and type(s.testOnly)=="boolean" and dense(s.orders) and dense(s.diagnostics),"INVALID_DEMAND_HEADER")
        local b=assert(D.validateBalance(s.balance));requireValue(fp(b)==fp(s.balance) and s.balanceRevision==b.revision,"INVALID_BALANCE_SNAPSHOT")
        local expected={species={},orders={}};local seen,counts,gs,baseGroups={}, {},{},{};local extras,elites=0,0
        for _,species in ipairs(speciesOrder) do local caps=b.scaledSpecies[species];if caps then expected.species[species]={monthlyHeadCap=caps.monthlyHeadCap,perBreedHeadCap=caps.perBreedHeadCap} end end
        for _,order in ipairs(s.orders) do
            requireValue(type(order)=="table" and order.monthId==s.monthId and text(order.slotId) and order.orderId==s.monthId..":"..order.slotId
                and (order.slotType=="BASE" or order.slotType=="EXTRA") and order.status=="OPEN","INVALID_ORDER_HEADER")
            local p=assert(RLBrokerConditionPackage.compile(order.rules));local species=p.speciesKey;local scope=b.species[species];local caps=b.scaledSpecies[species]
            requireValue(scope~=nil,"UNSUPPORTED_ORDER_SPECIES")
            if order.slotType=="BASE" then
                local index=tonumber(order.slotId:match("^BASE:"..species..":(%d+)$"))
                requireValue(index~=nil and integer(index,1) and index<=scope.baseMax and order.slotId=="BASE:"..species..":"..string.format("%.0f",index),"INVALID_BASE_SLOT")
            else
                local index=tonumber(order.slotId:match("^EXTRA:(%d+)$"))
                requireValue(index~=nil and integer(index,1) and index<=b.extraOrders and order.slotId=="EXTRA:"..string.format("%.0f",index),"INVALID_EXTRA_SLOT")
            end
            requireValue(scope~=nil and order.packageRevision==p.revision and fp(order.rules)==fp(p) and order.speciesKey==species
                and order.purposeGroup==p.purposeGroup and order.breedScope==p.breedScope and order.requiredBreedId==p.requiredBreedId
                and order.breedingObjective==p.breedingObjective and order.tier==p.tier and fp(order.allowedProductionClasses)==fp(p.allowedProductionClasses),"ORDER_RULE_MISMATCH")
            local semantic=D.semanticKey(p);requireValue(order.semanticKey==semantic and not seen[semantic],"DUPLICATE_DEMAND");seen[semantic]=true
            requireValue(version(order.classRevision) and version(order.traitMappingRevision) and version(order.formulaVersion) and version(order.priceRevision) and order.configRevision==s.configRevision
                and type(order.priceBasis)=="table" and text(order.priceBasis.basisId)
                and (order.priceBasis.currencyBasis=="CURRENT" or order.priceBasis.currencyBasis=="HARD"),"INVALID_ORDER_BASIS")
            local evidence=order.admissionEvidence
            requireValue(type(evidence)=="table" and evidence.speciesKey==species and breedMatches(species,evidence.breedId)
                and evidence.packageRevision==p.revision and evidence.verificationType=="MODEL_REACHABILITY" and text(evidence.evidenceRef)
                and (p.breedScope=="ANY" or evidence.breedId==p.requiredBreedId),"INVALID_ADMISSION_EVIDENCE")
            local quantityBasis=order.quantityBasis
            requireValue(type(quantityBasis)=="table","INVALID_QUANTITY_BASIS")
            local total
            if quantityBasis.kind=="OVERRIDE" then requireValue(integer(quantityBasis.unscaledHeads,1),"INVALID_QUANTITY_OVERRIDE");total=math.max(1,math.floor(quantityBasis.unscaledHeads*b.capacityScale+0.5))
            else requireValue(quantityBasis.kind==headCategory(p),"INVALID_QUANTITY_CATEGORY");total=caps[quantityBasis.kind] end
            requireValue(integer(order.quantityTotal,1) and order.quantityTotal==total and total<=caps.monthlyHeadCap
                and (p.breedScope=="ANY" or total<=caps.perBreedHeadCap),"INVALID_ORDER_CAPACITY")
            requireValue(expected.orders[order.orderId]==nil,"DUPLICATE_ORDER_ID")
            expected.orders[order.orderId]={speciesKey=species,breedScope=p.breedScope,requiredBreedId=p.requiredBreedId,quantityTotal=total}
            counts[species]=(counts[species] or 0)+1;requireValue(counts[species]<=scope.maxOrders,"SPECIES_ORDER_LIMIT")
            gs[species]=gs[species] or {};gs[species][p.purposeGroup]=true
            if order.slotType=="EXTRA" then extras=extras+1;requireValue(p.breedScope=="SPECIFIC","EXTRA_REQUIRES_SPECIFIC")
            else baseGroups[species]=baseGroups[species] or {};requireValue(not baseGroups[species][p.purposeGroup],"BASE_DUPLICATE_GROUP");baseGroups[species][p.purposeGroup]=true end
            requireValue(p.tier~="elite" or sire(p),"INVALID_ELITE_PURPOSE")
            if p.tier=="elite" then elites=elites+1 end
        end
        for _,g in pairs(gs) do local n=0;for _ in pairs(g) do n=n+1 end;requireValue(n<=b.maxPurposeGroupsPerSpecies,"PURPOSE_GROUP_LIMIT") end
        requireValue(#s.orders<=b.maxTotalOrders and extras<=b.extraOrders and elites<=b.maxEliteOrders,"MONTH_LAYOUT_LIMIT")
        requireValue(fp(expected)==fp(s.quotaDefinition),"QUOTA_DEFINITION_MISMATCH")
        return s
    end)
    if not ok then return nil,tostring(result) end
    return result
end
