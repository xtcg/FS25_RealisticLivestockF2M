-- Delivery to Hof Bergmann's farm butcher and public slaughterhouse (AnimalMoveEvent EPP path).

AnimalMoveEvent = { MOVE_SUCCESS = 0, MOVE_ERROR_INVALID_CLUSTER = 4, MOVE_ERROR_NOT_ENOUGH_SPACE = 6 }

TYPES = { [1] = { name = "COW" }, [2] = { name = "PIG" }, [3] = { name = "DUCKWILD" }, [4] = { name = "SHEEP" } }
SUBS = { [1] = { typeIndex = 1, targetWeight = 1000, name = "BULL_ANGUS", breed = "ANGUS", gender = "male" },
         [2] = { typeIndex = 1, targetWeight = 730, name = "COW_HOLSTEIN", breed = "HOLSTEIN", gender = "female" },
         [3] = { typeIndex = 2, targetWeight = 240, name = "PIG_LANDRACE", breed = "LANDRACE", gender = "female" },
         [4] = { typeIndex = 3, targetWeight = 3.5 }, [5] = { typeIndex = 3, targetWeight = 2.5 },
         [6] = { typeIndex = 4, targetWeight = 60, name = "GOAT", breed = "GOAT", gender = "female" },
         [7] = { typeIndex = 4, targetWeight = 55, name = "SHEEP_LANDRACE", breed = "LANDRACE", gender = "female" },
         [8] = { typeIndex = 1, targetWeight = 1200, name = "BULL_LIMOUSIN", breed = "LIMOUSIN", gender = "male" },
         [9] = { typeIndex = 1, targetWeight = 1100, name = "BULL_HOLSTEIN", breed = "HOLSTEIN", gender = "male" } }
MONEY = {}
g_currentMission = {
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    getMoney = function(_, farmId) return MONEY[farmId] or 0 end,
    addMoney = function(_, delta, farmId) MONEY[farmId] = (MONEY[farmId] or 0) + delta end,
}

XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")

local config = AnimalMoveEvent.getCarcassConfig()
check("config: shipped xml/carcassYield.xml is read",
    near(config.layers.root.qualitySwing, 0.2) and config.layers.types.COW.anchorWeight == 600
    and near(config.layers.breeds.COW.HOLSTEIN.maleMaturity, 0.59) and config.layers.breeds.SHEEP.GOAT.anchorWeight == 50 and near(config.layers.types.SHEEP.anchorWeight, 42.6667)
    and near(config.maxFinishFactor, 1.3) and near(config.sizeExponent, 0.25))

-- The chain: a standard animal x dressing to the carcass x saleable to what the map sells.
check("meat per head: cattle 600 x 0.60 x 0.75 = 270, pig 125 x 0.80 x 0.75 = 75, lamb 42.67 x 0.50 x 0.90 = 19.2",
    near(AnimalMoveEvent.getMeatPerHead("COW"), 270) and near(AnimalMoveEvent.getMeatPerHead("PIG"), 75)
    and near(AnimalMoveEvent.getMeatPerHead("SHEEP"), 19.2) and AnimalMoveEvent.getMeatPerHead("DUCKWILD") == nil)
check("meat per head: bird 3 x 0.70 x 0.90 = 1.89, goose 7 x 0.70 x 0.90 = 4.41, rabbit 3 x 0.58 x 0.90 = 1.566",
    near(AnimalMoveEvent.getMeatPerHead("CHICKEN"), 1.89) and near(AnimalMoveEvent.getMeatPerHead("GOOSE"), 4.41)
    and near(AnimalMoveEvent.getMeatPerHead("RABBIT"), 1.566))

-- The animal's own target weight defaults to its subtype's (no metabolism gene in these tests).
local function animal(sub, weight, quality, targetWeight)
    return { subTypeIndex = sub, weight = weight, gender = SUBS[sub].gender,
        targetWeight = targetWeight or SUBS[sub].targetWeight, genetics = quality and { quality = quality } or nil }
end
local function yield(a) return AnimalMoveEvent.getCarcassYieldFactor(a, nil, a.subTypeIndex) end
local function entry(a) return { animal = { subTypeIndex = a.subTypeIndex }, sourceCluster = a } end

-- Stand-in for the map's unit-based butcher addCluster (PlaceableExtendedProductionAnimalUnits):
-- whole animals of unitsPerAnimal each, read live from eppAnimalInputUnitsByFillType.
local BEEF, PIGS, POULTRY, SHEEPGOAT = 20, 21, 22, 23
-- The farm butcher's recipes: units in -> meat out (BEEF 1500 -> 900, PIGS 240 -> 150, SHEEPGOAT 160 -> 100).
local MEAT = { BEEFMEAT = 30, PORKMEAT = 31, POULTRYMEAT = 32, SHEEPGOATMEAT = 33 }
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) return MEAT[name] end }
local function production(input, inputAmount, output, outputAmount)
    return { inputs = { { type = input, amount = inputAmount } }, outputs = { { type = output, amount = outputAmount } } }
end
local function butcher(capacity, fill)
    local f = { isServer = true, animalsTypeData = {}, level = fill or 0, cap = capacity,
        animalSubTypeToFillType = { [1] = BEEF, [2] = BEEF, [3] = PIGS, [4] = POULTRY, [5] = POULTRY,
            [6] = SHEEPGOAT, [7] = SHEEPGOAT, [8] = BEEF, [9] = BEEF, [10] = BEEF },
        eppAnimalInputUnitsByFillType = { [BEEF] = 750, [PIGS] = 120, [POULTRY] = 10, [SHEEPGOAT] = 80 },
        productions = { production(BEEF, 1500, MEAT.BEEFMEAT, 900), production(PIGS, 240, MEAT.PORKMEAT, 150),
            production(SHEEPGOAT, 160, MEAT.SHEEPGOATMEAT, 100) },
        eppHasScaledAnimalInputs = true }
    function f:getCapacity() return self.cap end
    function f:getFillLevel() return self.level end
    function f:addCluster(cluster)
        local fillType = self.animalSubTypeToFillType[cluster.subTypeIndex]
        local units = self.eppAnimalInputUnitsByFillType[fillType] or 1
        local toMove = math.min(cluster.numAnimals, math.floor((self.cap - self.level) / units + 0.001))
        if toMove > 0 then
            self.level = self.level + toMove * units
            cluster:changeNumAnimals(-toMove)
        end
    end
    return f
end
local function butcherUnits(a)
    local f = butcher(1e6)
    local list = AnimalMoveEvent._deliverToEPPTarget(f, { entry(a) }, 1)
    return f.level, #list, f
end

check("yield: Angus bull at its reference (1000 x 0.60 = 600 kg) -> size 1.000 x carcass 1.06 = 1.06",
    near(yield(animal(1, 600, 1)), 1.06, 0.001))
check("yield: Limousin bull at its reference (1200 x 0.585 = 702 kg) -> 1.102", near(yield(animal(8, 702, 1)), 1.1024, 0.001))
check("yield: Holstein bull at its reference (1100 x 0.59 = 649 kg) -> 0.959", near(yield(animal(9, 649, 1)), 0.9586, 0.001))
check("yield: finish (750 / 600) ^ 0.85 for a heavy Angus -> 1.282", near(yield(animal(1, 750, 1)), 1.2818, 0.001))
check("yield: finish clamped at 1.3 for a huge Angus", near(yield(animal(1, 5000, 1)), 1.378, 0.001))
check("yield: no finish floor, a 50 kg calf yields by its weight", near(yield(animal(1, 50, 1)), (50 / 600) ^ 0.85 * 1.06, 0.001))
check("yield: meat gene 1.5 -> +10% (qualitySwing 0.2)", near(yield(animal(1, 600, 1.5)) / yield(animal(1, 600, 1)), 1.1))
check("yield: goat qualitySwing 0.12 -> +6% at gene 1.5", near(yield(animal(6, 51, 1.5)) / yield(animal(6, 51, 1)), 1.06))
check("yield: own target weight moves the reference (metabolism)",
    yield(animal(1, 800, 1, 1200)) < yield(animal(1, 800, 1)))
check("yield: 1 without an animal; no weight -> size x carcass only",
    AnimalMoveEvent.getCarcassYieldFactor(nil) == 1 and near(yield({ subTypeIndex = 1, gender = "male" }), 1.06, 0.001))

local units, count, f = butcherUnits(animal(1, 600, 1))
check("butcher: Angus bull at its reference -> 450 x 1.06 = 477", near(units, 477, 0.05) and count == 1)
check("butcher: configured units restored", f.eppAnimalInputUnitsByFillType[BEEF] == 750)

-- Hof Bergmann's insemination system: the same unit-based input, but it turns 1000 units back
-- into one live MILK_COW, so a head must stay 1000 units whatever the cow weighs.
local insemination = butcher(1e6)
insemination.eppAnimalInputUnitsByFillType = { [BEEF] = 1000 }
insemination.eao_specs = { { animals = { { inputFillTypeIndex = BEEF } } } }
AnimalMoveEvent._deliverToEPPTarget(insemination, { entry(animal(2, 450, 1)) }, 1)
check("insemination: a light Holstein is still 1000 units (not carcass-scaled)", insemination.level == 1000)
check("insemination: counted by head, not by yield",
    not AnimalMoveEvent._isWeighedTarget(insemination, nil, 2) and AnimalMoveEvent._isWeighedTarget(butcher(1), nil, 2))
check("butcher: Holstein cull cow at 621 kg, gene 1.5 -> 469.5", near(butcherUnits(animal(2, 621, 1.5)), 469.55, 0.05))
check("butcher: 120 kg Landrace gilt (target 240 x 0.446) -> 120 units x 1.060 = 127.2", near(butcherUnits(animal(3, 120, 1)), 127.21, 0.05))
check("butcher: unlisted type anchors on the facility mean target weight -> 10.39",
    near(butcherUnits(animal(4, 3.5, 1)), 10.39, 0.01))
check("butcher: 51 kg doe on the goat's own 50 kg anchor, goat carcass 0.94 -> 30.72 x 0.945 = 29.0",
    near(butcherUnits(animal(6, 51, 1)), 29.02, 0.05))
check("butcher: 46.75 kg Landrace ewe uses the SHEEP type -> 30.72 x (46.75/42.67)^0.25 = 31.43",
    near(butcherUnits(animal(7, 46.75, 1)), 30.72 * (46.75 / 42.6667) ^ 0.25, 0.05))

-- The rest checks batch, room and fee handling on a linear config: yield = live / reference x
-- (1 + 0.25 x (gene - 1)), fixed references COW 650 and PIG 120.
local shipped = AnimalMoveEvent.carcassConfig
AnimalMoveEvent.carcassConfig = { sizeExponent = 0, minSizeFactor = 1, maxSizeFactor = 1, finishExponent = 1,
    minFinishFactor = 0.1, maxFinishFactor = 2.5,
    layers = { root = { qualitySwing = 0.25 }, breeds = { COW = { ANGUS = { carcassFactor = 1.1 } } }, subTypes = {},
        types = { COW = { referenceWeight = 650, anchorWeight = 650 }, PIG = { referenceWeight = 120, anchorWeight = 120 } } } }
check("config: breed value beats type", near(yield(animal(1, 650, 1)), 1.1))
AnimalMoveEvent.carcassConfig.layers.subTypes.BULL_ANGUS = { carcassFactor = 1.2 }
check("config: subtype value beats breed", near(yield(animal(1, 650, 1)), 1.2))
AnimalMoveEvent.carcassConfig.layers.breeds.COW = {}
AnimalMoveEvent.carcassConfig.layers.subTypes = {}
check("config: fixed referenceWeight replaces target x maturity", near(butcherUnits(animal(1, 900, 1)), 1038.46))

local heavy = butcher(2000)
list = AnimalMoveEvent._deliverToEPPTarget(heavy, { entry(animal(1, 900, 1)), entry(animal(1, 900, 1)) }, 1)
check("butcher: two 1038-unit bulls into 2000 of room -> whole batch refused, nothing stored",
    #list == 0 and heavy.level == 0)

local full = butcher(1500, 1000)
local list, abort = AnimalMoveEvent._deliverToEPPTarget(full, { entry(animal(1, 650, 1)) }, 1)
check("butcher: no room for a whole carcass -> refused, nothing stored",
    #list == 0 and full.level == 1000 and abort == AnimalMoveEvent.EPP_NOT_ACCEPTED)

-- Slaughterhouse: order buffer and per-batch fee as in PlaceableContractProductionService.
local function slaughterhouse(orderFarm, feePerBatch, capacity, buffered)
    local recipe = { inputs = { [BEEF] = { amount = 1 } }, feeInputFillTypeIndex = BEEF, feePerBatch = feePerBatch or 0 }
    local order = { farmId = orderFarm, recipeId = "beef", feeCredit = 0, inputs = { [BEEF] = { buffered = buffered or 0 } } }
    local input = order.inputs[BEEF]
    local t = { isServer = true, animalsTypeData = {}, animalSubTypeToFillType = { [1] = BEEF, [2] = BEEF },
        spec_contractProductionService = { orders = orderFarm and { order } or {}, recipeById = { beef = recipe } },
        order = input, refreshed = 0 }
    function t:getCapacity() return capacity or 100 end
    function t:contractProductionGetAnimalFreeSlots(farmId)
        if orderFarm ~= farmId then return 0 end
        local free = (capacity or 100) - math.ceil(input.buffered)
        if recipe.feePerBatch > 0 then free = math.min(free, math.floor(math.max(MONEY[farmId] or 0, 0) / recipe.feePerBatch + 1e-6)) end
        return free
    end
    function t:contractProductionDeliver(farmId, fillType, amount)
        if orderFarm ~= farmId then return 0 end
        local accepted = amount
        if recipe.feePerBatch > 0 then
            accepted = math.min(accepted, math.max(MONEY[farmId] or 0, 0) / recipe.feePerBatch)
            g_currentMission:addMoney(-accepted * recipe.feePerBatch, farmId)
        end
        input.buffered = input.buffered + accepted
        return accepted
    end
    function t:contractProductionAddAnimals() error("per-head path must not be used") end
    function t:contractProductionRefreshAnimalVisuals() self.refreshed = self.refreshed + 1 end
    function t:addCluster() error("addCluster must not be used when the farm is known") end
    return t
end

MONEY[2] = 10000
local s = slaughterhouse(2, 100)
list, abort = AnimalMoveEvent._deliverToEPPTarget(s, { entry(animal(1, 900, 1)), entry(animal(2, 575, 1.5)) }, 2)
check("slaughterhouse: bull + cow buffered as 2.380 animal-equivalents", #list == 2 and abort == nil and near(s.order.buffered, 2.380))
check("slaughterhouse: fee scales with yield (237.98)", near(10000 - MONEY[2], 237.98))
check("slaughterhouse: visuals refreshed per animal", s.refreshed == 2)

MONEY[2] = 120
s = slaughterhouse(2, 100)
list, abort = AnimalMoveEvent._deliverToEPPTarget(s, { entry(animal(1, 900, 1)) }, 2)
check("slaughterhouse: can pay one head but not 1.385 -> refused, nothing charged",
    #list == 0 and abort == AnimalMoveEvent.EPP_NOT_ACCEPTED and MONEY[2] == 120 and s.order.buffered == 0)
list, abort = AnimalMoveEvent._deliverToEPPTarget(slaughterhouse(nil, 0), { entry(animal(1, 650, 1)) }, 2)
check("slaughterhouse: no open order -> refused", #list == 0 and abort == AnimalMoveEvent.EPP_NOT_ACCEPTED)

MONEY[2] = 10000
s = slaughterhouse(2, 100, 10, 7)
list, abort = AnimalMoveEvent._deliverToEPPTarget(s,
    { entry(animal(1, 900, 1)), entry(animal(1, 900, 1)), entry(animal(1, 900, 1)) }, 2)
check("slaughterhouse: 3 heads fit the slots but 4.15 yield does not fit 3 of room -> whole batch refused",
    #list == 0 and abort == AnimalMoveEvent.EPP_NOT_ACCEPTED and s.order.buffered == 7 and MONEY[2] == 10000)

s = slaughterhouse(2, 100, 10, 8.5)
list, abort = AnimalMoveEvent._deliverToEPPTarget(s, { entry(animal(2, 455, 1)), entry(animal(2, 455, 1)) }, 2)
check("slaughterhouse: two 0.7 animals into 1.5 of room (1 whole slot) -> both taken",
    #list == 2 and abort == nil and near(s.order.buffered, 9.9))

-- Two open orders (beef $100, pork $50 per batch), each with its own fee credit, sharing the
-- farm's money - as PlaceableContractProductionService.contractProductionDeliver charges it.
local function mixedSlaughterhouse(beefCredit, porkCredit)
    local recipes = {
        beef = { inputs = { [BEEF] = { amount = 1 } }, feeInputFillTypeIndex = BEEF, feePerBatch = 100 },
        pork = { inputs = { [PIGS] = { amount = 1 } }, feeInputFillTypeIndex = PIGS, feePerBatch = 50 } }
    local orders = {
        { id = 1, farmId = 3, recipeId = "beef", feeCredit = beefCredit or 0, inputs = { [BEEF] = { buffered = 0 } } },
        { id = 2, farmId = 3, recipeId = "pork", feeCredit = porkCredit or 0, inputs = { [PIGS] = { buffered = 0 } } } }
    local t = { isServer = true, animalsTypeData = {}, animalSubTypeToFillType = { [1] = BEEF, [2] = BEEF, [3] = PIGS },
        spec_contractProductionService = { orders = orders, recipeById = recipes }, orders = orders }
    local function orderFor(fillType) return fillType == BEEF and orders[1] or orders[2] end
    function t:getCapacity() return 100 end
    function t:contractProductionGetAnimalFreeSlots(farmId, subTypeIndex) return farmId == 3 and 100 or 0 end
    function t:contractProductionDeliver(farmId, fillType, amount)
        local order = orderFor(fillType)
        local recipe = recipes[order.recipeId]
        local budget = math.max(MONEY[farmId] or 0, 0) + order.feeCredit
        local accepted = math.min(amount, budget / recipe.feePerBatch)
        local fee = accepted * recipe.feePerBatch
        local credit = math.min(order.feeCredit, fee)
        order.feeCredit = order.feeCredit - credit
        g_currentMission:addMoney(-(fee - credit), farmId)
        order.inputs[fillType].buffered = order.inputs[fillType].buffered + accepted
        return accepted
    end
    function t:contractProductionAddAnimals() error("per-head path must not be used") end
    return t
end
local cowAndPigs = function() return { entry(animal(2, 650, 1)), entry(animal(3, 120, 1)), entry(animal(3, 120, 1)) } end

MONEY[3] = 150
local mixed = mixedSlaughterhouse()
list, abort = AnimalMoveEvent._deliverToEPPTarget(mixed, cowAndPigs(), 3)
check("slaughterhouse: $150 pays the cow ($100) or the pigs ($100) but not both -> whole batch refused",
    #list == 0 and abort == AnimalMoveEvent.EPP_NOT_ACCEPTED and MONEY[3] == 150
    and mixed.orders[1].inputs[BEEF].buffered == 0 and mixed.orders[2].inputs[PIGS].buffered == 0)

MONEY[3] = 200
mixed = mixedSlaughterhouse()
list, abort = AnimalMoveEvent._deliverToEPPTarget(mixed, cowAndPigs(), 3)
check("slaughterhouse: $200 pays cow and pigs -> all taken, $200 charged", #list == 3 and abort == nil and near(MONEY[3], 0))

MONEY[3] = 60
mixed = mixedSlaughterhouse(100, 0)
list, abort = AnimalMoveEvent._deliverToEPPTarget(mixed, cowAndPigs(), 3)
check("slaughterhouse: beef credit pays the cow, $60 does not cover the pigs' $100 -> refused",
    #list == 0 and MONEY[3] == 60 and mixed.orders[1].feeCredit == 100)

MONEY[3] = 100
mixed = mixedSlaughterhouse(100, 0)
list, abort = AnimalMoveEvent._deliverToEPPTarget(mixed, cowAndPigs(), 3)
check("slaughterhouse: beef credit pays the cow, $100 the pigs -> all taken",
    #list == 3 and abort == nil and near(MONEY[3], 0) and near(mixed.orders[1].feeCredit, 0))

MONEY[3] = 40
mixed = mixedSlaughterhouse(500, 0)
list = AnimalMoveEvent._deliverToEPPTarget(mixed, cowAndPigs(), 3)
check("slaughterhouse: one order's credit does not pay another order's fee", #list == 0 and MONEY[3] == 40)

check("weighed targets: contract with a farm, scaled butcher; not a contract without one",
    AnimalMoveEvent._isWeighedTarget(s, 2) and AnimalMoveEvent._isWeighedTarget(butcher(1), nil)
    and not AnimalMoveEvent._isWeighedTarget(slaughterhouse(2, 0), nil))

-- Getter-style addCluster without a known farm (the shim must answer getters too).
local getterStyle = { animalsTypeData = {}, credited = 0 }
function getterStyle:addCluster(cluster)
    self.credited = self.credited + cluster:getNumAnimals()
    assert(cluster:getSubTypeIndex() == 1)
    cluster:changeNumAnimals(-cluster:getNumAnimals())
end
list = AnimalMoveEvent._deliverToEPPTarget(getterStyle, { entry(animal(1, 650, 1)) }, nil)
check("shim answers getSubTypeIndex/getNumAnimals", #list == 1 and getterStyle.credited == 1)

check("weight ratio clamped at 2.5", near(yield(animal(1, 5000, 1)), 2.5))
AnimalMoveEvent.carcassConfig = shipped

-- Contract recipes rescaled to the farm butcher's meat per typical animal (animalType#meatPerHead).
local BEEFMEAT, PORKMEAT, POULTRYMEAT, SHEEPMEAT, WASTE = 30, 31, 32, 33, 34
local function contractRecipes(subTypeToFillType)
    local function recipe(id, input, output, amount, extra)
        local r = { id = id, inputs = { [input] = { amount = 1 } }, outputs = { [output] = { amount = amount } },
            primaryOutputFillTypeIndex = output, feePerBatch = 100, feeInputFillTypeIndex = input }
        if extra ~= nil then r.outputs[WASTE] = { amount = extra } end
        return r
    end
    local recipes = { recipe("beef", BEEF, BEEFMEAT, 1000), recipe("pork", PIGS, PORKMEAT, 500),
        recipe("poultry", POULTRY, POULTRYMEAT, 100), recipe("sheep", SHEEPGOAT, SHEEPMEAT, 400, 80) }
    return { spec_contractProductionService = { serviceId = "slaughterhouse", recipes = recipes },
        animalSubTypeToFillType = subTypeToFillType or { [1] = BEEF, [2] = BEEF, [3] = PIGS, [4] = POULTRY,
            [5] = POULTRY, [6] = SHEEPGOAT, [7] = SHEEPGOAT } }, recipes
end

local target, recipes = contractRecipes()
check("contract recipes: beef, pork and sheep rescaled; a type without meatPerHead left alone",
    AnimalMoveEvent.alignContractRecipes(target) == 3)
check("contract recipes: 1 cow -> 270 kg, 1 pig -> 75 kg, like the farm butcher",
    near(recipes[1].outputs[BEEFMEAT].amount, 270) and near(recipes[2].outputs[PORKMEAT].amount, 75))
check("contract recipes: fine cutting per kg added to the batch fee: cattle 100 + 0.37 x 270, pork 100 + 0.60 x 75",
    near(recipes[1].feePerBatch, 199.9) and near(recipes[2].feePerBatch, 145))
check("contract recipes: DUCKWILD (no meatPerHead) keeps 100", recipes[3].outputs[POULTRYMEAT].amount == 100)
check("contract recipes: sheep 400 -> 19.2 kg, its other output scaled by the same factor",
    near(recipes[4].outputs[SHEEPMEAT].amount, 19.2) and near(recipes[4].outputs[WASTE].amount, 3.84))
AnimalMoveEvent.alignContractRecipes(target)
check("contract recipes: a second run does not scale again",
    near(recipes[1].outputs[BEEFMEAT].amount, 270) and near(recipes[4].outputs[WASTE].amount, 3.84) and near(recipes[1].feePerBatch, 199.9))

target, recipes = contractRecipes({ [1] = BEEF, [3] = BEEF })
check("contract recipes: a fill type taken by two animal types is left alone",
    AnimalMoveEvent.alignContractRecipes(target) == 0 and recipes[1].outputs[BEEFMEAT].amount == 1000)
-- Hof Bergmann 1.5 Beta2 maps COW and its MILKCOW placeholder type (no carcass config) to BEEF.
TYPES[5] = { name = "MILKCOW" }
SUBS[11] = { typeIndex = 5, targetWeight = 730, name = "MILK_COW", breed = "MILK_COW", gender = "female" }
target, recipes = contractRecipes({ [1] = BEEF, [2] = BEEF, [11] = BEEF, [3] = PIGS })
check("contract recipes: BEEF also taken by MILKCOW (no meat per head) -> cattle recipe still 270 kg, fee 199.9",
    AnimalMoveEvent.alignContractRecipes(target) == 2 and near(recipes[1].outputs[BEEFMEAT].amount, 270)
    and near(recipes[1].feePerBatch, 199.9))
TYPES[5], SUBS[11] = nil, nil
check("contract recipes: a placeable without the contract spec is ignored",
    AnimalMoveEvent.alignContractRecipes({}) == 0 and AnimalMoveEvent.alignContractRecipes(nil) == 0)

-- The reported Swiss Brown bull: 516 kg, average meat gene, target 1000 kg -> 0.79 typical animals.
SUBS[10] = { typeIndex = 1, targetWeight = 1000, name = "BULL_SWISS_BROWN", breed = "SWISS_BROWN", gender = "male" }
local bull = yield(animal(10, 516, 1))
check("Swiss Brown bull 516 kg: 0.85 typical animals, 228 kg of beef at either facility",
    near(bull, 0.8453, 0.002) and near(butcherUnits(animal(10, 516, 1)) * 0.6, bull * 270, 0.05))

for _, line in ipairs(LOG) do
    if line:find("^safeCall") then check("no script error: " .. line, false) end
end
