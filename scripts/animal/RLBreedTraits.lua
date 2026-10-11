--[[
    RLBreedTraits.lua
    Breed husbandry traits read from xml/breedTraits.xml: how much a breed eats, how well it
    turns feed into weight, and how well it uses grass, hay and silage/TMR.

    Also holds the layered lookup the carcass yield config (xml/carcassYield.xml) shares: a
    value is looked up by subType name first, then by breed within the animal type, then by
    animal type, then on the root element.
]]

RLBreedTraits = {}

local Log = RmLogging.getLogger("RLRM")

RLBreedTraits.CONFIG_FILE = "breedTraits.xml"

--- Per-animal trait attributes. All but matureAgeMonth, priceTargetWeight and priceMatureAgeMonth are
--- multipliers, 1 = unchanged.
RLBreedTraits.TRAITS = { "feed", "growth", "grass", "hay", "silage", "femaleGrowth", "matureAgeMonth",
    "priceTargetWeight", "priceMatureAgeMonth" }

--- Female growth relative to male, where the file sets none (the mod's original rule).
RLBreedTraits.DEFAULT_FEMALE_GROWTH = 0.6

--- Forage categories a food fill type can count as. Anything else eats at efficiency 1.
RLBreedTraits.FORAGE_CATEGORIES = { "grass", "hay", "silage" }

--- Used for whatever the file leaves out.
RLBreedTraits.DEFAULTS = {
    growthNutritionFactor = 1.10,
    bodyWeightExponent = 0.35,
    minBodyRatio = 0.5,
    maxBodyRatio = 1.5,
}

local modDirectory = g_currentModDirectory
local modSettingsDirectory = g_currentModSettingsDirectory


-- =============================================================================
-- Layered lookup, shared with the carcass yield config
-- =============================================================================

--- Read `attributes` from the root element, each animalType(name) with its breed(name)
--- children, and each subType(name). Names are upper-cased.
--- @param xmlFile table|nil
--- @param root string Root element name
--- @param attributes table List of float attribute names
--- @return table layers {root, types, breeds[type][breed], subTypes}
function RLBreedTraits.parseLayers(xmlFile, root, attributes)
    local layers = { root = {}, types = {}, breeds = {}, subTypes = {} }
    if xmlFile == nil then return layers end

    local function read(key)
        local values = {}
        for _, attr in ipairs(attributes) do
            local value = xmlFile:getFloat(key .. "#" .. attr)
            if value ~= nil then
                if value < 0 then
                    Log:warning("RLBreedTraits.parseLayers: %s#%s is negative, ignored", key, attr)
                else
                    values[attr] = value
                end
            end
        end
        return values
    end

    local function name(key)
        local value = xmlFile:getString(key .. "#name")
        if value == nil then Log:warning("RLBreedTraits.parseLayers: %s has no name, ignored", key) end
        return value ~= nil and value:upper() or nil
    end

    layers.root = read(root)

    xmlFile:iterate(root .. ".animalType", function(_, typeKey)
        local typeName = name(typeKey)
        if typeName == nil then return end
        layers.types[typeName] = read(typeKey)
        layers.breeds[typeName] = layers.breeds[typeName] or {}
        xmlFile:iterate(typeKey .. ".breed", function(_, breedKey)
            local breed = name(breedKey)
            if breed ~= nil then layers.breeds[typeName][breed] = read(breedKey) end
        end)
    end)

    xmlFile:iterate(root .. ".subType", function(_, subTypeKey)
        local subTypeName = name(subTypeKey)
        if subTypeName ~= nil then layers.subTypes[subTypeName] = read(subTypeKey) end
    end)

    return layers
end


--- The animal type name of a subtype, or nil.
--- @param subType table|nil
--- @return string|nil
function RLBreedTraits.getTypeName(subType)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if subType == nil or animalSystem == nil then return nil end
    local animalType = animalSystem:getTypeByIndex(subType.typeIndex)
    return animalType ~= nil and animalType.name or nil
end


--- Look `attr` up for a subtype and say which layer set it: subType, then breed within its type,
--- then type, then root.
--- @param layers table From parseLayers
--- @param subType table|nil
--- @param attr string
--- @return any value nil when no layer sets it
--- @return string|nil source "subType", "breed", "type" or "root"; nil when no layer sets it
function RLBreedTraits.resolveSource(layers, subType, attr)
    if subType ~= nil then
        local own = subType.name ~= nil and layers.subTypes[subType.name] or nil
        if own ~= nil and own[attr] ~= nil then return own[attr], "subType" end

        local typeName = RLBreedTraits.getTypeName(subType)
        if typeName ~= nil then
            local breeds = layers.breeds[typeName]
            local breed = breeds ~= nil and subType.breed ~= nil and breeds[subType.breed] or nil
            if breed ~= nil and breed[attr] ~= nil then return breed[attr], "breed" end

            local animalType = layers.types[typeName]
            if animalType ~= nil and animalType[attr] ~= nil then return animalType[attr], "type" end
        end
    end

    local value = layers.root[attr]
    if value ~= nil then return value, "root" end
    return nil, nil
end


--- Look `attr` up for a subtype: subType, then breed within its type, then type, then root.
--- @param layers table From parseLayers
--- @param subType table|nil
--- @param attr string
--- @param default any Returned when no layer sets it
--- @return any
function RLBreedTraits.resolve(layers, subType, attr, default)
    if subType == nil then return RLBreedTraits.resolveNamed(layers, nil, nil, nil, attr, default) end
    return RLBreedTraits.resolveNamed(layers, RLBreedTraits.getTypeName(subType), subType.breed, subType.name, attr, default)
end


--- The same lookup by names, for callers without a live subtype (the dealer draws a breed before a
--- subtype): subTypeName, then breed within typeName, then typeName, then root. Any name may be nil;
--- a layers table without a root skips it.
--- @return any
function RLBreedTraits.resolveNamed(layers, typeName, breed, subTypeName, attr, default)
    local own = subTypeName ~= nil and layers.subTypes[subTypeName] or nil
    if own ~= nil and own[attr] ~= nil then return own[attr] end

    if typeName ~= nil then
        local breeds = layers.breeds[typeName]
        local breedLayer = breeds ~= nil and breed ~= nil and breeds[breed] or nil
        if breedLayer ~= nil and breedLayer[attr] ~= nil then return breedLayer[attr] end

        local animalType = layers.types[typeName]
        if animalType ~= nil and animalType[attr] ~= nil then return animalType[attr] end
    end

    if layers.root ~= nil and layers.root[attr] ~= nil then return layers.root[attr] end
    return default
end


--- Load a config from this mod's xml folder, or from the mod's modSettings folder when a copy
--- is there (it then replaces the shipped file).
--- @param fileName string
--- @param root string Root element name
--- @param parse function(xmlFile|nil) -> config
--- @return table config
function RLBreedTraits.loadConfig(fileName, root, parse)
    local path = modDirectory .. "xml/" .. fileName
    if modSettingsDirectory ~= nil and fileExists(modSettingsDirectory .. fileName) then
        path = modSettingsDirectory .. fileName
    end

    local xmlFile = XMLFile.loadIfExists(root, path)
    if xmlFile == nil then
        Log:warning("RLBreedTraits.loadConfig: %s not found, using defaults", path)
    end
    local config = parse(xmlFile)
    if xmlFile ~= nil then xmlFile:delete() end
    Log:info("RLBreedTraits.loadConfig: loaded %s", path)

    return config
end


-- =============================================================================
-- Breed traits
-- =============================================================================

--- Read a breed traits config.
--- @param xmlFile table|nil An XMLFile with a breedTraits root; nil gives the defaults
--- @return table config {growthNutritionFactor, bodyWeightExponent, minBodyRatio, maxBodyRatio, layers, forage}
function RLBreedTraits.parseConfig(xmlFile)
    local config = table.clone(RLBreedTraits.DEFAULTS)
    config.forage = {}

    if xmlFile ~= nil then
        for key, default in pairs(RLBreedTraits.DEFAULTS) do
            config[key] = xmlFile:getFloat("breedTraits#" .. key, default)
        end

        xmlFile:iterate("breedTraits.forage.category", function(_, key)
            local category = xmlFile:getString(key .. "#name")
            local fillTypes = xmlFile:getString(key .. "#fillTypes")
            if category == nil or fillTypes == nil then
                Log:warning("RLBreedTraits.parseConfig: %s needs a name and fillTypes", key)
                return
            end
            for fillTypeName in fillTypes:gmatch("%S+") do config.forage[fillTypeName:upper()] = category end
        end)
    end

    config.layers = RLBreedTraits.parseLayers(xmlFile, "breedTraits", RLBreedTraits.TRAITS)

    return config
end


--- The breed traits config, loaded on the first call.
--- @return table config See parseConfig
function RLBreedTraits.getConfig()
    if RLBreedTraits.config == nil then
        RLBreedTraits.config = RLBreedTraits.loadConfig(RLBreedTraits.CONFIG_FILE, "breedTraits", RLBreedTraits.parseConfig)
    end
    return RLBreedTraits.config
end


--- A breed trait multiplier for a subtype; 1 when nothing sets it.
--- @param subType table|nil
--- @param trait string One of RLBreedTraits.TRAITS
--- @return number
function RLBreedTraits.get(subType, trait)
    return RLBreedTraits.resolve(RLBreedTraits.getConfig().layers, subType, trait, 1)
end


--- Time scale of growth in months: updateWeight's base gain is (target - minWeight) / this per
--- month, before breed growth, femaleGrowth, age and nutrition change the actual rate. It is also
--- the age at which the expected weight for age (food, sale value, newly generated animals)
--- reaches the target. matureAgeMonth when set, else 1.5 x the subtype's reproductionMinAgeMonth
--- (the mod's original rule).
--- @param subType table|nil
--- @return number months, 0 when unknown
function RLBreedTraits.getMatureAge(subType)
    if subType == nil then return 0 end
    local default = (subType.reproductionMinAgeMonth or 0) * 1.5
    return RLBreedTraits.resolve(RLBreedTraits.getConfig().layers, subType, "matureAgeMonth", default)
end


--- Growth of a female relative to a male of the subtype (femaleGrowth, default 0.6).
--- @param subType table|nil
--- @return number
function RLBreedTraits.getFemaleGrowth(subType)
    return RLBreedTraits.resolve(RLBreedTraits.getConfig().layers, subType, "femaleGrowth",
        RLBreedTraits.DEFAULT_FEMALE_GROWTH)
end


--- Weight an animal on the growth line has at `age`: from the subtype's minWeight to
--- `targetWeight` by getMatureAge, then flat.
--- @param subType table
--- @param targetWeight number
--- @param age number|nil Months; nil counts as grown
--- @return number
function RLBreedTraits.getExpectedWeight(subType, targetWeight, age)
    local minWeight = subType.minWeight or 0
    local matureAge = RLBreedTraits.getMatureAge(subType)
    local grown = matureAge > 0 and math.clamp((age or matureAge) / matureAge, 0, 1) or 1
    return minWeight + (targetWeight - minWeight) * grown
end


--- Oldest age in months the dealer normally offers an animal of this subtype and sex at
--- (maleMaxSaleAgeMonth / femaleMaxSaleAgeMonth); nil when the file sets none (no limit but the
--- animal type's maxBuyAge). Older stock is offered only when its genetics are elite
--- (isEliteForSale): a breeder sells a grown animal only when it is worth more than a young one.
--- @param subType table|nil
--- @param gender string|nil
--- @return number|nil
function RLBreedTraits.getMaxSaleAge(subType, gender)
    if subType == nil then return nil end
    local trait = (gender or subType.gender) == "male" and "maleMaxSaleAgeMonth" or "femaleMaxSaleAgeMonth"
    return RLBreedTraits.resolve(RLBreedTraits.getConfig().layers, subType, trait, nil)
end


--- Whether a dealer animal's genetics are good enough to be offered past its maximum sale age: the
--- mean of its genes at least eliteSaleGenetics (1.45 by default, about the best 11% of the dealer's draw).
--- @param genetics table|nil
--- @return boolean
function RLBreedTraits.isEliteForSale(genetics)
    if type(genetics) ~= "table" then return false end
    local total, count = 0, 0
    for _, value in pairs(genetics) do
        if type(value) == "number" then total, count = total + value, count + 1 end
    end
    return count > 0 and total / count >= RLBreedTraits.getConfig().eliteSaleGenetics
end


--- A growth line's mature age and its monthly gain before the age factor: base gain
--- (targetWeight - minWeight) / mature age x sex x metabolism x breed growth.
local function getLineRate(subType, gender, targetWeight, metabolism)
    local matureAge = RLBreedTraits.getMatureAge(subType)
    if matureAge <= 0 then return 0, 0 end
    local sex = gender == "female" and RLBreedTraits.getFemaleGrowth(subType) or 1
    return matureAge, (targetWeight - (subType.minWeight or 0)) / matureAge * sex * (metabolism or 1)
        * RLBreedTraits.get(subType, "growth")
end


--- Monthly gain of the full-feed growth line of an intact, healthy animal at `age`: base gain
--- (targetWeight - minWeight) / mature age x sex x age factor x metabolism x breed growth. The age
--- factor 1 + (mature age - age) / 75 runs down to 0 and stays there (RLWeightMath), so the line
--- never loses weight with age. Animal:updateWeight and the body condition budget scale this by
--- what the animal ate, castration, a milking cow and disease.
--- @param subType table
--- @param gender string|nil "female" grows at getFemaleGrowth
--- @param targetWeight number The animal's own target weight
--- @param age number Months
--- @param metabolism number|nil Metabolism gene, default 1
--- @return number kg per period (>= 0)
function RLBreedTraits.getLineGain(subType, gender, targetWeight, age, metabolism)
    local matureAge, rate = getLineRate(subType, gender, targetWeight, metabolism)
    if matureAge <= 0 then return 0 end
    return math.max(rate * RLWeightMath.getAgeGrowthFactor(age, matureAge), 0)
end


--- Sum of the age factor over the line's months up to `age`: whole months k = 0 .. n-1 at their
--- start (1 + (matureAge - k) / 75, never below 0) and the part month from n = floor(age) at month
--- n's factor - what a month-by-month step from birth adds up. In closed form: the factor is
--- positive for k <= floor(matureAge + 75) and falls by 1/75 a month, an arithmetic series.
local function getAgeFactorSum(age, matureAge)
    local n = math.floor(age)
    local months = math.min(n, math.floor(matureAge + RLWeightMath.AGE_FACTOR_MONTHS) + 1)
    local first = RLWeightMath.getAgeGrowthFactor(0, matureAge)
    local whole = months > 0 and months * first - months * (months - 1) / (2 * RLWeightMath.AGE_FACTOR_MONTHS) or 0
    return whole + RLWeightMath.getAgeGrowthFactor(n, matureAge) * (age - n)
end


--- The full-feed growth line at `age`: its weight, from the subtype's minWeight, month by month at
--- getLineGain (the gain at the start of each month) and never above `targetWeight`, and what it
--- gains in the month from `age` on. Gains are never negative, so capping at the target once is
--- capping it every month; the weight is minWeight + base rate x getAgeFactorSum, O(1) at any age.
--- @param subType table
--- @param gender string|nil
--- @param targetWeight number The animal's own target weight
--- @param age number Months
--- @param metabolism number|nil
--- @return number weight kg at `age`
--- @return number nextGain kg the line gains from `age` to `age` + 1 month
function RLBreedTraits.getGrownLine(subType, gender, targetWeight, age, metabolism)
    local minWeight = subType.minWeight or 0
    local matureAge, rate = getLineRate(subType, gender, targetWeight, metabolism)
    if matureAge <= 0 or targetWeight <= minWeight then return minWeight, 0 end

    age = math.max(age or 0, 0)
    local weight = math.min(minWeight + rate * getAgeFactorSum(age, matureAge), targetWeight)
    local after = math.min(minWeight + rate * getAgeFactorSum(age + 1, matureAge), targetWeight)
    return weight, after - weight
end


--- Weight an animal raised on full feed has at `age` (the weight of getGrownLine): the same monthly
--- gain as Animal:updateWeight at full feed, starting at the subtype's minWeight and never above
--- `targetWeight`. Used for animals that appear with no weight of their own (the dealer's stock, a
--- new game's herds), so that a bull of finishing age arrives at about the weight one raised in the
--- pen reaches, not on the slower expected-weight line above, and as the line live prices are read
--- against.
--- @param subType table
--- @param gender string|nil "female" grows at getFemaleGrowth
--- @param targetWeight number The animal's own target weight
--- @param age number Months
--- @param metabolism number|nil Metabolism gene, default 1
--- @return number
function RLBreedTraits.getGrownWeight(subType, gender, targetWeight, age, metabolism)
    return (RLBreedTraits.getGrownLine(subType, gender, targetWeight, age, metabolism))
end


--- Weight of an animal that appears with none of its own (the dealer's stock, a new game's herds): the
--- full-feed growth line at its age (getGrownWeight) +/-15%, never above the animal's own target
--- weight. A grown animal is at its mature weight, never above it. The subtype's minWeight is the
--- line's birth weight, not a floor: a newborn's draw keeps its whole 85-115% spread.
--- @param subType table
--- @param gender string|nil
--- @param targetWeight number The animal's own target weight
--- @param age number Months
--- @param metabolism number|nil
--- @param randomFn function|nil `function(lo, hi) -> int`, default math.random
--- @return number
function RLBreedTraits.getNewAnimalWeight(subType, gender, targetWeight, age, metabolism, randomFn)
    local grown = RLBreedTraits.getGrownWeight(subType, gender, targetWeight, age, metabolism)
    local variation = (randomFn or math.random)(85, 115) / 100
    local maxWeight = math.min(subType.maxWeight or targetWeight, targetWeight)
    return math.min(grown * variation, maxWeight)
end


--- An individual target weight under the old rules: a target moved by 0.4 x (metabolism - 1),
--- target + (target x metabolism - target) / 2.5. The live price, the feed request and the
--- old full-feed line were calibrated on it.
--- @param target number kg
--- @param metabolism number|nil
--- @return number kg
function RLBreedTraits.getGeneTarget(target, metabolism)
    target = target or 0
    return target + ((target * (metabolism or 1)) - target) / 2.5
end


--- The reference line live prices measure weight against: target weight and mature age (months)
--- from priceTargetWeight / priceMatureAgeMonth; nil for a subtype that sets neither, whose price
--- then uses its own target weight and mature age.
--- @param subType table|nil
--- @return number|nil priceTargetWeight
--- @return number|nil priceMatureAge
function RLBreedTraits.getPriceModel(subType)
    if subType == nil then return nil end
    local layers = RLBreedTraits.getConfig().layers
    local target = RLBreedTraits.resolve(layers, subType, "priceTargetWeight", nil)
    local matureAge = RLBreedTraits.resolve(layers, subType, "priceMatureAgeMonth", nil)
    if target == nil or matureAge == nil or target <= 0 or matureAge <= 0 then return nil end
    return target, matureAge
end


--- An animal's weight on the live-price reference line: its share of the full-feed growth line at
--- its age, applied to the price line's weight for that age (from birth weight to priceTargetWeight
--- by priceMatureAgeMonth, then flat, as animals with no weight of their own once got theirs). An
--- animal on the growth line weighs what the price line says for its age, so a change to target
--- weights, maturity or growth does not move its price. Unchanged for a subtype with no price line.
--- @param subType table
--- @param gender string|nil
--- @param targetWeight number The animal's own target weight
--- @param age number Months
--- @param metabolism number|nil
--- @param weight number The animal's weight
--- @return number
function RLBreedTraits.toPriceWeight(subType, gender, targetWeight, age, metabolism, weight)
    local priceTarget = RLBreedTraits.getPriceModel(subType)
    if priceTarget == nil then return weight end

    local line = RLBreedTraits.getGrownWeight(subType, gender, targetWeight, age, metabolism)
    if line <= 0 then return weight end

    return weight * RLBreedTraits.getPriceLineWeight(subType, age) / line
end


--- Weight on the live-price reference line at `age`: from the subtype's minWeight toward
--- priceTargetWeight at its rate (reached at priceMatureAgeMonth), rising on at that rate until
--- max(priceMatureAgeMonth, 20) months and flat after; nil for a subtype without a price line.
--- (A line that matures before 20 months runs past priceTargetWeight to month 20: the prices
--- were calibrated so.)
--- @param subType table
--- @param age number Months
--- @return number|nil
function RLBreedTraits.getPriceLineWeight(subType, age)
    local priceTarget, priceMatureAge = RLBreedTraits.getPriceModel(subType)
    if priceTarget == nil then return nil end
    local minWeight = subType.minWeight or 0
    return minWeight + (priceTarget - minWeight) / priceMatureAge * math.clamp(age, 0, math.max(priceMatureAge, 20))
end


--- Food multiplier for an animal's body condition: (weight / expected weight for its age)
--- ^ bodyWeightExponent, the expected weight from getExpectedWeight with the animal's own target,
--- so the age curve in the subtype's food input is not counted twice. The ratio is clamped to
--- minBodyRatio..maxBodyRatio.
--- @param subType table|nil
--- @param weight number|nil
--- @param targetWeight number|nil The animal's own target weight
--- @param age number|nil Months
--- @return number
function RLBreedTraits.getBodyFeedFactor(subType, weight, targetWeight, age)
    if subType == nil or weight == nil or targetWeight == nil or targetWeight <= 0 then return 1 end

    local config = RLBreedTraits.getConfig()
    local expected = RLBreedTraits.getExpectedWeight(subType, targetWeight, age)
    if expected <= 0 then return 1 end

    local ratio = math.clamp(weight / expected, config.minBodyRatio, config.maxBodyRatio)
    return ratio ^ config.bodyWeightExponent
end


--- Share of the food a pen ate in one feeding per forage category, from the food fill levels
--- before and after it. Fill types in no category count toward the total only.
--- @param before table fillTypeIndex -> liters
--- @param after table|nil fillTypeIndex -> liters
--- @param hasMeadow boolean The pen has its own meadow; a feeding that ate nothing from the
---        trough is then counted as grass
--- @return table|nil shares category -> 0..1; nil when nothing was eaten and there is no meadow
function RLBreedTraits.getForageShares(before, after, hasMeadow)
    local forage = RLBreedTraits.getConfig().forage
    local shares, total = {}, 0

    for fillTypeIndex, level in pairs(before) do
        local eaten = level - ((after ~= nil and after[fillTypeIndex]) or 0)
        if eaten > 0 then
            total = total + eaten
            local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
            local category = name ~= nil and forage[name:upper()] or nil
            if category ~= nil then shares[category] = (shares[category] or 0) + eaten end
        end
    end

    if total <= 0 then return hasMeadow and { grass = 1 } or nil end

    for category, eaten in pairs(shares) do shares[category] = eaten / total end
    return shares
end


--- How well a subtype uses what its pen ate: the forage shares weighted by the breed's grass,
--- hay and silage traits; the rest of the ration counts at 1.
--- @param subType table|nil
--- @param shares table|nil From getForageShares
--- @return number
function RLBreedTraits.getForageEfficiency(subType, shares)
    if shares == nil then return 1 end

    local efficiency, covered = 0, 0
    for _, category in ipairs(RLBreedTraits.FORAGE_CATEGORIES) do
        local share = shares[category]
        if share ~= nil and share > 0 then
            efficiency = efficiency + share * RLBreedTraits.get(subType, category)
            covered = covered + share
        end
    end

    return efficiency + math.max(1 - covered, 0)
end
