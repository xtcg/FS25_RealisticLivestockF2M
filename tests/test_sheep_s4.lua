-- Sheep S4 (2026-10-11): sheep weight curves in xml/weightProfiles.xml, a type of their own and switched off.
-- Profiles of a non-cattle type are kept apart (SHEEP LANDRACE is not a cattle or pig breed); while the
-- type is off every sheep keeps the old weight rules and no cattle binding moves.

ANIMALS_XML = REPO .. "xml/animals.xml"
loadMod("tests/economics.lua")
loadMod("scripts/animal/RLWeightProfiles.lua")
loadMod("scripts/animal/RLGrowthCurve.lua")

local SHEEP_TYPE, COW_TYPE
for _, sub in ipairs(Economics.subTypes) do
    if sub.typeName == "SHEEP" then SHEEP_TYPE = sub.typeIndex end
    if sub.typeName == "COW" then COW_TYPE = sub.typeIndex end
end
local function sub(name, breed, gender, typeIndex) return { name = name, breed = breed, gender = gender, typeIndex = typeIndex } end
local PIG_TYPE = -5
local baseGetType = g_currentMission.animalSystem.getTypeByIndex
g_currentMission.animalSystem.getTypeByIndex = function(system, index)
    if index == PIG_TYPE then return { name = "PIG" } end
    return baseGetType(system, index)
end

local config = RLWeightProfiles.getConfig()
local BREEDS = { "LANDRACE", "STEINSCHAF", "SWISS_MOUNTAIN", "BLACK_WELSH", "TEXEL", "SUFFOLK", "BLUE_FACED_LEICESTER",
    "BORDER_LEICESTER", "BELCLARE", "DORSET", "CHEVIOT", "KERRY_HILL", "NORFOLK", "BLACKFACE", "EASYCARE", "JACOB" }

-- The file: 16 sheep breeds, both sexes, valid curves under keys of their own; the type is off.
local valid, missing = true, {}
for _, breed in ipairs(BREEDS) do
    local profile = config.profiles["SHEEP:" .. breed]
    if profile == nil or profile.invalid ~= nil or profile.typeName ~= "SHEEP" then
        missing[#missing + 1] = breed
    else
        for _, sex in ipairs({ "female", "male" }) do
            local ok = RLGrowthCurve.validate(profile.knots[sex])
            valid = valid and ok
        end
    end
end
check("file: 16 sheep profiles under SHEEP:<breed>, both sexes, knots rising from birth (" .. table.concat(missing, " ") .. ")",
    #missing == 0 and valid)
check("file: SHEEP is listed and switched off", config.types.SHEEP ~= nil and config.types.SHEEP.enabled == false)
check("file: no sheep breed lands among the cattle profiles", config.profiles.LANDRACE == nil and config.profiles.TEXEL == nil)

-- Off: sheep keep the old rules; cattle and pigs resolve as before.
local ewe = sub("SHEEP_LANDRACE", "LANDRACE", "female", SHEEP_TYPE)
local ram = sub("RAM_TEXEL", "TEXEL", "male", SHEEP_TYPE)
local goat = sub("GOAT", "GOAT", "female", SHEEP_TYPE)
local pig = sub("PIG_LANDRACE", "LANDRACE", "female", PIG_TYPE)
local holstein = sub("COW_HOLSTEIN", "HOLSTEIN", "female", COW_TYPE)
local bindingOf = function(s) local b, r = RLWeightProfiles.getCurveBinding(s); return b, r end
local _, eweOff = bindingOf(ewe)
check("off: a sheep has no curve (TYPE_OFF)", bindingOf(ewe) == nil and eweOff == "TYPE_OFF" and bindingOf(ram) == nil)
local _, pigWhy = bindingOf(pig)
check("off: a pig named LANDRACE is not a sheep or a cow (its own type, off since pig P4)", bindingOf(pig) == nil and pigWhy == "TYPE_OFF")
local cowBefore = {}
for _, s in ipairs(Economics.subTypes) do
    if s.typeName == "COW" then
        local b, r = bindingOf(s)
        cowBefore[s.name] = (b ~= nil and (b.profile .. "/" .. b.sex) or "nil") .. "/" .. r
    end
end
check("off: the cattle breed lookup is unchanged (no cattle LANDRACE)", RLWeightProfiles.resolveBreed("LANDRACE") == nil
    and RLWeightProfiles.resolveBreed("HOLSTEIN") == "HOLSTEIN")

check("off: a proxy type (MILKCOW) still reads the cattle breeds", RLWeightProfiles.resolveBreed("HOLSTEIN", "MILKCOW") == "HOLSTEIN"
    and RLWeightProfiles.resolveBreed("LANDRACE", "SHEEP") == "SHEEP:LANDRACE" and RLWeightProfiles.resolveBreed("LANDRACE", "PIG") == "PIG:LANDRACE")
local _, goatOff = bindingOf(goat)
check("off: a goat is NOT_COVERED (excludeBreeds), not a gap", goatOff == "NOT_COVERED")

-- On (for review): sheep resolve to their own profiles, goats stay out, cattle bindings do not move.
-- The switch is undone even when a check throws, so later checks see the type off.
config.types.SHEEP.enabled = true
local okOn, eweOn, eweWhy, ramOn, goatOnBinding, goatWhy = pcall(function()
    local b1, r1 = bindingOf(ewe)
    local b3, r3 = bindingOf(goat)
    return b1, r1, bindingOf(ram), b3, r3
end)
check("on: SHEEP_LANDRACE -> SHEEP:LANDRACE female, RAM_TEXEL -> SHEEP:TEXEL male (EXACT)",
    eweOn ~= nil and eweOn.profile == "SHEEP:LANDRACE" and eweOn.sex == "female" and eweWhy == "EXACT"
    and ramOn ~= nil and ramOn.profile == "SHEEP:TEXEL" and ramOn.sex == "male")
check("on: a goat has no sheep curve (NOT_COVERED, excluded)", okOn and goatOnBinding == nil and goatWhy == "NOT_COVERED")
local okSame, same = pcall(function()
    local all = true
    for _, s in ipairs(Economics.subTypes) do
        if s.typeName == "COW" then
            local b, r = bindingOf(s)
            all = all and cowBefore[s.name] == (b ~= nil and (b.profile .. "/" .. b.sex) or "nil") .. "/" .. r
        end
    end
    return all
end)
config.types.SHEEP.enabled = false
check("on: every cattle subtype's binding is the same as with sheep off", okOn and okSame and same and next(cowBefore) ~= nil)

-- The curves: birth as the game has it today, the ram lamb's market weight at its real intensive age,
-- 6 months and the yearling from LfL where it has them, mature at 36 months. Segments gain at most 0.47 kg a day;
-- the smooth curve's peak sits a little above its secant, at most about 0.50.
local function curveOf(breed, sex)
    local profile = config.profiles["SHEEP:" .. breed]
    return RLGrowthCurve.new(profile.knots[sex]), profile.knots[sex]
end
local landraceRam = curveOf("LANDRACE", "male")
local landraceEwe = curveOf("LANDRACE", "female")
check("curve: Landrace born 6.4 kg (ewe) / 6.85 kg (ram), as today", near(landraceEwe:value(0), 6.4, 0.01) and near(landraceRam:value(0), 6.848, 0.01))
check("curve: Landrace ram lamb 42.67 kg at 2.6 months (LfL 400-500 g a day), 72 kg at 6 (LfL 60-80), 108 at 15, 144 at 36",
    near(landraceRam:value(2.6), 42.67, 0.01) and near(landraceRam:value(6), 72, 0.01) and near(landraceRam:value(15), 108, 0.01)
    and near(landraceRam:value(36), 144, 0.01) and near(landraceRam:value(60), 144, 0.01))
local steinRam = curveOf("STEINSCHAF", "male")
check("curve: Steinschaf ram lamb 38 kg at 4.96 months (LfL 200-250 g a day), yearling 52 (LfL 40-60), 69 mature",
    near(steinRam:value(4.96), 38, 0.01) and near(steinRam:value(15), 52, 0.01) and near(steinRam:value(36), 69, 0.01))
local fastest, where = 0, ""
for _, breed in ipairs(BREEDS) do
    for _, sex in ipairs({ "female", "male" }) do
        local c = curveOf(breed, sex)
        for m = 0, 36, 0.25 do
            local adg = (c:value(m + 0.25) - c:value(m)) / (0.25 * 30)
            if adg > fastest then fastest, where = adg, breed .. " " .. sex .. " " .. m end
        end
    end
end
-- LfL fattening lambs average 400-500 g a day.
check(string.format("curve: no sheep gains more than 0.51 kg a day anywhere (most %.3f, %s)", fastest, where), fastest <= 0.51)
local heaviest, at = -1, ""
for _, breed in ipairs(BREEDS) do
    local f, m = curveOf(breed, "female"), curveOf(breed, "male")
    for t = 0, 40, 0.05 do
        local d = f:value(t) - m:value(t)
        if d > heaviest then heaviest, at = d, breed .. " " .. t end
    end
end
check(string.format("curve: no ewe outweighs her breed's ram at any age (closest %.2f kg, %s)", heaviest, at), heaviest < 0)
local function eweSix(breed)
    local profile = config.profiles["SHEEP:" .. breed]
    local ram6 = curveOf(breed, "male"):value(6)
    return profile.knots.female[1][2] + 0.76 * (ram6 - profile.knots.male[1][2]), curveOf(breed, "female"):value(6)
end
local formula, actual = eweSix("BORDER_LEICESTER")
local lflFormula, lflActual = eweSix("LANDRACE")
check(string.format("curve: a ewe lamb without LfL figures is at 0.76 of the ram's gain at 6 months (Border Leicester %.1f = %.1f), as LfL Merinolandschaf (%.1f vs 56)",
    formula, actual, lflFormula), near(actual, formula, 0.06) and near(lflActual, 56, 0.01) and near(lflFormula, 56, 0.2))

-- The report: with the type off, a sheep is TYPE_OFF with its curve shown inactive; a goat NOT_COVERED, no gap.
local eweRecord = RLWeightProfiles.describe(ewe)
check("report: a sheep with the type off is TYPE_OFF (EXACT profile), its curve shown but not active",
    eweRecord.resolution == "TYPE_OFF" and eweRecord.profileResolution == "EXACT" and eweRecord.profile == "SHEEP:LANDRACE"
    and eweRecord.curve ~= nil and eweRecord.curve.active == false and near(eweRecord.curve.adultKg, 88, 0.01))
local goatRecord = RLWeightProfiles.describe(goat)
check("report: a goat is NOT_COVERED and no gap", goatRecord.resolution == "NOT_COVERED" and goatRecord.gap == false)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") or line:find("^warning") then check("no warning or error: " .. line, false) end
end
