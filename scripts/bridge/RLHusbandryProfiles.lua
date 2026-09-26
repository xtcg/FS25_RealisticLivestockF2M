--[[
    RLHusbandryProfiles.lua
    Pen rules for map husbandries that whitelist animal subtypes (Hof Bergmann's
    HusbandrySubtypeFilter).

    A bridge's husbandryProfiles.xml defines profiles - which sexes, castration states,
    ages and breeds a pen takes - and assigns one to each map husbandry by its config
    file. RLRM then enforces the profile in two layers:

    1. Subtype and age: written into the map filter's own fields (subtypeFilterAllowedSubTypes,
       subtypeFilterAgeMin/Max), so the map's shop, animal screen and getSupportsAnimalSubType
       follow it.
    2. Per animal (castration, intact males past maturity, and age for RLRM's own moves,
       which the map's move hook cannot read): checkAnimal, called by the move, buy and
       herdsman paths.

    Rules apply to animals coming in. Animals already in a pen stay when they age out,
    and births are never blocked.
]]

RLHusbandryProfiles = {}

local Log = RmLogging.getLogger("RLRM")
local modDirectory = g_currentModDirectory

RLHusbandryProfiles.FILE = "husbandryProfiles.xml"

--- Reason checkAnimal gives for an animal the profile turns away (breed, sex, castration,
--- maturity or age); the map's plain age window gives AGE_TOO_YOUNG / AGE_TOO_OLD.
RLHusbandryProfiles.REJECT_PEN_RULES = "PEN_RULES"


local function splitNames(value)
    if value == nil or value == "" then return nil end
    local set = {}
    for token in value:gmatch("[^%s,;]+") do set[token:upper()] = true end
    return next(set) ~= nil and set or nil
end


--- Read a husbandryProfiles.xml.
--- @param xmlFile table|nil An XMLFile with a husbandryProfiles root
--- @param config table|nil Config to add to (a later bridge's entries follow an earlier one's)
--- @return table config {profiles = {NAME = rule}, husbandries = {{filename, profile, breeds}}}
function RLHusbandryProfiles.parse(xmlFile, config)
    config = config or { profiles = {}, husbandries = {} }
    if xmlFile == nil then return config end

    xmlFile:iterate("husbandryProfiles.profile", function(_, key)
        local name = xmlFile:getString(key .. "#name")
        if name == nil then
            Log:warning("RLHusbandryProfiles.parse: %s has no name", key)
            return
        end
        local intactMale = (xmlFile:getString(key .. "#intactMale", "false")):lower()
        config.profiles[name:upper()] = {
            name = name:upper(),
            female = xmlFile:getBool(key .. "#female", false),
            steer = xmlFile:getBool(key .. "#steer", false),
            intactMale = intactMale == "true" or intactMale == "untilmature",
            intactMaleUntilMature = intactMale == "untilmature",
            minAge = xmlFile:getInt(key .. "#minAge"),
            maxAge = xmlFile:getInt(key .. "#maxAge"),
            breeds = splitNames(xmlFile:getString(key .. "#breeds")),
        }
    end)

    xmlFile:iterate("husbandryProfiles.husbandry", function(_, key)
        local filename, profile = xmlFile:getString(key .. "#filename"), xmlFile:getString(key .. "#profile")
        if filename == nil or profile == nil then
            Log:warning("RLHusbandryProfiles.parse: %s needs a filename and a profile", key)
            return
        end
        table.insert(config.husbandries, {
            filename = filename:gsub("\\", "/"):lower(),
            profile = profile:upper(),
            breeds = splitNames(xmlFile:getString(key .. "#breeds")),
        })
    end)

    return config
end


--- Profiles from every active map bridge, loaded on the first call.
--- @return table config See parse
function RLHusbandryProfiles.getConfig()
    if RLHusbandryProfiles.config ~= nil then return RLHusbandryProfiles.config end

    local config = { profiles = {}, husbandries = {} }
    for _, bridge in ipairs(RLMapBridge ~= nil and RLMapBridge.activeBridges or {}) do
        if bridge.resolvedConfigPath ~= nil then
            local path = modDirectory .. bridge.resolvedConfigPath .. RLHusbandryProfiles.FILE
            local xmlFile = XMLFile.loadIfExists("husbandryProfiles", path)
            if xmlFile ~= nil then
                RLHusbandryProfiles.parse(xmlFile, config)
                xmlFile:delete()
                Log:info("RLHusbandryProfiles: loaded %s (%d husbandries)", path, #config.husbandries)
            end
        end
    end

    RLHusbandryProfiles.config = config
    return config
end


--- The rule for a placeable: its profile, with the husbandry entry's breeds taking the place
--- of the profile's when given. Cached on the placeable.
--- @return table|nil rule nil when no profile names this placeable
function RLHusbandryProfiles.getRule(placeable)
    if placeable == nil then return nil end
    if placeable.rlPenRule ~= nil then return placeable.rlPenRule or nil end

    local rule = false
    local configFileName = placeable.configFileName ~= nil and placeable.configFileName:gsub("\\", "/"):lower() or nil
    if configFileName ~= nil then
        local config = RLHusbandryProfiles.getConfig()
        for _, entry in ipairs(config.husbandries) do
            if configFileName:sub(-#entry.filename) == entry.filename then
                local profile = config.profiles[entry.profile]
                if profile == nil then
                    Log:warning("RLHusbandryProfiles.getRule: unknown profile '%s' for %s", entry.profile, entry.filename)
                else
                    rule = setmetatable({ breeds = entry.breeds or profile.breeds }, { __index = profile })
                end
                break
            end
        end
    end

    placeable.rlPenRule = rule
    return rule or nil
end


local function breedAllowed(rule, subType)
    return rule.breeds == nil or (subType.breed ~= nil and rule.breeds[subType.breed:upper()] == true)
end


--- Write a placeable's profile into the map filter's fields (subtype whitelist and age
--- window) so the map's own checks follow it. Idempotent; no-op without a profile.
function RLHusbandryProfiles.apply(placeable)
    local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
    if spec == nil or spec.rlPenProfileApplied then return end

    local rule = RLHusbandryProfiles.getRule(placeable)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if rule == nil or animalSystem == nil then return end

    local animalType = animalSystem:getTypeByIndex(spec.animalTypeIndex)
    if animalType == nil then return end

    local allowed, names = {}, {}
    for _, subTypeIndex in ipairs(animalType.subTypes) do
        local subType = animalSystem:getSubTypeByIndex(subTypeIndex)
        local sexAllowed = subType ~= nil and (subType.gender == "female" and rule.female
            or subType.gender ~= "female" and (rule.steer or rule.intactMale))
        if sexAllowed and breedAllowed(rule, subType) then
            allowed[subTypeIndex] = true
            table.insert(names, subType.name)
        end
    end

    spec.subtypeFilterAllowedSubTypes = allowed
    spec.subtypeFilterAgeMin = rule.minAge
    spec.subtypeFilterAgeMax = rule.maxAge
    spec.rlPenProfileApplied = true

    Log:info("RLHusbandryProfiles: %s -> %s, age %s-%s, %d subtype(s): %s",
        tostring(placeable.getName ~= nil and placeable:getName() or placeable.configFileName), rule.name,
        tostring(rule.minAge or 0), tostring(rule.maxAge or "any"), #names, table.concat(names, " "))
end


--- Apply profiles to every husbandry already placed.
function RLHusbandryProfiles.applyAll()
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    for _, placeable in ipairs(placeableSystem ~= nil and placeableSystem.placeables or {}) do
        RLHusbandryProfiles.apply(placeable)
    end
end


--- Whether an animal may enter a placeable.
--- @param placeable table Target husbandry
--- @param animal table An RLRM Animal (live or its stream copy): subTypeIndex, age, gender, isCastrated
--- @return boolean ok
--- @return string|nil reason REJECT_PEN_RULES, "AGE_TOO_YOUNG" or "AGE_TOO_OLD"
--- @return string|nil detail For the log
function RLHusbandryProfiles.checkAnimal(placeable, animal)
    local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
    if spec == nil or animal == nil then return true end
    RLHusbandryProfiles.apply(placeable)

    local age = animal.age or 0
    local rule = RLHusbandryProfiles.getRule(placeable)

    if rule == nil then
        -- The map's age window, which its move hook misses for RLRM moves (it reads the
        -- base game's validate arguments).
        if spec.subtypeFilterAgeMin ~= nil and age < spec.subtypeFilterAgeMin then return false, "AGE_TOO_YOUNG" end
        if spec.subtypeFilterAgeMax ~= nil and age > spec.subtypeFilterAgeMax then return false, "AGE_TOO_OLD" end
        return true
    end

    local subType = g_currentMission.animalSystem:getSubTypeByIndex(animal.subTypeIndex)
    if subType == nil then return false, RLHusbandryProfiles.REJECT_PEN_RULES, "unknown subtype" end

    local reject = RLHusbandryProfiles.REJECT_PEN_RULES
    if not breedAllowed(rule, subType) then return false, reject, "breed " .. tostring(subType.breed) end

    local gender = animal.gender or subType.gender
    if gender == "female" then
        if not rule.female then return false, reject, "female" end
    elseif animal.isCastrated then
        if not rule.steer then return false, reject, "steer" end
    else
        if not rule.intactMale then return false, reject, "intact male" end
        local matureAge = subType.reproductionMinAgeMonth
        if rule.intactMaleUntilMature and matureAge ~= nil and age >= matureAge then
            return false, reject, string.format("intact male at %d months (mature at %d)", age, matureAge)
        end
    end

    if rule.minAge ~= nil and age < rule.minAge then return false, reject, string.format("age %d < %d", age, rule.minAge) end
    if rule.maxAge ~= nil and age > rule.maxAge then return false, reject, string.format("age %d > %d", age, rule.maxAge) end

    return true
end


--- Apply a newly built or bought husbandry's profile once it is placed.
if Placeable ~= nil and Placeable.finalizePlacement ~= nil then
    Placeable.finalizePlacement = Utils.appendedFunction(Placeable.finalizePlacement, function(self)
        RLHusbandryProfiles.apply(self)
    end)
end
