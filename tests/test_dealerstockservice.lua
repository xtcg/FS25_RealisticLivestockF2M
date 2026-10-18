loadMod("tests/dealerreplaysim.lua")
for _, path in ipairs({ "scripts/animal/RLTradePersistence.lua", "scripts/dealer/RLDealerSourceState.lua",
    "scripts/dealer/RLDealerClock.lua", "scripts/dealer/RLDealerSourceFarm.lua", "scripts/dealer/RLDealerListingRegistry.lua",
    "scripts/dealer/RLDealerPurchase.lua", "scripts/dealer/RLDealerPersistence.lua", "scripts/dealer/RLDealerStockService.lua" }) do loadMod(path) end
local V, R, Sim = RLDealerStockService, RLDealerReplay, DealerReplaySim
local seed = Sim.seed("HOLSTEIN", "female", 1)
local entry = RLDealerStockPolicy.getEntry(RLDealerStockPolicy.getConfig(), seed.subType, "COW")
local purpose = RLDealerStockPolicy.findPurpose(entry, "female", "HEIFER_READY")
local history = Sim.history(seed, 20.5); history.source = "DAIRY_HERD"
local candidate = assert(R.evaluate(seed, history, entry, purpose,
    { maxBuyAge = 72, weaningMonth = 3, union = { { 0, 72 } }, lactates = true }, { daysPerMonth = 1 }))
local store = assert(V.new("stock-test", 100))
local no, why = V.publish(store, "source-A", candidate, "GROWING")
check("stock service: purpose owns lifetime and failed publication consumes no ID", no == nil and why == "PURPOSE_LIFETIME"
    and store.listings.nextSequence == 1 and next(store.farm.sources) == nil)
local listing = assert(V.publish(store, "source-A", candidate))
check("stock service: verified source and listing publish together with fixed purpose lifetime", listing.saleId == "stock-test:1"
    and listing.lifetimeClass == "BREEDING" and listing.expiresAtMonths == 102
    and store.farm.sources["source-A"].animal.weight == candidate.animal.weight)
no, why = V.publish(store, "source-A", candidate)
check("stock service: source cannot be relisted under another stable sale ID", no == nil and why == "SOURCE_ID"
    and store.listings.nextSequence == 2)
local random = math.random; math.random = function() error("read must not generate") end
local read = V.readListing(store, listing.saleId); read.payload.purpose = "edited"
math.random = random
check("stock service: listing reads are detached and never advance physiology", store.farm.clock.months == 100
    and store.listings.records[listing.saleId].payload.purpose == "HEIFER_READY")
local function resolve(name) local _, sub = Economics.find(name); return sub end
local function rules() return entry end
local update = assert(V.advanceSegments(store, { { hours = 6, daysPerMonth = 1 } }, resolve, rules,
    function(result, row) return result.state.ageMonths == 20.75 and row.payload.purpose == "HEIFER_READY" end))
check("stock service: feeding precedes current eligibility and one checkpoint request", update.months == 100.25
    and update.replenishAtMonths == 100.25 and store.listings.records[listing.saleId].lastProgressedAtMonths == 100.25)
assert(V.advanceSegments(store, { { hours = 6, daysPerMonth = 1 } }, resolve, rules, function() return false, "PURPOSE_LOST" end))
local withdrawnAge = store.farm.sources["source-A"].ageMonths
assert(V.advanceSegments(store, { { hours = 6, daysPerMonth = 1 } }, resolve, rules, function() error("withdrawn is not reclassified") end))
check("stock service: withdrawn dam remains fed at source without relisting", store.farm.sources["source-A"].ageMonths == withdrawnAge + 0.25
    and store.listings.records[listing.saleId].state == "WITHDRAWN" and store.listings.nextSequence == 2)
store.purchase.records.pending = { stage = "APPLYING" }
local before = store.farm.clock.months
no, why = V.advanceSegments(store, { { hours = 6, daysPerMonth = 1 } }, resolve, rules, function() return true end)
check("stock service: pending ownership journal blocks source mutation", no == nil and why == "TRANSACTION_IN_PROGRESS"
    and store.farm.clock.months == before)
check("stock service: unchecked or client document cannot initialize live stock", not V.fromVerifiedDocument({ state = "VERIFIED", sourceResolution = "NOT_CHECKED" }))
