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

--- Per-animal trait attributes. All but matureAgeMonth are multipliers, 1 = unchanged. The
--- birth attributes after them are read by RLBirthWeight.
RLBreedTraits.TRAITS = { "feed", "growth", "grass", "hay", "silage", "femaleGrowth", "matureAgeMonth",
    "birthWeightRatio", "maleBirthFactor", "birthWeightCV", "firstBirthFactor",
    "litter2", "litter3", "litter4", "litterBase", "litterStep", "litterMin", "litterMax" }

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


--- Look `attr` up for a subtype: subType, then breed within its type, then type, then root.
--- @param layers table From parseLayers
--- @param subType table|nil
--- @param attr string
--- @param default any Returned when no layer sets it
--- @return any
function RLBreedTraits.resolve(layers, subType, attr, default)
    if subType ~= nil then
        local own = subType.name ~= nil and layers.subTypes[subType.name] or nil
        if own ~= nil and own[attr] ~= nil then return own[attr] end

        local typeName = RLBreedTraits.getTypeName(subType)
        if typeName ~= nil then
            local breeds = layers.breeds[typeName]
            local breed = breeds ~= nil and subType.breed ~= nil and breeds[subType.breed] or nil
            if breed ~= nil and breed[attr] ~= nil then return breed[attr] end

            local animalType = layers.types[typeName]
            if animalType ~= nil and animalType[attr] ~= nil then return animalType[attr] end
        end
    end

    local value = layers.root[attr]
    if value ~= nil then return value end
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
