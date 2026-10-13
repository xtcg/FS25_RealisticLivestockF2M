-- Dormant server-only dealer batch coordinator. No game globals or animal payloads.
-- Durability is supplied by an ownership adapter, NEVER inferred from pcall or locks.
-- checkpoint(snapshot) must durably store the WHOLE journal before returning true.
-- prepare is side-effect free; apply must atomically revalidate clock, eligibility, revisions,
-- quote, permission, capacity and funds while reserving the full batch.
-- apply(token, plan, context) and reconcile(token, plan, context) must report authoritative
-- bound whole-batch receipts (or UNKNOWN), with idempotent ownership+money evidence.
-- reconcile must compensate partial target/source/money changes before ROLLED_BACK.
RLDealerPurchase = {}
local P = RLDealerPurchase
P.VERSION = 1
P.MAX_BATCH = 1000
P.LOCK_MS = 5000
P.LIMITS = {maxNodes=400000,maxString=262144,maxDepth=32}
local terminal = { COMMITTED = true, ROLLED_BACK = true }
local stages = { PREPARED = true, APPLYING = true, COMMITTED = true, ROLLED_BACK = true, RECOVERY_REQUIRED = true }
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function str(v) return type(v) == "string" and #v > 0 and #v <= 4096 end
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function call(a, name, ...)
    local ok, value, why = pcall(a[name], ...)
    if not ok then return nil, "ADAPTER_ERROR:" .. name end
    return value, why
end
local function dense(t, max)
    if type(t) ~= "table" or #t < 1 or #t > max then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > #t then return false end
        n = n + 1
    end
    return n == #t
end
local function normalize(request, principal)
    if type(request) ~= "table" or RLTradePersistence.check(request, P.LIMITS) then return nil, "BAD_REQUEST" end
    if not str(principal) or not str(request.requestId) or not str(request.destination)
        or not str(request.quoteCredential) or not dense(request.items, P.MAX_BATCH) then return nil, "BAD_REQUEST" end
    local out = { requestId = request.requestId, principal = principal, destination = request.destination,
        quoteCredential = request.quoteCredential, items = {} }
    local seen = {}
    for _, item in ipairs(request.items) do
        if type(item) ~= "table" or not str(item.saleId) or not finite(item.revision)
            or item.revision < 1 or item.revision % 1 ~= 0 then return nil, "BAD_ITEM" end
        if seen[item.saleId] then return nil, "DUPLICATE_SALE_ID" end
        seen[item.saleId] = true
        out.items[#out.items + 1] = { saleId = item.saleId, revision = item.revision }
    end
    table.sort(out.items, function(a, b) return a.saleId < b.saleId end)
    return out
end
function P.new() return { version = P.VERSION, records = {}, locks = {}, recoveryRequired = false } end
function P.export(store)
    return copy({ version = P.VERSION, records = store.records, recoveryRequired = store.recoveryRequired })
end
local function release(store, record)
    for _, item in ipairs(record.request.items) do
        local lock = store.locks[item.saleId]
        if lock and lock.recoveryOwners then
            lock.recoveryOwners[record.request.requestId] = nil
            local remaining = next(lock.recoveryOwners)
            if remaining then lock.owner = remaining else store.locks[item.saleId] = nil end
        elseif lock and lock.owner == record.request.requestId then store.locks[item.saleId] = nil end
    end
end
local function checkpoint(store, adapter)
    local ok = call(adapter, "checkpoint", P.export(store))
    if ok ~= true then store.recoveryRequired = true; return nil, "CHECKPOINT_UNCERTAIN" end
    return true
end
local function now(store, adapter)
    local ms = call(adapter, "monotonicMs")
    if not finite(ms) or ms < 0 or (store.lastMs and ms < store.lastMs) then return nil, "BAD_MONOTONIC_CLOCK" end
    store.lastMs = ms; return ms
end
local function adapterOK(a)
    if type(a) ~= "table" or a.durableDealerOwnershipVersion ~= 1 then return false end
    for _, name in ipairs({ "isServer", "authorize", "monotonicMs", "currentClock", "readListing",
        "validateQuote", "validateListing", "validateDestination", "validateFunds", "prepare",
        "checkpoint", "apply", "reconcile" }) do
        if type(a[name]) ~= "function" then return false end
    end
    return true
end
local function receiptStatus(record, receipt)
    if type(receipt) ~= "table" or RLTradePersistence.check(receipt, P.LIMITS) then return nil end
    if not terminal[receipt.status] or receipt.token ~= record.context.token or receipt.amount ~= record.plan.amount
        or receipt.sourceComplete ~= true or receipt.targetComplete ~= true or receipt.moneyComplete ~= true
        or type(receipt.transferIds) ~= "table"
        or RLTradePersistence.canonical(receipt.transferIds) ~= RLTradePersistence.canonical(record.plan.transferIds) then return nil end
    return receipt.status
end
local function finish(store, record, adapter, receipt, reason)
    local outcome = receiptStatus(record, receipt)
    if not outcome then
        record.stage, record.reason = "RECOVERY_REQUIRED", reason or "OWNERSHIP_UNKNOWN"
        store.recoveryRequired = true
        checkpoint(store, adapter)
        return nil, "RECOVERY_REQUIRED"
    end
    record.needsReconciliation = nil
    record.receipt = copy(receipt)
    record.stage, record.reason = outcome, reason
    record.result = { status = outcome, requestId = record.request.requestId, amount = record.plan.amount,
        transferIds = copy(record.plan.transferIds) }
    if not checkpoint(store, adapter) then return nil, "CHECKPOINT_UNCERTAIN" end
    release(store, record)
    return copy(record.result)
end
-- principal is resolved by the SERVER connection adapter; it is not a client field.
function P.execute(store, request, principal, adapter)
    if not adapterOK(adapter) then return nil, "ADAPTER_NOT_DURABLE" end
    if call(adapter, "isServer") ~= true then return nil, "SERVER_ONLY" end
    local r, why = normalize(request, principal)
    if not r then return nil, why end
    if call(adapter, "authorize", principal, r.destination) ~= true then return nil, "NO_PERMISSION" end
    local fingerprint = RLTradePersistence.canonical(r)
    local existing = store.records[r.requestId]
    if existing then
        if existing.fingerprint ~= fingerprint then return nil, "REQUEST_CONFLICT" end
        if terminal[existing.stage] and not store.recoveryRequired then return copy(existing.result) end
        return nil, "RECOVERY_REQUIRED"
    end
    if store.recoveryRequired then return nil, "RECOVERY_REQUIRED" end
    local ms; ms, why = now(store, adapter); if not ms then return nil, why end
    -- Never steal an expired lock from a transaction that may own side effects.
    for _, item in ipairs(r.items) do
        local lock = store.locks[item.saleId]
        if lock and (lock.deadline > ms or store.records[lock.owner]) then return nil, "SALE_LOCKED" end
    end
    local transient = { request = r }
    for _, item in ipairs(r.items) do store.locks[item.saleId] = { owner = r.requestId, deadline = ms + P.LOCK_MS } end
    local function reject(reason) release(store, transient); return nil, reason end
    local clock = call(adapter, "currentClock")
    if not finite(clock) or clock < 0 then return reject("BAD_CURRENT_CLOCK") end
    local context = { request = copy(r), currentClock = clock, token = "dealer:" .. r.requestId }
    local listings = {}
    for _, item in ipairs(r.items) do
        local listing = call(adapter, "readListing", item.saleId)
        if type(listing) ~= "table" or RLTradePersistence.check(listing, P.LIMITS) then return reject("SALE_NOT_FOUND") end
        if listing.saleId ~= item.saleId or listing.recordRevision ~= item.revision then return reject("STALE_REVISION") end
        if listing.state ~= "LISTED" then return reject("SALE_NOT_LISTED") end
        local valid, reason = call(adapter, "validateListing", copy(listing), copy(context))
        if valid ~= true then return reject(reason or "INELIGIBLE") end
        listings[#listings + 1] = copy(listing)
    end
    for _, method in ipairs({ "validateQuote", "validateDestination", "validateFunds" }) do
        local valid, reason = call(adapter, method, copy(listings), copy(context))
        if valid ~= true then return reject(reason or method) end
    end
    local plan, reason = call(adapter, "prepare", copy(listings), copy(context))
    if type(plan) ~= "table" or RLTradePersistence.check(plan, P.LIMITS) or not finite(plan.amount) or plan.amount < 0
        or type(plan.compensation) ~= "table" or not dense(plan.transferIds, #r.items)
        or #plan.transferIds ~= #r.items then return reject(reason or "BAD_PREPARED_TRANSFER") end
    local ids = {}
    for _, id in ipairs(plan.transferIds) do
        if not str(id) or ids[id] then return reject("BAD_TRANSFER_ID") end; ids[id] = true
    end
    -- Stable transfer identities cannot be shared by two journal owners, including
    -- rolled-back owners whose receipts may still exist in durable recovery storage.
    for _, prior in pairs(store.records) do
        for _, id in ipairs(prior.plan.transferIds) do
            if ids[id] then return reject("TRANSFER_ID_IN_USE") end
        end
    end
    local finalMs; finalMs, why = now(store, adapter)
    if not finalMs then return reject(why) end
    if finalMs >= ms + P.LOCK_MS then return reject("LOCK_TIMEOUT") end
    local record = { request = r, fingerprint = fingerprint, stage = "PREPARED", plan = copy(plan), context = context }
    store.records[r.requestId] = record
    if not checkpoint(store, adapter) then return nil, "CHECKPOINT_UNCERTAIN" end
    record.stage = "APPLYING"
    if not checkpoint(store, adapter) then return nil, "CHECKPOINT_UNCERTAIN" end
    local commitMs = now(store, adapter)
    if not commitMs or commitMs >= ms + P.LOCK_MS then
        local outcome, reason = call(adapter, "reconcile", context.token, copy(plan), copy(context))
        return finish(store, record, adapter, outcome, reason or "LOCK_TIMEOUT")
    end
    local function abortPrepared(reason)
        local receipt, reconcileReason = call(adapter, "reconcile", context.token, copy(plan), copy(context))
        return finish(store, record, adapter, receipt, reconcileReason or reason)
    end
    -- Checkpoint adapters may yield to engine work. Re-read authority immediately before
    -- effects; apply must still hold an atomic source/target/money fence against reentry.
    if call(adapter, "authorize", principal, r.destination) ~= true then return abortPrepared("NO_PERMISSION") end
    if call(adapter, "currentClock") ~= clock then return abortPrepared("CURRENT_CLOCK_CHANGED") end
    local latest = {}
    for _, item in ipairs(r.items) do
        local listing = call(adapter, "readListing", item.saleId)
        if type(listing) ~= "table" or RLTradePersistence.check(listing, P.LIMITS) or listing.saleId ~= item.saleId
            or listing.recordRevision ~= item.revision or listing.state ~= "LISTED" then return abortPrepared("STALE_REVISION") end
        local valid, reason = call(adapter, "validateListing", copy(listing), copy(context))
        if valid ~= true then return abortPrepared(reason or "INELIGIBLE") end
        latest[#latest + 1] = copy(listing)
    end
    for _, method in ipairs({ "validateQuote", "validateDestination", "validateFunds" }) do
        local valid, reason = call(adapter, method, copy(latest), copy(context))
        if valid ~= true then return abortPrepared(reason or method) end
    end
    commitMs = now(store, adapter)
    if not commitMs or commitMs >= ms + P.LOCK_MS then return abortPrepared("LOCK_TIMEOUT") end
    local outcome, applyReason = call(adapter, "apply", context.token, copy(plan), copy(context))
    if not receiptStatus(record, outcome) then
        outcome, reason = call(adapter, "reconcile", context.token, copy(plan), copy(context))
        return finish(store, record, adapter, outcome, reason or applyReason)
    end
    return finish(store, record, adapter, outcome, applyReason)
end
-- Read-only answer for an order's owner, independent of the live adapter and of recovery state: the saved
-- result of a finished order, PENDING while it is in flight, UNCERTAIN when it needs reconciliation. Another
-- principal's order is indistinguishable from a missing one.
function P.lookup(store, requestId, principal)
    if type(store) ~= "table" or not str(requestId) or not str(principal) then return nil, "BAD_LOOKUP" end
    local record = store.records[requestId]
    if record == nil or record.request.principal ~= principal then return nil, "UNKNOWN_REQUEST" end
    if terminal[record.stage] and not record.needsReconciliation then return copy(record.result) end
    if record.stage == "RECOVERY_REQUIRED" or record.needsReconciliation then
        return { status = "UNCERTAIN", requestId = requestId }
    end
    return { status = "PENDING", requestId = requestId }
end
-- Plain journal import validates identity, request fingerprint and finished results.
-- Every interrupted stage closes the gate; locks are reconstructed only as recovery ownership.
function P.import(data, options)
    if type(data) ~= "table" or RLTradePersistence.check(data, P.LIMITS) or data.version ~= P.VERSION
        or type(data.records) ~= "table" or type(data.recoveryRequired) ~= "boolean" then return nil, "BAD_JOURNAL" end
    if options ~= nil and (type(options) ~= "table" or (options.forceReconciliation ~= nil
        and type(options.forceReconciliation) ~= "boolean")) then return nil, "BAD_IMPORT_OPTIONS" end
    local force = options and options.forceReconciliation == true
    local store = P.new(); store.recoveryRequired = data.recoveryRequired
    local claimedTransfers = {}
    for id, saved in pairs(data.records) do
        if type(saved) ~= "table" or not stages[saved.stage] then return nil, "BAD_JOURNAL_STAGE" end
        if saved.needsReconciliation ~= nil and type(saved.needsReconciliation) ~= "boolean" then return nil, "BAD_JOURNAL_RECORD" end
        if type(saved.request) ~= "table" then return nil, "BAD_JOURNAL_RECORD" end
        local r = normalize(saved.request, saved.request.principal)
        if not r or id ~= r.requestId or saved.fingerprint ~= RLTradePersistence.canonical(r)
            or type(saved.plan) ~= "table" or not finite(saved.plan.amount) or saved.plan.amount < 0
            or type(saved.plan.compensation) ~= "table" or not dense(saved.plan.transferIds, #r.items)
            or #saved.plan.transferIds ~= #r.items or type(saved.context) ~= "table"
            or saved.context.token ~= "dealer:" .. id
            or not finite(saved.context.currentClock) or saved.context.currentClock < 0
            or RLTradePersistence.canonical(saved.context.request or {}) ~= saved.fingerprint then return nil, "BAD_JOURNAL_RECORD" end
        local ids = {}; for _, identity in ipairs(saved.plan.transferIds) do
            if not str(identity) or ids[identity] or claimedTransfers[identity] then return nil, "BAD_JOURNAL_TRANSFER" end
            ids[identity] = true; claimedTransfers[identity] = id
        end
        if terminal[saved.stage] then
            if receiptStatus(saved, saved.receipt) ~= saved.stage then return nil, "BAD_JOURNAL_RECEIPT" end
            local result = saved.result
            if type(result) ~= "table" or result.status ~= saved.stage or result.requestId ~= id
                or result.amount ~= saved.plan.amount or type(result.transferIds) ~= "table"
                or RLTradePersistence.canonical(result.transferIds) ~= RLTradePersistence.canonical(saved.plan.transferIds)
                then return nil, "BAD_JOURNAL_RESULT" end
        end
        local record = copy(saved)
        if force or saved.needsReconciliation == true then record.needsReconciliation = true end
        if not terminal[saved.stage] or record.needsReconciliation then
            store.recoveryRequired = true
            for _, item in ipairs(r.items) do
                local lock = store.locks[item.saleId]
                if lock then
                    if not force and not record.needsReconciliation and not lock.forcedReconciliation then
                        return nil, "OVERLAPPING_JOURNAL"
                    end
                    lock.recoveryOwners = lock.recoveryOwners or { [lock.owner] = true }
                    lock.recoveryOwners[id] = true
                    lock.forcedReconciliation = true
                else
                    store.locks[item.saleId] = { owner = id, deadline = 0,
                        forcedReconciliation = record.needsReconciliation == true }
                end
            end
        end
        store.records[id] = record
    end
    return store
end
function P.recover(store, adapter)
    if not adapterOK(adapter) then return nil, "ADAPTER_NOT_DURABLE" end
    if call(adapter, "isServer") ~= true then return nil, "SERVER_ONLY" end
    local ids = {}; for id in pairs(store.records) do ids[#ids + 1] = id end; table.sort(ids)
    for _, id in ipairs(ids) do
        local record = store.records[id]
        if not terminal[record.stage] or record.needsReconciliation then
            local outcome, reason = call(adapter, "reconcile", record.context.token, copy(record.plan), copy(record.context))
            if not finish(store, record, adapter, outcome, reason) then return nil, "RECOVERY_REQUIRED" end
        end
    end
    store.recoveryRequired = false
    if not checkpoint(store, adapter) then return nil, "CHECKPOINT_UNCERTAIN" end
    return true
end
