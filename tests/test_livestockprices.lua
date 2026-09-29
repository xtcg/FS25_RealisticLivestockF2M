-- Livestock products at a fixed difficulty (RLLivestockPrices, xml/livestockPrices.xml): on HARD with
-- reference EASY the listed fill types sell as on EASY, and live animals are priced as on EASY.

XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

-- The game's difficulty and multipliers (EconomyManager, v1.23.1).
local DIFFICULTY = 3
EconomyManager = { PRICE_MULTIPLIER = { 3, 1.8, 1 } }
function EconomyManager.getPriceMultiplier() return EconomyManager.PRICE_MULTIPLIER[DIFFICULTY] end
function EconomyManager:getPricePerLiter(fillTypeIndex, useMultiplier)
    local price = ECONOMY_PRICE[fillTypeIndex] or 0
    return useMultiplier == false and price or price * EconomyManager.getPriceMultiplier()
end
ECONOMY_PRICE = {}

-- A selling point as the game computes it: base price x season x the difficulty multiplier.
SellingStation = {}
function SellingStation:getEffectiveFillTypePrice(fillType)
    if not self.isServer then return self.fillTypePrices[fillType] end
    return self.fillTypePrices[fillType] * (SEASON or 1) * EconomyManager.getPriceMultiplier()
end
Utils = { overwrittenFunction = function(old, new)
    return function(self, ...) return new(self, old, ...) end
end }

local BEEFMEAT, MILK, WHEAT = 40, 41, 42
local NAMES = { [BEEFMEAT] = "BEEFMEAT", [MILK] = "MILK", [WHEAT] = "WHEAT" }
g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return NAMES[i] end,
    getFillTypeIndexByName = function(_, name) for i, n in pairs(NAMES) do if n == name then return i end end end,
    getFillTypeByIndex = function(_, i)
        if i == BEEFMEAT then return { pricePerLiter = 1.8, economy = { factors = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 } } } end
    end,
}

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animal/RLLivestockPrices.lua")

local config = RLLivestockPrices.getConfig()
check("config: shipped reference difficulty EASY", config.difficulty == 1)
check("config: meat, milk, dairy goods, eggs, wool and semen are listed",
    config.fillTypes.BEEFMEAT and config.fillTypes.PORKMEAT and config.fillTypes.POULTRYMEAT and config.fillTypes.MILK
    and config.fillTypes.CHEESE and config.fillTypes.BUFFALOMOZZARELLA and config.fillTypes.EGG_HB
    and config.fillTypes.SHEEPWOOL_SHEARED and config.fillTypes.BULLSPERM)
check("config: crops, feed, manure and goods also made from crops are not",
    not config.fillTypes.WHEAT and not config.fillTypes.SILAGE and not config.fillTypes.MANURE
    and not config.fillTypes.FABRIC and not config.fillTypes.CALFMILK)
check("config: no file or GAME -> the game's difficulty", RLLivestockPrices.parseConfig(nil).difficulty == nil)

-- Multipliers.
DIFFICULTY = 3
check("HARD: beef and milk at EASY's x3, wheat at HARD's x1",
    RLLivestockPrices.getPriceMultiplier(BEEFMEAT) == 3 and RLLivestockPrices.getPriceMultiplier(MILK) == 3
    and RLLivestockPrices.getPriceMultiplier(WHEAT) == 1 and RLLivestockPrices.getFactor(WHEAT) == 1)
DIFFICULTY = 2
check("NORMAL: beef x3 (factor 3 / 1.8), wheat x1.8", near(RLLivestockPrices.getFactor(BEEFMEAT), 3 / 1.8)
    and near(RLLivestockPrices.getPriceMultiplier(WHEAT), 1.8))
DIFFICULTY = 1
check("EASY: nothing changes", RLLivestockPrices.getFactor(BEEFMEAT) == 1 and RLLivestockPrices.getFactor(WHEAT) == 1)

-- Selling points and the economy price.
local function station(isServer)
    return setmetatable({ isServer = isServer, fillTypePrices = { [BEEFMEAT] = 1.8, [WHEAT] = 0.337 } },
        { __index = SellingStation })
end
local server = station(true)
DIFFICULTY = 1
local easyBeef = server:getEffectiveFillTypePrice(BEEFMEAT)
DIFFICULTY = 3
check("station: beef on HARD pays what it pays on EASY (5.4)", near(server:getEffectiveFillTypePrice(BEEFMEAT), easyBeef)
    and near(easyBeef, 5.4))
check("station: wheat on HARD keeps HARD's price", near(server:getEffectiveFillTypePrice(WHEAT), 0.337))
check("station: a client shows the price the server sent, unchanged", station(false):getEffectiveFillTypePrice(BEEFMEAT) == 1.8)
ECONOMY_PRICE = { [BEEFMEAT] = 1.8, [WHEAT] = 0.337 }
check("economy price: beef x3 on HARD (farm shop), wheat x1, unmultiplied stays unmultiplied",
    near(EconomyManager:getPricePerLiter(BEEFMEAT), 5.4) and near(EconomyManager:getPricePerLiter(WHEAT), 0.337)
    and near(EconomyManager:getPricePerLiter(BEEFMEAT, false), 1.8))

-- A bull: live price on HARD with reference EASY is its live price on EASY, at any beef price.
AnimalMoveEvent = { MOVE_SUCCESS = 0 }
TYPES = { [1] = { name = "COW" } }
SUBS = { [1] = { typeIndex = 1, targetWeight = 1000, minWeight = 40, reproductionMinAgeMonth = 12,
    name = "BULL_SWISS_BROWN", breed = "SWISS_BROWN", gender = "male", sellPrice = { get = function() return 1900 end } } }
STATIONS = {}
g_currentMission = {
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    storageSystem = { getUnloadingStations = function() return STATIONS end },
    economyManager = EconomyManager,
}
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadMod("scripts/animal/RLMeatValue.lua")
loadAnimalSection("function Animal:getSellPrice()", "function Animal:getDailyRidingTime()")
local bull = setmetatable({ subTypeIndex = 1, age = 20, weight = 620, gender = "male", targetWeight = 1000,
    genetics = { quality = 1, metabolism = 1 }, diseases = {}, isCastrated = false }, { __index = Animal })
bull.getSubType = function() return SUBS[1] end
bull.isHorse = function() return false end
bull.getHealthFactor = function() return 1 end

local function livePrice(difficulty, reference, mapBeef, season)
    DIFFICULTY, SEASON = difficulty, season
    RLLivestockPrices.config.difficulty = reference
    local s = station(true)
    s.isSellingPoint, s.acceptedFillTypes = true, { [BEEFMEAT] = true }
    s.fillTypePrices[BEEFMEAT] = mapBeef
    s.originalFillTypePrices = { [BEEFMEAT] = mapBeef }
    STATIONS = { s }
    RLMeatValue.resetPriceCache()
    return bull:getSellPrice(), RLMeatValue.getMeatPrice(BEEFMEAT)
end
for _, mapBeef in ipairs({ 1.8, 9.43 }) do
    for _, season in ipairs({ 0.81, 1.0, 1.21 }) do
        local easy, easyMeat = livePrice(1, nil, mapBeef, season)
        local hard, hardMeat = livePrice(3, 1, mapBeef, season)
        local plainHard = livePrice(3, nil, mapBeef, season)
        check(string.format("bull: map beef %.2f, season x%.2f: HARD = EASY (%.0f = %.0f, beef %.2f = %.2f; plain HARD %.0f)",
            mapBeef, season, hard, easy, hardMeat, easyMeat, plainHard), near(hard, easy, 0.01) and near(hardMeat, easyMeat))
    end
end
local easy = livePrice(1, nil, 9.43, 1.21)
local plainHard = livePrice(3, nil, 9.43, 1.21)
check("bull: on plain HARD the same bull sells for less (meat floor at a third)", plainHard < easy * 0.9)
SEASON = nil

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
