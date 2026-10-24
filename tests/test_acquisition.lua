loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLMarketMoney.lua")
loadMod("scripts/market/RLAnimalAcquisition.lua")
local A=RLAnimalAcquisition
local ledger=A.new()
local r={schemaVersion=1,animalKey="1 22 3",originStatus="PURCHASE_RECORDED",purchaseReceiptId="receipt1",purchaseRequestId="buy:epoch:1",
    sellerChannel="DEALER",buyerOwnerFarmId=7,acquiredAtAbsoluteMonths=20,bodyAmount=900,mandatoryFees=100,totalPaid=1000,
    currencyBasis="CURRENT",currencyUnit="FS25_MONEY",difficultyAtPurchase=1,acquiredSnapshotDigest="snapshot1",
    configRevision="config1",formulaVersion="1",priceRevision="prices1",acquiredState={weightKg=100,stage="GROWER"},provenanceChain={}}
check("acquisition: actual expense recorded idempotently",ledger:record("buy:epoch:1",r) and ledger:record("buy:epoch:1",r))
local different=assert(RLMarketData.copy(r));different.totalPaid=1001;different.mandatoryFees=101
check("acquisition: request reuse with changed expense refused",not ledger:record("buy:epoch:1",different))
different.purchaseRequestId="buy:epoch:2"
check("acquisition: new request cannot overwrite existing source expense",not ledger:record("buy:epoch:2",different)
    and ledger:lookup(r.animalKey).totalPaid==1000)
local current={animalKey=r.animalKey,currencyUnit="FS25_MONEY",absoluteMonths=20.01,weightKg=100.001,difficultyMultiplier=3,ownerFarmId=9,name="changed"}
local policy={minimumHoldingMonths=1,minimumGainKg=10,minimumGainRate=0.1,minimumSpreadAbs=10,minimumSpreadRate=0.04}
local cap=assert(A.sourceCap(ledger:lookup(r.animalKey),current,policy))
check("acquisition: price/difficulty/owner/name/microgain cannot wash cost",cap.limited and cap.maximumBeforeTransport==960)
current.absoluteMonths=22
check("acquisition: waiting alone does not release",A.sourceCap(r,current,policy).limited)
current.absoluteMonths=20.01;current.weightKg=120
check("acquisition: gain alone does not release",A.sourceCap(r,current,policy).limited)
current.absoluteMonths=22
check("acquisition: configured compound material change releases",not A.sourceCap(r,current,policy).limited)
local missing=assert(RLMarketData.copy(r));missing.acquiredState={}
check("acquisition: missing original weight retains cap instead of fabricating gain",A.validate(missing)~=nil
    and A.sourceCap(missing,current,policy).limited)
local birth={schemaVersion=1,animalKey="1 23 3",originStatus="OWN_BIRTH_PROVEN",birthEvidenceRef="birth:23",bornAtAbsoluteMonths=20}
check("acquisition: offspring has independent own birth evidence",ledger:record("birth:23",birth) and not A.sourceCap(ledger:lookup(birth.animalKey),{animalKey=birth.animalKey},policy).limited)
check("acquisition: own birth proof cannot exempt a different animal",A.sourceCap(birth,{animalKey=r.animalKey},policy)==nil)
check("acquisition: invalid lookup is a stable rejection",ledger:lookup(nil)==nil and ledger:lookup(0/0)==nil)
check("acquisition: unknown is never inferred own birth",ledger:lookup("old-key").originStatus=="LEGACY_UNKNOWN"
    and A.sourceCap(ledger:lookup("old-key"),current,policy)==nil)
check("acquisition: quarantine blocks new sale",A.sourceCap({schemaVersion=1,animalKey="q",originStatus="QUARANTINED"},current,policy)==nil)
local restored=A.new()
check("acquisition: export/restore preserves actual spend",restored:restore(ledger:export()) and restored:lookup(r.animalKey).totalPaid==1000)
local copy=restored:lookup(r.animalKey);copy.totalPaid=0
check("acquisition: returned receipt immutable to caller",restored:lookup(r.animalKey).totalPaid==1000)
check("acquisition: new birth cannot erase existing purchase",not ledger:record("fake-birth",{schemaVersion=1,animalKey=r.animalKey,originStatus="OWN_BIRTH_PROVEN",birthEvidenceRef="x",bornAtAbsoluteMonths=21}))

local function clone(value) return assert(RLMarketData.copy(value)) end
local function receipt(key,id,request,body,fees)
    local item=clone(r)
    item.animalKey=key;item.purchaseReceiptId=id;item.purchaseRequestId=request
    item.bodyAmount=body;item.mandatoryFees=fees;item.totalPaid=body+fees
    return item
end
local first=receipt("1 31 3","batch-receipt1","buy:batch:2",900,40)
local second=receipt("1 32 3","batch-receipt2","buy:batch:2",1200,60)
local batches=A.new()
check("acquisition: v2 batch records two actual animals with one request",batches:recordBatch("buy:batch:2",{second,first},2200))
check("acquisition: total batch fees are allocated exactly once",batches:lookup(first.animalKey).mandatoryFees==40 and batches:lookup(second.animalKey).mandatoryFees==60
    and batches:lookup(first.animalKey).totalPaid+batches:lookup(second.animalKey).totalPaid==2200)
check("acquisition: normalized reordered batch exact retry succeeds",batches:recordBatch("buy:batch:2",{first,second},2200))
local savedBatch=batches:export()
check("acquisition: store2 saves explicit batch evidence",savedBatch.schemaVersion==2 and savedBatch.requests["buy:batch:2"].kind=="PURCHASE_BATCH"
    and savedBatch.requests["buy:batch:2"].actualTotalPaid==2200 and savedBatch.requests["buy:batch:2"].animalKeys[1]==first.animalKey)
first.bodyAmount=0
check("acquisition: caller mutation cannot rewrite batch",batches:lookup(first.animalKey).bodyAmount==900)
first.bodyAmount=900
local retry=clone(second);retry.bodyAmount=1199;retry.totalPaid=1259
check("acquisition: changed batch price rejected on same request",not batches:recordBatch("buy:batch:2",{first,retry},2199))
check("acquisition: retry cannot substitute single receipt for whole batch",not batches:record("buy:batch:2",first))
check("acquisition: total expenditure mismatch rejected",not A.new():recordBatch("buy:batch:2",{first,second},2300))
check("acquisition: nil total does not invent expenditure",not A.new():recordBatch("buy:batch:2",{first,second},nil))
check("acquisition: duplicate animal in batch rejected",not A.new():recordBatch("buy:batch:2",{first,first},1880))
local sameReceipt=clone(second);sameReceipt.purchaseReceiptId=first.purchaseReceiptId
check("acquisition: duplicate receipt ID in batch rejected",not A.new():recordBatch("buy:batch:2",{first,sameReceipt},2200))
check("acquisition: sparse receipt list rejected",not A.new():recordBatch("buy:batch:2",{[1]=first,[3]=second},2200))
check("acquisition: dictionary receipt list rejected",not A.new():recordBatch("buy:batch:2",{first=first,second=second},2200))
check("acquisition: empty receipt batch rejected",not A.new():recordBatch("buy:batch:2",{},0))
local mismatch=clone(second);mismatch.purchaseRequestId="other-request"
check("acquisition: every receipt binds real batch request",not A.new():recordBatch("buy:batch:2",{first,mismatch},2200))
local wrongOwner=clone(second);wrongOwner.buyerOwnerFarmId=8
check("acquisition: mixed payer batch rejected",not A.new():recordBatch("buy:batch:2",{first,wrongOwner},2200))
local wrongCurrency=clone(second);wrongCurrency.currencyUnit="OTHER"
check("acquisition: mixed currency batch rejected",not A.new():recordBatch("buy:batch:2",{first,wrongCurrency},2200))
local atomic=A.new()
local broken=clone(second);broken.totalPaid=0
check("acquisition: late validation failure rejects entire batch",not atomic:recordBatch("buy:batch:2",{first,broken},940))
check("acquisition: failed batch leaves no first animal or request",atomic:lookup(first.animalKey).originStatus=="LEGACY_UNKNOWN" and next(atomic:export().requests)==nil)
check("acquisition: corrected batch can reuse failed request",atomic:recordBatch("buy:batch:2",{first,second},2200))
local occupied=A.new();assert(occupied:record("birth:occupied",{schemaVersion=1,animalKey=second.animalKey,originStatus="OWN_BIRTH_PROVEN",birthEvidenceRef="b2",bornAtAbsoluteMonths=10}))
check("acquisition: existing second animal rejects whole new batch",not occupied:recordBatch("buy:batch:2",{first,second},2200)
    and occupied:lookup(first.animalKey).originStatus=="LEGACY_UNKNOWN" and occupied:lookup(second.animalKey).originStatus=="OWN_BIRTH_PROVEN")
local reusedId=receipt("1 33 3",first.purchaseReceiptId,"buy:batch:3",100,10)
check("acquisition: receipt IDs are unique across requests",not batches:recordBatch("buy:batch:3",{reusedId},110))
local restoredBatch=A.new()
check("acquisition: whole batch restore validates",restoredBatch:restore(savedBatch))
check("acquisition: batch retry survives restore and input reorder",restoredBatch:recordBatch("buy:batch:2",{second,first},2200))
local function badRestore(name,mutate)
    local saved=clone(savedBatch);mutate(saved)
    local fresh=A.new();local ok=fresh:restore(saved)
    check("acquisition: restore rejects "..name,not ok)
    check("acquisition: rejected restore remains empty "..name,next(fresh:export().animals)==nil and next(fresh:export().requests)==nil)
end
badRestore("old store schema without batch proof",function(s) s.schemaVersion=1 end)
badRestore("missing request evidence",function(s) s.requests={} end)
badRestore("missing referenced animal",function(s) s.animals[second.animalKey]=nil end)
badRestore("dangling animal not referenced",function(s) s.animals["1 99 3"]={schemaVersion=1,animalKey="1 99 3",originStatus="LEGACY_UNKNOWN"} end)
badRestore("reused request pointer",function(s) local e=clone(s.requests["buy:batch:2"]);e.requestId="alias";s.requests.alias=e end)
badRestore("animal referenced twice",function(s) s.requests["buy:batch:2"].animalKeys={first.animalKey,first.animalKey} end)
badRestore("wrong batch total",function(s) s.requests["buy:batch:2"].actualTotalPaid=2300 end)
badRestore("wrong per-animal fingerprint",function(s) s.requests["buy:batch:2"].receiptFingerprints[first.animalKey]="wrong" end)
badRestore("missing per-animal fingerprint",function(s) s.requests["buy:batch:2"].receiptFingerprints[first.animalKey]=nil end)
badRestore("wrong batch fingerprint",function(s) s.requests["buy:batch:2"].fingerprint="wrong" end)
badRestore("wrong request binding",function(s) s.animals[second.animalKey].purchaseRequestId="alias" end)
badRestore("duplicate global receipt identity",function(s) s.animals[second.animalKey].purchaseReceiptId=first.purchaseReceiptId end)
badRestore("unsorted evidence keys",function(s) s.requests["buy:batch:2"].animalKeys={second.animalKey,first.animalKey} end)
badRestore("extra request evidence field",function(s) s.requests["buy:batch:2"].ignored="unsupported" end)
local calls=0
local function evil(method) return setmetatable({}, {[method]=function() calls=calls+1;error("untrusted metatable executed") end}) end
for _,method in ipairs({"__index","__pairs"}) do
    local called,out=pcall(A.sourceCap,r,evil(method),policy)
    check("acquisition: current "..method.." not executed",called and out==nil and calls==0)
    called,out=pcall(A.sourceCap,r,current,evil(method))
    check("acquisition: policy "..method.." not executed",called and out==nil and calls==0)
    called,out=pcall(A.sourceCap,birth,{animalKey=birth.animalKey},evil(method))
    check("acquisition: own birth cannot execute policy "..method,called and out==nil and calls==0)
    local receipts={first,second};receipts.extension=evil(method)
    called,out=pcall(function() return A.new():recordBatch("buy:batch:2",receipts,2200) end)
    check("acquisition: nested batch "..method.." not executed",called and out==false and calls==0)
end
do
    local receipts={}
    for i,amount in ipairs({1000.1,0.1,0.2}) do
        local one=clone(r)
        one.animalKey=({"1 z 3","1 a 3","1 b 3"})[i]
        one.purchaseRequestId="buy:precision"
        one.purchaseReceiptId="precision:"..i
        one.bodyAmount,one.mandatoryFees,one.totalPaid=amount,0,amount
        receipts[i]=one
    end
    local total=0;for _,one in ipairs(receipts) do total=total+one.bodyAmount end
    local precise=A.new()
    check("acquisition: actual payment accumulation order is preserved",precise:recordBatch("buy:precision",receipts,total))
    check("acquisition: canonical retry does not reassociate actual spend",precise:recordBatch("buy:precision",{receipts[2],receipts[3],receipts[1]},total))
    local saved=precise:export()
    check("acquisition: persisted payment order restores exactly",A.new():restore(saved)
        and saved.requests["buy:precision"].actualTotalPaid==1000.4000000000001)
    saved.requests["buy:precision"].settlementOrder={"1 a 3","1 b 3","1 z 3"}
    check("acquisition: altered payment accumulation order fails recovery",not A.new():restore(saved))
end
