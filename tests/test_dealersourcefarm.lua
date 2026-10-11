loadMod("tests/dealerreplaysim.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/dealer/RLDealerSourceState.lua")
loadMod("scripts/dealer/RLDealerClock.lua")
loadMod("scripts/dealer/RLDealerSourceFarm.lua")
local F, S, R, Sim = RLDealerSourceFarm, RLDealerSourceState, RLDealerReplay, DealerReplaySim
local seed = Sim.seed("HOLSTEIN", "female", 1)
local function resolve(name) local _, sub = Economics.find(name); return sub end
local function entry() return { breedingWeightRatio = 0.55, profile = { minRecoveryMonth = 3 } } end
local farm = assert(F.new("source-farm", 100))
local initial = assert(S.capture(assert(R.run(seed, Sim.history(seed, 8), { daysPerMonth = 1 })), 100))
assert(F.add(farm, "dam-A", initial))
check("source farm: independent source ledger rejects duplicate ownership", not F.add(farm, "dam-A", initial)
    and farm.sources["dam-A"] ~= initial)
local random = math.random; math.random = function() error("source update cannot redraw history") end
assert(F.advanceSegments(farm, { { hours = 12, daysPerMonth = 1 }, { hours = 36, daysPerMonth = 3 } }, resolve, entry))
math.random = random
local reference = assert(R.run(seed, Sim.history(seed, 9), { daysPerMonth = { 1,1,1,1,1,1,1,1,1 } }))
-- The mixed calendar is supplied per real elapsed segment rather than guessed
-- from the animal's birth month; compare the same split hourly reference.
local split = assert(R.resume(assert(R.resume(assert(R.run(seed, Sim.history(seed, 8), { daysPerMonth = 1 })),
    8.5, { daysPerMonth = 1 })), 9, { daysPerMonth = 3 }))
check("source farm: mixed calendar advances source and shared clock exactly once", farm.clock.months == 101
    and farm.sources["dam-A"].ageMonths == 9 and farm.sources["dam-A"].animal.weight == split.animal.weight
    and reference.animal.weight > 0)
local saved = assert(F.restore(F.export(farm)))
local reads = F.get(farm, "dam-A"); reads.animal.weight = -1
check("source farm: reads and saved snapshots cannot mutate ownership", farm.sources["dam-A"].animal.weight > 0
    and saved.sources["dam-A"] ~= farm.sources["dam-A"])
local before = RLTradePersistence.canonical(F.export(farm))
local no, why = F.advanceSegments(farm, { { hours = 12, daysPerMonth = 3 }, { hours = 1, daysPerMonth = 0 } }, resolve, entry)
check("source farm: bad later calendar rolls back all ledgers", no == nil and before == RLTradePersistence.canonical(F.export(farm)))
no, why = F.advanceSegments(farm, { { hours = 1, daysPerMonth = 3 } }, function() return nil end, entry)
check("source farm: missing mods refuse without subtype remapping", no == nil and why == "SOURCE_SUBTYPE"
    and before == RLTradePersistence.canonical(F.export(farm)))
local history = Sim.history(seed, 27, "NORMAL_PRODUCTION", { { kind = "CONCEPTION", atMonths = 17.125, parity = 1 } })
local mother = assert(R.run(seed, history, { daysPerMonth = 1, entry = entry(), pregnancySubTypes = { [4] = { seed.subType } } }))
assert(F.add(farm, "dam-B", assert(S.capture(mother, 101))))
before = RLTradePersistence.canonical(F.export(farm))
no, why = F.advanceSegments(farm, { { hours = 3, daysPerMonth = 1 } }, resolve, entry)
check("source farm: due birth requires real reproduction before publishing any batch changes", no == nil
    and why == "SOURCE_CALVING_REQUIRED" and before == RLTradePersistence.canonical(F.export(farm)))
local corrupt = F.export(farm); corrupt.sources["dam-A"].cursorMonths = 100
check("source farm: restore refuses unaligned physiology cursors", not F.restore(corrupt))
