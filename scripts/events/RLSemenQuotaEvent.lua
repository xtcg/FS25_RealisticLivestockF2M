--[[
    RLSemenQuotaEvent
    Server -> clients: straws of the player's own semen the dealer has bought this month, by farm
    and species (RLSemenCollection.quotaUsed), so a client's sale prompt shows what the server will
    take. Broadcast after each sale; the full set goes to a joining client from
    RealisticLivestock_FSBaseMission:sendInitialClientState.
]]

RLSemenQuotaEvent = {}

local RLSemenQuotaEvent_mt = Class(RLSemenQuotaEvent, Event)
InitEventClass(RLSemenQuotaEvent, "RLSemenQuotaEvent")


function RLSemenQuotaEvent.emptyNew()
    return Event.new(RLSemenQuotaEvent_mt)
end


--- @param entries table|nil list of { farmId, typeName, month, used }; nil sends every record
function RLSemenQuotaEvent.new(entries)
    local event = RLSemenQuotaEvent.emptyNew()
    if entries == nil then
        entries = {}
        for farmId, types in pairs(RLSemenCollection.quotaUsed) do
            for typeName, entry in pairs(types) do
                table.insert(entries, { farmId = farmId, typeName = typeName, month = entry.month, used = entry.used })
            end
        end
    end
    event.entries = entries
    return event
end


function RLSemenQuotaEvent:writeStream(streamId, connection)
    streamWriteUInt16(streamId, #self.entries)
    for _, entry in ipairs(self.entries) do
        streamWriteUInt8(streamId, entry.farmId)
        streamWriteString(streamId, entry.typeName)
        streamWriteInt32(streamId, entry.month)
        streamWriteUInt16(streamId, entry.used)
    end
end


function RLSemenQuotaEvent:readStream(streamId, connection)
    self.entries = {}
    for _ = 1, streamReadUInt16(streamId) do
        local farmId = streamReadUInt8(streamId)
        local typeName = streamReadString(streamId)
        local month = streamReadInt32(streamId)
        table.insert(self.entries, { farmId = farmId, typeName = typeName, month = month, used = streamReadUInt16(streamId) })
    end
    self:run(connection)
end


function RLSemenQuotaEvent:run(connection)
    if connection == nil or not connection:getIsServer() or g_server ~= nil then return end
    for _, entry in ipairs(self.entries) do
        RLSemenCollection.setQuotaUsed(entry.farmId, entry.typeName, entry.month, entry.used)
    end
end
