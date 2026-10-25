-- Actual shipped price code + animals.xml curves at the measured release
-- windows. Station prices are explicit test assumptions, not a map calibration.
loadMod("tests/breedingvalue_fixture.lua")
loadMod("scripts/animal/RLLivestockPrices.lua")
loadMod("scripts/core/RLConstants.lua")
loadMod("scripts/dealer/RLDealerQualityModel.lua")
loadMod("scripts/dealer/RLDealerQualityResolver.lua")
loadMod("scripts/gui/rlmenu/services/RLAnimalBuyService.lua")
for _,name in ipairs({"RLMarketData","RLMarketMoney","RLMarketEnginePrice","RLBrokerPricePolicy","RLBrokerCattlePolicy"}) do loadMod("scripts/market/"..name..".lua") end
local P=RLBrokerCattlePolicy
local xml=assert(loadXMLFileFromDisk(REPO.."xml/animals.xml"))
local transport={}
xml:iterate("animals.animal",function(_,key)
    xml:iterate(key..".subType",function(_,sub)
        local points={}
        xml:iterate(sub..".transportPrice.key",function(_,p) points[#points+1]={xml:getFloat(p.."#ageMonth"),xml:getFloat(p.."#value")} end)
        transport[xml:getString(sub.."#subType")]=points
    end)
end)
function g_currentMission.animalSystem:getAnimalTransportFee(index,age)
    local points=transport[SUBS[index].name]
    if age<=points[1][1] then return points[1][2] end
    for n=2,#points do local a,b=points[n-1],points[n];if age<=b[1] then return a[2]+(b[2]-a[2])*(age-a[1])/(b[1]-a[1]) end end
    return points[#points][2]
end
local multiplier=1
EconomyManager={getPriceMultiplier=function() return multiplier end}
g_currentMission.missionInfo={}
RLSettings={SETTINGS={dealerQuality={state=3}}}
BROKER_CATTLE_ECONOMY={}
for _,sample in ipairs({
    {name="COW_ANGUS",age=4,weight=127.26286115200345},
    {name="BULL_ANGUS",age=4,weight=142.7773121287686},
    {name="COW_ANGUS",age=10,weight=267.697583336126},
    {name="BULL_ANGUS",age=10,weight=352.54775239262506}
}) do
    for _,difficulty in ipairs({1,1.8,3}) do
        multiplier=difficulty
        local a=bvAnimal(sample.name,sample.age,{weight=sample.weight,health=100,isDead=false})
        local s={speciesKey="COW",breedId="COW:ANGUS",subTypeName=sample.name,
            classRevision=P.CLASS_REVISION,traitMappingRevision=P.TRAIT_REVISION}
        local q=assert(P.quote(a,s,g_currentMission))
        local ask=RLAnimalBuyService.computeBuyPrice(a)
        local bid=a:getSellPrice()
        check("broker economics: real purchase roundtrip negative "..sample.name.." "..sample.age.." "..difficulty,
            q.pickup.netToPlayer<ask and q.selfDelivery.netToPlayer<=bid)
        check("broker economics: actual pickup remains payable "..sample.name.." "..sample.age.." "..difficulty,q.pickupAvailable and q.pickup.netToPlayer>0)
        if difficulty==1 then BROKER_CATTLE_ECONOMY[#BROKER_CATTLE_ECONOMY+1]={name=sample.name,age=sample.age,
            weight=sample.weight,ask=ask,bid=bid,pickup=q.pickupFee,net=q.pickup.netToPlayer} end
    end
end
