--[[
    Dealer v2 T3: one stock animal from nothing to a LISTED, owned source.

        PLANNED     RLDealerPlanner.plan on the job's own stream (selection is plain data)
        REPLAYING   RLDealerReplay.evaluate (detached, no RNG) -> VERIFIED_CANDIDATE or a named rejection
        IDS_DURABLE keys of the adult, the fixed fetuses and the sire reserved in the identity ledger as one
                    batch (R.reserveFor); a rejection after this burns them, never releases them
        MATERIALIZED bound to the digest of selection + prepared (R.bindFor)
        ADMITTED    RLDealerOwnedAdmission.admit (factory, whole-stock check, synchronous barrier, listing)
        PUBLISHED   the keys CONSUMED (R.consumeAll)

    A job is in memory only: it runs inside one scheduler call (no frame boundary, so no save can fall in
    the middle), and what it needs to survive - the reserved keys, the listing, the admission proof - is
    already in the ledger and the store. A job lost to a crash leaves reserved keys (blocked for ever) and
    no animal. Replay is the slow stage; scheduler budgets decide how many jobs a frame may run.

    `ctx` carries the capabilities the admission needs (resolveSubType, checkGlobalIdentities,
    persistBarrier, ...) plus ctx.identity, the port to the ledger:
        reserve(farmInfo, requestId, items) -> { keys = { {key, uniqueId, farmId, country, raw, ...} } } | nil, why
        bind(requestId, digest) -> ok | nil, why;  consume(requestId);  burn(requestId, reason)
    RLDealerGeneration.ledgerPort(farmLookup) builds it on RLAnimalIdentityRuntime.
]]

RLDealerGeneration = { VERSION = 1, MAX_ATTEMPTS = 8, OWNER_CAPACITY = 8 }
local G = RLDealerGeneration

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end


--- The identity port over the running ledger. `farmOf(countryIndex, farmId)` returns the country farm table.
function G.ledgerPort(farmOf)
    local R = RLAnimalIdentityRuntime
    return {
        authoritative = function() return R.authoritative() end,
        nextJobId = function() return "G" .. RLAnimalIdentity.nextOp(R.ledger) end,
        reserve = function(info, requestId, items)
            local farm = farmOf(info.countryIndex, info.farmId)
            if farm == nil then return nil, "NO_FARM" end
            local ctx = RLAnimalIdentityWorld.systemContextForFarm("dealer-v2", info.countryIndex, farm, info.typeIndex, "adult")
            return R.reserveFor(ctx, requestId, items)
        end,
        bind = function(requestId, digest) return R.bindFor(requestId, digest) end,
        consume = function(requestId) return R.consumeAll(requestId) end,
        burn = function(requestId, reason) return R.burnFor(requestId, reason) end,
    }
end


local function birthday(now, ageMonths, countryIndex, rng)
    local month, year = RLCalendar.subtractMonths(now.month, now.year, ageMonths)
    return { day = rng.random(1, RLConstants.DAYS_PER_MONTH[month]), month = month, year = year, country = countryIndex,
        lastAgeMonth = now.month }
end


local function dueDate(now, remainingMonths, rng)
    local month, year = now.month + remainingMonths, now.year
    while month > 12 do month, year = month - 12, year + 1 end
    return { day = rng.random(1, RLConstants.DAYS_PER_MONTH[month]), month = month, year = year }
end


--- The factory's `prepared` for a selection and its reserved keys. Draws only from `rng` (birthday days).
function G.prepare(selection, keys, requestId, jobId, now, rng)
    local adultKey = keys[1]
    local prepared = {
        version = 1, requestId = requestId, sourceOwnerId = "own-" .. requestId, capacity = G.OWNER_CAPACITY,
        adult = { uniqueId = adultKey.uniqueId, farmId = adultKey.farmId, subType = selection.subType,
            birthday = birthday(now, selection.ageMonths, selection.farm.countryIndex, rng), deathEnabled = true, diseases = {} },
        evidence = { version = 1, requestId = requestId, selectionId = jobId },
    }
    if selection.name ~= nil then prepared.adult.name = selection.name end
    if selection.fetuses ~= nil then
        local fetuses = {}
        for i, f in ipairs(selection.fetuses) do
            local k = keys[1 + i]
            fetuses[i] = { uniqueId = k.uniqueId, farmId = adultKey.farmId, subType = f.subType, genetics = copy(f.genetics) }
        end
        local sireKey = keys[#keys]
        prepared.pregnancy = { duration = selection.pregnancy.duration,
            expected = dueDate(now, selection.pregnancy.duration - selection.pregnancy.progressMonths, rng), fetuses = fetuses }
        prepared.sire = { uniqueId = sireKey.uniqueId, farmId = sireKey.farmId, breed = selection.sire.breed,
            subType = selection.sire.subType, genetics = copy(selection.sire.genetics) }
    end
    return prepared
end


--- One attempt. Returns the listing row, or nil and a reason (the slot stays empty for this attempt).
--- `world` as RLDealerPlanner; `store` the owned stock; `attempt` 1..MAX_ATTEMPTS.
function G.attempt(store, world, ctx, jobId, attempt)
    local port = ctx.identity
    if port == nil or not port.authoritative() then return nil, "IDENTITY_NOT_AUTHORITATIVE" end
    local label = jobId .. ":" .. attempt
    local rng = RLDealerRng.new(label)

    local selection, why = RLDealerPlanner.plan(world, rng)
    if selection == nil then return nil, why end
    local built
    built, why = RLDealerPlanner.build(selection, world)
    if built == nil then return nil, why end
    local candidate, failure = RLDealerReplay.evaluate(built.seed, built.history, built.entry, built.purpose, built.context, built.options)
    if candidate == nil then return nil, "REPLAY:" .. tostring(failure and failure.reason) end

    -- Identity: adult, then each fetus, then the sire, in one batch.
    local items = { { role = "adult", type = selection.typeName } }
    for _ = 1, #(selection.fetuses or {}) do items[#items + 1] = { role = "fetus", type = selection.typeName } end
    if selection.sire ~= nil then items[#items + 1] = { role = "ai", type = selection.typeName } end
    local requestId = label
    local info = { countryIndex = selection.farm.countryIndex, farmId = selection.farm.farmId, typeIndex = world.typeIndex }
    local reserved
    reserved, why = port.reserve(info, requestId, items)
    if reserved == nil then return nil, "IDENTITY:" .. tostring(why) end

    local prepared = G.prepare(selection, reserved.keys, requestId, jobId, world.now, rng)
    local digest = RLTradePersistence.checksum(RLTradePersistence.canonical({ selection = selection, prepared = prepared }))
    local bound
    bound, why = port.bind(requestId, digest)
    if bound == nil then port.burn(requestId, "BIND:" .. tostring(why)); return nil, "IDENTITY_BIND:" .. tostring(why) end

    local sourceId = "S" .. label
    local row
    row, why = RLDealerOwnedAdmission.admit(store, sourceId, candidate, prepared, ctx)
    if row == nil then
        -- Admission rejected or held: nothing was published; the keys are spent either way.
        port.burn(requestId, "ADMIT:" .. tostring(why))
        return nil, "ADMIT:" .. tostring(why)
    end
    local consumed
    consumed, why = port.consume(requestId)
    if consumed == nil then
        -- The animal is admitted and listed: the place IS filled. The keys stay MATERIALIZED (blocked); say so loudly.
        if Log ~= nil then Log:error("RLDealerGeneration: %s listed but its keys could not be consumed (%s)", requestId, tostring(why)) end
    end
    return row, nil, selection
end


--- Fill one empty place: up to MAX_ATTEMPTS attempts, each with its own stream. The place stays empty
--- when none works; the next restock checkpoint tries again with a new job id.
function G.fillPlace(store, world, ctx)
    local jobId = ctx.identity.nextJobId()
    local reasons = {}
    for attempt = 1, G.MAX_ATTEMPTS do
        local row, why, selection = G.attempt(store, world, ctx, jobId, attempt)
        if row ~= nil then return row, nil, { jobId = jobId, attempt = attempt, selection = selection } end
        reasons[#reasons + 1] = why
        -- A held store stops everything: retrying cannot help and must not spend more keys.
        if store.recoveryRequired or why == "IDENTITY_NOT_AUTHORITATIVE" then break end
    end
    return nil, "EMPTY:" .. tostring(reasons[#reasons]), { jobId = jobId, reasons = reasons }
end
