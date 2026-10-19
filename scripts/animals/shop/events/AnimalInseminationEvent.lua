AnimalInseminationEvent = {}

local AnimalInseminationEvent_mt = Class(AnimalInseminationEvent, Event)
InitEventClass(AnimalInseminationEvent, "AnimalInseminationEvent")


function AnimalInseminationEvent.emptyNew()

    local self = Event.new(AnimalInseminationEvent_mt)
    return self

end


function AnimalInseminationEvent.new(object, animal, semen)

	local event = AnimalInseminationEvent.emptyNew()

	event.object = object
	event.animal = animal
	event.semen = semen

	return event

end


function AnimalInseminationEvent:readStream(streamId, connection)

	self.object = NetworkUtil.readNodeObject(streamId)
	self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
	
	self.semen = { ["genetics"] = {} }

	self.semen.country = streamReadUInt8(streamId)
	self.semen.farmId = streamReadString(streamId)
	self.semen.uniqueId = streamReadString(streamId)
	self.semen.name = streamReadString(streamId)
	self.semen.typeIndex = streamReadUInt8(streamId)
	self.semen.subTypeIndex = streamReadUInt8(streamId)
	self.semen.success = streamReadFloat32(streamId)

	self.semen.genetics.metabolism = streamReadFloat32(streamId)
	self.semen.genetics.fertility = streamReadFloat32(streamId)
	self.semen.genetics.health = streamReadFloat32(streamId)
	self.semen.genetics.quality = streamReadFloat32(streamId)
	self.semen.genetics.productivity = streamReadFloat32(streamId)

	if self.semen.genetics.productivity < 0 then self.semen.genetics.productivity = nil end
	RLSemenBatch.readStream(streamId, self.semen)

	Log:trace("InseminationEvent:readStream semen.country=%s", tostring(self.semen.country))

	self:run(connection)

end


function AnimalInseminationEvent:writeStream(streamId, connection)

	NetworkUtil.writeNodeObject(streamId, self.object)
	RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)

	local semen = self.semen

	streamWriteUInt8(streamId, semen.country)
	streamWriteString(streamId, semen.farmId)
	streamWriteString(streamId, semen.uniqueId)
	streamWriteString(streamId, semen.name or "")
	streamWriteUInt8(streamId, semen.typeIndex)
	streamWriteUInt8(streamId, semen.subTypeIndex)
	streamWriteFloat32(streamId, semen.success)

	streamWriteFloat32(streamId, semen.genetics.metabolism)
	streamWriteFloat32(streamId, semen.genetics.fertility)
	streamWriteFloat32(streamId, semen.genetics.health)
	streamWriteFloat32(streamId, semen.genetics.quality)
	streamWriteFloat32(streamId, semen.genetics.productivity or -1)
	RLSemenBatch.writeStream(streamId, semen)

end


--- Execute the event on the receiver.
---
--- Pattern A flow (caller-mutates-first + rebroadcast-from-run + ignoreConnection=sender):
---   * Caller (HandToolAIStraw:onInseminate) calls animal:setInsemination locally BEFORE sendEvent.
---   * Server branch (`not connection:getIsServer()`): apply mutation (idempotent),
---     then rebroadcast to other clients with ignoreConnection=sender.
---   * Client branch (`connection:getIsServer()`): apply mutation locally, no rebroadcast.
---
--- No dewar decrement happens here - this event is the hand-tool path; the straw
--- was already drained from its dewar when the hand-tool was filled, and the
--- hand-tool itself is consumed via markHandToolForDeletion.
---@param connection table Network connection the event arrived on
function AnimalInseminationEvent:run(connection)

	RmSafeUtils.safeCall("AnimalInseminationEvent:run", function()

		local clusterSystem = self.object:getClusterSystem()
		local identifiers = self.animal

		local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)
		local isServerBranch = not connection:getIsServer()
		Log:trace("InseminationEvent:run branch=%s animal=%s", isServerBranch and "server" or "client", tostring(identifiers.uniqueId))

		if isServerBranch then
			-- Server-authoritative order; nothing is spent or rebroadcast until every check passed:
			-- 1. The animal must exist here; without it there is nothing to compensate, and a
			--    rebroadcast would let other clients apply what the server never did.
			if animal == nil then
				Log:warning("InseminationEvent:run animal not found uniqueId=%s, NOT rebroadcasting (server-authoritative reject)",
					tostring(identifiers.uniqueId))
				return
			end

			-- 2. One pending insemination at a time: a second player's straw arriving after the
			--    first must not replace it (nor spend a second straw).
			if animal.insemination ~= nil then
				Log:info("InseminationEvent:run refused uniqueId=%s: already inseminated", tostring(identifiers.uniqueId))
				return
			end

			-- 3. The straw must be one the server handed this player (RLStrawLedger). Its recorded
			--    sire and batch replace what the client sent, so every later check and the
			--    insemination itself use the server's sire.
			local userId = RLStrawLedger.getUserId(connection)
			local semen = RLStrawLedger.findForSemen(userId, self.semen)
			if semen == nil then
				Log:warning("InseminationEvent:run: refused, no straw of sire %s on record for this player",
					tostring(self.semen ~= nil and self.semen.uniqueId))
				return
			end

			-- 4. The same eligibility the straw prompt checks (type, subtype group, age, close
			--    relatives, ...), against the recorded sire; a refused straw stays on record.
			if animal.getCanBeInseminatedByAnimal ~= nil then
				local canInseminate, reason = animal:getCanBeInseminatedByAnimal(semen)
				if not canInseminate then
					Log:warning("InseminationEvent:run: refused uniqueId=%s by sire %s: %s", tostring(identifiers.uniqueId),
						tostring(semen.uniqueId), tostring(reason))
					return
				end
			end

			RLStrawLedger.spendForSemen(userId, semen)
			self.semen = semen
			animal:setInsemination(semen)
			Log:info("InseminationEvent:run applied uniqueId=%s", tostring(identifiers.uniqueId))

			-- Rebroadcast to other clients excluding sender (Pattern A).
			-- Sender mutated locally before sendEvent and must not receive an echo.
			g_server:broadcastEvent(
				AnimalInseminationEvent.new(self.object, self.animal, self.semen),
				nil, connection, nil)
			Log:trace("InseminationEvent:run rebroadcast ignoreConnection=sender uniqueId=%s",
				tostring(identifiers.uniqueId))
		else
			-- Client (rebroadcast from server): the server only rebroadcasts an insemination it
			-- applied, so its record replaces whatever this client holds.
			if animal ~= nil then
				animal:setInsemination(self.semen)
				Log:debug("InseminationEvent:run client-applied uniqueId=%s",
					tostring(identifiers.uniqueId))
			else
				Log:trace("InseminationEvent:run client-skip, animal not found uniqueId=%s", tostring(identifiers.uniqueId))
			end
		end

	end)

end