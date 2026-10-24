loadMod("tests/fixtures/broker_engine.lua")
local F,A=BrokerEngineFixture,RLBrokerMoneyAdapter
local function setup(persist)
    local m,f,t=F.money();local disk={}
    local adapter=assert(A.new({mission=m,moneyType=t,persistReceipt=persist or function(r)disk[#disk+1]=r;return true end}))
    return adapter,m,f,disk,t
end
local function action(id)return {paymentId=id or "pay1",requestId="broker-request",farmId=1,netAmount=100}end
local a,m,f,disk=setup()
local receipt=a:pay(action())
check("broker money: real balance finance hero HUD witnesses prove payout",receipt.status=="APPLIED" and f.money==1100 and f.stats.finances.animals==100 and m.calls==1 and receipt.kind=="BROKER")
check("broker money: complete before evidence durable prior to paid after record",#disk==2 and disk[1].stage=="BEFORE" and disk[1].before.money==1000 and disk[2].after.money==1100)
check("broker money: same payment replays receipt without second credit",a:pay(action()).status=="APPLIED" and m.calls==1)
local changed=action();changed.netAmount=101
check("broker money: payment ID cannot change payload",a:pay(changed).status=="UNKNOWN" and m.calls==1)
for _,mode in ipairs({"PARTIAL","RETURN_EMPTY","BEFORE_THROW","HUD_THROW"})do
    a,m,f=setup();m.mode=mode
    local got=a:pay(action());local expected=mode=="BEFORE_THROW" and "NOT_APPLIED" or (mode=="HUD_THROW" and "APPLIED" or "UNKNOWN")
    check("broker money: observed "..mode.." classification",got.status==expected and m.calls==1)
    a:pay(action());check("broker money: "..mode.." never auto retried",m.calls==1)
end
local calls=0
a,m,f=setup(function()calls=calls+1;return false end)
check("broker money: failed before receipt barrier prevents payout",a:pay(action()).status=="NOT_APPLIED" and m.calls==0 and f.money==1000)
calls=0
a,m,f=setup(function()calls=calls+1;return calls==1 end)
check("broker money: failed after receipt becomes UNKNOWN and stays single-paid",a:pay(action()).status=="UNKNOWN" and f.money==1100 and a:pay(action()).status=="UNKNOWN" and m.calls==1)
a,m,f=setup()
local nested,other
m.onMoney=function()nested=a:pay(action());other=a:pay(action("pay2"))end
check("broker money: reentrant same and different payment IDs cannot double credit",a:pay(action()).status=="APPLIED" and nested.status=="UNKNOWN" and other.status=="NOT_APPLIED" and m.calls==1)
a,m,f,disk=setup();a:pay(action())
local reloaded=assert(A.new({mission=m,moneyType={id=7,statistic="animals"},receipts={pay1=disk[1]},persistReceipt=function()return true end}))
check("broker money: loaded before-only receipt is UNKNOWN and cannot be paid again",reloaded:pay(action()).status=="UNKNOWN" and m.calls==1)
local freshMission,freshFarm,freshType=F.money()
local withoutProof=assert(A.new({mission=freshMission,moneyType=freshType,receipts={pay1=disk[2]},persistReceipt=function()return true end}))
check("broker money: loaded APPLIED cannot prove current payout after rollback",withoutProof:pay(action()).status=="UNKNOWN"
    and freshFarm.money==1000 and freshMission.calls==0 and withoutProof:receipt("pay1").historicalEvidence.status=="APPLIED")
local settled=assert(A.new({mission=freshMission,moneyType=freshType,receipts={pay1=disk[2]},checkpointRef="verified-whole-checkpoint",
    verifyHistoricalReceipt=function(receipt,reference)return receipt.status=="APPLIED" and reference=="verified-whole-checkpoint" end,
    persistReceipt=function()return true end}))
check("broker money: verified saved history never becomes a new live APPLIED result",settled:pay(action()).status=="HISTORICAL_SETTLED"
    and freshMission.calls==0 and freshFarm.money==1000)
local foreign=assert(RLMarketData.copy(disk[2]))
foreign.paymentId="pay2";foreign.action.paymentId="pay2";foreign.action.netAmount=10
foreign.actionFingerprint=assert(RLMarketData.fingerprint(foreign.action))
local disguised=assert(RLMarketData.copy(disk[2]));disguised.historicalEvidence=foreign
local verifierCalls=0
local invalidHistory=A.new({mission=freshMission,moneyType=freshType,receipts={pay1=disguised},checkpointRef="saved",
    verifyHistoricalReceipt=function()verifierCalls=verifierCalls+1;return true end,persistReceipt=function()return true end})
check("broker money: another settled payment cannot certify this action",invalidHistory==nil and verifierCalls==0 and freshMission.calls==0)
a,m,f=setup();local invalid=action();invalid.netAmount=0
check("broker money: nonpositive net never enters settlement",a:pay(invalid).status=="NOT_APPLIED" and m.calls==0)
