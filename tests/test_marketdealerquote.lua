loadMod("tests/fixtures/market_production.lua")
for _, name in ipairs({"RLMarketMoney", "RLMarketMath", "RLDealerPricePolicy", "RLMarketDealerQuote", "RLMarketPriceService", "RLLegacyPriceAdapter"}) do
    loadMod("scripts/market/" .. name .. ".lua")
end
local F, Q, D = MarketProductionFixture, RLMarketDealerQuote, RLMarketData
local function cp(v) return assert(D.copy(v)) end
local registry = RLAnimalValueProvider.new()
assert(RLMarketProviders.register(registry))
local function setup(species)
    local x = {snapshot = F.snapshot(species or "COW"), time = 1000}
    x.snapshot.traitCapabilities.tradeEligibility = true
    x.snapshot.eligibility = {tradeAllowed = true}
    x.context = F.context(x.snapshot, F.input())
    if species == "PIG" then
        x.context.referenceInputs.production.selectionWeights = {TERMINAL = {quality = .6, health = .4}, MATERNAL = {fertility = .6, health = .4}}
    end
    x.policy = function(s, c)
        return {currencyBasis = "HARD", scopeFingerprint = Q.scope(s, c), publishedOrderInformDealerBid = false,
            retailServiceFactor = 1.2, retailFixedFee = 10, minSpreadAbs = 10, minSpreadRate = .1,
            commodityTradeCost = 5, commodityProfit = 5,
            liquidation = {currencyBasis = "HARD", net = 80, basis = "NET_RECOVERY_AFTER_PROCESSING_BEFORE_LISTED_TRADE_COSTS"},
            fees = {ASK = {{id = "purchase", amount = 3}}, BID = {{id = "sale", amount = 2}}},
            bonuses = {ASK = {}, BID = {}}, quoteTTLms = 15000}
    end
    x.route = function(_, s, c)
        return {currencyBasis = "HARD", scopeFingerprint = Q.scope(s, c), holdingMonths = 1,
            monthlySaleProbability = 1, season = {1,1,1,1,1,1,1,1,1,1,1,1},
            holdingCost = {feed = 5, care = 2, risk = 2, finance = 1}, tradeCost = 5, profit = 5, expectedNegotiationFactor = .9}
    end
    local deps = {registry = registry, nowMs = function() return x.time end,
        policy = function(s,c) return x.policy(s,c) end,
        routePolicy = function(o,s,c,v) return x.route(o,s,c,v) end}
    x.deps = deps
    x.service = assert(Q.new(deps))
    function x:quote(side)
        local c = cp(self.context); c.channel = side == "ASK" and "DEALER_BUY" or "DEALER_SELL"
        return self.service:quote(side, self.snapshot, c)
    end
    return x
end
local x = setup()
local before = D.fingerprint({x.snapshot, x.context})
local ask = assert(x:quote("ASK")); local bid = assert(x:quote("BID"))
check("dealer composition: actual provider references produce protocol-valid pair", RLMarketSchema.validateQuote(ask) and RLMarketSchema.validateQuote(bid) and ask.status == "OK" and bid.status == "OK")
check("dealer composition: common retailBase independently produces ASK and resale", ask.retailBaseHard == 230 and ask.bodyAmount == 286 and bid.bodyAmount == 187 and bid.netToPlayer == 185 and ask.netToPlayer == -289)
check("dealer composition: waiting paths maximize rather than add", #bid.candidatePaths == 4 and bid.pair.rawBidHard == 187 and bid.pair.publicOrdersUsed == false)
check("dealer composition: raw provider inputs remain detached", before == D.fingerprint({x.snapshot, x.context}))
check("dealer composition: costs and own/hereditary gains are not added twice", ask.references.DAIRY.productionReference == ask.retailBaseHard and ask.references.DAIRY.breeding.byObjective.DAIRY.referenceValue == 230)
x.context.difficultyMultiplier = 2
local twice = assert(x:quote("BID"))
check("dealer composition: body fees and net convert HARD to CURRENT exactly once", twice.bodyAmount == 374 and twice.fees == 4 and twice.netToPlayer == 370 and twice.references.DAIRY.productionReference == 230)
x = setup("PIG")
local pig = assert(x:quote("ASK"))
check("dealer composition: unsupported pig dairy excluded without cattle fallback", pig.references.DAIRY == nil and pig.status == "OK" and pig.references.MATERNAL ~= nil)
x = setup(); x.snapshot.genes.productivity = 1.5
local elite = assert(x:quote("ASK"))
local maxReference = elite.references.COMMODITY.commodityValue
for _, objective in ipairs({"DAIRY", "TERMINAL", "MATERNAL"}) do maxReference = math.max(maxReference, elite.references[objective].productionReference) end
check("dealer composition: high genes use provider reference only once", elite.retailBaseHard == maxReference and elite.bodyAmount == maxReference * 1.2 + 10)
x = setup(); x.context.referenceInputs.production.params.offspringBaseNet = nil
local missing, why = x:quote("ASK")
check("dealer composition: missing legal production economics cannot lower independent ASK", missing == nil and why == "DEALER_REFERENCE_UNAVAILABLE")
x = setup(); x.context.referenceInputs.stateRevision = "another animal state"
missing, why = x:quote("ASK")
check("dealer composition: stale provider basis cannot enter either direction", missing == nil and why == "DEALER_REFERENCE_UNAVAILABLE")
x = setup(); local policy = x.policy
x.policy = function(s,c) local p = policy(s,c);p.publishedOrderInformDealerBid = true;return p end
missing, why = x:quote("BID")
check("dealer composition: finite public order actual BID toggle refused", missing == nil and why == "PUBLIC_ORDER_BID_FORBIDDEN")
x = setup(); policy = x.policy
x.policy = function(s,c) local p = policy(s,c);p.liquidation.currencyBasis = "CURRENT";return p end
missing, why = x:quote("ASK")
check("dealer composition: unknown liquidation cost boundary never treated as rearing value", missing == nil and why == "LIQUIDATION_BASIS_REQUIRED")
x = setup(); local route = x.route
x.route = function(o,s,c,v) local r = route(o,s,c,v);r.scopeFingerprint = "old";return r end
missing, why = x:quote("BID")
check("dealer composition: per-objective economic scope must match full quote scope", missing == nil and why == "ROUTE_POLICY_SCOPE_REQUIRED")
x = setup(); x.snapshot.eligibility.tradeAllowed = false
missing, why = x:quote("ASK")
check("dealer composition: real trade prohibition blocks prices", missing == nil and why == "DEALER_TRADE_FORBIDDEN")
x = setup(); x.snapshot.traitCapabilities.tradeEligibility = false
missing, why = x:quote("BID")
check("dealer composition: unknown trade eligibility is not neutral permission", missing == nil and why == "DEALER_TRADE_ELIGIBILITY_UNAVAILABLE")
x = setup(); x.snapshot.supportedBreedingRoles = {}; x.context.referenceInputs.production = nil
local ordinary = assert(x:quote("BID"))
check("dealer composition: genuinely commodity-only animal needs no invented production economics", ordinary.bodyAmount == 70 and ordinary.references.DAIRY == nil)
x = setup(); x.snapshot.castrated = true; x.context.referenceInputs.production = nil
ordinary = assert(x:quote("BID"))
check("dealer composition: castrated animal uses known commodity scope", ordinary.bodyAmount == 70 and #ordinary.candidatePaths == 1)
x = setup(); x.snapshot.supportedBreedingRoles = {}; policy = x.policy
x.policy = function(s,c) local p = policy(s,c);p.liquidation.net = 0;p.retailServiceFactor = .001;p.retailFixedFee = 0;return p end
local low = assert(x:quote("BID"))
check("dealer composition: low value BID is rejected without settlement-shaped zero", low.status == "REJECTED" and low.bodyAmount == nil and low.netToPlayer == nil and RLMarketSchema.validateQuote(low))
x = setup(); x.context.difficultyMultiplier = 1e308
missing = x:quote("ASK")
check("dealer composition: conversion overflow cannot create a quote", missing == nil)
x = setup(); local nesting
x.policy = function(s,c) local _, reason = x:quote("ASK");nesting = reason;return policy(s,c) end
local outer = assert(x:quote("ASK"))
check("dealer composition: policy callbacks cannot recurse into pricing", outer.status == "OK" and nesting == "RECURSIVE_DEALER_QUOTE")
x = setup(); local commodityOnly = RLAnimalValueProvider.new()
assert(commodityOnly:register("COW", "COMMODITY", registry.providers.COW.COMMODITY))
x.deps.registry = commodityOnly; x.service = assert(Q.new(x.deps))
ordinary = assert(x:quote("BID"))
check("dealer composition: unimplemented targets explicitly unsupported while commodity scope works", ordinary.status == "OK" and ordinary.bodyAmount == 70 and #ordinary.reasons == 3 and ordinary.references.DAIRY == nil)
x = setup(); route = x.route
x.route = function(o,s,c,v) local r = route(o,s,c,v);r.season[13] = 1;return r end
missing, why = x:quote("BID")
check("dealer composition: season cannot silently include a thirteenth month", missing == nil and why == "INVALID_SEASON")
x = setup(); x.deps.moneyPolicy = assert(RLMarketMoney.new({unit = .01, verifyRoundTrip = function() return true end}));x.service = assert(Q.new(x.deps))
local quantized = assert(x:quote("BID"))
check("dealer composition: explicitly verified money policy preserves final body and cash spreads", quantized.money.settlementUnit == .01 and quantized.bodyAmount <= quantized.pair.spreadCapCurrent and quantized.netToPlayer < -quantized.pair.ask.netToPlayer)
