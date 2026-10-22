-- Mode routing seam only. No engine hook, wallet, animal update, orders or GUI.
-- U03-U08 and calibrated market policies are prerequisites for a real binding.
RLMarketPriceService = {}

function RLMarketPriceService.new(deps)
    if type(deps) ~= "table" or type(deps.legacy) ~= "table" or type(deps.legacy.quote) ~= "function" then
        return nil, "MISSING_LEGACY_ADAPTER"
    end
    local service = { mode = "legacy" }
    local active = false
    function service:setMode(mode)
        if mode ~= "legacy" and mode ~= "shadow" and mode ~= "market" then
            self.mode = "legacy"
            return false, "INVALID_MODE"
        end
        self.mode = mode
        return true
    end
    function service:getMode() return self.mode end
    function service:quote(side, legacyInput, snapshot, context)
        if active then return nil, "RECURSIVE_PRICE_SERVICE" end
        if side ~= "BID" and side ~= "ASK" then return nil, "INVALID_SIDE" end
        active = true
        local ok, result, reason = pcall(function()
            local function market()
                if type(deps.marketQuote) ~= "function" or type(deps.pricingReady) ~= "function" then
                    return nil, "MARKET_NOT_READY"
                end
                local valid, invalid = RLMarketSchema.validateSnapshot(snapshot)
                if not valid then return nil, invalid end
                valid, invalid = RLMarketSchema.validateQuoteContext(context)
                if not valid then return nil, invalid end
                if (side == "ASK" and context.channel ~= "DEALER_BUY")
                    or (side == "BID" and context.channel ~= "DEALER_SELL") then
                    return nil, "CHANNEL_MISMATCH"
                end
                if snapshot.classRevision ~= context.classRevision
                    or snapshot.traitMappingRevision ~= context.traitMappingRevision then
                    return nil, "SNAPSHOT_VERSION_MISMATCH"
                end
                local snap = RLAnimalValueProvider.copyData(snapshot)
                local ctx = RLAnimalValueProvider.copyData(context)
                -- Gate is per snapshot/context scope, never Dealer runtime readiness.
                if deps.pricingReady(snap, ctx) ~= true then return nil, "MARKET_NOT_READY" end
                local quote, failure = deps.marketQuote(side,
                    RLAnimalValueProvider.copyData(snapshot), RLAnimalValueProvider.copyData(context))
                if quote == nil then return nil, failure or "MARKET_UNAVAILABLE" end
                valid, invalid = RLMarketSchema.validateQuote(quote)
                if not valid then return nil, invalid end
                if quote.channel ~= context.channel or quote.identityKey ~= snapshot.identityKey
                    or quote.stateRevision ~= snapshot.stateRevision then return nil, "QUOTE_SCOPE_MISMATCH" end
                for _, key in ipairs({ "classRevision", "traitMappingRevision", "marketEpoch",
                    "configRevision", "formulaVersion", "priceRevision" }) do
                    if quote[key] ~= context[key] then return nil, "QUOTE_VERSION_MISMATCH" end
                end
                return RLAnimalValueProvider.copyData(quote)
            end
            if self.mode == "market" then return market() end
            local legacy, failure = deps.legacy:quote(side, legacyInput, context)
            if legacy == nil or self.mode == "legacy" then return legacy, failure end
            -- Shadow errors cannot change the legacy amount or block its return.
            local worked, candidate, why = pcall(market)
            if type(deps.observe) == "function" then
                pcall(deps.observe, { legacy = RLAnimalValueProvider.copyData(legacy),
                    candidate = worked and candidate or nil,
                    reason = worked and why or "SHADOW_ERROR" })
            end
            return legacy
        end)
        active = false
        if not ok then return nil, "PRICE_SERVICE_ERROR" end
        return result, reason
    end
    return service
end
