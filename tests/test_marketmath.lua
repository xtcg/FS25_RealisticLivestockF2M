loadMod("scripts/market/RLMarketMoney.lua")
loadMod("scripts/market/RLMarketMath.lua")
loadMod("scripts/market/RLDealerPricePolicy.lua")
local M, P = RLMarketMath, RLDealerPricePolicy
local example = assert(M.fixed(3650, 1800, 0.1, 3, 65))
check("waiting: design independent pH 0.271", near(example.saleProbability, 0.271, 1e-12))
check("waiting: design independent E[T] 2.71", near(example.expectedMonths, 2.71, 1e-12))
check("waiting: design independent revenue 2301.35", near(example.expectedRevenue, 2301.35, 1e-10))
check("waiting: design independent holding cost 176.15", near(example.expectedHoldingCost, 176.15, 1e-10))
check("waiting: design specialist candidate 1900.20", near(example.expectedRevenue - example.expectedHoldingCost - 95 - 130, 1900.20, 1e-10))
local zero = assert(M.fixed(3650, 1800, 0.1, 0, 65))
check("waiting: H0 is immediate liquidation", zero.saleProbability == 0 and zero.expectedRevenue == 1800 and zero.expectedHoldingCost == 0)
zero = assert(M.fixed(3650, 1800, 0, 3, 65))
check("waiting: pm0 all months plus liquidation", zero.expectedRevenue == 1800 and zero.expectedMonths == 3 and zero.expectedHoldingCost == 195)
local certain = assert(M.fixed(3650, 1800, 1, 3, 65))
check("waiting: pm1 sells at end of first month with full month cost", certain.expectedRevenue == 3650
    and certain.expectedMonths == 1 and certain.expectedHoldingCost == 65)
local flat = {}; for month = 1, 12 do flat[month] = 1 end
local seasonal = assert(M.seasonal(3650, 1800, 0.1, 3, 65, 12, flat))
check("waiting: flat season reduces to fixed model", seasonal.expectedRevenue == example.expectedRevenue
    and seasonal.expectedHoldingCost == example.expectedHoldingCost)
flat[12], flat[1], flat[2] = 0, 1, 2
seasonal = assert(M.seasonal(100, 0, 0.5, 3, 10, 12, flat))
check("waiting: December then January then February", seasonal.months[1].probability == 0
    and seasonal.months[2].probability == 0.5 and seasonal.months[3].probability == 1
    and seasonal.expectedRevenue == 100 and seasonal.expectedHoldingCost == 25)
check("waiting: invalid pm/H/season rejected", M.fixed(1, 1, 1.01, 3, 1) == nil
    and M.fixed(1, 1, 0.1, 3.5, 1) == nil and M.fixed(1, 1, 0/0, 0, 1) == nil
    and M.seasonal(1, 1, 0.1, 3, 1, 1, {}) == nil)
local options = { retailServiceFactor = 1.3, retailFixedFee = 0, expectedNegotiationFactor = 1,
    minSpreadAbs = 10, minSpreadRate = 0.04, commodityTradeCost = 50, commodityProfit = 50,
    specialistTradeCost = 95, specialistProfit = 130, publishedOrderInformDealerBid = false }
local references = { commodityRetail = 1800, liquidationNet = 1800,
    productionRoutes = { { purpose = "TERMINAL", eligible = true, retailReference = 3650,
        probability = 0.1, holdingMonths = 3, monthlyCost = 65 } } }
local quote = assert(P.quote(references, options))
check("dealer: independent ASK uses retail reference", quote.ask == 4745 and quote.retailBase == 3650)
check("dealer: max commodity/specialist candidate", near(quote.bid, 1900.20, 1e-10) and not quote.spreadCapApplied)
options.commodityProfit = 500
local changed = assert(P.quote(references, options))
check("dealer: ASK independent of BID cost changes", changed.ask == quote.ask)
references.productionRoutes[2] = { purpose = "MATERNAL", eligible = true, retailReference = 3650,
    probability = 0.1, holdingMonths = 3, monthlyCost = 65 }
changed = assert(P.quote(references, options))
check("dealer: alternatives are max rather than sum", changed.bid == quote.bid and changed.ask == quote.ask)
options.minSpreadAbs = 5000
changed = assert(P.quote(references, options))
check("dealer: low-value spread cap yields zero instead of negative", changed.bid == 0 and changed.spreadCapApplied)
options.publishedOrderInformDealerBid = true
check("dealer: public order never raises real BID", P.quote(references, options) == nil)
local cost = assert(P.holdingCost({ feed = 40, care = 10, risk = 5, finance = 10 }))
check("holding: component costs only and no free missing capability", cost.total == 65 and P.holdingCost({feed=40}) == nil)
options.publishedOrderInformDealerBid = false
references.productionRoutes = { [2] = references.productionRoutes[1] }
check("dealer: sparse routes never silently disappear",P.quote(references,options)==nil)
