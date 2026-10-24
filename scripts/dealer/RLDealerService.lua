--[[
    Dealer v2 T4: the server-side facade the quote / purchase events talk to, and the gate in front of it.
    It owns no state of its own: the store, the quote book, the purchase adapter (one per session: it holds
    the money store of this epoch) and the scheduler are built by RLDealerRuntime and handed in.

        authorize(connection, destinationRef)   gate + connection permission + the farm owns the destination
        resolvePrincipal(connection)            "farm:<id>:user:<uid>" from the connection, never from a payload
        quote(request, principal, connection)   a formal quote bound to principal, destination and listings
        execute(connection, request)            the guarded batch purchase (RLDealerPurchase.execute)
        lookup(connection, requestId)           the saved result of the caller's own order, read only
        tick(segments, world)                   the scheduler (generation, progress); never from a read

    The gate (`ready()`) is every condition the design lists, each with its own reason: the channel switch,
    the identity ledger as the allocator, a verified dealer checkpoint, no recovery state, and the species /
    map / container capabilities the caller registered. A false answer is returned as a reason, never as
    silence, and nothing is half done behind it.
]]

RLDealerService = { VERSION = 1 }
local S = RLDealerService


--- parts = { mission, farmManager, stock, quotes, quoteAdapter, adapter, purchaseContext, scheduler, gate }
--- gate() -> true | false, reason   (the runtime's view of channel / identity / checkpoint / capabilities)
function S.new(parts)
    for _, key in ipairs({ "mission", "farmManager", "stock", "quotes", "quoteAdapter", "adapter", "purchaseContext", "gate" }) do
        if parts[key] == nil then return nil, "SERVICE_PART:" .. key end
    end
    local self = {}

    local function ready()
        local ok, reason = parts.gate()
        if ok ~= true then return false, reason or "DEALER_V2_DISABLED" end
        if parts.stock.recoveryRequired or parts.stock.purchase.recoveryRequired then return false, "RECOVERY_REQUIRED" end
        return true
    end

    function self.ready() return ready() end

    function self.resolvePrincipal(connection)
        local principal = RLDealerDestination.principal(connection, parts.mission, parts.farmManager)
        return principal
    end

    function self.authorize(connection, destination)
        local ok, reason = ready()
        if not ok then return false, reason end
        local resolved, why = RLDealerDestination.authorize(connection, destination, parts.mission, parts.farmManager)
        if not resolved then return false, why end
        return true
    end

    function self.quote(request, principal, connection)
        local ok, reason = ready()
        if not ok then return nil, reason end
        return RLDealerQuote.issue(parts.quotes, { destination = request.destination, items = request.items }, principal, parts.quoteAdapter)
    end

    function self.execute(connection, request)
        local ok, reason = ready()
        if not ok then return nil, reason end
        local principal, why = RLDealerDestination.principal(connection, parts.mission, parts.farmManager)
        if not principal then return nil, why end
        -- The adapter reads the requesting connection from this table; set for this call only.
        local previous = parts.purchaseContext.connection
        parts.purchaseContext.connection = connection
        local ran, result, failure = pcall(RLDealerPurchase.execute, parts.stock.purchase, request, principal, parts.adapter)
        parts.purchaseContext.connection = previous
        if not ran then
            if Log ~= nil then Log:error("RLDEALERV2 purchase failed with an error: %s", tostring(result)) end
            return nil, "SERVICE_ERROR"
        end
        return result, failure
    end

    function self.lookup(connection, requestId)
        local principal, why = RLDealerDestination.principal(connection, parts.mission, parts.farmManager)
        if not principal then return nil, why end
        return RLDealerPurchase.lookup(parts.stock.purchase, requestId, principal)
    end

    -- Browsing: pages, detail, destinations, order status. Read only; answers from the last tick.
    function self.browse(connection, kind, payload)
        local P = RLDealerCatalogProtocol
        local ok, reason = ready()
        if not ok then return { status = "REJECTED", reason = reason } end
        local principal, why = RLDealerDestination.principal(connection, parts.mission, parts.farmManager)
        if not principal then return { status = "REJECTED", reason = why or "NO_PLAYER_FARM" } end
        local deps = { epoch = parts.epoch, refPrice = parts.refPrice }
        if kind == P.PAGE then
            local page, failure = RLDealerCatalog.page(parts.stock, payload, deps)
            if page == nil then return { status = "REJECTED", reason = failure } end
            if page.status == "STALE_SNAPSHOT" then page.rows = nil end
            return page
        elseif kind == P.DETAIL then
            return RLDealerCatalog.detail(parts.stock, payload.saleId, payload.revision, deps)
        elseif kind == P.DESTINATIONS then
            if parts.destinations == nil then return { status = "REJECTED", reason = "DESTINATIONS_UNAVAILABLE" } end
            return parts.destinations(connection, payload.saleIds)
        elseif kind == P.ORDER then
            local result, failure = RLDealerPurchase.lookup(parts.stock.purchase, payload.orderId, principal)
            if result == nil then
                return { orderId = payload.orderId, status = failure == "UNKNOWN_REQUEST" and "UNKNOWN_REQUEST" or "REJECTED", reason = failure }
            end
            return { orderId = payload.orderId, status = result.status, amount = result.amount, transferIds = result.transferIds }
        end
        return { status = "REJECTED", reason = "UNKNOWN_CATALOG_MESSAGE" }
    end

    -- Singleplayer console route (no connection object); present only when the assembly was given a local farm.
    local function localPrincipal()
        if parts.localAuthority == nil then return nil, "LOCAL_ROUTE_UNAVAILABLE" end
        local farmId = parts.localFarmId and parts.localFarmId()
        if farmId == nil then return nil, "NO_PLAYER_FARM" end
        return "farm:" .. tostring(farmId) .. ":local"
    end
    function self.localQuote(request)
        local ok, reason = ready()
        if not ok then return nil, reason end
        local principal, why = localPrincipal()
        if not principal then return nil, why end
        return RLDealerQuote.issue(parts.quotes, { destination = request.destination, items = request.items }, principal, parts.quoteAdapter)
    end
    function self.localExecute(request)
        local ok, reason = ready()
        if not ok then return nil, reason end
        local principal, why = localPrincipal()
        if not principal then return nil, why end
        local previous = parts.purchaseContext.useLocal
        parts.purchaseContext.useLocal, parts.purchaseContext.connection = true, nil
        local ran, result, failure = pcall(RLDealerPurchase.execute, parts.stock.purchase, request, principal, parts.adapter)
        parts.purchaseContext.useLocal = previous
        if not ran then
            if Log ~= nil then Log:error("RLDEALERV2 purchase failed with an error: %s", tostring(result)) end
            return nil, "SERVICE_ERROR"
        end
        return result, failure
    end
    function self.localLookup(requestId)
        local principal, why = localPrincipal()
        if not principal then return nil, why end
        return RLDealerPurchase.lookup(parts.stock.purchase, requestId, principal)
    end
    function self.localBrowse(kind, payload)
        local P = RLDealerCatalogProtocol
        local ok, reason = ready()
        if not ok then return { status = "REJECTED", reason = reason } end
        local deps = { epoch = parts.epoch, refPrice = parts.refPrice }
        if kind == P.PAGE then
            local page, failure = RLDealerCatalog.page(parts.stock, payload, deps)
            if page == nil then return { status = "REJECTED", reason = failure } end
            return page
        elseif kind == P.DETAIL then return RLDealerCatalog.detail(parts.stock, payload.saleId, payload.revision, deps)
        elseif kind == P.DESTINATIONS then return parts.destinations(nil, payload.saleIds) end
        return { status = "REJECTED", reason = "UNKNOWN_CATALOG_MESSAGE" }
    end

    function self.tick(segments, world)
        if parts.scheduler == nil then return nil, "NO_SCHEDULER" end
        local ok, reason = ready()
        if not ok then return nil, reason end
        return RLDealerScheduler.tick(parts.scheduler, parts.stock, segments, world, parts.generationContext)
    end

    return self
end
