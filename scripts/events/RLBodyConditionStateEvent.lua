--[[
    RLBodyConditionStateEvent
    Server -> clients, once per game hour per cattle pen whose animals took a body condition step:
    each stepped animal's weight, reserve, trends and last budget (ration coverage, intake, milk
    share), and the pen's feed ledger summary. Clients only display these; the server is the only
    one that advances them. Sent from RL_PlaceableHusbandry:onHourChanged.

    A client cannot send it: run() ignores it unless it came from the server.
]]

RLBodyConditionStateEvent = {}

local RLBodyConditionStateEvent_mt = Class(RLBodyConditionStateEvent, Event)
InitEventClass(RLBodyConditionStateEvent, "RLBodyConditionStateEvent")


function RLBodyConditionStateEvent.emptyNew()
    return Event.new(RLBodyConditionStateEvent_mt)
end


--- @param placeable table The cattle pen
--- @param tick number The hour whose steps to send
function RLBodyConditionStateEvent.new(placeable, tick)
    local event = RLBodyConditionStateEvent.emptyNew()
    event.object = placeable
    event.tick = tick
    return event
end


--- Pen summary of the hour's ledger: share of the request eaten, energy per liter requested,
--- water coverage.
local function getPenSummary(placeable)
    local foodSpec = placeable.spec_husbandryFood
    local supply = foodSpec ~= nil and foodSpec.rlNutritionSupply or nil
    local water = foodSpec ~= nil and foodSpec.rlWaterCoverage or nil
    local energy = 0
    if supply ~= nil then
        for _, share in pairs(supply.energyShare) do energy = energy + share end
    end
    return {
        eatenShare = (supply ~= nil and supply.requested > 0) and supply.eaten / supply.requested or 0,
        energy = energy,
        water = water ~= nil and water.coverage or 1,
    }
end


function RLBodyConditionStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)

    local summary = getPenSummary(self.object)
    streamWriteFloat32(streamId, summary.eatenShare)
    streamWriteFloat32(streamId, summary.energy)
    streamWriteFloat32(streamId, summary.water)

    local animals = {}
    for _, animal in ipairs(self.object:getClusters()) do
        local state = animal.bodyCondition
        if state ~= nil and state.lastTick == self.tick then table.insert(animals, animal) end
    end

    streamWriteUInt16(streamId, #animals)
    for _, animal in ipairs(animals) do
        local state = animal.bodyCondition
        local nutrition = animal.rlNutrition or {}
        RLAnimalUtil.writeStreamIdentifiers(animal, streamId, connection)
        streamWriteFloat32(streamId, animal.weight)
        RLBodyCondition.writeStream(state, streamId)
        streamWriteFloat32(streamId, nutrition.coverage or 0)
        streamWriteFloat32(streamId, nutrition.intakeRatio or 0)
        streamWriteFloat32(streamId, nutrition.milkShare or -1)
    end
end


function RLBodyConditionStateEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.summary = {
        eatenShare = streamReadFloat32(streamId),
        energy = streamReadFloat32(streamId),
        water = streamReadFloat32(streamId),
    }

    self.entries = {}
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        local identifiers = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
        local weight = streamReadFloat32(streamId)
        local state = RLBodyCondition.readStream(streamId)
        local coverage = streamReadFloat32(streamId)
        local intakeRatio = streamReadFloat32(streamId)
        local milkShare = streamReadFloat32(streamId)
        table.insert(self.entries, { identifiers = identifiers, weight = weight, state = state, coverage = coverage,
            intakeRatio = intakeRatio, milkShare = milkShare >= 0 and milkShare or nil })
    end

    self:run(connection)
end


function RLBodyConditionStateEvent:run(connection)
    -- Only the server's word counts; a server never applies what a client sends.
    if connection == nil or not connection:getIsServer() or g_server ~= nil then return end
    if self.object == nil or self.object.getClusterSystem == nil then return end

    local foodSpec = self.object.spec_husbandryFood
    if foodSpec ~= nil then foodSpec.rlPenSummary = self.summary end

    local clusterSystem = self.object:getClusterSystem()
    if clusterSystem == nil then return end

    for _, entry in ipairs(self.entries) do
        local id = entry.identifiers
        local animal = RLAnimalUtil.find(clusterSystem.animals, id.farmId, id.uniqueId, id.country)
        if animal ~= nil and entry.state ~= nil then
            animal.weight = entry.weight
            animal.bodyCondition = entry.state
            animal.rlNutrition = { tick = entry.state.lastTick, coverage = entry.coverage, intakeRatio = entry.intakeRatio,
                milkShare = entry.milkShare }
        end
    end
end
