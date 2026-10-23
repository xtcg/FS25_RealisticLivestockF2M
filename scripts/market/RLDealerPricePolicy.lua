RLDealerPricePolicy = {}
local P = RLDealerPricePolicy
local function nonnegative(n) return RLMarketMoney.finite(n) and n >= 0 end
function P.quote(value, options)
    if type(value) ~= "table" or type(options) ~= "table" then return nil, "INVALID_POLICY_INPUT" end
    if options.publishedOrderInformDealerBid ~= false then return nil, "PUBLIC_ORDER_BID_FORBIDDEN" end
    for _, key in ipairs({ "retailServiceFactor", "retailFixedFee", "expectedNegotiationFactor", "minSpreadAbs",
        "minSpreadRate", "commodityTradeCost", "commodityProfit", "specialistTradeCost", "specialistProfit" }) do
        if not nonnegative(options[key]) then return nil, "INVALID_POLICY_" .. key end
    end
    if options.minSpreadRate > 1 or options.retailServiceFactor <= 0 or options.expectedNegotiationFactor > 1 then
        return nil, "INVALID_POLICY_RANGE"
    end
    if not nonnegative(value.commodityRetail) or not nonnegative(value.liquidationNet)
        or type(value.productionRoutes) ~= "table" then return nil, "MISSING_RETAIL_REFERENCE" end
    local count = 0
    for key in pairs(value.productionRoutes) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #value.productionRoutes then return nil, "INVALID_ROUTES" end
        count = count + 1
    end
    if count ~= #value.productionRoutes then return nil, "INVALID_ROUTES" end
    local retailBase = value.commodityRetail
    for _, route in ipairs(value.productionRoutes) do
        if type(route) ~= "table" or type(route.eligible) ~= "boolean" then return nil, "INVALID_ROUTE" end
        if route.purpose ~= "DAIRY" and route.purpose ~= "TERMINAL" and route.purpose ~= "MATERNAL" then
            return nil, "INVALID_ROUTE_PURPOSE"
        end
        if route.eligible then
            if not nonnegative(route.retailReference) then return nil, "INVALID_PRODUCTION_RETAIL" end
            retailBase = math.max(retailBase, route.retailReference)
        end
    end
    local ask = retailBase * options.retailServiceFactor + options.retailFixedFee
    local candidates = { { purpose = "COMMODITY", amount = math.max(0,
        value.liquidationNet - options.commodityTradeCost - options.commodityProfit) } }
    local raw = candidates[1].amount
    for _, route in ipairs(value.productionRoutes) do
        if route.eligible then
            local waiting, reason = RLMarketMath.waiting({ resale = retailBase * options.expectedNegotiationFactor,
                liquidation = value.liquidationNet, probability = route.probability, months = route.holdingMonths,
                monthlyCost = route.monthlyCost })
            if waiting == nil then return nil, reason end
            local amount = math.max(0, waiting.expectedRevenue - waiting.expectedHoldingCost
                - options.specialistTradeCost - options.specialistProfit)
            candidates[#candidates + 1] = { purpose = route.purpose, amount = amount, waiting = waiting }
            raw = math.max(raw, amount)
        end
    end
    local cap = math.max(0, ask - math.max(options.minSpreadAbs, ask * options.minSpreadRate))
    if not nonnegative(ask) or not nonnegative(raw) or not nonnegative(cap) then return nil, "VALUE_OVERFLOW" end
    return { ask = ask, bid = math.min(raw, cap), rawBid = raw, spreadCap = cap,
        retailBase = retailBase, candidates = candidates, currencyBasis = "HARD",
        spreadCapApplied = raw > cap, reason = raw > cap and "SPREAD_CAP_APPLIED" or nil }
end
-- Virtual costs only, split for diagnostics. An absent cost is not a free cost.
function P.holdingCost(costs)
    if type(costs) ~= "table" then return nil, "MISSING_HOLDING_COST" end
    local result = { total = 0 }
    for _, key in ipairs({ "feed", "care", "risk", "finance" }) do
        if not nonnegative(costs[key]) then return nil, "INVALID_HOLDING_COST_" .. key end
        result[key], result.total = costs[key], result.total + costs[key]
    end
    if not nonnegative(result.total) then return nil, "VALUE_OVERFLOW" end
    return result
end
