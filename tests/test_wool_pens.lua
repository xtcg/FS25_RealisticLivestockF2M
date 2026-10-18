-- SHEEP-WOOL-NEWPEN-01 and HB-WINTER-WOOL-01: sheep wool into pallets.
-- Hof Bergmann remaps every sheep's WOOL to SHEEPWOOL_SHEARED; the base game's sheep barns
-- (sheepBarnBig/Medium/Small, sheepGoatBarn: palletSpawner fillTypes="WOOL GOATMILK") and HB's
-- goat stable spawn only WOOL, so their sheep's wool was dropped (no pendingLiters node in the
-- save). The pallet spec below is shaped on FS25's PlaceableHusbandryPallets (onLoad tables,
-- updateOutput, addPendingLiters/updatePallets, save/load of pendingLiters).

Utils = {
    appendedFunction = function(base, after)
        return function(self, ...)
            if base ~= nil then base(self, ...) end
            return after(self, ...)
        end
    end,
    overwrittenFunction = function(base, replacement)
        return function(self, ...) return replacement(self, base, ...) end
    end,
}
SpecializationUtil = { registerOverwrittenFunction = function() end }
FSBaseMission = { INGAME_NOTIFICATION_CRITICAL = 1, INGAME_NOTIFICATION_INFO = 2 }
g_i18n = { getText = function(_, key) return key .. " %s %d %d" end }
local NOTES = {}
local FILLS = { WOOL = 5, SHEEPWOOL_SHEARED = 9, GOATMILK = 7, MILK = 3 }
local NAMES = {}
for name, index in pairs(FILLS) do NAMES[index] = name end
g_fillTypeManager = {
    getFillTypeIndexByName = function(_, name) return FILLS[name] end,
    getFillTypeNameByIndex = function(_, index) return NAMES[index] end,
}
Animal = { isCowMilkPalletFillType = function() return false end }
table.addElement = function(t, v) for _, x in ipairs(t) do if x == v then return end end t[#t + 1] = v end

-- Engine-shaped PlaceableHusbandryPallets ---------------------------------------------------------
PlaceableHusbandryPallets = {}
function PlaceableHusbandryPallets.registerOverwrittenFunctions() end
function PlaceableHusbandryPallets:onHusbandryAnimalsUpdate() end
function PlaceableHusbandryPallets:onLoad()
    local spec = self.spec_husbandryPallets
    for _, key in ipairs({ "fillTypeIndexToPalletSpawner", "litersPerHour", "maxNumPallets", "capacities", "capacitiesPending",
        "capacitiesSent", "maxCapacitiesPending", "fillLevels", "fillLevelsPending", "fillLevelsSent", "pendingLiters" }) do
        spec[key] = {}
    end
    spec.fillTypes = {}
    for _, spawner in ipairs(self.spawners) do
        for _, name in ipairs(spawner.fillTypes) do
            local index = FILLS[name]
            spec.fillTypeIndexToPalletSpawner[index] = spawner
            table.insert(spec.fillTypes, index)
            spec.litersPerHour[index], spec.maxNumPallets[index], spec.pendingLiters[index] = 0, spawner.max, 0
            spec.capacities[index], spec.capacitiesPending[index], spec.capacitiesSent[index], spec.maxCapacitiesPending[index] = 0, 0, 0, 0
            spec.fillLevels[index], spec.fillLevelsPending[index], spec.fillLevelsSent[index] = 0, 0, 0
        end
    end
end
function PlaceableHusbandryPallets:updateOutput(foodFactor, productionFactor, globalProductionFactor)
    local spec = self.spec_husbandryPallets
    for _, fillTypeIndex in ipairs(spec.fillTypes) do
        local litersPerHour = spec.litersPerHour[fillTypeIndex]
        if litersPerHour > 0 then
            spec.pendingLiters[fillTypeIndex] = spec.pendingLiters[fillTypeIndex]
                + productionFactor * globalProductionFactor * litersPerHour * g_currentMission.environment.timeAdjustment
            self:updatePallets()
        end
    end
end
function PlaceableHusbandryPallets:saveToXMLFile(xmlFile, key)
    for fillTypeIndex, liters in pairs(self.spec_husbandryPallets.pendingLiters) do
        if liters > 0 then xmlFile:setFloat(key .. ".pendingLiters." .. NAMES[fillTypeIndex] .. "#liters", liters) end
    end
end
function PlaceableHusbandryPallets:loadFromXMLFile(xmlFile, key)
    for fillTypeIndex in pairs(self.spec_husbandryPallets.pendingLiters) do
        self.spec_husbandryPallets.pendingLiters[fillTypeIndex] = xmlFile:getFloat(key .. ".pendingLiters." .. NAMES[fillTypeIndex] .. "#liters") or 0
    end
end

loadMod("tests/fixtures/giants_lua.lua")
loadGiantsMod("scripts/bridge/RLMapBridge.lua")
loadMod("scripts/animals/husbandry/placeables/RLPastureSeason.lua")
loadMod("scripts/animals/husbandry/placeables/RLWoolShearing.lua")
loadMod("scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryPallets.lua")

-- Hof Bergmann's bridge: its palletRemap is kept as a building alias.
local xml = loadXMLFileFromDisk(REPO .. "mod_support/FS25_HofBergmann/v1.5/animals.xml")
function xml:iterator(key)
    local list = {}
    self:iterate(key, function(i, k) list[#list + 1] = { i, k } end)
    local n = 0
    return function() n = n + 1; if list[n] ~= nil then return list[n][1], list[n][2] end end
end
RLMapBridge.pendingPalletRemaps = {}
RLMapBridge.palletAliases = {}
RLMapBridge.readPalletRemaps(xml, "Hof Bergmann")
local SHEEP, PIG = 3, 2
local ewe = { name = "SHEEP_TEXEL", typeIndex = SHEEP, output = { pallets = { fillType = 5 } } }
local hbEwe = { name = "SHEEP_LANDRACE", typeIndex = SHEEP, output = { pallets = { fillType = 9 } } }
local doe = { name = "GOAT", typeIndex = SHEEP, output = { pallets = { fillType = 7 } } }
g_currentMission = {
    animalSystem = { nameToType = { SHEEP = { typeIndex = SHEEP, subTypes = { 1, 2, 3 } }, PIG = { typeIndex = PIG, subTypes = {} } },
        subTypes = { ewe, hbEwe, doe } },
    environment = { currentPeriod = 6, currentYear = 1, timeAdjustment = 1 },
    getFarmId = function() return 1 end,
    addIngameNotification = function(_, kind, text) NOTES[#NOTES + 1] = { kind = kind, text = text } end,
}
RLMapBridge.applyPalletRemaps(g_currentMission.animalSystem)
check("bridge: HB's WOOL -> SHEEPWOOL_SHEARED remap kept as a building alias",
    #RLMapBridge.palletAliases == 1 and RLMapBridge.palletAliases[1].from == 5 and RLMapBridge.palletAliases[1].to == 9
    and ewe.output.pallets.fillType == 9)
RLMapBridge.activeBridges = { { modName = "FS25_HofBergmann" } }

local function animal(subType, litersPerHour)
    return { subType = subType, getSubType = function(self) return self.subType end,
        getOutput = function(self, kind) return kind == "pallets" and self.liters or 0 end, liters = litersPerHour }
end
local function pen(spawnerFillTypes, typeIndex, animals, name)
    local placeable = {
        isServer = true, spawners = { { fillTypes = spawnerFillTypes, max = 8 } }, spec_husbandryPallets = {},
        spec_husbandryAnimals = { clusterSystem = { getClusters = function() return animals end } },
        animals = animals, spawned = 0,
        getAnimalTypeIndex = function() return typeIndex end,
        getName = function() return name or "pen" end,
        getOwnerFarmId = function() return 1 end,
        updatePallets = function(self) self.spawned = self.spawned + 1 end,
    }
    PlaceableHusbandryPallets.onLoad(placeable)
    return placeable
end
local function refresh(placeable)
    PlaceableHusbandryPallets.updateInputAndOutput(placeable, function() end, placeable.animals)
end
local function output(placeable, productionFactor, globalProductionFactor)
    RealisticLivestock_PlaceableHusbandryPallets.updateOutput(placeable, PlaceableHusbandryPallets.updateOutput, 1,
        productionFactor or 1, globalProductionFactor or 1)
end
local function pending(placeable, name) return placeable.spec_husbandryPallets.pendingLiters[FILLS[name]] end

-- SHEEP-WOOL-NEWPEN-01: a base-game sheep barn on HB --------------------------------------------
RLWoolShearing.reset()
RLWoolShearing.config = RLWoolShearing.getDefaultConfig()
RLWoolShearing.preset = RLPastureSeason.resolvePreset(RLWoolShearing.config.presets, function() return false end) -- YEAR_ROUND
local flock = { animal(ewe, 0.01), animal(hbEwe, 0.02), animal(doe, 0) }
local barn = pen({ "WOOL", "GOATMILK" }, SHEEP, flock, "sheepBarnBig")
check("new barn: spawns SHEEPWOOL_SHEARED from its WOOL spawner", barn.spec_husbandryPallets.fillTypeIndexToPalletSpawner[9] == barn.spawners[1]
    and barn.spec_husbandryPallets.maxNumPallets[9] == 8 and barn.spec_husbandryPallets.fillTypes[3] == 9)
refresh(barn)
check("new barn: its sheep's wool counts (0.03 l/h)", near(barn.spec_husbandryPallets.litersPerHour[9], 0.03, 1e-9))
output(barn)
check("new barn: wool pending -> a pendingLiters node in the save", near(pending(barn, "SHEEPWOOL_SHEARED"), 0.03, 1e-9))
local hbPen = pen({ "SHEEPWOOL_SHEARED", "GOATMILK" }, SHEEP, {}, "sheepPasture01")
check("HB pen: unchanged (already spawns the map's wool)", #hbPen.spec_husbandryPallets.fillTypes == 2)
local pigBarn = pen({ "WOOL" }, PIG, {}, "pig")
check("other animal type: no alias", pigBarn.spec_husbandryPallets.fillTypeIndexToPalletSpawner[9] == nil)
local milkOnly = pen({ "GOATMILK" }, SHEEP, { animal(ewe, 0.01), animal(hbEwe, 0.01) }, "goatOnly")
refresh(milkOnly); refresh(milkOnly)
check("no wool spawner: no wool made up, nothing pending", milkOnly.spec_husbandryPallets.pendingLiters[9] == nil)
-- The pallets module logs through the global Log (stubs: info is silent); the note is kept once.
check("no wool spawner: noted once per building and fill type",
    milkOnly.spec_husbandryPallets.rlUnsupportedNoted ~= nil and milkOnly.spec_husbandryPallets.rlUnsupportedNoted[9] == true)

-- HB-WINTER-WOOL-01: spring shearing ------------------------------------------------------------
RLWoolShearing.preset = nil
RLWoolShearing.config = RLWoolShearing.parse(loadXMLFileFromDisk(REPO .. "xml/breedTraits.xml"))
local preset = RLWoolShearing.getPreset()
check("preset: Hof Bergmann shears in late spring / early summer, every 12 months",
    preset.name == "HOF_BERGMANN" and preset.mode == "SPRING_SHEARING" and preset.shearingPeriods[3] and preset.shearingPeriods[4]
    and not preset.shearingPeriods[5] and preset.intervalMonths == 12)
check("preset: elsewhere year-round", RLPastureSeason.resolvePreset(RLWoolShearing.config.presets, function() return false end).mode == "YEAR_ROUND")
check("preset: a breedTraits copy without woolShearing keeps the same presets",
    RLWoolShearing.parse(nil).presets[2].mode == "SPRING_SHEARING")

local env = g_currentMission.environment
local function runYears(placeable, startPeriod, years, hoursPerMonth, factor)
    local woolByPeriod = {}
    local before = pending(placeable, "SHEEPWOOL_SHEARED")
    for m = 0, years * 12 - 1 do
        local index = (startPeriod - 1) + m
        env.currentPeriod = index % 12 + 1
        env.currentYear = 1 + math.floor(index / 12)
        for _ = 1, hoursPerMonth do output(placeable, factor or 1, 1) end
        local now = pending(placeable, "SHEEPWOOL_SHEARED")
        woolByPeriod[#woolByPeriod + 1] = { period = env.currentPeriod, liters = now - before }
        before = now
    end
    return woolByPeriod
end

local function flockOf(n, liters)
    local list = {}
    for i = 1, n do list[i] = animal(i % 2 == 0 and ewe or hbEwe, liters) end
    return list
end
local spring = pen({ "SHEEPWOOL_SHEARED", "GOATMILK" }, SHEEP, flockOf(10, 0.01), "sheepStable")
local yearRoundPen = pen({ "SHEEPWOOL_SHEARED", "GOATMILK" }, SHEEP, flockOf(10, 0.01), "control")
refresh(spring); refresh(yearRoundPen)
NOTES = {}
local months = runYears(spring, 7, 2, 24, 0.8) -- from early autumn, two years, 24 h a month, food factor 0.8
local shorn, winterWool, total = {}, 0, 0
for _, m in ipairs(months) do
    total = total + m.liters
    if m.liters > 1e-9 then shorn[#shorn + 1] = m.period end
    if m.period >= 9 then winterWool = winterWool + m.liters end
end
check("spring: no wool pallets in autumn or winter", winterWool == 0)
check("spring: shorn once a year, in late spring (" .. table.concat(shorn, " ") .. ")", table.concat(shorn, " ") == "3 3")
local fleeceLeft = 0
for _, a in ipairs(spring.animals) do fleeceLeft = fleeceLeft + (a.rlFleece or 0) end
RLWoolShearing.preset = { name = "T", maps = {}, mode = "YEAR_ROUND", intervalMonths = 12 }
runYears(yearRoundPen, 7, 2, 24, 0.8)
local yearRound = pending(yearRoundPen, "SHEEPWOOL_SHEARED")
check(string.format("spring: shorn + still on the sheep = year-round total (%.4f + %.4f = %.4f)", total, fleeceLeft, yearRound),
    near(total + fleeceLeft, yearRound, 1e-9) and near(yearRound, 10 * 0.01 * 0.8 * 24 * 24, 1e-9))
check("spring: a notification for each shearing", #NOTES == 2 and NOTES[1].text:find("rl_wool_shorn", 1, true) ~= nil)

-- Not more than grown: a second shearing month in the same season shears nothing.
RLWoolShearing.preset = nil
local late = pen({ "SHEEPWOOL_SHEARED" }, SHEEP, flockOf(4, 0.01), "late")
refresh(late)
env.currentPeriod, env.currentYear = 3, 5
output(late)
check("spring: a pen shears its own fleece only (4 sheep x 0.01 l after one hour)", near(pending(late, "SHEEPWOOL_SHEARED"), 0.04, 1e-9))
env.currentPeriod = 4
output(late); output(late)
check("spring: the next shearing month does not shear again within 12 months", near(pending(late, "SHEEPWOOL_SHEARED"), 0.04, 1e-9)
    and near(late.animals[1].rlFleece, 0.02, 1e-9))

-- Year-round compatibility: switching back releases the fleece the next hour.
RLWoolShearing.preset = { name = "T", maps = {}, mode = "YEAR_ROUND", intervalMonths = 12 }
env.currentPeriod = 10
output(late)
check("year-round again: the stored fleece and this hour's wool go to the pallets",
    near(pending(late, "SHEEPWOOL_SHEARED"), 0.04 + 0.08 + 0.04, 1e-9) and late.animals[1].rlFleece == 0)

-- Manual shearing stall (HB shearing station): left to the map.
RLWoolShearing.preset = nil
local manual = pen({ "SHEEPWOOL_SHEARED" }, SHEEP, flockOf(2, 0.01), "manual")
manual.lsfmGetShearingStationEnabled = function() return true end
refresh(manual)
env.currentPeriod = 10
output(manual)
check("manual shearing stall: the base output runs (the map's station suppresses it)", near(pending(manual, "SHEEPWOOL_SHEARED"), 0.02, 1e-9)
    and manual.animals[1].rlFleece == nil)

-- Persistence --------------------------------------------------------------------------------
local function memoryXml()
    local values = {}
    return {
        values = values,
        setInt = function(_, k, v) values[k] = v end, setFloat = function(_, k, v) values[k] = v end,
        getInt = function(_, k, d) return values[k] or d end, getFloat = function(_, k, d) return values[k] or d end,
    }
end
local file = memoryXml()
local sheared = pen({ "SHEEPWOOL_SHEARED" }, SHEEP, {}, "saved")
sheared.spec_husbandryPallets.rlLastShearMonth = 63
PlaceableHusbandryPallets.saveToXMLFile(sheared, file, "p")
local loaded = pen({ "SHEEPWOOL_SHEARED" }, SHEEP, {}, "loaded")
PlaceableHusbandryPallets.loadFromXMLFile(loaded, file, "p")
check("save: the pen's last shearing comes back", loaded.spec_husbandryPallets.rlLastShearMonth == 63)
local oldPen = pen({ "SHEEPWOOL_SHEARED" }, SHEEP, {}, "old")
PlaceableHusbandryPallets.loadFromXMLFile(oldPen, memoryXml(), "p")
check("old save: no shearing on record (shears at the next shearing month)", oldPen.spec_husbandryPallets.rlLastShearMonth == nil)
local sheep = { rlFleece = 0.75 }
local animalFile = memoryXml()
RLWoolShearing.saveAnimal(sheep, animalFile, "a")
local back = {}
RLWoolShearing.loadAnimal(back, animalFile, "a")
local bare = {}
RLWoolShearing.saveAnimal({}, animalFile, "b")
RLWoolShearing.loadAnimal(bare, animalFile, "b")
check("save: an animal's fleece comes back; none saved or made up when bare", back.rlFleece == 0.75 and bare.rlFleece == nil
    and animalFile.values["b#rlFleece"] == nil)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
