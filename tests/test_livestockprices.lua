-- Livestock price scale (RLLivestockPrices, xml/livestockPrices.xml): one factor on live prices, the
-- livestock fill types' base prices, semen and the contract slaughter fees.

XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animal/RLLivestockPrices.lua")

-- The shipped file.
local config = RLLivestockPrices.getConfig()
local listed = {}
for _, name in ipairs(config.fillTypes) do listed[name] = true end
check("config: shipped scale 3, fees x3 with it", near(config.scale, 3) and near(config.feeScale, 3)
    and near(RLLivestockPrices.getScale(), 3) and near(RLLivestockPrices.getFeeScale(), 3))
check("config: meat, milk, dairy goods, eggs, wool and semen are listed",
    listed.BEEFMEAT and listed.PORKMEAT and listed.POULTRYMEAT and listed.MILK and listed.GOATMILK and listed.CHEESE
    and listed.BUFFALOMOZZARELLA and listed.MILK_BOTTLED and listed.EGG_HB and listed.SHEEPWOOL_SHEARED and listed.BULLSPERM)
check("config: crops, feed, manure and goods also made from crops are not",
    not listed.WHEAT and not listed.SILAGE and not listed.MANURE and not listed.FABRIC and not listed.CALFMILK)
check("config: meat base prices are the calibration prices (beef 9.43, pork 4.30, lamb 14.94)",
    near(config.basePrices.BEEFMEAT, 9.43) and near(config.basePrices.PORKMEAT, 4.30) and near(config.basePrices.SHEEPGOATMEAT, 14.94)
    and near(config.basePrices.POULTRYMEAT, 9.05) and near(config.basePrices.GOOSEMEAT, 10.20) and near(config.basePrices.RABBITMEAT, 10.34)
    and config.basePrices.MILK == nil)
check("config: no file -> scale 1", near(RLLivestockPrices.parseConfig(nil).scale, 1)
    and near(RLLivestockPrices.parseConfig(nil).feeScale, 1))

-- Fill types: base price and history x scale, once; others and missing names untouched.
local FT = {
    BEEFMEAT = { pricePerLiter = 1.8, economy = { factors = { [1] = 1.0, [2] = 1.07 }, history = { [1] = 1.8, [2] = 1.926 } } },
    MILK = { pricePerLiter = 0.68, economy = { history = {} } },
    WHEAT = { pricePerLiter = 0.337, economy = { history = { [1] = 0.337 } } },
}
local manager = { getFillTypeByName = function(_, name) return FT[name] end }
RLLivestockPrices.config.basePrices = { BEEFMEAT = 9.43 }
local count = RLLivestockPrices.applyToFillTypes(manager)
check("fill types: BEEFMEAT base 1.8 -> 9.43, x3 = 28.29, history from the factors x3; MILK 0.68 -> 2.04", count == 2
    and near(FT.BEEFMEAT.pricePerLiter, 28.29) and near(FT.BEEFMEAT.economy.history[2], 9.43 * 1.07 * 3)
    and near(FT.MILK.pricePerLiter, 2.04))
check("fill types: a crop keeps its price", near(FT.WHEAT.pricePerLiter, 0.337) and near(FT.WHEAT.economy.history[1], 0.337))
RLLivestockPrices.applyToFillTypes(manager)
check("fill types: a second run does not set or scale again", near(FT.BEEFMEAT.pricePerLiter, 28.29))
FT.PORKMEAT = { pricePerLiter = 1.5, economy = { history = {} } }
RLLivestockPrices.config = { scale = 1, feeScale = 1, fillTypes = { "PORKMEAT" }, basePrices = { PORKMEAT = 4.3 } }
check("fill types: at scale 1 only the base price is set", RLLivestockPrices.applyToFillTypes(manager) == 0
    and near(FT.PORKMEAT.pricePerLiter, 4.3))

-- Contract slaughterhouse fees: (the map's fee + cutting per kg) x feeScale, also for a type sold whole.
RLLivestockPrices.config = { scale = 3, feeScale = 3, fillTypes = {} }
AnimalMoveEvent = { MOVE_SUCCESS = 0 }
TYPES = { [1] = { name = "COW" }, [2] = { name = "CHICKEN" } }
SUBS = { [1] = { typeIndex = 1, name = "BULL_ANGUS", breed = "ANGUS", gender = "male" },
         [2] = { typeIndex = 2, name = "CHICKEN_ROOSTER", breed = "CHICKEN", gender = "male" } }
g_currentMission = { animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end,
    getTypeByIndex = function(_, i) return TYPES[i] end } }
local BEEF, POULTRY, BEEFMEAT, POULTRYMEAT = 20, 22, 30, 32
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
local function recipe(input, output, amount, fee)
    return { inputs = { [input] = { amount = 1 } }, outputs = { [output] = { amount = amount } },
        primaryOutputFillTypeIndex = output, feePerBatch = fee, feeInputFillTypeIndex = input }
end
local recipes = { recipe(BEEF, BEEFMEAT, 1000, 100), recipe(POULTRY, POULTRYMEAT, 100, 5) }
local target = { spec_contractProductionService = { serviceId = "slaughterhouse", recipes = recipes },
    animalSubTypeToFillType = { [1] = BEEF, [2] = POULTRY } }
AnimalMoveEvent.alignContractRecipes(target)
check("fees: cattle (100 + 1.05 x 270) x 3 = 1150.5", near(recipes[1].feePerBatch, 1150.5))
check("fees: poultry, no cutting fee, 5 x 3 = 15", near(recipes[2].feePerBatch, 15))
AnimalMoveEvent.alignContractRecipes(target)
check("fees: a second run does not scale again", near(recipes[1].feePerBatch, 1150.5) and near(recipes[2].feePerBatch, 15))

-- Semen: the dealer's straw x3, so your own dewars' sale value (a share of it) x3 too.
DewarData = { CAPACITY = 1000, PRICE_PER_STRAW = 4.65 }
loadMod("scripts/insemination/RLSemenCollection.lua")
local sire = { success = 0.6, genetics = { metabolism = 1, quality = 1, health = 1, fertility = 1, productivity = 1 }, subTypeIndex = 1 }
local tripled = RLSemenCollection.getStrawPrice(sire, 1)
RLLivestockPrices.config = { scale = 1, feeScale = 1, fillTypes = {} }
check("semen: a straw costs 3 x its scale-1 price", tripled > 0 and near(tripled, 3 * RLSemenCollection.getStrawPrice(sire, 1)))

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end

-- The whole chain at x3: live prices, meat and fees move together, so every margin is as calibrated.
MEATCHAIN_SCALE = 3
loadMod("tests/test_meatchain.lua")
