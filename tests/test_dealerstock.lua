-- Dealer stock age and weight (xml/breedTraits.xml sale ages, AnimalSystem:createNewSaleAnimal, Animal.new):
-- an animal past its type's maximum sale age is offered only when its genetics are elite, and no animal
-- the dealer generates is heavier than its own target weight.

XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

TYPES = { [1] = { name = "COW" }, [2] = { name = "PIG" }, [3] = { name = "SHEEP" }, [4] = { name = "HORSE" } }
g_currentMission = { animalSystem = { getTypeByIndex = function(_, i) return TYPES[i] end } }
RLConstants = { GENETICS_MIN = 0.25, GENETICS_MAX = 1.75 }
RmLogging.LOG_LEVEL = { ERROR = 1, WARNING = 2, INFO = 3, DEBUG = 4, TRACE = 5 }
local getLogger = RmLogging.getLogger
RmLogging.getLogger = function(...) local log = getLogger(...); log.level = 0; return log end

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animal/RLGeneticsDraw.lua")

-- The dealer's age picker, from the AnimalSystem file (which the test harness cannot load whole).
do
    local handle = assert(io.open(REPO .. "scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua", "r"))
    local text = handle:read("a")
    handle:close()
    local from = assert(text:find("function AnimalSystem:_pickSaleAnimalAge", 1, true))
    local to = assert(text:find("--- Build a new sale animal", from, true))
    AnimalSystem = {}
    assert(load("local Log = RmLogging.getLogger()\n" .. text:sub(from, to - 1), "picker"))()
end

local function sub(typeIndex, name, breed, gender)
    return { typeIndex = typeIndex, name = name, breed = breed, gender = gender,
        visuals = { { minAge = 0, store = { canBeBought = true } } } }
end
local angusBull = sub(1, "BULL_ANGUS", "ANGUS", "male")
local highlandBull = sub(1, "BULL_HIGHLAND_CATTLE", "HIGHLAND", "male")
local holstein = sub(1, "COW_HOLSTEIN", "HOLSTEIN", "female")
local boar = sub(2, "BOAR_LANDRACE", "LANDRACE", "male")
local ram = sub(3, "RAM_LANDRACE", "LANDRACE", "male")
local ewe = sub(3, "SHEEP_LANDRACE", "LANDRACE", "female")
local horse = sub(4, "HORSE_GRAY", "GRAY", "female")

check("limits: bulls 24 months (Highland 30), cows 48", RLBreedTraits.getMaxSaleAge(angusBull) == 24
    and RLBreedTraits.getMaxSaleAge(highlandBull) == 30 and RLBreedTraits.getMaxSaleAge(holstein) == 48)
check("limits: pigs 12, rams 18, ewes 30; horses none", RLBreedTraits.getMaxSaleAge(boar) == 12
    and RLBreedTraits.getMaxSaleAge(ram) == 18 and RLBreedTraits.getMaxSaleAge(ewe) == 30 and RLBreedTraits.getMaxSaleAge(horse) == nil)
check("elite: mean of the genes at least 1.45", RLBreedTraits.isEliteForSale({ quality = 1.5, health = 1.4, fertility = 1.45 })
    and not RLBreedTraits.isEliteForSale({ quality = 1.6, health = 1.2, fertility = 1.3 }) and not RLBreedTraits.isEliteForSale(nil))

-- The dealer's draw as createNewSaleAnimal does it: age, genetics, and a new age within the limit for a
-- non-elite animal drawn too old. Cows: average buy age 12, maximum 72.
math.randomseed(7)
local function dealerDraw(subType, averageBuyAge, maxBuyAge, n)
    local over, eliteOver, overLimit = 0, 0, 0
    local limit = RLBreedTraits.getMaxSaleAge(subType)
    for _ = 1, n do
        local age = AnimalSystem:_pickSaleAnimalAge(subType, averageBuyAge, maxBuyAge)
        local genetics = RLGeneticsDraw.draw(RLGeneticsDraw.TRAITS_WITH_PRODUCTIVITY)
        if limit ~= nil and age > limit then
            overLimit = overLimit + 1
            if not RLBreedTraits.isEliteForSale(genetics) then
                age = AnimalSystem:_pickSaleAnimalAge(subType, averageBuyAge, math.min(maxBuyAge, limit))
            end
        end
        if limit ~= nil and age > limit then
            over = over + 1
            if RLBreedTraits.isEliteForSale(genetics) then eliteOver = eliteOver + 1 end
        end
    end
    return over / n, eliteOver, over, overLimit / n
end

local share, eliteOver, over, before = dealerDraw(angusBull, 12, 72, 20000)
check(string.format("bulls: %.1f%% offered past 24 months (was %.1f%%), all of them elite", share * 100, before * 100),
    share < 0.02 and share > 0 and eliteOver == over and before > 0.05)
share, eliteOver, over, before = dealerDraw(holstein, 12, 72, 20000)
check(string.format("cows: %.2f%% offered past 48 months (was %.1f%%), all of them elite", share * 100, before * 100),
    share < 0.01 and eliteOver == over)
share = dealerDraw(horse, 24, 240, 2000)
check("horses: no limit, the type's maxBuyAge applies", share == 0)

-- Weight: an animal without one is on the growth line +/-15%, never over its own target.
local bull = { typeIndex = 1, name = "BULL_ANGUS", breed = "ANGUS", gender = "male", minWeight = 35, maxWeight = 1400 }
local function weight(age, roll) return RLBreedTraits.getNewAnimalWeight(bull, "male", 1000, age, 1, function() return roll end) end
local line = RLBreedTraits.getGrownWeight(bull, "male", 1000, 12, 1)
check(string.format("weight: a 12-month bull %.0f kg on the line, 85%%-115%% of it", line),
    near(weight(12, 85), line * 0.85) and near(weight(12, 115), line * 1.15))
check("weight: a grown bull at 1.15 is its target 1000, not 1150", near(weight(120, 115), 1000) and near(weight(120, 85), 850))
check("weight: a small target caps below the subtype's maxWeight", near(RLBreedTraits.getNewAnimalWeight(bull, "male", 700, 120, 1,
    function() return 115 end), 700))

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
