--[[
    Dealer v2 T4: builds the running dealer service from the game's objects. Every game dependency is
    injected (`deps`, defaulting to the globals), so the same code runs in tests against stand-ins and in
    the game against the mission. Nothing here switches the channel on: RLDealerRuntime.CHANNEL_ENABLED
    and the gate decide, and `assemble` only runs from the server console command or a test.

    Price. Body price and transport fee are the ones the shop uses today: RLAnimalBuyService.computeBuyPrice
    (which carries the breeding-value and dealer-markup layers) and animal:getTranportationFee(1), read from
    the private source animal named by the listing. No second formula.
    Barrier. persistBarrier is RLDealerJournal.checkpoint (synchronous XML write and exact readback) with the
    dealer checkpoint's generation as base; the asynchronous save hooks are never used for it.
]]

RLDealerAssembly = { VERSION = 1 }
local A = RLDealerAssembly


local function listingAnimal(stock, listing)
    local sourceId = listing.payload and listing.payload.sourceId
    local binding = sourceId and stock.sourceBindings[sourceId]
    local owner = binding and stock.sourceOwners[binding.ownerId]
    return owner and owner.byId[binding.animalId] or nil
end


--- deps = { mission, farmManager, stock, epoch, directory, lineage, generation(), monotonicMs, resolveSubType,
---          resolveEntry, eligible, allOwners, priceOf(animal), feeOf(animal), connectionLookup }
--- Returns parts for RLDealerService.new (without `gate` / `scheduler`) or nil and why.
function A.assemble(deps)
    local stock = deps.stock
    if type(stock) ~= "table" or type(stock.sourceOwners) ~= "table" then return nil, "OWNED_STORE_REQUIRED" end
    local mission, farmManager = deps.mission, deps.farmManager
    local quotes, why = RLDealerQuote.new(deps.epoch)
    if not quotes then return nil, why end
    local journal
    journal, why = RLDealerJournal.new(deps.lineage, deps.epoch)
    if not journal then return nil, why end

    local priceOf = deps.priceOf or function(animal) return RLAnimalBuyService.computeBuyPrice(animal) end
    local feeOf = deps.feeOf or function(animal) return animal:getTranportationFee(1) or 0 end

    -- Price, fee and eligibility of one listing revision at one clock are fixed: mid-purchase, after the
    -- source animal left the dealer's inventory, the figures given before the effects are the ones asked again.
    local memo, memoSize = { eligible = {}, price = {}, fee = {} }, 0
    local function cacheKey(listing, context)
        return tostring(listing.saleId) .. "|" .. tostring(listing.recordRevision) .. "|" .. tostring(context and context.currentClock)
    end
    local function remember(table_, key, value)
        if memoSize > 4096 then memo, memoSize = { eligible = {}, price = {}, fee = {} }, 0; table_ = nil end
        if table_ ~= nil then table_[key] = value; memoSize = memoSize + 1 end
    end
    local quoteAdapter = {
        isServer = function() return mission:getIsServer() == true end,
        authorize = function(principal, reference)
            -- The quote was issued to this principal for this destination; the connection check is
            -- done by the service before issue. Here only that the destination still resolves.
            return RLDealerDestination.resolveWire(reference) ~= nil
        end,
        currentClock = function() return stock.farm.clock.months end,
        monotonicMs = deps.monotonicMs,
        readListing = function(id) return RLDealerListingRegistry.get(stock.listings, id) end,
        eligible = function(listing, context)
            local key = cacheKey(listing, context)
            local source = stock.farm.sources[listing.payload and listing.payload.sourceId]
            if source == nil then
                -- Mid-purchase the source is already detached: the answer given before the effects stands.
                if memo.eligible[key] then return true end
                return false, "SOURCE_NOT_CURRENT"
            end
            local ok, reason = deps.eligible(source, listing, context)
            if ok == true then remember(memo.eligible, key, true) end
            return ok, reason
        end,
        computeBuyPrice = function(listing, context)
            local key = cacheKey(listing, context)
            local animal = listingAnimal(stock, listing)
            if animal == nil then
                if memo.price[key] ~= nil then return memo.price[key] end
                return nil, "SOURCE_NOT_CURRENT"
            end
            local price = priceOf(animal)
            if price ~= nil then remember(memo.price, key, price) end
            return price
        end,
        computeTransportFee = function(listing, context)
            local key = cacheKey(listing, context)
            local animal = listingAnimal(stock, listing)
            if animal == nil then
                if memo.fee[key] ~= nil then return memo.fee[key] end
                return nil, "SOURCE_NOT_CURRENT"
            end
            local fee = feeOf(animal)
            if fee ~= nil then remember(memo.fee, key, fee) end
            return fee
        end,
    }

    local capacity
    capacity, why = RLDealerCapacity.new({ isServer = true, mission = mission, stock = stock,
        resolveSubType = deps.resolveSubType, allOwners = deps.allOwners })
    if not capacity then return nil, "CAPACITY:" .. tostring(why) end

    local purchaseContext = {
        stock = stock, mission = mission, farmManager = farmManager, connection = nil, epoch = deps.epoch,
        quotes = quotes, quoteAdapter = quoteAdapter, resolveSubType = deps.resolveSubType,
        resolveDiseaseModel = deps.resolveDiseaseModel, monotonicMs = deps.monotonicMs,
        allOwners = deps.allOwners, eligible = deps.eligible, validateCapacity = capacity,
        persistBarrier = function(payload)
            return RLDealerJournal.checkpoint(journal, deps.directory, payload.purchase, deps.generation(), deps.storage, payload.recovery)
        end,
    }
    local adapter
    adapter, why = RLDealerPurchaseAdapter.new(purchaseContext)
    if not adapter then return nil, "ADAPTER:" .. tostring(why) end
    return { mission = mission, farmManager = farmManager, stock = stock, quotes = quotes, quoteAdapter = quoteAdapter,
        adapter = adapter, purchaseContext = purchaseContext, journal = journal, capacity = capacity }
end
