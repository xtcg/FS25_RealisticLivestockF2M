-- Pig P4 (2026-10-16): pig weight curves in xml/weightProfiles.xml, a type of their own, switched off and needing
-- the real-equivalent nutrition model. Knots are measured points where a source has them
-- (FS25_PigBreeds_离线准备_2026-10-16/生长数据核对_v2.md); the birth means are one number in both paths
-- (breedTraits.xml birthFemaleKg for the old rules, the profile's for the curves). While the type is off every pig
-- keeps the old weight rules and no cattle or sheep binding or setting moves.

ANIMALS_XML = REPO .. "xml/animals.xml"
loadMod("tests/economics.lua")
loadMod("scripts/animal/RLBirthWeight.lua")

local TYPE = {}
local SUB = {}
for _, s in ipairs(Economics.subTypes) do
    TYPE[s.typeName] = s.typeIndex
    SUB[s.name] = s
end
local config = RLWeightProfiles.getConfig()
local BREEDS = { "LANDRACE", "BLACK_PIED", "BERKSHIRE" }
local bindingOf = function(s) return RLWeightProfiles.getCurveBinding(s) end

-- The file.
local ok, missing = true, {}
for _, breed in ipairs(BREEDS) do
    local profile = config.profiles["PIG:" .. breed]
    if profile == nil or profile.invalid ~= nil or profile.typeName ~= "PIG" then
        missing[#missing + 1] = breed
    else
        for _, sex in ipairs({ "female", "male" }) do ok = ok and RLGrowthCurve.validate(profile.knots[sex]) == true end
    end
end
check("file: 3 pig profiles under PIG:<breed>, both sexes, valid knots (" .. table.concat(missing, " ") .. ")", #missing == 0 and ok)
local pigType = config.types.PIG
check("file: PIG is listed, switched off, and needs the real-equivalent nutrition model",
    pigType ~= nil and pigType.enabled == false and pigType.nutrition == "REAL" and pigType.invalidReason == nil)
check("file: PIG:LANDRACE is not SHEEP:LANDRACE and no pig breed is a cattle profile",
    config.profiles["SHEEP:LANDRACE"] ~= nil and config.profiles["PIG:LANDRACE"] ~= config.profiles["SHEEP:LANDRACE"]
    and config.profiles.LANDRACE == nil and config.profiles.BERKSHIRE == nil and config.profiles.BLACK_PIED == nil)

-- Settings: the pig type's own (sourced), cattle and sheep untouched.
local ps = RLWeightProfiles.getSettings("PIG")
check("settings: pig maleBirthFactor 1.035, birthWeightCV 0.20, firstBirthFactor 1, castratedSpeed 1.0",
    ps.maleBirthFactor == 1.035 and ps.birthWeightCV == 0.20 and ps.firstBirthFactor == 1 and ps.castratedSpeed == 1.0)
check("settings: pig litter 1 - 0.024 x (n - 12), clamped 0.80-1.15",
    ps.litterBase == 12 and ps.litterStep == 0.024 and ps.litterMin == 0.80 and ps.litterMax == 1.15)
local root, sheep = config.settings, RLWeightProfiles.getSettings("SHEEP")
check("settings: cattle root and sheep keep litter2/3/4 (litterBase 0) and their own birth settings",
    root.litterBase == 0 and sheep.litterBase == 0 and root.maleBirthFactor == 1.07 and root.castratedSpeed == 0.90
    and sheep.castratedSpeed == 0.86 and root.firstBirthFactor == 0.93 and sheep.birthWeightCV == 0.10)

-- The v2 litter factor.
local holstein, ewe, gilt = SUB.COW_HOLSTEIN, SUB.SHEEP_LANDRACE, SUB.PIG_LANDRACE
check("litter: cattle 1 / 0.85 / 0.75 / 0.70 as before",
    RLGrowth.getLitterFactor(1, holstein) == 1 and RLGrowth.getLitterFactor(2, holstein) == 0.85
    and RLGrowth.getLitterFactor(3, holstein) == 0.75 and RLGrowth.getLitterFactor(4, holstein) == 0.70)
check("litter: sheep as before (litter2/3/4 of the root)", RLGrowth.getLitterFactor(1, ewe) == 1
    and RLGrowth.getLitterFactor(2, ewe) == root.litter2 and RLGrowth.getLitterFactor(3, ewe) == root.litter3)
check("litter: piglets 1 at 12, 0.904 at 16, 1.096 at 8, clamped at 1 and 30", near(RLGrowth.getLitterFactor(12, gilt), 1, 1e-12)
    and near(RLGrowth.getLitterFactor(16, gilt), 0.904, 1e-9) and near(RLGrowth.getLitterFactor(8, gilt), 1.096, 1e-9)
    and RLGrowth.getLitterFactor(1, gilt) == 1.15 and RLGrowth.getLitterFactor(30, gilt) == 0.80)
check("litter: the v2 factor equals the old rules' (breedTraits.xml) for 1-16 piglets", (function()
    for n = 1, 16 do
        if not near(RLGrowth.getLitterFactor(n, gilt), RLBirthWeight.getLitterFactor(gilt, n), 1e-12) then return false end
    end
    return true
end)())

-- One birth mean in both paths.
local same = true
for _, breed in ipairs(BREEDS) do
    for _, prefix in ipairs({ "PIG_", "BOAR_" }) do
        local s = SUB[prefix .. breed]
        local sex = prefix == "PIG_" and "female" or "male"
        local old = RLBirthWeight.getBreedMean(s)
        local curve = config.profiles["PIG:" .. breed].knots[sex][1][2]
        same = same and s ~= nil and near(old, curve, 1e-9)
    end
end
check("birth: the old rules' mean (birthFemaleKg x 1.035) is the curve's birth knot for all six pig subtypes", same)
check("birth: Landrace 1.494 / 1.546, Berkshire 1.42 / 1.470, Black pied 1.444 / 1.495 kg",
    near(RLBirthWeight.getBreedMean(SUB.PIG_LANDRACE), 1.494, 1e-6) and near(RLBirthWeight.getBreedMean(SUB.BOAR_LANDRACE), 1.54629, 1e-5)
    and near(RLBirthWeight.getBreedMean(SUB.PIG_BERKSHIRE), 1.42, 1e-6) and near(RLBirthWeight.getBreedMean(SUB.BOAR_BERKSHIRE), 1.4697, 1e-5)
    and near(RLBirthWeight.getBreedMean(SUB.PIG_BLACK_PIED), 1.444, 1e-6) and near(RLBirthWeight.getBreedMean(SUB.BOAR_BLACK_PIED), 1.49454, 1e-5))
check("birth: cattle and sheep still from their ratio (Holstein 6.18% of the cow)",
    near(RLBirthWeight.getBreedMean(holstein), 0.0618 * holstein.targetWeight, 0.05))

-- Off: pigs keep the old rules; cattle and sheep resolve as before.
local pig, boar = SUB.PIG_LANDRACE, SUB.BOAR_BERKSHIRE
local _, pigWhy = bindingOf(pig)
check("off: a pig has no curve (TYPE_OFF), no v2 birth mean", bindingOf(pig) == nil and pigWhy == "TYPE_OFF"
    and RLGrowth.getBirthMeanFor(pig, { litterSize = 12 }) == nil)
check("off: breed lookups by type stay apart", RLWeightProfiles.resolveBreed("LANDRACE", "PIG") == "PIG:LANDRACE"
    and RLWeightProfiles.resolveBreed("LANDRACE", "SHEEP") == "SHEEP:LANDRACE" and RLWeightProfiles.resolveBreed("LANDRACE") == nil)
local before = {}
for _, s in ipairs(Economics.subTypes) do
    if s.typeName ~= "PIG" then
        local b, r = bindingOf(s)
        before[s.name] = (b ~= nil and (b.profile .. "/" .. b.sex) or "nil") .. "/" .. tostring(r)
    end
end

-- On (for review): the pig curves resolve; nothing else moves; still not covered without a PIG nutrition section.
pigType.enabled = true
local okOn, gb, gr, bb, unchanged, covered = pcall(function()
    local b1, r1 = bindingOf(pig)
    local b2 = bindingOf(boar)
    local all = true
    for _, s in ipairs(Economics.subTypes) do
        if s.typeName ~= "PIG" then
            local b, r = bindingOf(s)
            all = all and before[s.name] == (b ~= nil and (b.profile .. "/" .. b.sex) or "nil") .. "/" .. tostring(r)
        end
    end
    return b1, r1, b2, all, RLGrowth.speciesNutritionReady("PIG")
end)
pigType.enabled = false
check("on: PIG_LANDRACE -> PIG:LANDRACE female, BOAR_BERKSHIRE -> PIG:BERKSHIRE male (EXACT)", okOn and gb ~= nil
    and gb.profile == "PIG:LANDRACE" and gb.sex == "female" and gr == "EXACT" and bb ~= nil and bb.profile == "PIG:BERKSHIRE" and bb.sex == "male")
check("on: every cattle and sheep subtype's binding is the same as with pigs off", okOn and unchanged == true and next(before) ~= nil)
check("on: the pig type is not ready to run (no PIG section in feedProfiles.xml / bodyCondition.xml)", okOn and covered == false)

-- The curves at their measured points.
local function curveOf(breed, sex) return RLGrowthCurve.new(config.profiles["PIG:" .. breed].knots[sex]) end
local function ageAt(curve, kg) return curve:inverse(kg) * 30 end
local lrF, lrM = curveOf("LANDRACE", "female"), curveOf("LANDRACE", "male")
check("curve: Landrace gilt 30 kg at 78.3 days, 105 kg at 145.5 (DanBred 2025 364 / 1117 g a day)",
    near(ageAt(lrF, 30), (30 - 1.494) / 0.364, 0.05) and near(ageAt(lrF, 105), (30 - 1.494) / 0.364 + 75 / 1.117, 0.05))
check("curve: Landrace boar 30 kg at 78.8 days, 105 kg at 143.3 (361 / 1164 g a day)",
    near(ageAt(lrM, 30), (30 - 1.5463) / 0.361, 0.05) and near(ageAt(lrM, 105), (30 - 1.5463) / 0.361 + 75 / 1.164, 0.05))
local bkF, bkM = curveOf("BERKSHIRE", "female"), curveOf("BERKSHIRE", "male")
check("curve: Berkshire gilt 6.48 / 25.7 / 88.5 kg at 22.9 / 72.7 / 152.4 days (Korean herd LS means)",
    near(bkF:value(22.9 / 30), 6.48, 0.001) and near(bkF:value(72.7 / 30), 25.7, 0.001) and near(bkF:value(152.4 / 30), 88.5, 0.001))
check("curve: Berkshire boar 6.55 / 26.1 / 92.2 kg at the same ages", near(bkM:value(22.9 / 30), 6.55, 0.001)
    and near(bkM:value(72.7 / 30), 26.1, 0.001) and near(bkM:value(152.4 / 30), 92.2, 0.001))
local adultOk = true
for _, breed in ipairs(BREEDS) do
    for _, prefix in ipairs({ "PIG_", "BOAR_" }) do
        local s = SUB[prefix .. breed]
        local c = curveOf(breed, prefix == "PIG_" and "female" or "male")
        adultOk = adultOk and c:value(24) == s.targetWeight and c:value(40) == s.targetWeight
    end
end
check("curve: every pig curve flat at its animals.xml targetWeight from 24 months", adultOk)
local fastest, where = 0, ""
for _, breed in ipairs(BREEDS) do
    for _, sex in ipairs({ "female", "male" }) do
        local c = curveOf(breed, sex)
        for d = 0, 720 do
            local g = c:slope(d / 30) / 30
            if g > fastest then fastest, where = g, breed .. " " .. sex .. " day " .. d end
        end
    end
end
check(string.format("curve: no pig gains more than 1.40 kg a model day (fastest %.3f, %s)", fastest, where), fastest < 1.40)
