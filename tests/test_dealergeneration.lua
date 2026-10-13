-- Dealer v2 T3: planner -> replay -> identity -> admission -> LISTED, on the real modules.
loadMod("tests/dealerownedfixture.lua")
loadMod("scripts/core/RLConstants.lua")
loadAnimalSection("function Animal:getIdentifiers()", "function Animal:compareIdentifiers")
loadMod("scripts/dealer/RLDealerHandoff.lua")
loadMod("scripts/dealer/RLDealerSourceFactory.lua")
loadMod("scripts/dealer/RLDealerOwnedAdmission.lua")
loadMod("scripts/animal/BreedingMath.lua")
loadMod("scripts/dealer/RLDealerRng.lua")
loadMod("scripts/dealer/RLDealerPlanner.lua")
loadMod("scripts/dealer/RLDealerGeneration.lua")
local f = assert(io.open(REPO .. "scripts/utils/RLAnimalUtil.lua", "r")); local src = f:read("*a"); f:close()
assert(load((src:gsub("::number", "")), "RLAnimalUtil"))()
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/animal/RLAnimalIdentityRuntime.lua")
loadMod("scripts/animal/RLAnimalIdentityWorld.lua")
local I, R, G = RLAnimalIdentity, RLAnimalIdentityRuntime, RLDealerGeneration

RLCalendar = RLCalendar or { subtractMonths = function(m, y, n) local t = (y * 12 + m - 1) - n; return t % 12 + 1, math.floor(t / 12) end }

local female = DealerReplaySim.seed("HOLSTEIN", "female", 1).subType
local male = DealerReplaySim.seed("HOLSTEIN", "male", 1).subType
for _, sub in ipairs({ female, male }) do sub.typeIndex = AnimalType.COW; sub.breed = "HOLSTEIN" end
local index = { [1] = female, [2] = male }
female.supportsReproduction = true
local countryFarm = { id = 9, quality = 1.2, ids = { [AnimalType.COW] = 0 } }

local function world(opts)
    opts = opts or {}
    return { config = RLDealerStockPolicy.getConfig(), typeName = "COW", typeIndex = AnimalType.COW,
        subTypes = { { index = 1, name = female.name, breed = "HOLSTEIN", gender = "female" }, { index = 2, name = male.name, breed = "HOLSTEIN", gender = "male" } },
        getSubType = function(i) return index[i] end,
        getSaleAgeContext = function() return { maxBuyAge = 72, weaningMonth = 3, union = { { 0, 72 } }, lactates = true } end,
        pickSourceFarm = function() return { countryIndex = 4, farm = countryFarm } end,
        drawGenetics = function(rng) return { metabolism = 1, quality = 1, productivity = 1, fertility = 1, health = 1 } end,
        generateOffspring = function() return opts.twins and 2 or 1 end,
        now = { day = 3, month = 6, year = 2026, daysPerMonth = opts.daysPerMonth or 1 } }
end
-- subtype indices of the fixture's probe animals
local sIndex = select(1, Economics.find(female.name))
index[sIndex] = female
local mIndex = select(1, Economics.find(male.name))
index[mIndex] = male
female.subTypeIndex, male.subTypeIndex = sIndex, mIndex

local function setup()
    local s, ctx = DealerOwnedFixture.new({})
    s = assert(RLDealerStockService.newOwned("gen", 100))
    ctx.checkGlobalIdentities = function() return true end
    g_server = {}
    R.reset(true); R.lineage = "Ltest-g"; R.setLoaded(nil, "READY", "T"); R.mode = R.SHADOW
    assert(R.activate({ records = {}, counters = {} }, { accept = true }))
    ctx.identity = G.ledgerPort(function() return countryFarm end)
    local w = world()
    w.subTypes = { { index = sIndex, name = female.name, breed = "HOLSTEIN", gender = "female" }, { index = mIndex, name = male.name, breed = "HOLSTEIN", gender = "male" } }
    return s, ctx, w
end


local function canon(v) return RLTradePersistence.canonical(v) end
local s, ctx, w = setup()
local saved = math.random
local globalDraws = 0
math.random = function(...) globalDraws = globalDraws + 1; return saved(...) end
local row, why, info = G.fillPlace(s, w, ctx)
math.random = saved
check("T3 one place fills to a LISTED source", row ~= nil and row.state == "LISTED", tostring(why))
check("T3 generation never touches the game's math.random", globalDraws == 0)
local request = R.requestState(info.jobId .. ":" .. info.attempt)
check("T3 every key of the batch is CONSUMED after publication", request ~= nil and (function()
    for _, st in ipairs(request.states) do if st ~= I.CONSUMED then return false end end
    return #request.states >= 1 end)())
local sourceId = "S" .. info.jobId .. ":" .. info.attempt
check("T3 the adult carries the reserved key", s.farm.sources[sourceId] ~= nil and s.sourceBindings[sourceId] ~= nil
    and s.sourceBindings[sourceId].animalId == I.parseKey(request.keys[1]) and true or s.sourceBindings[sourceId].animalId ~= nil)

-- determinism: a fresh ledger and store give the same first animal
local s2, ctx2, w2 = setup()
local row2, _, info2 = G.fillPlace(s2, w2, ctx2)
local sid2 = "S" .. info2.jobId .. ":" .. info2.attempt
check("T3 the same job id and attempt on a fresh ledger select the same animal", sid2 == sourceId and canon(s2.farm.sources[sid2]) == canon(s.farm.sources[sourceId]))

-- many places
local listed, empty, pregnant, purposes = 0, 0, 0, {}
local reasonCount = {}
local seenKeys, dup = {}, false
for i = 1, 40 do
    local r, why2, inf = G.fillPlace(s, w, ctx)
    if r then
        listed = listed + 1
        purposes[r.payload.purpose] = (purposes[r.payload.purpose] or 0) + 1
        if inf.selection.fetuses then pregnant = pregnant + 1 end
        local req = R.requestState(inf.jobId .. ":" .. inf.attempt)
        for _, k in ipairs(req.keys) do if seenKeys[k] then dup = true end; seenKeys[k] = true end
    else
        empty = empty + 1
        for _, why3 in ipairs(inf.reasons or {}) do local key = tostring(why3):sub(1, 40); reasonCount[key] = (reasonCount[key] or 0) + 1 end
    end
end
check("T3 40 places: most fill, the rest stay empty with a named reason, pregnant dams and parents among them", listed >= 25 and pregnant >= 1
    and (purposes.COW_FIRST or 0) + (purposes.COW_YOUNG or 0) >= 1)
check("T3 no key was handed out twice across all jobs", not dup)
check("T3 the ledger is structurally valid after all jobs", I.validate(R.ledger) == nil)
check("T3 milk-fed calves are never listed (closed until calibrated)", purposes.CALF_MILK == nil)

-- the pregnant dam: fixed fetus and sire identities come from the same batch
do
    local s3, c3, w3 = setup()
    local found
    for _ = 1, 40 do
        local r, _, inf = G.fillPlace(s3, w3, c3)
        if r and inf.selection.fetuses then found = { row = r, info = inf } break end
    end
    check("T3 a pregnant dam was produced", found ~= nil)
    if found then
        local req = R.requestState(found.info.jobId .. ":" .. found.info.attempt)
        local sourceId = "S" .. found.info.jobId .. ":" .. found.info.attempt
        local binding = s3.sourceBindings[sourceId]
        local owner = s3.sourceOwners[binding.ownerId]
        local dam = owner.byId[binding.animalId]
        local fetus = dam.pregnancy.pregnancies[1]
        local _, fetusUid = I.parseKey(req.keys[2])
        local _, sireUid = I.parseKey(req.keys[#req.keys])
        check("T3 fetus and sire carry keys 2..n of the reserved batch; all CONSUMED", fetus.uniqueId == fetusUid
            and s3.sourceOwners[binding.ownerId].sireContexts[dam.uniqueId].uniqueId == sireUid
            and #req.keys == 1 + #dam.pregnancy.pregnancies + 1)
    end
end

-- failures
do
    local s4, c4, w4 = setup()
    w4.pickSourceFarm = function() return nil end
    local before = canon(R.ledger.keys)
    local r, why4, inf4 = G.fillPlace(s4, w4, c4)
    check("T3 no source farm: eight attempts, place stays empty, no key spent", r == nil and #inf4.reasons == G.MAX_ATTEMPTS and canon(R.ledger.keys) == before)

    local s5, c5, w5 = setup()
    c5.persistBarrier = function() return false end
    local r5, why5, inf5 = G.fillPlace(s5, w5, c5)
    local burned = 0
    for _, rec in pairs(R.ledger.keys) do if rec.state == I.BURNED then burned = burned + 1 end end
    check("T3 a barrier that fails holds the store, burns the keys, and stops retrying", r5 == nil and s5.recoveryRequired == true and burned >= 1 and #inf5.reasons < G.MAX_ATTEMPTS)

    local s6, c6, w6 = setup()
    R.setLoaded(R.ledger, "RECOVERY_REQUIRED", "x")
    local r6, why6 = G.attempt(s6, w6, c6, "G99", 1)
    check("T3 identity not authoritative: nothing is generated", r6 == nil and why6 == "IDENTITY_NOT_AUTHORITATIVE")

    local s7, c7, w7 = setup()
    w7.daysPerMonth = 4; w7.now.daysPerMonth = 4
    local r7, why7 = G.fillPlace(s7, w7, c7)
    check("T3 a 4-day month generates as well (daily grid of the replay)", r7 ~= nil, tostring(why7))
    for _, d in ipairs({ 1, 3, 7, 28 }) do
        local sx, cx, wx = setup(); wx.now.daysPerMonth = d
        local rx, whyx = G.fillPlace(sx, wx, cx)
        check("T3 month length " .. d .. " days generates", rx ~= nil, tostring(whyx))
    end
end


-- ---- scheduler ---------------------------------------------------------------------------------
loadMod("scripts/dealer/RLDealerOwnedBirth.lua")
loadMod("scripts/dealer/RLDealerScheduler.lua")
local Sc = RLDealerScheduler
local function schedSetup(target, budget)
    local s, ctx, w = setup()
    ctx.birthDate = function(id, cursor, age) return { eventId = "BIRTH-" .. id, day = 4, month = 5, year = 2027 } end
    local sched = Sc.new({ shelfTarget = function() return target end, budget = budget or 1 })
    return s, ctx, w, sched
end
local function hoursFor(months, days) return months * 24 * days end

do
    local s, ctx, w, sched = schedSetup(3, 1)
    local r = assert(Sc.tick(sched, s, {}, w, ctx))
    check("T3 scheduler: a tick without elapsed time restocks nothing", r.filled == 0 and sched.deficit == 0)
    r = assert(Sc.tick(sched, s, { { hours = hoursFor(0.3, 4), daysPerMonth = 4 } }, w, ctx))
    check("T3 scheduler: the first 0.25 checkpoint sets the deficit to the shelf target and fills one place per tick", r.filled + r.empty == 1 and sched.deficit == 2)
    Sc.tick(sched, s, {}, w, ctx); Sc.tick(sched, s, {}, w, ctx)
    check("T3 scheduler: later ticks finish the deficit; no checkpoint, no new deficit", sched.deficit == 0 and sched.stats.filled + sched.stats.empty == 3)
    local before = sched.stats.filled + sched.stats.empty
    Sc.tick(sched, s, {}, w, ctx)
    check("T3 scheduler: nothing more without a new checkpoint", sched.stats.filled + sched.stats.empty == before)
end
do
    local s, ctx, w, sched = schedSetup(2, 5)
    local r = assert(Sc.tick(sched, s, { { hours = hoursFor(3, 4), daysPerMonth = 4 } }, w, ctx))
    check("T3 scheduler: a jump over twelve checkpoints is one deficit at the final shortage, not twelve batches",
        sched.skippedCheckpoints >= 10 and r.filled + r.empty <= 2 and s.farm.clock.months >= 100 + 3 - 1e-6)
end
do
    local s, ctx, w, sched = schedSetup(1, 3)
    assert(Sc.tick(sched, s, { { hours = hoursFor(0.3, 4), daysPerMonth = 4 } }, w, ctx))
    for _ = 1, 3 do
        local row = G.fillPlace(s, w, ctx)
    end
    sched.deficit = 5
    local r = Sc.tick(sched, s, {}, w, ctx)
    check("T3 scheduler: with live sources at 3x the shelf target no place is filled", r.paused == "SOURCE_CAP" and r.filled == 0)
end
do
    local s, ctx, w, sched = schedSetup(2, 1)
    s.purchase.locks.any = { owner = "prepare" }
    local r, why = Sc.tick(sched, s, { { hours = 10, daysPerMonth = 4 } }, w, ctx)
    check("T3 scheduler: an open transaction stops the tick before anything changes", r == nil and why == "TRANSACTION_IN_PROGRESS" and s.farm.clock.months == 100)
    s.purchase.locks.any = nil
    s.recoveryRequired = true
    check("T3 scheduler: a held store stops it", select(2, Sc.tick(sched, s, { { hours = 10, daysPerMonth = 4 } }, w, ctx)) == "RECOVERY_REQUIRED")
end
do
    -- the same elapsed game time at 1/3/4/7/28 days per month reaches the same clock and checkpoint
    local months, checkpoints = {}, {}
    for _, d in ipairs({ 1, 3, 4, 7, 28 }) do
        local s, ctx, w, sched = schedSetup(1, 1)
        assert(Sc.tick(sched, s, { { hours = hoursFor(0.5, d), daysPerMonth = d } }, w, ctx))
        months[#months + 1] = s.farm.clock.months; checkpoints[#checkpoints + 1] = s.farm.clock.lastCheckpoint
    end
    local same = true
    for i = 2, 5 do if math.abs(months[i] - months[1]) > 1e-9 or checkpoints[i] ~= checkpoints[1] then same = false end end
    check("T3 scheduler: half a game month is the same clock and checkpoint at 1, 3, 4, 7 and 28 days per month", same)
end
do
    local s, ctx, w, sched = schedSetup(2, 2)
    assert(Sc.tick(sched, s, { { hours = hoursFor(0.3, 4), daysPerMonth = 4 } }, w, ctx))
    Sc.tick(sched, s, {}, w, ctx)
    local first = 0
    for _, row in pairs(s.listings.records) do if row.state == "LISTED" then first = first + 1 end end
    for _ = 1, 3 do Sc.tick(sched, s, { { hours = hoursFor(0.5, 4), daysPerMonth = 4 } }, w, ctx); Sc.tick(sched, s, {}, w, ctx) end
    local withdrawn, listedNow = 0, 0
    for _, row in pairs(s.listings.records) do
        if row.state == "WITHDRAWN" then withdrawn = withdrawn + 1 elseif row.state == "LISTED" then listedNow = listedNow + 1 end
    end
    check("T3 scheduler: listings past their lifetime are withdrawn by the tick and the shelf is refilled to the target", first >= 1 and withdrawn >= 1 and listedNow >= 1)
    check("T3 scheduler: the ledger stays valid and every key distinct after months of turnover", I.validate(R.ledger) == nil)
end

-- ---- game binding ------------------------------------------------------------------------------
loadMod("scripts/dealer/RLDealerGameBinding.lua")
do
    local B = RLDealerGameBinding
    local sys = {
        getTypeByIndex = function() return { name = "COW", subTypes = { sIndex, mIndex }, fertility = { get = function() return 100 end },
            pregnancy = { average = 1, get = function(x) return 2 end } } end,
        getSubTypeByIndex = function(_, i) return index[i] end,
        getSaleAgeContext = function() return { maxBuyAge = 72, weaningMonth = 3, union = { { 0, 72 } }, lactates = true } end,
        countries = { { farms = {} }, { farms = {} }, { farms = {} }, { farms = { countryFarm } } },
    }
    sys.getTypeByIndex = function(self) return { name = "COW", subTypes = { sIndex, mIndex }, fertility = { get = function() return 100 end }, pregnancy = { average = 1, get = function() return 2 end } } end
    sys.getSubTypeByIndex = function(self, i) return index[i] end
    sys.getSaleAgeContext = function() return { maxBuyAge = 72, weaningMonth = 3, union = { { 0, 72 } }, lactates = true } end
    for _, sub in ipairs({ female, male }) do sub.visuals = { { minAge = 0, store = { canBeBought = true } } } end
    RealisticLivestock = { getMapCountryIndex = function() return 4 end }
    RLCalendar.getDate = RLCalendar.getDate or function(env) return env.currentDayInPeriod, env.currentPeriod + 2, env.currentYear end
    local world = assert(B.generationWorld(sys, AnimalType.COW, { day = 3, month = 6, year = 2026, daysPerMonth = 4 }))
    check("T3 binding: buyable subtypes come from their visuals", #world.subTypes == 2 and world.typeName == "COW")
    local rng = RLDealerRng.new("binding")
    local farm = world.pickSourceFarm(rng)
    check("T3 binding: a source farm that keeps the type is found on the job stream", farm ~= nil and farm.countryIndex == 4 and farm.farm == countryFarm)
    local before = RLTradePersistence.canonical({ countryFarm })
    check("T3 binding: offspring count comes from the stream and the type's own tables", world.generateOffspring(female, { fertility = 1 }, rng, 24) >= 0)
    check("T3 binding: planning reads, never writes, the country farm", RLTradePersistence.canonical({ countryFarm }) == before)
    check("T3 binding: date helpers", B.birthDate({ currentPeriod = 4, currentYear = 2, currentDayInPeriod = 1, daysPerPeriod = 4 })("S1", 100.5).eventId == "BS1@100.500000")
end

do
    local s9, c9, w9 = setup()
    local row9, _, inf9 = G.fillPlace(s9, w9, c9)
    local sid = "S" .. inf9.jobId .. ":" .. inf9.attempt
    local resolveSub = function(name) local i, sub = Economics.find(name); return sub, i end
    local eligible = RLDealerGameBinding.eligible(w9, resolveSub)
    local ok, why = eligible(s9.farm.sources[sid], row9, {})
    check("T3 binding: a fresh listing passes the shelf rule", ok == true, tostring(why))
    local gone = { payload = { purpose = "NO_SUCH_PURPOSE", sourceId = sid } }
    check("T3 binding: a listing whose purpose no longer exists is not eligible", select(1, eligible(s9.farm.sources[sid], gone, {})) == false)
    local broken = RLTradePersistence.parse(RLTradePersistence.canonical(s9.farm.sources[sid]), RLDealerPersistence.LIMITS)
    broken.animal.health = 10
    check("T3 binding: a source that fell ill below the minimum health is not eligible", select(1, eligible(broken, row9, {})) == false)
end
