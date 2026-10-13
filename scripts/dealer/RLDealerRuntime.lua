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
        recoveryMatches = wal.recovery ~= nil and RLTradePersistence.canonical(wal.recovery)==RLTradePersistence.canonical(currentRecovery)
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
--- Move an unsaved session's WAL aside (rm_RlDealerPurchaseJournal.unsaved.xml) so the next purchase
--- starts a fresh one; the next save replaces the folder and drops it (savegameBackup keeps it).
function R.archiveWal(walPath)
    local archived = walPath:gsub("%.xml$", ".unsaved.xml")
    if copyFile ~= nil and deleteFile ~= nil then
        copyFile(walPath, archived, true)
        deleteFile(walPath)
    end
    R.reason = "WAL_UNSAVED_DISCARDED"
    if RmLogging ~= nil then
        RmLogging.getLogger("RLRM"):info("RLDealerRuntime: a purchase journal from a session left without saving was set aside (%s)", archived)
    end
    return archived
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
        if why == "WAL_UNSAVED_DISCARDED" then R.archiveWal(walPath) end
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
    if checkpoint.state == checkpoint.UNARMED then
        local armed, why = checkpoint.arm("DL" .. stamp())
        if not armed then return nil, "ARM:" .. tostring(why) end
    end
    if R.store == nil then
        local store, why = RLDealerStockService.newOwned("dealer-v2", 0)
        if not store then return nil, why end
        R.store = store
    end
    if R.store.sourceOwners == nil then return nil, "LEGACY_STORE_RECONCILIATION_REQUIRED" end
    local environment = mission.environment
    local resolveSubType = overrides.resolveSubType or resolve
    local world, why = (overrides.generationWorld or function()
        return RLDealerGameBinding.generationWorld(mission.animalSystem, AnimalType.COW, RLDealerGameBinding.now(environment))
    end)()
    if not world then return nil, "WORLD:" .. tostring(why) end
    local eligible = overrides.eligible or RLDealerGameBinding.eligible(world, resolveSubType)
    local ownerWorld = overrides.ownerWorld or RLDealerWorld.new({ isServer = true, mission = mission })
    local deps = { mission = mission, farmManager = overrides.farmManager or g_farmManager, stock = R.store,
        epoch = "e" .. stamp() .. tostring(math.random(1000, 9999)), directory = mission.missionInfo.savegameDirectory,
        lineage = checkpoint.lineage, generation = function() return checkpoint.generation end,
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
    local ok, report, why = pcall(R.service.tick, { { hours = 1, daysPerMonth = environment.daysPerPeriod } }, R.parts.world)
    if not ok then
        RmLogging.getLogger("RLRM"):error("RLDealerRuntime.onHour: %s", tostring(report))
    end
end
function R.getStatus()
    return { version = R.VERSION, state = R.state, reason = R.reason, channelEnabled = R.CHANNEL_ENABLED == true,
        checkpointState = RLDealerCheckpoint.state, generation = RLDealerCheckpoint.generation,
        months = R.store and R.store.farm.clock.months or nil }
end
