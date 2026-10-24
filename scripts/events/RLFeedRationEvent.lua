--[[
    RLFeedRationEvent
    A cattle pen's ration settings for the real-equivalent nutrition mode (RLFeed): what its
    animals eat for (AUTO / FINISH / GROW / MAINTAIN), which concentrate (AUTO, a grain, NONE),
    the concentrate share target (none: as much as the ration rules allow) and whether another
    grain may stand in for the chosen one.

    Client -> server: checked (the pen owner's farm with the tradeAnimals permission, values in
    range), applied, then sent to every client, the asking one included. Server -> clients:
    applied as sent. A server or single player applies it directly (RLFeedRationEvent.sendEvent).
]]

RLFeedRationEvent = {}

local Log = RmLogging.getLogger("RLRM")

local RLFeedRationEvent_mt = Class(RLFeedRationEvent, Event)
InitEventClass(RLFeedRationEvent, "RLFeedRationEvent")


function RLFeedRationEvent.emptyNew()
    return Event.new(RLFeedRationEvent_mt)
end


--- @param object table The cattle pen
--- @param ration table { target, grain, share (nil: as much as allowed), substitute }
function RLFeedRationEvent.new(object, ration)
    local event = RLFeedRationEvent.emptyNew()
    event.object = object
    event.ration = ration
    return event
end


function RLFeedRationEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    RLFeed.writeRationStream(self.ration or RLFeed.DEFAULT_RATION, streamId)
end


function RLFeedRationEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.ration, self.valid = RLFeed.readRationStream(streamId)
    self:run(connection)
end


function RLFeedRationEvent:run(connection)
    local object = self.object
    if object == nil or object.spec_husbandryFood == nil then
        Log:warning("RLFeedRationEvent: no cattle pen (removed while the event was on its way?); dropped")
        return
    end

    if connection ~= nil and not connection:getIsServer() then
        local ownerFarmId = object.getOwnerFarmId ~= nil and object:getOwnerFarmId() or nil
        local ok, reason, userName = RLPermissionHelper.authorizeConnection(connection, "tradeAnimals", ownerFarmId)
        if not ok then
            Log:warning("RLFeedRationEvent: %s for user '%s' on a pen of farm %s; dropped", tostring(reason), tostring(userName),
                tostring(ownerFarmId))
            return
        end
        -- The pen must run the mode's rations at all: the dialog is read-only otherwise, and a
        -- client's request is not taken on trust (UI-RATION-01).
        if not RLFeed.isNutritionPen(object) then
            Log:warning("RLFeedRationEvent: %s from user '%s' for '%s'; dropped",
                "NOT_NUTRITION_PEN", tostring(userName),
                object.getName ~= nil and tostring(object:getName()) or "?")
            return
        end
        local _, valid = RLFeed.sanitizeRation(self.ration)
        if not valid or self.valid == false then
            Log:warning("RLFeedRationEvent: ration values out of range from user '%s'; dropped", tostring(userName))
            return
        end
        RLFeed.setRation(object, self.ration)
        -- Every client, the one that asked too: it shows what the server applied.
        g_server:broadcastEvent(RLFeedRationEvent.new(object, RLFeed.getRation(object)), nil, nil, object)
        return
    end

    RLFeed.setRation(object, self.ration)
end


--- Change a pen's ration settings from wherever this runs: a server applies them and tells the
--- clients, a client asks the server.
function RLFeedRationEvent.sendEvent(object, ration)
    if g_server ~= nil then
        RLFeed.setRation(object, ration)
        g_server:broadcastEvent(RLFeedRationEvent.new(object, RLFeed.getRation(object)), nil, nil, object)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(RLFeedRationEvent.new(object, ration))
    end
end
