-- First released scope: shipped Angus weaned calves, pickup, single player.
-- Policy facts are read from the same curve and rearing stage as live growth.
RLBrokerCattlePolicy = {}
local P = RLBrokerCattlePolicy
P.CLASS_REVISION = "broker-cattle-classes:1"
P.TRAIT_REVISION = "broker-cattle-traits:1"
P.REVISION = "angus-weaned:1"
P.EVIDENCE = "docs/evidence/broker-cattle-release.md"
P.PICKUP_FACTOR = .5
local finite = RLPlain.finite
function P.rules()
    return RLBrokerConditionPackage.compile(assert(RLBrokerConditionPackage.candidate("cattleWeaned", {
        id=P.REVISION, allowedProductionClasses={"BEEF"}, breedScope="SPECIFIC", requiredBreedId="COW:ANGUS"
    })))
end
function P.supported(snapshot)
    return type(snapshot)=="table" and snapshot.speciesKey=="COW" and snapshot.breedId=="COW:ANGUS"
        and (snapshot.subTypeName=="COW_ANGUS" or snapshot.subTypeName=="BULL_ANGUS")
        and snapshot.classRevision==P.CLASS_REVISION and snapshot.traitMappingRevision==P.TRAIT_REVISION
end
function P.catalog()
    local rules=assert(P.rules())
    return {schemaVersion=1,configRevision=P.REVISION,calendarOriginMonth=3,entries={{
        speciesKey="COW",breedId="COW:ANGUS",package=rules,packageRevision=rules.revision,
        verified=true,verificationType="MODEL_REACHABILITY",evidenceRef=P.EVIDENCE,
        classRevision=P.CLASS_REVISION,traitMappingRevision=P.TRAIT_REVISION,formulaVersion=1,
        priceRevision=P.REVISION,priceBasis={basisId=P.REVISION,currencyBasis="CURRENT"},orderHeads=4
    }}}
end
function P.facts(animal,snapshot)
    if not P.supported(snapshot) or not RLGrowth.covers(animal) then return nil,"UNSUPPORTED_CATTLE_MODEL" end
    local binding=RLGrowth.getBinding(animal:getSubType())
    if not binding or type(animal.rlGrowth)~="table" then return nil,"GROWTH_STATE_REQUIRED" end
    -- buildCurve is pure; getCurve would populate a cache on the live animal.
    local curve=RLGrowth.buildCurve(binding,RLGrowth.getFrameTarget(animal,binding),RLGrowth.getBirthWeight(animal,binding))
    local reference=curve:value(snapshot.ageMonths)
    local development=animal.rlGrowth.developmentMonths
    if not finite(reference) or reference<=0 or not finite(development) then return nil,"GROWTH_REFERENCE_REQUIRED" end
    local weaned=RLCalfRearing.getStage(animal)==RLCalfRearing.STAGE_WEANED
    local production,caps=snapshot.production or {},snapshot.traitCapabilities or {}
    local slaughterReference=production.slaughterReferenceKg
    local finished
    if caps.slaughterReference==true and finite(slaughterReference) and slaughterReference>0 and finite(snapshot.weightKg) then
        -- Use the same individual-weight/finish thresholds as cattleFinished.
        -- Age alone cannot establish an unfinished animal; missing evidence
        -- remains UNKNOWN instead of being converted into a false fact.
        if snapshot.weightKg<slaughterReference*.95 then finished=false
        elseif caps.finishScore==true and finite(production.finishScore) then finished=production.finishScore>=65 end
    end
    local facts={actualMinimumAgeMonths=4,minimumPurchaseKg=curve:value(4)*.75,ageReferenceKg=reference,
        weaned=weaned,developmentReady=development>=4,finished=finished}
    local factCaps={};for key in pairs(facts) do factCaps[key]=true end
    return facts,factCaps
end
function P.quote(animal,snapshot,mission)
    if not P.supported(snapshot) then return nil,"UNSUPPORTED_CATTLE_SCOPE" end
    local bid=RLMarketEnginePrice.salePrice(animal)
    local ask=RLAnimalBuyService.computeBuyPrice(animal)
    local pickup=mission.animalSystem:getAnimalTransportFee(animal.subTypeIndex,animal.age)
    if not finite(bid) or bid<=0 or not finite(ask) or ask<=0 or not finite(pickup) or pickup<0 then return nil,"CATTLE_PRICE_UNAVAILABLE" end
    -- All three inputs already use current difficulty/currency. Unknown historic
    -- acquisition is NEVER called own-born or assigned a fabricated purchase cost.
    -- Until every purchase path supplies provenance, the verified current Dealer
    -- BID is a stricter no-resale-bonus cap for every animal in this release.
    local result,why=RLBrokerPricePolicy.quote({buyerReference=bid*1.05,bonus=0,commissionRate=.02,
        ask=ask,minSpreadAbs=0,minSpreadRate=.10,difficultyMultiplier=1,pickupFee=pickup*P.PICKUP_FACTOR,finished=false,
        sourceResult={verified=true,limited=true,maximumBeforeTransport=bid}})
    if result then result.provenancePolicy="CONSERVATIVE_DEALER_BID_CAP" end
    return result,why
end
