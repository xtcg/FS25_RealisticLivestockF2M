-- Milk output gated by lactation (Animal:updateOutput): tank milk, goat milk and Hof Bergmann's
-- cow milk cans, which RLRM feeds through output.pallets.

local FILL = { [1] = "MILK", [2] = "BUFFALOMILK", [3] = "GOATMILK", [4] = "EGG", [5] = "WOOL" }
g_fillTypeManager = { getFillTypeNameByIndex = function(_, i) return FILL[i] end }
FillType = { WOOL = 5 }

loadAnimalSection("Animal.SEMEN_FILL_TYPE_NAMES", "\nfunction Animal:getInput")

local function curve(value) return { get = function() return value end } end

-- A 48-month animal whose subtype outputs 100 a day of `fillTypeIndex`, through pallets or milk.
local function cow(path, fillTypeIndex, state, multipliers)
    local output = path == "pallets" and { fillType = fillTypeIndex, curve = curve(100) }
        or { fillType = fillTypeIndex, get = curve(100).get }
    local subType = { name = "COW_HOLSTEIN", output = { [path] = output } }
    local a = setmetatable({ age = 48, farmId = 1, uniqueId = "1", genetics = { productivity = 1 }, diseases = {},
        output = {}, isParent = state.isParent, isLactating = state.isLactating,
        monthsSinceLastBirth = state.months }, { __index = Animal })
    a.getSubType = function() return subType end
    a.getDiseaseMultipliers = function() return multipliers, multipliers ~= nil and 1 or 0 end
    return a
end
local function perDay(path, fillTypeIndex, state, multipliers)
    local a = cow(path, fillTypeIndex, state, multipliers)
    a:updateOutput(20)
    return a.output[path] * 24
end

local fresh = { isParent = true, isLactating = true, months = 3 }
local dry = { isParent = true, isLactating = false, months = 11 }
local heifer = { isParent = false, isLactating = false, months = nil }

check("cans: fresh cow at lactation peak fills 1.3x the curve", near(perDay("pallets", 1, fresh), 130))
check("cans: dry cow fills none", perDay("pallets", 1, dry) == 0)
check("cans: never-calved heifer fills none", perDay("pallets", 1, heifer) == 0)
check("cans: buffalo milk gated too", perDay("pallets", 2, dry) == 0 and near(perDay("pallets", 2, fresh), 130))
check("cans: 10 months after calving the cow is dry",
    perDay("pallets", 1, { isParent = true, isLactating = true, months = 10 }) == 0)
check("cans: same yield as tank milk through the lactation", (function()
    for months = 0, 9 do
        local state = { isParent = true, isLactating = true, months = months }
        if not near(perDay("pallets", 1, state), perDay("milk", 1, state)) then return false end
    end
    return true
end)())
check("goat milk still gated", perDay("pallets", 3, dry) == 0 and near(perDay("pallets", 3, fresh), 130))
check("eggs are not milk: no gate", near(perDay("pallets", 4, heifer), 100))

-- Foot and mouth, as in xml/diseases.xml: milk x0.35, pallets x0.9.
local fmd = { milk = 0.35, pallets = 0.9, manure = 1, liquidManure = 1 }
check("disease: a sick cow's cans drop like her tank milk (x0.35)",
    near(perDay("pallets", 1, fresh, fmd), perDay("milk", 1, fresh, fmd)) and near(perDay("pallets", 1, fresh, fmd), 130 * 0.35))
check("disease: buffalo milk cans use the milk modifier", near(perDay("pallets", 2, fresh, fmd), 130 * 0.35))
check("disease: CVM's milk-only x1.5 reaches the cans", near(perDay("pallets", 1, fresh,
    { milk = 1.5, pallets = 1, manure = 1, liquidManure = 1 }), 130 * 1.5))
check("disease: goat milk keeps the pallets modifier", near(perDay("pallets", 3, fresh, fmd), 130 * 0.9))
check("disease: eggs keep the pallets modifier", near(perDay("pallets", 4, heifer, fmd), 90))

for _, line in ipairs(LOG) do
    if line:find("^safeCall") then check("no script error: " .. line, false) end
end
