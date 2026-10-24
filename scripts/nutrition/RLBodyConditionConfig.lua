--[[
    RLBodyConditionConfig.lua
    Reads and checks xml/bodyCondition.xml (or the copy in the mod's modSettings folder) for the
    body condition model (RLNutritionMath, RLBodyCondition). A file that fails a check switches
    the feature off and logs why: the game never runs on silently clamped values.
]]

RLBodyConditionConfig = {}

local Log = RmLogging.getLogger("RLRM")

RLBodyConditionConfig.CONFIG_FILE = "bodyCondition.xml"

--- Root attributes and their defaults (used where the file leaves one out).
RLBodyConditionConfig.DEFAULTS = {
    calfLegacyUntilAgeMonth = 6,
    initialReserve = 0.45, reserveCapacityRatio = 0.20, referenceReserve = 0.45, minReserve = 0.05,
    gainRatePerMonth = 0.07, lossRatePerMonth = 0.08, mobilizeEaseRange = 0.15, trendTauMonths = 0.5,
    maintenancePerKgMetabolic = 4.5, growthNUPerKg = 40, depositNUPerKg = 48, mobilizeNUPerKg = 32,
    catabolismNUPerKg = 10, maxCatabolismPerMonth = 0.05, frameExcessTauMonths = 1,
    milkNUPerLiter = 11, pregnancyFactor = 0.35, pregnancyRampStart = 0.6,
    intakeGrowing = 1.10, intakeLactating = 1.02, intakeDry = 1.6, lactationMeanFactor = 1.08,
    highYieldIntake = 0.8, maxIntakeFactor = 1.25, milkPriority = 2, milkMobilizeShare = 0.15,
    milkMobilizeFloor = 0.30, heiferReserveCeiling = 0.55, cowReserveCeiling = 0.75, steerFinishShift = 0.08,
}

--- Attributes an animalType / breed / subType element may set for its animals (same layered
--- lookup as breedTraits.xml); the root value is the default.
RLBodyConditionConfig.LAYERED = { "intakeGrowing", "intakeLactating", "intakeDry" }

RLBodyConditionConfig.CURVES = { "finishingTarget", "finishScore", "yield", "market", "fertility", "lossTrend" }

--- Default curves, the shipped file's.
RLBodyConditionConfig.DEFAULT_CURVES = {
    finishingTarget = { { 0.5, 0.35 }, { 0.8, 0.42 }, { 1.0, 0.52 }, { 1.15, 0.65 }, { 1.3, 0.78 }, { 1.5, 0.90 } },
    finishScore = { { 0, 0 }, { 0.2, 25 }, { 0.35, 50 }, { 0.45, 65 }, { 0.6, 80 }, { 0.75, 90 }, { 1, 100 } },
    yield = { { 0, 0.92 }, { 25, 0.95 }, { 50, 0.98 }, { 65, 1 }, { 80, 1 }, { 90, 0.95 }, { 100, 0.88 } },
    market = { { 0, 0.92 }, { 25, 0.95 }, { 50, 0.98 }, { 65, 1 }, { 80, 1 }, { 90, 0.95 }, { 100, 0.88 } },
    fertility = { { 1, 0.2 }, { 2, 0.65 }, { 2.5, 1 }, { 3.25, 1 }, { 4, 0.75 }, { 5, 0.35 } },
    lossTrend = { { 0, 1 }, { 0.03, 1 }, { 0.1, 0.75 } },
}


--- Values only a species section has (the root, cattle, has none: a reader treats a missing one
--- as the cattle rule). femaleFinishShift: a young female read on the finishing target curve at
--- x + this (sheep: ewe lambs fatten at a lighter weight); fertilityEffect 0: body condition
--- leaves conception as it is (sheep S5: BCS and reproduction are S7); birthReserve (-1: the
--- initialReserve) the reserve index a newborn starts with (sheep: lean, about fat class 2);
--- finishReadyReserve / finishOverfatReserve (-1: the finish score's 65 / 80) the reserve from which
--- a grown young animal is ready, and over-fat (sheep: fat class 2 and 4L); youngUntilMonth (0: no
--- limit) the continuous age (months) from which an animal that never had young is grown: no fat
--- class, and a female no longer on the finishing target (sheep 12: a maiden ewe past it is a ewe
--- hogg on heiferReserveCeiling, not a ewe lamb fattened; RLBodyCondition.isFinishingYoungFemale).
RLBodyConditionConfig.SPECIES_DEFAULTS = { femaleFinishShift = 0, fertilityEffect = 1, birthReserve = -1, finishReadyReserve = -1,
    finishOverfatReserve = -1, youngUntilMonth = 0 }


--- A species section from its element: the root's values where it leaves one out, its own
--- attributes, curves and fat classes (`<fatClass name="3L" minReserve="0.38"/>`, ascending: the
--- class of a reserve is the last whose minReserve it reaches).
local function parseSpecies(xmlFile, key, root)
    local section = {}
    for field, value in pairs(root) do
        if field ~= "species" then section[field] = value end
    end
    section.speciesName = (xmlFile:getString(key .. "#name") or ""):upper()
    for field, default in pairs(RLBodyConditionConfig.DEFAULTS) do
        section[field] = xmlFile:getFloat(key .. "#" .. field, root[field] or default)
    end
    for field, default in pairs(RLBodyConditionConfig.SPECIES_DEFAULTS) do
        section[field] = xmlFile:getFloat(key .. "#" .. field, default)
    end
    section.curves = {}
    for name, points in pairs(root.curves) do section.curves[name] = points end
    for _, curve in ipairs(RLBodyConditionConfig.CURVES) do
        local points = {}
        xmlFile:iterate(key .. "." .. curve .. ".point", function(_, pointKey)
            local x, y = xmlFile:getFloat(pointKey .. "#x"), xmlFile:getFloat(pointKey .. "#y")
            if x ~= nil and y ~= nil then table.insert(points, { x, y }) end
        end)
        if #points > 0 then section.curves[curve] = points end
    end
    section.fatClasses = {}
    xmlFile:iterate(key .. ".fatClass", function(_, classKey)
        local name, minReserve = xmlFile:getString(classKey .. "#name"), xmlFile:getFloat(classKey .. "#minReserve")
        if name ~= nil and minReserve ~= nil then table.insert(section.fatClasses, { name = name, minReserve = minReserve }) end
    end)
    section.enabled = root.enabled
    local ok, reason = RLBodyConditionConfig.validate(section)
    if ok then ok, reason = RLBodyConditionConfig.validateSpecies(section) end
    if not ok then
        Log:error("RLBodyConditionConfig: species %s: %s - its body condition is off", section.speciesName, reason)
        section.enabled = false
        section.invalidReason = reason
    end
    return section
end


--- Check a species section's own values.
--- @return boolean ok
--- @return string|nil reason
function RLBodyConditionConfig.validateSpecies(section)
    if section.fertilityEffect ~= 0 and section.fertilityEffect ~= 1 then return false, "fertilityEffect must be 0 or 1" end
    if section.birthReserve ~= -1 and not (section.birthReserve >= section.minReserve and section.birthReserve <= 1) then
        return false, "birthReserve must be -1 or between minReserve and 1"
    end
    if section.youngUntilMonth < 0 then return false, "youngUntilMonth must be >= 0" end
    if #(section.fatClasses or {}) > 0 and section.youngUntilMonth <= 0 then
        return false, "a section with fat classes needs youngUntilMonth > 0"
    end
    for i, class in ipairs(section.fatClasses or {}) do
        if class.minReserve ~= class.minReserve or class.minReserve < 0 or class.minReserve > 1 then
            return false, "fat class " .. tostring(class.name) .. " minReserve must be 0..1"
        end
        if i > 1 and class.minReserve <= section.fatClasses[i - 1].minReserve then return false, "fat classes must rise in minReserve" end
    end
    return true
end


--- The section an animal, pen, subtype or type name reads: its species', else the root.
function RLBodyConditionConfig.getFor(subject)
    return RLSpecies.select(RLBodyConditionConfig.get(), subject)
end


--- Read a config.
--- @param xmlFile table|nil XMLFile with a bodyCondition root; nil gives the defaults
--- @return table config Values, curves, feedEnergy (fill type name -> energy), enabled
function RLBodyConditionConfig.parse(xmlFile)
    local config = table.clone(RLBodyConditionConfig.DEFAULTS)
    config.enabled = true
    config.fixedFeedPrice = false
    config.curves = {}
    config.feedEnergy = {}
    config.layers = { root = {}, types = {}, breeds = {}, subTypes = {} }

    for name, points in pairs(RLBodyConditionConfig.DEFAULT_CURVES) do config.curves[name] = points end

    if xmlFile ~= nil then
        config.enabled = xmlFile:getBool("bodyCondition#enabled", true)
        config.fixedFeedPrice = xmlFile:getBool("bodyCondition#fixedFeedPrice", false)

        for key, default in pairs(RLBodyConditionConfig.DEFAULTS) do
            config[key] = xmlFile:getFloat("bodyCondition#" .. key, default)
        end

        for _, curve in ipairs(RLBodyConditionConfig.CURVES) do
            local points = {}
            xmlFile:iterate("bodyCondition." .. curve .. ".point", function(_, key)
                local x, y = xmlFile:getFloat(key .. "#x"), xmlFile:getFloat(key .. "#y")
                if x ~= nil and y ~= nil then table.insert(points, { x, y }) end
            end)
            if #points > 0 then config.curves[curve] = points end
        end

        config.layers = RLBreedTraits.parseLayers(xmlFile, "bodyCondition", RLBodyConditionConfig.LAYERED)

        xmlFile:iterate("bodyCondition.feedEnergy.fillType", function(_, key)
            local name, energy = xmlFile:getString(key .. "#name"), xmlFile:getFloat(key .. "#energy")
            if name ~= nil and energy ~= nil then config.feedEnergy[name:upper()] = energy end
        end)
    end

    local ok, reason = RLBodyConditionConfig.validate(config)
    if not ok then
        Log:error("RLBodyConditionConfig: %s - body condition switched off", reason)
        config.enabled = false
        config.invalidReason = reason
    end

    config.species = {}
    if xmlFile ~= nil then
        xmlFile:iterate("bodyCondition.species", function(_, key)
            local section = parseSpecies(xmlFile, key, config)
            if section.speciesName ~= "" and config.species[section.speciesName] == nil then
                config.species[section.speciesName] = section
            end
        end)
    end

    return config
end


--- Check a config's values.
--- @param config table
--- @return boolean ok
--- @return string|nil reason
function RLBodyConditionConfig.validate(config)
    for key, _ in pairs(RLBodyConditionConfig.DEFAULTS) do
        local value = config[key]
        if type(value) ~= "number" or value ~= value or value < 0 then
            return false, string.format("%s must be a number >= 0 (got %s)", key, tostring(value))
        end
    end

    local c = config
    if not (c.minReserve < c.initialReserve and c.initialReserve <= 1) then return false, "need minReserve < initialReserve <= 1" end
    if not (c.referenceReserve >= 0 and c.referenceReserve <= 1) then return false, "referenceReserve must be 0..1" end
    if c.heiferReserveCeiling > 1 or c.cowReserveCeiling > 1 then return false, "reserve ceilings must be <= 1" end
    if c.reserveCapacityRatio <= 0 then return false, "reserveCapacityRatio must be > 0" end
    if c.gainRatePerMonth <= 0 or c.lossRatePerMonth <= 0 then return false, "gain and loss rates must be > 0" end
    if c.trendTauMonths <= 0 or c.frameExcessTauMonths <= 0 then return false, "time constants must be > 0" end
    if c.mobilizeEaseRange <= 0 then return false, "mobilizeEaseRange must be > 0" end
    if c.mobilizeNUPerKg <= 0 or c.catabolismNUPerKg <= 0 then return false, "mobilizeNUPerKg and catabolismNUPerKg must be > 0" end
    if not (c.depositNUPerKg > c.mobilizeNUPerKg) then
        return false, "depositNUPerKg must exceed mobilizeNUPerKg, or condition could be cycled into free energy"
    end
    if c.pregnancyRampStart >= 1 then return false, "pregnancyRampStart must be < 1" end
    if c.maxIntakeFactor < 1 then return false, "maxIntakeFactor must be >= 1" end
    if c.milkMobilizeShare > 1 then return false, "milkMobilizeShare must be <= 1" end
    if c.lactationMeanFactor <= 0 then return false, "lactationMeanFactor must be > 0" end

    for _, name in ipairs(RLBodyConditionConfig.CURVES) do
        local points = config.curves[name]
        if points == nil or #points == 0 then return false, "curve " .. name .. " has no points" end
        for i, point in ipairs(points) do
            if point[1] ~= point[1] or point[2] ~= point[2] then return false, string.format("curve %s point %d is not a number", name, i) end
            if point[2] < 0 then return false, string.format("curve %s point %d is negative", name, i) end
            if i > 1 and point[1] < points[i - 1][1] then
                return false, string.format("curve %s is not sorted by x at point %d", name, i)
            end
        end
    end

    for _, name in ipairs({ "yield", "market", "fertility", "lossTrend" }) do
        for i, point in ipairs(config.curves[name]) do
            if point[2] > 1.5 then return false, string.format("curve %s point %d is above 1.5", name, i) end
        end
    end
    for i, point in ipairs(config.curves.finishingTarget) do
        if point[2] > 1 then return false, string.format("curve finishingTarget point %d is above 1", i) end
    end

    local layers = config.layers
    local entries = {}
    for name, values in pairs(layers.types) do entries[#entries + 1] = { name, values } end
    for name, values in pairs(layers.subTypes) do entries[#entries + 1] = { name, values } end
    for typeName, breeds in pairs(layers.breeds) do
        for breed, values in pairs(breeds) do entries[#entries + 1] = { typeName .. "/" .. breed, values } end
    end
    for attr, value in pairs(layers.root or {}) do entries[#entries + 1] = { "root", { [attr] = value } } end
    for _, entry in ipairs(entries) do
        for attr, value in pairs(entry[2]) do
            if value ~= value or value <= 0 then return false, string.format("%s of %s must be a number > 0", attr, entry[1]) end
        end
    end

    for name, energy in pairs(config.feedEnergy) do
        if energy ~= energy or energy < 0 then return false, "feedEnergy of " .. name .. " is negative" end
    end

    return true
end


--- Migrate a copy of the file (the mod's modSettings folder) to what the unified nutrition model
--- needs, from the mod's own file. The body condition budget is part of the one nutrition model:
--- a copy that fails its checks gives way to the mod's file; a copy's enabled="false" (once the old
--- weight and milk rules) is no longer a way back to them and is not honoured; a species section it
--- lacks or that fails its checks (an older copy: no GOAT) is the mod's. Other values are the copy's.
--- @param config table The copy's config
--- @param builtin table|nil The mod's own file's
--- @return table config
function RLBodyConditionConfig.migrateCopy(config, builtin)
    if builtin == nil or builtin.enabled ~= true then return config end
    if config.invalidReason ~= nil then
        Log:error("RLBodyConditionConfig: the modSettings copy is invalid (%s) - the mod's own bodyCondition.xml is used",
            tostring(config.invalidReason))
        builtin.migrated = { "COPY_INVALID" }
        return builtin
    end
    local notes = {}
    if config.enabled ~= true then
        config.enabled = true
        notes[#notes + 1] = "ENABLED_IGNORED"
        for _, section in pairs(config.species or {}) do
            if section.invalidReason == nil then section.enabled = true end
        end
    end
    config.species = config.species or {}
    local names = {}
    for name in pairs(builtin.species or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local own, section = config.species[name], builtin.species[name]
        if section.enabled == true and (own == nil or own.enabled ~= true) then
            config.species[name] = section
            notes[#notes + 1] = name .. (own == nil and ":SECTION_ADDED" or ":SECTION_REPLACED")
        end
    end
    for _, note in ipairs(notes) do
        Log:info("RLBodyConditionConfig: modSettings copy migrated (%s) from the mod's own file", note)
    end
    config.migrated = notes
    return config
end


--- The config, loaded on the first call.
--- @return table
function RLBodyConditionConfig.get()
    if RLBodyConditionConfig.config == nil then
        local config, builtin = RLBreedTraits.loadConfigPair(RLBodyConditionConfig.CONFIG_FILE, "bodyCondition",
            RLBodyConditionConfig.parse)
        RLBodyConditionConfig.config = RLBodyConditionConfig.migrateCopy(config, builtin)
    end
    return RLBodyConditionConfig.config
end



--- A client takes the server's config (RLBodyConditionConfigEvent), so what it shows matches what
--- the server computes. Missing values keep the defaults; a config that fails the checks switches
--- the feature off on this client, as it would on a server. fixedFeedPrice is not sent: only the
--- server runs the budget it prices.
--- @param received table
function RLBodyConditionConfig.applyServerConfig(received)
    local config = table.clone(RLBodyConditionConfig.DEFAULTS)
    for key, _ in pairs(RLBodyConditionConfig.DEFAULTS) do
        if received[key] ~= nil then config[key] = received[key] end
    end
    config.enabled = received.enabled == true
    config.curves = received.curves or RLBodyConditionConfig.DEFAULT_CURVES
    config.feedEnergy = received.feedEnergy or {}
    config.layers = received.layers or { root = {}, types = {}, breeds = {}, subTypes = {} }

    local ok, reason = RLBodyConditionConfig.validate(config)
    if not ok then
        Log:error("RLBodyConditionConfig: the server's config fails a check (%s) - body condition switched off", reason)
        config.enabled = false
        config.invalidReason = reason
    end

    config.species = {}
    for name, sent in pairs(received.species or {}) do
        local section = {}
        for field, value in pairs(config) do
            if field ~= "species" then section[field] = value end
        end
        section.speciesName = name
        for field, _ in pairs(RLBodyConditionConfig.DEFAULTS) do
            if sent[field] ~= nil then section[field] = sent[field] end
        end
        for field, default in pairs(RLBodyConditionConfig.SPECIES_DEFAULTS) do section[field] = sent[field] or default end
        section.curves = {}
        for curveName, points in pairs(config.curves) do section.curves[curveName] = (sent.curves or {})[curveName] or points end
        section.fatClasses = sent.fatClasses or {}
        section.enabled = config.enabled
        local sectionOk, sectionReason = RLBodyConditionConfig.validate(section)
        if sectionOk then sectionOk, sectionReason = RLBodyConditionConfig.validateSpecies(section) end
        if not sectionOk then section.enabled, section.invalidReason = false, sectionReason end
        config.species[name] = section
    end

    RLBodyConditionConfig.config = config
    Log:info("RLBodyConditionConfig: using the server's config (enabled=%s)", tostring(config.enabled))
end
