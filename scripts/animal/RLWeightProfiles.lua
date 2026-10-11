--[[
    RLWeightProfiles.lua
    The weight profiles of cattle (xml/weightProfiles.xml): each physical breed's female and male
    reference curve and mean birth weight, the names maps use for those breeds, the animal types
    bound to a profile as a stand-in (Hof Bergmann's MILKCOW), and the root settings of the weight
    model v2 (RLGrowth). Also the read-only report rlWeightProfiles: one line per loaded cattle
    subtype and a summary,

        [RLRM|I] RLWEIGHT {"kind":"WEIGHT_PROFILE","subType":"BULL_CHAROLAISE","profile":"CHAROLAIS_PACK",...}

    Resolution of a subtype's breed: EXACT (the breed is a profile), ALIAS (a map's name for a
    profile's breed), PROXY (its animal type is bound to a profile as a stand-in), NOT_COVERED
    (an animal type the file names without a binding in use) or UNRESOLVED (none of these: a
    gap, never put under another breed).

    Each legacy weight setting is reported with the value the game uses (read through the same
    getter) and its source: the layer of the config file that set it ("subType", "breed", "type",
    "root") or "default" when the getter's fallback applies. Under v2 the record also carries the
    curve the subtype grows on: adult and birth weight, plateau month, its knots.
]]

RLWeightProfiles = {}

local Log = RmLogging.getLogger("RLRM")

RLWeightProfiles.CONFIG_FILE = "weightProfiles.xml"
RLWeightProfiles.TAG = "RLWEIGHT"

--- Animal type names the report covers, and the ones it lists as not covered unless a binding
--- in the file takes them in. Other animal types join through `<animalType name enabled>` in the
--- file, with profiles of their own (`<profile type="SHEEP">`, kept apart from cattle breeds of the
--- same name: a sheep and a pig are both "LANDRACE"); a type the file switches off keeps every
--- animal of it on the old rules while its curves wait for the type's feed and body condition.
RLWeightProfiles.COVERED_TYPE = "COW"
RLWeightProfiles.UNCOVERED_TYPES = { MILKCOW = "MILKCOW is an animal type of its own without individual weights" }

RLWeightProfiles.SEXES = { "female", "male" }

--- Root settings of the weight model v2 and their defaults. All are design candidates (see the
--- file's comment), not measured values.
RLWeightProfiles.DEFAULTS = {
    maleBirthFactor = 1.07, birthWeightCV = 0.10, birthTruncateSD = 2.5, birthGeneEffect = 0.05,
    firstBirthFactor = 0.93, litter2 = 0.85, litter3 = 0.75, litter4 = 0.70,
    damReserveEffect = 0.25, damFactorMin = 0.90, damFactorMax = 1.03,
    geneSpan = 0.75, sizeGeneEffect = 0.12, speedGeneEffect = 0.10, maintenanceGeneEffect = 0.15,
    birthFadeMonths = 6, castratedSpeed = 0.90, transitionMonths = 0.5, underweightRatio = 0.60,
    frameFloorRatio = 0.5, migrationBlendMonths = 12,
    gravidTermRatio = 1.8, gravidExponent = 3,
    lactationIntakeRate = 0.192, lactationIntakeOffset = 3.67, lactationWeeksPerMonth = 4.29, lactationIntakeStrength = 1,
    lactationCapacityStrength = 0.3, earlyMilkMobilizeShare = 0.45, earlyMilkMobilizeMonths = 3,
}


--- The key a profile is stored under: the breed for cattle, "TYPE:BREED" for any other type.
--- @param typeName string|nil
--- @param name string
--- @return string
function RLWeightProfiles.profileKey(typeName, name)
    if typeName == nil or typeName:upper() == RLWeightProfiles.COVERED_TYPE then return name:upper() end
    return typeName:upper() .. ":" .. name:upper()
end


--- Parse "month:kg month:kg ..." into knots, the birth knot (0, birthKg) first.
--- @param text string|nil
--- @param birthKg number
--- @return table|nil knots
--- @return string|nil reason
function RLWeightProfiles.parseKnots(text, birthKg)
    if text == nil then return nil, "no knots" end
    local knots = { { 0, birthKg } }
    for pair in text:gmatch("%S+") do
        local t, w = pair:match("^([%d%.]+):([%d%.]+)$")
        t, w = tonumber(t), tonumber(w)
        if t == nil or w == nil then return nil, "knot '" .. pair .. "' is not month:kg" end
        knots[#knots + 1] = { t, w }
    end
    local ok, reason = RLGrowthCurve.validate(knots)
    if not ok then return nil, reason end
    return knots
end


--- Check root settings.
--- @param settings table
--- @return boolean ok
--- @return string|nil reason
function RLWeightProfiles.validateSettings(settings)
    for key in pairs(RLWeightProfiles.DEFAULTS) do
        local value = settings[key]
        if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
            return false, string.format("%s must be a number >= 0 (got %s)", key, tostring(value))
        end
    end
    local s = settings
    if s.birthWeightCV >= 0.5 then return false, "birthWeightCV must be < 0.5" end
    if s.birthTruncateSD <= 0 or s.birthTruncateSD * s.birthWeightCV >= 0.9 then
        return false, "birthTruncateSD must be > 0 and keep every draw above 10% of the mean"
    end
    if s.geneSpan <= 0 then return false, "geneSpan must be > 0" end
    if s.sizeGeneEffect >= 1 or s.speedGeneEffect >= 1 or s.maintenanceGeneEffect >= 1 or s.birthGeneEffect >= 1 then
        return false, "gene effects must be < 1"
    end
    if s.maleBirthFactor <= 0 or s.firstBirthFactor <= 0 or s.litter2 <= 0 or s.litter3 <= 0 or s.litter4 <= 0 then
        return false, "birth factors must be > 0"
    end
    if not (s.damFactorMin <= 1 and 1 <= s.damFactorMax) then return false, "need damFactorMin <= 1 <= damFactorMax" end
    if s.castratedSpeed <= 0 or s.castratedSpeed > 2 then return false, "castratedSpeed must be > 0 and <= 2" end
    if s.transitionMonths <= 0 then return false, "transitionMonths must be > 0" end
    if s.underweightRatio >= 1 then return false, "underweightRatio must be < 1" end
    if s.frameFloorRatio <= 0 or s.frameFloorRatio > 1 then return false, "frameFloorRatio must be > 0 and <= 1" end
    if s.birthFadeMonths <= 0 then return false, "birthFadeMonths must be > 0" end
    if s.migrationBlendMonths <= 0 then return false, "migrationBlendMonths must be > 0" end
    if s.gravidExponent < 1 then return false, "gravidExponent must be >= 1" end
    if s.lactationWeeksPerMonth <= 0 then return false, "lactationWeeksPerMonth must be > 0" end
    if s.earlyMilkMobilizeShare > 1 then return false, "earlyMilkMobilizeShare must be <= 1" end
    if s.earlyMilkMobilizeMonths <= 0 then return false, "earlyMilkMobilizeMonths must be > 0" end
    if s.lactationIntakeStrength > 1 or s.lactationCapacityStrength > 1 then
        return false, "lactationIntakeStrength and lactationCapacityStrength must be <= 1"
    end
    return true
end


--- Read a config.
--- @param xmlFile table|nil
--- @return table config { enabled, settings, profiles = { NAME = { status, birthFemaleKg, knots = { female, male }, invalid } },
---                        aliases = { BREED = { profile, source } }, bindings = { TYPE = { profile, sex, status, enabled } } }
function RLWeightProfiles.parse(xmlFile)
    local config = { enabled = false, settings = table.clone(RLWeightProfiles.DEFAULTS), profiles = {}, aliases = {}, bindings = {},
        types = {} }
    if xmlFile == nil then return config end

    config.enabled = xmlFile:getBool("weightProfiles#enabled", false)
    for key, default in pairs(RLWeightProfiles.DEFAULTS) do
        config.settings[key] = xmlFile:getFloat("weightProfiles#" .. key, default)
    end

    xmlFile:iterate("weightProfiles.animalType", function(_, key)
        local typeName = xmlFile:getString(key .. "#name")
        if typeName == nil or typeName:upper() == RLWeightProfiles.COVERED_TYPE then return end
        config.types[typeName:upper()] = { enabled = xmlFile:getBool(key .. "#enabled", false),
            status = xmlFile:getString(key .. "#status", "UNKNOWN") }
    end)

    xmlFile:iterate("weightProfiles.profile", function(_, key)
        local name = xmlFile:getString(key .. "#name")
        if name == nil then return end
        local typeName = xmlFile:getString(key .. "#type", RLWeightProfiles.COVERED_TYPE):upper()
        if typeName ~= RLWeightProfiles.COVERED_TYPE and config.types[typeName] == nil then
            Log:warning("RLWeightProfiles: profile %s is of type %s, which no animalType element lists; ignored", name, typeName)
            return
        end
        name = RLWeightProfiles.profileKey(typeName, name)
        local profile = { status = xmlFile:getString(key .. "#status", "UNKNOWN"), knots = {}, typeName = typeName }
        config.profiles[name] = profile

        local birth = xmlFile:getFloat(key .. "#birthFemaleKg")
        if birth == nil then return end
        if birth <= 0 or birth ~= birth then
            profile.invalid = "birthFemaleKg must be > 0"
        else
            profile.birthFemaleKg = birth
            profile.maleBirthFactor = xmlFile:getFloat(key .. "#maleBirthFactor")
            local factor = profile.maleBirthFactor
            if factor ~= nil and not (factor > 0 and factor < 3) then
                profile.invalid = "maleBirthFactor must be > 0 and < 3"
            end
            for _, sex in ipairs(RLWeightProfiles.SEXES) do
                if profile.invalid ~= nil then break end
                local births = sex == "male" and birth * (profile.maleBirthFactor or config.settings.maleBirthFactor) or birth
                local knots, reason = RLWeightProfiles.parseKnots(xmlFile:getString(key .. "." .. sex .. "#knots"), births)
                if knots == nil then
                    profile.invalid = sex .. ": " .. reason
                    profile.knots = {}
                    break
                end
                profile.knots[sex] = knots
            end
        end
        if profile.invalid ~= nil then
            Log:warning("RLWeightProfiles: profile %s is invalid (%s); its animals keep the old weight rules", name, profile.invalid)
        end
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

    xmlFile:iterate("weightProfiles.typeBinding", function(_, key)
        local typeName, profile = xmlFile:getString(key .. "#type"), xmlFile:getString(key .. "#profile")
        local sex = xmlFile:getString(key .. "#sex", "female")
        if typeName == nil or profile == nil then return end
        profile = profile:upper()
        if config.profiles[profile] == nil or (sex ~= "female" and sex ~= "male") then
            Log:warning("RLWeightProfiles: binding of type %s names profile %s / sex %s the file does not have; ignored",
                typeName, profile, tostring(sex))
            return
        end
        config.bindings[typeName:upper()] = { profile = profile, sex = sex, enabled = xmlFile:getBool(key .. "#enabled", true),
            status = xmlFile:getString(key .. "#status", "PROXY") }
    end)

    local ok, reason = RLWeightProfiles.validateSettings(config.settings)
    if not ok then
        Log:error("RLWeightProfiles: %s - weight model v2 switched off", reason)
        config.enabled = false
        config.invalidReason = reason
    end

    return config
end


--- The config, loaded on the first call.
function RLWeightProfiles.getConfig()
    if RLWeightProfiles.config == nil then
        RLWeightProfiles.config = RLBreedTraits.loadConfig(RLWeightProfiles.CONFIG_FILE, "weightProfiles", RLWeightProfiles.parse)
    end
    return RLWeightProfiles.config
end


--- The profile a breed name resolves to.
--- @param breed string|nil As subtypes carry it
--- @param typeName string|nil The animal type (cattle when nil): other types use their own profiles, no aliases
--- @return string|nil profile
--- @return string resolution "EXACT", "ALIAS" or "UNRESOLVED"
function RLWeightProfiles.resolveBreed(breed, typeName)
    if breed == nil then return nil, "UNRESOLVED" end
    local config = RLWeightProfiles.getConfig()
    if typeName ~= nil and typeName:upper() ~= RLWeightProfiles.COVERED_TYPE then
        local key = RLWeightProfiles.profileKey(typeName, breed)
        if config.profiles[key] ~= nil then return key, "EXACT" end
        return nil, "UNRESOLVED"
    end
    breed = breed:upper()
    if config.profiles[breed] ~= nil then return breed, "EXACT" end
    local alias = config.aliases[breed]
    if alias ~= nil then return alias.profile, "ALIAS" end
    return nil, "UNRESOLVED"
end


--- The profile a subtype's breed resolves to.
--- @param subType table
--- @return string|nil profile
--- @return string resolution "EXACT", "ALIAS" or "UNRESOLVED"
function RLWeightProfiles.resolveProfile(subType)
    if subType == nil then return nil, "UNRESOLVED" end
    return RLWeightProfiles.resolveBreed(subType.breed, RLBreedTraits.getTypeName(subType))
end


--- A non-cattle animal type the file lists (`<animalType>`), or nil.
--- @param typeName string|nil
--- @return table|nil { enabled, status }
function RLWeightProfiles.getTypeEntry(typeName)
    if typeName == nil then return nil end
    return RLWeightProfiles.getConfig().types[typeName:upper()]
end


--- A binding of a whole animal type to a profile, in use (enabled).
--- @param typeName string|nil
--- @return table|nil { profile, sex, status }
function RLWeightProfiles.getBinding(typeName)
    if typeName == nil then return nil end
    local binding = RLWeightProfiles.getConfig().bindings[typeName:upper()]
    if binding == nil or not binding.enabled then return nil end
    return binding
end


--- Which profile and sex curve a subtype grows on, and how it got there.
--- @param subType table|nil
--- @return table|nil binding { profile, sex, resolution = "EXACT" / "ALIAS" / "PROXY", typeName }
--- @return string resolution Also "UNRESOLVED", "NOT_COVERED", "NOT_CATTLE", "TYPE_OFF" (a listed type switched
--- off) or "INVALID_PROFILE" when there is none
function RLWeightProfiles.getCurveBinding(subType)
    if subType == nil then return nil, "UNRESOLVED" end
    local typeName = RLBreedTraits.getTypeName(subType)
    local config = RLWeightProfiles.getConfig()
    local typeEntry = RLWeightProfiles.getTypeEntry(typeName)

    local profileName, sex, resolution
    if typeName == RLWeightProfiles.COVERED_TYPE or typeEntry ~= nil then
        if typeEntry ~= nil and not typeEntry.enabled then return nil, "TYPE_OFF" end
        profileName, resolution = RLWeightProfiles.resolveProfile(subType)
        sex = subType.gender == "male" and "male" or "female"
    else
        local binding = RLWeightProfiles.getBinding(typeName)
        if binding == nil then
            if typeName ~= nil and (RLWeightProfiles.UNCOVERED_TYPES[typeName] ~= nil or config.bindings[typeName:upper()] ~= nil) then
                return nil, "NOT_COVERED"
            end
            return nil, "NOT_CATTLE"
        end
        profileName, sex, resolution = binding.profile, binding.sex, "PROXY"
    end

    if profileName == nil then return nil, resolution end
    local profile = config.profiles[profileName]
    if profile == nil or profile.invalid ~= nil or profile.knots[sex] == nil then return nil, "INVALID_PROFILE" end
    return { profile = profileName, sex = sex, resolution = resolution, typeName = typeName }, resolution
end


--- One setting: the value the game uses (from its own getter) and the layer of its file that set
--- it, "default" when none does and the getter's fallback applies.
local function setting(value, layers, subType, attr)
    local _, source = RLBreedTraits.resolveSource(layers, subType, attr)
    return { value = value, source = source or "default" }
end


local function round(value, digits)
    local scale = 10 ^ (digits or 2)
    return math.floor(value * scale + 0.5) / scale
end


--- A subtype's report record (no state change).
--- @param subType table
--- @param counts table|nil RLGrowth.countHeldAnimals(), counted once for a whole report
--- @return table record
function RLWeightProfiles.describe(subType, counts)
    local typeName = RLBreedTraits.getTypeName(subType)
    local record = { kind = "WEIGHT_PROFILE", subType = subType.name, breed = subType.breed, gender = subType.gender,
        type = typeName }
    local config = RLWeightProfiles.getConfig()

    local typeEntry = RLWeightProfiles.getTypeEntry(typeName)
    if typeEntry ~= nil then record.typeEnabled = typeEntry.enabled end
    if typeName ~= RLWeightProfiles.COVERED_TYPE and typeEntry == nil then
        local binding = RLWeightProfiles.getBinding(typeName)
        if binding == nil then
            record.resolution, record.reason, record.gap = "NOT_COVERED", RLWeightProfiles.UNCOVERED_TYPES[typeName]
                or "animal type without a binding", true
            if RLGrowth ~= nil then record.capability = RLGrowth.describeCapability(subType, counts) end
            return record
        end
        record.profile, record.resolution, record.proxySex = binding.profile, "PROXY", binding.sex
        record.profileStatus = binding.status
        record.gap = true
        if RLGrowth ~= nil then
            record.capability = RLGrowth.describeCapability(subType, counts)
            record.curve = RLGrowth.describeCurve(subType)
        end
        return record
    end

    local profile, resolution = RLWeightProfiles.resolveProfile(subType)
    record.profile, record.resolution = profile, resolution
    record.profileStatus = profile ~= nil and config.profiles[profile].status or nil

    record.targetWeight, record.minWeight, record.maxWeight = subType.targetWeight, subType.minWeight, subType.maxWeight
    record.reproductionMinAgeMonth = subType.reproductionMinAgeMonth

    local traits = RLBreedTraits.getConfig().layers
    record.matureAgeMonth = setting(RLBreedTraits.getMatureAge(subType), traits, subType, "matureAgeMonth")
    record.growth = setting(RLBreedTraits.get(subType, "growth"), traits, subType, "growth")
    record.feed = setting(RLBreedTraits.get(subType, "feed"), traits, subType, "feed")
    -- The growth line's sex factor applies to "female" only (RLBreedTraits.getLineGain).
    if subType.gender == "female" then
        record.femaleGrowth = setting(RLBreedTraits.getFemaleGrowth(subType), traits, subType, "femaleGrowth")
    end
    record.priceLine = RLBreedTraits.getPriceModel(subType) ~= nil

    if AnimalMoveEvent ~= nil and AnimalMoveEvent.getCarcassConfig ~= nil then
        -- The slaughter reference's choice (AnimalMoveEvent.getCarcassReferenceWeight): maleMaturity
        -- for "male", femaleMaturity for anything else.
        local attr = subType.gender == "male" and "maleMaturity" or "femaleMaturity"
        local layers = AnimalMoveEvent.getCarcassConfig().layers
        record.maturity = setting(RLBreedTraits.resolve(layers, subType, attr, AnimalMoveEvent.CARCASS_ATTRIBUTE_DEFAULTS[attr]),
            layers, subType, attr)
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

    if RLGrowth ~= nil then record.curve = RLGrowth.describeCurve(subType) end

    -- A gap: the breed is unresolved; or, where the v2 curve does not apply, a setting the old
    -- growth line needs (matureAgeMonth, and femaleGrowth for a female) is on the code's fallback.
    local onCurve = record.curve ~= nil and record.curve.active == true
    record.gap = resolution == "UNRESOLVED" or (not onCurve and (record.matureAgeMonth.source == "default"
        or (record.femaleGrowth ~= nil and record.femaleGrowth.source == "default")))

    return record
end


--- Records of the loaded cattle subtypes (COW, and the bound or uncovered types), in load order.
--- @param filter string|nil Part of a subtype or breed name, case-insensitive
--- @return table records
function RLWeightProfiles.enumerate(filter)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    local records = {}
    if animalSystem == nil or animalSystem.subTypes == nil then return records end
    filter = filter ~= nil and filter:lower() or nil
    local bindings = RLWeightProfiles.getConfig().bindings
    local counts = RLGrowth ~= nil and RLGrowth.countHeldAnimals() or nil

    for _, subType in ipairs(animalSystem.subTypes) do
        local typeName = RLBreedTraits.getTypeName(subType)
        if typeName == RLWeightProfiles.COVERED_TYPE or RLWeightProfiles.UNCOVERED_TYPES[typeName] ~= nil
            or (typeName ~= nil and (bindings[typeName:upper()] ~= nil or RLWeightProfiles.getTypeEntry(typeName) ~= nil)) then
            local name = ((subType.name or "") .. " " .. (subType.breed or "")):lower()
            if filter == nil or name:find(filter, 1, true) ~= nil then table.insert(records, RLWeightProfiles.describe(subType, counts)) end
        end
    end

    return records
end


--- Totals of a list of records.
--- @param records table
--- @return table summary
function RLWeightProfiles.summarize(records)
    local summary = { kind = "WEIGHT_PROFILE_SUMMARY", subTypes = #records, resolution = {}, defaults = {}, generic = {},
        gaps = 0, noPriceLine = 0, unresolvedBreeds = {}, onCurve = 0,
        model = RLGrowth ~= nil and RLGrowth.isEnabled() and "v2" or "legacy" }
    local seen = {}
    for _, record in ipairs(records) do
        summary.resolution[record.resolution] = (summary.resolution[record.resolution] or 0) + 1
        if record.gap then summary.gaps = summary.gaps + 1 end
        if record.priceLine == false then summary.noPriceLine = summary.noPriceLine + 1 end
        if record.curve ~= nil and record.curve.active then summary.onCurve = summary.onCurve + 1 end
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
    return string.format("rlWeightProfiles: %d cattle subtypes (%s model, %d on a v2 curve), %d with gaps, unresolved breeds: %s (RLWEIGHT lines in the log)",
        summary.subTypes, summary.model, summary.onCurve, summary.gaps,
        #summary.unresolvedBreeds > 0 and table.concat(summary.unresolvedBreeds, " ") or "none")
end


RLWeightProfiles.round = round
