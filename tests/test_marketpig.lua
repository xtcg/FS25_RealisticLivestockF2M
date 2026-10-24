loadMod("tests/fixtures/market_production.lua")
local F, P = MarketProductionFixture, RLMarketPigValue
local s,i = F.snapshot("PIG"),F.input()
s.genes.productivity=nil;s.genes.quality=1.5
local sow=assert(P.evaluate(s,"TERMINAL",i))
check("pig: 2 litters x10 x0.8 x(100+5)=1680", sow.referenceValue==1680 and sow.hereditaryDelta==80 and sow.ownDelta==0)
check("pig: no productivity or milk needed", sow.breakdown.ownMilk==0)
s.gender="male"
local boar=assert(P.evaluate(s,"TERMINAL",i))
check("pig: boar descendants only 4x10x0.8x5+50=210", boar.referenceValue==210 and boar.ownDelta==0 and boar.breakdown.ownLitters==0)
s.genes.fertility=0
check("pig: zero fertility is ineligible", P.evaluate(s,"MATERNAL",i)==nil)
s.genes.fertility=1;i.params.expectedLitter=nil
check("pig: missing real litter parameter closes capability", P.evaluate(s,"TERMINAL",i)==nil)
check("pig: DAIRY explicitly unsupported", P.evaluate(s,"DAIRY",i)==nil)
s,i=F.snapshot("PIG"),F.input();s.reproductive.pregnant=true;s.reproductive.reproduction=50
s.reproductive.pregnancy={duration=1,pregnancies={{},{}}};i.existingFetusNetValues={20,30}
s.genes.quality=1.5
local pregnant=assert(P.evaluate(s,"TERMINAL",i))
check("pig: current litter known once, future litter alone inherits sow gain",pregnant.referenceValue==890 and pregnant.breakdown.existingFetusValue==50 and pregnant.hereditaryDelta==40)
s,i=F.snapshot("PIG"),F.input();s.genes.productivity=nil
i.weights.TERMINAL.productivity=0;i.offspringDeltaPerGene.TERMINAL.productivity=0
check("pig: explicit zero weight/coefficient does not require productivity",P.evaluate(s,"TERMINAL",i)~=nil)
