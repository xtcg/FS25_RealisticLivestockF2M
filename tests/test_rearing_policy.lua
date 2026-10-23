-- RLRearingPolicy (batch A of the unified nursing design, 2026-10-22): what each subtype is kept for,
-- which genes it really has, and that beef cattle - cows, bulls and calves - have no milk yield gene
-- anywhere: not drawn, not inherited, not scored, not valued. Dairy cattle, goats, sheep (wool) and
-- poultry keep theirs; pigs and horses never get one.

loadMod("tests/breedingvalue_fixture.lua")
loadMod("scripts/animal/RLRearingPolicy.lua")
loadMod("scripts/core/RLConstants.lua")
loadMod("scripts/animal/RLGenetics.lua")
loadMod("scripts/insemination/RLSemenCollection.lua")

local function sub(name) return assert(BV_SUB[name], name) end
local function packSub(name, gender)
    -- A Cow Breeds pack subtype the way the pack's animals.xml has it (breed = name minus the prefix).
    return { name = name, breed = name:match("^%u+_(.+)$"), typeIndex = sub("COW_ANGUS").typeIndex, gender = gender }
end


-- Production use -----------------------------------------------------------------------------------

do
    local beef, dairy = true, true
    for _, name in ipairs({ "COW_ANGUS", "BULL_ANGUS", "COW_HEREFORD", "BULL_HEREFORD", "COW_LIMOUSIN", "BULL_LIMOUSIN",
        "COW_HIGHLAND_CATTLE", "BULL_HIGHLAND_CATTLE" }) do
        beef = beef and RLRearingPolicy.getUse(sub(name)) == "BEEF"
    end
    for _, name in ipairs({ "COW_HOLSTEIN", "BULL_HOLSTEIN", "COW_SWISS_BROWN", "BULL_SWISS_BROWN", "COW_WATERBUFFALO", "BULL_WATERBUFFALO" }) do
        dairy = dairy and RLRearingPolicy.getUse(sub(name)) == "DAIRY"
    end
    check("use: Angus, Hereford, Limousin and Highland cows and bulls are BEEF", beef)
    check("use: Holstein, Swiss Brown and water buffalo cows and bulls are DAIRY", dairy)

    local packBeef, packDairy = true, true
    for _, breed in ipairs({ "CHAROLAIS", "REDANGUS", "SHORTHORN", "IRISHMOILED", "BRITISHBLUE", "BELTEDGALLOWAY", "SIMMENTAL" }) do
        packBeef = packBeef and RLRearingPolicy.getUse(packSub("COW_" .. breed .. "_PACK", "female")) == "BEEF"
            and RLRearingPolicy.getUse(packSub("BULL_" .. breed .. "_PACK", "male")) == "BEEF"
    end
    for _, breed in ipairs({ "REDHOLSTEIN", "AYRSHIRE", "KERRY", "SHORTHORNMILKERS", "JERSEY", "GUERNSEY" }) do
        packDairy = packDairy and RLRearingPolicy.getUse(packSub("COW_" .. breed .. "_PACK", "female")) == "DAIRY"
            and RLRearingPolicy.getUse(packSub("BULL_" .. breed .. "_PACK", "male")) == "DAIRY"
    end
    check("use: the pack's seven beef breeds are BEEF for bulls too (their bulls set no milkCollect)", packBeef)
    check("use: the pack's six dairy breeds are DAIRY", packDairy)

    check("use: goats are DAIRY_GOAT, other sheep MEAT_SHEEP, pigs PIG, horses and chickens uncovered",
        RLRearingPolicy.getUse(sub("GOAT")) == "DAIRY_GOAT" and RLRearingPolicy.getUse(sub("RAM_GOAT")) == "DAIRY_GOAT"
        and RLRearingPolicy.getUse(sub("SHEEP_LANDRACE")) == "MEAT_SHEEP" and RLRearingPolicy.getUse(sub("RAM_LANDRACE")) == "MEAT_SHEEP"
        and RLRearingPolicy.getUse(sub("PIG_LANDRACE")) == "PIG" and RLRearingPolicy.getUse(sub("BOAR_LANDRACE")) == "PIG"
        and RLRearingPolicy.getUse(sub("HORSE_GRAY")) == nil and RLRearingPolicy.getUse(sub("CHICKEN")) == nil)
    check("mode: beef, sheep and pigs NUTRITION_COVERAGE; dairy cattle and goats DAIRY_MILK",
        RLRearingPolicy.getRearingMode(sub("COW_ANGUS")) == "NUTRITION_COVERAGE"
        and RLRearingPolicy.getRearingMode(sub("SHEEP_LANDRACE")) == "NUTRITION_COVERAGE"
        and RLRearingPolicy.getRearingMode(sub("PIG_LANDRACE")) == "NUTRITION_COVERAGE"
        and RLRearingPolicy.getRearingMode(sub("COW_HOLSTEIN")) == "DAIRY_MILK"
        and RLRearingPolicy.getRearingMode(sub("GOAT")) == "DAIRY_MILK"
        and RLRearingPolicy.getRearingMode(sub("HORSE_GRAY")) == nil)

    -- A modSettings copy of breedTraits.xml from before productionUse: sucklingMonths / milkCollect="0" still mark beef.
    local config = RLBreedTraits.getConfig()
    local saved = config.stringLayers
    config.stringLayers = nil
    RLRearingPolicy.resetCache()
    check("use: an old breedTraits copy (no productionUse) still marks the suckler breeds BEEF and Holstein DAIRY",
        RLRearingPolicy.getUse(sub("COW_ANGUS")) == "BEEF" and RLRearingPolicy.getUse(sub("BULL_HIGHLAND_CATTLE")) == "BEEF"
        and RLRearingPolicy.getUse(packSub("BULL_CHAROLAIS_PACK", "male")) == "BEEF"
        and RLRearingPolicy.getUse(sub("COW_HOLSTEIN")) == "DAIRY")
    config.stringLayers = saved
    RLRearingPolicy.resetCache()
end


-- Active traits and normalisation --------------------------------------------------------------------

do
    local function keys(name) return table.concat(RLRearingPolicy.getActiveTraitKeys(sub(name)), ",") end
    check("traits: beef cattle have four genes", keys("COW_ANGUS") == "metabolism,quality,health,fertility"
        and keys("BULL_ANGUS") == "metabolism,quality,health,fertility")
    check("traits: dairy cattle, goats, sheep and chickens have five; pigs and horses four",
        keys("COW_HOLSTEIN") == "metabolism,quality,health,fertility,productivity"
        and keys("BULL_HOLSTEIN") == "metabolism,quality,health,fertility,productivity"
        and keys("GOAT") == "metabolism,quality,health,fertility,productivity"
        and keys("SHEEP_LANDRACE") == "metabolism,quality,health,fertility,productivity"
        and keys("CHICKEN") == "metabolism,quality,health,fertility,productivity"
        and keys("PIG_LANDRACE") == "metabolism,quality,health,fertility" and keys("HORSE_GRAY") == "metabolism,quality,health,fertility")

    local g = { metabolism = 1.21, quality = 0.83, health = 1.4, fertility = 0.97, productivity = 1.75 }
    local _, removed = RLRearingPolicy.normalizeGenetics(sub("BULL_ANGUS"), g)
    check("normalise: a beef bull's milk gene is dropped, the other four exactly kept", removed and g.productivity == nil
        and g.metabolism == 1.21 and g.quality == 0.83 and g.health == 1.4 and g.fertility == 0.97)
    local d = { metabolism = 1, quality = 1, health = 1, fertility = 1, productivity = 1.6 }
    local _, removedDairy = RLRearingPolicy.normalizeGenetics(sub("BULL_HOLSTEIN"), d)
    local w = { metabolism = 1, quality = 1, health = 1, fertility = 1, productivity = 0.4 }
    RLRearingPolicy.normalizeGenetics(sub("SHEEP_LANDRACE"), w)
    local goat = { metabolism = 1, quality = 1, health = 1, fertility = 1, productivity = 1.3 }
    RLRearingPolicy.normalizeGenetics(sub("RAM_GOAT"), goat)
    check("normalise: a dairy bull keeps his (he passes it on), wool and goat milk genes are kept",
        not removedDairy and d.productivity == 1.6 and w.productivity == 0.4 and goat.productivity == 1.3)
    local pig = { metabolism = 1, quality = 1, health = 1, fertility = 1 }
    RLRearingPolicy.normalizeGenetics(sub("PIG_LANDRACE"), pig)
    check("normalise: a pig gets no productivity", pig.productivity == nil)

    local sire = { metabolism = 1, productivity = 1.2 }
    RLRearingPolicy.normalizeNamed("COW", "ANGUS", sire)
    local unknown = { metabolism = 1, productivity = 1.2 }
    RLRearingPolicy.normalizeNamed("COW", nil, unknown)
    local dairySire = { metabolism = 1, productivity = 1.2 }
    RLRearingPolicy.normalizeNamed("COW", "HOLSTEIN", dairySire)
    check("normalise: a sire snapshot by breed - beef dropped, dairy kept, unknown breed never taken for beef",
        sire.productivity == nil and unknown.productivity == 1.2 and dairySire.productivity == 1.2)
end


-- Inheritance ----------------------------------------------------------------------------------------

do
    local function mean(a, b) return 0.5 * (a + b) end
    check("inherit: a beef calf inherits none, whatever its parents carry",
        RLRearingPolicy.inheritProductivity(sub("BULL_ANGUS"), 1.7, 1.7, mean) == nil
        and RLRearingPolicy.inheritProductivity(sub("COW_ANGUS"), nil, 1.6, mean) == nil)
    check("inherit: a dairy calf of a beef sire takes its dam's value for both (never a backfilled 1)",
        RLRearingPolicy.inheritProductivity(sub("COW_HOLSTEIN"), 1.6, nil, mean) == 1.6
        and RLRearingPolicy.inheritProductivity(sub("COW_HOLSTEIN"), nil, 1.4, mean) == 1.4
        and RLRearingPolicy.inheritProductivity(sub("COW_HOLSTEIN"), 1.6, 1.0, mean) == 1.3
        and RLRearingPolicy.inheritProductivity(sub("COW_HOLSTEIN"), nil, nil, mean) == nil)
end


-- Scores ---------------------------------------------------------------------------------------------

do
    local four = { metabolism = 1.2, quality = 1.0, health = 0.8, fertility = 1.0 }
    local _, mean, present = RLGenetics.aggregate(four)
    check(string.format("score: a beef animal's overall is the mean of its four genes (%.3f, %d present)", mean, present),
        present == 4 and math.abs(mean - 1.0) < 1e-12)
    local allOne = { metabolism = 1, quality = 1, health = 1, fertility = 1 }
    local factor = RLGenetics.aggregate(allOne)
    check("score: four genes at 1 give the four-gene factor 1/1.75, not a five-slot one", math.abs(factor - 1 / 1.75) < 1e-12)
end


-- Breeding value: the beef cow's and bull's price does not move with an old milk value -----------

do
    local function quoteWith(name, age, p, fields)
        local genes = { productivity = p }
        local f = { genes = genes }
        for k, v in pairs(fields or {}) do f[k] = v end
        return bvQuote(bvAnimal(name, age, f))
    end
    local low = quoteWith("COW_ANGUS", 40, 0.25, { isParent = true, birthCount = 2, monthsSinceLastBirth = 2, isLactating = true })
    local high = quoteWith("COW_ANGUS", 40, 1.75, { isParent = true, birthCount = 2, monthsSinceLastBirth = 2, isLactating = true })
    check(string.format("value: a beef cow's quote with an injected milk value 0.25 / 1.75: %.2f / %.2f (equal)", low.price, high.price),
        low.price == high.price)
    local lowBull = quoteWith("BULL_ANGUS", 24, 0.25)
    local highBull = quoteWith("BULL_ANGUS", 24, 1.75)
    check(string.format("value: a beef bull's quote 0.25 / 1.75: %.2f / %.2f (equal)", lowBull.price, highBull.price),
        lowBull.price == highBull.price)
    local lowDairy = quoteWith("COW_HOLSTEIN", 40, 0.5, { isParent = true, birthCount = 2, monthsSinceLastBirth = 2, isLactating = true })
    local highDairy = quoteWith("COW_HOLSTEIN", 40, 1.6, { isParent = true, birthCount = 2, monthsSinceLastBirth = 2, isLactating = true })
    check(string.format("value: a dairy cow's milk gene still moves her quote: %.2f -> %.2f", lowDairy.price, highDairy.price),
        highDairy.price > lowDairy.price)

    local inherited = RLBreedingValue.inheritedGenes({ fertility = 1.2, health = 1, quality = 1.1 })
    check("value: an animal without the milk gene passes none on (inheritedGenes)", inherited.productivity == nil and inherited.fertility > 1)
end


-- Semen index ----------------------------------------------------------------------------------------

do
    local beefSire = { subTypeIndex = sub("BULL_ANGUS").index, typeIndex = sub("BULL_ANGUS").typeIndex,
        genetics = { quality = 1.4, metabolism = 1.2, fertility = 1.0, health = 0.9 } }
    local index = RLSemenCollection.getBreedingIndex(beefSire)
    local expected = (0.35 * 1.4 + 0.25 * 1.2 + 0.20 * 1.0 + 0.10 * 0.9) / 0.90
    check(string.format("semen: a beef sire's index is quality/metabolism/fertility/health over 0.90 (%.4f vs %.4f)", index, expected),
        math.abs(index - expected) < 1e-12)
    local beefOld = { subTypeIndex = beefSire.subTypeIndex, typeIndex = beefSire.typeIndex,
        genetics = { quality = 1.4, metabolism = 1.2, fertility = 1.0, health = 0.9, productivity = 1.75 } }
    RLRearingPolicy.normalizeByIndex(beefOld.subTypeIndex, beefOld.genetics)
    check("semen: an old beef straw normalised on load has the same index as one without the gene",
        RLSemenCollection.getBreedingIndex(beefOld) == index)
end
