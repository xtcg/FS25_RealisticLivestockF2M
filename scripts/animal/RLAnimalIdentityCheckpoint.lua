--[[
    Dealer v2 T2d: the identity ledger saved with the savegame, at the same point as the assets it
    describes, and checked on load. Same single synchronous save call as RLTradeCheckpoint (see its
    header); this module is independent of it and of RLDealerCheckpoint and touches neither.

        begin   (prepended)  new generation G; the ledger exported for G (nothing is allocated inside
                             the save call: it is synchronous)
        markers              "<lineage>:G" at the root of placeables.xml, vehicles.xml, farms.xml and
                             rm_RlAnimalSystem.xml (the native counters), through the game's own open
                             documents
        end     (appended)   rm_RlAnimalIdentityLedger.xml written and read back; every marker read back
                             from disk; only then "<lineage>:G" in the career document: WRITTEN
        engine result        SavegameController.onSaveComplete: the finished folder is read back (career
                             mark, ledger digest and G, four markers): COMMITTED, else INCOMPLETE

    The ledger exists only after RLAnimalIdentityRuntime.activate (or a loaded ledger); a save that never
    used it gets no file, no markers.

    Unsaved keys. rm_RlAnimalIdentityJournal.xml lists the keys handed out since the last COMMITTED save
    (flushed when dirty, on the hour). The engine replaces the save folder on every save, so a journal
    left in the folder always belongs to a session that was not saved: on load, a journal of the loaded
    generation burns its keys; an older one is ignored; a newer or damaged one is RECOVERY_REQUIRED.

    RECOVERY_REQUIRED (damaged or mixed evidence) keeps the ledger for the report, makes the runtime
    answer from the old counters again (the behaviour before this module), logs an error, and is
    carried by every later save until rlIdentityRecoveryClear. A save never launders it.
]]

RLAnimalIdentityCheckpoint = {}
local C = RLAnimalIdentityCheckpoint
local P = RLAnimalIdentityPersistence
local R = RLAnimalIdentityRuntime
local I = RLAnimalIdentity

C.MARKER = "rlIdentityCheckpoint"
C.PARTICIPANTS = { "placeables", "vehicles", "farms", "animalSystem" }
C.ROOTS = { placeables = "placeables", vehicles = "vehicles", farms = "farms", animalSystem = "rm_RlAnimalSystem" }
C.FILES = { placeables = "placeables.xml", vehicles = "vehicles.xml", farms = "farms.xml", animalSystem = "rm_RlAnimalSystem.xml" }
C.DISABLED, C.LOADING, C.READY, C.RECOVERY_REQUIRED = "DISABLED", "LOADING", "READY", "RECOVERY_REQUIRED"

local function clone(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = clone(x) end
    return out
end

local function logf(level, fmt, ...)
    if Log ~= nil and Log[level] ~= nil then Log[level](Log, fmt, ...) end
end


local function base36(n, width)
    local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    for _ = 1, width do
        local d = n % 36
        out = digits:sub(d + 1, d + 1) .. out
        n = math.floor(n / 36)
    end
    return out
end


local function stamp()
    if getDate ~= nil then
        local ok, text = pcall(getDate, "%Y%m%d%H%M%S")
        if ok and type(text) == "string" then return text end
    end
    return os.date("%Y%m%d%H%M%S")
end


--- Engine storage: XMLFile documents. Tests replace C.storage.
local function defaultStorage()
    return {
        exists = function(path) return fileExists(path) end,
        load = function(path) return XMLFile.loadIfExists("rlIdentityRead", path) end,
        create = function(path, root) return XMLFile.create("rlIdentityWrite", path, root) end,
        careerSet = function(handle, key, value) setXMLString(handle, key, value) end,
    }
end


local function storage() return C.storage or defaultStorage() end


function C.reset(isServer)
    C.server = isServer == true
    C.state = C.server and C.LOADING or C.DISABLED
    C.reason = C.server and "WAITING_FOR_MISSION" or "CLIENT"
    C.armed, C.lineage, C.generation, C.committed = false, nil, 0, 0
    C.pass, C.last, C.recovery = nil, nil, nil
end


local function recover(reason)
    C.state, C.reason, C.recovery = C.RECOVERY_REQUIRED, reason, C.recovery or reason
    R.setLoaded(R.ledger, "RECOVERY_REQUIRED", reason)
    logf("error", "RLAnimalIdentityCheckpoint: RECOVERY_REQUIRED (%s) - keys come from the old counters again until rlIdentityRecoveryClear", tostring(reason))
end


-- -------------------------------------------------------------------------------------------
-- Save
-- -------------------------------------------------------------------------------------------

function C.onSaveBegin(missionInfo)
    if C.pass ~= nil then
        C.last = { generation = C.pass.generation, status = "ABORTED", reason = "NEXT_SAVE_STARTED" }
        C.pass = nil
    end
    if not C.armed or R.ledger == nil or C.state == C.LOADING then return end
    local generation = C.generation + 1
    C.generation = generation
    local exported, why = R.exportLedger(generation)
    C.pass = { generation = generation, marker = C.lineage .. ":" .. string.format("%d", generation), participants = {},
        journalCount = #R.journalKeys() }
    if exported == nil then
        C.pass.error = "LEDGER_EXPORT:" .. tostring(why)
        logf("error", "RLAnimalIdentityCheckpoint: generation %d not written: %s", generation, tostring(C.pass.error))
        return
    end
    C.pass.data = { schema = P.SCHEMA, lineage = C.lineage, generation = generation, mode = R.mode, ledger = exported,
        recovery = C.recovery }
end


function C.markParticipant(name, xml, root)
    local pass = C.pass
    if pass == nil or pass.data == nil or xml == nil then return end
    xml:setString(root .. "#" .. C.MARKER, pass.marker)
    pass.participants[name] = true
end


local function readMarker(path, root)
    local s = storage()
    if path == nil or not s.exists(path) then return nil end
    local ok, xml = pcall(s.load, path)
    if not ok or xml == nil then return false end
    local value = xml:getString(root .. "#" .. C.MARKER)
    xml:delete()
    return value
end


local function verifyParticipants(directory, pass)
    local wrong = {}
    for _, name in ipairs(C.PARTICIPANTS) do
        local found = readMarker(directory .. "/" .. C.FILES[name], C.ROOTS[name])
        local want = pass.participants[name] and pass.marker or nil
        if found ~= want then wrong[#wrong + 1] = name .. "=" .. tostring(found) end
    end
    return #wrong > 0 and table.concat(wrong, ";") or nil
end


local function readLedgerFile(directory)
    local s = storage()
    local path = directory .. "/" .. P.FILENAME
    if not s.exists(path) then return { present = false } end
    local ok, xml = pcall(s.load, path)
    if not ok or xml == nil then return { present = true, error = "PARSE_FAILED" } end
    local readOk, doc, why = pcall(P.readLedger, xml)
    xml:delete()
    if not readOk then return { present = true, error = "READ_THREW:" .. tostring(doc) } end
    if doc == nil then return { present = true, error = why } end
    return { present = true, doc = doc }
end


function C.onSaveEnd(missionInfo)
    local pass = C.pass
    if pass == nil then return end
    C.pass = nil
    local status, reason = "INCOMPLETE", pass.error
    if pass.data ~= nil then
        pass.data.participants = clone(pass.participants)
        local directory = missionInfo.savegameDirectory
        local path = directory .. "/" .. P.FILENAME
        local s = storage()
        local xml = s.create(path, P.ROOT)
        local written, digest = false, nil
        if xml ~= nil then
            written, digest = P.writeLedger(xml, pass.data)
            written = written and xml:save() == true
            xml:delete()
        end
        if not written then
            reason = "LEDGER_WRITE_FAILED:" .. tostring(digest)
        else
            local check = readLedgerFile(directory)
            local missing = verifyParticipants(directory, pass)
            local unmarked = {}
            for _, name in ipairs(C.PARTICIPANTS) do
                if not pass.participants[name] then unmarked[#unmarked + 1] = name end
            end
            if check.doc == nil or check.doc.meta.digest ~= digest or check.doc.meta.generation ~= pass.generation then
                reason = "LEDGER_READBACK_FAILED:" .. tostring(check.error)
            elseif #unmarked > 0 then
                -- The ledger stays on disk (a save without it would look like one that never used it);
                -- without the career mark the next load reports the mixed save.
                reason = "PARTICIPANT_HOOK_MISSING:" .. table.concat(unmarked, ",")
            elseif missing ~= nil then
                reason = "PARTICIPANT_NOT_ON_DISK:" .. missing
            elseif missionInfo.xmlFile == nil or missionInfo.xmlFile == 0 then
                reason = "NO_CAREER_FILE"
            else
                s.careerSet(missionInfo.xmlFile, "careerSavegame#" .. C.MARKER, pass.marker)
                status, reason, pass.digest = "WRITTEN", nil, digest
            end
        end
    end
    C.last = { generation = pass.generation, status = status, reason = reason, marker = pass.marker, digest = pass.digest,
        directory = missionInfo.savegameDirectory, participants = clone(pass.participants), journalCount = pass.journalCount }
    if status == "WRITTEN" then
        logf("info", "RLAnimalIdentityCheckpoint: generation %d written (%s), waiting for the engine to finish the save", pass.generation, pass.marker)
    else
        logf("error", "RLAnimalIdentityCheckpoint: generation %d not complete: %s", pass.generation, tostring(reason))
    end
end


function C.verifyFinal(directory, last)
    if directory == nil then return "NO_DIRECTORY" end
    local career = readMarker(directory .. "/careerSavegame.xml", "careerSavegame")
    if career ~= last.marker then return "CAREER_MARK_NOT_IN_SAVE:" .. tostring(career) end
    local check = readLedgerFile(directory)
    if check.doc == nil or check.doc.meta.digest ~= last.digest or check.doc.meta.generation ~= last.generation then
        return "LEDGER_NOT_IN_SAVE:" .. tostring(check.doc ~= nil and "OTHER_GENERATION" or check.error)
    end
    local missing = verifyParticipants(directory, last)
    if missing ~= nil then return "PARTICIPANT_NOT_IN_SAVE:" .. missing end
    return nil
end


function C.onSaveComplete(errorCode, directory)
    if C.pass ~= nil then
        C.last = { generation = C.pass.generation, status = "ABORTED", reason = "SAVE_ENDED_INSIDE_PASS" }
        C.pass = nil
    end
    local last = C.last
    if last == nil or last.engine ~= nil then return end
    last.engine = tostring(errorCode)
    if last.status ~= "WRITTEN" then return end
    if Savegame ~= nil and errorCode ~= Savegame.ERROR_OK then
        last.status, last.reason = "FAILED", "ENGINE_ERROR"
    else
        local ran, wrong = pcall(C.verifyFinal, directory or last.directory, last)
        if not ran then wrong = "FINAL_CHECK_THREW:" .. tostring(wrong) end
        if wrong == nil then last.status = "COMMITTED" else last.status, last.reason = "INCOMPLETE", wrong end
    end
    if last.status == "COMMITTED" then
        C.committed = last.generation
        -- The keys the committed save absorbed leave the journal; later ones stay.
        local keys, kept = R.journalKeys(), {}
        for i = (last.journalCount or 0) + 1, #keys do kept[#kept + 1] = keys[i] end
        R.journal, R.journalDirty = kept, #kept > 0
        logf("info", "RLAnimalIdentityCheckpoint: generation %d committed (%s)", last.generation, last.marker)
    else
        logf("error", "RLAnimalIdentityCheckpoint: generation %d not committed: %s (engine %s)", last.generation, tostring(last.reason), last.engine)
    end
end


-- -------------------------------------------------------------------------------------------
-- Unsaved-key journal
-- -------------------------------------------------------------------------------------------

--- Write the journal when it changed. Cheap enough to call every hour. Returns true when written.
function C.flushJournal(missionInfo)
    if not C.armed or R.ledger == nil or not R.journalDirty or C.state ~= C.READY then return false end
    local directory = missionInfo ~= nil and missionInfo.savegameDirectory or nil
    if directory == nil then return false end
    local keys = R.journalKeys()
    if #keys > P.MAX_JOURNAL_KEYS then
        logf("error", "RLAnimalIdentityCheckpoint: %d unsaved keys exceed the journal limit - save the game", #keys)
        return false
    end
    local s = storage()
    local xml = s.create(directory .. "/" .. P.JOURNAL_FILENAME, P.JOURNAL_ROOT)
    if xml == nil then return false end
    local data = { lineage = C.lineage, generation = C.committed, sequence = R.ledger.writerSequence, keys = clone(keys) }
    local written = P.writeJournal(xml, data)
    written = written and xml:save() == true
    xml:delete()
    if written then R.journalDirty = false end
    return written
end


-- -------------------------------------------------------------------------------------------
-- Load
-- -------------------------------------------------------------------------------------------

--- At the end of RLRM's onStartMission (server). `mission` = g_currentMission. Never moves an asset.
function C.onMissionStarted(mission)
    if not C.server or C.state ~= C.LOADING then return end
    local info = mission.missionInfo
    local directory = info ~= nil and info.savegameDirectory or nil
    if directory == nil then
        C.state, C.reason = C.DISABLED, "NO_DIRECTORY"
        R.setLoaded(nil, "READY", "NO_DIRECTORY")
        return
    end
    local markers = {}
    markers.career = readMarker(directory .. "/careerSavegame.xml", "careerSavegame")
    for _, name in ipairs(C.PARTICIPANTS) do markers[name] = readMarker(directory .. "/" .. C.FILES[name], C.ROOTS[name]) end
    local file = readLedgerFile(directory)
    local anyMarker = false
    for _, value in pairs(markers) do if value ~= nil and value ~= false then anyMarker = true end end

    local scan = RLAnimalIdentityWorld ~= nil and RLAnimalIdentityWorld.scan(mission) or nil
    if scan ~= nil then
        R.setLive(scan.records)
        if #scan.partial > 0 then logf("warning", "RLAnimalIdentityCheckpoint: world scan partial: %s", table.concat(scan.partial, "; ")) end
    end
    R.lineage = nil

    if not file.present then
        if anyMarker then
            C.lineage, C.armed = nil, false
            C.state, C.reason = C.LOADING, "LEDGER_MISSING"
            R.lineage = "L" .. stamp() .. "-" .. base36(math.random(0, 36 ^ 4 - 1), 4)
            recover("LEDGER_MISSING")
            return
        end
        C.lineage = "L" .. stamp() .. "-" .. base36(math.random(0, 36 ^ 4 - 1), 4)
        R.lineage = C.lineage
        C.state, C.reason, C.armed = C.READY, "NO_LEDGER_YET", false
        R.setLoaded(nil, "READY", "NO_LEDGER_YET")
        logf("info", "RLAnimalIdentityCheckpoint: no ledger in this save (shadow mode); rlIdentityActivate starts it")
        return
    end
    if file.doc == nil then
        R.lineage = "L" .. stamp() .. "-" .. base36(math.random(0, 36 ^ 4 - 1), 4)
        recover("LEDGER_UNREADABLE:" .. tostring(file.error))
        return
    end
    local doc = file.doc
    local want = doc.meta.lineage .. ":" .. string.format("%d", doc.meta.generation)
    local wrong = {}
    for _, name in ipairs(C.PARTICIPANTS) do
        if doc.data.participants[name] ~= true or markers[name] ~= want then wrong[#wrong + 1] = name .. "=" .. tostring(markers[name]) end
    end
    if markers.career ~= want then wrong[#wrong + 1] = "career=" .. tostring(markers.career) end
    C.lineage, C.generation, C.committed, C.armed = doc.meta.lineage, doc.meta.generation, doc.meta.generation, true
    R.lineage = C.lineage
    R.setLoaded(doc.ledger, "READY", "LOADED_VERIFIED")
    if #wrong > 0 then recover("MARKER_MISMATCH:" .. table.concat(wrong, ";")) return end
    if doc.data.recovery ~= nil then recover("RECOVERY_CARRIED:" .. tostring(doc.data.recovery)) return end

    -- The unsaved session's keys.
    local s = storage()
    local jpath = directory .. "/" .. P.JOURNAL_FILENAME
    if s.exists(jpath) then
        local ok, xml = pcall(s.load, jpath)
        local journal, why
        if ok and xml ~= nil then
            local readOk
            readOk, journal, why = pcall(P.readJournal, xml)
            xml:delete()
            if not readOk then journal, why = nil, "READ_THREW:" .. tostring(journal) end
        else
            why = "PARSE_FAILED"
        end
        if journal == nil then recover("JOURNAL_UNREADABLE:" .. tostring(why)) return end
        if journal.meta.lineage ~= C.lineage then recover("JOURNAL_OTHER_LINEAGE") return end
        if journal.meta.generation > C.committed then recover("JOURNAL_FUTURE_GENERATION") return end
        if journal.meta.generation == C.committed then
            local keys = {}
            for i, key in ipairs(journal.data.keys) do
                local farmId, uniqueId, country = I.parseKey(key)
                keys[i] = { farmId = farmId, uniqueId = uniqueId, country = country }
            end
            local burned = I.burnUnsaved(R.ledger, keys)
            if burned == nil then recover("JOURNAL_BAD_KEYS") return end
            logf("info", "RLAnimalIdentityCheckpoint: %d key(s) of an unsaved session burned (%d new)", #keys, burned)
            R.journal, R.journalDirty = {}, false
            for _, key in ipairs(journal.data.keys) do R.journal[#R.journal + 1] = key end
            R.journalDirty = #R.journal > 0
        end
    end
    C.state, C.reason = C.READY, "LOADED_VERIFIED"
    logf("info", "RLAnimalIdentityCheckpoint: ledger generation %d loaded (%s), mode %s", doc.meta.generation, C.lineage, tostring(R.mode))
end


--- After a successful activation: the save from now on carries the ledger.
function C.arm()
    if R.ledger == nil or type(R.lineage) ~= "string" or C.state ~= C.READY then return nil, "NOT_ARMABLE" end
    C.lineage, C.armed = R.lineage, true
    return true
end


--- User decision after looking at the evidence: carry on with the ledger as loaded.
function C.recoveryClear()
    if C.state ~= C.RECOVERY_REQUIRED then return nil, "NOT_IN_RECOVERY" end
    C.recovery = nil
    C.state, C.reason = C.READY, "RECOVERY_CLEARED"
    if R.ledger ~= nil then
        if C.lineage == nil then C.lineage = R.lineage end
        C.armed = true
    end
    R.setLoaded(R.ledger, "READY", "RECOVERY_CLEARED")
    return true
end


function C.onHour()
    local mission = g_currentMission
    if mission == nil or not C.server then return end
    local ok, err = pcall(C.flushJournal, mission.missionInfo)
    if not ok then logf("error", "RLAnimalIdentityCheckpoint: journal flush failed: %s", tostring(err)) end
end


--- Wrap the game's save functions. Protected: a failure here never stops the game's save.
function C.install()
    if C.installed then return end
    C.installed = true
    local function guard(name, fn)
        return function(...)
            local ok, err = pcall(fn, ...)
            if not ok then
                logf("error", "RLAnimalIdentityCheckpoint.%s failed: %s", name, tostring(err))
                if C.pass ~= nil and (name == "onSaveBegin" or name == "marker") then C.pass.data, C.pass.error = nil, "HOOK_FAILED:" .. tostring(err) end
            end
        end
    end
    if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
        FSCareerMissionInfo.saveToXMLFile = Utils.prependedFunction(FSCareerMissionInfo.saveToXMLFile,
            guard("onSaveBegin", function(self) C.onSaveBegin(self) end))
        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile,
            guard("onSaveEnd", function(self) C.onSaveEnd(self) end))
    end
    if PlaceableSystem ~= nil and PlaceableSystem.saveToXML ~= nil then
        PlaceableSystem.saveToXML = Utils.prependedFunction(PlaceableSystem.saveToXML,
            guard("marker", function(_, xml) C.markParticipant("placeables", xml, "placeables") end))
    end
    if VehicleSystem ~= nil and VehicleSystem.saveToXML ~= nil then
        VehicleSystem.saveToXML = Utils.prependedFunction(VehicleSystem.saveToXML,
            guard("marker", function(_, _, xml) C.markParticipant("vehicles", xml, "vehicles") end))
    end
    if Farm ~= nil and Farm.saveToXMLFile ~= nil then
        Farm.saveToXMLFile = Utils.appendedFunction(Farm.saveToXMLFile,
            guard("marker", function(_, xml) C.markParticipant("farms", xml, "farms") end))
    end
    if SavegameController ~= nil and SavegameController.onSaveComplete ~= nil then
        SavegameController.onSaveComplete = Utils.appendedFunction(SavegameController.onSaveComplete,
            guard("onSaveComplete", function(controller, errorCode, finalDirectory)
                local savegame = controller ~= nil and controller.currentSavegame or nil
                C.onSaveComplete(errorCode, savegame ~= nil and savegame.savegameDirectory or finalDirectory)
            end))
    end
end
