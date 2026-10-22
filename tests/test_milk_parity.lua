-- Cattle milk by lactation number (RLMilkParity, Animal:updateOutput): the mature cow's milk (the
-- curve at 36 months and over) is the third lactation and later; a first lactation gives 80% of it,
-- a second 92%, whatever the curve's step at 36 months says. The number is the animal's own count
-- of calvings (birthCount); an animal with none on record takes it once from its calf record or age.

local FILL = { [1] = "MILK", [2] = "BUFFALOMILK", [3] = "GOATMILK" }
g_fillTypeManager = { getFillTypeNameByIndex = function(_, i) return FILL[i] end }
FillType = { WOOL = 5 }
AnimalType = { COW = 1, GOAT = 2 }
-- The shipped breedTraits.xml (milkScale of the pack breeds).
g_currentMission = { animalSystem = { getTypeByIndex = function() return { name = "COW" } end } }
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO
loadMod("scripts/animal/RLBreedTraits.lua")
g_server = {}

loadAnimalSection("Animal.SEMEN_FILL_TYPE_NAMES", "\nfunction Animal:getInput")

-- The body condition budget is not under test: its milk entry point records the curve it is given.
local lastCurve
RLBodyCondition.applyMilk = function(_, potential, curvePerPeriod) lastCurve = curvePerPeriod; return potential end

-- The game's step: 590 from 12 to 36 months, 1000 from 36.
local stepCurve = { get = function(_, age) if age < 12 then return 0 end if age < 36 then return 590 end if age < 120 then return 1000 end return 545 end }

local function cow(age, births, typeIndex, path, children, subTypeName)
    path = path or "milk"
    local output = path == "pallets" and { fillType = 1, curve = stepCurve } or { fillType = 1, get = stepCurve.get }
    local subType = { name = subTypeName or "COW_HOLSTEIN", output = { [path] = output } }
    local kids = {}
    for i = 1, children or 0 do kids[i] = { uniqueId = tostring(i) } end
    local a = setmetatable({ age = age, farmId = 1, uniqueId = "1", genetics = { productivity = 1 }, diseases = {},
        output = {}, isParent = true, isLactating = true, monthsSinceLastBirth = 3, children = kids, birthCount = births,
        animalTypeIndex = typeIndex or AnimalType.COW }, { __index = Animal })
    a.getSubType = function() return subType end
    a.getDiseaseMultipliers = function() return nil, 0 end
    return a
end
local function perDay(age, births, typeIndex, path, children, subTypeName)
    local a = cow(age, births, typeIndex, path, children, subTypeName)
    a:updateOutput(20)
    return a.output[path or "milk"] * 24
end

local mature = perDay(60, 5)
check("parity: a mature cow gives the curve's 1000 x the lactation factor", near(mature, 1000 * (0.8 + 3 / 6), 1e-6))
local first, second, third = perDay(24, 1), perDay(37, 2), perDay(50, 3)
check(string.format("parity: first / second / third lactation give %.0f%% / %.0f%% / %.0f%% of a mature cow",
    first / mature * 100, second / mature * 100, third / mature * 100),
    near(first / mature, 0.80, 1e-9) and near(second / mature, 0.92, 1e-9) and near(third / mature, 1, 1e-9))
check("parity: the curve's step at 36 months no longer shows - a 35-month-old second-lactation cow gives the same as at 40 and 49",
    near(perDay(35, 2), perDay(40, 2), 1e-9) and near(perDay(35, 2), perDay(49, 2), 1e-9))
check("parity: the cans give the same as the tank", near(perDay(24, 1, nil, "pallets"), first, 1e-9))
do
    -- No count on record: taken once from the calf record, else from age, and kept (server).
    local ok = true
    for _, c in ipairs({ { 24, 1, 0.80 }, { 36, 2, 0.92 }, { 48, 3, 1 } }) do
        local a = cow(c[1], nil); a:updateOutput(20)
        if a.birthCount ~= c[2] or not near(a.output.milk * 24 / mature, c[3], 1e-9) then ok = false end
    end
    check("parity: with no count on record it is taken from age (24 months one birth, 36 two, 48 three), kept, and gives that level", ok)

    local a = cow(29, nil); a:updateOutput(20)
    a.age = 33; a:updateOutput(20)
    check("parity: once kept, age no longer decides - the 29-month-old stays in her first lactation at 33",
        a.birthCount == 1 and near(a.output.milk * 24 / mature, 0.80, 1e-9))

    local r = cow(40, nil, nil, nil, 1); r:updateOutput(20)
    check("parity: with no count but one calf on record the record decides, not age", r.birthCount == 1 and near(r.output.milk * 24 / mature, 0.80, 1e-9))

    local late = cow(31, 1); late:updateOutput(20)
    check("parity: a count on record is never topped up against age - a heifer that calves late (31 months, one birth) is in her first",
        late.birthCount == 1 and near(late.output.milk * 24 / mature, 0.80, 1e-9))

    local twins = cow(24, 1, nil, nil, 2); twins:updateOutput(20)
    check("parity: twins are one birth - her own count of 1 beats the two calves on record", near(twins.output.milk * 24 / mature, 0.80, 1e-9))

    local never = cow(40, nil); never.isParent = false
    check("parity: an animal that never calved has nothing to resolve and no level to carry", never:resolveBirthCount() == 0 and never:getParityFactor() == 1)

    g_server = nil
    local client = cow(40, nil); client:updateOutput(20)
    check("parity: a client counts the same but keeps nothing", client.birthCount == nil and near(client.output.milk * 24 / mature, 0.92, 1e-9))
    g_server = {}
end
check("parity: later than the third nothing grows (old age still follows the curve)",
    near(perDay(70, 9), mature, 1e-9) and perDay(130, 9) < mature)
check("parity: goats keep their own curve and rule", near(perDay(24, 1, AnimalType.GOAT) / (1000 * 1.3), 590 / 1000, 1e-9))
do
    local a = cow(24, 1); a:updateOutput(20)
    check("parity: the budget's anchor curve carries the level too (a first-lactation cow's demand is 80% of a mature one's)",
        near(lastCurve, 1000 * 0.80, 1e-9))
end
check("milkScale: a pack breed's curve is taken to this mod's scale (Jersey pack x2.58), the mod's own breeds are not touched",
    near(RLBreedTraits.get({ name = "COW_JERSEY_PACK" }, "milkScale"), 652 / 253, 1e-3) and RLBreedTraits.get({ name = "COW_HOLSTEIN" }, "milkScale") == 1
    and near(perDay(60, 3, nil, nil, nil, "COW_JERSEY_PACK") / mature, 652 / 253, 1e-3) and near(perDay(24, 1, nil, nil, nil, "COW_JERSEY_PACK") / mature, 0.8 * 652 / 253, 1e-3))
check("parity: the pure functions", RLMilkParity.getParity(0) == 1 and RLMilkParity.getParity(7) == 3 and RLMilkParity.getImpliedBirths(29) == 1
    and RLMilkParity.getImpliedBirths(30) == 2 and RLMilkParity.getImpliedBirths(43) == 3 and RLMilkParity.getFactor(1) == 0.80 and RLMilkParity.getFactor(2) == 0.92 and RLMilkParity.getFactor(3) == 1
    and RLMilkParity.getCurveAge(11) == 11 and RLMilkParity.getCurveAge(12) == 60 and RLMilkParity.getCurveAge(40) == 60 and RLMilkParity.getCurveAge(60) == 60 and RLMilkParity.getCurveAge(80) == 80)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end

-- Beef cattle (breedTraits productionUse BEEF, RLRearingPolicy) give no milk output at all: nothing in the tank or the
-- cans, and no curve milk for the budget either - her calves are fed on the nutrition she pays for them (RLFeed nursing).
check("suckler: a Cow Breeds pack beef cow puts nothing in the tank or the cans, and her budget sees no curve milk",
    perDay(60, 5, nil, nil, nil, "COW_CHAROLAIS_PACK") == 0 and perDay(60, 5, nil, "pallets", nil, "COW_CHAROLAIS_PACK") == 0
    and (lastCurve == nil or lastCurve == 0))
check("dairy: a Cow Breeds pack dairy cow still gives milk", perDay(60, 5, nil, nil, nil, "COW_JERSEY_PACK") > 0)

-- breedTraits sucklingMonths: a suckler cow is dried off when her calf is weaned at 7 months.
loadAnimalSection("function Animal:advanceRecoveryPeriod", "\nfunction Animal:onPeriodChanged")
local function mother(subType, monthsSinceLastBirth)
    local a = setmetatable({ isParent = true, isLactating = true, monthsSinceLastBirth = monthsSinceLastBirth, uniqueId = "1" },
        { __index = Animal })
    a.getSubType = function() return subType end
    return a
end
local angusSub, packSub = { name = "COW_ANGUS", breed = "ANGUS" }, { name = "COW_CHAROLAIS_PACK", breed = "CHAROLAIS_PACK" }
local holsteinSub = { name = "COW_HOLSTEIN", breed = "HOLSTEIN" }
local function after(subType, monthsSinceLastBirth)
    local a = mother(subType, monthsSinceLastBirth)
    a:advanceRecoveryPeriod()
    return a.isLactating, a.monthsSinceLastBirth
end
local angusAt6, angusAt7, packAt7 = after(angusSub, 5), after(angusSub, 6), after(packSub, 6)
local holsteinAt7, holsteinAt10 = after(holsteinSub, 6), after(holsteinSub, 9)
check("suckler cows dry at 7 months after calving (Angus, the pack's Charolais); a Holstein milks to 10",
    angusAt6 and not angusAt7 and not packAt7 and holsteinAt7 and not holsteinAt10)
check("suckler yield: Angus 6 months after calving as before, 0 from 7; Holstein unchanged at 7",
    near(mother(angusSub, 6):getLactationFactor(), 0.8 + 5 / 15, 1e-9) and mother(angusSub, 7):getLactationFactor() == 0
    and near(mother(holsteinSub, 7):getLactationFactor(), 0.8 + 4 / 15, 1e-9))
