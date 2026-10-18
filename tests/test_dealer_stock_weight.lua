-- DEALER-WEIGHT-SPREAD-01: the dealer's own pool (AnimalSystem:createNewSaleAnimal, not the dormant
-- dealer v2) gave pigs and sheep the old rules' line while their species' curves were off, which
-- swings with the metabolism gene (a 3-month Landrace gilt 113.6 kg at metabolism 1.61, 61 kg at
-- 0.97, 28 kg at 8 months at 0.30), and a listed animal aged a month each shelf day (1 day a
-- period) without gaining. New stock now weighs its breed curve's at its age with its genes; on
-- the shelf it gains what the curve gains; more than 25% off the standard-genes curve is warned
-- once; an animal already listed is never cut.

loadMod("tests/sheepsim.lua")
-- The dealer's genetics draw (its logger needs a level).
RLConstants = RLConstants or { GENETICS_MIN = 0.25, GENETICS_MAX = 1.75 }
RmLogging.LOG_LEVEL = RmLogging.LOG_LEVEL or { ERROR = 1, WARNING = 2, INFO = 3, DEBUG = 4, TRACE = 5 }
local getLogger = RmLogging.getLogger
RmLogging.getLogger = function(...) local log = getLogger(...); log.level = log.level or 0; return log end
loadMod("scripts/animal/RLGeneticsDraw.lua")
RmLogging.getLogger = getLogger
loadMod("scripts/dealer/RLDealerStockWeight.lua")

FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(1)

local W = RLDealerStockWeight

local function pig(age, metabolism, weight)
    local animal = GrowthSim.makeAnimal("PIG_LANDRACE", { age = age, gender = "female",
        genetics = { metabolism = metabolism, quality = 1, productivity = 1, fertility = 1, health = 1 } })
    if weight ~= nil then animal.weight = weight end
    return animal, animal:getSubType()
end
local function warnings(from) local n = 0 for i = from + 1, #LOG do if LOG[i]:find("Dealer stock", 1, true) then n = n + 1 end end return n end

-- The species' curves are off (weightProfiles.xml PIG enabled="false"): the pens keep the old rules,
-- the dealer still has the breed curve.
local _, landrace = pig(3, 1)
check("PIG curves off: the pens are not covered, the dealer reads the breed curve",
    not RLGrowth.coversSubType(landrace) and W.getBinding(landrace) ~= nil and RLWeightProfiles.getCurveBinding(landrace) == nil)
local standard3 = W.getStandardWeight(landrace, 3)
check(string.format("the 3-month Landrace gilt's standard curve weight is a real one (%.1f kg)", standard3 or -1),
    standard3 ~= nil and standard3 > 30 and standard3 < 50)

-- The reported sample: 113.6 kg at 3 months, metabolism 1.61.
local logged = #LOG
local sample = pig(3, 1.611439, 113.596863)
W.applyToNewStock(sample, landrace)
check(string.format("new stock: the 113.6 kg sample's genes now give %.1f kg, within 25%% of the curve, no warning", sample.weight),
    math.abs(sample.weight / standard3 - 1) <= 0.25 and warnings(logged) == 0)

-- A population of standard dealer genetics (RLGeneticsDraw): mean on the curve, spread by the
-- genes only, none past the warning.
math.randomseed(1017)
local sum, lo, hi, n, oldLo, oldHi = 0, math.huge, 0, 2000, math.huge, 0
for _ = 1, n do
    local genetics = RLGeneticsDraw.draw(RLGeneticsDraw.TRAITS_BASE)
    local animal = pig(3, genetics.metabolism)
    local old = RLBreedTraits.getNewAnimalWeight(landrace, "female", animal.targetWeight, 3, genetics.metabolism)
    oldLo, oldHi = math.min(oldLo, old), math.max(oldHi, old)
    W.applyToNewStock(animal, landrace)
    sum, lo, hi = sum + animal.weight, math.min(lo, animal.weight), math.max(hi, animal.weight)
end
local mean = sum / n
check(string.format("population: mean %.1f kg on the curve's %.1f (within 3%%), %.1f-%.1f kg (old rules %.1f-%.1f), no warning",
    mean, standard3, lo, hi, oldLo, oldHi),
    math.abs(mean / standard3 - 1) < 0.03 and lo / standard3 > 0.75 and hi / standard3 < 1.25 and oldHi / oldLo > 2
    and warnings(logged) == 0)

-- On the shelf: a month older, the curve's gain.
local onCurve = pig(2, 1)
W.applyToNewStock(onCurve, landrace)
onCurve.age = 3
W.onShelfAged(onCurve, 2)
check("shelf: an animal on its curve is still on it a month later", math.abs(onCurve.weight - standard3) < 1e-6)

-- An old listing far off the curve (the 8-month gilt at 27.8 kg): never cut, it grows by the
-- curve's gain, warned once however many months it stays.
logged = #LOG
local light = pig(7, 0.30269, 27.80809)
light.age = 8
W.onShelfAged(light, 7)
local afterOne = light.weight
light.age = 9
W.onShelfAged(light, 8)
local curve = W.getCurve(landrace, 0.30269)
check(string.format("shelf: an old outlier keeps its offset and grows (%.1f -> %.1f -> %.1f kg), one warning", 27.80809, afterOne, light.weight),
    afterOne > 27.80809 and math.abs(afterOne - 27.80809 - (curve:value(8) - curve:value(7))) < 1e-6 and light.weight > afterOne
    and warnings(logged) == 1)
local heavy = pig(8, 1.455847, 287.748749)
local before = heavy.weight
W.check(heavy, landrace, "SHELF")
check("an existing heavy listing is not clipped, only warned", heavy.weight == before and warnings(logged) == 2)

-- A goat: no curve, the old rules' weight stays.
local goat = GrowthSim.makeAnimal("GOAT", { age = 5 })
local goatWeight = goat.weight
W.applyToNewStock(goat, goat:getSubType())
goat.age = 6
W.onShelfAged(goat, 5)
check("a goat (no breed curve) keeps the old rules' weight", goat.weight == goatWeight and W.getBinding(goat:getSubType()) == nil)

-- Curves on (sheep): Animal.new already gives the curve and a generated state; the shelf moves both.
SheepSim.enable(true)
local lamb = SheepSim.grown("SHEEP_LANDRACE", "DW1", 4)
local sub = lamb:getSubType()
local listed = lamb.weight
W.applyToNewStock(lamb, sub)
local unchanged = lamb.weight == listed
-- The pool's daily progression has already advanced its clock by a model month.
lamb.rlGrowth.ageMonths = 5
lamb.age = 5
W.onShelfAged(lamb, 4)
check("covered sheep: new stock keeps its curve weight; a month on the shelf moves weight and state together",
    unchanged and math.abs(lamb.weight - W.getCurve(sub, 1):value(5)) < 1e-6 and lamb.rlGrowth ~= nil
    and lamb.rlGrowth.source == "generated" and lamb.rlGrowth.ageMonths == 5 and math.abs(lamb.rlGrowth.weightKg - lamb.weight) < 1e-9)

-- A birthday need not coincide with a whole model month. Shelf weight refreshes must
-- preserve the clock that daily progression already advanced, including month-length changes.
for _, days in ipairs({ 1, 2, 28 }) do
    local listing = SheepSim.grown("SHEEP_LANDRACE", "CLOCK" .. days, 4)
    listing.rlGrowth.ageMonths = 4.5 + 1 / days
    listing.age = 5
    local clock = listing.rlGrowth.ageMonths
    W.onShelfAged(listing, 4)
    check("shelf birthday: the advanced clock survives at " .. days .. " days/month",
        listing.rlGrowth.ageMonths == clock and math.abs(listing.rlGrowth.weightKg - listing.weight) < 1e-9)
end
local switched = SheepSim.grown("SHEEP_LANDRACE", "CLOCK-SWITCH", 4)
for _, days in ipairs({ 28, 2, 1 }) do
    switched.rlGrowth.ageMonths = switched.rlGrowth.ageMonths + 1 / days
    local oldAge, clock = switched.age, switched.rlGrowth.ageMonths
    switched.age = oldAge + 1
    W.onShelfAged(switched, oldAge)
    check("shelf birthday: changing month length to " .. days .. " preserves prior clock progress",
        switched.rlGrowth.ageMonths == clock)
end
SheepSim.enable(false)

-- Wiring: the dealer's generation and its shelf day call it; the mod loads it.
local function read(path) local f = assert(io.open(REPO .. path, "r")); local t = f:read("a"); f:close(); return t end
local system = read("scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua")
local main = read("scripts/main.lua")
local gen = system:find("RLDealerStockWeight.applyToNewStock(animal, subType)", 1, true)
local validate = gen ~= nil and system:find("RLDealerStockPolicy.validate(animal, purpose, entry, subType, ctx)", gen, true) or nil
check("wiring: generation sets the weight before the purpose checks; the shelf day grows it; main.lua loads it",
    gen ~= nil and validate ~= nil and system:find("RLDealerStockWeight.onShelfAged(animal, ageBefore)", 1, true) ~= nil
    and main:find("scripts/dealer/RLDealerStockWeight.lua", 1, true) ~= nil)
while #LOG > 0 and LOG[#LOG]:find("Dealer stock", 1, true) do table.remove(LOG) end
