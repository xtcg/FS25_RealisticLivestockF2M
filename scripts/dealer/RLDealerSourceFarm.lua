-- Server-owned source physiology. Withdrawn listings do not own or delete these
-- animals. Calendar segments are supplied by the authoritative update adapter.
-- No live hook is installed here, and calving requires a real offspring service.
RLDealerSourceFarm = { VERSION = 1 }
local F = RLDealerSourceFarm
local copy=RLPlain.copy
local finite=RLPlain.finite
local function id(v) return type(v) == "string" and #v > 0 and #v <= 256 end
function F.new(namespace, months)
    if not id(namespace) then return nil, "SOURCE_NAMESPACE" end
    local clock, reason = RLDealerClock.new(months)
    if not clock then return nil, reason end
    return { version = F.VERSION, namespace = namespace, clock = clock, sources = {} }
end
function F.get(farm, sourceId)
    return farm.sources[sourceId] ~= nil and copy(farm.sources[sourceId]) or nil
end
function F.add(farm, sourceId, record)
    if not id(sourceId) or farm.sources[sourceId] ~= nil then return nil, "SOURCE_ID" end
    local ok, reason = RLDealerSourceState.validate(record)
    if not ok then return nil, reason end
    if record.cursorMonths ~= farm.clock.months then return nil, "SOURCE_CLOCK" end
    farm.sources[sourceId] = copy(record)
    return F.get(farm, sourceId)
end
function F.export(farm) return copy(farm) end
function F.restore(data)
    if type(data) ~= "table" or RLTradePersistence.check(data) or data.version ~= F.VERSION
        or not id(data.namespace) or type(data.sources) ~= "table" then return nil, "SOURCE_FARM" end
    local clock, reason = RLDealerClock.restore(data.clock)
    if not clock then return nil, reason end
    for sourceId, record in pairs(data.sources) do
        local ok, why = RLDealerSourceState.validate(record)
        if not id(sourceId) or not ok then return nil, why or "SOURCE_ID" end
        if record.cursorMonths ~= clock.months then return nil, "SOURCE_CLOCK" end
    end
    return copy(data)
end
-- Whole update is staged: bad calendar, missing models, health rejection or a
-- due source birth leaves every source and the cursor unchanged for recovery.
function F.advanceSegments(farm, segments, resolveSubType, resolveEntry)
    if type(resolveSubType) ~= "function" or type(resolveEntry) ~= "function" then return nil, "SOURCE_RULES" end
    local staged, reason = F.restore(farm)
    if not staged then return nil, reason end
    local checkClock = RLDealerClock.export(staged.clock)
    local finish; finish, reason = RLDealerClock.advanceSegments(checkClock, segments)
    if not finish then return nil, reason end
    for _, segment in ipairs(segments) do
        if not finite(segment.daysPerMonth) or segment.daysPerMonth < 1 or segment.daysPerMonth > 31
            or segment.daysPerMonth % 1 ~= 0 then return nil, "MONTH_LENGTH" end
        local delta = segment.hours / (24 * segment.daysPerMonth)
        local nextCursor = staged.clock.months + delta
        local keys = {}; for sourceId in pairs(staged.sources) do keys[#keys + 1] = sourceId end; table.sort(keys)
        for _, sourceId in ipairs(keys) do
            local record = staged.sources[sourceId]
            local replay, failure = RLDealerSourceState.restore(record, resolveSubType)
            if not replay then return nil, failure.reason, sourceId end
            local ok, entry = pcall(resolveEntry, record.animal.subType, sourceId)
            if not ok then return nil, "SOURCE_RULES", sourceId end
            local progressed
            progressed, failure = RLDealerReplay.resume(replay, record.ageMonths + delta,
                { daysPerMonth = segment.daysPerMonth, entry = entry })
            if not progressed then return nil, failure.reason, sourceId end
            local moved
            moved, failure = RLDealerSourceState.advanceCursor(record, progressed, nextCursor)
            if not moved then return nil, failure.reason, sourceId end
            staged.sources[sourceId] = moved
        end
        staged.clock.months = nextCursor
    end
    -- The shared clock is published only with all physiological ledgers.
    farm.clock, farm.sources = staged.clock, staged.sources
    return farm.clock.months
end
