-- Live sale floor at a slaughterhouse's price for the animal's meat (RLMeatValue, Animal:getSellPrice).

AnimalMoveEvent = { MOVE_SUCCESS = 0 }

TYPES = { [1] = { name = "COW" }, [2] = { name = "HORSE" } }
SUBS = { [1] = { typeIndex = 1, targetWeight = 1000, minWeight = 40, reproductionMinAgeMonth = 12,
                 name = "BULL_SWISS_BROWN", breed = "SWISS_BROWN", gender = "male" },
         [2] = { typeIndex = 2, targetWeight = 600, name = "STALLION_GRAY", gender = "male" } }
local BEEFMEAT = 40
FILLTYPES = { BEEFMEAT = BEEFMEAT }
-- Hof Bergmann's BEEFMEAT seasonal factors (config/fillTypes.xml), mean 1.000833.
local HB_FACTORS = { 1.00, 1.07, 0.99, 0.94, 0.85, 0.81, 0.86, 0.99, 1.08, 1.13, 1.21, 1.08 }
FACTORS = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) return FILLTYPES[name] end,
    getFillTypeByIndex = function(_, index)
        return index == BEEFMEAT and { pricePerLiter = 1.8, economy = { factors = FACTORS } } or nil
    end }

-- A selling point paying `price` now; its own base price (pricePerLiter x priceScale) is `price` too
-- unless fields set originalFillTypePrices.
local function station(price, fields)
    local s = { isSellingPoint = true, acceptedFillTypes = { [BEEFMEAT] = true },
        originalFillTypePrices = { [BEEFMEAT] = price } }
    for k, v in pairs(fields or {}) do s[k] = v end
    function s:getEffectiveFillTypePrice(fillType) return fillType == BEEFMEAT and price or 0 end
    return s
end
STATIONS = {}
ECONOMY = {}
g_currentMission = {
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    storageSystem = { getUnloadingStations = function() return STATIONS end },
    economyManager = { getPricePerLiter = function(_, fillType) return ECONOMY[fillType] or 0 end },
}

XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadMod("scripts/animal/RLMeatValue.lua")

local config = AnimalMoveEvent.getCarcassConfig()
check("config: meat fill type, shares and ages read from xml/carcassYield.xml",
    config.meatFillTypes.COW == "BEEFMEAT" and config.meatFillTypes.HORSE == nil
    and near(config.layers.root.slaughterShare, 0.85) and near(config.layers.root.cullShare, 0.70)
    and config.layers.types.COW.cullAgeMonth == 30 and config.layers.types.COW.slaughterMinAgeMonth == 6)

-- Prices
local function price() RLMeatValue.resetPriceCache(); return RLMeatValue.getMeatPrice(BEEFMEAT) end
STATIONS = { station(4.383), station(6.648), station(9, { hideFromPricesMenu = true }), station(9, { isSellingPoint = false }) }
local p, source = price()
check("price: best selling point in the prices menu (hidden and non-selling points ignored)", near(p, 6.648) and source == "station")
STATIONS, ECONOMY = {}, { [BEEFMEAT] = 5.4 }
p, source = price()
check("price: no selling point takes it -> economy price", near(p, 5.4) and source == "economy")
ECONOMY = {}
p, source = price()
check("price: nothing prices it -> 0", p == 0 and source == "none")
STATIONS = { station(6.648) }
check("price: a station that errors is skipped", (function()
    STATIONS[2] = station(0); STATIONS[2].getEffectiveFillTypePrice = function() error("boom") end
    return near(price(), 6.648)
end)())

-- Slaughter value of the reported bull: 516 kg, gene 1 -> 0.845 typical x 270 kg = 228 kg beef.
local function bull(age, weight, fields)
    local a = { subTypeIndex = 1, age = age, weight = weight, gender = "male", targetWeight = 1000,
        genetics = { quality = 1, metabolism = 1 }, diseases = {} }
    for k, v in pairs(fields or {}) do a[k] = v end
    return a
end
-- Cattle floor: (meat kg x price - fee 100 per typical animal - 1.05 per kg) / 1.25 (maxSlaughterMargin),
-- x 0.82 from 30 months.
local function netOf(kg, price) return kg * price - (100 * kg / 270 + 1.05 * kg) end
local function floorOf(kg, price, cull)
    local value = math.max(netOf(kg, price), 0) / 1.25
    return cull and value * 0.82 or value
end
local value, kg, perKg = RLMeatValue.getSlaughterValue(bull(20, 516))
check("value: 516 kg bull -> 228 kg beef, floor (228 x 6.648 - fees 324) / 1.25 = 954", near(kg, 228.2, 0.5)
    and near(perKg, 6.648) and near(value, floorOf(228.2282, 6.648), 3))
check("value: from 30 months cullFloorFactor 0.82", near(RLMeatValue.getSlaughterValue(bull(30, 516)), floorOf(228.2282, 6.648, true), 3))
check("value: under slaughterMinAgeMonth (6) -> no floor", RLMeatValue.getSlaughterValue(bull(5, 200)) == 0)
check("value: a 6-month 220 kg calf by its weight (no finish floor) -> 111 kg",
    near(select(2, RLMeatValue.getSlaughterValue(bull(6, 220))), 110.6, 1))
check("value: a type without meatFillType (horse) -> no floor",
    RLMeatValue.getSlaughterValue({ subTypeIndex = 2, age = 60, weight = 600, genetics = { quality = 1 } }) == 0)
FILLTYPES.BEEFMEAT = nil
check("value: the map lacks the meat fill type -> no floor", RLMeatValue.getSlaughterValue(bull(20, 516)) == 0)
FILLTYPES.BEEFMEAT = BEEFMEAT

-- Annual mean price: the best station's base price x the mean of the 12 seasonal factors x difficulty.
FACTORS = HB_FACTORS
STATIONS = { station(9, { originalFillTypePrices = { [BEEFMEAT] = 8 } }), station(9, { originalFillTypePrices = { [BEEFMEAT] = 8.8 } }),
    station(20, { hideFromPricesMenu = true }) }
RLMeatValue.resetPriceCache()
check("annual mean: best station base 8.8 x seasonal mean 1.000833 (hidden station ignored)",
    near(RLMeatValue.getAnnualMeanPrice(BEEFMEAT), 8.8 * 1.000833, 0.001))
STATIONS = {}
RLMeatValue.resetPriceCache()
check("annual mean: no station -> the fill type's own price 1.8 x 1.000833",
    near(RLMeatValue.getAnnualMeanPrice(BEEFMEAT), 1.8 * 1.000833, 0.001))
FACTORS = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }

-- Animal:getSellPrice: curve price x market factor, never below the slaughter value.
loadAnimalSection("function Animal:getSellPrice()", "function Animal:getDailyRidingTime()")
local CURVE = 700
SUBS[1].sellPrice = { get = function() return CURVE end }
local function live(age, weight, fields)
    local a = bull(age, weight, fields)
    a.getSubType = function() return SUBS[1] end
    a.isHorse = function() return false end
    a.getHealthFactor = function() return 1 end
    return setmetatable(a, { __index = Animal })
end
-- Beef at `now` with an annual mean of `mean`: one station whose base price is the mean.
local function market(now, mean)
    STATIONS = { station(now, { originalFillTypePrices = { [BEEFMEAT] = mean or now } }) }
    RLMeatValue.resetPriceCache()
end
local TYPICAL_NET = function(price) return 270 * price - 100 - 1.05 * 270 end
local function marketFactor(now, mean)
    return math.clamp(1 + 0.6 * (TYPICAL_NET(now) / TYPICAL_NET(mean) - 1), 0.5, 1.5)
end

market(6.648)
local sell = live(20, 516):getSellPrice()
check("sell: curve 700 < slaughter value -> 954", near(sell, floorOf(228.2282, 6.648), 3))
local sick = live(20, 516, { diseases = { { modifyValue = function(_, v) return v * 0.5 end } } })
check("sell: disease scales the floor too", near(sick:getSellPrice(), floorOf(228.2282, 6.648) * 0.5, 3))

-- The live price follows the beef market at pass-through 0.6: 1 at the annual mean.
CURVE = 5000
local function liveAt(now, mean) market(now, mean); return live(20, 516):getSellPrice() end
local atMean = liveAt(9.44, 9.44)
STATIONS = {}
RLMeatValue.resetPriceCache()
check("market: in an average month the live price is the curve price (factor 1)",
    near(atMean, live(20, 516):getSellPrice(), 0.5))
check("market: cheapest month (x0.81) -> x" .. string.format("%.3f", marketFactor(9.44 * 0.81, 9.44)),
    near(liveAt(9.44 * 0.81, 9.44) / atMean, marketFactor(9.44 * 0.81, 9.44), 0.001) and liveAt(9.44 * 0.81, 9.44) < atMean)
check("market: peak month (x1.21) -> x" .. string.format("%.3f", marketFactor(9.44 * 1.21, 9.44)),
    near(liveAt(9.44 * 1.21, 9.44) / atMean, marketFactor(9.44 * 1.21, 9.44), 0.001))
CURVE = 50000
local high = liveAt(9.44, 9.44)
check("market: bounded at x1.5 and x0.5", near(liveAt(40, 9.44) / high, 1.5, 0.001) and near(liveAt(2, 9.44) / high, 0.5, 0.001))
CURVE = 5000
local function cowAt(now) market(now, 9.44); return live(20, 516, { gender = "female" }):getSellPrice() end
check("market: a cow is priced by its milk, not the beef market", near(cowAt(9.44 * 1.21), cowAt(9.44 * 0.81), 0.5))

-- A finished bull calibrated at 12% over the year: V = net at the mean / 1.12. Slaughtering by contract
-- then pays about 0% in the cheapest month, +12% on average and about +22% at the peak, never over 25%.
local KG = 270
local V = TYPICAL_NET(9.44) / 1.12
CURVE = 5000 * V / liveAt(9.44, 9.44)
local margins, netSum, liveSum = {}, 0, 0
for period, factor in ipairs(HB_FACTORS) do
    local now = 9.44 * factor / 1.000833
    local price = liveAt(now, 9.44)
    local net = TYPICAL_NET(now)
    margins[period] = net / price - 1
    netSum, liveSum = netSum + net, liveSum + price
end
check(string.format("margin: +%.1f%% over the year at the map's seasonal factors", (netSum / liveSum - 1) * 100),
    near(netSum / liveSum, 1.12, 0.005))
check(string.format("margin: cheapest month %+.1f%% (-5..+5), peak %+.1f%% (+15..+25)", margins[6] * 100, margins[11] * 100),
    margins[6] > -0.05 and margins[6] < 0.05 and margins[11] > 0.15 and margins[11] < 0.25)
local worst = 0
for _, now in ipairs({ 9.44 * 0.81, 9.44, 9.44 * 1.21, 9.44 * 1.21 * 1.4, 9.44 * 3 }) do
    worst = math.max(worst, netOf(228.2282, now) / liveAt(now, 9.44) - 1)
end
check(string.format("margin: never over maxSlaughterMargin 25%% (great demand x1.4 included; worst %+.1f%%)", worst * 100),
    worst <= 0.25 + 1e-6 and near(netOf(228.2282, 9.44 * 3) / liveAt(9.44 * 3, 9.44), 1.25, 0.001))
CURVE = 700
market(6.648)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
