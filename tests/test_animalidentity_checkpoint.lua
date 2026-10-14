-- Dealer v2 T2d: save / load checkpoint of the identity ledger, with an in-memory disk. Models the
-- engine's own save only as far as the checkpoint depends on it (one synchronous pass, participants'
-- documents written by the game, the career document written after the pass, folder replaced).
local f = assert(io.open(REPO .. "scripts/utils/RLAnimalUtil.lua", "r")); local src = f:read("*a"); f:close()
assert(load((src:gsub("::number", "")), "RLAnimalUtil"))()
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/animal/RLAnimalIdentityPersistence.lua")
loadMod("scripts/animal/RLAnimalIdentityRuntime.lua")
loadMod("scripts/animal/RLAnimalIdentityWorld.lua")
loadMod("scripts/animal/RLAnimalIdentityCheckpoint.lua")
local I, R, W, C, P, U = RLAnimalIdentity, RLAnimalIdentityRuntime, RLAnimalIdentityWorld, RLAnimalIdentityCheckpoint, RLAnimalIdentityPersistence, RLAnimalUtil
AnimalType = { COW = 1, PIG = 2, SHEEP = 3, HORSE = 4, CHICKEN = 5 }
Savegame = { ERROR_OK = 0 }

local function clone(v) if type(v) ~= "table" then return v end local o = {} for k, x in pairs(v) do o[k] = clone(x) end return o end

local function world()
    local w = { disk = {}, fault = nil }
    local function document(path, values)
        local x = { path = path, values = values or {} }
        function x:getString(k) return self.values[k] end
        function x:setString(k, v) self.values[k] = v end
        function x:delete() end
        function x:save()
            if w.fault == "LEDGER_SAVE" and self.path:find(P.FILENAME, 1, true) then return false end
            w.disk[self.path] = clone(self.values); return true
        end
        function x:iterate(prefix, fn)
            local n = {}
            for k in pairs(self.values) do
                if k:sub(1, #prefix + 1) == prefix .. "(" and k:sub(-2) == "#v" then n[#n + 1] = tonumber(k:match("%((%d+)%)#v$")) end
            end
            table.sort(n)
            for _, i in ipairs(n) do fn(i, prefix .. "(" .. i .. ")") end
        end
        return x
    end
    w.document = document
    C.storage = {
        exists = function(path) return w.disk[path] ~= nil end,
        load = function(path) return w.disk[path] and document(path, clone(w.disk[path])) or nil end,
        create = function(path) return document(path) end,
        careerSet = function(handle, k, v) handle:setString(k, v) end,
    }
    w.info = { savegameDirectory = "/save", xmlFile = document("/save/careerSavegame.xml", {}) }
    w.skip = {}
    -- one engine save: the pass, the participants, the career document, then the engine's completion
    function w:save(complete)
        local nonJournal = {}
        C.onSaveBegin(self.info)
        local files = { placeables = "placeables", vehicles = "vehicles", farms = "farms", animalSystem = "rm_RlAnimalSystem" }
        for role, root in pairs(files) do
            local x = document("/save/" .. C.FILES[role], { content = role })
            if not self.skip[role] then C.markParticipant(role, x, root) end
            x:save()
        end
        C.onSaveEnd(self.info)
        if complete == false then return end
        self.info.xmlFile:save()
        C.onSaveComplete(self.fail or 0, "/save")
        self.disk["/save/" .. P.JOURNAL_FILENAME] = nil      -- the engine replaces the folder
    end
    function w:load()
        R.reset(true); C.reset(true)
        self.skip = {}
        C.onMissionStarted({ missionInfo = self.info })
    end
    return w
end

local function herdFarm(herd, cow)
    local farm = { stats = { statistics = { farmId = herd, cowId = cow or 0, pigId = 0, sheepId = 0, horseId = 0, chickenId = 0 } } }
    function farm.stats:getNextAnimalId() self.statistics.cowId = self.statistics.cowId + 1; return self.statistics.cowId end
    return farm
end
local function alloc(farm, n)
    local last
    for _ = 1, n or 1 do last = W.nextStatsRaw("t", farm, AnimalType.COW, 2, "auto") end
    return last
end
local function activate(farm)
    R.setMode(R.SHADOW)
    local scan = { records = {}, counters = farm and { { country = 2, farmId = tostring(farm.stats.statistics.farmId), type = "cowId", nextRaw = farm.stats.statistics.cowId + 1 } } or {} }
    assert(R.activate(scan, { accept = true }))
    assert(C.arm())
end

-- 1 fresh save: nothing written
local w = world()
w:load()
check("fresh save: READY without a ledger, shadow mode, not armed", C.state == C.READY and R.ledger == nil and R.mode == R.SHADOW and not C.armed and R.authoritative() == false)
w:save()
check("fresh save: a save writes no ledger, no markers", w.disk["/save/" .. P.FILENAME] == nil and w.disk["/save/farms.xml"][("farms#" .. C.MARKER)] == nil
    and w.info.xmlFile.values["careerSavegame#" .. C.MARKER] == nil)

-- 2 activate, save, commit
local farm = herdFarm(123456, 4)
activate(farm)
check("activate arms the checkpoint with the lineage", C.armed and C.lineage == R.lineage and R.authoritative())
alloc(farm, 3)
w:save()
check("save pass: WRITTEN then COMMITTED, generation 1, journal trimmed to nothing", C.last.status == "COMMITTED" and C.last.generation == 1 and C.committed == 1
    and #R.journalKeys() == 0 and w.disk["/save/" .. P.FILENAME] ~= nil)
check("markers on every participant and the career document", (function()
    local want = C.lineage .. ":1"
    return w.disk["/save/placeables.xml"]["placeables#" .. C.MARKER] == want and w.disk["/save/vehicles.xml"]["vehicles#" .. C.MARKER] == want
        and w.disk["/save/farms.xml"]["farms#" .. C.MARKER] == want and w.disk["/save/rm_RlAnimalSystem.xml"]["rm_RlAnimalSystem#" .. C.MARKER] == want
        and w.info.xmlFile.values["careerSavegame#" .. C.MARKER] == want
end)())

-- 3 reload
local lineage = C.lineage
local keysBefore = 0
for _ in pairs(R.ledger.keys) do keysBefore = keysBefore + 1 end
w:load()
local keysAfter = 0
for _ in pairs(R.ledger.keys) do keysAfter = keysAfter + 1 end
check("reload: READY, ledger and mode restored, lineage and generation continue", C.state == C.READY and R.mode == R.ON and R.authoritative() and keysAfter == keysBefore
    and C.lineage == lineage and C.generation == 1 and C.committed == 1)
local farm2 = herdFarm(123456, 4)
check("reload: the next key continues above the saved ones", alloc(farm2) == 8)
w:save()
check("second save is generation 2", C.last.generation == 2 and C.last.status == "COMMITTED")

-- 4 a participant is missing from the pass (hook did not run)
w:load()
w.skip.farms = true
alloc(herdFarm(123456, 4))
w:save()
check("a participant without its marker: pass INCOMPLETE, no career mark", C.last.status == "INCOMPLETE" and C.last.reason == "PARTICIPANT_HOOK_MISSING:farms"
    and w.info.xmlFile.values["careerSavegame#" .. C.MARKER] == C.lineage .. ":2" and w.disk["/save/" .. P.FILENAME] ~= nil)
w:load()
check("loading a mixed save is RECOVERY_REQUIRED and the runtime is back on the old counters", C.state == C.RECOVERY_REQUIRED and not R.authoritative()
    and C.reason:find("MARKER_MISMATCH", 1, true) ~= nil)
local f3 = herdFarm(123456, 20)
check("in recovery an entry answers from the old counter", W.nextStatsRaw("t", f3, AnimalType.COW, 2, "auto") == 21)
w:save()
check("recovery is carried by the next save (a save does not launder it)", C.last.status == "COMMITTED" and (function()
    local doc = P.readLedger(w.document("/save/" .. P.FILENAME, w.disk["/save/" .. P.FILENAME]))
    return doc.data.recovery ~= nil
end)())
w:load()
check("reload of a carried recovery stays in recovery", C.state == C.RECOVERY_REQUIRED and C.reason:find("RECOVERY_CARRIED", 1, true) ~= nil)
check("recoveryClear without a world scan keeps the recovery", select(2, C.recoveryClear()) == "BAD_SCAN" and C.state == C.RECOVERY_REQUIRED and not R.authoritative())
check("recoveryClear is the user's decision and returns to READY", C.recoveryClear({ records = {}, counters = {}, herdNext = { ["123456"] = 22 } }) == true
    and C.state == C.READY and R.authoritative() and select(2, C.recoveryClear()) == "NOT_IN_RECOVERY")
w:save()

-- 5 unsaved session: journal burns on the same generation
w:load()
local g = herdFarm(123456, 4)
local k1 = alloc(g, 2)
check("two keys handed out are in the journal", #R.journalKeys() == 2)
check("journal flush writes the file once and only when dirty", C.flushJournal(w.info) == true and w.disk["/save/" .. P.JOURNAL_FILENAME] ~= nil and C.flushJournal(w.info) == false)
local shownKey = R.journalKeys()[1]
w:load()   -- no save: the session is gone
check("same-generation journal: its keys are burned, the animals are not restored", C.state == C.READY and R.ledger.keys[shownKey] ~= nil
    and R.ledger.keys[shownKey].state == I.BURNED)
local g2 = herdFarm(123456, 4)
local again = alloc(g2)
check("a burned key is never handed out again", R.ledger.keys[I.keyString("123456", U.generateUniqueId(123456, again), 2)].state == I.CONSUMED and again > k1)

-- 6 journal evidence
local function withJournal(generation, lineageOverride, keys)
    local x = w.document("/save/" .. P.JOURNAL_FILENAME)
    assert(P.writeJournal(x, { lineage = lineageOverride or C.lineage, generation = generation, sequence = 1, keys = keys or { "123456 310001 2" } }))
    x:save()
end
w:save()
w:load()
local gen = C.committed
withJournal(gen - 1)
w:load()
check("an older journal is ignored", C.state == C.READY)
withJournal(gen + 1)
w:load()
check("a journal of a newer generation is RECOVERY_REQUIRED", C.state == C.RECOVERY_REQUIRED and C.reason == "JOURNAL_FUTURE_GENERATION")
withJournal(gen, "Lother-1")
w:load()
check("a journal of another lineage is RECOVERY_REQUIRED", C.state == C.RECOVERY_REQUIRED and C.reason == "JOURNAL_OTHER_LINEAGE")
w.disk["/save/" .. P.JOURNAL_FILENAME] = { garbage = "x" }
w:load()
check("a damaged journal is RECOVERY_REQUIRED, never partly read", C.state == C.RECOVERY_REQUIRED and C.reason:find("JOURNAL_UNREADABLE", 1, true) ~= nil)
w.disk["/save/" .. P.JOURNAL_FILENAME] = nil

-- 7 keys allocated after the pass but before the engine finished stay in the journal
w:load()
local h = herdFarm(123456, 4)
alloc(h)
w:save(false)
alloc(h)
w.info.xmlFile:save(); C.onSaveComplete(0, "/save")
check("a commit removes only the keys its save absorbed", C.last.status == "COMMITTED" and #R.journalKeys() == 1)

-- 8 faults
w:load()
w.fault = "LEDGER_SAVE"
alloc(herdFarm(123456, 4))
local before = w.info.xmlFile.values["careerSavegame#" .. C.MARKER]
w:save()
check("ledger write failure: INCOMPLETE and the career mark is not advanced", C.last.status == "INCOMPLETE" and C.last.reason:find("LEDGER_WRITE_FAILED", 1, true) ~= nil
    and w.info.xmlFile.values["careerSavegame#" .. C.MARKER] == before)
w.fault = nil
w.fail = 1
w:load(); alloc(herdFarm(123456, 4)); w:save()
check("engine error: FAILED, nothing committed", C.last.status == "FAILED" and C.committed ~= C.last.generation)
w.fail = nil

-- 9 evidence missing
w:load()
w.disk["/save/" .. P.FILENAME] = nil
w:load()
check("markers without a ledger file: RECOVERY_REQUIRED, ledger missing", C.state == C.RECOVERY_REQUIRED and C.reason == "LEDGER_MISSING")
local w2 = world(); w2:load()
w2.disk["/save/" .. P.FILENAME] = { garbage = "1" }
w2:load()
check("an unreadable ledger file is RECOVERY_REQUIRED", C.state == C.RECOVERY_REQUIRED and C.reason:find("LEDGER_UNREADABLE", 1, true) ~= nil)

-- 10 hooks never throw into the engine
C.install()
check("install is idempotent and safe without the engine classes", C.installed == true)

-- the career commit mark missing (the engine never finished the save) is a mixed save
do
    local wc = world()
    wc:load()
    local farmC = herdFarm(123456, 4)
    activate(farmC)
    wc:save()                 -- generation 1, complete
    alloc(farmC, 1)
    wc.info.xmlFile.values["careerSavegame#" .. C.MARKER] = nil
    wc.disk["/save/careerSavegame.xml"] = nil
    wc:save(false)            -- generation 2 written, the engine's career document never lands
    wc:load()
    check("a save whose career commit mark never reached the disk is RECOVERY_REQUIRED", C.state == C.RECOVERY_REQUIRED
        and C.reason:find("career=nil", 1, true) ~= nil)
end

-- review: a save in RECOVERY_REQUIRED with no ledger must still carry the recovery
do
    local wr = world()
    wr:load()
    wr.disk["/save/" .. P.FILENAME] = { garbage = "x" }
    wr:load()
    check("R1 unreadable ledger: recovery, armed so that saves keep writing", C.state == C.RECOVERY_REQUIRED and C.armed == true)
    wr:save()
    check("R1 the save wrote a stub ledger that carries the recovery", wr.disk["/save/" .. P.FILENAME] ~= nil and C.last.status == "COMMITTED")
    wr:load()
    check("R1 the next load is still RECOVERY_REQUIRED, not 'never used the ledger'", C.state == C.RECOVERY_REQUIRED and C.reason:find("RECOVERY_CARRIED", 1, true) ~= nil)
end

-- review: re-activation after SHADOW does not re-import, does not ask again, keeps the acceptance
do
    local wa = world()
    wa:load()
    local farmA = herdFarm(123456, 4)
    R.setMode(R.SHADOW)
    local scanA = { records = { { farmId = "123456", uniqueId = U.generateUniqueId(123456, 2), country = 2, type = "1" } },
        counters = { { country = 2, farmId = "123456", type = "cowId", nextRaw = 5 } } }
    assert(R.activate(scanA, { accept = true }))
    local seqBefore = R.ledger.writerSequence
    R.setMode(R.SHADOW)
    local ok, why = R.activate(scanA, {})
    check("R2 re-activation needs no new acceptance for a domain the ledger already holds", ok == true, tostring(why))
    check("R2 re-activation imports no live key twice and keeps the acceptance", next(R.ledger.duplicates) == nil and R.ledger.policy.acceptWeak == true
        and R.ledger.writerSequence - seqBefore <= 3)
    -- a herd that used counters but holds no animal still needs the acceptance
    R.reset(true); R.lineage = "Ltest-r3"; R.setLoaded(nil, "READY", "T")
    local refused = select(2, R.activate({ records = {}, counters = {}, uncoveredHerds = { "*/555555" } }, {}))
    check("R3 an uncovered herd (counters used, no animal) needs the acceptance too", refused == "UNPROVEN_DOMAINS")
    check("R3 with the acceptance a later key in it is served", R.activate({ records = {}, counters = {}, uncoveredHerds = { "*/555555" } }, { accept = true })
        and W.nextStatsRaw("t", (function() local f = herdFarm(555555, 30); return f end)(), AnimalType.COW, 2, "auto") == 31)
end

-- PR #58 review P1: rlIdentityRecoveryClear must not resume a stale allocator
do
    local wp = world()
    wp:load()
    local farmP = herdFarm(246810, 0)
    activate(farmP)
    local first = alloc(farmP)                      -- ON: raw 1
    wp:save()
    wp.skip.farms = true
    wp:save()                                        -- a mixed save
    wp:load()
    check("R9 setup: the mixed save loads in recovery", C.state == C.RECOVERY_REQUIRED and not R.authoritative() and first == 1)
    local born = alloc(farmP)                        -- recovery: the old counter numbers raw 2 (alive)
    local sold = alloc(farmP)                        -- raw 3, sold before the clear
    local liveRecords = { { farmId = "246810", uniqueId = U.generateUniqueId(246810, 1), country = 2, type = "1" },
        { farmId = "246810", uniqueId = U.generateUniqueId(246810, born), country = 2, type = "1" } }
    local function scanNow(partial)
        return { records = liveRecords, counters = { { country = 2, farmId = "246810", type = "cowId", nextRaw = farmP.stats.statistics.cowId + 1 } },
            herdNext = { ["246810"] = farmP.stats.statistics.cowId + 1 }, partial = partial or {} }
    end
    local seq = R.ledger.writerSequence
    local ok, why = C.recoveryClear(scanNow({ "vehicles:boom" }))
    check("R9 a partial scan keeps the recovery and changes nothing", ok == nil and why == "SCAN_PARTIAL" and C.state == C.RECOVERY_REQUIRED
        and not R.authoritative() and R.ledger.writerSequence == seq)
    check("R9 a clear with a complete scan returns to ON", C.recoveryClear(scanNow()) == true and C.state == C.READY and R.authoritative())
    check("R9 the animal born in recovery is in the ledger", R.ledger.keys[I.keyString("246810", U.generateUniqueId(246810, born), 2)].state == I.CONSUMED)
    local next1 = alloc(farmP)
    check("R9 the next key is above every raw the old counter used (not the born 2, not the sold 3)", born == 2 and sold == 3 and next1 == 4)
    wp:save()
    check("R9 the reconciled ledger saves and commits, the recovery is gone", C.last.status == "COMMITTED")
    wp:load()
    check("R9 after a reload the clear holds and the next key continues", C.state == C.READY and R.authoritative() and alloc(farmP) == 5
        and R.ledger.domains["2/246810"].blocked[1][2] >= 3)
    -- a recovery in which the old counters ran past the 9999 alias boundary is blocked through the alias
    wp.skip.farms = true
    wp:save()
    wp:load()
    farmP.stats.statistics.cowId = 10000
    local aliasRaw = alloc(farmP)                    -- raw 10001: the same full key as raw 1
    check("R9 setup: recovery after a reload is entered again", C.state == C.RECOVERY_REQUIRED and aliasRaw == 10001)
    assert(C.recoveryClear({ records = liveRecords, counters = {}, herdNext = { ["246810"] = 10002 } }))
    local after = W.nextStatsRaw("t", farmP, AnimalType.COW, 2, "auto")
    -- raws 10002..19999 alias 2..9999, all used by the counter: the ledger refuses rather than reissue one
    check("R9 past the alias boundary no key of a used raw is handed out again", C.state == C.READY and (after == nil or after >= 20000))
end
