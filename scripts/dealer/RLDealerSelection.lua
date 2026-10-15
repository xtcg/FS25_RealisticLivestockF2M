-- Dealer v2 T5: the player's selection across pages. Pure client state. A selection is saleId -> revision:
-- when a page or detail shows another revision (or the row is gone) the entry is marked stale and has to
-- be picked again - it is never silently swapped for another animal of the same breed. At most 100 per
-- order (the server's own batch limit is separate and larger).
RLDealerSelection = { MAX = 100 }
local S = RLDealerSelection

function S.new() return { items = {}, count = 0, stale = {} } end

function S.toggle(sel, saleId, revision)
    if sel.items[saleId] ~= nil then
        sel.items[saleId], sel.stale[saleId] = nil, nil
        sel.count = sel.count - 1
        return true, "REMOVED"
    end
    if sel.count >= S.MAX then return nil, "SELECTION_LIMIT" end
    sel.items[saleId] = revision
    sel.count = sel.count + 1
    return true, "ADDED"
end

--- Rows of the current snapshot: any selected entry on these rows with another revision turns stale.
function S.observe(sel, rows)
    local changed = {}
    for _, row in ipairs(rows) do
        local want = sel.items[row.saleId]
        if want ~= nil and want ~= row.revision then sel.stale[row.saleId] = true; changed[#changed + 1] = row.saleId end
    end
    return changed
end

--- A listing the server says is gone or newer.
function S.invalidate(sel, saleId)
    if sel.items[saleId] ~= nil then sel.stale[saleId] = true end
end

function S.hasStale(sel) return next(sel.stale) ~= nil end

--- Drop the stale entries (the player confirmed to continue without them).
function S.dropStale(sel)
    for saleId in pairs(sel.stale) do sel.items[saleId] = nil; sel.count = sel.count - 1 end
    sel.stale = {}
end

--- The items for a quote request, or nil and why (nothing selected, or stale entries still there).
function S.items(sel)
    if sel.count == 0 then return nil, "EMPTY_SELECTION" end
    if S.hasStale(sel) then return nil, "STALE_SELECTION" end
    local out = {}
    for saleId, revision in pairs(sel.items) do out[#out + 1] = { saleId = saleId, revision = revision } end
    table.sort(out, function(a, b) return a.saleId < b.saleId end)
    return out
end
