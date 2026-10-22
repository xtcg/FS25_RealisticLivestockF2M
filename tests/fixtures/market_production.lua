-- Uncalibrated hand-calculation fixtures. These numbers test finite cash-flow
-- arithmetic only; none is a production default or a claim about game balance.
for _, name in ipairs({ "RLMarketSchema", "RLMarketData", "RLAnimalValueProvider", "RLMarketCommodityValue", "RLMarketCattleValue", "RLMarketPigValue", "RLMarketSheepValue", "RLMarketValueAdapter", "RLMarketProviders" }) do
    loadMod("scripts/market/" .. name .. ".lua")
end
loadMod("scripts/market/RLBrokerConditionPackage.lua")
MarketProductionFixture = {}
function MarketProductionFixture.snapshot(species, gender)
    return { schemaVersion = 1, identityKey = "123 12345 2", stateRevision = "state1", animalType = species, speciesKey = species,
        breed = "TEST", subTypeName = "TEST_SUB", productionClass = species == "COW" and "DAIRY" or "BEEF",
        classRevision = "c1", traitMappingRevision = "t1", gender = gender or "female", ageMonths = 18,
        weightKg = 500, targetWeightKg = 700, health = 100, castrated = false,
        genes = { health = 1, fertility = 1, quality = 1, productivity = 1 },
        reproductive = { parity = 0, pregnant = false, lactating = false, isParent = false },
        supportedBreedingRoles = { "DAIRY", "TERMINAL", "MATERNAL" },
        traitCapabilities = { gene_quality=true,gene_productivity=true,gene_fertility=true,gene_health=true, milkProductivity = species == "COW", woolProductivity = species == "SHEEP" } }
end
function MarketProductionFixture.input()
    return { currencyBasis = "HARD", costBasis = "NET_FLOWS_INCLUDE_ALL_PRODUCTION_COSTS", params = { minBreedingAge = 12, exitAge = 30, gestationMonths = 1,
        recoveryMonths = 0, openMonths = 0, maxBirths = 2, annualExitRisk = 0, healthExitSlope = 0,
        discountRate = 0, inheritanceSD = 0, mateGene = 1, offspringBaseNet = 100,
        breedingWeightRatio = 0.5, sireFemalesPerSeason = 4, sireSeasons = 1, sireConception = 1, standardSireReference = 50,
        expectedLitter = 10, pigletSurvival = 0.8, sireLittersPerYear = 4, sireYears = 1,
        lambSurvival = 1, sireEwesPerSeason = 4 },
        weights = { DAIRY = { productivity = 1 }, TERMINAL = { quality = 1 }, MATERNAL = { fertility = 1 } },
        offspringDeltaPerGene = { DAIRY = { productivity = 40 }, TERMINAL = { quality = 20 }, MATERNAL = { fertility = 30 } },
        lactationNetByMonth = { 10, 10 }, lactationIncrementNetByMonth = {10,10}, parityFactors = { 1, 1, 1, 1 },
        calendarMonth = 1, breedingSeason = {true,true,true,true,true,true,true,true,true,true,true,true},
        woolNetByMonth = {0,0,0,0,0,0,0,0,0,0,0,0} }
end
function MarketProductionFixture.context(s, input)
    return { schemaVersion = 1, channel = "DEALER_SELL", breedingObjective = nil,
        classRevision = s.classRevision, traitMappingRevision = s.traitMappingRevision,
        configRevision = "config1", formulaVersion = 1, marketEpoch = "epoch1", priceRevision = "price1",
        referenceRevision = "reference1", difficultyMultiplier = 1, calendarMonth = 1, absoluteMonths = 1,
        referenceInputs = { currencyBasis = "HARD", identityKey = s.identityKey, stateRevision = s.stateRevision,
            classRevision = s.classRevision, traitMappingRevision = s.traitMappingRevision,
            referenceRevision = "reference1", priceRevision = "price1", configRevision = "config1",
            commodity = { currencyBasis = "HARD", rearing = { futureGross = 120, remainingCost = 20, discountRate = 0, months = 1 } },
            production = input } }
end
