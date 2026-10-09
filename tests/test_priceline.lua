-- Live prices do not depend on the target weights and growth lines the pens use: a dealer's animal
-- (weight from RLBreedTraits.getGrownWeight) is priced as before the cattle weights were set to
-- real ones, when it weighed its age on the old linear line. The old formula is written out here
-- with the old target weights and mature ages.

g_currentMission = {}
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO
AnimalMoveEvent = {}

loadMod("scripts/animal/RLBreedTraits.lua")
loadAnimalSection("function Animal:getSellPrice()", "function Animal:getDailyRidingTime()")

local xml = loadXMLFileFromDisk(REPO .. "xml/animals.xml")
local SUBS = {}
xml:iterate("animals.animal", function(_, animalKey)
    xml:iterate(animalKey .. ".subType", function(_, key)
        local points = {}
        xml:iterate(key .. ".sellPrice.key", function(_, k) points[#points + 1] = { xml:getFloat(k .. "#ageMonth"), xml:getFloat(k .. "#value") } end)
        SUBS[xml:getString(key .. "#subType")] = { name = xml:getString(key .. "#subType"), breed = xml:getString(key .. "#breed"),
            gender = xml:getString(key .. "#gender"), minWeight = xml:getFloat(key .. "#minWeight"),
            targetWeight = xml:getFloat(key .. "#targetWeight"), maxWeight = xml:getFloat(key .. "#maxWeight"),
            reproductionMinAgeMonth = xml:getInt(key .. ".reproduction#minAgeMonth"),
            sellPrice = { get = function(_, age)
                if age <= points[1][1] then return points[1][2] end
                for i = 2, #points do
                    local a, b = points[i - 1], points[i]
                    if age <= b[1] then return a[2] + (b[2] - a[2]) * (age - a[1]) / (b[1] - a[1]) end
                end
                return points[#points][2]
            end } }
    end)
end)

-- The subtypes' target weight and mature age before they were set to real ones.
local OLD = { BULL_ANGUS = { 850, 33.4 }, COW_HOLSTEIN = { 680, 18 }, BULL_WATERBUFFALO = { 900, 45.4 },
    COW_HIGHLAND_CATTLE = { 500, 18 } }

local function oldPrice(sub, oldTarget, oldMature, age, weight, quality, metabolism)
    local own = oldTarget + (oldTarget * metabolism - oldTarget) / 2.5
    local sell = sub.sellPrice:get(age)
    local forAge = ((own - sub.minWeight) / oldMature) * math.min(age + 1.5, oldMature) * 0.85
    local factor = 1 + (weight - forAge) / forAge
    sell = sell + sell * 0.25 * (quality - 1)
    sell = math.max(sell + ((sell * 0.6) / oldTarget) * weight * (-1 + quality), 0.5)
    return math.max(sell * 0.6 + sell * 0.4 * factor * 0.75, sell * 0.05)
end

local worst = 0
for name, old in pairs(OLD) do
    local sub = SUBS[name]
    for _, age in ipairs({ 1, 6, 12, 19.5, 30, 48 }) do
        for _, gene in ipairs({ { 1, 1 }, { 1.3, 0.6 }, { 0.7, 1.5 } }) do
            local quality, metabolism = gene[1], gene[2]
            local own = sub.targetWeight + (sub.targetWeight * metabolism - sub.targetWeight) / 2.5
            local ratio = 0.9
            local oldWeight = (sub.minWeight + (old[1] - sub.minWeight) / old[2] * math.min(math.max(age, 0), math.max(old[2], 20))) * ratio
            local newWeight = RLBreedTraits.getGrownWeight(sub, sub.gender, own, age, metabolism) * ratio
            local animal = setmetatable({ age = age, weight = newWeight, gender = sub.gender, targetWeight = own,
                genetics = { quality = quality, metabolism = metabolism }, diseases = {}, isCastrated = false },
                { __index = Animal })
            animal.getSubType = function() return sub end
            animal.isHorse = function() return false end
            animal.getHealthFactor = function() return 1 end
            local expected = oldPrice(sub, old[1], old[2], age, oldWeight, quality, metabolism)
            worst = math.max(worst, math.abs(animal:getSellPrice() / expected - 1))
        end
    end
end
check(string.format("price line: dealer animals keep the price they had (worst difference %.2f%%)", worst * 100), worst < 0.01)
