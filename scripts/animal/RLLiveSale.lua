--[[
    T02 batch 3: the player's sale (AnimalSellEvent) and the herdsman's sale
    (AIAnimalSellEvent.executeServer) as one server transaction each, with a money receipt; and the
    herdsman wage as its own money action, once per execution round and farm.

        OFF     (default) the old paths, unchanged.
        SHADOW  the old paths run; this module only prepares and logs what TEST would do.
                Nothing is locked or recorded.
        TEST    test saves only: a sale goes through RLTradeTransaction.executeLiveSale with the
                source adapter (RLTradeSourceAdapter) and the money receipt (RLSaleSettlement);
                anything it cannot take is refused, never passed to the old path.

    The mode is per run (OFF on every map load, never saved) and separate from the contract
    mode (rlTradeTxMode). Records share RLContractTrade's ledger, so the locks of a contract
    transaction awaiting reconciliation also block a sale of the same animals, pen or farm cash.

    Kept from the old paths: the server prices the batch itself (AnimalSellEvent.quoteSale /
    AIAnimalSellEvent.quoteSale, unchanged); the player is paid price minus transport fee, the
    herdsman price plus fee, summed per head over the animals that really left, in the same order
    and arithmetic as before; a known partial removal is paid for its confirmed subset and still
    reported as not completed; zero or negative totals are paid as they are (no abs, no clamp).

    New in TEST: the removal is read as a subset by object (the same animal objects, never an id
    index); an unreadable source pays nothing and holds the locks; the money is one action per
    paymentId with an APPLIED / NOT_APPLIED / UNKNOWN receipt; NOT_APPLIED puts the very animals
    back (verified), UNKNOWN pays nothing again, puts nothing back and holds the locks. Records
    live in memory for this run only: no crash or reload safety (batch 4).
]]

RLLiveSale = {}

local Log = RmLogging.getLogger("RLRM")

RLLiveSale.MODE_OFF = "OFF"
RLLiveSale.MODE_SHADOW = "SHADOW"
RLLiveSale.MODE_TEST = "TEST"
RLLiveSale.POLICY_VERSION = "t02b3-1"
RLLiveSale.SCHEMA = 1

RLLiveSale.MANUAL = "MANUAL"   -- the player's sale: price - transport fee per head
RLLiveSale.AI = "AI"           -- the herdsman's sale: price + transport fee per head


--- Back to OFF (map load). The ledger itself is RLContractTrade's and is reset with it.
function RLLiveSale.reset()
    RLLiveSale.mode = RLLiveSale.MODE_OFF
    RLLiveSale.receipts = {}
    RLLiveSale.results = {}
    RLLiveSale.refusals = {}
    RLLiveSale.sequence = 0
    RLLiveSale.roundSequence = 0
end
RLLiveSale.reset()


function RLLiveSale.getMode()
    return RLLiveSale.mode
end


--- @param mode string OFF, SHADOW or TEST
--- @return boolean ok
function RLLiveSale.setMode(mode)
    mode = type(mode) == "string" and mode:upper() or nil
    if mode ~= RLLiveSale.MODE_OFF and mode ~= RLLiveSale.MODE_SHADOW and mode ~= RLLiveSale.MODE_TEST then return false end
    RLLiveSale.mode = mode
    Log:info("RLLiveSale: mode %s", mode)
    return true
end


--- The shared ledger (records, locks, payment receipts).
function RLLiveSale.ledger()
    return RLContractTrade.store
end


local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end


local function stableId(object)
    if object == nil then return "?" end
    if object.uniqueId ~= nil then return tostring(object.uniqueId) end
    local owner = object.owningPlaceable
    if owner ~= nil and owner.uniqueId ~= nil then return tostring(owner.uniqueId) end
    return tostring(object)
end


--- The request's fingerprint: what was asked, not what it costs today. A replay comes after the
--- animals left and the prices moved; the same id with another payload is a collision.
--- @return string|nil
function RLLiveSale.fingerprint(kind, farmId, source, keys)
    if type(keys) ~= "table" then return nil end
    local sorted = {}
    for i, key in ipairs(keys) do
        if type(key) ~= "string" then return nil end
        sorted[i] = key
    end
    table.sort(sorted)
    return table.concat({ "v" .. RLLiveSale.SCHEMA, RLLiveSale.POLICY_VERSION, "kind=" .. tostring(kind),
        "farm=" .. tostring(farmId), "source=" .. stableId(source), "animals=" .. table.concat(sorted, ";") }, "|")
end


--- A new execution round of the herdsman (one executeActions call). Never derived from the day:
--- two legitimate rounds on one day stay apart.
function RLLiveSale.nextRoundId()
    RLLiveSale.roundSequence = RLLiveSale.roundSequence + 1
    return "hr" .. RLLiveSale.roundSequence
end


--- Whether a record of the ledger holds this farm's cash (a sale or contract still being worked
--- out, or awaiting reconciliation). A herdsman buy is not made against it.
function RLLiveSale.isCashHeld(farmId)
    return RLLiveSale.ledger().locks["cash:farm" .. tostring(farmId)] ~= nil
end


--- The money for the animals that left, per head in quote order, in the old paths' arithmetic:
--- the player (price - fee) accumulated as `credit + price - fee`, the herdsman `credit + credits[i]`.
local function amountFor(context, removed)
    local quote, credit = context.quote, 0
    for _, i in ipairs(removed) do
        if context.kind == RLLiveSale.MANUAL then
            credit = credit + quote.prices[i] - quote.fees[i]
        else
            credit = credit + quote.credits[i]
        end
    end
    return credit
end


--- Everything a sale needs before it may touch anything, or why not. With shadow no lock is taken
--- and nothing is recorded.
--- @param kind string MANUAL or AI
--- @param source table The pen (or, for the player, a livestock trailer)
--- @param quote table The old path's server quote ({clusters, keys, prices, fees[, credits]})
--- @param farmId number The selling farm (the quote checked it owns the source)
--- @param mission table g_currentMission (the herdsman's ctx.mission)
--- @param saleId string|nil The transaction id; the herdsman passes round + action, the player none
--- @param shadow boolean|nil
--- @return table|nil context
--- @return string|nil reason
function RLLiveSale.prepare(kind, source, quote, farmId, mission, saleId, shadow)
    if mission == nil or type(mission.getIsServer) ~= "function" or not mission:getIsServer() then return nil, "NOT_SERVER" end
    if kind ~= RLLiveSale.MANUAL and kind ~= RLLiveSale.AI then return nil, "BAD_KIND" end
    if type(quote) ~= "table" or type(quote.keys) ~= "table" or #quote.keys == 0 or #quote.keys ~= #quote.clusters then
        return nil, "BAD_QUOTE"
    end
    local keys = quote.keys
    for i = 1, #keys do
        local value = kind == RLLiveSale.MANUAL and quote.prices[i] or quote.credits[i]
        if type(value) ~= "number" then return nil, "BAD_QUOTE" end
    end
    local fingerprint = RLLiveSale.fingerprint(kind, farmId, source, keys)
    if fingerprint == nil then return nil, "BAD_QUOTE" end

    local binding, reason = RLTradeSourceAdapter.bind(source, keys)
    if binding == nil then return nil, reason end
    -- The quote's objects and the bound members must be the same animals.
    for i, animal in ipairs(binding.animals) do
        if animal ~= quote.clusters[i] then return nil, "ANIMAL_MISMATCH:" .. tostring(keys[i]) end
    end
    local witnesses, why = RLSaleSettlement.observe(mission, farmId, MoneyType.SOLD_ANIMALS)
    if witnesses == nil then return nil, "RECEIPT_UNSUPPORTED:" .. tostring(why) end

    local sourceId = stableId(source)
    local all = {}
    for i = 1, #keys do all[i] = i end
    local context = { kind = kind, source = source, farmId = farmId, keys = keys, quote = quote, binding = binding,
        fingerprint = fingerprint, sourceId = sourceId, mission = mission }
    context.quotedAmount = amountFor(context, all)
    if shadow then
        context.wouldBlock = nil
        local locks = RLLiveSale.ledger().locks
        if locks["source:" .. sourceId] ~= nil or locks["cash:farm" .. tostring(farmId)] ~= nil then context.wouldBlock = "RESOURCE_BUSY" end
        for _, key in ipairs(keys) do
            if locks["animal:" .. key] ~= nil then context.wouldBlock = "RESOURCE_BUSY" end
        end
        return context
    end

    local resources = { "source:" .. sourceId, "cash:farm" .. tostring(farmId) }
    for _, key in ipairs(keys) do resources[#resources + 1] = "animal:" .. key end
    if saleId == nil then
        RLLiveSale.sequence = RLLiveSale.sequence + 1
        saleId = string.format("ls%d-f%s", RLLiveSale.sequence, tostring(farmId))
    end
    context.txId = saleId
    local record
    record, reason = RLTradeTransaction.begin(RLLiveSale.ledger(), saleId, "SALE", fingerprint, resources)
    if record == nil then return nil, reason end
    if reason == "REPLAY" then return nil, "REPLAY" end
    return context
end


--- The coordinator's adapter for one prepared context.
local function makeAdapter(context)
    local binding = context.binding
    return {
        preflight = function()
            if RLLiveSale.mode ~= RLLiveSale.MODE_TEST then context.preflightError = "MODE" return false end
            local ok, reason = RLTradeSourceAdapter.recheck(binding)
            if not ok then context.preflightError = reason return false end
            return true
        end,
        applySource = function()
            local ok = RLTradeSourceAdapter.apply(binding)
            return ok, binding.receipt.error
        end,
        observeSource = function() return RLTradeSourceAdapter.observe(binding) end,
        clearSourceQueue = function() return (RLTradeSourceAdapter.clearBatchQueue(binding)) end,
        settle = function(_, outcome)
            local paymentId, amount = "pay:" .. context.txId, amountFor(context, outcome.removed)
            local receipt, replay = RLSaleSettlement.apply(RLLiveSale.ledger().payments, { paymentId = paymentId, ref = context.txId,
                kind = "SALE", farmId = context.farmId, amount = amount, moneyType = MoneyType.SOLD_ANIMALS }, context.mission)
            -- Only this call's own receipt counts: one already under the id is not this payment.
            if replay ~= nil or receipt.paymentId ~= paymentId or receipt.ref ~= context.txId or receipt.kind ~= "SALE"
                or receipt.farmId ~= context.farmId or receipt.amount ~= amount then
                return { status = RLSaleSettlement.UNKNOWN, evidence = "RECEIPT_MISMATCH", paymentId = paymentId, amount = amount }
            end
            return receipt
        end,
        restoreSource = function() return RLTradeSourceAdapter.rollback(binding) end,
        verifySourceRestored = function() return (RLTradeSourceAdapter.verifyRestored(binding)) end,
        notify = context.notify,
    }
end


--- The sale's receipt as plain data.
function RLLiveSale.exportReceipt(context, record)
    local payment = RLLiveSale.ledger().payments["pay:" .. context.txId]
    return {
        schema = RLLiveSale.SCHEMA, policy = RLLiveSale.POLICY_VERSION, txId = context.txId, kind = context.kind,
        fingerprint = context.fingerprint, farmId = context.farmId, sourceId = context.sourceId, keys = copy(context.keys),
        quotedAmount = context.quotedAmount, state = record.state, reason = record.reason,
        preflightError = context.preflightError, sale = copy(record.sale), payment = copy(payment),
        source = RLTradeSourceAdapter.exportReceipt(context.binding),
    }
end


--- Run a prepared context through the coordinator and keep its receipt.
--- @return table record
function RLLiveSale.run(context)
    local record = RLTradeTransaction.executeLiveSale(RLLiveSale.ledger(), context.txId, makeAdapter(context))
    local ok, receipt = pcall(RLLiveSale.exportReceipt, context, record)
    if not ok then
        Log:error("RLLiveSale %s: receipt could not be written: %s", context.txId, tostring(receipt))
        receipt = { txId = context.txId, state = record.state, receiptError = tostring(receipt) }
    end
    RLLiveSale.receipts[context.txId] = receipt
    local sale = record.sale or {}
    local level = record.state == "NEEDS_RECONCILIATION" and "error" or "info"
    Log[level](Log, "RLLiveSale %s (%s): %s %s - %d of %d left, payment %s %s", context.txId, context.kind, record.state,
        tostring(record.reason or context.preflightError or ""), #(sale.removed or {}), #context.keys,
        tostring(sale.payment), sale.amount ~= nil and string.format("%.2f", sale.amount) or "-")
    return record
end


--- Note a message/visual failure after the sale was settled. The sale is not retried.
function RLLiveSale.noteNotification(txId, err)
    local record = RLLiveSale.ledger().records[txId]
    if record ~= nil then record.notificationError = tostring(err) end
    Log:warning("RLLiveSale %s: settled, but the message failed: %s", tostring(txId), tostring(err))
end


-- -------------------------------------------------------------------------------------------
-- The player's sale
-- -------------------------------------------------------------------------------------------

--- TEST: sell the quoted batch as one transaction.
--- @return table|nil record
--- @return string|nil reason Refusal before a transaction began
function RLLiveSale.executeManual(source, quote, farmId, mission)
    local context, reason = RLLiveSale.prepare(RLLiveSale.MANUAL, source, quote, farmId, mission or g_currentMission)
    if context == nil then
        Log:info("RLLiveSale: player sale refused before start: %s", tostring(reason))
        return nil, reason
    end
    return RLLiveSale.run(context)
end


--- The player's reply code for a result. The protocol is unchanged: anything but a full,
--- settled sale is a failure code (detail in the log and rlTradeTxReport), never SUCCESS. As in
--- the old path, a removal that threw counts as failed even when every animal left and was paid.
--- @return number
function RLLiveSale.toSellErrorCode(record, reason)
    if record ~= nil and record.state == "COMMITTED" and (record.sale == nil or record.sale.applyError == nil) then
        return AnimalSellEvent.SELL_SUCCESS
    end
    if record == nil then
        local why = tostring(reason)
        if why:find("^ANIMAL_NOT_FOUND") or why:find("^ANIMAL_IDENTITY_NOT_UNIQUE") or why:find("^DUPLICATE_ANIMAL")
            or why:find("^ANIMAL_MISMATCH") or why == "BAD_QUOTE" then
            return AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER
        end
        if why:find("^ANIMAL_GONE") or why:find("^ANIMAL_LISTED_FOR_SALE") or why == "RESOURCE_BUSY" or why == "RECOVERY_REQUIRED" then
            return AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD
        end
    end
    return AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST
end


--- SHADOW: prepare only and log; the old path then runs as before.
function RLLiveSale.shadowManual(source, quote, farmId, mission)
    return RLLiveSale.shadow(RLLiveSale.MANUAL, source, quote, farmId, mission or g_currentMission)
end


function RLLiveSale.shadow(kind, source, quote, farmId, mission)
    local ok, context, reason = pcall(RLLiveSale.prepare, kind, source, quote, farmId, mission, nil, true)
    if not ok then
        Log:warning("RLLiveSale shadow (%s): prepare threw: %s", kind, tostring(context))
        return nil, "THREW"
    end
    if context == nil then
        Log:info("RLLiveSale shadow (%s): TEST would refuse: %s", kind, tostring(reason))
    elseif context.wouldBlock ~= nil then
        Log:info("RLLiveSale shadow (%s): TEST would refuse: %s", kind, context.wouldBlock)
    else
        Log:info("RLLiveSale shadow (%s): TEST would sell %d animal(s) for %.2f with a receipt", kind, #context.keys, context.quotedAmount)
    end
    return context, reason
end


-- -------------------------------------------------------------------------------------------
-- The herdsman's sale
-- -------------------------------------------------------------------------------------------

local REFUSAL_STAGE = { NOT_SERVER = "server", SOURCE_UNSUPPORTED = "source", SOURCE_UNREADABLE = "source",
    SOURCE_QUEUE_BUSY = "pending", SOURCE_FLUSH_WOULD_REMOVE = "source", RESOURCE_BUSY = "locked",
    RECOVERY_REQUIRED = "locked", ID_COLLISION = "replay", IN_PROGRESS = "replay", BAD_QUOTE = "price",
    BAD_KIND = "server", BAD_RESOURCES = "identity", REPLAY = "replay" }

local function refusalStage(reason)
    local why = tostring(reason)
    if REFUSAL_STAGE[why] ~= nil then return REFUSAL_STAGE[why] end
    if why:find("^ANIMAL_NOT_FOUND") or why:find("^ANIMAL_IDENTITY_NOT_UNIQUE") or why:find("^DUPLICATE_ANIMAL")
        or why:find("^ANIMAL_MISMATCH") then
        return "identity"
    end
    if why:find("^ANIMAL_GONE") or why:find("^ANIMAL_LISTED_FOR_SALE") then return "animal" end
    if why:find("^RECEIPT_UNSUPPORTED") then return "receipt" end
    return "source"
end

local function applyStage(applyError)
    local why = tostring(applyError)
    if why:find("^QUEUE_THREW") then return "queue" end
    if why:find("^FLUSH_THREW") then return "flush" end
    return "removal"
end


--- The executeServer result for a refusal or a finished record. The old fields keep their
--- meaning; removedCount is the number gone from the source now (nil when unknown), so a put-back
--- batch reports 0, with originalRemovedCount and restoredCount beside it. settledCount and
--- amountGained are what the receipt confirms (nil when the payment is unknown).
--- @param record table|nil
--- @param reason string|nil Refusal before start
--- @param result table executeServer's result (requestedCount, quotedAmount set)
--- @return table result
function RLLiveSale.toAiResult(record, reason, result)
    local out = copy(result)
    out.removedCount, out.settledCount, out.amountGained = 0, 0, 0
    if record == nil then
        out.status, out.failureStage, out.reason = AIAnimalSellEvent.STATUS_REFUSED, refusalStage(reason), tostring(reason)
        return out
    end
    local sale = record.sale or {}
    local removed = #(sale.removed or {})
    out.txId, out.txState, out.paymentStatus = record.id, record.state, sale.payment
    out.reason = record.reason
    local why = tostring(record.reason)
    if record.state == "COMMITTED" and sale.applyError == nil then
        out.status, out.removedCount, out.settledCount, out.amountGained = AIAnimalSellEvent.STATUS_SOLD, removed, removed, sale.amount
        out.reason = nil
    elseif record.state == "COMMITTED" then
        -- Every animal left and was paid, but the removal threw: PARTIAL at that stage, as before.
        out.status, out.removedCount, out.settledCount, out.amountGained = AIAnimalSellEvent.STATUS_PARTIAL, removed, removed, sale.amount
        out.failureStage = applyStage(sale.applyError)
    elseif record.state == "COMMITTED_PARTIAL" then
        out.status, out.removedCount, out.settledCount, out.amountGained = AIAnimalSellEvent.STATUS_PARTIAL, removed, removed, sale.amount
        out.failureStage = applyStage(sale.applyError)
    elseif record.state == "REJECTED" then
        out.status, out.failureStage = AIAnimalSellEvent.STATUS_REFUSED, "preflight"
    elseif record.state == "ROLLED_BACK" then
        out.status, out.originalRemovedCount, out.restoredCount = AIAnimalSellEvent.STATUS_FAILED, removed, #(sale.restored or {})
        out.failureStage = sale.payment == RLSaleSettlement.NOT_APPLIED and "payment" or applyStage(sale.applyError)
    elseif why:find("^SOURCE_UNKNOWN") then
        out.status, out.failureStage, out.removedCount = AIAnimalSellEvent.STATUS_FAILED, "verify", nil
    elseif why:find("^SETTLEMENT_UNKNOWN") then
        out.status, out.failureStage = AIAnimalSellEvent.STATUS_FAILED, "payment"
        out.removedCount, out.settledCount, out.amountGained = removed, nil, nil
    elseif why == "SOURCE_CHANGED_AFTER_SETTLEMENT" then
        out.status, out.failureStage, out.removedCount = AIAnimalSellEvent.STATUS_FAILED, "verify", nil
        out.settledCount, out.amountGained = removed, sale.amount
    elseif why == "SURVIVOR_QUEUE_NOT_CLEARED" then
        out.status, out.failureStage = AIAnimalSellEvent.STATUS_PARTIAL, "queue-cleanup"
        out.removedCount, out.settledCount, out.amountGained = removed, removed, sale.amount
    elseif why:find("SETTLEMENT_NOT_APPLIED") then
        out.status, out.failureStage, out.removedCount, out.originalRemovedCount = AIAnimalSellEvent.STATUS_FAILED, "payment", nil, removed
    else
        out.status, out.failureStage = AIAnimalSellEvent.STATUS_FAILED, applyStage(sale.applyError)
    end
    return out
end


--- Keep pre-ledger refusals for this run, keyed by the same request fingerprint as a sale.
function RLLiveSale.rememberAiRefusal(saleId, source, keys, farmId, result)
    if saleId == nil or result.status ~= AIAnimalSellEvent.STATUS_REFUSED then return end
    local fingerprint = RLLiveSale.fingerprint(RLLiveSale.AI, farmId, source, keys)
    if fingerprint == nil or RLLiveSale.ledger().records[saleId] ~= nil or RLLiveSale.refusals[saleId] ~= nil then return end
    RLLiveSale.refusals[saleId] = { fingerprint = fingerprint, result = copy(result) }
end


--- Return the first sale or refusal result, without repeating its economic effects.
--- @return table|nil result nil when the id is new
function RLLiveSale.replayAi(saleId, source, identityKeys, farmId, result)
    if saleId == nil then return nil end
    local record = RLLiveSale.ledger().records[saleId]
    local fingerprint = RLLiveSale.fingerprint(RLLiveSale.AI, farmId, source, identityKeys)
    if record == nil then
        local refused = RLLiveSale.refusals[saleId]
        if refused == nil then return nil end
        if fingerprint ~= refused.fingerprint then return RLLiveSale.toAiResult(nil, "ID_COLLISION", result) end
        local out = copy(refused.result)
        out.replayed = true
        return out
    end
    if record.kind ~= "SALE" or fingerprint ~= record.fingerprint then return RLLiveSale.toAiResult(nil, "ID_COLLISION", result) end
    if not RLTradeTransaction.TERMINAL[record.state] then return RLLiveSale.toAiResult(nil, "IN_PROGRESS", result) end
    local out = RLLiveSale.results[saleId] ~= nil and copy(RLLiveSale.results[saleId]) or RLLiveSale.toAiResult(record, nil, result)
    out.replayed = true
    return out
end


--- TEST: sell a herdsman batch as one transaction and report it as executeServer does.
function RLLiveSale.executeAi(source, quote, farmId, ctx, saleId, result)
    local context, reason = RLLiveSale.prepare(RLLiveSale.AI, source, quote, farmId, ctx.mission, saleId)
    if context == nil then return RLLiveSale.toAiResult(nil, reason, result) end
    local record = RLLiveSale.run(context)
    local out = RLLiveSale.toAiResult(record, nil, result)
    RLLiveSale.results[context.txId] = copy(out)
    return out
end


-- -------------------------------------------------------------------------------------------
-- The herdsman's wage
-- -------------------------------------------------------------------------------------------

--- TEST: charge one round's wage for one farm as its own money action. The id is the round and
--- the farm, so replaying the round charges nothing again and two rounds on one day stay apart.
--- The rule of what is charged is the executor's, unchanged.
--- @return table receipt
--- @return string|nil replay "REPLAY" when this round's wage already had a receipt
function RLLiveSale.chargeWage(mission, roundId, farmId, wage)
    local receipt, replay = RLSaleSettlement.apply(RLLiveSale.ledger().payments, {
        paymentId = string.format("wage:%s:f%s", tostring(roundId), tostring(farmId)), ref = roundId, kind = "WAGE",
        farmId = farmId, amount = -wage, moneyType = MoneyType.HERDSMAN_WAGES }, mission)
    if replay ~= nil then
        Log:info("RLLiveSale: wage %s already %s, not charged again", tostring(receipt.paymentId), tostring(receipt.status))
    elseif receipt.status ~= RLSaleSettlement.APPLIED then
        Log:error("RLLiveSale: wage %s %s (%s)", tostring(receipt.paymentId), tostring(receipt.status), tostring(receipt.evidence))
    end
    return receipt, replay
end
