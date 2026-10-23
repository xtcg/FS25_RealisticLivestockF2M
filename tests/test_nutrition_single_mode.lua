-- Unified nursing batch E: one nutrition model. The Legacy choice is retired (no setting, a saved
-- one migrated once), the pig fallback and the old food-factor weight rules no longer run for the
-- covered cattle, sheep, goats and pigs (a pen that cannot run the model holds them), and an older
-- copy of the nutrition configs in modSettings migrates section by section from the mod's files.
loadMod("tests/feedsim.lua")
loadMod("tests/sheepsim.lua")
loadMod("tests/pigsim.lua")
loadMod("scripts/animal/AnimalHealth.lua")

SheepSim.enable(true)
PigSim.enable(true)
GrowthSim.setDaysPerPeriod(1)

local function readText(path)
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    return text
end

-- An XMLFile over text (a copy of a shipped file with edits), through a temporary file.
local function parseText(text)
    local path = os.tmpname()
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
    local xml = loadXMLFileFromDisk(path)
    os.remove(path)
    return xml
end

-- Remove one element (from its opening tag to its closing tag, or a self-closing one) after `from`.
local function cut(text, openPattern, closeTag, from)
    local s = text:find(openPattern, from or 1)
    assert(s, openPattern)
    local _, e = text:find(closeTag, s, true)
    assert(e, closeTag)
    return text:sub(1, s - 1) .. text:sub(e + 1)
end


-- No mode left ------------------------------------------------------------------------------------

check("mode: RLFeed has no mode, no setting callback and no pig fallback any more",
    RLFeed.mode == nil and RLFeed.MODE_LEGACY == nil and RLFeed.onSettingChanged == nil and RLFeed.stepFallback == nil)
check("mode: the model can run on the shipped configs (canRun OK)", (select(2, RLFeed.canRun())) == "OK")


-- feedProfiles.xml copy migration -------------------------------------------------------------------

do
    local shipped = readText(REPO .. "xml/feedProfiles.xml")
    local builtin = RLFeedProfiles.parse(loadXMLFileFromDisk(REPO .. "xml/feedProfiles.xml"))
    -- An older copy: no GOAT section, a PIG section without nursing rules, and a value of the user's own.
    local old = cut(shipped, '<species name="GOAT">', "</species>")
    local pigAt = old:find('<species name="PIG">', 1, true)
    old = cut(old, "<nursing ", "</nursing>", pigAt)
    old = old:gsub('(<feedProfiles[^>]-)resourceScale="[^"]*"', '%1resourceScale="0.2"', 1)
    local copy = RLFeedProfiles.parse(parseText(old))
    check("feed copy: the older copy really lacks GOAT and the PIG nursing rules", copy.species.GOAT == nil
        and copy.species.PIG ~= nil and copy.species.PIG.nursing == nil and copy.resourceScale == 0.2)
    local migrated = RLFeedProfiles.migrateCopy(copy, builtin)
    local notes = table.concat(migrated.migrated or {}, ",")
    check("feed copy: GOAT taken from the mod's file, PIG takes the mod's nursing rules (" .. notes .. ")",
        migrated == copy and migrated.species.GOAT == builtin.species.GOAT and migrated.species.PIG.nursing == builtin.species.PIG.nursing
        and notes:find("GOAT:SECTION_ADDED", 1, true) ~= nil and notes:find("PIG:NURSING_ADDED", 1, true) ~= nil)
    check("feed copy: the user's own values are kept (resource scale 0.2), the PIG section is its own",
        migrated.resourceScale == 0.2 and migrated.species.PIG ~= builtin.species.PIG and migrated.species.PIG.hash ~= nil)
    check("feed copy: the shipped file itself needs no migration", #RLFeedProfiles.migrateCopy(
        RLFeedProfiles.parse(loadXMLFileFromDisk(REPO .. "xml/feedProfiles.xml")), builtin).migrated == 0)
    check("feed copy: no mod file to migrate from leaves a config as it is", RLFeedProfiles.migrateCopy(copy, nil) == copy)
    local broken = RLFeedProfiles.parse(parseText(shipped:gsub('(<feedProfiles[^>]-)resourceScale="[^"]*"', '%1resourceScale="-1"', 1)))
    check("feed copy: a copy that cannot be read gives way to the mod's file", broken.valid == false
        and RLFeedProfiles.migrateCopy(broken, builtin) == builtin)

    -- A pig pen whose section has no nursing rules (a third-party config) is not fed by the old rules.
    local section = RLFeed.getConfig(PigSim.TYPE ~= nil and PigSim.makePen({}, {}) or nil)
    local saved = section.nursing
    section.nursing = nil
    local sow = PigSim.grown("PIG_LANDRACE", 7, 18, { isParent = true, monthsSinceLastBirth = 0 })
    local active, reason = RLFeed.evaluatePen(PigSim.makePen({ sow }, { PIGFOOD = 100 }))
    section.nursing = saved
    check("pigs: a sow in a section without nursing rules: NO_NURSING_RULES, never PIG_BREEDING_LEGACY",
        active == false and reason == "NO_NURSING_RULES")
    local active2, reason2 = RLFeed.evaluatePen(PigSim.makePen({ sow }, { PIGFOOD = 100 }))
    check("pigs: with the shipped rules the sow's pen runs the model", active2 == true and reason2 == "OK")
end


-- bodyCondition.xml and weightProfiles.xml copy migration -----------------------------------------------

do
    local shipped = readText(REPO .. "xml/bodyCondition.xml")
    local builtin = RLBodyConditionConfig.parse(loadXMLFileFromDisk(REPO .. "xml/bodyCondition.xml"))
    local old = cut(shipped, '<species name="GOAT"', "</species>")
    old = old:gsub('(<bodyCondition[^>]-)enabled="true"', '%1enabled="false"', 1)
    local copy = RLBodyConditionConfig.parse(parseText(old))
    check("body copy: the older copy is switched off and lacks GOAT", copy.enabled == false and copy.species.GOAT == nil
        and copy.species.SHEEP ~= nil and copy.species.SHEEP.enabled == false)
    local migrated = RLBodyConditionConfig.migrateCopy(copy, builtin)
    local notes = table.concat(migrated.migrated or {}, ",")
    check("body copy: enabled=false is not a way back to the old rules; GOAT is the mod's; SHEEP its own, on (" .. notes .. ")",
        migrated.enabled == true and migrated.species.GOAT == builtin.species.GOAT and migrated.species.SHEEP ~= builtin.species.SHEEP
        and migrated.species.SHEEP.enabled == true and notes:find("ENABLED_IGNORED", 1, true) ~= nil)
end

do
    local shipped = readText(REPO .. "xml/weightProfiles.xml")
    local builtin = RLWeightProfiles.parse(loadXMLFileFromDisk(REPO .. "xml/weightProfiles.xml"))
    -- An older copy: sheep exclude goats, no GOAT profile, the pig type switched off.
    local old = cut(shipped, '<profile name="GOAT" type="SHEEP"', "</profile>")
    old = old:gsub('(<animalType name="SHEEP")', '%1 excludeBreeds="GOAT"', 1)
    old = old:gsub('(<animalType name="PIG" )enabled="true"', '%1enabled="false"', 1)
    local copy = RLWeightProfiles.parse(parseText(old))
    check("weight copy: the older copy excludes goats, has no GOAT profile and switches pigs off",
        copy.types.SHEEP.excludeBreeds.GOAT == true and copy.profiles["SHEEP:GOAT"] == nil and copy.types.PIG.enabled == false)
    local migrated = RLWeightProfiles.migrateCopy(copy, builtin)
    local notes = table.concat(migrated.migrated or {}, ",")
    check("weight copy: goats no longer excluded, their profile added, pigs back on the curves (" .. notes .. ")",
        migrated.types.SHEEP.excludeBreeds.GOAT == nil and migrated.profiles["SHEEP:GOAT"] == builtin.profiles["SHEEP:GOAT"]
        and migrated.types.PIG.enabled == true and notes:find("PIG:TYPE_ENABLED", 1, true) ~= nil)
end


-- A pen that cannot run the model holds its covered animals --------------------------------------

do
    -- No trough: the hour is held - no growth, no health change, no old weight rule.
    local calf = GrowthSim.makeAnimal("BULL_ANGUS", { age = 3 })
    local sub = calf:getSubType()
    sub.healthThresholdFactor, sub.healthIncreaseHour, sub.healthDecreaseHour = 0.5, 1, 1
    local oldRule = 0
    calf.updateWeight = function() oldRule = oldRule + 1 end
    local bare = { getClusters = function() return { calf } end, getAnimalTypeIndex = function() return AnimalType.COW end }
    calf.clusterSystem = { owner = bare }
    local weight, health = calf.weight, calf.health
    for _ = 1, 3 do
        GrowthSim.advanceHour()
        AnimalHealth.updateHealth(calf, 0.2)
    end
    check("hold: a covered calf with no pen model this hour keeps weight and health, never the old weight rule",
        calf.weight == weight and calf.health == health and oldRule == 0 and calf.rlFeedHold ~= nil
        and calf.rlFeedHold.tick == RLBodyCondition.getTickId())

    -- Its next pen that runs the model does not step it again in the same hour; the hour after it does.
    local pen = FeedSim.makePen({ calf }, { FORAGE = 50000 })
    calf.clusterSystem = { owner = pen }
    local steps = 0
    local function observe(kind, data)
        if kind == "STEP" then for _, e in ipairs(data.animals) do if e.animal == calf then steps = steps + 1 end end end
    end
    RLFeed.addObserver(observe)
    local advance = GrowthSim.advanceHour
    GrowthSim.advanceHour = function() end
    FeedSim.hour(pen)
    GrowthSim.advanceHour = advance
    local sameHour = steps
    FeedSim.hour(pen)
    RLFeed.removeObserver(observe)
    check(string.format("hold: the held hour is that hour's one settlement (steps %d), the next hour runs the model (%d)", sameHour, steps),
        sameHour == 0 and steps > 0 and oldRule == 0)

    -- An animal the model does not cover (a vanilla cluster) keeps its own type's rules.
    local cluster = GrowthSim.makeAnimal("BULL_ANGUS", { age = 3 })
    cluster.isIndividual = false
    local clusterRule = 0
    cluster.updateWeight = function() clusterRule = clusterRule + 1 end
    cluster.clusterSystem = { owner = bare }
    GrowthSim.advanceHour()
    AnimalHealth.updateHealth(cluster, 1)
    check("hold: an animal outside the model (not an individual) keeps the old rules of its type", clusterRule == 1
        and not RLFeed.holdUnsettled(cluster))
end

do
    -- A sheep whose species section cannot be read is refused by the model (CONFIG_INVALID), never
    -- given the old weight rule.
    local lamb = SheepSim.grown("RAM_LANDRACE", "E1", 4.0)
    local pen = SheepSim.makePen({ lamb })
    local section = RLFeedProfiles.getConfig().species.SHEEP
    section.valid = false
    local oldRule = 0
    lamb.updateWeight = function() oldRule = oldRule + 1 end
    local weight = lamb.weight
    FeedSim.hour(pen)
    AnimalHealth.updateHealth(lamb, 1)
    section.valid = true
    check("hold: a sheep with an unreadable section is held (CONFIG_INVALID), never the old weight rule",
        oldRule == 0 and lamb.weight == weight and lamb.rlFeedHold ~= nil and lamb.rlFeedHold.reason == "CONFIG_INVALID")
end


-- Settings on the wire ---------------------------------------------------------------------------------

do
    loadMod("scripts/events/RL_BroadcastSettingsEvent.lua")
    local savedSettings = RLSettings
    local applied = {}
    RLSettings = { SETTINGS = {
        foodScale = { state = 2, values = { 1, 2, 3 }, callback = function(name, value) applied[name] = value end },
        maxVisualAnimals = { ignore = true, state = 1, values = { 1 } },
    } }
    RLDebugUtils = RLDebugUtils or { dumpSettingsOnce = function() end }
    -- A stream: what one side writes the other reads back in order.
    local stream = {}
    local readAt = 0
    streamWriteBool = function(_, v) stream[#stream + 1] = v end
    streamWriteString = streamWriteBool
    streamWriteUInt8 = streamWriteBool
    local function nextValue() readAt = readAt + 1; return stream[readAt] end
    streamReadBool, streamReadString, streamReadUInt8 = nextValue, nextValue, nextValue
    -- An older sender's full set still holding the retired row.
    stream = { true, 2, "nutritionMode", 1, "foodScale", 3 }
    local event = RL_BroadcastSettingsEvent.emptyNew()
    event:readStream(1, nil)
    check("wire: a full set read by the sender's count; the retired nutritionMode row is skipped, the rest applied",
        readAt == #stream and RLSettings.SETTINGS.nutritionMode == nil and RLSettings.SETTINGS.foodScale.state == 3 and applied.foodScale == 3)
    -- Written by this side: its own count first, ignored rows left out.
    stream, readAt = {}, 0
    RL_BroadcastSettingsEvent.new(nil):writeStream(1, nil)
    check("wire: a full set written with its count and only the shared rows", stream[1] == true and stream[2] == 1
        and stream[3] == "foodScale" and #stream == 4)
    -- A single retired row: dropped, nothing created or applied.
    stream, readAt, applied = { false, "nutritionMode", 1 }, 0, {}
    local single = RL_BroadcastSettingsEvent.emptyNew()
    local ok = pcall(single.readStream, single, 1, nil)
    check("wire: a single retired row is dropped without an error", ok and RLSettings.SETTINGS.nutritionMode == nil and next(applied) == nil)
    RLSettings = savedSettings
end

SheepSim.enable(false)
PigSim.enable(false)
