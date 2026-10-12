--[[
    RLFacilityAge.lua
    Youngest age a butcher or contract slaughterhouse takes an animal type at, from carcassYield.xml.

    Hof Bergmann's farm butcher (extended production point) and public slaughterhouse (contract
    production) read their animal inputs into `animalsTypeData[typeIndex] = {minimumAge, ...}` at
    load, from the map's XML. Their own animal screen and RLRM's move checks (RLEppAge) both read that
    table. An animal type with `facilityMinAgeMonth` in carcassYield.xml (sheep: 3 months, real lambs
    finish at 12-14 weeks) gets that minimum written into every such table once the placeable is
    added, so the map files stay untouched. Types without the attribute keep the map's value.
    The tables are keyed by animal type, so the minimum is per type (goats share the sheep's): the
    attribute is read from the type element or the file's root, never from a breed or subtype.
]]

RLFacilityAge = {}

local Log = RmLogging.getLogger("RLRM")


--- The configured minimum age for an animal type, or nil.
--- @param typeName string|nil
--- @return number|nil
function RLFacilityAge.getMinAge(typeName)
    if typeName == nil or AnimalMoveEvent == nil or AnimalMoveEvent.getCarcassConfig == nil then return nil end
    local layers = AnimalMoveEvent.getCarcassConfig().layers
    if layers == nil then return nil end
    -- The facility table is per animal type, so only the type and root layers apply (no breed or subtype).
    local value = RLBreedTraits.resolveNamed(layers, typeName:upper(), nil, nil, "facilityMinAgeMonth", nil)
    return type(value) == "number" and value or nil
end


--- Write the configured minimum ages into one animalsTypeData table.
--- @param typeData table|nil animalsTypeData (typeIndex -> entry)
--- @param label string|nil For the log
--- @return number count Entries changed
function RLFacilityAge.applyToTypeData(typeData, label)
    if type(typeData) ~= "table" then return 0 end
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if animalSystem == nil then return 0 end
    local count = 0
    for typeIndex, entry in pairs(typeData) do
        local animalType = animalSystem:getTypeByIndex(typeIndex)
        local minAge = animalType ~= nil and RLFacilityAge.getMinAge(animalType.name) or nil
        if minAge ~= nil and type(entry) == "table" and entry.minimumAge ~= minAge then
            Log:info("RLFacilityAge: %s %s minimum age %s -> %s months", tostring(label), animalType.name,
                tostring(entry.minimumAge), tostring(minAge))
            entry.minimumAge = minAge
            count = count + 1
        end
    end
    return count
end


--- Every animalsTypeData a placeable holds: its own (contract production) and its production
--- point's (extended production point).
--- @param placeable table
--- @return number count Entries changed
function RLFacilityAge.applyToPlaceable(placeable)
    if placeable == nil then return 0 end
    local label = placeable.getName ~= nil and placeable:getName() or "?"
    local count = RLFacilityAge.applyToTypeData(placeable.animalsTypeData, label)
    local epp = placeable.spec_extendedProductionPoint
    local pp = epp ~= nil and epp.productionPoint or nil
    if pp ~= nil and pp.animalsTypeData ~= placeable.animalsTypeData then
        count = count + RLFacilityAge.applyToTypeData(pp.animalsTypeData, label)
    end
    return count
end


--- Every placeable already in the mission (savegame load); new ones go through addPlaceable.
--- @return number count Entries changed
function RLFacilityAge.applyToAll()
    local system = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if system == nil or system.placeables == nil then return 0 end
    local count = 0
    for _, placeable in ipairs(system.placeables) do
        count = count + RLFacilityAge.applyToPlaceable(placeable)
    end
    return count
end


if PlaceableSystem ~= nil and PlaceableSystem.addPlaceable ~= nil then
    PlaceableSystem.addPlaceable = Utils.appendedFunction(PlaceableSystem.addPlaceable, function(_, placeable)
        RmSafeUtils.safeCall("RLFacilityAge.addPlaceable", function() RLFacilityAge.applyToPlaceable(placeable) end)
    end)
end
