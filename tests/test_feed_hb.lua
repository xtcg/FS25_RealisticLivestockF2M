-- FEED-13: Hof Bergmann's feeds without a fixed identity. GRAINGRIST is a stated proxy (50% wheat +
-- 50% barley of the DM; the mill merges its grains), at a density that keeps the 1:1 mill from
-- making or losing feed, capped as wheat, for weaned animals; ROUNDBALE is a bale marker, never a
-- feed (a bale adds its own content to a trough).

loadMod("tests/feedsim.lua")
loadMod("scripts/events/RLFeedRationEvent.lua")
loadMod("scripts/gui/rlmenu/services/RLFeedRationModel.lua")

local F = RLFeedProfiles
local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end

local grist, wheat, barley = F.getUsableFeed("GRAINGRIST"), F.getUsableFeed("WHEAT"), F.getUsableFeed("BARLEY")
local mean = function(field) return (wheat[field] + barley[field]) / 2 end
check("grist: a stated proxy - every value the mean of wheat and barley, ME from their mean TDN",
    grist.status == "PROXY" and grist.role == "CONCENTRATE" and near(grist.dm, mean("dm")) and near(grist.tdn, mean("tdn"))
    and near(grist.me, RLFeedUnits.getMEFromTDN(mean("tdn"))) and near(grist.cp, mean("cp")) and near(grist.ndf, mean("ndf"))
    and near(grist.starch, mean("starch")) and near(grist.sugar, mean("sugar")))
local inputDm = 1 * wheat.density * wheat.dm + 1 * barley.density * barley.dm
local outputDm = 2 * grist.density * grist.dm
check(string.format("grist: the mill's 1:1 liters keep the DM (in %.4f kg, out %.4f kg per 2 L)", inputDm, outputDm),
    near(grist.density, mean("density")) and math.abs(outputDm / inputDm - 1) < 0.001)
check("grist: capped as wheat (30% of the ration), for weaned animals only", grist.maxShare == 0.30 and grist.stages.WEANED
    and not grist.stages.PRE_WEANING and not grist.stages.WEANING)
check("bale: ROUNDBALE stays unconfigured (never eaten)", F.getFeed("ROUNDBALE") ~= nil and F.getUsableFeed("ROUNDBALE") == nil)

FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(1)
local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
local pen = FeedSim.makePen({ bull }, { DRYGRASS_WINDROW = 1e6, GRAINGRIST = 1e6 })
RLGrowth.ensureState(bull).feedAdapted = 1
RLFeed.setRation(pen, { target = "FINISH", grain = "GRAINGRIST", share = 0.6 })
FeedSim.untilStep(pen)
local r = bull.rlFeedIntake
check(string.format("grist: a bull on hay and grist asked for 60%% eats %.1f%% grist (FEED_CAP)", r.byFill.GRAINGRIST.kg / r.kg * 100),
    near(r.byFill.GRAINGRIST.kg / r.kg, 0.30, 1e-6) and r.concLimit == "FEED_CAP")

local calf = GrowthSim.newborn("BULL_HOLSTEIN")
calf.age = 2
local nursery = FeedSim.makePen({ calf }, { CALFMILK = 1e5, FORAGE = 1e5, GRAINGRIST = 1e5 }, { rearing = true })
FeedSim.untilStep(nursery)
check("grist: a calf on milk eats none (weaned animals only)", calf.rlFeedIntake.byFill.GRAINGRIST == nil and nursery:level("GRAINGRIST") == 1e5)

local model = RLFeedRationModel.new(pen)
local listed = false
for _, grain in ipairs(model.grains) do listed = listed or grain == "GRAINGRIST" end
check("grist: the ration dialog offers it as the pen's concentrate", listed)
