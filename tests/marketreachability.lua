-- Offline measurement over the shipped growth, nutrition, health and snapshot
-- adapters. No invented breeds, altered growth curves or generated sell prices
-- enter the measurement. Missing Broker policy facts remain UNKNOWN.
loadMod("tests/feedsim.lua")
loadMod("scripts/core/RLConstants.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/dealer/RLDealerStockPolicy.lua")
loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLMarketSchema.lua")
loadMod("scripts/market/RLMarketSpecies.lua")
loadMod("scripts/market/RLMarketSnapshot.lua")
loadMod("scripts/market/RLBrokerConditionPackage.lua")
loadMod("scripts/market/RLBrokerEligibility.lua")

MarketReachability = {}
local R = MarketReachability
local D = RLMarketData
local function copy(v) return assert(D.copy(v)) end
local function addWindow(windows, value, sample, step)
    local last = windows[#windows]
    if value then
        if last and last.lastStep == step - 1 then
            last.lastStep, last.toAgeMonths, last.toWeightKg = step, sample.ageMonths, sample.weightKg
            last.toFinishScore = sample.production.finishScore
        else
            windows[#windows + 1] = {firstStep = step, lastStep = step,
                fromAgeMonths = sample.ageMonths, toAgeMonths = sample.ageMonths,
                fromWeightKg = sample.weightKg, toWeightKg = sample.weightKg,
                fromFinishScore = sample.production.finishScore, toFinishScore = sample.production.finishScore}
        end
    end
end
local function sortedKeys(values)
    local result = {}; for key in pairs(values) do result[#result + 1] = key end
    table.sort(result); return result
end

function R.cattle(options)
    local o = copy(options)
    assert(type(o.subTypeName) == "string" and type(o.months) == "number" and o.months >= 1 and o.months <= 48 and o.months % 1 == 0)
    assert(o.mode == "REAL" or o.mode == "LEGACY")
    local _, sub = Economics.find(o.subTypeName)
    assert(sub and sub.typeName == "COW", "SHIPPED_CATTLE_SUBTYPE_REQUIRED")
    local class = assert(RLMarketSpecies.resolve(sub, "COW", {dealerConfig = RLDealerStockPolicy.getConfig()}))
    FeedSim.setMode(o.mode == "REAL")
    GrowthSim.setDaysPerPeriod(o.daysPerPeriod or 1)
    local gene = o.gene or 1
    assert(gene >= .25 and gene <= 1.75)
    local animal = GrowthSim.newborn(o.subTypeName, {farmId = "1", uniqueId = "1", birthday = {country = 1},
        isDead = false, canBeSold = true, isCastrated = o.castrated == true, birthCount = 0,
        genetics = {metabolism = gene, quality = gene, productivity = gene, fertility = gene, health = gene}})
    local pen = FeedSim.makePen({animal}, {})
    FeedSim.addWater(pen, 1, 0, true)
    local refill = FeedSim.keepStocked({FORAGE = 100000, CALFMILK = 100000})
    local consumed = {}
    local removeFood = pen.removeFood
    function pen:removeFood(liters, index)
        local amount = removeFood(self, liters, index)
        local name = g_fillTypeManager:getFillTypeNameByIndex(index)
        consumed[name] = (consumed[name] or 0) + amount
        return amount
    end
    local packages = {}
    for _, kind in ipairs({"cattleWeaned", "cattleStore", "cattleFinished"}) do
        local rules = assert(RLBrokerConditionPackage.compile(assert(RLBrokerConditionPackage.candidate(kind,
            {allowedProductionClasses = {class.productionClass}, breedScope = "SPECIFIC", requiredBreedId = class.breedId}))))
        packages[#packages + 1] = {rules = rules, completeWindows = {}, measuredWindows = {}, unknown = {}, failures = {}}
    end
    -- These are sandbox administration assumptions, never proof of permission,
    -- usable quota, source compatibility, live trading readiness or money.
    local base = {permissionGranted = true, ownershipVerified = true, identityVerified = true,
        unlocked = true, orderOpen = true, sourceSupported = true, quota = {order = 1, species = 1, breed = 1}}
    local perMonth = 24 * GrowthSim.env.daysPerPeriod
    for step = 1, o.months * perMonth do
        refill(pen)
        FeedSim.hour(pen)
        local snapshot, why = RLMarketSnapshot.capture(animal,
            {classRevision = "shipped-dealer-taxonomy", traitMappingRevision = "shipped-market-snapshot"},
            {dealerConfig = RLDealerStockPolicy.getConfig(), diseasesEnabled = false})
        assert(snapshot, why)
        local context = copy(base)
        context.facts, context.factCapabilities = {}, {}
        -- Existing calf feeding API is read-only. No guessed development,
        -- minimum purchase kg, slaughter-price basis or finished classification.
        context.facts.weaned = RLCalfRearing.getStage(animal) == RLCalfRearing.STAGE_WEANED
        context.factCapabilities.weaned = true
        for _, p in ipairs(packages) do
            local result = RLBrokerEligibility.evaluate(snapshot, p.rules, context)
            for _, entry in ipairs(result.unknowns) do p.unknown[entry.capability or entry.code] = true end
            for _, entry in ipairs(result.failures) do p.failures[entry.code] = true end
            addWindow(p.completeWindows, result.eligible, snapshot, step)
            -- A measured window only says the KNOWN checks overlap. It cannot
            -- be promoted to full qualification while any fact is unknown.
            addWindow(p.measuredWindows, #result.failures == 0, snapshot, step)
        end
        if step % perMonth == 0 then animal.age = animal.age + 1 end
    end
    local rows = {}
    for _, p in ipairs(packages) do
        rows[#rows + 1] = {packageId = p.rules.id, packageRevision = p.rules.revision,
            status = #p.completeWindows > 0 and "MODEL_WINDOW_OBSERVED" or "NOT_ADMITTED",
            completeWindows = p.completeWindows, measuredWindows = p.measuredWindows,
            unknownCapabilities = sortedKeys(p.unknown), observedFailureCodes = sortedKeys(p.failures)}
    end
    return {schemaVersion = 1, verificationType = "PHYSIOLOGY_MEASUREMENT_ONLY", admissionReady = false,
        subTypeName = o.subTypeName, breedId = class.breedId, productionClass = class.productionClass,
        mode = o.mode, gene = gene, castrated = o.castrated == true, months = o.months,
        daysPerPeriod = GrowthSim.env.daysPerPeriod, sampleIntervalGameHours = 1,
        assumptions = {ration = "FORAGE_PLUS_CALFMILK_AVAILABLE", automaticWater = true,
            sandboxAdministration = true, noDiseaseChallenge = true, neutralBirthFactor = 1,
            foodGroups = "FEEDSIM_HOF_BERGMANN_1_5_ENGINE_STANDIN",
            healthIncreaseHour = sub.healthIncreaseHour, healthDecreaseHour = sub.healthDecreaseHour,
            healthThresholdFactor = sub.healthThresholdFactor,
            note = "FeedSim overrides health rates; this is not a real-game parameter validation"},
        consumedFeedLiters = consumed, packages = rows}
end
