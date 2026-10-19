AnimalInseminationEvent = {}

local AnimalInseminationEvent_mt = Class(AnimalInseminationEvent, Event)
InitEventClass(AnimalInseminationEvent, "AnimalInseminationEvent")


function AnimalInseminationEvent.emptyNew()

    local self = Event.new(AnimalInseminationEvent_mt)
    return self

end


--- APPLY: a request from the straw's client, or the server's copy of an applied insemination for
--- every other client. ACCEPTED / REFUSED: the server's answer to the requesting client only.
AnimalInseminationEvent.MODE_APPLY = 0
AnimalInseminationEvent.MODE_ACCEPTED = 1
AnimalInseminationEvent.MODE_REFUSED = 2

--- Client: straws sent to the server and not yet answered, by animal (see awaitServer).
AnimalInseminationEvent.pendingStraws = {}


function AnimalInseminationEvent.new(object, animal, semen, mode)

	local event = AnimalInseminationEvent.emptyNew()

	event.object = object
	event.animal = animal
	event.semen = semen
	event.mode = mode or AnimalInseminationEvent.MODE_APPLY

	return event

end


--- The server's refusal for the requesting client, carrying the animal's current insemination
--- (nil when it has none) so that client shows what the server holds.
function AnimalInseminationEvent.newRefused(object, animal, current)

	return AnimalInseminationEvent.new(object, animal, current, AnimalInseminationEvent.MODE_REFUSED)

end


local function readSemen(streamId)

	local semen = { ["genetics"] = {} }

	semen.country = streamReadUInt8(streamId)
	semen.farmId = streamReadString(streamId)
	semen.uniqueId = streamReadString(streamId)
	semen.name = streamReadString(streamId)
	semen.typeIndex = streamReadUInt8(streamId)
	semen.subTypeIndex = streamReadUInt8(streamId)
	semen.success = streamReadFloat32(streamId)

	semen.genetics.metabolism = streamReadFloat32(streamId)
	semen.genetics.fertility = streamReadFloat32(streamId)
	semen.genetics.health = streamReadFloat32(streamId)
	semen.genetics.quality = streamReadFloat32(streamId)
	semen.genetics.productivity = streamReadFloat32(streamId)

	if semen.genetics.productivity < 0 then semen.genetics.productivity = nil end
	RLSemenBatch.readStream(streamId, semen)

	return semen

end


local function writeSemen(streamId, semen)

	local genetics = semen.genetics or {}

	streamWriteUInt8(streamId, semen.country)
	streamWriteString(streamId, semen.farmId)
	streamWriteString(streamId, semen.uniqueId)
	streamWriteString(streamId, semen.name or "")
	streamWriteUInt8(streamId, semen.typeIndex or 0)
	streamWriteUInt8(streamId, semen.subTypeIndex or 0)
	streamWriteFloat32(streamId, semen.success or 0)

	streamWriteFloat32(streamId, genetics.metabolism or 1)
	streamWriteFloat32(streamId, genetics.fertility or 1)
	streamWriteFloat32(streamId, genetics.health or 1)
	streamWriteFloat32(streamId, genetics.quality or 1)
	streamWriteFloat32(streamId, genetics.productivity or -1)
	RLSemenBatch.writeStream(streamId, semen)

end


function AnimalInseminationEvent:readStream(streamId, connection)

	self.mode = streamReadUIntN(streamId, 2)
	self.object = NetworkUtil.readNodeObject(streamId)
	self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

	if self.mode ~= AnimalInseminationEvent.MODE_REFUSED or streamReadBool(streamId) then
		self.semen = readSemen(streamId)
	end

	Log:trace("InseminationEvent:readStream mode=%s semen.country=%s", tostring(self.mode),
		tostring(self.semen ~= nil and self.semen.country))

	self:run(connection)

end


function AnimalInseminationEvent:writeStream(streamId, connection)

	streamWriteUIntN(streamId, self.mode or AnimalInseminationEvent.MODE_APPLY, 2)
	NetworkUtil.writeNodeObject(streamId, self.object)
	RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)

	if self.mode == AnimalInseminationEvent.MODE_REFUSED then
		streamWriteBool(streamId, self.semen ~= nil)
		if self.semen == nil then return end
	end

	writeSemen(streamId, self.semen)

end


local function pendingKey(identifiers)

	if identifiers == nil then return nil end
	return string.format("%s %s", tostring(identifiers.farmId), tostring(identifiers.uniqueId))

end


--- Client: whether a straw already waits for the server's answer about `animal`. Only one
--- request per animal may be open, since the answer names the animal and not the straw.
function AnimalInseminationEvent.isAwaiting(animal)

	local key = pendingKey(animal)
	return key ~= nil and AnimalInseminationEvent.pendingStraws[key] ~= nil

end


--- Client: hold `handTool`'s straw until the server answers its request for `animal`. False when
--- another straw already waits for that animal.
function AnimalInseminationEvent.awaitServer(animal, handTool)

	local key = pendingKey(animal)
	if key == nil or AnimalInseminationEvent.pendingStraws[key] ~= nil then return false end
	AnimalInseminationEvent.pendingStraws[key] = handTool
	return true

end


--- Client: the server's answer for a held straw; nil when no straw waits for this animal.
local function takePending(identifiers)

	local key = pendingKey(identifiers)
	local handTool = key ~= nil and AnimalInseminationEvent.pendingStraws[key] or nil
	if key ~= nil then AnimalInseminationEvent.pendingStraws[key] = nil end
	return handTool

end


--- Execute the event on the receiver.
---
--- Server-confirmed flow for a client's straw:
---   * HandToolAIStraw:onInseminate on a client sends an APPLY request and holds the straw
---     (awaitServer); nothing changes on that client yet.
---   * Server: every check passes -> apply, spend the ledger straw, send ACCEPTED to the requester
---     and APPLY to every other client. Any check fails -> send REFUSED with the animal's current
---     insemination to the requester; nothing is spent.
---   * Requester: ACCEPTED applies the server's record and uses up the held straw; REFUSED sets
---     the server's record and gives the straw back to the player.
---   * A host or single player applies locally and broadcasts APPLY.
---
--- No dewar decrement happens here - this event is the hand-tool path; the straw
--- was already drained from its dewar when the hand-tool was filled.
---@param connection table Network connection the event arrived on
function AnimalInseminationEvent:run(connection)

	RmSafeUtils.safeCall("AnimalInseminationEvent:run", function()

		local clusterSystem = self.object:getClusterSystem()
		local identifiers = self.animal

		local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)
		local isServerBranch = not connection:getIsServer()
		Log:trace("InseminationEvent:run branch=%s animal=%s", isServerBranch and "server" or "client", tostring(identifiers.uniqueId))

		if isServerBranch then
			local function refuse()
				connection:sendEvent(AnimalInseminationEvent.newRefused(self.object, self.animal,
					animal ~= nil and animal.insemination or nil))
			end

			-- Server-authoritative order; nothing is spent or rebroadcast until every check passed:
			-- 1. The animal must exist here; without it there is nothing to compensate, and a
			--    rebroadcast would let other clients apply what the server never did.
			if animal == nil then
				Log:warning("InseminationEvent:run animal not found uniqueId=%s, NOT rebroadcasting (server-authoritative reject)",
					tostring(identifiers.uniqueId))
				refuse()
				return
			end

			-- 2. One pending insemination at a time: a second player's straw arriving after the
			--    first must not replace it (nor spend a second straw).
			if animal.insemination ~= nil then
				Log:info("InseminationEvent:run refused uniqueId=%s: already inseminated", tostring(identifiers.uniqueId))
				refuse()
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
				refuse()
				return
			end

			-- 4. The same eligibility the straw prompt checks (type, subtype group, age, close
			--    relatives, ...), against the recorded sire; a refused straw stays on record.
			if animal.getCanBeInseminatedByAnimal ~= nil then
				local canInseminate, reason = animal:getCanBeInseminatedByAnimal(semen)
				if not canInseminate then
					Log:warning("InseminationEvent:run: refused uniqueId=%s by sire %s: %s", tostring(identifiers.uniqueId),
						tostring(semen.uniqueId), tostring(reason))
					refuse()
					return
				end
			end

			RLStrawLedger.spendForSemen(userId, semen)
			self.semen = semen
			animal:setInsemination(semen)
			Log:info("InseminationEvent:run applied uniqueId=%s", tostring(identifiers.uniqueId))

			connection:sendEvent(AnimalInseminationEvent.new(self.object, self.animal, semen,
				AnimalInseminationEvent.MODE_ACCEPTED))
			g_server:broadcastEvent(AnimalInseminationEvent.new(self.object, self.animal, semen), nil, connection, nil)
			Log:trace("InseminationEvent:run accepted, rebroadcast ignoreConnection=sender uniqueId=%s",
				tostring(identifiers.uniqueId))
		else
			-- Client: the server only sends an insemination it applied, or with a refusal the one
			-- the animal holds there, so its record replaces whatever this client holds.
			local refused = self.mode == AnimalInseminationEvent.MODE_REFUSED
			if animal ~= nil and self.semen ~= nil then
				animal:setInsemination(self.semen)
				Log:debug("InseminationEvent:run client-applied uniqueId=%s mode=%s",
					tostring(identifiers.uniqueId), tostring(self.mode))
			elseif animal ~= nil and refused then
				-- The server holds no insemination for this animal; drop a stale local one.
				animal.insemination = nil
			elseif animal == nil then
				Log:trace("InseminationEvent:run client-skip, animal not found uniqueId=%s", tostring(identifiers.uniqueId))
			end

			if self.mode ~= AnimalInseminationEvent.MODE_APPLY then
				local handTool = takePending(identifiers)
				if handTool ~= nil and HandToolAIStraw ~= nil then
					HandToolAIStraw.onServerAnswer(handTool, not refused)
				end
			end
		end

	end)

end