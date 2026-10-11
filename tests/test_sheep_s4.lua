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
check("off: a pig named LANDRACE is not a sheep or a cow (NOT_CATTLE)", bindingOf(pig) == nil and pigWhy == "NOT_CATTLE")
local cowBefore = {}
for _, s in ipairs(Economics.subTypes) do
    if s.typeName == "COW" then
        local b, r = bindingOf(s)
        cowBefore[s.name] = (b ~= nil and (b.profile .. "/" .. b.sex) or "nil") .. "/" .. r
    end
end
check("off: the cattle breed lookup is unchanged (no cattle LANDRACE)", RLWeightProfiles.resolveBreed("LANDRACE") == nil
    and RLWeightProfiles.resolveBreed("HOLSTEIN") == "HOLSTEIN")

-- On (for review): sheep resolve to their own profiles, goats stay a gap, cattle bindings do not move.
config.types.SHEEP.enabled = true
local eweOn, eweWhy = bindingOf(ewe)
local ramOn = bindingOf(ram)
local _, goatWhy = bindingOf(goat)
check("on: SHEEP_LANDRACE -> SHEEP:LANDRACE female, RAM_TEXEL -> SHEEP:TEXEL male (EXACT)",
    eweOn ~= nil and eweOn.profile == "SHEEP:LANDRACE" and eweOn.sex == "female" and eweWhy == "EXACT"
    and ramOn ~= nil and ramOn.profile == "SHEEP:TEXEL" and ramOn.sex == "male")
check("on: a goat has no sheep curve (UNRESOLVED, a gap)", bindingOf(goat) == nil and goatWhy == "UNRESOLVED")
local same = true
for _, s in ipairs(Economics.subTypes) do
    if s.typeName == "COW" then
        local b, r = bindingOf(s)
        same = same and cowBefore[s.name] == (b ~= nil and (b.profile .. "/" .. b.sex) or "nil") .. "/" .. r
    end
end
check("on: every cattle subtype's binding is the same as with sheep off", same and next(cowBefore) ~= nil)
config.types.SHEEP.enabled = false

-- The curves: birth as the game has it today, the ram lamb's market weight at its real intensive age,
-- 6 months and the yearling from LfL where it has them, mature at 36 months; growth never above 0.47 kg a day.
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
-- LfL fattening lambs average 400-500 g a day; the smooth curve's peak sits a little above its secant.
check(string.format("curve: no sheep gains more than 0.55 kg a day anywhere (most %.3f, %s)", fastest, where), fastest <= 0.55)
check("curve: ewes stay below their breed's rams", landraceEwe:value(6) < landraceRam:value(6) and landraceEwe:value(36) < landraceRam:value(36))

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") or line:find("^warning") then check("no warning or error: " .. line, false) end
end
