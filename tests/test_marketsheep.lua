loadMod("tests/fixtures/market_production.lua")
local F,S=MarketProductionFixture,RLMarketSheepValue
local s,i=F.snapshot("SHEEP"),F.input()
i.params.expectedLitter=2;i.params.exitAge=20
i.woolNetByMonth={1,1,1,1,1,1,1,1,1,1,1,1}
s.genes.quality=1.5
local ewe=assert(S.evaluate(s,"TERMINAL",i))
check("sheep: 2 births x2 lambs x105 +2 wool =422",ewe.referenceValue==422 and ewe.hereditaryDelta==20 and ewe.breakdown.woolPV==2)
s.genes.productivity=1.5
local wool=assert(S.evaluate(s,"TERMINAL",i))
check("sheep: productivity changes wool only, not terminal genes",wool.referenceValue==423 and wool.valuationScore==ewe.valuationScore and wool.hereditaryDelta==20)
s.genes.productivity=1
i.calendarMonth=12;i.breedingSeason={true,false,false,false,false,false,false,false,false,false,false,false}
local seasonal=assert(S.evaluate(s,"TERMINAL",i))
check("sheep: December waits for January, later conception exceeds exit",seasonal.breakdown.births==1 and seasonal.referenceValue==212)
check("sheep: wool is never a dairy capability",S.evaluate(s,"DAIRY",i)==nil)
s.speciesKey="GOAT"
check("sheep: goat cannot use sheep life parameters",S.evaluate(s,"MATERNAL",i)==nil)
s.speciesKey="SHEEP";s.traitCapabilities.woolProductivity=false
check("sheep: real wool revenue needs verified output",S.evaluate(s,"MATERNAL",i)==nil)
s,i=F.snapshot("SHEEP"),F.input();i.params.expectedLitter=2;i.params.exitAge=20
s.traitCapabilities.milkProductivity=true;s.genes.productivity=1.5
i.dairyCapability={speciesKey="SHEEP",milkOutputVerified=true,traitMappingRevision=s.traitMappingRevision}
local milk=assert(S.evaluate(s,"DAIRY",i))
check("sheep: explicit real milk/mapping injection permits dairy raw value",milk.referenceValue==455 and milk.breakdown.milkPV==15)
i.dairyCapability.speciesKey="GOAT"
check("sheep: goat milk proof cannot enable dairy sheep",S.evaluate(s,"DAIRY",i)==nil)
