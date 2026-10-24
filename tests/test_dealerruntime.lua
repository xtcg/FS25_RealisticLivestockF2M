loadMod("tests/dealerreplaysim.lua")
for _, path in ipairs({ "scripts/animal/RLTradePersistence.lua", "scripts/dealer/RLDealerSourceState.lua",
    "scripts/dealer/RLDealerClock.lua", "scripts/dealer/RLDealerSourceFarm.lua", "scripts/dealer/RLDealerListingRegistry.lua",
    "scripts/dealer/RLDealerPurchase.lua", "scripts/dealer/RLDealerPersistence.lua", "scripts/dealer/RLDealerStockService.lua",
    "scripts/dealer/RLDealerJournal.lua", "scripts/dealer/RLDealerCheckpoint.lua", "scripts/dealer/RLDealerRuntime.lua" }) do loadMod(path) end
local R, C, P, V = RLDealerRuntime, RLDealerCheckpoint, RLDealerPurchase, RLDealerStockService
RLDealerPurchaseEvent = { service = {} }; RLDealerQuoteEvent = { service = {} }
R.reset(false)
check("dealer runtime: client reset clears old map authority and cannot purchase", R.state == "DISABLED"
    and C.state == C.DISABLED and RLDealerPurchaseEvent.service == nil and RLDealerQuoteEvent.service == nil and not R.canPurchase())
R.reset(true)
check("dealer runtime: fresh server does not arm or generate inventory", C.state == C.LOADING and not C.armed and R.store == nil)
local oldMissionStarted, oldExists = C.onMissionStarted, fileExists
C.onMissionStarted = function() C.state = C.UNARMED end
fileExists = function() return false end
local random = math.random; math.random = function() error("mission read cannot reroll stock") end
R.onMissionStarted({ missionInfo = { savegameDirectory = "/save" } })
math.random = random
check("dealer runtime: empty map remains dormant with no stock or save write", R.state == "DORMANT" and R.store == nil and not C.armed)
R.store = assert(V.new("runtime-test", 10))
local wal = { data = { lineage = "DLruntime", baseGeneration = 3, purchase = P.export(P.new()) } }
check("dealer runtime: identical WAL and checkpoint preserves owned stock without replay", R.compareJournal(wal, 3, "DLruntime")
    and not R.store.recoveryRequired)
local no, why = R.compareJournal(wal, 2, "DLruntime")
check("dealer runtime: newer generation cannot attach to old backup assets", no == nil and why == "WAL_CHECKPOINT_MISMATCH"
    and not R.store.recoveryRequired)
wal.data.purchase.recoveryRequired = true
-- On the checkpoint's own generation a differing WAL is a session left without saving: the save on
-- disk is wholly before the purchase, so the WAL is set aside and the saved stock stands.
local yes, unsaved = R.compareJournal(wal, 3, "DLruntime")
check("dealer runtime: a WAL on the last checkpoint's generation (left without saving) is discarded, stock kept",
    yes == true and unsaved == "WAL_UNSAVED_DISCARDED" and not R.store.recoveryRequired
    and R.discardedWal.generation == 3 and R.discardedWal.purchase.recoveryRequired)
wal.data.baseGeneration = 2
no, why = R.compareJournal(wal, 3, "DLruntime")
check("dealer runtime: an older WAL a later save did not reconcile holds ownership and retains both evidences", no == nil
    and why == "WAL_ASSET_RECONCILIATION_REQUIRED" and R.store.recoveryRequired
    and R.evidence.checkpointPurchase.recoveryRequired == false and R.evidence.wal.data.purchase.recoveryRequired)
local can, reason = R.canPurchase()
R.CHANNEL_ENABLED = true
local stillClosed, gate = R.canPurchase(); R.CHANNEL_ENABLED = false
check("dealer runtime: config flag cannot bypass missing ownership adapter", not can and reason == "DEALER_V2_DISABLED"
    and not stillClosed and gate == "DEALER_OWNERSHIP_ADAPTER_REQUIRED")
R.reset(true); C.onMissionStarted = function() C.state = C.READY; C.generation = 3; C.lineage = "DLruntime" end
fileExists = function() return true end
local oldLoad = RLDealerJournal.load; RLDealerJournal.load = function() return nil, "CORRUPT" end
R.onMissionStarted({ missionInfo = { savegameDirectory = "/save" } })
check("dealer runtime: damaged WAL is retained and closes game checkpoint gate", R.state == "RECOVERY_REQUIRED"
    and C.state == C.RECOVERY_REQUIRED and R.reason == "WAL:CORRUPT" and R.evidence.path ~= nil)
-- Load after a purchase in a session left without saving: the WAL is moved aside, the dealer stays dormant (not closed).
R.reset(true)
C.onMissionStarted = function() C.state = C.READY; C.generation = 3; C.lineage = "DLruntime"; R.store = assert(V.new("runtime-unsaved", 10)) end
local unsavedWal = { data = { lineage = "DLruntime", baseGeneration = 3, sequence = 2, purchase = P.export(P.new()) } }
unsavedWal.data.purchase.recoveryRequired = true
RLDealerJournal.load = function() return unsavedWal end
local moved, archiveDisk, archiveFault = {}, {}, nil
local function clone(v) if type(v) ~= "table" then return v end local o = {}; for k,x in pairs(v) do o[k]=clone(x) end; return o end
unsavedWal.digest = RLTradePersistence.checksum(RLTradePersistence.canonical(unsavedWal.data))
local source = "/save/rm_RlDealerPurchaseJournal.xml"
local archive = "/save/rm_RlDealerPurchaseJournal.unsaved.xml"
archiveDisk[source] = clone(unsavedWal)
R.archiveStorage = {
    exists = function(path) return archiveDisk[path] ~= nil end,
    read = function(path)
        if archiveFault == "READ_THROW" and path == archive then error("read fault") end
        return clone(archiveDisk[path])
    end,
    copy = function(from, to)
        moved[#moved + 1] = "copy " .. from .. " " .. to
        if archiveFault == "COPY_FALSE" then return false end
        if archiveFault == "COPY_THROW" then error("copy fault") end
        archiveDisk[to] = clone(archiveDisk[from])
        if archiveFault == "COPY_CORRUPT" then archiveDisk[to].data.sequence = 999 end
        return true
    end,
    remove = function(path) error("the engine refuses deleteFile in the savegame folder") end,
}
R.onMissionStarted({ missionInfo = { savegameDirectory = "/save" } })
check("dealer runtime: unsaved WAL is exactly archived and left in place (no delete), saved stock stays dormant",
    R.state == "DORMANT" and R.reason == "WAL_UNSAVED_DISCARDED" and C.state == C.READY and not R.store.recoveryRequired
    and moved[1] == "copy " .. source .. " " .. archive and #moved == 1
    and archiveDisk[source] ~= nil and RLTradePersistence.canonical(archiveDisk[archive]) == RLTradePersistence.canonical(unsavedWal))
-- Game test 2026-10-24: a second load without a save in between meets the same WAL and its archive.
R.reset(true); moved = {}
R.onMissionStarted({ missionInfo = { savegameDirectory = "/save" } })
check("dealer runtime: loading the same unsaved WAL again is a no-op, not RECOVERY_REQUIRED",
    R.state == "DORMANT" and R.reason == "WAL_UNSAVED_DISCARDED" and #moved == 0)
-- A later unsaved session (new epoch) is archived beside the first one's evidence.
do
    local later = clone(unsavedWal); later.data.epoch = "e20261024170000123"; later.data.sequence = 5
    later.digest = RLTradePersistence.checksum(RLTradePersistence.canonical(later.data))
    archiveDisk[source] = clone(later); moved = {}
    R.reset(true); RLDealerJournal.load = function() return later end
    R.onMissionStarted({ missionInfo = { savegameDirectory = "/save" } })
    local named = "/save/rm_RlDealerPurchaseJournal.unsaved.e20261024170000123.xml"
    check("dealer runtime: a later unsaved session is archived under its own epoch beside the earlier evidence",
        R.state == "DORMANT" and moved[1] == "copy " .. source .. " " .. named and archiveDisk[archive] ~= nil
        and RLTradePersistence.canonical(archiveDisk[named]) == RLTradePersistence.canonical(later))
    RLDealerJournal.load = function() return unsavedWal end
    archiveDisk[source] = clone(unsavedWal)
end
for _, fault in ipairs({ "COPY_FALSE", "COPY_THROW", "COPY_CORRUPT", "READ_THROW" }) do
    R.reset(true); archiveDisk, moved, archiveFault = {[source]=clone(unsavedWal)}, {}, fault
    R.store = assert(V.new("archive-failure", 10))
    local path = R.archiveWal(source, unsavedWal)
    check("dealer archive " .. fault .. " preserves source and recovery evidence", path == nil
        and R.state == "RECOVERY_REQUIRED" and C.state == C.RECOVERY_REQUIRED and R.store.recoveryRequired
        and archiveDisk[source] ~= nil and R.evidence.expected.digest == unsavedWal.digest)
end
archiveFault = nil
for _, location in ipairs({source, archive}) do
    R.reset(true); archiveDisk, moved = {[source]=clone(unsavedWal)}, {}
    if location == archive then archiveDisk[archive] = clone(unsavedWal) end
    archiveDisk[location].data.sequence = 100
    local path = R.archiveWal(source, unsavedWal)
    check("dealer archive refuses changed evidence at " .. location, path == nil and R.state == "RECOVERY_REQUIRED"
        and archiveDisk[source] ~= nil and #moved == 0)
end
R.archiveStorage = nil

RLDealerJournal.load, C.onMissionStarted, fileExists = oldLoad, oldMissionStarted, oldExists

-- T4: the gate and the enable switch
do
    R.reset(true)
    check("T4 gate: closed by default with its reason", select(2, R.gate()) == "DEALER_V2_DISABLED")
    R.CHANNEL_ENABLED = true
    check("T4 gate: enabled but not READY names the state", select(2, R.gate()) == "DEALER_STATE:LOADING")
    R.state = "READY"
    check("T4 gate: READY without a service is the missing adapter", select(2, R.gate()) == "DEALER_OWNERSHIP_ADAPTER_REQUIRED")
    R.service = {}
    RLAnimalIdentityRuntime = { authoritative = function() return false end }
    check("T4 gate: identity must be the allocator", select(2, R.gate()) == "IDENTITY_NOT_AUTHORITATIVE")
    RLAnimalIdentityRuntime.authoritative = function() return true end
    C.state, C.reason = C.UNARMED, "EMPTY"
    check("T4 gate: the dealer checkpoint must be verified", (select(2, R.gate())):find("CHECKPOINT:UNARMED", 1, true) ~= nil)
    C.state = C.READY
    check("T4 gate: a species / map capability must be registered", select(2, R.gate()) == "CAPABILITY:cattleSingleplayer")
    R.setCapability("cattleSingleplayer", true)
    check("T4 gate: all conditions met opens", R.gate() == true)
    R.setCapability("cattleSingleplayer", false)
    check("T4 gate: a capability that is withdrawn closes it again", R.gate() == false)

    R.reset(false)
    check("T4 enable: a client cannot", select(2, R.enable()) == "SERVER_ONLY")
    R.reset(true)
    check("T4 enable: not before the mission start check", select(2, R.enable()) == "DEALER_STATE:LOADING")
    R.state = "DORMANT"
    g_currentMission = { missionDynamicInfo = { isMultiplayer = true } }
    check("T4 enable: multiplayer is not verified and refused", select(2, R.enable()) == "MULTIPLAYER_NOT_VERIFIED")
    g_currentMission = { missionDynamicInfo = { isMultiplayer = false } }
    RLAnimalIdentityRuntime = { authoritative = function() return false end }
    check("T4 enable: the identity ledger must be ON first", select(2, R.enable()) == "IDENTITY_NOT_AUTHORITATIVE")
    RLAnimalIdentityRuntime.authoritative = function() return true end
    C.state = C.READY
    R.store = assert(V.new("legacy-store", 10))
    check("T4 enable: a historical-only store is never converted silently", select(2, R.enable()) == "LEGACY_STORE_RECONCILIATION_REQUIRED" and not R.CHANNEL_ENABLED)
    RLDealerPurchaseEvent.service, RLDealerQuoteEvent.service = {}, {}
    R.CHANNEL_ENABLED = true
    R.disable()
    check("T4 disable: closes the switch and clears both event handles", not R.CHANNEL_ENABLED and RLDealerPurchaseEvent.service == nil and RLDealerQuoteEvent.service == nil)
    check("T4 status never claims an open channel while disabled", R.getStatus().channelEnabled == false)
end

-- review: every hourly tick plans with the game date of that tick
do
    R.reset(true)
    local seen
    R.CHANNEL_ENABLED = true
    R.service = { tick = function(_, world) seen = world.now.day; return {} end }
    R.parts = { world = { now = { day = 1 } } }
    RLDealerGameBinding = { now = function() return { day = 9 } end }
    g_currentMission = { environment = { daysPerPeriod = 4 } }
    R.onHour()
    check("R5 onHour refreshes world.now before the tick", seen == 9 and R.parts.world.now.day == 9)
    R.disable()
end

-- review: a failed enable leaves nothing armed, stored or installed
do
    R.reset(true); R.state = "DORMANT"
    g_currentMission = { missionDynamicInfo = { isMultiplayer = false }, environment = {} }
    RLAnimalIdentityRuntime = { authoritative = function() return true end }
    C.state = C.UNARMED; C.armed = false
    RLDealerStockService.newOwned = RLDealerStockService.newOwned or function() return {} end
    local armedBefore = C.armed
    local ok, why = R.enable({ generationWorld = function() return nil, "BOOM" end })
    check("R7 enable that fails after the store was made leaves the checkpoint unarmed and R.store empty", ok == nil and why == "WORLD:BOOM"
        and C.state == C.UNARMED and C.armed == armedBefore and R.store == nil and R.service == nil and not R.CHANNEL_ENABLED)
end
