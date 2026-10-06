-- T02 transaction coordinator. Adapters must provide verified compensation including their
-- economic side effects; returning true from a delivery function is NOT a rollback contract.
-- Batch 3 adds executeLiveSale (a known partial removal settles its confirmed subset once) and
-- the ledger's money receipts (store.payments, RLSaleSettlement); ledger schema 2.
RLTradeTransaction = {}
local T = RLTradeTransaction
T.VERSION = 2

local terminal = { COMMITTED = true, COMMITTED_PARTIAL = true, ROLLED_BACK = true, REJECTED = true, NEEDS_RECONCILIATION = true }
-- Terminal states whose work is finished: their locks are released and a reload does not lock again.
local finished = { COMMITTED = true, COMMITTED_PARTIAL = true, ROLLED_BACK = true, REJECTED = true }
local known = { PREPARED = true, VALIDATING = true, APPLYING_TARGET = true, TARGET_APPLIED = true,
    APPLYING_SOURCE = true, SOURCE_APPLIED = true, SOURCE_UNKNOWN = true, SETTLING = true, SETTLED = true,
    COMMITTED = true, COMMITTED_PARTIAL = true, ROLLED_BACK = true, REJECTED = true, NEEDS_RECONCILIATION = true }
T.TERMINAL, T.FINISHED, T.KNOWN = terminal, finished, known
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
local function call(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok then return false, tostring(value) end
    return value == true, value
end

function T.new()
    return { records = {}, locks = {}, payments = {}, sequence = 0, recoveryRequired = false }
end

local function release(store, record)
    for _, key in ipairs(record.resources) do
        if store.locks[key] == record.id then store.locks[key] = nil end
    end
end

-- No arbitrary object references in records. Persist identity, operation kind and a
-- canonical request fingerprint; changed payload under the same id is not a retry.
function T.begin(store, id, kind, fingerprint, resources)
    if type(id) ~= "string" or id == "" or type(fingerprint) ~= "string" or fingerprint == ""
        or (kind ~= "CONTRACT" and kind ~= "SALE") then return nil, "BAD_REQUEST" end
    local old = store.records[id]
    if old ~= nil then
        if old.kind ~= kind or old.fingerprint ~= fingerprint then return nil, "ID_COLLISION" end
        return copy(old), "REPLAY"
    end
    if store.recoveryRequired then return nil, "RECOVERY_REQUIRED" end
    if type(resources) ~= "table" or #resources == 0 or getmetatable(resources) ~= nil then return nil, "BAD_RESOURCES" end
    local keys, seen, count = {}, {}, 0
    for k in pairs(resources) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > #resources then return nil, "BAD_RESOURCES" end
        count = count + 1
    end
    if count ~= #resources then return nil, "BAD_RESOURCES" end
    for _, key in ipairs(resources) do
        if type(key) ~= "string" or key == "" or seen[key] then return nil, "BAD_RESOURCES" end
        if store.locks[key] ~= nil then return nil, "RESOURCE_BUSY" end
        seen[key] = true
        keys[#keys + 1] = key
    end
    table.sort(keys)
    store.sequence = store.sequence + 1
    local record = { id = id, kind = kind, fingerprint = fingerprint, resources = keys,
        state = "PREPARED", sequence = store.sequence, history = { "PREPARED" } }
    store.records[id] = record
    for _, key in ipairs(keys) do store.locks[key] = id end
    return copy(record)
end

local function state(record, nextState, reason)
    record.state, record.reason = nextState, reason
    record.history[#record.history + 1] = nextState
end

local function reconcile(store, record, reason)
    state(record, "NEEDS_RECONCILIATION", reason)
    -- Hold resources. An unknown economic outcome must block conflicting retries.
    return copy(record)
end

local function undo(store, record, adapter, targetAttempted, sourceAttempted, reason)
    -- Reverse dependency order; only certified inverse operations, never broad snapshots.
    if sourceAttempted then
        if not call(adapter.rollbackSource, record.id) or not call(adapter.verifySourceRestored, record.id) then
            return reconcile(store, record, "SOURCE_ROLLBACK_UNKNOWN:" .. tostring(reason))
        end
    end
    if targetAttempted then
        if not call(adapter.rollbackTarget, record.id) or not call(adapter.verifyTargetRestored, record.id) then
            return reconcile(store, record, "TARGET_ROLLBACK_UNKNOWN:" .. tostring(reason))
        end
    end
    state(record, "ROLLED_BACK", reason)
    release(store, record)
    return copy(record)
end

-- CONTRACT: target commit -> source removal. Each attempted stage must have an inverse
-- that can deal with a throw after mutation. Verification is required even after true.
function T.executeContract(store, id, adapter)
    local record = store.records[id]
    if record == nil then return nil, "NOT_FOUND" end
    if record.kind ~= "CONTRACT" then return nil, "WRONG_KIND" end
    if terminal[record.state] then return copy(record), "REPLAY" end
    if record.state ~= "PREPARED" then return nil, "IN_PROGRESS" end
    local methods = { "preflight", "applyTarget", "verifyTarget", "rollbackTarget", "verifyTargetRestored",
        "applySource", "verifySource", "rollbackSource", "verifySourceRestored" }
    for _, method in ipairs(methods) do
        if type(adapter) ~= "table" or type(adapter[method]) ~= "function" then
            state(record, "REJECTED", "NO_CONTRACT:" .. method)
            release(store, record)
            return copy(record)
        end
    end
    -- Mark before entering callbacks so reentrant requests cannot execute this id twice.
    state(record, "VALIDATING")
    if not call(adapter.preflight, id) then
        state(record, "REJECTED", "PREFLIGHT_FAILED")
        release(store, record)
        return copy(record)
    end
    state(record, "APPLYING_TARGET")
    if not call(adapter.applyTarget, id) or not call(adapter.verifyTarget, id) then
        return undo(store, record, adapter, true, false, "TARGET_NOT_COMPLETE")
    end
    state(record, "TARGET_APPLIED")
    state(record, "APPLYING_SOURCE")
    if not call(adapter.applySource, id) or not call(adapter.verifySource, id) then
        return undo(store, record, adapter, true, true, "SOURCE_NOT_COMPLETE")
    end
    state(record, "SOURCE_APPLIED")
    state(record, "COMMITTED")
    release(store, record)
    -- Visuals/notifications are explicitly outside the economic commit. Failure cannot retry.
    if type(adapter.notify) == "function" then
        local ok, err = pcall(adapter.notify, id)
        if not ok then record.notificationError = tostring(err) end
    end
    return copy(record)
end

-- SALE uses source-first ordering. Settlement is delegated to a receipt-aware adapter:
-- APPLIED or NOT_APPLIED must be proven, UNKNOWN must never trigger an automatic retry.
function T.executeSale(store, id, adapter)
    local record = store.records[id]
    if record == nil then return nil, "NOT_FOUND" end
    if record.kind ~= "SALE" then return nil, "WRONG_KIND" end
    if terminal[record.state] then return copy(record), "REPLAY" end
    if record.state ~= "PREPARED" then return nil, "IN_PROGRESS" end
    for _, name in ipairs({ "preflight", "applySource", "verifySource", "rollbackSource",
        "verifySourceRestored", "settle", "settlementStatus" }) do
        if type(adapter) ~= "table" or type(adapter[name]) ~= "function" then
            state(record, "REJECTED", "NO_CONTRACT:" .. name)
            release(store, record)
            return copy(record)
        end
    end
    state(record, "VALIDATING")
    if not call(adapter.preflight, id) then
        state(record, "REJECTED", "PREFLIGHT_FAILED")
        release(store, record)
        return copy(record)
    end
    state(record, "APPLYING_SOURCE")
    if not call(adapter.applySource, id) or not call(adapter.verifySource, id) then
        return undo(store, record, adapter, false, true, "SOURCE_NOT_COMPLETE")
    end
    state(record, "SOURCE_APPLIED")
    state(record, "SETTLING")
    pcall(adapter.settle, id)
    local ok, receipt = pcall(adapter.settlementStatus, id)
    if not ok or receipt == "UNKNOWN" then return reconcile(store, record, "SETTLEMENT_UNKNOWN") end
    if receipt == "NOT_APPLIED" then
        return undo(store, record, adapter, false, true, "SETTLEMENT_NOT_APPLIED")
    end
    if receipt ~= "APPLIED" then return reconcile(store, record, "BAD_SETTLEMENT_RECEIPT") end
    state(record, "SETTLED")
    state(record, "COMMITTED")
    release(store, record)
    if type(adapter.notify) == "function" then
        local notified, err = pcall(adapter.notify, id)
        if not notified then record.notificationError = tostring(err) end
    end
    return copy(record)
end

-- LIVE SALE (batch 3): source first, then one money action for what really left.
-- The adapter reports the removal as a subset (observeSource), unqueues only this batch
-- (clearSourceQueue), pays once with a receipt (settle -> {status = APPLIED|NOT_APPLIED|UNKNOWN})
-- and can put back exactly the animals that left (restoreSource, verifySourceRestored).
-- Decisions are RLSaleRecovery's; a known partial removal settles its subset and ends
-- COMMITTED_PARTIAL instead of being rolled back, which the contract path never does.
function T.executeLiveSale(store, id, adapter)
    local record = store.records[id]
    if record == nil then return nil, "NOT_FOUND" end
    if record.kind ~= "SALE" then return nil, "WRONG_KIND" end
    if terminal[record.state] then return copy(record), "REPLAY" end
    if record.state ~= "PREPARED" then return nil, "IN_PROGRESS" end
    for _, name in ipairs({ "preflight", "applySource", "observeSource", "clearSourceQueue", "settle",
        "restoreSource", "verifySourceRestored" }) do
        if type(adapter) ~= "table" or type(adapter[name]) ~= "function" then
            state(record, "REJECTED", "NO_CONTRACT:" .. name)
            release(store, record)
            return copy(record)
        end
    end
    record.sale = record.sale or {}
    local sale = record.sale
    state(record, "VALIDATING")
    if not call(adapter.preflight, id) then
        state(record, "REJECTED", "PREFLIGHT_FAILED")
        release(store, record)
        return copy(record)
    end

    -- The stage is marked before the first side effect.
    state(record, "APPLYING_SOURCE")
    local ok, applied, applyError = pcall(adapter.applySource, id)
    if not ok then sale.applyError = "THREW:" .. tostring(applied)
    elseif applied ~= true then sale.applyError = tostring(applyError or "APPLY_INCOMPLETE") end

    local outcome
    ok, outcome = pcall(adapter.observeSource, id)
    if not ok then outcome = { known = false, reason = "OBSERVE_THREW:" .. tostring(outcome) } end
    local decision, why = RLSaleRecovery.afterSource(outcome)
    if decision == RLSaleRecovery.SOURCE_UNKNOWN then
        -- Survivors must not stay queued for a later flush to remove unpaid; an animal that left
        -- has no entry to clear. Nothing is paid, removed again or put back.
        pcall(adapter.clearSourceQueue, id)
        sale.sourceReason = why
        state(record, "SOURCE_UNKNOWN", why)
        return reconcile(store, record, "SOURCE_UNKNOWN:" .. tostring(why))
    end
    sale.removed, sale.survivors = copy(outcome.removedKeys), copy(outcome.survivorKeys)
    state(record, "SOURCE_APPLIED")

    if decision == RLSaleRecovery.NONE_REMOVED then
        if call(adapter.restoreSource, id) and call(adapter.verifySourceRestored, id) then
            state(record, "ROLLED_BACK", "NONE_REMOVED" .. (sale.applyError ~= nil and (":" .. sale.applyError) or ""))
            release(store, record)
            return copy(record)
        end
        return reconcile(store, record, "SOURCE_RESTORE_UNKNOWN:NONE_REMOVED")
    end

    -- Survivors leave the queue before any money moves.
    local cleared = call(adapter.clearSourceQueue, id)
    if not cleared then sale.queueError = "SURVIVOR_QUEUE_NOT_CLEARED" end

    state(record, "SETTLING")
    local receipt
    ok, receipt = pcall(adapter.settle, id, outcome)
    if not ok or type(receipt) ~= "table" then receipt = { status = nil, evidence = "SETTLE_THREW:" .. tostring(receipt) } end
    sale.paymentId, sale.amount, sale.payment = receipt.paymentId, receipt.amount, receipt.status or "UNKNOWN"
    local next = RLSaleRecovery.afterSettlement(outcome, receipt.status)
    if next == RLSaleRecovery.RESTORE then
        if call(adapter.restoreSource, id) and call(adapter.verifySourceRestored, id) then
            sale.restored = copy(outcome.removedKeys)
            state(record, "ROLLED_BACK", "SETTLEMENT_NOT_APPLIED")
            release(store, record)
            return copy(record)
        end
        return reconcile(store, record, "SOURCE_RESTORE_UNKNOWN:SETTLEMENT_NOT_APPLIED")
    end
    if next == RLSaleRecovery.RECONCILE then
        return reconcile(store, record, "SETTLEMENT_UNKNOWN:" .. tostring(receipt.evidence))
    end

    state(record, "SETTLED")
    -- The money stands; survivors still queued could leave unpaid on a later flush.
    if not cleared then return reconcile(store, record, "SURVIVOR_QUEUE_NOT_CLEARED") end
    if next == RLSaleRecovery.COMMITTED_PARTIAL then
        state(record, "COMMITTED_PARTIAL", sale.applyError or "PARTIAL_REMOVAL")
    else
        state(record, "COMMITTED", sale.applyError)
    end
    release(store, record)
    -- Visuals/messages are outside the economic commit. Failure cannot retry the sale.
    if type(adapter.notify) == "function" then
        local notified, err = pcall(adapter.notify, id)
        if not notified then record.notificationError = tostring(err) end
    end
    return copy(record)
end

-- This is a serializable ledger, NOT an independently durable journal. Live persistence
-- must save it in the same boundary as animals, HB orders and farm money before enabling.
function T.export(store)
    return { version = T.VERSION, sequence = store.sequence, records = copy(store.records), payments = copy(store.payments or {}) }
end

local paymentStatus = { APPLIED = true, NOT_APPLIED = true, UNKNOWN = true }

local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function stringList(list)
    if list == nil then return {} end
    if type(list) ~= "table" or getmetatable(list) ~= nil then return nil end
    local result, count = {}, 0
    for k, v in pairs(list) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or type(v) ~= "string" then return nil end
        count = count + 1
    end
    if count ~= #list then return nil end
    for i, v in ipairs(list) do result[i] = v end
    return result
end

local function optionalString(value)
    return type(value) == "string" and value or nil
end

-- A live sale's fields, projected; nil when malformed.
local function projectSale(saved)
    if saved == nil then return nil, true end
    if type(saved) ~= "table" then return nil, false end
    local sale = { removed = stringList(saved.removed), survivors = stringList(saved.survivors),
        restored = stringList(saved.restored) }
    if sale.removed == nil or sale.survivors == nil or sale.restored == nil then return nil, false end
    if saved.amount ~= nil and not isFinite(saved.amount) then return nil, false end
    if saved.payment ~= nil and not paymentStatus[saved.payment] then return nil, false end
    sale.amount, sale.payment, sale.paymentId = saved.amount, saved.payment, optionalString(saved.paymentId)
    sale.applyError, sale.sourceReason, sale.queueError = optionalString(saved.applyError),
        optionalString(saved.sourceReason), optionalString(saved.queueError)
    return sale, true
end

-- A money receipt, projected; one recorded but without a final status (stopped mid-call) is
-- UNKNOWN: it may have moved money and is never attempted again.
local function projectPayment(id, saved)
    if type(saved) ~= "table" or saved.paymentId ~= id or (saved.kind ~= "SALE" and saved.kind ~= "WAGE")
        or type(saved.farmId) ~= "number" or not isFinite(saved.amount)
        or (saved.status ~= nil and not paymentStatus[saved.status]) then
        return nil
    end
    local payment = { paymentId = id, ref = optionalString(saved.ref), kind = saved.kind, farmId = saved.farmId,
        amount = saved.amount, moneyType = optionalString(saved.moneyType), moneyTypeId = saved.moneyTypeId,
        addChange = saved.addChange == true, forceShow = saved.forceShow == true, stage = optionalString(saved.stage),
        status = saved.status, evidence = optionalString(saved.evidence), callError = optionalString(saved.callError) }
    if payment.status == nil then payment.status, payment.evidence = "UNKNOWN", "INTERRUPTED_BEFORE_RECEIPT" end
    return payment
end

function T.import(data)
    if type(data) ~= "table" or (data.version ~= 1 and data.version ~= T.VERSION) or type(data.records) ~= "table"
        or type(data.sequence) ~= "number" or data.sequence < 0 or data.sequence % 1 ~= 0 then
        return nil, "BAD_LEDGER"
    end
    local store, sequences = T.new(), {}
    store.sequence = data.sequence
    for id, saved in pairs(data.records) do
        if type(saved) ~= "table" or saved.id ~= id or type(saved.fingerprint) ~= "string"
            or saved.fingerprint == "" or (saved.kind ~= "CONTRACT" and saved.kind ~= "SALE")
            or type(saved.history) ~= "table" or type(saved.resources) ~= "table"
            or type(saved.sequence) ~= "number" or saved.sequence < 1 or saved.sequence > data.sequence
            or saved.sequence % 1 ~= 0 or sequences[saved.sequence] or not known[saved.state] then
            return nil, "BAD_LEDGER_RECORD"
        end
        -- Validate independently: a completed transaction may share resources with a
        -- later unfinished one, regardless of the table's iteration order.
        local record, reason = T.begin(T.new(), id, saved.kind, saved.fingerprint, saved.resources)
        if record == nil then return nil, reason end
        sequences[saved.sequence] = true
        for _, stage in ipairs(saved.history) do
            if not known[stage] then return nil, "BAD_LEDGER_HISTORY" end
        end
        local sale, saleOk = projectSale(saved.sale)
        if not saleOk then return nil, "BAD_LEDGER_SALE" end
        -- Project the schema instead of copying arbitrary nested caller data.
        store.records[id] = { id = id, kind = saved.kind, fingerprint = saved.fingerprint,
            resources = record.resources, history = {}, sequence = saved.sequence, state = saved.state,
            reason = type(saved.reason) == "string" and saved.reason or nil,
            notificationError = type(saved.notificationError) == "string" and saved.notificationError or nil, sale = sale }
        for _, stage in ipairs(saved.history) do table.insert(store.records[id].history, stage) end
        record = store.records[id]
        if not finished[saved.state] then
            for _, key in ipairs(record.resources) do
                if store.locks[key] ~= nil then return nil, "LEDGER_RESOURCE_CONFLICT" end
                store.locks[key] = id
            end
            -- Never replay incomplete work on load. Even PREPARED is not proof that the
            -- asset files and this ledger reached disk together.
            state(record, "NEEDS_RECONCILIATION", "RELOAD_REQUIRES_ASSET_CHECK")
            store.recoveryRequired = true
        end
    end
    if data.payments ~= nil then
        if type(data.payments) ~= "table" then return nil, "BAD_LEDGER_PAYMENTS" end
        for id, saved in pairs(data.payments) do
            if type(id) ~= "string" then return nil, "BAD_LEDGER_PAYMENT" end
            local payment = projectPayment(id, saved)
            if payment == nil then return nil, "BAD_LEDGER_PAYMENT" end
            store.payments[id] = payment
        end
    end
    store.sequence = data.sequence
    return store
end
