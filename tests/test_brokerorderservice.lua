for _,file in ipairs({"RLMarketData","RLMarketMoney","RLMarketSchema","RLBrokerConditionPackage","RLBrokerEligibility","RLBrokerPricePolicy","RLBrokerOrderService"}) do loadMod("scripts/market/"..file..".lua") end
local rules=assert(RLBrokerConditionPackage.compile(assert(RLBrokerConditionPackage.candidate("cattleStore",{allowedProductionClasses={"BEEF"}}))))
local snapshot={schemaVersion=1,identityKey="1 22 3",stateRevision="s1",animalType="COW",speciesKey="COW",breed="ANGUS",breedId="COW:ANGUS",subTypeName="BULL_ANGUS",productionClass="BEEF",classRevision="c1",traitMappingRevision="t1",gender="male",ageMonths=12,weightKg=500,health=95,castrated=false,genes={},reproductive={pregnant=false,lactating=false},production={finishScore=50,slaughterReferenceKg=700},eligibility={tradeAllowed=true},supportedBreedingRoles={},traitCapabilities={weight=true,health=true,castrated=true,pregnancy=true,lactation=true,finishScore=true,slaughterReference=true,tradeEligibility=true}}
local context={permissionGranted=true,ownershipVerified=true,identityVerified=true,unlocked=true,orderOpen=true,sourceSupported=true,quota={order=4,species=8,breed=4},facts={weaned=true,developmentReady=true,minimumPurchaseKg=300,actualMinimumAgeMonths=8,finished=false},factCapabilities={weaned=true,developmentReady=true,minimumPurchaseKg=true,actualMinimumAgeMonths=true,finished=true}}
local order={orderId="o1",monthId="M1",rules=rules,configRevision="cfg1",formulaVersion=1,priceRevision="p1",priceBasis="CURRENT_MARKET",classRevision="c1",traitMappingRevision="t1"}
local time,amount,permitted,ready,source,fee=1000,1000,true,true,true,100
local delayTo
local mutateGate=false
local service=assert(RLBrokerOrderService.new({serverEpoch="epoch1",authorize=function() return permitted end,
    readOrder=function() return order end,capture=function() return snapshot,{PICKUP=true,SELF_DELIVERY=true} end,
    eligibilityContext=function() return context end,nowMs=function() return time end,
    previewReady=function() return true end,settlementReady=function(_,providedOrder) if mutateGate then providedOrder.monthId="MUTATED" end;return ready end,
    price=function() if delayTo then time=delayTo end;return RLBrokerPricePolicy.quote({buyerReference=amount,bonus=0,commissionRate=0,ask=2000,minSpreadAbs=10,minSpreadRate=.04,
        difficultyMultiplier=1,pickupFee=fee,finished=false,sourceResult=source and {verified=true,limited=false} or nil}) end}))
local actor={userId="alice",farmId=1}
local request={orderId="o1",animalKey=snapshot.identityKey,sourceRef="pen:1",transportMode="PICKUP"}
local preflight=assert(service:preflight(actor,request))
check("broker preflight: all qualification diagnostics without locks or money",preflight.eligibility.eligible and preflight.price.pickup.netToPlayer==900)
local credential=assert(service:preview(actor,request))
check("broker quote: TTL15s and selected authoritative money",credential.expiresAt==16000 and credential.money.netToPlayer==900)
snapshot.stateRevision="s2";snapshot.weightKg=501
check("broker recheck: same-money eligible microchange accepted",service:validateConfirmation(actor,credential.credential,request)~=nil)
context.quota.order=2
check("broker recheck: another animal consuming spare quota does not invalidate",service:validateConfirmation(actor,credential.credential,request)~=nil)
mutateGate=true
local detachedPlan=assert(service:validateConfirmation(actor,credential.credential,request))
check("broker recheck: readiness cannot mutate already bound plan",detachedPlan.monthId=="M1" and order.monthId=="M1")
mutateGate=false
order.monthId="M2"
local cross,crossReason=service:validateConfirmation(actor,credential.credential,request)
check("broker recheck: changed published month invalidates even reused order id",cross==nil and crossReason=="BROKER_REQUOTE_REQUIRED")
order.monthId="M1"
amount=1001
local plan,reason=service:validateConfirmation(actor,credential.credential,request)
check("broker recheck: changed settlement requires new confirmation",plan==nil and reason=="BROKER_REQUOTE_REQUIRED")
fee=101
plan,reason=service:validateConfirmation(actor,credential.credential,request)
check("broker recheck: equal net with different fee/body still requires confirmation",plan==nil and reason=="BROKER_REQUOTE_REQUIRED")
fee=100
amount=1000;snapshot.weightKg=600
plan,reason=service:validateConfirmation(actor,credential.credential,request)
check("broker recheck: crossing qualification boundary rejected",plan==nil and reason=="BROKER_NO_LONGER_ELIGIBLE")
snapshot.weightKg=500
check("broker recheck: other principal cannot use quote",service:validateConfirmation({userId="bob",farmId=1},credential.credential,request)==nil)
local other=assert(RLMarketData.copy(request));other.transportMode="SELF_DELIVERY"
check("broker recheck: transport switch cannot reuse credential",service:validateConfirmation(actor,credential.credential,other)==nil)
permitted=false
check("broker recheck: permission change denied",service:validateConfirmation(actor,credential.credential,request)==nil)
permitted=true;ready=false
plan,reason=service:validateConfirmation(actor,credential.credential,request)
check("broker recheck: settlement readiness distinct from preview",plan==nil and reason=="BROKER_SETTLEMENT_NOT_READY")
ready=true;time=16000
plan,reason=service:validateConfirmation(actor,credential.credential,request)
check("broker quote: exact expiration rejected",plan==nil and reason=="BROKER_QUOTE_EXPIRED")
time=17000;source=false
preflight=assert(service:preflight(actor,request))
check("broker preflight: unknown source remains read-only estimate",preflight.price~=nil and not preflight.price.settlementReady and service:preview(actor,request)==nil)
source=true;context.facts.weaned=nil
preflight=assert(service:preflight(actor,request))
check("broker preflight: missing capability has reasons rather than fake low value",preflight.eligibility.status=="UNKNOWN" and preflight.price==nil)
local rejected,rejection,details=service:preview(actor,request)
check("broker quote: rejected preview retains full diagnostics",rejected==nil and rejection=="BROKER_INELIGIBLE" and details and details.eligibility.status=="UNKNOWN" and #details.eligibility.unknowns>0)
check("broker quote: missing principal rejected even if adapter permissive",service:preview(nil,request)==nil)
context.facts.weaned=true
local first=assert(service:preview(actor,request))
local second=assert(service:preview(actor,request))
check("broker quote: new selection replaces caller's pending credential",service:validateConfirmation(actor,first.credential,request)==nil
    and service:validateConfirmation(actor,second.credential,request)~=nil)
delayTo=second.expiresAt+1
plan,reason=service:validateConfirmation(actor,second.credential,request)
check("broker quote: expiration during callbacks is checked at final boundary",plan==nil and reason=="BROKER_QUOTE_EXPIRED")
