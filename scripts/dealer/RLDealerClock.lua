-- Detached authoritative dealer month clock. The adapter supplies each elapsed
-- segment's actual calendar length; reads never sample the game clock.
RLDealerClock = {}
local C = RLDealerClock
C.VERSION = 1
C.CHECKPOINT_MONTHS = 0.25
local finite=RLPlain.finite
function C.new(months)
    months = months or 0
    if not finite(months) or months < 0 then return nil, "INVALID_TIME" end
    return { version = C.VERSION, months = months, lastCheckpoint = math.floor(months / C.CHECKPOINT_MONTHS) }
end
function C.advanceSegments(clock, segments)
    if type(clock) ~= "table" or clock.version ~= C.VERSION or not finite(clock.months) or clock.months < 0 then return nil, "INVALID_CLOCK" end
    if type(segments) ~= "table" then return nil, "INVALID_SEGMENTS" end
    local count = 0
    for key in pairs(segments) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #segments then return nil, "INVALID_SEGMENTS" end
        count = count + 1
    end
    if count ~= #segments then return nil, "INVALID_SEGMENTS" end
    local delta = 0
    for _, segment in ipairs(segments) do
        if type(segment) ~= "table" or not finite(segment.hours) or segment.hours < 0
            or not finite(segment.daysPerMonth) or segment.daysPerMonth <= 0 then return nil, "INVALID_SEGMENT" end
        delta = delta + segment.hours / (24 * segment.daysPerMonth)
    end
    if not finite(delta) or not finite(clock.months + delta) then return nil, "INVALID_TIME" end
    clock.months = clock.months + delta
    return clock.months
end
function C.advanceHours(clock, hours, daysPerMonth)
    return C.advanceSegments(clock, { { hours = hours, daysPerMonth = daysPerMonth } })
end
-- At most one replenishment call, at the newest checkpoint. Missed batches are
-- intentionally not generated; the callback may fill only currently empty slots.
function C.checkpoint(clock)
    local index = math.floor((clock.months + 1e-10) / C.CHECKPOINT_MONTHS)
    if index <= clock.lastCheckpoint then return nil end
    local missed = index - clock.lastCheckpoint - 1
    clock.lastCheckpoint = index
    return index * C.CHECKPOINT_MONTHS, missed
end
function C.export(clock)
    return { version = C.VERSION, months = clock.months, lastCheckpoint = clock.lastCheckpoint }
end
function C.restore(data)
    if type(data) ~= "table" or data.version ~= C.VERSION or not finite(data.months) or data.months < 0
        or not finite(data.lastCheckpoint) or data.lastCheckpoint < 0 or data.lastCheckpoint % 1 ~= 0
        or data.lastCheckpoint > math.floor((data.months + 1e-10) / C.CHECKPOINT_MONTHS) then return nil, "INVALID_CLOCK" end
    return C.export(data)
end
