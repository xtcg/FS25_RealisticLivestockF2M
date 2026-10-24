--[[
    Dealer v2 T3: the one place that moves the dealer's stock forward. A server tick:

        1. gates     recovery, open transactions, a save pass or a source update in progress -> do nothing
        2. advance   RLDealerOwnedBirth.advance over the elapsed segments (feeding, actual source births,
                     listing eligibility; it is the superset of RLDealerOwnedProgress)
        3. restock   at most one deficit per 0.25 game-month checkpoint (RLDealerClock.checkpoint): a jump
                     over several checkpoints is one deficit at the final shortage, nothing is made up
        4. fill      at most `budget` places per tick (RLDealerGeneration.fillPlace), so a long restock
                     spreads over frames; a place that fails stays empty until the next checkpoint

    Reads (pages, quotes, debug) never call this: they see the store as the last tick left it.
    Source cap: while the live sources are 3x the shelf target or more, no new place is filled
    (RLDealerScheduler.SOURCE_CAP_FACTOR). Withdrawn sources keep being fed; retiring them from the
    simulation (EXPORTED after 2 months) needs a schema extension of the retired-source archive and is
    NOT implemented: the cap is what bounds the cost until it is.
]]

RLDealerScheduler = { VERSION = 1, SOURCE_CAP_FACTOR = 3 }
local S = RLDealerScheduler


--- opts = { shelfTarget = function(typeIndex) -> places, budget = places per tick (default 1) }
function S.new(opts)
    opts = opts or {}
    return { shelfTarget = opts.shelfTarget or function() return 0 end, budget = opts.budget or 1,
        deficit = 0, lastCheckpointMonths = nil, skippedCheckpoints = 0, paused = nil, stats = { filled = 0, empty = 0, ticks = 0 } }
end


local function countListed(store)
    local n = 0
    for _, row in pairs(store.listings.records) do
        if row.state == "LISTED" or row.state == "RESERVED" or row.state == "DRAFT" then n = n + 1 end
    end
    return n
end


local function countSources(store)
    local n = 0
    for _ in pairs(store.farm.sources) do n = n + 1 end
    return n
end


function S.gate(store, ctx)
    if store == nil or store.sourceOwners == nil then return "NOT_OWNED_STORE" end
    if store.recoveryRequired or store.purchase.recoveryRequired then return "RECOVERY_REQUIRED" end
    if store.sourceUpdateInProgress then return "SOURCE_UPDATE_IN_PROGRESS" end
    if next(store.purchase.locks) ~= nil then return "TRANSACTION_IN_PROGRESS" end
    if ctx.isBusy ~= nil and ctx.isBusy() then return "BUSY" end
    return nil
end


--- One tick. `segments` = { {hours, daysPerMonth}, ... } elapsed since the last tick (may be empty).
--- Returns a report { months, births, filled, empty, deficit, paused } or nil and why.
function S.tick(sched, store, segments, world, ctx)
    local blocked = S.gate(store, ctx)
    if blocked then sched.paused = blocked; return nil, blocked end
    sched.stats.ticks = sched.stats.ticks + 1
    local report = { filled = 0, empty = 0 }

    if #segments > 0 then
        local advanced, why = RLDealerOwnedBirth.advance(store, segments, ctx)
        if advanced == nil then sched.paused = "ADVANCE:" .. tostring(why); return nil, sched.paused end
        report.months, report.births = advanced.months, advanced.births
        -- The advance already took the checkpoint off the clock and reports it.
        local checkpoint = advanced.replenishAtMonths
        if checkpoint ~= nil then
            sched.lastCheckpointMonths, sched.skippedCheckpoints = checkpoint, advanced.skippedCheckpoints or 0
            -- One deficit, at the shortage that exists now.
            local target = sched.shelfTarget(world.typeIndex)
            sched.deficit = math.max(0, target - countListed(store))
        end
    end

    sched.paused = nil
    if sched.deficit > 0 then
        local cap = S.SOURCE_CAP_FACTOR * sched.shelfTarget(world.typeIndex)
        if countSources(store) >= cap then
            sched.paused = "SOURCE_CAP"
        else
            local places = math.min(sched.budget, sched.deficit)
            for _ = 1, places do
                local row, why, info = RLDealerGeneration.fillPlace(store, world, ctx)
                sched.deficit = sched.deficit - 1
                if row ~= nil then sched.stats.filled = sched.stats.filled + 1; report.filled = report.filled + 1
                else
                    sched.stats.empty = sched.stats.empty + 1; report.empty = report.empty + 1
                    -- Why the place stayed empty, for the log (RLDealerRuntime.onHour): every attempt's reason.
                    report.emptyReason, report.emptyReasons = why, type(info) == "table" and info.reasons or nil
                end
                if store.recoveryRequired then sched.paused = "RECOVERY_REQUIRED"; break end
            end
        end
    end
    report.deficit, report.paused = sched.deficit, sched.paused
    return report
end
