--[[
    RLFeed.lua
    The real-equivalent nutrition mode in the game (xml/feedProfiles.xml, RLFeedMath,
    RLFeedRationPlanner): which pens run it, the pen's hourly feeding, what each animal ate in real
    dry matter and ME, the weight model's step on that energy, health from what the hour paid for,
    and the cattle troughs' grain.

    Mode. RL settings > Nutrition model: Legacy (default) or Real-equivalent, per savegame. The
    mode needs the weight model v2 and body condition on and feedProfiles.xml valid. Changing it is
    a setting, never something a pen falls into.

    Pens. A cattle pen runs the mode for an hour when every animal in it is covered by the weight
    model v2 and none outside a calf rearing pen is still on milk (its dam's milk is not in any
    trough, so the pen's ration cannot stand for its diet). Any other cattle pen keeps the old
    rules as a whole for that hour; RLFeed.getPenState says why. One pen, one hour, one set of
    rules: never old energy with new liters.

    Feeding (server, per pen and hour). RLFeed.beginFeeding decides; the engine's own feeding then
    asks AnimalFoodSystem:consumeFood, which in a pen running the mode returns the planner's
    liters per fill type (removed through the trough and meadow as usual) and the share of the
    planned ME the pen got as its food factor. RLFeed.endFeeding gives each animal what it ate
    (animal.rlFeedIntake), scaled to what the trough really lost, and adds it to the pen's month.

    Step. RLGrowth.step values an animal's hour at the ME it ate (supplyPerPeriod), in ME units
    (RLFeedMath.getEnergyConfig), with protein limiting growth and milk. An animal with no record
    in an hour its pen ran the mode (moved in after the feeding) ate nothing that hour.

    Health. AnimalHealth.updateHealth, for these animals, settles the budget first and then takes
    health from it (RLFeed.applyHealth) instead of the old food-factor threshold and the 60%-of-
    curve rule: up while feed pays for maintenance, unchanged while the reserve buffers, down by
    the share left to frame breakdown or unpaid; only an animal below extremeUnderweightRatio of its
    curve loses health for its weight alone. Both at per-month rates, the same at any month length.

    Grain. Cattle troughs also take the grains of RLFeed.GRAINS the map has, as their own food
    group, registered once after the map's animal food is loaded (the map's own groups, and every
    other species, are left as they are). Under the old rules grain is never eaten.
]]

RLFeed = {}

local Log = RmLogging.getLogger("RLRM")

RLFeed.MODE_LEGACY = 1
RLFeed.MODE_REAL = 2
--- The setting's value (RLSettings nutritionMode).
RLFeed.mode = RLFeed.MODE_LEGACY

RLFeed.TARGETS = { "AUTO", "FINISH", "GROW", "MAINTAIN" }
--- Grains cattle troughs take, in the order AUTO takes them (wheat last: it has its own limit).
RLFeed.GRAINS = { "MAIZE", "BARLEY", "OAT", "WHEAT" }
--- Concentrate share targets a pen may set (nil: as much as the ration rules allow).
RLFeed.SHARES = { 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 }

RLFeed.DEFAULT_RATION = { target = "AUTO", grain = "AUTO", share = nil, substitute = true }

RLFeed.STATE_VERSION = 1


-- =============================================================================
-- Mode
-- =============================================================================

--- RLSettings callback.
function RLFeed.onSettingChanged(name, value)
    if name ~= "nutritionMode" then return end
    local mode = value == RLFeed.MODE_REAL and RLFeed.MODE_REAL or RLFeed.MODE_LEGACY
    if mode ~= RLFeed.mode then
        Log:info("RLFeed: nutrition model %s", mode == RLFeed.MODE_REAL and "real-equivalent" or "legacy")
    end
    RLFeed.mode = mode
end


--- Whether the mode can run at all, and why not.
--- @return boolean
--- @return string reason "OK", "MODE_OFF", "CONFIG_INVALID", "MODEL_OFF"
function RLFeed.canRun()
    if RLFeed.mode ~= RLFeed.MODE_REAL then return false, "MODE_OFF" end
    if not RLFeedProfiles.isValid() then return false, "CONFIG_INVALID" end
    if RLGrowth == nil or not RLGrowth.isEnabled() then return false, "MODEL_OFF" end
    return true, "OK"
end


function RLFeed.getConfig()
    return RLFeedProfiles.getConfig()
end


local energyCache = { body = nil, feed = nil, cfg = nil }

--- The budget step's config in ME (cached per pair of config tables).
function RLFeed.getEnergyConfig()
    local body, feed = RLBodyCondition.getConfig(), RLFeedProfiles.getConfig()
    if energyCache.body ~= body or energyCache.feed ~= feed then
        energyCache.body, energyCache.feed = body, feed
        energyCache.cfg = RLFeedMath.getEnergyConfig(body, feed)
    end
    return energyCache.cfg
end


--- Real days one game hour stands for now.
function RLFeed.getHourDays()
    local environment = g_currentMission.environment
    return RLFeedUnits.getHourDays(RLFeed.getConfig().realDaysPerPeriod, environment.daysPerPeriod)
end


-- =============================================================================
-- Pen ration settings
-- =============================================================================

--- A pen's ration settings (a copy of the defaults when it has none).
--- @param placeable table
--- @return table { target, grain, share (nil: as much as allowed), substitute }
function RLFeed.getRation(placeable)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    local ration = spec ~= nil and spec.rlFeedRation or nil
    return ration or RLFeed.DEFAULT_RATION
end


local function isTarget(value)
    for _, target in ipairs(RLFeed.TARGETS) do if target == value then return true end end
    return false
end

local function isGrainChoice(value)
    if value == "AUTO" or value == "NONE" then return true end
    for _, grain in ipairs(RLFeed.GRAINS) do if grain == value then return true end end
    return false
end


--- A ration settings table checked: unknown values fall back to the defaults (with false).
--- @param ration table
--- @return table ration
--- @return boolean ok every value was valid
function RLFeed.sanitizeRation(ration)
    local out, ok = {}, true
    ration = ration or {}
    out.target = type(ration.target) == "string" and ration.target:upper() or nil
    if not isTarget(out.target) then out.target, ok = RLFeed.DEFAULT_RATION.target, ration.target == nil and ok or false end
    out.grain = type(ration.grain) == "string" and ration.grain:upper() or nil
    if not isGrainChoice(out.grain) then out.grain, ok = RLFeed.DEFAULT_RATION.grain, ration.grain == nil and ok or false end
    if ration.share ~= nil then
        local share = tonumber(ration.share)
        if share ~= nil and share == share and share >= 0 and share <= 1 then out.share = share else ok = false end
    end
    out.substitute = ration.substitute ~= false
    return out, ok
end


--- Set a pen's ration settings (server; a client sends RLFeedRationEvent).
function RLFeed.setRation(placeable, ration)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    if spec == nil then return false end
    local clean, ok = RLFeed.sanitizeRation(ration)
    spec.rlFeedRation = clean
    Log:info("RLFeed: %s ration target=%s grain=%s share=%s substitute=%s", placeable.getName ~= nil and placeable:getName() or "?",
        clean.target, clean.grain, clean.share ~= nil and string.format("%.2f", clean.share) or "max", tostring(clean.substitute))
    return ok
end


--- The concentrates a pen's ration offers, in the order they are taken: AUTO every grain then
--- the other concentrates (sugar beet); one grain, then with substitution the rest; NONE nothing.
--- @param ration table
--- @return table names
function RLFeed.getConcentrateOrder(ration)
    local order = {}
    local function add(name) for _, existing in ipairs(order) do if existing == name then return end end table.insert(order, name) end
    if ration.grain == "NONE" then return order end
    if ration.grain ~= "AUTO" then add(ration.grain) end
    if ration.grain == "AUTO" or ration.substitute then
        for _, grain in ipairs(RLFeed.GRAINS) do add(grain) end
        local config = RLFeed.getConfig()
        for _, name in ipairs(config.feedOrder) do
            local profile = config.feeds[name]
            if profile.valid and profile.role == "CONCENTRATE" then add(name) end
        end
    end
    return order
end


-- =============================================================================
-- Coverage
-- =============================================================================

--- Whether a pen is a calf rearing pen (its calves' milk is in its trough).
local function isRearingPen(placeable)
    return RLCalfRearing ~= nil and RLCalfRearing.appliesToPen(placeable)
end


--- A calf's milk and solid caps (RLCalfRearing), with the calf still on milk when milkMax > 0.
local function getCalfCaps(animal)
    if RLCalfRearing == nil or not RLCalfRearing.isEnabled() then return 0, 1 end
    return RLCalfRearing.getCaps(animal)
end


--- Whether a pen runs the mode, and why (not).
--- @param placeable table
--- @return boolean active
--- @return string reason "OK", "MODE_OFF", "CONFIG_INVALID", "MODEL_OFF", "NOT_CATTLE", "NO_TROUGH",
---         "UNCOVERED_ANIMAL", "SUCKLING_CALF"
function RLFeed.evaluatePen(placeable)
    local ok, reason = RLFeed.canRun()
    if not ok then return false, reason end
    if placeable == nil or placeable.getAnimalTypeIndex == nil or AnimalType == nil
        or placeable:getAnimalTypeIndex() ~= AnimalType.COW then return false, "NOT_CATTLE" end
    if placeable.spec_husbandryFood == nil then return false, "NO_TROUGH" end
    local rearing = isRearingPen(placeable)
    for _, animal in ipairs(placeable:getClusters() or {}) do
        if not animal.isDead and (animal.numAnimals or 1) > 0 then
            if not RLGrowth.covers(animal) then return false, "UNCOVERED_ANIMAL" end
            if not rearing then
                local milkMax = getCalfCaps(animal)
                if milkMax > 0 then return false, "SUCKLING_CALF" end
            end
        end
    end
    return true, "OK"
end


--- A pen's state as of its last feeding this hour (or the current evaluation when it has not
--- fed this hour): { tick, active, reason }.
function RLFeed.getPenState(placeable, tick)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    local state = spec ~= nil and spec.rlFeedPen or nil
    if state ~= nil and (tick == nil or state.tick == tick) then return state end
    local active, reason = RLFeed.evaluatePen(placeable)
    return { tick = tick, active = active, reason = reason, evaluated = true }
end


local function getOwner(animal)
    return animal ~= nil and animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil
end


--- The ration class of an animal: CALF (on milk), LACTATING, DRY (a cow that has calved), GROWING.
function RLFeed.getRationClass(animal)
    local milkMax = getCalfCaps(animal)
    if milkMax > 0 then return "CALF" end
    if animal.isLactating then return "LACTATING" end
    if animal.gender == "female" and animal.isParent then return "DRY" end
    return "GROWING"
end


--- What an animal eats for: FINISH (freely), GROW (its growth, milk and a reserve back to the
--- reference) or MAINTAIN (maintenance and pregnancy). AUTO: bulls and steers FINISH, females
--- GROW; a calf on milk always eats freely.
function RLFeed.getAnimalTarget(animal, ration, class)
    if class == "CALF" then return "FINISH" end
    local target = ration.target or "AUTO"
    if target == "AUTO" then return animal.gender == "male" and "FINISH" or "GROW" end
    return target
end


-- =============================================================================
-- Animal descriptors
-- =============================================================================

--- Real milk (kg a day) a cow gives at full feed now, and the ME a game liter of her milk needs.
--- The game's milk curve at a mature age x the lactation mean stands for the breed's real
--- lactation average (RLFeedProfiles.getMilkBridge).
--- @param animal table
--- @param potentialPerPeriod number Game liters per month at full feed
--- @return number realKgPerDay
--- @return number mePerGameLiter
function RLFeed.getMilkBridge(animal, potentialPerPeriod)
    local binding = RLGrowth.getBinding(animal:getSubType())
    local realKg, mePerKg = RLFeedProfiles.getMilkBridge(binding ~= nil and binding.profile or nil)
    local subType = animal:getSubType()
    local milkCurve = subType ~= nil and subType.output ~= nil and subType.output.milk or nil
    local mature = milkCurve ~= nil and milkCurve.get ~= nil and milkCurve:get(60) or 0
    local mean = mature * RLBodyCondition.getConfig().lactationMeanFactor
    if mean <= 0 then return 0, 0 end
    local realPerGameLiter = realKg * RLFeed.getConfig().realDaysPerPeriod / mean
    return math.max(potentialPerPeriod or 0, 0) * realPerGameLiter / RLFeed.getConfig().realDaysPerPeriod,
        realPerGameLiter * mePerKg
end


--- The weight model's step input for an animal before it eats, in ME units: its frame, reserve,
--- development, genes, pregnancy and milk at full feed, with the growth cost of its weight and the
--- ME of its milk.
--- @return table input
--- @return table cfg Energy config
local function buildEnergyInput(animal, dtMonths)
    local state = RLGrowth.peekState(animal)
    local input = RLGrowth.buildStepInput(animal, state, 0, 1, dtMonths)
    local config = RLFeed.getConfig()
    input.growthCostPerKg = RLFeedMath.getGrowthCost(animal.weight or 0, config.requirements)
    local _, mePerLiter = RLFeed.getMilkBridge(animal, input.potentialMilk)
    input.milkCostPerLiter = mePerLiter
    return input, RLFeed.getEnergyConfig()
end


--- One animal as the planner sees it.
--- @param animal table
--- @param ration table Pen ration settings
--- @param dtMonths number
--- @param dtDays number
--- @return table descriptor
function RLFeed.describeAnimal(animal, ration, dtMonths, dtDays)
    local config = RLFeed.getConfig()
    local class = RLFeed.getRationClass(animal)
    local target = RLFeed.getAnimalTarget(animal, ration, class)
    local input, cfg = buildEnergyInput(animal, dtMonths)
    local _, _, gene = RLGrowth.getGeneFactors(animal.genetics.metabolism)
    local milkKg = 0
    if class == "LACTATING" then milkKg = RLFeed.getMilkBridge(animal, input.potentialMilk) end
    local milkMax, solidMax = getCalfCaps(animal)
    local weaningX = RLCalfRearing ~= nil and RLCalfRearing.getWeaningX(animal) or 1
    local state = RLGrowth.peekState(animal)

    local a = {
        animal = animal, class = class, target = target,
        appetite = RLFeedMath.getAppetite(animal.weight or 0, class, config.intake,
            { milkKgPerDay = milkKg, weaningX = weaningX, gene = gene }),
        fill = RLFeedMath.getFillCapacity(animal.weight or 0, class, config.intake, gene),
        concEligible = class ~= "CALF",
        adapted = state.feedAdapted or 0,
        milkMax = class == "CALF" and milkMax or 0,
        solidMax = solidMax,
        solidEnergy = class == "CALF" and RLCalfRearing.getSolidEnergyFactor(animal) or 1,
        proteinNeed = RLFeedMath.getProteinNeed(class, RLGrowth.getContinuousAge(animal), config.protein, milkMax),
    }

    -- What it needs a day: maintenance, pregnancy and milk at full feed, its growth this hour, and
    -- the reserve it may lay down (FINISH up to its ceiling, GROW back to the reference reserve).
    local body = RLBodyCondition.getConfig()
    if target == "GROW" then
        input.reserveCeiling = math.min(RLBodyCondition.getReserveCeiling(animal) or body.referenceReserve, body.referenceReserve)
    end
    local demands = RLGrowthMath.getStepDemands(input, cfg)
    local days = config.realDaysPerPeriod
    a.needs = {
        maintenance = demands.maintenance / days,
        pregnancy = demands.pregnancy / days,
        milk = target == "MAINTAIN" and 0 or demands.milk / days,
        growth = target == "MAINTAIN" and 0 or demands.growthStep / dtDays,
        deposit = target == "MAINTAIN" and 0 or demands.depositRoomKg * cfg.depositNUPerKg / dtDays,
    }
    return a
end


-- =============================================================================
-- Feeding
-- =============================================================================

local function fillTypeName(index)
    return index ~= nil and g_fillTypeManager:getFillTypeNameByIndex(index) or nil
end

local function fillTypeIndex(name)
    return name ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
end


--- The pen's stock as the planner takes it: forage (complete rations and forages in the order the
--- map's cattle food groups list them), concentrate (the ration's order) and milk.
--- @return table forage, table concentrate, table milk, table unconfigured names with stock
function RLFeed.getStockLists(placeable, ration)
    local spec = placeable.spec_husbandryFood
    local foodSystem = g_currentMission.animalFoodSystem
    local animalFood = foodSystem ~= nil and foodSystem:getAnimalFood(spec.animalTypeIndex) or nil
    local forage, milk, seen, unconfigured = {}, {}, {}, {}
    local function available(index)
        return math.max(placeable:getAvailableFood(index) or 0, 0)
    end
    for _, group in ipairs(animalFood ~= nil and animalFood.groups or {}) do
        for _, index in ipairs(group.fillTypes or {}) do
            local name = fillTypeName(index)
            if name ~= nil and not seen[name] then
                seen[name] = true
                local liters = available(index)
                local profile = RLFeedProfiles.getUsableFeed(name)
                if profile == nil then
                    if liters > 0 then table.insert(unconfigured, name) end
                elseif profile.role == "COMPLETE" or profile.role == "FORAGE" then
                    table.insert(forage, { name = name, profile = profile, liters = liters, index = index })
                elseif profile.role == "MILK" then
                    table.insert(milk, { name = name, profile = profile, liters = liters, index = index })
                end
            end
        end
    end
    local concentrate = {}
    for _, name in ipairs(RLFeed.getConcentrateOrder(ration)) do
        local index = fillTypeIndex(name)
        local profile = RLFeedProfiles.getUsableFeed(name)
        if index ~= nil and profile ~= nil and profile.role == "CONCENTRATE" and spec.supportedFillTypes[index] then
            table.insert(concentrate, { name = name, profile = profile, liters = available(index), index = index })
        end
    end
    return forage, concentrate, milk, unconfigured
end


--- Start a pen's feeding (server): decide whether it runs the mode this hour.
--- @param placeable table
--- @return boolean active
function RLFeed.beginFeeding(placeable)
    local spec = placeable.spec_husbandryFood
    if spec == nil then return false end
    local tick = RLBodyCondition.getTickId()
    local active, reason = RLFeed.evaluatePen(placeable)
    spec.rlFeedPen = { tick = tick, active = active, reason = reason }
    spec.rlFeedWindow = active and { tick = tick } or nil
    return active
end


--- The pen's feeding in the mode (from AnimalFoodSystem:consumeFood): plan, and hand the engine
--- the liters to remove per fill type.
--- @param placeable table
--- @param consumedFood table fillTypeIndex -> liters (filled here)
--- @return number factor Share of the planned ME the pen gets (its food factor)
function RLFeed.consume(placeable, consumedFood)
    local spec = placeable.spec_husbandryFood
    local window = spec.rlFeedWindow
    local config = RLFeed.getConfig()
    local ration = RLFeed.getRation(placeable)
    local environment = g_currentMission.environment
    local dtMonths = RLWeightMath.getHourMonths(environment.daysPerPeriod)
    local dtDays = RLFeed.getHourDays()

    local animals = {}
    for _, animal in ipairs(placeable:getClusters() or {}) do
        if not animal.isDead and (animal.numAnimals or 1) > 0 then
            table.insert(animals, RLFeed.describeAnimal(animal, ration, dtMonths, dtDays))
        end
    end
    local forage, concentrate, milk, unconfigured = RLFeed.getStockLists(placeable, ration)
    local plan = RLFeedRationPlanner.plan({
        animals = animals, forage = forage, concentrate = concentrate, milk = milk,
        scale = config.resourceScale, realDaysPerPeriod = config.realDaysPerPeriod, dtDays = dtDays,
        share = ration.share, ration = config.ration, classes = config.classes,
        proteinMaintenance = config.protein.maintenance, concentrateWanted = ration.grain ~= "NONE" and ration.share ~= 0,
    })
    plan.unconfigured = unconfigured
    plan.indices = {}
    for _, list in ipairs({ forage, concentrate, milk }) do
        for _, entry in ipairs(list) do plan.indices[entry.name] = entry.index end
    end
    for name, liters in pairs(plan.withdraw) do
        local index = plan.indices[name]
        if index ~= nil and liters > 0 then consumedFood[index] = (consumedFood[index] or 0) + liters end
    end
    window.plan, window.dtDays, window.dtMonths = plan, dtDays, dtMonths
    if plan.plannedMe <= 0 then return #animals > 0 and 0 or 1 end
    return math.clamp(plan.eatenMe / plan.plannedMe, 0, 1)
end


--- Close a pen's feeding (server, after the trough lost what it lost): each animal's record,
--- scaled per fill type to what was really removed, and the pen's hour and month.
--- @param placeable table
function RLFeed.endFeeding(placeable)
    local spec = placeable.spec_husbandryFood
    local window = spec ~= nil and spec.rlFeedWindow or nil
    if window == nil then return end
    spec.rlFeedWindow = nil
    local plan = window.plan
    if plan == nil then return end

    -- What the trough (and meadow) really lost, per fill type (RLBodyCondition's ledger, closed
    -- just before this).
    local supply = spec.rlNutritionSupply
    local removed = (supply ~= nil and supply.tick == window.tick) and supply.consumed or {}
    local ratio = {}
    for name, liters in pairs(plan.withdraw) do
        local index = plan.indices[name]
        local lost = index ~= nil and removed[index] or nil
        if lost ~= nil and liters > 0 then ratio[name] = math.clamp(lost / liters, 0, 1) end
    end

    local tick = window.tick
    local water = spec.rlWaterCoverage
    local pen = { tick = tick, byFill = {}, plannedMe = plan.plannedMe, plannedKg = plan.plannedKg, eatenMe = 0, eatenKg = 0,
        limits = {}, unconfigured = plan.unconfigured, animals = 0 }
    local protein = RLFeed.getConfig().protein
    for _, a in ipairs(plan.animals) do
        for name, fill in pairs(a.byFill) do
            local r = ratio[name] or 1
            if r < 1 then fill.kg, fill.liters, fill.me, fill.cpKg = fill.kg * r, fill.liters * r, fill.me * r, fill.cpKg * r end
            local total = pen.byFill[name] or { liters = 0, kg = 0, me = 0 }
            total.liters, total.kg, total.me = total.liters + fill.liters, total.kg + fill.kg, total.me + fill.me
            pen.byFill[name] = total
        end
        RLFeedRationPlanner.sumAnimal(a)
        local animal = a.animal
        animal.rlFeedIntake = {
            tick = tick, owner = placeable, kg = a.kg, me = a.me, cp = a.cp, byFill = a.byFill,
            plannedKg = a.plannedKg, plannedMe = a.plannedMe, class = a.class, target = a.target,
            concShare = a.cEaten, concLimit = a.concLimit, intakeLimit = a.intakeLimit,
            proteinFactor = RLFeedMath.getProteinFactor(a.cp, a.proteinNeed, protein.maintenance),
            proteinNeed = a.proteinNeed, dtDays = window.dtDays,
        }
        animal.rlFeedPlanLiters = a.litersPerPeriod
        pen.eatenMe, pen.eatenKg, pen.animals = pen.eatenMe + a.me, pen.eatenKg + a.kg, pen.animals + 1
        local limit = a.concLimit or a.intakeLimit
        if limit ~= nil then pen.limits[limit] = (pen.limits[limit] or 0) + 1 end
    end
    pen.water = (water ~= nil and water.tick == tick) and water.coverage or 1
    pen.coverage = pen.plannedMe > 0 and pen.eatenMe / pen.plannedMe or (pen.animals > 0 and 0 or 1)
    -- The old ledger's energy row reads the share of the planned ME eaten in this mode.
    if supply ~= nil and supply.tick == tick then supply.energyShare = { ME = math.clamp(pen.coverage, 0, 1) } end
    spec.rlFeedLast = pen
    RLFeed.addToMonth(placeable, pen)
end


-- =============================================================================
-- Pen month
-- =============================================================================

local function getPeriodKey()
    local environment = g_currentMission.environment
    return (environment.currentYear or 0) * 100 + (environment.currentPeriod or 0)
end


--- Add an hour to the pen's month; a new month moves the last one to `previous` (complete when it
--- held every hour of its month).
function RLFeed.addToMonth(placeable, hour)
    local spec = placeable.spec_husbandryFood
    local key = getPeriodKey()
    local month = spec.rlFeedMonth
    local config = RLFeed.getConfig()
    if month == nil or month.key ~= key then
        if month ~= nil then
            month.complete = month.hours >= month.hoursInMonth
            spec.rlFeedPrevious = month
        end
        local environment = g_currentMission.environment
        local hoursInMonth = 24 * math.max(environment.daysPerPeriod or 1, 1)
        local elapsed = ((environment.currentDayInPeriod or 1) - 1) * 24 + (environment.currentHour or 0)
        month = { key = key, hours = 0, hoursInMonth = hoursInMonth, startedAtStart = elapsed <= 1, byFill = {},
            hash = config.hash, version = config.version, scale = config.resourceScale, plannedMe = 0, eatenMe = 0 }
        spec.rlFeedMonth = month
    end
    month.hours = month.hours + 1
    month.plannedMe, month.eatenMe = month.plannedMe + hour.plannedMe, month.eatenMe + hour.eatenMe
    for name, fill in pairs(hour.byFill) do
        local total = month.byFill[name] or { liters = 0, kg = 0, me = 0 }
        total.liters, total.kg, total.me = total.liters + fill.liters, total.kg + fill.kg, total.me + fill.me
        month.byFill[name] = total
    end
end


-- =============================================================================
-- Step and health
-- =============================================================================

--- What the animal ate this hour, when its pen runs the mode this hour: its record, or a record
--- of nothing (it was not in the pen when the pen fed). nil: the old rules for this hour.
--- @param animal table
--- @param tick number|nil Defaults to this hour
--- @return table|nil
function RLFeed.getStepFeed(animal, tick)
    tick = tick or RLBodyCondition.getTickId()
    local owner = getOwner(animal)
    local spec = owner ~= nil and owner.spec_husbandryFood or nil
    local pen = spec ~= nil and spec.rlFeedPen or nil
    if tick == nil or pen == nil or pen.tick ~= tick or not pen.active then return nil end
    if not RLGrowth.covers(animal) then return nil end
    local record = animal.rlFeedIntake
    if record ~= nil and record.tick == tick and record.owner == owner then return record end
    local class = RLFeed.getRationClass(animal)
    record = { tick = tick, owner = owner, kg = 0, me = 0, cp = 0, byFill = {}, plannedKg = 0, plannedMe = 0, class = class,
        target = RLFeed.getAnimalTarget(animal, RLFeed.getRation(owner), class), concShare = 0, proteinFactor = 0, missed = true }
    animal.rlFeedIntake = record
    return record
end


--- Whether the animal's hour runs in the mode.
function RLFeed.runsFor(animal, tick)
    return RLFeed.getStepFeed(animal, tick) ~= nil
end


--- The step input in ME units (RLGrowth.step): the ME eaten as the supply, the growth cost of its
--- weight, the ME of its milk, protein limiting growth and milk, no reserve for milk under
--- MAINTAIN.
--- @param animal table
--- @param input table RLGrowth.buildStepInput's
--- @param feed table getStepFeed's
--- @param dtMonths number
--- @return table input
--- @return table cfg
function RLFeed.applyStepInput(animal, input, feed, dtMonths)
    local config = RLFeed.getConfig()
    input.supplyPerPeriod = dtMonths > 0 and feed.me / dtMonths or 0
    input.growthCostPerKg = RLFeedMath.getGrowthCost(animal.weight or 0, config.requirements)
    local _, mePerLiter = RLFeed.getMilkBridge(animal, input.potentialMilk)
    input.milkCostPerLiter = mePerLiter
    local protein = feed.proteinFactor or 0
    input.speed = (input.speed or 1) * protein
    input.potentialMilk = (input.potentialMilk or 0) * protein
    if feed.target == "MAINTAIN" then input.milkMobilizeShare = 0 end
    return input, RLFeed.getEnergyConfig()
end


--- After the step: the rumen's adaptation moves toward the concentrate share it ate (for the
--- model days the hour covers), and the step is kept for the health check.
function RLFeed.afterStep(animal, state, feed, result)
    local config = RLFeed.getConfig()
    if not feed.missed then
        state.feedAdapted = RLFeedMath.adapt(state.feedAdapted or 0, feed.concShare or 0, feed.dtDays or RLFeed.getHourDays(),
            config.ration)
    end
    feed.result = result
end


--- Health from the hour's budget (after the step), at per-month rates: the old per-hour rates
--- hold for a one-day month, and a longer month spreads them over its hours. Fractions carry
--- over, so a slow change is not lost to whole-point health.
--- @param animal table
--- @param dtMonths number
function RLFeed.applyHealth(animal, dtMonths)
    local feed = animal.rlFeedIntake
    local result = feed ~= nil and feed.tick == RLBodyCondition.getTickId() and feed.result or nil
    if result == nil then return end
    local body = RLBodyCondition.getConfig()
    local factor, reason = RLFeedMath.getHealthFactor({
        supply = result.supplyNU, maintenance = result.maintenanceNU, pregnancy = result.pregnancyNU,
        catabolism = result.catabolismNU, unpaid = (result.maintenanceDeficitNU or 0) + (result.pregnancyDeficitNU or 0),
        mobilized = result.mobilizedNU, reserve = result.reserve, lowReserve = body.minReserve + body.mobilizeEaseRange,
        water = feed.water, cp = feed.cp, cpMaintenance = RLFeed.getConfig().protein.maintenance, eatenDm = feed.kg,
    })
    feed.healthFactor, feed.healthReason = factor, reason
    local subType = animal:getSubType()
    local rate = factor >= 0 and (subType.healthIncreaseHour or 0) or (subType.healthDecreaseHour or 0)
    local hours = 24 * dtMonths
    RLFeed.addHealth(animal, rate * factor * (animal.genetics.health or 1) * hours)
end


--- Add a (fractional) health change; whole points reach animal.health, the rest carries.
function RLFeed.addHealth(animal, delta)
    if delta == 0 or delta ~= delta then return end
    local carry = (animal.rlHealthCarry or 0) + delta
    local whole = carry >= 0 and math.floor(carry) or -math.floor(-carry)
    animal.rlHealthCarry = carry - whole
    if whole ~= 0 then animal.health = math.clamp((animal.health or 0) + whole, 0, 100) end
end


--- The weight-only health check of the mode: below extremeUnderweightRatio of its curve (the
--- weight model's underweight threshold scaled to it), at the old penalty's per-month rate.
function RLFeed.applyUnderweight(animal, dtMonths)
    local ratio = RLFeed.getConfig().health.extremeUnderweightRatio
    local threshold = RLGrowth.getUnderweightThreshold(animal) * ratio / RLGrowth.getSettings().underweightRatio
    if threshold <= 0 or animal.weight >= threshold then return end
    RLFeed.addHealth(animal, -((threshold - animal.weight) / threshold) * 0.2 * 24 * dtMonths)
end


--- The liters a month an animal asks for in the mode (Animal:updateInput), from its last plan;
--- nil when its pen does not run the mode.
function RLFeed.getRequestLitersPerPeriod(animal)
    local owner = getOwner(animal)
    local spec = owner ~= nil and owner.spec_husbandryFood or nil
    local pen = spec ~= nil and spec.rlFeedPen or nil
    if pen == nil or not pen.active or animal.rlFeedPlanLiters == nil then return nil end
    local record = animal.rlFeedIntake
    if record == nil or record.owner ~= owner then return nil end
    return animal.rlFeedPlanLiters
end


-- =============================================================================
-- Grain in cattle troughs
-- =============================================================================

--- Add the cattle grain group (RLFeed.GRAINS the map has and no cattle group lists yet) to the
--- COW animal food. Idempotent; other species and the map's groups are untouched. The group is
--- skipped by the old rules' consumption (productionWeight 0, never eaten there).
--- @param foodSystem table AnimalFoodSystem
function RLFeed.registerCattleGrains(foodSystem)
    local mission = foodSystem ~= nil and foodSystem.mission or g_currentMission
    local animalSystem = mission ~= nil and mission.animalSystem or nil
    local typeIndex = animalSystem ~= nil and animalSystem:getTypeIndexByName("COW") or nil
    local animalFood = typeIndex ~= nil and foodSystem:getAnimalFood(typeIndex) or nil
    if animalFood == nil then return end
    local used = {}
    for _, group in ipairs(animalFood.groups) do
        if group.rlGrain then return end
        for _, index in ipairs(group.fillTypes or {}) do used[index] = true end
    end
    local fillTypes = {}
    for _, name in ipairs(RLFeed.GRAINS) do
        local index = fillTypeIndex(name)
        if index ~= nil and not used[index] then table.insert(fillTypes, index) end
    end
    if #fillTypes == 0 then return end
    table.insert(animalFood.groups, { title = g_i18n:getText("rl_feed_grainGroup"), productionWeight = 0, eatWeight = 0,
        fillTypes = fillTypes, rlGrain = true })
    Log:info("RLFeed: cattle troughs take %d grain fill type(s) (eaten under the real-equivalent nutrition model only)", #fillTypes)
end


if AnimalFoodSystem ~= nil then
    if AnimalFoodSystem.loadMapData ~= nil then
        AnimalFoodSystem.loadMapData = Utils.appendedFunction(AnimalFoodSystem.loadMapData, function(self)
            RLFeed.registerCattleGrains(self)
        end)
    end

    -- The pen's feeding in the mode; elsewhere the engine's own.
    local consumeFood = AnimalFoodSystem.consumeFood
    AnimalFoodSystem.consumeFood = function(self, animalTypeIndex, amount, foodOwner, consumedFood)
        local foodSpec = type(foodOwner) == "table" and foodOwner.spec_husbandryFood or nil
        local window = foodSpec ~= nil and foodSpec.rlFeedWindow or nil
        if window ~= nil and window.plan == nil then return RLFeed.consume(foodOwner, consumedFood) end
        return consumeFood(self, animalTypeIndex, amount, foodOwner, consumedFood)
    end

    -- The grain group is never eaten by the old rules.
    local consumeFoodGroup = AnimalFoodSystem.consumeFoodGroup
    AnimalFoodSystem.consumeFoodGroup = function(self, foodGroup, amount, foodOwner, consumedFood)
        if foodGroup ~= nil and foodGroup.rlGrain then return amount end
        return consumeFoodGroup(self, foodGroup, amount, foodOwner, consumedFood)
    end
end


-- =============================================================================
-- Persistence
-- =============================================================================

--- Write a pen's ration settings and its months under `key` (the food spec's savegame key).
function RLFeed.savePen(placeable, xmlFile, key)
    local spec = placeable.spec_husbandryFood
    if spec == nil then return end
    local base = key .. ".rlFeed"
    local ration = spec.rlFeedRation
    if ration ~= nil then
        xmlFile:setString(base .. "#target", ration.target)
        xmlFile:setString(base .. "#grain", ration.grain)
        if ration.share ~= nil then xmlFile:setFloat(base .. "#share", ration.share) end
        xmlFile:setBool(base .. "#substitute", ration.substitute ~= false)
    end
    local function saveMonth(month, path)
        if month == nil then return end
        xmlFile:setInt(path .. "#key", month.key)
        xmlFile:setInt(path .. "#hours", month.hours)
        xmlFile:setInt(path .. "#hoursInMonth", month.hoursInMonth)
        xmlFile:setBool(path .. "#startedAtStart", month.startedAtStart == true)
        if month.complete ~= nil then xmlFile:setBool(path .. "#complete", month.complete) end
        xmlFile:setString(path .. "#hash", month.hash or "")
        xmlFile:setInt(path .. "#version", month.version or 0)
        xmlFile:setFloat(path .. "#scale", month.scale or 0)
        xmlFile:setFloat(path .. "#plannedMe", month.plannedMe or 0)
        xmlFile:setFloat(path .. "#eatenMe", month.eatenMe or 0)
        local names = {}
        for name in pairs(month.byFill) do names[#names + 1] = name end
        table.sort(names)
        for i, name in ipairs(names) do
            local fill = month.byFill[name]
            local fillKey = string.format("%s.fill(%d)", path, i - 1)
            xmlFile:setString(fillKey .. "#name", name)
            xmlFile:setFloat(fillKey .. "#liters", fill.liters)
            xmlFile:setFloat(fillKey .. "#kg", fill.kg)
            xmlFile:setFloat(fillKey .. "#me", fill.me)
        end
    end
    saveMonth(spec.rlFeedMonth, base .. ".month")
    saveMonth(spec.rlFeedPrevious, base .. ".previous")
end


--- Read a pen's ration settings and months. A month keeps the scale and config it was counted
--- under: a later change of either does not recount it.
function RLFeed.loadPen(placeable, xmlFile, key)
    local spec = placeable.spec_husbandryFood
    if spec == nil then return end
    local base = key .. ".rlFeed"
    local target = xmlFile:getString(base .. "#target")
    if target ~= nil then
        local ration, ok = RLFeed.sanitizeRation({ target = target, grain = xmlFile:getString(base .. "#grain"),
            share = xmlFile:getFloat(base .. "#share"), substitute = xmlFile:getBool(base .. "#substitute", true) })
        if not ok then Log:warning("RLFeed: %s has ration settings out of range; defaults used where they were", base) end
        spec.rlFeedRation = ration
    end
    local function loadMonth(path)
        local monthKey = xmlFile:getInt(path .. "#key")
        if monthKey == nil then return nil end
        local month = { key = monthKey, hours = xmlFile:getInt(path .. "#hours", 0),
            hoursInMonth = xmlFile:getInt(path .. "#hoursInMonth", 24), startedAtStart = xmlFile:getBool(path .. "#startedAtStart", false),
            complete = xmlFile:getBool(path .. "#complete"), hash = xmlFile:getString(path .. "#hash", ""),
            version = xmlFile:getInt(path .. "#version", 0), scale = xmlFile:getFloat(path .. "#scale", 0),
            plannedMe = xmlFile:getFloat(path .. "#plannedMe", 0), eatenMe = xmlFile:getFloat(path .. "#eatenMe", 0), byFill = {} }
        xmlFile:iterate(path .. ".fill", function(_, fillKey)
            local name = xmlFile:getString(fillKey .. "#name")
            if name ~= nil then
                month.byFill[name] = { liters = xmlFile:getFloat(fillKey .. "#liters", 0), kg = xmlFile:getFloat(fillKey .. "#kg", 0),
                    me = xmlFile:getFloat(fillKey .. "#me", 0) }
            end
        end)
        return month
    end
    spec.rlFeedMonth = loadMonth(base .. ".month")
    spec.rlFeedPrevious = loadMonth(base .. ".previous")
    -- A month counted under other feed data is history: the next hour starts a new one.
    if spec.rlFeedMonth ~= nil and spec.rlFeedMonth.hash ~= RLFeed.getConfig().hash then
        Log:info("RLFeed: %s month was counted under feed data %s (now %s); kept as it was", base,
            tostring(spec.rlFeedMonth.hash), RLFeed.getConfig().hash)
    end
end


--- Write the feed data the savegame ran on (in rm_RlSettings.xml, beside the mode setting).
function RLFeed.saveSummary(xmlFile, key)
    local config = RLFeed.getConfig()
    xmlFile:setInt(key .. "#stateVersion", RLFeed.STATE_VERSION)
    xmlFile:setInt(key .. "#feedVersion", config.version or 0)
    xmlFile:setString(key .. "#hash", config.hash or "")
    xmlFile:setFloat(key .. "#resourceScale", config.resourceScale or 0)
    xmlFile:setFloat(key .. "#realDaysPerPeriod", config.realDaysPerPeriod or 0)
end


--- Read it back and log what changed since the save (nothing is recounted: only the future uses
--- new values).
function RLFeed.loadSummary(xmlFile, key)
    local hash = xmlFile:getString(key .. "#hash")
    if hash == nil then return end
    local config = RLFeed.getConfig()
    local scale = xmlFile:getFloat(key .. "#resourceScale", 0)
    RLFeed.savedSummary = { hash = hash, scale = scale, version = xmlFile:getInt(key .. "#feedVersion", 0) }
    if hash ~= config.hash then
        Log:info("RLFeed: feed data changed since this save (%s -> %s, scale %.3f -> %.3f); only the future uses the new values",
            hash, config.hash, scale, config.resourceScale)
    end
end
