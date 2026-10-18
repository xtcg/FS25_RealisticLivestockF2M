-- Dairy calibration of the real-equivalent mode (FEED calibration 2026-10-11): milk answers ration
-- protein with a diminishing return (protein milkResponse), growth keeps the linear share; a
-- breed's cows may eat more per kg than the Holstein-based equations (milk breed intakeFactor).

loadMod("tests/feedsim.lua")

local F = RLFeedProfiles
local M = RLFeedMath
local config = F.getConfig()
local S = GrowthSim

local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end


-- Protein ----------------------------------------------------------------------------------------

do
    check("protein: the shipped milkResponse is 2", config.protein.milkResponse == 2)
    check("protein: milk factor 1 at the need, 0 at maintenance, linear with milkResponse 1",
        M.getMilkProteinFactor(1, 2) == 1 and M.getMilkProteinFactor(0, 2) == 0 and near(M.getMilkProteinFactor(0.47, 1), 0.47))
    check("protein: an 11% CP ration for a 30 kg cow (linear 0.474) allows about 72% of her milk",
        near(M.getMilkProteinFactor(M.getProteinFactor(0.11, 0.16, 0.065), 2), 1 - (1 - 0.045 / 0.095) ^ 2) and
        near(M.getMilkProteinFactor(M.getProteinFactor(0.11, 0.16, 0.065), 2), 0.7230, 1e-3))
    local f = M.getProteinFactor(0.11, 0.14, 0.065)
    check("protein: without milk the production factor is the linear one exactly (growth untouched)",
        M.getProductionProteinFactor(f, 1.7, 0, 2) == f and M.getProductionProteinFactor(f, 0, 0, 2) == f)
    check("protein: with milk and growth it weighs each by its need",
        near(M.getProductionProteinFactor(f, 1, 3, 2), (f + 3 * M.getMilkProteinFactor(f, 2)) / 4))
    local bad = table.clone(config.protein)
    bad.milkResponse = 0.5
    local copy = table.clone(config)
    copy.protein = bad
    local ok, reason = F.validate(copy)
    check("protein: milkResponse below 1 is refused (" .. tostring(reason) .. ")", ok == false)
end


-- Breed intake ----------------------------------------------------------------------------------

do
    check("intake: Jersey cows 1.15, Guernsey 1.10, Holstein and an unknown breed 1",
        F.getCowIntakeFactor("JERSEY_PACK") == 1.15 and F.getCowIntakeFactor("guernsey_pack") == 1.10
        and F.getCowIntakeFactor("HOLSTEIN") == 1 and F.getCowIntakeFactor("NOPE") == 1 and F.getCowIntakeFactor(nil) == 1)
    local copy = table.clone(config)
    copy.milk = table.clone(config.milk)
    copy.milk.breeds = table.clone(config.milk.breeds)
    copy.milk.breeds.JERSEY_PACK = { realKgPerDay = 20, meMJPerKg = 6, intakeFactor = 3 }
    check("intake: an intakeFactor outside 0.5..2 is refused", F.validate(copy) == false)

    FeedSim.setMode(true)
    local jerseyIndex = Economics.find("COW_JERSEY_PACK")
    if jerseyIndex == nil then S.addSubType("COW_JERSEY_PACK", "JERSEY_PACK", "female", 430) end
    local cow = S.makeAnimal("COW_JERSEY_PACK", { age = 48, isParent = true, isLactating = true, monthsSinceLastBirth = 2 })
    local heifer = S.makeAnimal("COW_JERSEY_PACK", { age = 12 })
    local pen = FeedSim.makePen({ cow, heifer }, { FORAGE = 1e6 })
    local ration = RLFeed.getRation(pen)
    local function describe(animal) return RLFeed.describeAnimal(animal, ration, 1 / 24, 30 / 24) end
    local saved = config.milk.breeds.JERSEY_PACK.intakeFactor
    local withFactor, heiferWith = describe(cow), describe(heifer)
    config.milk.breeds.JERSEY_PACK.intakeFactor = 1
    local without, heiferWithout = describe(cow), describe(heifer)
    config.milk.breeds.JERSEY_PACK.intakeFactor = saved
    check(string.format("intake: a lactating Jersey's appetite and fill are 1.15 x (%.2f / %.2f kg DM)", withFactor.appetite, without.appetite),
        withFactor.class == "LACTATING" and near(withFactor.appetite, 1.15 * without.appetite)
        and near(withFactor.fill, 1.15 * without.fill))
    check("intake: a growing Jersey heifer is not scaled", heiferWith.class == "GROWING"
        and heiferWith.appetite == heiferWithout.appetite and heiferWith.fill == heiferWithout.fill)
end


-- Growth untouched -------------------------------------------------------------------------------

do
    FeedSim.setMode(true)
    local function grow(response)
        config.protein.milkResponse = response
        local bull = S.makeAnimal("BULL_ANGUS", { age = 7 })
        local pen = FeedSim.makePen({ bull }, {})
        FeedSim.months(pen, 3, { refill = FeedSim.keepStocked({ SILAGE = 1e5 }) })
        return bull.weight
    end
    local linear, curved = grow(1), grow(2)
    config.protein.milkResponse = 2
    check(string.format("growth: a bull on 11%% CP silage grows the same with milkResponse 1 and 2 (%.4f / %.4f kg)", linear, curved),
        linear == curved)
end
