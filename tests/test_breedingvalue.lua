-- Live value of cattle against standard genes (PRICE-BREED-03, RLBreedingValue) on the shipped
-- animals.xml, carcassYield.xml and breedingValue.xml: standard genes keep the curve price, poor
-- genes fall back to the meat route, good genes earn a premium bounded by their PV gain, castrated
-- and infertile animals are meat only, and nothing on the slaughter side reads the live price.

loadMod("tests/breedingvalue_fixture.lua")

local params = RLBreedingValue.getParams(BV_SUB.COW_HOLSTEIN)
local COWS, BULLS = {}, {}
for _, sub in ipairs(SUBS) do
    if TYPES[sub.typeIndex].name == "COW" then table.insert(sub.gender == "male" and BULLS or COWS, sub.name) end
end

-- The old price: curve with the fixed state parts, floored at the slaughter value.
local function oldPrice(a)
    local price = a:getCurvePrice(nil, true)
    local floor = RLMeatValue.getSlaughterValue(a)
    if floor > price then
        for _, d in pairs(a.diseases) do floor = d:modifyValue(floor) end
        price = math.max(price, floor)
    end
    return price
end

-- Pure arithmetic ------------------------------------------------------------------------------

check("excellence: 0 at the standard and up to the threshold, 1 at the top",
    RLBreedingValue.excellence(1, params) == 0 and RLBreedingValue.excellence(1.10, params) == 0
    and near(RLBreedingValue.excellence(1.75, params), 1, 1e-12))
local monotone, previous = true, -1
for i = 0, 15000 do
    local e = RLBreedingValue.excellence(0.25 + i / 10000, params)
    if e < previous - 1e-12 or e < 0 or e > 1 + 1e-12 then monotone = false end
    previous = e
end
check("excellence: 15001 points bounded and non-decreasing", monotone)
check("inheritance: 1.75 x standard mate -> 1.3747, regresses both ways",
    near(RLBreedingValue.inheritedMean(1.75), 1.37470, 1e-4) and near(RLBreedingValue.inheritedMean(1), 1, 1e-9)
    and RLBreedingValue.inheritedMean(0.25) > 0.6 and RLBreedingValue.inheritedMean(0.25) < 1)
check("open months: fertility 1 -> reference, low fertility longer, high shorter, bounded",
    near(RLBreedingValue.getOpenMonths(1, params), params.referenceOpenMonths, 1e-9)
    and RLBreedingValue.getOpenMonths(0.25, params) == params.maxOpenMonths
    and RLBreedingValue.getOpenMonths(1.75, params) == params.minOpenMonths)

local base = { role = "cow", curve = 2500, meatRoute = 2000, stateValue = 0, excellence = 1 }
local function combined(fields)
    local input = {}
    for k, v in pairs(base) do input[k] = v end
    for k, v in pairs(fields) do input[k] = v end
    return RLBreedingValue.combine(input, params)
end
local mixed = combined({ deltaOwn = 3000, deltaHered = -4000 })
check("formula: a profitable trait cannot hide a larger loss (milk +3000, offspring -4000 -> under standard)",
    mixed.price < 2500 and mixed.price >= 2000)
local capped = combined({ deltaOwn = 0, deltaHered = 100 })
check("formula: the premium never exceeds the PV gain", capped.price <= 2600 + 1e-9 and capped.heredPremium > 0)
local poorSire = combined({ role = "sire", curve = 1800, meatRoute = 1800, deltaHered = -9000, excellence = 0 })
check("formula: a poor bull is a meat bull (no loss under his meat route)", poorSire.price == 1800 and poorSire.loss == 0)
local neutral = combined({ deltaOwn = 0, deltaHered = 0 })
check("formula: standard genes, no premium, no loss", neutral.price == 2500 and neutral.ownPremium == 0
    and neutral.heredPremium == 0 and neutral.loss == 0)

-- Standard genes keep the calibrated price -----------------------------------------------------

local sameAsOld, noPremium, worst, worstName = true, true, 0, ""
for _, name in ipairs(COWS) do
    for _, age in ipairs({ 1, 8, 15, 24, 40, 70, 100 }) do
        local parent = age >= 30
        local a = bvAnimal(name, age, { isParent = parent, monthsSinceLastBirth = parent and 11 or nil, birthCount = parent and 1 or 0 })
        local q = bvQuote(a)
        if q.ownPremium ~= 0 or q.heredPremium ~= 0 or q.loss > 1e-9 or math.abs(q.deltaOwn) > 1e-6 or math.abs(q.deltaHered) > 1e-6 then noPremium = false end
        -- A grown cow's curve is scaled to the market (cowCurveScale); her meat value stays the floor.
        local p = RLBreedingValue.getParams(a:getSubType())
        local expected = math.max(a:getCurvePrice(nil, false) * RLBreedingValue.getCowCurveScale(p, age), q.meatRoute)
        local diff = math.abs(q.price / expected - 1)
        if age < p.cowCurveScaleFromMonth then diff = math.max(diff, math.abs(q.price / oldPrice(a) - 1)) end
        if diff > worst then worst, worstName = diff, name .. "@" .. age end
        if diff > 1e-9 then sameAsOld = false end
    end
end
for _, name in ipairs(BULLS) do
    for _, age in ipairs({ 1, 8, 18, 30, 60, 140 }) do
        local a = bvAnimal(name, age)
        local q = bvQuote(a)
        if q.heredPremium ~= 0 then noPremium = false end
        local diff = math.abs(q.price / oldPrice(a) - 1)
        if diff > worst then worst, worstName = diff, name .. "@" .. age end
        if diff > 1e-9 then sameAsOld = false end
    end
end
check(string.format("standard genes: open/dry cows at their scaled curve, heifers and intact bulls as before (worst %.2e %s)", worst, worstName), sameAsOld)
check("standard genes: no own or offspring premium and no loss", noPremium)

-- The fixed state parts are replaced by the state's PV
local fresh = bvAnimal("COW_HOLSTEIN", 40, { isParent = true, isLactating = true, monthsSinceLastBirth = 1, birthCount = 1 })
local dry = bvAnimal("COW_HOLSTEIN", 40, { isParent = true, monthsSinceLastBirth = 11, birthCount = 1 })
local inCalf = bvAnimal("COW_HOLSTEIN", 40, { isParent = true, isPregnant = true, reproduction = 80,
    pregnancy = { duration = 10, pregnancies = {} }, monthsSinceLastBirth = 9, isLactating = true, birthCount = 1 })
local qFresh, qDry, qCalf = bvQuote(fresh), bvQuote(dry), bvQuote(inCalf)
check(string.format("state: a fresh cow is worth her lactation's PV over a dry one (%.0f > %.0f), not a fixed +15%%", qFresh.price, qDry.price),
    qFresh.price > qDry.price and qFresh.stateValue > 0
    and near(qFresh.price, qDry.price + params.alphaNormal * qFresh.stateValue, 1e-6))
check(string.format("state: a calf on the way is in the PV (%.0f), no fixed +25%%", qCalf.price),
    qCalf.price > qDry.price and math.abs(qCalf.price - oldPrice(inCalf)) > 1)
local twinGenes = bvAnimal("COW_HOLSTEIN", 40, { isParent = true, isPregnant = true, reproduction = 80, birthCount = 1,
    pregnancy = { duration = 10, pregnancies = { { gender = "female", genetics = bvGenes(1.75) } } }, monthsSinceLastBirth = 9, isLactating = true })
check("state: an elite calf on the way is worth more than a standard one, in every gene world",
    bvQuote(twinGenes).price > qCalf.price and bvQuote(twinGenes).heredPremium == 0)

-- Asymmetric genes -------------------------------------------------------------------------------

local function priceAt(name, age, g, fields)
    fields = fields or {}
    fields.genes = bvGenes(g)
    return bvQuote(bvAnimal(name, age, fields))
end
local rising = true
for _, name in ipairs({ "COW_HOLSTEIN", "COW_SWISS_BROWN", "COW_ANGUS" }) do
    local last = -1
    for i = 0, 30 do
        local g = 0.25 + i * 0.05
        local q = priceAt(name, 15, g)
        if q.price < last - 1e-6 then rising = false end
        last = q.price
    end
end
check("genes: a heifer's price does not fall as all her genes rise (0.25 .. 1.75)", rising)

local stdCow = priceAt("COW_HOLSTEIN", 40, 1, { isParent = true, monthsSinceLastBirth = 11, birthCount = 1 })
local poorCow = priceAt("COW_HOLSTEIN", 40, 0.25, { isParent = true, monthsSinceLastBirth = 11, birthCount = 1 })
local topCow = priceAt("COW_HOLSTEIN", 40, 1.75, { isParent = true, monthsSinceLastBirth = 11, birthCount = 1 })
check(string.format("genes: a poor dairy cow falls to her meat route, not below (%.0f = meat %.0f, standard %.0f)",
    poorCow.price, poorCow.meatRoute, stdCow.price), near(poorCow.price, poorCow.meatRoute, 1e-6) and poorCow.price < stdCow.price)
check(string.format("genes: a top dairy cow earns a premium within her PV gain (x%.2f)", topCow.price / stdCow.price),
    topCow.price > stdCow.price and topCow.price <= topCow.ceiling + 1e-6 and topCow.ownPremium > 0 and topCow.heredPremium > 0)
local stdBull = priceAt("BULL_HOLSTEIN", 18, 1)
local poorBull = priceAt("BULL_HOLSTEIN", 18, 0.25)
local topBull = priceAt("BULL_HOLSTEIN", 18, 1.75)
check(string.format("genes: a top dairy sire's tail is longer than a cow's (x%.2f vs x%.2f)", topBull.price / stdBull.price, topCow.price / stdCow.price),
    topBull.price / stdBull.price > topCow.price / stdCow.price and topBull.ownPremium == 0)
check("genes: a poor bull keeps his meat route (curve and slaughter floor)",
    near(poorBull.price, oldPrice(bvAnimal("BULL_HOLSTEIN", 18, { genes = bvGenes(0.25) })), 1e-6))
check("genes: below the threshold a bull gets no breeding premium", priceAt("BULL_HOLSTEIN", 18, 1.10).heredPremium == 0)
local calf, yearling = priceAt("BULL_HOLSTEIN", 1, 1.75), priceAt("BULL_HOLSTEIN", 12, 1.75)
check("genes: a bull calf's premium is discounted for waiting and proving out",
    calf.qualification < yearling.qualification and calf.heredPremium < yearling.heredPremium)

-- Meat only ------------------------------------------------------------------------------------------

local steer = bvAnimal("BULL_ANGUS", 18, { genes = bvGenes(1.75), isCastrated = true })
local qSteer = bvQuote(steer)
check("castrated: meat route only, top genes earn nothing, no fixed +15%",
    qSteer.status == "MEAT_ONLY_CASTRATED" and qSteer.heredPremium == 0
    and near(qSteer.price, math.max(steer:getCurvePrice(nil, false), RLMeatValue.getSlaughterValue(steer)), 1e-6)
    and qSteer.price < oldPrice(steer))
local barren = bvQuote(bvAnimal("COW_HOLSTEIN", 40, { genes = { productivity = 1.75, fertility = 0, health = 1.75, quality = 1 },
    isParent = true, isLactating = true, monthsSinceLastBirth = 2, birthCount = 1 }))
check("infertile cow: meat route only, her milk is not capitalised", barren.status == "MEAT_ONLY_INFERTILE"
    and near(barren.price, barren.meat, 1e-6))
check("infertile and pregnant: the record conflict is flagged, meat route kept",
    bvQuote(bvAnimal("COW_HOLSTEIN", 40, { genes = { fertility = 0 }, isParent = true, isPregnant = true, reproduction = 50,
        pregnancy = { duration = 10, pregnancies = {} }, birthCount = 1 })).status == "REPRO_STATE_CONFLICT")
local barrenBull = bvQuote(bvAnimal("BULL_HOLSTEIN", 18, { genes = { productivity = 1.75, fertility = 0, health = 1.75, quality = 1 } }))
check("infertile bull: meat route only", barrenBull.status == "MEAT_ONLY_INFERTILE" and barrenBull.heredPremium == 0)
check("old bull past breeding age: meat route only", priceAt("BULL_HOLSTEIN", 140, 1.75).status == "MEAT_ONLY_PAST_BREEDING")
local lowFertility = priceAt("COW_HOLSTEIN", 15, 1, { genes = { fertility = 0.25 } })
check("low fertility is not infertility: still valued as a cow", lowFertility.status == "VALUED")

-- Meat gene priced once for cows ------------------------------------------------------------------

local tasty = bvQuote(bvAnimal("COW_ANGUS", 40, { genes = { quality = 1.75 }, isParent = true, monthsSinceLastBirth = 11, birthCount = 1 }))
local plain = bvQuote(bvAnimal("COW_ANGUS", 40, { isParent = true, monthsSinceLastBirth = 11, birthCount = 1 }))
check(string.format("meat gene: a cow's meat gene adds its meat value once (+%.0f) and her calves' meat", tasty.bodyDifference),
    tasty.bodyDifference > 0 and near(tasty.curve, plain.curve, 1e-6) and tasty.price > plain.price)

-- Slaughter is not touched -------------------------------------------------------------------------

local elite = bvAnimal("COW_HOLSTEIN", 40, { genes = bvGenes(1.75), isParent = true, birthCount = 1, monthsSinceLastBirth = 11 })
local realSell = Animal.getSellPrice
Animal.getSellPrice = function() error("the slaughter side read the live price") end
local okYield, yieldA = pcall(AnimalMoveEvent.getCarcassYield, elite, nil, elite.subTypeIndex)
local okValue, valueA = pcall(RLMeatValue.getSlaughterValue, elite)
Animal.getSellPrice = realSell
check("slaughter: carcass yield and slaughter value never read the live price", okYield and okValue)
RLBreedingValue.config = { layers = { root = { enabled = 0 }, types = {}, breeds = {}, subTypes = {} } }
local disabledPrice = elite:getSellPrice()
local yieldB, valueB = AnimalMoveEvent.getCarcassYield(elite, nil, elite.subTypeIndex), RLMeatValue.getSlaughterValue(elite)
RLBreedingValue.reset()
check("slaughter: meat kg and slaughter value are the same whether the premium is on or off",
    near(yieldA.modelMeat, yieldB.modelMeat, 1e-9) and near(valueA, valueB, 1e-9) and elite:getSellPrice() > disabledPrice)
check("config: enabled=0 gives the old price exactly", near(disabledPrice, oldPrice(elite), 1e-9))

-- Determinism, timing and other species ----------------------------------------------------------------

local again = bvAnimal("COW_HOLSTEIN", 40, { genes = bvGenes(1.6), isParent = true, birthCount = 2, monthsSinceLastBirth = 4, isLactating = true })
local q1 = bvQuote(again).price
g_currentMission.environment = { daysPerPeriod = 7 }
local q7 = bvQuote(again).price
g_currentMission.environment = { daysPerPeriod = 1 }
check("requote: the same animal prices the same, whatever the days per month", q1 == q7 and q1 == bvQuote(again).price)
g_time = 1000
local cached = bvAnimal("BULL_HOLSTEIN", 18, { genes = bvGenes(1.75) })
local before = cached:getSellPrice()
cached.isCastrated = true
check("cache: a castration within the cache window prices anew", cached:getSellPrice() < before)
g_time = nil
local pig = bvAnimal("BOAR_LANDRACE", 6)
check("other species: not covered (old price rules)", not RLBreedingValue.covers(pig, pig:getSubType()))

-- Calibration to the 2025 UK market (docs: breeding-value-formulas-v3.md §11) ---------------------------

local function inCalfRatio(name)
    local q = bvQuote(bvAnimal(name, 40, { isParent = true, isPregnant = true, reproduction = 50, birthCount = 1,
        pregnancy = { duration = 10, pregnancies = {} }, monthsSinceLastBirth = 8, isLactating = true }))
    return q.price / q.meat
end
local dairyRatio, beefRatio = inCalfRatio("COW_HOLSTEIN"), inCalfRatio("COW_ANGUS")
check(string.format("market: an in-calf Holstein is 1.5x her cull value (%.2f), an in-calf suckler cow 1.75x (Angus %.2f)", dairyRatio, beefRatio),
    math.abs(dairyRatio - 1.5) < 0.02 and math.abs(beefRatio - 1.75) < 0.02)
local allBeef = true
for _, name in ipairs({ "COW_LIMOUSIN", "COW_HEREFORD", "COW_HIGHLAND_CATTLE" }) do
    if math.abs(inCalfRatio(name) - 1.75) > 0.03 then allBeef = false end
end
check("market: every shipped suckler breed's in-calf cow at 1.75x her cull value", allBeef)
check("market: a standard suckler cow is worth more than a standard dairy cow, as in the market",
    priceAt("COW_ANGUS", 40, 1, { isParent = true, monthsSinceLastBirth = 11, birthCount = 1 }).price > stdCow.price)

local angusTop = priceAt("BULL_ANGUS", 18, 1.75)
local angusStd = priceAt("BULL_ANGUS", 18, 1)
check(string.format("sires: a top beef bull out-earns a top dairy bull (x%.2f vs x%.2f: suckler herds use the bull, dairy herds AI)",
    angusTop.price / angusStd.price, topBull.price / stdBull.price),
    angusTop.price > topBull.price and angusTop.price / angusStd.price > topBull.price / stdBull.price)

local beefFertile = bvQuote(bvAnimal("COW_ANGUS", 40, { genes = { fertility = 1.6 }, isParent = true, monthsSinceLastBirth = 11, birthCount = 1 }))
local beefStd = priceAt("COW_ANGUS", 40, 1, { isParent = true, monthsSinceLastBirth = 11, birthCount = 1 })
check(string.format("beef: fertility alone raises a suckler cow's value (+%.0f: calves weaned, fewer fertility culls)", beefFertile.price - beefStd.price),
    beefFertile.price > beefStd.price and beefFertile.deltaOwn > 0)
local beefTop = priceAt("COW_ANGUS", 40, 1.75, { isParent = true, monthsSinceLastBirth = 11, birthCount = 1 })
check(string.format("beef: a top suckler cow earns a real premium (x%.2f)", beefTop.price / beefStd.price), beefTop.price / beefStd.price > 1.25)

local ctx = RLBreedingValue.buildContext(BV_SUB.COW_ANGUS)
local eliteSon = RLBreedingValue.offspringDelta(ctx, RLBreedingValue.inheritedGenes(bvGenes(1.75), 1.35), "male")
local meatOnlySon = RLBreedingValue.offspringDelta(ctx, RLBreedingValue.inheritedGenes(bvGenes(1.75), 1.35), "male", 1)
check(string.format("seedstock: an elite cow's son is worth more as a breeding bull than as beef (%.0f > %.0f)", eliteSon, meatOnlySon),
    eliteSon > meatOnlySon)
check("seedstock: expected excellence integrates the gene spread (an average-score son can still prove out)",
    RLBreedingValue.expectedExcellence(bvGenes(1.1), params, "male") > 0 and RLBreedingValue.excellence(1.1, params) == 0)
