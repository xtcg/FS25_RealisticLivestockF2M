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
    model v2 and every calf still on milk outside a calf rearing pen has its nursing dam there
    (her milk is shared with her calves, RLFeed.settleDamMilk). Any other cattle pen keeps the old
    rules as a whole for that hour; RLFeed.getPenState says why. One pen, one hour, one set of
    rules: never old energy with new liters.

    Feeding (server, per pen). RLFeed.beginFeeding decides; the engine's own feeding then asks
    AnimalFoodSystem:consumeFood, which in a pen running the mode runs RLFeed.consume: the pen's
    model clock gives the hour's steps of stepDays, and each step plans (RLFeedRationPlanner),
    removes its liters from the trough and settles every animal (RLFeed.runStep). RLFeed.endFeeding
    writes each animal's record of the hour (animal.rlFeedIntake: what it ate over the hour's steps)
    and adds the hour to the pen's month. An animal moved in after its pen's steps waits for the next.

    Step. RLGrowth.stepFeed values an animal's step at the ME it ate (supplyPerPeriod), in ME units
    (RLFeedMath.getEnergyConfig), with protein limiting growth and milk.

    Health. Each step settles the budget and then takes health from it (RLFeed.applyHealth;
    AnimalHealth.updateHealth leaves these animals alone) instead of the old food-factor threshold
    and the 60%-of-curve rule: up while feed pays for maintenance, unchanged while the reserve buffers, down by
    the share left to frame breakdown or unpaid; only an animal below extremeUnderweightRatio of its
    curve loses health for its weight alone. Both at per-model-day rates (feedProfiles.xml health),
    the same at any month length; health keeps its fractions. The health gene moves the rates only
    (geneticsRateEffect). Each step also adds its low-health death risk (lowHealthDeath, one curve
    for every gene) to the animal's counter, drawn once at the day change (AnimalHealth).

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
--- Grains cattle troughs take, in the order AUTO takes them (the capped ones last: grain grist, a
--- proxy that may be all wheat, then wheat).
RLFeed.GRAINS = { "MAIZE", "BARLEY", "OAT", "GRAINGRIST", "WHEAT" }
--- Other concentrates cattle troughs take with the grains (a protein feed: a calf's starter with
--- the ration's forage), after them in AUTO's order.
RLFeed.SUPPLEMENTS = { "PEA" }
--- Highest concentrate share target a pen may set (nil: as much as the ration rules allow).
RLFeed.MAX_SHARE = 0.8

RLFeed.DEFAULT_RATION = { target = "AUTO", grain = "AUTO", share = nil, substitute = true }

RLFeed.STATE_VERSION = 1

-- Published (with the pen) when a pen's ration settings change, on the server and on every client
-- the server's answer reaches: an open menu shows them.
if MessageType ~= nil and nextMessageTypeId ~= nil and MessageType.RL_FEED_RATION_CHANGED == nil then
    MessageType.RL_FEED_RATION_CHANGED = nextMessageTypeId()
end

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


--- The feed config (subject: an animal or pen reads its species section, sheep; cattle and
--- anything without one read the root).
function RLFeed.getConfig(subject)
    if subject == nil then return RLFeedProfiles.getConfig() end
    return RLFeedProfiles.getConfigFor(subject)
end


local energyCache = setmetatable({}, { __mode = "k" })

--- The budget step's config in ME for a subject's species (cached per pair of config tables).
function RLFeed.getEnergyConfig(subject)
    local body, feed = RLBodyCondition.getConfig(subject), RLFeed.getConfig(subject)
    local byBody = energyCache[feed]
    if byBody == nil then
        byBody = setmetatable({}, { __mode = "k" })
        energyCache[feed] = byBody
    end
    local cfg = byBody[body]
    if cfg == nil then
        cfg = RLFeedMath.getEnergyConfig(body, feed)
        byBody[body] = cfg
    end
    return cfg
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
        -- A share sent as a 32-bit float (0.8 arrives as 0.8000000119) is the share meant.
        if share ~= nil and share == share and share >= 0 and share <= RLFeed.MAX_SHARE + 1e-6 then
            out.share = math.min(share, RLFeed.MAX_SHARE)
        else
            ok = false
        end
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
    if g_messageCenter ~= nil and MessageType ~= nil and MessageType.RL_FEED_RATION_CHANGED ~= nil then
        g_messageCenter:publish(MessageType.RL_FEED_RATION_CHANGED, placeable)
    end
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


local function getOwner(animal)
    return animal ~= nil and animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil
end


--- The nursing rules of a subject's species (feedProfiles.xml species nursing: sheep raise their
--- young at foot only), nil for cattle and anything without.
--- @param subject table An animal or a pen
--- @return table|nil
function RLFeed.getNursing(subject)
    return RLFeed.getConfig(subject).nursing
end
local getNursing = RLFeed.getNursing


--- Whether a young animal was weaned early (nursing rules): kept on its state once it was
--- (RLFeed.afterStep), so a later shortage or a move back to its dam never puts it on milk again.
local function isWeanedEarly(animal)
    local state = animal.rlGrowth
    return state ~= nil and state.weanedEarly == true
end


--- An animal's age for the feeding curves: continuous under the weight model v2, else whole months.
local function getFeedAge(animal)
    if RLGrowth ~= nil and RLGrowth.covers(animal) then return RLGrowth.getContinuousAge(animal) end
    return animal.age or 0
end


--- A young animal's milk cap by its age alone (nursing rules), before any orphan rule.
--- @param animal table
--- @param ageOffsetMonths number|nil
--- @return number 0..1 (0 without nursing rules)
function RLFeed.getNursingMilkMax(animal, ageOffsetMonths)
    local nursing = getNursing(animal)
    if nursing == nil then return 0 end
    return math.clamp(RLFeedProfiles.interpolate(nursing.curves.milkMax, getFeedAge(animal) + (ageOffsetMonths or 0)), 0, 1)
end


--- The cows in a pen that can nurse a calf (RLFeed.getNursingDams of its animals), kept for the
--- hour; `fresh` works them out again (a pen's evaluation and step do, so the hour's own changes
--- count there). Also, for a species with nursing rules, each dam's young on milk here
--- (suckling: dam -> { count, age }).
local function getPenDams(owner, fresh)
    local tick = RLBodyCondition ~= nil and RLBodyCondition.getTickId() or nil
    local cache = owner.rlFeedNursingDams
    if fresh or cache == nil or tick == nil or cache.tick ~= tick then
        local dams, suckling = RLFeed.getNursingDams(owner.getClusters ~= nil and owner:getClusters() or {})
        cache = { tick = tick, dams = dams, suckling = suckling }
        owner.rlFeedNursingDams = cache
    end
    return cache.dams, cache.suckling or {}
end


--- Whether an animal nurses young here this hour (a species with nursing rules: a ewe whose lambs
--- on milk are in her pen).
function RLFeed.isNursingDam(animal)
    local owner = getOwner(animal)
    if owner == nil or animal.getIdentifiers == nil or getNursing(animal) == nil then return false end
    return getPenDams(owner)[animal:getIdentifiers()] == animal
end


--- A nursing dam's milk at full feed now (real kg a day, as drunk; nursing lactation rows: her
--- system, single or twin by the young she suckles here - more share the twin row - in the month
--- of her youngest's age), the young she suckles and their age. 0 when she suckles none.
--- @param animal table
--- @return number kgPerDay
--- @return number suckled
--- @return number|nil youngAgeMonths
function RLFeed.getDamMilk(animal)
    local nursing = getNursing(animal)
    local owner = getOwner(animal)
    if nursing == nil or owner == nil then return 0, 0, nil end
    local _, suckling = getPenDams(owner)
    local info = suckling[animal]
    if info == nil or info.count <= 0 then return 0, 0, nil end
    local lactation = nursing.lactation
    local subType = animal.getSubType ~= nil and animal:getSubType() or nil
    local breed = subType ~= nil and subType.breed ~= nil and subType.breed:upper() or nil
    local system = lactation.systems[(breed ~= nil and lactation.breeds[breed]) or lactation.default]
    local row = info.count >= 2 and system.twin or system.single
    local month = math.max(math.floor(info.age) + 1, 1)
    if month > #row then return 0, info.count, info.age end
    return row[month], info.count, info.age
end


--- Share of her milk a nursing dam may fund from her reserve: the weight model's early-lactation
--- rule on her young's age (cattle: on her months since calving, RLGrowth.getMilkMobilizeShare).
function RLFeed.getDamMobilizeShare(animal, youngAge)
    local base = RLBodyCondition.getConfig(animal).milkMobilizeShare
    local s = RLGrowth.getSettings(animal)
    local early = math.max(1 - (youngAge or 0) / s.earlyMilkMobilizeMonths, 0)
    return base + math.max(s.earlyMilkMobilizeShare - base, 0) * early
end


--- Whether a calf still of an age for milk is weaned early: outside a calf rearing pen, with no
--- dam there that can nurse it (sold, dead, in another pen, dry), and at least calfMilk
--- earlyWeaningMonth old (3: a calf takes to solid feed from about 2-3 months, so an orphan is
--- weaned early rather than kept on milk). It then lives on solid feed as any weaned animal. A
--- younger one without its dam still needs milk: its pen keeps the old rules (SUCKLING_CALF) until
--- it is in a calf rearing pen, back with its dam, or old enough.
--- @param animal table
--- @return boolean
function RLFeed.isEarlyWeaned(animal)
    local owner = getOwner(animal)
    local nursing = getNursing(animal)
    if nursing ~= nil then
        -- Nursing rules (sheep): once weaned early, weaned for good (its state keeps it). Else an
        -- orphan from earlyWeaningMonth once it has eaten creep feed in earnest, readyCreepKgPerDay
        -- as fed for readyDays model days in a row (AHDB: 250 g a head a day for 3-4 days); age
        -- alone, or grass, does not make it ready. A lamb with its dam suckles to weaningMonth.
        if isWeanedEarly(animal) then return true end
        if owner == nil or getFeedAge(animal) < nursing.earlyWeaningMonth then return false end
        if animal.motherId ~= nil and getPenDams(owner)[animal.motherId] ~= nil then return false end
        local state = animal.rlGrowth
        return state ~= nil and (state.creepDays or 0) >= nursing.readyDays - 1e-9
    end
    if owner == nil or isRearingPen(owner) then return false end
    local age = (RLGrowth ~= nil and RLGrowth.covers(animal)) and RLGrowth.getContinuousAge(animal) or (animal.age or 0)
    if age < RLFeed.getConfig(animal).calfMilk.earlyWeaningMonth then return false end
    return animal.motherId == nil or getPenDams(owner)[animal.motherId] == nil
end


--- A calf's milk and solid caps (RLCalfRearing), with the calf still on milk when milkMax > 0;
--- a calf weaned early (RLFeed.isEarlyWeaned) is weaned: 0, 1.
--- With calf rearing switched off a young calf still suckles: the default weaning curves say how
--- long, so a pen holding one is never taken for a pen of weaned cattle.
local function getCalfCaps(animal, ageOffsetMonths)
    -- A monogastric species (pigs) has no calf rules: a pen with a young animal not yet weaned
    -- keeps the old rules (RLFeed.evaluatePen, PIG_BREEDING_LEGACY), so every animal it feeds is weaned.
    if RLFeed.getConfig(animal).monogastric ~= nil then return 0, 1 end
    local nursing = getNursing(animal)
    if nursing ~= nil then
        -- Nursing rules (sheep): the species' curves at its age; an orphan ready for it is weaned.
        local age = getFeedAge(animal) + (ageOffsetMonths or 0)
        local milkMax = math.clamp(RLFeedProfiles.interpolate(nursing.curves.milkMax, age), 0, 1)
        local solidMax = math.clamp(RLFeedProfiles.interpolate(nursing.curves.solidMax, age), 0, 1)
        if milkMax > 0 and RLFeed.isEarlyWeaned(animal) then return 0, 1 end
        return milkMax, solidMax
    end
    if RLCalfRearing == nil then return 0, 1 end
    local milkMax, solidMax
    if RLCalfRearing.isEnabled() then
        milkMax, solidMax = RLCalfRearing.getCaps(animal, ageOffsetMonths)
    else
        local x = (animal.age or 0) + (ageOffsetMonths or 0) - RLCalfRearing.DEFAULTS.weaningMonth
        local curves = RLCalfRearing.DEFAULT_CURVES
        milkMax, solidMax = RLNutritionMath.interpolate(curves.milkMax, x), RLNutritionMath.interpolate(curves.solidMax, x)
    end
    if milkMax > 0 and RLFeed.isEarlyWeaned(animal) then return 0, 1 end
    return milkMax, solidMax
end


--- An animal's feeding stage for the feeds' stages: PRE_WEANING, WEANING or WEANED, read off its
--- milk cap's position on the weaning curve.
local function getFeedStage(animal, milkMax)
    if milkMax <= 0 then return "WEANED" end
    local nursing = getNursing(animal)
    if nursing ~= nil then return getFeedAge(animal) < nursing.weaningMonth - 1 and "PRE_WEANING" or "WEANING" end
    if RLCalfRearing ~= nil and RLCalfRearing.isEnabled() then return RLCalfRearing.getStage(animal) end
    return (animal.age or 0) < RLCalfRearing.DEFAULTS.weaningMonth and "PRE_WEANING" or "WEANING"
end


--- Whether a pen is one the mode can feed: a cattle pen, or a pen of a species with a feed section of
--- its own (sheep), with a trough. For reports and menus; RLFeed.evaluatePen says whether it runs.
function RLFeed.isNutritionPen(placeable)
    if placeable == nil or placeable.spec_husbandryFood == nil or placeable.getAnimalTypeIndex == nil or AnimalType == nil then return false end
    if placeable:getAnimalTypeIndex() == AnimalType.COW then return true end
    return RLFeed.getConfig(placeable) ~= RLFeedProfiles.getConfig()
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
    local nursing
    if typeIndex ~= AnimalType.COW then
        -- Hof Bergmann's MILKCOW is a type of its own: it keeps the old rules (its own capability),
        -- however close its name.
        local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
        local animalType = animalSystem ~= nil and animalSystem.getTypeByIndex ~= nil and animalSystem:getTypeByIndex(typeIndex) or nil
        if animalType ~= nil and animalType.name == "MILKCOW" then return false, "MILKCOW_LEGACY" end
        -- A species with a section of its own (sheep) runs on it; any other type keeps the old rules.
        local section = RLFeed.getConfig(placeable)
        if section == RLFeedProfiles.getConfig() then return false, "NOT_CATTLE" end
        if section.valid ~= true then return false, "CONFIG_INVALID" end
        nursing = section.nursing
        if section.monogastric ~= nil then return RLFeed.evaluateMonogastricPen(placeable, section) end
    end
    if placeable.spec_husbandryFood == nil then return false, "NO_TROUGH" end
    local rearing = nursing == nil and isRearingPen(placeable)
    local clusters = placeable:getClusters() or {}
    -- Who can nurse is worked out afresh for the evaluation (and kept for the hour's calf caps).
    local dams = not rearing and getPenDams(placeable, true) or nil
    for _, animal in ipairs(clusters) do
        if not animal.isDead and (animal.numAnimals or 1) > 0 then
            if not RLGrowth.covers(animal) then return false, "UNCOVERED_ANIMAL" end
            -- Nursing rules: a young animal without its dam has no milk at all and lives on what it
            -- eats (RLFeed.isEarlyWeaned); the pen runs the mode.
            if not rearing and nursing == nil then
                -- A calf on milk drinks from its dam: she must be here, alive and in milk; an
                -- older one without her is weaned early (getCalfCaps).
                local milkMax = getCalfCaps(animal)
                if milkMax > 0 and (animal.motherId == nil or dams[animal.motherId] == nil) then return false, "SUCKLING_CALF" end
            end
        end
    end
    return true, "OK"
end


--- A monogastric pen (pigs): it runs the mode when it has a trough and every animal in it is covered
--- and growing - none younger than youngLegacyUntilMonth (continuous months: not weaned), none
--- pregnant, no female that has given birth. Otherwise the whole pen keeps the old rules
--- (PIG_BREEDING_LEGACY): the sow's milk, pregnancy and body condition are a later batch.
--- @return boolean active
--- @return string reason
function RLFeed.evaluateMonogastricPen(placeable, section)
    if placeable.spec_husbandryFood == nil then return false, "NO_TROUGH" end
    local young = section.monogastric.youngLegacyUntilMonth
    for _, animal in ipairs(placeable:getClusters() or {}) do
        if not animal.isDead and (animal.numAnimals or 1) > 0 then
            if not RLGrowth.covers(animal) then return false, "UNCOVERED_ANIMAL" end
            if animal.isPregnant or (animal.gender == "female" and animal.isParent) or RLGrowth.getContinuousAge(animal) < young then
                return false, "PIG_BREEDING_LEGACY"
            end
        end
    end
    return true, "OK"
end


--- Whether a cow can nurse a calf: alive, lactating and giving milk now (a cow whose milk a disease
--- has stopped cannot).
function RLFeed.canNurse(animal)
    return not animal.isDead and (animal.numAnimals or 1) > 0 and animal.isLactating == true and animal.getIdentifiers ~= nil
        and RLGrowth.getMilkPotential(animal) > 0
end


--- The cows in a list that can nurse a calf (RLFeed.canNurse), by their identifiers. For a
--- species with nursing rules (sheep) a dam nurses while a young animal of hers on milk by its
--- age is in the list; their count and the youngest's age come back too.
--- @param animals table
--- @return table identifiers -> animal
--- @return table suckling dam -> { count, age } (nursing rules only)
function RLFeed.getNursingDams(animals)
    local dams, suckling, byId = {}, {}, nil
    for _, animal in ipairs(animals) do
        if getNursing(animal) == nil then
            if RLFeed.canNurse(animal) then dams[animal:getIdentifiers()] = animal end
        elseif not animal.isDead and (animal.numAnimals or 1) > 0 and animal.getIdentifiers ~= nil then
            byId = byId or {}
            byId[animal:getIdentifiers()] = animal
        end
    end
    if byId == nil then return dams, suckling end
    for _, animal in ipairs(animals) do
        local motherId = animal.motherId
        local dam = motherId ~= nil and byId[motherId] or nil
        if dam ~= nil and dam ~= animal and dam.gender == "female" and not animal.isDead and (animal.numAnimals or 1) > 0
            and RLFeed.getNursingMilkMax(animal) > 0 and not isWeanedEarly(animal) then
            dams[motherId] = dam
            local info = suckling[dam]
            if info == nil then
                info = { count = 0, age = math.huge }
                suckling[dam] = info
            end
            info.count = info.count + 1
            info.age = math.min(info.age, getFeedAge(animal))
        end
    end
    return dams, suckling
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


--- The ration class of an animal: CALF (on milk), LACTATING, DRY (a cow that has calved), GROWING.
function RLFeed.getRationClass(animal)
    if RLFeed.getConfig(animal).monogastric ~= nil then return "GROWING" end
    local milkMax = getCalfCaps(animal)
    if milkMax > 0 then return "CALF" end
    if getNursing(animal) ~= nil then
        -- Nursing rules (sheep): a ewe is in milk while her lambs on milk are with her.
        if RLFeed.isNursingDam(animal) then return "LACTATING" end
        if animal.gender == "female" and animal.isParent then return "DRY" end
        return "GROWING"
    end
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
    if target == "AUTO" and RLFeed.getConfig(animal).monogastric ~= nil then
        -- Pigs: young stock (males, and females under the body condition's youngUntilMonth: gilts)
        -- eat freely, as growing-finishing pigs are fed; an older maiden female grows to her needs.
        if animal.gender == "male" or RLBodyCondition.isYoungStock(animal, RLBodyCondition.getConfig(animal)) then return "FINISH" end
        return "GROW"
    end
    if target == "AUTO" then
        if animal.gender == "male" then return "FINISH" end
        -- A species whose young females are finished too (sheep: ewe lambs, by the body
        -- condition's one rule; a maiden ewe from youngUntilMonth grows as a ewe hogg).
        if RLBodyCondition.isFinishingYoungFemale(animal) then return "FINISH" end
        return "GROW"
    end
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
    local realPerGameLiter, mePerKg = RLFeed.getMilkRealPerGameLiter(animal)
    if realPerGameLiter <= 0 then return 0, 0 end
    return math.max(potentialPerPeriod or 0, 0) * realPerGameLiter / RLFeed.getConfig(animal).realDaysPerPeriod,
        realPerGameLiter * mePerKg
end


--- Real kg of milk a game liter of a cow's milk stands for (the breed's real lactation average over
--- its game curve's mature value x the lactation mean), and the ME a real kg needs.
--- @return number realKgPerGameLiter (0 without a milk curve)
--- @return number meMJPerKg
function RLFeed.getMilkRealPerGameLiter(animal)
    -- Nursing rules (sheep): the dam's milk is counted in real kg from the start (her lactation
    -- rows), never a game liter; the ME a kg costs her is her species' milk meMJPerKg.
    if getNursing(animal) ~= nil then return 1, RLFeed.getConfig(animal).milk.meMJPerKg end
    local subType = animal:getSubType()
    local binding = RLGrowth.getBinding(subType)
    local realKg, mePerKg = RLFeedProfiles.getMilkBridge(binding ~= nil and binding.profile or nil)
    local milkCurve = subType ~= nil and subType.output ~= nil and subType.output.milk or nil
    local mature = milkCurve ~= nil and milkCurve.get ~= nil and milkCurve:get(60) * RLBreedTraits.get(subType, "milkScale") or 0
    local mean = mature * RLBodyCondition.getConfig(animal).lactationMeanFactor
    if mean <= 0 then return 0, mePerKg end
    return realKg * RLFeed.getConfig(animal).realDaysPerPeriod / mean, mePerKg
end


--- A calf's maintenance against the adult value: NRC 2001's milk-fed calf (requirements
--- calfMaintenanceMEPerKgMetabolic: 0.1 Mcal ME/kg^0.75) by the share of milk it may still drink
--- (milkMax halfway through the step), the adult value once weaned (1). The plan and the step's
--- settlement both use it.
--- @param animal table
--- @param dtMonths number|nil
--- @return number factor on maintenance
function RLFeed.getCalfMaintenanceFactor(animal, dtMonths)
    local config = RLFeed.getConfig(animal)
    local physiology = config.physiology
    if physiology ~= nil and physiology.youngMaintenanceMEPerKgMetabolic > 0 then
        -- A species with a young animal's maintenance of its own (sheep: lambs 0.475 MJ per
        -- kg^0.75 against 0.37 for ewes): that value to youngMaintenanceUntilMonth, moving to the
        -- adult one by adultMaintenanceFromMonth, at its age halfway through the step.
        local age = getFeedAge(animal) + 0.5 * (dtMonths or 0)
        local from, to = physiology.youngMaintenanceUntilMonth, physiology.adultMaintenanceFromMonth
        local t = to > from and math.clamp((age - from) / (to - from), 0, 1) or (age >= to and 1 or 0)
        local young = physiology.youngMaintenanceMEPerKgMetabolic
        return (young + (config.requirements.maintenanceMEPerKgMetabolic - young) * t) / config.requirements.maintenanceMEPerKgMetabolic
    end
    local milkMax = getCalfCaps(animal, 0.5 * (dtMonths or 0))
    if milkMax <= 0 then return 1 end
    local calf = config.calf.maintenanceMEPerKgMetabolic / config.requirements.maintenanceMEPerKgMetabolic
    return 1 + (calf - 1) * math.clamp(milkMax, 0, 1)
end


--- ME a kg of an animal's growth costs: the adult cost at its weight; a calf on milk NRC 2001's
--- young calf at its curve's gain (its growth phase, a real day) and its milk cap halfway through
--- the step (RLFeedMath.getCalfGrowthCost). The plan and the step's settlement both use it.
--- @param animal table
--- @param dtMonths number|nil
--- @return number MJ ME per kg
function RLFeed.getGrowthCost(animal, dtMonths)
    local config = RLFeed.getConfig(animal)
    local physiology = config.physiology
    local adult = RLFeedMath.getGrowthCost(animal.weight or 0, config.requirements, physiology ~= nil and physiology.growthReferenceKg or nil)
    if physiology ~= nil then
        -- By sex (species with its own factors, sheep): a ram lamb's gain is leaner, a ewe lamb's fatter.
        local sex = animal.gender ~= "male" and physiology.growthCostFemale
            or (animal.isCastrated and physiology.growthCostCastrate or physiology.growthCostMale)
        adult = adult * sex
    end
    -- A species whose young pay the growth cost of their weight (sheep: calfGrowthCost 0).
    if physiology ~= nil and physiology.calfGrowthCost == 0 then return adult end
    local milkMax = getCalfCaps(animal, 0.5 * (dtMonths or 0))
    if milkMax <= 0 then return adult end
    -- Its curve's gain a real day over the month around its growth phase (from birth: its first month).
    local curve = RLGrowth.getCurve(animal)
    local state = RLGrowth.peekState(animal)
    local phase = state ~= nil and state.developmentMonths or RLGrowth.getContinuousAge(animal)
    local from = math.max(phase - 0.5, 0)
    local gain = curve ~= nil and (curve:value(from + 1) - curve:value(from)) / config.realDaysPerPeriod or 0
    return RLFeedMath.getCalfGrowthCost(animal.weight or 0, gain, milkMax, config.calf, adult)
end


--- A nursing dam's milk in a step input (nursing rules, sheep): her milk at full feed this step
--- (RLFeed.getDamMilk, real kg a day) as the input's potentialMilk per month, x `share` (her water),
--- in milk, with her early-lactation reserve rule. An animal that nurses none gives none.
--- @return number kgPerDay Her milk at full feed (before `share`)
function RLFeed.applyDamMilk(animal, input, config, share)
    local kg, _, youngAge = RLFeed.getDamMilk(animal)
    input.potentialMilk = kg * config.realDaysPerPeriod * (share or 1)
    input.isLactating = input.potentialMilk > 0
    if input.isLactating then input.milkMobilizeShare = RLFeed.getDamMobilizeShare(animal, youngAge) end
    return kg
end


--- The weight model's step input for an animal before it eats, in ME units: its frame, reserve,
--- development, genes, pregnancy and milk at full feed, with the growth cost of its weight and the
--- ME of its milk.
--- @return table input
--- @return table cfg Energy config
local function buildEnergyInput(animal, dtMonths)
    local state = RLGrowth.peekState(animal)
    local input = RLGrowth.buildStepInput(animal, state, 0, 1, dtMonths, true)
    local config = RLFeed.getConfig(animal)
    input.maintenanceFactor = (input.maintenanceFactor or 1) * RLFeed.getCalfMaintenanceFactor(animal, dtMonths)
    input.growthCostPerKg = RLFeed.getGrowthCost(animal, dtMonths)
    if config.nursing ~= nil then RLFeed.applyDamMilk(animal, input, config, 1) end
    local _, mePerLiter = RLFeed.getMilkBridge(animal, input.potentialMilk)
    input.milkCostPerLiter = mePerLiter
    return input, RLFeed.getEnergyConfig(animal)
end


--- One animal as the planner sees it.
--- @param animal table
--- @param ration table Pen ration settings
--- @param dtMonths number
--- @param dtDays number
--- @return table descriptor
function RLFeed.describeAnimal(animal, ration, dtMonths, dtDays)
    local config = RLFeed.getConfig(animal)
    if config.monogastric ~= nil then return RLFeed.describeMonogastricAnimal(animal, ration, dtMonths, dtDays, config) end
    local body = RLBodyCondition.getConfig(animal)
    local class = RLFeed.getRationClass(animal)
    local target = RLFeed.getAnimalTarget(animal, ration, class)
    local input, cfg = buildEnergyInput(animal, dtMonths)
    local _, _, gene = RLGrowth.getGeneFactors(animal.genetics.metabolism, animal)
    local milkKg = 0
    if class == "LACTATING" then milkKg = RLFeed.getMilkBridge(animal, input.potentialMilk) end
    local nursing = config.nursing
    -- A nursing dam (sheep) makes only what her young drink: her milk is never collected.
    local milkCollect = class == "LACTATING" and (nursing ~= nil and 0 or RLBreedTraits.getMilkCollect(animal:getSubType())) or 1
    -- Mid-step caps avoid a larger milk allowance simply because the month has fewer ticks.
    local milkMax, solidMax = getCalfCaps(animal, 0.5 * dtMonths)
    local weaningX
    if nursing ~= nil then
        weaningX = getFeedAge(animal) - nursing.weaningMonth
    else
        weaningX = RLCalfRearing ~= nil and RLCalfRearing.getWeaningX(animal) or 1
    end
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
    -- Cows of a breed that eats more per kg than the Holstein-based equations (Jersey).
    local cowIntake = 1
    if class == "LACTATING" or class == "DRY" then
        local binding = RLGrowth.getBinding(animal:getSubType())
        cowIntake = RLFeedProfiles.getCowIntakeFactor(binding ~= nil and binding.profile or nil)
    end
    local milkLimit, nursingLimit = 0, 0
    if class == "CALF" and nursing ~= nil then
        -- Nursing rules (sheep): no trough milk; at its dam at most lambMilkKgPerDay of her whole
        -- milk x its milkMax (twins share her pool, RLFeed.linkDams).
        nursingLimit = nursing.lambMilkKgPerDay * config.damMilk.dm * milkMax
    elseif class == "CALF" then
        local binding = RLGrowth.getBinding(animal:getSubType())
        -- The reference calf is a Holstein of its sex; a weight profile file without Holstein
        -- leaves the calf at the reference allowance.
        local reference = RLGrowth.getConfig().profiles.HOLSTEIN ~= nil and { profile = "HOLSTEIN", sex = binding.sex } or binding
        milkLimit = RLFeedMath.getCalfMilkLimit(RLGrowth.getBirthMean(binding), RLGrowth.getBirthMean(reference),
            milkMax, config.calfMilk)
        nursingLimit = RLFeedMath.getCalfNursingLimit(RLGrowth.getBirthMean(binding), RLGrowth.getBirthMean(reference),
            milkMax, config.calfMilk, config.damMilk)
    end

    local appetiteCtx = { milkKgPerDay = milkKg, weaningX = weaningX, gene = gene, lactationFactor = RLGrowth.getLactationFactor(animal, state) }
    local appetite = RLFeedMath.getAppetite(weight, class, config.intake, appetiteCtx)
    -- A suckler cow's appetite per kg of milk, for RLFeed.limitSucklerMilk (appetite is linear in milk).
    local appetitePerMilkKg
    if milkCollect < 1 then
        appetiteCtx.milkKgPerDay = milkKg + 1
        appetitePerMilkKg = RLFeedMath.getAppetite(weight, class, config.intake, appetiteCtx) - appetite
    end
    -- Water first: short of it an animal eats less (its dry intake share, RLFeed.getAnimalWater).
    local waterCoverage, water = RLFeed.getAnimalWater(animal, class == "CALF" and milkMax or 0, dtDays)
    cowIntake = cowIntake * water

    return {
        animal = animal, class = class, target = target, stage = getFeedStage(animal, milkMax), milkKgPerDay = milkKg,
        milkCollect = milkCollect, appetitePerMilkKg = appetitePerMilkKg ~= nil and appetitePerMilkKg * cowIntake or nil,
        appetite = appetite * cowIntake,
        -- A calf on milk: what its rumen takes of solids, at its solidMax.
        solidCap = class == "CALF" and solidMax * RLFeedMath.getCalfSolidCapacity(weight, config.intake, weaningX, gene) * water or nil,
        waterCoverage = waterCoverage, waterCap = water,
        fill = RLFeedMath.getFillCapacity(weight, class, config.intake, gene) * cowIntake,
        -- Every animal may eat concentrate its feeding stage allows (a calf: a starter feed).
        concEligible = true,
        adapted = state.feedAdapted or 0,
        milkMax = class == "CALF" and milkMax or 0,
        milkMaxKgPerDay = milkLimit,
        nursingMaxKgPerDay = nursingLimit,
        solidMax = solidMax,
        solidEnergy = class == "CALF" and (nursing ~= nil
            and math.clamp(RLFeedProfiles.interpolate(nursing.curves.solidEnergy, getFeedAge(animal) + 0.5 * dtMonths), 0, 1)
            or RLCalfRearing.getSolidEnergyFactor(animal)) or 1,
        -- A young animal at foot eats at most creepMaxKgDMPerDay of concentrate (nursing rules).
        concMaxKgPerDay = class == "CALF" and nursing ~= nil and nursing.creepMaxKgDMPerDay or nil,
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


--- One pig as the monogastric planner sees it (NRC 2012 ch. 8): what it can physically eat
--- (appetite, kg DM a day) and, eaten freely, its energy appetite by sex (energyCap, MJ a day),
--- both at its weight halfway through the step and x its maintenance gene; its needs as any
--- animal's (maintenance at W^0.60, its curve's growth, the reserve it may lay down); its SID lysine
--- need (g per MJ ME) by weight and sex.
function RLFeed.describeMonogastricAnimal(animal, ration, dtMonths, dtDays, config)
    local mono = config.monogastric
    local body = RLBodyCondition.getConfig(animal)
    local class = "GROWING"
    local target = RLFeed.getAnimalTarget(animal, ration, class)
    local input, cfg = buildEnergyInput(animal, dtMonths)
    local _, _, gene = RLGrowth.getGeneFactors(animal.genetics.metabolism, animal)
    if target == "GROW" then
        input.reserveCeiling = math.min(RLBodyCondition.getReserveCeiling(animal) or body.referenceReserve, body.referenceReserve)
    end
    local demands = RLGrowthMath.getStepDemands(input, cfg)
    local days = config.realDaysPerPeriod
    local weight = math.max(animal.weight or 0, 0) + 0.5 * (demands.growthKg or 0)
    local sex = RLFeedMath.getMonoSex(animal.gender, animal.isCastrated)
    local waterCoverage, water = RLFeed.getAnimalWater(animal, 0, dtDays)
    return {
        animal = animal, class = class, target = target, stage = "WEANED", milkKgPerDay = 0, milkCollect = 1,
        weight = weight, sex = sex, waterCoverage = waterCoverage, waterCap = water,
        appetite = RLFeedMath.getMonoPhysicalCap(weight, mono) * gene * water,
        energyCap = RLFeedMath.getMonoEnergyIntake(weight, sex, mono) * gene * water,
        fill = 0, concEligible = false, adapted = 1, milkMax = 0, milkMaxKgPerDay = 0, nursingMaxKgPerDay = 0,
        solidMax = 1, solidEnergy = 1,
        proteinNeed = RLFeedMath.getLysineNeed(weight, sex, mono),
        needs = {
            maintenance = demands.maintenance / days,
            pregnancy = demands.pregnancy / days,
            milk = 0,
            growth = target == "MAINTAIN" and 0 or demands.growthStep / dtDays,
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
    local config = RLFeed.getConfig(placeable)
    if config.monogastric ~= nil then return RLFeed.getMonogastricStock(placeable, config) end
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


--- A monogastric pen's stock (pigs): every fill type its animal food groups list that the section
--- values (its own feeds first), in the groups' order, as one list for the planner.
--- @return table feeds, table concentrate (empty), table milk (empty), table unconfigured names with stock
function RLFeed.getMonogastricStock(placeable, config)
    local spec = placeable.spec_husbandryFood
    local foodSystem = g_currentMission.animalFoodSystem
    local animalFood = foodSystem ~= nil and foodSystem:getAnimalFood(spec.animalTypeIndex) or nil
    local feeds, seen, unconfigured = {}, {}, {}
    for _, group in ipairs(animalFood ~= nil and animalFood.groups or {}) do
        for _, index in ipairs(group.fillTypes or {}) do
            local name = fillTypeName(index)
            if name ~= nil and not seen[name] then
                seen[name] = true
                local liters = math.max(placeable:getAvailableFood(index) or 0, 0)
                local profile = RLFeedProfiles.getUsableFeed(name, config)
                if profile == nil or profile.role == "MILK" then
                    if liters > 0 then table.insert(unconfigured, name) end
                else
                    table.insert(feeds, { name = name, profile = profile, liters = liters, index = index })
                end
            end
        end
    end
    return feeds, {}, {}, unconfigured
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


--- The fill types of a pen's own groups this mod added (cattle grain: true; a species' feeds,
--- sheep: the species name), kept with the pen.
local function getAddedFills(placeable)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    local grains = spec ~= nil and spec.rlGrainFillTypes or nil
    if grains == nil then
        grains = {}
        local foodSystem = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
        local animalFood = foodSystem ~= nil and spec ~= nil and foodSystem:getAnimalFood(spec.animalTypeIndex) or nil
        for _, group in ipairs(animalFood ~= nil and animalFood.groups or {}) do
            if group.rlGrain then for _, index in ipairs(group.fillTypes) do grains[index] = group.rlSpecies or true end end
        end
        if spec ~= nil then spec.rlGrainFillTypes = grains end
    end
    return grains
end


--- Whether a pen eats the feeds added for its species this hour: the species runs the mode
--- (RLGrowth.speciesNutritionReady, its weight curves on) and every animal in the pen is covered (a
--- goat in a sheep pen keeps the whole pen on the old rules, which never eat them). An empty pen
--- takes them, ready for its animals. Kept for the hour.
function RLFeed.isSpeciesFeedOpen(placeable, species)
    local spec = placeable.spec_husbandryFood
    local tick = RLBodyCondition.getTickId()
    local cached = spec.rlSpeciesFeedOpen
    if cached ~= nil and tick ~= nil and cached.tick == tick and cached.species == species then return cached.open end
    local entry = RLWeightProfiles.getTypeEntry(species)
    local open = entry ~= nil and entry.enabled == true and RLGrowth.isEnabled() and RLGrowth.speciesNutritionReady(species)
    if open and placeable.getClusters ~= nil then
        for _, animal in ipairs(placeable:getClusters() or {}) do
            if not animal.isDead and (animal.numAnimals or 1) > 0 and not RLGrowth.covers(animal) then open = false break end
        end
    end
    spec.rlSpeciesFeedOpen = { tick = tick, species = species, open = open }
    return open
end


--- Whether a pen's trough takes more of a fill type: grain only while the mode is on; a species'
--- added feeds (sheep: silage, grain) only while its pen eats them (RLFeed.isSpeciesFeedOpen).
function RLFeed.acceptsFill(placeable, fillTypeIndex)
    -- Restoring existing stock is not new unloading. The save's mode and species settings
    -- load after the trough, and fallback pens must keep their stock for a later recovery.
    -- The engine still checks the supported fill type and the trough's actual capacity.
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    if spec ~= nil and spec.rlRestoringFood then return true end
    if RLFeed.mode == RLFeed.MODE_REAL then
        local species = getAddedFills(placeable)[fillTypeIndex]
        if type(species) == "string" then return RLFeed.isSpeciesFeedOpen(placeable, species) end
        return true
    end
    return not getAddedFills(placeable)[fillTypeIndex]
end


--- Start a pen's feeding (server): decide whether it runs the mode this hour.
--- @param placeable table
--- @return boolean active
function RLFeed.beginFeeding(placeable)
    local spec = placeable.spec_husbandryFood
    if spec == nil then return false end
    local tick = RLBodyCondition.getTickId()
    -- The hour's water before its feeding (the engine draws the water after the food): what the
    -- pen's water spec will give this hour, recorded now; the water spec records what the
    -- animals actually drank once it has drawn it (RL_PlaceableHusbandryWater.updateFeeding).
    if placeable.spec_husbandryWater ~= nil then RLBodyCondition.recordWater(placeable, (RLFeed.getWaterSupply(placeable))) end
    local active, reason = RLFeed.evaluatePen(placeable)
    spec.rlFeedPen = { tick = tick, active = active, reason = reason }
    spec.rlFeedWindow = active and { tick = tick } or nil
    if #observers > 0 then
        local config = RLFeed.getConfig(placeable)
        local environment = g_currentMission.environment
        RLFeed.notify("PEN_HOUR", { placeable = placeable, tick = tick, active = active, reason = reason, hash = config.hash,
            scale = config.resourceScale, stepDays = config.stepDays, realDaysPerPeriod = config.realDaysPerPeriod,
            daysPerPeriod = environment.daysPerPeriod, pendingDays = spec.rlFeedClock ~= nil and spec.rlFeedClock.pendingDays or 0 })
    end
    return active
end


--- The share of its water need a pen gets this hour, read off its water spec before the feeding:
--- automatic supply (the pen pays for its water) all of it; otherwise the water stock in the pen
--- (filled by hand, a pipeline or a rain water tank's deliveries) over the hour's need, as the
--- engine will draw it after the feeding. A pen without a water spec has no water modelled (1).
--- Water in fresh feed and in the milk a young animal drinks is not part of the pen's coverage
--- (RLFeed.getAnimalWater adds the milk; feed moisture is not counted in this version).
--- @return number coverage 0..1
--- @return string source "NONE", "AUTOMATIC", "NO_NEED", "STOCK"
function RLFeed.getWaterSupply(placeable)
    local water = placeable ~= nil and placeable.spec_husbandryWater or nil
    if water == nil then return 1, "NONE" end
    if water.automaticWaterSupply then return 1, "AUTOMATIC" end
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    local need = (water.litersPerHour or 0) * (environment ~= nil and environment.timeAdjustment or 1)
    if need <= 0 then return 1, "NO_NEED" end
    local stock = placeable.getHusbandryFillLevel ~= nil and placeable:getHusbandryFillLevel(water.fillType) or 0
    return math.clamp((stock or 0) / need, 0, 1), "STOCK"
end


--- A pen's water coverage this hour: as recorded for this hour (before its feeding, then what was
--- drunk), else read off its water spec now - never an older hour's, never 1 for want of a record.
function RLFeed.getHourWater(placeable, tick)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    local water = spec ~= nil and spec.rlWaterCoverage or nil
    tick = tick or RLBodyCondition.getTickId()
    if water ~= nil and tick ~= nil and water.tick == tick then return water.coverage end
    return (RLFeed.getWaterSupply(placeable))
end


--- An animal's water this step: its pen's coverage, with the milk it may still drink counted as
--- covered (a young animal on milk takes its water with it: milkMax of its diet), and the share of
--- its dry intake that water allows (RLFeedMath.stepWaterIntake from its last step's, read only:
--- RLFeed.runStep keeps it once the step is taken).
--- @return number coverage 0..1
--- @return number intake share 0..1
function RLFeed.getAnimalWater(animal, milkMax, dtDays)
    local coverage = RLFeed.getHourWater(getOwner(animal))
    coverage = 1 - (1 - math.clamp(coverage, 0, 1)) * (1 - math.clamp(milkMax or 0, 0, 1))
    local state = RLGrowth.peekState(animal)
    return coverage, RLFeedMath.stepWaterIntake(state ~= nil and state.waterIntake or nil, coverage, dtDays, RLFeed.getConfig(animal).water)
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
--- A second call in the same feeding window returns the first's factor (the hour is fed once).
--- A step that fails before anything was taken from the trough raises the error: the wrapper gives
--- the hour to the old rules, its model time with it. One that fails after the first removal keeps
--- the steps already done (their feed and budgets stand) and drops the rest of the hour's steps:
--- never the old rules on top of feed already taken.
--- @return number factor Share of the hour's planned ME the pen got (its food factor); in an hour
---         without a step the last step hour's (saved with the pen)
function RLFeed.consume(placeable, consumedFood)
    local spec = placeable.spec_husbandryFood
    local window = spec.rlFeedWindow
    if window.hour ~= nil then return window.factor or 1 end
    local clock = spec.rlFeedClock or { pendingDays = 0 }
    spec.rlFeedClock = clock
    local tickBefore, pendingBefore = clock.tick, clock.pendingDays or 0
    -- One hour's model time once, however often the hour is fed.
    if clock.tick ~= window.tick then
        clock.tick = window.tick
        clock.pendingDays = pendingBefore + RLFeed.getHourDays()
    end
    local stepDays = RLFeed.getStepDays()
    local steps = math.floor(clock.pendingDays / stepDays + 1e-9)
    clock.pendingDays = clock.pendingDays - steps * stepDays
    if clock.pendingDays < 1e-9 then clock.pendingDays = 0 end

    local hour = { steps = steps, stepDays = stepDays, animals = {}, order = {}, byFill = {}, plannedMe = 0, plannedKg = 0, eatenMe = 0,
        eatenKg = 0, limits = {}, limitOf = {}, plannedPerMonth = {}, unconfigured = {} }
    window.hour = hour
    for i = 1, steps do
        local ok, err = pcall(RLFeed.runStep, placeable, window, stepDays)
        if not ok then
            if not window.started then
                -- Nothing taken or settled: the old rules feed this hour, with its model time.
                clock.tick, clock.pendingDays = tickBefore, pendingBefore
                window.hour = nil
                error(err, 0)
            end
            RLFeed.onStepError(placeable, err, steps - i + 1)
            hour.steps = i - 1
            break
        end
    end
    local factor
    if hour.steps == 0 then
        factor = spec.rlFeedFactor or 1
    elseif hour.plannedMe <= 0 then
        factor = #hour.order > 0 and 0 or 1
    else
        factor = math.clamp(hour.eatenMe / hour.plannedMe, 0, 1)
    end
    if hour.steps > 0 then spec.rlFeedFactor = factor end
    window.factor = factor
    return factor
end


local stepErrors = {}

--- A step that failed after the hour's feeding had begun: logged once per pen and message; the
--- steps done stand, the rest of the hour's model time is dropped.
function RLFeed.onStepError(placeable, message, dropped)
    local key = tostring(placeable) .. tostring(message)
    if not stepErrors[key] then
        stepErrors[key] = true
        Log:error("RLFeed: a feeding step failed in %s (%s); the steps already done stand, %d step(s) of this hour dropped",
            placeable.getName ~= nil and placeable:getName() or "?", tostring(message), dropped or 0)
    end
end


--- The planner's view of a pen's living animals for a step of stepDays (`include(animal)`: which
--- of them, all when nil). Reads the animals only.
--- @return table descriptors
function RLFeed.describePen(placeable, ration, stepDays, include)
    local dtMonths = stepDays / RLFeed.getConfig(placeable).realDaysPerPeriod
    local animals = {}
    for _, animal in ipairs(placeable:getClusters() or {}) do
        if not animal.isDead and (animal.numAnimals or 1) > 0 and (include == nil or include(animal)) then
            table.insert(animals, RLFeed.describeAnimal(animal, ration, dtMonths, stepDays))
        end
    end
    if not isRearingPen(placeable) then RLFeed.linkDams(animals, stepDays) end
    RLFeed.limitSucklerMilk(animals)
    return animals
end


--- A suckler (beef) cow makes the milk her calves drink, not her dairy potential (breedTraits
--- milkCollect < 1): her milk this step is what her own calves here plan to drink from her (their
--- allowance within their appetite, as the planner gives it) plus milkCollect of the rest. Without a
--- calf at foot she gives none. Her milk need, appetite, protein need and her calves' pool follow;
--- the step's milk potential is scaled the same (milkDemandFactor, RLFeed.applyStepInput). A dairy
--- cow (milkCollect 1) is untouched.
--- @param animals table The step's descriptors (after RLFeed.linkDams)
function RLFeed.limitSucklerMilk(animals)
    local wanted = {}
    for _, a in ipairs(animals) do
        local pool = a.damPool
        if pool ~= nil and a.milkMax ~= nil and a.milkMax > 0 then
            local allowance = math.min(math.max(a.nursingMaxKgPerDay or 0, 0), a.appetite or 0)
            wanted[pool.dam] = (wanted[pool.dam] or 0) + allowance / RLFeed.getConfig(pool.dam.animal).damMilk.dm
        end
    end
    for _, a in ipairs(animals) do
        local milkKg = a.milkKgPerDay or 0
        if a.class == "LACTATING" and (a.milkCollect or 1) < 1 and milkKg > 0 then
            local drink = math.min(wanted[a] or 0, milkKg)
            local target = drink + a.milkCollect * (milkKg - drink)
            local factor = math.clamp(target / milkKg, 0, 1)
            a.milkDemandFactor = factor
            a.appetite = math.max(a.appetite - (a.appetitePerMilkKg or 0) * (milkKg - target), 0)
            a.milkKgPerDay = target
            a.needs.milk = a.needs.milk * factor
            a.proteinNeed = RLFeedMath.getProteinNeed(a.class, RLGrowth.getContinuousAge(a.animal), RLFeed.getConfig(a.animal).protein,
                a.milkMax, target)
            if a.nursing ~= nil then a.nursing.kg = a.nursing.kg * factor end
        end
    end
end


--- Each calf on milk with a dam that can nurse it among the step's animals drinks from her: one pool
--- per dam (twins share it), her milk at full feed this step x the share of it her budget paid in her
--- last step in this pen (all of it when she has none here: moved in, or the first step) (real kg
--- DM, damMilk values). The planner gives the pool's milk to her calves first; RLFeed.runStep settles
--- it against what she actually paid.
function RLFeed.linkDams(animals, stepDays)
    local dams = {}
    for _, a in ipairs(animals) do
        -- Nursing rules (sheep): a ewe in milk with her lambs here (her class); cattle: canNurse.
        local nurses
        if getNursing(a.animal) ~= nil then
            nurses = a.class == "LACTATING" and a.animal.getIdentifiers ~= nil and (a.milkKgPerDay or 0) > 0
        else
            nurses = RLFeed.canNurse(a.animal)
        end
        if nurses then dams[a.animal:getIdentifiers()] = a end
    end
    if next(dams) == nil then return end
    for _, a in ipairs(animals) do
        local dam = a.class == "CALF" and a.animal.motherId ~= nil and dams[a.animal.motherId] or nil
        if dam ~= nil then
            if dam.nursing == nil then
                local damMilk = RLFeed.getConfig(dam.animal).damMilk
                local last = dam.animal.rlFeedLastMilk
                local owner = dam.animal.clusterSystem ~= nil and dam.animal.clusterSystem.owner or nil
                local share = 1
                if last ~= nil and last.owner == owner and RLFeed.isFresh(last.tick) then share = last.share end
                dam.nursing = { dam = dam, kg = math.max(dam.milkKgPerDay or 0, 0) * share * damMilk.dm * stepDays,
                    me = damMilk.me, cp = damMilk.cp }
            end
            a.damPool = dam.nursing
        end
    end
end


--- A step's plan for a pen on its stock as it is now, on a ration: what the planner would take and
--- give each animal. Takes nothing from the trough (RLFeed.runStep removes the plan's liters).
--- @return table plan, table forage, table concentrate, table milk, table unconfigured
function RLFeed.planPen(placeable, ration, animals, stepDays)
    local config = RLFeed.getConfig(placeable)
    local forage, concentrate, milk, unconfigured = RLFeed.getStockLists(placeable, ration)
    if config.monogastric ~= nil then
        local plan = RLFeedRationPlanner.planMonogastric({ animals = animals, feeds = forage, scale = config.resourceScale,
            realDaysPerPeriod = config.realDaysPerPeriod, dtDays = stepDays, proteinMaintenance = config.monogastric.lysineMaintenance })
        return plan, forage, concentrate, milk, unconfigured
    end
    local plan = RLFeedRationPlanner.plan({
        animals = animals, forage = forage, concentrate = concentrate, milk = milk,
        scale = config.resourceScale, realDaysPerPeriod = config.realDaysPerPeriod, dtDays = stepDays,
        share = ration.share, ration = config.ration, classes = config.classes,
        proteinMaintenance = config.protein.maintenance, proteinMilkResponse = config.protein.milkResponse, concentrateWanted = ration.grain ~= "NONE" and ration.share ~= 0,
    })
    return plan, forage, concentrate, milk, unconfigured
end


--- One model-time step of a pen: plan, remove, settle each animal.
--- @param placeable table
--- @param window table The hour's feeding
--- @param stepDays number Model days
function RLFeed.runStep(placeable, window, stepDays)
    local spec = placeable.spec_husbandryFood
    local config = RLFeed.getConfig(placeable)
    local ration = RLFeed.getRation(placeable)
    local dtMonths = stepDays / config.realDaysPerPeriod
    local tick = window.tick
    local hour = window.hour

    local hourDays = RLFeed.getHourDays()
    local animals = RLFeed.describePen(placeable, ration, stepDays, function(animal)
        -- A sheep that took the old weight rule this hour in a pen out of the mode (moved here
        -- since): the hour is settled (RLGrowth.step).
        if animal.rlLegacyHourTick == tick then return false end
        local last = animal.rlFeedStepTick
        if last == nil or animal.rlFeedStepOwner == placeable then return true end
        -- Moved in from another pen: not twice in an hour, and not again before a step's model time
        -- has passed since its last step there (each pen keeps its own clock).
        return last ~= tick and (tick - last) * hourDays >= stepDays - hourDays - 1e-9
    end)
    local plan, forage, concentrate, milk, unconfigured = RLFeed.planPen(placeable, ration, animals, stepDays)
    hour.unconfigured = unconfigured

    -- Take it from the trough (and meadow) now; a feed the trough gave less of is shared as given.
    local indices, ratio, removedLiters = {}, {}, {}
    for _, list in ipairs({ forage, concentrate, milk }) do
        for _, entry in ipairs(list) do indices[entry.name] = entry.index end
    end
    -- From here the hour changes the trough and the animals: it can no longer go to the old rules.
    window.started = true
    if config.monogastric ~= nil then
        removedLiters = RLFeed.withdrawMonogastric(placeable, plan, indices, hour)
    else
        for name, liters in pairs(plan.withdraw) do
            local index = indices[name]
            if index ~= nil and liters > 0 then
                local removed = placeable:removeFood(liters, index) or 0
                removedLiters[name] = removed
                ratio[name] = math.clamp(removed / liters, 0, 1)
            end
        end
    end
    local observed = #observers > 0 and { placeable = placeable, tick = tick, stepDays = stepDays, scale = config.resourceScale,
        withdraw = plan.withdraw, removed = removedLiters, ledger = hour.monoLedger, animals = {}, dams = {} } or nil

    -- This hour's water, worked out before the feeding (RLFeed.beginFeeding): never an older hour's.
    local waterCoverage = RLFeed.getHourWater(placeable, tick)
    local protein = config.protein
    hour.plannedPerMonth = {}
    -- Dams settle before the calves drinking from them: a calf gets her milk only as far as her
    -- budget paid it this step.
    local order, calves = {}, {}
    for _, a in ipairs(plan.animals) do table.insert(a.damMilk ~= nil and calves or order, a) end
    for _, a in ipairs(calves) do table.insert(order, a) end
    for _, a in ipairs(order) do
        -- A monogastric pen's meals were already settled whole against the trough (RLFeed.withdrawMonogastric).
        if config.monogastric == nil then
            for name, fill in pairs(a.byFill) do
                local r = ratio[name] or 0
                if r < 1 then fill.kg, fill.liters, fill.me, fill.cpKg = fill.kg * r, fill.liters * r, fill.me * r, fill.cpKg * r end
            end
        end
        if a.damMilk ~= nil then RLFeed.settleDamMilk(a, hour, config.damMilk, observed) end
        RLFeedRationPlanner.sumAnimal(a)
        local animal = a.animal
        -- A calf's milk this step: what it planned to drink and what it got (trough and dam).
        local milkDrunk = a.damMilk ~= nil and a.damMilk.kg or 0
        for name, fill in pairs(a.byFill) do
            local profile = RLFeedProfiles.getUsableFeed(name, config)
            if profile ~= nil and profile.role == "MILK" then milkDrunk = milkDrunk + fill.kg end
        end
        -- Held by its water rather than its appetite or rumen: said so.
        if (a.waterCap or 1) < 1 - 1e-9 and (a.intakeLimit == "APPETITE" or a.intakeLimit == "FILL" or a.intakeLimit == "ENERGY") then
            a.intakeLimit = "WATER"
        end
        local feed = { tick = tick, owner = placeable, kg = a.kg, me = a.me, cp = a.cp, byFill = a.byFill, plannedKg = a.plannedKg,
            plannedMe = a.plannedMe, class = a.class, target = a.target, concShare = a.cEaten, concLimit = a.concLimit,
            intakeLimit = a.intakeLimit, proteinFactor = RLFeed.getStepProteinFactor(a, config),
            lysPerMe = config.monogastric ~= nil and a.lysPerMe or nil,
            proteinNeed = a.proteinNeed, dtDays = stepDays, water = a.waterCoverage or waterCoverage, waterIntake = a.waterCap or 1,
            damMilk = a.damMilk,
            milkDemandFactor = a.milkDemandFactor, milkPlanKg = a.milkPlanKg or 0, milkDrunkKg = milkDrunk }
        local before = observed ~= nil and { weight = animal.weight, health = animal.health, healthCarry = animal.rlHealthCarry or 0 } or nil
        local paidBefore = a.nursing ~= nil and hour.animals[animal] ~= nil and hour.animals[animal].milkPaidLiters or 0
        RLFeed.stepAnimal(animal, feed, dtMonths, tick, placeable, hour)
        -- Its water intake share is kept with it (saved), so a shortage builds up and passes off
        -- over model time, in any pen.
        if animal.rlGrowth ~= nil and feed.result ~= nil then
            animal.rlGrowth.waterIntake = (a.waterCap or 1) < 1 - 1e-9 and a.waterCap or nil
        end
        if a.nursing ~= nil and hour.animals[animal] ~= nil then
            -- What her budget paid this step, as real kg DM her calves may drink.
            local liters = hour.animals[animal].milkPaidLiters - paidBefore
            a.nursing.paidLiters = liters
            a.nursing.paidKg = liters * RLFeed.getMilkRealPerGameLiter(animal) * config.damMilk.dm
        end
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
        -- What held it, counted once per animal an hour (its last step's), whatever the month length.
        hour.limitOf[animal] = a.concLimit or a.intakeLimit
    end
    if observed ~= nil then RLFeed.notify("STEP", observed) end
end


--- Take a monogastric pen's plan from its trough (pigs) so every animal's mix - each feed within its
--- maxShare of what it eats - holds for what it actually eats. First against the stock right before
--- removal: a feed short of the plan shrinks each meal it is part of as a whole. Then against what the
--- trough gave: a feed it gave less of shrinks those meals again, and what was taken of the other feeds
--- above the meals is put back (addFood) or, where it cannot be, booked as lost - never as eaten. Only
--- what is eaten reaches an animal's DM, ME, CP and SID lysine. The hour's ledger keeps withdrawn,
--- eaten, returned and lost liters per feed (hour.monoLedger).
--- @return table removed name -> liters taken from the trough and kept (withdrawn - returned)
function RLFeed.withdrawMonogastric(placeable, plan, indices, hour)
    local function shrink(factors)
        local need = {}
        for _, a in ipairs(plan.animals) do
            local meal = 1
            for name in pairs(a.byFill) do meal = math.min(meal, factors[name] or 1) end
            if meal < 1 - 1e-12 then
                for _, fill in pairs(a.byFill) do
                    fill.kg, fill.liters, fill.me, fill.cpKg = fill.kg * meal, fill.liters * meal, fill.me * meal, fill.cpKg * meal
                    fill.lysKg = (fill.lysKg or 0) * meal
                end
                a.intakeLimit = "FEED_SHORT"
            end
            for name, fill in pairs(a.byFill) do need[name] = (need[name] or 0) + fill.liters end
        end
        return need
    end
    -- 1. Against the stock as it is now.
    local factors = {}
    for name, liters in pairs(plan.withdraw) do
        local index = indices[name]
        local available = index ~= nil and math.max(placeable:getAvailableFood(index) or 0, 0) or 0
        if liters > 0 and available < liters then factors[name] = available / liters end
    end
    local need = shrink(factors)
    -- 2. Against what the trough gives.
    local removed, short = {}, {}
    for name, liters in pairs(need) do
        local index = indices[name]
        if index ~= nil and liters > 0 then
            removed[name] = placeable:removeFood(liters, index) or 0
            if removed[name] < liters * (1 - 1e-9) then short[name] = removed[name] / liters end
        end
    end
    if next(short) ~= nil then need = shrink(short) end
    -- 3. The ledger: what was taken above the meals goes back where it can.
    local ledger = hour.monoLedger or {}
    hour.monoLedger = ledger
    local kept = {}
    for name, taken in pairs(removed) do
        local eaten = need[name] or 0
        local excess = math.max(taken - eaten, 0)
        local returned = 0
        if excess > 1e-9 and placeable.addFood ~= nil then
            local farmId = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
            returned = math.min(placeable:addFood(farmId, excess, indices[name]) or 0, excess)
        end
        local row = ledger[name] or { withdrawn = 0, eaten = 0, returned = 0, lost = 0 }
        row.withdrawn, row.eaten = row.withdrawn + taken, row.eaten + math.min(eaten, taken)
        row.returned, row.lost = row.returned + returned, row.lost + (excess - returned)
        ledger[name] = row
        kept[name] = taken - returned
    end
    return kept
end


--- The share of its growth potential a step's ration protein allows: crude protein against the
--- class need, or - monogastric sections (pigs) - SID lysine per MJ of ME against its need.
function RLFeed.getStepProteinFactor(a, config)
    if config.monogastric ~= nil then
        return RLFeedMath.getProteinFactor(a.lysPerMe or 0, a.proteinNeed, config.monogastric.lysineMaintenance)
    end
    return RLFeedMath.getProteinFactor(a.cp, a.proteinNeed, config.protein.maintenance)
end


--- A calf's dam milk for the step against what its dam paid: the pool's calves share at most her
--- step's milk (as planned, less in proportion when she paid less), settled once per dam, and what
--- they drink leaves her milk for the store (her record's milkLiters; milkToCalves keeps it).
--- @param a table The calf's plan
--- @param hour table
--- @param damMilk table damMilk values
--- @param observed table|nil The STEP event being built
function RLFeed.settleDamMilk(a, hour, damMilk, observed)
    local pool = a.damPool
    if pool.factor == nil then
        local planned = pool.plannedKg or 0
        local paid = pool.paidKg or 0
        pool.factor = planned > 0 and math.clamp(paid / planned, 0, 1) or 0
        local allocated = planned * pool.factor
        local dam = pool.dam.animal
        local record = hour.animals[dam]
        local perLiter = RLFeed.getMilkRealPerGameLiter(dam) * damMilk.dm
        local liters = (record ~= nil and perLiter > 0) and allocated / perLiter or 0
        if record ~= nil then
            -- Never more than she paid this step (rounding): her store takes the rest.
            liters = math.min(liters, pool.paidLiters or 0)
            record.milkLiters = math.max(record.milkLiters - liters, 0)
            record.milkToCalves = (record.milkToCalves or 0) + liters
        end
        pool.allocatedKg = allocated
        if observed ~= nil then
            table.insert(observed.dams, { animal = dam, plannedKg = planned, paidKg = paid, paidLiters = pool.paidLiters or 0,
                allocatedKg = allocated, allocatedLiters = liters, calves = #pool.calves })
        end
    end
    local f = pool.factor
    if f < 1 then
        local milk = a.damMilk
        milk.kg, milk.me, milk.cpKg = milk.kg * f, milk.me * f, milk.cpKg * f
    end
end


--- One animal's step: its growth budget on what it ate, its rumen's adaptation, its health, the
--- milk the budget paid, all added to the hour's record of it.
function RLFeed.stepAnimal(animal, feed, dtMonths, tick, placeable, hour)
    -- Its last step in the mode before this one (the state's lastTick: only these steps move it).
    feed.previousTick = animal.rlGrowth ~= nil and animal.rlGrowth.lastTick or nil
    local result, input, weightBefore = RLGrowth.stepFeed(animal, feed, dtMonths, tick)
    animal.rlFeedStepTick, animal.rlFeedStepOwner = tick, placeable
    local record = hour.animals[animal]
    if record == nil then
        record = { tick = tick, owner = placeable, kg = 0, me = 0, cpKg = 0, byFill = {}, plannedKg = 0, plannedMe = 0, dtDays = 0,
            milkLiters = 0, milkPaidLiters = 0, damMilkKg = 0, milkPlanKg = 0, milkDrunkKg = 0, steps = 0,
            healthLostWater = 0, healthLostFeed = 0 }
        hour.animals[animal] = record
        table.insert(hour.order, animal)
    end
    record.steps = record.steps + 1
    record.kg, record.me, record.cpKg = record.kg + feed.kg, record.me + feed.me, record.cpKg + feed.cp * feed.kg
    record.plannedKg, record.plannedMe, record.dtDays = record.plannedKg + feed.plannedKg, record.plannedMe + feed.plannedMe, record.dtDays + feed.dtDays
    if feed.damMilk ~= nil then record.damMilkKg = record.damMilkKg + feed.damMilk.kg end
    record.milkPlanKg, record.milkDrunkKg = record.milkPlanKg + (feed.milkPlanKg or 0), record.milkDrunkKg + (feed.milkDrunkKg or 0)
    for name, fill in pairs(feed.byFill) do
        local total = record.byFill[name] or { liters = 0, kg = 0, me = 0, cpKg = 0 }
        total.liters, total.kg, total.me, total.cpKg = total.liters + fill.liters, total.kg + fill.kg, total.me + fill.me, total.cpKg + fill.cpKg
        record.byFill[name] = total
    end
    record.class, record.target, record.concShare, record.concLimit, record.intakeLimit = feed.class, feed.target, feed.concShare,
        feed.concLimit, feed.intakeLimit
    record.proteinFactor, record.proteinNeed, record.water = feed.proteinFactor, feed.proteinNeed, feed.water
    record.waterIntake = feed.waterIntake
    if result == nil then return end
    RLFeed.afterStep(animal, animal.rlGrowth, feed, result, weightBefore, dtMonths)
    local healthBefore = animal.health or 0
    RLFeed.applyHealth(animal, feed, result, dtMonths)
    -- Health lost for want of water is kept apart from health lost for want of feed.
    local lost = healthBefore - (animal.health or 0)
    if lost > 0 then
        if feed.healthReason == "WATER" then record.healthLostWater = record.healthLostWater + lost
        else record.healthLostFeed = record.healthLostFeed + lost end
    end
    RLFeed.applyUnderweight(animal, dtMonths)
    RLFeed.addDeathRisk(animal, dtMonths)
    -- The milk this step's budget paid (game liters): her calves' share leaves it (settleDamMilk), the
    -- pen's store takes the rest this hour.
    local potentialLiters = math.max(input.potentialMilk or 0, 0) * dtMonths
    local paidLiters = potentialLiters * (result.milkFraction or 0)
    record.milkLiters = record.milkLiters + paidLiters
    record.milkPaidLiters = record.milkPaidLiters + paidLiters
    if potentialLiters > 0 then
        -- The share of her milk this step paid: what her calves' next step plans from her.
        animal.rlFeedLastMilk = { tick = tick, owner = placeable, share = math.clamp(paidLiters / potentialLiters, 0, 1) }
    end
    record.milkPotential = (record.milkPotential or 0) + math.max(input.potentialMilk or 0, 0) * dtMonths
    record.coverage, record.growthFraction = result.coverage, result.growthFraction
    record.healthFactor, record.healthReason, record.gainPerMonth = feed.healthFactor, feed.healthReason, feed.gainPerMonth
    record.result = result
end


--- Young animals of a pen with nursing rules (sheep) still of an age for milk, not weaned early,
--- whose dam is not here to nurse them: they drink nothing this hour.
--- @return number
function RLFeed.countUnnursed(placeable)
    local count = 0
    local dams = getPenDams(placeable)
    for _, animal in ipairs(placeable:getClusters() or {}) do
        if not animal.isDead and (animal.numAnimals or 1) > 0 and RLFeed.getNursingMilkMax(animal) > 0
            and (animal.motherId == nil or dams[animal.motherId] == nil) and not RLFeed.isEarlyWeaned(animal) then
            count = count + 1
        end
    end
    return count
end


--- A calf drank under half the milk it planned this hour (milk it was due: its allowance within its
--- appetite, from its dam and the trough).
RLFeed.MILK_SHORT_SHARE = 0.5
function RLFeed.isMilkShort(planKg, drunkKg)
    return (planKg or 0) > 0 and (drunkKg or 0) < RLFeed.MILK_SHORT_SHARE * planKg
end

--- Calf milk running low: less than this many months left at the plan.
RLFeed.CALF_MILK_LOW_MONTHS = 0.25

--- A rearing pen's calves on milk this hour: { state, calves, short, monthsLeft }. state "NONE" when
--- a calf drank under half its milk and the trough has too little milk for its plan, "LOW" when
--- the milk lasts under CALF_MILK_LOW_MONTHS at the plan, else "OK"; nil without a calf on milk.
--- Pure on its inputs: records { milkPlanKg, milkDrunkKg }, the milk stock and the planned milk
--- liters a month.
function RLFeed.getCalfMilkAlert(records, stockLiters, plannedPerMonth)
    local calves, short = 0, 0
    for _, record in ipairs(records) do
        if (record.milkPlanKg or 0) > 0 then
            calves = calves + 1
            if RLFeed.isMilkShort(record.milkPlanKg, record.milkDrunkKg) then short = short + 1 end
        end
    end
    if calves == 0 then return nil end
    local monthsLeft = plannedPerMonth > 0 and math.max(stockLiters, 0) / plannedPerMonth or nil
    local state = "OK"
    if short > 0 and (monthsLeft == nil or monthsLeft < RLFeed.CALF_MILK_LOW_MONTHS) then
        state = "NONE"
    elseif monthsLeft ~= nil and monthsLeft < RLFeed.CALF_MILK_LOW_MONTHS then
        state = "LOW"
    end
    return { state = state, calves = calves, short = short, monthsLeft = monthsLeft }
end

--- The alert for a pen's hour (server): its calves' records, the trough's milk and the plan's.
function RLFeed.getPenCalfMilkAlert(placeable, hour)
    local records = {}
    for _, animal in ipairs(hour.order or {}) do
        local record = hour.animals[animal]
        if record ~= nil and record.class == "CALF" then records[#records + 1] = record end
    end
    local stock, planned = 0, 0
    for name, liters in pairs(hour.plannedPerMonth or {}) do
        local profile = RLFeedProfiles.getUsableFeed(name)
        if profile ~= nil and profile.role == "MILK" then
            planned = planned + liters
            local index = g_fillTypeManager:getFillTypeIndexByName(name)
            if index ~= nil then stock = stock + math.max(placeable:getAvailableFood(index) or 0, 0) end
        end
    end
    return RLFeed.getCalfMilkAlert(records, stock, planned)
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
        record.milkShort = RLFeed.isMilkShort(record.milkPlanKg, record.milkDrunkKg)
        animal.rlFeedIntake = record
        -- A suckler breed's milk left after her calves is not collected (breedTraits milkCollect).
        local collect = record.milkLiters > 0 and (getNursing(animal) ~= nil and 0 or RLBreedTraits.getMilkCollect(animal:getSubType())) or 1
        record.milkLiters = record.milkLiters * collect
        -- The store deposits liters per hour x the hour's time adjustment.
        animal.rlMilkPaid = { tick = tick, litersPerHour = timeAdjustment > 0 and record.milkLiters / timeAdjustment or 0, deposited = false }
        animal.rlNutrition = { tick = tick, allocatedLiters = 0, coverage = record.coverage,
            intakeRatio = record.plannedKg > 0 and record.kg / record.plannedKg or 0,
            -- What her budget paid of her milk (her calves drank part of it: milkToCalves).
            milkShare = (record.milkPotential or 0) > 0 and (record.milkPaidLiters or record.milkLiters) / record.milkPotential or nil,
            growthFraction = record.growthFraction, intakeSource = "feed" }
    end
    if hour.steps > 0 then placeable.rlBodyConditionStepped = tick end
    hour.calfMilk = hour.steps > 0 and isRearingPen(placeable) and RLFeed.getPenCalfMilkAlert(placeable, hour) or nil
    -- Nursing rules (sheep): young still on milk with no dam here (moved, sold, or its dam moved
    -- away) get no milk at all - the player is told, never stopped (S5 D4).
    if hour.steps > 0 and getNursing(placeable) ~= nil then hour.unnursed = RLFeed.countUnnursed(placeable) end

    hour.tick = tick
    hour.limits = {}
    for _, limit in pairs(hour.limitOf or {}) do hour.limits[limit] = (hour.limits[limit] or 0) + 1 end
    hour.limitOf = nil
    hour.animals, hour.order = #hour.order, nil
    hour.water = RLFeed.getHourWater(placeable, tick)
    hour.coverage = hour.plannedMe > 0 and hour.eatenMe / hour.plannedMe or (hour.animals > 0 and 0 or 1)
    -- The old ledger's energy row reads the share of the planned ME eaten in this mode.
    local supply = spec.rlNutritionSupply
    if supply ~= nil and supply.tick == tick and hour.steps > 0 then supply.energyShare = { ME = math.clamp(hour.coverage, 0, 1) } end
    if hour.steps > 0 then spec.rlFeedLast = hour end
    if hour.calfMilk ~= nil and RLFeedInfoService ~= nil and g_currentMission ~= nil and g_currentMission.getIsClient ~= nil
        and g_currentMission:getIsClient() then
        RLFeedInfoService.notifyCalfMilk(placeable, hour.calfMilk)
    end
    if hour.unnursed ~= nil and RLFeedInfoService ~= nil and RLFeedInfoService.notifyUnnursed ~= nil and g_currentMission ~= nil
        and g_currentMission.getIsClient ~= nil and g_currentMission:getIsClient() then
        RLFeedInfoService.notifyUnnursed(placeable, hour.unnursed)
    end
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
    local config = RLFeed.getConfig(placeable)
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
            identity.water, identity.waterIntake = round(record.water or 1), round(record.waterIntake or 1)
            identity.healthLostWater, identity.healthLostFeed = round(record.healthLostWater), round(record.healthLostFeed)
            identity.weight = round(animal.weight)
            animals[#animals + 1] = identity
        end
    end
    table.sort(animals, function(a, b) return tostring(a.key) < tostring(b.key) end)
    local ration = RLFeed.getRation(placeable)
    local config = RLFeed.getConfig(placeable)
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
    local config = RLFeed.getConfig(animal)
    -- A nursing dam's milk (sheep): her lactation row this step, x her water as a cow's.
    if config.nursing ~= nil then RLFeed.applyDamMilk(animal, input, config, feed.water or 1) end
    input.supplyPerPeriod = dtMonths > 0 and feed.me / dtMonths or 0
    input.maintenanceFactor = (input.maintenanceFactor or 1) * RLFeed.getCalfMaintenanceFactor(animal, dtMonths)
    input.growthCostPerKg = RLFeed.getGrowthCost(animal, dtMonths)
    local _, mePerLiter = RLFeed.getMilkBridge(animal, input.potentialMilk)
    input.milkCostPerLiter = mePerLiter
    local protein = feed.proteinFactor or 0
    input.speed = (input.speed or 1) * protein
    input.potentialMilk = (input.potentialMilk or 0) * RLFeedMath.getMilkProteinFactor(protein, config.protein.milkResponse) * (feed.milkDemandFactor or 1)
    if feed.target == "MAINTAIN" then input.milkMobilizeShare = 0 end
    return input, RLFeed.getEnergyConfig(animal)
end


--- After a step: the rumen's adaptation moves toward the concentrate share it ate (for the step's
--- model days), and its live weight trend for the finishing forecast.
function RLFeed.afterStep(animal, state, feed, result, weightBefore, dtMonths)
    local config = RLFeed.getConfig(animal)
    state.feedAdapted = RLFeedMath.adapt(state.feedAdapted or 0, feed.concShare or 0, feed.dtDays, config.ration)
    local nursing = config.nursing
    if nursing ~= nil and (feed.dtDays or 0) > 0 then
        -- A young animal's days in a row on creep feed: each step in which it ate at least
        -- readyCreepKgPerDay of concentrate as fed (what it got from the trough, DM back to fresh
        -- weight by each feed's own DM; a day's rate) adds its model days, any other step starts
        -- the count again. So does a gap: an hour on the old weight rule (a pen out of the mode,
        -- no trough, the mode off, its config invalid) resets it there (RLGrowth.markLegacyHour),
        -- and a previous step older than the steps' spacing (a save from before: RLFeed.isFresh;
        -- a long month's hours between steps are no gap) resets it here; what it ate then is not
        -- known. An orphan whose count reaches readyDays
        -- from earlyWeaningMonth is weaned early (RLFeed.isEarlyWeaned), and that is kept: from
        -- then on it is a weaned lamb.
        if getFeedAge(animal) < nursing.weaningMonth + 1 then
            if not state.weanedEarly then
                if (state.creepDays or 0) > 0 and not RLFeed.isFresh(feed.previousTick, feed.tick) then state.creepDays = 0 end
                local fresh = 0
                for name, fill in pairs(feed.byFill or {}) do
                    local profile = RLFeedProfiles.getUsableFeed(name)
                    if profile ~= nil and profile.role == "CONCENTRATE" and profile.dm > 0 then fresh = fresh + fill.kg / profile.dm end
                end
                local onCreep = fresh / feed.dtDays >= nursing.readyCreepKgPerDay - 1e-9
                state.creepDays = onCreep and (state.creepDays or 0) + feed.dtDays or 0
                if RLFeed.isEarlyWeaned(animal) then state.weanedEarly = true end
            end
        else
            state.creepDays, state.weanedEarly = nil, nil
        end
    end
    feed.result = result
    if weightBefore ~= nil and dtMonths ~= nil and dtMonths > 0 then
        local gain = (result.weight - weightBefore) / dtMonths
        local alpha = 1 - math.exp(-dtMonths / RLFeed.GAIN_TAU_MONTHS)
        animal.rlFeedGain = animal.rlFeedGain == nil and gain or animal.rlFeedGain + alpha * (gain - animal.rlFeedGain)
        feed.gainPerMonth = animal.rlFeedGain
    end
end


--- Health from a step's budget, at the config's per-model-day rates (feedProfiles.xml health
--- lossPerDay, gainPerDay, geneticsRateEffect) for the step's model days; the subtype's per-hour
--- rates are the old rules' only.
--- @param animal table
--- @param feed table The step's feed
--- @param result table The step's budget
--- @param dtMonths number
function RLFeed.applyHealth(animal, feed, result, dtMonths)
    local body = RLBodyCondition.getConfig(animal)
    local config = RLFeed.getConfig(animal)
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
    if config.monogastric ~= nil then budget.cp, budget.cpMaintenance = feed.lysPerMe or 0, config.monogastric.lysineMaintenance end
    local factor, reason = RLFeedMath.getHealthFactor(budget)
    feed.healthFactor, feed.healthReason = factor, reason
    local genetics = animal.genetics ~= nil and animal.genetics.health or 1
    RLFeed.addHealth(animal, RLFeedMath.getHealthPerDay(factor, genetics, config.health) * dtMonths * config.realDaysPerPeriod)
end


--- Add a (fractional) health change to animal.health (saved and streamed as a float): no point is
--- lost or gained to rounding, whatever the month length or a save in between. A carry left by an
--- older build (whole-point health) goes into it once.
function RLFeed.addHealth(animal, delta)
    if delta ~= delta then return end
    delta = delta + (animal.rlHealthCarry or 0)
    animal.rlHealthCarry = nil
    if delta == 0 then return end
    animal.health = math.clamp((animal.health or 0) + delta, 0, 100)
end


--- After a step's health: the step's low-health death risk (the config's lowHealthDeath at the
--- health it left, for its model days) adds to the animal's risk counter (rlGrowth
--- lowHealthHazard, saved with it), which the day change draws once and clears
--- (AnimalHealth.evaluateDaily). Every step of the mode sets the counter, at 0 when healthy, so
--- the day change knows the animal is under the mode's curve and never draws the old one too.
--- @param animal table
--- @param dtMonths number
function RLFeed.addDeathRisk(animal, dtMonths)
    local state = animal.rlGrowth
    if state == nil then return end
    local config = RLFeed.getConfig(animal)
    local chance = RLFeedMath.getLowHealthDeathPerDay(config.lowHealthDeath, animal.health or 0, animal.age, config.health)
    state.lowHealthHazard = RLFeedMath.addDeathHazard(state.lowHealthHazard, chance, dtMonths * config.realDaysPerPeriod)
end


--- The weight-only health check of the mode: below extremeUnderweightRatio of its curve (the
--- weight model's underweight threshold scaled to it), at the old penalty's per-month rate.
function RLFeed.applyUnderweight(animal, dtMonths)
    local ratio = RLFeed.getConfig(animal).health.extremeUnderweightRatio
    local weightRatio = RLGrowth.getSettings(animal).underweightRatio
    -- Zero is a valid setting: it disables this weight threshold. Do not turn 0/0 into health NaN.
    if weightRatio <= 0 then return end
    local threshold = RLGrowth.getUnderweightThreshold(animal) * ratio / weightRatio
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
    for _, list in ipairs({ RLFeed.GRAINS, RLFeed.SUPPLEMENTS }) do
        for _, name in ipairs(list) do
            local index = fillTypeIndex(name)
            if index ~= nil and not used[index] then table.insert(fillTypes, index) end
        end
    end
    if #fillTypes == 0 then return end
    table.insert(animalFood.groups, { title = g_i18n:getText("rl_feed_grainGroup"), productionWeight = 0, eatWeight = 1,
        fillTypes = fillTypes, rlGrain = true })
    Log:info("RLFeed: cattle troughs take %d grain fill type(s) (eaten under the real-equivalent nutrition model only)", #fillTypes)
end


--- Fill types a species section's animals (sheep) may be given beside their map's groups: the
--- forage they eat in reality that the map leaves out, then grains and protein feed.
RLFeed.SPECIES_FORAGES = { SHEEP = { "SILAGE" } }


--- Add a species' feed groups (feedProfiles.xml species with a section: sheep) to its animal food:
--- the forages of RLFeed.SPECIES_FORAGES and the grains and supplements its groups do not list
--- yet, as groups of their own marked for that species. Idempotent; the map's groups and every
--- other type are untouched. The old rules never eat them (productionWeight 0, consumeFoodGroup),
--- and a trough takes them only while its pen eats them (RLFeed.acceptsFill). Goats share the
--- SHEEP type's food but never run the mode: a pen with a goat does not take these feeds.
--- @param foodSystem table AnimalFoodSystem
function RLFeed.registerSpeciesFeeds(foodSystem)
    local mission = foodSystem ~= nil and foodSystem.mission or g_currentMission
    local animalSystem = mission ~= nil and mission.animalSystem or nil
    local config = RLFeedProfiles.getConfig()
    if animalSystem == nil or config.species == nil then return end
    local names = {}
    for name in pairs(config.species) do names[#names + 1] = name end
    table.sort(names)
    for _, species in ipairs(names) do
        local typeIndex = animalSystem:getTypeIndexByName(species)
        local animalFood = typeIndex ~= nil and foodSystem:getAnimalFood(typeIndex) or nil
        if animalFood ~= nil and config.species[species].valid then
            local used, done = {}, false
            for _, group in ipairs(animalFood.groups) do
                if group.rlSpecies == species then done = true end
                for _, index in ipairs(group.fillTypes or {}) do used[index] = true end
            end
            if not done then
                local function collect(list)
                    local fillTypes = {}
                    for _, name in ipairs(list) do
                        local index = fillTypeIndex(name)
                        local profile = RLFeedProfiles.getUsableFeed(name)
                        if index ~= nil and profile ~= nil and not used[index] then
                            used[index] = true
                            table.insert(fillTypes, index)
                        end
                    end
                    return fillTypes
                end
                local forages = collect(RLFeed.SPECIES_FORAGES[species] or {})
                local grains = {}
                for _, list in ipairs({ RLFeed.GRAINS, RLFeed.SUPPLEMENTS }) do
                    for _, index in ipairs(collect(list)) do table.insert(grains, index) end
                end
                if #forages > 0 then
                    local fillType = g_fillTypeManager.getFillTypeByIndex ~= nil and g_fillTypeManager:getFillTypeByIndex(forages[1]) or nil
                    table.insert(animalFood.groups, { title = fillType ~= nil and fillType.title or g_i18n:getText("rl_feed_grainGroup"),
                        productionWeight = 0, eatWeight = 1, fillTypes = forages, rlGrain = true, rlSpecies = species })
                end
                if #grains > 0 then
                    table.insert(animalFood.groups, { title = g_i18n:getText("rl_feed_grainGroup"), productionWeight = 0, eatWeight = 1,
                        fillTypes = grains, rlGrain = true, rlSpecies = species })
                end
                Log:info("RLFeed: %s troughs take %d forage and %d grain fill type(s) (eaten under the real-equivalent nutrition model with the %s curves on)",
                    species, #forages, #grains, species)
            end
        end
    end
end


if AnimalFoodSystem ~= nil then
    if AnimalFoodSystem.loadMapData ~= nil then
        AnimalFoodSystem.loadMapData = Utils.appendedFunction(AnimalFoodSystem.loadMapData, function(self)
            RLFeed.registerCattleGrains(self)
            RLFeed.registerSpeciesFeeds(self)
        end)
    end

    -- The pen's feeding in the mode; elsewhere the engine's own. A plan that fails leaves the pen
    -- on the old rules for that hour (RLFeed.onPlanError), never without a feeding.
    local consumeFood = AnimalFoodSystem.consumeFood
    AnimalFoodSystem.consumeFood = function(self, animalTypeIndex, amount, foodOwner, consumedFood)
        local foodSpec = type(foodOwner) == "table" and foodOwner.spec_husbandryFood or nil
        local window = foodSpec ~= nil and foodSpec.rlFeedWindow or nil
        if window ~= nil then
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
        if spec.rlFeedFactor ~= nil then xmlFile:setFloat(base .. ".clock#foodFactor", spec.rlFeedFactor) end
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
    -- The last step hour's food factor: the hours until the next step keep it.
    local factor = xmlFile:getFloat(base .. ".clock#foodFactor")
    if factor ~= nil and factor == factor then spec.rlFeedFactor = math.clamp(factor, 0, 1) end
    -- A month counted under other feed data is history: the next hour starts a new one
    -- (RLFeed.addToMonth), and this one is kept as it was counted.
    if spec.rlFeedMonth ~= nil and spec.rlFeedMonth.hash ~= RLFeed.getConfig(placeable).hash then
        Log:info("RLFeed: %s month was counted under feed data %s (now %s); kept as it was, the next hour starts a new one", base,
            tostring(spec.rlFeedMonth.hash), RLFeed.getConfig(placeable).hash)
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
    local calfMilk = last ~= nil and last.calfMilk or nil
    streamWriteString(streamId, calfMilk ~= nil and calfMilk.state or "")
    if calfMilk ~= nil then
        streamWriteUInt8(streamId, math.min(calfMilk.calves, 255))
        streamWriteUInt8(streamId, math.min(calfMilk.short, 255))
        streamWriteFloat32(streamId, calfMilk.monthsLeft or -1)
    end
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
    local state = streamReadString(streamId)
    if state ~= "" then
        data.calfMilk = { state = state, calves = streamReadUInt8(streamId), short = streamReadUInt8(streamId) }
        local months = streamReadFloat32(streamId)
        data.calfMilk.monthsLeft = months >= 0 and months or nil
    end
    return data
end


--- Apply a pen's summary on a client: what its info shows.
function RLFeed.applyPenStream(placeable, data)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    if spec == nil or data == nil then return end
    spec.rlFeedPen = { tick = RLBodyCondition.getTickId(), active = data.active, reason = data.reason, client = true }
    spec.rlFeedRation = RLFeed.sanitizeRation(data.ration)
    spec.rlFeedClient = data
    -- A client's own notice (the server's host has it from RLFeed.endFeeding).
    if data.calfMilk ~= nil and RLFeedInfoService ~= nil and (g_server == nil) then RLFeedInfoService.notifyCalfMilk(placeable, data.calfMilk) end
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
    -- Back to the decimal it was sent as (Float32 carries 0.35 as 0.3499999940).
    local raw = { target = target, grain = grain, share = share >= 0 and math.floor(share * 10000 + 0.5) / 10000 or nil,
        substitute = streamReadBool(streamId) }
    local _, valid = RLFeed.sanitizeRation(raw)
    return raw, valid
end


--- An animal's hour in the mode, for clients (per real day): only its current record.
function RLFeed.writeAnimalStream(animal, streamId, tick)
    local record = animal.rlFeedIntake
    local has = record ~= nil and record.dtDays ~= nil and record.dtDays > 0
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
    streamWriteBool(streamId, record.milkShort == true)
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
        healthReason = text(streamReadString(streamId)), gainPerMonth = streamReadFloat32(streamId), milkShort = streamReadBool(streamId), client = true,
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
