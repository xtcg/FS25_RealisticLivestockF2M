-- U01 exercises old price entry points, not a new market implementation.
loadMod("tests/fixtures/market_legacy.lua")
loadMod("tests/breedingvalue_fixture.lua")
local F = MarketLegacyFixture
-- Reuse the existing XML/animal harness, including the cattle breeding-value path.
-- Add the two meat markets absent from that harness; no price function is mocked.
for name, index in pairs({ PORKMEAT = 41, SHEEPGOATMEAT = 42 }) do
    BV_FILL[name] = index
    local price = F.parameters.meatPrices[name]
    local station = { isSellingPoint = true, acceptedFillTypes = { [index] = true }, originalFillTypePrices = { [index] = price } }
    function station:getEffectiveFillTypePrice(i) return i == index and price * EconomyManager.getPriceMultiplier() or 0 end
    STATIONS[#STATIONS + 1] = station
end
local multiplier = 1
EconomyManager = { getPriceMultiplier = function() return multiplier end }
g_currentMission.missionInfo = {}
-- The original cattle fixture's station returns its current price literally.
for _, station in ipairs(STATIONS) do
    if station.acceptedFillTypes[BV_FILL.BEEFMEAT] then
        function station:getEffectiveFillTypePrice(i) return i == BV_FILL.BEEFMEAT and 8.4 * multiplier or 0 end
    end
end
loadMod("scripts/animal/RLLivestockPrices.lua")
loadMod("scripts/core/RLConstants.lua")
loadMod("scripts/dealer/RLDealerQualityModel.lua")
loadMod("scripts/dealer/RLDealerQualityResolver.lua")
RLSettings = { SETTINGS = { dealerQuality = { state = F.parameters.dealerQualityIndex } } }
loadMod("scripts/gui/rlmenu/services/RLAnimalBuyService.lua")
loadMod("scripts/gui/rlmenu/services/RLAnimalSellService.lua")
loadMod("scripts/market/RLLegacyPriceAdapter.lua")
-- These are captured before any future price hooks. ASK uses the captured BID
-- plus the old markup exactly once; no dynamically dispatched getSellPrice call.
local originalBid = Animal.getSellPrice
local legacy = assert(RLLegacyPriceAdapter.new(originalBid,
    function(animal) return originalBid(animal) * RLDealerQualityResolver.getMarkup() end))
loadAnimalSection("function Animal:getTranportationFee(factor)", "--- Whether this animal can be sold.")

-- Only the engine's XML AnimCurve/transport accessor is emulated here.
local transport = {}
local xml = loadXMLFileFromDisk(REPO .. "xml/animals.xml")
xml:iterate("animals.animal", function(_, key)
    xml:iterate(key .. ".subType", function(_, subKey)
        local points = {}
        xml:iterate(subKey .. ".transportPrice.key", function(_, k)
            points[#points + 1] = { xml:getFloat(k .. "#ageMonth"), xml:getFloat(k .. "#value") }
        end)
        transport[xml:getString(subKey .. "#subType")] = points
    end)
end)
function g_currentMission.animalSystem:getAnimalTransportFee(index, age)
    local points = transport[SUBS[index].name]
    if age <= points[1][1] then return points[1][2] end
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if age <= b[1] then return a[2] + (b[2] - a[2]) * (age - a[1]) / (b[1] - a[1]) end
    end
    return points[#points][2]
end
local function close(a, b) return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= 1e-7 * math.max(1, math.abs(b)) end
check("U01 preset markup hand anchor", close(RLDealerQualityResolver.getMarkup(), F.parameters.dealerMarkup))
local animals = {}
for _, sample in ipairs(F.samples) do
    animals[#animals + 1] = bvAnimal(sample.subType, sample.age, { weight = sample.weight, targetWeight = sample.targetWeight, isIndividual = true })
end
for _, difficulty in ipairs(F.difficulty) do
    multiplier = difficulty.multiplier
    RLMeatValue.resetPriceCache()
    RLBreedingValue.reset()
    for i, sample in ipairs(F.samples) do
        local a, e = animals[i], sample.expected
        local bid, fee, net = RLAnimalSellService.computeSellPrice(a)
        local ask = RLAnimalBuyService.computeBuyPrice(a)
        local slaughter, kg = RLMeatValue.getSlaughterValue(a)
        check("U01 baseline " .. sample.id .. " " .. difficulty.name,
            close(bid, e.bid * multiplier) and close(ask, e.ask * multiplier)
            and close(fee, e.transportFee) and close(kg, e.meatKg) and close(slaughter, e.slaughterValue * multiplier))
        check("U01 hand arithmetic " .. sample.id .. " " .. difficulty.name,
            close(ask, bid * F.parameters.dealerMarkup) and close(net, bid - fee))
        local adaptedBid, adaptedAsk = legacy:quote("BID", a), legacy:quote("ASK", a)
        check("U10 frozen old entry points " .. sample.id .. " " .. difficulty.name,
            adaptedBid.bodyAmount == bid and adaptedAsk.bodyAmount == ask)
        local oneBuy, oneBuyFee, oneGross, oneBuyCount = RLAnimalBuyService.computeBulkTotal({ a })
        local oneSell, oneSellFee, oneNet, oneSellCount = RLAnimalSellService.computeBulkTotal({ a })
        check("U01 single vs batch " .. sample.id .. " " .. difficulty.name,
            close(oneBuy, e.ask * multiplier) and close(oneBuyFee, e.transportFee)
            and close(oneGross, e.ask * multiplier + e.transportFee) and oneBuyCount == 1
            and close(oneSell, e.bid * multiplier) and close(oneSellFee, e.transportFee)
            and close(oneNet, e.bid * multiplier - e.transportFee) and oneSellCount == 1)
    end
    local buy, buyFee, gross, buyCount = RLAnimalBuyService.computeBulkTotal(animals)
    local sell, sellFee, net, sellCount = RLAnimalSellService.computeBulkTotal(animals)
    local expectedBuy, expectedSell, expectedFee = 0, 0, 0
    for _, sample in ipairs(F.samples) do
        expectedBuy = expectedBuy + sample.expected.ask * multiplier
        expectedSell = expectedSell + sample.expected.bid * multiplier
        expectedFee = expectedFee + sample.expected.transportFee
    end
    check("U01 mixed species batch " .. difficulty.name,
        close(buy, expectedBuy) and close(sell, expectedSell) and close(buyFee, expectedFee) and close(sellFee, expectedFee)
        and close(gross, expectedBuy + expectedFee) and close(net, expectedSell - expectedFee) and buyCount == 3 and sellCount == 3)
end
-- A future engine hook may replace the method. Captured legacy entry points must
-- still work without invoking that hook (or re-applying the market's markup).
local hookedCalls = 0
Animal.getSellPrice = function() hookedCalls = hookedCalls + 1; error("new hook") end
multiplier = 1
RLMeatValue.resetPriceCache()
RLBreedingValue.reset()
check("U10 captured legacy ASK avoids a later live-price hook",
    close(legacy:quote("ASK", animals[1]).bodyAmount, F.samples[1].expected.ask) and hookedCalls == 0)
