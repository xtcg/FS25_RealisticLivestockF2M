--[[
    RLBodyConditionConfigEvent
    Server -> joining client: the server's body condition config (xml/bodyCondition.xml or its
    modSettings copy), so a client's displayed finish scores, BCS, yield and price factors use the
    same values the server computes with, whatever file the client has. Sent from
    RealisticLivestock_FSBaseMission:sendInitialClientState.
]]

RLBodyConditionConfigEvent = {}

local RLBodyConditionConfigEvent_mt = Class(RLBodyConditionConfigEvent, Event)
InitEventClass(RLBodyConditionConfigEvent, "RLBodyConditionConfigEvent")


function RLBodyConditionConfigEvent.emptyNew()
    return Event.new(RLBodyConditionConfigEvent_mt)
end


function RLBodyConditionConfigEvent.new(config)
    local event = RLBodyConditionConfigEvent.emptyNew()
    event.config = config
    return event
end


local function sortedKeys(t)
    local keys = {}
    for key, _ in pairs(t) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end


local function writeValues(streamId, values)
    local keys = sortedKeys(values)
    streamWriteUInt8(streamId, #keys)
    for _, key in ipairs(keys) do
        streamWriteString(streamId, key)
        streamWriteFloat32(streamId, values[key])
    end
end


local function readValues(streamId)
    local values = {}
    for _ = 1, streamReadUInt8(streamId) do
        local key = streamReadString(streamId)
        values[key] = streamReadFloat32(streamId)
    end
    return values
end


function RLBodyConditionConfigEvent:writeStream(streamId, connection)
    local config = self.config
    streamWriteBool(streamId, config.enabled == true)

    local values = {}
    for key, _ in pairs(RLBodyConditionConfig.DEFAULTS) do values[key] = config[key] end
    writeValues(streamId, values)

    for _, name in ipairs(RLBodyConditionConfig.CURVES) do
        local points = config.curves[name]
        streamWriteUInt8(streamId, #points)
        for _, point in ipairs(points) do
            streamWriteFloat32(streamId, point[1])
            streamWriteFloat32(streamId, point[2])
        end
    end

    writeValues(streamId, config.feedEnergy)

    local layers = config.layers
    writeValues(streamId, layers.root)
    local typeNames = sortedKeys(layers.types)
    streamWriteUInt8(streamId, #typeNames)
    for _, name in ipairs(typeNames) do
        streamWriteString(streamId, name)
        writeValues(streamId, layers.types[name])
    end
    local breedTypes = sortedKeys(layers.breeds)
    streamWriteUInt8(streamId, #breedTypes)
    for _, typeName in ipairs(breedTypes) do
        streamWriteString(streamId, typeName)
        local breeds = sortedKeys(layers.breeds[typeName])
        streamWriteUInt8(streamId, #breeds)
        for _, breed in ipairs(breeds) do
            streamWriteString(streamId, breed)
            writeValues(streamId, layers.breeds[typeName][breed])
        end
    end
    local subTypes = sortedKeys(layers.subTypes)
    streamWriteUInt8(streamId, #subTypes)
    for _, name in ipairs(subTypes) do
        streamWriteString(streamId, name)
        writeValues(streamId, layers.subTypes[name])
    end

    -- Species sections (sheep): their values, curves and fat classes.
    local species = sortedKeys(config.species or {})
    streamWriteUInt8(streamId, #species)
    for _, name in ipairs(species) do
        local section = config.species[name]
        streamWriteString(streamId, name)
        local sectionValues = {}
        for key, _ in pairs(RLBodyConditionConfig.DEFAULTS) do sectionValues[key] = section[key] end
        for key, _ in pairs(RLBodyConditionConfig.SPECIES_DEFAULTS) do sectionValues[key] = section[key] end
        writeValues(streamId, sectionValues)
        for _, curveName in ipairs(RLBodyConditionConfig.CURVES) do
            local points = section.curves[curveName]
            streamWriteUInt8(streamId, #points)
            for _, point in ipairs(points) do
                streamWriteFloat32(streamId, point[1])
                streamWriteFloat32(streamId, point[2])
            end
        end
        local classes = section.fatClasses or {}
        streamWriteUInt8(streamId, #classes)
        for _, class in ipairs(classes) do
            streamWriteString(streamId, class.name)
            streamWriteFloat32(streamId, class.minReserve)
        end
    end
end


function RLBodyConditionConfigEvent:readStream(streamId, connection)
    local config = { enabled = streamReadBool(streamId), curves = {} }

    for key, value in pairs(readValues(streamId)) do config[key] = value end

    for _, name in ipairs(RLBodyConditionConfig.CURVES) do
        local points = {}
        for _ = 1, streamReadUInt8(streamId) do
            local x = streamReadFloat32(streamId)
            table.insert(points, { x, streamReadFloat32(streamId) })
        end
        config.curves[name] = points
    end

    config.feedEnergy = readValues(streamId)

    local layers = { root = readValues(streamId), types = {}, breeds = {}, subTypes = {} }
    for _ = 1, streamReadUInt8(streamId) do
        local name = streamReadString(streamId)
        layers.types[name] = readValues(streamId)
    end
    for _ = 1, streamReadUInt8(streamId) do
        local typeName = streamReadString(streamId)
        layers.breeds[typeName] = {}
        for _ = 1, streamReadUInt8(streamId) do
            local breed = streamReadString(streamId)
            layers.breeds[typeName][breed] = readValues(streamId)
        end
    end
    for _ = 1, streamReadUInt8(streamId) do
        local name = streamReadString(streamId)
        layers.subTypes[name] = readValues(streamId)
    end
    config.layers = layers

    config.species = {}
    for _ = 1, streamReadUInt8(streamId) do
        local name = streamReadString(streamId)
        local section = readValues(streamId)
        section.curves = {}
        for _, curveName in ipairs(RLBodyConditionConfig.CURVES) do
            local points = {}
            for _ = 1, streamReadUInt8(streamId) do
                local x = streamReadFloat32(streamId)
                table.insert(points, { x, streamReadFloat32(streamId) })
            end
            section.curves[curveName] = points
        end
        section.fatClasses = {}
        for _ = 1, streamReadUInt8(streamId) do
            local className = streamReadString(streamId)
            table.insert(section.fatClasses, { name = className, minReserve = streamReadFloat32(streamId) })
        end
        config.species[name] = section
    end

    self.config = config
    self:run(connection)
end


function RLBodyConditionConfigEvent:run(connection)
    if connection == nil or not connection:getIsServer() or g_server ~= nil then return end
    RLBodyConditionConfig.applyServerConfig(self.config)
end
