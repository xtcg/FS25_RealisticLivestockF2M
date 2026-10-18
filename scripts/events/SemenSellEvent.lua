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

        -- The player's own semen sells up to the month's dealer quota; the rest stays in the dewar.
        local snapshot = dewar:getAnimal()
        local straws, quotaType = RLSemenCollection.getSellableStraws(snapshot, dewar.straws, farmId)
        if straws <= 0 then
            Log:info("SemenSellEvent: refused, farmId=%d has no %s quota left this month (dewar=%s)",
                farmId, tostring(quotaType), tostring(dewar:getUniqueId()))
            return
        end

        local value = RLSemenCollection.getSellValue(snapshot, straws)
        Log:info("SemenSellEvent: farmId=%d sold %d of %d straws from dewar uniqueId=%s for %.2f",
            farmId, straws, dewar.straws or 0, tostring(dewar:getUniqueId()), value)

        g_currentMission:addMoney(value, farmId, MoneyType.SEMEN_SALE, true, true)

        if quotaType ~= nil then
            local used = RLSemenCollection.addQuotaUsed(farmId, quotaType, straws)
            if g_server ~= nil and used ~= nil then
                g_server:broadcastEvent(RLSemenQuotaEvent.new({ { farmId = farmId, typeName = quotaType,
                    month = RLSemenCollection.getMonthIndex(), used = used } }))
            end
        end

        if straws < dewar.straws then
            dewar:changeStraws(-straws)
        else
            dewar:delete()
        end
    end)
end
