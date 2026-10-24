loadMod("tests/fixtures/market_production.lua")
local F, C = MarketProductionFixture, RLMarketCattleValue
local s, i = F.snapshot("COW"), F.input()
local base = assert(C.evaluate(s, "DAIRY", i))
check("cattle: raw two calves and nonoverlapping milk PV = 230", base.referenceValue == 230 and base.ownDelta == 0 and base.hereditaryDelta == 0)
s.genes.productivity = 1.5
local dairy = assert(C.evaluate(s, "DAIRY", i))
check("cattle: own milk delta 15 and daughter delta 20 counted separately", dairy.ownDelta == 15 and dairy.hereditaryDelta == 20 and dairy.referenceValue == 265)
s.genes.quality = 1.5
local terminal = assert(C.evaluate(s, "TERMINAL", i))
check("cattle: terminal offspring meat gene once, productivity excluded", terminal.referenceValue == 210 and terminal.hereditaryDelta == 10 and terminal.valuationScore == 1.5)
s.genes.productivity = 1
check("cattle: changing productivity cannot inflate terminal score/value", C.evaluate(s,"TERMINAL",i).referenceValue == terminal.referenceValue)
s.reproductive.pregnant, s.reproductive.reproduction = true, 50
s.reproductive.pregnancy = { duration = 1, pregnancies = { {}, {} } }
i.existingFetusNetValues = {60,70}
local pregnant = assert(C.evaluate(s,"TERMINAL",i))
check("cattle: known unborn values once; only future calf gets inherited gain", pregnant.referenceValue == 235 and pregnant.hereditaryDelta == 5 and pregnant.breakdown.existingFetusValue == 130)
s = F.snapshot("COW","male");s.genes.quality=1.5
local sire = assert(C.evaluate(s,"TERMINAL",i))
check("cattle: sire only descendants, no own milk cash flow", sire.referenceValue == 70 and sire.ownDelta == 0 and sire.breakdown.ownMilk == 0)
s.castrated = true
check("cattle: castration closes breeding route", C.evaluate(s,"DAIRY",i) == nil)
s.castrated=false;s.traitCapabilities.milkProductivity=false
check("cattle: DAIRY requires verified female milk capability", C.evaluate(s,"DAIRY",i) == nil)
i.params.sireFemalesPerSeason=nil
check("cattle: unknown service scale never uses cow defaults", C.evaluate(s,"TERMINAL",i) == nil)
-- Different marginal cost assumptions change the own-gene contribution without
-- silently scaling the whole net stream as though costs were proportional.
s=F.snapshot("COW");s.genes.productivity=1.5;i=F.input();i.lactationIncrementNetByMonth={20,20}
local marginal=assert(C.evaluate(s,"DAIRY",i))
check("cattle: milk baseline net and marginal productivity are distinct",marginal.ownDelta==30 and marginal.referenceValue==280)
local savedMission,savedRandom=g_currentMission,math.random
g_currentMission=nil;math.random=function()error("cash-flow RNG forbidden")end
local pure=assert(C.evaluate(s,"DAIRY",i))
g_currentMission=savedMission;math.random=savedRandom
check("cattle: raw cash flows use no game globals or RNG",pure.referenceValue==marginal.referenceValue)
i.costBasis=nil
check("cattle: omitted production costs cannot become a free stream",C.evaluate(s,"DAIRY",i)==nil)
s=F.snapshot("COW","male");i=F.input();s.genes.productivity=1.5;s.genes.quality=0.25
local dairySire=assert(C.evaluate(s,"DAIRY",i))
check("cattle: poor meat quality does not disqualify dairy sire",dairySire.referenceValue==90 and dairySire.valuationScore==1.5 and dairySire.breakdown.ownMilk==0)
s=F.snapshot("COW");s.genes.quality=1.5
local terminalScore=C.evaluate(s,"TERMINAL",i).valuationScore
local maternal=C.evaluate(s,"MATERNAL",i)
check("cattle: terminal and maternal index remain objective-specific",terminalScore==1.5 and maternal.valuationScore==1 and maternal.hereditaryDelta==0)
