-- RLMeatMath and the carcass entry points built on it, against the frozen dev 9be3881 code
-- (tests/fixtures/legacy_carcass_9be3881.lua): every breed, sex, meat gene, weight, target,
-- facility context, parameter override and body condition state gives the same reference,
-- anchor, yield factor and meat kg. Then the pure functions' isolation and strict checks.

ANIMALS_XML = REPO .. "xml/animals.xml"
loadMod("tests/economics.lua")
loadMod("scripts/animal/RLMeatValue.lua")
loadMod("tests/fixtures/legacy_carcass_9be3881.lua")

local COW_TYPE
for _, sub in ipairs(Economics.subTypes) do if sub.typeName == "COW" then COW_TYPE = sub.typeIndex end end

-- Body condition on (cattle covered) or off (no AnimalType: every factor 1, as before PR #28).
local function setCondition(on)
    AnimalType = on and { COW = COW_TYPE, HORSE = -1 } or nil
end

local function sameNumber(a, b)
    if a == nil or b == nil then return a == b end
    if a ~= a then return b ~= b end
    return a == b or math.abs(a - b) <= 1e-6 * math.max(1, math.abs(a), math.abs(b))
end

-- Animals: every subtype the mod ships, by name.
local SUBS = {}
for index, sub in ipairs(Economics.subTypes) do SUBS[sub.name] = index end

local CATTLE = {}
for index, sub in ipairs(Economics.subTypes) do
    if sub.typeName == "COW" then CATTLE[#CATTLE + 1] = index end
end
local BREEDS = {}
for _, index in ipairs(CATTLE) do BREEDS[Economics.subTypes[index].breed] = true end
local breedCount = 0
for _ in pairs(BREEDS) do breedCount = breedCount + 1 end
check(string.format("matrix: animals.xml has the seven cattle breeds (%d, %d subtypes)", breedCount, #CATTLE),
    breedCount == 7 and BREEDS.HOLSTEIN and BREEDS.WATER_BUFFALO and BREEDS.HIGHLAND)

local OTHERS = {}
for _, name in ipairs({ "BOAR_LANDRACE", "PIG_BLACK_PIED", "RAM_GOAT", "GOAT", "SHEEP_LANDRACE", "CHICKEN", "RABBIT",
    "STALLION_GRAY", "MARE_GRAY" }) do
    if SUBS[name] ~= nil then OTHERS[#OTHERS + 1] = SUBS[name] end
end

-- Facilities: none; one taking every cattle subtype as BEEF (mean of all cattle targets); one
-- taking only two Holstein subtypes; one that maps nothing for the animal.
local function facility(indices)
    local map = {}
    for _, index in ipairs(indices) do map[index] = 20 end
    return { animalSubTypeToFillType = map }
end
local FACILITIES = { false, facility(CATTLE), facility({ SUBS.BULL_HOLSTEIN, SUBS.COW_HOLSTEIN }), facility({}) }

local function makeAnimal(index, fields)
    local sub = Economics.subTypes[index]
    local animal = { subTypeIndex = index, animalTypeIndex = sub.typeIndex, gender = sub.gender, age = 20,
        weight = sub.targetWeight * 0.6, targetWeight = sub.targetWeight, genetics = { quality = 1 } }
    for k, v in pairs(fields or {}) do animal[k] = v end
    return animal
end

-- Compares new and old on one animal and one facility; returns nil or a description of the difference.
local function compare(animal, target)
    target = target or nil
    local index = animal.subTypeIndex
    local newRef, newAnchor = AnimalMoveEvent.getCarcassReferenceWeight(animal, target, index)
    local oldRef, oldAnchor = LegacyCarcass.getCarcassReferenceWeight(animal, target, index)
    local newFactor = AnimalMoveEvent.getCarcassYieldFactor(animal, target, index)
    local oldFactor = LegacyCarcass.getCarcassYieldFactor(animal, target, index)
    local sub = Economics.subTypes[index]
    local newKg = RLMeatValue.getMeatKg(animal, sub)
    local oldKg = LegacyCarcass.getMeatKg(animal, sub)
    local result = AnimalMoveEvent.getCarcassYield(animal, target, index)

    if not sameNumber(newRef, oldRef) or not sameNumber(newAnchor, oldAnchor) then
        return string.format("reference %s/%s vs %s/%s", tostring(newRef), tostring(newAnchor), tostring(oldRef), tostring(oldAnchor))
    end
    if not sameNumber(newFactor, oldFactor) or not sameNumber(result.factor, oldFactor) then
        return string.format("factor %s vs %s", tostring(newFactor), tostring(oldFactor))
    end
    if not sameNumber(newKg, oldKg) then return string.format("kg %s vs %s", tostring(newKg), tostring(oldKg)) end
    -- Model meat in the facility's context: the old factor there x the type's meat per head.
    local meatPerHead = AnimalMoveEvent.getMeatPerHead(sub.typeName)
    if not sameNumber(result.modelMeat, meatPerHead ~= nil and oldFactor * meatPerHead or nil) then
        return string.format("modelMeat %s vs %s", tostring(result.modelMeat), tostring(meatPerHead and oldFactor * meatPerHead))
    end
    return nil, (newFactor == oldFactor and newKg == oldKg)
end

-- Runs the matrix over a set of animals; reports cases, mismatches and how many were bit-identical.
local function runMatrix(label, indices, facilities)
    local cases, bad, identical, first = 0, 0, 0, nil
    local weights = { false, 0, 0.25, 0.55, 0.85, 1.0, 1.6, 3.0 }
    local qualities = { false, 0.25, 0.9, 1, 1.35, 1.75 }
    local targets = { "own", 1.12, "none", 0 }
    local conditions = { "off", "calf", 0.2, 0.52, 0.95, "noState" }
    for _, index in ipairs(indices) do
        local sub = Economics.subTypes[index]
        for _, w in ipairs(weights) do
            for _, q in ipairs(qualities) do
                for _, t in ipairs(targets) do
                    for _, c in ipairs(conditions) do
                        for _, f in ipairs(facilities) do
                            local animal = makeAnimal(index)
                            animal.weight = w and sub.targetWeight * w or nil
                            animal.genetics = q and { quality = q } or nil
                            if t == "none" then animal.targetWeight = nil
                            elseif t == 0 then animal.targetWeight = 0
                            elseif t ~= "own" then animal.targetWeight = sub.targetWeight * t end
                            setCondition(c ~= "off")
                            if c == "calf" then animal.age = 3
                            elseif type(c) == "number" then animal.bodyCondition = { reserve = c } end
                            local diff, same = compare(animal, f or nil)
                            cases = cases + 1
                            if diff ~= nil then
                                bad = bad + 1
                                first = first or string.format("%s w=%s q=%s t=%s c=%s: %s", sub.name, tostring(w), tostring(q),
                                    tostring(t), tostring(c), diff)
                            elseif same then
                                identical = identical + 1
                            end
                        end
                    end
                end
            end
        end
    end
    setCondition(false)
    check(string.format("equivalence %s: %d cases, %d bit-identical, %d differ%s", label, cases, identical, bad,
        first ~= nil and (" (first: " .. first .. ")") or ""), bad == 0 and identical == cases and cases > 0)
end

-- The matrix's condition states really move the factor (cattle covered, reserve away from moderate).
do
    setCondition(true)
    local lean = makeAnimal(SUBS.BULL_ANGUS, { bodyCondition = { reserve = 0.2 } })
    local fat = makeAnimal(SUBS.BULL_ANGUS, { bodyCondition = { reserve = 0.95 } })
    local calf = makeAnimal(SUBS.BULL_ANGUS, { age = 3, bodyCondition = { reserve = 0.95 } })
    local leanFactor = AnimalMoveEvent.getCarcassYield(lean).conditionFactor
    local fatFactor = AnimalMoveEvent.getCarcassYield(fat).conditionFactor
    check(string.format("matrix: condition factors in play (lean %.3f, overfat %.3f, calf 1)", leanFactor, fatFactor),
        leanFactor < 1 and fatFactor < 1 and AnimalMoveEvent.getCarcassYield(calf).conditionFactor == 1)
    setCondition(false)
end

runMatrix("cattle, shipped config", CATTLE, FACILITIES)
runMatrix("pigs, sheep, goats, poultry, rabbits, horses", OTHERS, FACILITIES)

-- Parameter overrides: the same matrix with layers and formula changed, at every level.
local shipped = AnimalMoveEvent.carcassConfig
local function withConfig(label, edit)
    local config = table.clone(shipped, 4)
    edit(config)
    AnimalMoveEvent.carcassConfig = config
    runMatrix(label, CATTLE, { false, FACILITIES[2] })
    AnimalMoveEvent.carcassConfig = shipped
end
withConfig("subtype referenceWeight 480 on BULL_ANGUS", function(c)
    c.layers.subTypes.BULL_ANGUS = { referenceWeight = 480 }
end)
withConfig("breed qualitySwing 0.5 and carcassFactor 1.2 on Holstein", function(c)
    c.layers.breeds.COW.HOLSTEIN = table.clone(c.layers.breeds.COW.HOLSTEIN)
    c.layers.breeds.COW.HOLSTEIN.qualitySwing, c.layers.breeds.COW.HOLSTEIN.carcassFactor = 0.5, 1.2
end)
withConfig("no anchorWeight on COW (facility mean)", function(c)
    c.layers.types.COW = table.clone(c.layers.types.COW)
    c.layers.types.COW.anchorWeight = nil
end)
withConfig("root referenceWeight and maturity only at root", function(c)
    c.layers.types.COW = table.clone(c.layers.types.COW)
    c.layers.types.COW.maleMaturity, c.layers.types.COW.femaleMaturity = nil, nil
    c.layers.breeds.COW = {}
    c.layers.root.maleMaturity = 0.7
end)
withConfig("formula: size exponent 0.5, finish bounds 0.2..1.0", function(c)
    c.sizeExponent, c.minFinishFactor, c.maxFinishFactor = 0.5, 0.2, 1.0
end)

-- Body condition config switched off: factor 1 for every animal, like the old code.
do
    local bcConfig = RLBodyCondition.getConfig()
    local enabled = bcConfig.enabled
    bcConfig.enabled = false
    runMatrix("body condition disabled in its config", { SUBS.BULL_ANGUS, SUBS.COW_HOLSTEIN }, { false })
    bcConfig.enabled = enabled
end

-- Missing animal and missing subtype keep the old answers.
check("fallbacks: no animal gives factor 1 and no reference",
    AnimalMoveEvent.getCarcassYieldFactor(nil, nil, 1) == 1 and AnimalMoveEvent.getCarcassReferenceWeight(nil) == nil
    and AnimalMoveEvent.getCarcassYield(nil) == nil)
do
    local animal = { subTypeIndex = 9999, weight = 500, gender = "male" }
    check("fallbacks: an unknown subtype gives the old factor and reference",
        sameNumber(AnimalMoveEvent.getCarcassYieldFactor(animal, nil, 9999), LegacyCarcass.getCarcassYieldFactor(animal, nil, 9999))
        and sameNumber(AnimalMoveEvent.getCarcassReferenceWeight(animal, nil, 9999), LegacyCarcass.getCarcassReferenceWeight(animal, nil, 9999)))
end

-- A representative bull: the audit's 649 kg Holstein bull, 17 months, average genes.
do
    local animal = makeAnimal(SUBS.BULL_HOLSTEIN, { age = 17, weight = 649 })
    local result = AnimalMoveEvent.getCarcassYield(animal, nil, animal.subTypeIndex)
    check(string.format("representative: 649 kg Holstein bull factor %.8f, model meat %.4f kg (270 x factor)",
        result.factor, result.modelMeat), sameNumber(result.modelMeat, 270 * result.factor) and result.meatPerHead == 270
        and sameNumber(result.factor, result.size * result.weightCompletion * 0.94 * result.qualityFactor * result.conditionFactor))
end

-- Pure: compute and check read no global, load nothing and roll no random number.
do
    local snapshot = { weight = 600, targetWeight = 1000, gender = "male", quality = 1.2, conditionFactor = 0.97 }
    local params = { maleMaturity = 0.6, femaleMaturity = 0.85, anchorWeight = 600, carcassFactor = 1.06,
        qualitySwing = 0.2, meatPerHead = 270 }
    local formula = { sizeExponent = 0.25, minSizeFactor = 0.88, maxSizeFactor = 1.15, finishExponent = 0.85,
        minFinishFactor = 0, maxFinishFactor = 1.3 }
    local saved = { g_currentMission = g_currentMission, AnimalMoveEvent = AnimalMoveEvent, RLBodyCondition = RLBodyCondition,
        RLBreedTraits = RLBreedTraits, g_fillTypeManager = g_fillTypeManager, random = math.random }
    g_currentMission, AnimalMoveEvent, RLBodyCondition, RLBreedTraits, g_fillTypeManager = nil, nil, nil, nil, nil
    math.random = function() error("random called") end
    local ok, result = pcall(RLMeatMath.compute, snapshot, params, formula)
    local okCheck, reasons = pcall(RLMeatMath.check, snapshot, params, formula)
    g_currentMission, AnimalMoveEvent, RLBodyCondition = saved.g_currentMission, saved.AnimalMoveEvent, saved.RLBodyCondition
    RLBreedTraits, g_fillTypeManager, math.random = saved.RLBreedTraits, saved.g_fillTypeManager, saved.random

    local expected = math.clamp((600 / 600) ^ 0.25, 0.88, 1.15) * math.clamp((600 / 600) ^ 0.85, 0, 1.3) * 1.06 * 1.04 * 0.97
    check("pure: compute runs with no game globals and no random", ok and okCheck and #reasons == 0
        and sameNumber(result.factor, expected) and sameNumber(result.modelMeat, expected * 270)
        and result.reference == 600 and result.anchor == 600)
    check("pure: inputs are not changed", snapshot.weight == 600 and params.meatPerHead == 270 and formula.sizeExponent == 0.25
        and snapshot.reference == nil and params.reference == nil)
end

-- Strict check: bad inputs are named, not corrected into a valid-looking yield.
do
    local formula = AnimalMoveEvent.getCarcassConfig()
    local NIL = {}
    local function reasons(snapshotEdit, paramsEdit, formulaEdit)
        local snapshot = { weight = 500, targetWeight = 1000, gender = "male", quality = 1, conditionFactor = 1 }
        local params = { maleMaturity = 0.6, femaleMaturity = 0.85, anchorWeight = 600, carcassFactor = 1,
            qualitySwing = 0.2, meatPerHead = 270 }
        local f = table.clone(formula)
        for k, v in pairs(snapshotEdit or {}) do snapshot[k] = v ~= NIL and v or nil end
        for k, v in pairs(paramsEdit or {}) do params[k] = v ~= NIL and v or nil end
        for k, v in pairs(formulaEdit or {}) do f[k] = v ~= NIL and v or nil end
        local set = {}
        for _, code in ipairs(RLMeatMath.check(snapshot, params, f)) do set[code] = true end
        return set
    end
    check("strict: a sound animal has no reasons", next(reasons()) == nil)
    check("strict: a meatPerHead of 0 or less is BAD_MEAT_PER_HEAD", reasons(nil, { meatPerHead = -5 }).BAD_MEAT_PER_HEAD
        and reasons(nil, { meatPerHead = 0 }).BAD_MEAT_PER_HEAD)
    local noProfile = (function()
        local snapshot = { weight = 500, targetWeight = 1000, gender = "male", quality = 1 }
        local params = { maleMaturity = 0.6, femaleMaturity = 0.85, anchorWeight = 600, carcassFactor = 1, qualitySwing = 0.2 }
        for _, code in ipairs(RLMeatMath.check(snapshot, params, formula)) do if code == "NO_MEAT_PROFILE" then return true end end
        return false
    end)()
    check("strict: a type without meatPerHead reports NO_MEAT_PROFILE", noProfile)
    check("strict: missing or NaN weight is NO_WEIGHT (compute treats it as complete)",
        reasons({ weight = NIL }).NO_WEIGHT and reasons({ weight = 0 / 0 }).NO_WEIGHT and reasons({ weight = 0 }).NO_WEIGHT)
    check("strict: no target and no facility mean is NO_REFERENCE and NO_ANCHOR",
        (function() local r = reasons({ targetWeight = NIL }, { anchorWeight = NIL }); return r.NO_REFERENCE and r.NO_ANCHOR end)())
    check("strict: negative carcassFactor, reversed bounds and gene NaN are named",
        reasons(nil, { carcassFactor = -1 }).BAD_CARCASS_FACTOR and reasons(nil, nil, { minSizeFactor = 2 }).BAD_FORMULA_BOUNDS
        and reasons({ quality = 0 / 0 }).BAD_QUALITY)
    check("strict: a value of the wrong type is named and nothing is computed",
        reasons({ weight = "heavy" })["BAD_INPUT:weight"] and reasons(nil, { meatPerHead = true })["BAD_INPUT:meatPerHead"])
    check("strict: a quality swing that turns the factor negative is named, not clamped",
        reasons({ quality = 0.25 }, { qualitySwing = 2 }).BAD_QUALITY_FACTOR)
end
