loadMod("tests/breedingvalue_fixture.lua")
local function input()
    return { meatKg = 270, typicalMeatKg = 270, pricePerKg = 8.4, priceBasis = "HARD", feeBasis = "HARD",
        slaughterFee = 100, processingFeePerKg = 0.37, difficultyMultiplier = 1,
        basis = { stationId = "configured-reference", reachable = true, priceRevision = "p1",
            priceKind = "CURRENT", includesPersonalBonus = false, routeId = "HB_REFERENCE" } }
end
local i = input()
local b = assert(RLMeatValue.calculateBreakdown(i))
check("market meat: raw revenue independent 270x8.4 minus 199.9", near(b.gross,2268,1e-10)
    and near(b.fees,199.9,1e-10) and near(b.net,2068.1,1e-10))
check("market meat: no old maxSlaughterMargin discount", b.net > b.net/1.12)
i.priceBasis, i.pricePerKg, i.difficultyMultiplier = "CURRENT", 25.2, 3
local easy = assert(RLMeatValue.calculateBreakdown(i))
check("market meat: input price normalized once", near(easy.net,b.net,1e-10))
i.basis.reachable = false
check("market meat: inaccessible station is missing capability", RLMeatValue.calculateBreakdown(i) == nil)
i = input(); i.basis.includesPersonalBonus = true
check("market meat: no assumed personal bonus", RLMeatValue.calculateBreakdown(i) == nil)
i = input(); i.processingFeePerKg = nil
check("market meat: unknown fee is not zero", RLMeatValue.calculateBreakdown(i) == nil)
i = input(); i.pricePerKg = math.huge
check("market meat: nonfinite rejected", RLMeatValue.calculateBreakdown(i) == nil)
i = input(); i.meatKg = 540
b = assert(RLMeatValue.calculateBreakdown(i))
check("market meat: per-typical slaughter fee follows actual yield", near(b.fees,399.8,1e-10))
local animal = bvAnimal("BULL_HOLSTEIN",17,{weight=649,targetWeight=1100,isIndividual=true})
local original,kg = RLMeatValue.getSlaughterValue(animal)
local route = { pricePerKg=8.4, priceBasis="HARD", basis=input().basis }
b = assert(RLMeatValue.getMarketBreakdown(animal,route))
check("market meat: actual old meat kg retained and raw net is not floor", b.meatKg==kg
    and b.net > original and near(original,b.net/1.25,1e-6))
check("market meat: legacy result unchanged", RLMeatValue.getSlaughterValue(animal)==original)
check("market meat: no implicit best station", RLMeatValue.getMarketBreakdown(animal,nil)==nil)
animal.genetics.quality = "corrupt"
local ok, result, reason = pcall(RLMeatValue.getMarketBreakdown,animal,route)
check("market meat: bad quality returns unsupported rather than raising", ok and result == nil and reason == "INCOMPLETE_MEAT_CAPABILITY")
animal.genetics.quality = 1
for _, key in ipairs({"weight","targetWeight"}) do
    local old = animal[key]; animal[key] = "corrupt"
    ok,result = pcall(RLMeatValue.getMarketBreakdown,animal,route)
    check("market meat: malformed "..key.." fails closed",ok and result==nil)
    animal[key] = old
end
ok,result = pcall(RLMeatValue.getMarketBreakdown,nil,route)
check("market meat: nil animal fails closed",ok and result==nil)
