-- Composition of source feeding and listing lifecycle. No engine hook or live
-- purchase endpoint is enabled by constructing this server-owned store.
RLDealerStockService = { VERSION = 1 }
local V = RLDealerStockService
local cattleLifetime = { CALF_MILK = "UNWEANED", CALF_WEANED = "GROWING", HEIFER_REPLACEMENT = "REPLACEMENT",
    FEEDER = "STORE", HEIFER_READY = "BREEDING", HEIFER_IN_CALF = "BREEDING", BULL_YOUNG = "BREEDING",
    COW_FIRST = "PRODUCTION", COW_YOUNG = "PRODUCTION" }
local copy=RLPlain.copy
function V.new(namespace, months)
    local farm, why = RLDealerSourceFarm.new(namespace, months)
    if not farm then return nil, why end
    local listings; listings, why = RLDealerListingRegistry.new(namespace)
    if not listings then return nil, why end
    return { version = V.VERSION, farm = farm, listings = listings, purchase = RLDealerPurchase.new(),
        recoveryRequired = false }
end
-- Empty private inventory for the owned admission path. Existing historical-only
-- inventories must be explicitly reconciled; this constructor never converts them.
function V.newOwned(namespace,months)
    local store,why=V.new(namespace,months);if not store then return nil,why end
    store.sourceOwners,store.sourceBindings,store.sourceRecordsByOwner={},{},{}
    store.observedChildren,store.retiredSources={},{}
    return store
end
-- Only the server evaluator may publish; neither a client animal nor an
-- unscreened reference replay is a listing. Source IDs cannot be relisted.
function V.publish(store, sourceId, candidate, lifetimeClass)
    if store.recoveryRequired then return nil, "RECOVERY_REQUIRED" end
    if store.sourceOwners ~= nil then return nil, "OWNED_SOURCE_PUBLICATION_REQUIRED" end
    if type(candidate) ~= "table" or candidate.eligibility ~= "VERIFIED_CANDIDATE" then return nil, "CANDIDATE_REQUIRED" end
    local screened, reason = RLDealerReplay.screen(candidate)
    if not screened then return nil, reason end
    local purpose = candidate.animal.sale and candidate.animal.sale.purpose
    local expectedLifetime = cattleLifetime[purpose]
    if expectedLifetime == nil or (lifetimeClass ~= nil and lifetimeClass ~= expectedLifetime) then return nil, "PURPOSE_LIFETIME" end
    lifetimeClass = expectedLifetime
    local farm, why = RLDealerSourceFarm.restore(RLDealerSourceFarm.export(store.farm))
    if not farm then return nil, why end
    local source, failure = RLDealerSourceState.capture(candidate, farm.clock.months)
    if not source then return nil, failure.reason end
    local added; added, why = RLDealerSourceFarm.add(farm, sourceId, source)
    if not added then return nil, why end
    local listings = RLDealerListingRegistry.export(store.listings)
    local draft; draft, why = RLDealerListingRegistry.createDraft(listings,
        { sourceId = sourceId, purpose = candidate.animal.sale and candidate.animal.sale.purpose,
            source = candidate.history.source }, lifetimeClass, farm.clock.months)
    if not draft then return nil, why end
    local listed; listed, why = RLDealerListingRegistry.list(listings, draft.saleId, farm.clock.months)
    if not listed then return nil, why end
    store.farm, store.listings = farm, listings
    return listed
end
-- Sources continue feeding after withdrawal. Active listings follow the source
-- cursor before eligibility/expiry is checked; replenishment is requested once
-- at the latest quarter-month boundary, never run by a page or quote read.
function V.advanceSegments(store, segments, resolveSubType, resolveEntry, eligible)
    if store.recoveryRequired or store.purchase.recoveryRequired then return nil, "RECOVERY_REQUIRED" end
    if store.sourceOwners ~= nil then return nil, "OWNED_SOURCE_PROGRESSION_REQUIRED" end
    if type(eligible) ~= "function" then return nil, "ELIGIBILITY_REQUIRED" end
    -- Transactions own reserved sources. An update must not mutate assets under
    -- an in-flight or interrupted ownership decision.
    for _, record in pairs(store.purchase.records) do
        if record.stage ~= "COMMITTED" and record.stage ~= "ROLLED_BACK" then return nil, "TRANSACTION_IN_PROGRESS" end
    end
    for _, listing in pairs(store.listings.records) do
        if listing.state == "RESERVED" then return nil, "TRANSACTION_IN_PROGRESS" end
    end
    local farm, why = RLDealerSourceFarm.restore(RLDealerSourceFarm.export(store.farm))
    if not farm then return nil, why end
    local now; now, why = RLDealerSourceFarm.advanceSegments(farm, segments, resolveSubType, resolveEntry)
    if not now then return nil, why end
    local listings = RLDealerListingRegistry.export(store.listings)
    for _, record in ipairs(RLDealerListingRegistry.listRecords(listings, "LISTED")) do
        local source = farm.sources[record.payload.sourceId]
        if source == nil then return nil, "LISTING_SOURCE_MISSING" end
        local result, failure = RLDealerSourceState.restore(source, resolveSubType)
        if not result then return nil, failure.reason end
        local progressed
        progressed, why = RLDealerListingRegistry.progress(listings, record.saleId, now,
            function(payload) return payload end,
            function(_, current) return eligible(result, current) end)
        if not progressed then return nil, why end
    end
    local checkpoint, skipped = RLDealerClock.checkpoint(farm.clock)
    store.farm, store.listings = farm, listings
    return { months = now, replenishAtMonths = checkpoint, skippedCheckpoints = skipped }
end
function V.readListing(store, saleId)
    return RLDealerListingRegistry.get(store.listings, saleId)
end
function V.buildSnapshot(store, meta, markers)
    local ownership
    if store.sourceOwners ~= nil then
        local why
        ownership, why = RLDealerOwnedStock.export(store.sourceOwners, store.sourceBindings,
            store.sourceRecordsByOwner, store.observedChildren, store.farm.sources, store.farm.clock.months, store.retiredSources)
        if not ownership then return nil, why end
    end
    return RLDealerPersistence.capture(meta, RLDealerClock.export(store.farm.clock),
        RLDealerListingRegistry.export(store.listings), copy(store.farm.sources),
        RLDealerPurchase.export(store.purchase, { settled = true }), markers, ownership)
end
function V.fromVerifiedDocument(document)
    if type(document) ~= "table" or document.state ~= "VERIFIED" or document.sourceResolution ~= "RESOLVED" then
        return nil, "VERIFIED_SOURCE_CHECKPOINT_REQUIRED"
    end
    local data = document.restored
    if type(data) ~= "table" then return nil, "VERIFIED_SOURCE_CHECKPOINT_REQUIRED" end
    if data.ownershipResolution ~= nil and data.ownershipResolution ~= "RESOLVED" then
        return nil, "VERIFIED_OWNERSHIP_CHECKPOINT_REQUIRED"
    end
    local farm, why = RLDealerSourceFarm.restore({ version = RLDealerSourceFarm.VERSION,
        namespace = data.listings.namespace, clock = data.clock, sources = data.sources })
    if not farm and why=="SOURCE_CLOCK" and data.ownedStock and data.ownedStock.recoveryRequired==true then
        -- A verified interrupted whole-owner birth may contain older active dam
        -- records at the shared boundary. Preserve all evidence in a closed store;
        -- it cannot enter ordinary SourceFarm feeding or purchasing.
        farm={version=RLDealerSourceFarm.VERSION,namespace=data.listings.namespace,clock=copy(data.clock),sources=copy(data.sources)}
    end
    if not farm then return nil, why end
    local store = { version = V.VERSION, farm = farm, listings = copy(data.listings), purchase = copy(data.purchase),
        recoveryRequired = data.recoveryRequired == true or (data.ownedStock and data.ownedStock.recoveryRequired==true) or false }
    if data.ownedStock then
        for _, key in ipairs({"sourceOwners", "sourceBindings", "sourceRecordsByOwner", "observedChildren", "retiredSources"}) do
            store[key] = data.ownedStock[key]
        end
    end
    return store
end
