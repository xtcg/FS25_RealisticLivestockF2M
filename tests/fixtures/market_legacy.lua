-- U01 fixed data only: do not compute expected prices by calling a market provider.
-- Captured before integration at 7f01d330f2de0b32a30ca8eda1ef9b1cdf4aba40.
-- baseline-observation entries are old production-code results, not an independent
-- proof of the economics. Hand-calculated checks are separately declared below.
MarketLegacyFixture = {
    revision = 1,
    sourceCommit = "7f01d330f2de0b32a30ca8eda1ef9b1cdf4aba40",
    basis = "xml/animals.xml + shipped breedTraits/carcassYield; no map override; healthy individual males; no disease/state bonus; no body-condition state",
    difficulty = { { name = "HARD", multiplier = 1 }, { name = "NORMAL", multiplier = 1.8 }, { name = "EASY", multiplier = 3 } },
    parameters = { dealerQualityIndex = 3, dealerMarkup = 1.30, meatPrices = { BEEFMEAT = 8.4, PORKMEAT = 4.31, SHEEPGOATMEAT = 14.95 },
        seasonalFactors = "twelve ones; current = annual mean", transportFactor = 1,
        transportBasis = "animals.xml transport curve interpolated at sample age; transport does not scale with difficulty",
        genes = { quality = 1, metabolism = 1, health = 1, fertility = 1, productivity = 1 } },
    samples = {
        { id = "cattle", subType = "BULL_HOLSTEIN", age = 17, weight = 649, targetWeight = 1100, expected = { bid = 1762.0419594016839, ask = 2290.6545472221892, transportFee = 441.66666666666669, meatKg = 258.8302187411125, slaughterValue = 1586.034890010355 } },
        { id = "pig", subType = "BOAR_LANDRACE", age = 6, weight = 120, targetWeight = 300, expected = { bid = 205.84001103372182, ask = 267.5920143438384, transportFee = 125.0, meatKg = 75.374822465662959, slaughterValue = 183.51256776306738 } },
        { id = "sheep", subType = "RAM_LANDRACE", age = 5, weight = 40, targetWeight = 75, expected = { bid = 205.00498876, ask = 266.506485388, transportFee = 96.875, meatKg = 21.964817160000003, slaughterValue = 205.00498876 } },
    },
    provenance = { observed = "bid, ask, transportFee, meatKg, slaughterValue at HARD; doubles captured once, never refreshed during tests",
        handCalculated = "ask = bid * preset markup; buy gross = ask + fee; sell net = bid - fee; batch sums; difficulty scaling" },
}
