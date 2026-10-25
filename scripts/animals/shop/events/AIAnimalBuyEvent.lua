AIAnimalBuyEvent = {}

local AIAnimalBuyEvent_mt = Class(AIAnimalBuyEvent, Event)
InitEventClass(AIAnimalBuyEvent, "AIAnimalBuyEvent")


function AIAnimalBuyEvent.emptyNew()

    local self = Event.new(AIAnimalBuyEvent_mt)
    return self

end


function AIAnimalBuyEvent.new(object, animals, price)

	local event = AIAnimalBuyEvent.emptyNew()

	event.object = object
	event.animals = animals
	event.price = price

	return event

end


function AIAnimalBuyEvent:readStream(streamId, connection)

	self.object = NetworkUtil.readNodeObject(streamId)
	local numAnimals = streamReadUInt16(streamId)

	self.animals = {}

	for i = 1, numAnimals do

		local animal = Animal.new()
		animal:readStream(streamId, connection)
		table.insert(self.animals, animal)

	end

	self.price = streamReadFloat32(streamId)

	self:run(connection)

end


function AIAnimalBuyEvent:writeStream(streamId, connection)

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.animals)

	for _, animal in pairs(self.animals) do animal:writeStream(streamId, connection) end

	streamWriteFloat32(streamId, self.price)

end


function AIAnimalBuyEvent:run(connection)
    if RLBrokerRuntime and not RLBrokerRuntime.mutationAllowed() then return end

	RmSafeUtils.safeCall("AIAnimalBuyEvent:run", function()

		-- Backstop for validate: a pen that is not built takes nothing, checked before the dealer
		-- loses its animals or the farm pays. The construction state is synced, so every machine
		-- running this event decides the same.
		if not RLPenConstruction.canAdmit(self.object) then
			if g_server ~= nil then
				RLPenLog.emit("AI_BUY_REFUSED", { pen = RLPenLog.pen(self.object), numAnimals = #self.animals,
					price = self.price, construction = RLPenConstruction.describe(self.object),
					errorCode = AnimalBuyEvent.BUY_ERROR_PEN_NOT_BUILT }, true)
			end
			return
		end

		for _, animal in pairs(self.animals) do

			animal:setRecentlyBoughtByAI(true)

			g_currentMission.animalSystem:removeSaleAnimal(animal.animalTypeIndex, animal.birthday.country, animal.farmId, animal.uniqueId)

		end

		self.object:addAnimals(self.animals)

		if g_server ~= nil then

			local farmId = self.object:getOwnerFarmId()
			g_currentMission:addMoney(-self.price, farmId, MoneyType.NEW_ANIMALS_COST, true, true)

		end

	end)

end


function AIAnimalBuyEvent.validate(object, numAnimals, price, farmId)

	if object == nil then return AnimalBuyEvent.BUY_ERROR_OBJECT_DOES_NOT_EXIST end

	if not RLPenConstruction.canAdmit(object) then return AnimalBuyEvent.BUY_ERROR_PEN_NOT_BUILT end

	if object:getNumOfFreeAnimalSlots() < numAnimals then return AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_SPACE end
	
	if g_currentMission:getMoney(farmId) - price < 0 then return AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_MONEY end
	
	return nil

end
