--[[
    T02 batch 4: the trade ledger saved with the savegame, at the same point as the assets it
    talks about, and checked on load before any T02 transaction may start.

    Save (server). The game writes every XML file of a save in one synchronous call,
    FSCareerMissionInfo:saveToXMLFile (FS25 v1.23.1): placeables.xml (pens, Hof Bergmann's
    orders), vehicles.xml (livestock trailers), ..., farms.xml (money, statistics), then
    careerSavegame.xml; RLRM's own files follow in its appended hook. No frame, network event or
    production update runs inside that call, so the files describe one moment. Here:

        begin   (prepended)   new generation G; new T02 transactions refused; the ledger frozen
        markers (in the pass) "<lineage>:G" written at the root of placeables.xml, vehicles.xml
                              and farms.xml through the game's own open document, before it saves
        end     (appended,    rm_RlTradeLedger.xml written and read back (schema, digest, G);
                 after RLRM)  only then "<lineage>:G" at the root of careerSavegame.xml, saved
                              again: the commit mark. The gate reopens.
        engine result         SavegameController:onSaveComplete's error code is recorded.

    The ledger, markers and pass are written only once T02 was enabled in this savegame (TEST set
    once, or a ledger loaded): a save that never used T02 gets nothing. Disabling the modes later
    keeps writing the ledger, so its records and locks are never dropped.

    Load (server), at the end of RLRM's onStartMission, after the game loaded every file, after
    RLRM's identity repair, before the first herdsman day and before a mode can be set:
    LOADING -> VERIFYING -> READY or RECOVERY_REQUIRED (RLTradeRecovery.decideLoad). Until READY
    every new T02 transaction is refused and TEST cannot be set. A READY load keeps finished
    records as replay-only, unfinished ones as NEEDS_RECONCILIATION with their locks (scoped, so
    unrelated work may run), and cancels a record that never left PREPARED. A RECOVERY_REQUIRED load
    keeps what it could read for the report, refuses all new T02 transactions, keeps a damaged
    ledger's text beside the save (rm_RlTradeLedger.quarantine.txt), and every later save writes the
    ledger as RECOVERY_REQUIRED again - a save never launders it. Nothing is paid, refunded, put
    back or unlocked automatically (no L3). The old sale and delivery paths are not affected.

    Ids. Each load starts an epoch; transaction ids and herdsman rounds carry its tag, so ids from
    a previous run or an older backup are never issued again. Clients load and save nothing.
]]

RLTradeCheckpoint = {}
local C = RLTradeCheckpoint

local Log = RmLogging.getLogger("RLRM")

C.MARKER = "rlTradeCheckpoint"
C.QUARANTINE_FILENAME = "rm_RlTradeLedger.quarantine.txt"
C.MAX_RECORDS = 5000            -- records of one epoch; beyond, new transactions are refused
C.MAX_QUARANTINE = 4 * 1024 * 1024

C.DISABLED = "DISABLED"
C.LOADING = "LOADING"
C.VERIFYING = "VERIFYING"
C.READY = "READY"
C.RECOVERY_REQUIRED = "RECOVERY_REQUIRED"


local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
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


--- New instance for a map load. Server: LOADING (closed); client: DISABLED.
function C.reset(isServer)
    C.state = isServer and C.LOADING or C.DISABLED
    C.reason = isServer and "WAITING_FOR_ASSETS" or "CLIENT"
    C.armed, C.lineage, C.generation = false, nil, 0
    C.epoch, C.epochTag, C.epochStart = 0, nil, 0
    C.pass, C.last, C.load, C.quarantine = nil, nil, nil, nil
    C.loadedPayments = {}
    C.attach(RLContractTrade.store)
end


--- Put the gate in front of a ledger's begin.
function C.attach(store)
    if store ~= nil then store.admit = C.admit end
end


--- RLTradeTransaction.begin's gate: closed while loading, verifying, saving, after a failed
--- check, or when this epoch's records reach the cap.
function C.admit(store)
    if C.pass ~= nil then return false, "SAVE_IN_PROGRESS" end
    if C.state ~= C.READY then return false, "RECOVERY_GATE:" .. tostring(C.state) .. ":" .. tostring(C.reason) end
    -- The files on disk are not one checkpoint after a broken save: no new work until a save
    -- completes again.
    if C.last ~= nil and (C.last.status == "INCOMPLETE" or C.last.status == "ABORTED" or C.last.status == "FAILED") then
        return false, "LAST_SAVE_" .. C.last.status .. ":" .. tostring(C.last.generation)
    end
    if store.sequence - C.epochStart >= C.MAX_RECORDS then return false, "LEDGER_FULL" end
    return true
end


--- Whether TEST may be set now; setting it arms the ledger for this savegame. Without a
--- checkpoint instance (tests of earlier batches) always true and nothing is armed.
function C.allowTest()
    if C.state == nil then return true end
    if C.state ~= C.READY then return false end
    if not C.armed then
        C.armed = true
        C.lineage = C.lineage or ("L" .. stamp() .. "-" .. base36(math.random(0, 36 ^ 4 - 1), 4))
        if C.epochTag == nil then C.newEpoch(0) end
        Log:info("RLTradeCheckpoint: ledger armed for this savegame (lineage %s); it is saved with every save from now on", C.lineage)
    end
    return true
end


function C.newEpoch(previous)
    C.epoch = (previous or 0) + 1
    C.epochTag = string.format("%d%s", C.epoch, base36(math.random(0, 36 ^ 3 - 1), 3))
end


--- The tag every transaction id and herdsman round of this epoch carries ("" before a load).
function C.idTag()
    return C.epochTag ~= nil and ("-e" .. C.epochTag) or ""
end


-- -------------------------------------------------------------------------------------------
-- Save
-- -------------------------------------------------------------------------------------------

--- The data written for generation G. Receipts are evidence and are sanitized; records and
--- money receipts must pass RLTradeTransaction.import as they are.
function C.buildData(generation)
    local store = RLContractTrade.store
    local current = {}
    for id in pairs(store.payments or {}) do
        if not C.loadedPayments[id] then current[id] = true end
    end
    local receipts = { contract = RLContractTrade.receipts or {}, sale = RLLiveSale ~= nil and RLLiveSale.receipts or {} }
    local limits = RLTradePersistence.LIMITS
    if C.state == C.RECOVERY_REQUIRED then
        -- Keep every piece of evidence while recovery is required: nothing is pruned.
        limits = copy(limits)
        limits.detailed, limits.tombstones, limits.wages = math.huge, math.huge, math.huge
    end
    local ledger, kept, stats = RLTradePersistence.compact(RLTradeTransaction.export(store), receipts, C.epochStart, current, limits)
    local imported, why = RLTradeTransaction.import(ledger)
    if imported == nil then return nil, "LEDGER_INVALID:" .. tostring(why) end
    return {
        schema = RLTradePersistence.SCHEMA, lineage = C.lineage, generation = generation, epoch = C.epoch,
        sequences = { contract = RLContractTrade.sequence or 0, sale = RLLiveSale ~= nil and RLLiveSale.sequence or 0,
            round = RLLiveSale ~= nil and RLLiveSale.roundSequence or 0 },
        ledger = ledger, receipts = RLTradePersistence.sanitize(kept), retention = stats,
        load = C.load ~= nil and { state = C.load.state, reason = C.load.reason, generation = C.load.generation } or nil,
    }
end


--- Prepended to FSCareerMissionInfo:saveToXMLFile.
local function abortPass(reason)
    local pass = C.pass
    C.pass = nil
    C.last = { generation = pass.generation, status = "ABORTED", reason = reason, participants = copy(pass.participants) }
    Log:error("RLTradeCheckpoint: generation %d did not finish (%s) - T02 stays closed until a save completes", pass.generation, reason)
end


function C.onSaveBegin(missionInfo)
    if C.pass ~= nil then abortPass("NEXT_SAVE_STARTED") end
    if C.state == nil or C.state == C.DISABLED or C.state == C.LOADING or C.state == C.VERIFYING or not C.armed then return end
    -- The generation advances here: a pass that never ends leaves its number used, so the next
    -- pass can never share it with files of the broken one.
    local generation = C.generation + 1
    C.generation = generation
    local data, why = C.buildData(generation)
    C.pass = { generation = generation, marker = C.lineage .. ":" .. string.format("%d", generation), participants = {},
        data = data, error = why }
    if data == nil then Log:error("RLTradeCheckpoint: generation %d not written: %s", generation, tostring(why)) end
end


--- A participant file's document, before the game saves it.
function C.markParticipant(name, xmlFile, root)
    local pass = C.pass
    if pass == nil or pass.data == nil or xmlFile == nil then return end
    xmlFile:setString(root .. "#" .. C.MARKER, pass.marker)
    pass.participants[name] = true
end


local function writeQuarantine(directory)
    if C.quarantine == nil or io == nil or io.open == nil then return end
    local handle = io.open(directory .. "/" .. C.QUARANTINE_FILENAME, "wb")
    if handle == nil then return end
    handle:write(C.quarantine.text)
    handle:close()
end


local readMarker


--- Read back each participant file this pass wrote: a marked one must carry this pass's marker,
--- an unmarked one none (its save then failed and left an older file). nil when all match.
function C.verifyParticipants(missionInfo, pass)
    local directory = missionInfo.savegameDirectory
    local files = { placeables = { missionInfo.placeablesXML or (directory .. "/placeables.xml"), "placeables" },
        vehicles = { missionInfo.vehiclesXML or (directory .. "/vehicles.xml"), "vehicles" },
        farms = { missionInfo.farmsXML or (directory .. "/farms.xml"), "farms" } }
    local wrong = {}
    for _, name in ipairs(RLTradeRecovery.PARTICIPANTS) do
        local found = readMarker(files[name][1], files[name][2])
        local want = pass.participants[name] and pass.marker or nil
        if found ~= want then wrong[#wrong + 1] = name .. "=" .. tostring(found) end
    end
    return #wrong > 0 and table.concat(wrong, ";") or nil
end


--- Appended to FSCareerMissionInfo:saveToXMLFile, after RLRM's own files.
function C.onSaveEnd(missionInfo)
    local pass = C.pass
    if pass == nil then return end
    C.pass = nil
    local status, reason = "INCOMPLETE", pass.error
    if pass.data ~= nil then
        pass.data.participants = pass.participants
        local directory = missionInfo.savegameDirectory
        local path = directory .. "/" .. RLTradePersistence.FILENAME
        local meta = { lineage = C.lineage, generation = pass.generation,
            integrity = C.state == C.RECOVERY_REQUIRED and RLTradePersistence.INTEGRITY_RECOVERY or RLTradePersistence.INTEGRITY_OK,
            reason = C.state == C.RECOVERY_REQUIRED and C.reason or nil }
        local xml = XMLFile.create("rlTradeLedgerXML", path, RLTradePersistence.ROOT)
        local written, digest = false, nil
        if xml ~= nil then
            written, digest = RLTradePersistence.writeDocument(xml, meta, pass.data)
            written = written and xml:save() == true
            xml:delete()
        end
        writeQuarantine(directory)
        if not written then
            reason = "LEDGER_WRITE_FAILED:" .. tostring(digest)
        else
            local check = XMLFile.loadIfExists("rlTradeLedgerCheck", path)
            local doc, why = nil, "NOT_READABLE"
            if check ~= nil then
                doc, why = RLTradePersistence.readDocument(check)
                check:delete()
            end
            local missing = C.verifyParticipants(missionInfo, pass)
            if doc == nil or doc.meta.digest ~= digest or doc.meta.generation ~= pass.generation then
                reason = "LEDGER_READBACK_FAILED:" .. tostring(why)
            elseif missing ~= nil then
                reason = "PARTICIPANT_NOT_ON_DISK:" .. missing
            elseif missionInfo.xmlFile == nil or missionInfo.xmlFile == 0 then
                reason = "NO_CAREER_FILE"
            else
                setXMLString(missionInfo.xmlFile, "careerSavegame#" .. C.MARKER, pass.marker)
                if saveXMLFile(missionInfo.xmlFile) then
                    status, reason = "WRITTEN", nil
                else
                    reason = "CAREER_MARK_FAILED"
                end
            end
        end
    end
    C.last = { generation = pass.generation, status = status, reason = reason, participants = copy(pass.participants) }
    if status == "WRITTEN" then
        Log:info("RLTradeCheckpoint: generation %d written (%s)", pass.generation, pass.marker)
    else
        Log:error("RLTradeCheckpoint: generation %d not complete: %s - a load of this save will require recovery",
            pass.generation, tostring(reason))
    end
end


--- Appended to SavegameController:onSaveComplete.
function C.onSaveComplete(errorCode)
    if C.pass ~= nil then abortPass("SAVE_ENDED_INSIDE_PASS") end
    local last = C.last
    if last == nil or last.engine ~= nil then return end
    last.engine = tostring(errorCode)
    local ok = Savegame == nil or errorCode == Savegame.ERROR_OK
    if last.status == "WRITTEN" then last.status = ok and "COMMITTED" or "FAILED" end
end


-- -------------------------------------------------------------------------------------------
-- Load
-- -------------------------------------------------------------------------------------------

function readMarker(path, root)
    if path == nil or not fileExists(path) then return nil end
    local ok, xml = pcall(XMLFile.load, "rlTradeMarker", path)
    if not ok or xml == nil then return false end
    local value = xml:getString(root .. "#" .. C.MARKER)
    xml:delete()
    return value
end


local function readRaw(path)
    if io == nil or io.open == nil then return nil end
    local handle = io.open(path, "rb")
    if handle == nil then return nil end
    local text = handle:read(C.MAX_QUARANTINE)
    handle:close()
    return text
end


local function readLedger(directory)
    local path = directory .. "/" .. RLTradePersistence.FILENAME
    if not fileExists(path) then return { present = false } end
    local ok, xml = pcall(XMLFile.load, "rlTradeLedgerXML", path)
    if not ok or xml == nil then return { present = true, error = "PARSE_FAILED", path = path } end
    local readOk, doc, why = pcall(RLTradePersistence.readDocument, xml)
    xml:delete()
    if not readOk then return { present = true, error = "READ_THREW:" .. tostring(doc), path = path } end
    if doc == nil then return { present = true, error = why, path = path } end
    local data = doc.data
    for _, name in ipairs({ "contract", "sale", "round" }) do
        local n = type(data.sequences) == "table" and data.sequences[name] or nil
        if type(n) ~= "number" or n < 0 or n % 1 ~= 0 then return { present = true, error = "BAD_SEQUENCES", path = path } end
    end
    if type(data.epoch) ~= "number" or data.epoch < 0 or data.epoch % 1 ~= 0 then return { present = true, error = "BAD_EPOCH", path = path } end
    if type(data.participants) ~= "table" then return { present = true, error = "NO_PARTICIPANTS", path = path } end
    for name, value in pairs(data.participants) do
        if type(name) ~= "string" or value ~= true then return { present = true, error = "BAD_PARTICIPANTS", path = path } end
    end
    local store
    store, why = RLTradeTransaction.import(type(data.ledger) == "table" and data.ledger or nil)
    if store == nil then return { present = true, error = "BAD_RECORDS:" .. tostring(why), path = path } end
    return { present = true, doc = doc, path = path }
end


--- What every lock of the ledger points at now (report only; a lock is never moved or freed).
function C.rebind(store, mission)
    local found = {}
    local function scan(owner)
        if owner == nil then return end
        if owner.uniqueId ~= nil then found["source:" .. tostring(owner.uniqueId)] = true end
        local ok, clusterSystem = pcall(function() return owner:getClusterSystem() end)
        if ok and type(clusterSystem) == "table" and type(clusterSystem.animals) == "table" then
            for _, animal in ipairs(clusterSystem.animals) do
                local key = RLTradeSourceAdapter.identityKey(animal)
                if key ~= nil then found["animal:" .. key] = true end
            end
        end
    end
    pcall(function()
        for _, placeable in pairs(mission.husbandrySystem ~= nil and mission.husbandrySystem.placeables or {}) do scan(placeable) end
        for _, vehicle in pairs(mission.vehicleSystem ~= nil and mission.vehicleSystem.vehicles or {}) do
            if vehicle.spec_livestockTrailer ~= nil then scan(vehicle) end
        end
    end)
    local report = {}
    for key, owner in pairs(store.locks) do
        local status = "UNCHECKED"
        if key:find("^animal:") or key:find("^source:") then status = found[key] and "FOUND" or "MISSING" end
        report[#report + 1] = { key = key, owner = owner, status = status }
    end
    table.sort(report, function(a, b) return a.key < b.key end)
    return report
end


--- At the end of RLRM's onStartMission (server). Reads the ledger and the markers and opens or
--- keeps closed the T02 gate. Never moves an asset.
--- @param mission table g_currentMission
--- @param notes table|nil { identityRepairs = n }
function C.onMissionStarted(mission, notes)
    if C.state ~= C.LOADING then return end
    C.state, C.reason = C.VERIFYING, "READING"
    local info = mission.missionInfo
    local directory = info ~= nil and info.savegameDirectory or nil
    local evidence = { ledger = { present = false }, markers = {} }
    if directory ~= nil then
        evidence.ledger = readLedger(directory)
        evidence.markers.career = readMarker(directory .. "/careerSavegame.xml", "careerSavegame")
        evidence.markers.placeables = readMarker(info.placeablesXML or (directory .. "/placeables.xml"), "placeables")
        evidence.markers.vehicles = readMarker(info.vehiclesXML or (directory .. "/vehicles.xml"), "vehicles")
        evidence.markers.farms = readMarker(info.farmsXML or (directory .. "/farms.xml"), "farms")
    end
    local decision = RLTradeRecovery.decideLoad(evidence)
    local doc = evidence.ledger.doc
    local cancelled, kept = 0, 0
    -- The highest generation any file shows: a later save never reuses a number already on disk.
    local best
    for _, marker in pairs(evidence.markers) do
        if type(marker) == "string" then
            local lineage, generation = marker:match("^(L[%w%-]+):(%d+)$")
            if lineage ~= nil and (best == nil or tonumber(generation) > best.generation) then
                best = { lineage = lineage, generation = tonumber(generation) }
            end
        end
    end

    if doc ~= nil then
        local data = doc.data
        local ledger = copy(data.ledger)
        if decision.state == RLTradeRecovery.READY then
            for _, record in pairs(ledger.records) do
                if RLTradeRecovery.decideRecord(record) == RLTradeRecovery.CANCEL_NEVER_STARTED then
                    record.state, record.reason = "REJECTED", "CANCELLED_AT_RELOAD:NEVER_STARTED"
                    record.history[#record.history + 1] = "REJECTED"
                    cancelled = cancelled + 1
                end
            end
        end
        local store = RLTradeTransaction.import(ledger)
        if store == nil then
            store = RLTradeTransaction.new()
            decision = { state = RLTradeRecovery.RECOVERY_REQUIRED, level = "L2", reason = "RECORDS_NOT_IMPORTED" }
        end
        for _, record in pairs(store.records) do
            if not RLTradeTransaction.FINISHED[record.state] then kept = kept + 1 end
        end
        -- A verified checkpoint scopes the unfinished records to their own locks.
        if decision.state == RLTradeRecovery.READY then store.recoveryRequired = false end
        RLContractTrade.store = store
        RLContractTrade.receipts = copy(type(data.receipts) == "table" and data.receipts.contract or {}) or {}
        RLContractTrade.sequence = data.sequences.contract
        if RLLiveSale ~= nil then
            RLLiveSale.receipts = copy(type(data.receipts) == "table" and data.receipts.sale or {}) or {}
            RLLiveSale.sequence, RLLiveSale.roundSequence = data.sequences.sale, data.sequences.round
        end
        for id in pairs(store.payments) do C.loadedPayments[id] = true end
        C.lineage, C.generation, C.armed = doc.meta.lineage, math.max(doc.meta.generation, best ~= nil and best.generation or 0), true
        C.newEpoch(data.epoch)
    elseif decision.state == RLTradeRecovery.RECOVERY_REQUIRED then
        -- No readable ledger: continue the lineage and generation the markers show, keep the text.
        C.lineage = best ~= nil and best.lineage or ("L" .. stamp() .. "-" .. base36(math.random(0, 36 ^ 4 - 1), 4))
        C.generation, C.armed = best ~= nil and best.generation or 0, true
        RLContractTrade.store.recoveryRequired = true
        C.newEpoch(0)
        if evidence.ledger.present and evidence.ledger.path ~= nil then
            local text = readRaw(evidence.ledger.path)
            if text ~= nil then C.quarantine = { text = text, reason = decision.reason } end
        end
    else
        C.newEpoch(0)
    end

    C.epochStart = RLContractTrade.store.sequence
    C.attach(RLContractTrade.store)
    if decision.state == RLTradeRecovery.RECOVERY_REQUIRED then RLContractTrade.store.recoveryRequired = true end
    C.state = decision.state == RLTradeRecovery.RECOVERY_REQUIRED and C.RECOVERY_REQUIRED or C.READY
    C.reason = decision.reason
    C.load = { state = decision.state, level = decision.level, reason = decision.reason,
        generation = doc ~= nil and doc.meta.generation or nil, lineage = C.lineage, markers = copy(evidence.markers),
        cancelled = cancelled, unfinished = kept, identityRepairs = notes ~= nil and notes.identityRepairs or 0,
        resources = C.rebind(RLContractTrade.store, mission), ledgerError = evidence.ledger.error }
    local level = C.state == C.READY and "info" or "error"
    Log[level](Log, "RLTradeCheckpoint: %s (%s); %d unfinished record(s) held, %d never-started cancelled",
        C.state, tostring(C.reason), kept, cancelled)
end


--- Wrap the game's save functions. Every hook is protected: a failure here never stops the
--- game's save; it only leaves this save's checkpoint incomplete (detected on load).
function C.install()
    local function guard(name, fn)
        return function(...)
            local ok, err = pcall(fn, ...)
            if not ok then
                Log:error("RLTradeCheckpoint.%s failed: %s", name, tostring(err))
                if name == "onSaveBegin" or name == "marker" then
                    if C.pass ~= nil then C.pass.data, C.pass.error = nil, "HOOK_FAILED:" .. tostring(err) end
                end
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
            guard("marker", function(_, xmlFile) C.markParticipant("placeables", xmlFile, "placeables") end))
    end
    if VehicleSystem ~= nil and VehicleSystem.saveToXML ~= nil then
        VehicleSystem.saveToXML = Utils.prependedFunction(VehicleSystem.saveToXML,
            guard("marker", function(_, _, xmlFile) C.markParticipant("vehicles", xmlFile, "vehicles") end))
    end
    if Farm ~= nil and Farm.saveToXMLFile ~= nil then
        Farm.saveToXMLFile = Utils.appendedFunction(Farm.saveToXMLFile,
            guard("marker", function(_, xmlFile) C.markParticipant("farms", xmlFile, "farms") end))
    end
    if SavegameController ~= nil and SavegameController.onSaveComplete ~= nil then
        SavegameController.onSaveComplete = Utils.appendedFunction(SavegameController.onSaveComplete,
            guard("onSaveComplete", function(_, errorCode) C.onSaveComplete(errorCode) end))
    end
end
