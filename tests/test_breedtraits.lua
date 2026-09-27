-- Breed husbandry traits (RLBreedTraits, xml/breedTraits.xml): feed, growth and forage.

TYPES = { [1] = { name = "COW" }, [2] = { name = "SHEEP" }, [3] = { name = "HORSE" }, [4] = { name = "PIG" } }
local highland = { typeIndex = 1, name = "COW_HIGHLAND_CATTLE", breed = "HIGHLAND", minWeight = 35, reproductionMinAgeMonth = 12 }
local holstein = { typeIndex = 1, name = "COW_HOLSTEIN", breed = "HOLSTEIN", minWeight = 42, reproductionMinAgeMonth = 12 }
local bull = { typeIndex = 1, name = "BULL", minWeight = 40, reproductionMinAgeMonth = 12 }
local goat = { typeIndex = 2, name = "GOAT", breed = "GOAT", minWeight = 3.75, reproductionMinAgeMonth = 8 }
local horse = { typeIndex = 3, name = "HORSE_GRAY", breed = "GRAY" }
local limousinBull = { typeIndex = 1, name = "BULL_LIMOUSIN", breed = "LIMOUSIN", minWeight = 42, reproductionMinAgeMonth = 12 }
local landraceBoar = { typeIndex = 4, name = "BOAR_LANDRACE", breed = "LANDRACE", minWeight = 1.5, reproductionMinAgeMonth = 8 }
local landraceGilt = { typeIndex = 4, name = "PIG_LANDRACE", breed = "LANDRACE", minWeight = 1.5, reproductionMinAgeMonth = 8 }

g_currentMission = { animalSystem = { getTypeByIndex = function(_, i) return TYPES[i] end } }
local FILL = { [1] = "GRASS_WINDROW", [2] = "DRYGRASS_WINDROW", [3] = "SILAGE", [4] = "FORAGE", [5] = "SUGARBEET_CUT",
    [6] = "CLOVER_WINDROW" }
g_fillTypeManager = { getFillTypeNameByIndex = function(_, i) return FILL[i] end }
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

loadMod("scripts/animal/RLBreedTraits.lua")

local config = RLBreedTraits.getConfig()
check("config: shipped xml/breedTraits.xml is read",
    near(config.growthNutritionFactor, 1.1) and near(config.bodyWeightExponent, 0.35)
    and config.forage.GRASS_WINDROW == "grass" and config.forage.CLOVER_WINDROW == "hay" and config.forage.FORAGE == "silage")

check("traits: breed values", near(RLBreedTraits.get(highland, "feed"), 0.8) and near(RLBreedTraits.get(holstein, "silage"), 1.1)
    and near(RLBreedTraits.get(goat, "grass"), 1.15))
check("traits: 1 for a breed or type the file leaves out", RLBreedTraits.get(bull, "growth") == 1
    and RLBreedTraits.get(horse, "feed") == 1 and RLBreedTraits.get(nil, "feed") == 1)

-- Growth line: matureAgeMonth (subtype over breed) or 1.5 x reproductionMinAgeMonth; femaleGrowth.
check("mature age: 1.5 x reproduction age where the file sets none", near(RLBreedTraits.getMatureAge(holstein), 18)
    and RLBreedTraits.getMatureAge(nil) == 0)
check("mature age: subtype over breed", near(RLBreedTraits.getMatureAge(limousinBull), 35.7)
    and near(RLBreedTraits.getMatureAge(landraceBoar), 16.3) and near(RLBreedTraits.getMatureAge(landraceGilt), 12.2))
check("female growth: 0.95 for pigs, 0.6 elsewhere", near(RLBreedTraits.getFemaleGrowth(landraceGilt), 0.95)
    and near(RLBreedTraits.getFemaleGrowth(holstein), 0.6) and near(RLBreedTraits.getFemaleGrowth(goat), 0.6))
check("expected weight: linear to the target by the mature age, then flat",
    near(RLBreedTraits.getExpectedWeight(holstein, 680, 9), 42 + (680 - 42) * 0.5)
    and near(RLBreedTraits.getExpectedWeight(holstein, 680, 60), 680) and near(RLBreedTraits.getExpectedWeight(holstein, 680, nil), 680))

-- Body condition: expected weight grows linearly to the target by the mature age.
check("body: adult at its target weight -> 1", near(RLBreedTraits.getBodyFeedFactor(holstein, 680, 680, 60), 1))
check("body: adult at 1000 vs a 500 target -> 1.5 ^ 0.35 (clamped)",
    near(RLBreedTraits.getBodyFeedFactor(holstein, 1000, 500, 60), 1.5 ^ 0.35))
check("body: adult at 400 vs a 500 target -> 0.8 ^ 0.35", near(RLBreedTraits.getBodyFeedFactor(holstein, 400, 500, 60), 0.8 ^ 0.35))
check("body: a calf on its growth line eats its curve",
    near(RLBreedTraits.getBodyFeedFactor(holstein, 42 + (680 - 42) * 0.5, 680, 9), 1))
check("body: 1 without weight or target", RLBreedTraits.getBodyFeedFactor(holstein, nil, 680, 9) == 1
    and RLBreedTraits.getBodyFeedFactor(nil, 500, 680, 9) == 1)

-- Forage shares from one feeding's fill level change.
local shares = RLBreedTraits.getForageShares({ [1] = 100, [3] = 50, [5] = 20 }, { [1] = 70, [3] = 40, [5] = 10 }, false)
check("shares: by category of what was eaten, others count toward the total",
    near(shares.grass, 0.6) and near(shares.silage, 0.2) and shares.hay == nil)
check("shares: nothing eaten -> nil, or grass with a meadow",
    RLBreedTraits.getForageShares({ [1] = 10 }, { [1] = 10 }, false) == nil
    and RLBreedTraits.getForageShares({}, {}, true).grass == 1)
check("shares: a fill type emptied this feeding counts",
    RLBreedTraits.getForageShares({ [2] = 5 }, {}, false).hay == 1)

check("efficiency: Highland on pure grass -> 1.25",
    near(RLBreedTraits.getForageEfficiency(highland, { grass = 1 }), 1.25))
check("efficiency: Holstein on 60% grass, 20% silage, 20% other -> 0.6x0.9 + 0.2x1.1 + 0.2",
    near(RLBreedTraits.getForageEfficiency(holstein, shares), 0.96))
check("efficiency: 1 without shares", RLBreedTraits.getForageEfficiency(highland, nil) == 1)
