loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLMarketMoney.lua")
loadMod("scripts/market/RLBrokerPricePolicy.lua")
local P=RLBrokerPricePolicy
local function input()
    return {buyerReference=2000,bonus=100,commissionRate=.05,ask=1800,minSpreadAbs=10,minSpreadRate=.04,
        difficultyMultiplier=1,pickupFee=125,finished=true,finishedSpreadAbs=10,finishedSpreadRate=.1,
        slaughter={available=true,net=1500,basis={moneyBasis="HARD"}},sourceResult={verified=true,limited=false}}
end
local r=input();local q=assert(P.quote(r))
check("broker price: finished S1500 ten percent cap independent 1350",q.preTransportCap==1350 and q.selfDelivery.netToPlayer==1350)
check("broker price: bonus before cap and commission once",q.selfDelivery.bodyAmount==2000
    and q.selfDelivery.bonuses[1].amount==100 and q.selfDelivery.fees[1].amount==105 and q.constraintDiscount==645)
check("broker price: pickup fee exactly one shared subtraction",q.pickup.netToPlayer==1225 and q.selfDelivery.netToPlayer-q.pickup.netToPlayer==125)
r.finished=false
q=assert(P.quote(r))
check("broker price: grower and breeding never get finished cap",q.selfDelivery.netToPlayer==1728 and q.capSources.finished==nil)
r.sourceResult={verified=true,limited=true,maximumBeforeTransport=960}
q=assert(P.quote(r))
check("broker price: actual current purchase cap before both transports",q.selfDelivery.netToPlayer==960 and q.pickup.netToPlayer==835)
r.difficultyMultiplier=3
q=assert(P.quote(r))
check("broker price: difficulty does not rescale historical purchase cap or engine transport",q.selfDelivery.netToPlayer==960 and q.pickup.netToPlayer==835)
r=input();r.slaughter=nil
check("broker price: unknown slaughter basis not zero",P.quote(r)==nil)
r=input();r.sourceResult=nil
q=assert(P.quote(r))
check("broker price: unknown provenance can preview but not settle",q.selfDelivery.netToPlayer==1350 and not q.settlementReady and q.reason=="SOURCE_PROOF_REQUIRED")
r=input();r.pickupFee=1400
q=assert(P.quote(r))
check("broker price: nonpositive pickup only blocks pickup",q.selfDeliveryAvailable and not q.pickupAvailable)
local cents=assert(RLMarketMoney.new({unit=.01,verifyRoundTrip=function() return true end}))
r=input();r.slaughter.net=1500.129;r.pickupFee=125.125
q=assert(P.quote(r,cents))
check("broker price: quantized cap and common fee",q.selfDelivery.netToPlayer<=1500.129*.9+1e-9 and near(q.pickupFee,125.13,1e-12)
    and q.pickup.netToPlayer==q.selfDelivery.netToPlayer-q.pickupFee)
r=input();r.buyerReference=1e308;r.difficultyMultiplier=3
local ok,result,reason=pcall(P.quote,r)
check("broker price: overflow fails without exception",ok and result==nil and reason=="MONEY_OVERFLOW")
