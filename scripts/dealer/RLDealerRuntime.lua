-- Map lifecycle for the dormant v2 channel. Loading saved evidence never turns
-- on generation, purchases, source progression or automatic money recovery.
RLDealerRuntime = { VERSION = 1, CHANNEL_ENABLED = false }
local R = RLDealerRuntime
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function resolve(name)
    local system = g_currentMission and g_currentMission.animalSystem
    if system == nil then return nil end
    -- Engine subtype indices are map-local; persisted names must match exactly.
    local found, index
    for key, sub in pairs(system.subTypes or {}) do
        if sub.name == name then
            if found ~= nil and found ~= sub then return nil end
            found = sub
            index = sub.subTypeIndex or (type(key) == "number" and key)
        end
    end
    return found, index
end
local function close(reason, evidence)
    R.state, R.reason, R.evidence = "RECOVERY_REQUIRED", reason, evidence
    if R.store then R.store.recoveryRequired = true end
    RLDealerCheckpoint.state, RLDealerCheckpoint.reason = RLDealerCheckpoint.RECOVERY_REQUIRED, reason
end
function R.reset(isServer)
    R.server, R.store, R.evidence, R.discardedWal = isServer == true, nil, nil, nil
    R.service, R.parts, R.capabilities = nil, nil, {}
    R.CHANNEL_ENABLED = false
    R.lastTickBlock, R.lastTickPause = nil, nil
    R.state, R.reason = isServer and "LOADING" or "DISABLED", isServer and "WAITING_FOR_MISSION" or "CLIENT"
    -- Events from an earlier map must never retain a service or authority handle.
    if RLDealerPurchaseEvent then RLDealerPurchaseEvent.service = nil end
    if RLDealerQuoteEvent then RLDealerQuoteEvent.service = nil end
    if RLDealerCatalogEvent then RLDealerCatalogEvent.service = nil end
    local runtime = {
        resolver = resolve,
        ownershipContext = {isServer=R.server, resolveDiseaseModel=function(title)
            local manager = g_diseaseManager
            if manager and type(manager.getDiseaseByTitle) == "function" then return manager:getDiseaseByTitle(title) end
        end},
        getSnapshot = function(meta, participants)
            if R.store == nil or R.store.recoveryRequired then return nil, "STOCK_NOT_READY" end
            return RLDealerStockService.buildSnapshot(R.store, meta, participants)
        end,
        acceptLoaded = function(data, restored)
            local stock, why = RLDealerStockService.fromVerifiedDocument({ state = "VERIFIED", data = data,
                restored = restored, sourceResolution = "RESOLVED" })
            if not stock then R.reason = why; return false end
            R.store = stock
            return true
        end,
    }
    R.checkpointRuntime = runtime
    RLDealerCheckpoint.reset(R.server, runtime)
end
-- Kept separate for fault-injection tests and future explicit recovery tools.
-- It validates evidence only; it never transfers, removes, pays or refunds.
function R.compareJournal(document, generation, lineage)
    if R.store == nil or type(document) ~= "table" or type(document.data) ~= "table" then return nil, "WAL_WITHOUT_STOCK" end
    local wal = document.data
    if RLTradePersistence.check(wal, RLDealerPersistence.LIMITS) or type(generation) ~= "number"
        or type(wal.baseGeneration) ~= "number" or wal.baseGeneration ~= wal.baseGeneration
        or wal.lineage ~= lineage or wal.baseGeneration > generation then return nil, "WAL_CHECKPOINT_MISMATCH" end
    local purchase, why = RLDealerPurchase.import(wal.purchase, { forceReconciliation = true })
    if not purchase then return nil, why end
    local current = RLDealerPurchase.export(R.store.purchase)
    local recoveryMatches = wal.recovery == nil and R.store.sourceOwners == nil
    local currentRecovery
    if R.store.sourceOwners ~= nil then
        local ownership, failure = RLDealerOwnedStock.export(R.store.sourceOwners, R.store.sourceBindings,
            R.store.sourceRecordsByOwner, R.store.observedChildren, R.store.farm.sources, R.store.farm.clock.months, R.store.retiredSources)
        if not ownership then return nil, failure end
        currentRecovery = {version=1,clockMonths=R.store.farm.clock.months,sources=copy(R.store.farm.sources),sourceOwnership=ownership}
        if R.store.money then currentRecovery.money=RLDealerMoneyAdapter.export(R.store.money) end
        local recovery = wal.recovery
        if recovery ~= nil and wal.version == 1 then
            -- Compare the same effective state on both sides, retaining raw WAL evidence.
            recovery = RLDealerPersistence.migrateRearingSnapshot(recovery)
            recovery.version = 1
        end
        recoveryMatches = recovery ~= nil and RLTradePersistence.canonical(recovery)==RLTradePersistence.canonical(currentRecovery)
    end
    if RLTradePersistence.canonical(wal.purchase) == RLTradePersistence.canonical(current) and recoveryMatches then return true end
    -- A WAL on the generation of the last verified checkpoint was written after that save, and no
    -- later save took it in: the session that bought was left without saving (or crashed). The game
    -- writes money and animals only in a save, so the whole save on disk is before the purchase and
    -- consistent: the purchase never happened, as anything else not saved (decided 2026-10-13).
    -- The WAL is set aside as evidence; nothing is replayed, paid or refunded.
    if wal.baseGeneration == generation then
        R.discardedWal = { reason = "WAL_UNSAVED_DISCARDED", generation = generation, lineage = lineage,
            walSequence = document.data.sequence, purchase = copy(wal.purchase) }
        return true, "WAL_UNSAVED_DISCARDED"
    end
    -- A WAL from an older generation that a later save did not reconcile: retain the independently
    -- saved stock as compensation evidence. A COMMITTED WAL cannot overrule old saved
    -- source/target/money ownership by itself.
    R.evidence = { checkpointPurchase = current, checkpointRecovery=currentRecovery, wal = copy(document), generation = generation, lineage = lineage }
    R.store.purchase, R.store.recoveryRequired = purchase, true
    return nil, "WAL_ASSET_RECONCILIATION_REQUIRED"
end
--- Keep an unsaved session's WAL as evidence (rm_RlDealerPurchaseJournal.unsaved.<epoch>.xml) and
--- let the dealer go on. The engine refuses a mod deleteFile in the savegame folder ("No access to
--- folder"), so the WAL itself stays: the next journal write replaces it whole (new epoch, sequence 1)
--- and the next save replaces the folder. Loading the same WAL again finds its archive and is a no-op.
function R.archiveWal(walPath, expected)
    local epoch = type(expected) == "table" and type(expected.data) == "table" and expected.data.epoch or nil
    local tag = type(epoch) == "string" and epoch:match("^[%w%-]+$") and ("." .. epoch) or ""
    local archived = walPath:gsub("%.xml$", ".unsaved" .. tag .. ".xml")
    local io = R.archiveStorage or {
        exists = function(path) return fileExists(path) end,
        read = function(path)
            local xml = XMLFile.loadIfExists("rlDealerArchiveRead", path)
            if xml == nil then return nil end
            local ok, data, digest = pcall(RLDealerJournal.readDocument, xml)
            xml:delete()
            if not ok or data == nil then return nil end
            return { data = data, digest = digest }
        end,
        copy = function(from, to) return copyFile(from, to, true) end,
    }
    local function same(document)
        return type(document) == "table" and type(document.data) == "table"
            and not RLTradePersistence.check(document.data, RLDealerPersistence.LIMITS)
            and document.digest == expected.digest
            and RLTradePersistence.canonical(document.data) == RLTradePersistence.canonical(expected.data)
    end
    local function archive()
        if type(expected) ~= "table" or type(expected.data) ~= "table" then return nil, "WAL_ARCHIVE_EXPECTED_MISSING" end
        if not same(io.read(walPath)) then return nil, "WAL_ARCHIVE_SOURCE_CHANGED" end
        -- Never overwrite a previous, different unsaved session's evidence.
        if io.exists(archived) then
            if not same(io.read(archived)) then return nil, "WAL_ARCHIVE_CONFLICT" end
        else
            if io.copy(walPath, archived) == false then return nil, "WAL_ARCHIVE_COPY_FAILED" end
            if not same(io.read(archived)) then return nil, "WAL_ARCHIVE_READBACK_FAILED" end
        end
        if not same(io.read(walPath)) then return nil, "WAL_ARCHIVE_SOURCE_CHANGED" end
        return archived
    end
    local ok, path, why = pcall(archive)
    if not ok then path, why = nil, "WAL_ARCHIVE_UNCERTAIN" end
    if path == nil then
        close(why, { source = walPath, archive = archived, expected = copy(expected) })
        return nil, why
    end
    R.reason = "WAL_UNSAVED_DISCARDED"
    return path
end
function R.onMissionStarted(mission, evidence)
    if not R.server then return end
    RLDealerCheckpoint.onMissionStarted(mission, evidence)
    local checkpoint = RLDealerCheckpoint
    if checkpoint.state == checkpoint.RECOVERY_REQUIRED then
        close(checkpoint.reason, checkpoint.quarantine); return
    end
    local directory = mission.missionInfo and mission.missionInfo.savegameDirectory
    if directory == nil then close("NO_DIRECTORY"); return end
    local walPath = directory .. "/" .. RLDealerJournal.FILENAME
    if fileExists(walPath) then
        local journal, why = RLDealerJournal.load(directory)
        if not journal then close("WAL:" .. tostring(why), { path = walPath }); return end
        local matched
        matched, why = R.compareJournal(journal, checkpoint.generation, checkpoint.lineage)
        if not matched then close(why, R.evidence or journal); return end
        if why == "WAL_UNSAVED_DISCARDED" then
            local archived = R.archiveWal(walPath, journal)
            if not archived then return end
        end
    end
    R.state = "DORMANT"
    if R.reason ~= "WAL_UNSAVED_DISCARDED" then
        R.reason = R.store and "SAVED_STOCK_VERIFIED_CHANNEL_CLOSED" or "EMPTY_CHANNEL_CLOSED"
    end
end
-- Capabilities a channel needs beyond the code: species / map / container / role, registered by the code
-- that proved them (never by a setting). Only what was verified is true.
R.capabilities = {}
function R.setCapability(name, on) R.capabilities[name] = on == true end

--- Every condition the channel needs, with the first one that fails as its reason.
function R.gate()
    if not R.CHANNEL_ENABLED then return false, "DEALER_V2_DISABLED" end
    if R.state ~= "READY" then return false, "DEALER_STATE:" .. tostring(R.state) end
    if R.service == nil then return false, "DEALER_OWNERSHIP_ADAPTER_REQUIRED" end
    if RLAnimalIdentityRuntime == nil or not RLAnimalIdentityRuntime.authoritative() then return false, "IDENTITY_NOT_AUTHORITATIVE" end
    local checkpoint = RLDealerCheckpoint
    if checkpoint.state ~= checkpoint.READY then return false, "CHECKPOINT:" .. tostring(checkpoint.state) .. ":" .. tostring(checkpoint.reason) end
    if R.capabilities.cattleSingleplayer ~= true then return false, "CAPABILITY:cattleSingleplayer" end
    return true
end
function R.canPurchase()
    if not R.CHANNEL_ENABLED then return false, "DEALER_V2_DISABLED" end
    if R.service == nil then return false, "DEALER_OWNERSHIP_ADAPTER_REQUIRED" end
    return R.gate()
end
local function stamp()
    if getDate ~= nil then
        local ok, text = pcall(getDate, "%Y%m%d%H%M%S")
        if ok and type(text) == "string" then return text end
    end
    return os.date("%Y%m%d%H%M%S")
end
--- Switch the channel on for this session (server console / test). Builds the service from the game's
--- objects and installs the event handles. Singleplayer cattle only: nothing else has been verified.
--- Returns true, or nil and why; on failure nothing stays half installed.
function R.enable(overrides)
    overrides = overrides or {}
    if not R.server then return nil, "SERVER_ONLY" end
    if R.state ~= "DORMANT" and R.state ~= "READY" then return nil, "DEALER_STATE:" .. tostring(R.state) end
    local mission = overrides.mission or g_currentMission
    if mission.missionDynamicInfo ~= nil and mission.missionDynamicInfo.isMultiplayer then return nil, "MULTIPLAYER_NOT_VERIFIED" end
    if RLAnimalIdentityRuntime == nil or not RLAnimalIdentityRuntime.authoritative() then return nil, "IDENTITY_NOT_AUTHORITATIVE" end
    local checkpoint = RLDealerCheckpoint
    -- Nothing is armed, stored or installed until everything below has succeeded.
    local store = R.store
    if store == nil then
        local created, why = RLDealerStockService.newOwned("dealer-v2", 0)
        if not created then return nil, why end
        store = created
    end
    if store.sourceOwners == nil then return nil, "LEGACY_STORE_RECONCILIATION_REQUIRED" end
    local lineage = checkpoint.lineage
    if checkpoint.state == checkpoint.UNARMED then lineage = "DL" .. stamp() end
    if lineage == nil then return nil, "NO_LINEAGE" end
    local environment = mission.environment
    local resolveSubType = overrides.resolveSubType or resolve
    local world, why = (overrides.generationWorld or function()
        return RLDealerGameBinding.generationWorld(mission.animalSystem, AnimalType.COW, RLDealerGameBinding.now(environment))
    end)()
    if not world then return nil, "WORLD:" .. tostring(why) end
    local eligible = overrides.eligible or RLDealerGameBinding.eligible(world, resolveSubType)
    local ownerWorld = overrides.ownerWorld or RLDealerWorld.new({ isServer = true, mission = mission })
    local deps = { mission = mission, farmManager = overrides.farmManager or g_farmManager, stock = store,
        epoch = "e" .. stamp() .. tostring(math.random(1000, 9999)), directory = mission.missionInfo.savegameDirectory,
        lineage = lineage, generation = function() return checkpoint.generation end,
        monotonicMs = overrides.monotonicMs or function() return g_time end, resolveSubType = resolveSubType,
        resolveDiseaseModel = R.checkpointRuntime.ownershipContext.resolveDiseaseModel, eligible = eligible,
        allOwners = ownerWorld.allOwners, storage = overrides.storage,
        localFarmId = overrides.localFarmId or function() return mission:getFarmId() end }
    local parts
    parts, why = RLDealerAssembly.assemble(deps)
    if not parts then return nil, "ASSEMBLE:" .. tostring(why) end
    local generationContext = { isServer = true, resolveSubType = resolveSubType, resolveEntry = RLDealerGameBinding.resolveEntry(world),
        eligible = eligible, resolveDiseaseModel = deps.resolveDiseaseModel, birthDate = RLDealerGameBinding.birthDate(environment),
        checkGlobalIdentities = function(encoded) return ownerWorld.checkGlobalIdentities(encoded) end,
        persistBarrier = function(payload)
            return RLDealerJournal.checkpoint(parts.journal, deps.directory, payload.purchase, deps.generation(), deps.storage, payload.recovery)
        end,
        identity = RLDealerGeneration.ledgerPort(overrides.farmOf or function(countryIndex, farmId)
            for _, farm in pairs(mission.animalSystem.countries[countryIndex].farms) do if tostring(farm.id) == tostring(farmId) then return farm end end
        end),
        isBusy = overrides.isBusy }
    parts.generationContext = generationContext
    parts.world = world
    parts.scheduler = RLDealerScheduler.new({ budget = overrides.budget or 1,
        shelfTarget = overrides.shelfTarget or function() return mission.animalSystem.maxDealerAnimals or 0 end })
    parts.gate = R.gate
    parts.localFarmId = deps.localFarmId
    local service
    service, why = RLDealerService.new(parts)
    if not service then return nil, why end
    if checkpoint.state == checkpoint.UNARMED then
        local armed, armWhy = checkpoint.arm(lineage)
        if not armed then return nil, "ARM:" .. tostring(armWhy) end
    end
    R.store = store
    R.service, R.parts, R.state, R.reason = service, parts, "READY", "ENABLED"
    R.CHANNEL_ENABLED = true
    R.setCapability("cattleSingleplayer", true)
    if RLDealerPurchaseEvent then RLDealerPurchaseEvent.service = service end
    if RLDealerQuoteEvent then RLDealerQuoteEvent.service = service end
    if RLDealerCatalogEvent then RLDealerCatalogEvent.service = service end
    return true
end
function R.disable()
    R.CHANNEL_ENABLED = false
    R.service, R.parts = nil, nil
    if R.state == "READY" then R.state, R.reason = "DORMANT", "DISABLED" end
    if RLDealerPurchaseEvent then RLDealerPurchaseEvent.service = nil end
    if RLDealerQuoteEvent then RLDealerQuoteEvent.service = nil end
    if RLDealerCatalogEvent then RLDealerCatalogEvent.service = nil end
    return true
end
--- The hourly game tick (HOUR_CHANGED), only while enabled: progress, restock, generation within the budget.
function R.onHour()
    if R.service == nil or not R.CHANNEL_ENABLED then return end
    local environment = g_currentMission.environment
    -- The planner dates birthdays and due dates from world.now: it is the game date of THIS tick.
    R.parts.world.now = RLDealerGameBinding.now(environment)
    local ok, report, why = pcall(R.service.tick, { { hours = 1, daysPerMonth = environment.daysPerPeriod } }, R.parts.world)
    local Log = RmLogging.getLogger("RLRM")
    if not ok then
        Log:error("RLDealerRuntime.onHour: %s", tostring(report))
        return
    end
    R.logTick(Log, report, why)
end
--- One line per tick that did something or could not: a filled or empty place (with every attempt's
--- reason), and a blocked tick once per new reason. A quiet tick (no checkpoint, no deficit) logs nothing.
function R.logTick(Log, report, why)
    if report == nil then
        if why ~= R.lastTickBlock then
            R.lastTickBlock = why
            Log:warning("RLDEALERV2 TICK blocked: %s", tostring(why))
        end
        return
    end
    R.lastTickBlock = nil
    if (report.filled or 0) > 0 then
        Log:info("RLDEALERV2 TICK filled=%d deficit=%s months=%s", report.filled, tostring(report.deficit), tostring(report.months))
    end
    if (report.empty or 0) > 0 then
        local reasons = type(report.emptyReasons) == "table" and table.concat(report.emptyReasons, ", ") or ""
        Log:warning("RLDEALERV2 TICK place left empty: %s [%s] deficit=%s", tostring(report.emptyReason), reasons, tostring(report.deficit))
    end
    if report.paused ~= nil and report.paused ~= R.lastTickPause then
        Log:warning("RLDEALERV2 TICK paused: %s", tostring(report.paused))
    end
    R.lastTickPause = report.paused
end
function R.getStatus()
    return { version = R.VERSION, state = R.state, reason = R.reason, channelEnabled = R.CHANNEL_ENABLED == true,
        checkpointState = RLDealerCheckpoint.state, generation = RLDealerCheckpoint.generation,
        months = R.store and R.store.farm.clock.months or nil }
end
