-- Pig P5 (2026-10-16): growing pigs in the real-equivalent nutrition mode, monogastric (NRC 2012 ch. 8):
-- the PIG sections of feedProfiles.xml and bodyCondition.xml, the monogastric planner, SID lysine per MJ
-- of ME, the maintenance exponent and the pen gate that keeps sows and unweaned piglets on the old rules.
-- Cattle and sheep configs are untouched (their hashes) and never take the monogastric path.

loadMod("tests/pigsim.lua")

local F, M, P = RLFeedProfiles, RLFeedMath, RLFeedRationPlanner
local feed = F.getConfig()
local pig = feed.species.PIG
local KCAL = 4.184 / 1000

-- Config.
check("config: the PIG section is valid and monogastric, the root and sheep hashes as on dev (2050392e / 35154e91)",
    pig ~= nil and pig.valid == true and pig.monogastric ~= nil and feed.hash == "2050392e" and feed.species.SHEEP.hash == "35154e91")
local own, allLys = 0, true
for name in pairs(pig.ownFeeds or {}) do
    own = own + 1
    allLys = allLys and pig.feeds[name].valid and pig.feeds[name].sidLys ~= nil
end
check("config: 20 pig feeds of its own, each valid with SID lysine", own == 20 and allLys)
check("config: a pig's wheat is pig ME (15.4 MJ/kg DM, INRA), the cattle wheat is not changed",
    F.getUsableFeed("WHEAT", pig).me == 15.4 and F.getUsableFeed("WHEAT") ~= F.getUsableFeed("WHEAT", pig)
    and F.getUsableFeed("WHEAT").sidLys == nil)
check("config: grass and silage stay unvalued for pigs only where the root has them (the root's feeds are kept)",
    F.getUsableFeed("SILAGE", pig) == F.getUsableFeed("SILAGE"))
local mono = pig.monogastric
check("config: maintenance x W^0.60 (Eq. 8-19), physical cap 0.111 x W^0.803 at 90% DM (Eq. 8-16)",
    mono.maintenanceExponent == 0.60 and near(mono.physicalKgDMPerKg, 0.0999, 1e-9) and mono.physicalExponent == 0.803)
local body = RLBodyConditionConfig.get().species.PIG
check("config: the PIG body section: reference 17.8% lipid (0.356 x 0.5), no ceiling below capacity, conception untouched",
    body ~= nil and body.enabled ~= false and near(body.reserveCapacityRatio * body.referenceReserve, 0.178, 1e-9)
    and body.heiferReserveCeiling == 1.0 and body.fertilityEffect == 0 and body.youngUntilMonth == 8)

-- Math.
check("math: sexes are female / castrate / male", M.getMonoSex("female") == "female" and M.getMonoSex("male", true) == "castrate"
    and M.getMonoSex("male", false) == "male")
check("math: ME eaten freely at 60 kg = NRC Eqs. 8-10 / 8-11 / 8-12",
    near(M.getMonoEnergyIntake(60, "female", mono), 10967 * (1 - math.exp(-math.exp(-3.803) * 60 ^ 0.9072)) * KCAL, 1e-3)
    and near(M.getMonoEnergyIntake(60, "castrate", mono), 10447 * (1 - math.exp(-math.exp(-4.283) * 60 ^ 1.0843)) * KCAL, 1e-3)
    and near(M.getMonoEnergyIntake(60, "male", mono), 10638 * (1 - math.exp(-math.exp(-3.803) * 60 ^ 0.9072)) * KCAL, 1e-3))
check("math: SID lysine need by weight and sex (Table 16-1A / 16-2A): 0.710 g/MJ at 37.5 kg; at 87.5 kg 0.558 gilt, 0.500 barrow, 0.594 boar",
    near(M.getLysineNeed(37.5, "female", mono), 0.710, 1e-9) and near(M.getLysineNeed(87.5, "female", mono), 0.558, 1e-9)
    and near(M.getLysineNeed(87.5, "castrate", mono), 0.500, 1e-9) and near(M.getLysineNeed(87.5, "male", mono), 0.594, 1e-9)
    and near(M.getLysineNeed(150, "male", mono), 0.529, 1e-9) and near(M.getLysineNeed(3, "male", mono), 1.054, 1e-9))
check("math: frame cost 10.03 x (W/60)^0.133 MJ/kg (NRC Eqs. 8-2/8-3 x 10.6 kcal/g), the 7.0 floor below about 4 kg",
    near(M.getGrowthCost(60, pig.requirements, pig.physiology.growthReferenceKg), 10.03, 1e-9)
    and near(M.getGrowthCost(5, pig.requirements, pig.physiology.growthReferenceKg), 10.03 * (5 / 60) ^ 0.133, 1e-9)
    and M.getGrowthCost(1.5, pig.requirements, pig.physiology.growthReferenceKg) == 7.0)
local pigCfg = M.getEnergyConfig(body, pig)
local cowCfg = M.getEnergyConfig(RLBodyConditionConfig.get(), feed)
check("math: the pig energy config has maintenance exponent 0.60; cattle none (W^0.75 as before)",
    pigCfg.maintenanceExponent == 0.60 and cowCfg.maintenanceExponent == nil)

-- Stock shares.
local function entry(name, kg, cap) return { name = name, availableKg = kg, profile = { maxShare = cap } } end
local s1 = P.getStockShares({ entry("A", 30), entry("B", 10) })
check("shares: in proportion to the stock", near(s1.A, 0.75, 1e-12) and near(s1.B, 0.25, 1e-12))
local s2 = P.getStockShares({ entry("A", 10), entry("SOY", 30, 0.25) })
check("shares: a capped feed at its cap, the rest takes what is left", near(s2.SOY, 0.25, 1e-12) and near(s2.A, 0.75, 1e-12))
local s3 = P.getStockShares({ entry("SOY", 30, 0.25), entry("EMPTY", 0) })
check("shares: only a capped feed stocked: its cap (the animal goes short of the rest)", near(s3.SOY, 0.25, 1e-12) and s3.EMPTY == nil)

-- The pen.
FeedSim.setMode(true)
PigSim.enable(true)
local gilt = PigSim.grown("PIG_LANDRACE", 1, 4)
gilt.weight = 60
local pen = PigSim.makePen({ gilt }, { PIGFOOD = 4000 })
local active, why = RLFeed.evaluatePen(pen)
check("pen: growing pigs run the mode (" .. tostring(why) .. ")", active == true and why == "OK")
local d = RLFeed.describeAnimal(gilt, RLFeed.getRation(pen), 0.25 / 30, 0.25)
check("pen: a gilt under 8 months eats freely (AUTO FINISH), weaned, its sex's energy and lysine",
    d.target == "FINISH" and d.stage == "WEANED" and d.sex == "female" and near(d.energyCap, M.getMonoEnergyIntake(d.weight, "female", mono), 1e-9)
    and near(d.proteinNeed, M.getLysineNeed(d.weight, "female", mono), 1e-9))
local plan = RLFeed.planPen(pen, RLFeed.getRation(pen), { d }, 0.25)
local a = plan.animals[1]
local pigfood = F.getUsableFeed("PIGFOOD", pig)
check("plan: on PIGFOOD it eats its energy appetite (ENERGY): kg DM = MJ / 15.34",
    plan.monogastric == true and a.intakeLimit == "ENERGY" and near(a.kg, d.energyCap * 0.25 / 15.34, 1e-9)
    and near(a.me, d.energyCap * 0.25, 1e-9))
check("plan: SID lysine per MJ of PIGFOOD 9.44 / 15.34 = 0.615 g/MJ", near(a.lysPerMe, 9.44 / 15.34, 1e-9)
    and near(RLFeed.getStepProteinFactor(a, pig), (9.44 / 15.34 - 0.05) / (d.proteinNeed - 0.05), 1e-9))
check("plan: the withdrawal is the kg DM eaten at PIGFOOD's density, DM and the resource scale",
    near(plan.withdraw.PIGFOOD, RLFeedUnits.kgToLiters(a.kg, pig.resourceScale, pigfood.density, pigfood.dm), 1e-9))

local potatoPen = PigSim.makePen({ gilt }, { POTATO = 4000 })
local pp = RLFeed.planPen(potatoPen, RLFeed.getRation(potatoPen), { d }, 0.25).animals[1]
check("plan: on raw potatoes alone it eats at most their 30% share of its intake (FEED_CAP)",
    pp.intakeLimit == "FEED_CAP" and near(pp.kg, 0.30 * math.min(d.appetite * 0.25, d.energyCap * 0.25 / 15.1), 1e-9))

local light = PigSim.grown("PIG_LANDRACE", 2, 1.2)
local mixPen = PigSim.makePen({ gilt, light }, { PIGFOOD = 2000, PIGLETFOOD = 2000 })
local animals = RLFeed.describePen(mixPen, RLFeed.getRation(mixPen), 0.25)
local mp = RLFeed.planPen(mixPen, RLFeed.getRation(mixPen), animals, 0.25)
local byName = {}
for _, x in ipairs(mp.animals) do byName[x.animal.id] = x end
check("plan: piglet feed only for pigs up to 25 kg; a light pig eats both, as stocked",
    byName[1].byFill.PIGLETFOOD == nil and byName[1].byFill.PIGFOOD ~= nil
    and byName[2].byFill.PIGLETFOOD ~= nil and byName[2].byFill.PIGFOOD ~= nil
    and near(byName[2].byFill.PIGLETFOOD.kg, byName[2].byFill.PIGFOOD.kg, 1e-9))

-- An hour in the mode moves the gilt on its budget and takes the feed.
local before, level = gilt.weight, pen:level("PIGFOOD")
FeedSim.hour(pen)
check("hour: the pen ran the mode, the gilt grew and the trough gave PIGFOOD",
    pen.spec_husbandryFood.rlFeedPen.active == true and gilt.weight > before and pen:level("PIGFOOD") < level)

-- The pen gate.
local function reason(animals)
    local _, r = RLFeed.evaluatePen(PigSim.makePen(animals, { PIGFOOD = 100 }))
    return r
end
check("gate: an unweaned piglet, a pregnant gilt or a sow that farrowed keeps the pen on the old rules",
    reason({ PigSim.grown("PIG_LANDRACE", 3, 3), PigSim.grown("PIG_LANDRACE", 4, 0.5) }) == "PIG_BREEDING_LEGACY"
    and reason({ PigSim.grown("PIG_LANDRACE", 5, 9, { isPregnant = true }) }) == "PIG_BREEDING_LEGACY"
    and reason({ PigSim.grown("PIG_LANDRACE", 6, 18, { isParent = true }) }) == "PIG_BREEDING_LEGACY"
    and reason({ PigSim.grown("PIG_LANDRACE", 7, 0.95) }) == "OK")
local legacyPen = PigSim.makePen({ PigSim.grown("PIG_LANDRACE", 8, 18, { isParent = true }) }, { PIGFOOD = 100 })
FeedSim.hour(legacyPen)
check("gate: a legacy pen's hour is not the mode's", legacyPen.spec_husbandryFood.rlFeedPen.active == false)

PigSim.enable(false)
local _, offWhy = RLFeed.evaluatePen(PigSim.makePen({ PigSim.grown("PIG_LANDRACE", 9, 3) }, { PIGFOOD = 100 }))
check("off: with the PIG curves off a pig pen keeps the old rules (UNCOVERED_ANIMAL)", offWhy == "UNCOVERED_ANIMAL")
FeedSim.setMode(false)
