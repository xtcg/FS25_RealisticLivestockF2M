--[[
    RLBodyConditionStateEvent
    Server -> clients, once per game hour per cattle pen whose animals took a body condition step:
    each stepped animal's weight, reserve, trends, weight model v2 state (RLGrowth) and last budget
    (ration coverage, intake, milk share, and in the real-equivalent nutrition mode its real
    intake, limits and target), and the pen's feed ledger summary (with the mode's state, ration and
    feed month). Clients only display
    these; the server is the only one that advances them. Sent from
    RL_PlaceableHusbandry:onHourChanged.

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
    -- The hour the animals below took their step (their nutrition's hour on the client).
    streamWriteInt32(streamId, self.tick or -1)
    -- Real-equivalent nutrition: the pen's mode, ration and feed month (RLFeed).
    RLFeed.writePenStream(self.object, streamId)

    local animals = {}
    for _, animal in ipairs(self.object:getClusters()) do
        local state, growth = animal.bodyCondition, animal.rlGrowth
        if state ~= nil and (state.lastTick == self.tick or (growth ~= nil and growth.lastTick == self.tick)) then
            table.insert(animals, animal)
        end
    end

    streamWriteUInt16(streamId, #animals)
    for _, animal in ipairs(animals) do
        local state = animal.bodyCondition
        local nutrition = animal.rlNutrition or {}
        RLAnimalUtil.writeStreamIdentifiers(animal, streamId, connection)
        streamWriteFloat32(streamId, animal.weight)
        RLBodyCondition.writeStream(state, streamId)
        RLGrowth.writeStream(animal.rlGrowth, streamId)
        streamWriteFloat32(streamId, nutrition.coverage or 0)
        streamWriteFloat32(streamId, nutrition.intakeRatio or 0)
        streamWriteFloat32(streamId, nutrition.milkShare or -1)
        RLFeed.writeAnimalStream(animal, streamId)
    end
end


function RLBodyConditionStateEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.summary = {
        eatenShare = streamReadFloat32(streamId),
        energy = streamReadFloat32(streamId),
        water = streamReadFloat32(streamId),
    }
    self.tick = streamReadInt32(streamId)
    self.feed = RLFeed.readPenStream(streamId)

    self.entries = {}
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        local identifiers = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
        local weight = streamReadFloat32(streamId)
        local state = RLBodyCondition.readStream(streamId)
        local growth = RLGrowth.readStream(streamId)
        local coverage = streamReadFloat32(streamId)
        local intakeRatio = streamReadFloat32(streamId)
        local milkShare = streamReadFloat32(streamId)
        local feed = RLFeed.readAnimalStream(streamId)
        table.insert(self.entries, { identifiers = identifiers, weight = weight, state = state, growth = growth,
            coverage = coverage, intakeRatio = intakeRatio, milkShare = milkShare >= 0 and milkShare or nil, feed = feed })
    end

    self:run(connection)
end


function RLBodyConditionStateEvent:run(connection)
    -- Only the server's word counts; a server never applies what a client sends.
    if connection == nil or not connection:getIsServer() or g_server ~= nil then return end
    if self.object == nil or self.object.getClusterSystem == nil then return end

    local foodSpec = self.object.spec_husbandryFood
    if foodSpec ~= nil then foodSpec.rlPenSummary = self.summary end
    RLFeed.applyPenStream(self.object, self.feed)

    local clusterSystem = self.object:getClusterSystem()
    if clusterSystem == nil then return end

    for _, entry in ipairs(self.entries) do
        local id = entry.identifiers
        local animal = RLAnimalUtil.find(clusterSystem.animals, id.farmId, id.uniqueId, id.country)
        if animal ~= nil and entry.state ~= nil then
            animal.weight = entry.weight
            animal.bodyCondition = entry.state
            if entry.growth ~= nil then
                animal.rlGrowth = entry.growth
                -- Its target weight follows its state (an old savegame's moves to the model's).
                if RLGrowth.covers(animal) then animal.targetWeight = RLGrowth.getAnimalTargetWeight(animal) end
            end
            animal.rlNutrition = { tick = self.tick, coverage = entry.coverage, intakeRatio = entry.intakeRatio,
                milkShare = entry.milkShare }
            animal.rlFeedClient = entry.feed
        end
    end
end
