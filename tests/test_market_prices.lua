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

-- Bulls: commodity-age live-market anchors after the realistic growth calibration.
local BULLS = {
    { "BULL_HOLSTEIN", 18, 2050 },
    { "BULL_SWISS_BROWN", 18, 1850 },
    { "BULL_HEREFORD", 18, 1950 },
    { "BULL_ANGUS", 18, 2150 },
    { "BULL_LIMOUSIN", 18, 2450 },
    { "BULL_HIGHLAND_CATTLE", 18, 1550 },
    { "BULL_WATERBUFFALO", 18, 1500 },
}
for _, row in ipairs(BULLS) do
    check("market cattle: " .. row[1] .. " sell anchor", near(price(row[1], "sell", row[2]), row[3]))
    local spread = price(row[1], "buy", row[2]) / price(row[1], "sell", row[2])
    check("market cattle: " .. row[1] .. " dealer spread 15-35%", spread >= 1.15 and spread <= 1.35)
end

-- Finishing pigs: six-month values are commodity-meat prices, not mature breeding-stock prices.
local PIGS = {
    { "PIG_LANDRACE", 190 }, { "BOAR_LANDRACE", 210 },
    { "PIG_BLACK_PIED", 170 }, { "BOAR_BLACK_PIED", 190 },
    { "PIG_BERKSHIRE", 215 }, { "BOAR_BERKSHIRE", 240 },
}
for _, row in ipairs(PIGS) do
    check("market pig: " .. row[1] .. " six-month sell", near(price(row[1], "sell", 6), row[2]))
    local spread = price(row[1], "buy", 6) / price(row[1], "sell", 6)
    check("market pig: " .. row[1] .. " dealer spread 15-35%", spread >= 1.15 and spread <= 1.35)
end

-- Lambs: six-month market anchors while 36-month prices retain breeding-stock value.
local SHEEP = {
    { "SHEEP_BLACK_WELSH", 130 }, { "RAM_BLACK_WELSH", 155 },
    { "SHEEP_LANDRACE", 140 }, { "RAM_LANDRACE", 170 },
    { "SHEEP_STEINSCHAF", 180 }, { "RAM_STEINSCHAF", 210 },
    { "SHEEP_SWISS_MOUNTAIN", 190 }, { "RAM_SWISS_MOUNTAIN", 220 },
}
for _, row in ipairs(SHEEP) do
    check("market sheep: " .. row[1] .. " six-month sell", near(price(row[1], "sell", 6), row[2]))
    local spread = price(row[1], "buy", 6) / price(row[1], "sell", 6)
    check("market sheep: " .. row[1] .. " dealer spread 15-35%", spread >= 1.15 and spread <= 1.35)
end
