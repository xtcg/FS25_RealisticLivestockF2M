-- U03: engine-compatible unquantized doubles by default. A quantized policy can
-- only be created with explicit round-trip evidence from its payment adapter.
RLMarketMoney = {}
local M = RLMarketMoney
function M.finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end
function M.convert(amount, from, to, multiplier)
    if not M.finite(amount) or not M.finite(multiplier) or multiplier <= 0
        or (from ~= "HARD" and from ~= "CURRENT") or (to ~= "HARD" and to ~= "CURRENT") then
        return nil, "INVALID_MONEY_BASIS"
    end
    local result = amount
    if from ~= to then result = from == "HARD" and amount * multiplier or amount / multiplier end
    if not M.finite(result) then return nil, "MONEY_OVERFLOW" end
    return result
end
function M.new(options)
    options = options or {}
    local unit = options.unit
    if unit ~= nil then
        if not M.finite(unit) or unit <= 0 or type(options.verifyRoundTrip) ~= "function" then return nil, "UNVERIFIED_SETTLEMENT_UNIT" end
        local ok,verified = pcall(options.verifyRoundTrip,unit)
        if not ok or verified ~= true then return nil,"UNVERIFIED_SETTLEMENT_UNIT" end
    end
    local policy = {}
    function policy:quantize(n, direction)
        if not M.finite(n) then return nil, "INVALID_AMOUNT" end
        if direction~=nil and direction~="DOWN" and direction~="UP" and direction~="NEAREST" then return nil,"INVALID_ROUNDING" end
        if unit == nil then return n end
        local scaled = n / unit
        if not M.finite(scaled) or math.abs(scaled) >= 2 ^ 52 then return nil, "MONEY_OVERFLOW" end
        -- Division can place a decimal grid value one ULP below its integer
        -- count (0.29 / 0.01). Normalize that representation error only; values
        -- materially on either side of a boundary retain directional rounding.
        local nearest = scaled >= 0 and math.floor(scaled + 0.5) or math.ceil(scaled - 0.5)
        local tolerance = math.min(1e-9, 2 ^ -50 * math.max(1, math.abs(scaled)))
        if math.abs(scaled - nearest) <= tolerance then scaled = nearest end
        local count
        if direction == "DOWN" then count = math.floor(scaled)
        elseif direction == "UP" then count = math.ceil(scaled)
        elseif direction == nil or direction == "NEAREST" then
            count = scaled >= 0 and math.floor(scaled + 0.5) or math.ceil(scaled - 0.5)
        else return nil, "INVALID_ROUNDING" end
        local result = count * unit
        if not M.finite(result) then return nil, "MONEY_OVERFLOW" end
        return result
    end
    function policy:breakdown(bodyAmount, fees, bonuses, direction)
        if direction ~= "IN" and direction ~= "OUT" then return nil, "INVALID_DIRECTION" end
        if not M.finite(bodyAmount) or bodyAmount < 0 or type(fees) ~= "table" or type(bonuses) ~= "table" then
            return nil, "INVALID_BREAKDOWN"
        end
        local body, err = self:quantize(bodyAmount, "DOWN")
        if body == nil then return nil, err end
        local result = { bodyAmount = body, fees = {}, bonuses = {}, currencyBasis = "CURRENT",
            settlementDirection = direction, settlementUnit = unit, totalFees = 0, totalBonuses = 0 }
        local function items(source, target, totalKey)
            -- Ordered line items: preserve the same items for display and payment.
            local count = 0
            for key in pairs(source) do
                if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
                count = count + 1
            end
            if count ~= #source then return false end
            for _, item in ipairs(source) do
                if type(item) ~= "table" or type(item.id) ~= "string" or item.id == ""
                    or not M.finite(item.amount) or item.amount < 0 then return false end
                local amount = self:quantize(item.amount)
                if amount == nil then return false end
                target[#target + 1] = { id = item.id, amount = amount }
                result[totalKey] = result[totalKey] + amount
                if not M.finite(result[totalKey]) then return false end
            end
            return true
        end
        if not items(fees, result.fees, "totalFees") or not items(bonuses, result.bonuses, "totalBonuses") then
            return nil, "INVALID_LINE_ITEM"
        end
        result.netToPlayer = direction == "IN" and (body + result.totalBonuses - result.totalFees)
            or -(body + result.totalFees - result.totalBonuses)
        if not M.finite(result.netToPlayer) then return nil, "MONEY_OVERFLOW" end
        if direction == "OUT" and result.netToPlayer > 0 then return nil, "BUY_CANNOT_CREDIT_PLAYER" end
        return result
    end
    function policy:transportPair(preTransport, pickupFee)
        if not M.finite(preTransport) or preTransport < 0 or not M.finite(pickupFee) or pickupFee < 0 then
            return nil, "INVALID_TRANSPORT"
        end
        local delivery, err = self:quantize(preTransport, "DOWN")
        if delivery == nil then return nil, err end
        local fee = self:quantize(pickupFee)
        if fee == nil then return nil, "INVALID_TRANSPORT" end
        -- Never round the two final net amounts independently.
        return { selfDelivery = delivery, pickup = delivery - fee, pickupFee = fee,
            selfDeliveryAvailable = delivery > 0, pickupAvailable = delivery - fee > 0 }
    end
    return policy
end
