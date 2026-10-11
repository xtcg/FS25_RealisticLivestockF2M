--[[
    RLFeedInfoService.lua
    What the real-equivalent nutrition mode (RLFeed) shows, in one place: a cattle pen's state and
    ration, one row per feed (stock, what the last hour's ration held of it, the month's liters,
    planned liters a month and the months its stock lasts), the feed that runs out first, and an
    animal's real intake, concentrate share, what limits it and its finishing forecast. The pen
    info box, the animal rows, the RL menu's food rows (getFoodInfos) and the forecast read it; on
    a client it reads what the server last sent (RLBodyConditionStateEvent). Read-only.
]]

RLFeedInfoService = {}

--- Months a forecast never goes past (shown as "12+").
RLFeedInfoService.MAX_MONTHS = 12
--- Below this live weight trend (kg a month) a finishing animal counts as stalled.
RLFeedInfoService.STALL_KG_PER_MONTH = 1
--- Longest finishing forecast given as a number of months.
RLFeedInfoService.MAX_FINISH_MONTHS = 60


local function getText(key)
    return g_i18n ~= nil and g_i18n:getText(key) or key
end

-- Unknown values can arrive from a newer server or stale saved summary. Keep the displayed
-- explanation localised instead of exposing a constructed i18n key.
local function enumText(prefix, value, default)
    local key = prefix .. tostring(value or default)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and not g_i18n:hasText(key) then
        key = prefix .. "UNKNOWN"
    end
    return getText(key)
end


--- A cattle pen with a trough.
function RLFeedInfoService.isCattlePen(placeable)
    return placeable ~= nil and placeable.spec_husbandryFood ~= nil and placeable.getAnimalTypeIndex ~= nil and AnimalType ~= nil
        and placeable:getAnimalTypeIndex() == AnimalType.COW
end


--- The mode's state for a pen (the last feeding's, or the server's on a client): { active, reason, ration }.
function RLFeedInfoService.getPenState(placeable)
    local spec = placeable.spec_husbandryFood
    local state = spec.rlFeedPen
    if state == nil then
        local active, reason = RLFeed.evaluatePen(placeable)
        state = { active = active, reason = reason }
    end
    return { active = state.active == true, reason = state.reason or "MODE_OFF", ration = RLFeed.getRation(placeable) }
end


local function fillTitle(index, name)
    local fillType = g_fillTypeManager.getFillTypeByIndex ~= nil and g_fillTypeManager:getFillTypeByIndex(index) or nil
    return fillType ~= nil and fillType.title or name
end


--- Rows are rebuilt when the hour or the trough's stock changes, not on every info refresh.
local function getRowsCacheKey(placeable)
    local total = placeable.getTotalFood ~= nil and placeable:getTotalFood() or 0
    return tostring(RLBodyCondition.getTickId()) .. ":" .. string.format("%.3f", total) .. ":" .. tostring(RLFeed.mode)
end


--- One row per feed of a pen running the mode, in the order the ration takes them (complete
--- rations and forages in the map's order, then concentrates, then milk in a rearing pen): every
--- usable feed the trough takes with stock, eaten this month or in the plan, the grains always,
--- and any unconfigured feed with stock (never eaten).
--- @param placeable table
--- @return table rows { name, index, title, stock (the trough's), available (with a meadow's),
---         capacity, status ("EATEN", "STOCKED", "EMPTY", "UNCONFIGURED"), dmShare (of the last
---         hour's DM), monthLiters, monthHours, previousLiters (last complete month),
---         plannedPerMonth, monthsLeft }
function RLFeedInfoService.getFeedRows(placeable)
    local spec = placeable.spec_husbandryFood
    local ration = RLFeed.getRation(placeable)
    local key = getRowsCacheKey(placeable)
    local cache = spec.rlFeedRowsCache
    if cache ~= nil and cache.key == key and cache.ration == ration and cache.last == spec.rlFeedLast
        and cache.client == spec.rlFeedClient then return cache.rows, ration end
    local rows = RLFeedInfoService.buildFeedRows(placeable, ration)
    spec.rlFeedRowsCache = { key = key, ration = ration, last = spec.rlFeedLast, client = spec.rlFeedClient, rows = rows }
    return rows, ration
end


--- The rows themselves (getFeedRows caches them).
function RLFeedInfoService.buildFeedRows(placeable, ration)
    local spec = placeable.spec_husbandryFood
    local last, month, previous = spec.rlFeedLast, spec.rlFeedMonth, spec.rlFeedPrevious
    local client = spec.rlFeedClient
    local byFill = month ~= nil and month.byFill or (client ~= nil and client.byFill) or {}
    local planned = (last ~= nil and last.plannedPerMonth) or (client ~= nil and client.plannedPerMonth) or {}
    local hourKg = 0
    if last ~= nil then for _, fill in pairs(last.byFill) do hourKg = hourKg + fill.kg end end
    local rearing = RLCalfRearing ~= nil and RLCalfRearing.appliesToPen(placeable)

    local rows, seen = {}, {}
    local function add(name, index, alwaysShow)
        if name == nil or index == nil or seen[name] or not spec.supportedFillTypes[index] then return end
        seen[name] = true
        local profile = RLFeedProfiles.getFeed(name)
        local usable = profile ~= nil and profile.valid
        -- The trough's own stock is shown (a meadow shows its grass in its own row); what lasts
        -- counts the meadow too.
        local stock = math.max(spec.fillLevels[index] or 0, 0)
        local available = math.max(placeable:getAvailableFood(index) or 0, 0)
        local eaten = byFill[name] ~= nil and byFill[name].liters or 0
        local plan = planned[name] or 0
        if usable and profile.role == "MILK" and not rearing and stock <= 0 then return end
        if not alwaysShow and available <= 0 and eaten <= 0 and plan <= 0 then return end
        if not usable and available <= 0 then return end
        local hour = last ~= nil and last.byFill[name] or nil
        local status = not usable and "UNCONFIGURED" or ((hour ~= nil and hour.kg > 0) and "EATEN" or (available > 0 and "STOCKED" or "EMPTY"))
        table.insert(rows, {
            name = name, index = index, title = fillTitle(index, name), stock = stock, capacity = spec.capacity or 0, status = status,
            dmShare = (hour ~= nil and hourKg > 0) and hour.kg / hourKg or nil, monthLiters = eaten,
            monthHours = month ~= nil and month.hours or (client ~= nil and client.hours) or 0,
            previousLiters = (previous ~= nil and previous.complete and previous.byFill[name] ~= nil) and previous.byFill[name].liters or nil,
            plannedPerMonth = plan, monthsLeft = plan > 0 and available / plan or nil, available = available,
        })
    end

    local foodSystem = g_currentMission.animalFoodSystem
    local animalFood = foodSystem ~= nil and foodSystem:getAnimalFood(spec.animalTypeIndex) or nil
    for _, group in ipairs(animalFood ~= nil and animalFood.groups or {}) do
        if not group.rlGrain then
            for _, index in ipairs(group.fillTypes or {}) do
                local name = g_fillTypeManager:getFillTypeNameByIndex(index)
                local profile = RLFeedProfiles.getFeed(name)
                if profile == nil or profile.role ~= "CONCENTRATE" then add(name, index, false) end
            end
        end
    end
    for _, name in ipairs(RLFeed.getConcentrateOrder({ grain = "AUTO" })) do
        local grain = false
        for _, g in ipairs(RLFeed.GRAINS) do if g == name then grain = true end end
        add(name, g_fillTypeManager:getFillTypeIndexByName(name), grain and (name == "WHEAT" or name == "MAIZE"))
    end
    return rows
end


--- The feed in the plan that runs out first: { name, title, monthsLeft } (nil when none is planned).
function RLFeedInfoService.getFirstOut(rows)
    local first
    for _, row in ipairs(rows) do
        if row.monthsLeft ~= nil and (first == nil or row.monthsLeft < first.monthsLeft) then first = row end
    end
    return first
end


--- Months a pen running the mode is fed for at its plan (the first feed to run out), capped.
function RLFeedInfoService.getMonthsLeft(placeable)
    local rows = RLFeedInfoService.getFeedRows(placeable)
    local first = RLFeedInfoService.getFirstOut(rows)
    if first == nil then return nil end
    return math.min(first.monthsLeft, RLFeedInfoService.MAX_MONTHS), first
end


-- =============================================================================
-- Ration preview
-- =============================================================================

--- The limit most of a pen's animals had (ties: the first in `order`), nil when none had one.
local function mostCommon(counts, order)
    local best, bestCount = nil, 0
    for _, key in ipairs(order) do
        if (counts[key] or 0) > bestCount then best, bestCount = key, counts[key] end
    end
    return best
end


--- A plan's concentrate share of the DM of the animals that may eat concentrate (planned, before a
--- shortage), the limit most of them had, and how many there were.
local function planShare(plan)
    local forage, conc, counts, order, n = 0, 0, {}, {}, 0
    for _, a in ipairs(plan.animals) do
        if a.concEligible then
            n = n + 1
            forage, conc = forage + (a.forageKg or 0), conc + (a.concKg or 0)
            local limit = a.concLimit or "NONE"
            if counts[limit] == nil then order[#order + 1] = limit end
            counts[limit] = (counts[limit] or 0) + 1
        end
    end
    if n == 0 then return nil, nil, 0 end
    local total = forage + conc
    return total > 0 and conc / total or 0, mostCommon(counts, order), n
end


--- What a pen's animals would eat on a ration (the ration dialog's draft): one step's plan on the
--- pen's animals and stock as they are now. Nothing is taken from the trough and no animal, rumen
--- or reserve changes. Planned twice: with each rumen as adapted as it is now, and fully adapted
--- (the share the ration settles at once the animals are used to it).
--- @param placeable table
--- @param ration table A ration's settings (sanitised here)
--- @return table|nil preview { animals, eligible (animals that may eat concentrate), targetShare
---         (nil: AUTO), share, limit (now), adaptedShare, adaptedLimit (fully adapted; nil without
---         an eligible animal), kgPerHeadDay, coverage (eaten / planned ME this step), rows = { { name,
---         title, perMonth (planned liters a month), dmShare (of the planned DM), available,
---         monthsLeft } } (most liters first), firstOut }
--- @return string|nil error
function RLFeedInfoService.previewRation(placeable, ration)
    ration = RLFeed.sanitizeRation(ration)
    if not RLFeedProfiles.isValid() then return nil, "CONFIG_INVALID" end
    local config = RLFeed.getConfig()
    local stepDays = config.stepDays
    local animals = RLFeed.describePen(placeable, ration, stepDays)
    local plan = RLFeed.planPen(placeable, ration, animals, stepDays)

    local preview = { animals = #animals, targetShare = ration.share, rows = {} }
    preview.share, preview.limit, preview.eligible = planShare(plan)
    preview.coverage = plan.plannedMe > 0 and plan.eatenMe / plan.plannedMe or nil
    preview.kgPerHeadDay = #animals > 0 and plan.plannedKg / (#animals * stepDays) or 0

    local perMonth, scale = {}, config.resourceScale
    for _, a in ipairs(plan.animals) do
        for name, liters in pairs(a.plannedByFill or {}) do perMonth[name] = (perMonth[name] or 0) + liters end
    end
    local totalKg, kgByFill = 0, {}
    for name, liters in pairs(perMonth) do
        local profile = RLFeedProfiles.getUsableFeed(name)
        local kg = profile ~= nil and RLFeedUnits.litersToKg(liters, scale, profile.density, profile.dm) or 0
        kgByFill[name], totalKg = kg, totalKg + kg
    end
    for name, liters in pairs(perMonth) do
        if liters > 0 then
            local index = g_fillTypeManager:getFillTypeIndexByName(name)
            local available = index ~= nil and math.max(placeable:getAvailableFood(index) or 0, 0) or 0
            table.insert(preview.rows, { name = name, title = index ~= nil and fillTitle(index, name) or name, perMonth = liters,
                dmShare = totalKg > 0 and kgByFill[name] / totalKg or 0, available = available, monthsLeft = available / liters })
        end
    end
    table.sort(preview.rows, function(a, b)
        if a.perMonth ~= b.perMonth then return a.perMonth > b.perMonth end
        return a.name < b.name
    end)
    preview.firstOut = RLFeedInfoService.getFirstOut(preview.rows)
    -- Calves on milk the plan cannot give half their milk (no or too little milk in the trough).
    preview.calvesWithoutMilk = 0
    for _, a in ipairs(plan.animals) do
        if RLFeed.isMilkShort(a.milkPlanKg, a.milkKg) then preview.calvesWithoutMilk = preview.calvesWithoutMilk + 1 end
    end

    -- The same animals once their rumens are used to the ration (the plan above set no state).
    for _, a in ipairs(animals) do a.adapted = 1 end
    local adapted = RLFeed.planPen(placeable, ration, animals, stepDays)
    preview.adaptedShare, preview.adaptedLimit = planShare(adapted)
    return preview
end


-- =============================================================================
-- Texts
-- =============================================================================

function RLFeedInfoService.getReasonText(reason)
    return enumText("rl_feed_reason_", reason, "MODE_OFF")
end


function RLFeedInfoService.getTargetText(target)
    return enumText("rl_feed_target_", target, "AUTO")
end


function RLFeedInfoService.getLimitText(limit)
    return enumText("rl_feed_limit_", limit, "NONE")
end


function RLFeedInfoService.getGrainText(ration)
    local grain = ration.grain or "AUTO"
    if grain == "AUTO" then return getText("rl_feed_grain_AUTO") end
    if grain == "NONE" then return getText("rl_feed_grain_NONE") end
    local index = g_fillTypeManager:getFillTypeIndexByName(grain)
    return index ~= nil and fillTitle(index, grain) or grain
end


local function formatMonths(months)
    if months >= RLFeedInfoService.MAX_MONTHS then return string.format("%d+ %s", RLFeedInfoService.MAX_MONTHS, getText("rl_feed_monthsShort")) end
    return string.format("%.1f %s", months, getText("rl_feed_monthsShort"))
end
RLFeedInfoService.formatMonths = formatMonths


-- =============================================================================
-- Animal
-- =============================================================================

--- An animal's last hour in the mode, per real day (server: its record; client: what was sent);
--- nil when it has none.
--- @return table|nil { kgPerDay, plannedKgPerDay, mePerDay, plannedMePerDay, coverage, concShare,
---         concLimit, intakeLimit, proteinFactor, target, class, healthReason, gainPerMonth }
function RLFeedInfoService.getAnimalInfo(animal)
    -- Only while its pen runs the mode, and only a record of this hour or the last: an animal
    -- whose pen went back to the old rules (or the setting) shows no frozen feed rows.
    local owner = animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil
    local spec = owner ~= nil and owner.spec_husbandryFood or nil
    local pen = spec ~= nil and spec.rlFeedPen or nil
    if pen == nil or not pen.active or RLFeed.mode ~= RLFeed.MODE_REAL then return nil end
    local tick = RLBodyCondition.getTickId()
    local function fresh(at) return RLFeed.isFresh(at, tick) end
    local record = animal.rlFeedIntake
    if record ~= nil and record.dtDays ~= nil and record.dtDays > 0 and record.owner == owner and fresh(record.tick) then
        local days = record.dtDays
        return { kgPerDay = record.kg / days, plannedKgPerDay = (record.plannedKg or 0) / days, mePerDay = record.me / days,
            plannedMePerDay = (record.plannedMe or 0) / days, coverage = (record.plannedMe or 0) > 0 and record.me / record.plannedMe or 0,
            concShare = record.concShare or 0, concLimit = record.concLimit, intakeLimit = record.intakeLimit,
            proteinFactor = record.proteinFactor or 0, target = record.target, class = record.class, healthReason = record.healthReason,
            gainPerMonth = record.gainPerMonth, milkShort = record.milkShort == true }
    end
    local remote = animal.rlFeedClient
    if remote ~= nil and fresh(remote.tick) then
        local info = {}
        for key, value in pairs(remote) do info[key] = value end
        info.coverage = (remote.plannedMePerDay or 0) > 0 and remote.mePerDay / remote.plannedMePerDay or 0
        return info
    end
    return nil
end


--- What holds an animal's ration: a calf short of its milk first, then the concentrate limit when
--- it wanted more, the protein when it holds growth or milk, else what held its intake.
function RLFeedInfoService.getMainLimit(info)
    if info == nil then return nil end
    if info.milkShort then return "NO_CALF_MILK" end
    if info.proteinFactor ~= nil and info.proteinFactor < 0.95 then return "PROTEIN" end
    if info.concLimit ~= nil and info.concLimit ~= "PROTEIN_OR_DEMAND" then return info.concLimit end
    return info.intakeLimit
end


--- Finishing forecast of a bull or steer: months to its slaughter reference at its live weight
--- trend; READY at it; STALLED when it hardly gains (its ration does not carry it there: more
--- or better feed is needed). nil for a female or without a reference or a trend.
--- @return string|nil state "READY", "MONTHS", "STALLED"
--- @return number|nil months
function RLFeedInfoService.getFinishForecast(animal, info)
    if animal.gender ~= "male" or info == nil or info.gainPerMonth == nil then return nil end
    local reference = RLBodyCondition.getReferenceWeight(animal)
    if reference == nil then return nil end
    local left = reference * 0.95 - (animal.weight or 0)
    if left <= 0 then return "READY", 0 end
    if info.gainPerMonth < RLFeedInfoService.STALL_KG_PER_MONTH then return "STALLED", nil end
    local months = left / info.gainPerMonth
    if months > RLFeedInfoService.MAX_FINISH_MONTHS then return "STALLED", nil end
    return "MONTHS", months
end


-- =============================================================================
-- Info box and menu rows
-- =============================================================================

--- Rows for a cattle pen's info box while the mode is on (one short figure each).
--- @return table rows { titleKey, text }
function RLFeedInfoService.getPenInfoRows(placeable)
    if RLFeed.mode ~= RLFeed.MODE_REAL or not RLFeedInfoService.isCattlePen(placeable) then return {} end
    local state = RLFeedInfoService.getPenState(placeable)
    local rows = {}
    if not state.active then
        table.insert(rows, { titleKey = "rl_feed_penMode", text = RLFeedInfoService.getReasonText(state.reason) })
        return rows
    end
    table.insert(rows, { titleKey = "rl_feed_penMode", text = getText("rl_feed_modeReal") })
    table.insert(rows, { titleKey = "rl_feed_penRation", text = string.format("%s · %s", RLFeedInfoService.getTargetText(state.ration.target),
        RLFeedInfoService.getGrainText(state.ration)) })
    local spec = placeable.spec_husbandryFood
    local coverage = spec.rlFeedLast ~= nil and spec.rlFeedLast.coverage or (spec.rlFeedClient ~= nil and spec.rlFeedClient.coverage) or nil
    if coverage ~= nil then
        table.insert(rows, { titleKey = "rl_feed_penCoverage", text = string.format("%.0f %%", math.clamp(coverage, 0, 9.99) * 100) })
    end
    local calfMilk = RLFeedInfoService.getCalfMilkAlert(placeable)
    if calfMilk ~= nil and calfMilk.state ~= "OK" then
        table.insert(rows, { titleKey = "rl_feed_penCalfMilk", text = RLFeedInfoService.getCalfMilkText(calfMilk), warning = true })
    end
    local _, first = RLFeedInfoService.getMonthsLeft(placeable)
    if first ~= nil then
        table.insert(rows, { titleKey = "rl_feed_penFirstOut", text = string.format("%s %s", first.title, formatMonths(first.monthsLeft)) })
    end
    return rows
end


-- =============================================================================
-- Calves on milk without milk (a rearing pen)
-- =============================================================================

--- A rearing pen's calf milk alert of its last hour (server: its hour; client: what was sent), or nil.
--- @return table|nil { state "OK"|"LOW"|"NONE", calves, short, monthsLeft }
function RLFeedInfoService.getCalfMilkAlert(placeable)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    if spec == nil then return nil end
    if spec.rlFeedLast ~= nil then return spec.rlFeedLast.calfMilk end
    return spec.rlFeedClient ~= nil and spec.rlFeedClient.calfMilk or nil
end


--- The pen row's text: how many calves go without milk, or how long the milk lasts.
function RLFeedInfoService.getCalfMilkText(alert)
    if alert.state == "NONE" then return string.format(getText("rl_feed_calfMilkNone"), alert.short) end
    if alert.state == "LOW" then return string.format(getText("rl_feed_calfMilkLow"), formatMonths(alert.monthsLeft or 0)) end
    return ""
end


--- Tell the player once when a rearing pen's calves go without milk (critical) or its milk runs
--- low (info), only for the player's own farm. Again only after the pen was back to OK (a refill):
--- the state is kept per pen, so an hour that stays short does not repeat it.
--- @param placeable table
--- @param alert table getCalfMilkAlert
function RLFeedInfoService.notifyCalfMilk(placeable, alert)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    if spec == nil or alert == nil then return end
    if alert.state == "OK" then
        spec.rlCalfMilkNotified = "OK"
        return
    end
    -- Keep the highest severity notified until recovery, even if NONE briefly becomes LOW.
    local last = spec.rlCalfMilkNotified
    if alert.state == last or last == "NONE" then return end
    local mission = g_currentMission
    if mission == nil or mission.addIngameNotification == nil then return end
    if placeable.getOwnerFarmId ~= nil and mission.getFarmId ~= nil and placeable:getOwnerFarmId() ~= mission:getFarmId() then return end
    spec.rlCalfMilkNotified = alert.state
    local name = placeable.getName ~= nil and placeable:getName() or ""
    if alert.state == "NONE" then
        mission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, string.format(getText("rl_feed_calfMilkAlert"), name, alert.short))
    else
        mission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(getText("rl_feed_calfMilkLowAlert"), name, formatMonths(alert.monthsLeft or 0)))
    end
end


--- Rows for an animal's info (RLBodyCondition.addInfos), in the mode: real intake against plan,
--- concentrate share and what limits the ration, and for a bull or steer the finishing forecast.
--- @return table rows { key, titleKey, valueText, ratio }
function RLFeedInfoService.getAnimalRows(animal)
    local info = RLFeedInfoService.getAnimalInfo(animal)
    if info == nil then return {} end
    local rows = {}
    table.insert(rows, { key = "feedIntake", titleKey = "rl_feed_intake", ratio = math.clamp(info.coverage or 0, 0, 1),
        valueText = string.format(getText("rl_feed_intakeFormat"), info.kgPerDay, math.clamp(info.coverage or 0, 0, 9.99) * 100) })
    table.insert(rows, { key = "feedLimit", titleKey = "rl_feed_ration", ratio = math.clamp(info.concShare or 0, 0, 1),
        valueText = string.format("%.0f %% · %s", (info.concShare or 0) * 100, RLFeedInfoService.getLimitText(RLFeedInfoService.getMainLimit(info))) })
    local state, months = RLFeedInfoService.getFinishForecast(animal, info)
    if state ~= nil then
        local text = state == "READY" and getText("rl_feed_finishReady") or (state == "STALLED" and getText("rl_feed_finishStalled")
            or string.format("~%.1f %s", months, getText("rl_feed_monthsShort")))
        table.insert(rows, { key = "feedFinish", titleKey = "rl_feed_finish", ratio = state == "READY" and 1 or 0, valueText = text })
    end
    return rows
end


--- The pen's food rows (getFoodInfos) for a cattle pen. In the mode: one row per feed
--- (getFeedRows), its stock against the trough, the title with the last hour's DM share, the value
--- text with its planned liters a month (the RL menu shows it, the base menu the stock). Under the
--- old rules the grain group's row says it is not eaten, and is left out while it holds nothing.
--- @param placeable table
--- @param infos table The engine's rows (its food groups' rows last, in group order)
--- @return table infos
function RLFeedInfoService.adjustFoodInfos(placeable, infos)
    if not RLFeedInfoService.isCattlePen(placeable) then return infos end
    local state = RLFeedInfoService.getPenState(placeable)
    if state.active then
        local rows = RLFeedInfoService.getFeedRows(placeable)
        local out = {}
        for _, row in ipairs(rows) do
            local title = row.title
            if row.status == "UNCONFIGURED" then
                title = string.format("%s (%s)", title, getText("rl_feed_unconfigured"))
            elseif row.dmShare ~= nil then
                title = string.format(getText("rl_feed_feedShareFormat"), title, row.dmShare * 100)
            end
            local valueText = g_i18n ~= nil and g_i18n.formatVolume ~= nil and g_i18n:formatVolume(row.stock, 0) or string.format("%.0f l", row.stock)
            if row.plannedPerMonth > 0 then
                valueText = string.format(getText("rl_feed_feedPlanFormat"), valueText, row.plannedPerMonth, getText("rl_feed_monthsShort"))
            end
            table.insert(out, { title = title, value = row.stock, capacity = row.capacity, ratio = row.capacity > 0 and row.stock / row.capacity or 0,
                valueText = valueText, disabled = row.status == "UNCONFIGURED" or row.status == "EMPTY", rlFeedRow = row })
        end
        return out
    end

    -- The old rules: the grain group's row (registered by RLFeed, never eaten here).
    local foodSystem = g_currentMission.animalFoodSystem
    local animalFood = foodSystem ~= nil and foodSystem:getAnimalFood(placeable.spec_husbandryFood.animalTypeIndex) or nil
    local groups = animalFood ~= nil and animalFood.groups or {}
    local offset = #infos - #groups
    if offset < 0 then return infos end
    for i = #groups, 1, -1 do
        local group = groups[i]
        local info = infos[offset + i]
        if group.rlGrain and info ~= nil then
            if (info.value or 0) <= 0 then
                table.remove(infos, offset + i)
            else
                info.title = string.format("%s (%s)", group.title, getText("rl_feed_grainNotEaten"))
                -- Not in the pen's food total: it feeds nobody.
                info.disabled, info.ignoreCapacity = true, true
            end
        end
    end
    return infos
end
