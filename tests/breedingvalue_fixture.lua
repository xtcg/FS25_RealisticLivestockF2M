-- Shared fixture for the breeding value tests: the mod's animals.xml cattle, one selling point for
-- beef (8.4/kg annual mean, the meat chain calibration) and one for milk (0.5/L), the real
-- Animal:getSellPrice / getCurvePrice, RLMeatValue, carcass yield and RLBreedingValue.

AnimalMoveEvent = { MOVE_SUCCESS = 0 }
AnimalType = { COW = 1, PIG = 2, SHEEP = 3, HORSE = 4, CHICKEN = 5 }
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

BV_PRICE = { BEEFMEAT = 8.4, MILK = 0.5 }
local FILL = { BEEFMEAT = 40, MILK = 50 }
BV_FILL = FILL
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) return FILL[name] end,
    getFillTypeByIndex = function(_, index)
        for _, i in pairs(FILL) do if i == index then return { pricePerLiter = 1, economy = { factors = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 } } } end end
    end }

local function curveOf(xml, key)
    local points = {}
    xml:iterate(key .. ".key", function(_, k) points[#points + 1] = { xml:getFloat(k .. "#ageMonth"), xml:getFloat(k .. "#value") } end)
    if #points == 0 then return nil end
    return { get = function(_, age)
        if age <= points[1][1] then return points[1][2] end
        for i = 2, #points do
            local a, b = points[i - 1], points[i]
            if age <= b[1] then
                if b[1] == a[1] then return b[2] end
                return a[2] + (b[2] - a[2]) * (age - a[1]) / (b[1] - a[1])
            end
        end
        return points[#points][2]
    end }
end

TYPES, SUBS, BV_SUB = {}, {}, {}
local typeIndex = {}
for _, path in ipairs(BV_ANIMALS or { REPO .. "xml/animals.xml" }) do
local xml = loadXMLFileFromDisk(path)
xml:iterate("animals.animal", function(_, animalKey)
    local typeName = xml:getString(animalKey .. "#type")
    if typeIndex[typeName] == nil then
        TYPES[#TYPES + 1] = { name = typeName }
        typeIndex[typeName] = #TYPES
    end
    xml:iterate(animalKey .. ".subType", function(_, key)
        local sub = { name = xml:getString(key .. "#subType"), typeIndex = typeIndex[typeName],
            breed = xml:getString(key .. "#breed"), gender = xml:getString(key .. "#gender", "female"),
            minWeight = xml:getFloat(key .. "#minWeight"), targetWeight = xml:getFloat(key .. "#targetWeight"),
            reproductionMinAgeMonth = xml:getInt(key .. ".reproduction#minAgeMonth"),
            reproductionDurationMonth = xml:getInt(key .. ".reproduction#durationMonth"),
            sellPrice = curveOf(xml, key .. ".sellPrice"), output = {} }
        local milk = curveOf(xml, key .. ".output.milk")
        if milk ~= nil then
            milk.fillType = FILL[xml:getString(key .. ".output.milk#fillType", "MILK")] or FILL.MILK
            sub.output.milk = milk
        end
        if BV_SUB[sub.name] == nil then
            SUBS[#SUBS + 1] = sub
            sub.index = #SUBS
            BV_SUB[sub.name] = sub
        end
    end)
end)
end

BV_NOW = { BEEFMEAT = BV_PRICE.BEEFMEAT, MILK = BV_PRICE.MILK }
STATIONS = {}
for name, index in pairs(FILL) do
    local s = { isSellingPoint = true, acceptedFillTypes = { [index] = true }, originalFillTypePrices = { [index] = BV_PRICE[name] } }
    function s:getEffectiveFillTypePrice(fillType) return fillType == index and BV_NOW[name] or 0 end
    STATIONS[#STATIONS + 1] = s
end
g_currentMission = {
    animalSystem = { subTypes = SUBS, getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    storageSystem = { getUnloadingStations = function() return STATIONS end },
    economyManager = { getPricePerLiter = function() return 0 end },
}

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadMod("scripts/animal/RLMeatValue.lua")
loadMod("scripts/animal/BreedingMath.lua")
loadAnimalSection("function Animal:getSellPrice()", "function Animal:getDailyRidingTime()")
Animal.isSemenFillType = function() return false end
Animal.isCowMilkPalletFillType = function() return false end
loadMod("scripts/animal/RLBreedingValue.lua")

--- A dealer-style animal of a subtype: weight on the full-feed line, genes as given (default 1).
function bvAnimal(subName, age, fields)
    local sub = assert(BV_SUB[subName], subName)
    local a = { subTypeIndex = sub.index, subType = sub.name, animalTypeIndex = sub.typeIndex, age = age,
        gender = sub.gender, targetWeight = sub.targetWeight,
        weight = RLBreedTraits.getGrownWeight(sub, sub.gender, sub.targetWeight, age, 1),
        genetics = { quality = 1, metabolism = 1, health = 1, fertility = 1, productivity = 1 },
        diseases = {}, isCastrated = false, isParent = false, isLactating = false, isPregnant = false,
        reproduction = 0, birthCount = 0 }
    for k, v in pairs(fields or {}) do
        if k == "genes" then for g, x in pairs(v) do a.genetics[g] = x end else a[k] = v end
    end
    a.getSubType = function() return sub end
    a.isHorse = function() return false end
    a.getHealthFactor = function() return 1 end
    a.resolveBirthCount = function(self) return self.birthCount or 0 end
    return setmetatable(a, { __index = Animal })
end

function bvGenes(x) return { productivity = x, fertility = x, health = x, quality = x } end

function bvQuote(animal)
    RLBreedingValue.reset()
    return RLBreedingValue.getQuote(animal)
end
