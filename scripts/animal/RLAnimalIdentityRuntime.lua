--[[
    Dealer v2 T2c: the identity ledger in the running game. The seven places that used to take the next
    raw counter value (player births, setUniqueId, Animal.new, the trailer rideable conversion, the old
    dealer's sale animals, sale births, legacy AI bulls) call R.raw(ctx, legacyFn) instead of their own
    counter. One switch decides for all of them, never a mix:

        OFF     legacyFn() runs, nothing else.
        SHADOW  legacyFn() runs and its full key is only compared with the keys known to exist
                (the world at load, plus everything seen since): collisions are counted and logged.
                The default. It changes no animal, counter, RNG or file.
        ON      the ledger (RLAnimalIdentity) hands out the key; legacyFn is NOT called; the native
                counter is moved up to the raw value (mirror) so old tools still see a high-water mark.

    ON is entered only by R.activate (console rlIdentityActivate), on a READY server, after the world
    scan: every live key is imported as CONSUMED, every domain is registered. A domain whose counter
    history cannot be proven needs the user to accept the weaker MIGRATION_POINT guarantee
    (activate with accept); without it activation is refused and the domains are listed.

    Births. A birth cannot be refused halfway, so R.beginBirth runs before the engine touches the
    pregnancy: it reserves one key per fetus for this birth event (idempotent per event id, so a held
    birth retried the next day gets the same keys) and answers false when it cannot. A false answer
    leaves the mother pregnant with every field as it was - no RNG, no parity change, no placeholder
    newborn; the pregnancy itself is the saved intent. Children take their keys from the litter in order
    (R.raw with ctx.litter); R.endBirth burns the keys of dead or unborn children.

    Unsaved session. Every key handed out is appended to a journal list that the checkpoint writes
    beside the save; on a load of the same generation those keys are burned (they were shown to the
    player in a session that was not saved). The animals are not restored.
]]

RLAnimalIdentityRuntime = {}
local R = RLAnimalIdentityRuntime
local I = RLAnimalIdentity

R.OFF, R.SHADOW, R.ON = "OFF", "SHADOW", "ON"
R.MAX_SHADOW_LINES = 40
R.COMPACT_EVERY = 500

local function log(level, fmt, ...)
    if Log ~= nil and Log[level] ~= nil then Log[level](Log, fmt, ...) end
end


function R.reset(isServer)
    R.server = isServer == true
    R.state = R.server and "LOADING" or "DISABLED"
    R.reason = R.server and "WAITING_FOR_MISSION" or "CLIENT"
    R.ledger, R.mode, R.lineage = nil, R.SHADOW, nil
    R.litters, R.current = {}, nil
    R.journal, R.journalSent = {}, 0
    R.live = nil
    R.shadow = { observed = 0, collisions = 0, byEntry = {}, lines = 0, seen = {} }
    R.held = {}
    R.allocations = 0
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

--- Remember the world's keys (from R.scan) as the shadow reference.
function R.setLive(records)
    local live, herds = {}, {}
    for _, r in ipairs(records or {}) do
        if r.farmId ~= nil and r.uniqueId ~= nil and r.country ~= nil then
            live[liveKey(r.farmId, r.uniqueId, r.country)] = r.type or "?"
            local hk = I.domainKey(r.country, r.farmId)
            herds[hk] = (herds[hk] or 0) + 1
        end
    end
    R.live = { keys = live, herds = herds }
end


local function observe(ctx, raw)
    local sh = R.shadow
    sh.observed = sh.observed + 1
    sh.byEntry[ctx.entry or "?"] = (sh.byEntry[ctx.entry or "?"] or 0) + 1
    if ctx.country == nil or ctx.herd == nil or raw == nil then return end
    local key = liveKey(ctx.herd, I.format(ctx.herd, raw), ctx.country)
    local known = (R.live ~= nil and R.live.keys[key]) or sh.seen[key]
    if known then
        sh.collisions = sh.collisions + 1
        if sh.lines < R.MAX_SHADOW_LINES then
            sh.lines = sh.lines + 1
            log("warning", "IDENTITY_SHADOW: %s produced %s which already exists (%s, entry type %s)", tostring(ctx.entry), key, tostring(known), tostring(ctx.typeKey))
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
    R.journal[#R.journal + 1] = key
    R.journalDirty = true
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
    res, why = I.reserveBatch(l, requestId, plan)
    if res == nil then return nil, why end
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
    if not R.server or R.state ~= "READY" or R.mode == R.OFF then return legacyFn() end
    if R.mode == R.ON and R.ledger == nil then return legacyFn() end
    if R.mode ~= R.ON then
        local raw = legacyFn()
        local ok, err = pcall(observe, ctx, raw)
        if not ok then log("warning", "IDENTITY_SHADOW failed: %s", tostring(err)) end
        return raw
    end
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
        res, why = I.reserveBatch(l, requestId, { country = ctx.country, farmId = tostring(ctx.herd), items = items })
        if res == nil then return nil, why end
        local untouched = true
        for _, k in ipairs(res.keys) do if k.state ~= I.RESERVED and k.state ~= I.MATERIALIZED then untouched = false end end
        if untouched then
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
    if not R.authoritative() then return true end
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
    local d, why = ensureDomain(ctx)
    if d == nil then return nil, why end
    local res
    res, why = I.reserveBatch(R.ledger, requestId, { country = ctx.country, farmId = tostring(ctx.herd), items = items })
    if res == nil then return nil, why end
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


--- Switch to ON. scan = { records, counters }; options.accept = the user accepts MIGRATION_POINT for
--- every domain whose history cannot be proven. Returns true, or nil and why (with the unproven list).
function R.activate(scan, options)
    options = options or {}
    if not R.server or R.state ~= "READY" then return nil, "NOT_READY:" .. tostring(R.state) end
    if R.mode == R.ON then return nil, "ALREADY_ON" end
    if type(scan) ~= "table" or type(scan.records) ~= "table" or type(scan.counters) ~= "table" then return nil, "BAD_SCAN" end
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
    -- same acceptance, or a later key in that herd would be refused (DOMAIN_UNPROVEN).
    for _, herd in ipairs(scan.uncoveredHerds or {}) do
        if ledger.policy.acceptWeak ~= true then unproven[#unproven + 1] = herd end
    end
    table.sort(unproven)
    if #unproven > 0 and options.accept ~= true then return nil, "UNPROVEN_DOMAINS", unproven, report end
    -- Keys the ledger already holds (a re-activation after OFF / SHADOW) are not imported again.
    local fresh = {}
    for _, r in ipairs(scan.records) do
        if r.farmId ~= nil and r.uniqueId ~= nil and r.country ~= nil and ledger.keys[I.keyString(r.farmId, r.uniqueId, r.country)] ~= nil then
            -- already known
        else
            fresh[#fresh + 1] = r
        end
    end
    I.applyMigration(ledger, report, fresh)
    for _, dk in ipairs(unproven) do
        local d = report.domains[dk]
        if d ~= nil and ledger.domains[dk] ~= nil and ledger.domains[dk].status ~= I.VERIFIED then
            local counterMax = 0
            for _, nextRaw in pairs(d.counters) do counterMax = math.max(counterMax, nextRaw) end
            local start = math.max(counterMax, (d.maxLiveRaw or 0) + 1, 1)
            I.promoteDomain(ledger, d.country, d.farmId, math.min(start, I.MAX_RAW + 1), true)
        end
    end
    ledger.policy.mode = R.ON
    ledger.policy.acceptWeak = (options.accept == true or ledger.policy.acceptWeak == true) or nil
    ledger.policy.activatedGeneration = ledger.generation
    R.ledger, R.mode = ledger, R.ON
    R.setLive(scan.records)
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
    R.journal, R.journalDirty = {}, false
end
