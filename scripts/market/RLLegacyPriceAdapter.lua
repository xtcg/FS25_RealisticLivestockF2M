-- Capture the original BID/ASK entry points BEFORE any future engine hooks. ASK
-- must be the complete old body price (including its existing markup/difficulty).
-- This adapter neither multiplies nor rounds it, and never adds transport fees.
-- Binding game APIs belongs to U12/U33+, not to this pure first package.
RLLegacyPriceAdapter = {}

function RLLegacyPriceAdapter.new(originalBid, originalAsk)
    if type(originalBid) ~= "function" or type(originalAsk) ~= "function" then
        return nil, "MISSING_LEGACY_FUNCTION"
    end
    local active = false
    local adapter = {}
    function adapter:quote(side, input, context)
        if side ~= "BID" and side ~= "ASK" then return nil, "INVALID_SIDE" end
        if active then return nil, "RECURSIVE_LEGACY_PRICE" end
        active = true
        local ok, amount = pcall(side == "BID" and originalBid or originalAsk, input, context)
        active = false
        if not ok then return nil, "LEGACY_PRICE_ERROR" end
        if type(amount) ~= "number" or amount ~= amount or amount < 0 or amount == math.huge then
            return nil, "INVALID_LEGACY_PRICE"
        end
        -- A reference price is not a server credential or authority to trade.
        return { mode = "legacy", side = side, bodyAmount = amount, currencyBasis = "CURRENT" }
    end
    return adapter
end
