-- Dealer-only witnessed money effects through the EXISTING mission API. Dormant.
-- Persistence hooks must be synchronous durable WAL writes, not an asynchronous game save.
-- Runtime witnesses do not prove ownership after reload; restored records stay UNKNOWN.
RLDealerMoneyAdapter={}
local M=RLDealerMoneyAdapter
M.VERSION=1
local finite=RLPlain.finite
local function text(v) return type(v)=="string" and #v>0 and #v<=4096 end
local copy=RLPlain.copy
local function safe(fn,...) local ok,v,why=pcall(fn,...); if not ok then return nil,"CALLBACK_ERROR" end; return v,why end
local function moneyType(store)
    local registered=MoneyType and MoneyType.NEW_ANIMALS_COST
    if type(registered)~="table" or not text(registered.statistic) or not finite(registered.id) or registered.id%1~=0 or registered.id<0 then return nil,"BAD_MONEY_TYPE" end
    if store.moneyType and store.moneyType~=registered then return nil,"MONEY_TYPE_CHANGED" end
    return registered
end
local function snapshotUnsafe(store,farmId)
    local mission,manager=store.context.mission,store.context.farmManager
    if (store.context.globalMissionBound and mission~=g_currentMission)
        or (store.context.globalManagerBound and manager~=g_farmManager) then return nil,"MONEY_OWNER_CHANGED" end
    if type(mission)~="table" or type(mission.getIsServer)~="function" or safe(mission.getIsServer,mission)~=true then return nil,"SERVER_ONLY" end
    if type(mission.addMoney)~="function" or type(manager)~="table" or type(manager.getFarmById)~="function" then return nil,"NO_MONEY_OWNER" end
    local mt,why=moneyType(store); if not mt then return nil,why end
    local farm=safe(manager.getFarmById,manager,farmId)
    if type(farm)~="table" or farm.farmId~=farmId then return nil,"FARM_NOT_FOUND" end
    local stats=farm.stats
    if not finite(farm.money) or type(stats)~="table" or type(stats.finances)~="table"
        or not finite(stats.finances[mt.statistic]) or not finite(stats.financesVersionCounter)
        or stats.financesVersionCounter%1~=0 or stats.financesVersionCounter<0 or stats.financesVersionCounter>999999
        or not finite(stats.moneyEarnedHeroAccum) or type(mission.moneyChanges)~="table" then return nil,"MONEY_WITNESS_UNREADABLE" end
    local bucket=mission.moneyChanges[mt.id]
    if bucket~=nil and type(bucket)~="table" then return nil,"MONEY_WITNESS_UNREADABLE" end
    local change=bucket and bucket[farmId]
    if change~=nil and not finite(change) then return nil,"MONEY_WITNESS_UNREADABLE" end
    return {money=farm.money,finance=stats.finances[mt.statistic],counter=stats.financesVersionCounter,
        moneyTypeId=mt.id,moneyStatistic=mt.statistic,hero=stats.moneyEarnedHeroAccum,heroActive=type(stats.heroStats)=="table" and stats.heroStats.moneyEarned~=nil,change=change},
        nil,{farm=farm,stats=stats,mission=mission,manager=manager,finances=stats.finances,moneyChanges=mission.moneyChanges,moneyType=mt,addMoney=mission.addMoney,getFarmById=manager.getFarmById}
end
local function snapshot(store,farmId)
    local ok,value,why,owner=pcall(snapshotUnsafe,store,farmId)
    if not ok then return nil,"MONEY_WITNESS_ERROR" end
    return value,why,owner
end
local function sameWitness(a,b) return RLTradePersistence.canonical(a)==RLTradePersistence.canonical(b) end
local function sameOwner(a,b)
    if not a or not b then return false end
    for _,key in ipairs({"farm","stats","mission","manager","finances","moneyChanges","moneyType","addMoney","getFarmById"}) do if a[key]~=b[key] then return false end end
    return true
end
local function unknown(store,record,reason)
    record.status,record.reason="UNKNOWN",reason; store.recoveryRequired=true
    return copy(record)
end
local function persist(store,kind,record)
    local callback=store.context[kind]
    if type(callback)~="function" then return nil,"DURABLE_PERSISTENCE_REQUIRED" end
    if safe(callback,copy(record))~=true then return nil,"PERSISTENCE_UNCERTAIN" end
    return true
end
function M.new(context)
    context=context or {}
    if type(context)~="table" or not text(context.epoch) then return nil,"INVALID_MONEY_CONTEXT" end
    local ctx={epoch=context.epoch,mission=context.mission or g_currentMission,farmManager=context.farmManager or g_farmManager,
        persistPrepared=context.persistPrepared,persistCommitted=context.persistCommitted}
    ctx.globalMissionBound=ctx.mission==g_currentMission
    ctx.globalManagerBound=ctx.farmManager==g_farmManager
    return {version=M.VERSION,epoch=ctx.epoch,context=ctx,records={},bindings={},locks={},recoveryRequired=false}
end
function M.bind(store,farmId,token,amount)
    if not text(token) or not finite(farmId) or farmId%1~=0 or farmId<1 or not finite(amount) or amount<=0 then return nil,"BAD_MONEY_BINDING" end
    local previous=store.records[token]
    if previous then
        if previous.farmId~=farmId or previous.amount~=amount then return nil,"MONEY_TOKEN_CONFLICT" end
        return copy(previous),"REPLAY"
    end
    if store.recoveryRequired then return nil,"RECOVERY_REQUIRED" end
    if store.locks[farmId] then return nil,"FARM_MONEY_LOCKED" end
    if type(store.context.persistPrepared)~="function" or type(store.context.persistCommitted)~="function" then return nil,"DURABLE_PERSISTENCE_REQUIRED" end
    local before,why,owner=snapshot(store,farmId); if not before then return nil,why end
    if before.money<amount then return nil,"INSUFFICIENT_FUNDS" end
    if not finite(before.money-amount) or before.money-amount==before.money or before.finance-amount==before.finance then return nil,"UNREPRESENTABLE_AMOUNT" end
    store.moneyType=owner.moneyType
    local record={version=M.VERSION,epoch=store.epoch,token=token,farmId=farmId,amount=amount,moneyTypeId=owner.moneyType.id,
        moneyStatistic=owner.moneyType.statistic,phase="BOUND",status="NOT_APPLIED",before=before,debitAttempted=false,refundAttempted=false}
    store.records[token],store.bindings[token],store.locks[farmId]=record,{owner=owner},token
    return copy(record)
end
local function current(store,record)
    local binding=store.bindings[record.token]
    if not binding or binding.restored then return nil,"RESTORED_OWNERSHIP_UNPROVEN" end
    local observed,why,owner=snapshot(store,record.farmId)
    if not observed then return nil,why end
    if not sameOwner(binding.owner,owner) then return nil,"MONEY_OWNER_CHANGED" end
    return observed
end
-- Classification includes the actual finance/counter/hero and HUD accumulator path.
-- A throw after balance/stat writes is ambiguous: no blind debit/refund retry is permitted.
local function classify(before,after,signed,returned)
    local counter=before.counter+1; if counter>999999 then counter=0 end
    local hero=before.hero+((signed>0 and before.heroActive) and signed or 0)
    local complete=after.moneyTypeId==before.moneyTypeId and after.moneyStatistic==before.moneyStatistic and after.money==before.money+signed and after.finance==before.finance+signed and after.counter==counter
        and after.hero==hero and after.heroActive==before.heroActive and returned and after.change==nil
    if complete then return "APPLIED","COMPLETE_MONEY_PATH" end
    if sameWitness(before,after) and not returned then return "NOT_APPLIED","THREW_WITHOUT_OBSERVABLE_EFFECT" end
    return "UNKNOWN",returned and "UNEXPLAINED_MONEY_DELTA" or "MONEY_CALL_INTERRUPTED"
end
function M.observe(store,token)
    local record=store.records[token]; if not record then return nil,"UNKNOWN_MONEY_TOKEN" end
    local binding=store.bindings[token]
    if binding and binding.busy then local result=copy(record); result.status,result.reason="UNKNOWN","MONEY_CALL_IN_PROGRESS"; return result end
    local observed,why=current(store,record)
    if not observed then return unknown(store,record,why) end
    if record.status=="UNKNOWN" then return copy(record) end
    local expected=record.debitAttempted and record.debitAfter or record.before
    if not expected or not sameWitness(observed,expected) then return unknown(store,record,"FOREIGN_MONEY_CHANGE") end
    return copy(record)
end
function M.apply(store,token)
    local record=store.records[token]; if not record then return nil,"UNKNOWN_MONEY_TOKEN" end
    local binding=store.bindings[token]
    if not binding or binding.restored then return unknown(store,record,"RESTORED_OWNERSHIP_UNPROVEN") end
    if binding.busy then local result=copy(record); result.status,result.reason="UNKNOWN","MONEY_CALL_IN_PROGRESS"; return result end
    if record.cancelled then return M.observe(store,token) end
    if record.debitAttempted or record.phase~="BOUND" then return M.observe(store,token) end
    local before,why=current(store,record)
    if not before or not sameWitness(before,record.before) then return unknown(store,record,why or "FOREIGN_MONEY_CHANGE") end
    if store.recoveryRequired then return unknown(store,record,"RECOVERY_REQUIRED") end
    binding.busy=true
    record.phase,record.status,record.debitAttempted="DEBIT_PREPARED","UNKNOWN",true
    local durable,reason=persist(store,"persistPrepared",record)
    if not durable then binding.busy=false; return unknown(store,record,reason) end
    -- A durable callback can yield or reenter; check owner and all witnesses again.
    local live,liveReason=current(store,record)
    if not live or not sameWitness(live,before) then binding.busy=false; return unknown(store,record,liveReason or "FOREIGN_MONEY_CHANGE") end
    record.phase="DEBIT_CALLED"
    local returned,err=pcall(store.context.mission.addMoney,store.context.mission,-record.amount,record.farmId,store.moneyType,true,true)
    record.callReturned=returned
    if not returned then record.callError=tostring(err) end
    local after,afterReason=current(store,record)
    record.phase="DEBIT_FINISHED"
    if not after then record.status,record.reason="UNKNOWN",afterReason else
        record.debitAfter=after
        record.status,record.reason=classify(before,after,-record.amount,returned)
        record.debitEffectStatus=record.status
    end
    local committed,commitReason=persist(store,"persistCommitted",record)
    binding.busy=false
    if not committed then return unknown(store,record,commitReason) end
    local settled,settledReason=current(store,record)
    if not settled or not record.debitAfter or not sameWitness(settled,record.debitAfter) then
        unknown(store,record,settledReason or "FOREIGN_MONEY_CHANGE")
        persist(store,"persistCommitted",record)
    end
    if record.status=="UNKNOWN" then store.recoveryRequired=true else store.locks[record.farmId]=nil end
    return copy(record)
end
-- Release an unused/proven no-effect token without forgetting its durable identity.
-- A cancelled token can never subsequently debit through apply.
function M.cancel(store,token)
    local record=store.records[token];if not record then return nil,"UNKNOWN_MONEY_TOKEN" end
    local binding=store.bindings[token]
    if not binding or binding.restored or binding.busy then return nil,"MONEY_CANCEL_UNPROVEN" end
    local observed=M.observe(store,token)
    if not observed or observed.status~="NOT_APPLIED" or record.refundAttempted or store.recoveryRequired then return nil,"MONEY_CANCEL_UNPROVEN" end
    if record.cancelled then return observed end
    binding.busy=true;record.cancelled,record.phase=true,"CANCELLED"
    local durable,why=persist(store,"persistCommitted",record);binding.busy=false
    if not durable then return unknown(store,record,why) end
    local settled=M.observe(store,token)
    if not settled or settled.status~="NOT_APPLIED" then return unknown(store,record,"MONEY_CANCEL_CHANGED") end
    if store.locks[record.farmId]==token then store.locks[record.farmId]=nil end
    return copy(record)
end
function M.rollback(store,token)
    local record=store.records[token]; if not record then return nil,"UNKNOWN_MONEY_TOKEN" end
    local binding=store.bindings[token]
    if not binding or binding.restored then return unknown(store,record,"RESTORED_OWNERSHIP_UNPROVEN") end
    if binding.busy then local result=copy(record); result.status,result.reason="UNKNOWN","MONEY_CALL_IN_PROGRESS"; return result end
    if record.refundAttempted then return copy(record) end
    local observed=M.observe(store,token)
    if not observed or observed.status~="APPLIED" then return observed end
    if store.recoveryRequired or (store.locks[record.farmId] and store.locks[record.farmId]~=token) then return unknown(store,record,"RECOVERY_REQUIRED") end
    local before,why=current(store,record)
    if not before or not sameWitness(before,record.debitAfter) then return unknown(store,record,why or "FOREIGN_MONEY_CHANGE") end
    binding.busy=true; store.locks[record.farmId]=token
    record.refundAttempted,record.phase,record.status=true,"REFUND_PREPARED","UNKNOWN"
    local prepared,reason=persist(store,"persistPrepared",record)
    if not prepared then binding.busy=false; return unknown(store,record,reason) end
    local live,liveReason=current(store,record)
    if not live or not sameWitness(live,before) then binding.busy=false; return unknown(store,record,liveReason or "FOREIGN_MONEY_CHANGE") end
    record.phase="REFUND_CALLED"
    local returned,err=pcall(store.context.mission.addMoney,store.context.mission,record.amount,record.farmId,store.moneyType,true,true)
    record.refundReturned=returned
    if not returned then record.refundError=tostring(err) end
    local after,afterReason=current(store,record)
    record.phase="REFUND_FINISHED"
    if after then
        record.refundAfter=after
        record.refundEffectStatus,record.refundReason=classify(before,after,record.amount,returned)
        record.moneyRestored=after.money==record.before.money
        record.financeRestored=after.finance==record.before.finance
        record.statisticsRestored=sameWitness(after,record.before)
        record.reason=record.refundEffectStatus=="APPLIED" and "STATISTICS_NOT_INVERSE" or record.refundReason
    else record.reason=afterReason end
    -- Standard +refund adds hero earnings and finance revisions and emits notifications.
    -- Money restoration alone is not full economic rollback. Keep the gate CLOSED.
    record.status="UNKNOWN"; store.recoveryRequired=true
    local committed,commitReason=persist(store,"persistCommitted",record)
    binding.busy=false
    if not committed then record.reason=commitReason end
    return copy(record)
end
function M.export(store)
    return copy({version=M.VERSION,epoch=store.epoch,records=store.records})
end
-- No amount-equality shortcut. Even a terminal WAL receipt needs a SAME-GENERATION engine
-- money receipt/coordinated asset ownership proof, not supplied by this isolated adapter.
local function witnessOK(w,record)
    return type(w)=="table" and finite(w.money) and finite(w.finance) and finite(w.counter)
        and w.counter%1==0 and w.counter>=0 and w.counter<=999999 and finite(w.hero)
        and type(w.heroActive)=="boolean" and (w.change==nil or finite(w.change))
        and w.moneyTypeId==record.moneyTypeId and w.moneyStatistic==record.moneyStatistic
end
local phases={BOUND=true,CANCELLED=true,DEBIT_PREPARED=true,DEBIT_CALLED=true,DEBIT_FINISHED=true,REFUND_PREPARED=true,REFUND_CALLED=true,REFUND_FINISHED=true}
function M.validate(data)
    if type(data)~="table" or RLTradePersistence.check(data) or data.version~=M.VERSION or not text(data.epoch)
        or type(data.records)~="table" then return nil,"BAD_MONEY_DOCUMENT" end
    for token,saved in pairs(data.records) do
        if type(saved)~="table" or not text(token) or token~=saved.token or saved.version~=M.VERSION
            or not text(saved.epoch) or not finite(saved.farmId) or saved.farmId<1 or saved.farmId%1~=0
            or not finite(saved.amount) or saved.amount<=0 or not text(saved.moneyStatistic)
            or not finite(saved.moneyTypeId) or saved.moneyTypeId%1~=0 or saved.moneyTypeId<0 or not phases[saved.phase]
            or not witnessOK(saved.before,saved) or (saved.debitAfter~=nil and not witnessOK(saved.debitAfter,saved))
            or (saved.refundAfter~=nil and not witnessOK(saved.refundAfter,saved))
            or (saved.status~="APPLIED" and saved.status~="NOT_APPLIED" and saved.status~="UNKNOWN")
            or type(saved.debitAttempted)~="boolean" or type(saved.refundAttempted)~="boolean" then return nil,"BAD_MONEY_RECEIPT" end
        if (saved.cancelled~=nil and saved.cancelled~=true) or ((saved.phase=="CANCELLED")~=(saved.cancelled==true))
            or (saved.cancelled and (saved.status=="APPLIED" or saved.refundAttempted)) then return nil,"BAD_MONEY_RECEIPT" end
    end
    return true
end
function M.restore(data,context)
    local valid,why=M.validate(data);if not valid then return nil,why end
    local store;store,why=M.new(context); if not store then return nil,why end
    for token,saved in pairs(data.records) do
        local record=copy(saved); record.historicalStatus=record.historicalStatus or record.status
        record.status,record.reason="UNKNOWN","RESTORED_OWNERSHIP_UNPROVEN"
        store.records[token],store.bindings[token]=record,{restored=true}
        store.locks[record.farmId]=token; store.recoveryRequired=true
    end
    return store
end
