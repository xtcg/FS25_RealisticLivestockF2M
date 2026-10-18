--[[
    RLMeadowSeason.lua
    Fresh grass of a pen's own pasture through the seasons (xml/pastureSeasons.xml).
    Only husbandry meadows (PlaceableHusbandryMeadow): fields and trough stores are untouched.

    The engine keeps a pasture's grass as a cache (spec.fillLevels, liters by windrow fill type)
    that its growth updates top up from the ground's growth states, up to the full pasture when
    the ground has grown back everywhere, also at a month change in late autumn. HB's grass stays
    in its eatable states all winter, so the autumn's grass fed the animals through the winter.

    Here the edible share follows RLPastureSeason.getMeadowState (factor 0..1 x the pasture's
    grass area, capacities):
      WITHER / DORMANT  server: the cache is cut to the factor (the grass withered; the eaten
                        visuals show it), every hour before feeding and after any growth update,
                        meadow creation or load refresh, and a growth update adds nothing back
      RECOVER           what the map's growth put back, less the (1 - factor) x area not grown
                        back yet: getAvailableFood, removeFood and the food rows
                        (updateMeadowInfo) see that much
      NORMAL / WARN     the engine's rules unchanged (WARN: the owner is told once to feed)
    The ration planner (RLFeed), the engine's food consumption, the pen's food rows and info box
    all go through getAvailableFood / removeFood / foodInfo, so they see the same grass.
]]

RLMeadowSeason = {}

local Log = RmLogging.getLogger("RLRM")

local EPSILON = 1e-6
local NORMAL = { factor = 1, phase = "NORMAL", warn = false }


--- Whether the game grows by season (growth mode SEASONAL); daily or disabled growth has no
--- seasons to follow, so the pasture keeps the base rules.
function RLMeadowSeason.isSeasonalGrowth()
    local mission = g_currentMission
    local info = mission ~= nil and mission.missionInfo or nil
    if info == nil or GrowthMode == nil then return false end
    return info.growthMode == GrowthMode.SEASONAL
end


--- The pasture's dormant periods (the preset's, or its fruit types' growth tables), kept on the spec.
function RLMeadowSeason.getDormantPeriods(placeable)
    local spec = placeable.spec_husbandryMeadow
    if spec.rlDormantPeriods == nil then
        local preset = RLPastureSeason.getMeadowPreset()
        if preset.dormancy == "PERIODS" and preset.dormantPeriods ~= nil then
            spec.rlDormantPeriods = preset.dormantPeriods
        else
            spec.rlDormantPeriods = RLPastureSeason.deriveDormantPeriods(spec.fruitTypeInfos)
        end
        local list = {}
        for period = 1, 12 do if spec.rlDormantPeriods[period] then list[#list + 1] = period end end
        Log:info("RLMeadowSeason: '%s' dormant periods: %s (%s)", tostring(placeable.getName ~= nil and placeable:getName() or "?"),
            #list > 0 and table.concat(list, " ") or "none", preset.dormancy)
    end
    return spec.rlDormantPeriods
end


--- The pasture's season state now: { factor, phase, warn, daysToDormancy }.
function RLMeadowSeason.getState(placeable)
    local spec = placeable ~= nil and placeable.spec_husbandryMeadow or nil
    if spec == nil or spec.fruitTypeInfos == nil or #spec.fruitTypeInfos == 0 then return NORMAL end
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    if environment == nil or not RLMeadowSeason.isSeasonalGrowth() then return NORMAL end
    local preset = RLPastureSeason.getMeadowPreset()
    if preset == nil or not preset.enabled then return NORMAL end
    local period, progress = RLPastureSeason.getSeasonPosition(environment)
    return RLPastureSeason.getMeadowState(RLMeadowSeason.getDormantPeriods(placeable), period, progress, preset)
end


local function isCutting(state) return state.phase == "WITHER" or state.phase == "DORMANT" end


--- Liters of a fill type the animals can eat from the pasture now. While it recovers, the
--- (1 - factor) x area that has not grown back yet is held back from what the map's growth put
--- there, so grazing in the ramp takes no more than has grown (eating does not free the rest);
--- withering or dormant, at most factor x area (the server's cut, also before a client syncs).
function RLMeadowSeason.getEdible(placeable, fillTypeIndex, state)
    local spec = placeable.spec_husbandryMeadow
    local fill = spec.fillLevels[fillTypeIndex] or 0
    state = state or RLMeadowSeason.getState(placeable)
    if state.factor >= 1 then return fill end
    local area = spec.capacities[fillTypeIndex] or 0
    if state.phase == "RECOVER" then return math.max(fill - (1 - state.factor) * area, 0) end
    return math.max(math.min(fill, state.factor * area), 0)
end


--- Server: cut the cache to the factor while the grass withers or lies dormant. With `ceiling`
--- (fill type -> liters) no fill type ends above it either (a growth update adds nothing back).
--- @return table state
function RLMeadowSeason.apply(placeable, ceiling)
    local spec = placeable ~= nil and placeable.spec_husbandryMeadow or nil
    if spec == nil or not placeable.isServer then return NORMAL end
    local state = RLMeadowSeason.getState(placeable)
    if not isCutting(state) then return state end

    local changed = false
    for fillTypeIndex, fill in pairs(spec.fillLevels) do
        local limit = math.max(state.factor * (spec.capacities[fillTypeIndex] or 0), 0)
        if ceiling ~= nil and ceiling[fillTypeIndex] ~= nil then limit = math.min(limit, ceiling[fillTypeIndex]) end
        if fill > limit + EPSILON then
            spec.fillLevels[fillTypeIndex] = limit
            spec.dirtyFillLevels[fillTypeIndex] = true
            changed = true
            Log:debug("RLMeadowSeason: '%s' %s %s: %.1f -> %.1f l (factor %.3f)", tostring(placeable.getName ~= nil and placeable:getName() or "?"),
                state.phase, tostring(fillTypeIndex), fill, limit, state.factor)
        end
    end
    if changed then
        if placeable.raiseDirtyFlags ~= nil and spec.dirtyFlag ~= nil then placeable:raiseDirtyFlags(spec.dirtyFlag) end
        if placeable.updateMeadowInfo ~= nil then placeable:updateMeadowInfo() end
    end
    return state
end


-- =============================================================================
-- Engine hooks
-- =============================================================================

--- Swap the cache to what is edible for the call, then put back what was not eaten.
local function withEdible(placeable, fillTypeIndex, fn)
    local spec = placeable.spec_husbandryMeadow
    local fill = spec ~= nil and spec.fillLevels ~= nil and spec.fillLevels[fillTypeIndex] or nil
    if fill == nil then return fn(), false end
    local edible = RLMeadowSeason.getEdible(placeable, fillTypeIndex)
    if edible >= fill then return fn(), false end
    spec.fillLevels[fillTypeIndex] = edible
    local ok, result = pcall(fn)
    local eaten = math.max(edible - (spec.fillLevels[fillTypeIndex] or edible), 0)
    spec.fillLevels[fillTypeIndex] = math.max(fill - eaten, 0)
    if not ok then error(result, 0) end
    return result, true
end


function RLMeadowSeason:getAvailableFood(superFunc, fillTypeIndex)
    return (withEdible(self, fillTypeIndex, function() return superFunc(self, fillTypeIndex) end))
end


function RLMeadowSeason:removeFood(superFunc, deltaToRemove, fillTypeIndex)
    local removed, swapped = withEdible(self, fillTypeIndex, function() return superFunc(self, deltaToRemove, fillTypeIndex) end)
    if swapped and self.updateMeadowInfo ~= nil then self:updateMeadowInfo() end
    return removed
end


--- The hour's feeding (server): first cut withered grass, so none of it is eaten this hour.
function RLMeadowSeason:updateFeeding(superFunc)
    if self.isServer then RmSafeUtils.safeCall("RLMeadowSeason.apply", function() RLMeadowSeason.apply(self) end) end
    return superFunc(self)
end


--- Food rows and info box: the edible grass.
function RLMeadowSeason.updateMeadowInfo(placeable)
    local spec = placeable.spec_husbandryMeadow
    if spec == nil or spec.fillLevels == nil then return end
    local state = RLMeadowSeason.getState(placeable)
    if state.factor >= 1 then return end
    local value, capacity = 0, 0
    for fillTypeIndex, _ in pairs(spec.fillLevels) do
        value = value + RLMeadowSeason.getEdible(placeable, fillTypeIndex, state)
        capacity = capacity + (spec.capacities[fillTypeIndex] or 0)
    end
    local ratio = capacity > 0 and value / capacity or 0
    for _, info in ipairs({ spec.foodInfo, spec.info }) do
        if info ~= nil then
            info.value = value
            info.capacity = capacity
            info.ratio = ratio
        end
    end
    if spec.info ~= nil then spec.info.text = string.format("%d l", value) end
end


--- A growth update (server): while the grass withers or is dormant it restores nothing.
function RLMeadowSeason.wrapGrowthUpdate(placeable, superFunc, ...)
    local spec = placeable.spec_husbandryMeadow
    local before
    if placeable.isServer and spec ~= nil and spec.fillLevels ~= nil then
        before = {}
        for fillTypeIndex, fill in pairs(spec.fillLevels) do before[fillTypeIndex] = fill end
    end
    local result = superFunc(placeable, ...)
    if before ~= nil then
        RmSafeUtils.safeCall("RLMeadowSeason.growth", function()
            local state = RLMeadowSeason.apply(placeable, before)
            if isCutting(state) then
                Log:debug("RLMeadowSeason: '%s' growth update in %s kept to the withered grass",
                    tostring(placeable.getName ~= nil and placeable:getName() or "?"), state.phase)
            end
        end)
    end
    return result
end


--- Hourly on every machine: tell the owner once before the grass dies back; keep the food rows
--- on the ramp (a client's rows follow the same factor).
function RLMeadowSeason:onHourChanged()
    local spec = self.spec_husbandryMeadow
    if spec == nil then return end
    RmSafeUtils.safeCall("RLMeadowSeason.onHourChanged", function()
        local state = RLMeadowSeason.getState(self)
        if state.factor < 1 or spec.rlSeasonFactor ~= nil and spec.rlSeasonFactor < 1 then
            if self.updateMeadowInfo ~= nil then self:updateMeadowInfo() end
        end
        spec.rlSeasonFactor = state.factor
        RLMeadowSeason.notify(self, state)
    end)
end


--- One notification a season, when the warning window opens, for the pen owner's own player.
function RLMeadowSeason.notify(placeable, state)
    local spec = placeable.spec_husbandryMeadow
    if not state.warn then
        spec.rlWitherWarned = nil
        return
    end
    if spec.rlWitherWarned then return end
    spec.rlWitherWarned = true
    local mission = g_currentMission
    if mission == nil or mission.addIngameNotification == nil or FSBaseMission == nil then return end
    if placeable.getOwnerFarmId ~= nil and mission.getFarmId ~= nil and placeable:getOwnerFarmId() ~= mission:getFarmId() then return end
    if g_i18n == nil then return end
    local name = placeable.getName ~= nil and placeable:getName() or ""
    local days = math.max(math.ceil((state.daysToDormancy or 0) - EPSILON), 0)
    mission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
        string.format(g_i18n:getText("rl_meadow_witherWarning"), name, days))
    Log:info("RLMeadowSeason: '%s' warned: grass dies back in %d model days", name, days)
end


-- Registration: outer wrappers of the meadow's own overrides, its info refresh, growth update,
-- creation and load refresh, and an hourly listener.
if PlaceableHusbandryMeadow ~= nil then
    PlaceableHusbandryMeadow.registerOverwrittenFunctions = Utils.appendedFunction(PlaceableHusbandryMeadow.registerOverwrittenFunctions,
        function(placeableType)
            SpecializationUtil.registerOverwrittenFunction(placeableType, "getAvailableFood", RLMeadowSeason.getAvailableFood)
            SpecializationUtil.registerOverwrittenFunction(placeableType, "removeFood", RLMeadowSeason.removeFood)
            SpecializationUtil.registerOverwrittenFunction(placeableType, "updateFeeding", RLMeadowSeason.updateFeeding)
        end)

    PlaceableHusbandryMeadow.registerEventListeners = Utils.appendedFunction(PlaceableHusbandryMeadow.registerEventListeners,
        function(placeableType)
            SpecializationUtil.registerEventListener(placeableType, "onHourChanged", RLMeadowSeason)
        end)

    PlaceableHusbandryMeadow.updateMeadowInfo = Utils.appendedFunction(PlaceableHusbandryMeadow.updateMeadowInfo, RLMeadowSeason.updateMeadowInfo)

    PlaceableHusbandryMeadow.finishMeadowGrowthUpdate = Utils.overwrittenFunction(PlaceableHusbandryMeadow.finishMeadowGrowthUpdate,
        RLMeadowSeason.wrapGrowthUpdate)

    local function applyAfter(self)
        if self.isServer then RmSafeUtils.safeCall("RLMeadowSeason.apply", function() RLMeadowSeason.apply(self) end) end
    end
    PlaceableHusbandryMeadow.finishedMeadow = Utils.appendedFunction(PlaceableHusbandryMeadow.finishedMeadow, applyAfter)
    PlaceableHusbandryMeadow.onHusbandryAnimalsCreated = Utils.appendedFunction(PlaceableHusbandryMeadow.onHusbandryAnimalsCreated, applyAfter)
end
