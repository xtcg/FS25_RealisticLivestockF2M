--- Reply when the target husbandry is not built yet (RLPenConstruction). The base game's codes
--- fill 0-7, so the reply is written in ERROR_CODE_NUM_BITS rather than the base game's 3.
AnimalBuyEvent.BUY_ERROR_PEN_NOT_BUILT = 8
AnimalBuyEvent.BUY_ERROR_PRICE_UNAVAILABLE = 9
AnimalBuyEvent.ERROR_CODE_NUM_BITS = 4

-- The wire carries float32 totals; the server always charges its exact double.
-- Tolerance follows representable wire precision, not a fixed currency amount.
function AnimalBuyEvent.matchesWirePrice(sent,expected)
    local function finite(v)return type(v)=="number" and v==v and math.abs(v)<math.huge end
    if not finite(sent) or not finite(expected) or sent>0 or expected>0 then return false end
    return math.abs(sent-expected)<=math.max(2^-149,math.abs(expected)*2^-23)
end

-- The price the player confirmed is the one charged while it is within QUOTE_TOLERANCE of the server's
-- quote now: a quote moves a little while a dialog is open (an hour: age, weight), and a player never
-- minds those few units. A wider gap (a month change, a forged amount) is refused as price-unavailable.
AnimalBuyEvent.QUOTE_TOLERANCE = 0.02
function AnimalBuyEvent.acceptsConfirmedPrice(sent,expected)
    if AnimalBuyEvent.matchesWirePrice(sent,expected) then return true end
    local function finite(v)return type(v)=="number" and v==v and math.abs(v)<math.huge end
    if not finite(sent) or not finite(expected) or sent>0 or expected>0 then return false end
    return math.abs(sent-expected)<=math.abs(expected)*AnimalBuyEvent.QUOTE_TOLERANCE
end


function AnimalBuyEvent.new(object, animals, buyPrice, transportPrice)

	local event = AnimalBuyEvent.emptyNew()

	event.object = object
	event.animals = animals
	event.buyPrice = buyPrice
	event.transportPrice = transportPrice

	return event

end


function AnimalBuyEvent:readStream(streamId, connection)

	if connection:getIsServer() then

		self.errorCode = streamReadUIntN(streamId, AnimalBuyEvent.ERROR_CODE_NUM_BITS)

	else

		self.object = NetworkUtil.readNodeObject(streamId)
		local numAnimals = streamReadUInt16(streamId)

		self.animals = {}

		for i = 1, numAnimals do

			local animal = Animal.new()
			animal:readStream(streamId, connection)
			table.insert(self.animals, animal)

		end

		self.buyPrice = streamReadFloat32(streamId)
		self.transportPrice = streamReadFloat32(streamId)

	end

	self:run(connection)

end


function AnimalBuyEvent:writeStream(streamId, connection)

	if not connection:getIsServer() then
		streamWriteUIntN(streamId, self.errorCode, AnimalBuyEvent.ERROR_CODE_NUM_BITS)
		return
	end

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.animals)

	for _, animal in pairs(self.animals) do animal:writeStream(streamId, connection) end

	streamWriteFloat32(streamId, self.buyPrice)
	streamWriteFloat32(streamId, self.transportPrice)

end


function AnimalBuyEvent:run(connection)

	if connection:getIsServer() then

		g_messageCenter:publish(AnimalBuyEvent, self.errorCode)
		return

	end

	RmSafeUtils.safeCall("AnimalBuyEvent:run", function()
        if RLBrokerRuntime and not RLBrokerRuntime.mutationAllowed() then
            connection:sendEvent(AnimalBuyEvent.newServerToClient(AnimalBuyEvent.BUY_ERROR_NO_PERMISSION))
            return
        end

		-- Phase timing: per-phase TRACE lines (setup / validate / removeSale /
		-- addAnimals / addMoney+sendEvent) so a slow buy can be localised to one phase.
		-- TRACE-only because the surrounding safeCall enter/exit (also TRACE) gives the
		-- elapsed-ms total via its own log.
		local phaseStart = getTimeSec()
		local function phaseDoneMs() return (getTimeSec() - phaseStart) * 1000 end
		local function phaseReset() phaseStart = getTimeSec() end

		if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then

			connection:sendEvent(AnimalBuyEvent.newServerToClient(AnimalBuyEvent.BUY_ERROR_NO_PERMISSION))
			return

		end

		local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
		local farmId = g_farmManager:getFarmForUniqueUserId(userId).farmId

		Log:trace("AnimalBuyEvent:run phase: setup took %.2fms (N=%d, dest=%s)",
			phaseDoneMs(),
			#self.animals,
			tostring(self.object and self.object.getName and self.object:getName() or self.object))

		-- Recompute both body and the applicable delivery leg before checking
		-- affordability. A changed quote gets a refresh response; a forged price
		-- cannot choose what the server charges. Numeric comparison below allows
		-- only the float32 wire representation of the exact server totals.
		-- A failed computation still reaches ordinary subtype/pen validation,
		-- then refuses before any stock, animal or money mutation.
		local dispatchedBuyPrice,dispatchedTransportPrice=self.buyPrice,self.transportPrice
		local serverBuyPrice,serverTransportPrice = 0,0
		local priced = pcall(function()
			local total,fees = 0,0
			for _, animal in pairs(self.animals) do
				local price=RLAnimalBuyService.computeBuyPrice(animal)
				assert(type(price)=="number" and price==price and price>=0 and price<math.huge,"SERVER_BUY_PRICE_UNAVAILABLE")
				local fee=0
				if self.object==nil or self.object.spec_livestockTrailer==nil then fee=animal:getTranportationFee(1) end
				assert(type(fee)=="number" and fee==fee and fee>=0 and fee<math.huge,"SERVER_BUY_TRANSPORT_UNAVAILABLE")
				total = total - price
				fees = fees - fee
			end
			assert(math.abs(total)<math.huge and math.abs(fees)<math.huge,"SERVER_BUY_TOTAL_OVERFLOW")
			serverBuyPrice,serverTransportPrice = total,fees
		end)

		if not priced then
			Log:warning("AnimalBuyEvent:run: authoritative quote unavailable for %d animal(s); validating ordinary refusal before returning price-unavailable",
				#self.animals)
		else
			local clientBuyPrice = self.buyPrice or 0
			if not AnimalBuyEvent.matchesWirePrice(clientBuyPrice,serverBuyPrice) then
				Log:debug("AnimalBuyEvent:run: client body price %s differs from the server quote %s (charged as confirmed within QUOTE_TOLERANCE)",
					tostring(clientBuyPrice),tostring(serverBuyPrice))
			else
				Log:trace("AnimalBuyEvent:run: server price recompute agrees with the client (%.2f)", serverBuyPrice)
			end

			self.buyPrice = serverBuyPrice
			self.transportPrice = serverTransportPrice
		end

		phaseReset()
		for _, animal in pairs(self.animals) do

			local errorCode = AnimalBuyEvent.validate(self.object, animal.subTypeIndex, animal.age, #self.animals, self.buyPrice, self.transportPrice, farmId)

			if errorCode == nil then
				errorCode = AnimalBuyEvent.getPenErrorCode(self.object, animal)
			end

			-- Admission record: the map filter's and the pen rules' verdicts with the result,
			-- so a refusal says which layer (or capacity, farm, money) turned the animal away.
			RLHusbandryProfiles.logDecision("BUY_CHECK", self.object, animal,
				{ farmId = farmId, errorCode = errorCode, numAnimals = #self.animals })

			if errorCode ~= nil then
				Log:trace("AnimalBuyEvent:run phase: validate FAILED took %.2fms errorCode=%d", phaseDoneMs(), errorCode)
				connection:sendEvent(AnimalBuyEvent.newServerToClient(errorCode))
				return
			end

		end
		Log:trace("AnimalBuyEvent:run phase: validate took %.2fms", phaseDoneMs())

		-- An unavailable authoritative quote can still reach the validation
		-- loop for its usual subtype/pen error, but never the asset mutation.
		-- In particular, a new market quote may deliberately reject a scope.
		if not priced or type(serverBuyPrice)~="number" or serverBuyPrice~=serverBuyPrice or math.abs(serverBuyPrice)==math.huge then
			connection:sendEvent(AnimalBuyEvent.newServerToClient(AnimalBuyEvent.BUY_ERROR_PRICE_UNAVAILABLE))
			return
		end
		if not AnimalBuyEvent.acceptsConfirmedPrice(dispatchedBuyPrice,serverBuyPrice)
			or not AnimalBuyEvent.acceptsConfirmedPrice(dispatchedTransportPrice,serverTransportPrice) then
			connection:sendEvent(AnimalBuyEvent.newServerToClient(AnimalBuyEvent.BUY_ERROR_PRICE_UNAVAILABLE))
			return
		end
		-- Charged as the player confirmed it (within QUOTE_TOLERANCE of the server's quote).
		self.buyPrice,self.transportPrice = dispatchedBuyPrice,dispatchedTransportPrice

		phaseReset()
		for _, animal in pairs(self.animals) do

			g_currentMission.animalSystem:removeSaleAnimal(animal.animalTypeIndex, animal.birthday.country, animal.farmId, animal.uniqueId)

		end
		Log:trace("AnimalBuyEvent:run phase: removeSale took %.2fms", phaseDoneMs())

		local farm = g_farmManager ~= nil and g_farmManager:getFarmById(farmId) or nil
		local moneyBefore = farm ~= nil and farm.money or nil

		phaseReset()
		self.object:addAnimals(self.animals)
		Log:trace("AnimalBuyEvent:run phase: addAnimals took %.2fms", phaseDoneMs())

		phaseReset()
		g_currentMission:addMoney(self.buyPrice + self.transportPrice, farmId, MoneyType.NEW_ANIMALS_COST, true, true)
		connection:sendEvent(AnimalBuyEvent.newServerToClient(AnimalBuyEvent.BUY_SUCCESS))

		if self.object.spec_husbandryAnimals ~= nil then
			local bought = {}
			for _, animal in pairs(self.animals) do bought[#bought + 1] = RLPenLog.animal(animal) end
			RLPenLog.emit("BUY_RESULT", { pen = RLPenLog.pen(self.object), farmId = farmId, animals = bought,
				price = self.buyPrice, fee = self.transportPrice, moneyBefore = moneyBefore,
				moneyAfter = farm ~= nil and farm.money or nil,
				numAnimalsAfter = self.object.getNumOfAnimals ~= nil and self.object:getNumOfAnimals() or nil,
				construction = RLPenConstruction.describe(self.object) })
		end

		-- Object may be a trailer on trailer-based dealer buys; only husbandry
		-- placeables carry addRLMessage.
		if self.object.addRLMessage ~= nil then
			if #self.animals == 1 then
				self.object:addRLMessage("BOUGHT_ANIMALS_SINGLE", nil, { g_i18n:formatMoney(math.abs(self.buyPrice + self.transportPrice), 2, true, true) })
			elseif #self.animals > 0 then
				self.object:addRLMessage("BOUGHT_ANIMALS_MULTIPLE", nil, { #self.animals, g_i18n:formatMoney(math.abs(self.buyPrice + self.transportPrice), 2, true, true) })
			end
		else
			Log:trace("AnimalBuyEvent:run: skipping addRLMessage (object has no husbandryAnimals spec, likely trailer buy) N=%d", #self.animals)
		end
		Log:trace("AnimalBuyEvent:run phase: addMoney+sendEvent+addRLMessage took %.2fms", phaseDoneMs())

	end)

end

--- The pen rules' answer for one animal as a buy error code: PEN_NOT_BUILT for a husbandry that is
--- not built yet, ANIMAL_NOT_SUPPORTED for any other refusal, nil when the animal may go in.
--- @return number|nil errorCode
function AnimalBuyEvent.getPenErrorCode(object, animal)
	local ok, reason = RLHusbandryProfiles.checkAnimal(object, animal)
	if ok then return nil end
	return reason == RLPenConstruction.REJECT and AnimalBuyEvent.BUY_ERROR_PEN_NOT_BUILT or AnimalBuyEvent.BUY_ERROR_ANIMAL_NOT_SUPPORTED
end


--- A husbandry that is not built yet takes no animals (RLPenConstruction). Only a missing object
--- outranks it; every other base answer (subtype, space, money) comes after the building exists.
--- Every buy path (the base screens, RLRM's menu, the server's run) goes through here.
AnimalBuyEvent.validate = Utils.overwrittenFunction(AnimalBuyEvent.validate, function(object, superFunc, ...)
	local errorCode = superFunc(object, ...)
	if errorCode == AnimalBuyEvent.BUY_ERROR_OBJECT_DOES_NOT_EXIST then return errorCode end
	if not RLPenConstruction.canAdmit(object) then return AnimalBuyEvent.BUY_ERROR_PEN_NOT_BUILT end
	return errorCode
end)


-- The base screens look every reply code up in these tables and fail on a missing one.
for _, controller in ipairs({ AnimalScreenDealerFarm, AnimalScreenDealer, AnimalScreenDealerTrailer }) do
	if controller ~= nil and controller.BUY_ERROR_CODE_MAPPING ~= nil then
		controller.BUY_ERROR_CODE_MAPPING[AnimalBuyEvent.BUY_ERROR_PEN_NOT_BUILT] = { warning = true, text = "rl_ui_penNotBuilt" }
		controller.BUY_ERROR_CODE_MAPPING[AnimalBuyEvent.BUY_ERROR_PRICE_UNAVAILABLE] = { warning = true, text = "rl_ui_priceUnavailable" }
	end
end
