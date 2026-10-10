--[[
    T02 controlled contract delivery: a batch of animals to Hof Bergmann's public slaughterhouse
    as one server transaction - the whole batch or nothing.

        OFF     (default) the old delivery path, unchanged, with its known limits.
        SHADOW  the old path runs; this module only prepares the transaction and logs what it
                would do. Nothing is locked or changed.
        TEST    development and test saves only: a supported batch goes through
                RLTradeTransaction with the HB target adapter and the source adapter; anything
                unsupported is refused, never passed to the old path.

    Supported first: COW animals with a meat profile, ALIGNED quote, from a pen or livestock
    trailer of the requesting farm, into HB 1.5.0.0 Beta2's contract service with an open order.
    The mode is per run (reset to OFF on every map load, never saved). Since batch 4 the records
    are saved with the savegame (RLTradeCheckpoint) once T02 was enabled in it, and TEST can only
    be set after the loaded ledger checked out; a transaction awaiting reconciliation stays held
    across reloads. TEST is for test saves.

    Order: prepare (permission, ownership, identities, live animals, quotes, whole-batch budget
    and room, HB binding, fingerprint, locks) -> preflight (recheck both sides) -> target
    (deliver, verify full deltas) -> source (remove, verify) -> commit. A failure undoes the
    source first, then the target; anything that cannot be proven undone stays
    NEEDS_RECONCILIATION with its locks held. Meat, fees, prices and recipes are not changed.
]]

RLContractTrade = {}

local Log = RmLogging.getLogger("RLRM")

RLContractTrade.MODE_OFF = "OFF"
RLContractTrade.MODE_SHADOW = "SHADOW"
RLContractTrade.MODE_TEST = "TEST"
RLContractTrade.POLICY_VERSION = "t02b2-2"
RLContractTrade.RECEIPT_SCHEMA = 1

--- Animal types this first version takes.
RLContractTrade.SUPPORTED_TYPES = { COW = true }


--- Back to OFF with an empty ledger (map load).
function RLContractTrade.reset()
    RLContractTrade.mode = RLContractTrade.MODE_OFF
    RLContractTrade.store = RLTradeTransaction.new()
    RLContractTrade.receipts = {}
    RLContractTrade.sequence = 0
end
RLContractTrade.reset()


function RLContractTrade.getMode()
    return RLContractTrade.mode
end


--- @param mode string OFF, SHADOW or TEST
--- @return boolean ok
function RLContractTrade.setMode(mode)
    mode = type(mode) == "string" and mode:upper() or nil
    if mode ~= RLContractTrade.MODE_OFF and mode ~= RLContractTrade.MODE_SHADOW and mode ~= RLContractTrade.MODE_TEST then return false end
    -- Batch 4: TEST only after the savegame's ledger checked out; setting it arms the ledger.
    if mode == RLContractTrade.MODE_TEST and RLTradeCheckpoint ~= nil and not RLTradeCheckpoint.allowTest() then
        return false, "LEDGER_" .. tostring(RLTradeCheckpoint.state) .. ":" .. tostring(RLTradeCheckpoint.reason)
    end
    RLContractTrade.mode = mode
    Log:info("RLContractTrade: mode %s", mode)
    return true
end


local function stableId(object)
    if object == nil then return "?" end
    if object.uniqueId ~= nil then return tostring(object.uniqueId) end
    local owner = object.owningPlaceable
    if owner ~= nil and owner.uniqueId ~= nil then return tostring(owner.uniqueId) end
    return tostring(object)
end


--- Identity keys of the requested animals: a dense array, every entry a full identity, no repeat.
--- @param animals table The request's animals (client payload copies; only their identity is used)
--- @return table|nil keys
--- @return string|nil reason
function RLContractTrade.readIdentities(animals)
    if type(animals) ~= "table" or getmetatable(animals) ~= nil then return nil, "BAD_BATCH" end
    local count = 0
    for key in pairs(animals) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return nil, "BAD_BATCH" end
        count = count + 1
    end
    if count == 0 or count ~= #animals then return nil, "EMPTY_OR_SPARSE_BATCH" end
    local keys, seen = {}, {}
    for i, animal in ipairs(animals) do
        local key = RLTradeSourceAdapter.identityKey(animal)
        if key == nil then return nil, "BAD_IDENTITY:" .. i end
        if seen[key] then return nil, "DUPLICATE_IDENTITY:" .. key end
        seen[key] = true
        keys[i] = key
    end
    return keys
end


--- Everything a batch needs before it may touch anything, or why not. With shadow no lock is taken.
--- @param request table {farmId, source, target, animals, connection?}
--- @param shadow boolean|nil
--- @return table|nil context
--- @return string|nil reason
function RLContractTrade.prepare(request, shadow)
    local mission = g_currentMission
    if mission == nil or mission.getIsServer == nil or not mission:getIsServer() then return nil, "NOT_SERVER" end
    local farmId, source, target = request.farmId, request.source, request.target
    if type(farmId) ~= "number" or farmId < 1 or farmId % 1 ~= 0 then return nil, "BAD_FARM" end

    -- Trade permission, and the source must belong to the requesting farm (access is not ownership).
    if request.connection ~= nil then
        if RLPermissionHelper == nil then return nil, "NO_PERMISSION_HELPER" end
        local ownerFarmId = source ~= nil and source.getOwnerFarmId ~= nil and source:getOwnerFarmId() or nil
        local ok, reason = RLPermissionHelper.authorizeConnection(request.connection, "tradeAnimals", ownerFarmId)
        if not ok then return nil, "NO_PERMISSION:" .. tostring(reason) end
    end
    if source == nil or source.getOwnerFarmId == nil or source:getOwnerFarmId() ~= farmId then return nil, "NOT_OWNER" end
    if mission.accessHandler ~= nil and not mission.accessHandler:canFarmAccess(farmId, target) then return nil, "NO_TARGET_ACCESS" end

    local support, reason = RLHBContractAdapter.getSupport(target)
    if support == nil then return nil, reason end

    local keys
    keys, reason = RLContractTrade.readIdentities(request.animals)
    if keys == nil then return nil, reason end
    local sourceBinding
    sourceBinding, reason = RLTradeSourceAdapter.bind(source, keys)
    if sourceBinding == nil then return nil, reason end

    -- Each live animal: role, health, facility age range, and a SUPPORTED, ALIGNED quote.
    local entries, fillType = {}, nil
    for i, animal in ipairs(sourceBinding.animals) do
        local subType = mission.animalSystem:getSubTypeByIndex(animal.subTypeIndex)
        local typeName = RLBreedTraits.getTypeName(subType)
        if not RLContractTrade.SUPPORTED_TYPES[typeName] then return nil, "TYPE_UNSUPPORTED:" .. tostring(typeName) end
        if RLDiseaseSaleGate ~= nil and not RLDiseaseSaleGate.check(animal) then return nil, "SICK:" .. keys[i] end
        local quote, description = RLTradeQuote.quoteAnimal(animal, target, farmId)
        if not quote.authoritative then return nil, "NOT_AUTHORITATIVE" end
        if quote.semantics ~= RLTradeQuote.WEIGHTED_BATCH then return nil, "NOT_WEIGHTED_BATCH" end
        -- A head's own CANNOT_AFFORD is decided by the whole batch below; anything else refuses.
        for _, why in ipairs(quote.reasons) do
            if why ~= "CANNOT_AFFORD" then return nil, "QUOTE:" .. why .. ":" .. keys[i] end
        end
        if quote.status ~= RLTradeQuote.SUPPORTED and not (quote.status == RLTradeQuote.UNKNOWN and #quote.reasons > 0) then
            return nil, "QUOTE_" .. tostring(quote.status) .. ":" .. keys[i]
        end
        if description.recipe == nil or description.recipe.alignment ~= "ALIGNED" then return nil, "RECIPE_NOT_ALIGNED" end
        if fillType ~= nil and description.inputFillType ~= fillType then return nil, "MIXED_INPUTS" end
        fillType = description.inputFillType
        entries[i] = { key = keys[i], quote = quote, inputFillType = description.inputFillType, room = description.room,
            recipeId = description.recipe.id, orderId = description.order ~= nil and description.order.id or nil,
            feeCredit = description.order ~= nil and description.order.feeCredit or nil }
    end

    -- Whole batch: room, the order's credit once, the farm's money once (RLContractPlan).
    local ok, money = pcall(mission.getMoney, mission, farmId)
    if not ok then return nil, "WALLET_UNKNOWN" end
    local plan
    plan, reason = RLContractPlan.prepare(entries, money)
    if plan == nil then return nil, reason end
    local amount = plan.inputs[fillType].amount

    local targetBinding
    targetBinding, reason = RLHBContractAdapter.bind(target, farmId, fillType, amount)
    if targetBinding == nil then return nil, reason end

    local sourceId, targetId = stableId(source), stableId(target)
    local sortedKeys = {}
    for i, key in ipairs(keys) do sortedKeys[i] = key end
    table.sort(sortedKeys)
    local fingerprint = table.concat({ "v" .. RLContractTrade.RECEIPT_SCHEMA, RLContractTrade.POLICY_VERSION,
        "farm=" .. farmId, "source=" .. sourceId, "target=" .. targetId, "order=" .. tostring(targetBinding.orderId),
        "recipe=" .. targetBinding.recipeFingerprint, string.format("amount=%.17g", amount),
        "animals=" .. table.concat(sortedKeys, ";") }, "|")

    local context = { farmId = farmId, source = source, target = target, keys = keys, plan = plan, amount = amount,
        fillType = fillType, sourceBinding = sourceBinding, targetBinding = targetBinding, fingerprint = fingerprint,
        connection = request.connection,
        sourceId = sourceId, targetId = targetId }
    if shadow then return context end

    local resources = { "cash:farm" .. farmId, "order:" .. targetId .. ":" .. tostring(targetBinding.orderId),
        "input:" .. targetId .. ":" .. tostring(fillType) .. ":farm" .. farmId, "source:" .. sourceId }
    for _, key in ipairs(keys) do resources[#resources + 1] = "animal:" .. key end

    RLContractTrade.sequence = RLContractTrade.sequence + 1
    context.txId = string.format("ct%d-f%d-o%s%s", RLContractTrade.sequence, farmId, tostring(targetBinding.orderId),
        RLTradeCheckpoint ~= nil and RLTradeCheckpoint.idTag() or "")
    local record
    record, reason = RLTradeTransaction.begin(RLContractTrade.store, context.txId, "CONTRACT", fingerprint, resources)
    if record == nil then return nil, reason end
    return context
end


--- The coordinator's adapter for one prepared context.
local function makeAdapter(context)
    local source, target = context.sourceBinding, context.targetBinding
    local function authorize()
        if RLContractTrade.mode ~= RLContractTrade.MODE_TEST then return false, "MODE" end
        if context.source:getOwnerFarmId() ~= context.farmId then return false, "NOT_OWNER" end
        if context.connection ~= nil then
            if RLPermissionHelper == nil then return false, "NO_PERMISSION_HELPER" end
            local ok, reason = RLPermissionHelper.authorizeConnection(context.connection, "tradeAnimals", context.farmId)
            if not ok then return false, "NO_PERMISSION:" .. tostring(reason) end
        end
        if g_currentMission.accessHandler ~= nil and not g_currentMission.accessHandler:canFarmAccess(context.farmId, context.target) then
            return false, "NO_TARGET_ACCESS"
        end
        return true
    end
    return {
        preflight = function()
            local ok, reason = authorize()
            if not ok then context.preflightError = reason return false end
            ok, reason = RLHBContractAdapter.recheck(target)
            if not ok then context.preflightError = reason return false end
            ok, reason = RLTradeSourceAdapter.recheck(source)
            if not ok then context.preflightError = reason return false end
            return true
        end,
        applyTarget = function() return RLHBContractAdapter.apply(target) end,
        verifyTarget = function() return (RLHBContractAdapter.verify(target)) end,
        rollbackTarget = function() return RLHBContractAdapter.rollback(target) end,
        verifyTargetRestored = function() return RLHBContractAdapter.verifyRestored(target) end,
        applySource = function()
            local ok, reason = authorize()
            if not ok then source.receipt.error = "RECHECK:" .. tostring(reason) return false end
            for _, animal in ipairs(source.animals) do
                if RLDiseaseSaleGate ~= nil and not RLDiseaseSaleGate.check(animal) then
                    source.receipt.error = "RECHECK:SICK" return false
                end
            end
            return RLTradeSourceAdapter.apply(source)
        end,
        verifySource = function() return (RLTradeSourceAdapter.verify(source)) end,
        rollbackSource = function() return RLTradeSourceAdapter.rollback(source) end,
        verifySourceRestored = function() return (RLTradeSourceAdapter.verifyRestored(source)) end,
    }
end


--- The transaction's receipt as plain data.
function RLContractTrade.exportReceipt(context, record)
    return {
        schema = RLContractTrade.RECEIPT_SCHEMA, policy = RLContractTrade.POLICY_VERSION,
        txId = context.txId, fingerprint = context.fingerprint, farmId = context.farmId,
        sourceId = context.sourceId, targetId = context.targetId, fillType = context.fillType, amount = context.amount,
        keys = context.keys, plan = { fee = context.plan.fee, creditUse = context.plan.creditUse, cashDue = context.plan.cashDue },
        state = record ~= nil and record.state or nil, reason = record ~= nil and record.reason or context.preflightError,
        preflightError = context.preflightError,
        target = RLHBContractAdapter.exportReceipt(context.targetBinding),
        source = RLTradeSourceAdapter.exportReceipt(context.sourceBinding),
    }
end


--- Run a prepared context through the coordinator and keep its receipt.
--- @param context table From prepare (not shadow)
--- @return table record
function RLContractTrade.run(context)
    local record = RLTradeTransaction.executeContract(RLContractTrade.store, context.txId, makeAdapter(context))
    local ok, receipt = pcall(RLContractTrade.exportReceipt, context, record)
    if not ok then
        -- The economic outcome stands; only its report is missing, and says so.
        Log:error("RLContractTrade %s: receipt could not be written: %s", context.txId, tostring(receipt))
        receipt = { txId = context.txId, state = record.state, receiptError = tostring(receipt) }
    end
    RLContractTrade.receipts[context.txId] = receipt
    local level = record.state == "NEEDS_RECONCILIATION" and "error" or "info"
    Log[level](Log, "RLContractTrade %s: %s %s (%d animal(s), %.4f batches, fee %.2f)", context.txId, record.state,
        tostring(record.reason or context.preflightError or ""), #context.keys, context.amount, context.plan.fee)
    return record
end


--- Prepare and run one batch. Server, TEST mode.
--- @param request table See prepare
--- @return table|nil record The transaction record (COMMITTED, ROLLED_BACK, REJECTED, NEEDS_RECONCILIATION)
--- @return string|nil reason Refusal before a transaction began
function RLContractTrade.execute(request)
    if RLContractTrade.mode ~= RLContractTrade.MODE_TEST then return nil, "MODE_" .. tostring(RLContractTrade.mode) end
    local context, reason = RLContractTrade.prepare(request)
    if context == nil then
        Log:info("RLContractTrade: refused before start: %s", tostring(reason))
        return nil, reason
    end
    return RLContractTrade.run(context)
end


--- SHADOW: prepare only and log; the old path then runs as before.
--- @return table|nil context
--- @return string|nil reason
function RLContractTrade.shadow(request)
    local ok, context, reason = pcall(RLContractTrade.prepare, request, true)
    if not ok then
        Log:warning("RLContractTrade shadow: prepare threw: %s", tostring(context))
        return nil, "THREW"
    end
    if context == nil then
        Log:info("RLContractTrade shadow: TEST would refuse: %s", tostring(reason))
    else
        Log:info("RLContractTrade shadow: TEST would deliver %d animal(s), %.4f batches to order %s, fee %.2f (credit %.2f, cash %.2f)",
            #context.keys, context.amount, tostring(context.targetBinding.orderId), context.plan.fee,
            context.plan.creditUse, context.plan.cashDue)
    end
    return context, reason
end


--- The move event's error code for a result.
--- @return number
function RLContractTrade.toMoveErrorCode(record, reason)
    if record ~= nil and record.state == "COMMITTED" then return AnimalMoveEvent.MOVE_SUCCESS end
    local why = tostring(record ~= nil and record.reason or reason)
    if why:find("^NO_PERMISSION") or why == "NOT_OWNER" or why == "NO_TARGET_ACCESS" then return AnimalMoveEvent.MOVE_ERROR_NO_PERMISSION end
    if why:find("CANNOT_AFFORD") or why:find("INSUFFICIENT") or why:find("NO_OPEN_ORDER") or why == "NO_ORDER"
        or why:find("NO_ROOM") then
        return AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE
    end
    if why:find("^TYPE_UNSUPPORTED") or why:find("^SICK") or why:find("^QUOTE") or why == "RECIPE_NOT_ALIGNED" then
        return AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED
    end
    return AnimalMoveEvent.MOVE_ERROR_INVALID_CLUSTER
end
