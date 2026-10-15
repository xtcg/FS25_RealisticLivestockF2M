-- Sheep S5 calibration measurements (tests/sheepcalib.lua, tests/sheepcalib_scenarios.lua): from the
-- real-equivalent mode's STEP events only (RLFeed observers: read-only), per animal
--   - elapsedModelDays: the model days of its own steps (not game hours x a month's days);
--   - a crossing record against a reference weight: lastBelow / firstAtOrAbove = { days, weight }
--     at step ends, and crossingEstimateDays, the linear interpolation between them (an estimate,
--     never the judged value by itself);
--   - what it ate: fresh kg, DM kg, ME MJ, concentrate fresh kg, by fill type;
--   - the budget's own ledger, step by step (supplyNU, demandNU, paidNU, unmetNU, depositNU,
--     mobilizedNU, catabolismNU, lostNU, maintenanceNU, pregnancyNU), by bucket of its model days.
-- And FCR helpers: conversion proxies on live gain x a kill-out, and on the game's saleable meat.

SheepMetrics = {}

SheepMetrics.LEDGER = { "supplyNU", "demandNU", "paidNU", "unmetNU", "depositNU", "mobilizedNU", "catabolismNU", "lostNU",
    "maintenanceNU", "pregnancyNU" }
SheepMetrics.CONCENTRATE = { BARLEY = true, PEA = true, WHEAT = true, MAIZE = true, OAT = true, GRAINGRIST = true }
-- Model days compared at a boundary only allow for rounding.
SheepMetrics.EPS_DAYS = 1e-9

--- kg fresh weight of a fill eaten (its liters at the feed's density, the resource scale undone).
function SheepMetrics.freshKg(name, liters)
    local p = RLFeedProfiles.getUsableFeed(name)
    if p == nil or p.density == nil or p.density <= 0 then return 0 end
    return liters * p.density / RLFeedProfiles.getConfig().resourceScale
end


--- The game's saleable meat of an animal now (the farm butcher's model meat, no age gate).
function SheepMetrics.saleableMeat(animal)
    local result = AnimalMoveEvent.getCarcassYield(animal, nil, animal.subTypeIndex)
    return result ~= nil and result.modelMeat or nil
end


--- Concentrate (kg fresh) per kg of live gain x killOut: a carcass-gain proxy, not a measured
--- carcass gain.
function SheepMetrics.fcrOnLive(concFresh, liveGain, killOut)
    if liveGain == nil or liveGain <= 0 then return nil end
    return concFresh / (liveGain * killOut)
end


--- Concentrate (kg fresh) per kg of the game's saleable meat gained (never a trial's FCR).
function SheepMetrics.fcrOnMeat(concFresh, meatGain)
    if meatGain == nil or meatGain <= 0 then return nil end
    return concFresh / meatGain
end


--- Start tracking animals. opts.reference(animal) -> kg or nil (no crossing record);
--- opts.bucketDays: ledger buckets of the animal's own model days (default 30, a model month).
--- @return table tracker { rec = animal -> record, stop = function, add = function(animal) }
function SheepMetrics.track(animals, opts)
    opts = opts or {}
    local bucketDays = opts.bucketDays or 30
    local tracker = { rec = {} }
    local function newRecord(animal)
        local ref = opts.reference ~= nil and opts.reference(animal) or nil
        local r = { elapsedModelDays = 0, steps = 0, ref = ref, startWeight = animal.weight,
            lastBelow = ref ~= nil and animal.weight < ref and { days = 0, weight = animal.weight } or nil,
            intake = { freshKg = 0, dmKg = 0, meMJ = 0, concFreshKg = 0, byFill = {} }, ledger = {}, ledgerTotal = {} }
        if ref ~= nil and animal.weight >= ref then r.firstAtOrAbove = { days = 0, weight = animal.weight } end
        return r
    end
    function tracker.add(animal) if tracker.rec[animal] == nil then tracker.rec[animal] = newRecord(animal) end end
    for _, animal in ipairs(animals or {}) do tracker.add(animal) end
    local fn = function(kind, data)
        if kind ~= "STEP" then return end
        for _, e in ipairs(data.animals) do
            local r = tracker.rec[e.animal]
            if r ~= nil then
                local dt = e.feed.dtDays or 0
                local bucket = math.floor(r.elapsedModelDays / bucketDays + SheepMetrics.EPS_DAYS) + 1
                r.elapsedModelDays = r.elapsedModelDays + dt
                r.steps = r.steps + 1
                -- What it ate, in all and in the bucket.
                local b = r.ledger[bucket] or { days = 0, freshKg = 0, dmKg = 0, meMJ = 0, concFreshKg = 0 }
                r.ledger[bucket] = b
                b.days = b.days + dt
                local intake = r.intake
                for name, fill in pairs(e.feed.byFill or {}) do
                    local fresh = SheepMetrics.freshKg(name, fill.liters or 0)
                    local f = intake.byFill[name] or { freshKg = 0, dmKg = 0, meMJ = 0 }
                    intake.byFill[name] = f
                    f.freshKg, f.dmKg, f.meMJ = f.freshKg + fresh, f.dmKg + (fill.kg or 0), f.meMJ + (fill.me or 0)
                    intake.freshKg, b.freshKg = intake.freshKg + fresh, b.freshKg + fresh
                    if SheepMetrics.CONCENTRATE[name] then
                        intake.concFreshKg, b.concFreshKg = intake.concFreshKg + fresh, b.concFreshKg + fresh
                    end
                end
                intake.dmKg, intake.meMJ = intake.dmKg + (e.feed.kg or 0), intake.meMJ + (e.feed.me or 0)
                b.dmKg, b.meMJ = b.dmKg + (e.feed.kg or 0), b.meMJ + (e.feed.me or 0)
                -- The budget's ledger.
                local result = e.result
                if result ~= nil then
                    for _, key in ipairs(SheepMetrics.LEDGER) do
                        local v = result[key] or 0
                        b[key] = (b[key] or 0) + v
                        r.ledgerTotal[key] = (r.ledgerTotal[key] or 0) + v
                    end
                end
                -- The crossing record, at step ends.
                if r.ref ~= nil and r.firstAtOrAbove == nil then
                    local w = e.weightAfter
                    if w >= r.ref then
                        r.firstAtOrAbove = { days = r.elapsedModelDays, weight = w }
                        local before = r.lastBelow
                        if before ~= nil and w > before.weight then
                            r.crossingEstimateDays = before.days + (r.ref - before.weight) / (w - before.weight) * (r.elapsedModelDays - before.days)
                        else
                            r.crossingEstimateDays = r.elapsedModelDays
                        end
                    else
                        r.lastBelow = { days = r.elapsedModelDays, weight = w }
                    end
                end
            end
        end
    end
    RLFeed.addObserver(fn)
    function tracker.stop() RLFeed.removeObserver(fn) end
    return tracker
end


--- A record as plain data (no animal keys), for CALIB.
function SheepMetrics.export(r)
    if r == nil then return nil end
    local ledger = {}
    for bucket, b in pairs(r.ledger) do ledger[#ledger + 1] = b; b.bucket = bucket end
    table.sort(ledger, function(a, b) return a.bucket < b.bucket end)
    local total = r.ledgerTotal
    local closure = (total.supplyNU or 0) + (total.mobilizedNU or 0) + (total.catabolismNU or 0)
        - (total.paidNU or 0) - (total.depositNU or 0) - (total.lostNU or 0)
    return { elapsedModelDays = r.elapsedModelDays, steps = r.steps, ref = r.ref, lastBelow = r.lastBelow,
        firstAtOrAbove = r.firstAtOrAbove, crossingEstimateDays = r.crossingEstimateDays, intake = r.intake,
        ledger = ledger, ledgerTotal = total, ledgerClosureNU = closure }
end
