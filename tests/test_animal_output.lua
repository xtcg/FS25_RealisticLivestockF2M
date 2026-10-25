loadMod("tests/feedsim.lua")
loadMod("scripts/dealer/RLDealerReplay.lua")
local O=RLAnimalOutput
local oldAnimal=Animal
Animal={isSemenFillType=function(fill)return fill=="BULLSPERM"end,
    isLactationPalletFillType=function(fill)return fill=="MILK" or fill=="GOATMILK"end}
local curve={get=function(_,age)return age*2 end}
local tank={output={milk={fillType="MILK",curve=curve}}}
local direct={output={milk=curve}}
for name,sub in pairs({native=tank,legacy=direct}) do
    check("output reader: feed and dealer agree on "..name,RLFeed.getMatureMilk(sub)==120 and RLDealerReplay.getMilkCurve(sub)==curve)
end
local both={output={milk={fillType="MILK",curve=curve},pallets={fillType="MILK",curve={get=function()return 999 end}}}}
check("output reader: tank takes precedence without adding can milk",RLFeed.getMatureMilk(both)==120)
local semen={output={milk={fillType="BULLSPERM",curve=curve}}}
check("output reader: semen is not forecast milk",RLFeed.getMatureMilk(semen)==0 and RLDealerReplay.getMilkCurve(semen)==nil)
semen.output.pallets={fillType="GOATMILK",curve=curve}
check("output reader: eligible can milk is fallback after semen",RLFeed.getMatureMilk(semen)==120)
local unknown={output={milk={fillType="MILK"},pallets={fillType="EGG",curve=curve}}}
check("output reader: missing curve and nonmilk pallets are unavailable",RLFeed.getMatureMilk(unknown)==0 and O.milkCurve(unknown)==nil)
check("output reader: missing subtypes and malformed curves are unavailable",RLFeed.getMatureMilk(nil)==0 and O.curve({curve={}})==nil)
-- An output without a readable curve yields 0 and leaves the other outputs alone, instead of aborting the hour.
local stubAnimal={age=24,uniqueId="u1",farmId=1,output={},
    getSubType=function()return {name="T",output={manure={fillType="MANURE"},slurry={fillType="LIQUIDMANURE",curve=curve}}} end,
    getDiseaseMultipliers=function()return nil end,
    isCattleMilkOutput=function()return false end}
local produced,why=pcall(AnimalProduction.updateOutput,stubAnimal,20)
check("output production: a curveless output is 0 and does not throw",produced and stubAnimal.output.manure==0)
check("output production: other outputs are still computed",produced and math.abs((stubAnimal.output.slurry or -1)-48/24)<1e-9)
Animal=oldAnimal
