-- Persistable dealer listing state only. No game integration, identity allocation,
-- RNG, money, physiology or reproduction is owned by this module.
RLDealerListingRegistry = {}
local R = RLDealerListingRegistry
R.VERSION, R.MIGRATION_VERSION, R.EXTERNAL_BUYER_LAMBDA = 1, 1, 0
R.LIFETIMES = { UNWEANED = 0.5, GROWING = 1, STORE = 1, REPLACEMENT = 1,
    BREEDING = 2, PRODUCTION = 2, SHORT_CYCLE = 0.5, HORSE = 2 }
local states = { DRAFT = true, LISTED = true, RESERVED = true, SOLD = true, WITHDRAWN = true, QUARANTINED = true }
local finite=RLPlain.finite
local function copy(x, seen)
    if type(x) ~= "table" then return x end
    seen = seen or {}; if seen[x] then error("cyclic listing data") end
    seen[x] = true; local y = {}
    for k, v in pairs(x) do y[k] = copy(v, seen) end
    seen[x] = nil; return y
end
local function timeOK(r, now) return finite(now) and now >= 0 and now >= (r.lastUpdatedAtMonths or 0) end
local function bump(r, now) r.recordRevision = r.recordRevision + 1; r.lastUpdatedAtMonths = now end
local function identifier(x) return type(x) == "string" and #x > 0 end
function R.new(namespace)
    if not identifier(namespace) then return nil, "INVALID_NAMESPACE" end
    return { version = R.VERSION, namespace = namespace, nextSequence = 1, records = {}, migrationVersion = 0, migratedKeys = {} }
end
function R.get(registry, saleId)
    local r = registry.records[saleId]; return r and copy(r) or nil
end
function R.listRecords(registry, state)
    local result = {}
    for _, r in pairs(registry.records) do if state == nil or r.state == state then result[#result + 1] = copy(r) end end
    table.sort(result, function(a, b) return a.saleId < b.saleId end)
    return result
end
function R.createDraft(registry, payload, lifetimeClass, now, options)
    options = options or {}
    if type(payload) ~= "table" or R.LIFETIMES[lifetimeClass] == nil or not finite(now) or now < 0 then return nil, "INVALID_DRAFT" end
    if options.rotation ~= nil and options.rotation ~= "MONTH_CHECKPOINT" then return nil, "ROTATION_CONFLICT" end
    local saleId = registry.namespace .. ":" .. tostring(registry.nextSequence)
    if registry.records[saleId] ~= nil then return nil, "IDENTITY_COLLISION" end
    local r = { saleId = saleId, state = "DRAFT", recordRevision = 1, lastUpdatedAtMonths = now, lastProgressedAtMonths = now,
        lifetimeClass = lifetimeClass, rotation = "MONTH_CHECKPOINT", payload = copy(payload) }
    registry.nextSequence = registry.nextSequence + 1; registry.records[saleId] = r
    return copy(r)
end
function R.list(registry, saleId, now)
    local r = registry.records[saleId]
    if not r or r.state ~= "DRAFT" then return nil, "INVALID_STATE" end
    if not timeOK(r, now) then return nil, "INVALID_TIME" end
    r.state, r.listedAtMonths = "LISTED", now
    r.expiresAtMonths = now + R.LIFETIMES[r.lifetimeClass]; bump(r, now)
    return copy(r)
end
function R.withdraw(registry, saleId, now, reason)
    local r = registry.records[saleId]
    if not r or (r.state ~= "LISTED" and r.state ~= "RESERVED") then return nil, "INVALID_STATE" end
    if not timeOK(r, now) then return nil, "INVALID_TIME" end
    r.state, r.reason, r.lock = "WITHDRAWN", reason or "INELIGIBLE", nil; bump(r, now)
    return copy(r)
end
function R.quarantine(registry, saleId, now, reason)
    local r = registry.records[saleId]
    if not r or r.state == "SOLD" then return nil, "INVALID_STATE" end
    if not timeOK(r, now) then return nil, "INVALID_TIME" end
    r.state, r.reason, r.lock = "QUARANTINED", reason or "UNRELIABLE", nil; bump(r, now)
    return copy(r)
end
-- Callback works on a detached snapshot; failure cannot partly mutate a listing.
-- It must advance normal source-farm physiology/reproduction exactly once and
-- return a complete payload. No fallback growth/migration occurs here.
function R.progress(registry, saleId, now, advance, eligible)
    local r = registry.records[saleId]
    if not r or (r.state ~= "LISTED" and r.state ~= "RESERVED") then return nil, "INVALID_STATE" end
    if not timeOK(r, now) then return nil, "INVALID_TIME" end
    if type(eligible) ~= "function" then return nil, "ELIGIBILITY_REQUIRED" end
    if now > r.lastProgressedAtMonths then
        if type(advance) ~= "function" then return nil, "PROGRESSION_REQUIRED" end
        local ok, payload, reason = pcall(advance, copy(r.payload), r.lastProgressedAtMonths, now, copy(r))
        if not ok or type(payload) ~= "table" then return R.quarantine(registry, saleId, now, reason or "PROGRESSION_FAILED") end
        r.payload = copy(payload); r.lastProgressedAtMonths = now; bump(r, now)
    end
    if now >= r.expiresAtMonths then return R.withdraw(registry, saleId, now, "EXPIRED") end
    if type(eligible) ~= "function" then return nil, "ELIGIBILITY_REQUIRED" end
    local ok, accepted, reason = pcall(eligible, copy(r.payload), copy(r))
    if not ok then return R.quarantine(registry, saleId, now, "ELIGIBILITY_FAILED") end
    if accepted ~= true then return R.withdraw(registry, saleId, now, reason or "INELIGIBLE") end
    return copy(r)
end
function R.reserve(registry, saleId, revision, requestId, now, realNow, timeout)
    local r = registry.records[saleId]
    if not r or r.state ~= "LISTED" then return nil, "INVALID_STATE" end
    if r.recordRevision ~= revision then return nil, "STALE_REVISION" end
    if not identifier(requestId) or not timeOK(r, now) or not finite(realNow) or realNow < 0
        or not finite(timeout) or timeout <= 0 or not finite(realNow + timeout) then return nil, "INVALID_LOCK" end
    if now ~= r.lastProgressedAtMonths then return nil, "PROGRESSION_REQUIRED" end
    if now >= r.expiresAtMonths then return R.withdraw(registry, saleId, now, "EXPIRED") end
    r.state, r.lock = "RESERVED", { requestId = requestId, acquiredAtReal = realNow, expiresAtReal = realNow + timeout }
    bump(r, now); return copy(r)
end
function R.release(registry, saleId, requestId, now, realNow)
    local r = registry.records[saleId]
    if not r or r.state ~= "RESERVED" or not r.lock then return nil, "INVALID_STATE" end
    if not timeOK(r, now) or not finite(realNow) or realNow < r.lock.acquiredAtReal then return nil, "INVALID_TIME" end
    if requestId ~= r.lock.requestId and realNow < r.lock.expiresAtReal then return nil, "LOCKED" end
    r.state, r.lock = "LISTED", nil; bump(r, now)
    if now >= r.expiresAtMonths then return R.withdraw(registry, saleId, now, "EXPIRED") end
    return copy(r)
end
-- paid: the buyer's money is already applied, so the sale is final even if the lock's real-time
-- window ran out meanwhile (the lock must still be this request's).
function R.markSold(registry, saleId, requestId, revision, now, realNow, paid)
    local r = registry.records[saleId]
    if not r or r.state ~= "RESERVED" or not r.lock or r.lock.requestId ~= requestId then return nil, "LOCKED" end
    if r.recordRevision ~= revision then return nil, "STALE_REVISION" end
    if not timeOK(r, now) or not finite(realNow) or realNow < r.lock.acquiredAtReal then return nil, "INVALID_TIME" end
    if paid ~= true and realNow >= r.lock.expiresAtReal then return nil, "LOCK_EXPIRED" end
    if now ~= r.lastProgressedAtMonths then return nil, "PROGRESSION_REQUIRED" end
    if now >= r.expiresAtMonths then return R.withdraw(registry, saleId, now, "EXPIRED") end
    r.state, r.soldRequestId, r.lock = "SOLD", requestId, nil; bump(r, now); return copy(r)
end
function R.export(registry) return copy(registry) end
function R.restore(data)
    if type(data) ~= "table" or data.version ~= R.VERSION or not identifier(data.namespace)
        or not finite(data.nextSequence) or data.nextSequence < 1 or data.nextSequence % 1 ~= 0
        or type(data.records) ~= "table" or type(data.migratedKeys) ~= "table"
        or (data.migrationVersion ~= 0 and data.migrationVersion ~= R.MIGRATION_VERSION) then return nil, "INVALID_REGISTRY" end
    local ok, result = pcall(copy, data); if not ok then return nil, "INVALID_REGISTRY" end
    local prefix = result.namespace .. ":"
    for id, r in pairs(result.records) do
        local suffix = type(id) == "string" and string.sub(id, #prefix + 1) or ""
        local sequence = tonumber(suffix)
        if type(id) ~= "string" or string.sub(id, 1, #prefix) ~= prefix
            or not string.match(suffix, "^[1-9][0-9]*$") or not finite(sequence)
            or sequence >= result.nextSequence then return nil, "INVALID_IDENTITY" end
        if type(r) ~= "table" or id ~= r.saleId or not identifier(id) or not states[r.state]
            or not finite(r.recordRevision) or r.recordRevision < 1 or r.recordRevision % 1 ~= 0
            or not finite(r.lastUpdatedAtMonths) or r.lastUpdatedAtMonths < 0
            or not finite(r.lastProgressedAtMonths) or r.lastProgressedAtMonths < 0
            or r.lastProgressedAtMonths > r.lastUpdatedAtMonths or type(r.payload) ~= "table"
            or R.LIFETIMES[r.lifetimeClass] == nil or r.rotation ~= "MONTH_CHECKPOINT" then return nil, "INVALID_RECORD" end
        if r.state ~= "DRAFT" and r.state ~= "QUARANTINED" and
            (not finite(r.listedAtMonths) or not finite(r.expiresAtMonths) or r.listedAtMonths < 0
            or r.expiresAtMonths ~= r.listedAtMonths + R.LIFETIMES[r.lifetimeClass]
            or r.lastUpdatedAtMonths < r.listedAtMonths) then return nil, "INVALID_RECORD" end
        -- Runtime monotonic locks cannot survive a process/clock epoch. Keep the
        -- record quarantined for transaction-journal reconciliation, never unlock.
        if r.state == "RESERVED" then
            r.recoveryLock = r.lock; r.lock = nil; r.state = "QUARANTINED"; r.reason = "TRANSACTION_RECOVERY_REQUIRED"
            r.recordRevision = r.recordRevision + 1
        end
    end
    return result
end
-- Only the stock adapter calls this. Classification must explicitly distinguish
-- VALID / HARD_INVALID / UNRELIABLE_V2 / MISSING_MOD / UNKNOWN / CORRUPT.
-- Uncertain entries retain raw data; this path never generates birth/history.
function R.migrateStock(registry, stock, now, classify)
    if registry.migrationVersion == R.MIGRATION_VERSION then return { migrated = 0, skipped = true } end
    if type(stock) ~= "table" or type(classify) ~= "function" or not finite(now) or now < 0 then return nil, "INVALID_MIGRATION" end
    local staged = copy(registry); local count = 0
    for _, item in ipairs(stock) do
        if type(item) ~= "table" or not identifier(item.stockKey) then return nil, "MISSING_STOCK_ID" end
        if not staged.migratedKeys[item.stockKey] then
            local ok, classification, lifetimeClass, reason = pcall(classify, copy(item))
            local valid = ok and classification == "VALID" and R.LIFETIMES[lifetimeClass] ~= nil
            local r = R.createDraft(staged, { legacyStock = copy(item), migrationClass = ok and classification or "CORRUPT" }, valid and lifetimeClass or "GROWING", now)
            if valid then R.list(staged, r.saleId, now)
            elseif classification == "HARD_INVALID" then
                local raw = staged.records[r.saleId]; raw.state, raw.reason = "WITHDRAWN", reason or "HARD_INVALID"
                raw.listedAtMonths, raw.expiresAtMonths = now, now + R.LIFETIMES.GROWING; bump(raw, now)
            else R.quarantine(staged, r.saleId, now, reason or (ok and classification) or "CORRUPT") end
            staged.migratedKeys[item.stockKey] = r.saleId; count = count + 1
        end
    end
    staged.migrationVersion = R.MIGRATION_VERSION
    for k, v in pairs(staged) do registry[k] = v end
    return { migrated = count, skipped = false }
end
