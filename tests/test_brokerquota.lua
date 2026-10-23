loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLMarketMoney.lua")
loadMod("scripts/market/RLMarketResourceLock.lua")
loadMod("scripts/market/RLBrokerQuota.lua")
local Q=RLBrokerQuota
local ledger,locks=Q.new(),RLMarketResourceLock.new()
local definition={species={COW={monthlyHeadCap=2,perBreedHeadCap=1}},orders={grow={speciesKey="COW",breedScope="ANY",quantityTotal=2}}}
check("quota: initialize once",ledger:initialize("M1",definition) and ledger:initialize("M1",definition))
local changed=assert(RLMarketData.copy(definition));changed.species.COW.monthlyHeadCap=3
check("quota: same month cannot reset capacity",not ledger:initialize("M1",changed))
local remaining=ledger:available("M1","grow","COW")
check("quota: ANY has no invented breed balance",remaining.breed==nil and remaining.available==nil and remaining.breedNote~=nil)
local function reserve(id,breed,month)
    month=month or "M1"
    local resources=assert(Q.resources(month,"grow","COW",breed))
    assert(locks:acquire(id,resources))
    local result,reason=ledger:reserve(id,month,"grow","COW",breed,locks)
    locks:release(id)
    return result,reason
end
check("quota: no lock proof no reservation",ledger:reserve("unlocked","M1","grow","COW","COW:ANGUS",nil)==nil)
check("quota: first animal reserves all three",reserve("tx1","COW:ANGUS")~=nil)
check("quota: same breed last place cannot double reserve",reserve("tx2","COW:ANGUS")==nil)
check("quota: commit idempotent",ledger:commit("tx1") and ledger:commit("tx1"))
check("quota: different breed uses remaining public capacity",reserve("tx3","COW:HEREFORD")~=nil)
check("quota: exact reserved retry not double counted",reserve("tx3","COW:HEREFORD")~=nil and ledger:available("M1","grow","COW","COW:HEREFORD").available==0)
ledger:markUnknown("tx3")
check("quota: unknown keeps reservation",not ledger:release("tx3"))
check("quota: unknown old month never consumes new pool",ledger:initialize("M2",definition) and ledger:available("M2","grow","COW","COW:ANGUS").available==1)
local restored=Q.new()
check("quota: restore verifies total counters",restored:restore(ledger:export()))
check("quota: restore keeps old pending head and historical committed",not restored:release("tx3") and restored:commit("tx1"))
local corrupt=ledger:export();corrupt.pools.M1.committed.order.grow=0
check("quota: drift is refused atomically",not Q.new():restore(corrupt))
check("quota: reconciliation returns only old month head",restored:release("tx3",true)
    and restored:available("M1","grow","COW","COW:HEREFORD").available==1 and restored:available("M2","grow","COW","COW:HEREFORD").available==1)
check("quota: released history restores without transient capacity replay",Q.new():restore(restored:export()))
local reconciled=Q.new();assert(reconciled:restore(ledger:export()))
check("quota: unknown cannot commit without full evidence",not reconciled:commit("tx3")
    and not reconciled:reconcileCommit("tx3",{requestId="tx3",outcome="COMMITTED"}))
local proof={requestId="tx3",monthId="M1",outcome="COMMITTED",animalRemoved=true,moneyApplied=true,proofRef="verified-tx-checkpoint"}
check("quota: proven old-month success commits reserved head once",reconciled:reconcileCommit("tx3",proof)
    and reconciled:reconcileCommit("tx3",proof) and reconciled:available("M1","grow","COW","COW:HEREFORD").available==0
    and reconciled:available("M2","grow","COW","COW:HEREFORD").available==1)
