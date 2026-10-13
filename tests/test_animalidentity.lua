-- Dealer v2 T1: the identity ledger, against the REAL RLAnimalUtil formatter (loaded with the Giants
-- "::number" cast removed, which is the only thing plain Lua cannot read in that file).
local f = assert(io.open(REPO .. "scripts/utils/RLAnimalUtil.lua", "r")); local src = f:read("*a"); f:close()
assert(load((src:gsub("::number", "")), "RLAnimalUtil"))()
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
local I, U = RLAnimalIdentity, RLAnimalUtil

-- preimages must mirror padId over the whole supported range (a changed formatter fails here)
local groups, ok = {}, true
for raw = 0, I.MAX_RAW do
    local key = U.generateUniqueId("41", raw)
    groups[key] = groups[key] or {}
    table.insert(groups[key], raw)
end
for key, raws in pairs(groups) do
    local want = I.preimages(raws[1])
    if #want ~= #raws then ok = false else for i, r in ipairs(raws) do if want[i] ~= r then ok = false end end end
end
check("ID-01 preimages equal the real padId collision classes for every raw 0..99999", ok)
check("ID-01 known collisions: raw 1 and 10001, raw 0 and 10000", U.generateUniqueId("41", 1) == U.generateUniqueId("41", 10001)
    and U.generateUniqueId("41", 0) == U.generateUniqueId("41", 10000))
check("keyString matches RLAnimalUtil.toKey", I.keyString("41", "310003", 2) == U.toKey("41", "310003", 2))

local function ledgerWith(farm, proof)
    local l = assert(I.new("L1"))
    assert(I.registerDomain(l, 2, farm, proof or { kind = "EXCLUSIVE_NEW", startRaw = 1 }))
    return l
end
local function plan(n, role, farm)
    local items = {}
    for i = 1, n do items[i] = { role = role or "adult", type = i % 2 == 0 and "SHEEP" or "COW" } end
    return { country = 2, farmId = farm or "41", items = items }
end

-- ID-01: no duplicates across a long run, including raws that collide after padId
local l = ledgerWith("41", { kind = "EXCLUSIVE_NEW", startRaw = 9990 })
local seen, dup = {}, false
for i = 1, 30 do
    local r = assert(I.reserveBatch(l, "req" .. i, plan(7)))
    for _, k in ipairs(r.keys) do if seen[k.key] then dup = true end; seen[k.key] = true end
end
check("ID-01 210 keys across the 9999/10000/10001 boundary are all distinct", not dup)
local naive, naiveSeen, naiveDup = 9990, {}, false
for _ = 1, 20000 do
    local key = U.generateUniqueId("41", naive); naive = naive + 1
    if naiveSeen[key] then naiveDup = true end; naiveSeen[key] = true
end
check("ID-01 a plain raw counter produces duplicate full keys in the same range (the defect being fixed)", naiveDup)
local l2 = ledgerWith("41", { kind = "COUNTER_HISTORY", nextRaw = 3, evidence = "test" })
local r2 = assert(I.reserveBatch(l2, "a", { country = 2, farmId = "41", items = { { role = "adult", type = "COW" } } }))
check("ID-01 COUNTER_HISTORY blocks full keys of raws 1..next-1, cursor continues at next", r2.keys[1].raw == 3)
local l3 = ledgerWith("41", { kind = "COUNTER_HISTORY", nextRaw = 3, evidence = "test" })
l3.domains["2/41"].next = 10001  -- a cursor that jumped into the aliased range
local r3 = assert(I.reserveBatch(l3, "a", { country = 2, farmId = "41", items = { { role = "adult", type = "COW" } } }))
check("ID-01 a candidate aliasing a blocked historical raw (10001 ~ 1) is skipped", r3.keys[1].raw == 10003)
check("ID-01 cross-species: same raw in one herd never handed out twice", (function()
    local lx = ledgerWith("41")
    local a = assert(I.reserveBatch(lx, "x", { country = 2, farmId = "41", items = { { role = "adult", type = "COW" } } }))
    local b = assert(I.reserveBatch(lx, "y", { country = 2, farmId = "41", items = { { role = "adult", type = "PIG" } } }))
    return a.keys[1].key ~= b.keys[1].key
end)())

-- ID-02: keys are never released; exact retry does not allocate again
local l4 = ledgerWith("41")
local first = assert(I.reserveBatch(l4, "r1", plan(3)))
local seq = l4.writerSequence
local again = assert(I.reserveBatch(l4, "r1", plan(3)))
check("ID-02 exact retry returns the same keys, flags replayed, writes nothing", again.replayed and l4.writerSequence == seq
    and again.keys[1].key == first.keys[1].key and again.keys[3].key == first.keys[3].key)
check("ID-02 same requestId with another plan is refused", select(2, I.reserveBatch(l4, "r1", plan(4))) == "REQUEST_MISMATCH")
assert(I.bindMaterialization(l4, "r1", "sel-1"))
check("ID-02 the same selection digest binds again, another digest is refused",
    I.bindMaterialization(l4, "r1", "sel-1").replayed and select(2, I.bindMaterialization(l4, "r1", "sel-2")) == "SELECTION_MISMATCH")
assert(I.consume(l4, first.keys[1].key))
check("ID-02 burn after a partial consume burns only unconsumed keys", I.burn(l4, "r1", "factory failed") == 2
    and l4.keys[first.keys[1].key].state == I.CONSUMED and l4.keys[first.keys[2].key].state == I.BURNED)
local after = assert(I.reserveBatch(l4, "r2", plan(5)))
local reused = false
for _, k in ipairs(after.keys) do for _, o in ipairs(first.keys) do if k.key == o.key then reused = true end end end
check("ID-02 consumed, burned and reserved keys stay blocked for the next request", not reused)
check("ID-02 consume needs MATERIALIZED and a known key", select(2, I.consume(l4, after.keys[1].key)) == "BAD_STATE"
    and select(2, I.consume(l4, "nope")) == "KEY_UNKNOWN")

-- ID-03: mixed adult + fetus batch, atomic, no half batch on failure
local l5 = ledgerWith("41", { kind = "EXCLUSIVE_NEW", startRaw = I.MAX_RAW - 2 })
local snapshot = RLTradePersistence.canonical(l5)
local no, why = I.reserveBatch(l5, "big", { country = 2, farmId = "41", items = { { role = "adult", type = "COW" }, { role = "fetus", type = "COW" },
    { role = "fetus", type = "COW" }, { role = "fetus", type = "COW" } } })
check("ID-03 a batch that does not fit is refused as a whole and writes nothing", no == nil and why == "RANGE_EXHAUSTED"
    and RLTradePersistence.canonical(l5) == snapshot)
local ok3 = assert(I.reserveBatch(l5, "fits", { country = 2, farmId = "41", items = { { role = "adult", type = "COW" }, { role = "fetus", type = "COW" } } }))
check("ID-03 adult and fetus keys are reserved together in plan order with their roles", ok3.keys[1].role == "adult" and ok3.keys[2].role == "fetus")
local vetoCalls = 0
local l6 = ledgerWith("41")
local r6 = assert(I.reserveBatch(l6, "v", plan(2), { isOccupied = function(k) vetoCalls = vetoCalls + 1; return k:find(" 10001 ") ~= nil or k:find("10001 2$") ~= nil end }))
check("ID-03 caller veto (a key in the world) is skipped and counted", r6.keys[1].raw == 2 and l6.domains["2/41"].skipped == 1)
check("ID-03 an erroring veto fails the batch without writing", select(2, I.reserveBatch(l6, "w", plan(1), { isOccupied = function() error("boom") end })) == "OCCUPANCY_CHECK_FAILED"
    and l6.requests["w"] == nil)
local l7 = ledgerWith("41")
check("ID-03 skips are bounded", select(2, I.reserveBatch(l7, "s", plan(1), { isOccupied = function() return true end })) == "SKIP_LIMIT")
check("ID-03 bad batches are refused", select(2, I.reserveBatch(l7, "b", { country = 2, farmId = "41", items = {} })) == "BAD_BATCH"
    and select(2, I.reserveBatch(l7, "b", { country = 2, farmId = "41", items = { { role = "x", type = "COW" } } })) == "BAD_BATCH")

-- ID-04: migration never invents a proof
local function rec(farm, raw, country, t) return { farmId = farm, uniqueId = U.generateUniqueId(farm, raw), country = country or 2, type = t or "COW" } end
local records = { rec("41", 1), rec("41", 2), rec("41", 2, 2, "PIG"), rec("50", 5) }
local counters = { { country = 2, farmId = "41", type = "COW", nextRaw = 3 }, { country = 2, farmId = "41", type = "PIG", nextRaw = 3 },
    { country = 2, farmId = "50", type = "COW", nextRaw = 3 } }
local report = I.migrationReport(records, counters, {})
local d41, d50 = report.domains["2/41"], report.domains["2/50"]
check("ID-04 without evidence every domain is LEGACY_HISTORY_UNPROVEN", d41.status == I.UNPROVEN and d50.status == I.UNPROVEN)
check("ID-04 duplicate full key across species reported, animals not altered", #report.duplicates[I.keyString("41", U.generateUniqueId("41", 2), 2)] == 2)
check("ID-04 shared raws across species and a counter below a live key are named", (function()
    local has = {}
    for _, r in ipairs(d41.reasons) do has[r] = true end
    local hasBelow = false
    for _, r in ipairs(d50.reasons) do if r == "COUNTER_BELOW_LIVE" then hasBelow = true end end
    return has.SHARED_RAW_ACROSS_SPECIES and hasBelow
end)())
local proven = I.migrationReport(records, counters, { counterNeverRegressed = { ["2/41"] = true, ["2/50"] = true }, exclusive = { ["2/99"] = true } })
check("ID-04 caller evidence proves 41 but never a domain whose counter is below a live key", proven.domains["2/41"].status == I.VERIFIED
    and proven.domains["2/41"].proof.nextRaw == 3 and proven.domains["2/50"].status == I.UNPROVEN)
local missing = I.migrationReport({ rec("60", 1) }, {}, { counterNeverRegressed = { ["2/60"] = true } })
check("ID-04 a missing counter cannot be proven even with a claim", missing.domains["2/60"].status == I.UNPROVEN)
local ph = I.migrationReport({ { farmId = "1", uniqueId = "1", country = 2 }, { farmId = "41", uniqueId = "5", country = nil } }, {}, {})
check("ID-04 placeholder and country-less records are reported, not imported", #ph.placeholders == 2 and next(ph.domains) == nil)
local foreign = I.migrationReport({ { farmId = "41", uniqueId = "777777", country = 2, type = "COW" } }, {}, {})
check("ID-04 an id the formatter cannot have made is reported as foreign", next(foreign.foreign) ~= nil)
local lm = assert(I.new("L2"))
I.applyMigration(lm, proven, records)
check("ID-04 applyMigration imports live keys once and registers proven vs unproven domains", lm.domains["2/41"].status == I.VERIFIED
    and lm.domains["2/50"].status == I.UNPROVEN and lm.duplicates[I.keyString("41", U.generateUniqueId("41", 2), 2)] == 2)
check("ID-04 an unproven domain hands out no keys; unknown domain neither", select(2, I.reserveBatch(lm, "z", plan(1, "adult", "50"))) == "DOMAIN_UNPROVEN"
    and select(2, I.reserveBatch(lm, "z", plan(1, "adult", "77"))) == "DOMAIN_UNKNOWN")
local lm1 = assert(I.reserveBatch(lm, "ok", plan(1, "adult", "41")))
check("ID-04 a migrated proven domain continues above its counter and never hits a live key", lm1.keys[1].raw == 3)
check("ID-04 weak guarantee needs explicit acceptance", select(2, I.registerDomain(assert(I.new("L3")), 2, "9", { kind = "MIGRATION_POINT", startRaw = 5 })) == "WEAK_GUARANTEE_NOT_ACCEPTED"
    and I.registerDomain(assert(I.new("L3")), 2, "9", { kind = "MIGRATION_POINT", startRaw = 5, userAccepted = true }) ~= nil)
check("domain proofs are validated", select(2, I.registerDomain(assert(I.new("L4")), 2, "9", { kind = "COUNTER_HISTORY", nextRaw = 3 })) == "BAD_PROOF"
    and select(2, I.registerDomain(assert(I.new("L4")), 2, "9", { kind = "WHATEVER" })) == "BAD_PROOF")

-- unsaved burn, shadow probe
local lb = ledgerWith("41")
local rb = assert(I.reserveBatch(lb, "b", plan(1)))
check("burnUnsaved adds new keys as BURNED, leaves known keys alone, rejects bad input", I.burnUnsaved(lb, { { farmId = "41", uniqueId = "999999", country = 2 },
    { farmId = "41", uniqueId = rb.keys[1].uniqueId, country = 2 } }) == 1 and lb.keys[rb.keys[1].key].state == I.RESERVED
    and select(2, I.burnUnsaved(lb, { { farmId = "41" } })) == "BAD_KEY")
check("probeLegacy is read only and reports conflicts", I.probeLegacy(lb, "41", "999999", 2) == "CONFLICT" and I.probeLegacy(lb, "41", "888888", 2) == "FREE"
    and lb.keys[I.keyString("41", "888888", 2)] == nil)

-- export / import
local le = ledgerWith("41")
for i = 1, 5 do local r = assert(I.reserveBatch(le, "e" .. i, plan(3))); I.bindMaterialization(le, "e" .. i, "s" .. i) end
I.burnUnsaved(le, { { farmId = "41", uniqueId = "999999", country = 2 } })
local data = assert(I.export(le))
local text = RLTradePersistence.canonical(data)
local back = assert(I.import(assert(RLTradePersistence.parse(text, I.LIMITS))))
local cont1 = assert(I.reserveBatch(le, "next", plan(2)))
local cont2 = assert(I.reserveBatch(back, "next", plan(2)))
check("export/import round trips and continues with the same keys", cont1.keys[1].key == cont2.keys[1].key and cont1.keys[2].key == cont2.keys[2].key)
local tampered = assert(RLTradePersistence.parse(text, I.LIMITS))
tampered.keys[next(tampered.keys)].state = "CONSUMED"
check("import refuses a damaged document", select(2, I.import(tampered)) == "DIGEST_MISMATCH")
local orphan = assert(RLTradePersistence.parse(text, I.LIMITS)); orphan.requests.e1 = nil; orphan.digest = nil
orphan.digest = (function() local c = {}; for k, v in pairs(orphan) do c[k] = v end; return RLTradePersistence.checksum(RLTradePersistence.canonical(c)) end)()
check("import refuses a structurally inconsistent document even with a valid digest", select(2, I.import(orphan)) ~= nil)
check("import refuses a stale-generation style change (sequence tamper) via digest", (function()
    local t = assert(RLTradePersistence.parse(text, I.LIMITS)); t.writerSequence = t.writerSequence - 1
    return select(2, I.import(t)) == "DIGEST_MISMATCH"
end)())

-- keys that already sit ahead of the cursor (burned unsaved, live animal imported later) are skipped
local la = ledgerWith("41")
I.burnUnsaved(la, { { farmId = "41", uniqueId = U.generateUniqueId("41", 2), country = 2 } })
I.importLiveKey(la, "41", U.generateUniqueId("41", 4), 2, "legacy")
local ra = assert(I.reserveBatch(la, "ahead", plan(3)))
check("ID-02 burned-unsaved and live keys ahead of the cursor are skipped (raws 1,3,5)", ra.keys[1].raw == 1 and ra.keys[2].raw == 3 and ra.keys[3].raw == 5)
