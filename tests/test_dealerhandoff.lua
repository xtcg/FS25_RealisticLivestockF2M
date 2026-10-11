loadMod("tests/dealerreplaysim.lua")
loadMod("scripts/dealer/RLDealerSourceState.lua")
loadMod("scripts/dealer/RLDealerHandoff.lua")
-- Load the actual Animal constructor while retaining the already loaded simulation methods.
-- A negative-age shell with explicit selected genes avoids constructor growth derivation and
-- random birthdays. A real prepared birthday is installed explicitly before handoff.
loadAnimalSection("local Animal_mt = Class(Animal)", "function Animal:delete()")
loadAnimalSection("function Animal:setBirthday", "function Animal:setUniqueId")
loadAnimalSection("function Animal:getSubTypeIndex", "function Animal:increaseAge")
loadAnimalSection("function Animal:setDirty", "function Animal:getRidableFilename")
local H, S, R, Sim = RLDealerHandoff, RLDealerSourceState, RLDealerReplay, DealerReplaySim
local seed = Sim.seed("HOLSTEIN", "female", 1)
local index = Economics.find(seed.subType.name)
local oldAnimalSystem = g_currentMission.animalSystem
oldAnimalSystem.getSubTypeByName = function(_, name) local _, sub = Economics.find(name); return sub end
oldAnimalSystem.getTypeIndexBySubTypeIndex = function(_, i) return Economics.subTypes[i].typeIndex end
oldAnimalSystem.types = {}
g_currentMission.environment.weather = { temperatureUpdater = { currentMin = 20 } }
Animal.getDefaultMarks = function() return {} end
Animal.isHorse = function() return false end
-- These are engine input/output surface adapters, not the constructor or handoff logic.
Animal.updateInput = function(self) self.input.food = 0 end
Animal.updateOutput = function(self) self.output.milk = 0 end
local birthday = { day = 12, month = 2, year = 2025, lastAgeMonth = 10, country = 1 }
local function makeTarget()
    local a = Animal.new({ age = -1, weight = 35, health = 100, gender = "female", subTypeIndex = index,
        genetics = { metabolism = 1, quality = 1, productivity = 1, fertility = 1, health = 1 },
        uniqueId = "PREPARED-DAM-1", farmId = "FARM-1" })
    a:setBirthday(birthday)
    a.clusterSystem = { owner = { farmId = 1 }, setDirty = function() error("publication belongs to commit") end }
    a.children, a.motherId, a.fatherId, a.name = { "existing lineage" }, "MOTHER", "FATHER", "Selected name"
    return a
end
local result = assert(R.run(seed, Sim.history(seed, 8.5), { daysPerMonth = 1 }))
local record = assert(S.capture(result, 100))
local target = makeTarget()
local identity, cluster, lineage = target.uniqueId, target.clusterSystem, target.children
local oldOwner = {}
for _, key in ipairs({ "rlFeedStepOwner", "rlFeedLastMilk", "rlFeedIntake", "rlMilkPaid", "rlNutrition", "rlMilk", "rlInfoRows", "rlGrowthCurve", "rlGrowthPeek" }) do target[key] = oldOwner end
target.rlFeedStepTick, target.rlFeedPlanLiters, target.rlGrowthDropped, target.sale = 24, 99, true, { purpose = "OLD" }
local beforeGrowth = target.rlGrowth
local receipt = assert(H.install(record, target, { isServer = true }))
check("handoff adapter: real Animal shell receives exact physiology without identity or ownership changes",
    target.weight == record.animal.weight and target.rlGrowth.weightKg == record.animal.weight
    and target.uniqueId == identity and target.clusterSystem == cluster and target.birthday == birthday
    and target.children == lineage and target.motherId == "MOTHER" and target.fatherId == "FATHER" and target.name == "Selected name"
    and target.subTypeIndex == index and target.isDirty == true)
check("handoff adapter: old feed, milk, nutrition and curve caches are explicitly cleared",
    target.rlFeedStepTick == nil and target.rlFeedStepOwner == nil and target.rlFeedLastMilk == nil
    and target.rlFeedIntake == nil and target.rlFeedPlanLiters == nil and target.rlMilkPaid == nil
    and target.rlNutrition == nil and target.rlMilk == nil and target.rlInfoRows == nil
    and target.rlGrowthDropped == nil and target.rlGrowthCurve == nil and target.rlGrowthPeek == nil and target.sale == nil)
check("handoff adapter: historical ticks never suppress first player hour or pay historical milk",
    target.rlHistoryReplay == nil and target.rlGrowth.lastTick == -1 and target.bodyCondition.lastTick == -1
    and target.rlFeedGain == record.animal.rlFeedGain and target.rlHealthCarry == record.animal.rlHealthCarry)
check("handoff adapter: pre-publication compensation restores old references and nil fields", H.rollback(receipt)
    and target.age == -1 and target.rlGrowth == beforeGrowth and target.rlMilkPaid == oldOwner and target.sale.purpose == "OLD")
local duplicate, why = H.rollback(receipt)
check("handoff adapter: compensation receipt is single-use", not duplicate and why == "HANDOFF_RECEIPT")
local function denied(context, edit, reason)
    local a = makeTarget()
    if edit then edit(a) end
    local originalAge, originalWeight, originalGenes, originalGrowth, originalCluster = a.age, a.weight, a.genetics, a.rlGrowth, a.clusterSystem
    local bad, failure = H.install(record, a, context)
    return bad == nil and failure.reason == reason and a.age == originalAge and a.weight == originalWeight
        and a.genetics == originalGenes and a.rlGrowth == originalGrowth and a.clusterSystem == originalCluster
end
check("handoff adapter: client invocation refuses before target mutation", denied({ isServer = false }, nil, "HANDOFF_SERVER_ONLY"))
check("handoff adapter: missing persistent identity refuses atomically", denied({ isServer = true }, function(a) a.uniqueId = nil end, "HANDOFF_IDENTITY"))
check("handoff adapter: missing prepared birthday refuses atomically", denied({ isServer = true }, function(a) a.birthday = nil end, "HANDOFF_BIRTHDAY"))
check("handoff adapter: detached replay animal cannot be mistaken for a real target", denied({ isServer = true }, function(a) a.rlHistoryReplay = true end, "HANDOFF_TARGET"))
check("handoff adapter: callback failure during prepare cannot partially install target", denied({ isServer = true }, function(a) a.getSubType = function() error("fault") end end, "HANDOFF_PREPARE_ERROR"))
local tick = RLBodyCondition.getTickId()
check("handoff adapter: historical source cannot label current tick without explicit live settlement", denied({ isServer = true, completedLiveTick = tick }, nil, "HANDOFF_LIVE_HOUR"))
check("handoff adapter: settled proof cannot refer to a different live tick", denied({ isServer = true, completedLiveTick = tick + 1, liveHourAlreadySettled = true }, nil, "HANDOFF_LIVE_HOUR"))
local settled = makeTarget()
assert(H.install(record, settled, { isServer = true, completedLiveTick = tick, liveHourAlreadySettled = true }))
check("handoff adapter: explicitly settled live hour deduplicates both growth paths and milk deposit",
    settled.rlGrowth.lastTick == tick and settled.rlFeedStepTick == tick and settled.rlFeedStepOwner == nil
    and settled.bodyCondition.lastTick == tick and settled.rlMilkPaid.tick == tick
    and settled.rlMilkPaid.deposited == true and settled.rlMilkPaid.litersPerHour == 0)
local changed = makeTarget()
local conflict = assert(H.install(record, changed, { isServer = true }))
changed.rlGrowth.reserveMassKg = changed.rlGrowth.reserveMassKg + 1
local restored, reason = H.rollback(conflict)
check("handoff adapter: compensation never overwrites physiology changed after installation", not restored and reason == "HANDOFF_CHANGED")
local changedOwner = makeTarget()
local ownerReceipt = assert(H.install(record, changedOwner, { isServer = true }))
changedOwner.clusterSystem = {}
restored, reason = H.rollback(ownerReceipt)
check("handoff adapter: compensation never overwrites a destination ownership change", not restored and reason == "HANDOFF_OWNERSHIP")
local entry = { breedingWeightRatio = 0.55, profile = { minRecoveryMonth = 3 } }
local pregnantHistory = Sim.history(seed, 20.25, "NORMAL_PRODUCTION", { { kind = "CONCEPTION", atMonths = 17.125, parity = 1 } })
local pregnant = assert(R.run(seed, pregnantHistory, { daysPerMonth = 1, entry = entry, pregnancySubTypes = { [4] = { seed.subType } } }))
local mother = assert(S.capture(pregnant, 200))
local dam = makeTarget()
local child = Animal.new({ age = -1, health = 100, weight = 35, gender = "female", subTypeIndex = index,
    genetics = { metabolism = 1, quality = 1, productivity = 1, fertility = 1, health = 1 }, uniqueId = "PREPARED-CHILD-1", farmId = "FARM-1" })
dam.pregnancy = { duration = 10, pregnancies = { child }, expected = { day = 10, month = 8, year = 2027 } }
local ownership = dam.pregnancy
assert(H.install(mother, dam, { isServer = true }))
check("handoff adapter: real unborn animals and expected-birth ownership survive installation exactly",
    dam.pregnancy == ownership and dam.pregnancy.pregnancies[1] == child and child.uniqueId == "PREPARED-CHILD-1"
    and dam.weight == mother.animal.weight and dam.rlGrowth.gravidKg == mother.animal.rlGrowth.gravidKg)
-- Exercise the ordinary player feeding path after actual installation. The first hour
-- must advance; historical hours are never deduplication tokens for live feeding.
Animal.getInput = function(self, key) return self.input[key] or 0 end
Animal.getHealthFactor = function(self) return self.health / 100 end
Animal.getDiseaseMultipliers = function() return nil, 0 end
seed.subType.healthThresholdFactor = 0.45
FeedSim.setMode(true)
local live = makeTarget()
assert(H.install(record, live, { isServer = true }))
local livePen = FeedSim.makePen({ live }, { FORAGE = 1e9, PEA = 1e9, MAIZE = 1e9 })
local initialAge = live.rlGrowth.ageMonths
FeedSim.hour(livePen)
check("handoff adapter: first real player-feed hour advances exactly once after history handoff",
    near(live.rlGrowth.ageMonths - initialAge, 1 / 24, 1e-8) and live.rlFeedStepTick == RLBodyCondition.getTickId())
local settledLive = makeTarget()
local settledTick = RLBodyCondition.getTickId()
assert(H.install(record, settledLive, { isServer = true, completedLiveTick = settledTick, liveHourAlreadySettled = true }))
local settledPen = FeedSim.makePen({ settledLive }, { FORAGE = 1e9, PEA = 1e9, MAIZE = 1e9 })
local settledAge, settledWeight = settledLive.rlGrowth.ageMonths, settledLive.weight
GrowthSim.env.currentHour = GrowthSim.env.currentHour - 1
FeedSim.hour(settledPen)
check("handoff adapter: real-feed destination skips explicitly settled transfer hour",
    settledLive.rlGrowth.ageMonths == settledAge and settledLive.weight == settledWeight
    and settledLive.rlMilkPaid.deposited == true and settledLive.rlMilkPaid.litersPerHour == 0)
FeedSim.hour(settledPen)
check("handoff adapter: settled transfer resumes normal real-feed growth next hour",
    near(settledLive.rlGrowth.ageMonths - settledAge, 1 / 24, 1e-8))
