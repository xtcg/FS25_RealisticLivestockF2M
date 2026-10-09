--[[
    RLDealerStockPolicy.lua
    What the animal dealer may sell, from xml/dealerStock.xml: each animal is generated for a
    purpose (weaned calf, store bull, heifer ready to breed...) from a source that supplies it
    (dairy herd, rearing unit...), at an age, sex, birth history, milk and health that purpose
    allows. Good genetics are no exemption.

    Pure: every function takes its subtype, entry and context as arguments and draws only through
    the `randomFn(lo, hi) -> int` it is given, so it runs outside the game. Only getConfig touches
    the file system (through RLBreedTraits.loadConfig).

    Ages are whole months. A purpose's window is half-open [lo, hi); the integer segments the
    generator draws from are inclusive [a, b].
]]

RLDealerStockPolicy = {}

local Log = RmLogging.getLogger("RLRM")

RLDealerStockPolicy.CONFIG_FILE = "dealerStock.xml"

--- Weight model every dealer animal is on until the v2 weight factory serves the dealer.
RLDealerStockPolicy.WEIGHT_MODEL = "LEGACY_WEIGHT"

--- Coverage of a subtype.
RLDealerStockPolicy.COVERED = "COVERED"          -- sold by purpose
RLDealerStockPolicy.LEGACY = "LEGACY"            -- marked legacy="true": old dealer rules
RLDealerStockPolicy.NOT_COVERED = "NOT_COVERED"  -- no profile for it: old dealer rules

--- Why a purpose cannot be offered, or a listing no longer qualifies.
RLDealerStockPolicy.REASON = {
    DISABLED = "DISABLED",                      -- purpose enabled="false"
    NO_BREEDING_WEIGHT = "NO_BREEDING_WEIGHT",  -- breedingWeight purpose, breed has no ratio
    NO_REPRODUCTION = "NO_REPRODUCTION",        -- needs a birth or pregnancy; subtype cannot reproduce
    NO_AGE = "NO_AGE",                          -- window empty after caps, breeding and weaning ages
    NOT_BUYABLE = "NOT_BUYABLE",                -- no age left whose visual can be bought
    NO_TIMELINE = "NO_TIMELINE",                -- no birth / pregnancy history fits the age
    NO_SOURCE = "NO_SOURCE",                    -- no source supplies the purpose for this breed and sex
    NO_PURPOSE = "NO_PURPOSE",                  -- nothing offerable for the subtype and sex
    UNKNOWN_PURPOSE = "UNKNOWN_PURPOSE",        -- listing names a purpose the config lacks
    GENDER = "GENDER",
    AGE = "AGE",                                -- age outside the purpose's ages
    PARENT = "PARENT",                          -- has / has not given birth against the purpose
    PREGNANCY = "PREGNANCY",                    -- pregnant / not pregnant against the purpose
    PREGNANCY_PROGRESS = "PREGNANCY_PROGRESS",  -- gestation not in (0, maxPregnancyProgress]
    TIMELINE = "TIMELINE",                      -- birth or conception earlier than possible
    CASTRATED = "CASTRATED",                    -- breeding male that is castrated
    TOO_LIGHT = "TOO_LIGHT",                    -- under breedingWeightRatio x target weight
    PARITY = "PARITY",                          -- births outside the purpose's, or more than fit its age
    LACTATION = "LACTATION",                    -- milking against its last birth
    HEALTH = "HEALTH",                          -- health under the profile's minHealth
    SICK = "SICK",                              -- shows a disease
    SOURCE = "SOURCE",                          -- its source does not (or no longer) supply it
}

local REASON = RLDealerStockPolicy.REASON

RLDealerStockPolicy.DEFAULTS = {
    version = 2,
    maxAttempts = 8,
    femaleShare = 0.5,
}

--- Months a listing's age, months since birth and gestation may drift apart (see validate).
RLDealerStockPolicy.TIMELINE_SLACK_MONTHS = 1

RLDealerStockPolicy.PROFILE_DEFAULTS = {
    maxPregnancyProgress = 0.75,
    minRecoveryMonth = 3,
    minHealth = 90,
}

--- Source traceability labels and their rank, least first (a label only: no certificate is implied).
RLDealerStockPolicy.TRACEABILITY = { UNKNOWN = 1, PARTIAL = 2, RECORDED = 3 }

--- Breed use a source takes whatever the breed (and the only one a breed without a use matches).
RLDealerStockPolicy.ANY_USE = "any"

--- The one source a profile without any gets (a file from before sources).
RLDealerStockPolicy.DEFAULT_SOURCE = "UNSPECIFIED"

local RULES = { never = true, always = true, optional = true }
local GENDERS = { female = true, male = true, any = true }

--- True with probability p, from an integer draw.
local function chance(randomFn, p)
    return randomFn(1, 1000) <= p * 1000
end


--- One of `items` by `weightOf(item)` (> 0 in total), from one draw; nil when the total is 0.
local function pickWeighted(items, weightOf, randomFn)
    local total = 0
    for _, item in ipairs(items) do total = total + weightOf(item) end
    if total <= 0 then return nil end

    local roll = randomFn(1, 1000000) / 1000000 * total
    local cumulative = 0
    for _, item in ipairs(items) do
        cumulative = cumulative + weightOf(item)
        if roll <= cumulative then return item end
    end
    return items[#items]
end


-- Layer attributes: name -> XML getter.
local LAYER_ATTRIBUTES = {
    profile = "getString",
    legacy = "getBool",
    slowMaturing = "getBool",
    breedingWeightRatio = "getFloat",
    breedingMinAgeMonth = "getFloat",
    femaleShare = "getFloat",
    use = "getString",
}


-- =============================================================================
-- Config
-- =============================================================================

local function readLayer(xmlFile, key)
    local values = {}
    for attr, getter in pairs(LAYER_ATTRIBUTES) do
        local value = xmlFile[getter](xmlFile, key .. "#" .. attr)
        if value ~= nil then
            if attr == "profile" then value = value:upper() end
            if attr == "use" then value = value:lower() end
            values[attr] = value
        end
    end
    return values
end


local function readName(xmlFile, key)
    local value = xmlFile:getString(key .. "#name")
    if value == nil then Log:warning("RLDealerStockPolicy: %s has no name, ignored", key) end
    return value ~= nil and value:upper() or nil
end


--- Read one purpose element; nil (with a warning) when it cannot be used.
local function readPurpose(xmlFile, key, profileName)
    local purpose = {
        id = xmlFile:getString(key .. "#id"),
        gender = (xmlFile:getString(key .. "#gender", "any")):lower(),
        minAge = xmlFile:getInt(key .. "#minAgeMonth"),
        maxAge = xmlFile:getInt(key .. "#maxAgeMonth"),
        weight = xmlFile:getFloat(key .. "#weight", 1),
        enabled = xmlFile:getBool(key .. "#enabled", true),
        parent = (xmlFile:getString(key .. "#parent", "never")):lower(),
        parentChance = xmlFile:getFloat(key .. "#parentChance", 0.5),
        pregnant = (xmlFile:getString(key .. "#pregnant", "never")):lower(),
        pregnancyChance = xmlFile:getFloat(key .. "#pregnancyChance", 0.5),
        breeding = xmlFile:getBool(key .. "#breeding", false),
        breedingWeight = xmlFile:getBool(key .. "#breedingWeight", false),
        weaned = xmlFile:getBool(key .. "#weaned", false),
        minParity = xmlFile:getInt(key .. "#minParity", 1),
        maxParity = xmlFile:getInt(key .. "#maxParity", 1),
    }
    purpose.slowMinAge = xmlFile:getInt(key .. "#slowMinAgeMonth", purpose.minAge)
    purpose.slowMaxAge = xmlFile:getInt(key .. "#slowMaxAgeMonth", purpose.maxAge)

    local problem
    if purpose.id == nil then
        problem = "no id"
    elseif not GENDERS[purpose.gender] then
        problem = "gender must be female, male or any"
    elseif purpose.minAge == nil or purpose.maxAge == nil or purpose.minAge < 0 or purpose.maxAge <= purpose.minAge then
        problem = "needs 0 <= minAgeMonth < maxAgeMonth"
    elseif purpose.slowMinAge < 0 or purpose.slowMaxAge <= purpose.slowMinAge then
        problem = "needs 0 <= slowMinAgeMonth < slowMaxAgeMonth"
    elseif not (purpose.weight >= 0) then
        problem = "weight must be >= 0"
    elseif not RULES[purpose.parent] or not RULES[purpose.pregnant] then
        problem = "parent and pregnant must be never, always or optional"
    elseif not (purpose.parentChance >= 0 and purpose.parentChance <= 1)
        or not (purpose.pregnancyChance >= 0 and purpose.pregnancyChance <= 1) then
        problem = "parentChance and pregnancyChance must be 0..1"
    elseif purpose.minParity < 1 or purpose.maxParity < purpose.minParity then
        problem = "needs 1 <= minParity <= maxParity"
    end

    if problem ~= nil then
        Log:warning("RLDealerStockPolicy: profile %s purpose %s ignored: %s", profileName, tostring(purpose.id), problem)
        return nil
    end

    purpose.id = purpose.id:upper()
    return purpose
end


--- Split a space-separated list.
local function words(text)
    local list = {}
    for word in string.gmatch(text or "", "%S+") do table.insert(list, word) end
    return list
end


--- Read one source element; nil (with a warning) when it cannot be used.
--- @return table|nil source {id, uses{[use]=true}, anyUse, purposes{["ID"|"ID:sex"]=true}|nil (all),
---         purposeList{{id, sex|nil}}|nil, weight, traceability}
local function readSource(xmlFile, key, profileName)
    local id = xmlFile:getString(key .. "#id")
    local weight = xmlFile:getFloat(key .. "#weight", 1)
    local traceability = (xmlFile:getString(key .. "#traceability", "UNKNOWN")):upper()

    local problem
    if id == nil then
        problem = "no id"
    elseif not (weight > 0) then
        problem = "weight must be > 0"
    elseif not RLDealerStockPolicy.TRACEABILITY[traceability] then
        problem = "traceability must be RECORDED, PARTIAL or UNKNOWN"
    end
    if problem ~= nil then
        Log:warning("RLDealerStockPolicy: profile %s source %s ignored: %s", profileName, tostring(id), problem)
        return nil
    end

    local source = { id = id:upper(), uses = {}, weight = weight, traceability = traceability }
    for _, use in ipairs(words(xmlFile:getString(key .. "#uses", RLDealerStockPolicy.ANY_USE))) do
        source.uses[use:lower()] = true
    end
    source.anyUse = source.uses[RLDealerStockPolicy.ANY_USE] == true

    local purposes = words(xmlFile:getString(key .. "#purposes", "*"))
    if not (#purposes == 1 and purposes[1] == "*") then
        source.purposes, source.purposeList = {}, {}
        for _, token in ipairs(purposes) do
            local purposeId, sex = token:match("^([^:]+):?(%a*)$")
            sex = sex ~= nil and sex:lower() or ""
            if purposeId == nil or (sex ~= "" and sex ~= "female" and sex ~= "male") then
                Log:warning("RLDealerStockPolicy: profile %s source %s: purpose %s not understood, ignored",
                    profileName, source.id, token)
            else
                purposeId = purposeId:upper()
                source.purposes[purposeId .. (sex ~= "" and (":" .. sex) or "")] = true
                table.insert(source.purposeList, { id = purposeId, sex = sex ~= "" and sex or nil })
            end
        end
    end
    return source
end


--- Read a dealer stock config.
--- @param xmlFile table|nil An XMLFile with a dealerStock root; nil gives an empty config (every type NOT_COVERED)
--- @return table config {version, maxAttempts, femaleShare, profiles[name] {.., purposes, sources}, layers{types, breeds, subTypes}}
function RLDealerStockPolicy.parseConfig(xmlFile)
    local config = table.clone(RLDealerStockPolicy.DEFAULTS)
    config.profiles = {}
    config.layers = { types = {}, breeds = {}, subTypes = {} }
    if xmlFile == nil then return config end

    local version = xmlFile:getInt("dealerStock#version")
    if version == nil or version < RLDealerStockPolicy.DEFAULTS.version then
        Log:warning("RLDealerStockPolicy: dealerStock.xml is version %s, the mod's is %d; copy the mod's file "
            .. "again to get its newer settings (sources, calving counts, health, weaning ages).",
            tostring(version), RLDealerStockPolicy.DEFAULTS.version)
    end
    config.version = version or config.version
    config.maxAttempts = math.max(1, xmlFile:getInt("dealerStock#maxAttempts", config.maxAttempts))
    config.femaleShare = math.clamp(xmlFile:getFloat("dealerStock#femaleShare", config.femaleShare), 0, 1)

    xmlFile:iterate("dealerStock.profile", function(_, key)
        local name = readName(xmlFile, key)
        if name == nil then return end

        local profile = {
            name = name,
            maxFemaleAge = xmlFile:getInt(key .. "#maxFemaleAgeMonth"),
            maxMaleAge = xmlFile:getInt(key .. "#maxMaleAgeMonth"),
            maxPregnancyProgress = math.clamp(xmlFile:getFloat(key .. "#maxPregnancyProgress",
                RLDealerStockPolicy.PROFILE_DEFAULTS.maxPregnancyProgress), 0, 1),
            minRecoveryMonth = math.max(0, xmlFile:getInt(key .. "#minRecoveryMonth",
                RLDealerStockPolicy.PROFILE_DEFAULTS.minRecoveryMonth)),
            minHealth = math.clamp(xmlFile:getFloat(key .. "#minHealth",
                RLDealerStockPolicy.PROFILE_DEFAULTS.minHealth), 0, 100),
            weaningMonth = xmlFile:getFloat(key .. "#weaningMonth"),
            purposes = {},
            sources = {},
        }
        if profile.maxFemaleAge == nil or profile.maxMaleAge == nil then
            Log:warning("RLDealerStockPolicy: profile %s needs maxFemaleAgeMonth and maxMaleAgeMonth, ignored", name)
            return
        end
        profile.slowMaxFemaleAge = xmlFile:getInt(key .. "#slowMaxFemaleAgeMonth", profile.maxFemaleAge)
        profile.slowMaxMaleAge = xmlFile:getInt(key .. "#slowMaxMaleAgeMonth", profile.maxMaleAge)

        local seen = {}
        xmlFile:iterate(key .. ".purpose", function(_, purposeKey)
            local purpose = readPurpose(xmlFile, purposeKey, name)
            if purpose == nil then return end
            -- One id per sex: "any" claims both.
            local sexes = purpose.gender == "any" and { "female", "male" } or { purpose.gender }
            for _, sex in ipairs(sexes) do
                local seenKey = purpose.id .. ":" .. sex
                if seen[seenKey] then
                    Log:warning("RLDealerStockPolicy: profile %s has purpose %s twice for %s, the later one ignored",
                        name, purpose.id, sex)
                    return
                end
            end
            for _, sex in ipairs(sexes) do seen[purpose.id .. ":" .. sex] = true end
            table.insert(profile.purposes, purpose)
        end)

        local sourceIds = {}
        xmlFile:iterate(key .. ".source", function(_, sourceKey)
            local source = readSource(xmlFile, sourceKey, name)
            if source == nil then return end
            if sourceIds[source.id] then
                Log:warning("RLDealerStockPolicy: profile %s has source %s twice, the later one ignored", name, source.id)
                return
            end
            sourceIds[source.id] = true
            for _, named in ipairs(source.purposeList or {}) do
                if not seen[named.id .. ":female"] and not seen[named.id .. ":male"] then
                    Log:warning("RLDealerStockPolicy: profile %s source %s names purpose %s, which the profile does not have",
                        name, source.id, named.id)
                elseif named.sex ~= nil and not seen[named.id .. ":" .. named.sex] then
                    Log:warning("RLDealerStockPolicy: profile %s source %s names purpose %s for %s, which the profile does not have",
                        name, source.id, named.id, named.sex)
                end
            end
            table.insert(profile.sources, source)
        end)
        if #profile.sources == 0 then
            -- A file from before sources (version 1): one source of unknown history that supplies
            -- every purpose of any breed, so the profile keeps selling as it did.
            table.insert(profile.sources, { id = RLDealerStockPolicy.DEFAULT_SOURCE, uses = { [RLDealerStockPolicy.ANY_USE] = true },
                anyUse = true, weight = 1, traceability = "UNKNOWN" })
            if #profile.purposes > 0 then
                Log:warning("RLDealerStockPolicy: profile %s has no source; its purposes come from one source, %s "
                    .. "(any breed, history unknown), until the file names its sources", name, RLDealerStockPolicy.DEFAULT_SOURCE)
            end
        end

        if config.profiles[name] ~= nil then
            Log:warning("RLDealerStockPolicy: profile %s defined twice, the later one used", name)
        end
        config.profiles[name] = profile
    end)

    xmlFile:iterate("dealerStock.animalType", function(_, typeKey)
        local typeName = readName(xmlFile, typeKey)
        if typeName == nil then return end
        config.layers.types[typeName] = readLayer(xmlFile, typeKey)
        config.layers.breeds[typeName] = config.layers.breeds[typeName] or {}
        xmlFile:iterate(typeKey .. ".breed", function(_, breedKey)
            local breed = readName(xmlFile, breedKey)
            if breed ~= nil then config.layers.breeds[typeName][breed] = readLayer(xmlFile, breedKey) end
        end)
    end)

    xmlFile:iterate("dealerStock.subType", function(_, subTypeKey)
        local subTypeName = readName(xmlFile, subTypeKey)
        if subTypeName ~= nil then config.layers.subTypes[subTypeName] = readLayer(xmlFile, subTypeKey) end
    end)

    return config
end


--- The dealer stock config, loaded on the first call.
--- @return table config See parseConfig
function RLDealerStockPolicy.getConfig()
    if RLDealerStockPolicy.config == nil then
        RLDealerStockPolicy.config = RLBreedTraits.loadConfig(RLDealerStockPolicy.CONFIG_FILE, "dealerStock",
            RLDealerStockPolicy.parseConfig)
    end
    return RLDealerStockPolicy.config
end


-- =============================================================================
-- Entries: what a subtype resolves to
-- =============================================================================

--- Look a layer attribute up: subType, then breed within its type, then type (the lookup
--- breedTraits.xml and calfRearing.xml use).
--- @return any|nil
function RLDealerStockPolicy.lookup(config, typeName, breed, subTypeName, attr)
    return RLBreedTraits.resolveNamed(config.layers, typeName, breed, subTypeName, attr, nil)
end


--- Share of a type's (or breed's) dealer animals that are female.
--- @return number 0..1
function RLDealerStockPolicy.getFemaleShare(config, typeName, breed)
    local share = RLDealerStockPolicy.lookup(config, typeName, breed, nil, "femaleShare")
    return math.clamp(share or config.femaleShare, 0, 1)
end


--- Resolve a subtype against the config.
--- @param config table
--- @param subType table {name, breed, gender, ...}
--- @param typeName string|nil The subtype's animal type name
--- @return table entry {status, typeName, profile, slow, breedingWeightRatio, breedingMinAge, use}
function RLDealerStockPolicy.getEntry(config, subType, typeName)
    local name, breed = subType.name, subType.breed
    local function get(attr) return RLDealerStockPolicy.lookup(config, typeName, breed, name, attr) end

    local entry = {
        typeName = typeName,
        slow = get("slowMaturing") == true,
        breedingWeightRatio = get("breedingWeightRatio"),
        breedingMinAge = get("breedingMinAgeMonth"),
        use = get("use"),
    }

    if get("legacy") == true then
        entry.status = RLDealerStockPolicy.LEGACY
        return entry
    end

    local profileName = get("profile")
    entry.profile = profileName ~= nil and config.profiles[profileName] or nil
    entry.status = entry.profile ~= nil and RLDealerStockPolicy.COVERED or RLDealerStockPolicy.NOT_COVERED
    if profileName ~= nil and entry.profile == nil then entry.missingProfile = profileName end
    return entry
end


--- Purposes of the entry's profile for one sex, in file order.
--- @return table[]
function RLDealerStockPolicy.getPurposes(entry, gender)
    local list = {}
    if entry.profile == nil then return list end
    for _, purpose in ipairs(entry.profile.purposes) do
        if purpose.gender == "any" or purpose.gender == gender then table.insert(list, purpose) end
    end
    return list
end


--- The purpose with this id for this sex, or nil.
function RLDealerStockPolicy.findPurpose(entry, gender, id)
    if id == nil then return nil end
    for _, purpose in ipairs(RLDealerStockPolicy.getPurposes(entry, gender)) do
        if purpose.id == id then return purpose end
    end
    return nil
end


--- Whether a source supplies a purpose for the entry's breed (use) and this sex.
function RLDealerStockPolicy.supplies(source, entry, purpose, gender)
    if not (source.anyUse or (entry.use ~= nil and source.uses[entry.use])) then return false end
    if source.purposes == nil then return true end
    return source.purposes[purpose.id] == true or source.purposes[purpose.id .. ":" .. tostring(gender)] == true
end


--- Whether a breed without a use loses anything: some source of the profile keeps only certain uses.
function RLDealerStockPolicy.isUseMissing(entry)
    if entry.use ~= nil or entry.profile == nil then return false end
    for _, source in ipairs(entry.profile.sources) do
        if not source.anyUse then return true end
    end
    return false
end


--- Whether any source of the entry's profile supplies a purpose for its breed and this sex.
function RLDealerStockPolicy.hasSource(entry, purpose, gender)
    if entry.profile == nil or purpose == nil then return false end
    for _, source in ipairs(entry.profile.sources) do
        if RLDealerStockPolicy.supplies(source, entry, purpose, gender) then return true end
    end
    return false
end


--- The least traceable of some sources (the first of equals): what an old listing, whose history
--- is not known, is labelled with.
--- @param sources table[]
--- @return table|nil source nil for none
function RLDealerStockPolicy.getLeastTraceableSource(sources)
    local best = sources[1]
    if best == nil then return nil end
    for _, source in ipairs(sources) do
        local rank = RLDealerStockPolicy.TRACEABILITY
        if rank[source.traceability] < rank[best.traceability] then best = source end
    end
    return best
end


--- The sources of the entry's profile that supply a purpose for its breed and this sex, in file order.
--- @return table[]
function RLDealerStockPolicy.getSources(entry, purpose, gender)
    local list = {}
    if entry.profile == nil or purpose == nil then return list end
    for _, source in ipairs(entry.profile.sources) do
        if RLDealerStockPolicy.supplies(source, entry, purpose, gender) then table.insert(list, source) end
    end
    return list
end


--- The source with this id in the entry's profile, or nil.
function RLDealerStockPolicy.findSource(entry, id)
    if id == nil or entry.profile == nil then return nil end
    for _, source in ipairs(entry.profile.sources) do
        if source.id == id then return source end
    end
    return nil
end


--- Draw a source by weight; no draw when there is only one.
--- @param sources table[] From getSources, not empty
--- @return table source
function RLDealerStockPolicy.pickSource(sources, randomFn)
    if #sources == 1 then return sources[1] end
    return pickWeighted(sources, function(source) return source.weight end, randomFn)
end


--- Draw a subtype: a breed first, then its sex by femaleShare, then one of its subtypes of that
--- sex. A breed is drawn by the number of sexes it has (a breed with cows and bulls twice as often
--- as one with bulls only, as when every subtype was drawn alike), but several subtypes of one
--- breed and sex, such as map aliases, do not make it more likely. A breed with only one sex
--- gives that sex.
--- @param subTypes table[] {{index, name, breed, gender}, ...}
--- @param typeName string|nil
--- @param randomFn function `function(lo, hi) -> int`
--- @return number|nil index
function RLDealerStockPolicy.pickSubType(config, subTypes, typeName, randomFn)
    local groups, order = {}, {}
    for _, subType in ipairs(subTypes) do
        local key = subType.breed or subType.name or "?"
        local group = groups[key]
        if group == nil then
            group = { female = {}, male = {} }
            groups[key] = group
            table.insert(order, key)
        end
        table.insert(subType.gender == "male" and group.male or group.female, subType.index)
    end
    if #order == 0 then return nil end

    local total = 0
    for _, key in ipairs(order) do
        local group = groups[key]
        group.weight = (#group.female > 0 and 1 or 0) + (#group.male > 0 and 1 or 0)
        total = total + group.weight
    end
    local roll, breed = randomFn(1, total), order[#order]
    for _, key in ipairs(order) do
        roll = roll - groups[key].weight
        if roll <= 0 then breed = key break end
    end
    local group = groups[breed]
    local list
    if #group.male == 0 then
        list = group.female
    elseif #group.female == 0 then
        list = group.male
    else
        list = chance(randomFn, RLDealerStockPolicy.getFemaleShare(config, typeName, breed)) and group.female or group.male
    end
    return list[randomFn(1, #list)]
end


-- =============================================================================
-- Ages
-- =============================================================================

--- Ages at which the subtype can be bought: each buyable visual from its minAge to the month
--- before the next visual, the last up to maxBuyAge. Ascending, merged, inclusive integer segments.
--- @param subType table {visuals = {{minAge, store = {canBeBought}}, ...}}
--- @param maxBuyAge number
--- @return table[] segments {{lo, hi}, ...}
function RLDealerStockPolicy.getBuyableAgeUnion(subType, maxBuyAge)
    local union = {}
    if subType == nil or subType.visuals == nil then return union end
    local n = #subType.visuals
    for i = 1, n do
        local visual = subType.visuals[i]
        if visual.store ~= nil and visual.store.canBeBought then
            local lo = visual.minAge
            local hi = i < n and subType.visuals[i + 1].minAge - 1 or maxBuyAge
            if hi >= lo then
                local last = union[#union]
                if last ~= nil and lo <= last[2] + 1 then
                    last[2] = math.max(last[2], hi)
                else
                    table.insert(union, { lo, hi })
                end
            end
        end
    end
    return union
end


--- Earliest age at which the subtype may be bred: its reproduction age, or the breed's
--- breedingMinAgeMonth when later.
function RLDealerStockPolicy.getBreedingAge(entry, subType)
    return math.max(subType.reproductionMinAgeMonth or 0, entry.breedingMinAge or 0)
end


--- The month in which the young are weaned (weaned from the next): the profile's weaningMonth,
--- else the calf rearing one in ctx.
--- @return number|nil
function RLDealerStockPolicy.getWeaningMonth(entry, ctx)
    if entry.profile ~= nil and entry.profile.weaningMonth ~= nil then return entry.profile.weaningMonth end
    return ctx.weaningMonth
end


--- Absolute age cap (exclusive) for the subtype's sex.
function RLDealerStockPolicy.getCap(entry, gender)
    local profile = entry.profile
    if gender == "male" then return entry.slow and profile.slowMaxMaleAge or profile.maxMaleAge end
    return entry.slow and profile.slowMaxFemaleAge or profile.maxFemaleAge
end


--- A purpose's age window for a subtype, after the absolute cap, maxBuyAge, breeding and weaning
--- ages (not yet the buyable visuals).
--- @param ctx table {maxBuyAge, weaningMonth|nil (calf rearing)}
--- @return number lo
--- @return number hi exclusive; hi <= lo means empty
function RLDealerStockPolicy.getAgeWindow(purpose, entry, subType, ctx)
    local lo = entry.slow and purpose.slowMinAge or purpose.minAge
    local hi = entry.slow and purpose.slowMaxAge or purpose.maxAge
    hi = math.min(hi, RLDealerStockPolicy.getCap(entry, subType.gender), (ctx.maxBuyAge or hi) + 1)
    if purpose.breeding then lo = math.max(lo, math.ceil(RLDealerStockPolicy.getBreedingAge(entry, subType))) end
    local weaningMonth = RLDealerStockPolicy.getWeaningMonth(entry, ctx)
    if purpose.weaned and weaningMonth ~= nil then lo = math.max(lo, math.ceil(weaningMonth + 1)) end
    return lo, hi
end


--- Whether a purpose can ever be offered for the subtype, regardless of age.
--- @return string|nil reason
local function getStaticReason(purpose, entry, subType)
    if not purpose.enabled or purpose.weight <= 0 then return REASON.DISABLED end
    if purpose.breedingWeight and entry.breedingWeightRatio == nil then return REASON.NO_BREEDING_WEIGHT end
    if (purpose.parent == "always" or purpose.pregnant == "always")
        and (subType.gender ~= "female" or not subType.supportsReproduction) then
        return REASON.NO_REPRODUCTION
    end
    if not RLDealerStockPolicy.hasSource(entry, purpose, subType.gender) then return REASON.NO_SOURCE end
    return nil
end


--- The ages the subtype can be offered at for a purpose: its window cut down to the buyable ages.
--- @return table[]|nil segments inclusive {{a, b}, ...}, nil when none
--- @return string|nil reason
--- @return number lo, number hi The window (for the age draw's centre)
function RLDealerStockPolicy.getSegments(purpose, entry, subType, ctx)
    local reason = getStaticReason(purpose, entry, subType)
    if reason ~= nil then return nil, reason end

    local lo, hi = RLDealerStockPolicy.getAgeWindow(purpose, entry, subType, ctx)
    if hi <= lo then return nil, REASON.NO_AGE end

    local segments = {}
    for _, segment in ipairs(ctx.union or RLDealerStockPolicy.getBuyableAgeUnion(subType, ctx.maxBuyAge)) do
        local a, b = math.max(lo, segment[1]), math.min(hi - 1, segment[2])
        if b >= a then table.insert(segments, { a, b }) end
    end
    if #segments == 0 then return nil, REASON.NOT_BUYABLE end
    return segments, nil, lo, hi
end


--- Every purpose for the subtype's sex with the ages it can be offered at, and why the others cannot.
--- @return table[] candidates {{purpose, segments, lo, hi}, ...}
--- @return table[] gaps {{purpose, reason}, ...}
function RLDealerStockPolicy.getCandidates(entry, subType, ctx)
    local candidates, gaps = {}, {}
    for _, purpose in ipairs(RLDealerStockPolicy.getPurposes(entry, subType.gender)) do
        local segments, reason, lo, hi = RLDealerStockPolicy.getSegments(purpose, entry, subType, ctx)
        if segments == nil then
            table.insert(gaps, { purpose = purpose, reason = reason })
        else
            table.insert(candidates, { purpose = purpose, segments = segments, lo = lo, hi = hi })
        end
    end
    return candidates, gaps
end


--- Draw a candidate by purpose weight.
--- @return table|nil candidate
function RLDealerStockPolicy.pickCandidate(candidates, randomFn)
    return pickWeighted(candidates, function(candidate) return candidate.purpose.weight end, randomFn)
end


--- Draw an age from a candidate's segments, leaning to the middle of its window: each age's
--- weight falls linearly from the centre (1 + half the window there, 1 at the window's edges).
--- @return number age
function RLDealerStockPolicy.pickAge(candidate, randomFn)
    local centre = (candidate.lo + candidate.hi - 1) / 2
    local half = (candidate.hi - 1 - candidate.lo) / 2
    -- Doubled so every weight is a whole number (the centre may fall between two months).
    local function weight(age) return math.floor(2 * (half + 1 - math.abs(age - centre)) + 0.5) end

    local total = 0
    for _, segment in ipairs(candidate.segments) do
        for age = segment[1], segment[2] do total = total + weight(age) end
    end

    local roll = randomFn(1, total)
    local cumulative = 0
    for _, segment in ipairs(candidate.segments) do
        for age = segment[1], segment[2] do
            cumulative = cumulative + weight(age)
            if roll <= cumulative then return age end
        end
    end
    local last = candidate.segments[#candidate.segments]
    return last[2]
end


-- =============================================================================
-- Breeding history
-- =============================================================================

--- Months from one birth to the next at the earliest: a gestation after the recovery.
local function getBirthCycle(entry, duration)
    return duration + entry.profile.minRecoveryMonth
end


--- The most births that fit before a last birth at `lastBirthAge`: the first at the breeding age
--- plus a gestation at the earliest, each later one at least a cycle after the one before.
--- @return number births 0 when not even one fits
function RLDealerStockPolicy.getMostBirths(entry, subType, lastBirthAge)
    local duration = subType.reproductionDurationMonth or 0
    local spare = lastBirthAge - RLDealerStockPolicy.getBreedingAge(entry, subType) - duration
    if spare < 0 then return 0 end
    return 1 + math.floor(spare / getBirthCycle(entry, duration) + 1e-9)
end


--- A birth and pregnancy history that fits the purpose at this age.
--- A parent has had `parity` births (minParity..maxParity, as many as fit its age), the last
--- `monthsSinceLastBirth` months ago (at least 1). A pregnancy is `pregnancyMonths` months along
--- (at least 1, at most maxPregnancyProgress of the gestation), conceived no earlier than the
--- breeding age, or minRecoveryMonth after the last birth.
--- Draws: the parent chance, the parity (only when more than one fits), the months since the last
--- birth, the pregnancy chance and its months.
--- @return table|nil plan {isParent, parity, monthsSinceLastBirth, isPregnant, pregnancyMonths, duration}
--- @return string|nil reason
function RLDealerStockPolicy.planReproduction(purpose, entry, subType, age, randomFn)
    local plan = { isParent = false, parity = 0, monthsSinceLastBirth = 12, isPregnant = false, pregnancyMonths = 0,
        duration = subType.reproductionDurationMonth or 0 }

    local canBreed = subType.gender == "female" and subType.supportsReproduction and plan.duration > 0
    local breedingAge = RLDealerStockPolicy.getBreedingAge(entry, subType)
    local profile = entry.profile

    local wantsParent = purpose.parent == "always" or (purpose.parent == "optional" and chance(randomFn, purpose.parentChance))
    if wantsParent then
        -- Most months since a single birth; each further birth takes a cycle off it.
        local latest = canBreed and math.floor(age - breedingAge - plan.duration) or 0
        local most = latest >= 1 and 1 + math.floor((latest - 1) / getBirthCycle(entry, plan.duration)) or 0
        local hi = math.min(purpose.maxParity, most)
        if hi >= purpose.minParity then
            plan.isParent = true
            plan.parity = hi > purpose.minParity and randomFn(purpose.minParity, hi) or hi
            plan.monthsSinceLastBirth = randomFn(1, latest - (plan.parity - 1) * getBirthCycle(entry, plan.duration))
        elseif purpose.parent == "always" then
            return nil, REASON.NO_TIMELINE
        end
    end

    local wantsPregnant = purpose.pregnant == "always"
        or (purpose.pregnant == "optional" and chance(randomFn, purpose.pregnancyChance))
    if wantsPregnant then
        local upper = 0
        if canBreed then
            upper = math.floor(profile.maxPregnancyProgress * plan.duration)
            if plan.isParent then
                upper = math.min(upper, plan.monthsSinceLastBirth - profile.minRecoveryMonth)
            else
                upper = math.min(upper, math.floor(age - breedingAge))
            end
        end
        if upper >= 1 then
            plan.isPregnant = true
            plan.pregnancyMonths = randomFn(1, upper)
        elseif purpose.pregnant == "always" then
            return nil, REASON.NO_TIMELINE
        end
    end

    return plan, nil
end


--- Whether a mother milks now: a female, since her last birth, for lactationMonths (ctx.lactates:
--- the species milks at all). The game's own rule (RLLactation), so a listing stays in step
--- as it ages on the shelf.
--- @param ctx table {lactates, lactationMonths}
--- @return boolean
function RLDealerStockPolicy.isInMilk(gender, isParent, monthsSinceLastBirth, ctx)
    return ctx.lactates == true and gender == "female" and isParent == true
        and (monthsSinceLastBirth or 0) < (ctx.lactationMonths or 0)
end


--- A dealer animal's health: from a healthy herd, minHealth..100 whatever its health genetics.
--- One draw.
--- @return number health 0..100
function RLDealerStockPolicy.drawHealth(entry, randomFn)
    local minHealth = entry.profile.minHealth
    return minHealth + randomFn(0, 1000) / 1000 * (100 - minHealth)
end


-- =============================================================================
-- Validation
-- =============================================================================

--- Whether an animal qualifies for a purpose now. No draws, no side effects.
--- When a pregnant animal conceived is read back from its gestation progress (reproduction) as
--- nominal months (progress x gestation). That holds when the animal is generated, but on the shelf
--- progress rises at least 1% a day (AnimalReproduction.changeReproduction), so with long months it
--- runs ahead of the calendar (28 days a month: 28% a month, 2.8 nominal cow months). `onShelf`
--- therefore skips the two conception-time checks for a listing that already passed them when it
--- was generated; its ages, breeding state and progress limit are still checked.
--- The listing record (animal.sale) is checked when it names a source or a parity: the source must
--- supply the purpose for the breed and sex; the parity must be the purpose's and fit the age. A
--- parent without a parity (a listing saved before parities) qualifies only when no more births
--- than the purpose allows can fit its age (its last birth taken a slack month early, as age and
--- months since birth step apart on the shelf).
--- @param animal table {age, gender, isParent, monthsSinceLastBirth, isPregnant, pregnancy,
---        reproduction (0..100), isLactating, isCastrated, health, weight, targetWeight,
---        getHasAnyDisease|nil, sale|nil {source, parity}}
--- @param ctx table {maxBuyAge, weaningMonth|nil, union|nil, lactates|nil, lactationMonths}
---        (lactates nil: milk not checked)
--- @param onShelf boolean|nil See above
--- @return boolean ok
--- @return string[] reasons
function RLDealerStockPolicy.validate(animal, purpose, entry, subType, ctx, onShelf)
    local reasons = {}
    local function fail(reason) table.insert(reasons, reason) end

    if purpose == nil then return false, { REASON.UNKNOWN_PURPOSE } end
    if purpose.gender ~= "any" and purpose.gender ~= animal.gender then fail(REASON.GENDER) end

    local segments, reason = RLDealerStockPolicy.getSegments(purpose, entry, subType, ctx)
    local age = animal.age or 0
    if segments == nil then
        fail(reason)
    else
        local inside = false
        for _, segment in ipairs(segments) do
            if age >= segment[1] and age <= segment[2] then inside = true end
        end
        if not inside then fail(REASON.AGE) end
    end

    local isParent = animal.isParent == true
    if (purpose.parent == "never" and isParent) or (purpose.parent == "always" and not isParent) then
        fail(REASON.PARENT)
    end

    local isPregnant = animal.isPregnant == true or animal.pregnancy ~= nil
    if (purpose.pregnant == "never" and isPregnant) or (purpose.pregnant == "always" and not isPregnant) then
        fail(REASON.PREGNANCY)
    end

    local profile = entry.profile
    local breedingAge = RLDealerStockPolicy.getBreedingAge(entry, subType)
    local duration = animal.pregnancy ~= nil and animal.pregnancy.duration or subType.reproductionDurationMonth or 0
    local eps = 1e-6
    -- Age moves on the birthday's day, months since the last birth at the start of a period and
    -- gestation every day, so within a month they can be up to a month out of step. A generated
    -- history is exact (planReproduction); this only lets a listing age without being withdrawn.
    local slack = RLDealerStockPolicy.TIMELINE_SLACK_MONTHS + eps

    local pregnancyMonths = 0
    if isPregnant then
        local progress = (animal.reproduction or 0) / 100
        if not (progress > 0 and progress <= profile.maxPregnancyProgress + eps) then
            fail(REASON.PREGNANCY_PROGRESS)
        end
        pregnancyMonths = progress * duration
    end

    if isParent then
        local sinceBirth = animal.monthsSinceLastBirth or 0
        if sinceBirth < 1 or age - sinceBirth < breedingAge + (subType.reproductionDurationMonth or 0) - slack
            or (isPregnant and not onShelf and sinceBirth - pregnancyMonths < profile.minRecoveryMonth - slack) then
            fail(REASON.TIMELINE)
        end
    elseif isPregnant and not onShelf and age - pregnancyMonths < breedingAge - slack then
        fail(REASON.TIMELINE)
    end

    local sale = animal.sale or {}
    local parity = sale.parity
    if isParent then
        local sinceBirth = animal.monthsSinceLastBirth or 0
        if parity ~= nil then
            if parity < purpose.minParity or parity > purpose.maxParity
                or parity > RLDealerStockPolicy.getMostBirths(entry, subType, age - sinceBirth + slack) then
                fail(REASON.PARITY)
            end
        elseif purpose.minParity > 1
            or RLDealerStockPolicy.getMostBirths(entry, subType, age - sinceBirth - slack) > purpose.maxParity then
            fail(REASON.PARITY)
        end
    elseif parity ~= nil and parity > 0 then
        fail(REASON.PARITY)
    end

    if ctx.lactates ~= nil
        and (animal.isLactating == true) ~= RLDealerStockPolicy.isInMilk(animal.gender, isParent, animal.monthsSinceLastBirth, ctx) then
        fail(REASON.LACTATION)
    end

    if purpose.breeding and animal.gender == "male" and animal.isCastrated then fail(REASON.CASTRATED) end

    if not ((animal.health or 0) >= profile.minHealth - eps) then fail(REASON.HEALTH) end
    if type(animal.getHasAnyDisease) == "function" and animal:getHasAnyDisease() then fail(REASON.SICK) end

    if sale.source ~= nil then
        local source = RLDealerStockPolicy.findSource(entry, sale.source)
        if source == nil or not RLDealerStockPolicy.supplies(source, entry, purpose, animal.gender) then
            fail(REASON.SOURCE)
        end
    end

    if purpose.breedingWeight and entry.breedingWeightRatio ~= nil
        and not ((animal.weight or 0) >= entry.breedingWeightRatio * (animal.targetWeight or 0)) then
        fail(REASON.TOO_LIGHT)
    end

    return #reasons == 0, reasons
end


--- The first purpose (file order) the animal qualifies for now, for a listing saved before
--- purposes existed. Checked like a newly generated animal (not `onShelf`): its history was made
--- by the old rules and never checked, so one whose conception cannot be shown to fit is withdrawn
--- and replaced by the next restock rather than kept.
--- @return table|nil purpose
--- @return string|nil reason The first purpose's first failure, when none qualifies
function RLDealerStockPolicy.classify(animal, entry, subType, ctx)
    local firstReason
    for _, purpose in ipairs(RLDealerStockPolicy.getPurposes(entry, animal.gender)) do
        local ok, reasons = RLDealerStockPolicy.validate(animal, purpose, entry, subType, ctx)
        if ok then return purpose, nil end
        firstReason = firstReason or reasons[1]
    end
    return nil, firstReason or REASON.NO_PURPOSE
end


--- "KEY=n KEY=n", sorted, of a count map; "" when empty. One format for every RLDEALER and dealer
--- summary line, so log readers can parse them alike.
--- @param counts table|nil {[key] = count}
--- @return string
function RLDealerStockPolicy.formatCounts(counts)
    local parts = {}
    for key, count in pairs(counts or {}) do table.insert(parts, string.format("%s=%d", tostring(key), count)) end
    table.sort(parts)
    return table.concat(parts, " ")
end
