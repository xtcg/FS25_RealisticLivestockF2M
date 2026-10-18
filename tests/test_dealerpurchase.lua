loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/dealer/RLDealerPurchase.lua")
local P = RLDealerPurchase
local function clone(t)
    if type(t) ~= "table" then return t end
    local out = {}; for k,v in pairs(t) do out[k] = clone(v) end; return out
end
local function request(id)
    return { requestId = id or "r1", destination = "pen1", quoteCredential = "signed-q1",
        items = { {saleId = "b", revision = 1}, {saleId = "a", revision = 1} } }
end
-- Test ownership/checkpoint adapter, NOT the engine's persistence or ownership implementation.
local function fixture()
    local world = { money = 1000, stock = { a = true, b = true }, target = {}, receipts = {}, writes = 0, applies = 0, ms = 10 }
    local a = { durableDealerOwnershipVersion = 1 }
    a.isServer = function() return true end
    a.authorize = function() return true end
    a.monotonicMs = function() return world.ms end
    a.currentClock = function() return 3.25 end
    a.readListing = function(id) return { saleId = id, recordRevision = 1, state = world.stock[id] and "LISTED" or "SOLD" } end
    a.validateListing = function(_, c) return c.currentClock == 3.25 end
    a.validateQuote = function(_, c) return c.request.quoteCredential == "signed-q1", "STALE_QUOTE" end
    a.validateDestination = function() return true end
    a.validateFunds = function() return world.money >= 200, "INSUFFICIENT_FUNDS" end
    a.prepare = function(list, context)
        return { amount = 200, transferIds = { context.token .. ":" .. list[1].saleId, context.token .. ":" .. list[2].saleId },
            compensation = { moneyBefore = world.money, stockBefore = clone(world.stock), targetBefore = clone(world.target) } }
    end
    a.checkpoint = function(snapshot)
        world.writes = world.writes + 1
        if world.failCheckpoint == world.writes then
            if world.persistOnFailure then world.disk = clone(snapshot) end
            return false
        end
        world.disk = clone(snapshot); return true
    end
    local function receipt(token,plan,status)
        return {status=status,token=token,amount=plan.amount,transferIds=clone(plan.transferIds),
            sourceComplete=true,targetComplete=true,moneyComplete=true}
    end
    a.apply = function(token, plan, c)
        world.applies = world.applies + 1
        if world.receipts[token] then return world.receipts[token] end
        -- A production adapter must also revalidate all inputs atomically here.
        for i,item in ipairs(c.request.items) do
            world.target[plan.transferIds[i]] = item.saleId
            if world.fault == "target" then error("target interruption") end
        end
        for _,item in ipairs(c.request.items) do
            world.stock[item.saleId] = nil
            if world.fault == "source" then error("source interruption") end
        end
        world.money = world.money - plan.amount
        if world.fault == "money" then error("money interruption") end
        world.receipts[token] = receipt(token,plan,"COMMITTED")
        if world.fault == "receipt" then error("post receipt interruption") end
        return world.receipts[token]
    end
    a.reconcile = function(token, plan)
        if world.unknown then return "UNKNOWN" end
        if world.receipts[token] then return world.receipts[token] end
        world.money = plan.compensation.moneyBefore
        world.stock = clone(plan.compensation.stockBefore)
        world.target = clone(plan.compensation.targetBefore)
        world.receipts[token] = receipt(token,plan,"ROLLED_BACK")
        return world.receipts[token]
    end
    return P.new(), a, world
end
local store, a, w = fixture()
local result = P.execute(store, request(), "user1", a)
check("dealer purchase: sorted batch commits once with full target/source/money handoff", result and result.status == "COMMITTED"
    and result.transferIds[1] == "dealer:r1:a" and w.money == 800 and not next(w.stock) and w.applies == 1 and not next(store.locks))
local replay = P.execute(store, request(), "user1", a)
check("dealer purchase: equivalent request replay has no money or transfer effects", replay and replay.status == "COMMITTED" and w.applies == 1 and w.writes == 3)
replay.amount = 1
check("dealer purchase: returned results cannot mutate authoritative journal", store.records.r1.result.amount == 200)
local reordered = request(); reordered.items[1],reordered.items[2] = reordered.items[2],reordered.items[1]
check("dealer purchase: item order is canonical for idempotent replay", P.execute(store,reordered,"user1",a).status == "COMMITTED")
local changed = request(); changed.destination = "pen2"
local _, why = P.execute(store,changed,"user1",a)
check("dealer purchase: changed destination on request ID conflicts", why == "REQUEST_CONFLICT")
_,why = P.execute(store,request(),"user2",a)
check("dealer purchase: principal is bound into canonical request", why == "REQUEST_CONFLICT")
local loaded = assert(P.import(P.export(store)))
check("dealer purchase: completed save replay is idempotent", P.execute(loaded,request(),"user1",a).status == "COMMITTED" and w.applies == 1)
for _, case in ipairs({
    {"server only", function(s,x) x.isServer = function() return false end end, "SERVER_ONLY"},
    {"permission", function(s,x) x.authorize = function() return false end end, "NO_PERMISSION"},
    {"durability adapter gate", function(s,x) x.durableDealerOwnershipVersion = nil end, "ADAPTER_NOT_DURABLE"},
    {"current clock", function(s,x) x.currentClock = function() return 0/0 end end, "BAD_CURRENT_CLOCK"},
    {"revision", function(s,x) x.readListing = function(id) return {saleId=id, recordRevision=2,state="LISTED"} end end,"STALE_REVISION"},
    {"model/eligibility", function(s,x) x.validateListing = function() return false,"MODEL_GAP" end end,"MODEL_GAP"},
    {"destination/capacity", function(s,x) x.validateDestination = function() return false,"CAPACITY" end end,"CAPACITY"},
    {"funds", function(s,x,z) z.money = 199 end,"INSUFFICIENT_FUNDS"},
    {"quote", function(s,x) x.validateQuote = function() return false,"STALE_QUOTE" end end,"STALE_QUOTE"},
    {"missing compensation", function(s,x) x.prepare = function() return {amount=200,transferIds={"a","b"}} end end,"BAD_PREPARED_TRANSFER"},
    {"repeated transfer identity", function(s,x) x.prepare=function() return {amount=200,compensation={},transferIds={"a","a"}} end end,"BAD_TRANSFER_ID"},
    {"validator exception", function(s,x) x.validateFunds=function() error("fault") end end,"ADAPTER_ERROR:validateFunds"},
    {"monotonic lock deadline", function(s,x,z) x.prepare = function() z.ms=5010; return {amount=200,compensation={},transferIds={"a","b"}} end end,"LOCK_TIMEOUT"},
    {"clock regression", function(s,x,z) s.lastMs=20 end,"BAD_MONOTONIC_CLOCK"}
}) do
    local s,x,z=fixture(); case[2](s,x,z)
    local _,reason=P.execute(s,request(),"user1",x)
    check("dealer purchase: "..case[1].." fails before effects",reason==case[3] and z.applies==0 and not next(s.locks) and z.writes==0)
end
store,a,w=fixture(); local dup=request(); dup.items[2].saleId="b"
_,why=P.execute(store,dup,"user1",a)
check("dealer purchase: duplicate IDs fail before locks/checkpoints",why=="DUPLICATE_SALE_ID" and w.writes==0)
local sparse=request(); sparse.items[4]={saleId="c",revision=1}
_,why=P.execute(store,sparse,"user1",a)
check("dealer purchase: sparse batch is rejected",why=="BAD_REQUEST")
for _, fault in ipairs({"target","source","money"}) do
    store,a,w=fixture(); w.fault=fault
    result=P.execute(store,request(),"user1",a)
    check("dealer purchase: "..fault.." fault compensates entire batch",result and result.status=="ROLLED_BACK"
        and w.money==1000 and w.stock.a and w.stock.b and not next(w.target) and not next(store.locks))
    check("dealer purchase: "..fault.." rollback replay remains final", P.execute(store,request(),"user1",a).status=="ROLLED_BACK" and w.applies==1)
end
store,a,w=fixture(); w.fault="receipt"
result=P.execute(store,request(),"user1",a)
check("dealer purchase: exception after durable receipt reconciles committed outcome",result.status=="COMMITTED" and w.money==800)
for stage=1,3 do
    store,a,w=fixture(); w.failCheckpoint=stage; w.persistOnFailure=true
    _,why=P.execute(store,request(),"user1",a)
    check("dealer purchase: checkpoint "..stage.." uncertainty closes gate",why=="CHECKPOINT_UNCERTAIN" and store.recoveryRequired and (stage==3 or w.applies==0))
    loaded=assert(P.import(w.disk)); w.failCheckpoint=nil
    check("dealer purchase: checkpoint "..stage.." interrupted snapshot recovers",P.recover(loaded,a) and not loaded.recoveryRequired)
    local final=P.execute(loaded,request(),"user1",a)
    check("dealer purchase: checkpoint "..stage.." recovery does not duplicate effects",final and (stage==3 and final.status=="COMMITTED" and w.money==800 or stage<3 and final.status=="ROLLED_BACK" and w.money==1000))
end
store,a,w=fixture(); w.fault="money"; w.unknown=true
_,why=P.execute(store,request(),"user1",a)
check("dealer purchase: ambiguous money ownership retains lock and recovery gate",why=="RECOVERY_REQUIRED" and store.recoveryRequired and store.locks.a and w.money==800)
loaded=assert(P.import(w.disk)); w.unknown=false
check("dealer purchase: restart ownership reconciliation compensates partial money/target/source",P.recover(loaded,a) and w.money==1000 and w.stock.a and w.stock.b and not next(w.target))
store,a,w=fixture(); store.locks.a={owner="other",deadline=100}
_,why=P.execute(store,request(),"user1",a)
check("dealer purchase: competing sorted batch cannot take held lock",why=="SALE_LOCKED" and not store.locks.b and w.writes==0)
store,a,w=fixture(); store.locks.a={owner="orphan",deadline=0}
check("dealer purchase: expired orphan lock can be reclaimed",P.execute(store,request(),"user1",a).status=="COMMITTED")
store,a,w=fixture(); local base=a.checkpoint
a.checkpoint=function(snapshot) local ok=base(snapshot); w.ms=5010; return ok end
result=P.execute(store,request(),"user1",a)
check("dealer purchase: slow durable checkpoint times out before first effect",result.status=="ROLLED_BACK" and w.applies==0 and w.money==1000)
store,a,w=fixture(); result=P.execute(store,request(),"user1",a)
local broken=P.export(store); broken.records.r1.result.amount=201
_,why=P.import(broken)
check("dealer purchase: corrupt finished amount is rejected on import",why=="BAD_JOURNAL_RESULT")
broken=P.export(store); broken.records.r1.context.token="other"
_,why=P.import(broken)
check("dealer purchase: corrupted stable ownership token is rejected",why=="BAD_JOURNAL_RECORD")
broken=P.export(store); broken.records.r1.fingerprint="changed"
_,why=P.import(broken)
check("dealer purchase: mismatched canonical request is rejected",why=="BAD_JOURNAL_RECORD")
broken=P.export(store); broken.records.r1.stage="MONEY_SENT"
_,why=P.import(broken)
check("dealer purchase: unknown journal stage fails closed",why=="BAD_JOURNAL_STAGE")
-- A second client arrives during the first adapter's apply: the journal owns the locks.
store,a,w=fixture(); local apply=a.apply; local raced
 a.apply=function(token,plan,c)
    local _,reason=P.execute(store,request("r2"),"user2",a); raced=reason
    return apply(token,plan,c)
end
result=P.execute(store,request(),"user1",a)
check("dealer purchase: two-client reentrant race commits exactly one batch",result.status=="COMMITTED" and raced=="SALE_LOCKED" and w.applies==1 and w.money==800)
for stage=2,3 do
    store,a,w=fixture(); w.failCheckpoint=stage; w.persistOnFailure=false
    _,why=P.execute(store,request(),"user1",a)
    loaded=assert(P.import(w.disk)); w.failCheckpoint=nil
    check("dealer purchase: retained prior checkpoint "..stage.." reconciles actual ownership",P.recover(loaded,a)
        and (stage==3 and w.money==800 and P.execute(loaded,request(),"user1",a).status=="COMMITTED"
            or stage==2 and w.money==1000 and P.execute(loaded,request(),"user1",a).status=="ROLLED_BACK"))
end
store,a,w=fixture(); w.failCheckpoint=1; w.persistOnFailure=false
_,why=P.execute(store,request(),"user1",a)
check("dealer purchase: missing initial checkpoint never permits any transfer",why=="CHECKPOINT_UNCERTAIN" and w.disk==nil and w.applies==0 and store.recoveryRequired)
store,a,w=fixture(); w.fault="money"; w.unknown=true
P.execute(store,request(),"user1",a)
loaded=assert(P.import(w.disk))
local recovered,recoveryReason=P.recover(loaded,a)
check("dealer purchase: repeated unresolved restart does not clear recovery gate",not recovered and recoveryReason=="RECOVERY_REQUIRED" and loaded.recoveryRequired and loaded.locks.a)

store,a,w=fixture(); P.execute(store,request(),"user1",a)
broken=P.export(store); broken.records.r1.request=5
local safe, value, reason=pcall(P.import,broken)
check("dealer purchase: malformed scalar request rejects without exception",safe and value==nil and reason=="BAD_JOURNAL_RECORD")

store,a,w=fixture(); local reconcile=a.reconcile
 a.apply=function() return "COMMITTED" end
 a.reconcile=function(token,plan,c)
    local receipt=reconcile(token,plan,c); receipt.token="wrong-token"; return receipt
 end
_,why=P.execute(store,request(),"user1",a)
check("dealer purchase: bare success and wrong-token receipt fail closed",why=="RECOVERY_REQUIRED" and store.recoveryRequired and store.locks.a)
store,a,w=fixture(); local apply=a.apply
 a.apply=function(token,plan,c)
    local receipt=apply(token,plan,c); receipt.transferIds={"other-a","other-b"}; return receipt
 end
 a.reconcile=function() return "UNKNOWN" end
_,why=P.execute(store,request(),"user1",a)
check("dealer purchase: receipt from wrong transfer batch cannot commit",why=="RECOVERY_REQUIRED" and store.recoveryRequired)
store,a,w=fixture(); P.execute(store,request(),"user1",a)
broken=P.export(store); broken.records.r1.receipt.moneyComplete=false
_,why=P.import(broken)
check("dealer purchase: incomplete money receipt cannot be imported as committed",why=="BAD_JOURNAL_RECEIPT")

store,a,w=fixture(); local first=P.execute(store,request(),"user1",a)
w.stock.c,w.stock.d=true,true
local nextRequest=request("r2"); nextRequest.items={{saleId="c",revision=1},{saleId="d",revision=1}}
a.prepare=function() return {amount=200,compensation={},transferIds=first.transferIds} end
_,why=P.execute(store,nextRequest,"user1",a)
check("dealer purchase: transfer identities cannot be reused across journal owners",why=="TRANSFER_ID_IN_USE" and w.applies==1 and w.money==800)

for _,fault in ipairs({"revision","clock","eligibility","permission","capacity","funds","quote"}) do
    store,a,w=fixture(); local checkpoint=a.checkpoint
    a.checkpoint=function(snapshot)
        local ok=checkpoint(snapshot)
        if w.writes==2 then
            if fault=="revision" then a.readListing=function(id) return {saleId=id,recordRevision=2,state="LISTED"} end
            elseif fault=="clock" then a.currentClock=function() return 3.5 end
            elseif fault=="eligibility" then a.validateListing=function() return false,"WITHDRAWN" end
            elseif fault=="permission" then a.authorize=function() return false end
            elseif fault=="capacity" then a.validateDestination=function() return false,"CAPACITY" end
            elseif fault=="funds" then a.validateFunds=function() return false,"FUNDS" end
            elseif fault=="quote" then a.validateQuote=function() return false,"STALE_QUOTE" end end
        end
        return ok
    end
    local outcome=P.execute(store,request(),"user1",a)
    check("dealer purchase: "..fault.." changed during checkpoint rejects before effects",outcome and outcome.status=="ROLLED_BACK" and w.applies==0 and w.money==1000)
end

store,a,w=fixture(); P.execute(store,request(),"user1",a)
local exported=P.export(store)
loaded=assert(P.import(exported,{forceReconciliation=true}))
check("dealer purchase: WAL ahead of assets preserves terminal evidence and gates replay",loaded.recoveryRequired
    and loaded.records.r1.stage=="COMMITTED" and loaded.records.r1.receipt.token=="dealer:r1" and loaded.records.r1.needsReconciliation and loaded.locks.a)
_,why=P.execute(loaded,request(),"user1",a)
check("dealer purchase: forced ownership audit blocks committed replay",why=="RECOVERY_REQUIRED")
local audits=0; local reconcile=a.reconcile
a.reconcile=function(...) audits=audits+1; return reconcile(...) end
check("dealer purchase: forced terminal audit consults actual ownership before replay",P.recover(loaded,a) and audits==1
    and not loaded.recoveryRequired and not loaded.records.r1.needsReconciliation and P.execute(loaded,request(),"user1",a).status=="COMMITTED" and w.applies==1)
loaded=assert(P.import(exported,{forceReconciliation=true})); w.receipts={}; w.money=1000; w.stock={a=true,b=true}; w.target={}
check("dealer purchase: WAL committed but older assets can reconcile to rolled back",P.recover(loaded,a)
    and loaded.records.r1.stage=="ROLLED_BACK" and w.money==1000 and P.execute(loaded,request(),"user1",a).status=="ROLLED_BACK")
loaded=assert(P.import(exported,{forceReconciliation=true})); w.unknown=true
local audited=P.recover(loaded,a)
check("dealer purchase: terminal WAL ownership ambiguity preserves prior receipt and lock",not audited and loaded.recoveryRequired
    and loaded.records.r1.receipt.status=="COMMITTED" and loaded.locks.a and loaded.records.r1.stage=="RECOVERY_REQUIRED")
-- A past rollback and later commit may refer to the same sale but different transfer IDs.
store,a,w=fixture(); w.fault="target"; P.execute(store,request(),"user1",a); w.fault=nil
P.execute(store,request("r2"),"user1",a)
loaded=assert(P.import(P.export(store),{forceReconciliation=true}))
check("dealer purchase: forced audit retains multiple historical owners for one sale",loaded.locks.a.recoveryOwners.r1 and loaded.locks.a.recoveryOwners.r2)
check("dealer purchase: forced audit releases shared recovery locks after every owner resolves",P.recover(loaded,a) and not next(loaded.locks) and not loaded.recoveryRequired)
