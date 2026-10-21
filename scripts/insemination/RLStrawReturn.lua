--[[
    RLStrawReturn.lua
    The one rule for putting a straw back into a dewar, shared by the straw's prompt, the host's
    own return and the server's check of a client's request (ReturnStrawEvent).

    A straw goes back into the dewar it came from, or into another dewar of the same batch on the
    same farm (RLSemenBatch); a legacy straw without a batch id returns to its own dewar only.
    Batches never mix: the same sire's straws of another month are another batch.
]]

RLStrawReturn = {}

RLStrawReturn.REFUSAL = {
    MISSING = "MISSING",       -- the target is gone or is not a dewar
    USED = "USED",             -- the straw has been used
    PENDING = "PENDING",       -- a request for this straw already waits for the server
    OTHER_FARM = "OTHER_FARM", -- the dewar belongs to another farm
    OTHER_BATCH = "OTHER_BATCH",
    FULL = "FULL",
    NOT_HELD = "NOT_HELD",     -- server: no straw of this batch on record for the player
}

RLStrawReturn.TEXT = {
    MISSING = "rl_strawReturn_missing",
    USED = "rl_strawReturn_used",
    PENDING = "rl_insemination_pending",
    OTHER_FARM = "rl_strawReturn_otherFarm",
    OTHER_BATCH = "rl_strawReturn_otherBatch",
    FULL = "rl_strawReturn_full",
    NOT_HELD = "rl_strawReturn_notHeld",
}


--- Why `straw` (its sire snapshot and the dewar it was taken from) cannot go into `dewar` for
--- a player of `farmId`; nil when it can.
--- @param straw table { animal = snapshot, dewarUniqueId = string|nil, isEmpty = bool, awaitingServer = bool }
--- @param dewar table|nil Dewar vehicle
--- @param farmId number The returning player's farm
--- @return string|nil refusal One of RLStrawReturn.REFUSAL
function RLStrawReturn.getRefusal(straw, dewar, farmId)
    local R = RLStrawReturn.REFUSAL
    if straw == nil or straw.isEmpty then return R.USED end
    if straw.awaitingServer then return R.PENDING end
    if dewar == nil or dewar.isDewar ~= true or dewar.isDeleted == true then return R.MISSING end
    if farmId == nil or dewar:getOwnerFarmId() ~= farmId then return R.OTHER_FARM end

    local ownDewar = straw.dewarUniqueId ~= nil and straw.dewarUniqueId ~= "" and dewar:getUniqueId() == straw.dewarUniqueId
    if not ownDewar then
        local dewarAnimal = dewar.getAnimal ~= nil and dewar:getAnimal() or nil
        if straw.animal == nil or dewarAnimal == nil or straw.animal.batchId == nil
            or dewarAnimal.batchId ~= straw.animal.batchId then return R.OTHER_BATCH end
    end

    local capacity = DewarData ~= nil and DewarData.CAPACITY or 1000
    if (dewar.straws or 0) >= capacity then return R.FULL end
    return nil
end


--- The player-facing text for a refusal.
function RLStrawReturn.getText(refusal)
    return g_i18n:getText(RLStrawReturn.TEXT[refusal] or RLStrawReturn.TEXT.MISSING)
end


--- The dewar a targeted collision node belongs to: the node's own object, or one of its parents'
--- (a dewar's collision may sit below its component). Nil when the node is no dewar.
--- @param node number Entity id from the player's targeter
--- @param getObject function node -> object (g_currentMission:getNodeObject)
--- @param getParentNode function node -> parent node (getParent)
function RLStrawReturn.findDewar(node, getObject, getParentNode)
    for _ = 1, 4 do
        if node == nil or node == 0 then return nil end
        local object = getObject(node)
        if object ~= nil then return object.isDewar == true and object or nil end
        node = getParentNode(node)
    end
    return nil
end
