-- HB-WINTER-MEADOW-01: a pen's own pasture through the winter (RLPastureSeason, RLMeadowSeason).
-- The meadow functions below are shaped on FS25's PlaceableHusbandryMeadow (getAvailableFood,
-- removeFood, finishMeadowGrowthUpdate with its refill-to-capacity, updateMeadowInfo); the growth
-- tables are Hof Bergmann 1.5's grass.xml / meadowUS.xml (states invisible 1, greenSmall 2,
-- greenMiddle 3, harvestReady 4, cut 5, cutRolled 6; eatable greenMiddle..harvestReady).

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
SpecializationUtil = {
    registerOverwrittenFunction = function(placeableType, name, fn)
        local previous = placeableType[name]
        placeableType[name] = function(self, ...) return fn(self, previous, ...) end
    end,
    registerEventListener = function(placeableType, event, spec)
        placeableType.listeners[event] = placeableType.listeners[event] or {}
        table.insert(placeableType.listeners[event], spec)
    end,
}
GrowthMode = { SEASONAL = 1, DAILY = 2, DISABLED = 3 }
FSBaseMission = { INGAME_NOTIFICATION_CRITICAL = 1, INGAME_NOTIFICATION_INFO = 2 }
g_i18n = { getText = function(_, key) return key .. " %s %d" end }
local NOTES = {}
g_currentMission = {
    environment = { currentPeriod = 6, currentDayInPeriod = 1, daysPerPeriod = 1, dayTime = 0, currentYear = 1, timeAdjustment = 1 },
    missionInfo = { growthMode = GrowthMode.SEASONAL },
    getFarmId = function() return 1 end,
    addIngameNotification = function(_, kind, text) NOTES[#NOTES + 1] = { kind = kind, text = text } end,
}
RLMapBridge = { isMapActive = function(name) return name == "FS25_HofBergmann" end }

-- Engine-shaped PlaceableHusbandryMeadow -------------------------------------------------------
PlaceableHusbandryMeadow = {}
function PlaceableHusbandryMeadow.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getAvailableFood", PlaceableHusbandryMeadow.getAvailableFood)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "removeFood", PlaceableHusbandryMeadow.removeFood)
end
function PlaceableHusbandryMeadow.registerEventListeners(placeableType) end
function PlaceableHusbandryMeadow:getAvailableFood(superFunc, fillTypeIndex)
    local spec = self.spec_husbandryMeadow
    local fillLevel = superFunc(self, fillTypeIndex)
    local meadowFillLevel = spec.fillLevels[fillTypeIndex]
    if meadowFillLevel ~= nil then fillLevel = (fillLevel or 0) + meadowFillLevel end
    return fillLevel
end
function PlaceableHusbandryMeadow:removeFood(superFunc, deltaToRemove, fillTypeIndex)
    local deltaRemoved = superFunc(self, deltaToRemove, fillTypeIndex)
    local deltaRemaining = deltaToRemove - deltaRemoved
    if deltaRemaining > 0 then
        local spec = self.spec_husbandryMeadow
        local fillLevel = spec.fillLevels[fillTypeIndex]
        if fillLevel ~= nil then
            local removed = math.min(fillLevel, deltaRemaining)
            spec.fillLevels[fillTypeIndex] = fillLevel - removed
            deltaRemoved = deltaRemoved + removed
            spec.dirtyFillLevels[fillTypeIndex] = true
            self:updateMeadowInfo()
        end
    end
    return deltaRemoved
end
function PlaceableHusbandryMeadow:updateMeadowInfo()
    local spec = self.spec_husbandryMeadow
    local fillLevel, capacity = 0, 0
    for fillTypeIndex, level in pairs(spec.fillLevels) do
        fillLevel = fillLevel + level
        capacity = capacity + spec.capacities[fillTypeIndex]
    end
    local ratio = capacity > 0 and fillLevel / capacity or 0
    spec.foodInfo.value, spec.foodInfo.capacity, spec.foodInfo.ratio = fillLevel, capacity, ratio
    spec.info.value, spec.info.capacity, spec.info.ratio = fillLevel, capacity, ratio
    spec.info.text = string.format("%d l", fillLevel)
end
function PlaceableHusbandryMeadow:startMeadowGrowthUpdate()
    self.spec_husbandryMeadow.growthStartFillLevels, self.spec_husbandryMeadow.growthStartCapacities = self:getMeadowVisualFillLevels()
end
function PlaceableHusbandryMeadow:finishMeadowGrowthUpdate()
    local spec = self.spec_husbandryMeadow
    local growthEndFillLevels, growthEndCapacities = self:getMeadowVisualFillLevels()
    if spec.growthStartFillLevels ~= nil and growthEndFillLevels ~= nil then
        for fillTypeIndex, fillLevel in pairs(growthEndFillLevels) do
            local delta = fillLevel - spec.growthStartFillLevels[fillTypeIndex]
            if fillLevel == growthEndCapacities[fillTypeIndex] then delta = growthEndCapacities[fillTypeIndex] end
            spec.fillLevels[fillTypeIndex] = math.clamp(spec.fillLevels[fillTypeIndex] + delta, 0, growthEndCapacities[fillTypeIndex])
        end
        self:updateMeadowInfo()
    end
end
function PlaceableHusbandryMeadow:finishedMeadow() end
function PlaceableHusbandryMeadow:onHusbandryAnimalsCreated() end

loadMod("scripts/animals/husbandry/placeables/RLPastureSeason.lua")
loadMod("scripts/animals/husbandry/placeables/RLMeadowSeason.lua")
RLPastureSeason.config = RLPastureSeason.parse(loadXMLFileFromDisk(REPO .. "xml/pastureSeasons.xml"))

-- The pen's placeable type: the trough (PlaceableHusbandryFood) under the meadow's overrides.
local TYPE = { listeners = {} }
TYPE.getAvailableFood = function(self, fillTypeIndex) return self.trough[fillTypeIndex] or 0 end
TYPE.removeFood = function(self, delta, fillTypeIndex)
    local have = self.trough[fillTypeIndex] or 0
    local removed = math.min(have, delta)
    self.trough[fillTypeIndex] = have - removed
    return removed
end
TYPE.updateFeeding = function() return 1 end
PlaceableHusbandryMeadow.registerOverwrittenFunctions(TYPE)
PlaceableHusbandryMeadow.registerEventListeners(TYPE)
TYPE.updateMeadowInfo = PlaceableHusbandryMeadow.updateMeadowInfo
TYPE.startMeadowGrowthUpdate = PlaceableHusbandryMeadow.startMeadowGrowthUpdate
TYPE.finishMeadowGrowthUpdate = PlaceableHusbandryMeadow.finishMeadowGrowthUpdate
TYPE.getMeadowVisualFillLevels = function(self) return { [GRASS] = self.visual }, { [GRASS] = self.visualCap } end
TYPE.raiseDirtyFlags = function(self) self.dirtyRaised = (self.dirtyRaised or 0) + 1 end
TYPE.getName = function() return "Pasture 21" end
TYPE.getOwnerFarmId = function() return 1 end

local function mapping(updates)
    local m = {}
    for state = 1, 6 do m[state] = state end
    for _, u in ipairs(updates) do m[u[1]] = u[2] end
    return { growthMapping = m }
end
local GROW = { { 1, 2 }, { 2, 3 }, { 3, 4 }, { 5, 2 }, { 6, 2 } }
local function hbTable(earlySpring)
    local periods = {}
    periods[1] = mapping(earlySpring)
    for p = 2, 8 do periods[p] = mapping(GROW) end
    periods[9] = mapping({ { 1, 2 }, { 4, 3 } })        -- LATE_AUTUMN: knock back harvestReady
    periods[10] = mapping({})                           -- EARLY_WINTER
    periods[11] = mapping({})                           -- MID_WINTER
    periods[12] = mapping({ { 2, 3 } })                 -- LATE_WINTER
    return { periods = periods }
end
local GRASS_FRUIT = { growthDataSeasonal = hbTable(GROW) }
local MEADOW_FRUIT = { growthDataSeasonal = hbTable({ { 1, 2 }, { 3, 4 }, { 5, 2 }, { 6, 2 } }) }
GRASS = 21

local function newPen(fill, cap)
    local pen = setmetatable({
        isServer = true,
        trough = {},
        visual = fill, visualCap = cap,
        spec_husbandryMeadow = {
            fillLevels = { [GRASS] = fill }, capacities = { [GRASS] = cap }, dirtyFillLevels = {}, dirtyFlag = 4,
            foodInfo = {}, info = {},
            fruitTypeInfos = {
                { fruitType = GRASS_FRUIT, eatableStartGrowthState = 3, eatableEndGrowthState = 4, fillTypeIndex = GRASS },
                { fruitType = MEADOW_FRUIT, eatableStartGrowthState = 3, eatableEndGrowthState = 4, fillTypeIndex = GRASS },
            },
        },
    }, { __index = TYPE })
    pen:updateMeadowInfo()
    return pen
end
local env = g_currentMission.environment
local function at(period, progress, days)
    env.currentPeriod = period
    env.daysPerPeriod = days or 1
    local dayFloat = (progress or 0) * env.daysPerPeriod
    env.currentDayInPeriod = math.floor(dayFloat) + 1
    env.dayTime = (dayFloat - math.floor(dayFloat)) * 86400000
end
local function hour(pen)
    for _, listener in ipairs(TYPE.listeners.onHourChanged or {}) do listener.onHourChanged(pen) end
end

-- Dormancy from the map's growth tables -----------------------------------------------------------
local pen = newPen(6736, 6736)
local dormant = RLMeadowSeason.getDormantPeriods(pen)
local list = {}
for p = 1, 12 do if dormant[p] then list[#list + 1] = p end end
check("dormancy: HB grass+meadow tables -> late autumn, early and mid winter (" .. table.concat(list, " ") .. ")",
    table.concat(list, " ") == "9 10 11")
check("dormancy: a fruit without seasonal table -> never dormant",
    next(RLPastureSeason.deriveDormantPeriods({ { fruitType = {}, eatableStartGrowthState = 3, eatableEndGrowthState = 4 } })) == nil)
check("preset: Hof Bergmann's preset on Hof Bergmann", RLPastureSeason.getMeadowPreset().name == "HOF_BERGMANN")
check("preset: DEFAULT elsewhere", RLPastureSeason.resolvePreset(RLPastureSeason.config.meadow.presets, function() return false end).name == "DEFAULT")

-- The factor through the year (model days, 30 a month) -------------------------------------------
local preset = RLPastureSeason.getMeadowPreset()
local function state(period, progress) return RLPastureSeason.getMeadowState(dormant, period, progress, preset) end
check("factor: summer 1, no warning", state(6, 0.5).factor == 1 and not state(6, 0.5).warn)
check("warning: 7 model days before late autumn (mid autumn day 24) warns, day 15 not",
    state(8, 0.8).warn and state(8, 0.8).phase == "WARN" and near(state(8, 0.8).daysToDormancy, 6) and not state(8, 0.5).warn)
check("ramp down: late autumn day 0 = 1, day 7 = 0.5, day 14 = 0 (dormant)",
    state(9, 0).factor == 1 and state(9, 0).phase == "WITHER" and near(state(9, 7 / 30).factor, 0.5, 1e-9)
    and state(9, 14 / 30).factor == 0 and state(9, 14 / 30).phase == "DORMANT")
check("dormant: early and mid winter 0", state(10, 0.5).factor == 0 and state(11, 0.99).factor == 0)
check("recovery: late winter day 0 = 0, day 7 = 0.5, day 15 = 1",
    state(12, 0).factor == 0 and state(12, 0).phase == "RECOVER" and near(state(12, 7 / 30).factor, 0.5, 1e-9)
    and state(12, 0.5).factor == 1 and state(12, 0.5).phase == "NORMAL")

at(9, 7 / 30, 1)
local p1, x1 = RLPastureSeason.getSeasonPosition(env)
at(9, 7 / 30, 28)
local p28, x28 = RLPastureSeason.getSeasonPosition(env)
check("month length: the same point of late autumn at 1 and 28 days a month", p1 == 9 and p28 == 9 and near(x1, x28, 1e-6))

-- Summer: bit-identical to the engine ------------------------------------------------------------
at(6, 0.5)
pen = newPen(3000, 6736)
pen.trough[GRASS] = 100
check("summer: available = trough + meadow", pen:getAvailableFood(GRASS) == 3100)
check("summer: remove takes trough, then meadow", pen:removeFood(500, GRASS) == 500 and pen.trough[GRASS] == 0
    and pen.spec_husbandryMeadow.fillLevels[GRASS] == 2600)
pen.spec_husbandryMeadow.fillLevels[GRASS] = 1000
pen.visual = 6736
pen:startMeadowGrowthUpdate()
pen:finishMeadowGrowthUpdate()
check("summer: the engine's growth update (refill when the ground is full) is untouched",
    pen.spec_husbandryMeadow.fillLevels[GRASS] == 6736)

-- Autumn: the grass withers; a growth update / month change restores nothing ----------------------
pen = newPen(6000, 6736)
pen.trough[GRASS] = 200
pen.trough[22] = 900 -- hay in the trough
at(9, 7 / 30)
pen:updateFeeding()
check("wither: half way the cache is cut to 0.5 x area", near(pen.spec_husbandryMeadow.fillLevels[GRASS], 3368, 1e-6)
    and pen.spec_husbandryMeadow.dirtyFillLevels[GRASS] == true and (pen.dirtyRaised or 0) > 0)
check("wither: the food row shows it", near(pen.spec_husbandryMeadow.foodInfo.value, 3368, 1e-6))
check("wither: trough grass and hay untouched", pen.trough[GRASS] == 200 and pen.trough[22] == 900)
pen.visual, pen.visualCap = 5000, 6736
pen:startMeadowGrowthUpdate()
pen.visual = 6736
pen:finishMeadowGrowthUpdate()
check("wither: a growth update that would refill to capacity restores nothing",
    near(pen.spec_husbandryMeadow.fillLevels[GRASS], 3368, 1e-6))

at(10, 0)
pen:updateFeeding()
check("dormant: nothing left on the pasture", pen.spec_husbandryMeadow.fillLevels[GRASS] == 0
    and pen:getAvailableFood(GRASS) == 200 and pen.spec_husbandryMeadow.info.text == "0 l")
pen.visual = 6736
pen:startMeadowGrowthUpdate()
pen:finishMeadowGrowthUpdate()
check("dormant: the month change's growth update does not refill", pen.spec_husbandryMeadow.fillLevels[GRASS] == 0)
check("dormant: animals eat only the trough", pen:removeFood(500, GRASS) == 200 and pen.trough[22] == 900)

-- An old save loaded in mid winter with the autumn's grass still cached ---------------------------
local old = newPen(6589, 6736)
at(11, 0.3)
old:updateFeeding()
check("old save in January: the residual grass is gone at the first hour", old.spec_husbandryMeadow.fillLevels[GRASS] == 0)

-- Spring: real growth, capped by the ramp ---------------------------------------------------------
at(12, 0)
pen.visual = 6736
pen:startMeadowGrowthUpdate()
pen.visual = 6736
pen:finishMeadowGrowthUpdate()
check("spring: the map's late winter growth refills the cache", pen.spec_husbandryMeadow.fillLevels[GRASS] == 6736)
check("spring day 0: none of it edible yet", pen:getAvailableFood(GRASS) == 0)
at(12, 7 / 30)
hour(pen)
check("spring day 7: half the area edible", near(pen:getAvailableFood(GRASS), 3368, 1e-6)
    and near(pen.spec_husbandryMeadow.foodInfo.value, 3368, 1e-6) and near(pen.spec_husbandryMeadow.info.ratio, 0.5, 1e-6))
pen.trough[GRASS] = 100
local removed = pen:removeFood(10000, GRASS)
check(string.format("spring: a big request takes the trough and only the edible grass (%.1f)", removed),
    near(removed, 3468, 1e-6) and near(pen.spec_husbandryMeadow.fillLevels[GRASS], 3368, 1e-6) and pen.trough[GRASS] == 0)
check("spring: what is left is not edible until the ramp moves on", near(pen:getAvailableFood(GRASS), 0, 1e-6))
pen:updateFeeding()
check("spring: no cut while recovering (growth is real)", near(pen.spec_husbandryMeadow.fillLevels[GRASS], 3368, 1e-6))
at(12, 0.6)
check("spring done: all of the cache edible", near(pen:getAvailableFood(GRASS), 3368, 1e-6))

-- Warning, once a season --------------------------------------------------------------------------
NOTES = {}
pen = newPen(6736, 6736)
at(8, 0.5); hour(pen)
at(8, 0.8); hour(pen); hour(pen)
check("warning: one notification when the window opens", #NOTES == 1 and NOTES[1].text:find("rl_meadow_witherWarning", 1, true) ~= nil)
at(6, 0.5); hour(pen)
at(8, 0.8); hour(pen)
check("warning: again next season", #NOTES == 2)

-- Compatible behaviour -------------------------------------------------------------------------------
g_currentMission.missionInfo.growthMode = GrowthMode.DAILY
pen = newPen(6000, 6736)
at(10, 0.5)
pen:updateFeeding()
check("growth not seasonal: factor 1, nothing cut", pen.spec_husbandryMeadow.fillLevels[GRASS] == 6000 and pen:getAvailableFood(GRASS) == 6000)
g_currentMission.missionInfo.growthMode = GrowthMode.SEASONAL
RLPastureSeason.meadowPreset = { name = "OFF", maps = {}, enabled = false, dormancy = "AUTO", rampDownDays = 14, rampUpDays = 14, dormantFactor = 0, warnDays = 7 }
pen = newPen(6000, 6736)
pen:updateFeeding()
check("preset disabled: the base game's pasture", pen.spec_husbandryMeadow.fillLevels[GRASS] == 6000)
RLPastureSeason.meadowPreset = nil

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
