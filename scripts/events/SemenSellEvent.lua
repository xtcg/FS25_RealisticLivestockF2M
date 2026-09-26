--[[
    SemenSellEvent.lua
    Sell a dewar the player's farm owns. The server prices it with
    RLSemenCollection.getSellValue from the dewar's own snapshot and straw count - never a
    client-sent price - credits the farm, and deletes the dewar.
]]

local Log = RmLogging.getLogger("RLRM")

SemenSellEvent = {}

local SemenSellEvent_mt = Class(SemenSellEvent, Event)
InitEventClass(SemenSellEvent, "SemenSellEvent")


function SemenSellEvent.emptyNew()
    return Event.new(SemenSellEvent_mt)
end


function SemenSellEvent.new(dewar)
    local self = SemenSellEvent.emptyNew()
    self.dewar = dewar
    return self
end


function SemenSellEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.dewar)
end


function SemenSellEvent:readStream(streamId, connection)
    self.dewar = NetworkUtil.readNodeObject(streamId)
    self:run(connection)
end


function SemenSellEvent:run(connection)
    if connection:getIsServer() then return end

    RmSafeUtils.safeCall("SemenSellEvent:run", function()
        local dewar = self.dewar
        local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
        local farm = userId ~= nil and g_farmManager:getFarmForUniqueUserId(userId) or nil
        local farmId = farm ~= nil and farm.farmId or nil

        if dewar == nil or dewar.isDewar ~= true or dewar.isDeleted == true
            or farmId == nil or dewar:getOwnerFarmId() ~= farmId
            or not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then
            Log:warning("SemenSellEvent: refused (dewar=%s farmId=%s owner=%s)", tostring(dewar), tostring(farmId),
                tostring(dewar ~= nil and dewar.getOwnerFarmId ~= nil and dewar:getOwnerFarmId()))
            return
        end

        local value = RLSemenCollection.getSellValue(dewar:getAnimal(), dewar.straws)
        Log:info("SemenSellEvent: farmId=%d sold dewar uniqueId=%s straws=%d for %.2f",
            farmId, tostring(dewar:getUniqueId()), dewar.straws or 0, value)

        g_currentMission:addMoney(value, farmId, MoneyType.SEMEN_SALE, true, true)
        dewar:delete()
    end)
end
