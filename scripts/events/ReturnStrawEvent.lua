--[[
    ReturnStrawEvent.lua
    Putting a hand-held straw back into a dewar, confirmed by the server.

    REQUEST (client -> server): the dewar, the client's request id and the straw's claim (its batch,
    sire and the dewar it was taken from). The server checks the player's straw on record
    (RLStrawLedger) against the return rule (RLStrawReturn) and only then adds the straw to the
    dewar; the count reaches every client through the dewar's dirty flag.
    ANSWER (server -> that client): the request id, accepted or the refusal. Accepted uses the held
    straw up; refused gives it back with the reason. A repeated request id gets the first answer
    again and adds nothing.

    A host or single player checks the same rule locally (HandToolAIStraw:onReturnToDewar).
]]

ReturnStrawEvent = {}

local ReturnStrawEvent_mt = Class(ReturnStrawEvent, Event)
InitEventClass(ReturnStrawEvent, "ReturnStrawEvent")

ReturnStrawEvent.MODE_REQUEST = 0
ReturnStrawEvent.MODE_ANSWER = 1

--- Client: held straws waiting for an answer, by request id.
ReturnStrawEvent.pending = {}
ReturnStrawEvent.nextRequestId = 0

--- Server: the last answers per user, by request id, so a repeated request is not applied twice.
ReturnStrawEvent.answered = {}
ReturnStrawEvent.ANSWERS_KEPT = 32


function ReturnStrawEvent.emptyNew()

    local self = Event.new(ReturnStrawEvent_mt)
    return self

end


--- A client's request to put `straw` (its spec: animal, dewarUniqueId) into `object`.
function ReturnStrawEvent.new(object, requestId, straw)

	local event = ReturnStrawEvent.emptyNew()

	event.mode = ReturnStrawEvent.MODE_REQUEST
	event.object = object
	event.requestId = requestId or 0
	local animal = straw ~= nil and straw.animal or {}
	event.claim = {
		batchId = animal.batchId, country = animal.country, farmId = animal.farmId, uniqueId = animal.uniqueId,
		dewarUniqueId = straw ~= nil and straw.dewarUniqueId or nil,
	}

	return event

end


--- The server's answer to request `requestId`: refusal nil = accepted.
function ReturnStrawEvent.newAnswer(requestId, refusal)

	local event = ReturnStrawEvent.emptyNew()

	event.mode = ReturnStrawEvent.MODE_ANSWER
	event.requestId = requestId
	event.refusal = refusal

	return event

end


local function readOptionalString(streamId)
	local value = streamReadString(streamId)
	return value ~= "" and value or nil
end


function ReturnStrawEvent:readStream(streamId, connection)

	self.mode = streamReadUIntN(streamId, 1)
	self.requestId = streamReadInt32(streamId)

	if self.mode == ReturnStrawEvent.MODE_REQUEST then
		self.object = NetworkUtil.readNodeObject(streamId)
		self.claim = {
			batchId = readOptionalString(streamId),
			country = streamReadUInt8(streamId),
			farmId = readOptionalString(streamId),
			uniqueId = readOptionalString(streamId),
			dewarUniqueId = readOptionalString(streamId),
		}
	else
		self.refusal = readOptionalString(streamId)
	end

	self:run(connection)

end


function ReturnStrawEvent:writeStream(streamId, connection)

	streamWriteUIntN(streamId, self.mode, 1)
	streamWriteInt32(streamId, self.requestId)

	if self.mode == ReturnStrawEvent.MODE_REQUEST then
		local claim = self.claim
		NetworkUtil.writeNodeObject(streamId, self.object)
		streamWriteString(streamId, claim.batchId or "")
		streamWriteUInt8(streamId, claim.country or 0)
		streamWriteString(streamId, claim.farmId ~= nil and tostring(claim.farmId) or "")
		streamWriteString(streamId, claim.uniqueId ~= nil and tostring(claim.uniqueId) or "")
		streamWriteString(streamId, claim.dewarUniqueId or "")
	else
		streamWriteString(streamId, self.refusal or "")
	end

end


--- Client: send `handTool`'s straw back to `dewar` and hold it until the server answers.
function ReturnStrawEvent.request(handTool, dewar, straw)

	ReturnStrawEvent.nextRequestId = ReturnStrawEvent.nextRequestId + 1
	local requestId = ReturnStrawEvent.nextRequestId
	ReturnStrawEvent.pending[requestId] = handTool
	g_client:getServerConnection():sendEvent(ReturnStrawEvent.new(dewar, requestId, straw))
	return requestId

end


local function remember(userId, requestId, refusal)
	local list = ReturnStrawEvent.answered[userId]
	if list == nil then
		list = {}
		ReturnStrawEvent.answered[userId] = list
	end
	table.insert(list, { requestId = requestId, refusal = refusal or false })
	if #list > ReturnStrawEvent.ANSWERS_KEPT then table.remove(list, 1) end
end


local function previousAnswer(userId, requestId)
	for _, answer in ipairs(ReturnStrawEvent.answered[userId] or {}) do
		if answer.requestId == requestId then return answer end
	end
	return nil
end


--- Server: check and apply a client's request; the answer goes to that client only.
function ReturnStrawEvent:runRequest(connection)

	local userId = RLStrawLedger.getUserId(connection)
	local dewar = self.object
	local dewarId = dewar ~= nil and dewar.getUniqueId ~= nil and dewar:getUniqueId() or nil

	local previous = previousAnswer(userId, self.requestId)
	if previous ~= nil then
		Log:info("ReturnStrawEvent: repeated request %d from user=%s, answering again without applying",
			self.requestId, tostring(userId))
		connection:sendEvent(ReturnStrawEvent.newAnswer(self.requestId, previous.refusal or nil))
		return
	end

	local spent, refusal = RLStrawLedger.spendForReturn(userId, dewar, self.claim, RLStrawLedger.getFarmId(connection))
	if spent then dewar:changeStraws(1) end

	Log:info("ReturnStrawEvent: request %d user=%s batch=%s from=%s into dewar=%s -> %s (straws=%s)",
		self.requestId, tostring(userId), tostring(self.claim and self.claim.batchId),
		tostring(self.claim and self.claim.dewarUniqueId), tostring(dewarId), refusal or "ACCEPTED",
		tostring(dewar ~= nil and dewar.straws))

	remember(userId, self.requestId, refusal)
	connection:sendEvent(ReturnStrawEvent.newAnswer(self.requestId, refusal))

end


function ReturnStrawEvent:run(connection)

	if self.mode == ReturnStrawEvent.MODE_ANSWER then
		if not connection:getIsServer() then return end
		local handTool = ReturnStrawEvent.pending[self.requestId]
		ReturnStrawEvent.pending[self.requestId] = nil
		if handTool ~= nil and HandToolAIStraw ~= nil then
			HandToolAIStraw.onReturnAnswer(handTool, self.refusal)
		end
		return
	end

	-- A request only ever comes from a client.
	if connection:getIsServer() then return end
	self:runRequest(connection)

end
