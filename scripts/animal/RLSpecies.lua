--[[
    RLSpecies.lua
    Which species section of a config an animal, pen, subtype or type name reads. The nutrition
    configs (feedProfiles.xml, bodyCondition.xml) hold the cattle values at their root and may
    hold a <species name="SHEEP"> section of their own; goats (the SHEEP type's GOAT breed) read
    a GOAT section; anything without a section - cattle, every other type, and a breed its type's
    weight profiles exclude (weightProfiles.xml excludeBreeds) - reads the root, the same table as
    before.

    Read only, no engine state changed. The type name is the animal system's (upper case).
]]

RLSpecies = {}

local cache = setmetatable({}, { __mode = "k" })


local function getTypeNameByIndex(typeIndex)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if typeIndex == nil or animalSystem == nil or animalSystem.getTypeByIndex == nil then return nil end
    local animalType = animalSystem:getTypeByIndex(typeIndex)
    return animalType ~= nil and animalType.name ~= nil and animalType.name:upper() or nil
end


--- The species key of a subtype: its type's name, nil for a breed its type's weight profiles
--- exclude (goats) or when the type cannot be named yet (not cached then).
--- @param subType table|nil
--- @return string|nil
function RLSpecies.getSubTypeKey(subType)
    if type(subType) ~= "table" then return nil end
    local cached = cache[subType]
    if cached ~= nil then return cached or nil end
    local typeName = subType.typeName ~= nil and subType.typeName:upper() or nil
    if typeName == nil and RLBreedTraits ~= nil and RLBreedTraits.getTypeName ~= nil then
        typeName = RLBreedTraits.getTypeName(subType)
        typeName = typeName ~= nil and typeName:upper() or nil
    end
    if typeName == nil then return nil end
    local key = typeName
    -- Goats share the SHEEP type but have sections of their own (GOAT): their own growth, milk and
    -- nursing values, never a sheep's (unified nursing design, 2026-10-22). A config without a GOAT
    -- section gives them its root, as before.
    if typeName == "SHEEP" and RLRearingPolicy ~= nil and RLRearingPolicy.getUseNamed(typeName, subType.breed, subType.name) == "DAIRY_GOAT" then
        cache[subType] = "GOAT"
        return "GOAT"
    end
    if RLWeightProfiles ~= nil and RLWeightProfiles.getTypeEntry ~= nil and RLWeightProfiles.isExcludedBreed ~= nil
        and RLWeightProfiles.isExcludedBreed(RLWeightProfiles.getTypeEntry(typeName), subType.breed) then
        key = false
    end
    cache[subType] = key
    return key or nil
end


--- The species key of a subject: a type name (string), an animal, a subtype or a pen.
--- @param subject any
--- @return string|nil
function RLSpecies.getKey(subject)
    local kind = type(subject)
    if kind == "string" then return subject:upper() end
    if kind ~= "table" then return nil end
    if subject.getSubType ~= nil then
        return RLSpecies.getSubTypeKey(subject:getSubType())
    end
    if subject.getAnimalTypeIndex ~= nil then
        return getTypeNameByIndex(subject:getAnimalTypeIndex())
    end
    if subject.typeIndex ~= nil or subject.typeName ~= nil then
        return RLSpecies.getSubTypeKey(subject)
    end
    return nil
end


--- The section of a config for a subject: config.species[key] when the config has one, else the
--- config itself (its root).
--- @param config table A config with an optional `species` table of sections
--- @param subject any
--- @return table
function RLSpecies.select(config, subject)
    local sections = config ~= nil and config.species or nil
    if sections == nil or next(sections) == nil or subject == nil then return config end
    local key = RLSpecies.getKey(subject)
    local section = key ~= nil and sections[key] or nil
    return section or config
end


--- Forget cached subtype keys (after the weight profiles are replaced).
function RLSpecies.resetCache()
    cache = setmetatable({}, { __mode = "k" })
end
