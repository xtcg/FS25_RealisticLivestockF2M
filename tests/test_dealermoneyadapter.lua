loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("tests/fixtures/fs25_money.lua")
loadMod("scripts/dealer/RLDealerMoneyAdapter.lua")
local M=RLDealerMoneyAdapter
local epochs=0
local function fixture()
    epochs=epochs+1
    MoneyType={NEW_ANIMALS_COST={id=9,statistic="newAnimalsCost"}}
    local mt=MoneyType.NEW_ANIMALS_COST
    local w={calls=0,prepared=0,committed=0,events=0,notifications=0,hud=0,listener=nil,failPrepared=false,failCommitted=false}
    local farm=FarmMoney.newFarm(1,1000,{"newAnimalsCost","otherCost"})
    local farms={[1]=farm,[2]=FarmMoney.newFarm(2,2000,{"newAnimalsCost","otherCost"})}
    local manager={getFarmById=function(_,id) return farms[id] end}
    g_farmManager=manager
    local mission={getIsServer=function() return true end,getFarmId=function() return 1 end,
        missionDynamicInfo={isMultiplayer=true},moneyChanges={},hud={addMoneyChange=function() w.hud=w.hud+1 end,showMoneyChange=function() end},
        addMoneyChange=FSBaseMissionMoney.addMoneyChange,broadcastNotifications=FSBaseMissionMoney.broadcastNotifications,
        broadcastEventToFarm=function() w.notifications=w.notifications+1 end}
    mission.addMoney=function(self,amount,farmId,moneyType,addChange,forceShow)
        w.calls=w.calls+1
        w.lastCall={amount=amount,farmId=farmId,moneyType=moneyType,addChange=addChange,forceShow=forceShow}
        if w.beforeCall then w.beforeCall() end
        FSBaseMissionMoney.addMoney(self,amount,farmId,moneyType,addChange,forceShow)
        if w.afterCall then w.afterCall() end
    end
    g_currentMission=mission
    g_messageCenter={publish=function(_,kind,id,amount) w.events=w.events+1; if w.listener then w.listener(kind,id,amount) end end}
    MessageType={MONEY_CHANGED=5}; MoneyChangeEvent={new=function(...) return {...} end}
    local context={epoch="money-load-"..epochs,mission=mission,farmManager=manager,
        persistPrepared=function(record)
            w.prepared=w.prepared+1; w.preparedReceipt=record
            if w.onPrepared then w.onPrepared(record) end
            return not w.failPrepared
        end,
        persistCommitted=function(record)
            w.committed=w.committed+1; w.committedReceipt=record
            if w.onCommitted then w.onCommitted(record) end
            return not w.failCommitted
        end}
    local store=assert(M.new(context))
    return store,w,farm,farms,context,mission,mt
end
local store,w,farm,farms,ctx,mission,mt=fixture()
local bound=assert(M.bind(store,1,"t1",200))
check("dealer money: bind is pure and records actual owner witnesses",bound.status=="NOT_APPLIED" and bound.before.money==1000 and w.calls==0 and w.prepared==0 and farm.money==1000)
local receipt=M.apply(store,"t1")
check("dealer money: existing mission API debits exactly once with registered money type",receipt.status=="APPLIED" and farm.money==800 and w.calls==1
    and w.lastCall.amount==-200 and w.lastCall.farmId==1 and w.lastCall.moneyType==mt and w.lastCall.addChange and w.lastCall.forceShow)
check("dealer money: finance counter hero and HUD follow actual engine ordering",farm.stats.finances.newAnimalsCost==-200 and farm.stats.financesVersionCounter==1
    and farm.stats.moneyEarnedHeroAccum==0 and w.events==1 and w.notifications==1 and w.hud==1 and mission.moneyChanges[mt.id][1]==nil)
check("dealer money: durable intent precedes API and final receipt follows",w.prepared==1 and w.committed==1 and w.preparedReceipt.phase=="DEBIT_PREPARED"
    and w.preparedReceipt.status=="UNKNOWN" and w.preparedReceipt.debitAttempted and w.committedReceipt.status=="APPLIED")
receipt.amount=1
check("dealer money: receipt copies cannot alter token authority",store.records.t1.amount==200 and M.apply(store,"t1").status=="APPLIED" and w.calls==1)
local _,why=M.bind(store,1,"t1",201)
check("dealer money: changed amount on same token conflicts",why=="MONEY_TOKEN_CONFLICT")
_,why=M.bind(store,2,"t1",200)
check("dealer money: changed farm on same token conflicts",why=="MONEY_TOKEN_CONFLICT")
check("dealer money: unchanged owner and full token receipt observe applied",M.observe(store,"t1").status=="APPLIED")
local refund=M.rollback(store,"t1")
check("dealer money: refund uses same API positive amount exactly once",w.calls==2 and w.lastCall.amount==200 and w.lastCall.moneyType==mt and farm.money==1000 and refund.moneyRestored and refund.financeRestored)
check("dealer money: refund exposes irreversible engine statistical effects and closes gate",refund.status=="UNKNOWN" and refund.reason=="STATISTICS_NOT_INVERSE"
    and not refund.statisticsRestored and farm.stats.moneyEarnedHeroAccum==200 and farm.stats.financesVersionCounter==2 and w.events==2 and w.notifications==2 and store.recoveryRequired)
M.rollback(store,"t1"); M.apply(store,"t1")
check("dealer money: unknown refund is never repeated or redebited",w.calls==2 and farm.money==1000)
for _,case in ipairs({
    {"negative amount",function(s,w,f,l,c) return 1,"t",-1 end,"BAD_MONEY_BINDING"},
    {"zero amount",function(s,w,f,l,c) return 1,"t",0 end,"BAD_MONEY_BINDING"},
    {"NaN amount",function(s,w,f,l,c) return 1,"t",0/0 end,"BAD_MONEY_BINDING"},
    {"spectator farm",function(s,w,f,l,c) return 0,"t",1 end,"BAD_MONEY_BINDING"},
    {"missing farm",function(s,w,f,l,c) return 3,"t",1 end,"FARM_NOT_FOUND"},
    {"funds",function(s,w,f,l,c) return 1,"t",1001 end,"INSUFFICIENT_FUNDS"},
    {"unreadable money",function(s,w,f,l,c) f.money=0/0; return 1,"t",1 end,"MONEY_WITNESS_UNREADABLE"},
    {"unreadable finance",function(s,w,f,l,c) f.stats.finances.newAnimalsCost=nil; return 1,"t",1 end,"MONEY_WITNESS_UNREADABLE"},
    {"missing durable intent",function(s,w,f,l,c) s.context.persistPrepared=nil; return 1,"t",1 end,"DURABLE_PERSISTENCE_REQUIRED"},
    {"client",function(s,w,f,l,c) s.context.mission.getIsServer=function() return false end; return 1,"t",1 end,"SERVER_ONLY"},
    {"tiny unrepresentable debit",function(s,w,f,l,c) return 1,"t",1e-300 end,"UNREPRESENTABLE_AMOUNT"}
}) do
    local s,z,f,l,c=fixture(); local id,token,amount=case[2](s,z,f,l,c)
    local value,reason=M.bind(s,id,token,amount)
    check("dealer money: "..case[1].." refuses before any call",not value and reason==case[3] and z.calls==0)
end
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); w.failPrepared=true
receipt=M.apply(store,"t")
check("dealer money: uncertain intent write prevents engine debit and closes gate",receipt.status=="UNKNOWN" and receipt.reason=="PERSISTENCE_UNCERTAIN" and w.calls==0 and store.recoveryRequired)
M.apply(store,"t")
check("dealer money: failed intent never silently retries",w.calls==0)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); w.failCommitted=true
receipt=M.apply(store,"t"); M.apply(store,"t"); M.rollback(store,"t")
check("dealer money: final WAL uncertainty never repays or refunds blindly",receipt.status=="UNKNOWN" and farm.money==800 and w.calls==1 and store.recoveryRequired)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); w.beforeCall=function() error("before") end
receipt=M.apply(store,"t"); M.apply(store,"t")
check("dealer money: throw before observable effect is not applied and never retried",receipt.status=="NOT_APPLIED" and farm.money==1000 and w.calls==1)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); w.afterCall=function() error("after") end
receipt=M.apply(store,"t"); M.apply(store,"t"); M.rollback(store,"t")
check("dealer money: throw after complete effect remains unknown without duplicate/refund",receipt.status=="UNKNOWN" and receipt.debitAfter.money==800 and farm.money==800 and w.calls==1 and store.recoveryRequired)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
w.listener=function() error("money changed listener") end
receipt=M.apply(store,"t")
check("dealer money: listener interruption after balance/statistics closes gate",receipt.status=="UNKNOWN" and farm.money==800 and farm.stats.finances.newAnimalsCost==-200 and w.notifications==0)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
local finance=farm.stats.changeFinanceStats
farm.stats.changeFinanceStats=function() error("finance interrupted") end
receipt=M.apply(store,"t")
check("dealer money: partial balance-only debit cannot claim applied",receipt.status=="UNKNOWN" and farm.money==800 and farm.stats.finances.newAnimalsCost==0)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
w.listener=function() farm.money=farm.money+5 end
receipt=M.apply(store,"t"); M.rollback(store,"t")
check("dealer money: foreign listener balance movement refuses compensation",receipt.status=="UNKNOWN" and farm.money==805 and w.calls==1)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
w.listener=function() local hook=w.listener; w.listener=nil; mission:addMoney(-5,1,mt,true,true); w.listener=hook end
receipt=M.apply(store,"t"); M.rollback(store,"t")
check("dealer money: nested actual money callback with extra stats is unknown",receipt.status=="UNKNOWN" and farm.money==795 and farm.stats.financesVersionCounter==2 and w.calls==2)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); M.apply(store,"t")
mission:addMoney(-1,1,mt,true,true); receipt=M.rollback(store,"t")
check("dealer money: foreign post-debit change forbids refund even with valid receipt",receipt.status=="UNKNOWN" and farm.money==799 and w.calls==2)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
farms[1]=FarmMoney.newFarm(1,1000,{"newAnimalsCost"})
receipt=M.apply(store,"t")
check("dealer money: replacement farm with same balance is not same owner",receipt.status=="UNKNOWN" and receipt.reason=="MONEY_OWNER_CHANGED" and w.calls==0)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); M.apply(store,"t")
local copied={}; for k,v in pairs(farm.stats) do copied[k]=v end; farm.stats=copied
receipt=M.rollback(store,"t")
check("dealer money: replaced stats object forbids compensation",receipt.status=="UNKNOWN" and w.calls==1 and farm.money==800)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
w.onPrepared=function() farm.money=farm.money-1 end
receipt=M.apply(store,"t")
check("dealer money: mutation during durable prepare is rechecked before debit",receipt.status=="UNKNOWN" and w.calls==0 and farm.money==999)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
w.onCommitted=function() if w.committed==1 then farm.money=farm.money-1 end end
receipt=M.apply(store,"t")
check("dealer money: mutation during durable committed receipt cannot pass observe",receipt.status=="UNKNOWN" and farm.money==799 and w.calls==1 and w.committed==2)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
local reentered,otherBind,otherWhy,refundAttempt
w.listener=function()
    reentered=M.apply(store,"t")
    otherBind,otherWhy=M.bind(store,1,"other",1)
    refundAttempt=M.rollback(store,"t")
end
receipt=M.apply(store,"t")
check("dealer money: same-token apply and refund reentrancy never double mutate",receipt.status=="APPLIED" and reentered.status=="UNKNOWN" and refundAttempt.status=="UNKNOWN" and w.calls==1 and farm.money==800)
check("dealer money: same-farm competing token is locked during callback",not otherBind and otherWhy=="FARM_MONEY_LOCKED")
store,w,farm,farms,ctx,mission,mt=fixture(); farm.stats.financesVersionCounter=999999; M.bind(store,1,"t",200)
receipt=M.apply(store,"t")
check("dealer money: actual finance counter wrap is witnessed",receipt.status=="APPLIED" and receipt.debitAfter.counter==0)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); M.apply(store,"t")
local document=M.export(store)
local restored=assert(M.restore(document,{epoch="next-load",mission=mission,farmManager=ctx.farmManager,persistPrepared=ctx.persistPrepared,persistCommitted=ctx.persistCommitted}))
receipt=M.apply(restored,"t"); M.rollback(restored,"t")
check("dealer money: loaded WAL plus matching balance never proves engine ownership",receipt.status=="UNKNOWN" and receipt.historicalStatus=="APPLIED" and receipt.reason=="RESTORED_OWNERSHIP_UNPROVEN" and w.calls==1 and restored.recoveryRequired)
local bad=M.export(store); bad.records.t.amount=0
check("dealer money: malformed restored receipt refuses whole document",not M.restore(bad,ctx))
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); M.apply(store,"t")
w.beforeCall=function() error("refund before effect") end
receipt=M.rollback(store,"t"); M.rollback(store,"t")
check("dealer money: failed refund attempt never retries or changes balance",receipt.status=="UNKNOWN" and receipt.refundEffectStatus=="NOT_APPLIED" and w.calls==2 and farm.money==800)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); M.apply(store,"t")
w.afterCall=function() error("refund after effect") end
receipt=M.rollback(store,"t"); M.rollback(store,"t")
check("dealer money: post-refund exception never double refunds",receipt.status=="UNKNOWN" and receipt.moneyRestored and w.calls==2 and farm.money==1000)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
w.onPrepared=function() mt.id=10 end
receipt=M.apply(store,"t")
check("dealer money: mutable money type fields are part of authority witnesses",receipt.status=="UNKNOWN" and w.calls==0)

store,w,farm,farms,ctx,mission,mt=fixture()
mission.addMoney=function() w.calls=w.calls+1 end
M.bind(store,1,"t",200); receipt=M.apply(store,"t"); M.apply(store,"t")
check("dealer money: clean-return no-op never masquerades as debit",receipt.status=="UNKNOWN" and w.calls==1 and farm.money==1000)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); M.apply(store,"t")
w.onPrepared=function() if w.prepared==2 then farm.money=farm.money-1 end end
receipt=M.rollback(store,"t")
check("dealer money: foreign change during refund intent refuses API refund",receipt.status=="UNKNOWN" and w.calls==1 and farm.money==799)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
w.afterCall=function() farm.money=nil end
receipt=M.apply(store,"t")
check("dealer money: unreadable post-call owner closes gate without retry",receipt.status=="UNKNOWN" and store.recoveryRequired and w.calls==1)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200); M.apply(store,"t")
local once=assert(M.restore(M.export(store),{epoch="restore-1",mission=mission,farmManager=ctx.farmManager}))
local twice=assert(M.restore(M.export(once),{epoch="restore-2",mission=mission,farmManager=ctx.farmManager}))
check("dealer money: repeated restore retains original token evidence without trusting balance",twice.records.t.epoch==store.records.t.epoch and twice.records.t.historicalStatus=="APPLIED" and twice.records.t.status=="UNKNOWN")
local malformed=M.export(store); malformed.records.t.before.money=nil
check("dealer money: damaged witness cannot enter recovery document",not M.restore(malformed,ctx))

store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
local replacement=FarmMoney.newFarm(1,1000,{"newAnimalsCost"})
g_farmManager={getFarmById=function() return replacement end}
receipt=M.apply(store,"t")
check("dealer money: changed global manager cannot debit a different farm behind binding",receipt.status=="UNKNOWN" and receipt.reason=="MONEY_OWNER_CHANGED" and w.calls==0 and replacement.money==1000)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
g_currentMission={getIsServer=function() return true end}
receipt=M.apply(store,"t")
check("dealer money: changed global mission closes stale runtime binding",receipt.status=="UNKNOWN" and receipt.reason=="MONEY_OWNER_CHANGED" and w.calls==0)
store,w,farm,farms,ctx,mission,mt=fixture(); M.bind(store,1,"t",200)
mission.addMoney=function() error("changed implementation") end
receipt=M.apply(store,"t")
check("dealer money: changing bound mission money method refuses before any effect",receipt.status=="UNKNOWN" and receipt.reason=="MONEY_OWNER_CHANGED" and w.calls==0)
