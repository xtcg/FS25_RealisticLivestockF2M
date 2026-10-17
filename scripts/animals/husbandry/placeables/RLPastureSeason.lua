--[[
    RLPastureSeason.lua
    Seasons of a pen's own pasture (xml/pastureSeasons.xml): the config, the preset of the loaded
    map, and the pure season arithmetic of the pasture adapter (RLMeadowSeason). The period
    helpers (getSeasonPosition, getMonthIndex, parsePeriods, isMapLoaded, resolvePreset) are also
    used by the wool shearing season (RLWoolShearing).

    Time is the engine's: period 1 is early spring, a period is RLPastureSeason.MODEL_DAYS model
    days at any days-per-month setting, and the position within it comes from the day in the
    period and the time of day. Nothing here reads g_* except getConfig / getMeadowPreset (files,
    the loaded map) and getSeasonPosition (the environment it is given).
]]

RLPastureSeason = {}

local Log = RmLogging.getLogger("RLRM")

RLPastureSeason.CONFIG_FILE = "pastureSeasons.xml"
RLPastureSeason.MODEL_DAYS = 30

RLPastureSeason.PERIODS = {
    EARLY_SPRING = 1, MID_SPRING = 2, LATE_SPRING = 3, EARLY_SUMMER = 4, MID_SUMMER = 5, LATE_SUMMER = 6,
    EARLY_AUTUMN = 7, MID_AUTUMN = 8, LATE_AUTUMN = 9, EARLY_WINTER = 10, MID_WINTER = 11, LATE_WINTER = 12,
}

RLPastureSeason.MEADOW_DEFAULTS = {
    enabled = true, dormancy = "AUTO", rampDownDays = 14, rampUpDays = 14, dormantFactor = 0, warnDays = 7,
}


-- =============================================================================
-- Config
-- =============================================================================

--- Periods named in a space-separated list, as a set (period -> true); nil for none valid.
function RLPastureSeason.parsePeriods(text, where)
    if text == nil then return nil end
    local set, any = {}, false
    for name in text:gmatch("%S+") do
        local period = RLPastureSeason.PERIODS[name:upper()] or tonumber(name)
        if period ~= nil and period >= 1 and period <= 12 and period == math.floor(period) then
            set[period] = true
            any = true
        else
            Log:warning("RLPastureSeason: %s: unknown period '%s' ignored", where, name)
        end
    end
    return any and set or nil
end

function RLPastureSeason.parseMaps(text)
    local maps = {}
    for name in (text or ""):gmatch("%S+") do maps[#maps + 1] = name end
    return maps
end

local function nonNegative(value, default)
    if type(value) ~= "number" or value ~= value or value < 0 then return default end
    return value
end


--- @param xmlFile table|nil XMLFile with a pastureSeasons root; nil gives the defaults
--- @return table config { meadow = { presets } }
function RLPastureSeason.parse(xmlFile)
    local config = { meadow = { presets = {} } }

    if xmlFile ~= nil then
        local d = RLPastureSeason.MEADOW_DEFAULTS
        xmlFile:iterate("pastureSeasons.meadow.preset", function(_, key)
            local name = xmlFile:getString(key .. "#name", "DEFAULT")
            local preset = {
                name = name:upper(),
                maps = RLPastureSeason.parseMaps(xmlFile:getString(key .. "#maps")),
                enabled = xmlFile:getBool(key .. "#enabled", d.enabled),
                dormancy = (xmlFile:getString(key .. "#dormancy", d.dormancy) or d.dormancy):upper(),
                dormantPeriods = RLPastureSeason.parsePeriods(xmlFile:getString(key .. "#dormantPeriods"), key),
                rampDownDays = nonNegative(xmlFile:getFloat(key .. "#rampDownDays", d.rampDownDays), d.rampDownDays),
                rampUpDays = nonNegative(xmlFile:getFloat(key .. "#rampUpDays", d.rampUpDays), d.rampUpDays),
                dormantFactor = math.clamp(nonNegative(xmlFile:getFloat(key .. "#dormantFactor", d.dormantFactor), d.dormantFactor), 0, 1),
                warnDays = xmlFile:getFloat(key .. "#warnDays", d.warnDays),
            }
            if preset.dormancy ~= "AUTO" and preset.dormancy ~= "PERIODS" then
                Log:warning("RLPastureSeason: %s: dormancy '%s' unknown, AUTO used", key, preset.dormancy)
                preset.dormancy = "AUTO"
            end
            if preset.dormancy == "PERIODS" and preset.dormantPeriods == nil then
                Log:warning("RLPastureSeason: %s: dormancy PERIODS without dormantPeriods, AUTO used", key)
                preset.dormancy = "AUTO"
            end
            table.insert(config.meadow.presets, preset)
        end)
    end

    return config
end


--- The config, loaded on the first call.
function RLPastureSeason.getConfig()
    if RLPastureSeason.config == nil then
        RLPastureSeason.config = RLBreedTraits.loadConfig(RLPastureSeason.CONFIG_FILE, "pastureSeasons", RLPastureSeason.parse)
    end
    return RLPastureSeason.config
end


--- Whether the map mod `name` is the loaded map: an active map bridge, a loaded mod of that
--- name, or the mission's map id in that mod.
function RLPastureSeason.isMapLoaded(name)
    if RLMapBridge ~= nil and RLMapBridge.isMapActive ~= nil and RLMapBridge.isMapActive(name) then return true end
    if g_modIsLoaded ~= nil and g_modIsLoaded[name] then return true end
    local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local mapId = missionInfo ~= nil and missionInfo.mapId or nil
    return type(mapId) == "string" and mapId:sub(1, #name + 1) == name .. "."
end


--- The preset of a section for the loaded map: the first map preset whose maps include it,
--- else DEFAULT (else the section's defaults).
--- @param presets table list of presets
--- @param isLoaded function|nil map name -> boolean (RLPastureSeason.isMapLoaded)
function RLPastureSeason.resolvePreset(presets, isLoaded)
    isLoaded = isLoaded or RLPastureSeason.isMapLoaded
    local default
    for _, preset in ipairs(presets or {}) do
        if #preset.maps > 0 then
            for _, map in ipairs(preset.maps) do
                if isLoaded(map) then return preset end
            end
        elseif default == nil and preset.name == "DEFAULT" then
            default = preset
        end
    end
    return default
end


--- The pasture preset of the loaded map (resolved once).
function RLPastureSeason.getMeadowPreset()
    if RLPastureSeason.meadowPreset == nil then
        local preset = RLPastureSeason.resolvePreset(RLPastureSeason.getConfig().meadow.presets)
        if preset == nil then
            preset = table.clone(RLPastureSeason.MEADOW_DEFAULTS)
            preset.name, preset.maps = "DEFAULT", {}
        end
        RLPastureSeason.meadowPreset = preset
        Log:info("RLPastureSeason: pasture preset %s (enabled=%s dormancy=%s down=%.1f up=%.1f factor=%.2f warn=%.1f)",
            preset.name, tostring(preset.enabled), preset.dormancy, preset.rampDownDays, preset.rampUpDays,
            preset.dormantFactor, preset.warnDays)
    end
    return RLPastureSeason.meadowPreset
end


--- Forget the loaded config and presets (tests; a reload).
function RLPastureSeason.reset()
    RLPastureSeason.config, RLPastureSeason.meadowPreset = nil, nil
end


-- =============================================================================
-- Season arithmetic (pure)
-- =============================================================================

--- The period and the share of it gone (0..1) from an environment.
--- @param environment table currentPeriod, currentDayInPeriod, daysPerPeriod, dayTime (ms)
--- @return number period, number progress
function RLPastureSeason.getSeasonPosition(environment)
    local period = environment.currentPeriod or 1
    local days = math.max(environment.daysPerPeriod or 1, 1)
    local day = math.clamp((environment.currentDayInPeriod or 1) - 1, 0, days - 1)
    local dayShare = math.clamp((environment.dayTime or 0) / 86400000, 0, 0.999999)
    return period, math.clamp((day + dayShare) / days, 0, 0.999999)
end


--- A running month count (12 per engine year) for intervals across years.
function RLPastureSeason.getMonthIndex(environment)
    return (environment.currentYear or 0) * 12 + (environment.currentPeriod or 1) - 1
end


local function wrap(period) return (period - 1) % 12 + 1 end


--- Dormant periods of a pasture from its fruit types' seasonal growth tables: a period in which
--- no fruit type grows a state into or within its eatable band (start..end) is dormant. A fruit
--- type without a seasonal table makes the pasture never dormant (nothing to go by).
--- @param fruitInfos table list of { fruitType = { growthDataSeasonal = { periods } }, eatableStartGrowthState, eatableEndGrowthState }
--- @return table set period -> true
function RLPastureSeason.deriveDormantPeriods(fruitInfos)
    local dormant = {}
    if fruitInfos == nil or #fruitInfos == 0 then return dormant end
    for _, info in ipairs(fruitInfos) do
        local growth = info.fruitType ~= nil and info.fruitType.growthDataSeasonal or nil
        if growth == nil or growth.periods == nil then return {} end
    end
    for period = 1, 12 do
        local growing = false
        for _, info in ipairs(fruitInfos) do
            local periodInfo = info.fruitType.growthDataSeasonal.periods[period]
            local mapping = periodInfo ~= nil and periodInfo.growthMapping or nil
            local first, last = info.eatableStartGrowthState, info.eatableEndGrowthState
            if mapping ~= nil and first ~= nil and last ~= nil then
                for state, target in pairs(mapping) do
                    if target > state and target >= first and target <= last then
                        growing = true
                        break
                    end
                end
            end
            if growing then break end
        end
        if not growing then dormant[period] = true end
    end
    return dormant
end


--- The pasture's season state at a time of year.
--- @param dormant table period -> true
--- @param period number 1..12
--- @param progress number 0..1 within the period
--- @param preset table meadow preset
--- @return table { factor, phase (NORMAL|WARN|WITHER|DORMANT|RECOVER), daysToDormancy|nil, warn }
function RLPastureSeason.getMeadowState(dormant, period, progress, preset)
    local count = 0
    for p = 1, 12 do if dormant[p] then count = count + 1 end end
    if count == 0 or count == 12 or preset == nil or not preset.enabled then
        return { factor = 1, phase = "NORMAL", warn = false }
    end

    local D = RLPastureSeason.MODEL_DAYS
    local low = preset.dormantFactor or 0
    period = wrap(period)

    if dormant[period] then
        local back = 0
        while dormant[wrap(period - back - 1)] do back = back + 1 end
        local days = (back + progress) * D
        local down = preset.rampDownDays or 0
        if down > 0 and days < down then
            return { factor = 1 - (1 - low) * days / down, phase = "WITHER", warn = false, daysIntoDormancy = days }
        end
        return { factor = low, phase = "DORMANT", warn = false, daysIntoDormancy = days }
    end

    local back = 0
    while not dormant[wrap(period - back - 1)] do back = back + 1 end
    local days = (back + progress) * D
    local up = preset.rampUpDays or 0
    local state
    if up > 0 and days < up then
        state = { factor = low + (1 - low) * days / up, phase = "RECOVER" }
    else
        state = { factor = 1, phase = "NORMAL" }
    end

    local ahead = 1
    while not dormant[wrap(period + ahead)] do ahead = ahead + 1 end
    state.daysToDormancy = (ahead - progress) * D
    state.warn = preset.warnDays ~= nil and preset.warnDays >= 0 and state.daysToDormancy <= preset.warnDays
    if state.warn and state.phase == "NORMAL" then state.phase = "WARN" end
    return state
end


Log:debug("RLPastureSeason: loaded")
