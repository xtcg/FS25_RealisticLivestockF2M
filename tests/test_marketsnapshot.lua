-- Integration with shipped subtype XML, real policy, growth-clock, body-condition
-- and Disease objects. Sentinel live methods must never be invoked or written.
loadMod("tests/breedingvalue_fixture.lua")
loadMod("scripts/core/RLConstants.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/dealer/RLDealerStockPolicy.lua")
loadMod("scripts/disease/RLDiseaseRecord.lua")
loadMod("scripts/disease/RLDiseaseStatus.lua")
loadMod("scripts/disease/Disease.lua")
loadMod("scripts/market/RLMarketSchema.lua")
loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLMarketSpecies.lua")
loadMod("scripts/market/RLMarketSnapshot.lua")
local context = { classRevision = "classes1", traitMappingRevision = "traits1" }
local policy = RLDealerStockPolicy.getConfig()
local deps = { dealerConfig = policy, diseasesEnabled = true }
local function classify(name, typeName)
    return RLMarketSpecies.resolve(BV_SUB[name], typeName, { dealerConfig = policy })
end
check("U07 Swiss Brown retains dealer dairy class", classify("BULL_SWISS_BROWN", "COW").productionClass == "DAIRY")
local simmental = { name = "SIMMENTAL_TEST", breed = "SIMMENTAL", typeIndex = 1 }
local dual = RLMarketSpecies.resolve(simmental, "COW", { dealerConfig = policy })
check("U07 Simmental retains existing dual policy", dual.productionClass == "DUAL" and dual.classificationSource == "DEALER_USE")
local pigSame = RLMarketSpecies.resolve({ name = "PIG_SWISS_BROWN", breed = "SWISS_BROWN" }, "PIG", { dealerConfig = policy })
check("U07 same breed text cannot cross species", pigSame == nil)
check("U07 GOAT is distinct from sheep", classify("RAM_GOAT", "SHEEP").speciesKey == "GOAT")
local unsupported, why = RLMarketSpecies.resolve({ name = "MILKCOW_HOLSTEIN", breed = "HOLSTEIN" }, "MILKCOW", { dealerConfig = policy })
check("U07 HB MILKCOW explicitly unsupported", unsupported == nil and why == "UNSUPPORTED_SPECIES:MILKCOW")
local unknown = RLMarketSpecies.resolve({ name = "UNKNOWN_BULL", breed = "UNKNOWN" }, "COW", { dealerConfig = policy })
check("U07 unknown cattle class is not guessed", unknown == nil)
check("U07 policy read never loads dealer runtime", RLDealerRuntime == nil)
local a = bvAnimal("BULL_HOLSTEIN", 18, { farmId = "123456", uniqueId = "12345", birthday = { country = 2, day = 1 },
    isIndividual = true, isDead = false, canBeSold = true, health = 97, birthCount = 0,
    bodyCondition = { version = 1, reserve = 0.52, capacityKg = 100 },
    rlGrowth = { version = 1, ageMonths = 18.25 } })
local liveCalls = 0
for _, name in ipairs({ "getSellPrice", "getCanBeSold", "resolveBirthCount", "updateWeight" }) do
    a[name] = function() liveCalls = liveCalls + 1; error("mutable live method invoked") end
end
local function rawAnimal()
    local out = {}
    for k, v in pairs(a) do if type(v) ~= "function" then out[k] = v end end
    return assert(RLMarketData.fingerprint(out))
end
local before = rawAnimal()
local s, reason = RLMarketSnapshot.capture(a, context, deps)
assert(s, reason)
check("U08 snapshot satisfies production schema", RLMarketSchema.validateSnapshot(s))
check("U08 complete full identity and continuous age", s.identityKey == "123456 12345 2" and s.ageMonths == 18.25)
check("U08 read-only capture leaves exact raw animal unchanged", before == rawAnimal() and liveCalls == 0)
check("U08 male inherits verified breeding roles without own gestation", s.supportedBreedingRoles[1] == "DAIRY" and s.reproductive.gestationMonths == 10)
check("U08 real health genes and reproductive state copied", s.health == 97 and s.genes.productivity == 1 and s.reproductive.parity == 0 and s.reproductive.pregnant == false)
check("U08 male dairy capability verified through female subtype", s.traitCapabilities.milkOutput and s.traitCapabilities.milkProductivity and s.production.milkSourceSubType == "COW_HOLSTEIN")
check("U08 actual saved body condition uses distinct units", s.production.finishScore == RLBodyCondition.getFinishScore(a)
    and s.production.bcs == RLBodyCondition.getBCS(a) and s.production.slaughterReferenceKg == AnimalMoveEvent.getCarcassReferenceWeight(a, nil, a.subTypeIndex))
check("U08 repeated captures deterministic", RLMarketSnapshot.capture(a, context, deps).stateRevision == s.stateRevision)
s.genes.quality = 2
check("U08 detached genes never alter source", a.genetics.quality == 1)
local baseline = RLMarketSnapshot.capture(a, context, deps).stateRevision
for _, change in ipairs({
    function() a.weight = a.weight + 0.1 end,
    function() a.genetics.fertility = 1.01 end,
    function() a.health = 96.9 end,
    function() a.isCastrated = true end,
    function() a.birthCount = 1 end,
    function() a.bodyCondition.reserve = 0.53 end,
    function() a.rlGrowth.ageMonths = 18.26 end,
}) do
    change()
    local nextRevision = assert(RLMarketSnapshot.capture(a, context, deps)).stateRevision
    check("U08 economic state change invalidates fingerprint", nextRevision ~= baseline)
    baseline = nextRevision
end
local model = { title = "TEST", archetype = "infectious", endpoint = "recovers", salePrice = 0.7 }
local disease = Disease.new(model)
disease.state = "INFECTIOUS"
disease.monthsElapsed = 0.5
a.diseases = { disease }
local diseased = assert(RLMarketSnapshot.capture(a, context, deps))
check("U08 actual Disease object projects state and forbids symptomatic trade", diseased.diseases[1].state == "INFECTIOUS" and diseased.eligibility.tradeAllowed == false)
disease.monthsElapsed = 0.6
local progressed = assert(RLMarketSnapshot.capture(a, context, deps))
check("U08 severity/progression changes with same disease count invalidate state", diseased.stateRevision ~= progressed.stateRevision)
disease.severity = 0.4
check("U08 explicit severity also invalidates", progressed.stateRevision ~= RLMarketSnapshot.capture(a, context, deps).stateRevision)
local sheep = bvAnimal("RAM_LANDRACE", 5, { farmId = "123456", uniqueId = "12346", birthday = { country = 2 }, isDead = false })
local lamb = assert(RLMarketSnapshot.capture(sheep, context, deps))
check("U08 wool productivity never fabricates sheep milk", lamb.genes.productivity == 1 and lamb.traitCapabilities.milkProductivity == false and lamb.production.milkSourceSubType == nil)
sheep.genetics, sheep.birthCount, sheep.bodyCondition, sheep.health = nil, nil, nil, nil
local missing = assert(RLMarketSnapshot.capture(sheep, context, deps))
check("U08 missing measurements stay absent with false capabilities", missing.genes == nil and missing.health == nil and missing.reproductive.parity == nil
    and missing.production.bcs == nil and missing.traitCapabilities.health == false and missing.traitCapabilities.gene_quality == false and missing.traitCapabilities.parity == false)
sheep.birthday = nil
local noId, noIdReason = RLMarketSnapshot.capture(sheep, context, deps)
check("U08 refuses partial identity", noId == nil and noIdReason == "INCOMPLETE_IDENTITY")
check("U08 fingerprint key order invariant", RLMarketData.fingerprint({ a = 1, b = 2 }) == RLMarketData.fingerprint({ b = 2, a = 1 }))
check("U08 fingerprint same-length values differ", RLMarketData.fingerprint({ a = 12 }) ~= RLMarketData.fingerprint({ a = 21 }))
check("U08 fingerprint delimiters and types do not collide", RLMarketData.fingerprint({ [1] = "2:a" }) ~= RLMarketData.fingerprint({ ["1"] = "2:a" }))
check("U08 fingerprint rejects executable and nonfinite data", RLMarketData.fingerprint(setmetatable({}, {})) == nil and RLMarketData.fingerprint({ a = math.huge }) == nil)
-- Pregnancy is copied as immutable data, including fetal genes and expected date.
a.pregnancy = { duration = 9, expected = { day = 1, month = 2, year = 3 }, pregnancies = { { genetics = { quality = 1.2 } } } }
a.isPregnant = true
local pregnant = assert(RLMarketSnapshot.capture(a, context, deps))
a.pregnancy.pregnancies[1].genetics.quality = 1.3
check("U08 fetal genetics and pregnancy progress are fingerprinted", pregnant.stateRevision ~= RLMarketSnapshot.capture(a, context, deps).stateRevision
    and pregnant.reproductive.pregnancy.pregnancies[1].genetics.quality == 1.2)
local maleSub, femaleSub = BV_SUB.BULL_HOLSTEIN, BV_SUB.COW_HOLSTEIN
local maleOutput, femaleOutput = maleSub.output, femaleSub.output
local milk = femaleOutput.milk
-- HB bull semen shares output.milk; real cow milk may arrive as pallets.
BV_FILL.BULLSPERM = 99
maleSub.output = { milk = { fillType = 99, get = function() return 10 end } }
femaleSub.output = { pallets = milk }
local palletMilk = assert(RLMarketSnapshot.capture(a, context, deps))
check("U08 semen is not milk; HB milk pallets verify dairy capability", palletMilk.production.milkSourceSubType == femaleSub.name and palletMilk.production.milkFillType == BV_FILL.MILK)
femaleSub.output = {}
local noMilk = assert(RLMarketSnapshot.capture(a, context, deps))
check("U08 absent real milk output does not fabricate dairy ability", noMilk.traitCapabilities.milkProductivity == false and noMilk.production.milkFillType == nil)
maleSub.output, femaleSub.output = maleOutput, femaleOutput
local cycle = {}; cycle.self = cycle
check("U08 canonical data rejects cycles and nonfinite keys", RLMarketData.fingerprint(cycle) == nil and RLMarketData.fingerprint({ [math.huge] = 1 }) == nil)
-- An alias with the exact same real curve is safe, but source choice must not
-- depend on animalSystem table layout. Distinct opaque curves are ambiguous.
local system = g_currentMission.animalSystem
local savedSubs = system.subTypes
local alias = table.clone(femaleSub)
alias.name = "AAA_HOLSTEIN_ALIAS"
alias.output = { milk = femaleSub.output.milk }
system.subTypes = { z = femaleSub, a = alias }
local aliasFirst = assert(RLMarketSnapshot.capture(a, context, deps))
system.subTypes = { z = alias, a = femaleSub }
local aliasLast = assert(RLMarketSnapshot.capture(a, context, deps))
check("U08 female aliases use stable source independent of iteration", aliasFirst.stateRevision == aliasLast.stateRevision
    and aliasFirst.production.milkSourceSubType == alias.name)
alias.output = { milk = { fillType = BV_FILL.MILK, get = function() return 999 end } }
local conflict = assert(RLMarketSnapshot.capture(a, context, deps))
check("U08 incompatible female milk curves fail closed", conflict.traitCapabilities.milkOutput == false
    and conflict.capabilityReasons.milk == "AMBIGUOUS_MILK_CURVE" and conflict.production.milkSourceSubType == nil)
system.subTypes = savedSubs
