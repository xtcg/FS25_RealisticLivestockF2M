--[[
    RLWoolShearing.lua
    When a pen's sheep wool becomes pallets (xml/breedTraits.xml, woolShearing).

    A fleece grows all year: Animal:updateOutput gives each sheep its wool liters an hour (wool
    curve, breedTraits woolScale, productivity, disease) and the pen's pallet module sums them
    (litersPerHour), as before. What changes is only where that wool goes:

      YEAR_ROUND        to the pen's pallets every hour (the base game's way, the old behaviour)
      SPRING_SHEARING   onto the sheep: each one keeps what it grew (animal.rlFleece, liters of
                        its pallet fill type, saved with the animal), and the pen shears once, in
                        the first hour of a shearingPeriods month in which it holds wool and its
                        last shearing was at least intervalMonths ago. The shearing moves exactly
                        the fleece on its sheep to the pen's pending pallet liters; nothing is
                        made up, so a year's wool is the same as YEAR_ROUND's.

    Server only, from the pen's hourly output (RealisticLivestock_PlaceableHusbandryPallets:updateOutput)
    with the same factors the base output uses (productionFactor x globalProductionFactor x
    timeAdjustment). A Hof Bergmann stall in manual shearing (its shearing station) is left to
    the map. Under YEAR_ROUND any fleece still on a pen's sheep goes to its pallets the next hour.
]]

RLWoolShearing = {}

local Log = RmLogging.getLogger("RLRM")

RLWoolShearing.YEAR_ROUND = "YEAR_ROUND"
RLWoolShearing.SPRING_SHEARING = "SPRING_SHEARING"
RLWoolShearing.DEFAULT_FILL_TYPES = { "WOOL", "SHEEPWOOL_SHEARED" }
RLWoolShearing.DEFAULT_SHEARING_PERIODS = "LATE_SPRING EARLY_SUMMER"

--- Used when breedTraits.xml has no woolShearing block (an older copy in modSettings).
function RLWoolShearing.getDefaultConfig()
    local fillTypes = {}
    for _, name in ipairs(RLWoolShearing.DEFAULT_FILL_TYPES) do fillTypes[name] = true end
    return {
        fillTypes = fillTypes,
        presets = {
            { name = "DEFAULT", maps = {}, mode = RLWoolShearing.YEAR_ROUND, intervalMonths = 12 },
            { name = "HOF_BERGMANN", maps = { "FS25_HofBergmann" }, mode = RLWoolShearing.SPRING_SHEARING,
                shearingPeriods = RLPastureSeason.parsePeriods(RLWoolShearing.DEFAULT_SHEARING_PERIODS, "default"), intervalMonths = 12 },
        },
    }
end


--- @param xmlFile table|nil breedTraits.xml
--- @return table config { fillTypes = name -> true, presets }
function RLWoolShearing.parse(xmlFile)
    if xmlFile == nil or xmlFile:getString("breedTraits.woolShearing#fillTypes") == nil
        and xmlFile:getString("breedTraits.woolShearing.preset(0)#mode") == nil then
        return RLWoolShearing.getDefaultConfig()
    end

    local config = { fillTypes = {}, presets = {} }
    local names = xmlFile:getString("breedTraits.woolShearing#fillTypes", table.concat(RLWoolShearing.DEFAULT_FILL_TYPES, " "))
    for name in names:gmatch("%S+") do config.fillTypes[name:upper()] = true end

    xmlFile:iterate("breedTraits.woolShearing.preset", function(_, key)
        local preset = {
            name = (xmlFile:getString(key .. "#name", "DEFAULT")):upper(),
            maps = RLPastureSeason.parseMaps(xmlFile:getString(key .. "#maps")),
            mode = (xmlFile:getString(key .. "#mode", RLWoolShearing.YEAR_ROUND)):upper(),
            shearingPeriods = RLPastureSeason.parsePeriods(xmlFile:getString(key .. "#shearingPeriods", RLWoolShearing.DEFAULT_SHEARING_PERIODS), key),
            intervalMonths = math.max(math.floor(xmlFile:getInt(key .. "#intervalMonths", 12) or 12), 1),
        }
        if preset.mode ~= RLWoolShearing.YEAR_ROUND and preset.mode ~= RLWoolShearing.SPRING_SHEARING then
            Log:warning("RLWoolShearing: %s: mode '%s' unknown, YEAR_ROUND used", key, preset.mode)
            preset.mode = RLWoolShearing.YEAR_ROUND
        end
        if preset.mode == RLWoolShearing.SPRING_SHEARING and preset.shearingPeriods == nil then
            Log:warning("RLWoolShearing: %s: no valid shearingPeriods, YEAR_ROUND used", key)
            preset.mode = RLWoolShearing.YEAR_ROUND
        end
        table.insert(config.presets, preset)
    end)
    return config
end


function RLWoolShearing.getConfig()
    if RLWoolShearing.config == nil then
        RLWoolShearing.config = RLBreedTraits.loadConfig(RLBreedTraits.CONFIG_FILE or "breedTraits.xml", "breedTraits", RLWoolShearing.parse)
    end
    return RLWoolShearing.config
end


--- The loaded map's preset (resolved once).
function RLWoolShearing.getPreset()
    if RLWoolShearing.preset == nil then
        local preset = RLPastureSeason.resolvePreset(RLWoolShearing.getConfig().presets)
        if preset == nil then preset = { name = "DEFAULT", maps = {}, mode = RLWoolShearing.YEAR_ROUND, intervalMonths = 12 } end
        RLWoolShearing.preset = preset
        local periods = {}
        for period = 1, 12 do if preset.shearingPeriods ~= nil and preset.shearingPeriods[period] then periods[#periods + 1] = period end end
        Log:info("RLWoolShearing: preset %s (mode=%s shearingPeriods=%s interval=%d months)", preset.name, preset.mode,
            #periods > 0 and table.concat(periods, " ") or "-", preset.intervalMonths or 12)
    end
    return RLWoolShearing.preset
end


function RLWoolShearing.reset()
    RLWoolShearing.config, RLWoolShearing.preset = nil, nil
end


function RLWoolShearing.isWoolFillType(fillTypeIndex)
    if fillTypeIndex == nil or g_fillTypeManager == nil then return false end
    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    return name ~= nil and RLWoolShearing.getConfig().fillTypes[name:upper()] == true
end


--- A Hof Bergmann stall set to manual shearing: the map's shearing station takes its wool.
function RLWoolShearing.isManual(placeable)
    if placeable.lsfmGetShearingStationEnabled == nil then return false end
    local ok, manual = pcall(placeable.lsfmGetShearingStationEnabled, placeable)
    return ok and manual == true
end


--- From the pen's input/output refresh: one entry per animal whose wool this pen spawns.
function RLWoolShearing.addContribution(spec, animal, fillType, liters)
    if not RLWoolShearing.isWoolFillType(fillType) then return end
    spec.rlWoolContributions = spec.rlWoolContributions or {}
    table.insert(spec.rlWoolContributions, { animal = animal, fillType = fillType, liters = liters })
end


local function penName(placeable) return tostring(placeable.getName ~= nil and placeable:getName() or "?") end


--- The pen's animals now (the clusters of its husbandry).
local function getAnimals(placeable)
    local animals = placeable.spec_husbandryAnimals
    local clusterSystem = animals ~= nil and animals.clusterSystem or nil
    if clusterSystem == nil or clusterSystem.getClusters == nil then return {} end
    return clusterSystem:getClusters() or {}
end


--- Move the fleece on the pen's sheep to its pending pallet liters.
--- @return number sheep, table liters by fill type
function RLWoolShearing.takeFleece(placeable)
    local spec = placeable.spec_husbandryPallets
    local count, totals = 0, {}
    for _, animal in pairs(getAnimals(placeable)) do
        local fleece = animal.rlFleece
        if fleece ~= nil and fleece > 0 then
            local subType = animal.getSubType ~= nil and animal:getSubType() or nil
            local pallets = subType ~= nil and subType.output ~= nil and subType.output.pallets or nil
            local fillType = pallets ~= nil and pallets.fillType or nil
            if fillType ~= nil and spec.pendingLiters[fillType] ~= nil and RLWoolShearing.isWoolFillType(fillType) then
                totals[fillType] = (totals[fillType] or 0) + fleece
                animal.rlFleece = 0
                count = count + 1
            end
        end
    end
    for fillType, liters in pairs(totals) do spec.pendingLiters[fillType] = spec.pendingLiters[fillType] + liters end
    if count > 0 and placeable.updatePallets ~= nil then placeable:updatePallets() end
    return count, totals
end


--- Shear the pen if this month is a shearing month and the interval has passed.
--- @return boolean sheared
function RLWoolShearing.tryShear(placeable, preset, environment)
    local spec = placeable.spec_husbandryPallets
    if preset.shearingPeriods == nil or not preset.shearingPeriods[environment.currentPeriod] then return false end
    local month = RLPastureSeason.getMonthIndex(environment)
    local last = spec.rlLastShearMonth
    if last ~= nil and last <= month and month - last < (preset.intervalMonths or 12) then return false end

    local count, totals = RLWoolShearing.takeFleece(placeable)
    if count == 0 then return false end
    spec.rlLastShearMonth = month

    local liters = 0
    for fillType, amount in pairs(totals) do
        liters = liters + amount
        Log:info("RLWoolShearing: '%s' sheared %d sheep: %.2f l %s (month %d)", penName(placeable), count, amount,
            tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType)), month)
    end

    local mission = g_currentMission
    if mission ~= nil and mission.addIngameNotification ~= nil and FSBaseMission ~= nil and g_i18n ~= nil
        and (placeable.getOwnerFarmId == nil or mission.getFarmId == nil or placeable:getOwnerFarmId() == mission:getFarmId()) then
        mission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText("rl_wool_shorn"), penName(placeable), count, math.floor(liters + 0.5)))
    end
    return true
end


--- The pen's hourly pallet output (server). `base` runs the output of the other fill types (and
--- of the wool under YEAR_ROUND).
function RLWoolShearing.runOutput(placeable, base, productionFactor, globalProductionFactor)
    local spec = placeable.spec_husbandryPallets
    local contributions = spec ~= nil and spec.rlWoolContributions or nil
    if contributions == nil or #contributions == 0 or RLWoolShearing.isManual(placeable) then return base() end

    local preset = RLWoolShearing.getPreset()
    if preset.mode ~= RLWoolShearing.SPRING_SHEARING then
        base()
        -- Wool left on the sheep from a shearing season (the mode was switched): to the pallets.
        local count, totals = RLWoolShearing.takeFleece(placeable)
        if count > 0 then
            for fillType, liters in pairs(totals) do
                Log:info("RLWoolShearing: '%s' released %.2f l %s still on %d sheep (YEAR_ROUND)", penName(placeable), liters,
                    tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType)), count)
            end
        end
        return
    end

    -- Hold the sheep's wool back from this hour's pallets.
    local held = {}
    for _, entry in ipairs(contributions) do held[entry.fillType] = (held[entry.fillType] or 0) + entry.liters end
    local saved = {}
    for fillType, liters in pairs(held) do
        if spec.litersPerHour[fillType] ~= nil then
            saved[fillType] = spec.litersPerHour[fillType]
            spec.litersPerHour[fillType] = math.max(saved[fillType] - liters, 0)
        end
    end
    local ok, err = pcall(base)
    for fillType, liters in pairs(saved) do spec.litersPerHour[fillType] = liters end
    if not ok then error(err, 0) end

    -- ... onto the sheep, with the same factors the base output uses.
    local environment = g_currentMission.environment
    local factor = productionFactor * globalProductionFactor * (environment.timeAdjustment or 1)
    if factor > 0 then
        for _, entry in ipairs(contributions) do
            if saved[entry.fillType] ~= nil and entry.liters > 0 then
                entry.animal.rlFleece = (entry.animal.rlFleece or 0) + entry.liters * factor
            end
        end
    end

    RLWoolShearing.tryShear(placeable, preset, environment)
end


-- =============================================================================
-- Persistence
-- =============================================================================

function RLWoolShearing.savePen(placeable, xmlFile, key)
    local spec = placeable.spec_husbandryPallets
    if spec ~= nil and spec.rlLastShearMonth ~= nil then xmlFile:setInt(key .. ".rlWool#lastShearMonth", spec.rlLastShearMonth) end
end


--- An old savegame's pen has no shearing on record: it shears at the next shearing month.
function RLWoolShearing.loadPen(placeable, xmlFile, key)
    local spec = placeable.spec_husbandryPallets
    if spec ~= nil then spec.rlLastShearMonth = xmlFile:getInt(key .. ".rlWool#lastShearMonth") end
end


--- An animal's fleece: saved only when it carries some; an old savegame's animal starts bare.
function RLWoolShearing.saveAnimal(animal, xmlFile, key)
    if animal.rlFleece ~= nil and animal.rlFleece > 0 then xmlFile:setFloat(key .. "#rlFleece", animal.rlFleece) end
end


function RLWoolShearing.loadAnimal(animal, xmlFile, key)
    local fleece = xmlFile:getFloat(key .. "#rlFleece")
    if fleece ~= nil and fleece == fleece and fleece > 0 then animal.rlFleece = fleece end
end


Log:debug("RLWoolShearing: loaded")
