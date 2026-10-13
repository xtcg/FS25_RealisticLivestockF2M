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
    R.state, R.reason = isServer and "LOADING" or "DISABLED", isServer and "WAITING_FOR_MISSION" or "CLIENT"
    -- Events from an earlier map must never retain a service or authority handle.
    if RLDealerPurchaseEvent then RLDealerPurchaseEvent.service = nil end
    if RLDealerQuoteEvent then RLDealerQuoteEvent.service = nil end
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
function R.canPurchase()
    if not R.CHANNEL_ENABLED then return false, "DEALER_V2_DISABLED" end
    -- Real ownership adapter and release gates must be installed before this can
    -- ever return true. Changing a configuration value cannot bypass this seam.
    return false, "DEALER_OWNERSHIP_ADAPTER_REQUIRED"
end
function R.getStatus()
    return { version = R.VERSION, state = R.state, reason = R.reason, channelEnabled = false,
        checkpointState = RLDealerCheckpoint.state, generation = RLDealerCheckpoint.generation,
        months = R.store and R.store.farm.clock.months or nil }
end
