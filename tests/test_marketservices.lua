-- Independent routing assertions; synthetic values here test contracts, not economics.
loadMod("scripts/market/RLMarketSchema.lua")
loadMod("scripts/market/RLAnimalValueProvider.lua")
loadMod("scripts/market/RLLegacyPriceAdapter.lua")
loadMod("scripts/market/RLMarketPriceService.lua")
local function snapshot(species)
    return { schemaVersion = 1, identityKey = "1 22 3", stateRevision = "state1",
        animalType = "COW", speciesKey = species or "COW", breed = "ANGUS", subTypeName = "BULL_ANGUS",
        productionClass = "BEEF", classRevision = "class1", traitMappingRevision = "traits1",
        gender = "male", ageMonths = 18, traitCapabilities = { meatQuality = true },
        supportedBreedingRoles = { "TERMINAL" }, weightKg = 600 }
end
local function context(channel, objective)
    return { schemaVersion = 1, channel = channel or "DEALER_SELL", breedingObjective = objective,
        classRevision = "class1", traitMappingRevision = "traits1", marketEpoch = "epoch1",
        configRevision = "config1", formulaVersion = 1, priceRevision = "prices1",
        difficultyMultiplier = 1, calendarMonth = 10, absoluteMonths = 42 }
end
local function value()
    return { schemaVersion = 1, providerId = "test", providerVersion = 1, commodityValue = 0,
        capabilities = { commodity = true, breeding = false, slaughter = false },
        slaughter = { available = false, basis = {} }, breeding = { byObjective = {} } }
end
local registry = RLAnimalValueProvider.new()
local calls, fail, recurse, result, recursiveReason = 0, false, false, value(), nil
local provider = { id = "test", version = 1,
    supports = function(s, c) s.weightKg = 2; c.configRevision = "changed"; return true end,
    evaluate = function(s, c)
        calls = calls + 1
        assert(s.weightKg == 600 and c.configRevision == "config1")
        if fail then error("provider fault") end
        if recurse then local _, reason = registry:evaluate(s, c); recursiveReason = reason end
        s.weightKg = 4
        return result
    end,
    breedingEligibility = function() return { eligible = false } end,
    holdingCost = function() return { total = 0 } end }
check("provider: explicit registration", registry:register("COW", "COMMODITY", provider))
local registered, why = registry:register("COW", "COMMODITY", provider)
check("provider: duplicate scope rejected", not registered and why == "DUPLICATE_SCOPE")
provider.evaluate = function() error("registration was mutated") end
local s, c = snapshot(), context()
local output = registry:evaluate(s, c)
check("provider: real zero accepted, input and registration isolated", output and output.commodityValue == 0
    and s.weightKg == 600 and c.configRevision == "config1")
output.commodityValue = 99
check("provider: result is detached", result.commodityValue == 0)
local _, reason = registry:evaluate(snapshot("GOAT"), c)
check("provider: unknown species never borrows cattle", reason == "UNSUPPORTED")
_, reason = registry:evaluate(s, context(nil, "MATERNAL"))
check("provider: missing breeding objective never uses commodity", reason == "UNSUPPORTED")
local before = calls
registry:evaluate(snapshot("SHEEP"), c)
check("provider: unsupported dispatch invokes no provider", calls == before)
local mismatched = context()
mismatched.classRevision = "class2"
_, reason = registry:evaluate(s, mismatched)
check("provider: wrong classification revision never invokes provider",
    reason == "SNAPSHOT_VERSION_MISMATCH" and calls == before)
mismatched = context()
mismatched.traitMappingRevision = "traits2"
_, reason = registry:evaluate(s, mismatched)
check("provider: wrong trait revision never invokes provider",
    reason == "SNAPSHOT_VERSION_MISMATCH" and calls == before)
fail = true
_, reason = registry:evaluate(s, c)
check("provider: faults are explicit", reason == "PROVIDER_ERROR")
fail = false
check("provider: fault releases evaluation guard", registry:evaluate(s, c) ~= nil)
recurse = true
registry:evaluate(s, c)
check("provider: reentry is rejected", recursiveReason == "RECURSIVE_PROVIDER")
recurse = false
result.providerVersion = 2
_, reason = registry:evaluate(s, c)
check("provider: mismatched output version rejected", reason == "PROVIDER_VERSION_MISMATCH")
result = value()
s.getSellPrice = function() error("live price should not cross boundary") end
_, reason = registry:evaluate(s, c)
check("provider: executable animal object rejected", reason == "INVALID_WIRE_VALUE")
s = snapshot()

local bidCalls, askCalls, marketCalls, observed = 0, 0, 0, nil
local old = assert(RLLegacyPriceAdapter.new(
    function(a) bidCalls = bidCalls + 1; return a.bid end,
    function(a) askCalls = askCalls + 1; return a.ask end))
local ready, broken, stale, wrongSide = false, false, false, false
local function quote(side, snap, ctx)
    marketCalls = marketCalls + 1
    if broken then error("market fault") end
    return { schemaVersion = 1, status = "OK", channel = wrongSide and "DEALER_SELL" or ctx.channel,
        settlementDirection = (wrongSide or side == "BID") and "IN" or "OUT",
        identityKey = snap.identityKey, stateRevision = stale and "old-state" or snap.stateRevision,
        eligibilityFingerprint = "eligible1", settlementFingerprint = "money1",
        classRevision = ctx.classRevision, traitMappingRevision = ctx.traitMappingRevision,
        marketEpoch = ctx.marketEpoch, configRevision = ctx.configRevision, formulaVersion = ctx.formulaVersion,
        priceRevision = ctx.priceRevision, expiresAt = 15000, candidatePaths = {}, reasons = {},
        bodyAmount = 100, fees = 0, bonuses = 0, netToPlayer = side == "BID" and 100 or -100,
        selectedUse = "COMMODITY" }
end
local service = assert(RLMarketPriceService.new({ legacy = old, marketQuote = quote,
    pricingReady = function() return ready end,
    observe = function(record) observed = record; record.legacy.bodyAmount = -999 end }))
local input = { bid = 23.123456789, ask = 30.987654321 }
output = service:quote("ASK", input, nil, nil)
check("mode: defaults to legacy with exact old precision", service:getMode() == "legacy"
    and output.bodyAmount == input.ask and askCalls == 1 and bidCalls == 0 and marketCalls == 0)
service:setMode("shadow")
output = service:quote("BID", input, s, c)
check("shadow: closed gate returns unchanged legacy", output.bodyAmount == input.bid
    and observed.reason == "MARKET_NOT_READY" and marketCalls == 0)
ready = true
output = service:quote("BID", input, s, c)
check("shadow: observer cannot change returned price", output.bodyAmount == input.bid
    and observed.candidate.bodyAmount == 100 and marketCalls == 1)
broken = true
output = service:quote("BID", input, s, c)
check("shadow: evaluator errors preserve legacy", output.bodyAmount == input.bid and observed.reason == "SHADOW_ERROR")
broken = false
service:setMode("market")
local oldCalls = bidCalls + askCalls
output = service:quote("ASK", input, s, context("DEALER_BUY"))
check("market: explicit ready gate and no repeated markup", output and output.bodyAmount == 100
    and output.netToPlayer == -100 and bidCalls + askCalls == oldCalls)
stale = true
_, reason = service:quote("BID", input, s, c)
check("market: stale identity state rejected", reason == "QUOTE_SCOPE_MISMATCH")
stale, wrongSide = false, true
_, reason = service:quote("ASK", input, s, context("DEALER_BUY"))
check("market: opposite-channel quote rejected", reason == "QUOTE_SCOPE_MISMATCH")
wrongSide, ready = false, false
_, reason = service:quote("BID", input, s, c)
check("market: disabled capability refuses trade-shaped result", reason == "MARKET_NOT_READY")
local changed = service:setMode("typo")
check("mode: invalid configuration fails closed to legacy", not changed and service:getMode() == "legacy")
local recursive
recursive = assert(RLLegacyPriceAdapter.new(function() return recursive:quote("BID", {}) end, function() return 1 end))
_, reason = recursive:quote("BID", {})
check("legacy: recursion fails without calling a new market price", reason == "INVALID_LEGACY_PRICE")
local invalid = assert(RLLegacyPriceAdapter.new(function() return 0/0 end, function() return -1 end))
check("legacy: nonfinite and negative prices rejected", invalid:quote("BID", {}) == nil and invalid:quote("ASK", {}) == nil)
