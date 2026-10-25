--[[
    Dealer v2 T2c: the identity ledger in the running game. The seven places that used to take the next
    raw counter value (player births, setUniqueId, Animal.new, the trailer rideable conversion, the old
    dealer's sale animals, sale births, legacy AI bulls) call R.raw(ctx, legacyFn) instead of their own
    counter. One switch decides for all of them, never a mix:

        OFF     legacyFn() numbers, past every key known to be taken (below), nothing else.
        SHADOW  as OFF, and every key legacyFn produced that was taken is counted and logged.
                The default. It changes no RNG or file.
        ON      the ledger (RLAnimalIdentity) hands out the key; legacyFn is NOT called; the native
                counter is moved up to the raw value (mirror) so old tools still see a high-water mark.

    Taken keys (ID-COLLISION-01). A full key has no species and the native counters are per species
    (FarmStats cowId/pigId/sheepId..., a sale farm's ids per type), so the Nth lamb of a herd got the
    full key of its Nth pig. Whatever the mode, on the server a key is never handed out while it is
    known to be taken: a live animal of the world scan at load, a parent a live animal names, or a
    key handed out since (R.isTaken; ON also vetoes them in the ledger). Off the ledger the native
    counter skips such a key: on the first one it moves up to the highest counter of any species in
    the domain (mirror), then on one by one. The scan is the world at load; the load repair
    (RLAnimalIdentityRepair) renumbers duplicates the old counters left.

    ON is entered only by R.activate (console rlIdentityActivate), on a READY server, after the world
    scan: every live key is imported as CONSUMED, every domain is registered. A domain whose counter
    history cannot be proven needs the user to accept the weaker MIGRATION_POINT guarantee
    (activate with accept); without it activation is refused and the domains are listed. While the ledger is
    not the allocator (OFF, SHADOW, RECOVERY_REQUIRED) the native counters keep numbering; a re-activation and
    rlIdentityRecoveryClear (R.reconcile) therefore import the live keys and move every known domain past those
    counters, blocking the raws of animals that are gone since.

    Births. A birth cannot be refused halfway, so R.beginBirth runs before the engine touches the
    pregnancy: it reserves one key per fetus for this birth event (idempotent per event id, so a held
    birth retried the next day gets the same keys) and answers false when it cannot. A false answer
    leaves the mother pregnant with every field as it was - no RNG, no parity change, no placeholder
    newborn; the pregnancy itself is the saved intent. Children take their keys from the litter in order
    (R.raw with ctx.litter); R.endBirth burns the keys of dead or unborn children.

    Unsaved session. Every reserved key is synchronously written and read back by the checkpoint
    beside the save before binding or publication; on a load of the same generation those keys are burned (they were shown to the
    player in a session that was not saved). The animals are not restored.
]]

RLAnimalIdentityRuntime = {}
local R = RLAnimalIdentityRuntime
local I = RLAnimalIdentity

R.OFF, R.SHADOW, R.ON = "OFF", "SHADOW", "ON"
R.MAX_SHADOW_LINES = 40
R.COMPACT_EVERY = 500
-- Roles whose animals are only listed for sale: most are never bought and leave with the next restock, so a
-- permanent ledger key for each (about 1500 a game day) filled the ledger and used up a domain's 90000 ids in
-- ~45 days. They number by the native counter past live and issued keys; an animal that is bought is a live
-- animal from then on and is protected as one (R.setLive on load, the scan on activation).
R.TRANSIENT_ROLES = { sale = true }

local function log(level, fmt, ...)
    if Log ~= nil and Log[level] ~= nil then Log[level](Log, fmt, ...) end
end


function R.reset(isServer)
    R.server = isServer == true
    R.state = R.server and "LOADING" or "DISABLED"
    R.reason = R.server and "WAITING_FOR_MISSION" or "CLIENT"
    R.ledger, R.mode, R.lineage = nil, R.SHADOW, nil
    R.litters, R.current = {}, nil
    R.journal, R.journalSent, R.journalSeen = {}, 0, {}
    R.allocationBlocked, R.activationQuarantine, R.journalBarrierBusy = nil, nil, nil
    R.live = nil
    R.issued, R.skipLines = {}, 0
    R.shadow = { observed = 0, collisions = 0, byEntry = {}, lines = 0, seen = {} }
    R.held = {}
    R.allocations = 0
    R.batchDepth, R.batchPending = 0, nil
end


--- The checkpoint reports the load result: a ledger (or nil when the save never had one) and the state.
function R.setLoaded(ledger, state, reason)
    R.ledger = ledger
    R.state, R.reason = state, reason
    R.mode = ledger ~= nil and ledger.policy.mode or R.SHADOW
    if R.mode ~= R.ON and R.mode ~= R.OFF then R.mode = R.SHADOW end
end


--- Whether the ledger is the allocator right now.
function R.authoritative()
    return R.server == true and R.state == "READY" and R.mode == R.ON and R.ledger ~= nil
end


local function liveKey(farmId, uniqueId, country)
    return I.keyString(farmId, uniqueId, country)
end


-- -------------------------------------------------------------------------------------------
-- Shadow
-- -------------------------------------------------------------------------------------------

--- Remember the world's keys (from R.scan) as the reference of taken keys; `refs` (the scan's) are
--- the full keys live animals name as their parents.
function R.setLive(records, refs)
    local live, herds = {}, {}
    for _, r in ipairs(records or {}) do
        if r.farmId ~= nil and r.uniqueId ~= nil and r.country ~= nil then
            live[liveKey(r.farmId, r.uniqueId, r.country)] = r.type or "?"
            local hk = I.domainKey(r.country, r.farmId)
            herds[hk] = (herds[hk] or 0) + 1
        end
    end
    local named = {}
    for _, key in ipairs(refs or {}) do named[key] = true end
    R.live = { keys = live, herds = herds, refs = named }
end


--- Whether a full key is known to be taken: a live animal of the last scan, a parent one names, or
--- a key handed out since (any mode).
function R.isTaken(key)
    local live = R.live
    return (live ~= nil and (live.keys[key] ~= nil or (live.refs ~= nil and live.refs[key] ~= nil)))
        or (R.issued ~= nil and R.issued[key] ~= nil)
end


--- The native counter's next raw that is not taken (R.isTaken). Returns raw and how many taken keys it
--- passed. Without a domain (no country or herd) the counter's value as it is.
function R.freeRaw(ctx, legacyFn)
    local raw = legacyFn()
    if raw == nil or ctx == nil or ctx.country == nil or ctx.herd == nil then return raw, 0 end
    local key = liveKey(ctx.herd, I.format(ctx.herd, raw), ctx.country)
    local skipped, first = 0, key
    while R.isTaken(key) and skipped <= I.MAX_RAW do
        if skipped == 0 and ctx.counterMax ~= nil and ctx.mirror ~= nil then
            -- Keys carry no species: past the domain's highest counter of any species at once.
            local max = ctx.counterMax()
            if type(max) == "number" and max > raw then ctx.mirror(max) end
        end
        skipped = skipped + 1
        raw = legacyFn()
        if raw == nil then return nil, skipped end
        key = liveKey(ctx.herd, I.format(ctx.herd, raw), ctx.country)
    end
    R.issued = R.issued or {}
    if skipped > 0 then
        R.skipLines = R.skipLines or 0
        if R.isTaken(key) then
            log("error", "IDENTITY: %s found no free key in %s/%s after %d taken key(s)", tostring(ctx.entry), tostring(ctx.country), tostring(ctx.herd), skipped)
        elseif R.skipLines < R.MAX_SHADOW_LINES then
            R.skipLines = R.skipLines + 1
            log("info", "IDENTITY: %s passed %d taken key(s) from %s, numbered %s (type %s)", tostring(ctx.entry), skipped, first, key, tostring(ctx.typeKey))
        end
    end
    R.issued[key] = tostring(ctx.typeKey or "?")
    return raw, skipped, first
end


local function observe(ctx, raw, skipped, first)
    local sh = R.shadow
    sh.observed = sh.observed + 1
    sh.byEntry[ctx.entry or "?"] = (sh.byEntry[ctx.entry or "?"] or 0) + 1
    if ctx.country == nil or ctx.herd == nil or raw == nil then return end
    local key = liveKey(ctx.herd, I.format(ctx.herd, raw), ctx.country)
    if (skipped or 0) > 0 then
        sh.collisions = sh.collisions + skipped
        if sh.lines < R.MAX_SHADOW_LINES then
            sh.lines = sh.lines + 1
            log("warning", "IDENTITY_SHADOW: %s produced %s which already exists (%d taken, entry type %s, numbered %s)", tostring(ctx.entry),
                tostring(first), skipped, tostring(ctx.typeKey), key)
        end
    end
    sh.seen[key] = ctx.typeKey or "?"
end


-- -------------------------------------------------------------------------------------------
-- Allocation
-- -------------------------------------------------------------------------------------------

local function ensureDomain(ctx)
    local l = R.ledger
    local d = l.domains[I.domainKey(ctx.country, ctx.herd)]
    if d ~= nil then
        if d.status ~= I.VERIFIED then return nil, "DOMAIN_UNPROVEN" end
        return d
    end
    local max = ctx.counterMax ~= nil and ctx.counterMax() or nil
    if type(max) ~= "number" or max < 0 then return nil, "NO_COUNTER_EVIDENCE" end
    local liveHere = R.live ~= nil and (R.live.herds[I.domainKey(ctx.country, ctx.herd)] or 0) or 0
    local proof
    if max == 0 and liveHere == 0 then
        proof = { kind = "EXCLUSIVE_NEW", startRaw = 1 }
    elseif l.policy.acceptWeak == true then
        proof = { kind = "MIGRATION_POINT", startRaw = math.min(max + 1, I.MAX_RAW + 1), userAccepted = true }
    else
        return nil, "DOMAIN_UNPROVEN"
    end
    local domain, why = I.registerDomain(l, ctx.country, ctx.herd, proof)
    if domain == nil then return nil, why end
    log("info", "IDENTITY: domain %s registered (%s, next raw %d)", I.domainKey(ctx.country, ctx.herd), proof.kind, domain.next)
    return domain
end


local function journalKey(key)
    R.journalSeen = R.journalSeen or {}
    if R.journalSeen[key] then return end
    R.journalSeen[key] = true
    R.journal[#R.journal + 1] = key
    R.journalDirty = true
end


-- Reserve durability precedes materialization, native-counter mirroring and publication.
-- A verified journal protects the keys even if later binding fails: restart burns them,
-- never replays an animal. Tests may inject a barrier; production requires the checkpoint.
local function allocationGate()
    if R.journalBarrierBusy then return nil, "IDENTITY_JOURNAL_IN_PROGRESS" end
    if R.journalBarrier ~= nil then return true end
    if RLAnimalIdentityCheckpoint and RLAnimalIdentityCheckpoint.allocationGate then
        return RLAnimalIdentityCheckpoint.allocationGate()
    end
    return nil, "JOURNAL_BARRIER_MISSING"
end

local function runBarrier()
    local barrier = R.journalBarrier or (RLAnimalIdentityCheckpoint and RLAnimalIdentityCheckpoint.persistAllocation)
    local ok, saved, why = false, nil, "JOURNAL_BARRIER_MISSING"
    if barrier ~= nil then
        R.journalBarrierBusy = true
        ok, saved, why = pcall(barrier)
        R.journalBarrierBusy = nil
    end
    if saved == true and not R.authoritative() then saved, why = nil, "JOURNAL_AUTHORITY_CHANGED" end
    if not ok or saved ~= true then
        why = ok and (why or "JOURNAL_BARRIER_FAILED") or "JOURNAL_BARRIER_UNCERTAIN"
        -- An initial complete checkpoint is required but does not constitute damaged evidence.
        if why ~= "INITIAL_SAVE_REQUIRED" and why ~= "IDENTITY_SAVE_IN_PROGRESS" then
            R.allocationBlocked = why
            R.state, R.reason = "RECOVERY_REQUIRED", why
            if R.journalBarrier == nil and RLAnimalIdentityCheckpoint and RLAnimalIdentityCheckpoint.failAllocation then
                RLAnimalIdentityCheckpoint.failAllocation(why)
            end
        end
        return nil, why
    end
    return true
end

local function persistReserved(keys)
    for _, item in ipairs(keys) do journalKey(type(item) == "table" and item.key or item) end
    -- Inside R.batch the keys wait in R.journal for the one barrier at its end (see R.batch).
    if (R.batchDepth or 0) > 0 then R.batchPending = true; return true end
    return runBarrier()
end


local unpackValues = table.unpack or unpack
local function packValues(...) return { n = select("#", ...), ... } end

--- Run fn(...) as one allocation batch: the keys it reserves are journaled by ONE barrier when it
--- returns instead of one barrier per key. The barrier rewrites the whole unsaved-key journal (two
--- files, each read back), so per key it cost O(keys) and a day change of the old dealer's restock
--- (~1500 keys a game day at 200 animals) stalled the game (game test 2026-10-24).
--- Only for one synchronous engine callback: no save, network send or frame can fall inside it, so a
--- key is still on disk before anything outside this Lua call can see it. If the end barrier fails the
--- ledger goes to RECOVERY_REQUIRED as a failed per-key barrier does (the animals made in the batch
--- exist only in this unsaved session). Nested batches flush once, at the outermost end.
function R.batch(fn, ...)
    R.batchDepth = (R.batchDepth or 0) + 1
    local results = packValues(pcall(fn, ...))
    R.batchDepth = R.batchDepth - 1
    if R.batchDepth == 0 and R.batchPending then
        R.batchPending = nil
        local persisted, why = runBarrier()
        if not persisted then log("error", "IDENTITY: the batched journal barrier failed: %s", tostring(why)) end
    end
    if not results[1] then error(results[2], 0) end
    return unpackValues(results, 2, results.n)
end


local function afterAllocation()
    R.allocations = R.allocations + 1
    if R.allocations % R.COMPACT_EVERY == 0 then I.compact(R.ledger, 200) end
end


local function allocateOne(ctx)
    local d, why = ensureDomain(ctx)
    if d == nil then return nil, why end
    local l = R.ledger
    local requestId = "a" .. I.nextOp(l)
    local plan = { country = ctx.country, farmId = tostring(ctx.herd), items = { { role = ctx.role or "auto", type = tostring(ctx.typeKey or "?") } } }
    local res
    res, why = I.reserveBatch(l, requestId, plan, { isOccupied = R.isTaken })
    if res == nil then return nil, why end
    local persisted
    persisted, why = persistReserved(res.keys)
    if not persisted then return nil, why end
    local key = res.keys[1]
    assert(I.bindMaterialization(l, requestId, "auto"))
    assert(I.consume(l, key.key))
    journalKey(key.key)
    afterAllocation()
    return key.raw, key.key
end


local function takeFromLitter(litter)
    local l = R.ledger
    for _, key in ipairs(litter.keys) do
        local rec = l.keys[key]
        if rec ~= nil and rec.state == I.MATERIALIZED then
            assert(I.consume(l, key))
            journalKey(key)
            afterAllocation()
            return rec.raw, key
        end
    end
    return nil, "LITTER_EXHAUSTED"
end


--- The raw counter value an entry must use. Returns raw, or nil and why when ON refuses.
--- ctx = { entry, country, herd, typeKey, role, counterMax = fn, mirror = fn(raw), litter = litter }
function R.raw(ctx, legacyFn)
    if not R.server then return legacyFn() end
    if R.allocationBlocked then return nil, R.allocationBlocked end
    if R.mode == R.ON and R.journalBarrier == nil and RLAnimalIdentityCheckpoint
        and not RLAnimalIdentityCheckpoint.journalVerified then return nil, "JOURNAL_VERIFICATION_REQUIRED" end
    local authoritative = R.authoritative()
    if not authoritative or R.TRANSIENT_ROLES[ctx.role] then
        -- Not the allocator (OFF, SHADOW, loading, recovery), or an animal on the dealer's sale list: the
        -- native counter, past taken keys.
        local raw, skipped, first = R.freeRaw(ctx, legacyFn)
        if authoritative then
            -- The ledger stays behind the counter: its domain never hands out a raw the counter has passed.
            local domain = raw ~= nil and ctx.country ~= nil and ctx.herd ~= nil and R.ledger.domains[I.domainKey(ctx.country, ctx.herd)] or nil
            if domain ~= nil then I.raiseHighWater(R.ledger, ctx.country, ctx.herd, raw + 1) end
        elseif R.mode == R.SHADOW and R.state == "READY" then
            local ok, err = pcall(observe, ctx, raw, skipped, first)
            if not ok then log("warning", "IDENTITY_SHADOW failed: %s", tostring(err)) end
        end
        return raw
    end
    local allowed, blocked = allocationGate()
    if not allowed then return nil, blocked end
    if ctx.country == nil or ctx.herd == nil then return nil, "NO_DOMAIN" end
    local raw, why
    if ctx.litter ~= nil then
        local lc = ctx.litter.ctx
        if lc.country ~= ctx.country or tostring(lc.herd) ~= tostring(ctx.herd) then raw, why = nil, "LITTER_DOMAIN"
        else raw, why = takeFromLitter(ctx.litter) end
    else
        raw, why = allocateOne(ctx)
    end
    if raw == nil then
        log("error", "IDENTITY: %s could not take a key in %s/%s: %s", tostring(ctx.entry), tostring(ctx.country), tostring(ctx.herd), tostring(why))
        return nil, why
    end
    if ctx.mirror ~= nil then ctx.mirror(raw) end
    return raw
end


-- -------------------------------------------------------------------------------------------
-- Births
-- -------------------------------------------------------------------------------------------

local function reserveLitter(ctx, eventId, n)
    local d, why = ensureDomain(ctx)
    if d == nil then return nil, why end
    local l = R.ledger
    local items = {}
    for i = 1, n do items[i] = { role = "birth", type = tostring(ctx.typeKey or "?") } end
    for attempt = 1, 5 do
        local requestId = "L" .. eventId .. "@" .. I.domainKey(ctx.country, ctx.herd) .. (attempt > 1 and ("#" .. attempt) or "")
        local res
        res, why = I.reserveBatch(l, requestId, { country = ctx.country, farmId = tostring(ctx.herd), items = items }, { isOccupied = R.isTaken })
        if res == nil then return nil, why end
        local untouched = true
        for _, k in ipairs(res.keys) do if k.state ~= I.RESERVED and k.state ~= I.MATERIALIZED then untouched = false end end
        if untouched then
            local persisted
            persisted, why = persistReserved(res.keys)
            if not persisted then return nil, why end
            if not res.replayed or res.keys[1].state == I.RESERVED then
                local bound
                bound, why = I.bindMaterialization(l, requestId, "litter:" .. eventId)
                if bound == nil then return nil, why end
            end
            local keys = {}
            for i, k in ipairs(res.keys) do keys[i] = k.key end
            return { id = eventId, requestId = requestId, keys = keys, ctx = ctx }
        end
    end
    return nil, "LITTER_ATTEMPTS"
end


--- Before a birth touches anything. Returns true to go on, or false and why to hold the birth.
--- `context` = R.animalContext(mother, isSaleAnimal) result; `eventId` is stable for this pregnancy.
function R.beginBirth(context, eventId, n)
    R.current = nil
    if R.allocationBlocked then return false, R.allocationBlocked end
    if R.mode == R.ON and R.journalBarrier == nil and RLAnimalIdentityCheckpoint
        and not RLAnimalIdentityCheckpoint.journalVerified then return false, "JOURNAL_VERIFICATION_REQUIRED" end
    if not R.authoritative() then return true end
    local allowed, blocked = allocationGate()
    if not allowed then return false, blocked end
    if context == nil then return false, "NO_DOMAIN" end
    local litter, why = reserveLitter(context, eventId, n)
    if litter == nil then
        if not R.held[eventId] then
            R.held[eventId] = true
            log("error", "IDENTITY: birth %s held (%s) - the mother stays pregnant and the birth is tried again", eventId, tostring(why))
        end
        return false, why
    end
    R.held[eventId] = nil
    R.current = litter
    return true
end


--- The litter for the birth in progress (nil when the ledger is not the allocator).
function R.currentLitter() return R.current end


--- After the birth: the keys of children that did not become animals are burned.
function R.endBirth()
    local litter = R.current
    R.current = nil
    if litter == nil or R.ledger == nil then return 0 end
    local burned = 0
    for _, key in ipairs(litter.keys) do
        local rec = R.ledger.keys[key]
        if rec ~= nil and rec.state == I.MATERIALIZED then
            I.burnKey(R.ledger, key, "litter-unused")
            journalKey(key)
            burned = burned + 1
        end
    end
    return burned
end


-- -------------------------------------------------------------------------------------------
-- Batches for the dealer (T3): adults, fetuses and a sire reserved together, then bound and consumed
-- -------------------------------------------------------------------------------------------

--- Reserve the keys of one dealer source (adult, fixed fetuses, sire) in one domain.
--- items = { { role = "adult"|"fetus"|"ai", type = "COW" }, ... }. Idempotent per requestId.
--- Returns { keys = { { key, farmId, uniqueId, country, raw, role, state } } } or nil and why.
function R.reserveFor(ctx, requestId, items)
    if not R.authoritative() then return nil, "IDENTITY_NOT_AUTHORITATIVE" end
    local allowed, blocked = allocationGate()
    if not allowed then return nil, blocked end
    local d, why = ensureDomain(ctx)
    if d == nil then return nil, why end
    local res
    res, why = I.reserveBatch(R.ledger, requestId, { country = ctx.country, farmId = tostring(ctx.herd), items = items })
    if res == nil then return nil, why end
    local persisted
    persisted, why = persistReserved(res.keys)
    if not persisted then return nil, why end
    if not res.replayed and ctx.mirror ~= nil then
        for _, k in ipairs(res.keys) do ctx.mirror(k.raw) end
    end
    return res
end


--- The request's current record (read only), or nil.
function R.requestState(requestId)
    local request = R.ledger ~= nil and R.ledger.requests[requestId] or nil
    if request == nil then return nil end
    local states = {}
    for i, key in ipairs(request.keys) do states[i] = R.ledger.keys[key].state end
    return { keys = request.keys, states = states, selectionDigest = request.selectionDigest }
end


function R.bindFor(requestId, digest)
    if R.ledger == nil then return nil, "NO_LEDGER" end
    return I.bindMaterialization(R.ledger, requestId, digest)
end


--- Every key of the request that is MATERIALIZED becomes CONSUMED (the animals exist now).
function R.consumeAll(requestId)
    local request = R.ledger ~= nil and R.ledger.requests[requestId] or nil
    if request == nil then return nil, "REQUEST_UNKNOWN" end
    for _, key in ipairs(request.keys) do
        local ok, why = I.consume(R.ledger, key)
        if ok == nil then return nil, why end
        journalKey(key)
    end
    afterAllocation()
    return true
end


--- The request failed before any animal existed; its keys stay blocked, burned.
function R.burnFor(requestId, reason)
    if R.ledger == nil then return nil, "NO_LEDGER" end
    local request = R.ledger.requests[requestId]
    if request ~= nil then for _, key in ipairs(request.keys) do journalKey(key) end end
    return I.burn(R.ledger, requestId, reason)
end


-- -------------------------------------------------------------------------------------------
-- Activation (migration)
-- -------------------------------------------------------------------------------------------

--- The migration report for a scan { records, counters } without changing anything.
--- counters = { { country, farmId, type, nextRaw } } (nextRaw = last allocated + 1).
function R.report(scan)
    return I.migrationReport(scan.records, scan.counters, {})
end


-- The scan's live records whose full key the ledger does not hold yet.
local function freshRecords(ledger, records)
    local fresh = {}
    for _, r in ipairs(records) do
        if not (r.farmId ~= nil and r.uniqueId ~= nil and r.country ~= nil and ledger.keys[I.keyString(r.farmId, r.uniqueId, r.country)] ~= nil) then
            fresh[#fresh + 1] = r
        end
    end
    return fresh
end


-- Move every domain in `only` (all when nil) past what the native counters and the live animals show now:
-- the highest counter of any species in the domain (or of its herd, when the herd holds no animal in the
-- scan) and the highest live raw. Everything below is blocked, including raws whose animals are gone.
local function raiseDomains(ledger, report, scan, only)
    for dk, domain in pairs(ledger.domains) do
        if only == nil or only[dk] then
            local d = report.domains[dk]
            local high = (scan.herdNext ~= nil and scan.herdNext[domain.farmId]) or 0
            if d ~= nil then high = math.max(high, d.maxNext or 0, (d.maxLiveRaw or 0) + 1) end
            if high > 1 then assert(I.raiseHighWater(ledger, domain.country, domain.farmId, high)) end
        end
    end
end


local copy=RLPlain.copy


local function checkScan(scan)
    if type(scan) ~= "table" or type(scan.records) ~= "table" or type(scan.counters) ~= "table" then return "BAD_SCAN" end
    if type(scan.partial) == "table" and #scan.partial > 0 then return "SCAN_PARTIAL" end
    local seen = {}
    for _, record in ipairs(scan.records) do
        if record.farmId ~= nil and record.uniqueId ~= nil and record.country ~= nil then
            local key = I.keyString(record.farmId, record.uniqueId, record.country)
            if seen[key] then return "DUPLICATE_IDENTITIES" end
            seen[key] = true
        end
    end
    return nil
end


--- Before a ledger that was out of service (RECOVERY_REQUIRED) hands out keys again: take in every live key
--- the world holds now and move every domain past the native counters, which numbered the animals in the
--- meantime. All or nothing: works on a copy, swaps it in only when the whole scan was read and the result is
--- a valid ledger. Returns true and the report, or nil and why (the ledger unchanged).
function R.reconcile(scan, options)
    if R.ledger == nil then return nil, "NO_LEDGER" end
    if R.authoritative() then return nil, "ALREADY_AUTHORITATIVE" end
    local bad = checkScan(scan)
    if bad ~= nil then return nil, bad end
    local work = copy(R.ledger)
    local report = R.report(scan)
    local ok, err = pcall(function()
        for _, r in ipairs(freshRecords(work, scan.records)) do
            local transient=options and options.excludeTransient==true and R.TRANSIENT_ROLES[r.where]==true
            if not transient and r.country ~= nil and r.farmId ~= nil and r.uniqueId ~= nil and not (tostring(r.farmId) == "1" and tostring(r.uniqueId) == "1") then
                I.importLiveKey(work, r.farmId, r.uniqueId, r.country, "legacy")
            end
        end
        raiseDomains(work, report, scan, nil)
    end)
    if not ok then return nil, "RECONCILE_FAILED:" .. tostring(err) end
    local why = I.validate(work)
    if why ~= nil then return nil, "RECONCILE_INVALID:" .. why end
    R.ledger = work
    R.setLive(scan.records, scan.refs)
    log("info", "IDENTITY: ledger reconciled with the world (%d live record(s))", #scan.records)
    return true, report
end


--- Switch to ON. scan = { records, counters }; options.accept = the user accepts MIGRATION_POINT for
--- every domain whose history cannot be proven. Returns true, or nil and why (with the unproven list).
function R.activate(scan, options)
    options = options or {}
    if not R.server or R.state ~= "READY" then return nil, "NOT_READY:" .. tostring(R.state) end
    if R.mode == R.ON then return nil, "ALREADY_ON" end
    local bad = checkScan(scan)
    if bad ~= nil then
        if bad == "DUPLICATE_IDENTITIES" then R.activationQuarantine = R.report(scan) end
        return nil, bad, nil, R.activationQuarantine
    end
    local ledger = R.ledger
    if ledger == nil then
        if type(R.lineage) ~= "string" then return nil, "NO_LINEAGE" end
        ledger = assert(I.new(R.lineage))
    end
    local report = R.report(scan)
    local unproven = {}
    for dk, d in pairs(report.domains) do
        local known = ledger.domains[dk]
        if d.status ~= I.VERIFIED and not (known ~= nil and known.status == I.VERIFIED) then unproven[#unproven + 1] = dk end
    end
    -- Herds whose counters were used but that hold no animal now have no domain in the scan: they need the
    -- same acceptance, or a later key in that herd would be refused (DOMAIN_UNPROVEN). A herd the ledger
    -- already holds a verified domain of is reconciled below instead.
    local knownHerds = {}
    for _, d in pairs(ledger.domains) do if d.status == I.VERIFIED then knownHerds[d.farmId] = true end end
    for _, herd in ipairs(scan.uncoveredHerds or {}) do
        if ledger.policy.acceptWeak ~= true and not knownHerds[herd:match("^%*/(.+)$") or herd] then unproven[#unproven + 1] = herd end
    end
    table.sort(unproven)
    if #unproven > 0 and options.accept ~= true then return nil, "UNPROVEN_DOMAINS", unproven, report end
    -- Domains the ledger held before (a re-activation after OFF / SHADOW): their keys are not imported again,
    -- but the native counters ran while the ledger was off, so they are reconciled after the import.
    local existing = {}
    for dk in pairs(ledger.domains) do existing[dk] = true end
    I.applyMigration(ledger, report, freshRecords(ledger, scan.records))
    for _, dk in ipairs(unproven) do
        local d = report.domains[dk]
        if d ~= nil and ledger.domains[dk] ~= nil and ledger.domains[dk].status ~= I.VERIFIED then
            local counterMax = 0
            for _, nextRaw in pairs(d.counters) do counterMax = math.max(counterMax, nextRaw) end
            local start = math.max(counterMax, (d.maxLiveRaw or 0) + 1, 1)
            I.promoteDomain(ledger, d.country, d.farmId, math.min(start, I.MAX_RAW + 1), true)
        end
    end
    raiseDomains(ledger, report, scan, existing)
    ledger.policy.mode = R.ON
    ledger.policy.acceptWeak = (options.accept == true or ledger.policy.acceptWeak == true) or nil
    ledger.policy.activatedGeneration = ledger.generation
    R.ledger, R.mode = ledger, R.ON
    R.setLive(scan.records, scan.refs)
    log("info", "IDENTITY: ON - %d live keys imported, %d domain(s) under the MIGRATION_POINT guarantee", #scan.records, #unproven)
    return true, nil, unproven, report
end


--- Back to SHADOW or OFF. The ledger and every key in it stay.
function R.setMode(mode)
    if mode ~= R.OFF and mode ~= R.SHADOW then return nil, "BAD_MODE" end
    if R.ledger ~= nil then R.ledger.policy.mode = mode end
    R.mode = mode
    return true
end


-- -------------------------------------------------------------------------------------------
-- Export for the checkpoint
-- -------------------------------------------------------------------------------------------

--- A copy of the ledger as it must be saved for `generation`, with this session's journal absorbed.
function R.exportLedger(generation)
    local l = R.ledger
    if l == nil then return nil, "NO_LEDGER" end
    l.generation = generation
    return I.export(l)
end


--- Keys handed out since the last complete save (the checkpoint writes them to the journal file).
function R.journalKeys() return R.journal end


function R.clearJournal()
    R.journal, R.journalDirty, R.journalSeen = {}, false, {}
end
