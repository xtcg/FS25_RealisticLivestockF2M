--[[
    RLPedigreeStateEvent
    Server -> joining client: the pedigree registry (RLPedigree), so a client's inbreeding check
    in the AI dialog and the straw prompt reaches the same sold or dead ancestors the server's does.
    Animals streamed afterwards are recorded by the client itself. Sent from
    RealisticLivestock_FSBaseMission:sendInitialClientState.
]]

RLPedigreeStateEvent = {}

local RLPedigreeStateEvent_mt = Class(RLPedigreeStateEvent, Event)
InitEventClass(RLPedigreeStateEvent, "RLPedigreeStateEvent")


function RLPedigreeStateEvent.emptyNew()
    return Event.new(RLPedigreeStateEvent_mt)
end


function RLPedigreeStateEvent.new()
    return RLPedigreeStateEvent.emptyNew()
end


function RLPedigreeStateEvent:writeStream(streamId, connection)
    RLPedigree.writeStream(streamId)
end


function RLPedigreeStateEvent:readStream(streamId, connection)
    if g_server ~= nil then
        -- A listen host never receives its own push; read past the payload without touching state.
        local count = streamReadInt32(streamId)
        for _ = 1, count * 3 do streamReadString(streamId) end
        return
    end
    RLPedigree.readStream(streamId)
end
