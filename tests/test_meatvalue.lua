-- Live sale floor at a slaughterhouse's price for the animal's meat (RLMeatValue, Animal:getSellPrice).

AnimalMoveEvent = { MOVE_SUCCESS = 0 }

TYPES = { [1] = { name = "COW" }, [2] = { name = "HORSE" } }
SUBS = { [1] = { typeIndex = 1, targetWeight = 900, minWeight = 40, reproductionMinAgeMonth = 12,
                 name = "BULL_SWISS_BROWN", breed = "SWISS_BROWN", gender = "male" },
         [2] = { typeIndex = 2, targetWeight = 600, name = "STALLION_GRAY", gender = "male" } }
local BEEFMEAT = 40
FILLTYPES = { BEEFMEAT = BEEFMEAT }
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) return FILLTYPES[name] end }

local function station(price, fields)
    local s = { isSellingPoint = true, acceptedFillTypes = { [BEEFMEAT] = true } }
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

-- Slaughter value of the reported bull: 516 kg, gene 1 -> 0.794 typical x 450 kg = 357 kg beef.
local function bull(age, weight, fields)
    local a = { subTypeIndex = 1, age = age, weight = weight, gender = "male", targetWeight = 900,
        genetics = { quality = 1 }, diseases = {} }
    for k, v in pairs(fields or {}) do a[k] = v end
    return a
end
local value, kg, perKg = RLMeatValue.getSlaughterValue(bull(20, 516))
check("value: 516 kg bull -> 357 kg beef x 6.648 x 0.85 = 2018", near(kg, 357.3, 0.5) and near(perKg, 6.648)
    and near(value, 357.3 * 6.648 * 0.85, 3))
check("value: from 30 months cullShare 0.70", near(RLMeatValue.getSlaughterValue(bull(30, 516)), 357.3 * 6.648 * 0.70, 3))
check("value: under slaughterMinAgeMonth (6) -> no floor", RLMeatValue.getSlaughterValue(bull(5, 200)) == 0)
check("value: a 6-month 220 kg calf by its weight (no finish floor) -> 173 kg",
    near(select(2, RLMeatValue.getSlaughterValue(bull(6, 220))), 173, 1))
check("value: a type without meatFillType (horse) -> no floor",
    RLMeatValue.getSlaughterValue({ subTypeIndex = 2, age = 60, weight = 600, genetics = { quality = 1 } }) == 0)
FILLTYPES.BEEFMEAT = nil
check("value: the map lacks the meat fill type -> no floor", RLMeatValue.getSlaughterValue(bull(20, 516)) == 0)
FILLTYPES.BEEFMEAT = BEEFMEAT

-- Animal:getSellPrice takes the higher of the age curve and the slaughter value.
loadAnimalSection("function Animal:getSellPrice()", "function Animal:getDailyRidingTime()")
local CURVE = 1245
SUBS[1].sellPrice = { get = function() return CURVE end }
local function live(age, weight, fields)
    local a = bull(age, weight, fields)
    a.getSubType = function() return SUBS[1] end
    a.isHorse = function() return false end
    a.getHealthFactor = function() return 1 end
    return setmetatable(a, { __index = Animal })
end
RLMeatValue.resetPriceCache()
local sell = live(20, 516):getSellPrice()
check("sell: curve 1245 < slaughter value -> 2018", near(sell, 357.3 * 6.648 * 0.85, 3))
CURVE = 5000
STATIONS = {}
RLMeatValue.resetPriceCache()
local curveOnly = live(20, 516):getSellPrice()
STATIONS = { station(6.648) }
RLMeatValue.resetPriceCache()
check("sell: a curve price above the slaughter value is kept",
    curveOnly > 357.3 * 6.648 * 0.85 and near(live(20, 516):getSellPrice(), curveOnly))
CURVE = 1245
local sick = live(20, 516, { diseases = { { modifyValue = function(_, v) return v * 0.5 end } } })
check("sell: disease scales the floor too", near(sick:getSellPrice(), 357.3 * 6.648 * 0.85 * 0.5, 3))

-- Buying a finished bull to slaughter leaves at most 1 - share x markup of the meat's value.
local meatRevenue = 357.3 * 6.648
check("arbitrage: standard dealer (1.075) -> under 9% gross", (meatRevenue - sell * 1.075) / meatRevenue < 0.09)
check("arbitrage: budget dealer (1.05) -> under 11% gross", (meatRevenue - sell * 1.05) / meatRevenue < 0.11)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
