--[[
    RLRearingPolicy.lua
    What an animal is kept for, which genes it really has and how its young are raised: the one
    answer the genetics, displays, values, nursing and milk code read. Pure on its inputs apart
    from the breed traits config (RLBreedTraits) and the animal system's type names.

    Production use, by species and breed (never by sex or by whether it gives milk now):
        BEEF        cattle of a breed with productionUse="BEEF" (breedTraits.xml). A copy of the
                    file from before productionUse: a breed that sets sucklingMonths or
                    milkCollect="0" (the eleven suckler breeds).
        DAIRY       any other cattle (dairy, dual purpose, the water buffalo).
        DAIRY_GOAT  SHEEP subtypes of the GOAT breed.
        MEAT_SHEEP  every other sheep.
        PIG         pigs.
        nil         anything else (horses, poultry, a map's own types): not covered here, kept
                    as it was.

    Genes. BEEF cattle have no milk yield gene: their genetics hold metabolism, quality,
    fertility and health, and genetics.productivity is nil - never 1, never hidden. A BEEF bull
    is the same: there is no milk to pass on. DAIRY and DAIRY_GOAT animals (bulls and bucks too:
    they pass it on) keep it; sheep keep theirs (wool), poultry theirs (eggs); pigs and horses
    never had one and get none. RLRearingPolicy.normalizeGenetics drops what an animal does not
    have, keeping every other value exactly.

    Rearing mode:
        NUTRITION_COVERAGE  BEEF, MEAT_SHEEP, PIG: a dam pays the nutrition her young at foot need
                            (RLYoungDemandMath), they share whatever share of it she could pay; no
                            saleable milk.
        DAIRY_MILK          DAIRY, DAIRY_GOAT: genes x lactation give her potential, her budget
                            what she actually gives; her young drink first and the rest is
                            collected.
]]

RLRearingPolicy = {}

RLRearingPolicy.USE = { BEEF = "BEEF", DAIRY = "DAIRY", DAIRY_GOAT = "DAIRY_GOAT", MEAT_SHEEP = "MEAT_SHEEP", PIG = "PIG" }
RLRearingPolicy.MODE = { NUTRITION_COVERAGE = "NUTRITION_COVERAGE", DAIRY_MILK = "DAIRY_MILK" }

local VALID_USE = {}
for _, use in pairs(RLRearingPolicy.USE) do VALID_USE[use] = true end

local MODE_OF = {
    BEEF = "NUTRITION_COVERAGE", MEAT_SHEEP = "NUTRITION_COVERAGE", PIG = "NUTRITION_COVERAGE",
    DAIRY = "DAIRY_MILK", DAIRY_GOAT = "DAIRY_MILK",
}

--- Every gene key an animal can have, in the order RLGenetics walks them.
RLRearingPolicy.ALL_TRAITS = { "metabolism", "quality", "health", "fertility", "productivity" }

--- Animal types whose animals have a productivity gene (what it means is the species': milk, wool,
--- eggs); a use may still take it away (BEEF).
RLRearingPolicy.PRODUCTIVITY_TYPES = { COW = true, SHEEP = true, CHICKEN = true }

local Log = RmLogging ~= nil and RmLogging.getLogger("RLRM") or nil


local function typeNameOf(subType)
    if subType == nil then return nil end
    if subType.typeName ~= nil then return subType.typeName:upper() end
    local name = RLBreedTraits ~= nil and RLBreedTraits.getTypeName(subType) or nil
    return name ~= nil and name:upper() or nil
end


--- A subtype by its index, or nil.
local function subTypeByIndex(index)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if index == nil or animalSystem == nil or animalSystem.getSubTypeByIndex == nil then return nil end
    return animalSystem:getSubTypeByIndex(index)
end


--- A breed's production use by names (the dealer and a sire snapshot know a breed before or
--- without a subtype).
--- @param typeName string|nil COW, SHEEP, PIG, ...
--- @param breed string|nil
--- @param subTypeName string|nil
--- @return string|nil use
function RLRearingPolicy.getUseNamed(typeName, breed, subTypeName)
    if typeName == nil then return nil end
    typeName = typeName:upper()
    breed = breed ~= nil and breed:upper() or nil
    subTypeName = subTypeName ~= nil and subTypeName:upper() or nil
    local explicit = RLBreedTraits ~= nil and RLBreedTraits.getStringNamed ~= nil
        and RLBreedTraits.getStringNamed(typeName, breed, subTypeName, "productionUse") or nil
    if explicit ~= nil and VALID_USE[explicit] then return explicit end
    if typeName == "COW" then
        if RLBreedTraits ~= nil and RLBreedTraits.getNamed ~= nil then
            local suckling = RLBreedTraits.getNamed(typeName, breed, subTypeName, "sucklingMonths", 0)
            local collect = RLBreedTraits.getNamed(typeName, breed, subTypeName, "milkCollect", 1)
            if (suckling or 0) > 0 or (collect ~= nil and collect <= 0) then return "BEEF" end
        end
        return "DAIRY"
    end
    if typeName == "SHEEP" then
        if breed == "GOAT" or subTypeName == "GOAT" or subTypeName == "RAM_GOAT" then return "DAIRY_GOAT" end
        return "MEAT_SHEEP"
    end
    if typeName == "PIG" then return "PIG" end
    return nil
end


--- A subtype's production use (see the header), nil for a type this does not cover.
--- @param subType table|nil
--- @return string|nil
function RLRearingPolicy.getUse(subType)
    if subType == nil then return nil end
    return RLRearingPolicy.getUseNamed(typeNameOf(subType), subType.breed, subType.name)
end


--- The use of an animal (its subtype), or of a subtype index.
function RLRearingPolicy.getAnimalUse(animal)
    if animal == nil then return nil end
    local subType = animal.getSubType ~= nil and animal:getSubType() or subTypeByIndex(animal.subTypeIndex)
    return RLRearingPolicy.getUse(subType)
end


function RLRearingPolicy.getUseByIndex(subTypeIndex)
    return RLRearingPolicy.getUse(subTypeByIndex(subTypeIndex))
end


--- Whether a subtype is beef cattle.
function RLRearingPolicy.isBeef(subType)
    return RLRearingPolicy.getUse(subType) == "BEEF"
end


--- How a subtype's young are raised: NUTRITION_COVERAGE, DAIRY_MILK or nil (not covered).
function RLRearingPolicy.getRearingMode(subType)
    local use = RLRearingPolicy.getUse(subType)
    return use ~= nil and MODE_OF[use] or nil
end


--- Whether a subtype's females give saleable milk after giving birth (DAIRY, DAIRY_GOAT).
function RLRearingPolicy.collectsMilk(subType)
    local use = RLRearingPolicy.getUse(subType)
    return use == "DAIRY" or use == "DAIRY_GOAT"
end


--- Whether animals of a type and use have a gene, by names (see the header).
--- @return boolean
function RLRearingPolicy.hasTraitNamed(typeName, use, key)
    if key ~= "productivity" then return true end
    if typeName == nil then return false end
    if not RLRearingPolicy.PRODUCTIVITY_TYPES[typeName:upper()] then return false end
    return use ~= "BEEF"
end


--- Whether a subtype's animals have the gene `key` (metabolism, quality, health, fertility,
--- productivity). Display, filters, values and inheritance all ask this.
--- @param subType table|nil
--- @param key string
--- @return boolean
function RLRearingPolicy.hasTrait(subType, key)
    if key ~= "productivity" then return true end
    return RLRearingPolicy.hasTraitNamed(typeNameOf(subType), RLRearingPolicy.getUse(subType), key)
end


--- The gene keys a subtype's animals have, in RLGenetics' order.
--- @return table keys
function RLRearingPolicy.getActiveTraitKeys(subType)
    local keys = {}
    for _, key in ipairs(RLRearingPolicy.ALL_TRAITS) do
        if RLRearingPolicy.hasTrait(subType, key) then keys[#keys + 1] = key end
    end
    return keys
end


--- Drop the genes a subtype's animals do not have from a genetics table, in place; every other
--- value is kept exactly (nothing is drawn again, raised or lowered). Only a use that takes a
--- gene away removes it (BEEF: productivity): a type this does not cover is left alone.
--- @param subType table|nil
--- @param genetics table|nil
--- @return table|nil genetics
--- @return boolean removed whether a value was dropped
function RLRearingPolicy.normalizeGenetics(subType, genetics)
    if type(genetics) ~= "table" or subType == nil then return genetics, false end
    if genetics.productivity ~= nil and RLRearingPolicy.getUse(subType) == "BEEF" then
        genetics.productivity = nil
        return genetics, true
    end
    return genetics, false
end


--- The same for a sire snapshot or a straw that knows only its breed (impregnatedBy.breed): a
--- BEEF cattle breed drops productivity; an unknown breed is left as it is (never taken for beef).
--- @param typeName string|nil
--- @param breed string|nil
--- @param genetics table|nil
--- @return table|nil genetics
--- @return boolean removed
function RLRearingPolicy.normalizeNamed(typeName, breed, genetics)
    if type(genetics) ~= "table" or breed == nil or typeName == nil then return genetics, false end
    if genetics.productivity ~= nil and RLRearingPolicy.getUseNamed(typeName, breed, nil) == "BEEF" then
        genetics.productivity = nil
        return genetics, true
    end
    return genetics, false
end


--- Normalise by a subtype index (a straw's sire, a fetus); unknown index: unchanged.
function RLRearingPolicy.normalizeByIndex(subTypeIndex, genetics)
    local subType = subTypeByIndex(subTypeIndex)
    if subType == nil then return genetics, false end
    return RLRearingPolicy.normalizeGenetics(subType, genetics)
end


local migrated = 0

--- Count (and log the first few of) the beef milk genes a load dropped: one line per load path
--- kind, so an old save's migration is visible once without flooding the log.
--- @param what string What carried it ("animal", "sire", "fetus", "straw", ...)
--- @param id any
function RLRearingPolicy.noteMigrated(what, id)
    migrated = migrated + 1
    if Log ~= nil and migrated <= 5 then
        Log:info("RLRearingPolicy: dropped the milk gene of beef %s %s (beef cattle have none; other genes unchanged)%s",
            tostring(what), tostring(id), migrated == 5 and " - further ones are not logged" or "")
    end
end


function RLRearingPolicy.getMigratedCount()
    return migrated
end


--- The productivity of a young animal of a subtype that has the gene, from its parents' values
--- (BreedingMath.breedOffspring). A parent without the gene (a beef sire on a dairy cow) is never
--- given one: the other parent's value stands for both. With neither, nil (the caller draws one
--- as for a new animal). A subtype without the gene: nil.
--- @param childSubType table|nil
--- @param mother number|nil
--- @param father number|nil
--- @param breed function(mother, father) -> number
--- @return number|nil
function RLRearingPolicy.inheritProductivity(childSubType, mother, father, breed)
    if not RLRearingPolicy.hasTrait(childSubType, "productivity") then return nil end
    if mother == nil and father == nil then return nil end
    return breed(mother or father, father or mother)
end
