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
--- Highest concentrate share target a pen may set (nil: as much as the ration rules allow).
RLFeed.MAX_SHARE = 0.8

RLFeed.DEFAULT_RATION = { target = "AUTO", grain = "AUTO", share = nil, substitute = true }

RLFeed.STATE_VERSION = 1

--- Time constant (months) of the live weight trend the finishing forecast reads.
RLFeed.GAIN_TAU_MONTHS = 0.5


-- =============================================================================
-- Observers (TestDiagnostics)
-- =============================================================================

local observers = {}

--- Register a function called with (kind, data) at each point of the mode's run, read-only:
--- PEN_HOUR (a pen's feeding starts: active, reason, config), STEP (a step's plan, what the trough
--- lost and each animal's share, budget and weight/health before and after), HOUR (the pen's hour
--- put together), MILK (what a store was paid, asked and took). An observer that fails is logged
--- and never stops the game. Nothing is built for observers while none is registered.
function RLFeed.addObserver(fn)
    if type(fn) ~= "function" then return false end
    for _, existing in ipairs(observers) do if existing == fn then return true end end
    table.insert(observers, fn)
    return true
end


function RLFeed.removeObserver(fn)
    for i, existing in ipairs(observers) do
        if existing == fn then table.remove(observers, i) return true end
    end
    return false
end


function RLFeed.hasObservers()
    return #observers > 0
end


local observerErrors = 0

function RLFeed.notify(kind, data)
    for _, fn in ipairs(observers) do
        local ok, err = pcall(fn, kind, data)
        if not ok then
            observerErrors = observerErrors + 1
            if observerErrors <= 5 then Log:warning("RLFeed: an observer failed on %s: %s (game unaffected)", tostring(kind), tostring(err)) end
        end
    end
end


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
        if share ~= nil and share == share and share >= 0 and share <= RLFeed.MAX_SHARE then out.share = share else ok = false end
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
--- With calf rearing switched off a young calf still suckles: the default weaning curves say how
--- long, so a pen holding one is never taken for a pen of weaned cattle.
local function getCalfCaps(animal, ageOffsetMonths)
    if RLCalfRearing == nil then return 0, 1 end
    if RLCalfRearing.isEnabled() then return RLCalfRearing.getCaps(animal, ageOffsetMonths) end
    local x = (animal.age or 0) + (ageOffsetMonths or 0) - RLCalfRearing.DEFAULTS.weaningMonth
    local curves = RLCalfRearing.DEFAULT_CURVES
    return RLNutritionMath.interpolate(curves.milkMax, x), RLNutritionMath.interpolate(curves.solidMax, x)
end


--- An animal's feeding stage for the feeds' stages: PRE_WEANING, WEANING or WEANED, read off its
--- milk cap's position on the weaning curve.
local function getFeedStage(animal, milkMax)
    if milkMax <= 0 then return "WEANED" end
    if RLCalfRearing ~= nil and RLCalfRearing.isEnabled() then return RLCalfRearing.getStage(animal) end
    return (animal.age or 0) < RLCalfRearing.DEFAULTS.weaningMonth and "PRE_WEANING" or "WEANING"
end


--- Whether a pen runs the mode, and why (not).
--- @param placeable table
--- @return boolean active
--- @return string reason "OK", "MODE_OFF", "CONFIG_INVALID", "MODEL_OFF", "NOT_CATTLE", "MILKCOW_LEGACY",
---         "NO_TROUGH", "UNCOVERED_ANIMAL", "SUCKLING_CALF" (getPenState also "ERROR": the plan failed)
function RLFeed.evaluatePen(placeable)
    local ok, reason = RLFeed.canRun()
    if not ok then return false, reason end
    if placeable == nil or placeable.getAnimalTypeIndex == nil or AnimalType == nil then return false, "NOT_CATTLE" end
    local typeIndex = placeable:getAnimalTypeIndex()
    if typeIndex ~= AnimalType.COW then
        -- Hof Bergmann's MILKCOW is a type of its own: it keeps the old rules (its own capability),
        -- however close its name.
        local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
        local animalType = animalSystem ~= nil and animalSystem.getTypeByIndex ~= nil and animalSystem:getTypeByIndex(typeIndex) or nil
        if animalType ~= nil and animalType.name == "MILKCOW" then return false, "MILKCOW_LEGACY" end
        return false, "NOT_CATTLE"
    end
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
    local input = RLGrowth.buildStepInput(animal, state, 0, 1, dtMonths, true)
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
    local body = RLBodyCondition.getConfig()
    local class = RLFeed.getRationClass(animal)
    local target = RLFeed.getAnimalTarget(animal, ration, class)
    local input, cfg = buildEnergyInput(animal, dtMonths)
    local _, _, gene = RLGrowth.getGeneFactors(animal.genetics.metabolism)
    local milkKg = 0
    if class == "LACTATING" then milkKg = RLFeed.getMilkBridge(animal, input.potentialMilk) end
    -- Mid-step caps avoid a larger milk allowance simply because the month has fewer ticks.
    local milkMax, solidMax = getCalfCaps(animal, 0.5 * dtMonths)
    local weaningX = RLCalfRearing ~= nil and RLCalfRearing.getWeaningX(animal) or 1
    local state = RLGrowth.peekState(animal)

    -- What it needs a day: maintenance, pregnancy and milk at full feed, its growth this hour, and
    -- the reserve it may lay down (FINISH up to its ceiling, GROW back to the reference reserve).
    if target == "GROW" then
        input.reserveCeiling = math.min(RLBodyCondition.getReserveCeiling(animal) or body.referenceReserve, body.referenceReserve)
    end
    local demands = RLGrowthMath.getStepDemands(input, cfg)
    local days = config.realDaysPerPeriod
    -- Appetite and rumen fill at the weight halfway through the hour (its weight plus half the
    -- growth it could make), so a long hour does not size a growing animal's intake late.
    local weight = math.max(animal.weight or 0, 0) + 0.5 * (demands.growthKg or 0)
    local milkLimit = 0
    if class == "CALF" then
        local binding = RLGrowth.getBinding(animal:getSubType())
        -- The reference calf is a Holstein of its sex; a weight profile file without Holstein
        -- leaves the calf at the reference allowance.
        local reference = RLGrowth.getConfig().profiles.HOLSTEIN ~= nil and { profile = "HOLSTEIN", sex = binding.sex } or binding
        milkLimit = RLFeedMath.getCalfMilkLimit(RLGrowth.getBirthMean(binding), RLGrowth.getBirthMean(reference),
            milkMax, config.calfMilk)
    end

    return {
        animal = animal, class = class, target = target, stage = getFeedStage(animal, milkMax),
        appetite = RLFeedMath.getAppetite(weight, class, config.intake, { milkKgPerDay = milkKg, weaningX = weaningX, gene = gene }),
        fill = RLFeedMath.getFillCapacity(weight, class, config.intake, gene),
        concEligible = class ~= "CALF",
        adapted = state.feedAdapted or 0,
        milkMax = class == "CALF" and milkMax or 0,
        milkMaxKgPerDay = milkLimit,
        solidMax = solidMax,
        solidEnergy = class == "CALF" and RLCalfRearing.getSolidEnergyFactor(animal) or 1,
        proteinNeed = RLFeedMath.getProteinNeed(class, RLGrowth.getContinuousAge(animal), config.protein, milkMax, milkKg),
        needs = {
            maintenance = demands.maintenance / days,
            pregnancy = demands.pregnancy / days,
            milk = target == "MAINTAIN" and 0 or demands.milk / days,
            growth = target == "MAINTAIN" and 0 or demands.growthStep / dtDays,
            -- Reserve it may lay down a day: what is left under its ceiling spread over a month, at
            -- most the monthly gain rate - a rate, so the hour's length does not change it.
            deposit = target == "MAINTAIN" and 0
                or math.min(demands.depositHeadroomKg, demands.depositRatePerMonthKg) * cfg.depositNUPerKg / days,
        },
    }
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


local planErrors = {}

--- A plan that failed (an error in the planner or an animal's description): the pen's hour falls
--- back to the old rules, logged once per pen and message.
function RLFeed.onPlanError(placeable, message)
    local spec = placeable.spec_husbandryFood
    local window = spec.rlFeedWindow
    spec.rlFeedWindow = nil
    spec.rlFeedPen = { tick = window ~= nil and window.tick or RLBodyCondition.getTickId(), active = false, reason = "ERROR" }
    local key = tostring(placeable) .. tostring(message)
    if not planErrors[key] then
        planErrors[key] = true
        Log:error("RLFeed: ration plan failed in %s (%s); the old rules feed it this hour", placeable.getName ~= nil and placeable:getName() or "?",
            tostring(message))
    end
end


--- Whether a pen's trough takes more of a fill type: grain only while the mode is on.
function RLFeed.acceptsFill(placeable, fillTypeIndex)
    if RLFeed.mode == RLFeed.MODE_REAL then return true end
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    local grains = spec ~= nil and spec.rlGrainFillTypes or nil
    if grains == nil then
        grains = {}
        local foodSystem = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
        local animalFood = foodSystem ~= nil and spec ~= nil and foodSystem:getAnimalFood(spec.animalTypeIndex) or nil
        for _, group in ipairs(animalFood ~= nil and animalFood.groups or {}) do
            if group.rlGrain then for _, index in ipairs(group.fillTypes) do grains[index] = true end end
        end
        if spec ~= nil then spec.rlGrainFillTypes = grains end
    end
    return not grains[fillTypeIndex]
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
    if #observers > 0 then
        local config = RLFeed.getConfig()
        local environment = g_currentMission.environment
        RLFeed.notify("PEN_HOUR", { placeable = placeable, tick = tick, active = active, reason = reason, hash = config.hash,
            scale = config.resourceScale, stepDays = config.stepDays, realDaysPerPeriod = config.realDaysPerPeriod,
            daysPerPeriod = environment.daysPerPeriod, pendingDays = spec.rlFeedClock ~= nil and spec.rlFeedClock.pendingDays or 0 })
    end
    return active
end


--- Model days per step (feedProfiles.xml stepDays).
function RLFeed.getStepDays()
    return RLFeed.getConfig().stepDays
end


--- Game hours an animal's last step stays its current one: the longest gap between two of its
--- pen's steps (one step's model days in game hours), and the hour it was taken in.
function RLFeed.getRecordHours()
    local hourDays = RLFeed.getHourDays()
    if hourDays <= 0 then return 1 end
    return math.ceil(RLFeed.getStepDays() / hourDays - 1e-9) + 1
end


--- Whether a record of tick `at` is still an animal's current one at `tick`.
function RLFeed.isFresh(at, tick)
    tick = tick or RLBodyCondition.getTickId()
    return at ~= nil and tick ~= nil and tick - at <= RLFeed.getRecordHours()
end


--- The pen's feeding in the mode (from AnimalFoodSystem:consumeFood). The pen keeps a model clock:
--- each game hour adds its model days (realDaysPerPeriod / (24 x days per month)), and the pen runs
--- one step of stepDays for each whole step the clock holds - five in an hour of a one-day month,
--- one every fifth or sixth hour of a 28-day month. Each step plans, takes from the trough (the
--- liters are removed here, step by step, so the next step sees what is left), and settles every
--- animal's growth, adaptation and health. The same model time runs the same steps at any month
--- length; what is left of the clock is saved with the pen.
--- @param placeable table
--- @param consumedFood table fillTypeIndex -> liters (left empty: the steps removed their own)
--- @return number factor Share of the hour's planned ME the pen got (its food factor); the last
---         hour's in an hour without a step
function RLFeed.consume(placeable, consumedFood)
    local spec = placeable.spec_husbandryFood
    local window = spec.rlFeedWindow
    local clock = spec.rlFeedClock or { pendingDays = 0 }
    spec.rlFeedClock = clock
    -- One hour's model time once, however often the hour is fed.
    if clock.tick ~= window.tick then
        clock.tick = window.tick
        clock.pendingDays = (clock.pendingDays or 0) + RLFeed.getHourDays()
    end
    local stepDays = RLFeed.getStepDays()
    local steps = math.floor(clock.pendingDays / stepDays + 1e-9)
    clock.pendingDays = clock.pendingDays - steps * stepDays
    if clock.pendingDays < 1e-9 then clock.pendingDays = 0 end

    local hour = { steps = steps, stepDays = stepDays, animals = {}, order = {}, byFill = {}, plannedMe = 0, plannedKg = 0, eatenMe = 0,
        eatenKg = 0, limits = {}, plannedPerMonth = {}, unconfigured = {} }
    window.hour = hour
    for _ = 1, steps do RLFeed.runStep(placeable, window, stepDays) end
    if steps == 0 or hour.plannedMe <= 0 then
        if steps == 0 and spec.rlFeedFactor ~= nil then return spec.rlFeedFactor end
        return #hour.order > 0 and 0 or 1
    end
    spec.rlFeedFactor = math.clamp(hour.eatenMe / hour.plannedMe, 0, 1)
    return spec.rlFeedFactor
end


--- One model-time step of a pen: plan, remove, settle each animal.
--- @param placeable table
--- @param window table The hour's feeding
--- @param stepDays number Model days
function RLFeed.runStep(placeable, window, stepDays)
    local spec = placeable.spec_husbandryFood
    local config = RLFeed.getConfig()
    local ration = RLFeed.getRation(placeable)
    local dtMonths = stepDays / config.realDaysPerPeriod
    local tick = window.tick
    local hour = window.hour

    local animals = {}
    for _, animal in ipairs(placeable:getClusters() or {}) do
        -- Not twice in an hour: an animal stepped in another pen this hour (moved since) waits.
        local stepped = animal.rlFeedStepTick == tick and animal.rlFeedStepOwner ~= placeable
        if not animal.isDead and (animal.numAnimals or 1) > 0 and not stepped then
            table.insert(animals, RLFeed.describeAnimal(animal, ration, dtMonths, stepDays))
        end
    end
    local forage, concentrate, milk, unconfigured = RLFeed.getStockLists(placeable, ration)
    local plan = RLFeedRationPlanner.plan({
        animals = animals, forage = forage, concentrate = concentrate, milk = milk,
        scale = config.resourceScale, realDaysPerPeriod = config.realDaysPerPeriod, dtDays = stepDays,
        share = ration.share, ration = config.ration, classes = config.classes,
        proteinMaintenance = config.protein.maintenance, concentrateWanted = ration.grain ~= "NONE" and ration.share ~= 0,
    })
    hour.unconfigured = unconfigured

    -- Take it from the trough (and meadow) now; a feed the trough gave less of is shared as given.
    local indices, ratio, removedLiters = {}, {}, {}
    for _, list in ipairs({ forage, concentrate, milk }) do
        for _, entry in ipairs(list) do indices[entry.name] = entry.index end
    end
    for name, liters in pairs(plan.withdraw) do
        local index = indices[name]
        if index ~= nil and liters > 0 then
            local removed = placeable:removeFood(liters, index) or 0
            removedLiters[name] = removed
            ratio[name] = math.clamp(removed / liters, 0, 1)
        end
    end
    local observed = #observers > 0 and { placeable = placeable, tick = tick, stepDays = stepDays, scale = config.resourceScale,
        withdraw = plan.withdraw, removed = removedLiters, animals = {} } or nil

    local water = spec.rlWaterCoverage
    local waterCoverage = (water ~= nil and water.tick ~= nil and tick - water.tick <= 1) and water.coverage or 1
    local protein = config.protein
    hour.plannedPerMonth = {}
    for _, a in ipairs(plan.animals) do
        for name, fill in pairs(a.byFill) do
            local r = ratio[name] or 0
            if r < 1 then fill.kg, fill.liters, fill.me, fill.cpKg = fill.kg * r, fill.liters * r, fill.me * r, fill.cpKg * r end
        end
        RLFeedRationPlanner.sumAnimal(a)
        local animal = a.animal
        local feed = { tick = tick, owner = placeable, kg = a.kg, me = a.me, cp = a.cp, byFill = a.byFill, plannedKg = a.plannedKg,
            plannedMe = a.plannedMe, class = a.class, target = a.target, concShare = a.cEaten, concLimit = a.concLimit,
            intakeLimit = a.intakeLimit, proteinFactor = RLFeedMath.getProteinFactor(a.cp, a.proteinNeed, protein.maintenance),
            proteinNeed = a.proteinNeed, dtDays = stepDays, water = waterCoverage }
        local before = observed ~= nil and { weight = animal.weight, health = animal.health, healthCarry = animal.rlHealthCarry or 0 } or nil
        RLFeed.stepAnimal(animal, feed, dtMonths, tick, placeable, hour)
        if observed ~= nil then
            table.insert(observed.animals, { animal = animal, feed = feed, result = feed.result, weightBefore = before.weight,
                weightAfter = animal.weight, healthBefore = before.health, healthAfter = animal.health,
                healthCarryBefore = before.healthCarry, healthCarryAfter = animal.rlHealthCarry or 0 })
        end
        animal.rlFeedPlanLiters = a.litersPerPeriod
        for name, liters in pairs(a.plannedByFill or {}) do hour.plannedPerMonth[name] = (hour.plannedPerMonth[name] or 0) + liters end
        for name, fill in pairs(a.byFill) do
            local total = hour.byFill[name] or { liters = 0, kg = 0, me = 0 }
            total.liters, total.kg, total.me = total.liters + fill.liters, total.kg + fill.kg, total.me + fill.me
            hour.byFill[name] = total
        end
        hour.plannedMe, hour.plannedKg = hour.plannedMe + a.plannedMe, hour.plannedKg + a.plannedKg
        hour.eatenMe, hour.eatenKg = hour.eatenMe + a.me, hour.eatenKg + a.kg
        local limit = a.concLimit or a.intakeLimit
        if limit ~= nil then hour.limits[limit] = (hour.limits[limit] or 0) + 1 end
    end
    if observed ~= nil then RLFeed.notify("STEP", observed) end
end


--- One animal's step: its growth budget on what it ate, its rumen's adaptation, its health, the
--- milk the budget paid, all added to the hour's record of it.
function RLFeed.stepAnimal(animal, feed, dtMonths, tick, placeable, hour)
    local result, input, weightBefore = RLGrowth.stepFeed(animal, feed, dtMonths, tick)
    animal.rlFeedStepTick, animal.rlFeedStepOwner = tick, placeable
    local record = hour.animals[animal]
    if record == nil then
        record = { tick = tick, owner = placeable, kg = 0, me = 0, cpKg = 0, byFill = {}, plannedKg = 0, plannedMe = 0, dtDays = 0,
            milkLiters = 0, steps = 0 }
        hour.animals[animal] = record
        table.insert(hour.order, animal)
    end
    record.steps = record.steps + 1
    record.kg, record.me, record.cpKg = record.kg + feed.kg, record.me + feed.me, record.cpKg + feed.cp * feed.kg
    record.plannedKg, record.plannedMe, record.dtDays = record.plannedKg + feed.plannedKg, record.plannedMe + feed.plannedMe, record.dtDays + feed.dtDays
    for name, fill in pairs(feed.byFill) do
        local total = record.byFill[name] or { liters = 0, kg = 0, me = 0, cpKg = 0 }
        total.liters, total.kg, total.me, total.cpKg = total.liters + fill.liters, total.kg + fill.kg, total.me + fill.me, total.cpKg + fill.cpKg
        record.byFill[name] = total
    end
    record.class, record.target, record.concShare, record.concLimit, record.intakeLimit = feed.class, feed.target, feed.concShare,
        feed.concLimit, feed.intakeLimit
    record.proteinFactor, record.proteinNeed, record.water = feed.proteinFactor, feed.proteinNeed, feed.water
    if result == nil then return end
    RLFeed.afterStep(animal, animal.rlGrowth, feed, result, weightBefore, dtMonths)
    RLFeed.applyHealth(animal, feed, result, dtMonths)
    RLFeed.applyUnderweight(animal, dtMonths)
    -- The milk this step's budget paid (game liters), deposited by the pen's store this hour.
    record.milkLiters = record.milkLiters + math.max(input.potentialMilk or 0, 0) * dtMonths * (result.milkFraction or 0)
    record.milkPotential = (record.milkPotential or 0) + math.max(input.potentialMilk or 0, 0) * dtMonths
    record.coverage, record.growthFraction = result.coverage, result.growthFraction
    record.healthFactor, record.healthReason, record.gainPerMonth = feed.healthFactor, feed.healthReason, feed.gainPerMonth
    record.result = result
end


--- Close a pen's feeding (server): each animal's record of the hour (what it ate over the hour's
--- steps, the milk its budget paid for the store), the pen's hour and month.
--- @param placeable table
function RLFeed.endFeeding(placeable)
    local spec = placeable.spec_husbandryFood
    local window = spec ~= nil and spec.rlFeedWindow or nil
    if window == nil then return end
    spec.rlFeedWindow = nil
    local hour = window.hour
    if hour == nil then return end
    local tick = window.tick
    local timeAdjustment = g_currentMission.environment.timeAdjustment or 1

    for _, animal in ipairs(hour.order) do
        local record = hour.animals[animal]
        record.cp = record.kg > 0 and record.cpKg / record.kg or 0
        animal.rlFeedIntake = record
        -- The store deposits liters per hour x the hour's time adjustment.
        animal.rlMilkPaid = { tick = tick, litersPerHour = timeAdjustment > 0 and record.milkLiters / timeAdjustment or 0, deposited = false }
        animal.rlNutrition = { tick = tick, allocatedLiters = 0, coverage = record.coverage,
            intakeRatio = record.plannedKg > 0 and record.kg / record.plannedKg or 0,
            milkShare = (record.milkPotential or 0) > 0 and record.milkLiters / record.milkPotential or nil,
            growthFraction = record.growthFraction, intakeSource = "feed" }
    end
    if hour.steps > 0 then placeable.rlBodyConditionStepped = tick end

    local water = spec.rlWaterCoverage
    hour.tick = tick
    hour.animals, hour.order = #hour.order, nil
    hour.water = (water ~= nil and water.tick == tick) and water.coverage or 1
    hour.coverage = hour.plannedMe > 0 and hour.eatenMe / hour.plannedMe or (hour.animals > 0 and 0 or 1)
    -- The old ledger's energy row reads the share of the planned ME eaten in this mode.
    local supply = spec.rlNutritionSupply
    if supply ~= nil and supply.tick == tick and hour.steps > 0 then supply.energyShare = { ME = math.clamp(hour.coverage, 0, 1) } end
    if hour.steps > 0 then spec.rlFeedLast = hour end
    RLFeed.addToMonth(placeable, hour)
    if #observers > 0 then RLFeed.notify("HOUR", { placeable = placeable, tick = tick, hour = hour }) end
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
    -- A new game month, or feed data (scale, profiles) other than the month was counted under,
    -- starts a new month; the last one is kept as it was counted.
    if month == nil or month.key ~= key or month.hash ~= config.hash or month.scale ~= config.resourceScale then
        if month ~= nil then
            month.complete = month.key ~= key and month.hours >= month.hoursInMonth and month.startedAtStart == true
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
    local day = spec.rlFeedDay or { hours = 0, byFill = {}, plannedMe = 0, eatenMe = 0, eatenKg = 0, limits = {} }
    spec.rlFeedDay = day
    day.hours, day.plannedMe, day.eatenMe, day.eatenKg = day.hours + 1, day.plannedMe + hour.plannedMe, day.eatenMe + hour.eatenMe,
        day.eatenKg + hour.eatenKg
    for name, fill in pairs(hour.byFill) do
        local total = day.byFill[name] or { liters = 0, kg = 0, me = 0 }
        total.liters, total.kg, total.me = total.liters + fill.liters, total.kg + fill.kg, total.me + fill.me
        day.byFill[name] = total
    end
    for limit, count in pairs(hour.limits or {}) do day.limits[limit] = (day.limits[limit] or 0) + count end
    for name, fill in pairs(hour.byFill) do
        local total = month.byFill[name] or { liters = 0, kg = 0, me = 0 }
        total.liters, total.kg, total.me = total.liters + fill.liters, total.kg + fill.kg, total.me + fill.me
        month.byFill[name] = total
    end
end


local function round(value) return math.floor((value or 0) * 1000 + 0.5) / 1000 end


--- Log a pen's day in the mode (RLPEN FEED_DAY, server): its state, ration, what it ate per fill
--- type in game liters, real DM and ME, the share of the planned ME eaten and the limits that held
--- its animals, each animal's last hour. Called on the day change, after the day's last hour.
function RLFeed.onPenDayChanged(placeable)
    local spec = placeable.spec_husbandryFood
    if spec == nil then return end
    local day = spec.rlFeedDay
    spec.rlFeedDay = nil
    local pen = spec.rlFeedPen
    if day == nil or day.hours == 0 then
        if pen ~= nil and not pen.active and pen.reason ~= "MODE_OFF" and pen.reason ~= "NOT_CATTLE" and RLFeed.mode == RLFeed.MODE_REAL then
            RLPenLog.emit("FEED_DAY", { pen = RLPenLog.pen(placeable), active = false, reason = pen.reason })
        end
        return
    end
    local fills = {}
    for name, fill in pairs(day.byFill) do
        fills[name] = { liters = round(fill.liters), kgDM = round(fill.kg), meMJ = round(fill.me) }
    end
    local animals = {}
    for _, animal in ipairs(placeable:getClusters() or {}) do
        local record = animal.rlFeedIntake
        if record ~= nil and record.dtDays ~= nil and record.dtDays > 0 then
            local identity = RLPenLog.animal(animal)
            identity.class, identity.target = record.class, record.target
            identity.kgDMPerDay = round(record.kg / record.dtDays)
            identity.mePerDay = round(record.me / record.dtDays)
            identity.coverage = round(record.plannedMe > 0 and record.me / record.plannedMe or 0)
            identity.concShare = round(record.concShare)
            identity.concLimit, identity.intakeLimit = record.concLimit, record.intakeLimit
            identity.protein = round(record.proteinFactor)
            identity.health, identity.healthReason = animal.health, record.healthReason
            identity.weight = round(animal.weight)
            animals[#animals + 1] = identity
        end
    end
    table.sort(animals, function(a, b) return tostring(a.key) < tostring(b.key) end)
    local ration = RLFeed.getRation(placeable)
    local config = RLFeed.getConfig()
    RLPenLog.emit("FEED_DAY", {
        pen = RLPenLog.pen(placeable), active = true, hours = day.hours, scale = config.resourceScale, hash = config.hash,
        ration = { target = ration.target, grain = ration.grain, share = ration.share, substitute = ration.substitute },
        coverage = round(day.plannedMe > 0 and day.eatenMe / day.plannedMe or 0), kgDM = round(day.eatenKg), meMJ = round(day.eatenMe),
        fills = fills, limits = day.limits, animals = animals,
    })
end


-- =============================================================================
-- Step and health
-- =============================================================================

--- The animal's current record in the mode (its pen's last hour with steps), when its pen runs
--- the mode this hour; nil otherwise.
--- @param animal table
--- @param tick number|nil Defaults to this hour
--- @return table|nil
function RLFeed.getStepFeed(animal, tick)
    tick = tick or RLBodyCondition.getTickId()
    if not RLFeed.runsFor(animal, tick) then return nil end
    local record = animal.rlFeedIntake
    if record ~= nil and record.owner == getOwner(animal) and RLFeed.isFresh(record.tick, tick) then return record end
    return nil
end


--- Whether the animal's hour runs in the mode: its pen fed in the mode this hour.
function RLFeed.runsFor(animal, tick)
    tick = tick or RLBodyCondition.getTickId()
    local owner = getOwner(animal)
    local spec = owner ~= nil and owner.spec_husbandryFood or nil
    local pen = spec ~= nil and spec.rlFeedPen or nil
    if tick == nil or pen == nil or pen.tick ~= tick or not pen.active then return false end
    return RLGrowth.covers(animal)
end


--- The step input in ME units (RLGrowth.stepFeed): the ME eaten as the supply, the growth cost of
--- its weight, the ME of its milk, protein limiting growth and milk, no reserve for milk under
--- MAINTAIN.
--- @param animal table
--- @param input table RLGrowth.buildStepInput's
--- @param feed table The step's feed
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


--- After a step: the rumen's adaptation moves toward the concentrate share it ate (for the step's
--- model days), and its live weight trend for the finishing forecast.
function RLFeed.afterStep(animal, state, feed, result, weightBefore, dtMonths)
    local config = RLFeed.getConfig()
    state.feedAdapted = RLFeedMath.adapt(state.feedAdapted or 0, feed.concShare or 0, feed.dtDays, config.ration)
    feed.result = result
    if weightBefore ~= nil and dtMonths ~= nil and dtMonths > 0 then
        local gain = (result.weight - weightBefore) / dtMonths
        local alpha = 1 - math.exp(-dtMonths / RLFeed.GAIN_TAU_MONTHS)
        animal.rlFeedGain = animal.rlFeedGain == nil and gain or animal.rlFeedGain + alpha * (gain - animal.rlFeedGain)
        feed.gainPerMonth = animal.rlFeedGain
    end
end


--- Health from a step's budget, at per-month rates: the old per-hour rates hold for a one-day
--- month's hour (1/24 of a month), so a step of dtMonths counts 24 x dtMonths of them. Fractions
--- carry over, so a slow change is not lost to whole-point health.
--- @param animal table
--- @param feed table The step's feed
--- @param result table The step's budget
--- @param dtMonths number
function RLFeed.applyHealth(animal, feed, result, dtMonths)
    local body = RLBodyCondition.getConfig()
    local config = RLFeed.getConfig()
    local budget = { supply = result.supplyNU, maintenance = result.maintenanceNU, pregnancy = result.pregnancyNU,
        catabolism = result.catabolismNU, unpaid = (result.maintenanceDeficitNU or 0) + (result.pregnancyDeficitNU or 0),
        mobilized = result.mobilizedNU, reserve = result.reserve, lowReserve = body.minReserve + body.mobilizeEaseRange }
    local shortfall = RLFeedMath.getShortfall(budget)
    local state = animal.rlGrowth
    if state ~= nil then
        state.feedShortDays = RLFeedMath.updateShortDays(state.feedShortDays, shortfall,
            (result.supplyNU or 0) >= (result.maintenanceNU or 0) + (result.pregnancyNU or 0), feed.dtDays)
    end
    budget.shortfall, budget.shortDays, budget.bufferDays = shortfall, state ~= nil and state.feedShortDays or 0, config.health.shortageBufferDays
    budget.water, budget.cp, budget.cpMaintenance, budget.eatenDm = feed.water, feed.cp, config.protein.maintenance, feed.kg
    local factor, reason = RLFeedMath.getHealthFactor(budget)
    feed.healthFactor, feed.healthReason = factor, reason
    local subType = animal:getSubType()
    local rate = factor >= 0 and (subType.healthIncreaseHour or 0) or (subType.healthDecreaseHour or 0)
    RLFeed.addHealth(animal, rate * factor * (animal.genetics.health or 1) * 24 * dtMonths)
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
    if record == nil or record.owner ~= owner or not RLFeed.isFresh(record.tick) then return nil end
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
    table.insert(animalFood.groups, { title = g_i18n:getText("rl_feed_grainGroup"), productionWeight = 0, eatWeight = 1,
        fillTypes = fillTypes, rlGrain = true })
    Log:info("RLFeed: cattle troughs take %d grain fill type(s) (eaten under the real-equivalent nutrition model only)", #fillTypes)
end


if AnimalFoodSystem ~= nil then
    if AnimalFoodSystem.loadMapData ~= nil then
        AnimalFoodSystem.loadMapData = Utils.appendedFunction(AnimalFoodSystem.loadMapData, function(self)
            RLFeed.registerCattleGrains(self)
        end)
    end

    -- The pen's feeding in the mode; elsewhere the engine's own. A plan that fails leaves the pen
    -- on the old rules for that hour (RLFeed.onPlanError), never without a feeding.
    local consumeFood = AnimalFoodSystem.consumeFood
    AnimalFoodSystem.consumeFood = function(self, animalTypeIndex, amount, foodOwner, consumedFood)
        local foodSpec = type(foodOwner) == "table" and foodOwner.spec_husbandryFood or nil
        local window = foodSpec ~= nil and foodSpec.rlFeedWindow or nil
        if window ~= nil and window.plan == nil then
            local ok, factor = pcall(RLFeed.consume, foodOwner, consumedFood)
            if ok then return factor end
            RLFeed.onPlanError(foodOwner, factor)
            for index in pairs(consumedFood) do consumedFood[index] = nil end
        end
        return consumeFood(self, animalTypeIndex, amount, foodOwner, consumedFood)
    end

    -- Under the old rules a cattle trough takes no new grain: it would never be eaten.
    if PlaceableHusbandryFood ~= nil and PlaceableHusbandryFood.getFreeFoodCapacity ~= nil then
        local getFreeFoodCapacity = PlaceableHusbandryFood.getFreeFoodCapacity
        PlaceableHusbandryFood.getFreeFoodCapacity = function(self, fillTypeIndex, ...)
            if not RLFeed.acceptsFill(self, fillTypeIndex) then return 0 end
            return getFreeFoodCapacity(self, fillTypeIndex, ...)
        end
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
    -- The model time the pen has not stepped yet, so a reload neither repeats nor drops it.
    local clock = spec.rlFeedClock
    if clock ~= nil then
        xmlFile:setInt(base .. ".clock#version", RLFeed.STATE_VERSION)
        xmlFile:setFloat(base .. ".clock#pendingDays", clock.pendingDays or 0)
    end
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
    local pending = xmlFile:getFloat(base .. ".clock#pendingDays")
    if pending ~= nil and pending == pending and pending >= 0 then
        -- At most one step's model time: a larger value is not from this mod's clock.
        spec.rlFeedClock = { pendingDays = math.min(pending, RLFeed.getStepDays()) }
    end
    -- A month counted under other feed data is history: the next hour starts a new one
    -- (RLFeed.addToMonth), and this one is kept as it was counted.
    if spec.rlFeedMonth ~= nil and spec.rlFeedMonth.hash ~= RLFeed.getConfig().hash then
        Log:info("RLFeed: %s month was counted under feed data %s (now %s); kept as it was, the next hour starts a new one", base,
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
    if hash ~= config.hash then
        Log:info("RLFeed: feed data changed since this save (%s -> %s, scale %.3f -> %.3f); only the future uses the new values",
            hash, config.hash, scale, config.resourceScale)
    end
end


-- =============================================================================
-- Network (server -> clients: display only)
-- =============================================================================

--- A pen's mode, ration and feed month for clients (RLBodyConditionStateEvent, hourly; the
--- ration also when a client joins).
function RLFeed.writePenStream(placeable, streamId)
    local spec = placeable.spec_husbandryFood
    local pen = spec ~= nil and spec.rlFeedPen or nil
    local ration = RLFeed.getRation(placeable)
    streamWriteBool(streamId, pen ~= nil and pen.active == true)
    streamWriteString(streamId, pen ~= nil and pen.reason or "")
    local last = spec ~= nil and spec.rlFeedLast or nil
    streamWriteFloat32(streamId, last ~= nil and last.coverage or -1)
    RLFeed.writeRationStream(ration, streamId)
    local month = spec ~= nil and spec.rlFeedMonth or nil
    local names = {}
    if month ~= nil then for name in pairs(month.byFill) do names[#names + 1] = name end end
    table.sort(names)
    streamWriteUInt8(streamId, math.min(#names, 255))
    for i = 1, math.min(#names, 255) do
        local fill = month.byFill[names[i]]
        streamWriteString(streamId, names[i])
        streamWriteFloat32(streamId, fill.liters)
        streamWriteFloat32(streamId, fill.kg)
        local planned = last ~= nil and last.plannedPerMonth ~= nil and last.plannedPerMonth[names[i]] or 0
        streamWriteFloat32(streamId, planned)
    end
    streamWriteUInt16(streamId, month ~= nil and math.min(month.hours, 65535) or 0)
end


function RLFeed.readPenStream(streamId)
    local data = { active = streamReadBool(streamId), reason = streamReadString(streamId) }
    local coverage = streamReadFloat32(streamId)
    data.coverage = coverage >= 0 and coverage or nil
    data.ration = RLFeed.readRationStream(streamId)
    data.byFill, data.plannedPerMonth = {}, {}
    for _ = 1, streamReadUInt8(streamId) do
        local name = streamReadString(streamId)
        data.byFill[name] = { liters = streamReadFloat32(streamId), kg = streamReadFloat32(streamId) }
        data.plannedPerMonth[name] = streamReadFloat32(streamId)
    end
    data.hours = streamReadUInt16(streamId)
    return data
end


--- Apply a pen's summary on a client: what its info shows.
function RLFeed.applyPenStream(placeable, data)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    if spec == nil or data == nil then return end
    spec.rlFeedPen = { tick = RLBodyCondition.getTickId(), active = data.active, reason = data.reason, client = true }
    spec.rlFeedRation = RLFeed.sanitizeRation(data.ration)
    spec.rlFeedClient = data
end


function RLFeed.writeRationStream(ration, streamId)
    streamWriteString(streamId, ration.target or "AUTO")
    streamWriteString(streamId, ration.grain or "AUTO")
    streamWriteFloat32(streamId, ration.share ~= nil and ration.share or -1)
    streamWriteBool(streamId, ration.substitute ~= false)
end


--- Read a ration from a stream: the values as sent (checked by sanitizeRation) and whether they
--- were all valid.
function RLFeed.readRationStream(streamId)
    local target, grain = streamReadString(streamId), streamReadString(streamId)
    local share = streamReadFloat32(streamId)
    local raw = { target = target, grain = grain, share = share >= 0 and share or nil, substitute = streamReadBool(streamId) }
    local _, valid = RLFeed.sanitizeRation(raw)
    return raw, valid
end


--- An animal's hour in the mode, for clients (per real day): only its current record.
function RLFeed.writeAnimalStream(animal, streamId, tick)
    local record = animal.rlFeedIntake
    local has = record ~= nil and record.dtDays ~= nil and record.dtDays > 0 and not record.missed
        and (tick == nil or RLFeed.isFresh(record.tick, tick))
    streamWriteBool(streamId, has)
    if not has then return end
    local days = record.dtDays
    streamWriteFloat32(streamId, record.kg / days)
    streamWriteFloat32(streamId, record.me / days)
    streamWriteFloat32(streamId, (record.plannedKg or 0) / days)
    streamWriteFloat32(streamId, (record.plannedMe or 0) / days)
    streamWriteFloat32(streamId, record.concShare or 0)
    streamWriteFloat32(streamId, record.proteinFactor or 0)
    streamWriteString(streamId, record.class or "")
    streamWriteString(streamId, record.target or "")
    streamWriteString(streamId, record.concLimit or "")
    streamWriteString(streamId, record.intakeLimit or "")
    streamWriteString(streamId, record.healthReason or "")
    streamWriteFloat32(streamId, record.gainPerMonth or 0)
end


function RLFeed.readAnimalStream(streamId)
    if not streamReadBool(streamId) then return nil end
    local function text(value) return value ~= "" and value or nil end
    return {
        kgPerDay = streamReadFloat32(streamId), mePerDay = streamReadFloat32(streamId),
        plannedKgPerDay = streamReadFloat32(streamId), plannedMePerDay = streamReadFloat32(streamId),
        concShare = streamReadFloat32(streamId), proteinFactor = streamReadFloat32(streamId),
        class = text(streamReadString(streamId)), target = text(streamReadString(streamId)),
        concLimit = text(streamReadString(streamId)), intakeLimit = text(streamReadString(streamId)),
        healthReason = text(streamReadString(streamId)), gainPerMonth = streamReadFloat32(streamId), client = true,
        tick = RLBodyCondition.getTickId(),
    }
end


if PlaceableHusbandryFood ~= nil then
    -- A joining client gets each pen's ration settings with the trough.
    if PlaceableHusbandryFood.onWriteStream ~= nil then
        PlaceableHusbandryFood.onWriteStream = Utils.appendedFunction(PlaceableHusbandryFood.onWriteStream, function(self, streamId)
            RLFeed.writeRationStream(RLFeed.getRation(self), streamId)
        end)
    end
    if PlaceableHusbandryFood.onReadStream ~= nil then
        PlaceableHusbandryFood.onReadStream = Utils.appendedFunction(PlaceableHusbandryFood.onReadStream, function(self, streamId)
            local spec = self.spec_husbandryFood
            local ration = RLFeed.readRationStream(streamId)
            if spec ~= nil then spec.rlFeedRation = RLFeed.sanitizeRation(ration) end
        end)
    end
end
