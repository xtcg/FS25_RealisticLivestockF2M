-- Review 2 of the real-equivalent mode (FEED-08..13): a dam without milk cannot nurse; a step that
-- fails after feed was taken keeps what was done and never adds the old rules on top; a feeding
-- window is fed once; the food factor of an hour without a step is the last step hour's (saved);
-- an 80% share survives the network's 32-bit floats; AUTO is planned in both passes, so short
-- grain is not under-fed; wheat and grain grist share one cap; limits count animals, not steps; an
-- animal moved between pens is not stepped again before its time; the ration change reaches an
-- open menu.

loadMod("tests/feedsim.lua")

local config = RLFeed.getConfig()
local FILL = FeedSim.FILL
local function near(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-9) end

FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(1)

local function identify(animal, id)
    animal.id = id
    animal.getIdentifiers = function(self) return self.id end
    return animal
end


-- A dam without milk (mastitis) cannot nurse ---------------------------------------------------------

do
    local cow = identify((GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 48, isParent = true, isLactating = true, monthsSinceLastBirth = 1 })), "DM")
    local calf = identify(GrowthSim.newborn("BULL_HOLSTEIN", { motherId = "DM" }), "CM")
    local pen = FeedSim.makePen({ cow, calf }, { FORAGE = 1e5 })
    FeedSim.hour(pen)
    local nursing = pen.spec_husbandryFood.rlFeedPen.reason
    cow.rlMilk.potential = 0 -- her milk stopped (a disease's milk modifier 0)
    local original = RLBodyCondition.applyMilk
    RLBodyCondition.applyMilk = function(animal, potential, ...) return original(animal, animal == cow and 0 or potential, ...) end
    FeedSim.hour(pen)
    RLBodyCondition.applyMilk = original
    check("dam: a lactating cow whose milk stopped cannot nurse; her calf keeps the pen on the old rules",
        nursing == "OK" and pen.spec_husbandryFood.rlFeedPen.reason == "SUCKLING_CALF")
end


-- A step that fails after the trough gave feed --------------------------------------------------------

do
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local pen = FeedSim.makePen({ bull }, { FORAGE = 1e5 })
    RLFeed.beginFeeding(pen)
    RLBodyCondition.beginFeeding(pen)
    local original = RLFeed.stepAnimal
    local calls = 0
    RLFeed.stepAnimal = function(...)
        calls = calls + 1
        if calls == 2 then error("broken step") end
        return original(...)
    end
    local before = pen:level("FORAGE")
    local ok, factor = pcall(RLFeed.consume, pen, {})
    RLFeed.stepAnimal = original
    local logged = false
    for i = #LOG, 1, -1 do if LOG[i]:find("a feeding step failed", 1, true) then logged = true; table.remove(LOG, i) end end
    local window = pen.spec_husbandryFood.rlFeedWindow
    check("step error: after the first removal a failing step keeps the step done and does not hand the hour to the old rules",
        ok and factor ~= nil and window ~= nil and window.hour.steps == 1 and logged and pen:level("FORAGE") < before)
    local again = RLFeed.consume(pen, {})
    check("window: a second consumeFood in the same feeding returns the first's factor and keeps its records",
        again == factor and window.hour.steps == 1 and window.hour.animals[bull] ~= nil)
    RLFeed.endFeeding(pen)
    RLBodyCondition.endFeeding(pen)
end


-- The food factor of hours without a step ------------------------------------------------------------

do
    GrowthSim.setDaysPerPeriod(28)
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local pen = FeedSim.makePen({ bull }, { FORAGE = 1e5 })
    local factors = {}
    for _ = 1, 30 do factors[#factors + 1] = FeedSim.hour(pen) end
    pen.spec_husbandryFood.fillLevels[FILL.FORAGE] = 0
    local stepHour
    for h = 1, 12 do
        local f = FeedSim.hour(pen)
        if stepHour == nil and pen.spec_husbandryFood.rlFeedLast ~= nil and pen.spec_husbandryFood.rlFeedLast.tick == RLBodyCondition.getTickId() then
            stepHour = h
        elseif stepHour ~= nil then
            factors.after = factors.after or f
        end
    end
    check("factor: once a step finds the trough empty, the hours until the next step keep its factor (not the last fed one)",
        stepHour ~= nil and pen.spec_husbandryFood.rlFeedFactor == 0 and factors.after == 0)
    local xml = { values = {} }
    function xml:setInt(k, v) self.values[k] = v end
    function xml:setFloat(k, v) self.values[k] = v end
    function xml:setString(k, v) self.values[k] = v end
    function xml:setBool(k, v) self.values[k] = v end
    function xml:getFloat(k, d) local v = self.values[k] if v == nil then return d end return v end
    function xml:getInt(k, d) local v = self.values[k] if v == nil then return d end return v end
    function xml:getString(k, d) local v = self.values[k] if v == nil then return d end return v end
    function xml:getBool(k, d) local v = self.values[k] if v == nil then return d end return v end
    function xml:iterate() end
    RLFeed.savePen(pen, xml, "pen")
    local loaded = FeedSim.makePen({}, {})
    RLFeed.loadPen(loaded, xml, "pen")
    check("factor: saved with the pen's clock", loaded.spec_husbandryFood.rlFeedFactor == 0)
    GrowthSim.setDaysPerPeriod(1)
end


-- An 80% share through the network --------------------------------------------------------------------

do
    local f32 = 0.800000011920929
    local clean, ok = RLFeed.sanitizeRation({ target = "FINISH", grain = "MAIZE", share = f32 })
    local stream = { values = {} }
    local reads = 0
    streamReadString = function() reads = reads + 1 return reads == 1 and "FINISH" or "MAIZE" end
    streamReadFloat32 = function() return 0.3499999940395355 end
    streamReadBool = function() return true end
    local raw, valid = RLFeed.readRationStream(stream)
    check("share: 80% read back as 0.8000000119 is 80%, valid; 35% sent as a 32-bit float reads as 0.35",
        ok and clean.share == RLFeed.MAX_SHARE and valid and raw.share == 0.35)
end


-- AUTO and short grain -----------------------------------------------------------------------------------

do
    local function heifers(n)
        local list = {}
        for i = 1, n do
            local a = (GrowthSim.makeAnimal("COW_ANGUS", { age = 12 }))
            RLGrowth.ensureState(a).feedAdapted = 1
            list[i] = a
        end
        return list
    end
    local ample = FeedSim.makePen(heifers(4), { DRYGRASS_WINDROW = 1e6, OAT = 1e6 })
    RLFeed.setRation(ample, { target = "GROW", grain = "OAT" })
    local animals = RLFeed.describePen(ample, RLFeed.getRation(ample), config.stepDays)
    local plan = RLFeed.planPen(ample, RLFeed.getRation(ample), animals, config.stepDays)
    local wanted = plan.withdraw.OAT or 0
    local short = FeedSim.makePen(heifers(4), { DRYGRASS_WINDROW = 1e6, OAT = wanted * 0.999 })
    RLFeed.setRation(short, { target = "GROW", grain = "OAT" })
    local shortAnimals = RLFeed.describePen(short, RLFeed.getRation(short), config.stepDays)
    local shortPlan = RLFeed.planPen(short, RLFeed.getRation(short), shortAnimals, config.stepDays)
    check(string.format("AUTO: with 99.9%% of the grain AUTO wants (%.3f L), the plan takes nearly all of it (%.3f L)", wanted,
        shortPlan.withdraw.OAT or 0), wanted > 0 and plan.animals[1].concLimit == "PROTEIN_OR_DEMAND"
        and (shortPlan.withdraw.OAT or 0) >= 0.99 * wanted * 0.999)
end


-- Wheat and grain grist share one cap -------------------------------------------------------------------

do
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 12 })
    local pen = FeedSim.makePen({ bull }, { DRYGRASS_WINDROW = 1e6, WHEAT = 1e6, GRAINGRIST = 1e6 })
    RLGrowth.ensureState(bull).feedAdapted = 1
    RLFeed.setRation(pen, { target = "FINISH", grain = "AUTO", share = 0.6 })
    FeedSim.untilStep(pen)
    local r = bull.rlFeedIntake
    local capped = ((r.byFill.WHEAT or {}).kg or 0) + ((r.byFill.GRAINGRIST or {}).kg or 0)
    check(string.format("cap: wheat and grist together %.1f%% of the DM (at most 30%%)", capped / r.kg * 100),
        capped <= 0.30 * r.kg + 1e-9 and capped >= 0.30 * r.kg - 1e-6)
end


-- Limits count animals, not steps ---------------------------------------------------------------------

do
    local list = {}
    for i = 1, 3 do list[i] = (GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })) end
    local pen = FeedSim.makePen(list, { DRYGRASS_WINDROW = 1e6 })
    FeedSim.untilStep(pen)
    local last = pen.spec_husbandryFood.rlFeedLast
    local n = 0
    for _, count in pairs(last.limits) do n = n + count end
    check(string.format("limits: an hour of %d steps counts each of 3 animals once (%d)", last.steps, n), last.steps > 1 and n == 3)
end


-- An animal moved between pens --------------------------------------------------------------------------

do
    GrowthSim.setDaysPerPeriod(28)
    local bull = GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })
    local a = FeedSim.makePen({ bull }, { FORAGE = 1e5 })
    local b = FeedSim.makePen({}, { FORAGE = 1e5 })
    FeedSim.untilStep(a) -- stepped in A this hour
    local steppedAt = bull.rlFeedStepTick
    -- B's clock is about to step; the bull moves to B.
    b.spec_husbandryFood.rlFeedClock = { pendingDays = config.stepDays - 1e-6 }
    a.animals = {}
    b.animals = { bull }
    bull.clusterSystem = { owner = b }
    local steps = {}
    local function observe(kind, data) if kind == "STEP" then for _, e in ipairs(data.animals) do steps[#steps + 1] = RLBodyCondition.getTickId() end end end
    RLFeed.addObserver(observe)
    FeedSim.hour(b)
    local early = #steps
    for _ = 1, 8 do FeedSim.hour(b) end
    RLFeed.removeObserver(observe)
    check(string.format("move: a bull stepped in pen A is not stepped again by pen B an hour later (28-day month), only once due (%d later)", #steps),
        early == 0 and #steps >= 1)
    GrowthSim.setDaysPerPeriod(1)
end


-- The ration change reaches an open menu ------------------------------------------------------------------

do
    local published = {}
    local saved = g_messageCenter
    g_messageCenter = { publish = function(_, kind, placeable) published[#published + 1] = { kind = kind, placeable = placeable } end }
    MessageType = MessageType or {}
    local hadType = MessageType.RL_FEED_RATION_CHANGED
    MessageType.RL_FEED_RATION_CHANGED = hadType or "RL_FEED_RATION_CHANGED"
    local pen = FeedSim.makePen({}, {})
    RLFeed.setRation(pen, { target = "GROW" })
    g_messageCenter = saved
    check("message: setting a pen's ration publishes RL_FEED_RATION_CHANGED with the pen",
        #published == 1 and published[1].placeable == pen and published[1].kind == MessageType.RL_FEED_RATION_CHANGED)
    MessageType.RL_FEED_RATION_CHANGED = hadType
end
