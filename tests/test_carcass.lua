-- Delivery to Hof Bergmann's farm butcher and public slaughterhouse (AnimalMoveEvent EPP path).

AnimalMoveEvent = { MOVE_SUCCESS = 0, MOVE_ERROR_INVALID_CLUSTER = 4, MOVE_ERROR_NOT_ENOUGH_SPACE = 6 }

TYPES = { [1] = { name = "COW" }, [2] = { name = "PIG" }, [3] = { name = "DUCKWILD" } }
SUBS = { [1] = { typeIndex = 1, targetWeight = 900 }, [2] = { typeIndex = 1, targetWeight = 575 },
         [3] = { typeIndex = 2, targetWeight = 165 }, [4] = { typeIndex = 3, targetWeight = 3.5 },
         [5] = { typeIndex = 3, targetWeight = 2.5 } }
MONEY = {}
g_currentMission = {
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    getMoney = function(_, farmId) return MONEY[farmId] or 0 end,
    addMoney = function(_, delta, farmId) MONEY[farmId] = (MONEY[farmId] or 0) + delta end,
}

loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")

local function animal(sub, weight, quality)
    return { subTypeIndex = sub, weight = weight, genetics = quality and { quality = quality } or nil }
end
local function entry(a) return { animal = { subTypeIndex = a.subTypeIndex }, sourceCluster = a } end

-- Stand-in for the map's unit-based butcher addCluster (PlaceableExtendedProductionAnimalUnits):
-- whole animals of unitsPerAnimal each, read live from eppAnimalInputUnitsByFillType.
local BEEF, PIGS, POULTRY = 20, 21, 22
local function butcher(capacity, fill)
    local f = { isServer = true, animalsTypeData = {}, level = fill or 0, cap = capacity,
        animalSubTypeToFillType = { [1] = BEEF, [2] = BEEF, [3] = PIGS, [4] = POULTRY, [5] = POULTRY },
        eppAnimalInputUnitsByFillType = { [BEEF] = 750, [PIGS] = 120, [POULTRY] = 10 }, eppHasScaledAnimalInputs = true }
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

local units, count, f = butcherUnits(animal(1, 650, 1))
check("butcher: 650 kg average-gene cow = configured 750", near(units, 750) and count == 1)
check("butcher: configured units restored", f.eppAnimalInputUnitsByFillType[BEEF] == 750)
check("butcher: 900 kg Angus bull -> 750*900/650 = 1038.5", near(butcherUnits(animal(1, 900, 1)), 1038.46))
check("butcher: 575 kg Holstein cow -> 663.5", near(butcherUnits(animal(2, 575, 1)), 663.46))
check("butcher: same cow, meat gene 1.5 -> 746.4", near(butcherUnits(animal(2, 575, 1.5)), 746.39))
check("butcher: 110 kg finishing pig -> 110", near(butcherUnits(animal(3, 110, 1)), 110))
check("butcher: unlisted type falls back to the mean target weight", near(butcherUnits(animal(4, 3.5, 1)), 11.67))

local full = butcher(1500, 1000)
local list, abort = AnimalMoveEvent._deliverToEPPTarget(full, { entry(animal(1, 650, 1)) }, 1)
check("butcher: no room for a whole carcass -> refused, nothing stored",
    #list == 0 and full.level == 1000 and abort == AnimalMoveEvent.EPP_NOT_ACCEPTED)

-- Slaughterhouse: order buffer and per-batch fee as in PlaceableContractProductionService.
local function slaughterhouse(orderFarm, feePerBatch)
    local recipe = { inputs = { [BEEF] = { amount = 1 } }, feeInputFillTypeIndex = BEEF, feePerBatch = feePerBatch or 0 }
    local order = { farmId = orderFarm, recipeId = "beef", feeCredit = 0, buffered = 0 }
    local t = { isServer = true, animalsTypeData = {}, animalSubTypeToFillType = { [1] = BEEF, [2] = BEEF },
        spec_contractProductionService = { orders = orderFarm and { order } or {}, recipeById = { beef = recipe } },
        order = order, refreshed = 0 }
    function t:contractProductionGetAnimalFreeSlots(farmId)
        if orderFarm ~= farmId then return 0 end
        local free = 100 - math.ceil(order.buffered)
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
        order.buffered = order.buffered + accepted
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
