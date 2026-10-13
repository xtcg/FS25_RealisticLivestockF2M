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
        if not ran then return nil, "SERVICE_ERROR" end
        return result, failure
    end

    function self.lookup(connection, requestId)
        local principal, why = RLDealerDestination.principal(connection, parts.mission, parts.farmManager)
        if not principal then return nil, why end
        return RLDealerPurchase.lookup(parts.stock.purchase, requestId, principal)
    end

    function self.tick(segments, world)
        if parts.scheduler == nil then return nil, "NO_SCHEDULER" end
        local ok, reason = ready()
        if not ok then return nil, reason end
        return RLDealerScheduler.tick(parts.scheduler, parts.stock, segments, world, parts.generationContext)
    end

    return self
end
