loadMod("tests/marketreachability.lua")
loadMod("scripts/market/RLMarketMoney.lua")
loadMod("scripts/market/RLBrokerPricePolicy.lua")
loadMod("scripts/market/RLBrokerCattlePolicy.lua")
local P=RLBrokerCattlePolicy
local rules=assert(P.rules())
BROKER_CATTLE_WINDOWS={}
for _,mode in ipairs({"REAL","LEGACY"}) do
    for _,name in ipairs({"COW_ANGUS","BULL_ANGUS"}) do
        FeedSim.setMode(mode=="REAL");GrowthSim.setDaysPerPeriod(1)
        local a=GrowthSim.newborn(name,{farmId="123456",uniqueId="10001",birthday={country=1},
            isDead=false,canBeSold=true,isCastrated=false,birthCount=0})
        local pen=FeedSim.makePen({a},{})
        FeedSim.addWater(pen,1,0,true)
        local stock=FeedSim.keepStocked({FORAGE=100000,CALFMILK=100000})
        local first,last,sample,eligible= nil,nil,nil,0
        local unchanged=true
        for step=1,12*24 do
            stock(pen);FeedSim.hour(pen)
            local s=assert(RLMarketSnapshot.capture(a,{classRevision=P.CLASS_REVISION,traitMappingRevision=P.TRAIT_REVISION},
                {diseasesEnabled=false}))
            local before=RLMarketData.fingerprint(a.rlGrowth)
            local facts,caps=P.facts(a,s)
            unchanged=unchanged and before==RLMarketData.fingerprint(a.rlGrowth)
            local context={permissionGranted=true,ownershipVerified=true,identityVerified=true,unlocked=true,
                orderOpen=true,sourceSupported=true,quota={order=4,species=8,breed=4},facts=facts,factCapabilities=caps}
            local result=RLBrokerEligibility.evaluate(s,rules,context)
            if result.eligible then
                first=first or {age=s.ageMonths,weight=s.weightKg,development=a.rlGrowth.developmentMonths}
                last={age=s.ageMonths,weight=s.weightKg,development=a.rlGrowth.developmentMonths}
                sample={snapshot=s,context=context};eligible=eligible+1
            end
            if step%24==0 then a.age=a.age+1 end
        end
        check("broker cattle: complete real-model qualification "..mode.." "..name,eligible>0)
        check("broker cattle: fact reads preserve growth state over twelve months "..mode.." "..name,unchanged)
        if sample then
            local grown=assert(RLMarketData.copy(sample.snapshot))
            grown.weightKg=grown.production.slaughterReferenceKg;grown.production.finishScore=70;grown.traitCapabilities.finishScore=true
            local facts=P.facts(a,grown)
            check("broker cattle: finish fact uses live weight/condition instead of age "..mode.." "..name,facts.finished==true)
            grown.traitCapabilities.slaughterReference=false
            facts=P.facts(a,grown)
            check("broker cattle: missing finish reference stays unknown "..mode.." "..name,facts.finished==nil)
            for field,value in pairs({health=79,ageMonths=3.99,weightKg=1}) do
                local bad=assert(RLMarketData.copy(sample.snapshot));bad[field]=value
                check("broker cattle: rejects "..field.." "..mode.." "..name,not RLBrokerEligibility.evaluate(bad,rules,sample.context).eligible)
            end
            local context=assert(RLMarketData.copy(sample.context));context.facts.developmentReady=false
            check("broker cattle: rejects underdeveloped "..mode.." "..name,not RLBrokerEligibility.evaluate(sample.snapshot,rules,context).eligible)
            context=assert(RLMarketData.copy(sample.context));context.quota.breed=0
            check("broker cattle: exhausted breed blocks "..mode.." "..name,not RLBrokerEligibility.evaluate(sample.snapshot,rules,context).eligible)
        end
        BROKER_CATTLE_WINDOWS[#BROKER_CATTLE_WINDOWS+1]={mode=mode,name=name,first=first,last=last,hours=eligible}
    end
end
-- Financial policy uses actual current-currency inputs, never applies difficulty
-- twice, and cannot turn an unknown acquisition into a higher-price exit.
RLMarketEnginePrice={salePrice=function(a) return a.bid end}
RLAnimalBuyService={computeBuyPrice=function(a) return a.ask end}
local m={animalSystem={getAnimalTransportFee=function() return 50 end}}
local s={speciesKey="COW",breedId="COW:ANGUS",subTypeName="BULL_ANGUS",classRevision=P.CLASS_REVISION,traitMappingRevision=P.TRAIT_REVISION}
for _,mult in ipairs({1,1.8,3}) do
    local a={bid=1000*mult,ask=1300*mult,subTypeIndex=1,age=6}
    local q=assert(P.quote(a,s,m))
    check("broker cattle: Dealer purchase/sale roundtrip loses at difficulty "..mult,q.pickup.netToPlayer<a.ask and near(q.selfDelivery.netToPlayer,1000*mult))
    check("broker cattle: transport difference exactly one fee "..mult,near(q.selfDelivery.netToPlayer-q.pickup.netToPlayer,25))
end
local q=P.quote({bid=0,ask=10},s,m)
check("broker cattle: zero reference refuses settlement",q==nil)
