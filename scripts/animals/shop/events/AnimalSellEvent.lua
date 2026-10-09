function AnimalSellEvent.new(object, animals, price, transportPrice)

	local event = AnimalSellEvent.emptyNew()

	event.object = object
	event.animals = animals
	event.price = price
	event.transportPrice = transportPrice

	return event

end


function AnimalSellEvent:readStream(streamId, connection)

	if connection:getIsServer() then

		self.errorCode = streamReadUIntN(streamId, 3)

	else

		self.object = NetworkUtil.readNodeObject(streamId)
		local numAnimals = streamReadUInt16(streamId)

		self.animals = {}

		for i = 1, numAnimals do

			local identifiers = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
			table.insert(self.animals, identifiers)

		end

		self.price = streamReadFloat32(streamId)
		self.transportPrice = streamReadFloat32(streamId)

	end

	self:run(connection)

end


function AnimalSellEvent:writeStream(streamId, connection)

	if not connection:getIsServer() then
		streamWriteUIntN(streamId, self.errorCode, 3)
		return
	end

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.animals)

	for i, animal in pairs(self.animals) do
		RLAnimalUtil.writeStreamIdentifiers(animal, streamId, connection)
	end

	streamWriteFloat32(streamId, self.price)
	streamWriteFloat32(streamId, self.transportPrice)

end


local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end


--- Server: price a sale from the source's own animals; changes nothing. The client's price is
--- never used. Any missing, repeated, unsellable or sick animal, a source the farm does not own,
--- or a price the server cannot compute refuses the whole batch.
---@param object table|nil The sell source (husbandry placeable or livestock trailer)
---@param identifiers table|nil Array of animal identifiers from the request
---@param farmId number|nil The selling farm
---@return table|nil quote { clusters, keys, prices, fees, price, fee, total, isTrailer }
---@return number|nil errorCode The reply code when the sale is refused
---@return string|nil reason Log text when the sale is refused
function AnimalSellEvent.quoteSale(object, identifiers, farmId)

	if object == nil or object.getClusterSystem == nil or object.getClusterById == nil or object:getClusterSystem() == nil then
		return nil, AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST, "no source"
	end

	if farmId == nil or object.getOwnerFarmId == nil or object:getOwnerFarmId() ~= farmId then
		return nil, AnimalSellEvent.SELL_ERROR_NO_PERMISSION,
			string.format("source owned by farm %s, seller farm %s",
				tostring(object.getOwnerFarmId ~= nil and object:getOwnerFarmId() or nil), tostring(farmId))
	end

	if identifiers == nil or #identifiers == 0 then
		return nil, AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER, "empty batch"
	end

	-- A trailer at the dealer pays no transport, as in the base game's trailer sale.
	local isTrailer = object.spec_livestockTrailer ~= nil
	local quote = { clusters = {}, keys = {}, prices = {}, fees = {}, price = 0, fee = 0, total = 0, isTrailer = isTrailer }
	local seen = {}

	for i, identifier in ipairs(identifiers) do

		local key = identifier ~= nil and RLAnimalUtil.toKeyFromIdentifiers(identifier) or nil
		if key == nil then
			return nil, AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER, string.format("[%d] unreadable identifiers", i)
		end
		if seen[key] then
			return nil, AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER, string.format("[%d] %s requested twice", i, tostring(key))
		end
		seen[key] = true

		local animal = object:getClusterById(key)
		if animal == nil then
			return nil, AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER, string.format("[%d] %s not in source", i, tostring(key))
		end
		if not animal:getCanBeSold() then
			return nil, AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD, string.format("[%d] %s cannot be sold", i, tostring(key))
		end

		-- The client leaves sick animals out, but its disease view can be stale.
		local saleOk, saleReason = RLDiseaseSaleGate.check(animal)
		if not saleOk then
			return nil, AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD, string.format("[%d] %s sick (%s)", i, tostring(key), tostring(saleReason))
		end

		local price = animal:getSellPrice()
		local fee = isTrailer and 0 or animal:getTranportationFee(1)
		if not isFiniteNumber(price) or price < 0 or not isFiniteNumber(fee) or fee < 0 then
			return nil, AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD,
				string.format("[%d] %s no valid quote (price=%s fee=%s)", i, tostring(key), tostring(price), tostring(fee))
		end

		quote.clusters[i] = animal
		quote.keys[i] = key
		quote.prices[i] = price
		quote.fees[i] = fee
		quote.price = quote.price + price
		quote.fee = quote.fee + fee

	end

	quote.total = quote.price - quote.fee
	if not isFiniteNumber(quote.total) then
		return nil, AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD, "batch total not finite"
	end

	return quote

end


--- Server: remove the quoted animals and work out what to pay. Only the animals that are gone
--- from the source after the flush are paid, at their quoted price. Gone means the quoted object is
--- no longer in the source's animal list: getClusterById can fall back to an id index a failed flush
--- left stale and return a different animal. When the queue or the flush throws, the animals still in
--- the source are taken off the remove queue so a later flush cannot remove them unpaid. This is not
--- a rollback: an animal the flush already removed stays removed.
---@param object table The sell source
---@param quote table From AnimalSellEvent.quoteSale
---@return number removed Animals gone from the source
---@return number credit Money for the removed animals (prices minus fees)
---@return string|nil err The queue or flush error, if one was thrown
function AnimalSellEvent.commitSale(object, quote)

	local clusterSystem = object:getClusterSystem()

	local queued, queueErr = pcall(function()
		for _, cluster in ipairs(quote.clusters) do
			clusterSystem:addPendingRemoveCluster(cluster)
		end
	end)
	local flushed, flushErr = true, nil
	if queued then flushed, flushErr = pcall(function() clusterSystem:updateNow() end) end

	local present = {}
	for _, animal in ipairs(clusterSystem:getClusters() or {}) do present[animal] = true end

	local removed, credit = 0, 0
	for i, cluster in ipairs(quote.clusters) do
		if not present[cluster] then
			removed = removed + 1
			credit = credit + quote.prices[i] - quote.fees[i]
		elseif clusterSystem.clustersToRemove ~= nil then
			clusterSystem.clustersToRemove[cluster] = nil
		end
	end

	local err = nil
	if not (queued and flushed) then err = string.format("queue=%s flush=%s", tostring(queueErr), tostring(flushErr)) end

	return removed, credit, err

end


--- Client: publish the reply code. Server: price the batch from its own animals, then remove and
--- pay for it. The request's price and transportPrice are only compared for the log.
---@param connection table The sender's connection (a client when this runs on the server)
function AnimalSellEvent:run(connection)

	if connection:getIsServer() then

		g_messageCenter:publish(AnimalSellEvent, self.errorCode)
		return

	end

	-- Every request gets exactly one reply, even when something below throws, so the client is
	-- never left waiting for its timeout.
	local replied = false
	local function reply(errorCode)
		replied = true
		connection:sendEvent(AnimalSellEvent.newServerToClient(errorCode))
	end

	RmSafeUtils.safeCall("AnimalSellEvent:run", function()

		if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then

			reply(AnimalSellEvent.SELL_ERROR_NO_PERMISSION)
			return

		end

		local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
		local farm = g_farmManager:getFarmForUniqueUserId(userId)
		local farmId = farm ~= nil and farm.farmId or nil
		local numRequested = self.animals ~= nil and #self.animals or 0

		Log:trace("SellEvent:run selling %d animals", numRequested)

		-- Validate and price the whole batch before anything is removed.
		-- A throw while pricing (getSellPrice, the transport fee) refuses the batch; it never falls
		-- back to the client's amount.
		local quoted, quote, errorCode, reason = pcall(AnimalSellEvent.quoteSale, self.object, self.animals, farmId)
		if not quoted then
			quote, errorCode, reason = nil, AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD, "quote threw: " .. tostring(quote)
		end
		if quote == nil then
			Log:warning("SellEvent:run refused sale of %d animals (code=%s userId=%s farmId=%s): %s",
				numRequested, tostring(errorCode), tostring(userId), tostring(farmId), tostring(reason))
			reply(errorCode)
			return
		end

		local clientTotal = (self.price or 0) + (self.transportPrice or 0)
		if not isFiniteNumber(clientTotal) or math.abs(clientTotal - quote.total) > math.max(1, math.abs(quote.total) * 0.01) then
			Log:info("SellEvent:run client total %s differs from server total %.2f (price=%.2f fee=%.2f); paying the server total",
				tostring(clientTotal), quote.total, quote.price, quote.fee)
		end

		-- T02 batch 3 (RLLiveSale): in TEST the batch is one server transaction with a money
		-- receipt and never falls back to the path below; SHADOW only logs what TEST would do.
		-- OFF (the default) leaves the old path alone.
		if RLLiveSale ~= nil and RLLiveSale.getMode() ~= RLLiveSale.MODE_OFF then
			if RLLiveSale.getMode() == RLLiveSale.MODE_TEST then
				local record, liveReason = RLLiveSale.executeManual(self.object, quote, farmId)
				local liveCode = RLLiveSale.toSellErrorCode(record, liveReason)
				reply(liveCode)
				if liveCode == AnimalSellEvent.SELL_SUCCESS then
					-- After the settled sale: a failing message never retries it.
					local messaged, messageErr = pcall(self.addSoldMessage, self, #record.sale.removed, record.sale.amount)
					if not messaged then RLLiveSale.noteNotification(record.id, messageErr) end
				end
				return
			end
			RLLiveSale.shadowManual(self.object, quote, farmId)
		end

		local removed, credit, err = AnimalSellEvent.commitSale(self.object, quote)
		local numQuoted = #quote.clusters

		if removed > 0 then
			g_currentMission:addMoney(credit, farmId, MoneyType.SOLD_ANIMALS, true, true)
		end

		if removed < numQuoted or err ~= nil then
			Log:error("SellEvent:run: removal batch failed, %d of %d removed and paid %.2f (%s)",
				removed, numQuoted, credit, tostring(err))
			reply(AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST)
			return
		end

		reply(AnimalSellEvent.SELL_SUCCESS)

		self:addSoldMessage(removed, credit)

		Log:debug("SellEvent:run: sold %d animals farmId=%s total=%s",
			removed, tostring(farmId), tostring(credit))

	end)

	if not replied then
		Log:error("SellEvent:run: failed before replying; reporting failure to the client")
		connection:sendEvent(AnimalSellEvent.newServerToClient(AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST))
	end

end


--- The pen's "animals sold" message after a successful sale.
---@param removed number Animals sold
---@param credit number Money paid for them
function AnimalSellEvent:addSoldMessage(removed, credit)

	-- Object may be a trailer on trailer-based dealer sales; only husbandry
	-- placeables carry addRLMessage.
	if self.object.addRLMessage ~= nil then
		if removed == 1 then
			self.object:addRLMessage("SOLD_ANIMALS_SINGLE", nil, { g_i18n:formatMoney(math.abs(credit), 2, true, true) })
		else
			self.object:addRLMessage("SOLD_ANIMALS_MULTIPLE", nil, { removed, g_i18n:formatMoney(math.abs(credit), 2, true, true) })
		end
	else
		Log:trace("SellEvent:run: skipping addRLMessage (object has no husbandryAnimals spec, likely trailer sale) N=%d", removed)
	end

end
