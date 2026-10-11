-- Livestock market-price calibration: protect commodity-age anchors and dealer spreads.

local xml = loadXMLFileFromDisk(REPO .. "xml/animals.xml")

local subTypes = {}
xml:iterate("animals.animal", function(_, animalKey)
    xml:iterate(animalKey .. ".subType", function(_, key)
        local name = xml:getString(key .. "#subType")
        local function readCurve(section)
            local points = {}
            xml:iterate(key .. "." .. section .. ".key", function(_, k)
                points[#points + 1] = { xml:getFloat(k .. "#ageMonth"), xml:getFloat(k .. "#value") }
            end)
            return points
        end
        subTypes[name] = { buy = readCurve("buyPrice"), sell = readCurve("sellPrice") }
    end)
end)

local function curve(points, age)
    if #points == 0 then return 0 end
    if age <= points[1][1] then return points[1][2] end
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if age <= b[1] then
            if b[1] == a[1] then return b[2] end
            return a[2] + (b[2] - a[2]) * (age - a[1]) / (b[1] - a[1])
        end
    end
    return points[#points][2]
end

local function price(name, side, age)
    return curve(assert(subTypes[name], name)[side], age)
end

-- Bulls: commodity-age live-market anchors: the values of the realistic growth calibration scaled per breed so that
-- slaughtering by contract earns 12% over selling live over the year at one beef price (8.4/kg, fee 199.9) (xml/carcassYield.xml, docs RLRM_牛肉链收益校准.md).
local BULLS = {
    { "BULL_HOLSTEIN", 18, 1954 },
    { "BULL_SWISS_BROWN", 18, 1767 },
    { "BULL_HEREFORD", 18, 1791 },
    { "BULL_ANGUS", 18, 1928 },
    { "BULL_LIMOUSIN", 18, 2123 },
    { "BULL_HIGHLAND_CATTLE", 18, 1355 },
    { "BULL_WATERBUFFALO", 18, 1323 },
}
for _, row in ipairs(BULLS) do
    check("market cattle: " .. row[1] .. " sell anchor", near(price(row[1], "sell", row[2]), row[3]))
    local spread = price(row[1], "buy", row[2]) / price(row[1], "sell", row[2])
    check("market cattle: " .. row[1] .. " dealer spread 15-35%", spread >= 1.15 and spread <= 1.35)
end

-- Meat animals at their finishing age: the realistic growth calibration's curves scaled per breed so that
-- slaughtering by contract earns 12% over selling live over the year at one meat price per species (pork 4.31,
-- lamb and goat 14.95, poultry 9.06 per kg) (xml/carcassYield.xml, docs RLRM_猪羊禽兔屠宰与售价校准.md).
-- Gilts keep their breeding-stock value from 24 months: only their keys up to 6 months moved.
local FINISHED = {
    { "PIG_LANDRACE", 6, 218 }, { "BOAR_LANDRACE", 6, 210 },
    { "PIG_BLACK_PIED", 6, 219 }, { "BOAR_BLACK_PIED", 6, 211 },
    { "PIG_BERKSHIRE", 6.5, 241.8 }, { "BOAR_BERKSHIRE", 6.5, 232.6 },
    { "RAM_LANDRACE", 8, 192.9 }, { "RAM_STEINSCHAF", 8, 181.0 }, { "RAM_SWISS_MOUNTAIN", 8, 192.0 },
    { "RAM_BLACK_WELSH", 8, 191.7 }, { "RAM_GOAT", 8, 168.2 }, { "CHICKEN_ROOSTER", 6, 12.1 },
}
for _, row in ipairs(FINISHED) do
    check("market meat: " .. row[1] .. " sell at " .. row[2] .. " months", near(price(row[1], "sell", row[2]), row[3], 0.6))
    local spread = price(row[1], "buy", row[2]) / price(row[1], "sell", row[2])
    check("market meat: " .. row[1] .. " dealer spread 15-45%", spread >= 1.15 and spread <= 1.45)
end
check("market pig: a gilt's 24-month breeding value is unchanged", near(price("PIG_LANDRACE", "sell", 24), 1400))

-- Ewes: six-month market anchors while 36-month prices retain breeding-stock value.
local SHEEP = {
    { "SHEEP_BLACK_WELSH", 130 }, { "SHEEP_LANDRACE", 140 }, { "SHEEP_STEINSCHAF", 180 }, { "SHEEP_SWISS_MOUNTAIN", 190 },
}
for _, row in ipairs(SHEEP) do
    check("market sheep: " .. row[1] .. " six-month sell", near(price(row[1], "sell", 6), row[2]))
    local spread = price(row[1], "buy", 6) / price(row[1], "sell", 6)
    check("market sheep: " .. row[1] .. " dealer spread 15-35%", spread >= 1.15 and spread <= 1.35)
end
