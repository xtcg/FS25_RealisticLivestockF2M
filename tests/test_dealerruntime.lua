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
no, why = R.compareJournal(wal, 3, "DLruntime")
check("dealer runtime: WAL ahead of asset snapshot holds ownership and retains both evidences", no == nil
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
RLDealerJournal.load, C.onMissionStarted, fileExists = oldLoad, oldMissionStarted, oldExists
