-- Suckler (beef) cows' milk (breedTraits milkCollect): a beef cow's milk is her calf's. In the
-- real-equivalent mode she makes what her calves at foot drink (none without one) plus milkCollect
-- of the rest, and is fed for that; whatever her calves leave is not collected. Under the old rules
-- her store gets milkCollect of her milk. Dairy breeds (milkCollect 1) are untouched.

loadMod("tests/feedsim.lua")

local config = RLFeed.getConfig()
local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end
local function sub(name) return { name = name, typeName = "COW", breed = name:match("^COW_(.-)_PACK$") } end

FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(1)

local function identify(animal, id)
    animal.id = id
    animal.getIdentifiers = function(self) return self.id end
    return animal
end
local function dam(name, id)
    return identify((GrowthSim.makeAnimal(name, { age = 48, isParent = true, isLactating = true, monthsSinceLastBirth = 1 })), id)
end
local function calf(name, motherId, id) return identify(GrowthSim.newborn(name, { motherId = motherId }), id) end

--- Hours until a step has run; the dam's descriptor from the last plan, and the hour's records.
local function stepPen(pen)
    local steps = {}
    local function observe(kind, data) if kind == "STEP" then steps[#steps + 1] = data end end
    RLFeed.addObserver(observe)
    FeedSim.untilStep(pen)
    RLFeed.removeObserver(observe)
    return steps
end


-- Breeds ------------------------------------------------------------------------------------------

do
    local _, angus = Economics.find("COW_ANGUS")
    local _, holstein = Economics.find("COW_HOLSTEIN")
    local _, buffalo = Economics.find("COW_WATERBUFFALO")
    check("breeds: Angus, Hereford, Limousin and Highland cows are sucklers (0); Holstein and the water buffalo 1",
        RLBreedTraits.getMilkCollect(angus) == 0 and RLBreedTraits.getMilkCollect(holstein) == 1
        and RLBreedTraits.getMilkCollect(buffalo) == 1
        and RLBreedTraits.getMilkCollect(select(2, Economics.find("COW_HEREFORD"))) == 0
        and RLBreedTraits.getMilkCollect(select(2, Economics.find("COW_LIMOUSIN"))) == 0
        and RLBreedTraits.getMilkCollect(select(2, Economics.find("COW_HIGHLAND_CATTLE"))) == 0)
    local beef, dairy = true, true
    for _, name in ipairs({ "CHAROLAIS", "REDANGUS", "SHORTHORN", "IRISHMOILED", "BRITISHBLUE", "BELTEDGALLOWAY", "SIMMENTAL" }) do
        beef = beef and RLBreedTraits.getMilkCollect(sub("COW_" .. name .. "_PACK")) == 0
    end
    for _, name in ipairs({ "REDHOLSTEIN", "AYRSHIRE", "KERRY", "SHORTHORNMILKERS", "JERSEY", "GUERNSEY" }) do
        dairy = dairy and RLBreedTraits.getMilkCollect(sub("COW_" .. name .. "_PACK")) == 1
    end
    check("breeds: the Cow Breeds pack's seven beef cows are sucklers, its six dairy cows are not", beef and dairy)
end


-- Real-equivalent mode: a beef dam and her calf -----------------------------------------------------

do
    local cow = dam("COW_ANGUS", "S1")
    local c = calf("BULL_ANGUS", "S1", "SC1")
    local pen = FeedSim.makePen({ cow, c }, { FORAGE = 1e5 })
    FeedSim.hour(pen)
    local d = RLFeed.describePen(pen, RLFeed.getRation(pen), config.stepDays)
    local cowD, calfD
    for _, a in ipairs(d) do if a.animal == cow then cowD = a elseif a.animal == c then calfD = a end end
    local drink = math.min(calfD.nursingMaxKgPerDay, calfD.appetite) / config.damMilk.dm
    local potential = cowD.milkKgPerDay / (cowD.milkDemandFactor or 1)
    check(string.format("dam: she plans the milk her calf drinks, at most her potential: %.2f kg a day (calf %.2f, potential %.2f)",
        cowD.milkKgPerDay, drink, potential), cowD.milkDemandFactor ~= nil and near(cowD.milkKgPerDay, math.min(drink, potential), 1e-9))
    check("dam: her calf's pool is her scaled milk",
        near(cowD.nursing.kg, cowD.milkKgPerDay * config.damMilk.dm * config.stepDays, 1e-9))

    stepPen(pen)
    local record = cow.rlFeedIntake
    check(string.format("dam: she paid %.3f L, %.3f L to her calf, nothing to the store", record.milkPaidLiters, record.milkToCalves or 0),
        record.milkPaidLiters > 0 and (record.milkToCalves or 0) > 0 and record.milkLiters == 0 and cow.rlMilkPaid.litersPerHour == 0)
    check("dam: what her calf did not drink is small (her milk is her calf's)",
        record.milkPaidLiters - (record.milkToCalves or 0) <= 0.05 * record.milkPaidLiters + 1e-9)
    check("dam: her milk share reads against the milk she makes, not her dairy potential",
        cow.rlNutrition.milkShare ~= nil and cow.rlNutrition.milkShare > 0.9)
end

do
    -- A three-month-old calf on the weaning curve drinks less than she could give: she makes that.
    local cow = dam("COW_ANGUS", "S4")
    local c = calf("BULL_ANGUS", "S4", "SC4")
    c.age = 3
    local pen = FeedSim.makePen({ cow, c }, { FORAGE = 1e5 })
    FeedSim.hour(pen)
    local d = RLFeed.describePen(pen, RLFeed.getRation(pen), config.stepDays)
    local cowD, calfD
    for _, a in ipairs(d) do if a.animal == cow then cowD = a elseif a.animal == c then calfD = a end end
    local drink = math.min(calfD.nursingMaxKgPerDay, calfD.appetite) / config.damMilk.dm
    check(string.format("dam: with a calf near weaning (drinks %.2f kg) her milk falls to it (factor %.3f)", drink, cowD.milkDemandFactor or 1),
        cowD.milkDemandFactor ~= nil and cowD.milkDemandFactor < 1 and near(cowD.milkKgPerDay, drink, 1e-9))
end

do
    local cow = dam("COW_ANGUS", "S2")
    local herd = dam("COW_HOLSTEIN", "S3")
    local pen = FeedSim.makePen({ cow, herd }, { FORAGE = 1e5 })
    FeedSim.hour(pen)
    local d = RLFeed.describePen(pen, RLFeed.getRation(pen), config.stepDays)
    local cowD, herdD
    for _, a in ipairs(d) do if a.animal == cow then cowD = a elseif a.animal == herd then herdD = a end end
    check("dam: a beef cow with no calf at foot makes no milk, needs none and eats for none",
        cowD.milkDemandFactor == 0 and cowD.milkKgPerDay == 0 and cowD.needs.milk == 0 and cowD.appetite > 0
        and near(cowD.proteinNeed, config.protein.dry, 1e-12))
    check("dam: a dairy cow is untouched (no factor, her full milk)", herdD.milkDemandFactor == nil and herdD.milkKgPerDay > 0)
    stepPen(pen)
    check("dam: without a calf her budget pays no milk and her store gets none",
        cow.rlFeedIntake.milkPaidLiters == 0 and cow.rlFeedIntake.milkLiters == 0 and herd.rlFeedIntake.milkLiters > 0)
end
