--[[
    RLCalfRearing.lua
    Milk and solid feed for hand-reared calves (xml/calfRearing.xml), in pens whose husbandry
    profile has rearing="true".

    Per hour, server only:
    1. beginFeeding: each animal's food request and its caps (milkMax / solidMax x request, by age
       relative to weaning) are summed into the pen's milk and solid limits.
    2. The engine's own consumeFood runs; AnimalFoodSystem.consumeFoodGroup takes at most the
       remaining limit of each kind, so the trough is drawn down by what the calves can eat.
    3. settle: what the pen actually lost (RLBodyCondition's feed ledger) is shared out, milk by
       the animals' milk caps and solid feed by their solid caps. Each animal's food factor is its
       share x the fill type's productionWeight over its request; AnimalHealth.updateHealth uses it
       in place of the pen's factor, and the body condition budget uses the animal's own share.

    Nothing here changes an animal's identity, weight, reserve or disease state directly, or moves
    an animal. Outside rearing pens nothing changes.
]]

RLCalfRearing = {}

local Log = RmLogging.getLogger("RLRM")

RLCalfRearing.CONFIG_FILE = "calfRearing.xml"

RLCalfRearing.STAGE_PRE_WEANING = "PRE_WEANING"
RLCalfRearing.STAGE_WEANING = "WEANING"
RLCalfRearing.STAGE_WEANED = "WEANED"

RLCalfRearing.DEFAULTS = { weaningMonth = 3 }
RLCalfRearing.DEFAULT_MILK = { "CALFMILK" }
RLCalfRearing.DEFAULT_CURVES = {
    milkMax = { { -3, 1.0 }, { -2, 0.9 }, { -1, 0.7 }, { 0, 0.35 }, { 1, 0 } },
    solidMax = { { -3, 0.1 }, { -2, 0.3 }, { -1, 0.6 }, { 0, 0.9 }, { 1, 1 } },
    solidEnergy = { { -3, 0.4 }, { -2, 0.55 }, { -1, 0.75 }, { 0, 0.9 }, { 1, 1 } },
}
RLCalfRearing.LAYERED = { "weaningMonth" }


-- =============================================================================
-- Config
-- =============================================================================

--- @param xmlFile table|nil XMLFile with a calfRearing root; nil gives the defaults
--- @return table config
function RLCalfRearing.parse(xmlFile)
    local config = {
        enabled = true,
        weaningMonth = RLCalfRearing.DEFAULTS.weaningMonth,
        milkFillTypes = {},
        curves = {},
        layers = { root = {}, types = {}, breeds = {}, subTypes = {} },
    }
    for name, points in pairs(RLCalfRearing.DEFAULT_CURVES) do config.curves[name] = points end
    local milkNames = RLCalfRearing.DEFAULT_MILK

    if xmlFile ~= nil then
        config.enabled = xmlFile:getBool("calfRearing#enabled", true)
        config.weaningMonth = xmlFile:getFloat("calfRearing#weaningMonth", config.weaningMonth)
        local names = xmlFile:getString("calfRearing#milkFillTypes")
        if names ~= nil then
            milkNames = {}
            for name in names:gmatch("[^%s,;]+") do milkNames[#milkNames + 1] = name:upper() end
        end
        for name in pairs(RLCalfRearing.DEFAULT_CURVES) do
            local points = {}
            xmlFile:iterate("calfRearing." .. name .. ".point", function(_, key)
                local x, y = xmlFile:getFloat(key .. "#x"), xmlFile:getFloat(key .. "#y")
                if x ~= nil and y ~= nil then points[#points + 1] = { x, y } end
            end)
            if #points > 0 then config.curves[name] = points end
        end
        config.layers = RLBreedTraits.parseLayers(xmlFile, "calfRearing", RLCalfRearing.LAYERED)
    end
    for _, name in ipairs(milkNames) do config.milkFillTypes[name] = true end

    -- solidEnergy is read by the weight model v2 only, so a bad one falls back to the default
    -- curve instead of switching calf rearing off. A weaned animal gets its feed's full worth.
    local energy = config.curves.solidEnergy
    local energyOk, energyReason = RLCalfRearing.validateCurve(energy, "solidEnergy")
    if energyOk and energy[#energy][2] < 1 then energyOk, energyReason = false, "solidEnergy must reach 1 after weaning" end
    if not energyOk then
        Log:warning("RLCalfRearing: %s; the default solidEnergy curve is used", energyReason)
        config.curves.solidEnergy = RLCalfRearing.DEFAULT_CURVES.solidEnergy
    end

    local ok, reason = RLCalfRearing.validate(config)
    if not ok then
        Log:error("RLCalfRearing: %s - calf rearing switched off", reason)
        config.enabled = false
        config.invalidReason = reason
    end
    return config
end


--- A curve has points, numbers, y in 0..1, sorted by x.
--- @return boolean ok
--- @return string|nil reason
function RLCalfRearing.validateCurve(points, name)
    if points == nil or #points == 0 then return false, "curve " .. name .. " has no points" end
    for i, point in ipairs(points) do
        if point[1] ~= point[1] or point[2] ~= point[2] then return false, string.format("curve %s point %d is not a number", name, i) end
        if point[2] < 0 or point[2] > 1 then return false, string.format("curve %s point %d is outside 0..1", name, i) end
        if i > 1 and point[1] < points[i - 1][1] then return false, string.format("curve %s is not sorted by x at point %d", name, i) end
    end
    return true
end


--- @return boolean ok
--- @return string|nil reason
function RLCalfRearing.validate(config)
    local weaning = config.weaningMonth
    if type(weaning) ~= "number" or weaning ~= weaning or weaning <= 0 then
        return false, "weaningMonth must be a number > 0"
    end
    if next(config.milkFillTypes) == nil then return false, "milkFillTypes is empty" end
    for _, name in ipairs({ "milkMax", "solidMax" }) do
        local ok, reason = RLCalfRearing.validateCurve(config.curves[name], name)
        if not ok then return false, reason end
    end
    -- A weaned animal must be able to live on solid feed alone.
    local solid = config.curves.solidMax
    if solid[#solid][2] < 1 then return false, "solidMax must reach 1 after weaning" end
    return true
end


--- The config, loaded on the first call.
function RLCalfRearing.getConfig()
    if RLCalfRearing.config == nil then
        RLCalfRearing.config = RLBreedTraits.loadConfig(RLCalfRearing.CONFIG_FILE, "calfRearing", RLCalfRearing.parse)
    end
    return RLCalfRearing.config
end


function RLCalfRearing.isEnabled()
    return RLCalfRearing.getConfig().enabled == true
end


--- @param fillTypeIndex number
--- @return boolean
function RLCalfRearing.isMilkFillType(fillTypeIndex)
    local name = fillTypeIndex ~= nil and g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or nil
    return name ~= nil and RLCalfRearing.getConfig().milkFillTypes[name:upper()] == true
end


local function curve(points, x)
    if x <= points[1][1] then return points[1][2] end
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if x <= b[1] then
            if b[1] == a[1] then return b[2] end
            return a[2] + (b[2] - a[2]) * (x - a[1]) / (b[1] - a[1])
        end
    end
    return points[#points][2]
end


-- =============================================================================
-- Stages and caps
-- =============================================================================

--- Weaning month for an animal (breed / subType / type layers, else the root value).
function RLCalfRearing.getWeaningMonth(animal)
    local config = RLCalfRearing.getConfig()
    local subType = animal ~= nil and animal.getSubType ~= nil and animal:getSubType() or nil
    return RLBreedTraits.resolve(config.layers, subType, "weaningMonth", config.weaningMonth)
end


--- Feeding stage by age: PRE_WEANING, WEANING (the weaning month) or WEANED.
function RLCalfRearing.getStage(animal)
    local x = (animal.age or 0) - RLCalfRearing.getWeaningMonth(animal)
    if x < 0 then return RLCalfRearing.STAGE_PRE_WEANING end
    if x < 1 then return RLCalfRearing.STAGE_WEANING end
    return RLCalfRearing.STAGE_WEANED
end


--- An animal's age against its weaning month, the x of the curves. Under the weight model v2 the
--- age runs on within the month (RLGrowth.getContinuousAge), so the caps and the worth of solid
--- feed change smoothly rather than once a month; otherwise whole months, as before.
local function getWeaningX(animal)
    local age = animal.age or 0
    if RLGrowth ~= nil and RLGrowth.covers(animal) then age = RLGrowth.getContinuousAge(animal) end
    return age - RLCalfRearing.getWeaningMonth(animal)
end


--- Most of its food request an animal can take from milk and from solid feed.
--- @return number milkMax 0..1
--- @return number solidMax 0..1
function RLCalfRearing.getCaps(animal)
    local config = RLCalfRearing.getConfig()
    local x = getWeaningX(animal)
    return curve(config.curves.milkMax, x), curve(config.curves.solidMax, x)
end


--- What a liter of solid feed is worth to a calf against a weaned animal (rumen development):
--- the solidEnergy curve at its age against weaning. Read by the body condition budget for the
--- animal's own share in a rearing pen; milk keeps its own energy (bodyCondition.xml feedEnergy).
--- @param animal table
--- @return number 0..1
function RLCalfRearing.getSolidEnergyFactor(animal)
    if not RLCalfRearing.isEnabled() then return 1 end
    return math.clamp(curve(RLCalfRearing.getConfig().curves.solidEnergy, getWeaningX(animal)), 0, 1)
end


--- Whether the rearing rules feed this pen.
function RLCalfRearing.appliesToPen(placeable)
    if placeable == nil or placeable.spec_husbandryFood == nil or placeable.spec_husbandryAnimals == nil then return false end
    if not RLCalfRearing.isEnabled() then return false end
    local rule = RLHusbandryProfiles ~= nil and RLHusbandryProfiles.getRule(placeable) or nil
    return rule ~= nil and rule.rearing == true
end


local function getTick()
    return RLBodyCondition.getTickId()
end


local function getRequest(animal)
    local environment = g_currentMission.environment
    return (animal:getInput("food") or 0) * (environment.timeAdjustment or 1)
end


-- =============================================================================
-- Feeding
-- =============================================================================

--- Set the pen's milk and solid limits for this feeding. Server only.
function RLCalfRearing.beginFeeding(placeable)
    local spec = placeable.spec_husbandryFood
    if not RLCalfRearing.appliesToPen(placeable) then
        spec.rlCalfCaps = nil
        return
    end

    local caps = { tick = getTick(), milkCap = 0, solidCap = 0, animals = {} }
    for _, animal in pairs(placeable.spec_husbandryAnimals.clusterSystem:getClusters() or {}) do
        if not animal.isDead and (animal.numAnimals or 1) > 0 and animal.getInput ~= nil then
            local request = getRequest(animal)
            if request > 0 then
                local milkMax, solidMax = RLCalfRearing.getCaps(animal)
                local entry = { animal = animal, request = request, milkCap = request * milkMax, solidCap = request * solidMax,
                    stage = RLCalfRearing.getStage(animal) }
                caps.milkCap = caps.milkCap + entry.milkCap
                caps.solidCap = caps.solidCap + entry.solidCap
                table.insert(caps.animals, entry)
            end
        end
    end
    caps.milkLeft, caps.solidLeft = caps.milkCap, caps.solidCap
    spec.rlCalfCaps = caps
end


--- The engine's consumeFoodGroup with the pen's limits: the same order and bookkeeping, but each
--- fill type gives at most what is left of its kind's limit.
function RLCalfRearing.consumeFoodGroupCapped(caps, foodGroup, amount, foodOwner, consumedFood)
    for _, fillTypeIndex in ipairs(foodGroup.fillTypes) do
        local level = foodOwner:getAvailableFood(fillTypeIndex)
        if level ~= nil then
            local isMilk = RLCalfRearing.isMilkFillType(fillTypeIndex)
            local left = math.max(isMilk and caps.milkLeft or caps.solidLeft, 0)
            local delta = math.min(amount, level, left)
            amount = math.max(amount - delta, 0)
            consumedFood[fillTypeIndex] = (consumedFood[fillTypeIndex] or 0) + delta
            if isMilk then caps.milkLeft = left - delta else caps.solidLeft = left - delta end
            if amount == 0 then return amount end
        end
    end
    return amount
end


--- productionWeight of the food group holding a fill type, for an animal type.
function RLCalfRearing.getProductionWeight(fillTypeIndex, animalTypeIndex)
    local foodSystem = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
    local animalFood = foodSystem ~= nil and animalTypeIndex ~= nil and foodSystem:getAnimalFood(animalTypeIndex) or nil
    for _, group in pairs(animalFood ~= nil and animalFood.groups or {}) do
        for _, groupFillType in pairs(group.fillTypes or {}) do
            if groupFillType == fillTypeIndex then return group.productionWeight or 0 end
        end
    end
    return 0
end


--- Share what the pen ate out to its animals (after the feed ledger is closed). Server only.
function RLCalfRearing.settle(placeable)
    local spec = placeable.spec_husbandryFood
    local caps = spec.rlCalfCaps
    spec.rlCalfCaps = nil
    if caps == nil then return end

    local supply = spec.rlNutritionSupply
    local consumed = (supply ~= nil and supply.tick == caps.tick) and supply.consumed or {}

    local milkEaten, solidEaten = 0, 0
    for fillTypeIndex, liters in pairs(consumed) do
        if RLCalfRearing.isMilkFillType(fillTypeIndex) then milkEaten = milkEaten + liters else solidEaten = solidEaten + liters end
    end

    local day = spec.rlCalfDay or { hours = 0, requested = 0, consumed = {}, animals = {} }
    spec.rlCalfDay = day
    day.hours = day.hours + 1

    for _, entry in ipairs(caps.animals) do
        local animal = entry.animal
        local milkShare = caps.milkCap > 0 and entry.milkCap / caps.milkCap or 0
        local solidShare = caps.solidCap > 0 and entry.solidCap / caps.solidCap or 0
        local items, value, milk, solid = {}, 0, 0, 0
        for fillTypeIndex, liters in pairs(consumed) do
            local isMilk = RLCalfRearing.isMilkFillType(fillTypeIndex)
            local got = liters * (isMilk and milkShare or solidShare)
            if got > 0 then
                items[fillTypeIndex] = got
                value = value + got * RLCalfRearing.getProductionWeight(fillTypeIndex, spec.animalTypeIndex)
                if isMilk then milk = milk + got else solid = solid + got end
            end
        end
        local factor = math.clamp(value / entry.request, 0, 2)
        animal.rlCalfFeed = { tick = caps.tick, factor = factor, items = items, request = entry.request,
            milk = milk, solid = solid, stage = entry.stage }

        local key = tostring(animal.farmId) .. " " .. tostring(animal.uniqueId)
        local record = day.animals[key] or { animal = animal, hours = 0, request = 0, milk = 0, solid = 0, factor = 0 }
        day.animals[key] = record
        record.animal = animal
        record.hours = record.hours + 1
        record.request = record.request + entry.request
        record.milk = record.milk + milk
        record.solid = record.solid + solid
        record.factor = record.factor + factor
        record.stage = entry.stage
        day.requested = day.requested + entry.request
    end
    for fillTypeIndex, liters in pairs(consumed) do
        day.consumed[fillTypeIndex] = (day.consumed[fillTypeIndex] or 0) + liters
    end
    day.milk = (day.milk or 0) + milkEaten
    day.solid = (day.solid or 0) + solidEaten
    day.milkCap = (day.milkCap or 0) + caps.milkCap
    day.solidCap = (day.solidCap or 0) + caps.solidCap
end


--- The food factor for an animal's health and growth this hour: its own share in a rearing pen,
--- else the pen's factor unchanged.
--- @param animal table
--- @param foodFactor number The pen's factor
--- @return number
function RLCalfRearing.getFoodFactor(animal, foodFactor)
    local feed = animal ~= nil and animal.rlCalfFeed or nil
    if feed == nil then return foodFactor end
    if feed.tick ~= getTick() then
        animal.rlCalfFeed = nil
        return foodFactor
    end
    return feed.factor
end


--- An animal's own liters per fill type this hour in a rearing pen (for the body condition
--- budget), or nil outside one.
--- @return table|nil {[fillTypeIndex] = liters}
function RLCalfRearing.getAllocation(animal, tick)
    local feed = animal ~= nil and animal.rlCalfFeed or nil
    if feed == nil or feed.tick ~= tick then return nil end
    return feed.items
end


-- =============================================================================
-- Daily record
-- =============================================================================

local function round(value) return math.floor((value or 0) * 1000 + 0.5) / 1000 end


--- Log yesterday's feeding of a rearing pen and any animal whose feeding stage changed. Server only.
function RLCalfRearing.onPenDayChanged(placeable)
    if not RLCalfRearing.appliesToPen(placeable) then return end
    local foodSpec = placeable.spec_husbandryFood
    local spec = placeable.spec_husbandryAnimals
    local day = foodSpec.rlCalfDay
    foodSpec.rlCalfDay = nil

    if day ~= nil and day.hours > 0 then
        local consumed = {}
        for fillTypeIndex, liters in pairs(day.consumed) do
            consumed[g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or tostring(fillTypeIndex)] = round(liters)
        end
        local animals = {}
        for _, record in pairs(day.animals) do
            local identity = RLPenLog.animal(record.animal)
            identity.stage = record.stage
            identity.request = round(record.request)
            identity.milk = round(record.milk)
            identity.solid = round(record.solid)
            identity.meanFactor = round(record.factor / record.hours)
            identity.health = record.animal.health
            animals[#animals + 1] = identity
        end
        table.sort(animals, function(a, b) return tostring(a.key) < tostring(b.key) end)
        RLPenLog.emit("CALF_FEED_DAY", {
            pen = RLPenLog.pen(placeable),
            hours = day.hours,
            requested = round(day.requested),
            milkCap = round(day.milkCap),
            solidCap = round(day.solidCap),
            milk = round(day.milk),
            solid = round(day.solid),
            consumed = consumed,
            water = placeable.spec_husbandryWater == nil and "NONE" or "PRESENT",
            animals = animals,
        })
    end

    spec.rlFeedStages = spec.rlFeedStages or {}
    local seen = {}
    for _, animal in pairs(spec.clusterSystem:getClusters() or {}) do
        if not animal.isDead then
            local key = tostring(animal.farmId) .. " " .. tostring(animal.uniqueId)
            seen[key] = true
            local stage = RLCalfRearing.getStage(animal)
            local before = spec.rlFeedStages[key]
            if before ~= stage then
                local milkMax, solidMax = RLCalfRearing.getCaps(animal)
                RLPenLog.emit("FEED_STAGE", {
                    pen = RLPenLog.pen(placeable),
                    animal = RLPenLog.animal(animal),
                    from = before,
                    to = stage,
                    weaningMonth = RLCalfRearing.getWeaningMonth(animal),
                    milkMax = round(milkMax),
                    solidMax = round(solidMax),
                })
                spec.rlFeedStages[key] = stage
            end
        end
    end
    for key in pairs(spec.rlFeedStages) do
        if not seen[key] then spec.rlFeedStages[key] = nil end
    end
end


-- The engine's food consumption, with the rearing pen's limits while a feeding is open.
if AnimalFoodSystem ~= nil and AnimalFoodSystem.consumeFoodGroup ~= nil then
    local consumeFoodGroup = AnimalFoodSystem.consumeFoodGroup
    AnimalFoodSystem.consumeFoodGroup = function(self, foodGroup, amount, foodOwner, consumedFood)
        local foodSpec = type(foodOwner) == "table" and foodOwner.spec_husbandryFood or nil
        local caps = foodSpec ~= nil and foodSpec.rlCalfCaps or nil
        if caps == nil then return consumeFoodGroup(self, foodGroup, amount, foodOwner, consumedFood) end
        return RLCalfRearing.consumeFoodGroupCapped(caps, foodGroup, amount, foodOwner, consumedFood)
    end
end
