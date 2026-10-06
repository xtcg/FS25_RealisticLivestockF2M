-- AIAnimalSellEvent.lua
-- The herdsman's automatic sale. It runs only on the server, called directly by
-- RLHerdsmanExecutor through AIAnimalSellEvent.executeServer, which returns what actually happened.
-- The event class stays registered with its old stream format so an older peer's packet still
-- parses, but receiving or running the event never removes an animal or moves money.
--
-- A herdsman sale pays the sell price PLUS the transport fee per animal (the planner's
-- SELL_MARKUP 1.0 path), unlike the player's sale, which subtracts the fee. The wage is charged
-- separately by the executor.
--
-- executeServer checks the whole batch before touching anything: the source must still belong to
-- the farm the plan was made for, every identity must be well formed, unique and a current member,
-- and every animal sellable, healthy and priceable now. Any failure refuses the batch with nothing
-- removed or paid. After the removal only the animals that left the source are paid, at the price
-- quoted at execute. A failure after removal starts is recorded with its stage and never retried,
-- refunded or rolled back here.

AIAnimalSellEvent = {}

local AIAnimalSellEvent_mt = Class(AIAnimalSellEvent, Event)
InitEventClass(AIAnimalSellEvent, "AIAnimalSellEvent")

--- Result statuses from executeServer.
AIAnimalSellEvent.STATUS_SOLD = "sold"          -- every animal removed and paid
AIAnimalSellEvent.STATUS_PARTIAL = "partial"    -- some animals removed and paid, the batch failed
AIAnimalSellEvent.STATUS_REFUSED = "refused"    -- refused before removal: nothing removed or paid
AIAnimalSellEvent.STATUS_FAILED = "failed"      -- failed during or after removal, nothing settled or unknown


function AIAnimalSellEvent.emptyNew()

    local self = Event.new(AIAnimalSellEvent_mt)
    return self

end


function AIAnimalSellEvent.new(object, animals, price)

	local event = AIAnimalSellEvent.emptyNew()

	event.object = object
	event.animals = animals
	event.price = price

	return event

end


function AIAnimalSellEvent:readStream(streamId, connection)

	self.object = NetworkUtil.readNodeObject(streamId)
	local numAnimals = streamReadUInt16(streamId)

	self.animals = {}

	for i = 1, numAnimals do

		local identifiers = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
		table.insert(self.animals, identifiers)

	end

	self.price = streamReadFloat32(streamId)

	self:run(connection)

end


function AIAnimalSellEvent:writeStream(streamId, connection)

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.animals)

	for _, animal in pairs(self.animals) do RLAnimalUtil.writeStreamIdentifiers(animal, streamId, connection) end

	streamWriteFloat32(streamId, self.price)

end


--- Never sells. The sale is the server's own call to executeServer; a packet from a client, or a
--- stray local run, could otherwise remove animals and pay the price it carries.
---@param connection table|nil
function AIAnimalSellEvent:run(connection)

	Log:warning("AIAnimalSellEvent:run ignored (%d animals, price %s, from %s): herdsman sales run only through executeServer",
		self.animals ~= nil and #self.animals or 0, tostring(self.price),
		connection == nil and "local" or (connection.getIsServer ~= nil and connection:getIsServer() and "server" or "client"))

end


function AIAnimalSellEvent.validate(object, numAnimals, price, farmId)

	if object == nil then return AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST end

	return nil

end


local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end


--- The identity key of a requested animal, or nil when any of the three fields is missing.
---@param identity any
---@return string|nil
local function identityKey(identity)
	if type(identity) ~= "table" or identity.farmId == nil or identity.uniqueId == nil then return nil end
	local country = identity.country
	if country == nil and type(identity.birthday) == "table" then country = identity.birthday.country end
	if country == nil then return nil end
	return RLAnimalUtil.toKey(identity.farmId, identity.uniqueId, country)
end


--- The number of entries in a batch that is a plain array 1..n, or nil for anything else: a table
--- with holes or extra keys would otherwise sell only the prefix `#` and ipairs see.
---@param list any
---@return number|nil
function AIAnimalSellEvent.batchLength(list)
	if type(list) ~= "table" then return nil end
	local n, max = 0, 0
	for k in pairs(list) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return nil end
		n = n + 1
		if k > max then max = k end
	end
	if n ~= max then return nil end
	return n
end


--- Server: price the batch from the source's own animals at this moment; changes nothing. The
--- planned amount is never used. A missing, repeated or malformed identity, an animal that cannot
--- be sold, is sick or has no valid price, or a source no longer owned by the seller refuses the
--- whole batch. Animals are matched by identity against the source's animal list, never through an
--- id index.
---@param object table|nil The husbandry placeable
---@param identities table|nil Array of frozen identities from the plan
---@param sellerFarmId number|nil The farm the plan belongs to
---@return table|nil quote { clusters, keys, prices, fees, credits, total }
---@return string|nil failureStage Why it was refused: "source" | "ownership" | "identity" | "animal" | "price"
---@return string|nil reason Log text when refused
function AIAnimalSellEvent.quoteSale(object, identities, sellerFarmId)

	if object == nil or object.getClusterSystem == nil or object:getClusterSystem() == nil then
		return nil, "source", "no source"
	end

	local ownerFarmId = object.getOwnerFarmId ~= nil and object:getOwnerFarmId() or nil
	if sellerFarmId == nil or ownerFarmId ~= sellerFarmId then
		return nil, "ownership", string.format("source owned by farm %s, plan made for farm %s", tostring(ownerFarmId), tostring(sellerFarmId))
	end

	local count = AIAnimalSellEvent.batchLength(identities)
	if count == nil then
		return nil, "identity", "not a plain array of identities"
	end
	if count == 0 then
		return nil, "identity", "empty batch"
	end

	local present = {}
	for _, animal in ipairs(object:getClusterSystem():getClusters() or {}) do
		local key = identityKey(animal)
		if key ~= nil then
			-- Two live animals with one identity: neither can be told apart, so neither is sold.
			present[key] = present[key] == nil and animal or false
		end
	end

	local quote = { clusters = {}, keys = {}, prices = {}, fees = {}, credits = {}, total = 0 }
	local seen = {}

	for i, identity in ipairs(identities) do

		local key = identityKey(identity)
		if key == nil then
			return nil, "identity", string.format("[%d] malformed identity", i)
		end
		if seen[key] then
			return nil, "identity", string.format("[%d] %s requested twice", i, key)
		end
		seen[key] = true

		local animal = present[key]
		if animal == nil then
			return nil, "identity", string.format("[%d] %s not in source", i, key)
		end
		if animal == false then
			return nil, "identity", string.format("[%d] %s matches more than one animal", i, key)
		end

		if not animal:getCanBeSold() then
			return nil, "animal", string.format("[%d] %s cannot be sold", i, key)
		end
		local saleOk, saleReason = RLDiseaseSaleGate.check(animal)
		if not saleOk then
			return nil, "animal", string.format("[%d] %s sick (%s)", i, key, tostring(saleReason))
		end

		local price = animal:getSellPrice()
		local fee = animal:getTranportationFee(1)
		if not isFiniteNumber(price) or price < 0 or not isFiniteNumber(fee) or fee < 0 then
			return nil, "price", string.format("[%d] %s no valid quote (price=%s fee=%s)", i, key, tostring(price), tostring(fee))
		end

		quote.clusters[i] = animal
		quote.keys[i] = key
		quote.prices[i] = price
		quote.fees[i] = fee
		quote.credits[i] = price + fee
		quote.total = quote.total + price + fee

	end

	if not isFiniteNumber(quote.total) then
		return nil, "price", "batch total not finite"
	end

	return quote

end


--- Take this batch's animals off the remove queue, leaving every other queued removal alone.
---@param clusterSystem table
---@param clusters table[]
local function unqueue(clusterSystem, clusters)
	if type(clusterSystem.clustersToRemove) ~= "table" then return end
	for _, cluster in ipairs(clusters) do clusterSystem.clustersToRemove[cluster] = nil end
end


--- Server only: sell the planned animals now and report what actually happened.
---
--- Result: { status, requestedCount, removedCount, settledCount, amountGained, quotedAmount,
--- failureStage, reason }. removedCount is nil when the source list could not be read after the
--- removal; settledCount and amountGained are nil when addMoney threw, since it may have paid.
--- Only settledCount animals and amountGained money are confirmed. failureStage is one of
--- "server" | "source" | "ownership" | "identity" | "animal" | "price" | "pending" | "queue" |
--- "flush" | "removal" | "verify" | "payment".
---@param object table The husbandry placeable
---@param identities table Frozen identities from the plan
---@param sellerFarmId number The farm the plan belongs to; it must still own the source
---@param ctx table { server, mission } (g_server, g_currentMission)
---@return table result
function AIAnimalSellEvent.executeServer(object, identities, sellerFarmId, ctx)

	local requested = AIAnimalSellEvent.batchLength(identities) or 0
	local result = { status = AIAnimalSellEvent.STATUS_REFUSED, requestedCount = requested, removedCount = 0,
		settledCount = 0, amountGained = 0, quotedAmount = nil, failureStage = nil, reason = nil }

	local function finish(status, stage, reason)
		result.status, result.failureStage, result.reason = status, stage, reason
		if status == AIAnimalSellEvent.STATUS_SOLD then
			Log:debug("AIAnimalSellEvent.executeServer: sold %d animals farm=%s paid %.2f",
				result.settledCount, tostring(sellerFarmId), result.amountGained)
		elseif status == AIAnimalSellEvent.STATUS_REFUSED then
			Log:warning("AIAnimalSellEvent.executeServer: refused %d animals farm=%s (%s): %s",
				requested, tostring(sellerFarmId), tostring(stage), tostring(reason))
		else
			Log:error("AIAnimalSellEvent.executeServer: %s at %s, %s of %d removed, %s settled for %s (farm=%s): %s",
				status, tostring(stage), tostring(result.removedCount), requested, tostring(result.settledCount),
				tostring(result.amountGained), tostring(sellerFarmId), tostring(reason))
		end
		return result
	end

	if ctx == nil or ctx.server == nil or ctx.mission == nil then
		return finish(AIAnimalSellEvent.STATUS_REFUSED, "server", "not running on the server")
	end

	-- A throw while checking or pricing refuses the batch; nothing has been touched yet.
	local quoted, quote, stage, reason = pcall(AIAnimalSellEvent.quoteSale, object, identities, sellerFarmId)
	if not quoted then
		quote, stage, reason = nil, "price", "quote threw: " .. tostring(quote)
	end
	if quote == nil then
		return finish(AIAnimalSellEvent.STATUS_REFUSED, stage, reason)
	end
	result.quotedAmount = quote.total

	local clusterSystem = object:getClusterSystem()

	-- The flush commits every queued removal at once; another transaction's removals would be
	-- removed unpaid by this sale or counted into it, so this batch waits for a later day. Any key
	-- counts, whatever its value: the flush removes every animal whose entry is not nil.
	if type(clusterSystem.clustersToRemove) == "table" and next(clusterSystem.clustersToRemove) ~= nil then
		return finish(AIAnimalSellEvent.STATUS_REFUSED, "pending", "other removals already queued")
	end

	local queued, queueErr = pcall(function()
		for _, cluster in ipairs(quote.clusters) do clusterSystem:addPendingRemoveCluster(cluster) end
	end)
	local flushed, flushErr = true, nil
	if queued then
		flushed, flushErr = pcall(function() clusterSystem:updateNow() end)
	end

	-- Removal is checked by object against the source's list: an id lookup can fall back to an index
	-- a failed flush left stale.
	local listed, list = pcall(function() return clusterSystem:getClusters() end)
	if not listed or type(list) ~= "table" then
		-- Which animals left is unknown, so nothing is paid. Survivors must not stay queued for a
		-- later flush to remove unpaid; a removed animal has no queue entry to clear.
		unqueue(clusterSystem, quote.clusters)
		result.removedCount, result.settledCount, result.amountGained = nil, 0, 0
		return finish(AIAnimalSellEvent.STATUS_FAILED, "verify",
			string.format("source list unreadable after removal (%s); queue=%s flush=%s",
				tostring(list), tostring(queueErr), tostring(flushErr)))
	end

	local present = {}
	for _, animal in ipairs(list) do present[animal] = true end

	local removed, credit, survivors = 0, 0, {}
	for i, cluster in ipairs(quote.clusters) do
		if present[cluster] then
			survivors[#survivors + 1] = cluster
		else
			removed = removed + 1
			credit = credit + quote.credits[i]
		end
	end
	unqueue(clusterSystem, survivors)
	result.removedCount = removed

	if removed > 0 then
		local paid, payErr = pcall(function()
			ctx.mission:addMoney(credit, sellerFarmId, MoneyType.SOLD_ANIMALS, true, true)
		end)
		if not paid then
			result.settledCount, result.amountGained = nil, nil
			return finish(AIAnimalSellEvent.STATUS_FAILED, "payment",
				string.format("addMoney threw for %d removed animals worth %.2f: %s", removed, credit, tostring(payErr)))
		end
	end
	result.settledCount, result.amountGained = removed, credit

	if not queued or not flushed or removed < requested then
		local failStage = (not queued and "queue") or (not flushed and "flush") or "removal"
		local failReason = string.format("%d of %d removed; queue=%s flush=%s", removed, requested, tostring(queueErr), tostring(flushErr))
		return finish(removed > 0 and AIAnimalSellEvent.STATUS_PARTIAL or AIAnimalSellEvent.STATUS_FAILED, failStage, failReason)
	end

	return finish(AIAnimalSellEvent.STATUS_SOLD, nil, nil)

end
