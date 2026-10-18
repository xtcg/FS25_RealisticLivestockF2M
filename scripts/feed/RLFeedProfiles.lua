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
    youngUntilMonth = 8, growingUntilMonth = 14, lactatingAtKg = 30, milkResponse = 2,
}

RLFeedProfiles.HEALTH = { extremeUnderweightRatio = 0.45, shortageBufferDays = 3, lossPerDay = 6.4, gainPerDay = 8,
    geneticsRateEffect = 1 / 3, youngDeathMonths = 6, youngDeathHealthOffset = 10 }

--- Low-health death chance per model day by health (x: health, y: chance), linear between points,
--- flat outside; the same curve for every health gene (the gene acts on the health rates only).
RLFeedProfiles.LOW_HEALTH_DEATH = { { 0, 1 }, { 20, 0.05 }, { 40, 0.01 }, { 60, 0.001 }, { 80, 0 } }

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
RLFeedProfiles.CALF_MILK = { realLitersPerDay = 5, density = 1.03, dm = 0.50, sizeExponent = 0.75, nursingLitersPerDay = 10,
    earlyWeaningMonth = 3 }

-- A dam's own milk as her calf drinks it (whole milk, NRC 2001: 12.5% DM, ME 5.37 Mcal/kg DM).
RLFeedProfiles.DAM_MILK = { dm = 0.125, me = 22.5, cp = 0.25 }

-- Water (a game fit, not a real formula): the share of its dry intake an animal may eat at a
-- pen's water coverage - none held from fullFrom, halfIntake at halfCoverage, minIntake with no
-- water at all - reached within dropHours model hours as water runs short and given back over
-- recoveryDays model days once it is back.
RLFeedProfiles.WATER = { fullFrom = 0.9, halfCoverage = 0.5, halfIntake = 0.6, minIntake = 0.2, dropHours = 6, recoveryDays = 2 }

-- Concentrate routes (species sections only, sheep): the concentrate share (of the ration's DM) a
-- weaned male eats on AUTO, apart from what his rumen is adapted to. A ram lamb's growth route
-- (lambTarget, lambCap) to adultFromMonth, a breeding ram's maintenance route (ramTarget, ramCap)
-- from it, moving from one to the other over transitionDays model days; the share is the route's
-- target, above it only as far as his needs (maintenance, pregnancy, growth: not reserve laid
-- down freely) want, never above its cap. An explicit FINISH target or share is the intensive
-- route: at most finishingCap (the rest forage). The share he eats rises by at most
-- targetRisePerDay a model day (a route or age switch is taken up over about two weeks).
RLFeedProfiles.CONCENTRATE = { lambTarget = 0.20, lambCap = 0.40, ramTarget = 0.10, ramCap = 0.25, finishingCap = 0.80,
    adultFromMonth = 12, transitionDays = 14, targetRisePerDay = 0.05 }

-- Species sections only (<species name="SHEEP">): the root (cattle) has neither group, and
-- every reader treats a missing group as the cattle rule.
-- physiology: growthReferenceKg, the live weight growthMEPerKgAt500 is given at (500 for cattle);
-- youngMaintenanceMEPerKgMetabolic (0: none), maintenance of a young animal, used to
-- youngMaintenanceUntilMonth and moving to the adult value by adultMaintenanceFromMonth;
-- calfGrowthCost 1: a young animal on milk pays NRC 2001's calf cost (calf), 0: the growth cost
-- (under AUTO a ewe lamb eats freely as a ram lamb does: RLBodyCondition.isFinishingYoungFemale);
-- growthCostMale / Castrate / Female: the growth cost of a kg of frame by sex (an entire male's
-- gain is leaner, a female's fatter at the same weight); pregnancyThirdLambFactor: the pregnancy
-- cost of a third and every further fetus against one of the first two (1: the same).
RLFeedProfiles.PHYSIOLOGY = { growthReferenceKg = 500, youngMaintenanceMEPerKgMetabolic = 0, youngMaintenanceUntilMonth = 0,
    adultMaintenanceFromMonth = 0, calfGrowthCost = 1,
    growthCostMale = 1, growthCostCastrate = 1, growthCostFemale = 1, pregnancyThirdLambFactor = 1 }

-- nursing: young animals that drink only from their dams (sheep: no rearing pen, no trough milk).
-- The milkMax / solidMax / solidEnergy curves are read at the young animal's age (months), not
-- against a weaning month. weaningMonth: milk ends (milkMax 0 from here); earlyWeaningMonth: an
-- orphan that has eaten creep feed in earnest (readyCreepKgPerDay of concentrate as fed - fresh
-- weight, each feed's DM share converts what it ate - readyDays in a row) is weaned early, and
-- stays weaned (rlGrowth.weanedEarly); younger or not ready it lives on what it eats, with no milk
-- made for it.
-- lambMilkKgPerDay: most whole milk (kg as drunk) one young animal takes from its dam a day at
-- milkMax 1; creepMaxKgDMPerDay: most concentrate DM a young animal at foot eats a day (the
-- creep gate the game has no building for). maxSuckled: young animals a dam's milk table counts.
RLFeedProfiles.NURSING = { weaningMonth = 3, earlyWeaningMonth = 2, readyCreepKgPerDay = 0.25, readyDays = 3.5,
    lambMilkKgPerDay = 2.6, creepMaxKgDMPerDay = 0.35, maxSuckled = 2 }

RLFeedProfiles.NURSING_CURVES = { "milkMax", "solidMax", "solidEnergy" }

-- monogastric: a species without a rumen (pigs, NRC 2012 ch. 8). Its pens plan with
-- RLFeedRationPlanner.planMonogastric (every feed the animal may eat, mixed as stocked; no forage,
-- concentrate or rumen rules). maintenanceExponent: maintenance x W^this (NRC 2012 Eq. 8-19: 0.60;
-- other species 0.75). energy: the most ME (MJ a day) an animal eats freely, a x (1 - exp(-exp(b) x
-- W^c)) by sex (female, castrate, male; Eqs. 8-10 to 8-12); physicalKgDMPerKg x W^physicalExponent:
-- the most DM it can eat (Eq. 8-16, g as fed x 0.90 DM). lysine: SID lysine (g per MJ ME) a ration
-- needs for full growth, by weight (kg) and sex; lysineMaintenance the level growth falls to nothing
-- at. youngLegacyUntilMonth: a pen with a young animal under this age (continuous months: not weaned),
-- a pregnant female or one that has given birth keeps the old rules (PIG_BREEDING_LEGACY: the sow's
-- milk, pregnancy and body condition are a later batch).
RLFeedProfiles.MONOGASTRIC = { maintenanceExponent = 0.75, physicalKgDMPerKg = 0.0999, physicalExponent = 0.803,
    lysineMaintenance = 0.05, youngLegacyUntilMonth = 0 }
RLFeedProfiles.MONO_SEXES = { "female", "castrate", "male" }

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
        -- Monogastric sections only (pigs): SID lysine, share of DM; the heaviest animal (kg) that
        -- may eat the feed (piglet feed).
        sidLys = xmlFile:getFloat(key .. "#sidLys"),
        maxWeightKg = xmlFile:getFloat(key .. "#maxWeightKg"),
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
    if profile.sidLys ~= nil and (not finite(profile.sidLys) or profile.sidLys < 0 or profile.sidLys >= 0.1) then
        return false, "sidLys must be a share of DM in 0..0.1"
    end
    if profile.maxWeightKg ~= nil and (not finite(profile.maxWeightKg) or profile.maxWeightKg <= 0) then
        return false, "maxWeightKg must be > 0"
    end
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
        or positive(config.water, "water")
    if reason ~= nil then return false, reason end
    local w = config.water
    if not (w.fullFrom <= 1 and w.halfCoverage < w.fullFrom and w.minIntake < w.halfIntake and w.halfIntake < 1) then
        return false, "water needs halfCoverage < fullFrom <= 1 and minIntake < halfIntake < 1"
    end
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
    if p.milkResponse < 1 or p.milkResponse > 4 then return false, "protein milkResponse must be in 1..4" end
    for _, key in ipairs({ "calf", "young", "growing", "finishing", "lactating", "dry" }) do
        if not (p[key] > p.maintenance and p[key] < 1) then return false, "protein " .. key .. " must lie between maintenance and 1" end
    end
    local r = config.ration
    for _, key in ipairs({ "wheatMaxShare", "adaptationMaxShare", "stepAllowance", "unadaptedUtilisation" }) do
        if r[key] > 1 then return false, "ration " .. key .. " must be a share <= 1" end
    end
    if config.health.extremeUnderweightRatio >= 1 then return false, "health extremeUnderweightRatio must be < 1" end
    if config.health.geneticsRateEffect >= 1 then return false, "health geneticsRateEffect must be < 1, or a gene could stop health changing" end
    local death = config.lowHealthDeath
    if death == nil or #death < 2 then return false, "health lowHealthDeath needs at least two points" end
    for i, point in ipairs(death) do
        if not finite(point[1]) or not finite(point[2]) or point[2] < 0 or point[2] > 1 then
            return false, "health lowHealthDeath points need a health and a daily chance in 0..1"
        end
        if i > 1 and (point[1] <= death[i - 1][1] or point[2] > death[i - 1][2]) then
            return false, "health lowHealthDeath must rise in health and never rise in chance"
        end
    end
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
        if not finite(breed.intakeFactor) or breed.intakeFactor < 0.5 or breed.intakeFactor > 2 then
            return false, "milk breed " .. name .. " intakeFactor must be in 0.5..2"
        end
    end
    local usable = 0
    for _, profile in pairs(config.feeds) do
        if profile.valid then usable = usable + 1 end
    end
    if usable == 0 then return false, "no usable feed profile" end
    return true
end


--- Points of a curve element (x, y), or nil when it has none.
local function readCurve(xmlFile, path)
    local points = {}
    xmlFile:iterate(path .. ".point", function(_, key)
        local x, y = xmlFile:getFloat(key .. "#x"), xmlFile:getFloat(key .. "#y")
        if x ~= nil and y ~= nil then points[#points + 1] = { x, y } end
    end)
    return #points > 0 and points or nil
end


--- Check a species section's own groups (physiology, nursing).
--- @return boolean ok
--- @return string|nil reason
function RLFeedProfiles.validateSpecies(section)
    local p = section.physiology
    if p ~= nil then
        for key, value in pairs(p) do
            if not finite(value) or value < 0 then return false, "physiology " .. key .. " must be a number >= 0" end
        end
        if p.growthReferenceKg <= 0 then return false, "physiology growthReferenceKg must be > 0" end
        if p.youngMaintenanceMEPerKgMetabolic > 0 and p.adultMaintenanceFromMonth < p.youngMaintenanceUntilMonth then
            return false, "physiology adultMaintenanceFromMonth must not be before youngMaintenanceUntilMonth"
        end
    end
    local route = section.concentrate
    if route ~= nil then
        for key, value in pairs(route) do
            if not finite(value) or value < 0 then return false, "concentrate " .. key .. " must be a number >= 0" end
        end
        for _, key in ipairs({ "lambTarget", "lambCap", "ramTarget", "ramCap", "finishingCap", "targetRisePerDay" }) do
            if route[key] > 1 then return false, "concentrate " .. key .. " must be a share <= 1" end
        end
        if route.lambTarget > route.lambCap or route.ramTarget > route.ramCap then
            return false, "concentrate targets must not exceed their caps"
        end
        if route.transitionDays <= 0 or route.targetRisePerDay <= 0 then
            return false, "concentrate transitionDays and targetRisePerDay must be > 0"
        end
    end
    local m = section.monogastric
    if m ~= nil then
        for key, value in pairs(m) do
            if type(value) == "number" and (not finite(value) or value < 0) then return false, "monogastric " .. key .. " must be a number >= 0" end
        end
        if m.maintenanceExponent <= 0 or m.maintenanceExponent > 1 then return false, "monogastric maintenanceExponent must be in (0, 1]" end
        if m.physicalKgDMPerKg <= 0 or m.physicalExponent <= 0 then return false, "monogastric physical intake must be > 0" end
        for _, sex in ipairs(RLFeedProfiles.MONO_SEXES) do
            local e = m.energy[sex]
            if e == nil or not finite(e.a) or not finite(e.b) or not finite(e.c) or e.a <= 0 or e.c <= 0 then
                return false, "monogastric energy for " .. sex .. " needs a > 0, b and c > 0"
            end
            local points = m.lysine[sex] or m.lysine.all
            if points == nil or #points == 0 then return false, "monogastric lysine for " .. sex .. " has no points" end
            for i, point in ipairs(points) do
                if not finite(point[1]) or not finite(point[2]) or point[2] <= m.lysineMaintenance then
                    return false, string.format("monogastric lysine %s point %d must be above lysineMaintenance", sex, i)
                end
                if i > 1 and point[1] <= points[i - 1][1] then return false, "monogastric lysine " .. sex .. " must rise in weight" end
            end
        end
        for feedName in pairs(section.ownFeeds or {}) do
            local profile = section.feeds[feedName]
            if profile.valid and profile.sidLys == nil then return false, "monogastric feed " .. feedName .. " needs sidLys" end
        end
    end
    local n = section.nursing
    if n ~= nil then
        for key, value in pairs(n) do
            if type(value) == "number" and (not finite(value) or value < 0) then return false, "nursing " .. key .. " must be a number >= 0" end
        end
        if n.weaningMonth <= 0 or n.earlyWeaningMonth > n.weaningMonth then
            return false, "nursing needs weaningMonth > 0 and earlyWeaningMonth <= weaningMonth"
        end
        if n.readyDays <= 0 or n.readyCreepKgPerDay <= 0 or n.lambMilkKgPerDay <= 0 or n.maxSuckled < 1 then
            return false, "nursing readyDays, readyCreepKgPerDay, lambMilkKgPerDay must be > 0 and maxSuckled >= 1"
        end
        for _, name in ipairs(RLFeedProfiles.NURSING_CURVES) do
            local points = n.curves[name]
            if points == nil or #points == 0 then return false, "nursing curve " .. name .. " has no points" end
            for i, point in ipairs(points) do
                if not finite(point[1]) or not finite(point[2]) or point[2] < 0 or point[2] > 1 then
                    return false, string.format("nursing curve %s point %d must have y in 0..1", name, i)
                end
                if i > 1 and point[1] < points[i - 1][1] then return false, "nursing curve " .. name .. " is not sorted by x" end
            end
        end
        if RLFeedProfiles.interpolate(n.curves.milkMax, n.weaningMonth) > 0 then return false, "nursing milkMax must be 0 at weaningMonth" end
        if RLFeedProfiles.interpolate(n.curves.solidMax, n.weaningMonth) < 1 then return false, "nursing solidMax must reach 1 at weaningMonth" end
        if RLFeedProfiles.interpolate(n.curves.solidEnergy, n.weaningMonth) < 1 then return false, "nursing solidEnergy must reach 1 at weaningMonth" end
        local lactation = n.lactation
        if lactation == nil or next(lactation.systems) == nil then return false, "nursing has no lactation system" end
        for name, system in pairs(lactation.systems) do
            for _, row in ipairs({ "single", "twin" }) do
                local months = system[row]
                if months == nil or #months == 0 then return false, "lactation system " .. name .. " needs " .. row end
                for _, kg in ipairs(months) do
                    if not finite(kg) or kg < 0 then return false, "lactation system " .. name .. " " .. row .. " must be kg >= 0" end
                end
            end
        end
        if lactation.systems[lactation.default] == nil then return false, "lactation default system " .. tostring(lactation.default) .. " is not listed" end
        for breed, system in pairs(lactation.breeds) do
            if lactation.systems[system] == nil then return false, "lactation breed " .. breed .. " names an unknown system " .. system end
        end
    end
    return true
end


--- Linear between points, flat outside.
function RLFeedProfiles.interpolate(points, x)
    if x <= points[1][1] then return points[1][2] end
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if x <= b[1] then
            if b[1] == a[1] then return b[2] end
            return a[2] + (b[2] - a[2]) * (x - a[1]) / (b[1] - a[1])
        end
    end
    return points[#points][2]
end


--- Read the species sections: each is the root config with the groups its element sets replaced
--- (the root's values where it leaves one out), plus its own physiology and nursing. Feeds are
--- the root's. A section that fails a check is kept invalid (its species cannot run the mode);
--- the root is never changed by one.
local function parseSpecies(xmlFile, config)
    config.species = {}
    xmlFile:iterate("feedProfiles.species", function(_, key)
        local name = (xmlFile:getString(key .. "#name") or ""):upper()
        if name == "" or config.species[name] ~= nil then
            Log:warning("RLFeedProfiles: a species section without a name, or listed twice (%s), is ignored", name)
            return
        end
        local section = {}
        for field, value in pairs(config) do
            if field ~= "species" then section[field] = value end
        end
        section.speciesName = name
        section.requirements = readGroup(xmlFile, key .. ".requirements", config.requirements)
        section.intake = readGroup(xmlFile, key .. ".intake", config.intake)
        section.protein = readGroup(xmlFile, key .. ".protein", config.protein)
        section.health = readGroup(xmlFile, key .. ".health", config.health)
        section.lowHealthDeath = readCurve(xmlFile, key .. ".health.lowHealthDeath") or config.lowHealthDeath
        section.ration = readGroup(xmlFile, key .. ".ration", config.ration)
        section.calfMilk = readGroup(xmlFile, key .. ".calfMilk", config.calfMilk)
        section.calf = readGroup(xmlFile, key .. ".calf", config.calf)
        section.damMilk = readGroup(xmlFile, key .. ".damMilk", config.damMilk)
        section.water = readGroup(xmlFile, key .. ".water", config.water)
        if xmlFile:getString(key .. ".concentrate#lambCap") ~= nil then
            section.concentrate = readGroup(xmlFile, key .. ".concentrate", RLFeedProfiles.CONCENTRATE)
        end
        local breeds = config.milk.breeds
        section.milk = readGroup(xmlFile, key .. ".milk", { realKgPerDay = config.milk.realKgPerDay, meMJPerKg = config.milk.meMJPerKg })
        section.milk.breeds = breeds
        section.classes = {}
        for class, rules in pairs(config.classes) do section.classes[class] = table.clone(rules) end
        xmlFile:iterate(key .. ".ration.class", function(_, classKey)
            local rules = section.classes[(xmlFile:getString(classKey .. "#name") or ""):upper()]
            if rules == nil then return end
            rules.peNdfMin = xmlFile:getFloat(classKey .. "#peNdfMin", rules.peNdfMin)
            rules.fermentableMax = xmlFile:getFloat(classKey .. "#fermentableMax", rules.fermentableMax)
        end)
        section.physiology = readGroup(xmlFile, key .. ".physiology", RLFeedProfiles.PHYSIOLOGY)
        if xmlFile:getString(key .. ".nursing#weaningMonth") ~= nil then
            local nursing = readGroup(xmlFile, key .. ".nursing", RLFeedProfiles.NURSING)
            nursing.curves = {}
            for _, curveName in ipairs(RLFeedProfiles.NURSING_CURVES) do
                nursing.curves[curveName] = readCurve(xmlFile, key .. ".nursing." .. curveName)
            end
            local lactation = { systems = {}, breeds = {},
                default = (xmlFile:getString(key .. ".nursing.lactation#default") or ""):upper() }
            xmlFile:iterate(key .. ".nursing.lactation.system", function(_, systemKey)
                local systemName = (xmlFile:getString(systemKey .. "#name") or ""):upper()
                local system = {}
                for _, row in ipairs({ "single", "twin" }) do
                    system[row] = {}
                    for value in (xmlFile:getString(systemKey .. "#" .. row) or ""):gmatch("%S+") do
                        system[row][#system[row] + 1] = tonumber(value) or (0 / 0)
                    end
                end
                if systemName ~= "" then lactation.systems[systemName] = system end
            end)
            xmlFile:iterate(key .. ".nursing.lactation.breed", function(_, breedKey)
                local breed = (xmlFile:getString(breedKey .. "#name") or ""):upper()
                if breed ~= "" then lactation.breeds[breed] = (xmlFile:getString(breedKey .. "#system") or ""):upper() end
            end)
            nursing.lactation = lactation
            section.nursing = nursing
        end
        if xmlFile:getString(key .. ".monogastric#maintenanceExponent") ~= nil then
            local mono = readGroup(xmlFile, key .. ".monogastric", RLFeedProfiles.MONOGASTRIC)
            mono.energy, mono.lysine = {}, {}
            xmlFile:iterate(key .. ".monogastric.energy", function(_, energyKey)
                local sex = (xmlFile:getString(energyKey .. "#sex") or ""):lower()
                mono.energy[sex] = { a = xmlFile:getFloat(energyKey .. "#a"), b = xmlFile:getFloat(energyKey .. "#b"),
                    c = xmlFile:getFloat(energyKey .. "#c") }
            end)
            xmlFile:iterate(key .. ".monogastric.lysine", function(_, lysineKey)
                local sex = (xmlFile:getString(lysineKey .. "#sex") or ""):lower()
                local points = {}
                for pair in (xmlFile:getString(lysineKey .. "#points") or ""):gmatch("%S+") do
                    local x, y = pair:match("^([%d%.]+):([%d%.]+)$")
                    points[#points + 1] = { tonumber(x) or (0 / 0), tonumber(y) or (0 / 0) }
                end
                mono.lysine[sex] = points
            end)
            section.monogastric = mono
        end
        -- Feeds a section values for itself (pigs: pig ME and SID lysine), in place of the root's.
        local ownFeeds = nil
        xmlFile:iterate(key .. ".feed", function(_, feedKey)
            local profile = RLFeedProfiles.parseFeed(xmlFile, feedKey)
            if ownFeeds == nil then
                ownFeeds = {}
                section.feeds, section.feedOrder = {}, {}
                for feedName, rootProfile in pairs(config.feeds) do section.feeds[feedName] = rootProfile end
                for _, feedName in ipairs(config.feedOrder) do section.feedOrder[#section.feedOrder + 1] = feedName end
            end
            if profile.name == "" or ownFeeds[profile.name] then
                Log:warning("RLFeedProfiles: species %s: feed %s listed twice or without a fillType; the first is kept", name, profile.name)
                return
            end
            ownFeeds[profile.name] = true
            local feedOk, feedReason = RLFeedProfiles.validateFeed(profile)
            profile.valid, profile.invalidReason = feedOk, feedReason
            if not feedOk and profile.status ~= "UNCONFIGURED" then
                Log:warning("RLFeedProfiles: species %s: feed %s is not used: %s", name, profile.name, tostring(feedReason))
            end
            if section.feeds[profile.name] == nil then section.feedOrder[#section.feedOrder + 1] = profile.name end
            section.feeds[profile.name] = profile
        end)
        section.ownFeeds = ownFeeds
        local ok, reason = RLFeedProfiles.validate(section)
        if ok then ok, reason = RLFeedProfiles.validateSpecies(section) end
        section.valid, section.invalidReason = ok, reason
        if not ok then Log:error("RLFeedProfiles: species %s: %s - its animals cannot run the real-equivalent nutrition mode", name, tostring(reason)) end
        section.hash = RLFeedProfiles.computeHash(section)
        config.species[name] = section
    end)
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
    config.lowHealthDeath = xmlFile ~= nil and readCurve(xmlFile, "feedProfiles.health.lowHealthDeath") or nil
    if config.lowHealthDeath == nil then
        config.lowHealthDeath = {}
        for i, point in ipairs(RLFeedProfiles.LOW_HEALTH_DEATH) do config.lowHealthDeath[i] = { point[1], point[2] } end
    end
    config.ration = readGroup(xmlFile, "feedProfiles.ration", RLFeedProfiles.RATION)
    config.classes = {}
    for class, rules in pairs(RLFeedProfiles.CLASS_RULES) do config.classes[class] = table.clone(rules) end
    config.milk = readGroup(xmlFile, "feedProfiles.milk", RLFeedProfiles.MILK)
    config.calfMilk = readGroup(xmlFile, "feedProfiles.calfMilk", RLFeedProfiles.CALF_MILK)
    config.calf = readGroup(xmlFile, "feedProfiles.calf", RLFeedProfiles.CALF)
    config.damMilk = readGroup(xmlFile, "feedProfiles.damMilk", RLFeedProfiles.DAM_MILK)
    config.water = readGroup(xmlFile, "feedProfiles.water", RLFeedProfiles.WATER)
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
            intakeFactor = xmlFile:getFloat(key .. "#intakeFactor", 1),
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
    -- After the root is complete (its hash too): a section copies the finished root.
    parseSpecies(xmlFile, config)
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
    for i, point in ipairs(config.lowHealthDeath or {}) do add("health.lowHealthDeath." .. i, point[1] .. ":" .. point[2]) end
    for _, class in ipairs(RLFeedProfiles.CLASSES) do addGroup("class." .. class, config.classes[class]) end
    addGroup("milk", config.milk)
    addGroup("calfMilk", config.calfMilk)
    addGroup("calf", config.calf)
    addGroup("damMilk", config.damMilk)
    addGroup("water", config.water)
    -- A species section's own groups (the root has none: its fingerprint is as before).
    if config.speciesName ~= nil then
        add("species", config.speciesName)
        addGroup("physiology", config.physiology)
        if config.concentrate ~= nil then addGroup("concentrate", config.concentrate) end
        local mono = config.monogastric
        if mono ~= nil then
            addGroup("mono", mono)
            for _, sex in ipairs(RLFeedProfiles.MONO_SEXES) do
                local e = mono.energy[sex] or {}
                add("mono.energy." .. sex, tostring(e.a) .. ":" .. tostring(e.b) .. ":" .. tostring(e.c))
                for i, point in ipairs(mono.lysine[sex] or mono.lysine.all or {}) do add("mono.lysine." .. sex .. "." .. i, point[1] .. ":" .. point[2]) end
            end
        end
        local nursing = config.nursing
        if nursing ~= nil then
            addGroup("nursing", nursing)
            for _, name in ipairs(RLFeedProfiles.NURSING_CURVES) do
                for i, point in ipairs(nursing.curves[name] or {}) do add("nursing." .. name .. "." .. i, point[1] .. ":" .. point[2]) end
            end
            local lactation = nursing.lactation or { systems = {}, breeds = {} }
            add("lactation.default", lactation.default)
            local names = {}
            for systemName in pairs(lactation.systems) do names[#names + 1] = systemName end
            table.sort(names)
            for _, systemName in ipairs(names) do
                local system = lactation.systems[systemName]
                add("lactation." .. systemName .. ".single", table.concat(system.single or {}, " "))
                add("lactation." .. systemName .. ".twin", table.concat(system.twin or {}, " "))
            end
            local breedNames = {}
            for breed in pairs(lactation.breeds) do breedNames[#breedNames + 1] = breed end
            table.sort(breedNames)
            for _, breed in ipairs(breedNames) do add("lactation.breed." .. breed, lactation.breeds[breed]) end
        end
    end
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
            -- Monogastric fields only where a feed has them (the root's fingerprint is as before).
            if profile.sidLys ~= nil then add("feed." .. name .. ".sidLys", profile.sidLys) end
            if profile.maxWeightKg ~= nil then add("feed." .. name .. ".maxWeightKg", profile.maxWeightKg) end
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


--- The config an animal, pen, subtype or type name reads: its species section, else the root.
--- @param subject any
--- @return table
function RLFeedProfiles.getConfigFor(subject)
    return RLSpecies.select(RLFeedProfiles.getConfig(), subject)
end


--- Whether the config can run the mode (for a subject: its species section too).
function RLFeedProfiles.isValid(subject)
    local config = RLFeedProfiles.getConfig()
    if config.valid ~= true then return false end
    if subject == nil then return true end
    return RLSpecies.select(config, subject).valid == true
end


--- A fill type's profile (valid or not), or nil when the file does not list it.
--- @param name string|nil Fill type name
--- @return table|nil
function RLFeedProfiles.getFeed(name)
    if name == nil then return nil end
    return RLFeedProfiles.getConfig().feeds[name:upper()]
end


--- A usable profile of a fill type (nil when unlisted, unconfigured or invalid).
--- @param name string|nil
--- @param config table|nil A species section with feeds of its own (pigs); the root's by default
function RLFeedProfiles.getUsableFeed(name, config)
    local profile
    if config ~= nil and config.feeds ~= nil then
        profile = name ~= nil and config.feeds[name:upper()] or nil
    else
        profile = RLFeedProfiles.getFeed(name)
    end
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


--- A breed's intake capacity for its cows (lactating and dry) against the Holstein-based
--- equations: appetite and rumen fill both x this (Jerseys eat more per kg of live weight).
--- @param profileName string|nil
--- @return number factor (1 without an entry)
function RLFeedProfiles.getCowIntakeFactor(profileName)
    local breed = profileName ~= nil and RLFeedProfiles.getConfig().milk.breeds[profileName:upper()] or nil
    return breed ~= nil and breed.intakeFactor or 1
end
