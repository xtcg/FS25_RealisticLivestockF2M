loadMod("scripts/dealer/RLDealerListingRegistry.lua")
local R = RLDealerListingRegistry
local db = assert(R.new("farm-save"))
local payload = { weight = 42, history = { birth = 41 } }
local draft = assert(R.createDraft(db, payload, "GROWING", 0))
payload.weight = 999
check("listing: stable sale identity and independent draft", draft.saleId == "farm-save:1" and R.get(db,draft.saleId).payload.weight == 42)
local item = assert(R.list(db, draft.saleId, 0)); local id = item.saleId
check("listing: monthly lifetime timestamps and revision", item.state == "LISTED" and item.listedAtMonths == 0 and item.expiresAtMonths == 1 and item.recordRevision == 2)
check("listing: record cannot be purpose relisted or use two rotation mechanisms", not R.list(db,id,0) and not R.createDraft(db,{},"GROWING",0,{rotation="LEGACY_DAYS"}))
local random = math.random; math.random = function() error("read RNG") end
local read = R.get(db,id); read.payload.weight = 1; R.listRecords(db)
math.random = random
check("listing: reads neither mutate nor consume RNG", R.get(db,id).payload.weight == 42 and R.get(db,id).recordRevision == 2)
local function advance(p, from, to) p.weight = (p.weight or 0) + to - from; return p end
local function eligible() return true end
item = assert(R.progress(db,id,0.25,advance,eligible))
check("listing: explicit detached progression updates payload and revision", item.payload.weight == 42.25 and item.recordRevision == 3)
check("listing: stale purchase revision rejected", not R.reserve(db,id,2,"r",0.25,100,5))
item = assert(R.reserve(db,id,3,"r",0.25,100,5))
check("listing: reservation locks exact current revision", item.state == "RESERVED" and item.recordRevision == 4)
check("listing: second buyer and premature unlock rejected", not R.reserve(db,id,4,"other",0.25,101,5) and not R.release(db,id,"other",0.25,104))
check("listing: monotonic lock times reject backwards and exact timeout sale", not R.markSold(db,id,"r",4,0.25,99) and not R.markSold(db,id,"r",4,0.25,105))
item = assert(R.release(db,id,"other",0.25,105))
check("listing: real-time timeout releases without month progression", item.state == "LISTED" and item.recordRevision == 5)
item = assert(R.reserve(db,id,5,"r2",0.25,106,5))
item = assert(R.markSold(db,id,"r2",item.recordRevision,0.25,107))
check("listing: sold is terminal", item.state == "SOLD" and not R.list(db,id,1) and not R.quarantine(db,id,1))
local second = assert(R.createDraft(db,{},"UNWEANED",0)); R.list(db,second.saleId,0)
item = assert(R.progress(db,second.saleId,0.5,advance,eligible))
check("listing: expiry withdraws before purchase and never relists", item.state == "WITHDRAWN" and item.reason == "EXPIRED" and not R.reserve(db,item.saleId,item.recordRevision,"x",0.5,110,5))
local third = assert(R.createDraft(db,{},"BREEDING",0)); R.list(db,third.saleId,0)
item = assert(R.progress(db,third.saleId,0.1,advance,function() return false,"MATING_FAILED" end))
check("listing: current eligibility loss withdraws immediately", item.state == "WITHDRAWN" and item.reason == "MATING_FAILED")
local fourth = assert(R.createDraft(db,{weight=4},"HORSE",0)); R.list(db,fourth.saleId,0)
item = assert(R.progress(db,fourth.saleId,0.1,function(p) p.weight=100; error("bad") end,eligible))
check("listing: failed detached progression quarantines original payload", item.state == "QUARANTINED" and item.payload.weight == 4)
local fifth = assert(R.createDraft(db,{},"STORE",0)); local listed=R.list(db,fifth.saleId,0)
R.reserve(db,fifth.saleId,listed.recordRevision,"pending",0,1000,10)
local restored = assert(R.restore(R.export(db)))
item = R.get(restored,fifth.saleId)
check("listing: save interruption preserves reservation for journal recovery without unsafe timeout epoch", item.state == "QUARANTINED" and item.reason == "TRANSACTION_RECOVERY_REQUIRED" and item.recoveryLock.requestId == "pending")
local sixth = assert(R.createDraft(restored,{},"SHORT_CYCLE",0))
check("listing: persisted stable sequence prevents reused saleId", sixth.saleId == "farm-save:6")
local migrated = R.new("old")
local stock = { {stockKey="a",class="VALID"}, {stockKey="b",class="HARD_INVALID"}, {stockKey="c",class="MISSING_MOD",breed="unknown"} }
local function classify(p) return p.class,"GROWING" end
local stats = assert(R.migrateStock(migrated,stock,4,classify))
check("listing migration: stock-only classification retains quarantine raw breed", stats.migrated == 3 and R.get(migrated,"old:1").state == "LISTED" and R.get(migrated,"old:2").state == "WITHDRAWN" and R.get(migrated,"old:3").payload.legacyStock.breed == "unknown")
local calls=0
stats = R.migrateStock(migrated,stock,5,function() calls=calls+1; error("must not reroll") end)
check("listing migration: persisted migration version is idempotent without generation", stats.skipped and calls == 0 and #R.listRecords(migrated) == 3 and R.get(migrated,"old:3").state == "QUARANTINED")
local bad=R.new("bad")
check("listing migration: failed stock identity leaves complete registry unchanged", not R.migrateStock(bad,{{stockKey="a"},{}},0,classify) and #R.listRecords(bad) == 0 and bad.nextSequence == 1)
local saved=R.export(db); saved.records[id].rotation="LEGACY_DAYS"
check("listing persistence: malformed rotation rejected", not R.restore(saved))
check("listing: external buyer hazard stays zero", R.EXTERNAL_BUYER_LAMBDA == 0)

local cursorDb = R.new("cursor")
local cursorDraft = R.createDraft(cursorDb,{weight=10},"GROWING",0)
local cursor = R.list(cursorDb,cursorDraft.saleId,0)
cursor = R.reserve(cursorDb,cursor.saleId,cursor.recordRevision,"cursor-lock",0,0,1)
cursor = R.release(cursorDb,cursor.saleId,"cursor-lock",0.25,2)
check("listing: lock mutation does not masquerade as physiology progression", cursor.lastUpdatedAtMonths == 0.25 and cursor.lastProgressedAtMonths == 0 and not R.reserve(cursorDb,cursor.saleId,cursor.recordRevision,"new",0.25,3,1))
cursor = R.progress(cursorDb,cursor.saleId,0.25,advance,eligible)
check("listing: progression catches complete interval after lock mutation", cursor.payload.weight == 10.25 and cursor.lastProgressedAtMonths == 0.25)

local badIdentity=R.export(db); badIdentity.nextSequence=1
check("listing persistence: corrupt sequence cannot reuse stable sale identity", not R.restore(badIdentity))
local badExpiry=R.export(db); badExpiry.records[id].expiresAtMonths=900
check("listing persistence: corrupt lifetime cannot extend listing", not R.restore(badExpiry))
