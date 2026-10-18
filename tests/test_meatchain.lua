-- Bulls, pigs, lambs, kids, poultry and rabbits on the meat chain (xml/carcassYield.xml, docs
-- RLRM_猪羊禽兔屠宰与售价校准.md): a dealer's animal of finishing age, average genes, sells live for its
-- contract-slaughter net at the annual mean meat price / 1.12, and the market factor moves it through
-- the year. Runs the real Animal:getSellPrice, RLMeatValue and carcass yield on the shipped xml, plus
-- Hof Bergmann's bridge subtypes (v1.5).

-- tests/test_livestockprices.lua runs this file again on NORMAL and EASY with the real RLLivestockPrices:
-- the game multiplies the meat price, the mod the live prices and fees, so every margin is the same and
-- every live price is x1.8 / x3 of HARD's.
local M = MEATCHAIN_MULTIPLIER or 1
local LABEL = M ~= 1 and string.format("x%g ", M) or ""
if M ~= 1 then
    EconomyManager = { getPriceMultiplier = function() return M end }
end

AnimalMoveEvent = { MOVE_SUCCESS = 0 }
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

-- Annual mean best-station price per kg each species is calibrated at, and the map's seasonal factors
-- (Hof Bergmann: the same 12 for every meat, mean 1.000833).
local PRICE = { BEEFMEAT = 8.4, PORKMEAT = 4.31, SHEEPGOATMEAT = 14.95, POULTRYMEAT = 9.06, GOOSEMEAT = 10.21, RABBITMEAT = 10.34 }
local HB_FACTORS = { 1.00, 1.07, 0.99, 0.94, 0.85, 0.81, 0.86, 0.99, 1.08, 1.13, 1.21, 1.08 }
local SEASONAL = 1.000833
local FILL = { BEEFMEAT = 40, PORKMEAT = 41, SHEEPGOATMEAT = 42, POULTRYMEAT = 43, GOOSEMEAT = 44, RABBITMEAT = 45 }
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) return FILL[name] end,
    getFillTypeByIndex = function(_, index)
        for _, i in pairs(FILL) do if i == index then return { pricePerLiter = 1, economy = { factors = HB_FACTORS } } end end
    end }

-- Subtypes: the mod's animals.xml, then the bridge's new and overridden ones on top.
TYPES, SUBS = {}, {}
local byName, typeIndex = {}, {}
local function curveOf(xml, key)
    local points = {}
    xml:iterate(key .. ".key", function(_, k) points[#points + 1] = { xml:getFloat(k .. "#ageMonth"), xml:getFloat(k .. "#value") } end)
    if #points == 0 then return nil end
    return { get = function(_, age)
        if age <= points[1][1] then return points[1][2] end
        for i = 2, #points do
            local a, b = points[i - 1], points[i]
            if age <= b[1] then return a[2] + (b[2] - a[2]) * (age - a[1]) / (b[1] - a[1]) end
        end
        return points[#points][2]
    end }
end
local function readAnimals(path)
    local xml = loadXMLFileFromDisk(path)
    xml:iterate("animals.animal", function(_, animalKey)
        local typeName = xml:getString(animalKey .. "#type")
        if typeIndex[typeName] == nil then
            TYPES[#TYPES + 1] = { name = typeName }
            typeIndex[typeName] = #TYPES
        end
        xml:iterate(animalKey .. ".subType", function(_, key)
            local name = xml:getString(key .. "#subType")
            local sub = byName[name]
            if sub == nil then
                sub = { name = name, typeIndex = typeIndex[typeName] }
                SUBS[#SUBS + 1] = sub
                sub.index = #SUBS
                byName[name] = sub
            end
            sub.breed = xml:getString(key .. "#breed", sub.breed)
            sub.gender = xml:getString(key .. "#gender", sub.gender)
            sub.minWeight = xml:getFloat(key .. "#minWeight", sub.minWeight)
            sub.targetWeight = xml:getFloat(key .. "#targetWeight", sub.targetWeight)
            sub.reproductionMinAgeMonth = xml:getInt(key .. ".reproduction#minAgeMonth", sub.reproductionMinAgeMonth)
            sub.sellPrice = curveOf(xml, key .. ".sellPrice") or sub.sellPrice
        end)
    end)
end
readAnimals(REPO .. "xml/animals.xml")
readAnimals(REPO .. "mod_support/FS25_HofBergmann/v1.5/animals.xml")
-- Calibration runs (FS25_SheepBreeds_离线准备_2026-10-11/tools/calibrate_ram_prices.py) add a pack's animals.xml.
for _, path in ipairs(MEATCHAIN_EXTRA_XML or {}) do readAnimals(path) end
byName.RABBIT.gender = "female"  -- the map sets no gender on RABBIT: the loader reads it as female

-- One selling point per meat: its base price is the annual mean / the seasonal mean, it pays `now`.
local NOW = {}
STATIONS = {}
for name, index in pairs(FILL) do
    local s = { isSellingPoint = true, acceptedFillTypes = { [index] = true },
        originalFillTypePrices = { [index] = PRICE[name] / SEASONAL } }
    function s:getEffectiveFillTypePrice(fillType) return fillType == index and NOW[name] or 0 end
    STATIONS[#STATIONS + 1] = s
end
g_currentMission = {
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    storageSystem = { getUnloadingStations = function() return STATIONS end },
    economyManager = { getPricePerLiter = function() return 0 end },
}

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadMod("scripts/animal/RLMeatValue.lua")
loadAnimalSection("function Animal:getSellPrice()", "function Animal:getDailyRidingTime()")

-- breedTraits priceScale (RLCurveScale scales both price curves in game; the test reads the xml curves).
for _, sub in pairs(byName) do
    local factor = (MEATCHAIN_PRICE_SCALE or {})[sub.name]
        or RLBreedTraits.resolve(RLBreedTraits.getConfig().layers, sub, "priceScale", 1)
    if factor ~= 1 and sub.sellPrice ~= nil then
        local curve = sub.sellPrice
        sub.sellPrice = { get = function(_, age) return curve:get(age) * factor end }
    end
end
if M ~= 1 then
    g_currentMission.missionInfo = {}
    loadMod("scripts/animal/RLLivestockPrices.lua")
end

local function market(meat, factor)
    for name in pairs(FILL) do NOW[name] = PRICE[name] * factor / SEASONAL * M end
    RLMeatValue.resetPriceCache()
end

-- A dealer's animal: its weight is the full-feed growth line at its age, genes average, healthy.
local function dealerAnimal(sub, age)
    local a = { subTypeIndex = sub.index, age = age, gender = sub.gender, targetWeight = sub.targetWeight,
        weight = RLBreedTraits.getGrownWeight(sub, sub.gender, sub.targetWeight, age, 1),
        genetics = { quality = 1, metabolism = 1 }, diseases = {}, isCastrated = false }
    a.getSubType = function() return sub end
    a.isHorse = function() return false end
    a.getHealthFactor = function() return 1 end
    return setmetatable(a, { __index = Animal })
end

-- Net of slaughtering by contract: meat x price - the map's fee per typical animal - cutting per kg.
local function net(sub, kg, price)
    local layers = AnimalMoveEvent.getCarcassConfig().layers
    local typeName = TYPES[sub.typeIndex].name
    local typical = kg / AnimalMoveEvent.getMeatPerHead(typeName)
    return (kg * price - RLBreedTraits.resolve(layers, sub, "slaughterFee", 0) * typical
        - RLBreedTraits.resolve(layers, sub, "processingFeePerKg", 0) * kg) * M
end

local MEAT_OF = { COW = "BEEFMEAT", PIG = "PORKMEAT", SHEEP = "SHEEPGOATMEAT", CHICKEN = "POULTRYMEAT", GOOSE = "GOOSEMEAT", RABBIT = "RABBITMEAT" }
-- Subtype, finishing age (the map butcher's youngest age; ram lambs their real grass-system age, sheep S3),
-- meat kg of a finished animal.
local FINISHED = {
    { "BULL_HOLSTEIN", 17, 259 }, { "BULL_SWISS_BROWN", 20, 267 }, { "BULL_ANGUS", 19.5, 286 },
    { "BULL_LIMOUSIN", 18, 298 }, { "BULL_HEREFORD", 19.5, 267 }, { "BULL_HIGHLAND_CATTLE", 25, 258 },
    { "BULL_WATERBUFFALO", 23, 236 },
    { "BOAR_LANDRACE", 6, 75.0 }, { "BOAR_BERKSHIRE", 6.5, 80.2 }, { "BOAR_BLACK_PIED", 6, 71.3 },
    { "PIG_LANDRACE", 6, 75.0 }, { "PIG_BERKSHIRE", 6.5, 80.2 }, { "PIG_BLACK_PIED", 6, 71.3 },
    { "RAM_LANDRACE", 4.53, 19.2 }, { "RAM_STEINSCHAF", 5.46, 19.03 }, { "RAM_SWISS_MOUNTAIN", 4.76, 19.97 },
    { "RAM_BLACK_WELSH", 5.10, 18.32 }, { "RAM_GOAT", 8, 16.5 },
    { "CHICKEN_ROOSTER", 6, 1.92 }, { "DUCK_MALE", 6, 2.01 }, { "GOOSE_MALE", 10, 4.44 },
    { "RABBIT_MALE", 4, 1.57 }, { "RABBIT", 4, 1.57 },
}

MEATCHAIN_MARGIN = {}
for _, row in ipairs(MEATCHAIN_ROWS or FINISHED) do
    local sub = assert(byName[row[1]], row[1])
    local meat = MEAT_OF[TYPES[sub.typeIndex].name]
    local price = PRICE[meat]
    local animal = dealerAnimal(sub, row[2])
    local kg = RLMeatValue.getMeatKg(animal, sub)
    local reference = sub.targetWeight * RLBreedTraits.resolve(AnimalMoveEvent.getCarcassConfig().layers, sub,
        sub.gender == "male" and "maleMaturity" or "femaleMaturity", 1)

    check(string.format(LABEL .. "%s: at %.1f months weighs %.2f, its reference %.2f", row[1], row[2], animal.weight, reference),
        near(animal.weight / reference, 1, 0.03))
    check(string.format(LABEL .. "%s: %.2f kg of meat (%.2f)", row[1], row[3], kg), near(kg, row[3], row[3] * 0.03))

    -- Over the year: sum of nets / sum of live prices at each month's price.
    local netSum, liveSum, margins = 0, 0, {}
    for period, factor in ipairs(HB_FACTORS) do
        market(meat, factor)
        local live = animal:getSellPrice()
        local n = net(sub, kg, price * factor / SEASONAL)
        margins[period] = n / live - 1
        netSum, liveSum = netSum + n, liveSum + live
    end
    -- Bulls were calibrated on the reference animal (PR #21), not the dealer's growth-line weight: +12.7 to
    -- +14.3% here, so they get a wider band.
    MEATCHAIN_MARGIN[row[1]] = netSum / liveSum
    local band = TYPES[sub.typeIndex].name == "COW" and 0.025 or 0.015
    check(string.format(LABEL .. "%s: contract slaughter +%.1f%% over the year (12 +/- %.1f)", row[1], (netSum / liveSum - 1) * 100, band * 100),
        near(netSum / liveSum, 1.12, band))
    check(string.format(LABEL .. "%s: cheapest month %+.1f%%, peak %+.1f%%, never over +25%%", row[1], margins[6] * 100, margins[11] * 100),
        margins[6] < margins[1] and margins[11] > margins[1] and margins[11] <= 0.25 + 1e-6 and margins[6] > -0.10)

    -- Great demand x1.4 at the peak: the floor caps the gain at maxSlaughterMargin.
    market(meat, 1.21 * 1.4)
    local live = animal:getSellPrice()
    market(meat, 1)
    MEATCHAIN_LIVE = MEATCHAIN_LIVE or {}
    MEATCHAIN_LIVE[LABEL .. row[1]] = animal:getSellPrice()
    market(meat, 1.21 * 1.4)
    check(string.format(LABEL .. "%s: great demand capped at +25%% (%+.1f%%)", row[1], (net(sub, kg, price * 1.21 * 1.4 / SEASONAL) / live - 1) * 100),
        net(sub, kg, price * 1.21 * 1.4 / SEASONAL) / live - 1 <= 0.25 + 1e-6)
end

-- Which sexes follow the meat market: gilts and does (marketFemales) do, ewes and hens do not.
local function swing(name, age)
    local sub = byName[name]
    market(nil, 0.81); local low = RLMeatValue.getMarketFactor(sub, sub.gender)
    market(nil, 1.21); local high = RLMeatValue.getMarketFactor(sub, sub.gender)
    return high - low
end
check(LABEL .. "market: a gilt and a doe rabbit follow the meat market", swing("PIG_LANDRACE") > 0.2 and swing("RABBIT") > 0.2)
check(LABEL .. "market: a ewe, a doe goat and a hen do not", swing("SHEEP_LANDRACE") == 0 and swing("GOAT") == 0 and swing("CHICKEN") == 0)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
