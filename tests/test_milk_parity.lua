-- Cattle milk by lactation number (RLMilkParity, Animal:updateOutput): the mature cow's milk (the
-- curve at 36 months and over) is the third lactation and later; a first lactation gives 80% of it,
-- a second 92%, whatever the curve's step at 36 months says.

local FILL = { [1] = "MILK", [2] = "BUFFALOMILK", [3] = "GOATMILK" }
g_fillTypeManager = { getFillTypeNameByIndex = function(_, i) return FILL[i] end }
FillType = { WOOL = 5 }
AnimalType = { COW = 1, GOAT = 2 }
g_server = {}

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
do
    -- No record: filled once from its age (empty entries), then the record is what counts.
    local cases = { { 24, 1, 0.80 }, { 36, 2, 0.92 }, { 48, 3, 1 } }
    local ok = true
    for _, c in ipairs(cases) do
        local a = cow(c[1], 0); a:updateOutput(20)
        if #a.children ~= c[2] or not near(a.output.milk * 24 / mature, c[3], 1e-9) then ok = false end
    end
    check("parity: an animal with no record gets its record filled once from its age (24 months one calf, 36 two, 48 three) and gives that level", ok)

    local a = cow(29, 0); a:updateOutput(20)
    a.age = 33; a:updateOutput(20)
    check("parity: after the fill age no longer decides - the 29-month-old stays in her first lactation at 33 (no jump inside it)",
        #a.children == 1 and near(a.output.milk * 24 / mature, 0.80, 1e-9))

    local b = cow(31, 1); b:updateOutput(20)
    check("parity: a record is never topped up against age - a heifer that calves late (31 months, one calf) is in her first", near(b.output.milk * 24 / mature, 0.80, 1e-9) and #b.children == 1)

    local entries = cow(40, 0); entries:updateOutput(20)
    check("parity: filled entries are strings, so the animal still saves and streams", (function()
        for _, child in ipairs(entries.children) do
            if type(child.uniqueId) ~= "string" or type(child.farmId) ~= "string" then return false end
        end
        return #entries.children == 2
    end)())

    g_server = nil
    local client = cow(40, 0); client:updateOutput(20)
    check("parity: a client counts the same but keeps nothing", #client.children == 0 and near(client.output.milk * 24 / mature, 0.92, 1e-9))
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
check("parity: the pure functions", RLMilkParity.getParity(0) == 1 and RLMilkParity.getParity(7) == 3 and RLMilkParity.getImpliedCalves(29) == 1
    and RLMilkParity.getImpliedCalves(30) == 2 and RLMilkParity.getImpliedCalves(43) == 3 and RLMilkParity.getFactor(1) == 0.80 and RLMilkParity.getFactor(2) == 0.92 and RLMilkParity.getFactor(3) == 1
    and RLMilkParity.getCurveAge(11) == 11 and RLMilkParity.getCurveAge(12) == 60 and RLMilkParity.getCurveAge(40) == 60 and RLMilkParity.getCurveAge(60) == 60 and RLMilkParity.getCurveAge(80) == 80)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
