--[[
    SemenCollectEvent.lua
    Collect semen from one of the player's own sires into a new dewar.

    REQUEST  client -> server: husbandry, sire identifiers, spawn position. The server
             re-validates (farm access, tradeAnimals permission, RLSemenCollection rules),
             spawns the dewar through VehicleLoadingData like SemenBuyEvent, and once it loaded
             charges the service fee (RLSemenCollection.getFee, checked before the load and again
             after it, when a short balance removes the dewar) and records the collection month
             on the sire.
    STATE    server -> all clients: the sire's new semenCollectedMonth and semenCollectedAge, so
             every copy of the animal refuses a second collection this month.
    RESULT   server -> requester: success with the straw count and fee, or the refusal reason.
]]

local Log = RmLogging.getLogger("RLRM")
local modDirectory = g_currentModDirectory

SemenCollectEvent = {}

local SemenCollectEvent_mt = Class(SemenCollectEvent, Event)
InitEventClass(SemenCollectEvent, "SemenCollectEvent")

SemenCollectEvent.MODE_REQUEST = 0
SemenCollectEvent.MODE_STATE = 1
SemenCollectEvent.MODE_RESULT = 2

--- Result sent when the refusal is not one of RLSemenCollection.REFUSAL.
SemenCollectEvent.RESULT_FAILED = "rl_semen_collectFailed"

--- Callback for the next RESULT on this client: { callback, target }.
SemenCollectEvent.pendingResult = nil


function SemenCollectEvent.emptyNew()
    return Event.new(SemenCollectEvent_mt)
end


function SemenCollectEvent.newRequest(object, animal, position, rotation)
    local self = SemenCollectEvent.emptyNew()
    self.mode = SemenCollectEvent.MODE_REQUEST
    self.object = object
    self.animal = animal
    self.position = position
    self.rotation = rotation
    return self
end


function SemenCollectEvent.newState(object, animal, collectedAge, collectedMonth)
    local self = SemenCollectEvent.emptyNew()
    self.mode = SemenCollectEvent.MODE_STATE
    self.object = object
    self.animal = animal
    self.collectedAge = collectedAge
    self.collectedMonth = collectedMonth
    return self
end


function SemenCollectEvent.newResult(resultKey, straws, fee)
    local self = SemenCollectEvent.emptyNew()
    self.mode = SemenCollectEvent.MODE_RESULT
    self.resultKey = resultKey
    self.straws = straws or 0
    self.fee = fee or 0
    return self
end


function SemenCollectEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.mode, 2)

    if self.mode == SemenCollectEvent.MODE_RESULT then
        streamWriteString(streamId, self.resultKey or "")
        streamWriteUInt16(streamId, self.straws)
        streamWriteFloat32(streamId, self.fee or 0)
        return
    end

    NetworkUtil.writeNodeObject(streamId, self.object)
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)

    if self.mode == SemenCollectEvent.MODE_STATE then
        streamWriteInt32(streamId, self.collectedAge)
        streamWriteInt32(streamId, self.collectedMonth or -1)
    else
        for i = 1, 3 do streamWriteFloat32(streamId, self.position[i]) end
        for i = 1, 3 do streamWriteFloat32(streamId, self.rotation[i]) end
    end
end


function SemenCollectEvent:readStream(streamId, connection)
    self.mode = streamReadUIntN(streamId, 2)

    if self.mode == SemenCollectEvent.MODE_RESULT then
        self.resultKey = streamReadString(streamId)
        self.straws = streamReadUInt16(streamId)
        self.fee = streamReadFloat32(streamId)
    else
        self.object = NetworkUtil.readNodeObject(streamId)
        self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

        if self.mode == SemenCollectEvent.MODE_STATE then
            self.collectedAge = streamReadInt32(streamId)
            self.collectedMonth = streamReadInt32(streamId)
            if self.collectedMonth < 0 then self.collectedMonth = nil end
        else
            self.position = { streamReadFloat32(streamId), streamReadFloat32(streamId), streamReadFloat32(streamId) }
            self.rotation = { streamReadFloat32(streamId), streamReadFloat32(streamId), streamReadFloat32(streamId) }
        end
    end

    self:run(connection)
end


--- Resolve the live animal an event names in its husbandry, or nil.
local function findAnimal(object, identifiers)
    if object == nil or object.getClusterSystem == nil or identifiers == nil then return nil end
    local clusterSystem = object:getClusterSystem()
    if clusterSystem == nil then return nil end
    local country = identifiers.country or (identifiers.birthday ~= nil and identifiers.birthday.country)
    return RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, country)
end


--- Each mode is accepted from one direction only: the server takes REQUESTs from clients, and
--- clients take STATE and RESULT from the server. Anything else is dropped, so a client cannot
--- rewrite a sire's collection month or fake a result.
function SemenCollectEvent:run(connection)
    local fromServer = connection:getIsServer()

    if self.mode == SemenCollectEvent.MODE_REQUEST and not fromServer then
        RmSafeUtils.safeCall("SemenCollectEvent:run", function() self:runRequest(connection) end)
    elseif self.mode == SemenCollectEvent.MODE_STATE and fromServer then
        local animal = findAnimal(self.object, self.animal)
        if animal ~= nil then
            animal.semenCollectedAge = self.collectedAge
            animal.semenCollectedMonth = self.collectedMonth
        end
    elseif self.mode == SemenCollectEvent.MODE_RESULT and fromServer then
        self:runResult()
    else
        Log:warning("SemenCollectEvent: dropped mode=%s fromServer=%s", tostring(self.mode), tostring(fromServer))
    end
end


--- Server: fees of collections whose dewar is still loading, by farm. A request counts them
--- against the farm's money, so two requests in flight cannot both pass on the same balance.
SemenCollectEvent.reservedFees = {}


local function reserveFee(farmId, delta)
    local reserved = math.max((SemenCollectEvent.reservedFees[farmId] or 0) + delta, 0)
    SemenCollectEvent.reservedFees[farmId] = reserved > 0 and reserved or nil
end


--- Server: validate the request and spawn the dewar.
function SemenCollectEvent:runRequest(connection)
    local function reply(resultKey, straws, fee)
        connection:sendEvent(SemenCollectEvent.newResult(resultKey, straws, fee))
    end

    local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
    local farm = userId ~= nil and g_farmManager:getFarmForUniqueUserId(userId) or nil
    local farmId = farm ~= nil and farm.farmId or nil

    if farmId == nil or self.object == nil
        or not g_currentMission:getHasPlayerPermission("tradeAnimals", connection)
        or not g_currentMission.accessHandler:canFarmAccess(farmId, self.object) then
        Log:warning("SemenCollectEvent: refused, no permission or access (farmId=%s)", tostring(farmId))
        reply(SemenCollectEvent.RESULT_FAILED)
        return
    end

    local animal = findAnimal(self.object, self.animal)
    if animal == nil then
        Log:warning("SemenCollectEvent: sire not found uniqueId=%s", tostring(self.animal and self.animal.uniqueId))
        reply(SemenCollectEvent.RESULT_FAILED)
        return
    end

    local refusal = RLSemenCollection.getRefusal(animal)
    if refusal ~= nil then
        Log:debug("SemenCollectEvent: refused uniqueId=%s reason=%s", tostring(animal.uniqueId), refusal)
        reply(refusal)
        return
    end

    local storeItem = g_storeManager:getItemByXMLFilename(modDirectory .. "objects/dewar/dewar.xml")
    if storeItem == nil then
        Log:error("SemenCollectEvent: dewar store item missing")
        reply(SemenCollectEvent.RESULT_FAILED)
        return
    end

    local straws = RLSemenCollection.getStrawYield(animal)
    local fee = RLSemenCollection.getFee(animal)
    local reserved = SemenCollectEvent.reservedFees[farmId] or 0
    if fee > 0 and g_currentMission:getMoney(farmId) - reserved < fee then
        Log:debug("SemenCollectEvent: refused uniqueId=%s, fee %.2f over the farm's money (%.2f held for loading dewars)",
            tostring(animal.uniqueId), fee, reserved)
        reply(RLSemenCollection.REFUSAL_NO_MONEY, 0, fee)
        return
    end

    local snapshot = RLSemenCollection.createSnapshot(animal)

    -- Claim the month before the async load, so a second request in flight is refused.
    local previousMonth, previousAge = animal.semenCollectedMonth, animal.semenCollectedAge
    RLSemenCollection.markCollected(animal)

    -- Drop the sire's cached semen rate at once; the building's own hourly total can still carry
    -- at most the rest of the current hour.
    local milk = animal:getSubType().output.milk
    if milk ~= nil and Animal.isSemenFillType(milk.fillType) and animal.output ~= nil then
        animal.output.milk = 0
    end

    local data = VehicleLoadingData.new()
    data:setStoreItem(storeItem)
    data:setPropertyState(VehiclePropertyState.OWNED)
    data:setOwnerFarmId(farmId)
    data:setPosition(self.position[1], self.position[2], self.position[3])
    data:setRotation(self.rotation[1], self.rotation[2], self.rotation[3])

    local object, identifiers = self.object, self.animal
    local collectedAge, collectedMonth = animal.semenCollectedAge, animal.semenCollectedMonth
    reserveFee(farmId, fee)
    data:load(function(_, vehicles, loadingState)
        reserveFee(farmId, -fee)
        local vehicle = vehicles ~= nil and vehicles[1] or nil
        if loadingState ~= VehicleLoadingState.OK or vehicle == nil then
            Log:warning("SemenCollectEvent: dewar failed to load (state=%s), month released", tostring(loadingState))
            RLSemenCollection.restoreCollected(animal, previousMonth, previousAge)
            reply(SemenCollectEvent.RESULT_FAILED)
            return
        end

        -- The hold only stops other collections; any other spending of the farm during the load
        -- does not see it, so the balance is checked again before charging.
        if fee > 0 and g_currentMission:getMoney(farmId) < fee then
            Log:info("SemenCollectEvent: uniqueId=%s, fee %.2f over the farm's money after the load, dewar removed",
                tostring(animal.uniqueId), fee)
            vehicle:delete()
            RLSemenCollection.restoreCollected(animal, previousMonth, previousAge)
            reply(RLSemenCollection.REFUSAL_NO_MONEY, 0, fee)
            return
        end

        vehicle:setAnimal(snapshot)
        vehicle:setStraws(straws)

        if fee > 0 then
            g_currentMission:addMoney(-fee, farmId, MoneyType.SEMEN_COLLECTION, true, true)
        end

        g_server:broadcastEvent(SemenCollectEvent.newState(object, identifiers, collectedAge, collectedMonth))
        reply("", straws, fee)

        Log:info("SemenCollectEvent: collected %d straw(s) from uniqueId=%s farmId=%d success=%.2f fee=%.2f",
            straws, tostring(animal.uniqueId), farmId, snapshot.success, fee)
    end, self)
end


--- Client: show the outcome and run the requester's callback.
function SemenCollectEvent:runResult()
    local text
    if self.resultKey == "" then
        text = string.format(g_i18n:getText("rl_semen_collected"), self.straws)
        if (self.fee or 0) > 0 then
            text = text .. " " .. string.format(g_i18n:getText("rl_semen_feeCharged"), g_i18n:formatMoney(self.fee, 0, true, true))
        end
    elseif self.resultKey == RLSemenCollection.REFUSAL_NO_MONEY then
        text = string.format(g_i18n:getText(self.resultKey), g_i18n:formatMoney(self.fee or 0, 0, true, true))
    else
        text = RLSemenCollection.getRefusalText(self.resultKey)
    end

    local pending = SemenCollectEvent.pendingResult
    SemenCollectEvent.pendingResult = nil

    InfoDialog.show(text, function()
        if pending ~= nil and pending.callback ~= nil then pending.callback(pending.target) end
    end, nil, self.resultKey == "" and DialogElement.TYPE_INFO or DialogElement.TYPE_WARNING)
end


--- Client: request a collection. The dewar is delivered to a free store spawn place, like a
--- bought one. Returns false (and warns) when no place is free.
--- @param callback function|nil Called with `target` after the result dialog closes
function SemenCollectEvent.sendRequest(object, animal, callback, target)
    local spawnPlaces = g_currentMission.storeSpawnPlaces
    local usedPlaces = g_currentMission.usedStorePlaces
    local x, y, z, place, width = nil, nil, nil, nil, nil
    if spawnPlaces ~= nil and usedPlaces ~= nil then
        x, y, z, place, width = PlacementUtil.getPlace(spawnPlaces,
            { width = 1, height = 2.5, length = 1, widthOffset = 0.5, lengthOffset = 0.5 },
            usedPlaces, true, true, false, true)
    end

    if x == nil then
        InfoDialog.show(g_i18n:getText("shop_messageNoSpace"), nil, nil, DialogElement.TYPE_WARNING)
        return false
    end

    PlacementUtil.markPlaceUsed(usedPlaces, place, width)
    SemenCollectEvent.pendingResult = { callback = callback, target = target }
    g_client:getServerConnection():sendEvent(SemenCollectEvent.newRequest(object, animal, { x, y, z }, { 0, 0, 0 }))
    return true
end
