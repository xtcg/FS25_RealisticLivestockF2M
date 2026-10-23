-- Finite public buyers are diagnostics only. Never use their capacity to back
-- an unlimited Dealer BID; this service neither reserves quota nor issues quotes.
RLBrokerPublicRoute = {}
local P = RLBrokerPublicRoute
local function nonnegative(v) return RLMarketMoney.finite(v) and v >= 0 end
local function positiveInteger(v) return nonnegative(v) and v >= 1 and v % 1 == 0 end
local function copy(v) return assert(RLMarketData.copy(v)) end
function P.new(orderService)
    if type(orderService) ~= "table" or type(orderService.preflight) ~= "function" then return nil, "PREFLIGHT_SERVICE_REQUIRED" end
    local api, busy = {}, false
    function api:diagnose(principal, requests, policy)
        if busy then return nil, "PUBLIC_ROUTE_SYNCHRONOUS_FENCE" end
        busy = true
        local ok, result, failure = pcall(function()
            local actor, input, options = copy(principal), copy(requests), copy(policy)
            if type(options) ~= "table" or options.publishedOrderInformDealerBid ~= false then return nil, "PUBLIC_ORDER_BID_FORBIDDEN" end
            if options.currencyBasis ~= "CURRENT" or not nonnegative(options.dealerBid)
                or not nonnegative(options.tradeCost) or not nonnegative(options.profit) then return nil, "INVALID_PUBLIC_ROUTE_POLICY" end
            if type(input) ~= "table" or #input > 1000 then return nil, "INVALID_PUBLIC_ROUTE_REQUESTS" end
            local count = 0
            for key in pairs(input) do
                if not positiveInteger(key) or key > #input then return nil, "INVALID_PUBLIC_ROUTE_REQUESTS" end
                count = count + 1
            end
            if count ~= #input then return nil, "INVALID_PUBLIC_ROUTE_REQUESTS" end
            local report = {currencyBasis = "CURRENT", actualDealerBid = options.dealerBid,
                publishedOrderInformDealerBid = false, shadowOnly = true, candidates = {}, rejected = {}}
            local animal, source, seen = nil, nil, {}
            for _, req in ipairs(input) do
                if type(req) ~= "table" or type(req.orderId) ~= "string" or type(req.animalKey) ~= "string"
                    or type(req.sourceRef) ~= "string" or (req.transportMode ~= "PICKUP" and req.transportMode ~= "SELF_DELIVERY") then return nil, "INVALID_PUBLIC_ROUTE_REQUEST" end
                if animal and (animal ~= req.animalKey or source ~= req.sourceRef) then return nil, "MIXED_PUBLIC_ROUTE_ANIMALS" end
                animal, source = req.animalKey, req.sourceRef
                local key = assert(RLMarketData.fingerprint(req))
                if seen[key] then return nil, "DUPLICATE_PUBLIC_ROUTE_REQUEST" end
                seen[key] = true
                local preflight, reason = orderService:preflight(copy(actor), copy(req))
                local rejected = reason
                local money, available
                if type(preflight) ~= "table" then rejected = rejected or "PREFLIGHT_UNAVAILABLE"
                elseif type(preflight.eligibility) ~= "table" or preflight.eligibility.eligible ~= true then rejected = "BUYER_INELIGIBLE_OR_UNAVAILABLE"
                elseif type(preflight.order) ~= "table" or preflight.order.orderId ~= req.orderId then rejected = "PUBLIC_ORDER_SCOPE_MISMATCH"
                elseif type(preflight.location) ~= "table" or preflight.location[req.transportMode] ~= true then rejected = "TRANSPORT_SOURCE_UNSUPPORTED"
                elseif type(preflight.price) ~= "table" or preflight.price.sourceVerified ~= true then rejected = "SOURCE_PROOF_REQUIRED"
                else
                    local price = preflight.price
                    money = req.transportMode == "PICKUP" and price.pickup or price.selfDelivery
                    local quota = preflight.context and preflight.context.quota
                    if type(quota) ~= "table" or not positiveInteger(quota.order) or not positiveInteger(quota.species) or not positiveInteger(quota.breed) then rejected = "PUBLIC_CAPACITY_UNAVAILABLE"
                    elseif type(money) ~= "table" or money.currencyBasis ~= "CURRENT" or money.settlementDirection ~= "IN" then rejected = "INVALID_PUBLIC_ROUTE_MONEY"
                    else
                        available = math.min(quota.order, quota.species, quota.breed)
                        local rebuilt = assert(RLMarketMoney.new()):breakdown(money.bodyAmount, money.fees, money.bonuses, "IN")
                        if rebuilt == nil or rebuilt.netToPlayer ~= money.netToPlayer or rebuilt.bodyAmount ~= money.bodyAmount
                            or rebuilt.totalFees ~= money.totalFees or rebuilt.totalBonuses ~= money.totalBonuses
                            or RLMarketData.fingerprint(rebuilt.fees) ~= RLMarketData.fingerprint(money.fees)
                            or RLMarketData.fingerprint(rebuilt.bonuses) ~= RLMarketData.fingerprint(money.bonuses)
                            or not nonnegative(money.netToPlayer) or money.netToPlayer <= 0 then rejected = "INVALID_PUBLIC_ROUTE_MONEY" end
                    end
                end
                if rejected then report.rejected[#report.rejected + 1] = {request = req, reason = rejected}
                else
                    local value = math.max(0, money.netToPlayer - options.tradeCost - options.profit)
                    if not nonnegative(value) then return nil, "PUBLIC_ROUTE_OVERFLOW" end
                    report.candidates[#report.candidates + 1] = {request = req, monthId = preflight.order.monthId,
                        purpose = "BROKER_SHADOW", amount = value, remainingHeadCapacity = available,
                        money = copy(money), tradeCost = options.tradeCost, profit = options.profit}
                    report.bestShadowBid = math.max(report.bestShadowBid or 0, value)
                end
            end
            return report
        end)
        busy = false
        if not ok then return nil, "PUBLIC_ROUTE_ERROR" end
        return result, failure
    end
    return api
end
