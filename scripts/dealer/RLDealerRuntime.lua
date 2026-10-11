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
    local found
    for _, sub in pairs(system.subTypes or {}) do
        if sub.name == name then
            if found ~= nil and found ~= sub then return nil end
            found = sub
        end
    end
    return found
end
local function close(reason, evidence)
    R.state, R.reason, R.evidence = "RECOVERY_REQUIRED", reason, evidence
    if R.store then R.store.recoveryRequired = true end
    RLDealerCheckpoint.state, RLDealerCheckpoint.reason = RLDealerCheckpoint.RECOVERY_REQUIRED, reason
end
function R.reset(isServer)
    R.server, R.store, R.evidence = isServer == true, nil, nil
    R.state, R.reason = isServer and "LOADING" or "DISABLED", isServer and "WAITING_FOR_MISSION" or "CLIENT"
    -- Events from an earlier map must never retain a service or authority handle.
    if RLDealerPurchaseEvent then RLDealerPurchaseEvent.service = nil end
    if RLDealerQuoteEvent then RLDealerQuoteEvent.service = nil end
    local runtime = {
        resolver = resolve,
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
    if RLTradePersistence.canonical(wal.purchase) == RLTradePersistence.canonical(current) then return true end
    -- Retain the independently saved stock as compensation evidence. A COMMITTED
    -- WAL cannot overrule old saved source/target/money ownership by itself.
    R.evidence = { checkpointPurchase = current, wal = copy(document), generation = generation, lineage = lineage }
    R.store.purchase, R.store.recoveryRequired = purchase, true
    return nil, "WAL_ASSET_RECONCILIATION_REQUIRED"
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
    end
    R.state, R.reason = "DORMANT", R.store and "SAVED_STOCK_VERIFIED_CHANNEL_CLOSED" or "EMPTY_CHANNEL_CLOSED"
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
