-- Dealer v2 T2: runtime (modes, domains, litters, activation), persistence documents, world contexts.
local f = assert(io.open(REPO .. "scripts/utils/RLAnimalUtil.lua", "r")); local src = f:read("*a"); f:close()
assert(load((src:gsub("::number", "")), "RLAnimalUtil"))()
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/animal/RLAnimalIdentityPersistence.lua")
loadMod("scripts/animal/RLAnimalIdentityRuntime.lua")
-- This unit fixture omits engine storage; checkpoint tests exercise the real barrier.
RLAnimalIdentityRuntime.journalBarrier = function() return true end
loadMod("scripts/animal/RLAnimalIdentityWorld.lua")
local I, R, W, P, U, T = RLAnimalIdentity, RLAnimalIdentityRuntime, RLAnimalIdentityWorld, RLAnimalIdentityPersistence, RLAnimalUtil, RLTradePersistence

AnimalType = { COW = 1, PIG = 2, SHEEP = 3, HORSE = 4, CHICKEN = 5 }

local function ready(mode)
    R.reset(true)
    R.lineage = "Ltest-1"
    R.setLoaded(nil, "READY", "TEST")
    R.mode = mode or R.SHADOW
end

-- A player farm whose FarmStats counter behaves like the real one.
local function playerFarm(herd, cow)
    local farm = { stats = { statistics = { farmId = herd, cowId = cow or 0, pigId = 0, sheepId = 0, horseId = 0, chickenId = 0 } } }
    function farm.stats:getNextAnimalId(t)
        assert(t == AnimalType.COW)
        self.statistics.cowId = self.statistics.cowId + 1
        return self.statistics.cowId
    end
    return farm
end
local function key(herd, raw, country) return I.keyString(herd, U.generateUniqueId(herd, raw), country) end

-- ---- modes -------------------------------------------------------------------------------------
do
    local farm = playerFarm(123456, 5)
    ready(R.OFF)
    local raw = W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto")
    check("OFF: legacy counter only, nothing observed", raw == 6 and farm.stats.statistics.cowId == 6 and R.shadow.observed == 0)

    ready(R.SHADOW)
    farm = playerFarm(123456, 0)
    R.setLive({ { farmId = "123456", uniqueId = U.generateUniqueId(123456, 7), country = 2, type = "1" } })
    local a = W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto")
    local b = W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto")
    check("SHADOW: legacy values, counter moves exactly as before", a == 1 and b == 2 and farm.stats.statistics.cowId == 2)
    farm.stats.statistics.cowId = 6
    -- ID-COLLISION-01: a taken key is counted as a collision and passed (the counter takes the next one).
    local c = W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto")
    check("SHADOW: a legacy key that already exists is counted as a collision and passed", c == 8 and farm.stats.statistics.cowId == 8
        and R.shadow.collisions == 1)
    farm.stats.statistics.cowId = 10000
    local d = W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto")    -- raw 10001 ... aliases raw 1 handed out earlier in this session
    check("SHADOW: aliasing raw 10001 vs 1 (and 10002 vs 2) seen earlier are collisions, passed to 10003", d == 10003 and R.shadow.collisions == 3)

    R.reset(false)
    check("client: never anything but legacy", W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto") == 10004 and R.shadow.observed == 0)
end

-- ---- ON: domains -------------------------------------------------------------------------------
do
    ready(R.SHADOW)
    local scan = { records = { { farmId = "123456", uniqueId = U.generateUniqueId(123456, 1), country = 2, type = "1" },
        { farmId = "123456", uniqueId = U.generateUniqueId(123456, 2), country = 2, type = "1" } },
        counters = { { country = 2, farmId = "123456", type = "cowId", nextRaw = 3 } } }
    local ok, why, unproven = R.activate(scan, {})
    check("activate: unproven domain is refused and listed without the user's acceptance", ok == nil and why == "UNPROVEN_DOMAINS" and unproven[1] == "2/123456"
        and R.mode == R.SHADOW and R.ledger == nil)
    local ok2 = R.activate(scan, { accept = true })
    check("activate: with acceptance the domain is under MIGRATION_POINT and live keys are imported", ok2 == true and R.mode == R.ON
        and R.ledger.domains["2/123456"].proof == "MIGRATION_POINT" and R.ledger.keys[key(123456, 1, 2)].state == I.CONSUMED
        and R.ledger.policy.acceptWeak == true and R.authoritative())
    local farm = playerFarm(123456, 2)
    local r1 = W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto")
    check("ON: key comes from the ledger, legacy increment was not called, counter mirrored", r1 == 3 and farm.stats.statistics.cowId == 3)
    check("ON: handed-out key is CONSUMED and journalled", R.ledger.keys[key(123456, 3, 2)].state == I.CONSUMED and R.journalKeys()[1] == key(123456, 3, 2))
    -- a new herd with zero counters is exclusive; with counters it needs the policy
    local fresh = playerFarm(654321, 0)
    local rf = W.nextStatsRaw("t", fresh, AnimalType.COW, 2, "auto")
    check("ON: a never-used herd (zero counters, no live animal) becomes EXCLUSIVE_NEW at raw 1", rf == 1 and R.ledger.domains["2/654321"].proof == "EXCLUSIVE_NEW")
    local used = playerFarm(777777, 40)
    local ru = W.nextStatsRaw("t", used, AnimalType.COW, 2, "auto")
    check("ON: a herd with counters but unknown history continues above its counter (accepted policy)", ru == 41 and used.stats.statistics.cowId == 41)
    -- other country of the same herd is its own domain, same herd counters bound it
    local rc = W.nextStatsRaw("t", farm, AnimalType.COW, 5, "auto")
    check("ON: the same herd in another country is a separate domain above the herd counter", rc == 4 and R.ledger.domains["5/123456"] ~= nil)
    -- RECOVERY: back to the old counters
    R.setLoaded(R.ledger, "RECOVERY_REQUIRED", "x")
    farm.stats.statistics.cowId = 50
    check("RECOVERY_REQUIRED: entries use the old counters again", W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto") == 51 and not R.authoritative())
    R.setLoaded(R.ledger, "READY", "ok")
    check("ledger without acceptance refuses a domain it cannot prove (no silent legacy)", (function()
        R.ledger.policy.acceptWeak = nil
        local g = playerFarm(888888, 12)
        local raw, why2 = W.nextStatsRaw("t", g, AnimalType.COW, 2, "auto")
        return raw == nil and why2 == "DOMAIN_UNPROVEN" and g.stats.statistics.cowId == 12
    end)())
end

-- ---- system farms (sale animals, AI) -------------------------------------------------------------
do
    ready(R.SHADOW)
    local sys = { countries = { [3] = { index = 3, farms = { { id = 9, ids = { [1] = 4, [2] = 9 }, quality = 1.5 } } } } }
    local farm = sys.countries[3].farms[1]
    R.activate({ records = {}, counters = { { country = 3, farmId = "9", type = "T1", nextRaw = 5 }, { country = 3, farmId = "9", type = "T2", nextRaw = 10 } } }, { accept = true })
    local raw = W.nextSystemRaw("sale-animal", sys, 3, farm, 1, "sale", function() error("legacy must not run") end)
    check("ON system farm: continues above the highest species counter and mirrors only its own species", raw == 10 and farm.ids[1] == 10 and farm.ids[2] == 9)
end

-- ---- litters -----------------------------------------------------------------------------------
do
    ready(R.SHADOW)
    R.activate({ records = {}, counters = {} }, { accept = true })
    local farm = playerFarm(111111, 0)
    local ctx = W.statsContext("birth", farm, AnimalType.COW, 2, "birth")
    check("beginBirth reserves one key per fetus and sets the current litter", R.beginBirth(ctx, "mother|1", 3) and R.currentLitter() ~= nil and #R.currentLitter().keys == 3)
    local r1 = W.nextStatsRaw("set-unique-id", farm, AnimalType.COW, 2, "birth")
    local r2 = W.nextStatsRaw("set-unique-id", farm, AnimalType.COW, 2, "birth")
    check("children take the litter's keys in order and consume them", r1 == 1 and r2 == 2 and farm.stats.statistics.cowId == 2)
    check("endBirth burns the key of the child that did not become an animal", R.endBirth() == 1 and R.currentLitter() == nil
        and R.ledger.keys[key(111111, 3, 2)].state == I.BURNED)
    -- a held birth retried gets the same keys
    local ctx2 = W.statsContext("birth", farm, AnimalType.COW, 2, "birth")
    assert(R.beginBirth(ctx2, "mother|2", 2))
    local first = { table.unpack(R.currentLitter().keys) }
    R.current = nil   -- the birth threw before endBirth
    assert(R.beginBirth(ctx2, "mother|2", 2))
    check("a birth retried after an abort reuses the same reserved keys", R.currentLitter().keys[1] == first[1] and R.currentLitter().keys[2] == first[2])
    W.nextStatsRaw("x", farm, AnimalType.COW, 2, "birth")
    R.current = nil   -- abort after one key was used
    assert(R.beginBirth(ctx2, "mother|2", 2))
    check("after a partly used attempt the retry reserves a fresh set; used keys stay used", R.currentLitter().keys[1] ~= first[1] and R.ledger.keys[first[1]].state == I.CONSUMED)
    -- hold: domain cannot be served
    local g = playerFarm(222222, 9)
    R.ledger.policy.acceptWeak = nil
    local held, why = R.beginBirth(W.statsContext("birth", g, AnimalType.COW, 2, "birth"), "mother|3", 1)
    check("beginBirth answers false (hold) when no key can be reserved, and changes nothing", held == false and why == "DOMAIN_UNPROVEN" and R.currentLitter() == nil
        and g.stats.statistics.cowId == 9)
    check("beginBirth without a context holds too", R.beginBirth(nil, "mother|4", 1) == false)
    -- litter domain mismatch
    ready(R.SHADOW); R.activate({ records = {}, counters = {} }, { accept = true })
    local f2 = playerFarm(333333, 0)
    assert(R.beginBirth(W.statsContext("birth", f2, AnimalType.COW, 2, "birth"), "m|5", 1))
    local other = playerFarm(444444, 0)
    check("a litter is only used by its own domain", W.nextStatsRaw("x", other, AnimalType.COW, 2, "birth") == nil)
    R.current = nil
    -- not authoritative: beginBirth is a no-op that says go on
    ready(R.SHADOW)
    check("beginBirth outside ON is a no-op that lets the birth go on", R.beginBirth(nil, "x", 1) == true and R.currentLitter() == nil)
end

-- ---- world helpers -----------------------------------------------------------------------------
do
    local a = { farmId = "123456", uniqueId = "310001", animalTypeIndex = 1, pregnancy = { expected = { day = 3, month = 4, year = 2 }, pregnancies = { {}, {} } } }
    check("birthEventId is stable and carries mother, country, due date, type and litter size", W.birthEventId(a, 2) == "123456|310001|2|2-4-3|1|2")
    a.pregnancy.pregnancies[3] = {}
    check("birthEventId changes with the litter", W.birthEventId(a, 2) ~= "123456|310001|2|2-4-3|1|2")
    -- scan
    local function cs(list) return { animals = list, clustersToAdd = {} } end
    local animal = function(f, u, c, t) return { farmId = f, uniqueId = u, birthday = { country = c }, animalTypeIndex = t } end
    local mission = {
        placeableSystem = { placeables = { { spec_husbandryAnimals = { clusterSystem = cs({ animal("123456", "310001", 2, 1) }) } } } },
        vehicleSystem = { vehicles = { { spec_livestockTrailer = { clusterSystem = cs({ animal("123456", "310002", 2, 1) }) } } } },
        animalSystem = { animals = { [1] = { animal("9", "310003", 3, 1) } }, aiAnimals = { [1] = {} },
            countries = { [3] = { index = 3, farms = { { id = 9, ids = { [1] = 4 } } } } } },
    }
    g_farmManager = { farmIdToFarm = { [1] = playerFarm(123456, 6) } }
    local scan = W.scan(mission)
    check("scan: records from pens, trailers and sale animals; counters as last+1, herd counters per country", #scan.records == 3 and #scan.partial == 0
        and (function()
            local sys, herd = false, false
            for _, c in ipairs(scan.counters) do
                if c.country == 3 and c.farmId == "9" and c.nextRaw == 5 then sys = true end
                if c.country == 2 and c.farmId == "123456" and c.type == "cowId" and c.nextRaw == 7 then herd = true end
            end
            return sys and herd
        end)())
    g_farmManager.farmIdToFarm[2] = playerFarm(222222, 0)
    g_farmManager.farmIdToFarm[2].stats.statistics.pigId = 8
    local scan2 = W.scan(mission)
    check("scan: herdNext = highest counter of any species + 1, also for a herd without animals", scan2.herdNext["123456"] == 7 and scan2.herdNext["222222"] == 9)
    mission.vehicleSystem = nil
    check("scan: an unreadable part is reported as partial, the rest still scanned", #W.scan(mission).partial == 1)
end

-- ---- persistence documents ---------------------------------------------------------------------
do
    local function xml()
        local x = { values = {} }
        function x:setString(k, v) self.values[k] = v end
        function x:getString(k) return self.values[k] end
        function x:iterate(prefix, fn)
            local i = 0
            while self.values[prefix .. "(" .. i .. ")#v"] do fn(i, prefix .. "(" .. i .. ")"); i = i + 1 end
        end
        return x
    end
    local l = assert(I.new("Ltest-2"))
    I.registerDomain(l, 2, "41", { kind = "EXCLUSIVE_NEW", startRaw = 1 })
    for i = 1, 300 do assert(I.reserveBatch(l, "r" .. i, { country = 2, farmId = "41", items = { { role = "auto", type = "COW" } } })) end
    l.generation = 4
    local data = { schema = 1, lineage = "Ltest-2", generation = 4, mode = "ON", ledger = assert(I.export(l)), participants = { farms = true } }
    local x = xml()
    local ok, digest = P.writeLedger(x, data)
    local doc = P.readLedger(x)
    check("ledger document round trips (many chunks) and the ledger is imported", ok and doc ~= nil and doc.meta.digest == digest and doc.meta.generation == 4
        and doc.ledger.domains["2/41"].next == 301 and doc.data.participants.farms == true)
    local key1 = next(x.values)
    local broken = xml(); for k, v in pairs(x.values) do broken.values[k] = v end
    broken.values[P.ROOT .. ".data.chunk(0)#v"] = broken.values[P.ROOT .. ".data.chunk(0)#v"] .. "x"
    check("a damaged chunk is refused", select(2, P.readLedger(broken)) == "BAD_DATA:LENGTH")
    local forged = xml(); for k, v in pairs(x.values) do forged.values[k] = v end
    forged.values[P.ROOT .. "#generation"] = "5"
    check("a header that disagrees with the data is refused", select(2, P.readLedger(forged)) == "HEADER_MISMATCH")
    local newer = xml(); for k, v in pairs(x.values) do newer.values[k] = v end
    newer.values[P.ROOT .. "#schema"] = "9"
    check("a newer schema is named, not guessed", select(2, P.readLedger(newer)) == "NEWER_SCHEMA:9")
    check("a missing document has no schema", select(2, P.readLedger(xml())) == "NO_SCHEMA")
    local jx = xml()
    assert(P.writeJournal(jx, { lineage = "Ltest-2", generation = 4, sequence = 3, keys = { "41 310001 2", "41 310002 2" } }))
    check("journal round trips", #P.readJournal(jx).data.keys == 2)
    local bad = xml()
    check("journal with a malformed key is refused before writing", select(2, P.writeJournal(bad,
        { lineage = "Ltest-2", generation = 4, sequence = 3, keys = { "not a key" } })) == "BAD_JOURNAL_KEY:1")
    check("journal over the limit is not written", select(2, P.writeJournal(xml(), { lineage = "Ltest-2", generation = 1, sequence = 1, keys = (function() local k = {}; for i = 1, P.MAX_JOURNAL_KEYS + 1 do k[i] = "1 1 1" end; return k end)() })) == "BAD_JOURNAL")
end

-- ---- PR #58 review P2-2: re-activation reconciles domains the ledger already held -------------------
do
    local function cycle(offMode)
        ready(R.SHADOW)
        local farm = playerFarm(135790, 0)
        R.activate({ records = {}, counters = {} }, {})          -- a never-used herd needs no acceptance
        local first = W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto")
        R.setMode(offMode)
        local legacy = W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto")   -- the old counter numbers it; then it is sold
        -- the herd now holds no animal: no counter for its country domain, only the herd's high-water mark
        local ok, why = R.activate({ records = {}, counters = {}, uncoveredHerds = { "*/135790" }, herdNext = { ["135790"] = farm.stats.statistics.cowId + 1 } }, {})
        local again = W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto")
        return first, legacy, ok, why, again
    end
    local first, legacy, ok, why, again = cycle(R.OFF)
    check("R8 ON 1, OFF 2 sold, ON again: the known domain needs no acceptance and the next key is 3, not 2", first == 1 and legacy == 2 and ok == true
        and again == 3, string.format("first=%s legacy=%s ok=%s why=%s again=%s", tostring(first), tostring(legacy), tostring(ok), tostring(why), tostring(again)))
    check("R8 the raws the old counter used are blocked (aliases too) and the consumed key stays", R.ledger.domains["2/135790"].blocked[1][1] == 1
        and R.ledger.domains["2/135790"].blocked[1][2] == 2 and R.ledger.keys[key(135790, 1, 2)].state == I.CONSUMED
        and I.reserveBatch(I.import(I.export(R.ledger)), "probe", { country = 2, farmId = "135790", items = { { role = "auto", type = "1" } } }).keys[1].raw == 4)
    first, legacy, ok, why, again = cycle(R.SHADOW)
    check("R8 the same through SHADOW", first == 1 and legacy == 2 and ok == true and again == 3)

    -- another species' counter ran while the ledger was off: keys carry no species, so it bounds the domain too
    ready(R.SHADOW)
    local farm = playerFarm(246800, 0)
    R.activate({ records = {}, counters = {} }, {})
    W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto")
    R.setMode(R.OFF)
    farm.stats.statistics.pigId = 9       -- pigs 1..9 numbered by the old counter, some still alive
    local live = { { farmId = "246800", uniqueId = U.generateUniqueId(246800, 9), country = 2, type = "2" } }
    assert(R.activate({ records = live, counters = { { country = 2, farmId = "246800", type = "pigId", nextRaw = 10 }, { country = 2, farmId = "246800", type = "cowId", nextRaw = 2 } } }, {}))
    check("R8 cross species: the next cow continues above the pig counter, the live pig is imported", W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto") == 10
        and R.ledger.keys[key(246800, 9, 2)].state == I.CONSUMED)

    -- a sale farm (system domain) the ledger already held
    ready(R.SHADOW)
    local sys = { countries = { [3] = { index = 3, farms = { { id = 9, ids = { [1] = 0 } } } } } }
    local sf = sys.countries[3].farms[1]
    R.activate({ records = {}, counters = { { country = 3, farmId = "9", type = "T1", nextRaw = 1 } } }, { accept = true })
    local s1 = W.nextSystemRaw("sale-animal", sys, 3, sf, 1, "sale", function() error("legacy must not run") end)
    R.setMode(R.OFF)
    local s2 = W.nextSystemRaw("sale-animal", sys, 3, sf, 1, "sale", function() sf.ids[1] = sf.ids[1] + 1; return sf.ids[1] end)
    assert(R.activate({ records = {}, counters = { { country = 3, farmId = "9", type = "T1", nextRaw = sf.ids[1] + 1 } } }, {}))
    local s3 = W.nextSystemRaw("sale-animal", sys, 3, sf, 1, "sale", function() error("legacy must not run") end)
    check("R8 a sale-farm domain is reconciled with its counter too", s1 == 1 and s2 == 2 and s3 == 3)
end

-- A new authoritative activation is not a duplicate repair tool. It preserves
-- both animals and all their IDs and refuses even an explicit weak-history option.
do
    ready(R.SHADOW)
    local a = {farmId="333333",uniqueId=U.generateUniqueId(333333,1),country=2,type="COW"}
    local b = {farmId=a.farmId,uniqueId=a.uniqueId,country=a.country,type="SHEEP"}
    local id = b.uniqueId
    local scan = {records={a,b},counters={}}
    local activated, why, _, report = R.activate(scan, {accept=true})
    check("duplicate activation quarantines instead of silently changing IDs", activated == nil
        and why == "DUPLICATE_IDENTITIES" and R.mode == R.SHADOW and R.ledger == nil
        and b.uniqueId == id and next(report.duplicates) ~= nil)
    assert(R.activate({records={},counters={}},{}))
    R.setMode(R.SHADOW)
    local before = RLTradePersistence.canonical(I.export(R.ledger))
    local reconciled, reason = R.reconcile(scan)
    check("duplicate recovery reconciliation preserves the ledger and animal IDs", reconciled == nil
        and reason == "DUPLICATE_IDENTITIES" and RLTradePersistence.canonical(I.export(R.ledger)) == before
        and b.uniqueId == id)
end

-- Review P2: even a correct digest must not turn sparse/trailing journal fields
-- into permission to forget an already exposed key during ipairs-based recovery.
do
    local function document()
        local x={values={}}
        function x:setString(k,v) self.values[k]=v end
        function x:getString(k) return self.values[k] end
        function x:iterate(prefix,fn)
            local i=0
            while self.values[prefix.."("..i..")#v"] do fn(i,prefix.."("..i..")");i=i+1 end
        end
        return x
    end
    local function forge(data)
        local x=document()
        local canonical=T.canonical(data)
        local encoded=T.encodeText(canonical)
        x:setString(P.JOURNAL_ROOT.."#schema","1")
        x:setString(P.JOURNAL_ROOT.."#lineage",data.lineage)
        x:setString(P.JOURNAL_ROOT.."#generation",tostring(data.generation))
        x:setString(P.JOURNAL_ROOT.."#digest",T.checksum(canonical))
        x:setString(P.JOURNAL_ROOT..".data#length",tostring(#encoded))
        local i=0
        for first=1,#encoded,T.CHUNK do x:setString(P.JOURNAL_ROOT..".data.chunk("..i..")#v",encoded:sub(first,first+T.CHUNK-1));i=i+1 end
        return x
    end
    for _,case in ipairs({
        {name="sparse",keys={[1]="41 310001 2",[3]="41 310002 2"}},
        {name="named trailing key",keys={[1]="41 310001 2",later="41 310002 2"}},
        {name="duplicate key",keys={"41 310001 2","41 310001 2"}},
        {name="invalid complete key",keys={"41 310001 2","bad key"}},
        {name="noncanonical country",keys={"41 310001 02"}},
        {name="sequence fractional",keys={"41 310001 2"},sequence=0.5},
        {name="sequence out of range",keys={"41 310001 2"},sequence=2^52},
        {name="generation out of range",keys={"41 310001 2"},generation=2^52},
    }) do
        local data={lineage="Lstrict-1",generation=case.generation or 1,sequence=case.sequence or 1,keys=case.keys}
        check("journal strict writer rejects "..case.name,P.writeJournal(document(),data)==nil)
        check("journal strict reader rejects correctly digested "..case.name,P.readJournal(forge(data))==nil)
    end
    local over={}
    for i=1,P.MAX_JOURNAL_KEYS+1 do over[i]="41 "..i.." 2" end
    local data={lineage="Lstrict-1",generation=1,sequence=1,keys=over}
    check("journal strict writer counts all keys against limit",P.writeJournal(document(),data)==nil)
    check("journal strict reader counts all keys against limit",P.readJournal(forge(data))==nil)
    for _,invalid in ipairs({math.huge,-math.huge,0/0}) do
        check("journal strict writer rejects nonfinite sequence",P.writeJournal(document(),{lineage="Lstrict-1",generation=1,sequence=invalid,keys={}})==nil)
    end
end

-- ---- batch: one journal barrier per synchronous callback (game test 2026-10-24) ------------------
do
    local saved = R.journalBarrier
    local calls, answer = 0, true
    local function setup()
        ready(R.SHADOW)
        R.activate({ records = {}, counters = { { country = 3, farmId = "9", type = "T1", nextRaw = 1 } } }, { accept = true })
        calls, answer = 0, true
        R.journalBarrier = function() calls = calls + 1; return answer end
        return { countries = { [3] = { index = 3, farms = { { id = 9, ids = { [1] = 1 }, quality = 1 } } } } }
    end
    local function take(sys) return W.nextSystemRaw("sale-animal", sys, 3, sys.countries[3].farms[1], 1, "sale", function() error("legacy") end) end

    local sys = setup()
    for _ = 1, 5 do take(sys) end
    check("batch: outside a batch every key has its own barrier", calls == 5)

    sys = setup()
    local raws = {}
    local a, b = R.batch(function(x)
        for i = 1, 5 do raws[i] = take(sys) end
        check("batch: inside, no barrier runs until the end", calls == 0 and #R.journalKeys() >= 5)
        return x, "two"
    end, "one")
    check("batch: the five keys are journaled by ONE barrier at the end, and results pass through",
        calls == 1 and a == "one" and b == "two" and raws[5] ~= nil and raws[1] ~= raws[5] and R.batchDepth == 0)
    calls = 0
    R.batch(function() R.batch(function() take(sys); take(sys) end); take(sys) end)
    check("batch: nested batches flush once, at the outermost end", calls == 1)
    calls = 0
    R.batch(function() end)
    check("batch: a batch that took no key runs no barrier", calls == 0)

    sys = setup()
    local ok, err = pcall(R.batch, function() take(sys); error("boom") end)
    check("batch: an error inside still flushes the keys taken, then propagates", not ok and tostring(err):find("boom") ~= nil
        and calls == 1 and R.batchDepth == 0 and not R.batchPending)

    sys = setup(); answer = false
    R.batch(function() take(sys) end)
    check("batch: a failed end barrier blocks the ledger as a per-key failure does",
        R.state == "RECOVERY_REQUIRED" and R.allocationBlocked ~= nil)
    R.journalBarrier = saved
end
