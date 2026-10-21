--[[
    RLStrawLedger.lua
    Server-side record of the straws each remote player has taken from a dewar and not yet used
    or put back. The straw hand tool exists only on the client that holds it, so without this
    record the server would have to trust a client that says it is returning or using a straw.

    TakeStrawEvent records a straw with a copy of its dewar's sire snapshot; ReturnStrawEvent (after
    checking the return rule against that record) and the hand-tool AnimalInseminationEvent each
    spend one matching record, and insemination uses
    the recorded snapshot rather than genetics the client sent. A host or single player applies
    these actions locally and never goes through the record.

    In memory only: straws a remote player still holds when the server restarts can no longer be
    used or returned.
]]

RLStrawLedger = {}

local Log = RmLogging.getLogger("RLRM")

--- [uniqueUserId] = array of { dewarId = string, snapshot = table }
RLStrawLedger.held = {}


--- The unique user id behind a connection, or nil.
function RLStrawLedger.getUserId(connection)
    if connection == nil then return nil end
    return g_currentMission.userManager:getUniqueUserIdByConnection(connection)
end


--- The farm id of the user behind a connection, or nil.
function RLStrawLedger.getFarmId(connection)
    local userId = RLStrawLedger.getUserId(connection)
    local farm = userId ~= nil and g_farmManager:getFarmForUniqueUserId(userId) or nil
    return farm ~= nil and farm.farmId or nil
end


--- Record a straw handed out from `dewar` to a user.
function RLStrawLedger.record(userId, dewar)
    local list = RLStrawLedger.held[userId]
    if list == nil then
        list = {}
        RLStrawLedger.held[userId] = list
    end

    table.insert(list, { dewarId = dewar:getUniqueId(), snapshot = table.clone(dewar:getAnimal(), 3) })
    Log:trace("RLStrawLedger.record: user=%s dewar=%s held=%d", tostring(userId), tostring(dewar:getUniqueId()), #list)
end


--- Number of straws a user holds.
function RLStrawLedger.count(userId)
    local list = RLStrawLedger.held[userId]
    return list ~= nil and #list or 0
end


--- The user's straw that a return of `claim` (the straw's batch and its own dewar, as the client
--- names it) into `dewar` would spend, without spending it: one of the claim's batch, preferring
--- one taken from `dewar` itself.
--- @return table|nil entry { dewarId, snapshot }, number|nil index
function RLStrawLedger.findForReturn(userId, dewar, claim)
    local list = RLStrawLedger.held[userId]
    local dewarId = dewar ~= nil and dewar.getUniqueId ~= nil and dewar:getUniqueId() or nil
    local fallback, fallbackIndex

    for i, entry in ipairs(list or {}) do
        if claim == nil or RLSemenBatch.isSameBatch(entry.snapshot, claim) then
            if entry.dewarId == dewarId then return entry, i end
            if fallback == nil then fallback, fallbackIndex = entry, i end
        end
    end

    return fallback, fallbackIndex
end


--- Spend the straw findForReturn found (by its index), once the return was checked.
function RLStrawLedger.spendAt(userId, index)
    local list = RLStrawLedger.held[userId]
    if list == nil or index == nil or list[index] == nil then return nil end
    return table.remove(list, index)
end


--- Spend one of the user's straws to put it back into `dewar` when the return rule
--- (RLStrawReturn) allows it for a player of `farmId`.
--- @return boolean spent, string|nil refusal (RLStrawReturn.REFUSAL) when nothing was spent
function RLStrawLedger.spendForReturn(userId, dewar, claim, farmId)
    local entry, index = RLStrawLedger.findForReturn(userId, dewar, claim)
    if entry == nil then return false, RLStrawReturn.REFUSAL.NOT_HELD end

    local refusal = RLStrawReturn.getRefusal({ animal = entry.snapshot, dewarUniqueId = entry.dewarId }, dewar, farmId)
    if refusal ~= nil then return false, refusal end

    RLStrawLedger.spendAt(userId, index)
    return true
end


--- Spend one of the user's straws of the batch `semen` names (or, for data without batch ids,
--- the sire), for an insemination.
--- @return table|nil snapshot The server's copy of that straw's sire and batch, or nil when the user holds none
function RLStrawLedger.spendForSemen(userId, semen)
    local snapshot, index = RLStrawLedger.findForSemen(userId, semen)
    if snapshot ~= nil then table.remove(RLStrawLedger.held[userId], index) end
    return snapshot
end


--- The server's copy of the straw `spendForSemen` would spend, without spending it, so the
--- insemination can be checked against the recorded sire first.
--- @return table|nil snapshot, number|nil index
function RLStrawLedger.findForSemen(userId, semen)
    for i, entry in ipairs(RLStrawLedger.held[userId] or {}) do
        if RLSemenBatch.isSameBatch(entry.snapshot, semen) then return entry.snapshot, i end
    end
    return nil, nil
end
