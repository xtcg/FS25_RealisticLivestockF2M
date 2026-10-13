-- D3-3 hourly reference. Detached cattle only; never called by live dealer generation yet.
RLDealerReplay = { VERSION = 1, RECIPE_VERSION = 1 }
local R = RLDealerReplay
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

-- Candidate recipes use existing feed profiles and physical planner limits, never energy
-- invented from a deficit. Calibration reports determine which purposes they can supply.
local RECIPES = {
    NORMAL_REARING = { forage = { "FORAGE" }, concentrate = { "PEA", "MAIZE" }, milk = { "CALFMILK" }, target = "GROW" },
    MODERATE_SLOW_REARING = { forage = { "FORAGE" }, concentrate = { "PEA", "MAIZE" }, milk = { "CALFMILK" }, target = "GROW", offeredIntakeShare = 0.95 },
    NORMAL_PRODUCTION = { forage = { "FORAGE" }, concentrate = { "PEA", "MAIZE" }, milk = { "CALFMILK" }, target = "GROW" },
}
function R.getRecipe(id)
    if RECIPES[id] == nil then return nil end
    local recipe = copy(RECIPES[id])
    recipe.id, recipe.version = id, R.RECIPE_VERSION
    return recipe
end

-- Only explicitly configured breeds can supply breeding candidates. The development gate
-- is the individual's reference-frame phase at that ratio of its curve's adult target.
-- Thus a heavy reserve alone cannot make an underdeveloped heifer breedable.
function R.getBreedingRules(animal, entry)
    local ratio = entry ~= nil and entry.breedingWeightRatio or nil
    if not finite(ratio) or ratio <= 0 or ratio > 1 then return nil end
    return { minAgeMonths = RLDealerStockPolicy.getBreedingAge(entry, animal:getSubType()),
        minWeightRatio = ratio,
        minDevelopmentMonths = RLGrowth.getCurve(animal):inverse(animal.rlGrowth.frameTargetKg * ratio),
        minReserveFraction = 0.05, maxReserveFraction = 0.11 }
end

-- No pen, fill-type manager, trough, game clock, money or generation RNG is touched.
function R.planFeed(animal, recipe, dtMonths)
    local cfg = RLFeed.getConfig()
    local days = dtMonths * cfg.realDaysPerPeriod
    local function stock(names)
        local out = {}
        for _, name in ipairs(names) do
            local profile = RLFeedProfiles.getUsableFeed(name)
            if profile == nil then return nil, "FEED_PROFILE:" .. name end
            out[#out + 1] = { name = name, profile = profile, liters = 1e12 }
        end
        return out
    end
    local forage, reason = stock(recipe.forage)
    if forage == nil then return nil, reason end
    local concentrate; concentrate, reason = stock(recipe.concentrate)
    if concentrate == nil then return nil, reason end
    local milk; milk, reason = stock(recipe.milk)
    if milk == nil then return nil, reason end
    local descriptor = RLFeed.describeAnimal(animal, recipe, dtMonths, days)
    -- A physical daily DM offer ceiling, independent of the budget deficit. Energy/protein
    -- still come only from actual planned feed kg and their unchanged feed profiles.
    if recipe.offeredIntakeShare ~= nil then
        descriptor.appetite = descriptor.appetite * recipe.offeredIntakeShare
        if descriptor.solidCap ~= nil then descriptor.solidCap = descriptor.solidCap * recipe.offeredIntakeShare end
    end
    local plan = RLFeedRationPlanner.plan({ animals = { descriptor }, forage = forage,
        concentrate = concentrate, milk = milk, scale = cfg.resourceScale,
        realDaysPerPeriod = cfg.realDaysPerPeriod, dtDays = days, share = recipe.share,
        ration = cfg.ration, classes = cfg.classes, proteinMaintenance = cfg.protein.maintenance,
        proteinMilkResponse = cfg.protein.milkResponse, concentrateWanted = #concentrate > 0 })
    local a = plan.animals[1]
    return { kg = a.kg, me = a.me, cp = a.cp, byFill = a.byFill, plannedKg = a.plannedKg,
        plannedMe = a.plannedMe, class = a.class, target = a.target, concShare = a.cEaten,
        dtDays = days, water = 1, milkDemandFactor = a.milkDemandFactor,
        proteinFactor = RLFeedMath.getProteinFactor(a.cp, a.proteinNeed, cfg.protein.maintenance) }
end

local function snapshot(animal)
    local out = RLGrowth.copyState(animal.rlGrowth)
    out.health, out.birthCount = animal.health, animal.birthCount
    return out
end

local function validState(animal, time)
    local s = animal.rlGrowth
    return finite(time) and (s ~= nil and RLGrowth.isUsable(s)) and finite(s.ageMonths)
        and s.version == RLGrowth.STATE_VERSION and s.source == "birth" and s.legacyAnchor == nil
        and s.lastTick == nil and s.weightKg == animal.weight and finite(s.gravidKg or 0)
        and (s.gravidKg or 0) >= 0 and s.reserveMassKg < s.weightKg - (s.gravidKg or 0)
        and math.abs(s.ageMonths - time) < 1e-8 and finite(animal.health)
end

local function validateHistory(h)
    if type(h) ~= "table" or h.version ~= RLDealerHistory.VERSION or type(h.template) ~= "table"
        or h.template.version ~= RLDealerHistory.TEMPLATE_VERSION or R.getRecipe(h.template.id) == nil
        or not finite(h.saleAgeMonths) or h.saleAgeMonths <= 0 or h.saleAgeMonths > 120
        or not finite(h.weaningMonth) or h.weaningMonth < 0
        or h.weanedAtMonths ~= h.weaningMonth + 1 or type(h.events) ~= "table"
        or type(h.source) ~= "string" or h.source == "" then return false end
    local template = RLDealerHistory.getTemplate(h.template.id)
    local last, active, births, sales = -1, nil, 0, 0
    local kinds = { BIRTH = true, CONCEPTION = true, CALVING = true, WEANING_START = true, WEANED = true, SALE = true }
    local count = 0
    for key in pairs(h.events) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key > #h.events then return false end
        count = count + 1
    end
    if count ~= #h.events then return false end
    for index, e in ipairs(h.events) do
        if type(e) ~= "table" or not kinds[e.kind] or not finite(e.atMonths) or e.atMonths < 0
            or e.atMonths < last or e.atMonths > h.saleAgeMonths then return false end
        last = e.atMonths
        if e.kind == "BIRTH" then
            if index ~= 1 or last ~= 0 or not finite(e.weightKg) or e.weightKg <= 0 then return false end
        elseif e.kind == "CONCEPTION" then
            if not template.production or active ~= nil or e.parity ~= births + 1 then return false end
            active = e
        elseif e.kind == "CALVING" then
            if active == nil or e.parity ~= births + 1 or not finite(h.durationMonths) or h.durationMonths <= 0
                or math.abs(last - active.atMonths - h.durationMonths) > 1e-9 then return false end
            births, active = births + 1, nil
        elseif e.kind == "SALE" then
            sales = sales + 1
            if index ~= #h.events or last ~= h.saleAgeMonths then return false end
        elseif e.kind == "WEANING_START" and last ~= h.weaningMonth then return false
        elseif e.kind == "WEANED" and last ~= h.weanedAtMonths then return false end
    end
    return #h.events >= 2 and h.events[1].kind == "BIRTH" and sales == 1
        and (active == nil or (finite(h.durationMonths) and h.saleAgeMonths - active.atMonths < h.durationMonths))
end

function R.validateHistory(history) return validateHistory(history) end

-- Assumed birth/history stays immutable. Actual source events have their own schema
-- and evidence; they cannot invent a conception or retrospectively fix a failed mating.
function R.getSourceLifecycle(history, observations, time)
    if not validateHistory(history) or not finite(time) or time < history.saleAgeMonths then return nil, "SOURCE_HISTORY" end
    local life = { birthCount = 0, nextEventIndex = 1 }
    for index, event in ipairs(history.events) do
        if event.atMonths <= time + 1e-10 then
            life.nextEventIndex = index + 1
            if event.kind == "CONCEPTION" then life.conceptionMonths = event.atMonths end
            if event.kind == "CALVING" then
                life.birthCount, life.lastBirthMonths, life.conceptionMonths = life.birthCount + 1, event.atMonths, nil
            end
        end
    end
    if observations == nil then return life end
    if type(observations) ~= "table" or observations.version ~= 1 or type(observations.events) ~= "table" then
        return nil, "SOURCE_OBSERVATIONS"
    end
    local count, ids, last = 0, {}, history.saleAgeMonths
    for key in pairs(observations.events) do
        if not finite(key) or key % 1 ~= 0 or key < 1 or key > #observations.events then return nil, "SOURCE_OBSERVATIONS" end
        count = count + 1
    end
    if count ~= #observations.events then return nil, "SOURCE_OBSERVATIONS" end
    for _, event in ipairs(observations.events) do
        if type(event) ~= "table" or event.kind ~= "CALVING" or event.evidence ~= "OBSERVED_SOURCE_BIRTH"
            or type(event.eventId) ~= "string" or event.eventId == "" or ids[event.eventId]
            or not finite(event.atAgeMonths) or event.atAgeMonths < last or event.atAgeMonths > time + 1e-10
            or not finite(event.cursorMonths) or event.cursorMonths < 0 or type(event.parentDied) ~= "boolean"
            or type(event.newborns) ~= "table" or type(event.draws) ~= "table" or #event.draws < 1 or #event.draws > 3
            or life.conceptionMonths == nil or event.atAgeMonths ~= life.conceptionMonths + history.durationMonths
            or event.parity ~= life.birthCount + 1 or life.isDead then return nil, "SOURCE_OBSERVATIONS" end
        local children = {}
        for _, draw in ipairs(event.draws) do
            if type(draw) ~= "table" or type(draw.uniqueId) ~= "string" or draw.uniqueId == ""
                or children[draw.uniqueId] or not finite(draw.weightKg) or draw.weightKg <= 0
                or not finite(draw.z) or not finite(draw.meanWeightKg) or draw.meanWeightKg <= 0 then return nil, "SOURCE_OBSERVATIONS" end
            children[draw.uniqueId] = draw
        end
        local survivors = {}
        for _, child in ipairs(event.newborns) do
            if type(child) ~= "table" or children[child.uniqueId] == nil or survivors[child.uniqueId]
                or child.birthWeightKg ~= children[child.uniqueId].weightKg or child.alive ~= true then return nil, "SOURCE_OBSERVATIONS" end
            survivors[child.uniqueId] = true
        end
        ids[event.eventId], last = true, event.atAgeMonths
        life.birthCount, life.lastBirthMonths, life.conceptionMonths = event.parity, event.atAgeMonths, nil
        life.isDead = event.parentDied
    end
    return life
end

local function refreshMilk(animal, lastBirth, time)
    animal.monthsSinceLastBirth = lastBirth ~= nil and time - lastBirth or 12
    animal.isLactating = lastBirth ~= nil and RLLactation.isWithin(animal.monthsSinceLastBirth)
    local sub = animal:getSubType()
    local curve = sub.output ~= nil and sub.output.milk or nil
    local milk = curve ~= nil and curve.get ~= nil and curve:get(RLMilkParity.getCurveAge(animal.age)) or 0
    milk = milk * RLMilkParity.getFactor(RLMilkParity.getParity(animal.birthCount)) * RLBreedTraits.get(sub, "milkScale")
    RLBodyCondition.applyMilk(animal, animal.isLactating
        and milk * RLLactation.getYieldFactor(animal.monthsSinceLastBirth) * animal.genetics.productivity or 0, milk, 1)
end

local function cloneReplayAnimal(original)
    local animal = setmetatable({}, { __index = Animal })
    for _, key in ipairs({ "age", "subType", "subTypeIndex", "animalTypeIndex", "breed", "gender",
        "isIndividual", "isCastrated", "health", "isParent", "birthCount", "isPregnant",
        "reproduction", "monthsSinceLastBirth", "isLactating", "weight", "targetWeight",
        "rlHistoryReplay", "rlFeedGain", "rlHealthCarry" }) do animal[key] = original[key] end
    for _, key in ipairs({ "genetics", "diseases", "input", "output", "rlGrowth", "bodyCondition", "rlMilk", "sale" }) do
        animal[key] = copy(original[key])
    end
    animal.getSubType = original.getSubType
    if original.pregnancy ~= nil then
        animal.pregnancy = { duration = original.pregnancy.duration, pregnancies = {} }
        for index, child in ipairs(original.pregnancy.pregnancies) do
            local sub = child:getSubType()
            animal.pregnancy.pregnancies[index] = { getSubType = function() return sub end }
        end
    end
    return animal
end

-- options: daysPerMonth (number or month-indexed array), breedingRules (explicit breed rules),
-- pregnancySubTypes[eventIndex] (selected physical fetal subtypes, no unborn animal identities),
-- minHealth (default 90). Input seed carries subtype + genes, never an existing animal state.
-- Result retains detached replay animal for review; it is NOT a listing/purchase payload.
local function replay(seed, history, options, previous, targetAge, sourceBoundary)
    options = options or {}
    local function reject(reason, at, detail) return nil, { reason = reason, atMonths = at, detail = detail } end
    if not validateHistory(history) then return reject("INVALID_HISTORY") end
    targetAge = targetAge or history.saleAgeMonths
    if not finite(targetAge) or targetAge < history.saleAgeMonths or targetAge > 120 then return reject("SOURCE_INTERVAL") end
    local sub = seed ~= nil and seed.subType or nil
    if sub == nil or AnimalType == nil or sub.typeIndex ~= AnimalType.COW or not RLGrowth.coversSubType(sub) then
        return reject("MODEL_COVERAGE")
    end
    if not finite(sub.healthIncreaseHour) or sub.healthIncreaseHour < 0
        or not finite(sub.healthDecreaseHour) or sub.healthDecreaseHour < 0 then return reject("HEALTH_RULES") end
    for _, event in ipairs(history.events) do
        if event.kind == "CALVING" and (sub.output == nil or sub.output.milk == nil
            or type(sub.output.milk.get) ~= "function") then return reject("MILK_RULES") end
    end
    local genes = seed.genetics
    for _, key in ipairs({ "metabolism", "quality", "productivity", "fertility", "health" }) do
        if genes == nil or not finite(genes[key]) or genes[key] < 0.25 or genes[key] > 1.75 then return reject("GENETICS") end
    end
    if seed.geneticsScreened ~= true then return reject("GENETICS_NOT_SCREENED") end
    for _, disease in pairs(seed.diseases or {}) do
        if disease.isCarrier ~= true then return reject("GENETIC_DISEASE") end
    end
    if not RLCalfRearing.isEnabled() or history.weaningMonth ~= RLCalfRearing.getWeaningMonthForSubType(sub) then
        return reject("WEANING_RULES")
    end
    local animal = previous ~= nil and cloneReplayAnimal(previous.animal) or setmetatable({ age = 0, subType = sub.name, subTypeIndex = seed.subTypeIndex,
        animalTypeIndex = sub.typeIndex, breed = sub.breed, gender = sub.gender, isIndividual = true,
        isCastrated = seed.isCastrated == true, genetics = copy(genes), health = seed.health or 100,
        isParent = false, birthCount = 0, isPregnant = false, reproduction = 0,
        diseases = copy(seed.diseases or {}), input = {}, output = {}, rlHistoryReplay = true,
        getSubType = function() return sub end }, { __index = Animal })
    local minHealth = options.minHealth or 90
    if not finite(minHealth) or minHealth < 0 or minHealth > 100 or not finite(animal.health)
        or animal.health < minHealth or animal.health > 100 then return reject("HEALTH") end
    local state, birthReason
    if previous ~= nil then
        state = animal.rlGrowth
        if not validState(animal, state.ageMonths) or state.birthWeightKg ~= history.events[1].weightKg
            or state.ageMonths < history.saleAgeMonths or targetAge < state.ageMonths then return reject("SOURCE_STATE") end
    else
        state, birthReason = RLGrowth.createBirthState(animal, history.events[1].weightKg)
        if state == nil then return reject(birthReason) end
        state.lastTick = nil
        animal.rlGrowth, animal.weight = state, state.weightKg
    end
    local breedingRules = options.breedingRules or R.getBreedingRules(animal, options.entry)
    local boundaries = RLDealerHistory.boundaries(history)
    for month = math.floor(history.saleAgeMonths) + 1, math.floor(targetAge) do boundaries[#boundaries + 1] = month end
    boundaries[#boundaries + 1] = targetAge
    for _, e in ipairs(history.events) do
        if e.kind == "CALVING" then
            for _, offset in ipairs({ 3, RLLactation.MONTHS }) do
                if e.atMonths + offset < targetAge then boundaries[#boundaries + 1] = e.atMonths + offset end
            end
        end
    end
    table.sort(boundaries)
    local time, eventIndex, boundaryIndex, steps, lastBirth, conception = 0, 1, 1, 0, nil, nil
    local snapshots, fetalSelections, ledger = {}, {}, { maxEnergyError = 0, maxMassError = 0, feedMe = 0, milkLiters = 0 }
    local recipe = R.getRecipe(history.template.id)
    local initialSteps = previous ~= nil and previous.steps or 0
    if previous ~= nil then
        time, steps = state.ageMonths, previous.steps
        snapshots, fetalSelections, ledger = copy(previous.conceptionSnapshots), copy(previous.fetalSelections), copy(previous.ledger)
        for index, e in ipairs(history.events) do
            if e.atMonths <= time + 1e-10 then
                eventIndex = index + 1
                if e.kind == "CONCEPTION" then conception = e.atMonths end
                if e.kind == "CALVING" then lastBirth, conception = e.atMonths, nil end
            end
        end
        local life, lifeReason = R.getSourceLifecycle(history, previous.observedSourceEvents, time)
        if life == nil or life.isDead then return reject(lifeReason or "SOURCE_DEAD", time) end
        lastBirth, conception, eventIndex = life.lastBirthMonths, life.conceptionMonths, life.nextEventIndex
        if animal.birthCount ~= life.birthCount then return reject("SOURCE_STATE", time) end
        if (conception ~= nil) ~= animal.isPregnant or animal.birthCount ~= (previous.state.birthCount or 0) then
            return reject("SOURCE_STATE", time)
        end
        if sourceBoundary and (conception == nil or targetAge ~= conception + history.durationMonths) then
            return reject("SOURCE_BIRTH_BOUNDARY", time)
        end
        if conception ~= nil and targetAge >= conception + history.durationMonths - 1e-10
            and not (sourceBoundary and targetAge == conception + history.durationMonths) then
            return reject("SOURCE_CALVING_REQUIRED", conception + history.durationMonths)
        end
    end
    while true do
        animal.age = math.floor(time + 1e-10)
        while history.events[eventIndex] ~= nil and history.events[eventIndex].atMonths <= time + 1e-10 do
            local e = history.events[eventIndex]
            if e.kind == "CONCEPTION" then
                local recovery = options.entry ~= nil and options.entry.profile ~= nil and options.entry.profile.minRecoveryMonth or nil
                if not finite(recovery) or recovery < 0 then return reject("MISSING_REPRODUCTION_RULES", time) end
                if history.durationMonths ~= sub.reproductionDurationMonth then return reject("GESTATION_DURATION", time) end
                if time < RLDealerStockPolicy.getBreedingAge(options.entry, sub) then return reject("BREEDING_AGE", time) end
                if lastBirth ~= nil and time < lastBirth + recovery - 1e-9 then return reject("RECOVERY", time) end
                snapshots[eventIndex] = snapshot(animal)
                local ok, reason = RLDealerHistory.validateConception(e, snapshots[eventIndex], breedingRules)
                if not ok then return reject(reason, time, eventIndex) end
                if sub.gender ~= "female" or not sub.supportsReproduction then return reject("NO_REPRODUCTION", time) end
                local fetalTypes = options.pregnancySubTypes ~= nil and options.pregnancySubTypes[eventIndex] or nil
                if type(fetalTypes) ~= "table" or #fetalTypes < 1 or #fetalTypes > 3 then return reject("FETAL_CONTEXT", time) end
                local fetuses = {}
                fetalSelections[eventIndex] = {}
                for _, fetal in ipairs(fetalTypes) do
                    if type(fetal) ~= "table" or fetal.typeIndex ~= AnimalType.COW or not RLGrowth.coversSubType(fetal) then return reject("FETAL_CONTEXT", time) end
                    if (RLGrowth.getBinding(fetal).profile == "WATER_BUFFALO")
                        ~= (RLGrowth.getBinding(sub).profile == "WATER_BUFFALO") then return reject("FETAL_CONTEXT", time) end
                    local selected = fetal
                    fetuses[#fetuses + 1] = { getSubType = function() return selected end }
                    fetalSelections[eventIndex][#fetuses] = { subType = fetal.name, breed = fetal.breed, sex = fetal.gender }
                end
                conception, animal.isPregnant = e.atMonths, true
                animal.pregnancy = { pregnancies = fetuses, duration = history.durationMonths }
            elseif e.kind == "CALVING" then
                -- Remove the existing pregnancy ledger once; tissue and reserve do not change.
                animal.weight = animal.weight - (state.gravidKg or 0)
                state.weightKg, state.gravidKg, state.lactationMonths = animal.weight, 0, 0
                conception, animal.isPregnant, animal.pregnancy, animal.reproduction = nil, false, nil, 0
                animal.isParent, animal.birthCount, lastBirth = true, e.parity, time
            end
            eventIndex = eventIndex + 1
        end
        animal.reproduction = conception ~= nil and 100 * (time - conception) / history.durationMonths or 0
        -- At each endpoint align fetal mass with the same physiological rule as live growth.
        local gravid = RLGrowth.getGravidTarget(animal)
        animal.weight = animal.weight + gravid - (state.gravidKg or 0)
        state.weightKg, state.gravidKg = animal.weight, gravid
        refreshMilk(animal, lastBirth, time)
        if not validState(animal, time) then return reject("HISTORY_STATE", time) end
        if time >= targetAge - 1e-10 then break end
        local days = type(options.daysPerMonth) == "table" and options.daysPerMonth[animal.age + 1] or options.daysPerMonth
        if not finite(days) or days < 1 or days > 31 or days ~= math.floor(days) then return reject("MONTH_LENGTH", time) end
        while boundaries[boundaryIndex] ~= nil and boundaries[boundaryIndex] <= time + 1e-10 do boundaryIndex = boundaryIndex + 1 end
        local hour = math.floor((time - animal.age) * 24 * days + 1e-8) + 1
        local finish = math.min(animal.age + hour / (24 * days), boundaries[boundaryIndex] or targetAge, targetAge)
        local dt = finish - time
        local feed, feedReason = R.planFeed(animal, recipe, dt)
        if feed == nil then return reject(feedReason, time) end
        if not finite(feed.me) or feed.me < 0 or not finite(feed.kg) or feed.kg < 0
            or not finite(feed.cp) or feed.cp < 0 or not finite(feed.proteinFactor)
            or feed.proteinFactor < 0 or feed.proteinFactor > 1 then return reject("FEED_RESULT", time) end
        local beforeBody = animal.weight - (state.gravidKg or 0)
        local result, input, before = RLGrowth.advanceHistoricalBudget(animal, { feed = feed }, dt)
        if result == nil then return reject(input or "HISTORY_RESULT", time) end
        local energy = math.abs((result.supplyNU or 0) + (result.mobilizedNU or 0) + (result.catabolismNU or 0)
            - (result.paidNU or 0) - (result.depositNU or 0) - (result.lostNU or 0))
        local mass = math.abs(result.weight - beforeBody - result.frameGainKg - result.growthReserveKg
            - result.depositKg + result.mobilizedKg + result.catabolismKg)
        if not finite(energy) or not finite(mass) or not finite(result.weight) or energy > 1e-6 or mass > 1e-6 then
            return reject("HISTORY_RESULT", time)
        end
        ledger.maxEnergyError, ledger.maxMassError = math.max(ledger.maxEnergyError, energy), math.max(ledger.maxMassError, mass)
        ledger.feedMe = ledger.feedMe + feed.me
        ledger.milkLiters = ledger.milkLiters + (input.potentialMilk or 0) * dt * (result.milkFraction or 0)
        RLFeed.afterStep(animal, state, feed, result, beforeBody, dt)
        RLFeed.applyHealth(animal, feed, result, dt)
        RLFeed.applyUnderweight(animal, dt)
        if animal.health < minHealth then return reject("HEALTH", finish) end
        time, steps = finish, steps + 1
        if steps > 100000 then return reject("STEP_LIMIT", time) end
    end
    state.lastTick = nil
    if animal.bodyCondition ~= nil then animal.bodyCondition.lastTick = nil end
    return { version = R.VERSION, recipe = recipe, animal = animal, state = snapshot(animal),
        conceptionSnapshots = snapshots, steps = steps, ledger = ledger, history = copy(history),
        fetalSelections = fetalSelections,
        observedSourceEvents = previous ~= nil and copy(previous.observedSourceEvents) or nil,
        sourceBirthBoundary = sourceBoundary and { version = 1, atAgeMonths = time, conceptionMonths = conception } or nil,
        session = { version = 1, timeMonths = time, lastBirthMonths = lastBirth,
            conceptionMonths = conception, nextEventIndex = eventIndex },
        advancedSteps = steps - initialSteps,
        eligibility = "UNSCREENED" }
end

function R.run(seed, history, options)
    return replay(seed, history, options)
end

-- Copy-on-success progression from the existing birth ledger. A failed update cannot
-- overwrite the source record, and a resume never replays birth or earlier feeding.
local function resume(previous, targetAge, options, sourceBoundary)
    if type(previous) ~= "table" or previous.version ~= R.VERSION or type(previous.animal) ~= "table"
        or type(previous.state) ~= "table" or not validState(previous.animal, previous.state.ageMonths)
        or previous.state.weightKg ~= previous.animal.weight or not validateHistory(previous.history)
        or type(previous.conceptionSnapshots) ~= "table" or type(previous.fetalSelections) ~= "table"
        or type(previous.ledger) ~= "table" or not finite(previous.ledger.feedMe)
        or not finite(previous.ledger.milkLiters) or not finite(previous.ledger.maxMassError)
        or not finite(previous.ledger.maxEnergyError) or type(previous.recipe) ~= "table"
        or previous.recipe.version ~= R.RECIPE_VERSION or previous.recipe.id ~= previous.history.template.id
        or not finite(previous.steps) or previous.steps < 0 or previous.steps % 1 ~= 0
        or type(previous.animal.getSubType) ~= "function" or previous.animal.rlHistoryReplay ~= true then
        return nil, { reason = "SOURCE_STATE" }
    end
    local animal = previous.animal
    return replay({ subType = animal:getSubType(), subTypeIndex = animal.subTypeIndex,
        genetics = animal.genetics, geneticsScreened = true, diseases = animal.diseases,
        health = animal.health, isCastrated = animal.isCastrated }, previous.history, options, previous, targetAge, sourceBoundary)
end

function R.resume(previous, targetAge, options) return resume(previous, targetAge, options, false) end

-- Only the source birth service may consume this exact endpoint. It is deliberately
-- not a portable/listable record: reproduction is 100 until actual births commit.
function R.runToSourceBirth(previous, dueAgeMonths, options) return resume(previous, dueAgeMonths, options, true) end

-- Unweaned cattle remain closed until a separate calf reserve rule is calibrated.
function R.screen(result)
    if type(result) ~= "table" or type(result.history) ~= "table" or type(result.animal) ~= "table"
        or type(result.state) ~= "table"
        or not validState(result.animal, result.state.ageMonths) then
        return false, "HISTORY_STATE"
    end
    local state = result.animal.rlGrowth
    if state.ageMonths < result.history.weanedAtMonths then return false, "CALF_RESERVE_UNCALIBRATED" end
    local fraction = state.reserveMassKg / state.weightKg
    if fraction < 0.05 or fraction > 0.11 then return false, "RESERVE_FRACTION" end
    return true
end

-- Dormant candidate path: D2 eligibility with its legacy-price-weight check disabled locally,
-- followed by v2 structural readiness. Never constructs Animal.new, IDs or real offspring.
function R.evaluate(seed, history, entry, purpose, context, options)
    if entry == nil or entry.profile == nil or purpose == nil then return nil, { reason = "INVALID_CONTEXT" } end
    if purpose.breedingWeight and (not finite(entry.breedingWeightRatio)
        or entry.breedingWeightRatio <= 0 or entry.breedingWeightRatio > 1) then
        return nil, { reason = "MISSING_BREEDING_RULES" }
    end
    local opts = {}
    for key, value in pairs(options or {}) do opts[key] = value end
    -- Numerical experiments may override gates on run(); verified candidates may not.
    opts.breedingRules = nil
    opts.entry = entry
    opts.minHealth = entry.profile.minHealth
    local result, failure = R.run(seed, history, opts)
    if result == nil then return nil, failure end
    local ok, reason = R.screen(result)
    if not ok then return nil, { reason = reason, atMonths = history.saleAgeMonths } end
    local animal = result.animal
    animal.sale = { source = history.source, parity = animal.birthCount, purpose = purpose.id }
    local policyPurpose = copy(purpose)
    policyPurpose.breedingWeight = false
    local reasons
    ok, reasons = RLDealerStockPolicy.validate(animal, policyPurpose, entry, seed.subType, context)
    if not ok then return nil, { reason = reasons[1], atMonths = history.saleAgeMonths } end
    if purpose.breedingWeight then
        local current = snapshot(animal)
        current.weightKg, current.gravidKg = current.weightKg - (current.gravidKg or 0), 0
        ok, reason = RLDealerHistory.validateConception({ kind = "CONCEPTION", atMonths = current.ageMonths },
            current, R.getBreedingRules(animal, entry))
        if not ok then return nil, { reason = reason, atMonths = history.saleAgeMonths } end
    end
    result.eligibility = "VERIFIED_CANDIDATE"
    return result
end
