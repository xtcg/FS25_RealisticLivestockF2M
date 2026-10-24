-- Pure provider dispatch. Only detached protocol data crosses this boundary: never
-- pass a live Animal or call getSellPrice from a provider (that would recurse once
-- the engine price hook is migrated). No providers are registered at module load.
RLAnimalValueProvider = {}
local Registry = {}
Registry.__index = Registry
local OBJECTIVES = { COMMODITY = true, DAIRY = true, TERMINAL = true, MATERNAL = true }

-- Reject executable/metatable-backed/cyclic data, rather than handing game objects
-- to a supposedly read-only calculation. Copies also isolate provider mutations.
function RLAnimalValueProvider.copyData(value, seen)
    local kind = type(value)
    if kind == "nil" or kind == "string" or kind == "boolean" then return value end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then error("NON_FINITE_DATA") end
        return value
    end
    if kind ~= "table" or getmetatable(value) ~= nil then error("NON_DATA_INPUT") end
    seen = seen or {}
    if seen[value] then error("CYCLIC_DATA") end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        if type(key) ~= "string" and type(key) ~= "number" then error("NON_DATA_KEY") end
        result[key] = RLAnimalValueProvider.copyData(item, seen)
    end
    seen[value] = nil
    return result
end

function RLAnimalValueProvider.new()
    return setmetatable({ providers = {}, evaluating = false }, Registry)
end

-- Explicit species + objective keys: SHEEP never implicitly means GOAT; a missing
-- breeding target never falls through to commodity or a cattle implementation.
function Registry:register(speciesKey, objective, provider)
    if type(speciesKey) ~= "string" or speciesKey == "" or not OBJECTIVES[objective] then
        return false, "INVALID_SCOPE"
    end
    if type(provider) ~= "table" or type(provider.id) ~= "string" or provider.id == ""
        or type(provider.version) ~= "number" or provider.version < 1 or provider.version % 1 ~= 0
        or provider.version == math.huge then return false, "INVALID_PROVIDER" end
    for _, name in ipairs({ "supports", "evaluate", "breedingEligibility", "holdingCost" }) do
        if type(provider[name]) ~= "function" then return false, "INVALID_PROVIDER_" .. name end
    end
    local byObjective = self.providers[speciesKey]
    if byObjective ~= nil and byObjective[objective] ~= nil then return false, "DUPLICATE_SCOPE" end
    byObjective = byObjective or {}
    -- Capture the contract, so later edits to the registration table do not change it.
    byObjective[objective] = { id = provider.id, version = provider.version,
        supports = provider.supports, evaluate = provider.evaluate,
        breedingEligibility = provider.breedingEligibility, holdingCost = provider.holdingCost }
    self.providers[speciesKey] = byObjective
    return true
end

function Registry:evaluate(snapshot, context)
    if self.evaluating then return nil, "RECURSIVE_PROVIDER" end
    local valid, reason = RLMarketSchema.validateSnapshot(snapshot)
    if not valid then return nil, reason end
    valid, reason = RLMarketSchema.validateQuoteContext(context)
    if not valid then return nil, reason end
    if snapshot.classRevision ~= context.classRevision
        or snapshot.traitMappingRevision ~= context.traitMappingRevision then
        return nil, "SNAPSHOT_VERSION_MISMATCH"
    end
    local objective = context.breedingObjective or "COMMODITY"
    local entries = self.providers[snapshot.speciesKey]
    local provider = entries ~= nil and entries[objective] or nil
    if provider == nil then return nil, "UNSUPPORTED" end
    self.evaluating = true
    local ok, result, failure = pcall(function()
        local input = RLAnimalValueProvider.copyData(snapshot)
        local ctx = RLAnimalValueProvider.copyData(context)
        local supported, why = provider.supports(input, ctx)
        if supported ~= true then return nil, why or "UNSUPPORTED" end
        -- supports and evaluate each get a fresh view of the caller's input.
        local value = provider.evaluate(RLAnimalValueProvider.copyData(snapshot),
            RLAnimalValueProvider.copyData(context))
        local accepted, invalid = RLMarketSchema.validateValueBreakdown(value)
        if not accepted then return nil, invalid end
        if value.providerId ~= provider.id or value.providerVersion ~= provider.version then
            return nil, "PROVIDER_VERSION_MISMATCH"
        end
        return RLAnimalValueProvider.copyData(value)
    end)
    self.evaluating = false
    if not ok then return nil, "PROVIDER_ERROR" end
    return result, failure
end
