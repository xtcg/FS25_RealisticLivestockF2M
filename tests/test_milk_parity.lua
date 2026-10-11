-- Cattle milk by lactation number (RLMilkParity, Animal:updateOutput): the mature cow's milk (the
-- curve at 36 months and over) is the third lactation and later; a first lactation gives 80% of it,
-- a second 92%, whatever the curve's step at 36 months says.

local FILL = { [1] = "MILK", [2] = "BUFFALOMILK", [3] = "GOATMILK" }
g_fillTypeManager = { getFillTypeNameByIndex = function(_, i) return FILL[i] end }
FillType = { WOOL = 5 }
AnimalType = { COW = 1, GOAT = 2 }

loadAnimalSection("Animal.SEMEN_FILL_TYPE_NAMES", "\nfunction Animal:getInput")

-- The body condition budget is not under test: its milk entry point records the curve it is given.
local lastCurve
RLBodyCondition.applyMilk = function(_, potential, curvePerPeriod) lastCurve = curvePerPeriod; return potential end

-- The game's step: 590 from 12 to 36 months, 1000 from 36.
local stepCurve = { get = function(_, age) if age < 12 then return 0 end if age < 36 then return 590 end if age < 120 then return 1000 end return 545 end }

local function cow(age, children, typeIndex, path)
    path = path or "milk"
    local output = path == "pallets" and { fillType = 1, curve = stepCurve } or { fillType = 1, get = stepCurve.get }
    local subType = { name = "COW_HOLSTEIN", output = { [path] = output } }
    local kids = {}
    for i = 1, children do kids[i] = { uniqueId = tostring(i) } end
    local a = setmetatable({ age = age, farmId = 1, uniqueId = "1", genetics = { productivity = 1 }, diseases = {},
        output = {}, isParent = true, isLactating = true, monthsSinceLastBirth = 3, children = kids,
        animalTypeIndex = typeIndex or AnimalType.COW }, { __index = Animal })
    a.getSubType = function() return subType end
    a.getDiseaseMultipliers = function() return nil, 0 end
    return a
end
local function perDay(age, children, typeIndex, path)
    local a = cow(age, children, typeIndex, path)
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
check("parity: an animal with no record of its calves is read from its age (first under 30 months, second under 43, then mature)",
    near(perDay(24, 0) / mature, 0.80, 1e-9) and near(perDay(36, 0) / mature, 0.92, 1e-9) and near(perDay(48, 0) / mature, 1, 1e-9))
check("parity: with calves on record age is only a floor (37 months: second, 50: third); the running first lactation of a 24-month-old stays at 80% until 35",
    near(perDay(34, 1) / mature, 0.80, 1e-9) and near(perDay(35, 1) / mature, 0.80, 1e-9) and near(perDay(37, 1) / mature, 0.92, 1e-9)
    and near(perDay(48, 2) / mature, 0.92, 1e-9) and near(perDay(50, 2) / mature, 1, 1e-9))
check("parity: later than the third nothing grows (old age still follows the curve)",
    near(perDay(70, 9), mature, 1e-9) and perDay(130, 9) < mature)
check("parity: goats keep their own curve and rule", near(perDay(24, 1, AnimalType.GOAT) / (1000 * 1.3), 590 / 1000, 1e-9))
do
    local a = cow(24, 1); a:updateOutput(20)
    check("parity: the budget's anchor curve carries the level too (a first-lactation cow's demand is 80% of a mature one's)",
        near(lastCurve, 1000 * 0.80, 1e-9))
end
check("parity: the pure functions", RLMilkParity.getFactor(1) == 0.80 and RLMilkParity.getFactor(2) == 0.92 and RLMilkParity.getFactor(3) == 1
    and RLMilkParity.getCurveAge(11) == 11 and RLMilkParity.getCurveAge(12) == 60 and RLMilkParity.getCurveAge(40) == 60 and RLMilkParity.getCurveAge(60) == 60 and RLMilkParity.getCurveAge(80) == 80)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
