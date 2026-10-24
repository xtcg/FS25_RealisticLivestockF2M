loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLMarketMoney.lua")
loadMod("scripts/market/RLBrokerPricePolicy.lua")
loadMod("scripts/market/RLBrokerPublicRoute.lua")
local function cp(v) return assert(RLMarketData.copy(v)) end
local input = {buyerReference = 1200, bonus = 100, commissionRate = .05, ask = 1600,
    minSpreadAbs = 10, minSpreadRate = .04, difficultyMultiplier = 1, pickupFee = 50,
    finished = false, sourceResult = {verified = true, limited = false}}
local price = assert(RLBrokerPricePolicy.quote(input))
local row = {eligibility = {eligible = true}, order = {orderId = "o1", monthId = "m1"},
    context = {quota = {order = 5, species = 3, breed = 2}}, price = price, location = {PICKUP = true, SELF_DELIVERY = true}}
local calls, nested, route = 0, nil, nil
local source = {preflight = function(_, _, req)
    calls = calls + 1
    if nested then local _, why = route:diagnose({}, {}, {}); nested = why end
    local r = cp(row); r.order.orderId = req.orderId
    if req.orderId == "expired" then r.eligibility.eligible = false end
    return r
end}
route = assert(RLBrokerPublicRoute.new(source))
local function request(id, mode) return {orderId = id, animalKey = "1 2 3", sourceRef = "p1", transportMode = mode or "PICKUP"} end
local policy = {currencyBasis = "CURRENT", publishedOrderInformDealerBid = false, dealerBid = 900, tradeCost = 20, profit = 30}
local result = assert(route:diagnose({userId = "alice", farmId = 1}, {request("o1"), request("o1", "SELF_DELIVERY")}, policy))
check("public route: actual Broker pricing gives finite shadow candidate only", result.actualDealerBid == 900 and result.shadowOnly and result.publishedOrderInformDealerBid == false and result.bestShadowBid == price.selfDelivery.netToPlayer - 50 and #result.candidates == 2)
check("public route: candidate capacity is minimum of all three balances", result.candidates[1].remainingHeadCapacity == 2 and row.context.quota.breed == 2)
check("public route: transport fee preserved once in candidate difference", result.candidates[2].amount - result.candidates[1].amount == 50)
local original = RLMarketData.fingerprint(row)
result.candidates[1].money.bodyAmount = 999
check("public route: outputs do not mutate source or policy", original == RLMarketData.fingerprint(row) and policy.dealerBid == 900)
local before = calls; local enabled = cp(policy); enabled.publishedOrderInformDealerBid = true
local no, why = route:diagnose({}, {request("o1")}, enabled)
check("public route: real BID enable is rejected before any preflight", no == nil and why == "PUBLIC_ORDER_BID_FORBIDDEN" and calls == before)
row.context.quota.species = 0
result = assert(route:diagnose({}, {request("o1")}, policy))
check("public route: exhausted shared species pool yields no candidate", #result.candidates == 0 and result.actualDealerBid == 900 and result.rejected[1].reason == "PUBLIC_CAPACITY_UNAVAILABLE")
row.context.quota.species = 3
result = assert(route:diagnose({}, {request("expired")}, policy))
check("public route: expired or ineligible order yields no candidate", #result.candidates == 0 and result.bestShadowBid == nil)
row.price.sourceVerified = false
result = assert(route:diagnose({}, {request("o1")}, policy))
check("public route: unknown provenance cannot back shadow available-buyer value", #result.candidates == 0 and result.rejected[1].reason == "SOURCE_PROOF_REQUIRED")
row.price.sourceVerified = true; row.price.pickup.netToPlayer = row.price.pickup.netToPlayer + 1
result = assert(route:diagnose({}, {request("o1")}, policy))
check("public route: forged total rejected against actual line arithmetic", #result.candidates == 0 and result.rejected[1].reason == "INVALID_PUBLIC_ROUTE_MONEY")
row.price = price
no, why = route:diagnose({}, {request("o1"), request("o1")}, policy)
check("public route: duplicate diagnostic requests rejected", no == nil and why == "DUPLICATE_PUBLIC_ROUTE_REQUEST")
local mixed = request("o2"); mixed.animalKey = "2 3 4"
no, why = route:diagnose({}, {request("o1"), mixed}, policy)
check("public route: mixed-animal bids cannot be maximized together", no == nil and why == "MIXED_PUBLIC_ROUTE_ANIMALS")
nested = true; result = assert(route:diagnose({}, {request("o1")}, policy))
check("public route: preflight callback reentry fenced", nested == "PUBLIC_ROUTE_SYNCHRONOUS_FENCE" and result.actualDealerBid == 900)
nested = nil
row.price = assert(RLBrokerPricePolicy.quote(input, assert(RLMarketMoney.new({unit = .01, verifyRoundTrip = function() return true end}))))
result = assert(route:diagnose({}, {request("o1")}, policy))
check("public route: diagnostic accepts verified-unit receipt without changing line amounts", #result.candidates == 1 and result.candidates[1].money.settlementUnit == .01)
