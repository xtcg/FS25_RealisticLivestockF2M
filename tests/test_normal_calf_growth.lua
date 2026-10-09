-- Normal, adequately fed calves: actual legacy weight and health functions used below six months.
-- Feeding allocation itself is covered through the real food adapter in test_calfrearing.lua.
ANIMALS_XML = REPO .. "xml/animals.xml"
loadMod("tests/economics.lua")
loadMod("scripts/animal/AnimalHealth.lua")

local function monthly(name, age, days, speed)
    local index, sub = Economics.find(name)
    sub.healthThresholdFactor, sub.healthIncreaseHour, sub.healthDecreaseHour = 0.5, 1, 1
    local animal = setmetatable({ age = age, weight = sub.minWeight + age * 35,
        targetWeight = sub.targetWeight, gender = sub.gender, subTypeIndex = index,
        health = 91, genetics = { metabolism = 1, health = 1 },
        getSubType = function() return sub end, getDiseaseMultipliers = function() return nil, 0 end },
        { __index = Animal })
    g_currentMission.environment.daysPerPeriod = days
    g_currentMission.environment.timeScale = speed
    local start = animal.weight
    for _ = 1, 24 * days do
        AnimalHealth.updateHealthOnly(animal, 1)
        animal:updateWeight(1)
    end
    local beforeBirthday = animal.weight
    animal.age = age + 1
    AnimalHealth.updateHealthOnly(animal, 1)
    animal:updateWeight(1)
    return animal, beforeBirthday - start, beforeBirthday
end

for _, name in ipairs({ "BULL_ANGUS", "COW_HOLSTEIN" }) do
    for age = 0, 4 do
        local reference
        for _, days in ipairs({ 1, 3, 28 }) do
            for _, speed in ipairs({ 1, 120 }) do
                local animal, gain, before = monthly(name, age, days, speed)
                reference = reference or gain
                check(string.format("normal calf %s age %d, %d days/month, speed %d: positive growth, healthy, no birthday collapse",
                    name, age, days, speed), gain > 0 and animal.health >= 91 and animal.weight >= before
                    and near(gain, reference, 1e-6))
            end
        end
    end
end
