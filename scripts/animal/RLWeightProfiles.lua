--[[
    RLWeightProfiles.lua
    Which weight profile (xml/weightProfiles.xml) each loaded cattle subtype belongs to, and where
    each of its weight settings comes from. Read-only: it reports, it never changes how an animal
    grows. The console command rlWeightProfiles writes one line per subtype and a summary:

        [RLRM|I] RLWEIGHT {"kind":"WEIGHT_PROFILE","subType":"BULL_CHAROLAISE","profile":"CHAROLAIS_PACK",...}

    Resolution of a subtype's breed: EXACT (the breed is a profile), ALIAS (a map's name for a
    profile's breed) or UNRESOLVED (neither: reported as a gap, never put under another breed).
    Hof Bergmann's MILKCOW is its own animal type without individual weights; its subtypes are
    listed as NOT_COVERED.

    Each setting is reported with its value and its source: the layer of the config file that set
    it ("subType", "breed", "type", "root") or "default" when the code's fallback applies - for
    matureAgeMonth 1.5 x the reproduction age, for femaleGrowth 0.6, growth and feed 1, the carcass
    maturity 1. defaults lists the settings on the code's fallback, generic those set only for the
    whole animal type or file (nothing for this breed), priceLine whether a live-price line is set.
    gap is true when the breed is unresolved or a setting the growth line needs (matureAgeMonth,
    and femaleGrowth for a female) is on the code's fallback.
]]

RLWeightProfiles = {}

local Log = RmLogging.getLogger("RLRM")

RLWeightProfiles.CONFIG_FILE = "weightProfiles.xml"
RLWeightProfiles.TAG = "RLWEIGHT"

--- Animal type names the report covers, and the one it lists as not covered.
RLWeightProfiles.COVERED_TYPE = "COW"
RLWeightProfiles.UNCOVERED_TYPES = { MILKCOW = "MILKCOW is an animal type of its own without individual weights" }


--- Read a config.
--- @param xmlFile table|nil
--- @return table config { profiles = { NAME = { status } }, aliases = { BREED = { profile, source } } }
function RLWeightProfiles.parse(xmlFile)
    local config = { profiles = {}, aliases = {} }
    if xmlFile == nil then return config end

    xmlFile:iterate("weightProfiles.profile", function(_, key)
        local name = xmlFile:getString(key .. "#name")
        if name ~= nil then config.profiles[name:upper()] = { status = xmlFile:getString(key .. "#status", "UNKNOWN") } end
    end)

    xmlFile:iterate("weightProfiles.alias", function(_, key)
        local breed, profile = xmlFile:getString(key .. "#breed"), xmlFile:getString(key .. "#profile")
        if breed == nil or profile == nil then return end
        profile = profile:upper()
        if config.profiles[profile] == nil then
            Log:warning("RLWeightProfiles: alias %s names profile %s, which the file does not list; ignored", breed, profile)
            return
        end
        config.aliases[breed:upper()] = { profile = profile, source = xmlFile:getString(key .. "#source") }
    end)

    return config
end


--- The config, loaded on the first call.
function RLWeightProfiles.getConfig()
    if RLWeightProfiles.config == nil then
        RLWeightProfiles.config = RLBreedTraits.loadConfig(RLWeightProfiles.CONFIG_FILE, "weightProfiles", RLWeightProfiles.parse)
    end
    return RLWeightProfiles.config
end


--- The profile a subtype's breed resolves to.
--- @param subType table
--- @return string|nil profile
--- @return string resolution "EXACT", "ALIAS" or "UNRESOLVED"
function RLWeightProfiles.resolveProfile(subType)
    local config = RLWeightProfiles.getConfig()
    local breed = subType ~= nil and subType.breed ~= nil and subType.breed:upper() or nil
    if breed == nil then return nil, "UNRESOLVED" end
    if config.profiles[breed] ~= nil then return breed, "EXACT" end
    local alias = config.aliases[breed]
    if alias ~= nil then return alias.profile, "ALIAS" end
    return nil, "UNRESOLVED"
end


--- One setting: { value, source }, source "default" when no layer of its file sets it.
local function setting(layers, subType, attr, default)
    local value, source = RLBreedTraits.resolveSource(layers, subType, attr)
    if source == nil then return { value = default, source = "default" } end
    return { value = value, source = source }
end


--- A subtype's report record (no state change).
--- @param subType table
--- @return table record
function RLWeightProfiles.describe(subType)
    local typeName = RLBreedTraits.getTypeName(subType)
    local record = { kind = "WEIGHT_PROFILE", subType = subType.name, breed = subType.breed, gender = subType.gender,
        type = typeName }

    local uncovered = typeName ~= nil and RLWeightProfiles.UNCOVERED_TYPES[typeName] or nil
    if uncovered ~= nil then
        record.resolution, record.reason, record.gap = "NOT_COVERED", uncovered, true
        return record
    end

    local profile, resolution = RLWeightProfiles.resolveProfile(subType)
    local config = RLWeightProfiles.getConfig()
    record.profile, record.resolution = profile, resolution
    record.profileStatus = profile ~= nil and config.profiles[profile].status or nil

    record.targetWeight, record.minWeight, record.maxWeight = subType.targetWeight, subType.minWeight, subType.maxWeight
    record.reproductionMinAgeMonth = subType.reproductionMinAgeMonth

    local traits = RLBreedTraits.getConfig().layers
    local isFemale = subType.gender == "female"
    record.matureAgeMonth = setting(traits, subType, "matureAgeMonth", (subType.reproductionMinAgeMonth or 0) * 1.5)
    record.growth = setting(traits, subType, "growth", 1)
    record.feed = setting(traits, subType, "feed", 1)
    if isFemale then record.femaleGrowth = setting(traits, subType, "femaleGrowth", RLBreedTraits.DEFAULT_FEMALE_GROWTH) end

    local priceTarget = RLBreedTraits.resolveSource(traits, subType, "priceTargetWeight")
    local priceAge = RLBreedTraits.resolveSource(traits, subType, "priceMatureAgeMonth")
    record.priceLine = priceTarget ~= nil and priceAge ~= nil

    if AnimalMoveEvent ~= nil and AnimalMoveEvent.getCarcassConfig ~= nil then
        record.maturity = setting(AnimalMoveEvent.getCarcassConfig().layers, subType, isFemale and "femaleMaturity" or "maleMaturity", 1)
    end

    local defaults, generic = {}, {}
    for _, name in ipairs({ "matureAgeMonth", "femaleGrowth", "growth", "feed", "maturity" }) do
        local source = record[name] ~= nil and record[name].source or nil
        if source == "default" then
            table.insert(defaults, name)
        elseif source == "type" or source == "root" then
            table.insert(generic, name)
        end
    end
    record.defaults, record.generic = defaults, generic

    record.gap = resolution == "UNRESOLVED" or record.matureAgeMonth.source == "default"
        or (record.femaleGrowth ~= nil and record.femaleGrowth.source == "default")

    return record
end


--- Records of the loaded cattle subtypes (COW, and MILKCOW as not covered), in load order.
--- @param filter string|nil Part of a subtype or breed name, case-insensitive
--- @return table records
function RLWeightProfiles.enumerate(filter)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    local records = {}
    if animalSystem == nil or animalSystem.subTypes == nil then return records end
    filter = filter ~= nil and filter:lower() or nil

    for _, subType in ipairs(animalSystem.subTypes) do
        local typeName = RLBreedTraits.getTypeName(subType)
        if typeName == RLWeightProfiles.COVERED_TYPE or RLWeightProfiles.UNCOVERED_TYPES[typeName] ~= nil then
            local name = ((subType.name or "") .. " " .. (subType.breed or "")):lower()
            if filter == nil or name:find(filter, 1, true) ~= nil then table.insert(records, RLWeightProfiles.describe(subType)) end
        end
    end

    return records
end


--- Totals of a list of records.
--- @param records table
--- @return table summary
function RLWeightProfiles.summarize(records)
    local summary = { kind = "WEIGHT_PROFILE_SUMMARY", subTypes = #records, resolution = {}, defaults = {}, generic = {},
        gaps = 0, noPriceLine = 0, unresolvedBreeds = {} }
    local seen = {}
    for _, record in ipairs(records) do
        summary.resolution[record.resolution] = (summary.resolution[record.resolution] or 0) + 1
        if record.gap then summary.gaps = summary.gaps + 1 end
        if record.priceLine == false then summary.noPriceLine = summary.noPriceLine + 1 end
        for _, name in ipairs(record.defaults or {}) do summary.defaults[name] = (summary.defaults[name] or 0) + 1 end
        for _, name in ipairs(record.generic or {}) do summary.generic[name] = (summary.generic[name] or 0) + 1 end
        if record.resolution == "UNRESOLVED" and record.breed ~= nil and not seen[record.breed] then
            seen[record.breed] = true
            table.insert(summary.unresolvedBreeds, record.breed)
        end
    end
    table.sort(summary.unresolvedBreeds)
    return summary
end


--- Write one record as a log line: TAG, then the record as one-line JSON (RLPenLog's encoding).
--- A line too long for the log is replaced by a LINE_TOO_LONG marker.
--- @param record table
--- @return string line
function RLWeightProfiles.emit(record)
    local line = RLWeightProfiles.TAG .. " " .. RLPenLog.encode(record)
    if #line > RLPenLog.MAX_LINE then
        line = RLWeightProfiles.TAG .. " " .. RLPenLog.encode({ kind = "LINE_TOO_LONG", record = record.kind,
            subType = record.subType, length = #line })
        Log:warning("%s", line)
    else
        Log:info("%s", line)
    end
    return line
end


--- Console: rlWeightProfiles [filter]. One line per cattle subtype, then the summary.
--- @param filter string|nil
--- @return string text What the console shows
function RLWeightProfiles:consoleReport(filter)
    local records = RLWeightProfiles.enumerate(filter)
    for _, record in ipairs(records) do RLWeightProfiles.emit(record) end
    local summary = RLWeightProfiles.summarize(records)
    RLWeightProfiles.emit(summary)
    return string.format("rlWeightProfiles: %d cattle subtypes, %d with gaps, unresolved breeds: %s (RLWEIGHT lines in the log)",
        summary.subTypes, summary.gaps, #summary.unresolvedBreeds > 0 and table.concat(summary.unresolvedBreeds, " ") or "none")
end
