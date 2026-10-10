--[[
    T02 batch 4: what a load may trust, from the ledger and the checkpoint markers the asset files
    carry. Pure: no game state is read or changed here.

    A save pass that writes the ledger writes "<lineage>:<generation>" into each participant file
    in the same synchronous pass: placeables.xml (pens and Hof Bergmann's orders), vehicles.xml
    (livestock trailers), farms.xml (money and statistics), and last careerSavegame.xml. The ledger
    lists which of the first three it marked.

    Load decision (decideLoad):

        no ledger, no marker anywhere           FRESH: never enabled; an empty ledger
        no ledger, some marker                  RECOVERY_REQUIRED (LEDGER_MISSING): a ledger existed
        no ledger, a participant unreadable     RECOVERY_REQUIRED (CANNOT_PROVE_FRESH)
        ledger unreadable / damaged / newer     RECOVERY_REQUIRED (LEDGER_UNREADABLE), kept aside
        ledger carries RECOVERY_REQUIRED        RECOVERY_REQUIRED (CARRIED): never laundered by a save
        a marker missing, extra or of another
        lineage or generation                   RECOVERY_REQUIRED (MIXED_CHECKPOINT): the files are
                                                not from one save; no file is preferred
        every marker equals the ledger's        READY (L1)

    RECOVERY_REQUIRED closes every new T02 transaction; the old paths are untouched. Nothing is
    paid, refunded, put back or unlocked automatically on any branch (no L3).

    Record decision on a READY load (decideRecord):

        finished (COMMITTED, COMMITTED_PARTIAL, ROLLED_BACK, REJECTED)   kept as replay-only
        NEEDS_RECONCILIATION                                            kept, locks held
        PREPARED and never past it (history is just PREPARED: no
        adapter callback ran, the stage is marked before each one)     cancelled, nothing to undo
        anything else (a save inside a running transaction)            NEEDS_RECONCILIATION
]]

RLTradeRecovery = {}
local R = RLTradeRecovery

R.FRESH = "FRESH"
R.READY = "READY"
R.RECOVERY_REQUIRED = "RECOVERY_REQUIRED"

R.PARTICIPANTS = { "placeables", "vehicles", "farms" }


--- @param evidence table { ledger = {present, doc = {meta, data}|nil, error}, markers = {career, placeables, vehicles, farms} }
---   A marker is the attribute's text, nil when absent, false when the file could not be read.
--- @return table decision { state, level, reason, mismatches = {text...} }
function R.decideLoad(evidence)
    local markers = evidence.markers or {}
    local ledger = evidence.ledger or {}
    local present, unreadable = {}, {}
    for _, name in ipairs({ "career", "placeables", "vehicles", "farms" }) do
        if markers[name] == false then unreadable[#unreadable + 1] = name
        elseif markers[name] ~= nil then present[#present + 1] = name end
    end

    if not ledger.present then
        if #present > 0 then
            return { state = R.RECOVERY_REQUIRED, level = "L2", reason = "LEDGER_MISSING:" .. table.concat(present, ",") }
        end
        if #unreadable > 0 then
            return { state = R.RECOVERY_REQUIRED, level = "L2", reason = "CANNOT_PROVE_FRESH:" .. table.concat(unreadable, ",") }
        end
        return { state = R.FRESH, level = "L1", reason = "NEVER_ENABLED" }
    end
    if ledger.doc == nil then
        return { state = R.RECOVERY_REQUIRED, level = "L2", reason = "LEDGER_UNREADABLE:" .. tostring(ledger.error) }
    end
    local meta, data = ledger.doc.meta, ledger.doc.data
    if meta.integrity ~= RLTradePersistence.INTEGRITY_OK then
        return { state = R.RECOVERY_REQUIRED, level = "L2", reason = "CARRIED:" .. tostring(meta.reason) }
    end

    local expected = meta.lineage .. ":" .. string.format("%d", meta.generation)
    local mismatches = {}
    if markers.career ~= expected then mismatches[#mismatches + 1] = "career=" .. tostring(markers.career) end
    local listed = type(data.participants) == "table" and data.participants or {}
    for _, name in ipairs(R.PARTICIPANTS) do
        local want = listed[name] == true and expected or nil
        if markers[name] ~= want then mismatches[#mismatches + 1] = name .. "=" .. tostring(markers[name]) end
    end
    if #mismatches > 0 then
        return { state = R.RECOVERY_REQUIRED, level = "L2", reason = "MIXED_CHECKPOINT:" .. table.concat(mismatches, ";"),
            mismatches = mismatches }
    end
    return { state = R.READY, level = "L1", reason = "CHECKPOINT_" .. expected }
end


R.KEEP_FINISHED = "KEEP_FINISHED"
R.KEEP_RECONCILIATION = "KEEP_RECONCILIATION"
R.CANCEL_NEVER_STARTED = "CANCEL_NEVER_STARTED"
R.RECONCILE_MID_TRANSACTION = "RECONCILE_MID_TRANSACTION"


--- @param record table A saved ledger record
--- @return string decision
function R.decideRecord(record)
    if RLTradeTransaction.FINISHED[record.state] then return R.KEEP_FINISHED end
    if record.state == "NEEDS_RECONCILIATION" then return R.KEEP_RECONCILIATION end
    if record.state == "PREPARED" and type(record.history) == "table" and #record.history == 1 and record.history[1] == "PREPARED" then
        return R.CANCEL_NEVER_STARTED
    end
    return R.RECONCILE_MID_TRANSACTION
end
