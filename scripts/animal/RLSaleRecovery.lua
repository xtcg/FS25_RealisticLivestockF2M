--[[
    T02 batch 3: what a live sale does next, from what the source really shows and what the money
    receipt proves. Pure: no game state is read or changed here.

    After the removal (RLTradeSourceAdapter.observe):

        source unreadable, cluster system changed, a member outside the batch changed
                                    -> SOURCE_UNKNOWN: nothing paid, nothing removed again,
                                       nothing put back; locks held for reconciliation
        nothing of the batch left   -> NONE_REMOVED: nothing to pay; put back / unqueue and verify
        some or all left            -> SETTLE the confirmed subset at its frozen per-head amounts

    After the one money action for that subset (RLSaleSettlement):

        APPLIED, all left           -> COMMITTED
        APPLIED, some left          -> COMMITTED_PARTIAL: survivors stay, unqueued; the batch is
                                       still reported as not completed
        NOT_APPLIED                 -> RESTORE the subset that left (the same animal objects),
                                       ROLLED_BACK only once the restore is verified
        UNKNOWN or no receipt       -> RECONCILE: no second payment, no restore, no resale
]]

RLSaleRecovery = {}

RLSaleRecovery.SOURCE_UNKNOWN = "SOURCE_UNKNOWN"
RLSaleRecovery.NONE_REMOVED = "NONE_REMOVED"
RLSaleRecovery.SETTLE = "SETTLE"

RLSaleRecovery.COMMITTED = "COMMITTED"
RLSaleRecovery.COMMITTED_PARTIAL = "COMMITTED_PARTIAL"
RLSaleRecovery.RESTORE = "RESTORE"
RLSaleRecovery.RECONCILE = "RECONCILE"


--- @param outcome table|nil {known, sameSystem, othersIntact, removed = {i...}, survivors = {i...}}
--- @return string decision SOURCE_UNKNOWN, NONE_REMOVED or SETTLE
--- @return string|nil reason For SOURCE_UNKNOWN
function RLSaleRecovery.afterSource(outcome)
    if type(outcome) ~= "table" or outcome.known ~= true then
        return RLSaleRecovery.SOURCE_UNKNOWN, type(outcome) == "table" and outcome.reason or "NO_OUTCOME"
    end
    if outcome.sameSystem ~= true then return RLSaleRecovery.SOURCE_UNKNOWN, "SOURCE_CHANGED" end
    if outcome.othersIntact ~= true then return RLSaleRecovery.SOURCE_UNKNOWN, "OTHER_MEMBER_CHANGED" end
    if type(outcome.removed) ~= "table" or type(outcome.survivors) ~= "table" then return RLSaleRecovery.SOURCE_UNKNOWN, "NO_SUBSET" end
    if #outcome.removed == 0 then return RLSaleRecovery.NONE_REMOVED end
    return RLSaleRecovery.SETTLE
end


--- @param outcome table A SETTLE outcome
--- @param status string|nil The receipt's status
--- @return string decision COMMITTED, COMMITTED_PARTIAL, RESTORE or RECONCILE
function RLSaleRecovery.afterSettlement(outcome, status)
    if status == RLSaleSettlement.APPLIED then
        if #outcome.survivors == 0 then return RLSaleRecovery.COMMITTED end
        return RLSaleRecovery.COMMITTED_PARTIAL
    end
    if status == RLSaleSettlement.NOT_APPLIED then return RLSaleRecovery.RESTORE end
    return RLSaleRecovery.RECONCILE
end
