-- FEED-12: the dam's milk in an ordinary pen. A calf on milk drinks from its lactating dam: her
-- budget pays her milk, her calves take it first up to their allowance (twins share it), the store
-- gets the rest; milk in the trough only makes up what she did not give, within the allowance.
-- Every liter she paid goes one way: paid = to her calves + to the store. A calf without its
-- lactating dam in the pen keeps the pen on the old rules (SUCKLING_CALF).

loadMod("tests/feedsim.lua")

local config = RLFeed.getConfig()
local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end

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

local function calf(name, motherId, id)
    local c = GrowthSim.newborn(name, { motherId = motherId })
    return identify(c, id)
end

--- Run hours until one with a step, collecting STEP events.
local function step(pen, opts)
    local steps = {}
    local function observe(kind, data) if kind == "STEP" then steps[#steps + 1] = data end end
    RLFeed.addObserver(observe)
    FeedSim.untilStep(pen, opts)
    RLFeed.removeObserver(observe)
    return steps
end

--- Every dam entry of every step: what her calves drank equals what was allocated from her, never
--- more than she paid.
local function allocatedOnce(steps)
    local ok, checked = true, 0
    for _, data in ipairs(steps) do
        local drunk = {}
        for _, entry in ipairs(data.animals) do
            local milk = entry.feed.damMilk
            if milk ~= nil then
                local motherId = entry.animal.motherId
                drunk[motherId] = (drunk[motherId] or 0) + milk.kg
            end
        end
        for _, d in ipairs(data.dams) do
            checked = checked + 1
            local got = drunk[d.animal:getIdentifiers()] or 0
            ok = ok and near(got, d.allocatedKg, 1e-9) and d.allocatedKg <= d.paidKg + 1e-9
        end
    end
    return ok and checked > 0, checked
end


-- Which pens run the mode ----------------------------------------------------------------------

do
    local cow = dam("COW_HOLSTEIN", "D1")
    local c = calf("BULL_HOLSTEIN", "D1", "C1")
    local pen = FeedSim.makePen({ cow, c }, { FORAGE = 1e5 })
    FeedSim.hour(pen)
    check("pen: a calf on milk with its lactating dam runs the mode (no longer SUCKLING_CALF)",
        pen.spec_husbandryFood.rlFeedPen.active == true and pen.spec_husbandryFood.rlFeedPen.reason == "OK")

    local orphan = FeedSim.makePen({ calf("BULL_HOLSTEIN", "D9", "C2") }, { FORAGE = 1e5 })
    FeedSim.hour(orphan)
    local dry = dam("COW_HOLSTEIN", "D3")
    dry.isLactating = false
    local dryPen = FeedSim.makePen({ dry, calf("BULL_HOLSTEIN", "D3", "C3") }, { FORAGE = 1e5 })
    FeedSim.hour(dryPen)
    local elsewhere = FeedSim.makePen({ calf("BULL_HOLSTEIN", "D1", "C4") }, { FORAGE = 1e5 })
    FeedSim.hour(elsewhere)
    check("pen: a calf whose dam is missing, dry or in another pen keeps the pen on the old rules (SUCKLING_CALF)",
        orphan.spec_husbandryFood.rlFeedPen.reason == "SUCKLING_CALF" and dryPen.spec_husbandryFood.rlFeedPen.reason == "SUCKLING_CALF"
        and elsewhere.spec_husbandryFood.rlFeedPen.reason == "SUCKLING_CALF")
end


-- Calves without a dam that can nurse them: weaned early from calfMilk earlyWeaningMonth (3) ------

do
    local function olderCalf(name, motherId, id, months)
        local c = identify((GrowthSim.makeAnimal(name, { age = math.floor(months), motherId = motherId })), id)
        if c.rlGrowth ~= nil then c.rlGrowth.ageMonths = months end
        return c
    end
    local saved = config.calfMilk.earlyWeaningMonth
    config.calfMilk.earlyWeaningMonth = 2
    local changedHash = RLFeedProfiles.computeHash(config)
    config.calfMilk.earlyWeaningMonth = saved
    check("config: earlyWeaningMonth 3 by default, in the fingerprint", saved == 3 and changedHash ~= config.hash)

    local orphan = olderCalf("BULL_ANGUS", "D90", "C90", 3.5)
    local orphanPen = FeedSim.makePen({ orphan }, { FORAGE = 1e5 })
    FeedSim.hour(orphanPen)
    local young = olderCalf("BULL_ANGUS", "D91", "C91", 2.5)
    local youngPen = FeedSim.makePen({ young }, { FORAGE = 1e5 })
    FeedSim.hour(youngPen)
    check("orphan 3.5 months (calf rearing still has milk for it until 4): weaned early, the pen runs the mode; at 2.5: SUCKLING_CALF",
        orphanPen.spec_husbandryFood.rlFeedPen.active == true and RLFeed.isEarlyWeaned(orphan)
        and RLFeed.getRationClass(orphan) == "GROWING" and RLFeed.getCalfMaintenanceFactor(orphan, 0) == 1
        and youngPen.spec_husbandryFood.rlFeedPen.reason == "SUCKLING_CALF" and not RLFeed.isEarlyWeaned(young))

    local cow = dam("COW_ANGUS", "D92")
    local withDam = olderCalf("BULL_ANGUS", "D92", "C92", 3.5)
    local pen = FeedSim.makePen({ cow, withDam }, { FORAGE = 1e5 })
    FeedSim.hour(pen)
    local drankBefore = withDam.rlFeedIntake ~= nil and withDam.rlFeedIntake.damMilkKg or 0
    local classWithDam = RLFeed.getRationClass(withDam)
    -- Her dam is sold: from the next hour the calf is weaned.
    pen.animals = { withDam }
    FeedSim.hour(pen)
    check(string.format("with its dam at 3.5 months a calf still drinks (%.2f kg DM); once she is gone it is weaned and the pen keeps the mode",
        drankBefore), classWithDam == "CALF" and drankBefore > 0 and pen.spec_husbandryFood.rlFeedPen.active == true
        and RLFeed.getRationClass(withDam) == "GROWING")

    local reared = olderCalf("BULL_HOLSTEIN", "D93", "C93", 3.5)
    local rearingPen = FeedSim.makePen({ reared }, { FORAGE = 1e5, CALFMILK = 1e4 }, { rearing = true })
    FeedSim.hour(rearingPen)
    check("in a calf rearing pen the rearing rules hold: a 3.5-month calf there is still on milk",
        not RLFeed.isEarlyWeaned(reared) and RLFeed.getRationClass(reared) == "CALF")
end


-- A dairy dam and her calf ------------------------------------------------------------------------

do
    local cow = dam("COW_HOLSTEIN", "D10")
    local c = calf("BULL_HOLSTEIN", "D10", "C10")
    local pen = FeedSim.makePen({ cow, c }, { FORAGE = 1e5, CALFMILK = 1e4 })
    local steps = step(pen)
    local ok, checked = allocatedOnce(steps)
    check(string.format("milk: what the calf drank from its dam is what she gave, never more than she paid (%d steps)", checked), ok)
    local record, calfRecord = cow.rlFeedIntake, c.rlFeedIntake
    local allowance = 0
    for _, data in ipairs(steps) do
        for _, entry in ipairs(data.animals) do if entry.animal == c then allowance = allowance + entry.feed.kg end end
    end
    check("milk: a Holstein dam gives her calf its whole allowance; the trough's milk is not touched",
        calfRecord.damMilkKg > 0 and pen:level("CALFMILK") == 1e4 and calfRecord.byFill.CALFMILK == nil)
    check(string.format("milk: her paid milk %.3f L = %.3f L to her calf + %.3f L to the store", record.milkPaidLiters,
        record.milkToCalves or 0, record.milkLiters), (record.milkToCalves or 0) > 0
        and near(record.milkPaidLiters, (record.milkToCalves or 0) + record.milkLiters, 1e-9))
    local perLiter = RLFeed.getMilkRealPerGameLiter(cow) * config.damMilk.dm
    check("milk: the liters she gave are the calf's real milk DM through the milk bridge",
        near((record.milkToCalves or 0) * perLiter, calfRecord.damMilkKg, 1e-9))
    local paid = cow.rlMilkPaid
    check("milk: the store is paid only the rest", near(paid.litersPerHour * GrowthSim.env.timeAdjustment, record.milkLiters, 1e-9))
    check("milk: her own milk share is what her budget paid (her calf's part included)",
        near(cow.rlNutrition.milkShare, record.milkPaidLiters / record.milkPotential, 1e-12))
    check("milk: the calf's DM, ME and protein count its dam's milk",
        near(calfRecord.kg, calfRecord.damMilkKg + (calfRecord.byFill.FORAGE ~= nil and calfRecord.byFill.FORAGE.kg or 0), 1e-9))
end


-- A beef dam, twins and the trough's milk ----------------------------------------------------------

do
    local cow = dam("COW_ANGUS", "D20")
    local a, b = calf("BULL_ANGUS", "D20", "C21"), calf("COW_ANGUS", "D20", "C22")
    local pen = FeedSim.makePen({ cow, a, b }, { FORAGE = 1e5 })
    local steps = step(pen)
    local ok = allocatedOnce(steps)
    local dams = steps[#steps].dams[1]
    check(string.format("twins: they share their dam's milk (%.4f + %.4f kg DM), together never more than she paid (%.4f)",
        a.rlFeedIntake.damMilkKg, b.rlFeedIntake.damMilkKg, dams.paidKg), ok and a.rlFeedIntake.damMilkKg > 0 and b.rlFeedIntake.damMilkKg > 0)

    -- The same twins with calf milk in the trough: it makes up only what she does not give.
    local cow2 = dam("COW_ANGUS", "D30")
    local a2, b2 = calf("BULL_ANGUS", "D30", "C31"), calf("COW_ANGUS", "D30", "C32")
    local pen2 = FeedSim.makePen({ cow2, a2, b2 }, { FORAGE = 1e5, CALFMILK = 1e4 })
    -- Its allowance at the start (it only falls with age on the weaning curve).
    local d = RLFeed.describeAnimal(a2, RLFeed.getRation(pen2), config.stepDays / 30, config.stepDays)
    local allowanceStep = d.nursingMaxKgPerDay * config.stepDays
    local steps2 = step(pen2)
    local planned, drunk = 0, 0
    for _, data in ipairs(steps2) do
        for _, entry in ipairs(data.animals) do
            if entry.animal == a2 then
                local milk = (entry.feed.damMilk ~= nil and entry.feed.damMilk.kg or 0) + (entry.feed.byFill.CALFMILK ~= nil and entry.feed.byFill.CALFMILK.kg or 0)
                drunk = drunk + milk
            end
        end
    end
    check(string.format("supplement: a beef dam's twins top up from the trough (%.4f kg DM), dam + trough within the allowance",
        a2.rlFeedIntake.byFill.CALFMILK ~= nil and a2.rlFeedIntake.byFill.CALFMILK.kg or 0),
        a2.rlFeedIntake.byFill.CALFMILK ~= nil and a2.rlFeedIntake.byFill.CALFMILK.kg > 0 and a2.rlFeedIntake.damMilkKg > 0
        and drunk <= allowanceStep * #steps2 + 1e-9 and drunk >= 0.99 * allowanceStep * #steps2 and allocatedOnce(steps2))
end


-- A dam short of feed: her calves get only what she paid -----------------------------------------------

do
    local cow = dam("COW_HOLSTEIN", "D40")
    local c = calf("BULL_HOLSTEIN", "D40", "C40")
    local pen = FeedSim.makePen({ cow, c }, { FORAGE = 1e5 })
    FeedSim.untilStep(pen)
    pen.spec_husbandryFood.fillLevels[FeedSim.FILL.FORAGE] = 0 -- no feed: her budget pays less milk
    local steps = {}
    local function observe(kind, data) if kind == "STEP" then steps[#steps + 1] = data end end
    RLFeed.addObserver(observe)
    for _ = 1, 48 do FeedSim.hour(pen) end
    RLFeed.removeObserver(observe)
    local short = false
    for _, data in ipairs(steps) do
        for _, d in ipairs(data.dams) do if d.paidKg < d.plannedKg - 1e-9 then short = true end end
    end
    check("short: when the dam pays less milk than planned her calf gets that, never more", short and allocatedOnce(steps))
end
