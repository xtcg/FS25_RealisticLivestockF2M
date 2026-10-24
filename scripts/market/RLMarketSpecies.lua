-- Market taxonomy is independent of the nutrition classifier. Read the dealer's
-- existing use policy without constructing or enabling any dealer runtime.
RLMarketSpecies = {}
local CLASSES = { dairy = "DAIRY", beef = "BEEF", dual = "DUAL" }
local BASE = {
    PIG = { LANDRACE = "BEEF", BLACK_PIED = "BEEF", BERKSHIRE = "BEEF" },
    SHEEP = { LANDRACE = "BEEF", STEINSCHAF = "BEEF", SWISS_MOUNTAIN = "BEEF", BLACK_WELSH = "BEEF" },
    GOAT = { GOAT = "BEEF" },
}
function RLMarketSpecies.resolve(subType, typeName, options)
    options = options or {}
    if type(subType) ~= "table" or type(subType.name) ~= "string" or type(subType.breed) ~= "string" then
        return nil, "UNRESOLVED_SUBTYPE"
    end
    local species = typeName
    if typeName == "SHEEP" and subType.breed == "GOAT" then species = "GOAT" end
    if species ~= "COW" and species ~= "PIG" and species ~= "SHEEP" and species ~= "GOAT" then
        return nil, "UNSUPPORTED_SPECIES:" .. tostring(species)
    end
    local config = options.dealerConfig
    if config == nil and RLDealerStockPolicy ~= nil then config = RLDealerStockPolicy.getConfig() end
    local entry = config ~= nil and RLDealerStockPolicy ~= nil
        and RLDealerStockPolicy.getEntry(config, subType, typeName) or nil
    local class = entry ~= nil and CLASSES[entry.use] or nil
    local source = class ~= nil and "DEALER_USE" or nil
    local supplemental = options.supplemental and options.supplemental[species]
    supplemental = supplemental and supplemental[subType.breed]
    if class == nil and supplemental ~= nil then
        class = supplemental.productionClass
        source = "MARKET_SUPPLEMENT"
    end
    if class == nil then class = BASE[species] and BASE[species][subType.breed]; source = "MARKET_BASE" end
    if class ~= "BEEF" and class ~= "DAIRY" and class ~= "DUAL" then return nil, "UNCONFIGURED_PRODUCTION_CLASS" end
    return { animalType = typeName, speciesKey = species, breed = subType.breed,
        breedId = species .. ":" .. subType.breed, subTypeName = subType.name,
        productionClass = class, classificationSource = source,
        classRevision = options.classRevision, traitMappingRevision = options.traitMappingRevision }
end
