--[[
    RLSemenSalePrompt.lua
    "Sell semen" prompt on a dewar the player looks at. The dewar targeting is RLRM's own
    (RealisticLivestock_PlayerInputComponent sets `self.dewar` for the Take Straw prompt); this
    adds a second action on the same target, shown only for a dewar the player's farm owns.
    Selling asks for confirmation, then sends SemenSellEvent - the server sets the price.
]]

RLSemenSalePrompt = {}

local Log = RmLogging.getLogger("RLRM")


--- Register the sell action with the player's other actions. Hidden until a dewar is targeted.
--- On foot only: the game also calls this when the player enters a vehicle, and keeping
--- that vehicle-context event id would leave the on-foot action unreachable (update would
--- toggle the vehicle one), so K did nothing once the player had driven anything.
function RLSemenSalePrompt.addPlayerActionEvents(playerInputComponent, controlling)
    if controlling == "VEHICLE" then return end

    local _, actionEventId = g_inputBinding:registerActionEvent(InputAction.RL_SELL_SEMEN,
        playerInputComponent, RLSemenSalePrompt.onSell, false, true, false, false, nil, true)

    if actionEventId ~= nil and actionEventId ~= "" then
        playerInputComponent.rlSellSemenActionId = actionEventId
    else
        Log:trace("RLSemenSalePrompt: RL_SELL_SEMEN not registered (controlling=%s)", tostring(controlling))
    end
end


--- Whether the local player may sell this dewar.
local function canSell(dewar)
    return dewar ~= nil and dewar.isDeleted ~= true and dewar:getAnimal() ~= nil
        and g_localPlayer ~= nil and dewar:getOwnerFarmId() == g_localPlayer.farmId
        and g_currentMission:getHasPlayerPermission("tradeAnimals")
end


--- The prompt for a dewar: its value, or how many of its straws the month's dealer quota takes,
--- or that the quota is used up.
function RLSemenSalePrompt.getPromptText(dewar)
    if (dewar.straws or 0) <= 0 then return g_i18n:getText("rl_semen_discardEmpty") end
    local straws = RLSemenCollection.getSellableStraws(dewar:getAnimal(), dewar.straws, dewar:getOwnerFarmId())
    if straws <= 0 then return g_i18n:getText("rl_semen_quotaFull") end

    local value = g_i18n:formatMoney(RLSemenCollection.getSellValue(dewar:getAnimal(), straws), 0, true, true)
    if straws < dewar.straws then
        return string.format(g_i18n:getText("rl_semen_sellPromptPartial"), straws, dewar.straws, value)
    end
    return string.format(g_i18n:getText("rl_semen_sellPrompt"), value)
end


--- Show or hide the prompt for the dewar RLRM's targeting picked this frame.
function RLSemenSalePrompt.update(playerInputComponent, _)
    local actionEventId = playerInputComponent.rlSellSemenActionId
    if actionEventId == nil then return end

    local dewar = playerInputComponent.dewar
    local active = canSell(dewar)

    if active then
        g_inputBinding:setActionEventText(actionEventId, RLSemenSalePrompt.getPromptText(dewar))
    end
    g_inputBinding:setActionEventActive(actionEventId, active)
end


--- Action callback: confirm, then ask the server to sell the targeted dewar.
function RLSemenSalePrompt.onSell(playerInputComponent)
    local dewar = playerInputComponent.dewar
    if not canSell(dewar) then
        Log:debug("RLSemenSalePrompt: K refused (dewar=%s owner=%s playerFarm=%s)", tostring(dewar),
            tostring(dewar ~= nil and dewar.getOwnerFarmId ~= nil and dewar:getOwnerFarmId()),
            tostring(g_localPlayer ~= nil and g_localPlayer.farmId))
        return
    end

    -- A dewar kept empty after its last straw was taken by hand: discarding it is the only action.
    if (dewar.straws or 0) <= 0 then
        RLSemenSalePrompt.pendingDewar = dewar
        YesNoDialog.show(RLSemenSalePrompt.onSellConfirmed, RLSemenSalePrompt,
            g_i18n:getText("rl_semen_discardConfirm"), g_i18n:getText("rl_semen_discardEmpty"))
        return
    end

    local straws = RLSemenCollection.getSellableStraws(dewar:getAnimal(), dewar.straws, dewar:getOwnerFarmId())
    if straws <= 0 then
        InfoDialog.show(g_i18n:getText("rl_semen_quotaFullInfo"))
        return
    end

    local value = g_i18n:formatMoney(RLSemenCollection.getSellValue(dewar:getAnimal(), straws), 0, true, true)
    local text = straws < dewar.straws
        and string.format(g_i18n:getText("rl_semen_sellConfirmPartial"), straws, dewar.straws, value)
        or string.format(g_i18n:getText("rl_semen_sellConfirm"), dewar.straws, value)

    RLSemenSalePrompt.pendingDewar = dewar
    YesNoDialog.show(RLSemenSalePrompt.onSellConfirmed, RLSemenSalePrompt, text, g_i18n:getText("rl_semen_sell"))
end


--- Confirmation answer for the dewar remembered by onSell.
function RLSemenSalePrompt:onSellConfirmed(yes)
    local dewar = RLSemenSalePrompt.pendingDewar
    RLSemenSalePrompt.pendingDewar = nil

    if yes and dewar ~= nil and dewar.isDeleted ~= true then
        Log:debug("RLSemenSalePrompt: selling dewar uniqueId=%s straws=%d", tostring(dewar:getUniqueId()), dewar.straws or 0)
        g_client:getServerConnection():sendEvent(SemenSellEvent.new(dewar))
    end
end


PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
    PlayerInputComponent.registerGlobalPlayerActionEvents, RLSemenSalePrompt.addPlayerActionEvents)
PlayerInputComponent.update = Utils.appendedFunction(PlayerInputComponent.update, RLSemenSalePrompt.update)
