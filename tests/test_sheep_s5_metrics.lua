-- Sheep S5 calibration measurements (tests/sheepcalib_metrics.lua) on hand-made STEP events: model
-- time, the crossing record and its interpolation, intake in fresh weight, the ledger by bucket and
-- its closure. The calibration's judgements rest on these.

loadMod("tests/feedsim.lua")
loadMod("tests/sheepcalib_metrics.lua")

local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end

local animal = { weight = 40 }
local other = { weight = 10 }
local tracker = SheepMetrics.track({ animal }, { reference = function(a) return a == animal and 42 or nil end, bucketDays = 1 })
local barley = RLFeedProfiles.getUsableFeed("BARLEY")
local litersPerKg = RLFeedProfiles.getConfig().resourceScale / barley.density

local function step(weightAfter, dt, barleyKgFresh, result)
    local liters = barleyKgFresh * litersPerKg
    RLFeed.notify("STEP", { stepDays = dt, animals = {
        { animal = animal, weightAfter = weightAfter, result = result,
          feed = { dtDays = dt, kg = barleyKgFresh * barley.dm, me = 3, byFill = { BARLEY = { liters = liters, kg = barleyKgFresh * barley.dm, me = 3 } } } },
        { animal = other, weightAfter = 11, feed = { dtDays = dt, kg = 1, me = 1, byFill = {} } },
    } })
end
local ledger = { supplyNU = 10, mobilizedNU = 2, catabolismNU = 0, paidNU = 9, depositNU = 1, lostNU = 2, demandNU = 12, unmetNU = 3 }
step(40.5, 0.25, 0.4, ledger)
step(41.0, 0.25, 0.4, ledger)
step(41.6, 0.25, 0.4, ledger)
step(42.4, 0.25, 0.4, ledger)   -- crosses 42 between 0.75 d (41.6) and 1.0 d (42.4)
step(43.0, 0.25, 0.4, ledger)
tracker.stop()
step(44.0, 0.25, 0.4, ledger)   -- after stop: not counted

local r = SheepMetrics.export(tracker.rec[animal])
check(string.format("metrics: model days are the animal's own steps (%.2f d, %d steps); an untracked animal is ignored", r.elapsedModelDays, r.steps),
    near(r.elapsedModelDays, 1.25) and r.steps == 5 and tracker.rec[other] == nil)
check("metrics: the crossing record holds the last step end below and the first at or above the reference",
    near(r.lastBelow.days, 0.75) and near(r.lastBelow.weight, 41.6) and near(r.firstAtOrAbove.days, 1.0) and near(r.firstAtOrAbove.weight, 42.4))
check(string.format("metrics: the estimate interpolates between them (%.4f d = 0.75 + 0.4 / 0.8 x 0.25)", r.crossingEstimateDays),
    near(r.crossingEstimateDays, 0.875))
check(string.format("metrics: intake in fresh weight from the liters (%.3f kg barley, DM %.3f)", r.intake.concFreshKg, r.intake.dmKg),
    near(r.intake.concFreshKg, 2.0, 1e-9) and near(r.intake.byFill.BARLEY.freshKg, 2.0, 1e-9) and near(r.intake.dmKg, 2.0 * barley.dm, 1e-9))
check(string.format("metrics: the ledger sums each step by bucket (%d buckets) and closes (residual %.3f)", #r.ledger, r.ledgerClosureNU),
    #r.ledger == 2 and near(r.ledger[1].supplyNU, 40) and near(r.ledger[2].supplyNU, 10) and near(r.ledgerTotal.unmetNU, 15)
    and near(r.ledgerClosureNU, 0))

local start = { weight = 45 }
local t2 = SheepMetrics.track({ start }, { reference = function() return 42 end })
local r2 = SheepMetrics.export(t2.rec[start])
t2.stop()
check("metrics: an animal already at its reference crosses at day 0 with no step below",
    r2.firstAtOrAbove ~= nil and r2.firstAtOrAbove.days == 0 and r2.lastBelow == nil)
check("metrics: FCR proxies divide by live gain x kill-out, the meat FCR by meat gained; nothing for no gain",
    near(SheepMetrics.fcrOnLive(10.7, 2, 0.5), 10.7) and near(SheepMetrics.fcrOnMeat(6, 2), 3) and SheepMetrics.fcrOnLive(1, 0, 0.49) == nil)
