--[[
    RLStrawLedger.lua
    Server-side record of the straws each remote player has taken from a dewar and not yet used
    or put back. The straw hand tool exists only on the client that holds it, so without this
    record the server would have to trust a client that says it is returning or using a straw.

    TakeStrawEvent records a straw with a copy of its dewar's sire snapshot; ReturnStrawEvent and
    the hand-tool AnimalInseminationEvent each spend one matching record, and insemination uses
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


--- Spend one of the user's straws to put it back into `dewar`: a straw taken from that dewar, or
--- one of the same batch (RLSemenBatch). False when the user holds none.
function RLStrawLedger.spendForReturn(userId, dewar)
    local list = RLStrawLedger.held[userId]
    local dewarId = dewar ~= nil and dewar:getUniqueId() or nil
    local dewarAnimal = dewar ~= nil and dewar.getAnimal ~= nil and dewar:getAnimal() or nil

    for i, entry in ipairs(list or {}) do
        if entry.dewarId == dewarId then
            table.remove(list, i)
            return true
        end
    end

    for i, entry in ipairs(list or {}) do
        if dewarAnimal ~= nil and dewarAnimal.batchId ~= nil and entry.snapshot.batchId == dewarAnimal.batchId then
            table.remove(list, i)
            return true
        end
    end

    return false
end


--- Spend one of the user's straws of the batch `semen` names (or, for data without batch ids,
--- the sire), for an insemination.
--- @return table|nil snapshot The server's copy of that straw's sire and batch, or nil when the user holds none
function RLStrawLedger.spendForSemen(userId, semen)
    local list = RLStrawLedger.held[userId]

    for i, entry in ipairs(list or {}) do
        if RLSemenBatch.isSameBatch(entry.snapshot, semen) then
            table.remove(list, i)
            return entry.snapshot
        end
    end

    return nil
end
