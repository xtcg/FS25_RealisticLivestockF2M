-- Versioned, read-only market protocol validation. No animal adapters or engine access.
-- Validators return true, or false and a stable field-oriented reason. They never fill defaults.
RLMarketSchema = {}
local S = RLMarketSchema
S.VERSION = 1
S.CHANNEL_DIRECTIONS = {
    DEALER_BUY = "OUT", DEALER_SELL = "IN",
    BROKER_PICKUP = "IN", BROKER_DELIVERY = "IN",
}

local function text(v) return type(v) == "string" and v:match("%S") ~= nil end
local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function nonnegative(v) return finite(v) and v >= 0 end
local function version(v) return (text(v) or (finite(v) and v >= 0 and v % 1 == 0)) end
local function fail(field) return false, "INVALID_" .. field end
local function header(v)
    if type(v) ~= "table" then return fail("TABLE") end
    if getmetatable(v) ~= nil then return fail("WIRE_VALUE") end
    if v.schemaVersion ~= S.VERSION then return false, "UNSUPPORTED_SCHEMA_VERSION" end
    return true
end

-- Reject non-finite numbers anywhere in extension data too; cycles are not wire data.
local function wire(v, active)
    local kind = type(v)
    if kind == "number" then return finite(v) end
    if kind ~= "table" then return kind == "nil" or kind == "string" or kind == "boolean" end
    if getmetatable(v) ~= nil then return false end
    if active[v] then return false end
    active[v] = true
    for k, item in pairs(v) do
        if (type(k) ~= "string" and not finite(k)) or not wire(item, active) then
            active[v] = nil
            return false
        end
    end
    active[v] = nil
    return true
end
local function checkedHeader(v)
    local ok, reason = header(v)
    if not ok then return ok, reason end
    if not wire(v, {}) then return fail("WIRE_VALUE") end
    return true
end
local function strings(v, fields)
    for _, key in ipairs(fields) do if not text(v[key]) then return fail(key) end end
    return true
end
local function booleanMap(v)
    if type(v) ~= "table" then return false end
    for key, value in pairs(v) do if not text(key) or type(value) ~= "boolean" then return false end end
    return true
end

function S.validateSnapshot(v)
    local ok, reason = checkedHeader(v)
    if not ok then return ok, reason end
    ok, reason = strings(v, {"identityKey", "stateRevision", "animalType", "speciesKey", "breed",
        "subTypeName", "productionClass", "classRevision", "traitMappingRevision", "gender"})
    if not ok then return ok, reason end
    if v.gender ~= "male" and v.gender ~= "female" then return fail("gender") end
    if not nonnegative(v.ageMonths) then return fail("ageMonths") end
    if not booleanMap(v.traitCapabilities) then return fail("traitCapabilities") end
    if type(v.supportedBreedingRoles) ~= "table" then return fail("supportedBreedingRoles") end
    local seen = {}
    for k, role in pairs(v.supportedBreedingRoles) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > #v.supportedBreedingRoles
            or (role ~= "DAIRY" and role ~= "TERMINAL" and role ~= "MATERNAL") or seen[role] then
            return fail("supportedBreedingRoles")
        end
        seen[role] = true
    end
    -- Optional measurements stay absent when adapters lack the corresponding capability.
    for _, key in ipairs({"weightKg", "targetWeightKg", "health"}) do
        if v[key] ~= nil and not nonnegative(v[key]) then return fail(key) end
    end
    if v.castrated ~= nil and type(v.castrated) ~= "boolean" then return fail("castrated") end
    if v.genes ~= nil then
        if type(v.genes) ~= "table" then return fail("genes") end
        for _, value in pairs(v.genes) do if not nonnegative(value) then return fail("genes") end end
    end
    if v.reproductive ~= nil then
        if type(v.reproductive) ~= "table" then return fail("reproductive") end
        for _, key in ipairs({"pregnant", "lactating"}) do
            if v.reproductive[key] ~= nil and type(v.reproductive[key]) ~= "boolean" then return fail("reproductive." .. key) end
        end
        local parity = v.reproductive.parity
        if parity ~= nil and (not nonnegative(parity) or parity % 1 ~= 0) then return fail("reproductive.parity") end
    end
    if v.production ~= nil then
        local p = v.production
        if type(p) ~= "table" then return fail("production") end
        if p.stage ~= nil and not text(p.stage) then return fail("production.stage") end
        if p.slaughterReferenceKg ~= nil and not nonnegative(p.slaughterReferenceKg) then return fail("production.slaughterReferenceKg") end
        if p.finishScore ~= nil and (not finite(p.finishScore) or p.finishScore < 0 or p.finishScore > 100) then return fail("production.finishScore") end
        if p.bcs ~= nil and (not finite(p.bcs) or p.bcs < 1 or p.bcs > 5) then return fail("production.bcs") end
        -- Fat-class vocabularies belong to species adapters, not a hard-coded cattle enum.
        if p.fatClass ~= nil and not text(p.fatClass) then return fail("production.fatClass") end
    end
    if v.eligibility ~= nil and not booleanMap(v.eligibility) then return fail("eligibility") end
    return true
end

function S.validateValueBreakdown(v)
    local ok, reason = checkedHeader(v)
    if not ok then return ok, reason end
    if not text(v.providerId) then return fail("providerId") end
    if not version(v.providerVersion) then return fail("providerVersion") end
    local c = v.capabilities
    if not booleanMap(c) then return fail("capabilities") end
    for _, key in ipairs({"commodity", "breeding", "slaughter"}) do
        if type(c[key]) ~= "boolean" then return fail("capabilities." .. key) end
    end
    if (c.commodity and not nonnegative(v.commodityValue)) or (not c.commodity and v.commodityValue ~= nil) then return fail("commodityValue") end
    if c.production == true then
        if not nonnegative(v.productionReference) then return fail("productionReference") end
    elseif v.productionReference ~= nil then return fail("productionReference") end
    local slaughter = v.slaughter
    if type(slaughter) ~= "table" or slaughter.available ~= c.slaughter then return fail("slaughter.available") end
    for _, key in ipairs({"net", "meatKg", "gross", "fees"}) do
        if c.slaughter then
            if (key == "net" and not finite(slaughter[key])) or (key ~= "net" and not nonnegative(slaughter[key])) then return fail("slaughter." .. key) end
        elseif slaughter[key] ~= nil then return fail("slaughter." .. key) end
    end
    if type(slaughter.basis) ~= "table" then return fail("slaughter.basis") end
    if type(v.breeding) ~= "table" or type(v.breeding.byObjective) ~= "table" then return fail("breeding.byObjective") end
    for objective, result in pairs(v.breeding.byObjective) do
        if not c.breeding or (objective ~= "DAIRY" and objective ~= "TERMINAL" and objective ~= "MATERNAL") or type(result) ~= "table" then return fail("breeding.byObjective") end
        for _, key in ipairs({"selectionIndex", "valuationScore", "referenceValue", "ownDelta", "hereditaryDelta"}) do
            if not finite(result[key]) then return fail("breeding." .. key) end
        end
        if result.referenceValue < 0 or type(result.eligible) ~= "boolean" or type(result.reasons) ~= "table" then return fail("breeding.result") end
    end
    if c.breeding and next(v.breeding.byObjective) == nil then return fail("breeding.byObjective") end
    if v.legacy ~= nil then
        if type(v.legacy) ~= "table" or not nonnegative(v.legacy.bid) or not nonnegative(v.legacy.ask) then return fail("legacy") end
    end
    return true
end

local revisions = {"classRevision", "traitMappingRevision", "marketEpoch", "configRevision", "formulaVersion", "priceRevision"}
function S.validateQuoteContext(v)
    local ok, reason = checkedHeader(v)
    if not ok then return ok, reason end
    for _, key in ipairs(revisions) do if not version(v[key]) then return fail(key) end end
    if not S.CHANNEL_DIRECTIONS[v.channel] then return fail("channel") end
    if not finite(v.difficultyMultiplier) or v.difficultyMultiplier <= 0 then return fail("difficultyMultiplier") end
    if not finite(v.calendarMonth) or v.calendarMonth % 1 ~= 0 or v.calendarMonth < 1 or v.calendarMonth > 12 then return fail("calendarMonth") end
    if not nonnegative(v.absoluteMonths) then return fail("absoluteMonths") end
    if v.breedingObjective ~= nil and v.breedingObjective ~= "DAIRY" and v.breedingObjective ~= "TERMINAL" and v.breedingObjective ~= "MATERNAL" then return fail("breedingObjective") end
    if v.allowedProductionClasses ~= nil then
        if type(v.allowedProductionClasses) ~= "table" then return fail("allowedProductionClasses") end
        for key, class in pairs(v.allowedProductionClasses) do
            if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #v.allowedProductionClasses or not text(class) then return fail("allowedProductionClasses") end
        end
    end
    return true
end

-- fees/bonuses are explicit nonnegative totals here; immutable itemized MoneyBreakdown
-- and arithmetic/quantization consistency belong to U03, not this shape validator.
-- Optional expected = {side = "BID"/"ASK", identityKey = ..., stateRevision = ...}
-- binds an envelope to the caller's request; it does not prove authority or freshness.
function S.validateQuote(v, expected)
    local ok, reason = checkedHeader(v)
    if not ok then return ok, reason end
    if v.status ~= "OK" and v.status ~= "REJECTED" and v.status ~= "UNSUPPORTED" and v.status ~= "UNAVAILABLE" then return fail("status") end
    local direction = S.CHANNEL_DIRECTIONS[v.channel]
    if direction == nil or v.settlementDirection ~= direction then return fail("settlementDirection") end
    if expected ~= nil then
        if type(expected) ~= "table" or not wire(expected, {}) then return fail("expected") end
        if expected.side ~= nil then
            if expected.side ~= "BID" and expected.side ~= "ASK" then return fail("expected.side") end
            if (expected.side == "ASK" and direction ~= "OUT") or (expected.side == "BID" and direction ~= "IN") then return fail("expected.side") end
        end
        for _, key in ipairs({"identityKey", "stateRevision"}) do
            if expected[key] ~= nil and expected[key] ~= v[key] then return fail("expected." .. key) end
        end
    end
    ok, reason = strings(v, {"identityKey", "stateRevision", "eligibilityFingerprint", "settlementFingerprint"})
    if not ok then return ok, reason end
    for _, key in ipairs(revisions) do if not version(v[key]) then return fail(key) end end
    if not nonnegative(v.expiresAt) then return fail("expiresAt") end
    if type(v.candidatePaths) ~= "table" or type(v.reasons) ~= "table" then return fail("pathsOrReasons") end
    if v.status == "OK" then
        if not finite(v.bodyAmount) or v.bodyAmount <= 0 then return fail("bodyAmount") end
        if not nonnegative(v.fees) or not nonnegative(v.bonuses) or not finite(v.netToPlayer) then return fail("amounts") end
        if not text(v.selectedUse) then return fail("selectedUse") end
        if direction == "OUT" and v.netToPlayer > 0 then return fail("netToPlayer") end
    else
        -- Rejected quotes carry explanations, never a settlement-shaped zero fallback.
        if v.bodyAmount ~= nil or v.netToPlayer ~= nil or v.fees ~= nil or v.bonuses ~= nil then return fail("rejectedAmounts") end
        if next(v.reasons) == nil then return fail("reasons") end
    end
    return true
end
