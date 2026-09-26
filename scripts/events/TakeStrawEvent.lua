--- Sync straw pickup to the server. Mirror of ReturnStrawEvent with delta -1.
--- Sent by the client after taking a straw from a dewar via the hand tool path.
--- The server's run() calls changeStraws(-1) which raises the dirty flag and
--- auto-deletes the dewar when empty.
TakeStrawEvent = {}

local TakeStrawEvent_mt = Class(TakeStrawEvent, Event)
InitEventClass(TakeStrawEvent, "TakeStrawEvent")


--- @return table self
function TakeStrawEvent.emptyNew()
    Log:trace("TakeStrawEvent.emptyNew")
    local self = Event.new(TakeStrawEvent_mt)
    return self
end


--- @param object table Dewar vehicle (DewarData specialization)
--- @return table self
function TakeStrawEvent.new(object)
	local event = TakeStrawEvent.emptyNew()
	event.object = object
	Log:trace("TakeStrawEvent.new dewar=%s", tostring(object))
	return event
end


--- @param streamId number Network stream id
--- @param connection table Network connection
function TakeStrawEvent:readStream(streamId, connection)
	self.object = NetworkUtil.readNodeObject(streamId)
	Log:trace("TakeStrawEvent:readStream dewar=%s", tostring(self.object))
	self:run(connection)
end


--- @param streamId number Network stream id
--- @param connection table Network connection
function TakeStrawEvent:writeStream(streamId, connection)
	NetworkUtil.writeNodeObject(streamId, self.object)
	Log:trace("TakeStrawEvent:writeStream dewar=%s", tostring(self.object))
end


--- Decrement the dewar's straw count on the receiving side.
--- @param connection table Network connection
function TakeStrawEvent:run(connection)
	if self.object == nil then
		Log:warning("TakeStrawEvent:run dewar is nil (deleted before event arrived)")
		return
	end

	-- From a remote client: hand out a straw only from a stocked dewar of the player's own farm,
	-- and record it so it can later be used or put back (RLStrawLedger). From the server: mirror.
	if not connection:getIsServer() then
		local dewar = self.object
		local farmId = RLStrawLedger.getFarmId(connection)
		if dewar.isDewar ~= true or dewar:getAnimal() == nil or (dewar.straws or 0) <= 0
			or farmId == nil or dewar:getOwnerFarmId() ~= farmId then
			Log:warning("TakeStrawEvent:run refused straw from dewar=%s (farmId=%s owner=%s straws=%s)",
				tostring(dewar.getUniqueId ~= nil and dewar:getUniqueId()), tostring(farmId),
				tostring(dewar.getOwnerFarmId ~= nil and dewar:getOwnerFarmId()), tostring(dewar.straws))
			return
		end
		RLStrawLedger.record(RLStrawLedger.getUserId(connection), dewar)
	end

	self.object:changeStraws(-1)
	Log:debug("TakeStrawEvent:run decremented dewar=%s", tostring(self.object:getUniqueId()))
end
