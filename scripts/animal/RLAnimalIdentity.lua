--[[
    Dealer v2 T1: the durable animal identity ledger. Pure data and functions: no game globals, no
    file access, no animal objects. It is NOT wired into any birth, sale, AI or dealer path yet
    (the dealer channel stays closed); T2 connects the entry points and the save participants.

    Why it exists. An animal's full key is (farmId, uniqueId, country) and has no species. The raw
    counters behind it are per species, and RLAnimalUtil.generateUniqueId is not injective: padId
    maps raw 1..9999 to 10001..19999 and raw 10001..19999 to the same strings, raw 0 and 10000 to
    "10000". A counter that only goes up therefore proves nothing about a full key. This ledger asks
    about FULL KEYS: a key that was reserved, materialized, consumed or burned is blocked for ever
    in its lineage, whatever happened to the animal.

    Domain = country + herd (farmId). A domain must be registered with a proof before it hands out
    keys: EXCLUSIVE_NEW (nobody ever used this herd; the caller holds the global registry),
    COUNTER_HISTORY (a native counter that provably never went back: raws 1..next-1 of every
    species are blocked, as full keys), or MIGRATION_POINT (weaker: only keys from the migration
    point on are protected; needs userAccepted = true, never a default). Without a proof the domain
    is LEGACY_HISTORY_UNPROVEN and reserveBatch refuses it.

    Key states: RESERVED -> MATERIALIZED -> CONSUMED, or BURNED. Every state blocks the key; none is
    ever released. Requests are idempotent: the same requestId with the same plan returns the same
    keys, a different plan is refused. A batch is all or nothing and writes nothing on failure.
    Candidate raws run upward from the domain cursor; a candidate whose full key is taken (ledger,
    blocked range, or the caller's isOccupied) is skipped, at most MAX_SKIPS times, and raws never
    exceed MAX_RAW (the number length is NOT extended here; T2 freezes it against the real entries).

    Integrity. export() adds a digest of the canonical text; it detects damage and mixed
    generations, it is not a proof that anything happened and not a security measure.
]]

RLAnimalIdentity = {}
local I = RLAnimalIdentity

I.SCHEMA = 1
I.MAX_RAW = 99999
I.MAX_SKIPS = 2000
I.MAX_BATCH = 1000
I.RESERVED, I.MATERIALIZED, I.CONSUMED, I.BURNED = "RESERVED", "MATERIALIZED", "CONSUMED", "BURNED"
I.VERIFIED, I.UNPROVEN = "VERIFIED", "LEGACY_HISTORY_UNPROVEN"
I.LIMITS = { maxNodes = 1500000, maxString = 262144, maxDepth = 12 }

local states = { RESERVED = true, MATERIALIZED = true, CONSUMED = true, BURNED = true }
local proofs = { EXCLUSIVE_NEW = true, COUNTER_HISTORY = true, MIGRATION_POINT = true }
local roles = { adult = true, fetus = true, birth = true, legacy = true, unsaved = true, ai = true, sale = true, auto = true }
local batchRoles = { adult = true, fetus = true, birth = true, ai = true, sale = true, auto = true }


local function str(v) return type(v) == "string" and #v > 0 and #v <= 256 end
local function int(v) return type(v) == "number" and v == v and v % 1 == 0 and math.abs(v) < 2 ^ 52 end


--- Complete unique id for a raw counter value, through the game's own formatter.
function I.format(farmId, raw)
    return RLAnimalUtil.generateUniqueId(farmId, raw)
end


function I.keyString(farmId, uniqueId, country)
    return tostring(farmId) .. " " .. tostring(uniqueId) .. " " .. tostring(country)
end


--- The fields of a key string "farmId uniqueId country", or nil.
function I.parseKey(key)
    local farmId, uniqueId, country = tostring(key):match("^(%S+) (%S+) (%d+)$")
    if farmId == nil then return nil end
    return farmId, uniqueId, tonumber(country)
end


function I.domainKey(country, farmId) return tostring(country) .. "/" .. tostring(farmId) end


--- Every raw counter value in 0..MAX_RAW whose padded id equals the padded id of `raw`. This mirrors
--- RLAnimalUtil.padId (the tests check it against the real function over the whole range).
function I.preimages(raw)
    local p = raw < 10000 and raw + 10000 or raw
    if raw == 0 then p = 10000 end
    local out = { }
    if p >= 10001 and p <= 19999 then out[#out + 1] = p - 10000 end
    if p == 10000 then out[#out + 1] = 0 end
    if p >= 10000 and p <= I.MAX_RAW then out[#out + 1] = p end
    table.sort(out)
    return out
end


--- The raw values a complete unique id can come from, or nil and why. The id is checksum digit
--- followed by the padded id; a wrong check digit means it was not made by this formatter.
function I.rawsOf(farmId, uniqueId)
    local text = tostring(uniqueId)
    if not text:match("^%d%d%d%d%d%d+$") then return nil, "NOT_GENERATED" end
    local padded = tonumber(text:sub(2))
    if padded == nil or padded > I.MAX_RAW or padded < 10000 then return nil, "OUT_OF_RANGE" end
    local raws = I.preimages(padded)
    if I.format(farmId, raws[1]) ~= text then return nil, "NOT_GENERATED" end
    return raws
end


function I.new(lineage)
    if not str(lineage) then return nil, "BAD_LINEAGE" end
    return { schema = I.SCHEMA, lineage = lineage, generation = 0, writerSequence = 0,
        domains = {}, keys = {}, requests = {}, duplicates = {}, opSequence = 0, policy = {} }
end


local function bump(ledger) ledger.writerSequence = ledger.writerSequence + 1 end


--- Register a domain with its proof. A proof that cannot be accepted leaves the domain UNPROVEN.
--- proof = { kind = "EXCLUSIVE_NEW", startRaw }, { kind = "COUNTER_HISTORY", nextRaw, evidence },
--- { kind = "MIGRATION_POINT", startRaw, userAccepted = true }.
function I.registerDomain(ledger, country, farmId, proof)
    if type(ledger) ~= "table" or not int(country) or not str(tostring(farmId)) then return nil, "BAD_DOMAIN" end
    local dk = I.domainKey(country, farmId)
    if ledger.domains[dk] ~= nil then return nil, "DOMAIN_EXISTS" end
    local domain = { country = country, farmId = tostring(farmId), status = I.UNPROVEN, next = 1, blocked = {}, skipped = 0 }
    if type(proof) == "table" and proofs[proof.kind] then
        if proof.kind == "EXCLUSIVE_NEW" then
            if not int(proof.startRaw) or proof.startRaw < 1 or proof.startRaw > I.MAX_RAW + 1 then return nil, "BAD_PROOF" end
            domain.next = proof.startRaw
        elseif proof.kind == "COUNTER_HISTORY" then
            if not int(proof.nextRaw) or proof.nextRaw < 1 or proof.nextRaw > I.MAX_RAW + 1 or not str(proof.evidence) then
                return nil, "BAD_PROOF"
            end
            domain.next = proof.nextRaw
            if proof.nextRaw > 1 then domain.blocked[1] = { 1, proof.nextRaw - 1 } end
        else
            if proof.userAccepted ~= true then return nil, "WEAK_GUARANTEE_NOT_ACCEPTED" end
            if not int(proof.startRaw) or proof.startRaw < 1 or proof.startRaw > I.MAX_RAW + 1 then return nil, "BAD_PROOF" end
            domain.next = proof.startRaw
        end
        domain.status = I.VERIFIED
        domain.proof = proof.kind
        domain.evidence = proof.evidence
    elseif proof ~= nil then
        return nil, "BAD_PROOF"
    end
    ledger.domains[dk] = domain
    bump(ledger)
    return domain
end


local function inBlocked(domain, raw)
    for _, raws in ipairs(I.preimages(raw)) do
        for _, range in ipairs(domain.blocked) do
            if raws >= range[1] and raws <= range[2] then return true end
        end
    end
    return false
end


--- True when the full key can never be handed out again in this lineage.
function I.isBlocked(ledger, farmId, uniqueId, country)
    return ledger.keys[I.keyString(farmId, uniqueId, country)] ~= nil
end


--- Take an already existing key (an animal in the world, a legacy record) into the ledger as CONSUMED.
--- A repeated live key is recorded as a duplicate and never changes the first record.
function I.importLiveKey(ledger, farmId, uniqueId, country, role)
    if not str(tostring(farmId)) or not str(tostring(uniqueId)) or not int(country) then return nil, "BAD_KEY" end
    local key = I.keyString(farmId, uniqueId, country)
    if ledger.keys[key] ~= nil then
        ledger.duplicates[key] = (ledger.duplicates[key] or 1) + 1
        bump(ledger)
        return key, "DUPLICATE"
    end
    ledger.keys[key] = { state = I.CONSUMED, role = role or "legacy" }
    bump(ledger)
    return key
end


local function fingerprint(plan)
    local parts = { tostring(plan.country), tostring(plan.farmId) }
    for _, item in ipairs(plan.items) do parts[#parts + 1] = item.role .. ":" .. item.type end
    return table.concat(parts, "|")
end


local function result(request, ledger, replayed)
    local out = { requestId = request.id, replayed = replayed, keys = {} }
    for i, key in ipairs(request.keys) do
        local rec = ledger.keys[key]
        local farmId, uniqueId, country = I.parseKey(key)
        out.keys[i] = { key = key, farmId = farmId, uniqueId = uniqueId, country = country,
            raw = rec.raw, role = rec.role, type = rec.type, state = rec.state }
    end
    return out
end


--- Reserve the complete keys for one batch (adults and fixed fetuses together).
--- plan = { country, farmId, items = { { role = "adult"|"fetus", type = "COW" }, ... } }.
--- opts.isOccupied(keyString) lets the caller veto keys it sees in the world.
--- Returns { requestId, replayed, keys } or nil and a reason; on failure the ledger is unchanged.
function I.reserveBatch(ledger, requestId, plan, opts)
    if type(ledger) ~= "table" or not str(requestId) or type(plan) ~= "table" or type(plan.items) ~= "table"
        or not int(plan.country) or not str(tostring(plan.farmId)) then return nil, "BAD_REQUEST" end
    local n = #plan.items
    if n < 1 or n > I.MAX_BATCH then return nil, "BAD_BATCH" end
    for k in pairs(plan.items) do if not int(k) or k < 1 or k > n then return nil, "BAD_BATCH" end end
    for _, item in ipairs(plan.items) do
        if type(item) ~= "table" or not batchRoles[item.role] or not str(item.type) then return nil, "BAD_BATCH" end
    end
    local finger = fingerprint(plan)
    local prior = ledger.requests[requestId]
    if prior ~= nil then
        if prior.fingerprint ~= finger then return nil, "REQUEST_MISMATCH" end
        return result(prior, ledger, true)
    end
    local domain = ledger.domains[I.domainKey(plan.country, plan.farmId)]
    if domain == nil then return nil, "DOMAIN_UNKNOWN" end
    if domain.status ~= I.VERIFIED then return nil, "DOMAIN_UNPROVEN" end

    local isOccupied = opts and opts.isOccupied
    local picked, chosen, raw, skips = {}, {}, domain.next, 0
    while #picked < n do
        if raw > I.MAX_RAW then return nil, "RANGE_EXHAUSTED" end
        local uniqueId = I.format(plan.farmId, raw)
        local key = I.keyString(plan.farmId, uniqueId, plan.country)
        local taken = ledger.keys[key] ~= nil or chosen[key] or inBlocked(domain, raw)
        if not taken and isOccupied ~= nil then
            local ok, veto = pcall(isOccupied, key)
            if not ok then return nil, "OCCUPANCY_CHECK_FAILED" end
            taken = veto == true
        end
        if taken then
            skips = skips + 1
            if skips > I.MAX_SKIPS then return nil, "SKIP_LIMIT" end
        else
            chosen[key] = true
            picked[#picked + 1] = { raw = raw, uniqueId = uniqueId, key = key }
        end
        raw = raw + 1
    end
    local request = { id = requestId, fingerprint = finger, keys = {}, state = I.RESERVED, domain = I.domainKey(plan.country, plan.farmId),
        order = ledger.writerSequence + 1 }
    for i, p in ipairs(picked) do
        local item = plan.items[i]
        ledger.keys[p.key] = { state = I.RESERVED, role = item.role, type = item.type, requestId = requestId, raw = p.raw }
        request.keys[i] = p.key
    end
    domain.next = raw
    domain.skipped = domain.skipped + skips
    ledger.requests[requestId] = request
    bump(ledger)
    return result(request, ledger, false)
end


--- Bind the reservation to the fixed selection (the Factory built exactly these keys). RESERVED ->
--- MATERIALIZED for every key of the request; the same digest again is a no-op, another digest is refused.
function I.bindMaterialization(ledger, requestId, selectionDigest)
    local request = ledger.requests[requestId]
    if request == nil then return nil, "REQUEST_UNKNOWN" end
    if not str(selectionDigest) then return nil, "BAD_DIGEST" end
    if request.selectionDigest ~= nil then
        if request.selectionDigest ~= selectionDigest then return nil, "SELECTION_MISMATCH" end
        return result(request, ledger, true)
    end
    for _, key in ipairs(request.keys) do
        if ledger.keys[key].state ~= I.RESERVED then return nil, "BAD_STATE" end
    end
    for _, key in ipairs(request.keys) do ledger.keys[key].state = I.MATERIALIZED end
    request.selectionDigest = selectionDigest
    request.state = I.MATERIALIZED
    bump(ledger)
    return result(request, ledger, false)
end


--- A materialized key became a real animal (adult admitted, fetus born). MATERIALIZED -> CONSUMED.
function I.consume(ledger, key)
    local rec = ledger.keys[key]
    if rec == nil then return nil, "KEY_UNKNOWN" end
    if rec.state == I.CONSUMED then return true end
    if rec.state ~= I.MATERIALIZED then return nil, "BAD_STATE" end
    rec.state = I.CONSUMED
    bump(ledger)
    return true
end


--- The request failed. Every key that was not consumed is burned; none is released.
function I.burn(ledger, requestId, reason)
    local request = ledger.requests[requestId]
    if request == nil then return nil, "REQUEST_UNKNOWN" end
    local burned = 0
    for _, key in ipairs(request.keys) do
        local rec = ledger.keys[key]
        if rec.state ~= I.CONSUMED and rec.state ~= I.BURNED then rec.state = I.BURNED; burned = burned + 1 end
    end
    request.state = I.BURNED
    request.reason = reason
    bump(ledger)
    return burned
end


--- Keys shown to the player in a session that was not saved: they never come back, but the animals do not either.
function I.burnUnsaved(ledger, keys)
    local added = 0
    for _, k in ipairs(keys) do
        if type(k) ~= "table" or not str(tostring(k.farmId)) or not str(tostring(k.uniqueId)) or not int(k.country) then return nil, "BAD_KEY" end
    end
    for _, k in ipairs(keys) do
        local key = I.keyString(k.farmId, k.uniqueId, k.country)
        if ledger.keys[key] == nil then
            ledger.keys[key] = { state = I.BURNED, role = "unsaved" }
            added = added + 1
        end
    end
    if added > 0 then bump(ledger) end
    return added
end


--- Turn an UNPROVEN domain into a usable one under the weaker MIGRATION_POINT guarantee. The caller
--- states the user accepted it. Live keys must already be in the ledger (applyMigration / importLiveKey).
function I.promoteDomain(ledger, country, farmId, startRaw, userAccepted)
    local domain = ledger.domains[I.domainKey(country, farmId)]
    if domain == nil then return nil, "DOMAIN_UNKNOWN" end
    if userAccepted ~= true then return nil, "WEAK_GUARANTEE_NOT_ACCEPTED" end
    if not int(startRaw) or startRaw < 1 or startRaw > I.MAX_RAW + 1 then return nil, "BAD_PROOF" end
    if domain.status == I.VERIFIED then return domain end
    domain.status, domain.proof, domain.next = I.VERIFIED, "MIGRATION_POINT", math.max(domain.next, startRaw)
    bump(ledger)
    return domain
end


--- While the ledger was not the allocator (OFF, SHADOW, RECOVERY_REQUIRED) the native counters handed out raws
--- it never saw, and those animals may be gone (sold, dead): only the counters remember them. Block raws
--- 1..nextRaw-1 (every full-key preimage, as COUNTER_HISTORY does) and move the cursor to nextRaw. Never lowers
--- anything. Returns the domain and whether it changed, or nil and why.
function I.raiseHighWater(ledger, country, farmId, nextRaw)
    local domain = ledger.domains[I.domainKey(country, farmId)]
    if domain == nil then return nil, "DOMAIN_UNKNOWN" end
    if not int(nextRaw) or nextRaw < 1 then return nil, "BAD_RAW" end
    nextRaw = math.min(nextRaw, I.MAX_RAW + 1)
    local changed = false
    if nextRaw > 1 then
        local head
        for _, range in ipairs(domain.blocked) do if range[1] == 1 then head = range break end end
        if head == nil then
            table.insert(domain.blocked, 1, { 1, nextRaw - 1 })
            changed = true
        elseif head[2] < nextRaw - 1 then
            head[2] = nextRaw - 1
            changed = true
        end
    end
    if domain.next < nextRaw then
        domain.next = nextRaw
        changed = true
    end
    if changed then bump(ledger) end
    return domain, changed
end


--- Burn one key that has not become an animal (a fetus that was lost, a stillborn). A CONSUMED key stays.
--- Returns true, or nil and why. Other keys of the same request are not touched.
function I.burnKey(ledger, key, reason)
    local rec = ledger.keys[key]
    if rec == nil then return nil, "KEY_UNKNOWN" end
    if rec.state == I.CONSUMED then return nil, "BAD_STATE" end
    if rec.state == I.BURNED then return true end
    rec.state = I.BURNED
    rec.reason = reason
    bump(ledger)
    return true
end


--- A new operation number (persisted in the ledger; ids for automatic single-key requests).
function I.nextOp(ledger)
    ledger.opSequence = ledger.opSequence + 1
    return ledger.opSequence
end


--- Drop the request records whose keys are all finished (CONSUMED or BURNED), keeping the newest
--- `keep` finished ones for exact retry. The keys themselves are never dropped: they stay blocked.
--- Returns how many requests were dropped.
function I.compact(ledger, keep)
    keep = keep or 200
    local finished = {}
    for id, request in pairs(ledger.requests) do
        local done = true
        for _, key in ipairs(request.keys) do
            local state = ledger.keys[key].state
            if state ~= I.CONSUMED and state ~= I.BURNED then done = false break end
        end
        if done then finished[#finished + 1] = { id = id, order = request.order or 0 } end
    end
    table.sort(finished, function(a, b) if a.order ~= b.order then return a.order > b.order end return a.id > b.id end)
    local dropped = 0
    for i = keep + 1, #finished do
        local request = ledger.requests[finished[i].id]
        for _, key in ipairs(request.keys) do
            local rec = ledger.keys[key]
            rec.requestId, rec.raw, rec.type = nil, nil, nil
        end
        ledger.requests[finished[i].id] = nil
        dropped = dropped + 1
    end
    if dropped > 0 then bump(ledger) end
    return dropped
end


--- Read-only shadow check for a key the old code just produced: does the ledger already know it?
function I.probeLegacy(ledger, farmId, uniqueId, country)
    local rec = ledger.keys[I.keyString(farmId, uniqueId, country)]
    if rec == nil then return "FREE" end
    return "CONFLICT", rec.state
end


--- What a set of live records and native counters can and cannot prove. Changes nothing.
--- records = { { farmId, uniqueId, country, type } }; counters = { { country, farmId, type, nextRaw } };
--- opts.exclusive[domainKey] = true when the caller's global registry proves the domain never existed;
--- opts.counterNeverRegressed[domainKey] = true when the counter history is proven monotonic.
function I.migrationReport(records, counters, opts)
    opts = opts or {}
    local report = { domains = {}, duplicates = {}, placeholders = {}, foreign = {} }
    local function domainOf(country, farmId)
        local dk = I.domainKey(country, farmId)
        local d = report.domains[dk]
        if d == nil then
            d = { country = country, farmId = tostring(farmId), live = 0, types = {}, reasons = {}, counters = {} }
            report.domains[dk] = d
        end
        return d
    end
    local seen = {}
    for _, r in ipairs(records or {}) do
        if r.country == nil or r.farmId == nil or r.uniqueId == nil or (tostring(r.farmId) == "1" and tostring(r.uniqueId) == "1") then
            report.placeholders[#report.placeholders + 1] = { farmId = r.farmId, uniqueId = r.uniqueId, country = r.country, type = r.type }
        else
            local key = I.keyString(r.farmId, r.uniqueId, r.country)
            local d = domainOf(r.country, r.farmId)
            d.live = d.live + 1
            d.types[r.type or "?"] = true
            if seen[key] ~= nil then
                report.duplicates[key] = report.duplicates[key] or { seen[key] }
                table.insert(report.duplicates[key], r.type or "?")
            else
                seen[key] = r.type or "?"
            end
            local raws, why = I.rawsOf(r.farmId, r.uniqueId)
            if raws == nil then report.foreign[key] = why else d.maxLiveRaw = math.max(d.maxLiveRaw or 0, raws[1]); d.minLiveRaw = math.min(d.minLiveRaw or math.huge, raws[1]) end
        end
    end
    for _, c in ipairs(counters or {}) do
        local d = domainOf(c.country, c.farmId)
        d.counters[c.type] = c.nextRaw
        d.types[c.type] = true
    end
    for dk, d in pairs(report.domains) do
        local nextMax = 0
        local kinds = 0
        for _, nextRaw in pairs(d.counters) do
            nextMax = math.max(nextMax, nextRaw)
            if nextRaw > 1 then kinds = kinds + 1 end
        end
        d.maxNext = nextMax
        if next(d.counters) == nil and d.live > 0 then d.reasons[#d.reasons + 1] = "COUNTER_MISSING" end
        -- A live key above every counter: a counter went back, or the key came from somewhere else.
        local contradicted = d.maxLiveRaw ~= nil and next(d.counters) ~= nil and d.maxLiveRaw > nextMax - 1
        if contradicted then d.reasons[#d.reasons + 1] = "COUNTER_BELOW_LIVE" end
        if kinds > 1 then d.reasons[#d.reasons + 1] = "SHARED_RAW_ACROSS_SPECIES" end
        if opts.exclusive and opts.exclusive[dk] and d.live == 0 and nextMax == 0 then
            d.status, d.proof = I.VERIFIED, { kind = "EXCLUSIVE_NEW", startRaw = 1 }
        elseif opts.counterNeverRegressed and opts.counterNeverRegressed[dk] and nextMax >= 1 and not contradicted then
            d.status, d.proof = I.VERIFIED, { kind = "COUNTER_HISTORY", nextRaw = nextMax, evidence = "counter monotonic (caller evidence)" }
        else
            d.status = I.UNPROVEN
            d.reasons[#d.reasons + 1] = "HISTORY_UNPROVEN"
        end
    end
    return report
end


--- Put a migration report into a ledger: live keys as CONSUMED, proven domains registered, the rest UNPROVEN.
function I.applyMigration(ledger, report, records)
    for _, r in ipairs(records or {}) do
        if r.country ~= nil and r.farmId ~= nil and r.uniqueId ~= nil and not (tostring(r.farmId) == "1" and tostring(r.uniqueId) == "1") then
            I.importLiveKey(ledger, r.farmId, r.uniqueId, r.country, "legacy")
        end
    end
    for dk, d in pairs(report.domains) do
        if ledger.domains[dk] == nil then
            I.registerDomain(ledger, d.country, d.farmId, d.status == I.VERIFIED and d.proof or nil)
        end
    end
    return ledger
end


--- Structural check of a ledger table. Returns nil or why not.
function I.validate(ledger)
    if type(ledger) ~= "table" or ledger.schema ~= I.SCHEMA or not str(ledger.lineage) then return "BAD_SCHEMA" end
    if not int(ledger.generation) or not int(ledger.writerSequence) or ledger.writerSequence < 0 then return "BAD_COUNTERS" end
    if not int(ledger.opSequence) or ledger.opSequence < 0 or type(ledger.policy) ~= "table" then return "BAD_COUNTERS" end
    for dk, d in pairs(ledger.domains or {}) do
        if type(d) ~= "table" or dk ~= I.domainKey(d.country, d.farmId) then return "BAD_DOMAIN:" .. tostring(dk) end
        if d.status ~= I.VERIFIED and d.status ~= I.UNPROVEN then return "BAD_DOMAIN_STATUS:" .. dk end
        if not int(d.next) or d.next < 1 or d.next > I.MAX_RAW + 1 then return "BAD_CURSOR:" .. dk end
    end
    local owners = {}
    for key, rec in pairs(ledger.keys or {}) do
        if type(rec) ~= "table" or not states[rec.state] or not roles[rec.role] then return "BAD_KEY:" .. tostring(key) end
        if I.parseKey(key) == nil then return "KEY_MISMATCH:" .. tostring(key) end
        if rec.requestId ~= nil then
            local request = ledger.requests and ledger.requests[rec.requestId]
            if request == nil then return "KEY_WITHOUT_REQUEST:" .. key end
            owners[key] = rec.requestId
        end
    end
    for id, request in pairs(ledger.requests or {}) do
        if type(request) ~= "table" or request.id ~= id or not str(request.fingerprint) or type(request.keys) ~= "table" or #request.keys < 1 then
            return "BAD_REQUEST:" .. tostring(id)
        end
        for _, key in ipairs(request.keys) do
            if owners[key] ~= id then return "REQUEST_KEY_MISMATCH:" .. tostring(id) end
            owners[key] = nil
        end
    end
    if next(owners) ~= nil then return "ORPHAN_KEY" end
    return nil
end


local function digestOf(ledger)
    local copy = {}
    for k, v in pairs(ledger) do if k ~= "digest" then copy[k] = v end end
    return RLTradePersistence.checksum(RLTradePersistence.canonical(copy))
end


--- The ledger as plain data with its digest, or nil and why. The caller persists it (T2).
function I.export(ledger)
    local why = I.validate(ledger)
    if why then return nil, why end
    why = RLTradePersistence.check(ledger, I.LIMITS)
    if why then return nil, why end
    local function copy(v)
        if type(v) ~= "table" then return v end
        local out = {}
        for k, x in pairs(v) do out[k] = copy(x) end
        return out
    end
    local out = copy(ledger)
    out.digest = digestOf(out)
    return out
end


--- Accept a decoded document only when its digest and structure hold.
function I.import(data)
    if type(data) ~= "table" then return nil, "NOT_A_TABLE" end
    if RLTradePersistence.check(data, I.LIMITS) then return nil, "BAD_DATA" end
    if data.digest ~= digestOf(data) then return nil, "DIGEST_MISMATCH" end
    local why = I.validate(data)
    if why then return nil, why end
    local ledger = {}
    for k, v in pairs(data) do if k ~= "digest" then ledger[k] = v end end
    ledger.duplicates = ledger.duplicates or {}
    return ledger
end
