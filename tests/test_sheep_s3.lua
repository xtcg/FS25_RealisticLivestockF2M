-- Sheep S3 (2026-10-11): curve scales from breedTraits.xml (RLCurveScale), the lamb meat chain and the
-- butcher's minimum age (carcassYield.xml, RLFacilityAge), and Hof Bergmann's wool remap for animal packs
-- (RLMapBridge palletRemap). Values: FS25_SheepBreeds_离线准备_2026-10-11/change-set-v1.json.

TYPES = { [1] = { name = "COW" }, [2] = { name = "SHEEP" }, [3] = { name = "PIG" } }
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO
Utils = { appendedFunction = function(old, new) return function(...) old(...); new(...) end end }
AnimalMoveEvent = { MOVE_SUCCESS = 0 }

local added = {}
PlaceableSystem = { addPlaceable = function(_, placeable) added[#added + 1] = placeable end }
g_currentMission = { animalSystem = { getTypeByIndex = function(_, i) return TYPES[i] end } }

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animal/RLCurveScale.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadMod("scripts/utils/RLEppAge.lua")
loadMod("scripts/utils/RLFacilityAge.lua")

-- An AnimCurve as the engine builds it: keyframes { value, time = age }, linear between.
local function curve(points)
    local c = { keyframes = {} }
    for _, p in ipairs(points) do c.keyframes[#c.keyframes + 1] = { p[2], time = p[1] } end
    function c:get(age)
        local k = self.keyframes
        if age <= k[1].time then return k[1][1] end
        for i = 2, #k do
            if age <= k[i].time then return k[i - 1][1] + (k[i][1] - k[i - 1][1]) * (age - k[i - 1].time) / (k[i].time - k[i - 1].time) end
        end
        return k[#k][1]
    end
    return c
end

-- breedTraits.xml: a subtype listed twice (growth line, curve scales) keeps both entries' attributes.
local landraceRam = { typeIndex = 2, name = "RAM_LANDRACE", breed = "LANDRACE", gender = "male", minWeight = 6.85, reproductionMinAgeMonth = 5 }
check("traits: RAM_LANDRACE keeps matureAgeMonth 22.0 and gets its scales (two entries merge)",
    near(RLBreedTraits.getMatureAge(landraceRam), 22.0) and near(RLBreedTraits.get(landraceRam, "priceScale"), 1.5035, 1e-4)
    and RLBreedTraits.get(landraceRam, "woolScale") < 0.02)
check("traits: ewes grow at 0.76 of a ram (SHEEP type), goats keep 0.6",
    near(RLBreedTraits.getFemaleGrowth({ typeIndex = 2, name = "SHEEP_TEXEL", breed = "TEXEL" }), 0.76)
    and near(RLBreedTraits.getFemaleGrowth({ typeIndex = 2, name = "GOAT", breed = "GOAT" }), 0.6))

local layers = RLBreedTraits.getConfig().layers
local scaled, foreign = 0, {}
for name, attrs in pairs(layers.subTypes) do
    if attrs.woolScale ~= nil or attrs.waterScale ~= nil or attrs.strawScale ~= nil or attrs.manureScale ~= nil or attrs.priceScale ~= nil then
        scaled = scaled + 1
        if not (name:find("^SHEEP_") or name:find("^RAM_")) or name == "RAM_GOAT" then foreign[#foreign + 1] = name end
    end
end
check(string.format("traits: curve scales on the 32 sheep subtypes only (%d, others: %s)", scaled, table.concat(foreign, " ")),
    scaled == 32 and #foreign == 0)

-- RLCurveScale on an animal system: each configured curve once, nothing else touched.
local function sheep(name, breed, gender, values)
    return { typeIndex = 2, name = name, breed = breed, gender = gender,
        input = { water = curve({ { 0, 3 }, { 18, values.water } }), straw = curve({ { 0, 3 }, { 18, values.straw } }),
            food = curve({ { 0, 5 }, { 18, 132 } }) },
        output = { manure = curve({ { 0, 5 }, { 18, values.manure } }),
            pallets = { fillType = 5, curve = curve({ { 0, 0 }, { 18, values.wool } }) } },
        buyPrice = curve({ { 0, 57 }, { 36, 758 } }), sellPrice = curve({ { 0, 47 }, { 36, 640 } }) }
end
local ewe = sheep("SHEEP_LANDRACE", "LANDRACE", "female", { water = 60, straw = 40, manure = 35, wool = 85 })
local ram = sheep("RAM_LANDRACE", "LANDRACE", "male", { water = 70, straw = 40, manure = 35, wool = 85 })
local texel = sheep("RAM_TEXEL", "TEXEL", "male", { water = 86, straw = 40, manure = 35, wool = 60 })
local goat = sheep("GOAT", "GOAT", "female", { water = 20, straw = 40, manure = 35, wool = 25 })
local cow = { typeIndex = 1, name = "COW_ANGUS", breed = "ANGUS", gender = "female",
    input = { water = curve({ { 0, 30 }, { 18, 180 } }), straw = curve({ { 0, 20 }, { 18, 130 } }) },
    output = { manure = curve({ { 0, 25 }, { 18, 300 } }) }, sellPrice = curve({ { 0, 300 }, { 36, 1500 } }) }
local system = { subTypes = { ewe, ram, texel, goat, cow } }
local count = RLCurveScale.apply(system)

check("scale: Landrace ewe at maturity - wool 85 -> 0.605 L/month (5.52 kg a year x 1.2), water 60 -> 26.7, straw 40 -> 15.6, manure 35 -> 53.7",
    near(ewe.output.pallets.curve:get(24), 0.605, 0.001) and near(ewe.input.water:get(24), 26.7, 0.05)
    and near(ewe.input.straw:get(24), 15.6, 0.05) and near(ewe.output.manure:get(24), 53.7, 0.05))
check("scale: Landrace ram - wool 0.895, water 38.6, manure 87.9 (144 kg); food untouched",
    near(ram.output.pallets.curve:get(24), 0.895, 0.001) and near(ram.input.water:get(24), 38.6, 0.05)
    and near(ram.output.manure:get(24), 87.9, 0.05) and ram.input.food:get(24) == 132)
check("scale: whole age curve (6-month wool is the same share of the mature value)",
    near(ewe.output.pallets.curve:get(9) / ewe.output.pallets.curve:get(18), 0.5, 1e-9))
check("scale: ram prices x priceScale (Landrace 1.5035, pack Texel 0.8917), both curves",
    near(ram.sellPrice:get(36), 640 * 1.5035, 0.01) and near(ram.buyPrice:get(0), 57 * 1.5035, 0.01)
    and near(texel.sellPrice:get(36), 640 * 0.8917, 0.01))
check("scale: a pack breed with no curve in the mod (Texel ram) is scaled by its own entry: wool 60 -> 0.605",
    near(texel.output.pallets.curve:get(24), 0.605, 0.001))
check("scale: goats and cattle untouched", goat.input.water:get(24) == 20 and goat.output.pallets.curve:get(24) == 25
    and cow.input.water:get(24) == 180 and cow.output.manure:get(24) == 300 and cow.sellPrice:get(36) == 1500)
check("scale: ewes keep their price (no priceScale)", ewe.sellPrice:get(36) == 640)
local again = RLCurveScale.apply(system)
check(string.format("scale: a second apply changes nothing (%d curves, then %d)", count, again),
    count == 16 and again == 0 and near(ewe.input.water:get(24), 26.7, 0.05))
local shared = curve({ { 0, 3 }, { 18, 60 } })
local twinA = sheep("SHEEP_LANDRACE", "LANDRACE", "female", { water = 60, straw = 40, manure = 35, wool = 85 })
local twinB = sheep("SHEEP_LANDRACE", "LANDRACE", "female", { water = 60, straw = 40, manure = 35, wool = 85 })
twinA.input.water, twinB.input.water = shared, shared
RLCurveScale.apply({ subTypes = { twinA, twinB } })
check("scale: a curve two subtypes share is scaled once", near(shared:get(24), 26.7, 0.05))

-- The shipped base sheep: the engine's integer curve keys at maturity x the scales = the change set.
local function shipped()
    local xml = loadXMLFileFromDisk(REPO .. "xml/animals.xml")
    local found = {}
    xml:iterate("animals.animal", function(_, animalKey)
        if xml:getString(animalKey .. "#type") ~= "SHEEP" then return end
        xml:iterate(animalKey .. ".subType", function(_, key)
            local function last(path)
                local value
                xml:iterate(key .. path .. ".key", function(_, k) value = xml:getInt(k .. "#value") end)
                return value
            end
            found[xml:getString(key .. "#subType")] = { breed = xml:getString(key .. "#breed"), gender = xml:getString(key .. "#gender"),
                target = xml:getFloat(key .. "#targetWeight"), minWeight = xml:getFloat(key .. "#minWeight"),
                water = last(".input.water"), straw = last(".input.straw"), manure = last(".output.manure"), wool = last(".output.pallets") }
        end)
    end)
    return found
end
local base = shipped()
local EXPECT = {  -- wool L/month, water, straw, manure at maturity; target weight; runtime minWeight (birth mean)
    SHEEP_LANDRACE = { 0.605, 26.7, 15.6, 53.7, 88, 6.40 }, RAM_LANDRACE = { 0.895, 38.6, 15.6, 87.9, 144, 6.85 },
    SHEEP_STEINSCHAF = { 0.395, 18.8, 10.1, 33.6, 55, 3.30 }, RAM_STEINSCHAF = { 0.461, 23.7, 10.1, 45.8, 75, 3.53 },
    SHEEP_SWISS_MOUNTAIN = { 0.5, 23.0, 15.6, 43.9, 72, 6.01 }, RAM_SWISS_MOUNTAIN = { 0.625, 31.1, 15.6, 65.9, 108, 6.43 },
    SHEEP_BLACK_WELSH = { 0.25, 17.5, 10.1, 30.5, 50, 4.00 }, RAM_BLACK_WELSH = { 0.312, 22.0, 10.1, 41.5, 68, 4.28 },
}
for name, e in pairs(EXPECT) do
    local s = base[name]
    local sub = { typeIndex = 2, name = name, breed = s.breed, gender = s.gender }
    local function scaled(value, trait) return value * RLBreedTraits.get(sub, trait) end
    check(string.format("shipped: %s wool %.3f water %.1f straw %.1f manure %.1f, %g kg", name, e[1], e[2], e[3], e[4], e[5]),
        near(scaled(s.wool, "woolScale"), e[1], 0.002) and near(scaled(s.water, "waterScale"), e[2], 0.06)
        and near(scaled(s.straw, "strawScale"), e[3], 0.06) and near(scaled(s.manure, "manureScale"), e[4], 0.06)
        and s.target == e[5] and near(s.minWeight, e[6], 0.006))
end

-- Lamb meat chain: the cattle share 270 / 600 = 0.45 (dressing 0.50 x sellable 0.90), a typical lamb of 42.67 kg
-- still gives 19.2 kg; each breed's ram lamb is finished at its real market weight.
local carcass = AnimalMoveEvent.getCarcassConfig()
local sheepType = carcass.layers.types.SHEEP
check("carcass: SHEEP 42.67 x 0.50 x 0.90 = 19.2 kg a typical lamb, as before",
    near(AnimalMoveEvent.getMeatPerHead("SHEEP"), 19.2, 0.001) and near(sheepType.dressingRate * sheepType.saleableRate, 0.45))
check("carcass: lambs from 3 months (slaughterMinAgeMonth, facilityMinAgeMonth)",
    sheepType.slaughterMinAgeMonth == 3 and sheepType.facilityMinAgeMonth == 3 and carcass.layers.types.COW.facilityMinAgeMonth == nil)
for name, market in pairs({ RAM_LANDRACE = 42.67, RAM_STEINSCHAF = 38, RAM_SWISS_MOUNTAIN = 42.67, RAM_BLACK_WELSH = 35.4 }) do
    local s = base[name]
    local maturity = RLBreedTraits.resolve(carcass.layers, { typeIndex = 2, name = name, breed = s.breed }, "maleMaturity", 1)
    check(string.format("carcass: %s finished at its market weight %.1f kg (%.1f x %.3f)", name, market, s.target, maturity),
        near(s.target * maturity, market, 0.1))
end
for _, breed in ipairs({ "TEXEL", "SUFFOLK", "BLUE_FACED_LEICESTER", "BORDER_LEICESTER", "BELCLARE", "DORSET", "CHEVIOT",
    "KERRY_HILL", "NORFOLK", "BLACKFACE", "EASYCARE", "JACOB" }) do
    check("carcass: pack breed " .. breed .. " has a lamb maturity (was the default 1 = its mature weight)",
        carcass.layers.breeds.SHEEP[breed] ~= nil and carcass.layers.breeds.SHEEP[breed].maleMaturity < 0.65)
end

-- Butcher and slaughterhouse minimum age: SHEEP 8 -> 3 in every animalsTypeData, other types as the map has them.
local contract = { getName = function() return "slaughterhouse" end,
    animalsTypeData = { [1] = { minimumAge = 6, maximumAge = 60 }, [2] = { minimumAge = 8, maximumAge = 60 } } }
local eppData = { [2] = { minimumAge = 8, maximumAge = 60 }, [3] = { minimumAge = 6, maximumAge = 60 } }
local butcher = { getName = function() return "farm butcher" end, spec_extendedProductionPoint = { productionPoint = { animalsTypeData = eppData } } }
PlaceableSystem:addPlaceable(contract)
PlaceableSystem:addPlaceable(butcher)
check("facility: the slaughterhouse takes sheep from 3 months, cattle still from 6",
    contract.animalsTypeData[2].minimumAge == 3 and contract.animalsTypeData[1].minimumAge == 6 and contract.animalsTypeData[2].maximumAge == 60)
check("facility: the farm butcher's production point too, pigs untouched", eppData[2].minimumAge == 3 and eppData[3].minimumAge == 6)
check("facility: the original addPlaceable still runs", #added == 2)
g_currentMission.placeableSystem = { placeables = { contract, butcher, {} } }
check("facility: the sweep at mission start finds nothing left to change", RLFacilityAge.applyToAll() == 0)
check("facility: RLEppAge reads the new window", RLEppAge.check(3, eppData[2]) and not RLEppAge.check(2, eppData[2]))

-- Hof Bergmann: a pack's WOOL becomes SHEEPWOOL_SHEARED once every pack has loaded.
loadMod("tests/fixtures/giants_lua.lua")
loadGiantsMod("scripts/bridge/RLMapBridge.lua")
local FILLS = { WOOL = 5, SHEEPWOOL_SHEARED = 9, GOATMILK = 7 }
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) return FILLS[name] end }
local xml = loadXMLFileFromDisk(REPO .. "mod_support/FS25_HofBergmann/v1.5/animals.xml")
function xml:iterator(key)
    local list = {}
    self:iterate(key, function(i, k) list[#list + 1] = { i, k } end)
    local n = 0
    return function() n = n + 1; if list[n] ~= nil then return list[n][1], list[n][2] end end
end
RLMapBridge.pendingPalletRemaps = {}
RLMapBridge.readPalletRemaps(xml, "Hof Bergmann")
local packEwe = { name = "SHEEP_TEXEL", output = { pallets = { fillType = 5 } } }
local hbEwe = { name = "SHEEP_LANDRACE", output = { pallets = { fillType = 9 } } }
local doe = { name = "GOAT", output = { pallets = { fillType = 7 } } }
local animalSystem = { nameToType = { SHEEP = { subTypes = { 1, 2, 3 } } }, subTypes = { packEwe, hbEwe, doe } }
local changed = RLMapBridge.applyPalletRemaps(animalSystem)
check(string.format("bridge: HB remaps a pack ewe's WOOL to SHEEPWOOL_SHEARED (%d changed), goat milk and HB wool untouched", changed),
    changed == 1 and packEwe.output.pallets.fillType == 9 and hbEwe.output.pallets.fillType == 9 and doe.output.pallets.fillType == 7)
check("bridge: remaps are used once", RLMapBridge.applyPalletRemaps(animalSystem) == 0)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
