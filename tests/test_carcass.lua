-- Delivery to Hof Bergmann's farm butcher and public slaughterhouse (AnimalMoveEvent EPP path).

AnimalMoveEvent = { MOVE_SUCCESS = 0, MOVE_ERROR_INVALID_CLUSTER = 4, MOVE_ERROR_NOT_ENOUGH_SPACE = 6 }

TYPES = { [1] = { name = "COW" }, [2] = { name = "PIG" }, [3] = { name = "DUCKWILD" }, [4] = { name = "SHEEP" } }
SUBS = { [1] = { typeIndex = 1, targetWeight = 900, name = "BULL_ANGUS", breed = "ANGUS" },
         [2] = { typeIndex = 1, targetWeight = 575, name = "COW_HOLSTEIN", breed = "HOLSTEIN" },
         [3] = { typeIndex = 2, targetWeight = 165 }, [4] = { typeIndex = 3, targetWeight = 3.5 },
         [5] = { typeIndex = 3, targetWeight = 2.5 },
         [6] = { typeIndex = 4, targetWeight = 30, name = "GOAT", breed = "GOAT" },
         [7] = { typeIndex = 4, targetWeight = 45, name = "SHEEP_LANDRACE", breed = "LANDRACE" } }
MONEY = {}
g_currentMission = {
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    getMoney = function(_, farmId) return MONEY[farmId] or 0 end,
    addMoney = function(_, delta, farmId) MONEY[farmId] = (MONEY[farmId] or 0) + delta end,
}

-- XMLFile over the flat, two-level carcassYield.xml: root attributes, animalType (with breed
-- children) and subType elements, addressed with the engine's "parent.child(i)#attr" keys.
local function attributes(text)
    local attrs = {}
    for name, value in text:gmatch('([%w_]+)="([^"]*)"') do attrs[name] = value end
    return attrs
end
local function fakeXMLFile(path)
    local handle = io.open(path, "r")
    if handle == nil then return nil end
    local text = handle:read("a"):gsub("<!%-%-.-%-%->", "")
    handle:close()
    local nodes, counts = {}, {}
    local function add(parent, child, attrs)
        local i = counts[parent .. "." .. child] or 0
        counts[parent .. "." .. child] = i + 1
        local key = string.format("%s.%s(%d)", parent, child, i)
        nodes[key] = attrs
        return key
    end
    nodes.carcassYield = attributes(text:match("<carcassYield([^>]*)>"))
    for element, attrText, rest in text:gmatch("<(%a+)([^>]-)(/?)>") do
        if element == "animalType" then
            nodes.lastType = add("carcassYield", "animalType", attributes(attrText))
        elseif element == "breed" then
            add(nodes.lastType, "breed", attributes(attrText))
        elseif element == "subType" then
            add("carcassYield", "subType", attributes(attrText))
        end
    end
    local function get(key)
        local node, attr = key:match("^(.*)#(.*)$")
        return nodes[node] ~= nil and nodes[node][attr] or nil
    end
    return {
        getString = function(_, key, default) return get(key) or default end,
        getFloat = function(_, key, default) return tonumber(get(key)) or default end,
        iterate = function(_, key, fn)
            for i = 0, (counts[key] or 0) - 1 do fn(i, string.format("%s(%d)", key, i)) end
        end,
        delete = function() end,
    }
end
XMLFile = { loadIfExists = function(_, path) return fakeXMLFile(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")

local config = AnimalMoveEvent.getCarcassConfig()
check("config: shipped xml/carcassYield.xml is read",
    near(config.qualitySwing, 0.25) and config.types.COW == 750 and config.types.PIG == 120
    and config.breeds.SHEEP.GOAT == 32 and near(config.maxWeightRatio, 2.5))

local function animal(sub, weight, quality)
    return { subTypeIndex = sub, weight = weight, genetics = quality and { quality = quality } or nil }
end
local function entry(a) return { animal = { subTypeIndex = a.subTypeIndex }, sourceCluster = a } end

-- Stand-in for the map's unit-based butcher addCluster (PlaceableExtendedProductionAnimalUnits):
-- whole animals of unitsPerAnimal each, read live from eppAnimalInputUnitsByFillType.
local BEEF, PIGS, POULTRY, SHEEPGOAT = 20, 21, 22, 23
local function butcher(capacity, fill)
    local f = { isServer = true, animalsTypeData = {}, level = fill or 0, cap = capacity,
        animalSubTypeToFillType = { [1] = BEEF, [2] = BEEF, [3] = PIGS, [4] = POULTRY, [5] = POULTRY,
            [6] = SHEEPGOAT, [7] = SHEEPGOAT },
        eppAnimalInputUnitsByFillType = { [BEEF] = 750, [PIGS] = 120, [POULTRY] = 10, [SHEEPGOAT] = 80 },
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

local units, count, f = butcherUnits(animal(1, 750, 1))
check("butcher: 750 kg average-gene cow = configured 750", near(units, 750) and count == 1)
check("butcher: configured units restored", f.eppAnimalInputUnitsByFillType[BEEF] == 750)
check("butcher: 900 kg Angus bull -> 900", near(butcherUnits(animal(1, 900, 1)), 900))
check("butcher: 575 kg Holstein cow -> 575", near(butcherUnits(animal(2, 575, 1)), 575))
check("butcher: same cow, meat gene 1.5 -> 646.9", near(butcherUnits(animal(2, 575, 1.5)), 646.875))
check("butcher: 110 kg finishing pig -> 110", near(butcherUnits(animal(3, 110, 1)), 110))
check("butcher: unlisted type falls back to the mean target weight", near(butcherUnits(animal(4, 3.5, 1)), 11.67))
check("butcher: 32 kg goat uses the GOAT breed reference -> 80", near(butcherUnits(animal(6, 32, 1)), 80))
check("butcher: 50 kg sheep uses the SHEEP type reference -> 80", near(butcherUnits(animal(7, 50, 1)), 80))

local shipped = AnimalMoveEvent.carcassConfig
AnimalMoveEvent.carcassConfig = { qualitySwing = 0.1, minWeightRatio = 0.1, maxWeightRatio = 2.5,
    types = { COW = 650 }, breeds = { COW = { ANGUS = 900 } }, subTypes = { COW_HOLSTEIN = 575 } }
check("config: breed reference beats type (900 kg Angus -> 750)", near(butcherUnits(animal(1, 900, 1)), 750))
check("config: subtype reference beats type (575 kg Holstein -> 750)", near(butcherUnits(animal(2, 575, 1)), 750))
check("config: qualitySwing read from config (gene 1.5 -> 1.05)", near(butcherUnits(animal(2, 575, 1.5)), 787.5))
AnimalMoveEvent.carcassConfig = shipped

local heavy = butcher(1700)
list = AnimalMoveEvent._deliverToEPPTarget(heavy, { entry(animal(1, 900, 1)), entry(animal(1, 900, 1)) }, 1)
check("butcher: two 900-unit bulls into 1700 of room -> whole batch refused, nothing stored",
    #list == 0 and heavy.level == 0)

local full = butcher(1500, 1000)
local list, abort = AnimalMoveEvent._deliverToEPPTarget(full, { entry(animal(1, 750, 1)) }, 1)
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
check("slaughterhouse: bull + cow buffered as 1.2 + 0.8625 = 2.0625 animal-equivalents", #list == 2 and abort == nil and near(s.order.buffered, 2.0625))
check("slaughterhouse: fee scales with yield (206.25)", near(10000 - MONEY[2], 206.25))
check("slaughterhouse: visuals refreshed per animal", s.refreshed == 2)

MONEY[2] = 110
s = slaughterhouse(2, 100)
list, abort = AnimalMoveEvent._deliverToEPPTarget(s, { entry(animal(1, 900, 1)) }, 2)
check("slaughterhouse: can pay one head but not 1.2 -> refused, nothing charged",
    #list == 0 and abort == AnimalMoveEvent.EPP_NOT_ACCEPTED and MONEY[2] == 110 and s.order.buffered == 0)
list, abort = AnimalMoveEvent._deliverToEPPTarget(slaughterhouse(nil, 0), { entry(animal(1, 750, 1)) }, 2)
check("slaughterhouse: no open order -> refused", #list == 0 and abort == AnimalMoveEvent.EPP_NOT_ACCEPTED)

MONEY[2] = 10000
s = slaughterhouse(2, 100, 10, 7)
list, abort = AnimalMoveEvent._deliverToEPPTarget(s,
    { entry(animal(1, 900, 1)), entry(animal(1, 900, 1)), entry(animal(1, 900, 1)) }, 2)
check("slaughterhouse: 3 heads fit the slots but 3.6 yield does not fit 3 of room -> whole batch refused",
    #list == 0 and abort == AnimalMoveEvent.EPP_NOT_ACCEPTED and s.order.buffered == 7 and MONEY[2] == 10000)

s = slaughterhouse(2, 100, 10, 8.5)
list, abort = AnimalMoveEvent._deliverToEPPTarget(s, { entry(animal(2, 525, 1)), entry(animal(2, 525, 1)) }, 2)
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
local cowAndPigs = function() return { entry(animal(2, 750, 1)), entry(animal(3, 120, 1)), entry(animal(3, 120, 1)) } end

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

check("yield factor is 1 without weight or genetics",
    AnimalMoveEvent.getCarcassYieldFactor({}, 650) == 1 and AnimalMoveEvent.getCarcassYieldFactor(nil) == 1)
check("weight ratio clamped at 2.5", near(AnimalMoveEvent.getCarcassYieldFactor(animal(1, 5000, 1), 650), 2.5))

for _, line in ipairs(LOG) do
    if line:find("^safeCall") then check("no script error: " .. line, false) end
end
