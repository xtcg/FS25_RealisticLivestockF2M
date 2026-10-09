--[[
    T02 source adapter: take a frozen batch of animals out of a pen or livestock trailer through
    RLRM's own cluster queue, check what really left, and put exactly those animal objects back.

    Remove: addPendingRemoveCluster for each frozen animal, then updateNow - the public path
    (RealisticLivestock_AnimalClusterSystem.updateClusters: removeCluster drops the visual
    animal, fixes the visual counts and the animal id map, rebuilds idToIndex, broadcasts
    AnimalClusterUpdateEvent, publishes it, updates the pen's visual animals).
    A flush also removes any member being ridden, with no head or a placeholder id, so a source
    holding one is refused; so is one with anything already queued (false values count).

    Restore: an animal still in the source only has this batch's queue entry cleared; an animal
    that left is re-added as the same object (id and idFull cleared, so the pen gives it a new
    visual animal; the removed engine id is never reused) through addPendingAddCluster and
    updateNow. Its business fields are compared with the frozen copy afterwards.

    Membership is always read from the live animal list by object and by full identity
    (farmId, uniqueId, birth country), never from idToIndex. A list that cannot be read is
    unknown, not "gone". Nothing here touches money or the target.
]]

RLTradeSourceAdapter = {}

local Log = RmLogging.getLogger("RLRM")

--- Fields a remove/re-add may change on an animal: engine ids and the cluster link.
RLTradeSourceAdapter.VOLATILE_FIELDS = { id = true, idFull = true, clusterSystem = true, isDirty = true }


local function identityKey(animal)
    if type(animal) ~= "table" or animal.farmId == nil or animal.uniqueId == nil or type(animal.birthday) ~= "table"
        or animal.birthday.country == nil then
        return nil
    end
    return RLAnimalUtil.toKey(animal.farmId, animal.uniqueId, animal.birthday.country)
end
RLTradeSourceAdapter.identityKey = identityKey


--- Members a flush removes on its own, besides the queued ones.
local function flushRemoves(animal)
    return animal.beingRidden == true or (animal.getNumAnimals ~= nil and animal:getNumAnimals() == 0)
        or animal.uniqueId == "1-1" or animal.uniqueId == "0-0"
end


--- Plain copy of an animal's business fields, for comparing after a restore.
local function snapshotFields(value, depth, seen)
    if type(value) ~= "table" then return value end
    if depth > 6 or seen[value] then return "<table>" end
    seen[value] = true
    local copy = {}
    for key, field in pairs(value) do
        if type(field) ~= "function" and not (depth == 0 and RLTradeSourceAdapter.VOLATILE_FIELDS[key]) then
            copy[key] = snapshotFields(field, depth + 1, seen)
        end
    end
    seen[value] = nil
    return copy
end


local function sameSnapshot(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
    for key, value in pairs(a) do
        if not sameSnapshot(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end


--- The cluster system of a source RLRM can remove from and restore to, and its kind.
--- @return table|nil clusterSystem
--- @return string kindOrReason "PEN", "TRAILER", or a refusal reason
function RLTradeSourceAdapter.getSupport(source)
    if source == nil or type(source.getClusterSystem) ~= "function" then return nil, "SOURCE_UNSUPPORTED" end
    -- The source object says whether this is the server: a live cluster system's isServer holds
    -- the base new function (RLRM's static override receives its arguments shifted).
    if source.isServer ~= true then return nil, "NOT_SERVER" end
    local ok, clusterSystem = pcall(source.getClusterSystem, source)
    if not ok or type(clusterSystem) ~= "table" then return nil, "SOURCE_UNREADABLE" end
    if type(clusterSystem.animals) ~= "table" or type(clusterSystem.clustersToAdd) ~= "table"
        or type(clusterSystem.clustersToRemove) ~= "table" or type(clusterSystem.addPendingRemoveCluster) ~= "function"
        or type(clusterSystem.addPendingAddCluster) ~= "function" or type(clusterSystem.updateNow) ~= "function"
        or type(clusterSystem.getClusters) ~= "function" then
        return nil, "SOURCE_UNSUPPORTED"
    end
    if source.spec_husbandryAnimals ~= nil then return clusterSystem, "PEN" end
    if source.spec_livestockTrailer ~= nil then return clusterSystem, "TRAILER" end
    return nil, "SOURCE_UNSUPPORTED"
end


--- The live member list, copied; nil when it cannot be read.
local function readMembers(clusterSystem)
    local ok, members = pcall(clusterSystem.getClusters, clusterSystem)
    if not ok or type(members) ~= "table" then return nil end
    local list = {}
    for _, animal in ipairs(members) do list[#list + 1] = animal end
    return list
end


--- Freeze a batch: resolve each identity key to exactly one live member, check the source can be
--- flushed for just this batch, and copy each animal's business fields.
--- @param source table
--- @param keys table Dense array of identity keys (RLAnimalUtil.toKey)
--- @return table|nil binding
--- @return string|nil reason
function RLTradeSourceAdapter.bind(source, keys)
    local clusterSystem, kind = RLTradeSourceAdapter.getSupport(source)
    if clusterSystem == nil then return nil, kind end
    local members = readMembers(clusterSystem)
    if members == nil then return nil, "SOURCE_UNREADABLE" end
    if next(clusterSystem.clustersToAdd) ~= nil or next(clusterSystem.clustersToRemove) ~= nil then
        return nil, "SOURCE_QUEUE_BUSY"
    end

    local byKey = {}
    for _, animal in ipairs(members) do
        if flushRemoves(animal) then return nil, "SOURCE_FLUSH_WOULD_REMOVE" end
        local key = identityKey(animal)
        if key ~= nil then
            if byKey[key] ~= nil then byKey[key] = false else byKey[key] = animal end
        end
    end

    local animals, inBatch, snapshots = {}, {}, {}
    for i, key in ipairs(keys) do
        local animal = byKey[key]
        if animal == nil then return nil, "ANIMAL_NOT_FOUND:" .. tostring(key) end
        if animal == false then return nil, "ANIMAL_IDENTITY_NOT_UNIQUE:" .. tostring(key) end
        if inBatch[animal] then return nil, "DUPLICATE_ANIMAL:" .. tostring(key) end
        if animal.isDead or animal.isSold then return nil, "ANIMAL_GONE:" .. tostring(key) end
        if animal.sale ~= nil then return nil, "ANIMAL_LISTED_FOR_SALE:" .. tostring(key) end
        inBatch[animal] = true
        animals[i] = animal
        snapshots[i] = snapshotFields(animal, 0, {})
    end

    local others = {}
    for _, animal in ipairs(members) do
        if not inBatch[animal] then others[#others + 1] = animal end
    end

    return { source = source, clusterSystem = clusterSystem, kind = kind, keys = keys, animals = animals,
        ownerFarmId = source.getOwnerFarmId ~= nil and source:getOwnerFarmId() or nil,
        inBatch = inBatch, snapshots = snapshots, others = others,
        receipt = { stage = "BOUND", kind = kind, keys = keys, removed = {}, restored = {} } }
end


--- Re-check just before removal: same cluster system, every frozen animal still a member
--- once, nothing queued, nothing a flush would remove, and no other member gone or added.
--- @return boolean ok
--- @return string|nil reason
function RLTradeSourceAdapter.recheck(binding, ownRemoveQueue)
    local clusterSystem = RLTradeSourceAdapter.getSupport(binding.source)
    if clusterSystem ~= binding.clusterSystem then return false, "SOURCE_CHANGED" end
    if binding.source.getOwnerFarmId ~= nil and binding.source:getOwnerFarmId() ~= binding.ownerFarmId then
        return false, "SOURCE_OWNER_CHANGED"
    end
    local members = readMembers(clusterSystem)
    if members == nil then return false, "SOURCE_UNREADABLE" end
    if next(clusterSystem.clustersToAdd) ~= nil then return false, "SOURCE_QUEUE_BUSY" end
    for animal, value in pairs(clusterSystem.clustersToRemove) do
        if not ownRemoveQueue or not binding.inBatch[animal] or value ~= true then return false, "SOURCE_QUEUE_BUSY" end
    end
    local count = {}
    for _, animal in ipairs(members) do
        if flushRemoves(animal) then return false, "SOURCE_FLUSH_WOULD_REMOVE" end
        count[animal] = (count[animal] or 0) + 1
    end
    for i, animal in ipairs(binding.animals) do
        if count[animal] ~= 1 or identityKey(animal) ~= binding.keys[i] then return false, "ANIMAL_CHANGED:" .. tostring(binding.keys[i]) end
        if animal.isDead or animal.isSold or animal.sale ~= nil then return false, "ANIMAL_GONE:" .. tostring(binding.keys[i]) end
        if not sameSnapshot(snapshotFields(animal, 0, {}), binding.snapshots[i]) then
            return false, "ANIMAL_FIELDS_CHANGED:" .. tostring(binding.keys[i])
        end
    end
    if #members ~= #binding.animals + #binding.others then return false, "SOURCE_MEMBERS_CHANGED" end
    for _, animal in ipairs(binding.others) do
        if count[animal] ~= 1 then return false, "SOURCE_MEMBERS_CHANGED" end
    end
    return true
end


--- Queue the batch for removal and flush.
--- @return boolean ok Every call returned
function RLTradeSourceAdapter.apply(binding)
    local r = binding.receipt
    if r.applied then return false end
    -- HB's money/activation/visual callbacks may have changed this source after preflight.
    -- Refuse before owning any queue entries; rollback must leave foreign work untouched.
    local ok, reason = RLTradeSourceAdapter.recheck(binding)
    if not ok then r.error = "RECHECK:" .. tostring(reason) return false end
    r.applied, r.stage = true, "APPLYING"
    local clusterSystem = binding.clusterSystem
    for i, animal in ipairs(binding.animals) do
        local ok, err = pcall(clusterSystem.addPendingRemoveCluster, clusterSystem, animal)
        if not ok then
            r.error = string.format("QUEUE_THREW:%d:%s", i, tostring(err))
            return false
        end
    end
    -- Enqueueing calls setDirty/raiseActive, which can invoke listeners as well.
    -- Only this batch's remove entries may be consumed by the following flush.
    ok, reason = RLTradeSourceAdapter.recheck(binding, true)
    if not ok then r.error = "RECHECK_BEFORE_FLUSH:" .. tostring(reason) return false end
    local ok, err = pcall(clusterSystem.updateNow, clusterSystem)
    if not ok then
        r.error = "FLUSH_THREW:" .. tostring(err)
        return false
    end
    r.stage = "APPLIED_UNVERIFIED"
    return true
end


--- Which frozen animals are members now, by object; nil when the list cannot be read.
local function presence(binding)
    local members = readMembers(binding.clusterSystem)
    if members == nil then return nil end
    local count = {}
    for _, animal in ipairs(members) do count[animal] = (count[animal] or 0) + 1 end
    return count, members
end


--- Whether exactly the batch left: every frozen animal gone, every other member still there
--- once, nothing left queued.
--- @return boolean ok
--- @return string|nil reason
function RLTradeSourceAdapter.verify(binding)
    local r = binding.receipt
    local count, members = presence(binding)
    if count == nil then r.verifyError = "SOURCE_UNREADABLE" return false, r.verifyError end
    r.removed = {}
    for i, animal in ipairs(binding.animals) do
        if count[animal] == nil then r.removed[#r.removed + 1] = binding.keys[i] end
    end
    if #r.removed ~= #binding.animals then r.verifyError = "NOT_ALL_REMOVED" return false, r.verifyError end
    for _, animal in ipairs(binding.others) do
        if count[animal] ~= 1 then r.verifyError = "OTHER_MEMBER_CHANGED" return false, r.verifyError end
    end
    if #members ~= #binding.others then r.verifyError = "OTHER_MEMBER_CHANGED" return false, r.verifyError end
    local clusterSystem = binding.clusterSystem
    if next(clusterSystem.clustersToAdd) ~= nil or next(clusterSystem.clustersToRemove) ~= nil then
        r.verifyError = "QUEUE_LEFT" return false, r.verifyError
    end
    r.verified, r.stage = true, "APPLIED"
    return true
end


--- Batch 3 (live sale): which frozen animals left and which stayed, by object, without judging
--- the batch. Unknown when the list cannot be read or a frozen animal is listed twice.
--- sameSystem: the source still has the bound cluster system; othersIntact: every member outside
--- the batch is still there once and nothing else joined.
--- @return table outcome {known, reason?, sameSystem, othersIntact, removed = {i}, survivors = {i}, removedKeys, survivorKeys}
function RLTradeSourceAdapter.observe(binding)
    local r = binding.receipt
    local okSupport, clusterSystem = pcall(RLTradeSourceAdapter.getSupport, binding.source)
    local count, members = presence(binding)
    if count == nil then
        r.observeError = "SOURCE_UNREADABLE"
        return { known = false, reason = "SOURCE_UNREADABLE" }
    end
    local outcome = { known = true, sameSystem = okSupport and clusterSystem == binding.clusterSystem, othersIntact = true,
        removed = {}, survivors = {}, removedKeys = {}, survivorKeys = {} }
    for i, animal in ipairs(binding.animals) do
        if count[animal] == nil then
            outcome.removed[#outcome.removed + 1] = i
            outcome.removedKeys[#outcome.removedKeys + 1] = binding.keys[i]
        elseif count[animal] == 1 then
            outcome.survivors[#outcome.survivors + 1] = i
            outcome.survivorKeys[#outcome.survivorKeys + 1] = binding.keys[i]
        else
            r.observeError = "BATCH_MEMBER_DUPLICATED"
            return { known = false, reason = "BATCH_MEMBER_DUPLICATED:" .. tostring(binding.keys[i]) }
        end
    end
    for _, animal in ipairs(binding.others) do
        if count[animal] ~= 1 then outcome.othersIntact = false end
    end
    if #members ~= #binding.others + #outcome.survivors then outcome.othersIntact = false end
    r.removed, r.survivors = outcome.removedKeys, outcome.survivorKeys
    r.stage = "OBSERVED"
    return outcome
end


--- Batch 3 (live sale): take this batch's animals off the source's queues, touching no other
--- entry. An animal that left has no entry; one still a member must not be removed unpaid by a
--- later flush. True only when no frozen animal is left in either queue.
--- @return boolean ok
--- @return string|nil reason
function RLTradeSourceAdapter.clearBatchQueue(binding)
    local clusterSystem = binding.clusterSystem
    if type(clusterSystem.clustersToRemove) ~= "table" or type(clusterSystem.clustersToAdd) ~= "table" then
        return false, "QUEUE_UNREADABLE"
    end
    for _, animal in ipairs(binding.animals) do clusterSystem.clustersToRemove[animal] = nil end
    for _, animal in ipairs(binding.animals) do
        if clusterSystem.clustersToRemove[animal] ~= nil or clusterSystem.clustersToAdd[animal] ~= nil then
            return false, "QUEUE_LEFT"
        end
    end
    return true
end


--- Put back exactly what this batch took out. Idempotent. False when the source cannot be read
--- or the re-add throws (unknown: keep for reconciliation).
--- @return boolean ok
function RLTradeSourceAdapter.rollback(binding)
    local r = binding.receipt
    if r.rolledBack then return true end
    if not r.applied then r.rolledBack, r.stage = true, "NOT_APPLIED" return true end
    local clusterSystem = binding.clusterSystem
    local count = presence(binding)
    if count == nil then r.rollbackError = "SOURCE_UNREADABLE" return false end

    local readd = {}
    for i, animal in ipairs(binding.animals) do
        -- Still a member: only this batch's own queue entry goes; a re-add would duplicate it.
        if clusterSystem.clustersToRemove[animal] ~= nil then clusterSystem.clustersToRemove[animal] = nil end
        if count[animal] == nil then readd[#readd + 1] = i end
    end
    if next(clusterSystem.clustersToAdd) ~= nil or next(clusterSystem.clustersToRemove) ~= nil then
        r.rollbackError = "FOREIGN_QUEUE"
        return false
    end
    r.restored = {}
    local expectedAdds = {}
    for _, i in ipairs(readd) do
        local animal = binding.animals[i]
        expectedAdds[animal] = true
        animal.id, animal.idFull = nil, nil
        local ok, err = pcall(clusterSystem.addPendingAddCluster, clusterSystem, animal)
        if not ok then r.rollbackError = "READD_QUEUE_THREW:" .. tostring(err) return false end
        r.restored[#r.restored + 1] = binding.keys[i]
    end
    if #readd > 0 then
        -- Restore enqueueing raises active as well. Do not consume a listener's foreign
        -- queue while trying to undo this transaction; leave the uncertain work locked.
        local queued = 0
        for animal, value in pairs(clusterSystem.clustersToAdd) do
            if not expectedAdds[animal] or value ~= true then r.rollbackError = "FOREIGN_QUEUE" return false end
            queued = queued + 1
        end
        if next(clusterSystem.clustersToRemove) ~= nil then r.rollbackError = "FOREIGN_QUEUE" return false end
        if queued ~= #readd then r.rollbackError = "RESTORE_QUEUE_CHANGED" return false end
        local ok, err = pcall(clusterSystem.updateNow, clusterSystem)
        if not ok then r.rollbackError = "READD_FLUSH_THREW:" .. tostring(err) return false end
    end
    r.rolledBack, r.stage = true, "ROLLED_BACK_UNVERIFIED"
    Log:info("RLTradeSourceAdapter.rollback: %d animal(s) put back into %s", #readd, tostring(binding.kind))
    return true
end


--- Whether the source is back to its members: every frozen animal present once with the same
--- business fields and cluster link, every other member present once, nothing queued.
--- @return boolean ok
--- @return string|nil reason
function RLTradeSourceAdapter.verifyRestored(binding)
    local r = binding.receipt
    if not r.applied then return true end
    if not r.rolledBack then return false, "NOT_ROLLED_BACK" end
    local count, members = presence(binding)
    if count == nil then return false, "SOURCE_UNREADABLE" end
    local clusterSystem = binding.clusterSystem
    for i, animal in ipairs(binding.animals) do
        if count[animal] ~= 1 or animal.clusterSystem ~= clusterSystem then return false, "NOT_RESTORED:" .. tostring(binding.keys[i]) end
        if not sameSnapshot(snapshotFields(animal, 0, {}), binding.snapshots[i]) then
            return false, "FIELDS_CHANGED:" .. tostring(binding.keys[i])
        end
    end
    for _, animal in ipairs(binding.others) do
        if count[animal] ~= 1 then return false, "OTHER_MEMBER_CHANGED" end
    end
    if #members ~= #binding.animals + #binding.others then return false, "MEMBER_COUNT" end
    if next(clusterSystem.clustersToAdd) ~= nil or next(clusterSystem.clustersToRemove) ~= nil then return false, "QUEUE_LEFT" end
    r.stage = "ROLLED_BACK"
    return true
end


--- The receipt as plain data.
function RLTradeSourceAdapter.exportReceipt(binding)
    local r = binding.receipt
    local copy = {}
    for key, value in pairs(r) do
        if type(value) == "table" then
            local list = {}
            for i, item in ipairs(value) do list[i] = item end
            copy[key] = list
        else
            copy[key] = value
        end
    end
    return copy
end
