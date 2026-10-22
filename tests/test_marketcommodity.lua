loadMod("tests/fixtures/market_production.lua")
local V = RLMarketCommodityValue
local s = MarketProductionFixture.snapshot("COW")
local input = { currencyBasis = "HARD", rearing = { futureGross = 120, remainingCost = 20, discountRate = 0, months = 6 } }
check("commodity: young animal retains independent future rearing net", V.evaluate(s, input).referenceValue == 100)
input.slaughter = { available = true, net = 90, basis={moneyBasis="HARD"} }
check("commodity: uses best alternative rather than adding flesh and rearing", V.evaluate(s, input).referenceValue == 100)
input.slaughter.net = 130
check("commodity: current S may be best reference", V.evaluate(s, input).referenceValue == 130)
input.rearing.remainingCost = nil
check("commodity: unknown remaining costs are not free", V.evaluate(s, input) == nil)
check("commodity: absent immature meat/future route is unsupported", V.evaluate(s, {currencyBasis="HARD"}) == nil)
input = { currencyBasis = "HARD", rearing = { futureGross = 140, remainingCost = 30, discountRate = 0.1, months = 12 } }
check("commodity: independently hand-discounted future net", near(V.evaluate(s, input).referenceValue, 100, 1e-10))
local bad={currencyBasis="HARD",slaughter={available=true,net=90,basis={moneyBasis="CURRENT"}}}
check("commodity: CURRENT slaughter cannot be silently relabeled HARD",V.evaluate(s,bad)==nil)
bad.slaughter.basis=nil
check("commodity: missing slaughter basis is unknown capability",V.evaluate(s,bad)==nil)
