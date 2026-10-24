loadMod("tests/fixtures/broker_engine.lua")
for _,name in ipairs({"RLMarketMoney","RLMarketSchema","RLBrokerConditionPackage","RLBrokerEligibility","RLBrokerPricePolicy","RLBrokerOrderService","RLMarketResourceLock","RLBrokerQuota","RLBrokerTransaction"})do loadMod("scripts/market/"..name..".lua")end
local F,T,D=BrokerEngineFixture,RLBrokerTransaction,RLMarketData
local function cp(v)return assert(D.copy(v))end
local actor={userId="alice",farmId=1}
local function setup(options)
    options=options or {}
    local s,a,b=F.source("PEN");local m,f,mt=F.money()
    local key=RLTradeSourceAdapter.identityKey(a)
    local snapshot={schemaVersion=1,identityKey=key,stateRevision="s1",animalType="COW",speciesKey="COW",breed="ANGUS",breedId="COW:ANGUS",subTypeName="BULL_ANGUS",productionClass="BEEF",classRevision="c1",traitMappingRevision="t1",gender="male",ageMonths=12,weightKg=500,health=95,castrated=false,genes={},reproductive={pregnant=false,lactating=false},production={finishScore=50,slaughterReferenceKg=700},eligibility={tradeAllowed=true},supportedBreedingRoles={},traitCapabilities={weight=true,health=true,castrated=true,pregnancy=true,lactation=true,finishScore=true,slaughterReference=true,tradeEligibility=true}}
    local rules=assert(RLBrokerConditionPackage.compile(assert(RLBrokerConditionPackage.candidate("cattleStore",{allowedProductionClasses={"BEEF"}}))))
    local order={orderId="o1",monthId="M1",rules=rules,configRevision="cfg1",formulaVersion=1,priceRevision="p1",priceBasis="CURRENT_MARKET",classRevision="c1",traitMappingRevision="t1"}
    local req={orderId="o1",animalKey=key,sourceRef="pen-alias",transportMode="PICKUP"}
    local q,l=RLBrokerQuota.new(),RLMarketResourceLock.new()
    local heads=options.headCap or 1
    local definition={species={COW={monthlyHeadCap=heads,perBreedHeadCap=heads}},orders={o1={speciesKey="COW",breedScope="ANY",quantityTotal=heads}}}
    assert(q:initialize("M1",definition))
    local x={source=s,animal=a,other=b,mission=m,farm=f,quota=q,locks=l,request=req,time=1000,ready=true,permission=true,docs={},order=order}
    x.service=assert(RLBrokerOrderService.new({serverEpoch="e1",authorize=function()return x.permission end,
        readOrder=function()return order end,capture=function(_,request)
            for _,animal in ipairs(s.system.animals)do if RLTradeSourceAdapter.identityKey(animal)==request.animalKey then local snap=cp(snapshot);snap.identityKey=request.animalKey;return snap,{PICKUP=true}end end
            return nil,"ANIMAL_GONE"
        end,eligibilityContext=function()
            return {permissionGranted=true,ownershipVerified=true,identityVerified=true,unlocked=true,orderOpen=true,sourceSupported=true,
                quota=q:available(order.monthId,"o1","COW","COW:ANGUS"),facts={weaned=true,developmentReady=true,minimumPurchaseKg=300,actualMinimumAgeMonths=8,finished=false},
                factCapabilities={weaned=true,developmentReady=true,minimumPurchaseKg=true,actualMinimumAgeMonths=true,finished=true}}
        end,nowMs=function()return x.time end,previewReady=function()return true end,settlementReady=function()return x.ready end,
        price=function()return RLBrokerPricePolicy.quote({buyerReference=100,bonus=0,commissionRate=0,ask=2000,minSpreadAbs=10,minSpreadRate=.04,difficultyMultiplier=1,pickupFee=0,finished=false,sourceResult={verified=true,limited=false}})end}))
    x.credential=assert(x.service:preview(actor,req)).credential;x.id=assert(T.requestId("e1",1))
    x.store={write=function(doc)
        x.docs[#x.docs+1]=cp(doc)
        if x.onWrite then x.onWrite(doc)end
        local r=doc.records[x.id]
        if options.failStage and r and r.stage==options.failStage then return false end
        x.disk=cp(doc);return true
    end,read=function()
        if options.corruptRead then return {} end
        return cp(x.disk)
    end}
    x.deps={serverEpoch="e1",authorize=function()return x.permission end,orderService=x.service,locks=l,quota=q,source=RLBrokerSourceAdapter,
        prepareSource=function(plan,principal)return RLBrokerSourceAdapter.prepare(s,plan.request.animalKey,{kind="PEN",sourceId=s.uniqueId,farmId=principal.farmId,mission=s.mission,channel="BROKER_PICKUP"})end,
        createMoneyAdapter=function(persist)return RLBrokerMoneyAdapter.new({mission=m,moneyType=mt,persistReceipt=persist})end,
        store=x.store,nowMs=function()return x.time end,ready=function()return x.ready end,saveFence=function()return true end}
    x.tx=assert(T.new(x.deps))
    function x:confirm(id,request,credential)return self.tx:confirm(actor,id or self.id,credential or self.credential,request or self.request)end
    return x
end
local x=setup();local got,why=x:confirm()
check("broker transaction: real source+money commits one selected head",got and got.status=="COMMITTED" and #x.source.system.animals==1 and x.source.system.animals[1]==x.other and x.farm.money==1100 and x.mission.calls==1)
check("broker transaction: all six barriers precise and terminal quota committed",#x.docs==6 and T.validateDocument(x.disk) and x.quota:available("M1","o1","COW","COW:ANGUS").available==0)
check("broker transaction: complete deep pregnancy/growth evidence before first removal",x.docs[1].records[x.id].sourceEvidence.animal.pregnancy.pregnancies[1].genetics.quality==1.25 and x.docs[1].records[x.id].sourceEvidence.animal.rlGrowth.nested.a.b.c.d.e.f.g==19)
check("broker transaction: complete globally ordered six-resource acquisition",#x.docs[1].records[x.id].resources==6 and next(x.locks:snapshot().owners)==nil)
local calls=x.mission.calls
check("broker transaction: gone animal lost-response retry returns original terminal",x:confirm().status=="COMMITTED" and x.mission.calls==calls and #x.docs==6)
local changed=cp(x.request);changed.transportMode="SELF_DELIVERY"
local no,reason=x:confirm(nil,changed)
check("broker transaction: reused request cannot mutate payload",no==nil and reason=="BROKER_REQUEST_MISMATCH" and x.mission.calls==1)
x.permission=false
check("broker transaction: historical lookup still checks authorization",x:confirm()==nil)
x.permission=true;x.ready=false
check("broker transaction: successful lookup survives readiness closure",x:confirm().status=="COMMITTED")
local stale=assert(T.requestId("old",1))
local _,staleReason=x:confirm(stale)
check("broker transaction: unknown old epoch cannot execute",staleReason=="STALE_BROKER_EPOCH")
for _,stage in ipairs({"PREPARED","REMOVE_BARRIER","REMOVED","PAYMENT_BEFORE","PAYMENT_AFTER","COMMITTED"})do
    x=setup({failStage=stage});got=x:confirm()
    local removed=stage~="PREPARED" and stage~="REMOVE_BARRIER"
    local paid=stage=="PAYMENT_AFTER" or stage=="COMMITTED"
    check("broker transaction: "..stage.." failure freezes exact actual asset state",got and got.status=="UNKNOWN" and x.tx:getStatus()=="RECOVERY_REQUIRED" and #x.source.system.animals==(removed and 1 or 2) and x.farm.money==(paid and 1100 or 1000))
    check("broker transaction: "..stage.." keeps locks and last head unavailable",x.locks:owner(x.tx:export().records[x.id].resources[1])==x.id and x.quota:available("M1","o1","COW","COW:ANGUS").available==0 and x:confirm().status=="UNKNOWN")
end
x=setup({corruptRead=true});got=x:confirm()
check("broker transaction: exact readback mismatch prevents removal",got.status=="UNKNOWN" and #x.source.system.animals==2 and x.mission.calls==0)
x=setup();x.mission.mode="BEFORE_THROW";got=x:confirm()
check("broker transaction: proved unpaid restores identical live pregnant object",got and got.status=="ROLLED_BACK" and #x.source.system.animals==2 and x.animal.clusterSystem==x.source.system and x.farm.money==1000 and x.animal.pregnancy.pregnancies[1].genetics.quality==1.25)
check("broker transaction: rollback terminal durable then frees quota/locks",x.quota:available("M1","o1","COW","COW:ANGUS").available==1 and next(x.locks:snapshot().owners)==nil and T.validateDocument(x.disk))
for _,mode in ipairs({"PARTIAL","RETURN_EMPTY"})do
    x=setup();x.mission.mode=mode;got=x:confirm()
    check("broker transaction: uncertain "..mode.." never restores/refunds/retries",got.status=="UNKNOWN" and #x.source.system.animals==1 and x.mission.calls==1 and x:confirm().status=="UNKNOWN" and x.mission.calls==1)
end
x=setup();x.source.system.onFlush=function()x.other.health=99 end;got=x:confirm()
check("broker transaction: foreign-member mutation retains unknown without payment",got.status=="UNKNOWN" and x.mission.calls==0 and x.locks:owner(x.tx:export().records[x.id].resources[1])==x.id)
x=setup();local nested,other,attempts=0,0,0
x.onWrite=function()attempts=attempts+1;local a,r=x:confirm();if r=="BROKER_SYNCHRONOUS_FENCE" then nested=nested+1 end;local b,s=x:confirm(T.requestId("e1",2));if s=="BROKER_SYNCHRONOUS_FENCE" then other=other+1 end end
got=x:confirm()
check("broker transaction: every storage callback fenced for same/other IDs",got.status=="COMMITTED" and attempts==6 and nested==6 and other==6 and x.mission.calls==1)
x=setup();local reentry
x.mission.onMoney=function()local _,r=x:confirm();reentry=r end
got=x:confirm()
check("broker transaction: actual payout callback cannot reenter",got.status=="COMMITTED" and reentry=="BROKER_SYNCHRONOUS_FENCE" and x.mission.calls==1)
local saved=cp(x.disk)
local y=setup();y.deps.quota=RLBrokerQuota.new();y.deps.locks=RLMarketResourceLock.new();y.deps.serverEpoch="e2";y.tx=assert(T.new(y.deps))
local validProof={verified=true,checkpointRef="whole-save-7",documentFingerprint=assert(D.fingerprint(saved))}
check("broker transaction: persisted terminals require whole-checkpoint binding",not y.tx:restore(saved,{verified=true,checkpointRef="arbitrary"}) and y.tx:restore(saved,validProof))
local historic=y.tx:confirm(actor,x.id,x.credential,x.request)
check("broker transaction: old epoch saved terminal is settled query only",historic.status=="COMMITTED" and historic.historicalSettled=="whole-save-7" and y.farm.money==1000 and y.mission.calls==0 and #y.source.system.animals==2)
local malformed=cp(saved);malformed.records[x.id].plan.money.netToPlayer=101
check("broker transaction: restore rejects action/plan drift",not T.validateDocument(malformed))
malformed=cp(saved);malformed.records[x.id].resources[7]="unexpected"
check("broker transaction: restore rejects resource-list drift",not T.validateDocument(malformed))
malformed=cp(saved);malformed.quota.pools.M1.committed.order.o1=0
check("broker transaction: restore rejects quota counter drift",not T.validateDocument(malformed))
x=setup({failStage="REMOVED"});x:confirm();saved=cp(x.disk)
y=setup();y.deps.quota=RLBrokerQuota.new();y.deps.locks=RLMarketResourceLock.new();y.deps.serverEpoch="e2";y.tx=assert(T.new(y.deps))
check("broker transaction: nonterminal old-month checkpoint restores unknown",y.tx:restore(saved,{verified=true,checkpointRef="old-month-save",documentFingerprint=assert(D.fingerprint(saved))}) and y.tx:getStatus()=="RECOVERY_REQUIRED" and y.deps.quota:available("M1","o1","COW","COW:ANGUS").available==0)
check("broker transaction: restored holds are UNKNOWN and no asset replay",y.deps.locks:snapshot().owners[x.id].state=="UNKNOWN" and y.mission.calls==0 and #y.source.system.animals==2)
local rec,recReason=y.tx:reconcile(x.id,{requestId=x.id,monthId="M1",proofRef="guess",outcome="ROLLED_BACK",animalRestored=true,moneyNotApplied=true})
check("broker transaction: booleans alone cannot reconcile recovery",rec==nil and recReason=="RECONCILIATION_VERIFIER_REQUIRED")
for _,callback in ipairs({"ready","saveFence"})do
    x=setup();local calls=0
    x.deps[callback]=function()calls=calls+1;if calls==2 then x.time=16000 end;return true end
    local no,why=x:confirm()
    check("broker transaction: final "..callback.." callback TTL boundary rejects untouched",no==nil and why=="BROKER_QUOTE_EXPIRED" and #x.source.system.animals==2 and x.mission.calls==0 and #x.docs==0 and next(x.locks:snapshot().owners)==nil and x.quota:available("M1","o1","COW","COW:ANGUS").available==1)
end
-- An old-month UNKNOWN can only be explicitly reconciled; neither side effects
-- nor the current month's counters are inferred or replayed.
x=setup({failStage="PAYMENT_AFTER"});x:confirm();saved=cp(x.disk)
y=setup();y.deps.quota=RLBrokerQuota.new();y.deps.locks=RLMarketResourceLock.new();y.deps.serverEpoch="e2"
local verifierNested
local verify=true
y.deps.verifyReconciliation=function(record,proof)
    local _,reason=y.tx:reconcile(record.requestId,proof);verifierNested=reason
    record.plan.monthId="MUTATE_COPY";proof.monthId="MUTATE_COPY";return verify
end
y.tx=assert(T.new(y.deps));assert(y.tx:restore(saved,{verified=true,checkpointRef="save",documentFingerprint=D.fingerprint(saved)}))
assert(y.deps.quota:initialize("M2",{species={COW={monthlyHeadCap=2,perBreedHeadCap=2}},orders={o2={speciesKey="COW",breedScope="ANY",quantityTotal=2}}}))
local payment=cp(x.tx:export().records[x.id].paymentReceipts[x.id..":payment"])
local proof={requestId=x.id,monthId="M1",proofRef="independent-original-asset-checkpoint",outcome="COMMITTED",animalRemoved=true,moneyApplied=true,paymentReceipt=payment,removal={status="APPLIED",removedKey=x.request.animalKey,keepLocked=true}}
-- The failed AFTER barrier left a PRE-BEFORE disk record; independent recovery
-- evidence is the live adapter's complete AFTER receipt retained by the owner.
local result=y.tx:reconcile(x.id,proof)
check("broker transaction: verifier reentry fenced and only original month commits",result and result.status=="COMMITTED" and verifierNested=="BROKER_SYNCHRONOUS_FENCE" and y.deps.quota:export().requests[x.id].state=="COMMITTED" and y.deps.quota:available("M2","o2","COW","COW:ANGUS").available==2 and y.mission.calls==0)
check("broker transaction: explicit recovery frees original locks and closes recovery",next(y.deps.locks:snapshot().owners)==nil and y.tx:getStatus()=="READY")
x=setup({failStage="PREPARED"});x:confirm();saved=cp(x.tx:export())
y=setup();y.deps.quota=RLBrokerQuota.new();y.deps.locks=RLMarketResourceLock.new();y.deps.serverEpoch="e2";y.deps.verifyReconciliation=function()return true end;y.tx=assert(T.new(y.deps))
assert(y.tx:restore(saved,{verified=true,checkpointRef="saved-before-side-effect",documentFingerprint=D.fingerprint(saved)}))
result=y.tx:reconcile(x.id,{requestId=x.id,monthId="M1",proofRef="verified-intact-unpaid",outcome="ROLLED_BACK",animalRestored=true,moneyNotApplied=true})
check("broker transaction: explicit intact-unpaid proof releases old reservation",result and result.status=="ROLLED_BACK" and y.deps.quota:available("M1","o1","COW","COW:ANGUS").available==1 and y.mission.calls==0)

x=setup()
local actor2={userId="bob",farmId=1};local request2=cp(x.request);request2.animalKey=RLTradeSourceAdapter.identityKey(x.other)
local credential2=assert(x.service:preview(actor2,request2)).credential
local first=x:confirm();local second,secondReason=x.tx:confirm(actor2,T.requestId("e1",2),credential2,request2)
check("broker transaction: two eligible animals competing for last head commit at most one",first.status=="COMMITTED" and second==nil and secondReason=="BROKER_NO_LONGER_ELIGIBLE" and x.mission.calls==1 and #x.source.system.animals==1 and x.source.system.animals[1]==x.other)
x=setup();local switched=false
x.onWrite=function(doc)
    if not switched and doc.records[x.id].stage=="PREPARED" then
        switched=true;x.order.monthId="M2"
        assert(x.quota:initialize("M2",{species={COW={monthlyHeadCap=2,perBreedHeadCap=2}},orders={o1={speciesKey="COW",breedScope="ANY",quantityTotal=2}}}))
    end
end
result=x:confirm()
check("broker transaction: durable prepared crosses month using original quota only",result.status=="COMMITTED" and x.quota:export().requests[x.id].monthId=="M1" and x.quota:available("M2","o1","COW","COW:ANGUS").available==2 and x.mission.calls==1)
malformed=cp(x.disk);malformed.records[x.id].sourceEvidence.queues.add=5
local ok,rejected=pcall(T.validateDocument,malformed)
check("broker transaction: corrupt nested source schema rejects without throwing",ok and rejected==false)
malformed=cp(x.disk);malformed.records[x.id].unknownField=true
check("broker transaction: unknown record fields cannot silently survive restore",not T.validateDocument(malformed))

x=setup();local sourcePersist,moneyPersist
local actualSource=RLBrokerSourceAdapter
x.deps.source={portableEvidence=actualSource.portableEvidence,observe=actualSource.observe,restore=actualSource.restore,verifyRestored=actualSource.verifyRestored,
    remove=function(handle,persist)sourcePersist=persist;return actualSource.remove(handle,persist)end}
local actualFactory=x.deps.createMoneyAdapter
x.deps.createMoneyAdapter=function(persist)moneyPersist=persist;return actualFactory(persist)end
assert(x:confirm().status=="COMMITTED")
local before=D.fingerprint(x.tx:export());local diskBefore=D.fingerprint(x.disk);local count=#x.docs
local record=x.tx:export().records[x.id]
check("broker transaction: retained source callback cannot rewrite terminal evidence",sourcePersist(record.sourceEvidence)==false and D.fingerprint(x.tx:export())==before and D.fingerprint(x.disk)==diskBefore and #x.docs==count)
check("broker transaction: retained money callback cannot rewrite terminal evidence",moneyPersist(record.paymentReceipts[x.id..":payment"])==false and D.fingerprint(x.tx:export())==before and D.fingerprint(x.disk)==diskBefore and #x.docs==count)
local floatingActor=cp(actor);floatingActor.farmId=1.0
check("broker transaction: same integer-valued farm has canonical wallet resource",D.fingerprint(T.resources(record.plan,record.sourceEvidence,floatingActor))==D.fingerprint(record.resources))

malformed=cp(x.disk);local receipt=malformed.records[x.id].paymentReceipts[x.id..":payment"]
receipt.action.kind="SALE";receipt.actionFingerprint=D.fingerprint(receipt.action)
check("broker transaction: another transaction kind cannot masquerade as Broker receipt",not T.validateDocument(malformed))

-- Real husbandry IDs are strings and visual objects point back to the animal.
x=setup();getAnimalRootNode=function()return 99 end
loadMod("scripts/animals/husbandry/cluster/VisualAnimal.lua")
x.animal.id="1-7";x.other.id="1-8"
x.animal.visualAnimal=VisualAnimal.new(x.animal,1,7)
x.other.visualAnimal=VisualAnimal.new(x.other,1,8)
check("broker transaction: actual visual objects and string engine IDs commit",x:confirm().status=="COMMITTED" and x.mission.calls==1)
-- Previous source evidence remains valid on restore; schema-1 animal payloads
-- are not rewritten merely because new transactions use compact schema 2.
local legacy=cp(x.disk);local record=legacy.records[x.id];local source=record.sourceEvidence
source.version=1
for _,member in ipairs(source.members)do
    local animal=member.identityKey==source.identityKey and x.animal or x.other
    member.state=assert(RLAnimalState.capture(animal,{ignored={rlGrowthCurve=true,rlInfoRows=true}}))
    member.stateFingerprint=nil
end
source.fingerprint=nil;source.fingerprint=D.fingerprint(source)
check("broker transaction: legacy full source evidence still validates",T.validateDocument(legacy))

x=setup({headCap=60})
for i=3,60 do
    local _,a=F.source("PEN");a.uniqueId=tostring(20000+i);a.id="1-"..i;a.clusterSystem=x.source.system
    x.source.system.animals[i]=a
end
-- Exercise actual coordinator history growth, not a mirrored size formula.
x.store.write=function(doc)x.disk=cp(doc);return true end
local successful=0
for i=1,30 do
    local req=cp(x.request);req.animalKey=RLTradeSourceAdapter.identityKey(x.source.system.animals[1])
    local credential=assert(x.service:preview(actor,req)).credential
    local result=x.tx:confirm(actor,T.requestId("e1",i),credential,req)
    if not result or result.status~="COMMITTED" then break end
    successful=successful+1
end
check("broker transaction: sixty-head source survives thirty sequential deliveries",successful==30 and x.mission.calls==30 and #x.source.system.animals==30 and T.validateDocument(x.disk))
