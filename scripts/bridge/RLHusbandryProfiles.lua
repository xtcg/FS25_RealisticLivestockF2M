--[[
    RLHusbandryProfiles.lua
    Pen rules for map husbandries that whitelist animal subtypes (Hof Bergmann's
    HusbandrySubtypeFilter).

    A bridge's husbandryProfiles.xml defines profiles - which sexes, castration states,
    ages and breeds a pen takes - and assigns one to each map husbandry by its config
    file. RLRM then enforces the profile in two layers:

    1. Subtype and age: written into the map filter's own fields (subtypeFilterAllowedSubTypes,
       subtypeFilterAgeMin/Max), so the map's shop, animal screen, buy check and
       getSupportsAnimalSubType follow it.
    2. Per animal (castration, intact males past maturity, and age for RLRM's own moves,
       which the map's move hook cannot read): checkAnimal, called by the GUI, move, buy and
       herdsman paths. For a profiled pen it also runs the map filter's own test on the fields
       it ends up with, so the GUI never offers a pen the map's buy check then refuses.

    The map filter reads a minimum age without a maximum as "until the subtype's next visual
    stage" (12 months for cattle). A profile without maxAge means no upper limit, so apply
    writes OPEN_MAX_AGE there instead of leaving it nil.

    Before either layer, a husbandry that is still under construction takes no animal at all
    (RLPenConstruction, from the same file's <construction> entries).

    Rules apply to animals coming in. Animals already in a pen stay when they outgrow it: they
    are logged (OVERAGE_RESIDENT), and the owner gets a message when one crosses the limit.
    Nothing moves, sells or removes them. Births are never blocked.
]]

RLHusbandryProfiles = {}

local Log = RmLogging.getLogger("RLRM")
local modDirectory = g_currentModDirectory

RLHusbandryProfiles.FILE = "husbandryProfiles.xml"

--- Reason checkAnimal gives for an animal the profile turns away (breed, sex, castration,
--- maturity, age or the map filter); the map's plain age window gives AGE_TOO_YOUNG / AGE_TOO_OLD.
RLHusbandryProfiles.REJECT_PEN_RULES = "PEN_RULES"

--- Upper age written into the map filter for a profile without maxAge: "no limit" as a finite
--- integer, so the map's nil-maximum branch (next visual stage) stays off and its "%d" message
--- format still works. Larger than any age in months; never saved or sent.
RLHusbandryProfiles.OPEN_MAX_AGE = 2147483647

--- Map filter results (checkMapFilter), named after the map check that refused.
RLHusbandryProfiles.MAP_SUBTYPE = "MAP_SUBTYPE"
RLHusbandryProfiles.MAP_AGE_MIN = "MAP_AGE_MIN"
RLHusbandryProfiles.MAP_AGE_MAX = "MAP_AGE_MAX"
RLHusbandryProfiles.MAP_NEXT_VISUAL_STAGE = "MAP_NEXT_VISUAL_STAGE"
RLHusbandryProfiles.MAP_VISUAL = "MAP_VISUAL"


local function splitNames(value)
    if value == nil or value == "" then return nil end
    local set = {}
    for token in value:gmatch("[^%s,;]+") do set[token:upper()] = true end
    return next(set) ~= nil and set or nil
end


local function sortedNames(set)
    if set == nil then return nil end
    local names = {}
    for name in pairs(set) do names[#names + 1] = name end
    table.sort(names)
    return names
end


--- Read a husbandryProfiles.xml.
--- @param xmlFile table|nil An XMLFile with a husbandryProfiles root
--- @param config table|nil Config to add to (a later bridge's entries follow an earlier one's)
--- @param source string|nil Path of the file, kept on each profile and entry for the log
--- @return table config {profiles = {NAME = rule}, husbandries = {{filename, profile, breeds, source}},
---   constructions = {{filename, readyStates = {NAME = true}, names, source}}}
function RLHusbandryProfiles.parse(xmlFile, config, source)
    config = config or { profiles = {}, husbandries = {}, constructions = {} }
    config.constructions = config.constructions or {}
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
            rearing = xmlFile:getBool(key .. "#rearing", false),
            source = source,
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
            source = source,
        })
    end)

    -- Buildings with a construction state machine: the states in which they take animals
    -- (RLPenConstruction).
    xmlFile:iterate("husbandryProfiles.construction", function(_, key)
        local filename = xmlFile:getString(key .. "#filename")
        local readyStates = splitNames(xmlFile:getString(key .. "#readyStates"))
        if filename == nil or readyStates == nil then
            Log:warning("RLHusbandryProfiles.parse: %s needs a filename and readyStates", key)
            return
        end
        table.insert(config.constructions, {
            filename = filename:gsub("\\", "/"):lower(),
            readyStates = readyStates,
            names = sortedNames(readyStates),
            source = source,
        })
    end)

    return config
end


--- Profiles from every active map bridge, loaded on the first call.
--- @return table config See parse
function RLHusbandryProfiles.getConfig()
    if RLHusbandryProfiles.config ~= nil then return RLHusbandryProfiles.config end

    local config = { profiles = {}, husbandries = {}, constructions = {} }
    for _, bridge in ipairs(RLMapBridge ~= nil and RLMapBridge.activeBridges or {}) do
        if bridge.resolvedConfigPath ~= nil then
            local path = modDirectory .. bridge.resolvedConfigPath .. RLHusbandryProfiles.FILE
            local xmlFile = XMLFile.loadIfExists("husbandryProfiles", path)
            if xmlFile ~= nil then
                RLHusbandryProfiles.parse(xmlFile, config, bridge.resolvedConfigPath .. RLHusbandryProfiles.FILE)
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
                    rule = setmetatable({ breeds = entry.breeds or profile.breeds, entry = entry.filename,
                        entrySource = entry.source }, { __index = profile })
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


-- =============================================================================
-- The map filter's own test, read from the spec fields (HusbandrySubtypeFilter.checkAnimalAllowed)
-- =============================================================================

local function getAnimalSystem()
    return g_currentMission ~= nil and g_currentMission.animalSystem or nil
end


--- The lowest visual stage start above an age (the map's getNextVisualMinAge).
--- @return number|nil
function RLHusbandryProfiles.getNextVisualMinAge(subTypeIndex, age)
    local animalSystem = getAnimalSystem()
    local subTypeDef = animalSystem ~= nil and animalSystem:getSubTypeByIndex(subTypeIndex) or nil
    if subTypeDef == nil or subTypeDef.visuals == nil then return nil end

    local nextAge
    for _, visual in ipairs(subTypeDef.visuals) do
        local minAge = visual.minAge or visual.minAgeMonth or 0
        if minAge > age and (nextAge == nil or minAge < nextAge) then nextAge = minAge end
    end
    return nextAge
end


local function getVisualAnimalIndex(subTypeIndex, age)
    local animalSystem = getAnimalSystem()
    if animalSystem == nil then return nil end
    if animalSystem.getVisualAnimalIndexByAge ~= nil then return animalSystem:getVisualAnimalIndexByAge(subTypeIndex, age) end
    if animalSystem.getVisualByAge == nil then return nil end
    local visual = animalSystem:getVisualByAge(subTypeIndex, age)
    return visual ~= nil and visual.visualAnimalIndex or nil
end


--- Whether the map's filter, as its fields stand now, takes this subtype at this age. Mirrors
--- HusbandrySubtypeFilter.checkAnimalAllowed, which the map runs on every buy.
--- @return boolean ok
--- @return string|nil code MAP_SUBTYPE, MAP_AGE_MIN, MAP_AGE_MAX, MAP_NEXT_VISUAL_STAGE or MAP_VISUAL
--- @return number|nil value The limit or visual index that refused
function RLHusbandryProfiles.checkMapFilter(placeable, subTypeIndex, age)
    local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
    if spec == nil then return true end
    age = tonumber(age) or 0

    if spec.subtypeFilterAllowedSubTypes ~= nil and spec.subtypeFilterAllowedSubTypes[subTypeIndex] ~= true then
        return false, RLHusbandryProfiles.MAP_SUBTYPE
    end
    local minAge, maxAge = spec.subtypeFilterAgeMin, spec.subtypeFilterAgeMax
    if minAge ~= nil and age < minAge then return false, RLHusbandryProfiles.MAP_AGE_MIN, minAge end
    if maxAge ~= nil and age > maxAge then return false, RLHusbandryProfiles.MAP_AGE_MAX, maxAge end
    if minAge ~= nil and maxAge == nil then
        local nextAge = RLHusbandryProfiles.getNextVisualMinAge(subTypeIndex, minAge)
        if nextAge ~= nil and age >= nextAge then return false, RLHusbandryProfiles.MAP_NEXT_VISUAL_STAGE, nextAge end
    end
    if spec.subtypeFilterAllowedVisuals ~= nil then
        local visualIndex = getVisualAnimalIndex(subTypeIndex, age)
        if visualIndex ~= nil and spec.subtypeFilterAllowedVisuals[visualIndex] ~= true then
            return false, RLHusbandryProfiles.MAP_VISUAL, visualIndex
        end
    end
    return true
end


--- The map filter fields of a pen, for the log.
--- @return table
function RLHusbandryProfiles.getMapFilterState(placeable)
    local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
    if spec == nil then return {} end
    local numSubTypes
    if spec.subtypeFilterAllowedSubTypes ~= nil then
        numSubTypes = 0
        for _ in pairs(spec.subtypeFilterAllowedSubTypes) do numSubTypes = numSubTypes + 1 end
    end
    local visuals
    if spec.subtypeFilterAllowedVisuals ~= nil then
        visuals = {}
        for index in pairs(spec.subtypeFilterAllowedVisuals) do visuals[#visuals + 1] = index end
        table.sort(visuals)
    end
    local maxAge = spec.subtypeFilterAgeMax
    return {
        minAge = spec.subtypeFilterAgeMin,
        maxAge = maxAge == RLHusbandryProfiles.OPEN_MAX_AGE and "OPEN" or maxAge,
        numSubTypes = numSubTypes,
        visuals = visuals,
        nextVisualStageCap = spec.subtypeFilterAgeMin ~= nil and maxAge == nil,
    }
end


-- =============================================================================
-- Applying a profile
-- =============================================================================

--- What a pen's trough takes and whether it has water, for the log: the food spec's fill types
--- that one of its unload triggers accepts (the engine reads no avoid list, so this is what a
--- player can actually tip in), split into milk and solid feed.
--- @return table
function RLHusbandryProfiles.getFeedAcceptance(placeable)
    local food = placeable ~= nil and placeable.spec_husbandryFood or nil
    local water = placeable ~= nil and placeable.spec_husbandryWater or nil
    local result = {
        trough = food ~= nil,
        water = water == nil and "NONE" or (water.automaticWaterSupply and "AUTOMATIC" or "TANK"),
    }
    if food == nil then return result end

    local milk, solid = {}, {}
    for fillTypeIndex in pairs(food.supportedFillTypes or {}) do
        local accepted = false
        for _, trigger in ipairs(food.feedingTroughs or {}) do
            if trigger.getIsFillTypeSupported == nil or trigger:getIsFillTypeSupported(fillTypeIndex) then
                accepted = true
                break
            end
        end
        if accepted then
            local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or tostring(fillTypeIndex)
            local isMilk = RLCalfRearing ~= nil and RLCalfRearing.isMilkFillType(fillTypeIndex)
            table.insert(isMilk and milk or solid, name)
        end
    end
    table.sort(milk)
    table.sort(solid)
    result.capacity = food.capacity
    result.milk = milk
    result.solid = solid
    return result
end


local function describeRule(rule)
    return {
        female = rule.female,
        steer = rule.steer,
        intactMale = rule.intactMaleUntilMature and "untilMature" or rule.intactMale,
        minAge = rule.minAge,
        maxAge = rule.maxAge,
        breeds = sortedNames(rule.breeds),
        rearing = rule.rearing,
    }
end


--- Write a placeable's profile into the map filter's fields (subtype whitelist and age
--- window) so the map's own checks follow it. Idempotent; no-op without a profile.
function RLHusbandryProfiles.apply(placeable)
    local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
    if spec == nil or spec.rlPenProfileApplied then return end

    local rule = RLHusbandryProfiles.getRule(placeable)
    local animalSystem = getAnimalSystem()
    if rule == nil or animalSystem == nil then return end

    local animalType = animalSystem:getTypeByIndex(spec.animalTypeIndex)
    if animalType == nil then return end

    local before = RLHusbandryProfiles.getMapFilterState(placeable)

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
    spec.subtypeFilterAgeMax = rule.maxAge or RLHusbandryProfiles.OPEN_MAX_AGE
    spec.rlPenProfileApplied = true

    Log:info("RLHusbandryProfiles: %s -> %s, age %s-%s, %d subtype(s): %s",
        tostring(placeable.getName ~= nil and placeable:getName() or placeable.configFileName), rule.name,
        tostring(rule.minAge or 0), tostring(rule.maxAge or "any"), #names, table.concat(names, " "))

    RLPenLog.emit("PROFILE_APPLIED", {
        pen = RLPenLog.pen(placeable),
        profile = rule.name,
        source = rule.entrySource or rule.source,
        entry = rule.entry,
        rule = describeRule(rule),
        mapBefore = before,
        mapAfter = RLHusbandryProfiles.getMapFilterState(placeable),
        subTypes = names,
        feed = RLHusbandryProfiles.getFeedAcceptance(placeable),
        construction = RLPenConstruction.describe(placeable),
    })

    if rule.rearing then
        local feed = RLHusbandryProfiles.getFeedAcceptance(placeable)
        if not feed.trough or #(feed.milk or {}) == 0 or #(feed.solid or {}) == 0 then
            RLPenLog.emit("REARING_FEED_MISSING", { pen = RLPenLog.pen(placeable), profile = rule.name, feed = feed }, true)
        end
    end
end


--- Apply profiles to every husbandry already placed.
function RLHusbandryProfiles.applyAll()
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    for _, placeable in ipairs(placeableSystem ~= nil and placeableSystem.placeables or {}) do
        RLHusbandryProfiles.apply(placeable)
    end
end


-- =============================================================================
-- Admission
-- =============================================================================

--- Whether an animal may enter a placeable. A husbandry that is not built yet takes none
--- (RLPenConstruction), whatever the animal.
--- @param placeable table Target husbandry
--- @param animal table|nil An RLRM Animal (live or its stream copy): subTypeIndex, age, gender, isCastrated
--- @return boolean ok
--- @return string|nil reason RLPenConstruction.REJECT, REJECT_PEN_RULES, "AGE_TOO_YOUNG" or "AGE_TOO_OLD"
--- @return string|nil detail For the log
function RLHusbandryProfiles.checkAnimal(placeable, animal)
    local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
    if spec == nil then return true end

    local admit, construction = RLPenConstruction.canAdmit(placeable)
    if not admit then return false, RLPenConstruction.REJECT, RLPenConstruction.detail(construction) end

    if animal == nil then return true end
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

    local subType = getAnimalSystem():getSubTypeByIndex(animal.subTypeIndex)
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

    -- The map's buy check runs on the fields apply wrote; refuse here what it would refuse there.
    local mapOk, code, value = RLHusbandryProfiles.checkMapFilter(placeable, animal.subTypeIndex, age)
    if not mapOk then return false, reject, string.format("map filter %s %s", tostring(code), tostring(value)) end

    return true
end


--- Every layer's verdict on one animal for one pen, for the log. Read-only.
--- @return table {profile, construction, rlrm = {ok, reason, detail}, map = {ok, code, value}}
function RLHusbandryProfiles.explain(placeable, animal)
    local rule = RLHusbandryProfiles.getRule(placeable)
    local ok, reason, detail = RLHusbandryProfiles.checkAnimal(placeable, animal)
    local mapOk, code, value = RLHusbandryProfiles.checkMapFilter(placeable, animal ~= nil and animal.subTypeIndex or nil,
        animal ~= nil and animal.age or 0)
    return {
        profile = rule ~= nil and rule.name or nil,
        construction = RLPenConstruction.describe(placeable),
        rlrm = { ok = ok, reason = reason, detail = detail },
        map = { ok = mapOk, code = code, value = value },
    }
end


--- Record one admission decision (buy, move, herdsman) with both layers' verdicts.
--- @param kind string BUY_CHECK, MOVE_CHECK, AI_MOVE_CHECK, HERDSMAN_CHECK, GUI_CHECK
--- @param placeable table Target
--- @param animal table
--- @param extra table|nil Fields to add (errorCode, path, ...)
function RLHusbandryProfiles.logDecision(kind, placeable, animal, extra)
    if placeable == nil or placeable.spec_husbandryAnimals == nil then return end
    local data = extra or {}
    data.pen = RLPenLog.pen(placeable)
    data.animal = RLPenLog.animal(animal)
    data.verdict = RLHusbandryProfiles.explain(placeable, animal)
    RLPenLog.emit(kind, data)
end


-- =============================================================================
-- Outgrown residents
-- =============================================================================

--- Whether an animal in a pen is past the pen's maximum age for new animals.
--- @return boolean
function RLHusbandryProfiles.isOutgrown(placeable, animal)
    local rule = RLHusbandryProfiles.getRule(placeable)
    return rule ~= nil and rule.maxAge ~= nil and animal ~= nil and (animal.age or 0) > rule.maxAge
end


--- Pens of the same farm that would take this animal now, with their free places. Read-only.
--- @return table {{name, freeSlots}}
function RLHusbandryProfiles.getOutgrownDestinations(placeable, animal)
    local list = {}
    if RLMoveDestinationHelper == nil or placeable.getOwnerFarmId == nil then return list end
    for _, entry in ipairs(RLMoveDestinationHelper.getValidDestinations(placeable, placeable:getOwnerFarmId(), animal.subTypeIndex, { animal })) do
        if not entry.isEPP then table.insert(list, { name = entry.name, freeSlots = entry.freeSlots }) end
    end
    return list
end


local function animalKey(animal)
    return tostring(animal.farmId) .. " " .. tostring(animal.uniqueId)
end


--- Log every outgrown animal in a pen and, unless loading, message the owner once per animal and
--- pen. Server only; never moves or changes an animal.
--- @param placeable table
--- @param trigger string LOAD or DAY
--- @return number outgrown
function RLHusbandryProfiles.checkResidents(placeable, trigger)
    local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
    local rule = RLHusbandryProfiles.getRule(placeable)
    if spec == nil or rule == nil or rule.maxAge == nil or spec.clusterSystem == nil then return 0 end

    spec.rlOutgrownNotified = spec.rlOutgrownNotified or {}
    local seen, count = {}, 0
    for _, animal in pairs(spec.clusterSystem:getClusters() or {}) do
        if animal.age ~= nil and not animal.isDead and RLHusbandryProfiles.isOutgrown(placeable, animal) then
            count = count + 1
            local key = animalKey(animal)
            seen[key] = true
            local destinations = RLHusbandryProfiles.getOutgrownDestinations(placeable, animal)
            local isNew = not spec.rlOutgrownNotified[key]
            RLPenLog.emit("OVERAGE_RESIDENT", {
                pen = RLPenLog.pen(placeable),
                profile = rule.name,
                maxAge = rule.maxAge,
                animal = RLPenLog.animal(animal),
                destinations = destinations,
                trigger = trigger,
                notified = isNew and trigger ~= "LOAD",
            }, isNew)
            if isNew then
                spec.rlOutgrownNotified[key] = true
                if trigger ~= "LOAD" and animal.addMessage ~= nil then
                    local names = {}
                    for _, destination in ipairs(destinations) do
                        if (destination.freeSlots or 0) > 0 then names[#names + 1] = destination.name end
                    end
                    animal:addMessage("PEN_OUTGROWN", { placeable:getName(), rule.maxAge,
                        #names > 0 and table.concat(names, ", ") or g_i18n:getText("rl_ui_penOutgrownNoPen") })
                end
            end
        end
    end
    -- An animal moved out (or back under the limit) may be told again if it returns.
    for key in pairs(spec.rlOutgrownNotified) do
        if not seen[key] then spec.rlOutgrownNotified[key] = nil end
    end
    return count
end


--- Check every profiled pen's residents (after loading).
function RLHusbandryProfiles.checkAllResidents(trigger)
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    local total = 0
    for _, placeable in ipairs(placeableSystem ~= nil and placeableSystem.placeables or {}) do
        total = total + RLHusbandryProfiles.checkResidents(placeable, trigger)
    end
    return total
end


--- Apply a newly built or bought husbandry's profile once it is placed.
if Placeable ~= nil and Placeable.finalizePlacement ~= nil then
    Placeable.finalizePlacement = Utils.appendedFunction(Placeable.finalizePlacement, function(self)
        RLHusbandryProfiles.apply(self)
    end)
end
