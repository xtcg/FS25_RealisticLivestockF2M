loadMod("tests/dealerreplaysim.lua")
loadMod("scripts/animal/RLBirthWeight.lua")
-- GIANTS continue is only exercised here for a one-child dead-birth loop; replacing
-- continue with break has identical behavior for that one-child path. Surviving twins
-- and every player-only continue branch are otherwise untouched and not exercised.
local handle = assert(io.open(REPO .. "scripts/animal/AnimalReproduction.lua", "r"))
local source = handle:read("*a"); handle:close()
assert(load(source:gsub("%f[%a]continue%f[%A]", "break"), "actual reproduction module"))()
loadMod("scripts/dealer/RLDealerSourceReproduction.lua")
local B, Sim = RLDealerSourceReproduction, DealerReplaySim
local function success(value, failure) assert(value, failure ~= nil and failure.reason or "unexpected nil"); return value end
local seed = Sim.seed("HOLSTEIN", "female", 1)
local index = Economics.find(seed.subType.name)
local broadcasts, money, birthDraws, randomCalls, persisted = 0, 0, 0, 0, {}
g_server = { broadcastEvent = function() broadcasts = broadcasts + 1; error("source broadcast") end }
g_currentMission.addMoney = function() money = money + 1; error("source money") end
g_currentMission.farmStats = function() error("source player stats") end
g_currentMission.placeableSystem = { placeables = setmetatable({}, { __pairs = function() error("player sire lookup") end }) }
RealisticLivestock = { getMapCountryIndex = function() error("source must preserve selected country") end }
AnimalBirthEvent = { new = function() error("source event publication") end }
local function realMethods(a)
    a.rlHistoryReplay = nil
    a.breed = a:getSubType().breed
    a.getAnimalTypeIndex = function(self) return self.animalTypeIndex end
    a.resolveBirthCount = function(self) return self.birthCount or 0 end
    a.setBirthday = function(self, birthday) self.birthday = birthday end
    a.setClusterSystem = function(self, cluster) self.clusterSystem = cluster; self.sale = nil end
    a.setUniqueId = function() error("source may not redraw stable identity") end
    a.getSellPrice = function() error("source child must not be priced for sale") end
    a.addMessage = function() error("source must not send player message") end
    a.die = function() error("source must not invoke player death lifecycle") end
    return a
end
local function fixture(capacity, twins)
    local dam = realMethods(GrowthSim.makeAnimal(seed.subType.name, { age = 27, birthCount = 0, isParent = false, deathEnabled = true,
        uniqueId = "DAM-1", farmId = "SOURCE-FARM", children = {}, birthday = { country = 4 }, isPregnant = true, reproduction = 100 }))
    dam.isPregnant, dam.reproduction = true, 100
    dam.rlGrowth = assert(RLGrowth.createBirthState(dam, 40))
    dam.rlGrowth.ageMonths, dam.rlGrowth.developmentMonths = 27, 27
    dam.rlGrowth.lastTick, dam.rlGrowth.weightKg, dam.weight = nil, 500, 500
    local children = {}
    for i = 1, twins and 2 or 1 do
        local child = realMethods(GrowthSim.makeAnimal(seed.subType.name, { age = -1, uniqueId = "UNBORN-" .. i,
            farmId = "SOURCE-FARM", weight = 35 }))
        child.rlGrowth = nil
        children[#children + 1] = child
    end
    dam.pregnancy = { duration = 10, expected = { day = 4, month = 10, year = 2026 }, pregnancies = children }
    local gravid = RLGrowth.getGravidTarget(dam)
    dam.weight, dam.rlGrowth.weightKg, dam.rlGrowth.gravidKg = 500 + gravid, 500 + gravid, gravid
    dam.rlGrowth.reserveMassKg = 45
    local owner = assert(B.createOwner("PRIVATE-SOURCE", capacity or 10, { dam }))
    assert(B.pinSire(owner, dam.uniqueId, { uniqueId = "SIRE-FIXED", farmId = "SOURCE-SIRE", breed = "HOLSTEIN",
        genetics = { metabolism = 1, quality = 1, productivity = 1, fertility = 1, health = 1 } }))
    local date = { eventId = "BIRTH-1", cursorMonths = 100, atAgeMonths = 27, day = 4, month = 10, year = 2026 }
    local context = { isServer = true,
        persistPrepared = function(event) persisted[#persisted + 1] = event.stage; return true end,
        persistCommitted = function(event) persisted[#persisted + 1] = event.stage; return true end }
    return owner, dam, children, date, context
end
local originalDraw, originalRandom = RLGrowth.drawBirthWeight, math.random
RLGrowth.drawBirthWeight = function(...)
    birthDraws = birthDraws + 1
    return originalDraw(...)
end
math.random = function()
    randomCalls = randomCalls + 1
    return 0.2
end
local owner, dam, children, date, context = fixture()
local newborn = children[1]
local result = success(B.execute(owner, dam, date, context))
check("source birth: actual shared reproduce owns one birth draw and one normal survival roll",
    birthDraws == 1 and randomCalls == 3 and result.children == 1 and newborn.rlGrowth.source == "birth"
    and newborn.rlGrowth.birthWeightKg == newborn.weight and newborn.rlGrowth.ageMonths == 0)
check("source birth: PREPARED durably precedes RNG and COMMITTED follows actual birth",
    persisted[1] == "PREPARED" and persisted[2] == "COMMITTED"
    and owner.birthJournal[date.eventId].draws[1].weightKg == newborn.weight)
check("source birth: stable unborn identity, selected country and private source ownership survive",
    newborn.uniqueId == "UNBORN-1" and newborn.farmId == "SOURCE-FARM" and newborn.birthday.country == 4
    and newborn.clusterSystem == owner.clusterSystem and owner.byId[newborn.uniqueId] == newborn
    and #owner.animals == 2 and broadcasts == 0 and money == 0 and result.money == 0 and result.sold == 0)
check("source birth: gravid is removed once while tissue/reserve and normal parity/lactation survive",
    dam.weight == 500 and dam.rlGrowth.weightKg == 500 and dam.rlGrowth.reserveMassKg == 45
    and dam.rlGrowth.gravidKg == 0 and dam.birthCount == 1 and dam.isParent and dam.isLactating
    and dam.pregnancy == nil and not dam.isPregnant and dam.reproduction == 0 and dam.impregnatedBy == nil)
check("source birth: observed events never pretend to be assumed history",
    result.evidence == "OBSERVED_SOURCE_BIRTH" and owner.observedBirths[1].sireContext.uniqueId == "SIRE-FIXED"
    and owner.observedBirths[1].selected[1].uniqueId == "UNBORN-1")
local replay = success(B.execute(owner, dam, date, context))
check("source birth: committed request replay returns result without redraw or another calf",
    replay.newborns[1].uniqueId == newborn.uniqueId and birthDraws == 1 and randomCalls == 3 and #owner.animals == 2)
local full, fullDam, _, fullDate, fullContext = fixture(1)
local before = birthDraws
local denied, failure = B.execute(full, fullDam, fullDate, fullContext)
check("source birth: insufficient source capacity refuses before RNG, parity and maternal mutation",
    denied == nil and failure.reason == "SOURCE_BIRTH_CAPACITY" and birthDraws == before
    and fullDam.birthCount == 0 and fullDam.isPregnant and #full.animals == 1)
local blocked, blockedDam, _, blockedDate, blockedContext = fixture()
blockedContext.persistPrepared = function() error("prepare save fault") end
before = birthDraws
denied, failure = B.execute(blocked, blockedDam, blockedDate, blockedContext)
check("source birth: uncertain prepare save quarantines before birth RNG", denied == nil
    and failure.reason == "SOURCE_BIRTH_PREPARE_UNCERTAIN" and birthDraws == before and blockedDam.isPregnant)
denied, failure = B.execute(blocked, blockedDam, blockedDate, context)
check("source birth: uncertain persisted stages never redraw on retry", denied == nil and failure.reason == "SOURCE_BIRTH_UNCERTAIN" and birthDraws == before)
local commit, commitDam, _, commitDate, commitContext = fixture()
commitContext.persistCommitted = function() return false end
before = birthDraws
denied, failure = B.execute(commit, commitDam, commitDate, commitContext)
check("source birth: uncertain commit preserves observed calf and quarantines source ownership",
    denied == nil and failure.reason == "SOURCE_BIRTH_COMMIT_UNCERTAIN" and birthDraws == before + 1
    and #commit.animals == 2 and commit.quarantine[commitDam.uniqueId] ~= nil)
denied, failure = B.execute(commit, commitDam, commitDate, context)
check("source birth: uncertain commit retry cannot create duplicate offspring", denied == nil
    and failure.reason == "SOURCE_BIRTH_UNCERTAIN" and birthDraws == before + 1 and #commit.animals == 2)
local twinOwner, twinDam, twins, twinDate, twinContext = fixture(10, true)
before = birthDraws
local twinResult = success(B.execute(twinOwner, twinDam, twinDate, twinContext))
check("source birth: actual surviving twins retain two fixed identities and each one shared draw",
    twinResult.children == 2 and #twinOwner.animals == 3 and birthDraws == before + 2
    and twins[1].uniqueId == "UNBORN-1" and twins[2].uniqueId == "UNBORN-2" and twinDam.birthCount == 1)
-- Force normal infant mortality for one child; only the one-child continue is replaced
-- by break in this stock-Lua execution, so all actual mortality code remains exercised.
local deadOwner, deadDam, deadChildren, deadDate, deadContext = fixture()
local deadChild = deadChildren[1]
local originalSurvival = RLBirthWeight.getSurvivalChance
RLBirthWeight.getSurvivalChance = function() return 0 end
before = birthDraws
local mortality = success(B.execute(deadOwner, deadDam, deadDate, deadContext))
RLBirthWeight.getSurvivalChance = originalSurvival
check("source birth: normal infant mortality keeps draw evidence and never queues a dead calf",
    mortality.children == 0 and #deadOwner.animals == 1 and deadChild.isDead
    and birthDraws == before + 1 and #deadOwner.birthJournal[deadDate.eventId].draws == 1 and deadDam.birthCount == 1)
RLGrowth.drawBirthWeight, math.random = originalDraw, originalRandom
local parentOwner, parentDam, _, parentDate, parentContext = fixture()
parentDam.genetics.health = 0.25
local parentChild = parentDam.pregnancy.pregnancies[1]
local savedRandom = math.random
math.random = function() return 0.9 end
RLBirthWeight.getSurvivalChance = function() return 0 end
local parentDeath = success(B.execute(parentOwner, parentDam, parentDate, parentContext))
math.random, RLBirthWeight.getSurvivalChance = savedRandom, originalSurvival
check("source birth: normal maternal mortality stays source-owned without player death lifecycle",
    parentDeath.parentDied == true and parentDam.isDead == true and parentChild.isDead == true and broadcasts == 0 and money == 0)
local ownerReplay = success(B.execute(parentOwner, parentDam, parentDate, parentContext))
check("source birth: a committed maternal-death result is still idempotent", ownerReplay.parentDied and ownerReplay.children == 0)
local rawOwner, rawDam = fixture()
local rawSourceContext = { mode = "DEALER_SOURCE", isServer = false, sourceId = rawOwner.rlDealerSourceId,
    clusterSystem = rawOwner.clusterSystem, spec = rawOwner.spec, sireContext = rawOwner.sireContexts[rawDam.uniqueId] }
local originalParity, drawsBefore = rawDam.birthCount, birthDraws
local invalidCount, _, _, _, rawReason = AnimalReproduction.reproduce(rawDam, rawOwner.spec, 4, 10, 2026, false, rawSourceContext)
check("source birth: shared entry rejects unauthorized source context before RNG or parity",
    invalidCount == nil and rawReason == "SOURCE_BIRTH_CONTEXT" and birthDraws == drawsBefore and rawDam.birthCount == originalParity)
RLGrowth.drawBirthWeight, math.random = originalDraw, originalRandom
-- End-to-end exact-term bridge: hourly source feeding reaches the boundary without
-- an epsilon, then real source offspring commit and a separate observed event allows
-- subsequent physiology to resume. Original assumed history remains unchanged.
loadMod("scripts/dealer/RLDealerSourceState.lua")
local R, S = RLDealerReplay, RLDealerSourceState
local entry = { breedingWeightRatio = 0.55, profile = { minRecoveryMonth = 3 } }
local history = Sim.history(seed, 20.25, "NORMAL_PRODUCTION", { { kind = "CONCEPTION", atMonths = 17.125, parity = 1 } })
local replayOptions = { daysPerMonth = 1, entry = entry, pregnancySubTypes = { [4] = { seed.subType } } }
local initial = success(R.run(seed, history, replayOptions))
local sourceRecord = success(S.capture(initial, 200))
local refused, refusal = R.resume(initial, 27.125, { daysPerMonth = 1, entry = entry })
check("source observed bridge: ordinary progression remains closed at pregnancy term", refused == nil and refusal.reason == "SOURCE_CALVING_REQUIRED")
local pending = success(R.runToSourceBirth(initial, 27.125, { daysPerMonth = 1, entry = entry }))
check("source observed bridge: dedicated pending endpoint integrates exactly to term and cannot be listed/saved",
    pending.state.ageMonths == 27.125 and pending.animal.reproduction == 100 and pending.sourceBirthBoundary.atAgeMonths == 27.125
    and not S.capture(pending, 206.875))
local actualOwner, actualDam, actualChildren, actualDate, actualContext = fixture()
-- Install already-integrated source physiology before invoking the durable real birth
-- service. The true fetus and its stable identity remain owned by the private source.
actualDam.age, actualDam.weight, actualDam.health = pending.animal.age, pending.animal.weight, pending.animal.health
actualDam.rlGrowth = RLGrowth.copyState(pending.animal.rlGrowth)
actualDam.bodyCondition = RLBodyCondition.copyState(pending.animal.bodyCondition)
actualDam.rlFeedGain, actualDam.rlHealthCarry = pending.animal.rlFeedGain, pending.animal.rlHealthCarry
actualDate.eventId, actualDate.atAgeMonths, actualDate.cursorMonths = "OBSERVED-1", 27.125, 206.875
local testRandom = math.random; math.random = function() return 0.2 end
success(B.execute(actualOwner, actualDam, actualDate, actualContext))
math.random = testRandom
local observed = success(B.captureObserved(sourceRecord, pending, actualOwner, actualDam, actualDate.eventId, actualDate.cursorMonths))
check("source observed bridge: committed birth appends evidence without changing assumed sale or past mating",
    observed.history.saleAgeMonths == 20.25 and #observed.history.events == #history.events
    and observed.observedSourceEvents.version == 1 and observed.observedSourceEvents.events[1].atAgeMonths == 27.125
    and observed.animal.birthCount == 1 and observed.animal.rlGrowth.gravidKg == 0 and observed.session.conceptionMonths == nil)
local function resolver(name) local _, sub = Economics.find(name); return sub end
local resumedSource = success(S.restore(observed, resolver))
local postpartum = success(R.resume(resumedSource, 27.375, { daysPerMonth = 3, entry = entry }))
local postpartumRecord = success(S.advanceCursor(observed, postpartum, 207.125))
check("source observed bridge: save/restore and future real-feed progression retain observed parity and lactation",
    postpartumRecord.animal.birthCount == 1 and postpartumRecord.animal.isLactating
    and postpartumRecord.animal.monthsSinceLastBirth == 0.25 and postpartumRecord.animal.rlGrowth.gravidKg == 0
    and postpartumRecord.observedSourceEvents.events[1].eventId == actualDate.eventId
    and postpartumRecord.birthOriginMonths == sourceRecord.birthOriginMonths)
local changed = success(S.restore(postpartumRecord, resolver))
changed.observedSourceEvents.events[1].draws[1].weightKg = changed.observedSourceEvents.events[1].draws[1].weightKg + 1
check("source observed bridge: mismatched observed newborn mass evidence rejects strictly", not S.capture(changed, 207.125))
local fake = success(S.restore(postpartumRecord, resolver))
fake.observedSourceEvents.events[1].evidence = "MODEL_ASSUMED"
check("source observed bridge: an assumed event cannot pose as an actual source calving", not S.capture(fake, 207.125))
