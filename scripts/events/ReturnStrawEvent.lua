ReturnStrawEvent = {}

local ReturnStrawEvent_mt = Class(ReturnStrawEvent, Event)
InitEventClass(ReturnStrawEvent, "ReturnStrawEvent")


function ReturnStrawEvent.emptyNew()

    local self = Event.new(ReturnStrawEvent_mt)
    return self

end


function ReturnStrawEvent.new(object)

	local event = ReturnStrawEvent.emptyNew()

	event.object = object

	return event

end


function ReturnStrawEvent:readStream(streamId, connection)

	self.object = NetworkUtil.readNodeObject(streamId)

	self:run(connection)

end


function ReturnStrawEvent:writeStream(streamId, connection)

	NetworkUtil.writeNodeObject(streamId, self.object)

end


--- From the server: mirror the return. From a remote client: accepted only for a straw the
--- server handed that player from this dewar (RLStrawLedger), so straws cannot be conjured.
function ReturnStrawEvent:run(connection)

	if self.object == nil then return end

	if not connection:getIsServer()
		and not RLStrawLedger.spendForReturn(RLStrawLedger.getUserId(connection), self.object) then
		Log:warning("ReturnStrawEvent:run refused, no straw from dewar=%s on record for this player",
			tostring(self.object.getUniqueId ~= nil and self.object:getUniqueId()))
		return
	end

	self.object:changeStraws(1)

end