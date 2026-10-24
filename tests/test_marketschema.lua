loadMod("scripts/market/RLMarketSchema.lua")
local S = RLMarketSchema
local function copy(v)
    if type(v) ~= "table" then return v end
    local result = {}
    for k, item in pairs(v) do result[k] = copy(item) end
    return result
end
local snapshot = {
    schemaVersion = 1, identityKey = "1 2 3", stateRevision = "animal-r1",
    animalType = "SHEEP", speciesKey = "SHEEP", breed = "TEXEL", subTypeName = "SHEEP_TEXEL",
    productionClass = "BEEF", classRevision = "class-1", traitMappingRevision = "traits-1",
    gender = "male", ageMonths = 7.2, weightKg = 47,
    supportedBreedingRoles = {"TERMINAL", "MATERNAL"}, traitCapabilities = {milkProductivity = false},
    production = {finishScore = 0}, reproductive = {pregnant = false, parity = 0},
}
local value = {
    schemaVersion = 1, providerId = "cattleLegacy", providerVersion = 1,
    capabilities = {commodity = true, breeding = false, slaughter = false}, commodityValue = 0,
    slaughter = {available = false, basis = {}}, breeding = {byObjective = {}}, legacy = {bid = 0, ask = 0},
}
local quote = {
    schemaVersion = 1, status = "OK", identityKey = "1 2 3", stateRevision = "animal-r1",
    eligibilityFingerprint = "e1", settlementFingerprint = "s1",
    channel = "DEALER_BUY", settlementDirection = "OUT",
    classRevision = "c1", traitMappingRevision = "t1", marketEpoch = 1,
    configRevision = "cfg1", formulaVersion = 1, priceRevision = "p1", expiresAt = 15000,
    bodyAmount = 100, fees = 10, bonuses = 0, netToPlayer = -110,
    selectedUse = "legacy", candidatePaths = {}, reasons = {},
}
local context = {
    schemaVersion = 1, channel = "DEALER_BUY", classRevision = "c1", traitMappingRevision = "t1",
    marketEpoch = 1, configRevision = "cfg1", formulaVersion = 1, priceRevision = "p1",
    difficultyMultiplier = 1, calendarMonth = 12, absoluteMonths = 7.2,
}
check("schema: valid snapshot preserves real zero and absent measurement", S.validateSnapshot(snapshot) and snapshot.production.finishScore == 0 and snapshot.targetWeightKg == nil)
check("schema: zero commodity is valid value, not trading permission", S.validateValueBreakdown(value))
check("schema: signed purchase quote", S.validateQuote(quote))
check("schema: quote binds requested side and animal", S.validateQuote(quote, {side = "ASK", identityKey = "1 2 3", stateRevision = "animal-r1"}))
check("schema: BID caller rejects an ASK quote", not S.validateQuote(quote, {side = "BID"}))
check("schema: quote cannot bind another animal", not S.validateQuote(quote, {identityKey = "9 9 9"}))
check("schema: quote cannot bind another revision", not S.validateQuote(quote, {stateRevision = "animal-r2"}))
check("schema: explicit quote clock and versions", S.validateQuoteContext(context))

for _, row in ipairs({{S.validateSnapshot, snapshot}, {S.validateValueBreakdown, value}, {S.validateQuote, quote}, {S.validateQuoteContext, context}}) do
    local v = copy(row[2]); v.schemaVersion = 2
    local ok, reason = row[1](v)
    check("schema: unknown version rejected " .. tostring(row[1]), not ok and reason == "UNSUPPORTED_SCHEMA_VERSION")
    check("schema: non-table rejected " .. tostring(row[1]), not row[1](nil))
end
local function bad(name, validator, original, mutate)
    local v = copy(original); mutate(v)
    local ok, reason = validator(v)
    check("schema: " .. name, not ok and type(reason) == "string")
end
bad("identity missing", S.validateSnapshot, snapshot, function(v) v.identityKey = nil end)
bad("state fingerprint missing", S.validateSnapshot, snapshot, function(v) v.stateRevision = "" end)
bad("trait mapping version missing", S.validateSnapshot, snapshot, function(v) v.traitMappingRevision = nil end)
bad("age negative", S.validateSnapshot, snapshot, function(v) v.ageMonths = -1 end)
bad("finish bounded independently", S.validateSnapshot, snapshot, function(v) v.production.finishScore = 101 end)
bad("bcs not finish score", S.validateSnapshot, snapshot, function(v) v.production.bcs = 60 end)
bad("parity integral", S.validateSnapshot, snapshot, function(v) v.reproductive.parity = 0.5 end)
bad("gene number required", S.validateSnapshot, snapshot, function(v) v.genes = {quality = "1"} end)
bad("breeding roles unique", S.validateSnapshot, snapshot, function(v) v.supportedBreedingRoles = {"DAIRY", "DAIRY"} end)
bad("missing commodity capability", S.validateValueBreakdown, value, function(v) v.capabilities.commodity = nil end)
bad("unavailable commodity cannot invent zero", S.validateValueBreakdown, value, function(v) v.capabilities.commodity = false end)
bad("available commodity needs value", S.validateValueBreakdown, value, function(v) v.commodityValue = nil end)
bad("unimplemented production cannot invent zero", S.validateValueBreakdown, value, function(v) v.productionReference = 0 end)
local production = copy(value); production.capabilities.production = true; production.productionReference = 0
check("schema: implemented true zero production", S.validateValueBreakdown(production))
local unsupported = copy(value); unsupported.capabilities.commodity = false; unsupported.commodityValue = nil
check("schema: unsupported commodity is explicit absence", S.validateValueBreakdown(unsupported))
bad("unavailable slaughter cannot invent zero", S.validateValueBreakdown, value, function(v) v.slaughter.net = 0 end)
bad("slaughter capability must match availability", S.validateValueBreakdown, value, function(v) v.slaughter.available = true end)
local slaughter = copy(value); slaughter.capabilities.slaughter = true
slaughter.slaughter = {available = true, net = -5, meatKg = 0, gross = 0, fees = 5, basis = {currency = "HARD"}}
check("schema: real negative slaughter net allowed", S.validateValueBreakdown(slaughter))
bad("unsupported breeding objective cannot appear", S.validateValueBreakdown, value, function(v) v.breeding.byObjective.DAIRY = {} end)
local breeding = copy(value); breeding.capabilities.breeding = true
breeding.breeding.byObjective.MATERNAL = {selectionIndex = 1, valuationScore = 0, referenceValue = 0, ownDelta = -2, hereditaryDelta = 2, eligible = false, reasons = {"TOO_YOUNG"}}
check("schema: objective value retains signed deltas and rejection", S.validateValueBreakdown(breeding))
bad("provider version required", S.validateValueBreakdown, value, function(v) v.providerVersion = nil end)
for _, invalid in ipairs({math.huge, -math.huge, 0 / 0}) do
    bad("non-finite snapshot extension", S.validateSnapshot, snapshot, function(v) v.extension = {severity = invalid} end)
    bad("non-finite monetary value", S.validateValueBreakdown, value, function(v) v.commodityValue = invalid end)
    bad("non-finite quote amount", S.validateQuote, quote, function(v) v.netToPlayer = invalid end)
end
bad("cyclic wire data", S.validateSnapshot, snapshot, function(v) v.self = v end)
bad("purchase cannot become positive income", S.validateQuote, quote, function(v) v.netToPlayer = 110 end)
bad("channel cannot reverse purchase direction", S.validateQuote, quote, function(v) v.settlementDirection = "IN" end)
bad("unknown channel rejected", S.validateQuote, quote, function(v) v.channel = "UNKNOWN" end)
bad("zero body cannot be tradable", S.validateQuote, quote, function(v) v.bodyAmount = 0 end)
bad("price version required", S.validateQuote, quote, function(v) v.priceRevision = nil end)
bad("negative fee", S.validateQuote, quote, function(v) v.fees = -1 end)
local rejected = copy(quote)
rejected.status = "UNSUPPORTED"; rejected.bodyAmount = nil; rejected.fees = nil
rejected.bonuses = nil; rejected.netToPlayer = nil; rejected.reasons = {"NO_PROVIDER"}
check("schema: unsupported quote carries reason and no settlement", S.validateQuote(rejected))
bad("rejected quote cannot resemble free trade", S.validateQuote, rejected, function(v) v.bodyAmount = 0 end)
bad("invalid calendar month", S.validateQuoteContext, context, function(v) v.calendarMonth = 13 end)
bad("difficulty must be positive", S.validateQuoteContext, context, function(v) v.difficultyMultiplier = 0 end)
for _, invalid in ipairs({false, 1, {}, "BEEF"}) do
    bad("invalid breeding objective type or value", S.validateQuoteContext, context, function(v) v.breedingObjective = invalid end)
end

-- Reject executable tables before indexing or iterating them, including extension data.
local validators = {
    {name = "snapshot", validate = S.validateSnapshot, fixture = snapshot},
    {name = "value", validate = S.validateValueBreakdown, fixture = value},
    {name = "quote", validate = S.validateQuote, fixture = quote},
    {name = "context", validate = S.validateQuoteContext, fixture = context},
}
for _, row in ipairs(validators) do
    for _, metamethod in ipairs({"__index", "__pairs"}) do
        local calls = 0
        local mt = {[metamethod] = function() calls = calls + 1; error("executable wire table") end}
        local top = setmetatable({}, mt)
        local called, ok = pcall(row.validate, top)
        check("schema: " .. row.name .. " rejects top " .. metamethod .. " without execution", called and not ok and calls == 0)
        local nested = copy(row.fixture); nested.extension = setmetatable({}, mt)
        called, ok = pcall(row.validate, nested)
        check("schema: " .. row.name .. " rejects nested " .. metamethod .. " without execution", called and not ok and calls == 0)
    end
end
for _, metamethod in ipairs({"__index", "__pairs"}) do
    local calls = 0
    local mt = {[metamethod] = function() calls = calls + 1; error("executable expected") end}
    for _, expected in ipairs({setmetatable({}, mt), {extension = setmetatable({}, mt)}}) do
        local called, ok = pcall(S.validateQuote, quote, expected)
        check("schema: rejects expected " .. metamethod .. " without execution", called and not ok and calls == 0)
    end
end
check("schema: rejects protected metatable", not S.validateSnapshot(setmetatable(copy(snapshot), {__metatable = false})))
check("schema: expected rejects non-finite extension", not S.validateQuote(quote, {extension = math.huge}))
local cyclicExpected = {}; cyclicExpected.self = cyclicExpected
check("schema: expected rejects cycles", not S.validateQuote(quote, cyclicExpected))

-- A fresh environment with only Lua primitives proves no game globals are required.
local env = {type = type, pairs = pairs, ipairs = ipairs, next = next, math = math, getmetatable = getmetatable}
local chunk = assert(loadfile(REPO .. "scripts/market/RLMarketSchema.lua", "t", env))
chunk()
check("schema: works without game globals", env.RLMarketSchema.validateSnapshot(snapshot) and env.RLMarketSchema.validateValueBreakdown(value))
check("schema: validation does not supply defaults", snapshot.targetWeightKg == nil and value.productionReference == nil and value.capabilities.production == nil)
