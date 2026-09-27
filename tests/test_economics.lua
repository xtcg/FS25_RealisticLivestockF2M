-- Slaughter ages and feed efficiency (tests/economics.lua on the shipped xml): each meat animal
-- reaches its slaughter reference at the calibrated age on full feed, and feed per kg gain keeps
-- the breed order. A change to curves, traits or growth code that moves these fails here.

ANIMALS_XML = REPO .. "xml/animals.xml"
loadMod("tests/economics.lua")

-- Subtype, ration, months to the slaughter reference.
local AGES = {
    { "BULL_HOLSTEIN", "TMR", 17 }, { "BULL_LIMOUSIN", "TMR", 18 }, { "BULL_ANGUS", "TMR", 19.5 },
    { "BULL_HEREFORD", "TMR", 19.5 }, { "BULL_SWISS_BROWN", "TMR", 20 }, { "BULL_WATERBUFFALO", "TMR", 23 },
    { "BULL_HIGHLAND_CATTLE", "TMR", 25 },
    { "BOAR_LANDRACE", "full", 5.5 }, { "BOAR_BLACK_PIED", "full", 6 }, { "BOAR_BERKSHIRE", "full", 6.5 },
    { "PIG_LANDRACE", "full", 5.6 }, { "PIG_BLACK_PIED", "full", 6.1 }, { "PIG_BERKSHIRE", "full", 6.6 },
    { "RAM_LANDRACE", "full", 5 }, { "RAM_STEINSCHAF", "full", 5 }, { "RAM_SWISS_MOUNTAIN", "full", 5.5 },
    { "RAM_BLACK_WELSH", "full", 5.5 },
}

-- Feed per kg gain relative to a reference breed: { reference, { subtype = ratio } }.
local FCR = {
    { "BULL_ANGUS", { BULL_LIMOUSIN = 0.92, BULL_HEREFORD = 0.96, BULL_SWISS_BROWN = 1.00, BULL_HOLSTEIN = 1.05,
        BULL_WATERBUFFALO = 1.05, BULL_HIGHLAND_CATTLE = 1.15 } },
    { "BOAR_BLACK_PIED", { BOAR_LANDRACE = 0.90, BOAR_BERKSHIRE = 1.15 } },
    { "RAM_LANDRACE", { RAM_BLACK_WELSH = 0.95, RAM_STEINSCHAF = 1.05, RAM_SWISS_MOUNTAIN = 1.10 } },
}

local results = {}
for _, entry in ipairs(AGES) do
    local i, sub = Economics.find(entry[1])
    local months, feed, live = Economics.raise(i, Economics.RATIONS[entry[2]], Economics.reference(sub))
    results[entry[1]] = { months = months, fcr = feed / (live - sub.minWeight) }
    check(string.format("age: %s at its reference by %.1f months (%.2f)", entry[1], entry[3], months),
        near(months, entry[3], 0.25))
end

for _, group in ipairs(FCR) do
    local base = results[group[1]].fcr
    for name, ratio in pairs(group[2]) do
        local actual = results[name].fcr / base
        check(string.format("fcr: %s %.2f x %s (%.3f)", name, ratio, group[1], actual), near(actual, ratio, 0.03))
    end
end

-- Dairy: Swiss Brown gives about 85% of Holstein's milk at a similar milk/feed ratio.
local _, holstein = Economics.find("COW_HOLSTEIN")
local _, swiss = Economics.find("COW_SWISS_BROWN")
check("dairy: Holstein peak 378, Swiss Brown 320", near(Economics.curve(holstein.milk, 60), 378)
    and near(Economics.curve(swiss.milk, 60), 320))
