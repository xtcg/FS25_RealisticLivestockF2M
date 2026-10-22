-- FEED-08: the ration dialog's model (RLFeedRationModel) and its preview
-- (RLFeedInfoService.previewRation). The preview is the plan the pen's next step runs, takes
-- nothing and changes no animal; the share target is a target (adaptation and the ration rules
-- still hold it); the draft is the dialog's own until applied; a client's pen changes only when
-- the server sends back what it applied; read-only with the reason when the pen cannot be edited.

loadMod("tests/feedsim.lua")
loadMod("scripts/events/RLFeedRationEvent.lua")
loadMod("scripts/gui/rlmenu/services/RLFeedRationModel.lua")

local Info = RLFeedInfoService
local Model = RLFeedRationModel

local function within(a, b, tolerance) return a ~= nil and b ~= nil and math.abs(a - b) <= tolerance end
local function relative(a, b) return math.abs(a - b) / math.max(math.abs(b), 1e-12) end

FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(7)

local function bulls(n)
    local list = {}
    for _ = 1, n do table.insert(list, (GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 }))) end
    return list
end

--- Everything the preview must leave as it was: the trough, each animal's weight, health, growth
--- state, adaptation and records, the pen's clock, ration and month.
local function snapshot(pen)
    local spec = pen.spec_husbandryFood
    local s = { levels = {}, animals = {}, ration = spec.rlFeedRation, last = spec.rlFeedLast, month = spec.rlFeedMonth,
        pending = spec.rlFeedClock ~= nil and spec.rlFeedClock.pendingDays or nil, monthHours = spec.rlFeedMonth ~= nil and spec.rlFeedMonth.hours or nil }
    for index, liters in pairs(spec.fillLevels) do s.levels[index] = liters end
    for _, animal in ipairs(pen.animals) do
        local state = animal.rlGrowth
        table.insert(s.animals, { animal = animal, weight = animal.weight, health = animal.health, state = state,
            adapted = state ~= nil and state.feedAdapted or nil, reserve = state ~= nil and state.reserveMassKg or nil,
            development = state ~= nil and state.developmentMonths or nil, intake = animal.rlFeedIntake, nutrition = animal.rlNutrition,
            carry = animal.rlHealthCarry, short = state ~= nil and state.feedShortDays or nil })
    end
    return s
end

local function unchanged(a, b)
    for index, liters in pairs(a.levels) do if b.levels[index] ~= liters then return false end end
    for i, x in ipairs(a.animals) do
        local y = b.animals[i]
        for key, value in pairs(x) do if y[key] ~= value then return false end end
    end
    return a.ration == b.ration and a.last == b.last and a.month == b.month and a.pending == b.pending and a.monthHours == b.monthHours
end


-- The preview is side-effect free and is the plan the next step runs -------------------------

do
    local pen = FeedSim.makePen(bulls(2), { DRYGRASS_WINDROW = 1e5, MAIZE = 1e4 })
    RLFeed.setRation(pen, { target = "FINISH", grain = "MAIZE", share = 0.3 })
    FeedSim.untilStep(pen) -- the animals have state, records and a month
    local before = snapshot(pen)
    local preview = Info.previewRation(pen, RLFeed.getRation(pen))
    Info.previewRation(pen, { target = "GROW", grain = "NONE" })
    check("preview: nothing is taken from the trough and no animal, rumen, reserve, record or pen month changes",
        preview ~= nil and unchanged(before, snapshot(pen)))

    -- The next step (one model step at 7 days a month) plans on the same animals and stock.
    local steps = {}
    local function observe(kind, data) if kind == "STEP" then steps[#steps + 1] = data end end
    RLFeed.addObserver(observe)
    FeedSim.untilStep(pen)
    RLFeed.removeObserver(observe)
    local last = pen.spec_husbandryFood.rlFeedLast
    local ok = #steps == 1 and last.steps == 1
    for _, row in ipairs(preview.rows) do ok = ok and relative(row.perMonth, last.plannedPerMonth[row.name] or 0) < 1e-9 end
    local n = 0
    for _ in pairs(last.plannedPerMonth) do n = n + 1 end
    check("preview: its liters a month per feed are those the next step plans (1e-9)", ok and n == #preview.rows)
    local record = pen.animals[1].rlFeedIntake
    check(string.format("preview: its concentrate share now (%.4f) is the share the next step's animals eat (%.4f)",
        preview.share, record.concShare), within(preview.share, record.concShare, 1e-9) and preview.eligible == 2)

    local dm = 0
    local sorted = true
    for i, row in ipairs(preview.rows) do
        dm = dm + row.dmShare
        sorted = sorted and (i == 1 or preview.rows[i - 1].perMonth >= row.perMonth)
        sorted = sorted and within(row.monthsLeft, row.available / row.perMonth, 1e-12)
    end
    check("preview: rows by liters a month, DM shares add to 1, months left = stock / planned liters a month",
        sorted and within(dm, 1, 1e-9) and preview.firstOut ~= nil)
end


-- Target, now, adapted -------------------------------------------------------------------------

do
    local pen = FeedSim.makePen(bulls(3), { DRYGRASS_WINDROW = 1e5, MAIZE = 1e4 })
    local preview = Info.previewRation(pen, { target = "FINISH", grain = "MAIZE", share = 0.4 })
    check(string.format("preview: new bulls on a 40%% target eat %.0f%% now (adapting) and %.0f%% once adapted (%s)",
        preview.share * 100, preview.adaptedShare * 100, tostring(preview.adaptedLimit)),
        preview.targetShare == 0.4 and preview.limit == "ADAPTATION" and preview.share < 0.4 and preview.adaptedShare > preview.share
        and preview.adaptedShare <= 0.4 + 1e-9 and preview.adaptedLimit ~= "ADAPTATION")
    local free = Info.previewRation(pen, { target = "FINISH", grain = "MAIZE" })
    check(string.format("preview: AUTO settles at the share the ration rules allow (%.0f%%, %s), never above 80%%",
        free.adaptedShare * 100, tostring(free.adaptedLimit)), free.targetShare == nil and free.adaptedShare > 0 and free.adaptedShare <= 0.8)
    local none = Info.previewRation(pen, { target = "FINISH", grain = "NONE" })
    local maize = false
    for _, row in ipairs(none.rows) do maize = maize or row.name == "MAIZE" end
    check("preview: no grain plans no grain", none.share == 0 and not maize)
    local empty = FeedSim.makePen({}, { DRYGRASS_WINDROW = 100 })
    local nobody = Info.previewRation(empty, RLFeed.DEFAULT_RATION)
    check("preview: an empty pen previews no animals and no rows", nobody.animals == 0 and #nobody.rows == 0 and nobody.share == nil)
end


-- The model: options, draft, apply ---------------------------------------------------------------

do
    local pen = FeedSim.makePen(bulls(1), { DRYGRASS_WINDROW = 1e5, MAIZE = 1e4 })
    RLFeed.setRation(pen, { target = "FINISH", grain = "MAIZE", share = 0.33, substitute = false })
    local model = Model.new(pen)
    local hasWheat = false
    for _, grain in ipairs(model.grains) do hasWheat = hasWheat or grain == "WHEAT" end
    check("model: targets, AUTO/NONE and each grain the trough takes, shares AUTO + 0..80% in 5s with the pen's own 33% kept",
        #model.targets == 4 and model.grains[1] == "AUTO" and model.grains[2] == "NONE" and hasWheat and #model.shares == 1 + 17 + 1
        and model.shares[1] == false and within(model.shares[model:getShareIndex()], 0.33, 1e-9)
        and model.shares[model:getShareIndex() + 1] == 0.35 and model:getSubstituteIndex() == 2)

    model:setTargetIndex(3)
    model:setShareIndex(1)
    model:setGrainIndex(1)
    check("model: editing the draft leaves the pen's ration alone", RLFeed.getRation(pen).target == "FINISH"
        and RLFeed.getRation(pen).share == 0.33 and model.draft.target == model.targets[3] and model.draft.share == nil
        and model.draft.grain == "AUTO" and model:isChanged())

    local sent = {}
    local savedSend = RLFeedRationEvent.sendEvent
    RLFeedRationEvent.sendEvent = function(object, ration) sent[#sent + 1] = { object = object, ration = ration } end
    local unchangedModel = Model.new(pen)
    check("model: apply without a change sends nothing", unchangedModel:apply() == false and #sent == 0)
    check("model: apply sends a copy of the draft for the pen", model:apply() == true and #sent == 1 and sent[1].object == pen
        and sent[1].ration ~= model.draft and sent[1].ration.target == model.draft.target and sent[1].ration.share == nil)

    -- Read-only: the mode off, a pen on the old rules, no permission. Nothing is sent.
    FeedSim.setMode(false)
    local editable, reason = Model.new(pen):getAccess()
    check("model: read-only while the mode is off", not editable and reason == "MODE_OFF" and model:apply() == false and #sent == 1)
    FeedSim.setMode(true)
    -- An animal the weight model does not cover (a vanilla cluster) keeps its pen on the old rules.
    local calf = GrowthSim.makeAnimal("BULL_ANGUS", { age = 1 })
    calf.isIndividual = false
    local nursery = FeedSim.makePen({ calf }, { DRYGRASS_WINDROW = 1000 })
    nursery.spec_husbandryFood.rlFeedPen = nil
    editable, reason = Model.new(nursery):getAccess()
    check("model: read-only in a pen the old rules feed, with its reason", not editable and reason == "UNCOVERED_ANIMAL")
    RLPermissionHelper = { hasLocalPermission = function() return false end }
    editable, reason = Model.new(pen):getAccess()
    check("model: read-only without the tradeAnimals permission", not editable and reason == "NO_PERMISSION" and model:apply() == false and #sent == 1)
    RLPermissionHelper = nil
    RLFeedRationEvent.sendEvent = savedSend

    -- A client: Apply asks the server; the pen changes when the server's answer arrives.
    local toServer = {}
    g_server = nil
    g_client = { getServerConnection = function() return { sendEvent = function(_, event) toServer[#toServer + 1] = event end } end }
    local clientModel = Model.new(pen)
    clientModel:setTargetIndex(4)
    local applied = clientModel:apply()
    check("client: Apply sends the draft to the server and leaves the pen's ration as it was", applied and #toServer == 1
        and toServer[1].ration.target == clientModel.targets[4] and RLFeed.getRation(pen).target == "FINISH")
    RLFeedRationEvent.new(pen, toServer[1].ration):run({ getIsServer = function() return true end })
    check("client: the server's answer sets the pen's ration", RLFeed.getRation(pen).target == clientModel.targets[4])
    g_client = nil
end


-- The model's preview texts and cache -------------------------------------------------------------

do
    local pen = FeedSim.makePen(bulls(2), { DRYGRASS_WINDROW = 1e5, MAIZE = 1e4, BARLEY = 1e4 })
    local model = Model.new(pen)
    local first = model:getPreview()
    check("model: the preview is worked out once per draft and hour", model:getPreview() == first)
    model:setShareIndex(9)
    local second = model:getPreview()
    check("model: a new draft gets a new preview", second ~= first and second.targetShare == model.shares[9])
    local texts = model:getPreviewTexts()
    check("model: preview texts have the share line, the intake line and one row per feed",
        texts.share ~= nil and texts.intake ~= nil and #texts.rows == #second.rows and texts.more == 0 and texts.empty == nil)
    local savedPreview = Info.previewRation
    Info.previewRation = function() error("boom") end
    model:setShareIndex(10)
    local logged = #LOG
    local failed, err = model:getPreview()
    Info.previewRation = savedPreview
    while #LOG > logged do table.remove(LOG) end
    check("model: a preview that fails shows 'preview unavailable', never an error in the dialog",
        failed == nil and err == "ERROR" and model:getPreviewTexts().empty ~= nil)
end
