-- Static feeding economics: raises one average-gene bull of each breed from birth to its slaughter
-- reference on the mod's own updateWeight / daily-food / carcass-yield code, and prints months,
-- feed, live weight and carcass units. Run with `python tests/economics.py`.
--
-- ANIMALS_XML is the animals.xml to read (so an older one can be compared). LEGACY = true
-- reproduces the pre-breed-traits rules: no breed traits, no body-condition food, growth at
-- min(food factor x 1.25, 1), carcass yield = live weight / 650 kg.

AnimalMoveEvent = {}
g_currentMission = { environment = { daysPerPeriod = 1 } }
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadAnimalSection("function Animal:updateWeight", "--- Advance post-birth recovery")
loadAnimalSection("--- Pure daily-food formula", "function Animal:updateInput")

-- animals.xml: types and subtypes with a piecewise-linear food curve, as AnimCurve interpolates.
local xml = loadXMLFileFromDisk(ANIMALS_XML)
local types, subTypes = {}, {}
xml:iterate("animals.animal", function(t, typeKey)
    types[t + 1] = { name = xml:getString(typeKey .. "#type") }
    xml:iterate(typeKey .. ".subType", function(_, key)
        local keys = {}
        xml:iterate(key .. ".input.food.key", function(_, k)
            keys[#keys + 1] = { xml:getFloat(k .. "#ageMonth"), xml:getFloat(k .. "#value") }
        end)
        subTypes[#subTypes + 1] = {
            name = xml:getString(key .. "#subType"), breed = xml:getString(key .. "#breed"),
            gender = xml:getString(key .. "#gender"), typeIndex = t + 1,
            minWeight = xml:getFloat(key .. "#minWeight"), targetWeight = xml:getFloat(key .. "#targetWeight"),
            reproductionMinAgeMonth = xml:getInt(key .. ".reproduction#minAgeMonth"),
            food = keys,
        }
    end)
end)
g_currentMission.animalSystem = { getTypeByIndex = function(_, i) return types[i] end,
    getSubTypeByIndex = function(_, i) return subTypes[i] end }

local function foodCurve(keys, age)
    if age <= keys[1][1] then return keys[1][2] end
    for i = 2, #keys do
        if age <= keys[i][1] then
            local a, b = keys[i - 1], keys[i]
            return a[2] + (b[2] - a[2]) * (age - a[1]) / (b[1] - a[1])
        end
    end
    return keys[#keys][2]
end

local traits = RLBreedTraits.getConfig()
local carcass = AnimalMoveEvent.getCarcassConfig()
if LEGACY then
    traits.layers = RLBreedTraits.parseLayers(nil, "breedTraits", {})
    traits.bodyWeightExponent = 0
    traits.growthNutritionFactor = 1.25
end

--- Raise one bull on a ration; returns months, feed, live kg, carcass units.
local function raise(subIndex, foodFactor, shares, reference)
    local sub = subTypes[subIndex]
    local a = setmetatable({ age = 0, weight = sub.minWeight, targetWeight = sub.targetWeight, gender = "male",
        subTypeIndex = subIndex, genetics = { metabolism = 1, quality = 1 }, health = 100,
        clusterSystem = { owner = { spec_husbandryFood = { rlForageShares = shares } } } }, { __index = Animal })
    a.getSubType = function() return sub end
    a.getDiseaseMultipliers = function() return nil, 0 end

    local feed, hours = 0, 0
    while a.weight < reference and a.age < 72 do
        for _ = 1, 24 do
            feed = feed + Animal._computeDailyFood(a.age, false, 0, 0, 1, foodCurve(sub.food, a.age), 1, a:getFeedModifier()) / 24
            a:updateWeight(foodFactor)
            hours = hours + 1
            if a.weight >= reference then break end
        end
        if a.weight < reference then a.age = a.age + 1 end
    end

    local units = LEGACY and a.weight / 650 or AnimalMoveEvent.getCarcassYieldFactor(a, nil, subIndex)
    return hours / 24, feed, a.weight, units
end

local RATIONS = {
    { "TMR (food factor 1.0)", 1.0, { silage = 1 } },
    { "grass (food factor 0.4)", 0.4, { grass = 1 } },
}

for _, ration in ipairs(RATIONS) do
    print(string.format("\n%s", ration[1]))
    print(string.format("%-22s %7s %9s %7s %8s %9s %11s %10s", "bull", "target", "reference", "months", "feed",
        "live kg", "kg/1000feed", "feed/unit"))
    for i, sub in ipairs(subTypes) do
        if types[sub.typeIndex].name == "COW" and sub.gender == "male" and sub.breed ~= nil then
            local maturity = RLBreedTraits.resolve(carcass.layers, sub, "maleMaturity", 1)
            local reference = sub.targetWeight * maturity
            local months, feed, live, units = raise(i, ration[2], ration[3], reference)
            print(string.format("%-22s %7.0f %9.0f %7.1f %8.0f %9.0f %11.2f %10.0f", sub.name, sub.targetWeight,
                reference, months, feed, live, (live - sub.minWeight) / feed * 1000, feed / units))
        end
    end
end
