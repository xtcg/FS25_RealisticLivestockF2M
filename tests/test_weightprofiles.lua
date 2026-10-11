-- Weight profiles (scripts/animal/RLWeightProfiles.lua, xml/weightProfiles.xml): every loaded cattle
-- subtype resolves to its breed's profile, a map's name for a breed to that breed's profile, an
-- unknown breed to nothing (a gap, not another breed), MILKCOW to "not covered"; and each weight
-- setting is reported with the layer that set it. The layered lookup's new source answer gives
-- the same values as before.

ANIMALS_XML = REPO .. "xml/animals.xml"
loadMod("tests/economics.lua")
loadMod("scripts/animal/RLWeightProfiles.lua")

local COW_TYPE
for _, sub in ipairs(Economics.subTypes) do if sub.typeName == "COW" then COW_TYPE = sub.typeIndex end end
local MILKCOW_TYPE = 99

-- The animal system: the mod's own subtypes, then what a Cow Breeds pack, a map and Hof Bergmann
-- would add.
local subTypes = {}
for _, sub in ipairs(Economics.subTypes) do subTypes[#subTypes + 1] = sub end
local function add(name, breed, gender, typeIndex, target)
    local sub = { name = name, breed = breed, gender = gender, typeIndex = typeIndex, minWeight = 40,
        targetWeight = target or 700, maxWeight = 1400, reproductionMinAgeMonth = 15 }
    subTypes[#subTypes + 1] = sub
    return sub
end
local packBull = add("BULL_CHAROLAIS_PACK", "CHAROLAIS_PACK", "male", COW_TYPE, 1050)
local packCow = add("COW_CHAROLAIS_PACK", "CHAROLAIS_PACK", "female", COW_TYPE, 850)
local mapCow = add("COW_CHAROLAISE", "CHAROLAISE", "female", COW_TYPE, 850)
local mapBull = add("BULL_MONTBELIARDE", "MONTBELIARDE", "male", COW_TYPE, 1000)
local unknown = add("COW_AUBRAC", "AUBRAC", "female", COW_TYPE, 650)
local milkCow = add("MILK_COW", "HOLSTEIN", "female", MILKCOW_TYPE, 650)
local pig = add("PIG_TEST", "LANDRACE", "female", -5, 120)

local baseGetType = g_currentMission.animalSystem.getTypeByIndex
g_currentMission.animalSystem.subTypes = subTypes
g_currentMission.animalSystem.getTypeByIndex = function(system, index)
    if index == MILKCOW_TYPE then return { name = "MILKCOW" } end
    if index == -5 then return { name = "PIG" } end
    return baseGetType(system, index)
end

local byName = {}
for _, record in ipairs(RLWeightProfiles.enumerate()) do byName[record.subType] = record end


-- Resolution ---------------------------------------------------------------------------------

do
    local ok, missing = true, {}
    for _, sub in ipairs(Economics.subTypes) do
        if sub.typeName == "COW" then
            local record = byName[sub.name]
            if record == nil or record.resolution ~= "EXACT" or record.profile ~= sub.breed
                or record.profileStatus ~= "BASE_XML_UNREVALIDATED" then
                ok = false
                missing[#missing + 1] = sub.name
            end
        end
    end
    check("profiles: every cattle subtype of the mod resolves to its own breed's profile (" .. table.concat(missing, " ") .. ")", ok)
end

check("profiles: a Cow Breeds pack subtype resolves to its pack profile",
    byName.BULL_CHAROLAIS_PACK.resolution == "EXACT" and byName.BULL_CHAROLAIS_PACK.profile == "CHAROLAIS_PACK"
    and byName.BULL_CHAROLAIS_PACK.profileStatus == "PACK_REVIEW_ONLY")
check("profiles: a map's name for a breed (CHAROLAISE) resolves to that breed's profile and keeps its own subtype",
    byName.COW_CHAROLAISE.resolution == "ALIAS" and byName.COW_CHAROLAISE.profile == "CHAROLAIS_PACK"
    and byName.COW_CHAROLAISE.subType == "COW_CHAROLAISE" and byName.COW_CHAROLAISE.breed == "CHAROLAISE")
check("profiles: a breed only a map brings has its own profile",
    byName.BULL_MONTBELIARDE.resolution == "EXACT" and byName.BULL_MONTBELIARDE.profileStatus == "MAP_REVIEW_ONLY")
check("profiles: an unknown breed is unresolved and a gap, never another breed's profile",
    byName.COW_AUBRAC.resolution == "UNRESOLVED" and byName.COW_AUBRAC.profile == nil and byName.COW_AUBRAC.gap == true)
check("profiles: Hof Bergmann's MILKCOW is listed as not covered, whatever its breed says",
    byName.MILK_COW.resolution == "NOT_COVERED" and byName.MILK_COW.profile == nil and byName.MILK_COW.gap == true)
check("profiles: other animal types are not listed", byName.PIG_TEST == nil and byName.PIG_LANDRACE == nil)
check("profiles: the filter matches part of a subtype or breed name",
    #RLWeightProfiles.enumerate("charola") == 3 and #RLWeightProfiles.enumerate("aubrac") == 1)


-- Where each setting comes from ----------------------------------------------------------------

do
    local bull, cow = byName.BULL_ANGUS, byName.COW_HOLSTEIN
    check(string.format("settings: an Angus bull's mature age (%.1f) comes from its subtype, its growth from its breed",
        bull.matureAgeMonth.value), bull.matureAgeMonth.source == "subType" and near(bull.matureAgeMonth.value, 52.2, 1e-9)
        and bull.growth.source == "breed" and bull.maturity.source == "breed" and bull.priceLine == true and bull.gap == false)
    check(string.format("settings: a Holstein cow's mature age falls back to 1.5 x her reproduction age (%.0f) and her growth "
        .. "to 0.6 of a male's: a gap", cow.matureAgeMonth.value), cow.matureAgeMonth.source == "default"
        and near(cow.matureAgeMonth.value, cow.reproductionMinAgeMonth * 1.5, 1e-9) and cow.femaleGrowth.source == "default"
        and near(cow.femaleGrowth.value, 0.6, 1e-9) and cow.gap == true)

    local pack = byName.BULL_CHAROLAIS_PACK
    local defaults, generic = table.concat(pack.defaults, " "), table.concat(pack.generic, " ")
    check(string.format("settings: a pack bull has no setting of its own (defaults: %s; type only: %s; price line %s)",
        defaults, generic, tostring(pack.priceLine)), pack.matureAgeMonth.source == "default" and pack.growth.source == "default"
        and pack.feed.source == "default" and pack.maturity.source == "type" and near(pack.maturity.value, 0.75, 1e-9)
        and pack.priceLine == false and pack.gap == true and generic == "maturity")
    check("settings: femaleGrowth is reported for females only", byName.BULL_ANGUS.femaleGrowth == nil and packCow.gender == "female"
        and byName.COW_CHAROLAIS_PACK.femaleGrowth ~= nil)
end


do
    -- The report reads the values the game uses, through the same getters and the same choices.
    local same = true
    for _, sub in ipairs(subTypes) do
        local record = byName[sub.name]
        if record ~= nil and record.matureAgeMonth ~= nil then
            if record.matureAgeMonth.value ~= RLBreedTraits.getMatureAge(sub) or record.growth.value ~= RLBreedTraits.get(sub, "growth")
                or (record.femaleGrowth ~= nil and record.femaleGrowth.value ~= RLBreedTraits.getFemaleGrowth(sub))
                or record.priceLine ~= (RLBreedTraits.getPriceModel(sub) ~= nil) then same = false end
        end
    end
    check("settings: every reported value is the getter's (mature age, growth, femaleGrowth, price line)", same)

    -- A price line with a zero target is no price line for the live price, nor for the report.
    local layers = RLBreedTraits.getConfig().layers
    local zero = add("BULL_ZEROPRICE", "CHAROLAIS_PACK", "male", COW_TYPE, 1000)
    layers.subTypes.BULL_ZEROPRICE = { priceTargetWeight = 0, priceMatureAgeMonth = 30 }
    local zeroRecord = RLWeightProfiles.describe(zero)
    layers.subTypes.BULL_ZEROPRICE = nil
    table.remove(subTypes)
    check("settings: a price target of 0 is reported as no price line, as the live price ignores it",
        zeroRecord.priceLine == false and RLBreedTraits.getPriceModel(zero) == nil)

    -- A subtype without a gender is read with femaleMaturity, as the slaughter reference reads it.
    local genderless = add("CATTLE_NOGENDER", "HOLSTEIN", nil, COW_TYPE, 700)
    local genderlessRecord = RLWeightProfiles.describe(genderless)
    table.remove(subTypes)
    local carcass = AnimalMoveEvent.getCarcassConfig().layers
    check(string.format("settings: a subtype without a gender is reported with femaleMaturity (%.2f), as the carcass code uses",
        genderlessRecord.maturity.value), near(genderlessRecord.maturity.value,
        RLBreedTraits.resolve(carcass, genderless, "femaleMaturity", 1), 1e-12) and genderlessRecord.femaleGrowth == nil)
end


-- Summary and log lines ------------------------------------------------------------------------

do
    local records = RLWeightProfiles.enumerate()
    local summary = RLWeightProfiles.summarize(records)
    local resolved = (summary.resolution.EXACT or 0) + (summary.resolution.ALIAS or 0)
    check(string.format("summary: %d subtypes = %d resolved + %d unresolved + %d not covered; unresolved breeds %s",
        summary.subTypes, resolved, summary.resolution.UNRESOLVED or 0, summary.resolution.NOT_COVERED or 0,
        table.concat(summary.unresolvedBreeds, " ")), summary.subTypes == #records
        and resolved + (summary.resolution.UNRESOLVED or 0) + (summary.resolution.NOT_COVERED or 0) == #records
        and table.concat(summary.unresolvedBreeds, " ") == "AUBRAC" and summary.resolution.ALIAS == 1)

    local longest, same = 0, true
    for _, sub in ipairs(subTypes) do
        if byName[sub.name] ~= nil then
            local line = RLWeightProfiles.emit(RLWeightProfiles.describe(sub))
            longest = math.max(longest, #line)
            same = same and line == RLWeightProfiles.emit(RLWeightProfiles.describe(sub))
        end
    end
    check(string.format("log: every record fits one log line (longest %d of %d) and the same subtype always gives the same line",
        longest, RLPenLog.MAX_LINE), longest < RLPenLog.MAX_LINE and same)

    local line = RLWeightProfiles.emit(byName.COW_CHAROLAISE)
    check("log: a record is a RLWEIGHT line of one-line JSON", line:find('^RLWEIGHT {"breed":"CHAROLAISE"') ~= nil
        and line:find('"resolution":"ALIAS"', 1, true) ~= nil and line:find("\n", 1, true) == nil)

    local text = RLWeightProfiles:consoleReport("charola")
    check("console: rlWeightProfiles reports the matching subtypes and the gaps", text:find("3 cattle subtypes", 1, true) ~= nil)
end


-- The layered lookup with its source -----------------------------------------------------------

do
    local same = true
    local layers = RLBreedTraits.getConfig().layers
    for _, sub in ipairs(subTypes) do
        for _, trait in ipairs(RLBreedTraits.TRAITS) do
            local value, source = RLBreedTraits.resolveSource(layers, sub, trait)
            local resolved = RLBreedTraits.resolve(layers, sub, trait, "none")
            if (source == nil and resolved ~= "none") or (source ~= nil and resolved ~= value) then same = false end
        end
    end
    check("lookup: resolveSource answers what resolve does, for every subtype and trait", same)
end


-- The file ---------------------------------------------------------------------------------------

do
    local config = RLWeightProfiles.getConfig()
    local profiles = 0
    for _ in pairs(config.profiles) do profiles = profiles + 1 end
    check(string.format("file: 22 physical breeds and 3 map names (%d / %d)", profiles,
        (function() local n = 0; for _ in pairs(config.aliases) do n = n + 1 end; return n end)()),
        profiles == 22 and config.aliases.CHAROLAISE.profile == "CHAROLAIS_PACK" and config.aliases.JERSEY.profile == "JERSEY_PACK")

    local xml = {
        iterate = function(_, key, fn)
            if key == "weightProfiles.profile" then fn(0, "p0") end
            if key == "weightProfiles.alias" then fn(0, "a0") end
        end,
        getString = function(_, key, default)
            local values = { ["p0#name"] = "angus", ["p0#status"] = "BASE", ["a0#breed"] = "x", ["a0#profile"] = "NOPE" }
            return values[key] or default
        end,
    }
    local before = #LOG
    local parsed = RLWeightProfiles.parse(xml)
    check("file: names are upper-cased, and an alias to a profile the file does not list is ignored with a warning",
        parsed.profiles.ANGUS ~= nil and parsed.aliases.X == nil and #LOG == before + 1 and LOG[#LOG]:find("NOPE", 1, true) ~= nil)
    table.remove(LOG)
end

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") or line:find("^warning") then check("no script error: " .. line, false) end
end
