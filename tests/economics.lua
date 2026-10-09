-- Static feeding economics on the mod's own updateWeight / daily-food / carcass-yield code: raises
-- one average-gene animal of a subtype from birth to its slaughter reference and reports months,
-- feed, live weight and carcass units. `python tests/economics.py` prints the tables.
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

Economics = {}

-- animals.xml: types and subtypes with piecewise-linear food and milk curves, as AnimCurve
-- interpolates them.
local function readCurve(xml, key)
    local keys = {}
    xml:iterate(key .. ".key", function(_, k)
        keys[#keys + 1] = { xml:getFloat(k .. "#ageMonth"), xml:getFloat(k .. "#value") }
    end)
    return keys
end

local xml = loadXMLFileFromDisk(ANIMALS_XML)
local types, subTypes = {}, {}
xml:iterate("animals.animal", function(t, typeKey)
    types[t + 1] = { name = xml:getString(typeKey .. "#type") }
    xml:iterate(typeKey .. ".subType", function(_, key)
        subTypes[#subTypes + 1] = {
            name = xml:getString(key .. "#subType"), breed = xml:getString(key .. "#breed"),
            gender = xml:getString(key .. "#gender"), typeIndex = t + 1, typeName = types[t + 1].name,
            minWeight = xml:getFloat(key .. "#minWeight"), targetWeight = xml:getFloat(key .. "#targetWeight"),
            reproductionMinAgeMonth = xml:getInt(key .. ".reproduction#minAgeMonth"),
            food = readCurve(xml, key .. ".input.food"), milk = readCurve(xml, key .. ".output.milk"),
        }
    end)
end)
Economics.subTypes = subTypes
g_currentMission.animalSystem = { getTypeByIndex = function(_, i) return types[i] end,
    getSubTypeByIndex = function(_, i) return subTypes[i] end }

function Economics.curve(keys, age)
    if #keys == 0 then return 0 end
    if age <= keys[1][1] then return keys[1][2] end
    for i = 2, #keys do
        if age <= keys[i][1] then
            local a, b = keys[i - 1], keys[i]
            if b[1] == a[1] then return b[2] end
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

--- Rations: food factor and forage shares. Pigs and sheep have one food group at factor 1.
Economics.RATIONS = {
    TMR = { 1.0, { silage = 1 } }, silage = { 0.8, { silage = 1 } },
    hay = { 0.65, { hay = 1 } }, grass = { 0.4, { grass = 1 } }, full = { 1.0, nil },
}

--- Slaughter reference of an average-gene animal of the subtype.
function Economics.reference(sub)
    local maturity = RLBreedTraits.resolve(carcass.layers, sub, sub.gender == "male" and "maleMaturity" or "femaleMaturity", 1)
    return sub.targetWeight * maturity
end

--- Raise one intact animal on a ration until it reaches `reference` (or 120 months).
--- @return number months, number feed, number live kg, number carcass units
function Economics.raise(subIndex, ration, reference, foodMultiplier)
    local sub = subTypes[subIndex]
    local foodFactor, shares = ration[1], ration[2]
    local a = setmetatable({ age = 0, weight = sub.minWeight, targetWeight = sub.targetWeight, gender = sub.gender,
        subTypeIndex = subIndex, genetics = { metabolism = 1, quality = 1 }, health = 100,
        clusterSystem = { owner = { spec_husbandryFood = { rlForageShares = shares } } } }, { __index = Animal })
    a.getSubType = function() return sub end
    a.getDiseaseMultipliers = function() return nil, 0 end

    local feed, hours = 0, 0
    while a.weight < reference and a.age < 120 do
        for _ = 1, 24 do
            feed = feed + Animal._computeDailyFood(a.age, false, 0, 0, 1, Economics.curve(sub.food, a.age), 1,
                a:getFeedModifier()) / 24 * (foodMultiplier or 1)
            a:updateWeight(foodFactor)
            hours = hours + 1
            if a.weight >= reference then break end
        end
        if a.weight < reference then a.age = a.age + 1 end
    end

    local units = LEGACY and a.weight / 650 or AnimalMoveEvent.getCarcassYieldFactor(a, nil, subIndex)
    return hours / 24, feed, a.weight, units
end

function Economics.find(name)
    for i, sub in ipairs(subTypes) do if sub.name == name then return i, sub end end
end

--- Print months, feed, feed per kg gain and feed per carcass unit for the given subtypes on
--- each ration.
function Economics.report(title, names, rations)
    print(string.format("\n%s", title))
    local header = string.format("%-22s %6s %6s", "subtype", "target", "ref kg")
    for _, r in ipairs(rations) do header = header .. string.format(" | %-6s %5s %6s %5s", r, "mo", "feed", "f/kg") end
    print(header)
    for _, name in ipairs(names) do
        local i, sub = Economics.find(name)
        if i ~= nil then
            local reference = Economics.reference(sub)
            local line = string.format("%-22s %6.0f %6.1f", name, sub.targetWeight, reference)
            for _, r in ipairs(rations) do
                local months, feed, live = Economics.raise(i, Economics.RATIONS[r], reference)
                line = line .. string.format(" | %-6s %5.1f %6.0f %5.2f", "", months, feed, feed / (live - sub.minWeight))
            end
            print(line)
        end
    end
end

Economics.BULLS = { "BULL_HOLSTEIN", "BULL_LIMOUSIN", "BULL_HEREFORD", "BULL_ANGUS", "BULL_SWISS_BROWN",
    "BULL_WATERBUFFALO", "BULL_HIGHLAND_CATTLE" }
Economics.PIGS = { "BOAR_LANDRACE", "BOAR_BLACK_PIED", "BOAR_BERKSHIRE", "PIG_LANDRACE", "PIG_BLACK_PIED", "PIG_BERKSHIRE" }
Economics.RAMS = { "RAM_LANDRACE", "RAM_STEINSCHAF", "RAM_SWISS_MOUNTAIN", "RAM_BLACK_WELSH", "RAM_GOAT" }

--- Adult cow feed against milk: food and milk curves at 60 months, lactation averaged over a
--- 12-month calving interval (10 months lactating: mean factor 1.08, food x1.25 while lactating).
function Economics.dairyReport()
    print("\nadult cows at 60 months (per month, 12-month calving interval)")
    print(string.format("%-22s %6s %6s %6s %7s", "subtype", "food", "milk", "feed", "milk/feed"))
    for _, sub in ipairs(subTypes) do
        if sub.typeName == "COW" and sub.gender == "female" and #sub.milk > 0 then
            local base = Economics.curve(sub.food, 60) * RLBreedTraits.get(sub, "feed")
            local feed = base * (10 * 1.25 + 2) / 12
            local milk = Economics.curve(sub.milk, 60) * 10.8 / 12
            print(string.format("%-22s %6.0f %6.0f %6.0f %7.2f", sub.name, Economics.curve(sub.food, 60),
                Economics.curve(sub.milk, 60), feed, milk / feed))
        end
    end
end

if REPORT then
    Economics.report("cattle bulls (intact)", Economics.BULLS, { "TMR", "silage", "hay", "grass" })
    Economics.report("pigs", Economics.PIGS, { "full" })
    Economics.report("rams (grass)", Economics.RAMS, { "full" })
    Economics.dairyReport()
end
