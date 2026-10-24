-- Explicit capability registration. Loading this file enables no economic route.
RLMarketProviders = {}
local function refsFor(snapshot, context)
    local r = context.referenceInputs
    if type(r) ~= "table" or r.currencyBasis ~= "HARD" then return nil, "MISSING_REFERENCE_INPUTS" end
    for _, key in ipairs({ "identityKey", "stateRevision", "classRevision", "traitMappingRevision" }) do
        if r[key] ~= snapshot[key] then return nil, "REFERENCE_SCOPE_MISMATCH" end
    end
    if type(context.referenceRevision) ~= "string" or r.referenceRevision ~= context.referenceRevision
        or r.priceRevision ~= context.priceRevision or r.configRevision ~= context.configRevision then return nil, "REFERENCE_VERSION_MISMATCH" end
    return r
end
local function result(snapshot, context, species, objective, id, selectionWeights)
    local refs, why = refsFor(snapshot, context)
    if not refs then return nil, why end
    local commodity, unavailable = RLMarketCommodityValue.evaluate(snapshot, refs.commodity)
    local production
    if objective ~= "COMMODITY" then
        local member=RLSpeciesCatalog.get(species)
        production, why = _G[member.marketModel].evaluate(snapshot, objective, refs.production)
        if not production then return nil, why end
    elseif not commodity then return nil, unavailable end
    if production then
        local weights = selectionWeights(species, objective, refs.production)
        if type(weights)~="table" then return nil,"SELECTION_INDEX_UNAVAILABLE" end
        for gene,weight in pairs(weights) do
            if weight~=0 and snapshot.traitCapabilities["gene_"..gene]~=true then return nil,"SELECTION_TRAIT_UNAVAILABLE:"..gene end
        end
        local index,why=RLMarketCommodityValue.score(snapshot.genes,weights)
        if index==nil then return nil,why end
        production.selectionIndex=index
        local p = refs.production.params
        if snapshot.ageMonths < p.minBreedingAge then
            production.eligible, production.reasons = false, { "NOT_BREEDING_AGE" }
        elseif not RLMarketCommodityValue.nonnegative(p.breedingWeightRatio) or snapshot.weightKg == nil or snapshot.targetWeightKg == nil then
            production.eligible, production.reasons = false, { "MISSING_BREEDING_WEIGHT" }
        elseif snapshot.weightKg < p.breedingWeightRatio * snapshot.targetWeightKg then
            production.eligible, production.reasons = false, { "TOO_LIGHT" }
        end
    end
    local slaughter = refs.commodity and refs.commodity.slaughter
    local value = { schemaVersion = 1, providerId = id, providerVersion = 1,
        capabilities = { commodity = commodity ~= nil, breeding = production ~= nil,
            production = production ~= nil, slaughter = slaughter ~= nil and slaughter.available == true },
        slaughter = slaughter ~= nil and assert(RLMarketData.copy(slaughter)) or { available = false, basis = {} },
        breeding = { byObjective = {} } }
    if commodity then value.commodityValue = commodity.referenceValue end
    if production then
        value.productionReference = production.referenceValue
        value.breeding.byObjective[objective] = production
    end
    return value
end
function RLMarketProviders.register(registry, options)
    options=options or {}
    local selectWeights=options.selectionWeights or function(species,objective,input)
        local member=RLSpeciesCatalog.get(species)
        local prefix=member and member.indexPrefix
        if prefix then
            return RLBrokerConditionPackage and RLBrokerConditionPackage.indexWeights(prefix.."."..objective:lower()) or nil
        end
        -- No cattle/sheep selection profile is borrowed for pigs.
        return input.selectionWeights and input.selectionWeights[objective]
    end
    for _, member in ipairs(RLSpeciesCatalog.marketMembers()) do
        local species=member.key
        for _, objective in ipairs({ "COMMODITY", "DAIRY", "TERMINAL", "MATERNAL" }) do
            local id = "market.reference." .. species .. "." .. objective
            local function compute(s, c) return result(s, c, species, objective, id, selectWeights) end
            local provider = { id = id, version = 1,
                supports = function(s, c) local value, why = compute(s, c); return value ~= nil, why end,
                evaluate = compute,
                breedingEligibility = function(s, c)
                    local value, why = compute(s, c)
                    local route = value and value.breeding.byObjective[objective]
                    return { eligible = route ~= nil and route.eligible, reasons = route and route.reasons or (why and { why } or {}) }
                end,
                holdingCost = function() return nil, "HOLDING_COST_PROVIDER_REQUIRED" end }
            local ok, why = registry:register(species, objective, provider)
            if not ok then return nil, why end
        end
    end
    return true
end
