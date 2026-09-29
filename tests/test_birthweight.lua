-- Birth weight of newborns (RLBirthWeight, birth traits in xml/breedTraits.xml).

TYPES = {
    [1] = { name = "COW", subTypes = { 1, 2, 3, 4 } },
    [2] = { name = "PIG", subTypes = { 5, 6 } },
    [3] = { name = "SHEEP", subTypes = { 7, 8 } },
    [4] = { name = "GOOSE", subTypes = { 9 } },
    [5] = { name = "HORSE", subTypes = { 10, 11 } },
}
SUBS = {
    [1] = { typeIndex = 1, name = "COW_HOLSTEIN", breed = "HOLSTEIN", gender = "female", targetWeight = 680, minWeight = 42, reproductionMinAgeMonth = 12 },
    [2] = { typeIndex = 1, name = "BULL_HOLSTEIN", breed = "HOLSTEIN", gender = "male", targetWeight = 1000, minWeight = 45, reproductionMinAgeMonth = 12 },
    [3] = { typeIndex = 1, name = "COW_ANGUS", breed = "ANGUS", gender = "female", targetWeight = 650, minWeight = 32, reproductionMinAgeMonth = 12 },
    [4] = { typeIndex = 1, name = "BULL_ANGUS", breed = "ANGUS", gender = "male", targetWeight = 850, minWeight = 35, reproductionMinAgeMonth = 12 },
    [5] = { typeIndex = 2, name = "PIG_LANDRACE", breed = "LANDRACE", gender = "female", targetWeight = 240, minWeight = 1.36, reproductionMinAgeMonth = 8 },
    [6] = { typeIndex = 2, name = "BOAR_LANDRACE", breed = "LANDRACE", gender = "male", targetWeight = 300, minWeight = 1.4, reproductionMinAgeMonth = 8 },
    [7] = { typeIndex = 3, name = "SHEEP_LANDRACE", breed = "LANDRACE", gender = "female", targetWeight = 55, minWeight = 4.4, reproductionMinAgeMonth = 8 },
    [8] = { typeIndex = 3, name = "RAM_LANDRACE", breed = "LANDRACE", gender = "male", targetWeight = 75, minWeight = 4.7, reproductionMinAgeMonth = 8 },
    [9] = { typeIndex = 4, name = "GOOSE", breed = "GOOSE", gender = "female", targetWeight = 5, minWeight = 0.5, reproductionMinAgeMonth = 10 },
    [10] = { typeIndex = 5, name = "HORSE_GRAY", breed = "GRAY", gender = "female", targetWeight = 500, minWeight = 45, reproductionMinAgeMonth = 24 },
    [11] = { typeIndex = 5, name = "STALLION_GRAY", breed = "GRAY", gender = "male", targetWeight = 575, minWeight = 48, reproductionMinAgeMonth = 24 },
}
g_currentMission = { animalSystem = {
    subTypes = SUBS,
    getTypeByIndex = function(_, i) return TYPES[i] end,
    getSubTypeByIndex = function(_, i) return SUBS[i] end,
} }
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animal/RLBirthWeight.lua")

local B = RLBirthWeight
local HOL_COW, HOL_BULL, ANG_COW, ANG_BULL = SUBS[1], SUBS[2], SUBS[3], SUBS[4]
local GILT, BOAR, EWE, RAM, GOOSE, MARE, COLT = SUBS[5], SUBS[6], SUBS[7], SUBS[8], SUBS[9], SUBS[10], SUBS[11]

-- Breed mean: ratio x the breed female's target weight, x maleBirthFactor for males.
check("mean: Holstein heifer calf 6.18% of 680 = 42.0 kg", near(B.getBreedMean(HOL_COW), 42.02, 0.01))
check("mean: Holstein bull calf from the cow's target, x1.07 = 45.0 kg", near(B.getBreedMean(HOL_BULL), 44.97, 0.01))
check("mean: Angus 32.0 / 34.2 kg", near(B.getBreedMean(ANG_COW), 31.98, 0.01) and near(B.getBreedMean(ANG_BULL), 34.22, 0.01))
check("mean: Landrace piglet 1.40 / 1.45 kg", near(B.getBreedMean(GILT), 1.399, 0.001) and near(B.getBreedMean(BOAR), 1.448, 0.001))
check("mean: Landrace lamb 4.40 / 4.71 kg", near(B.getBreedMean(EWE), 4.40) and near(B.getBreedMean(RAM), 4.708, 0.001))
check("mean: foal from the type-level ratio, 50 / 52 kg", near(B.getBreedMean(MARE), 50) and near(B.getBreedMean(COLT), 52))
local gooseMean, configured = B.getBreedMean(GOOSE)
check("mean: unconfigured species keeps its minWeight, no +0.5 kg", gooseMean == 0.5 and configured == false)

-- Birth mean follows the target weight.
HOL_COW.targetWeight = 750
check("mean: a heavier Holstein target gives heavier calves", near(B.getBreedMean(HOL_COW), 46.35, 0.01)
    and near(B.getBreedMean(HOL_BULL), 49.59, 0.01))
HOL_COW.targetWeight = 680

-- Litter size
check("litter: calf twins 85%, triplets 75%", near(B.getLitterFactor(HOL_COW, 2), 0.85) and near(B.getLitterFactor(HOL_COW, 3), 0.75))
check("litter: lambs 1 / 2 / 3 / 5", B.getLitterFactor(EWE, 1) == 1 and near(B.getLitterFactor(EWE, 2), 0.85)
    and near(B.getLitterFactor(EWE, 3), 0.72) and near(B.getLitterFactor(EWE, 5), 0.65))
check("litter: piglets 2% per piglet off 12, clamped 0.80-1.15", near(B.getLitterFactor(GILT, 12), 1)
    and near(B.getLitterFactor(GILT, 15), 0.94) and near(B.getLitterFactor(GILT, 8), 1.08)
    and near(B.getLitterFactor(GILT, 30), 0.80) and near(B.getLitterFactor(GILT, 1), 1.15))
check("litter: foal twins 80%", near(B.getLitterFactor(MARE, 2), 0.80))
check("litter: unconfigured species unchanged", B.getLitterFactor(GOOSE, 6) == 1)

-- Dam condition
local function dam(subType, weight, age)
    return { weight = weight, targetWeight = subType.targetWeight, age = age, getSubType = function() return subType end }
end
check("dam: in condition -> 1", near(B.getDamConditionFactor(dam(HOL_COW, 680, 60)), 1))
check("dam: thin (70% of expected) -> sqrt(0.7) clamped to 0.85", near(B.getDamConditionFactor(dam(HOL_COW, 476, 60)), 0.85))
check("dam: 90% -> sqrt(0.9)", near(B.getDamConditionFactor(dam(HOL_COW, 612, 60)), math.sqrt(0.9), 0.001))
check("dam: fat -> at most 1.05", near(B.getDamConditionFactor(dam(HOL_COW, 900, 60)), 1.05))

-- Birth mean with every factor
local ctx = { dam = dam(HOL_COW, 680, 60), damBreed = "HOLSTEIN", sireBreed = "HOLSTEIN", litterSize = 1, firstBirth = false, metabolism = 1 }
check("birth mean: purebred single from a grown cow = breed mean", near(B.getMean(HOL_COW, ctx), 42.02, 0.01))
ctx.firstBirth = true
check("birth mean: heifer's first calf 93%", near(B.getMean(HOL_COW, ctx), 42.02 * 0.93, 0.01))
ctx.firstBirth, ctx.litterSize = false, 2
check("birth mean: twin 85%", near(B.getMean(HOL_COW, ctx), 42.02 * 0.85, 0.01))
ctx.litterSize, ctx.metabolism = 1, 1.5
check("birth mean: metabolism 1.5 -> +2.5%", near(B.getMean(HOL_COW, ctx), 42.02 * 1.025, 0.01))
ctx.metabolism, ctx.sireBreed = 1, "ANGUS"
check("birth mean: Angus sire on a Holstein cow, mean of both breeds", near(B.getMean(HOL_COW, ctx), (42.02 + 31.98) / 2, 0.01))
check("birth mean: cross works whichever breed the calf takes", near(B.getMean(ANG_BULL, ctx), (44.97 + 34.22) / 2, 0.01))

-- Normal draw: mean and CV over many draws, truncated at 2.5 SD.
math.randomseed(12345)
local n, sum, sumSq, maxAbsZ = 20000, 0, 0, 0
ctx = { dam = dam(HOL_COW, 680, 60), damBreed = "HOLSTEIN", sireBreed = "HOLSTEIN", litterSize = 1, metabolism = 1 }
for _ = 1, n do
    local w, z = B.draw(HOL_COW, ctx)
    sum, sumSq = sum + w, sumSq + w * w
    maxAbsZ = math.max(maxAbsZ, math.abs(z))
end
local mean = sum / n
local sd = math.sqrt(sumSq / n - mean * mean)
check("draw: calves average 42.0 kg", near(mean, 42.02, 0.15))
check("draw: calves spread with CV ~10% (a little under, truncated)", sd / mean > 0.093 and sd / mean < 0.101)
check("draw: nothing beyond 2.5 SD", maxAbsZ <= 2.5)

sum, sumSq = 0, 0
local litter = { dam = dam(GILT, 240, 24), damBreed = "LANDRACE", sireBreed = "LANDRACE", litterSize = 12, metabolism = 1 }
for _ = 1, n do
    local w = B.draw(GILT, litter)
    sum, sumSq = sum + w, sumSq + w * w
end
mean = sum / n
sd = math.sqrt(sumSq / n - mean * mean)
check("draw: piglets average 1.40 kg with CV ~20%", near(mean, 1.399, 0.01) and sd / mean > 0.185 and sd / mean < 0.202)

-- Birth survival: a species baseline, modest health modifier, and species-specific weight risk.
check("survival: average calf baseline is 97%", near(B.getSurvivalChance(HOL_COW, 1, 0), 0.97))
check("survival: calf health 0.5 / 1.5 changes baseline by -/+10%",
    near(B.getSurvivalChance(HOL_COW, 0.5, 0), 0.97 * 0.90)
    and near(B.getSurvivalChance(HOL_COW, 1.5, 0), 0.97 * 1.10))
check("survival: very light calf (-2.5 SD) gets cattle low-weight penalty",
    near(B.getSurvivalChance(HOL_COW, 1, -2.5), 0.97 * 0.93))
check("survival: very heavy calf (+2.5 SD) gets cattle dystocia penalty",
    near(B.getSurvivalChance(HOL_COW, 1, 2.5), 0.97 * (1 - 0.12 * 1.2)))
check("survival: average piglet baseline is 94%", near(B.getSurvivalChance(GILT, 1, 0), 0.94))
check("survival: 1 SD-light piglet already gets a small penalty",
    near(B.getSurvivalChance(GILT, 1, -1.0), 0.94 * 0.98))
check("survival: heavy piglet has no high-weight penalty",
    near(B.getSurvivalChance(GILT, 1, 2.5), 0.94))

-- minWeight follows the breed mean at load; unconfigured species keep theirs.
B.syncMinWeights(g_currentMission.animalSystem)
check("sync: minWeight set to the breed means", near(HOL_BULL.minWeight, 44.97, 0.01) and near(BOAR.minWeight, 1.448, 0.001)
    and near(COLT.minWeight, 52) and HOL_BULL.configMinWeight == 45)
check("sync: unconfigured goose keeps 0.5", GOOSE.minWeight == 0.5)
