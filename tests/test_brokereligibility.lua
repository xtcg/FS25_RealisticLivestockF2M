loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLBrokerConditionPackage.lua")
loadMod("scripts/market/RLBrokerEligibility.lua")
local P, E = RLBrokerConditionPackage, RLBrokerEligibility
local function copy(v) return assert(RLMarketData.copy(v)) end
local function fixture(kind)
    local species = kind:sub(1, 3) == "pig" and "PIG" or (kind:sub(1, 6) == "cattle" and "COW" or "SHEEP")
    local grower = kind == "cattleWeaned" or kind == "cattleStore" or kind == "pigGrower" or kind == "lambGrower"
    local o = {allowedProductionClasses = kind == "cattleLactating" and {"DAIRY"} or {"BEEF"}, requiredBreedId = not grower and species .. ":TEST" or nil, breedingObjective = "MATERNAL", finishingStages = {"FINISHING"}, breedingStages = {"BREEDING_READY"}, indexWeights = {fertility = 0.6, health = 0.4}}
    local p = assert(P.compile(assert(P.candidate(kind, o))))
    local s = {identityKey = "1 2 3", speciesKey = species, breedId = species .. ":TEST", productionClass = o.allowedProductionClasses[1], gender = "female", ageMonths = 24, health = 98, weightKg = 500, castrated = false, production = {finishScore = 50, bcs = 3.2, fatClass = "3L", slaughterReferenceKg = 700}, reproductive = {pregnant = false, lactating = false, parity = 0, isParent = false, monthsSinceLastBirth = 0}, genes = {quality = 1.5, productivity = 1.5, fertility = 1.5, health = 1.5}, supportedBreedingRoles = {"DAIRY", "TERMINAL", "MATERNAL"}, eligibility = {tradeAllowed = true}, traitCapabilities = {health = true, weight = true, castrated = true, pregnancy = true, lactation = true, parity = true, finishScore = true, bcs = true, fatClass = true, slaughterReference = true, tradeEligibility = true, milkOutput = true, milkProductivity = true, gene_quality = true, gene_productivity = true, gene_fertility = true, gene_health = true}}
    local c = {permissionGranted = true, ownershipVerified = true, identityVerified = true, unlocked = true, orderOpen = true, sourceSupported = true, quota = {order = 1, species = 8, breed = 4}, facts = {weaned = true, developmentReady = true, finished = false, currentBreedingReady = true, breedingStock = false, slaughterBasisAvailable = true, minimumPurchaseKg = 10, ageReferenceKg = 500, standardFinishKg = 700, breedingMinimumWeightKg = 20, actualMinimumAgeMonths = 1, useExitAgeMonths = 90, remainingUseMonths = 30, pregnancyProgress = 0.5, finishingStage = "FINISHING", breedingStage = "BREEDING_READY"}, factCapabilities = {}}
    s.traitCapabilities.reproduction = true
    for key in pairs(c.facts) do c.factCapabilities[key] = true end
    if kind == "cattleWeaned" then s.ageMonths = 7 end
    if kind == "cattleStore" then s.gender = "male"; s.ageMonths = 12; s.weightKg = 550 end
    if kind == "cattleFinished" then s.ageMonths = 20; s.weightKg = 700; s.production.finishScore = 70 end
    if kind == "cattlePregnant" then s.ageMonths = 30; s.reproductive.pregnant = true; s.reproductive.parity = 2; c.facts.currentBreedingReady = false end
    if kind == "cattleLactating" then s.ageMonths = 30; s.reproductive.lactating = true; s.reproductive.isParent = true; s.reproductive.parity = 2; s.genes.fertility = 0.95 end
    if kind == "cattleSire" then s.gender = "male" end
    if species == "PIG" then c.facts.standardFinishKg = 100; s.weightKg = 100; s.ageMonths = 8 end
    if kind == "pigGrower" then s.ageMonths = 3; s.weightKg = 40 end
    if kind == "pigFinished" then s.ageMonths = 6 end
    if kind == "pigSire" then s.ageMonths = 12; s.gender = "male" end
    if species == "SHEEP" then c.facts.standardFinishKg = 50; s.weightKg = 50; s.ageMonths = 10 end
    if kind == "lambGrower" then s.ageMonths = 5; s.weightKg = 35 end
    if kind == "lambFinished" then s.ageMonths = 8 end
    if kind == "ramSire" then s.ageMonths = 12; s.gender = "male" end
    return s, p, c
end
for _, kind in ipairs({"cattleWeaned", "cattleStore", "cattleFinished", "cattleReplacement", "cattlePregnant", "cattleLactating", "cattleSire", "pigGrower", "pigFinished", "pigReplacement", "pigSire", "lambGrower", "lambFinished", "eweReplacement", "ramSire"}) do
    local s, p, c = fixture(kind)
    local r = E.evaluate(s, p, c)
    check("eligibility: constructed candidate can pass " .. kind, r.eligible and r.status == "PASS")
    s.health = 0
    local rejected = E.evaluate(s, p, c)
    check("eligibility: fixed unhealthy counterexample " .. kind, not rejected.eligible and #rejected.failures > 0)
end
local function mutate(name, kind, change, status)
    local s, p, c = fixture(kind); change(s, p, c)
    local r = E.evaluate(s, p, c)
    check("eligibility: " .. name, r.status == status)
    return r
end
mutate("store lower385 at Wref700 passes", "cattleStore", function(s) s.weightKg = 385 end, "PASS")
mutate("store upper560 at Wref700 passes", "cattleStore", function(s) s.weightKg = 560; s.production.finishScore = 60 end, "PASS")
mutate("store570 rejects despite low finish", "cattleStore", function(s) s.weightKg = 570 end, "FAIL")
mutate("store below385 rejects", "cattleStore", function(s) s.weightKg = 384.99 end, "FAIL")
mutate("store finish65 rejects", "cattleStore", function(s) s.production.finishScore = 65 end, "FAIL")
mutate("store castrated valid with own real Wref", "cattleStore", function(s) s.castrated = true; s.weightKg = 480; s.production.slaughterReferenceKg = 600 end, "PASS")
mutate("store missing Wref unknown", "cattleStore", function(s) s.production.slaughterReferenceKg = nil; s.targetWeightKg = 700 end, "UNKNOWN")
mutate("store missing finish capability unknown", "cattleStore", function(s) s.traitCapabilities.finishScore = false end, "UNKNOWN")
mutate("older thin adult still rejected", "cattleStore", function(s) s.ageMonths = 40; s.production.finishScore = 30 end, "FAIL")
mutate("finished standard reference alone insufficient", "cattleFinished", function(s, _, c) s.weightKg = 630; c.facts.standardFinishKg = 630 end, "FAIL")
mutate("finished individual95 boundary passes", "cattleFinished", function(s) s.weightKg = 665 end, "PASS")
mutate("finished missing economic reference unknown", "cattleFinished", function(_, _, c) c.facts.standardFinishKg = nil end, "UNKNOWN")
mutate("finished missing slaughter basis unknown", "cattleFinished", function(_, _, c) c.factCapabilities.slaughterBasisAvailable = false end, "UNKNOWN")
mutate("fat class2 passes", "lambFinished", function(s) s.production.fatClass = "2" end, "PASS")
mutate("fat class3H passes", "lambFinished", function(s) s.production.fatClass = "3H" end, "PASS")
mutate("fat class4 rejects via set", "lambFinished", function(s) s.production.fatClass = "4" end, "FAIL")
mutate("fat class missing remains unknown", "lambFinished", function(s) s.production.fatClass = nil end, "UNKNOWN")
mutate("no implicit weaning", "pigGrower", function(_, _, c) c.facts.weaned = nil end, "UNKNOWN")
mutate("no implicit development", "lambGrower", function(_, _, c) c.factCapabilities.developmentReady = false end, "UNKNOWN")
mutate("commodity ignores poor genetics", "cattleStore", function(s) for key in pairs(s.genes) do s.genes[key] = 0.25 end end, "PASS")
mutate("class high genes do not override mismatch", "cattleSire", function(s) s.productionClass = "DAIRY" end, "FAIL")
mutate("DUAL not implicit BEEF", "cattleStore", function(s) s.productionClass = "DUAL" end, "FAIL")
mutate("DUAL explicitly admitted", "cattleStore", function(s, p) s.productionClass = "DUAL"; p.allowedProductionClasses = {"BEEF", "DUAL"} end, "PASS")
mutate("SPECIFIC breed mismatch", "cattleSire", function(s) s.breedId = "COW:OTHER" end, "FAIL")
mutate("high genes castrated sire rejects", "cattleSire", function(s) s.castrated = true end, "FAIL")
mutate("high genes immature sire rejects", "cattleSire", function(_, _, c) c.facts.currentBreedingReady = false end, "FAIL")
mutate("sire infertility cannot be offset", "cattleSire", function(s) s.genes.fertility = 0.25; s.genes.health = 1.75; s.genes.quality = 1.75 end, "FAIL")
mutate("sire remaining use independent", "ramSire", function(_, _, c) c.facts.remainingUseMonths = 11.99 end, "FAIL")
mutate("overfat sire rejects", "cattleSire", function(s) s.production.bcs = 3.51 end, "FAIL")
mutate("pregnant 20percent passes without remating", "cattlePregnant", function(_, _, c) c.facts.pregnancyProgress = 0.2; c.facts.currentBreedingReady = false end, "PASS")
mutate("pregnant70percent passes", "cattlePregnant", function(_, _, c) c.facts.pregnancyProgress = 0.7 end, "PASS")
mutate("pregnant82percent rejects", "cattlePregnant", function(_, _, c) c.facts.pregnancyProgress = 0.82 end, "FAIL")
mutate("replacement cannot have parity", "eweReplacement", function(s) s.reproductive.parity = 1 end, "FAIL")
mutate("lactation fertility95 retains own floor", "cattleLactating", function(s) s.genes.fertility = 0.95 end, "PASS")
mutate("lactation fertility94 rejects", "cattleLactating", function(s) s.genes.fertility = 0.94 end, "FAIL")
mutate("lactation birth counter0 is month1", "cattleLactating", function(s) s.reproductive.monthsSinceLastBirth = 0 end, "PASS")
mutate("lactation month6 before counter6 passes", "cattleLactating", function(s) s.reproductive.monthsSinceLastBirth = 5.99 end, "PASS")
mutate("lactation counter6 starts month7", "cattleLactating", function(s) s.reproductive.monthsSinceLastBirth = 6 end, "FAIL")
mutate("lactation needs actual parent", "cattleLactating", function(s) s.reproductive.isParent = false end, "FAIL")
mutate("fake milk cannot pass dairy", "cattleLactating", function(s) s.traitCapabilities.milkOutput = false end, "UNKNOWN")
mutate("pregnant lactation excluded by default", "cattleLactating", function(s) s.reproductive.pregnant = true end, "FAIL")
mutate("lactating BEEF package cannot be enabled by real milk caps", "cattleLactating", function(s, p) s.productionClass = "BEEF"; p.allowedProductionClasses = {"BEEF"} end, "UNKNOWN")
mutate("lactating DUAL explicitly accepted", "cattleLactating", function(s, p) s.productionClass = "DUAL"; p.allowedProductionClasses = {"DAIRY", "DUAL"} end, "PASS")
local s, p, c = fixture("cattleStore")
s.ageMonths = 40; s.weightKg = 570; s.production.finishScore = 65; s.health = 60; c.permissionGranted = false; c.quota.breed = 0; c.factCapabilities.weaned = false
local many = E.evaluate(s, p, c)
check("eligibility: reports all evaluable failures and unknowns", #many.failures >= 6 and #many.unknowns >= 1)
check("eligibility: unknown retains explicit capability", many.unknowns[1].capability ~= nil)
local before = assert(RLMarketData.fingerprint({s, p, c})); E.evaluate(s, p, c)
check("eligibility: evaluation never writes inputs", before == RLMarketData.fingerprint({s, p, c}))
local genes = fixture("cattleSire")
genes.genes = {quality = 1.55, fertility = 1.20, health = 1.15}
local index = E.selectionIndex(genes, "cattle.terminal")
check("eligibility: fixed terminal1.44 independent example", near(index.value, 1.44, 1e-12))
genes.genes.productivity = nil; genes.traitCapabilities.gene_productivity = false
check("eligibility: zero-weight gene absence ignored", E.selectionIndex(genes, "cattle.terminal").status == "PASS")
genes.genes.quality = nil
check("eligibility: nonzero-weight missing gene UNKNOWN", E.selectionIndex(genes, "cattle.terminal").status == "UNKNOWN")
check("eligibility: scalar snapshot index input fails closed", E.selectionIndex(false, "cattle.terminal").status == "UNKNOWN")
check("eligibility: scalar gene container fails closed", E.selectionIndex({genes = 1, traitCapabilities = false}, "cattle.terminal").status == "UNKNOWN")
check("eligibility: executable input not run", E.evaluate(setmetatable({}, {__pairs = function() error("must not run") end}), p, c).status == "UNKNOWN")
local numeric = fixture("cattleSire")
numeric.genes = {quality = 1.5, productivity = 1.2, fertility = 1, health = 0.8}
for id, expected in pairs({["cattle.dairy"] = 1.02, ["cattle.terminal"] = 1.33, ["cattle.maternal"] = 1.04, ["sheep.dairy"] = 1.04, ["sheep.terminal"] = 1.305, ["sheep.maternal"] = 1.015}) do
    check("eligibility: independent fixed six-index example " .. id, near(E.selectionIndex(numeric, id).value, expected, 1e-12))
end
local dairy, _, dairyContext = fixture("cattleSire")
local dairyPackage = assert(P.compile(assert(P.candidate("cattleSire", {allowedProductionClasses = {"DAIRY"}, requiredBreedId = "COW:TEST", breedingObjective = "DAIRY"}))))
dairy.productionClass = "DAIRY"; dairy.genes.quality = 0.25; dairy.genes.productivity = 1.75; dairy.genes.fertility = 1.2; dairy.genes.health = 1.2
check("eligibility: dairy sire low meat gene not penalized", E.evaluate(dairy, dairyPackage, dairyContext).eligible)
dairy.genes = {quality = 1.75, productivity = 1.15, fertility = 1.3, health = 0.9}
local fixedDairy = E.evaluate(dairy, dairyPackage, dairyContext)
check("eligibility: canonical dairy1.12 cannot pass standard1.20", not fixedDairy.eligible and near(fixedDairy.selectionIndex, 1.12, 1e-12))
local switched = copy(dairyPackage); switched.genetics.indexId = nil
switched.genetics.weights = {quality = 0.01, productivity = 0.01, fertility = 0.97, health = 0.01}
local cannotReweight = E.evaluate(dairy, switched, dairyContext)
check("eligibility: substituted dairy1.299 cannot bypass package compilation", not cannotReweight.eligible and cannotReweight.status == "UNKNOWN")
dairy.genes = {quality = 0.25, productivity = 1.75, fertility = 1.2, health = 1.2}
dairy.traitCapabilities.milkProductivity = false
check("eligibility: sheep wool-like productivity cannot impersonate milk", E.evaluate(dairy, dairyPackage, dairyContext).status == "UNKNOWN")

-- Real source adapters interoperate; these constructed facts demonstrate wiring,
-- not a U51 feeding/growth reachability or publication approval.
loadMod("tests/breedingvalue_fixture.lua")
loadMod("scripts/core/RLConstants.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/dealer/RLDealerStockPolicy.lua")
loadMod("scripts/market/RLMarketSchema.lua")
loadMod("scripts/market/RLMarketSpecies.lua")
loadMod("scripts/market/RLMarketSnapshot.lua")
local animal = bvAnimal("BULL_HOLSTEIN", 12, {farmId = "123456", uniqueId = "12345", birthday = {country = 2}, isDead = false, health = 98, bodyCondition = {version = 1, reserve = 0.4, capacityKg = 100}})
animal.weight = 0.7 * AnimalMoveEvent.getCarcassReferenceWeight(animal, nil, animal.subTypeIndex)
local actual = assert(RLMarketSnapshot.capture(animal, {classRevision = "c1", traitMappingRevision = "t1"}, {dealerConfig = RLDealerStockPolicy.getConfig(), diseasesEnabled = true}))
local realPackage = assert(P.compile(assert(P.candidate("cattleStore", {allowedProductionClasses = {"DAIRY"}}))))
local _, _, realContext = fixture("cattleStore")
check("eligibility: actual snapshot fields and capabilities compose", E.evaluate(actual, realPackage, realContext).eligible)
realContext.facts.weaned = nil
local noWeaning = E.evaluate(actual, realPackage, realContext)
check("eligibility: actual snapshot cannot synthesize missing weaning", noWeaning.status == "UNKNOWN")
