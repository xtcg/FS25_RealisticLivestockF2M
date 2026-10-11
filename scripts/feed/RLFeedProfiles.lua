--[[
    RLFeedProfiles.lua
    Reads and checks xml/feedProfiles.xml (or the copy in the mod's modSettings folder): the
    real-equivalent mode's resource scale and month length, requirement and intake coefficients,
    ration rules, the milk bridge and one profile per feed fill type.

    A root value that fails a check leaves the config invalid (the mode cannot run) and logs why.
    A feed whose own values fail is kept as invalid, with its reason: it is never eaten in the
    real-equivalent mode and is listed as such. Nothing is clamped into range silently.
]]

RLFeedProfiles = {}

local Log = RmLogging.getLogger("RLRM")

RLFeedProfiles.CONFIG_FILE = "feedProfiles.xml"

RLFeedProfiles.ROLES = { COMPLETE = true, FORAGE = true, CONCENTRATE = true, MILK = true }
RLFeedProfiles.STATUSES = { TYPICAL = true, PROXY = true, UNCONFIGURED = true }
RLFeedProfiles.STAGES = { PRE_WEANING = true, WEANING = true, WEANED = true }
RLFeedProfiles.CLASSES = { "CALF", "GROWING", "LACTATING", "DRY" }

RLFeedProfiles.ROOT = { version = 1, resourceScale = 0.125, realDaysPerPeriod = 30, stepDays = 0.25 }

RLFeedProfiles.REQUIREMENTS = {
    maintenanceMEPerKgMetabolic = 0.50, growthMEPerKgAt500 = 50, growthWeightExponent = 0.75, growthMEPerKgMin = 18,
    reserveDepositMEPerKg = 52, reserveMobilizeMEPerKg = 38, catabolismMEPerKg = 10, pregnancyFactor = 0.35,
}

-- A calf on milk (NRC 2001, the young calf): maintenance ME per kg^0.75; the energy in its gain,
-- NEg (Mcal a day) = negCoefficient x W^negWeightExponent x LWG^negGainExponent, as ME at the
-- efficiency of milk (kgMilk) or of dry feed (kgSolid); LWG its curve's gain, at least minGainKgPerDay.
RLFeedProfiles.CALF = {
    maintenanceMEPerKgMetabolic = 0.42, negCoefficient = 0.84, negWeightExponent = 0.355, negGainExponent = 1.2,
    kgMilk = 0.69, kgSolid = 0.57, minGainKgPerDay = 0.2,
}

RLFeedProfiles.INTAKE = {
    growingPerKgMetabolic = 0.105, dryPerKgMetabolic = 0.090, lactatingPerKgMetabolic = 0.0968,
    lactatingPerKgMilk = 0.372, calfSolidPerKgMetabolic = 0.105,
    ndfFillGrowing = 0.0125, ndfFillDry = 0.0115, ndfFillLactating = 0.0135, ndfFillCalf = 0.0100,
}

RLFeedProfiles.PROTEIN = {
    maintenance = 0.065, calf = 0.18, young = 0.14, growing = 0.12, finishing = 0.105, lactating = 0.16, dry = 0.10,
    youngUntilMonth = 8, growingUntilMonth = 14, lactatingAtKg = 30,
}

RLFeedProfiles.HEALTH = { extremeUnderweightRatio = 0.45, shortageBufferDays = 3 }

RLFeedProfiles.RATION = {
    wheatMaxShare = 0.30, adaptationDays = 30, adaptationMaxShare = 0.80, stepAllowance = 0.20, unadaptedUtilisation = 0.85,
}

RLFeedProfiles.CLASS_RULES = {
    CALF = { peNdfMin = 0, fermentableMax = 0.40 },
    GROWING = { peNdfMin = 0.12, fermentableMax = 0.55 },
    LACTATING = { peNdfMin = 0.20, fermentableMax = 0.35 },
    DRY = { peNdfMin = 0.20, fermentableMax = 0.25 },
}

RLFeedProfiles.MILK = { realKgPerDay = 8, meMJPerKg = 5.0 }

-- Prepared calf milk, independent of the cow's milk-output bridge above. Ten real liters a
-- day is a calibration ceiling, not a promise of intake or an absolute biological maximum.
RLFeedProfiles.CALF_MILK = { realLitersPerDay = 5, density = 1.03, dm = 0.50, sizeExponent = 0.75, nursingLitersPerDay = 10 }

-- A dam's own milk as her calf drinks it (whole milk, NRC 2001: 12.5% DM, ME 5.37 Mcal/kg DM).
RLFeedProfiles.DAM_MILK = { dm = 0.125, me = 22.5, cp = 0.25 }

--- Numeric fields of a feed profile and the range each must be in.
RLFeedProfiles.FEED_SHARES = { "dm", "cp", "ndf", "peFactor", "starch", "sugar" }


local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end


local function readGroup(xmlFile, path, defaults)
    local values = table.clone(defaults)
    if xmlFile ~= nil then
        for key, default in pairs(defaults) do values[key] = xmlFile:getFloat(path .. "#" .. key, default) end
    end
    return values
end


--- Read one feed element.
--- @return table profile
function RLFeedProfiles.parseFeed(xmlFile, key)
    local profile = {
        name = (xmlFile:getString(key .. "#fillType") or ""):upper(),
        role = (xmlFile:getString(key .. "#role") or ""):upper(),
        status = (xmlFile:getString(key .. "#status") or "UNCONFIGURED"):upper(),
        form = xmlFile:getString(key .. "#form", ""),
        source = xmlFile:getString(key .. "#source", ""),
        year = xmlFile:getInt(key .. "#year", 0),
        meBasis = (xmlFile:getString(key .. "#meBasis") or ""):upper(),
        density = xmlFile:getFloat(key .. "#density"),
        tdn = xmlFile:getFloat(key .. "#tdn"),
        maxShare = xmlFile:getFloat(key .. "#maxShare"),
        capGroup = xmlFile:getString(key .. "#capGroup") ~= nil and xmlFile:getString(key .. "#capGroup"):upper() or nil,
        stages = {},
    }
    for _, field in ipairs(RLFeedProfiles.FEED_SHARES) do profile[field] = xmlFile:getFloat(key .. "#" .. field) end
    if profile.meBasis == "ME_DIRECT" then
        profile.me = xmlFile:getFloat(key .. "#me")
    elseif profile.meBasis == "TDN_NRC2000" and finite(profile.tdn) then
        profile.me = RLFeedUnits.getMEFromTDN(profile.tdn)
    end
    for stage in (xmlFile:getString(key .. "#stages") or ""):gmatch("%S+") do profile.stages[stage:upper()] = true end
    return profile
end


--- Check a feed profile, and fill its derived values (physically effective NDF, fermentable
--- carbohydrate). An UNCONFIGURED feed is not checked: it is never eaten.
--- @param profile table
--- @return boolean ok
--- @return string|nil reason
function RLFeedProfiles.validateFeed(profile)
    if profile.name == "" then return false, "a feed has no fillType" end
    if not RLFeedProfiles.ROLES[profile.role] then return false, "role must be COMPLETE, FORAGE, CONCENTRATE or MILK" end
    if not RLFeedProfiles.STATUSES[profile.status] then return false, "status must be TYPICAL, PROXY or UNCONFIGURED" end
    if profile.status == "UNCONFIGURED" then return false, "no nutrition data (UNCONFIGURED)" end
    if not finite(profile.density) or profile.density <= 0 then return false, "density must be a number > 0" end
    if not finite(profile.dm) or profile.dm <= 0 or profile.dm > 1 then return false, "dm must be in (0, 1]" end
    for _, field in ipairs(RLFeedProfiles.FEED_SHARES) do
        local value = profile[field]
        if not finite(value) or value < 0 or value > 1 then return false, field .. " must be a share in 0..1" end
    end
    if profile.meBasis ~= "TDN_NRC2000" and profile.meBasis ~= "ME_DIRECT" then
        return false, "meBasis must be TDN_NRC2000 or ME_DIRECT"
    end
    if profile.meBasis == "TDN_NRC2000" and (not finite(profile.tdn) or profile.tdn <= 0 or profile.tdn > 100) then
        return false, "tdn must be in (0, 100]"
    end
    if not finite(profile.me) or profile.me <= 0 or profile.me > 30 then return false, "ME must be in (0, 30] MJ/kg DM" end
    if profile.starch + profile.sugar > 1 then return false, "starch + sugar must not exceed 1" end
    if next(profile.stages) == nil then return false, "stages is empty" end
    for stage in pairs(profile.stages) do
        if not RLFeedProfiles.STAGES[stage] then return false, "unknown stage " .. stage end
    end
    if profile.role == "MILK" and profile.stages.WEANED then return false, "milk cannot be fed after weaning" end
    if profile.maxShare ~= nil and (not finite(profile.maxShare) or profile.maxShare <= 0 or profile.maxShare > 1) then
        return false, "maxShare must be a share in (0, 1]"
    end
    if profile.capGroup ~= nil and profile.maxShare == nil then return false, "capGroup needs a maxShare" end
    profile.peNdf = profile.ndf * profile.peFactor
    profile.fermentable = profile.starch + profile.sugar
    return true
end


--- Check the root, requirement, intake, protein and ration values.
--- @return boolean ok
--- @return string|nil reason
function RLFeedProfiles.validate(config)
    local function positive(group, name)
        for key, value in pairs(group) do
            if not finite(value) or value <= 0 then return string.format("%s %s must be a number > 0 (got %s)", name, key, tostring(value)) end
        end
    end
    if not finite(config.resourceScale) or config.resourceScale <= 0 or config.resourceScale > 1 then
        return false, "resourceScale must be in (0, 1]"
    end
    if not finite(config.realDaysPerPeriod) or config.realDaysPerPeriod <= 0 then return false, "realDaysPerPeriod must be > 0" end
    if not finite(config.stepDays) or config.stepDays <= 0 or config.stepDays > config.realDaysPerPeriod then
        return false, "stepDays must be in (0, realDaysPerPeriod]"
    end
    local reason = positive(config.requirements, "requirements") or positive(config.intake, "intake")
        or positive(config.ration, "ration") or positive(config.health, "health")
        or positive(config.calfMilk, "calfMilk") or positive(config.calf, "calf") or positive(config.damMilk, "damMilk")
    if reason ~= nil then return false, reason end
    if config.calfMilk.dm > 1 then return false, "calfMilk dm must be in (0, 1]" end
    local req = config.requirements
    local calf = config.calf
    if calf.maintenanceMEPerKgMetabolic > req.maintenanceMEPerKgMetabolic then
        return false, "calf maintenanceMEPerKgMetabolic must not exceed requirements maintenanceMEPerKgMetabolic"
    end
    if calf.kgMilk > 1 or calf.kgSolid > 1 then return false, "calf kgMilk and kgSolid must be efficiencies in (0, 1]" end
    if config.calfMilk.sizeExponent > 1 then return false, "calfMilk sizeExponent must be in (0, 1]" end
    if config.damMilk.dm > 1 or config.damMilk.cp >= 1 or config.damMilk.me > 30 then
        return false, "damMilk dm and cp must be shares, me at most 30 MJ/kg DM"
    end
    if not (req.reserveDepositMEPerKg > req.reserveMobilizeMEPerKg) then
        return false, "reserveDepositMEPerKg must exceed reserveMobilizeMEPerKg, or the reserve could be cycled into energy"
    end
    for key, value in pairs(config.protein) do
        if not finite(value) or value < 0 then return false, "protein " .. key .. " must be a number >= 0" end
    end
    local p = config.protein
    for _, key in ipairs({ "calf", "young", "growing", "finishing", "lactating", "dry" }) do
        if not (p[key] > p.maintenance and p[key] < 1) then return false, "protein " .. key .. " must lie between maintenance and 1" end
    end
    local r = config.ration
    for _, key in ipairs({ "wheatMaxShare", "adaptationMaxShare", "stepAllowance", "unadaptedUtilisation" }) do
        if r[key] > 1 then return false, "ration " .. key .. " must be a share <= 1" end
    end
    if config.health.extremeUnderweightRatio >= 1 then return false, "health extremeUnderweightRatio must be < 1" end
    for _, class in ipairs(RLFeedProfiles.CLASSES) do
        local rules = config.classes[class]
        if rules == nil then return false, "ration class " .. class .. " missing" end
        if not finite(rules.peNdfMin) or rules.peNdfMin < 0 or rules.peNdfMin >= 1 then return false, class .. " peNdfMin must be in 0..1" end
        if not finite(rules.fermentableMax) or rules.fermentableMax <= 0 or rules.fermentableMax > 1 then
            return false, class .. " fermentableMax must be in (0, 1]"
        end
    end
    local milk = config.milk
    if not finite(milk.realKgPerDay) or milk.realKgPerDay <= 0 or not finite(milk.meMJPerKg) or milk.meMJPerKg <= 0 then
        return false, "milk realKgPerDay and meMJPerKg must be > 0"
    end
    for name, breed in pairs(milk.breeds) do
        if not finite(breed.realKgPerDay) or breed.realKgPerDay <= 0 or not finite(breed.meMJPerKg) or breed.meMJPerKg <= 0 then
            return false, "milk breed " .. name .. " needs realKgPerDay and meMJPerKg > 0"
        end
    end
    local usable = 0
    for _, profile in pairs(config.feeds) do
        if profile.valid then usable = usable + 1 end
    end
    if usable == 0 then return false, "no usable feed profile" end
    return true
end


--- Read a config.
--- @param xmlFile table|nil XMLFile with a feedProfiles root; nil leaves the config invalid
--- @return table config
function RLFeedProfiles.parse(xmlFile)
    local config = readGroup(xmlFile, "feedProfiles", RLFeedProfiles.ROOT)
    config.requirements = readGroup(xmlFile, "feedProfiles.requirements", RLFeedProfiles.REQUIREMENTS)
    config.intake = readGroup(xmlFile, "feedProfiles.intake", RLFeedProfiles.INTAKE)
    config.protein = readGroup(xmlFile, "feedProfiles.protein", RLFeedProfiles.PROTEIN)
    config.health = readGroup(xmlFile, "feedProfiles.health", RLFeedProfiles.HEALTH)
    config.ration = readGroup(xmlFile, "feedProfiles.ration", RLFeedProfiles.RATION)
    config.classes = {}
    for class, rules in pairs(RLFeedProfiles.CLASS_RULES) do config.classes[class] = table.clone(rules) end
    config.milk = readGroup(xmlFile, "feedProfiles.milk", RLFeedProfiles.MILK)
    config.calfMilk = readGroup(xmlFile, "feedProfiles.calfMilk", RLFeedProfiles.CALF_MILK)
    config.calf = readGroup(xmlFile, "feedProfiles.calf", RLFeedProfiles.CALF)
    config.damMilk = readGroup(xmlFile, "feedProfiles.damMilk", RLFeedProfiles.DAM_MILK)
    config.milk.breeds = {}
    config.feeds, config.feedOrder = {}, {}

    if xmlFile == nil then
        config.valid, config.invalidReason = false, "feedProfiles.xml not found"
        config.hash = RLFeedProfiles.computeHash(config)
        return config
    end

    xmlFile:iterate("feedProfiles.ration.class", function(_, key)
        local name = (xmlFile:getString(key .. "#name") or ""):upper()
        local rules = config.classes[name]
        if rules == nil then
            Log:warning("RLFeedProfiles: unknown ration class '%s' ignored", name)
            return
        end
        rules.peNdfMin = xmlFile:getFloat(key .. "#peNdfMin", rules.peNdfMin)
        rules.fermentableMax = xmlFile:getFloat(key .. "#fermentableMax", rules.fermentableMax)
    end)

    xmlFile:iterate("feedProfiles.milk.breed", function(_, key)
        local name = (xmlFile:getString(key .. "#name") or ""):upper()
        if name == "" then return end
        config.milk.breeds[name] = {
            realKgPerDay = xmlFile:getFloat(key .. "#realKgPerDay", config.milk.realKgPerDay),
            meMJPerKg = xmlFile:getFloat(key .. "#meMJPerKg", config.milk.meMJPerKg),
        }
    end)

    xmlFile:iterate("feedProfiles.feed", function(_, key)
        local profile = RLFeedProfiles.parseFeed(xmlFile, key)
        if config.feeds[profile.name] ~= nil then
            Log:warning("RLFeedProfiles: fill type %s listed twice; the first is kept", profile.name)
            return
        end
        local ok, reason = RLFeedProfiles.validateFeed(profile)
        profile.valid, profile.invalidReason = ok, reason
        if not ok and profile.status ~= "UNCONFIGURED" then
            Log:warning("RLFeedProfiles: feed %s is not used: %s", profile.name, tostring(reason))
        end
        if profile.name ~= "" then
            config.feeds[profile.name] = profile
            table.insert(config.feedOrder, profile.name)
        end
    end)

    -- Wheat's cap is the ration's wheatMaxShare unless its own profile sets one.
    local wheat = config.feeds.WHEAT
    if wheat ~= nil and wheat.valid and wheat.maxShare == nil then wheat.maxShare = config.ration.wheatMaxShare end

    local ok, reason = RLFeedProfiles.validate(config)
    config.valid = ok
    config.invalidReason = reason
    if not ok then Log:error("RLFeedProfiles: %s - the real-equivalent nutrition mode cannot run", reason) end
    config.hash = RLFeedProfiles.computeHash(config)
    return config
end


--- A short fingerprint of the effective values (saved with monthly records, shown in reports): a
--- 32-bit djb2 of every number and name in a fixed order, as 8 hex digits.
--- @param config table
--- @return string
function RLFeedProfiles.computeHash(config)
    local parts = {}
    local function add(key, value)
        if type(value) == "number" then value = string.format("%.6g", value) end
        parts[#parts + 1] = key .. "=" .. tostring(value)
    end
    local function addGroup(name, group)
        local keys = {}
        for key, value in pairs(group or {}) do if type(value) ~= "table" then keys[#keys + 1] = key end end
        table.sort(keys)
        for _, key in ipairs(keys) do add(name .. "." .. key, group[key]) end
    end
    add("version", config.version)
    add("resourceScale", config.resourceScale)
    add("realDaysPerPeriod", config.realDaysPerPeriod)
    add("stepDays", config.stepDays)
    addGroup("req", config.requirements)
    addGroup("intake", config.intake)
    addGroup("protein", config.protein)
    addGroup("ration", config.ration)
    addGroup("health", config.health)
    for _, class in ipairs(RLFeedProfiles.CLASSES) do addGroup("class." .. class, config.classes[class]) end
    addGroup("milk", config.milk)
    addGroup("calfMilk", config.calfMilk)
    addGroup("calf", config.calf)
    addGroup("damMilk", config.damMilk)
    local breeds = {}
    for name in pairs(config.milk.breeds or {}) do breeds[#breeds + 1] = name end
    table.sort(breeds)
    for _, name in ipairs(breeds) do addGroup("milk." .. name, config.milk.breeds[name]) end
    local feeds = {}
    for name in pairs(config.feeds or {}) do feeds[#feeds + 1] = name end
    table.sort(feeds)
    for _, name in ipairs(feeds) do
        local profile = config.feeds[name]
        add("feed." .. name .. ".valid", profile.valid)
        if profile.valid then
            for _, field in ipairs({ "role", "density", "dm", "me", "cp", "ndf", "peFactor", "starch", "sugar", "maxShare", "capGroup" }) do
                add("feed." .. name .. "." .. field, profile[field])
            end
            local stages = {}
            for stage in pairs(profile.stages) do stages[#stages + 1] = stage end
            table.sort(stages)
            add("feed." .. name .. ".stages", table.concat(stages, " "))
        end
    end
    local hash = 5381
    local text = table.concat(parts, ";")
    for i = 1, #text do hash = (hash * 33 + text:byte(i)) % 4294967296 end
    -- Two 16-bit halves: %x of a number past 2^31 is not safe in every Lua 5.1 build.
    return string.format("%04x%04x", math.floor(hash / 65536), hash % 65536)
end


--- The config, loaded on the first call.
function RLFeedProfiles.getConfig()
    if RLFeedProfiles.config == nil then
        RLFeedProfiles.config = RLBreedTraits.loadConfig(RLFeedProfiles.CONFIG_FILE, "feedProfiles", RLFeedProfiles.parse)
        local config = RLFeedProfiles.config
        Log:info("RLFeedProfiles: version %s, scale %.3f, %s model days a month, hash %s, %s", tostring(config.version),
            config.resourceScale, tostring(config.realDaysPerPeriod), config.hash, config.valid and "valid" or ("INVALID: " .. tostring(config.invalidReason)))
    end
    return RLFeedProfiles.config
end


--- Whether the config can run the mode.
function RLFeedProfiles.isValid()
    return RLFeedProfiles.getConfig().valid == true
end


--- A fill type's profile (valid or not), or nil when the file does not list it.
--- @param name string|nil Fill type name
--- @return table|nil
function RLFeedProfiles.getFeed(name)
    if name == nil then return nil end
    return RLFeedProfiles.getConfig().feeds[name:upper()]
end


--- A usable profile of a fill type (nil when unlisted, unconfigured or invalid).
function RLFeedProfiles.getUsableFeed(name)
    local profile = RLFeedProfiles.getFeed(name)
    if profile ~= nil and profile.valid then return profile end
    return nil
end


--- Milk bridge of a weight profile (breed): real kg a day at the lactation average, ME per kg.
--- @param profileName string|nil
--- @return number realKgPerDay
--- @return number meMJPerKg
function RLFeedProfiles.getMilkBridge(profileName)
    local milk = RLFeedProfiles.getConfig().milk
    local breed = profileName ~= nil and milk.breeds[profileName:upper()] or nil
    if breed ~= nil then return breed.realKgPerDay, breed.meMJPerKg end
    return milk.realKgPerDay, milk.meMJPerKg
end
