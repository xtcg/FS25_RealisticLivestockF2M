--[[
    AnimalHealth.lua
    Health updates, death processing, and the daily death rolls - low health,
    old age, random accidents. The old-age chance is per month and is converted
    to a daily chance at the live days per period; the background accident chance
    is per model month by species and age band (ACCIDENT_BANDS), integrated over
    the model time each day stands for and paying nothing; the low-health chance
    is already daily. An animal under the real-equivalent nutrition mode
    (RLFeed) takes its low-health chance from the risk its steps built up instead
    (rlGrowth lowHealthHazard: the mode's one curve for every gene, per model day),
    taken and cleared at every day change. Animal.lua holds one-liner delegates
    that route here, and must be sourced AFTER this module.

    Serialization and XML load/save stay in Animal.lua: health, isDead and
    numAnimals are initialized in the constructor and serialized as part of the
    MP protocol. deathEnabled and accidentsChance are class-level settings owned
    by RLSettings via Animal.onSettingChanged - read here, never managed here.
]]

AnimalHealth = {}

local Log = RmLogging.getLogger("RLRM")


-- =============================================================================
-- HEALTH FUNCTIONS (delegated from Animal prototype)
-- =============================================================================

--- Get health as a 0.0-1.0 factor.
--- @param animal table Animal instance
--- @return number healthFactor Health divided by 100
function AnimalHealth.getHealthFactor(animal)
    return animal.health / 100
end


--- Update animal health based on food factor relative to subType threshold (in a pen running
--- the real-equivalent nutrition mode, on the hour's budget instead: RLFeed).
--- Food above threshold increases health; below threshold decreases it.
--- Better health genetics slow the loss.
--- Then weight: cattle under the weight model v2 take its step (RLGrowth.step: frame, reserve
--- and development, from birth, every hour) and never an old weight rule; other cattle under the
--- body condition rules take this hour's nutrition budget (RLBodyCondition.step), which moves
--- weight and reserve together; every other animal, and those cattle in an hour without a feed
--- ledger, take the old animal:updateWeight().
--- @param animal table Animal instance
--- @param foodFactor number Food factor (0.0-1.0)
function AnimalHealth.updateHealth(animal, foodFactor)
    -- Real-equivalent nutrition (RLFeed): its pen's model-time steps already settled its budget and
    -- its health from what the budget paid for (RLFeed.runStep) - nothing more this hour.
    if RLFeed ~= nil and RLFeed.runsFor(animal) then return end
    -- A sheep a pen in the mode settled this hour before it moved here: once an hour.
    if RLGrowth.isSettledThisHour(animal) then return end

    -- In a calf rearing pen each animal has its own factor from what it could eat at its age.
    foodFactor = RLCalfRearing.getFoodFactor(animal, foodFactor)
    AnimalHealth.updateHealthOnly(animal, foodFactor)

    if RLGrowth.covers(animal) then
        -- No game hour to count the step in, or a sheep in a pen that does not run the nutrition
        -- mode this hour (a goat in it): the old rule for this hour, to its old target (the next
        -- step takes the weight it leaves as it is).
        if RLGrowth.step(animal, foodFactor) then
            animal:applyUnderweightPenalty()
        else
            animal:updateWeight(foodFactor, RLGrowth.getLegacyTarget(animal:getSubType(), animal.genetics.metabolism))
            RLGrowth.markLegacyHour(animal)
        end
    elseif RLBodyCondition.step(animal) then
        animal:applyUnderweightPenalty()
    else
        animal:updateWeight(foodFactor)
        -- A sheep out of the model this hour (the mode off, its config invalid): marked too.
        RLGrowth.markLegacyHour(animal)
    end
end


--- The health part of updateHealth, without any weight change.
--- @param animal table Animal instance
--- @param foodFactor number Food factor (0.0-1.0)
function AnimalHealth.updateHealthOnly(animal, foodFactor)

    local subType = animal:getSubType()
    local healthThresholdFactor = subType.healthThresholdFactor
    local healthGenetics = animal.genetics.health

    local factor, delta, geneticsTerm, branch

    if healthThresholdFactor < foodFactor then
        factor = (foodFactor - healthThresholdFactor) / (1 - healthThresholdFactor)
        delta = subType.healthIncreaseHour
        geneticsTerm = healthGenetics
        branch = "gain"
    else
        factor = foodFactor / healthThresholdFactor - 1
        delta = subType.healthDecreaseHour
        geneticsTerm = 2 - healthGenetics
        branch = "loss"
    end

    local healthDelta = delta * factor * geneticsTerm
    local healthBefore = animal.health

    if healthDelta ~= 0 then animal.health = math.clamp(math.floor(animal.health + healthDelta), 0, 100) end

    Log:trace("updateHealth: farmId=%s uniqueId=%s typeIndex=%s subType=%s food=%s branch=%s geneticsTerm=%s"
        .. " healthDelta=%s health=%s->%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(animal.animalTypeIndex), tostring(subType.name),
        tostring(foodFactor), tostring(branch), tostring(geneticsTerm), tostring(healthDelta), tostring(healthBefore),
        tostring(animal.health))

end


-- =============================================================================
-- DEATH FUNCTIONS (delegated from Animal prototype)
-- =============================================================================

--- Kill the animal: set dead state, remove from sale/AI systems, add death message,
--- and queue removal from cluster system.
--- @param animal table Animal instance
--- @param reason string|nil Death reason key (e.g. "rl_death_health", "rl_death_age")
function AnimalHealth.die(animal, reason)

    animal.numAnimals = 0
    animal.isDead = true

    Log:debug("Animal died: %s reason=%s", animal.uniqueId or "?", reason or "unknown")

    if animal.sale ~= nil then g_currentMission.animalSystem:removeSaleAnimal(animal.animalTypeIndex, animal.birthday.country, animal.farmId, animal.uniqueId) end
    if animal.isAIAnimal then g_currentMission.animalSystem:removeAIAnimal(animal.animalTypeIndex, animal.birthday.country, animal.farmId, animal.uniqueId) end

    animal:addMessage("DEATH", { reason or "rl_ui_unknownCauses" })

    if animal.clusterSystem ~= nil then animal.clusterSystem:addPendingRemoveCluster(animal) end

end


--- Clamp a death chance to [0, 1]; zero, a negative and NaN read 0, and nothing above 1 reaches the conversion.
--- @param chance number raw chance
--- @return number clamped chance in [0, 1]
local function clampChance(chance)
    if not (chance > 0) then return 0 end
    if chance > 1 then return 1 end
    return chance
end


--- Daily death chance from low health; better health genetics lower it, and under 6 months reads 10 health worse.
--- @param animal table Animal instance
--- @return number chance daily probability in [0, 1]
function AnimalHealth.getLowHealthDailyDeathChance(animal)

    local health = animal.health

    if health >= 80 then
        Log:trace("getLowHealthDailyDeathChance: farmId=%s uniqueId=%s health=%s >= 80, chance 0",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(health))
        return 0
    end

    if animal.age < 6 then health = health - 10 end

    local raw = 0.5 * (1.5 - 0.5 * animal.genetics.health) - health / 100
    local chance = clampChance(raw)

    Log:trace("getLowHealthDailyDeathChance: farmId=%s uniqueId=%s health=%s age=%s genetics=%s raw=%s chance=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(animal.health), tostring(animal.age),
        tostring(animal.genetics.health), tostring(raw), tostring(chance))

    return chance

end


--- Monthly old-age death chance: zero below the type's minimum age, then rising with age, times (2 - health genetics).
--- @param animal table Animal instance
--- @return number chance monthly probability in [0, 1]
function AnimalHealth.getOldAgeMonthlyDeathChance(animal)

    local animalType = animal.animalTypeIndex
    local age = animal.age
    local healthGenetics = animal.genetics.health

    local minAge = 20000
    local maxAge = 30000

    if animalType == AnimalType.COW then
        -- cattle old age min: 15y (180m)
        -- cattle old age max: 20y (240m)
        minAge = 180
        maxAge = 240
    elseif animalType == AnimalType.SHEEP then
        -- sheep old age min: 10y (120m)
        -- sheep old age max: 12y (144m)
        minAge = 120
        maxAge = 144
    elseif animalType == AnimalType.HORSE then
        -- horse old age min: 25y (300m)
        -- horse old age max: 30y (360m)
        minAge = 300
        maxAge = 360
    elseif animalType == AnimalType.PIG then
        -- pig old age min: 15y (180m)
        -- pig old age max: 20y (240m)
        minAge = 180
        maxAge = 240
    elseif animalType == AnimalType.CHICKEN then
        -- chicken old age min: 5y (60m)
        -- chicken old age max: 8y (96m)
        minAge = 60
        maxAge = 96
    end

    if age < minAge then
        Log:trace("getOldAgeMonthlyDeathChance: farmId=%s uniqueId=%s age=%s < minAge=%s, chance 0",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(age), tostring(minAge))
        return 0
    end

    local raw = (0.7 - ((maxAge - age) / 100)) * (2 - healthGenetics)
    local chance = clampChance(raw)

    Log:trace("getOldAgeMonthlyDeathChance: farmId=%s uniqueId=%s age=%s minAge=%s maxAge=%s genetics=%s raw=%s"
        .. " chance=%s", tostring(animal.farmId), tostring(animal.uniqueId), tostring(age), tostring(minAge),
        tostring(maxAge), tostring(healthGenetics), tostring(raw), tostring(chance))

    return chance

end


-- =============================================================================
-- BACKGROUND ACCIDENTS (RL-ACCIDENT-RATE-01)
-- =============================================================================

--- A pig's neonatal accident band ends at 28 days of a 30-day model month.
AnimalHealth.PIG_NEONATAL_MONTHS = 28 / 30

--- Background accident chance a model month by species and age: { below this continuous age in
--- months, chance a model month }, ascending; the last band runs on. The only accident risk an
--- animal has: no cold, disease, water, health or birth factor raises it (those deaths are their
--- own causes), and nothing is paid for the carcass. Game balance starting values (plan
--- 2026-10-17 section 4.1), not real accident statistics. Goats (the SHEEP type) take the sheep
--- bands, water buffalo (the COW type) the cattle ones; a type the mod does not know (a map's
--- own) takes OTHER, the adult small-ruminant / poultry value.
AnimalHealth.ACCIDENT_BANDS = {
    COW = { { 6, 0.0004 }, { math.huge, 0.0002 } },
    PIG = { { AnimalHealth.PIG_NEONATAL_MONTHS, 0.0010 }, { 6, 0.0004 }, { math.huge, 0.0002 } },
    SHEEP = { { 3, 0.0006 }, { math.huge, 0.0003 } },
    HORSE = { { math.huge, 0.0002 } },
    CHICKEN = { { math.huge, 0.0003 } },
    OTHER = { { math.huge, 0.0003 } },
}


--- The accident bands for an animal: its own type, else the type the spec houses.
--- @param animal table Animal instance
--- @param spec table|nil Husbandry or trailer animal spec
--- @return table bands
--- @return string key
function AnimalHealth.getAccidentBands(animal, spec)
    local typeIndex = animal.animalTypeIndex
    if typeIndex == nil and spec ~= nil then typeIndex = spec.animalTypeIndex end
    local key = "OTHER"
    if AnimalType ~= nil and typeIndex ~= nil then
        if typeIndex == AnimalType.COW then key = "COW"
        elseif typeIndex == AnimalType.PIG then key = "PIG"
        elseif typeIndex == AnimalType.SHEEP then key = "SHEEP"
        elseif typeIndex == AnimalType.HORSE then key = "HORSE"
        elseif typeIndex == AnimalType.CHICKEN then key = "CHICKEN" end
    end
    return AnimalHealth.ACCIDENT_BANDS[key], key
end


--- The continuous ages in months the day just ended covered, dtMonths long. With a growth state it
--- ended at the state's clock (moved on by every hour's step, a pig's in an hour on the old rules
--- too, and read after a birthday's whole month, so the last day of a month of age is counted in
--- that month). An animal without a state has only its whole months: the day is taken from the
--- start of the whole month of age it is in (at one day a month, the month it has just turned).
--- Never before birth.
--- @param animal table Animal instance
--- @param dtMonths number Model months the day stood for (1 / days per month)
--- @return number fromMonths
--- @return number toMonths
function AnimalHealth.getAccidentAgeSpan(animal, dtMonths)
    local state = animal.rlGrowth
    local from
    if state ~= nil and state.ageMonths ~= nil and RLGrowth ~= nil and RLGrowth.getContinuousAge ~= nil then
        from = RLGrowth.getContinuousAge(animal) - dtMonths
    else
        from = animal.age or 0
    end
    from = math.max(0, from)
    return from, from + dtMonths
end


--- Accident hazard over an age span: -ln(1 - pMonth) for each model month spent in each band,
--- times the accidents setting. 0 for a span of no length or a multiplier not above 0.
--- @param bands table AnimalHealth.ACCIDENT_BANDS entry
--- @param fromMonths number
--- @param toMonths number
--- @param multiplier number The accidents setting (1 = as configured)
--- @return number hazard
function AnimalHealth.getAccidentHazard(bands, fromMonths, toMonths, multiplier)
    if bands == nil or not (multiplier > 0) or not (toMonths > fromMonths) then return 0 end
    local hazard, lower = 0, 0
    for _, band in ipairs(bands) do
        local upper, pMonth = band[1], band[2]
        local a, b = math.max(fromMonths, lower), math.min(toMonths, upper)
        if b > a and pMonth > 0 then
            hazard = hazard + (pMonth >= 1 and math.huge or -math.log(1 - pMonth)) * (b - a)
        end
        lower = upper
        if lower >= toMonths then break end
    end
    return hazard * multiplier
end


--- The chance a model month of an accident at the animal's present age band, before the accidents
--- setting (for display and logs; the day's draw integrates the bands it spans).
--- @param animal table Animal instance
--- @param spec table|nil Husbandry animal spec
--- @return number chance monthly probability in [0, 1]
function AnimalHealth.getAccidentMonthlyDeathChance(animal, spec)
    local bands = AnimalHealth.getAccidentBands(animal, spec)
    local age = select(2, AnimalHealth.getAccidentAgeSpan(animal, 0))
    for _, band in ipairs(bands) do
        if age < band[1] then return band[2] end
    end
    return bands[#bands][2]
end


--- The chance of a background accident on the day just ended: 1 - exp(-H), H the hazard of the
--- model time the day stood for (1 / days per month of a model month) across the age bands it
--- spans, times the accidents setting (nil reads 1).
--- @param animal table Animal instance
--- @param spec table|nil Husbandry or trailer animal spec
--- @param daysPerPeriod number days per month, 1..28
--- @return number chance
--- @return number hazard
--- @return number fromMonths
--- @return number toMonths
--- @return string bands key
--- @return number multiplier
function AnimalHealth.getAccidentDayChance(animal, spec, daysPerPeriod)
    local multiplier = animal.accidentsChance
    if multiplier == nil then multiplier = 1 end
    local dtMonths = 1 / math.max(daysPerPeriod or 1, 1)
    local bands, key = AnimalHealth.getAccidentBands(animal, spec)
    local from, to = AnimalHealth.getAccidentAgeSpan(animal, dtMonths)
    local hazard = AnimalHealth.getAccidentHazard(bands, from, to, multiplier)
    local chance = hazard > 0 and 1 - math.exp(-hazard) or 0
    return chance, hazard, from, to, key, multiplier
end


--- One death's record line: identity, model time, cause, chance and money.
--- @param animal table Animal instance
--- @param cause string Death reason key
--- @param chance number The chance that was drawn against
--- @param money number Money the death paid (0: none)
--- @param detail string|nil Cause-specific fields
local function logDeath(animal, cause, chance, money, detail)
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local state = animal.rlGrowth
    Log:info("DEATH: cause=%s farmId=%s uniqueId=%s country=%s type=%s subType=%s age=%s ageMonths=%s monotonicDay=%s"
        .. " hour=%s daysPerPeriod=%s chance=%s money=%s%s",
        tostring(cause), tostring(animal.farmId), tostring(animal.uniqueId),
        tostring(animal.birthday ~= nil and animal.birthday.country or nil), tostring(animal.animalTypeIndex),
        tostring(animal.subType), tostring(animal.age), tostring(state ~= nil and state.ageMonths or nil),
        tostring(env ~= nil and env.currentMonotonicDay or nil), tostring(env ~= nil and env.currentHour or nil),
        tostring(env ~= nil and env.daysPerPeriod or nil), tostring(chance), tostring(money or 0),
        detail ~= nil and (" " .. detail) or "")
end


--- Take the low-health risk the real-equivalent nutrition mode's steps built up since the last day
--- change (RLFeed.addDeathRisk) and clear it: drawn once, whatever happens to the draw (death off,
--- an unowned pen, a client). nil when no step of the mode ran since.
--- @param animal table Animal instance
--- @return number|nil hazard
function AnimalHealth.takeLowHealthHazard(animal)
    local state = animal.rlGrowth
    local hazard = state ~= nil and state.lowHealthHazard or nil
    if state ~= nil then state.lowHealthHazard = nil end
    return hazard
end


--- Roll the daily low-health death; no draw is spent when the chance is not above 0. With a hazard
--- (an animal the real-equivalent nutrition mode stepped since the last day change) the chance is
--- the one it stands for, not the old rule's.
--- @param animal table Animal instance
--- @param hazard number|nil AnimalHealth.takeLowHealthHazard's
--- @return number died 1 if the animal died, 0 otherwise
function AnimalHealth.calculateLowHealthDailyAnimalDeaths(animal, hazard)

    if animal.numAnimals <= 0 or animal.isDead then
        Log:trace("calculateLowHealth: skipped (dead=%s numAnimals=%d)",
            tostring(animal.isDead), animal.numAnimals or 0)
        return 0
    end

    local chance
    if hazard ~= nil then
        chance = RLFeedMath.getHazardChance(hazard)
    else
        chance = AnimalHealth.getLowHealthDailyDeathChance(animal)
    end

    if not (chance > 0) then
        Log:trace("calculateLowHealth: farmId=%s uniqueId=%s chance=%s, no draw",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(chance))
        return 0
    end

    local draw = math.random()

    Log:trace("calculateLowHealth: farmId=%s uniqueId=%s hazard=%s chance=%s draw=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(hazard), tostring(chance), tostring(draw))

    if draw < chance then
        animal:die("rl_death_health")
        logDeath(animal, "rl_death_health", chance, 0, string.format("health=%s hazard=%s", tostring(animal.health), tostring(hazard)))
        return 1
    end

    return 0

end


--- Roll the old-age death: the monthly chance converted to a daily one; no draw when it is not above 0.
--- @param animal table Animal instance
--- @param daysPerPeriod number days per month, 1..28
--- @return number died 1 if the animal died, 0 otherwise
function AnimalHealth.calculateOldAgeMonthlyAnimalDeaths(animal, daysPerPeriod)

    if animal.numAnimals <= 0 or animal.isDead then
        Log:trace("calculateOldAge: skipped (dead=%s numAnimals=%d)",
            tostring(animal.isDead), animal.numAnimals or 0)
        return 0
    end

    local monthly = AnimalHealth.getOldAgeMonthlyDeathChance(animal)

    if not (monthly > 0) then
        Log:trace("calculateOldAge: farmId=%s uniqueId=%s monthly=%s, no draw",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(monthly))
        return 0
    end

    local daily = RLDiseaseRates.perTick(monthly, daysPerPeriod)
    local draw = math.random()

    Log:trace("calculateOldAge: farmId=%s uniqueId=%s monthly=%s daily=%s daysPerPeriod=%s draw=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(monthly), tostring(daily),
        tostring(daysPerPeriod), tostring(draw))

    if draw < daily then
        animal:die("rl_death_age")
        logDeath(animal, "rl_death_age", daily, 0, string.format("monthly=%s", tostring(monthly)))
        return 1
    end

    return 0

end


--- Roll the background accident death for the day just ended: the hazard of the model time it
--- stood for (1 / days per month of a model month, split across the age bands it spans) times the
--- accidents setting, drawn once (RLDiseaseRates.perTick's conversion when the day lies in one
--- band at the setting 1). No draw at all when the chance is not above 0 (the setting at 0). An
--- accident pays nothing (RL-DEATH-CASH-01): the money return stays for the callers, always 0.
--- @param animal table Animal instance
--- @param spec table Husbandry or trailer animal spec
--- @param daysPerPeriod number days per month, 1..28
--- @return number deaths 1 if animal died, 0 otherwise
--- @return number money always 0
function AnimalHealth.calculateRandomMonthlyAnimalDeaths(animal, spec, daysPerPeriod)

    if animal.numAnimals <= 0 or animal.isDead then
        Log:trace("calculateRandom: skipped (dead=%s numAnimals=%d)",
            tostring(animal.isDead), animal.numAnimals or 0)
        return 0, 0
    end

    local chance, hazard, from, to, key, multiplier = AnimalHealth.getAccidentDayChance(animal, spec, daysPerPeriod)

    if not (chance > 0) then
        Log:trace("calculateRandom: farmId=%s uniqueId=%s multiplier=%s chance=%s, no draw",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(multiplier), tostring(chance))
        return 0, 0
    end

    local draw = math.random()

    Log:trace("calculateRandom: farmId=%s uniqueId=%s bands=%s ageMonths=%.4f..%.4f multiplier=%s hazard=%s"
        .. " chance=%s daysPerPeriod=%s draw=%s", tostring(animal.farmId), tostring(animal.uniqueId), key, from, to,
        tostring(multiplier), tostring(hazard), tostring(chance), tostring(daysPerPeriod), tostring(draw))

    if draw < chance then
        animal:die("rl_death_accident")
        logDeath(animal, "rl_death_accident", chance, 0,
            string.format("bands=%s span=%.4f..%.4f multiplier=%s", key, from, to, tostring(multiplier)))
        return 1, 0
    end

    return 0, 0

end


-- =============================================================================
-- DAILY EVALUATION (consolidation of death evaluation block from onDayChanged)
-- =============================================================================

--- Evaluate all death pathways for an animal during daily update.
--- Consolidates the death evaluation block from Animal:onDayChanged, including
--- server/deathEnabled guards and AnimalDeathEvent broadcast.
--- Sequential short-circuit: lowHealth -> oldAge (if alive) -> random (if alive and spec).
--- @param animal table Animal instance
--- @param spec table|nil Husbandry animal spec (nil for sale animals)
--- @param daysPerPeriod number days per month, 1..28, for the old-age and accident conversion
--- @return number lowHealthDeath 1 if died from low health, 0 otherwise
--- @return number oldDeath 1 if died from old age, 0 otherwise
--- @return number randomDeath 1 if died from random accident, 0 otherwise
--- @return number randomDeathMoney always 0 (an accident pays nothing)
function AnimalHealth.evaluateDaily(animal, spec, daysPerPeriod)

    -- Taken before any skip: risk never waits for a later day (death switched on, the pen owned).
    local hazard = AnimalHealth.takeLowHealthHazard(animal)

    if not animal.deathEnabled or g_server == nil then
        Log:trace("evaluateDaily: skipped (deathEnabled=%s server=%s)",
            tostring(animal.deathEnabled), tostring(g_server ~= nil))
        return 0, 0, 0, 0
    end

    if animal.clusterSystem ~= nil and animal.clusterSystem.owner:getOwnerFarmId() == FarmManager.INVALID_FARM_ID then
        Log:trace("evaluateDaily: skipped (invalid farm)")
        return 0, 0, 0, 0
    end

    local lowHealthDeath = animal:calculateLowHealthDailyAnimalDeaths(hazard)

    local oldDeath = 0
    if lowHealthDeath == 0 then
        oldDeath = animal:calculateOldAgeMonthlyAnimalDeaths(daysPerPeriod)
    end

    local randomDeath, randomDeathMoney = 0, 0
    if spec ~= nil and lowHealthDeath == 0 and oldDeath == 0 then
        randomDeath, randomDeathMoney = animal:calculateRandomMonthlyAnimalDeaths(spec, daysPerPeriod)
    end

    if lowHealthDeath > 0 or oldDeath > 0 or randomDeath > 0 then
        Log:debug("evaluateDaily: death occurred for %s (low=%d old=%d random=%d money=%.2f)",
            animal.uniqueId or "?", lowHealthDeath, oldDeath, randomDeath, randomDeathMoney)
        g_server:broadcastEvent(AnimalDeathEvent.new(
            animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil, animal))
    end

    return lowHealthDeath, oldDeath, randomDeath, randomDeathMoney

end
