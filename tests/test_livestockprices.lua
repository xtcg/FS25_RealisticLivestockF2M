-- Livestock prices follow the difficulty (RLLivestockPrices): HARD is the calibration level (x1), NORMAL
-- x1.8 and EASY x3, like the game's own meat and milk prices, with the same margins.

XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

local DIFFICULTY = 3
EconomyManager = { PRICE_MULTIPLIER = { 3, 1.8, 1 } }
function EconomyManager.getPriceMultiplier() return EconomyManager.PRICE_MULTIPLIER[DIFFICULTY] end
Utils = { appendedFunction = function(old, new) return function(...) old(...); new(...) end end }
FSBaseMission = { setEconomicDifficulty = function(self, difficulty) DIFFICULTY = difficulty end }

AnimalMoveEvent = { MOVE_SUCCESS = 0 }
TYPES = { [1] = { name = "COW" }, [2] = { name = "CHICKEN" } }
SUBS = { [1] = { typeIndex = 1, name = "BULL_ANGUS", breed = "ANGUS", gender = "male" },
         [2] = { typeIndex = 2, name = "CHICKEN_ROOSTER", breed = "CHICKEN", gender = "male" } }
local BEEF, POULTRY, BEEFMEAT, POULTRYMEAT = 20, 22, 30, 32
local function recipe(input, output, amount, fee)
    return { inputs = { [input] = { amount = 1 } }, outputs = { [output] = { amount = amount } },
        primaryOutputFillTypeIndex = output, feePerBatch = fee, feeInputFillTypeIndex = input }
end
local recipes = { recipe(BEEF, BEEFMEAT, 1000, 100), recipe(POULTRY, POULTRYMEAT, 100, 5) }
local slaughterhouse = { spec_contractProductionService = { serviceId = "slaughterhouse", recipes = recipes },
    animalSubTypeToFillType = { [1] = BEEF, [2] = POULTRY } }
g_currentMission = { missionInfo = {},
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    placeableSystem = { placeables = { slaughterhouse, {} } } }

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadMod("scripts/animal/RLLivestockPrices.lua")

check("multiplier: HARD x1 (the calibration level)", RLLivestockPrices.getMultiplier() == 1)
DIFFICULTY = 2
check("multiplier: NORMAL x1.8", near(RLLivestockPrices.getMultiplier(), 1.8))
DIFFICULTY = 1
check("multiplier: EASY x3", near(RLLivestockPrices.getMultiplier(), 3))

-- Contract slaughter fees: patched at load, re-applied when the difficulty changes in game.
DIFFICULTY = 3
AnimalMoveEvent.alignContractRecipes(slaughterhouse)
check("fees HARD: cattle 100 + 1.05 x 270 = 383.5, poultry the map's 5",
    near(recipes[1].feePerBatch, 383.5) and near(recipes[2].feePerBatch, 5))
FSBaseMission.setEconomicDifficulty(g_currentMission, 1)
check("fees EASY after a change in game: x3 (1150.5, 15)", near(recipes[1].feePerBatch, 1150.5) and near(recipes[2].feePerBatch, 15))
FSBaseMission.setEconomicDifficulty(g_currentMission, 2)
check("fees NORMAL: x1.8 (690.3, 9)", near(recipes[1].feePerBatch, 690.3) and near(recipes[2].feePerBatch, 9))
FSBaseMission.setEconomicDifficulty(g_currentMission, 3)
check("fees back on HARD: the shipped fees again", near(recipes[1].feePerBatch, 383.5) and near(recipes[2].feePerBatch, 5)
    and near(recipes[1].outputs[BEEFMEAT].amount, 270))

-- Semen: the dealer's straw (and so a dewar's sale value) x the multiplier.
DewarData = { CAPACITY = 1000, PRICE_PER_STRAW = 4.65 }
loadMod("scripts/insemination/RLSemenCollection.lua")
local sire = { success = 0.6, genetics = { metabolism = 1, quality = 1, health = 1, fertility = 1, productivity = 1 }, subTypeIndex = 1 }
local hard = RLSemenCollection.getStrawPrice(sire, 1)
DIFFICULTY = 1
check("semen: a straw on EASY is 3 x HARD's", hard > 0 and near(RLSemenCollection.getStrawPrice(sire, 1), 3 * hard))
DIFFICULTY = 3

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end

-- The whole chain on NORMAL and EASY: meat (the game's multiplier), live prices and fees (the mod's)
-- move together, so every margin is the calibrated one and every live price is x1.8 / x3 of HARD's.
MEATCHAIN_LIVE = {}
for _, multiplier in ipairs({ 1, 1.8, 3 }) do
    MEATCHAIN_MULTIPLIER = multiplier
    loadMod("tests/test_meatchain.lua")
end
local worst = 0
for name, price in pairs(MEATCHAIN_LIVE) do
    local multiplier, sub = name:match("^x([%d%.]+) (.+)$")
    if multiplier ~= nil then worst = math.max(worst, math.abs(price / (MEATCHAIN_LIVE[sub] * tonumber(multiplier)) - 1)) end
end
check(string.format("live prices: every finished animal x1.8 on NORMAL and x3 on EASY of its HARD price (worst %.4f%%)", worst * 100),
    worst < 1e-6 and next(MEATCHAIN_LIVE) ~= nil)
