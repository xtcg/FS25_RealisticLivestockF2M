-- Engine stand-ins and a simulator for the real-equivalent nutrition mode (RLFeed): cattle pens
-- with a trough of fill levels, the map's cattle food groups (Hof Bergmann order) with the grain
-- group registered as in the game, and an hour loop that runs the pen's feeding (RLFeed planner,
-- the trough's removal, both ledgers) and each animal's AnimalHealth.updateHealth, as the server's
-- hourly update does. Builds on tests/growthsim.lua. Shared by tests/test_feed.lua and the
-- offline report (tests/feedreport.lua).

loadMod("tests/growthsim.lua")
loadMod("scripts/animal/AnimalHealth.lua")

FeedSim = {}

local FILL = GrowthSim.FILL
for _, name in ipairs({ "WHEAT", "MAIZE", "BARLEY", "OAT", "CLOVER_WINDROW", "SUGARBEET_CUT", "FORAGEPLUS", "ROUNDBALE", "GRAINGRIST", "PEA" }) do
    if FILL[name] == nil then
        local index = 0
        for _, i in pairs(FILL) do index = math.max(index, i) end
        FILL[name] = index + 1
    end
end
local FILL_NAMES = {}
for name, index in pairs(FILL) do FILL_NAMES[index] = name end
g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return FILL_NAMES[i] end,
    getFillTypeIndexByName = function(_, n) return FILL[n] end,
}
FeedSim.FILL = FILL

local COW = GrowthSim.COW_TYPE
g_i18n = g_i18n or { getText = function(_, key) return key end }
local function group(title, weight, names)
    local fillTypes = {}
    for _, name in ipairs(names) do table.insert(fillTypes, FILL[name]) end
    return { title = title, productionWeight = weight, eatWeight = 1, fillTypes = fillTypes }
end
-- Hof Bergmann 1.5's cattle food (character/animalFood.xml), SERIAL.
local cowFood = { consumptionType = 1, groups = {
    group("forage", 1.0, { "FORAGE", "ROUNDBALE" }), group("hay", 0.65, { "DRYGRASS_WINDROW" }), group("silage", 0.8, { "SILAGE" }),
    group("grass", 0.4, { "GRASS_WINDROW", "CLOVER_WINDROW" }), group("earth", 0.85, { "SUGARBEET_CUT" }), group("special", 1.2, { "CALFMILK" }),
} }
local foodSystem = { mission = { animalSystem = { getTypeIndexByName = function(_, name) return name == "COW" and COW or nil end } } }
function foodSystem:getAnimalFood(typeIndex) return typeIndex == COW and cowFood or nil end
g_currentMission.animalFoodSystem = foodSystem
RLFeed.registerCattleGrains(foodSystem)
FeedSim.cowFood = cowFood

-- Rearing pens: RLCalfRearing asks the husbandry profile.
RLHusbandryProfiles = { getRule = function(placeable) return placeable.rearingRule end }

for _, sub in ipairs(Economics.subTypes) do
    sub.healthIncreaseHour, sub.healthDecreaseHour, sub.healthThresholdFactor = 10, 25, 0.45
    sub.output = { milk = { get = function(_, age) return Economics.curve(sub.milk, age) end } }
end


--- Switch the mode on or off (the RL setting).
function FeedSim.setMode(real)
    RLFeed.onSettingChanged("nutritionMode", real and RLFeed.MODE_REAL or RLFeed.MODE_LEGACY)
end


--- A cattle pen with a trough. stock: name -> liters.
function FeedSim.makePen(animals, stock, opts)
    opts = opts or {}
    local spec = { fillLevels = {}, supportedFillTypes = {}, litersPerHour = 0, animalTypeIndex = COW }
    for _, g in ipairs(cowFood.groups) do
        for _, index in ipairs(g.fillTypes) do spec.fillLevels[index], spec.supportedFillTypes[index] = 0, true end
    end
    local pen = { spec_husbandryFood = spec, isServer = true, animals = animals or {}, rearingRule = opts.rearing and { rearing = true } or nil,
        name = opts.name or "pen" }
    pen.spec_husbandryAnimals = { clusterSystem = { getClusters = function() return pen.animals end } }
    function pen:getName() return self.name end
    function pen:getAnimalTypeIndex() return COW end
    function pen:getClusters() return self.animals end
    function pen:getAvailableFood(index) return self.spec_husbandryFood.fillLevels[index] end
    function pen:removeFood(liters, index)
        local level = self.spec_husbandryFood.fillLevels[index] or 0
        local removed = math.min(math.max(liters, 0), level)
        self.spec_husbandryFood.fillLevels[index] = level - removed
        RLBodyCondition.recordRemoved(self, index, removed)
        return removed
    end
    function pen:add(name, liters)
        local index = FILL[name]
        self.spec_husbandryFood.fillLevels[index] = (self.spec_husbandryFood.fillLevels[index] or 0) + liters
    end
    function pen:level(name) return self.spec_husbandryFood.fillLevels[FILL[name]] or 0 end
    for name, liters in pairs(stock or {}) do pen:add(name, liters) end
    for _, animal in ipairs(pen.animals) do animal.clusterSystem = { owner = pen } end
    return pen
end


local function lactationFactor(m) if m >= 10 then return 0 end if m <= 3 then return 0.8 + m / 6 end return 0.8 + (11 - m) / 15 end

--- The food request per hour as Animal:updateInput sets it: in the mode the liters of the last
--- plan, else the curve.
function FeedSim.refreshRequest(animal)
    GrowthSim.refreshRequest(animal)
    local planned = RLFeed.getRequestLitersPerPeriod(animal)
    if planned ~= nil then animal.input.food = planned / 24 end
end


--- One hour: requests and milk at full feed, the pen's feeding, then each animal's update.
--- @return number foodFactor
function FeedSim.hour(pen, opts)
    opts = opts or {}
    for _, animal in ipairs(pen.animals) do
        FeedSim.refreshRequest(animal)
        local sub = animal:getSubType()
        if #sub.milk > 0 then
            -- As Animal:updateOutput: the curve at its mature age, the lactation number sets the level.
            local parity = RLMilkParity.getFactor(RLMilkParity.getParity(animal.children ~= nil and #animal.children or 0, animal.age))
            local curve = Economics.curve(sub.milk, RLMilkParity.getCurveAge(animal.age)) * parity
            local lactation = animal.isLactating and lactationFactor(animal.monthsSinceLastBirth or 0) or 0
            RLBodyCondition.applyMilk(animal, curve * lactation * animal.genetics.productivity, curve, 1)
        end
    end
    GrowthSim.advanceHour()
    local spec = pen.spec_husbandryFood
    local total = 0
    for _, animal in ipairs(pen.animals) do total = total + animal:getInput("food") end
    spec.litersPerHour = total

    local active = RLFeed.beginFeeding(pen)
    RLBodyCondition.beginFeeding(pen)
    local factor
    if active then
        local consumed = {}
        factor = RLFeed.consume(pen, consumed)
        for index, liters in pairs(consumed) do pen:removeFood(liters, index) end
    else
        -- The old rules: the map's groups in order, at their production weights (no grain).
        local amount = spec.litersPerHour * GrowthSim.env.timeAdjustment
        local request, weight = amount, 0
        for _, g in ipairs(cowFood.groups) do
            if not g.rlGrain and amount > 0 then
                local before = amount
                for _, index in ipairs(g.fillTypes) do
                    local take = math.min(amount, spec.fillLevels[index] or 0)
                    if take > 0 then pen:removeFood(take, index); amount = amount - take end
                end
                if request > 0 then weight = weight + (before - amount) / request * g.productionWeight end
            end
        end
        factor = weight
    end
    RLBodyCondition.recordWater(pen, opts.water or 1)
    RLBodyCondition.endFeeding(pen)
    if active then RLFeed.endFeeding(pen) end
    factor = factor * (opts.water or 1)
    for _, animal in ipairs(pen.animals) do AnimalHealth.updateHealth(animal, factor) end
    return factor
end


--- Run hours until the pen has taken a model-time step (RLFeed: one 0.25-day step is 1/5 of a
--- one-day month's hour, or several hours of a long month).
--- @return number hours run
function FeedSim.untilStep(pen, opts)
    local hours = 0
    repeat
        if opts ~= nil and opts.refill ~= nil then opts.refill(pen) end
        FeedSim.hour(pen, opts)
        hours = hours + 1
        local window = pen.spec_husbandryFood.rlFeedLast
    until (pen.spec_husbandryFood.rlFeedLast ~= nil and pen.spec_husbandryFood.rlFeedLast.tick == RLBodyCondition.getTickId())
        or hours >= 200 or not pen.spec_husbandryFood.rlFeedPen.active
    return hours
end


--- Run whole months: age moves on at each period change, a lactating cow's months since calving
--- too.
function FeedSim.months(pen, months, opts)
    for _ = 1, months do
        for _ = 1, 24 * GrowthSim.env.daysPerPeriod do
            if opts ~= nil and opts.refill ~= nil then opts.refill(pen) end
            FeedSim.hour(pen, opts)
        end
        GrowthSim.env.currentPeriod = (GrowthSim.env.currentPeriod or 1) % 12 + 1
        for _, animal in ipairs(pen.animals) do
            animal.age = animal.age + 1
            if animal.isLactating then
                animal.monthsSinceLastBirth = (animal.monthsSinceLastBirth or 0) + 1
                if animal.monthsSinceLastBirth >= 10 then animal.isLactating = false end
            end
        end
    end
end


--- Keep a pen's trough topped up with a ration (liters per name, set each hour).
function FeedSim.keepStocked(stock)
    return function(pen)
        for name, liters in pairs(stock) do
            if pen:level(name) < liters then pen:add(name, liters - pen:level(name)) end
        end
    end
end


--- Raise one animal in its own pen on a stocked ration until stop(animal) or maxMonths.
--- @return number months (to the hour), table animal, table pen
function FeedSim.raise(name, stock, stop, maxMonths, fields, opts)
    local animal = GrowthSim.newborn(name, fields)
    local pen = FeedSim.makePen({ animal }, {}, opts)
    if opts ~= nil and opts.ration ~= nil then RLFeed.setRation(pen, opts.ration) end
    local refill = FeedSim.keepStocked(stock)
    local hours, perMonth = 0, 24 * GrowthSim.env.daysPerPeriod
    while animal.age < (maxMonths or 120) do
        for _ = 1, perMonth do
            refill(pen)
            FeedSim.hour(pen, opts)
            hours = hours + 1
            if stop ~= nil and stop(animal) then return hours / perMonth, animal, pen end
        end
        animal.age = animal.age + 1
    end
    return hours / perMonth, animal, pen
end
