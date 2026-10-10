loadMod("scripts/animal/RLTradeTransaction.lua")
local T = RLTradeTransaction
local function start(kind, resources)
    local store = T.new()
    assert(T.begin(store, "tx1", kind or "CONTRACT", "fixed-payload", resources or { "farm:1", "animal:A", "order:1" }))
    return store
end
-- Fault injection adapters below verify coordinator behavior, not GIANTS rollback contracts.
local function adapter()
    local assets = { target = 0, source = 2, money = 100, notices = 0, receipt = "UNKNOWN" }
    local a = {
        preflight = function() return true end,
        applyTarget = function() assets.target = assets.target + 2; assets.money = assets.money - 20; return true end,
        verifyTarget = function() return assets.target == 2 and assets.money == 80 end,
        rollbackTarget = function() assets.target = assets.target - 2; assets.money = assets.money + 20; return true end,
        verifyTargetRestored = function() return assets.target == 0 and assets.money == 100 end,
        applySource = function() assets.source = assets.source - 2; return true end,
        verifySource = function() return assets.source == 0 end,
        rollbackSource = function() assets.source = assets.source + 2; return true end,
        verifySourceRestored = function() return assets.source == 2 end,
        settle = function() assets.money = assets.money + 20; assets.receipt = "APPLIED"; return true end,
        settlementStatus = function() return assets.receipt end,
        notify = function() assets.notices = assets.notices + 1 end,
    }
    return a, assets
end
do
    local s = start()
    local a, assets = adapter()
    local remove = a.applySource
    a.applySource = function() remove(); assets.target = assets.target + 1; return true end
    local result = T.executeContract(s, "tx1", a)
    check("contract: final target verification catches a source callback's foreign mutation",
        result.state == "NEEDS_RECONCILIATION" and assets.source == 2 and assets.target == 1
        and result.reason == "TARGET_ROLLBACK_UNKNOWN:TARGET_CHANGED_AFTER_SOURCE" and next(s.locks) ~= nil)
end
do
    local s, a = start(), adapter()
    local result = T.executeContract(s, "tx1", a)
    check("contract: verified target and source commit", result.state == "COMMITTED")
    check("contract: release shared resources on commit", next(s.locks) == nil)
    local before = #result.history
    local replay, reason = T.executeContract(s, "tx1", a)
    check("commit replay: no repeated economic callbacks", reason == "REPLAY" and #replay.history == before)
    replay.state = "PREPARED"
    check("returned record cannot mutate authoritative ledger", s.records.tx1.state == "COMMITTED")
end
do
    local s, a, assets = start(), adapter()
    a, assets = adapter()
    a.preflight = function() return false end
    local result = T.executeContract(s, "tx1", a)
    check("preflight reject: no assets touched", result.state == "REJECTED" and assets.target == 0 and assets.source == 2)
    check("preflight reject: locks released", next(s.locks) == nil)
end
for _, mode in ipairs({ "false", "throw", "verify" }) do
    local s, a, assets = start()
    a, assets = adapter()
    local original = a.applyTarget
    a.applyTarget = function()
        original()
        if mode == "throw" then error("after target mutation") end
        return mode ~= "false"
    end
    if mode == "verify" then a.verifyTarget = function() return false end end
    local result = T.executeContract(s, "tx1", a)
    check("target " .. mode .. ": compensated before source removal",
        result.state == "ROLLED_BACK" and assets.target == 0 and assets.money == 100 and assets.source == 2)
end
do
    local s, a, assets = start()
    a, assets = adapter()
    a.applyTarget = function() assets.target = 1; assets.money = 90; return true end
    a.rollbackTarget = function() assets.target = assets.target - 1; assets.money = assets.money + 10; return true end
    local result = T.executeContract(s, "tx1", a)
    check("half acceptance: true does not count as complete; verified partial delta reversed",
        result.state == "ROLLED_BACK" and assets.target == 0 and assets.money == 100 and assets.source == 2)
end
do
    local s, a = start(), adapter()
    a.applyTarget = function() return false end
    a.rollbackTarget = function() error("inverse uncertain") end
    local result = T.executeContract(s, "tx1", a)
    check("unknown rollback: explicit reconciliation state", result.state == "NEEDS_RECONCILIATION")
    local _, reason = T.begin(s, "tx2", "CONTRACT", "different", { "farm:1" })
    check("unknown rollback: conflicting request stays locked", reason == "RESOURCE_BUSY")
    a.rollbackTarget = function() return true end
    local _, replay = T.executeContract(s, "tx1", a)
    check("unknown rollback: no blind automatic retry", replay == "REPLAY")
end
do
    local s, a = start(), adapter()
    a.applyTarget = function() return false end
    a.rollbackTarget = function() return true end
    a.verifyTargetRestored = function() return false end
    check("rollback return true alone is insufficient", T.executeContract(s, "tx1", a).state == "NEEDS_RECONCILIATION")
end
do
    local s, a, assets = start()
    a, assets = adapter()
    a.applySource = function() assets.source = 0; error("source threw after removal") end
    local result = T.executeContract(s, "tx1", a)
    check("source failure: reverse source then target", result.state == "ROLLED_BACK" and assets.source == 2
        and assets.target == 0 and assets.money == 100)
end
do
    local s, a, assets = start()
    a, assets = adapter()
    a.applySource = function() assets.source = 0; error("source failed") end
    a.rollbackSource = function() return false end
    local result = T.executeContract(s, "tx1", a)
    check("unrecoverable source: do not also undo target and lose both assets",
        result.state == "NEEDS_RECONCILIATION" and assets.target == 2 and assets.money == 80)
end
do
    local s, a, assets = start()
    a, assets = adapter()
    a.notify = function() error("visual failure") end
    local result = T.executeContract(s, "tx1", a)
    check("visual failure is after economic commit", result.state == "COMMITTED" and result.notificationError ~= nil)
    T.executeContract(s, "tx1", a)
    check("visual failure cannot repeat target credit", assets.target == 2 and assets.money == 80)
end
do
    local s, a = start(), adapter()
    a.preflight = function()
        local _, reason = T.executeContract(s, "tx1", a)
        check("reentrant same id: cannot execute twice", reason == "IN_PROGRESS")
        local _, blocked = T.begin(s, "tx2", "CONTRACT", "other", { "farm:1" })
        check("reentrant shared wallet: locked", blocked == "RESOURCE_BUSY")
        return true
    end
    T.executeContract(s, "tx1", a)
end
do
    local s = start()
    local _, why = T.begin(s, "tx1", "CONTRACT", "changed payload", { "farm:1" })
    check("transaction id reuse with changed payload refused", why == "ID_COLLISION")
    local _, replay = T.begin(s, "tx1", "CONTRACT", "fixed-payload", { "farm:1" })
    check("same transaction returns prior state", replay == "REPLAY")
    local record = T.executeContract(s, "tx1", {})
    check("missing verified inverse refuses adapter before mutation", record.state == "REJECTED")
end
for _, mode in ipairs({ "applied", "before", "after", "unknown", "invalid" }) do
    local s, a, assets = start("SALE")
    a, assets = adapter()
    a.settle = function()
        if mode == "before" then assets.receipt = "NOT_APPLIED"; error("before money") end
        assets.money = assets.money + 20
        assets.receipt = mode == "unknown" and "UNKNOWN" or mode == "invalid" and "wrong" or "APPLIED"
        if mode ~= "applied" then error("after money") end
        return true
    end
    local result = T.executeSale(s, "tx1", a)
    if mode == "before" then
        check("sale known no payment: source restored", result.state == "ROLLED_BACK" and assets.source == 2 and assets.money == 100)
    elseif mode == "applied" or mode == "after" then
        check("sale " .. mode .. ": proven receipt commits once", result.state == "COMMITTED" and assets.source == 0 and assets.money == 120)
    else
        check("sale " .. mode .. ": do not resurrect or repay", result.state == "NEEDS_RECONCILIATION"
            and assets.source == 0 and assets.money == 120)
    end
    T.executeSale(s, "tx1", a)
    check("sale " .. mode .. ": retry cannot add money twice", assets.money == (mode == "before" and 100 or 120))
end
do
    local s, a = start(), adapter()
    T.executeContract(s, "tx1", a)
    assert(T.begin(s, "tx2", "CONTRACT", "second", { "farm:1" }))
    local data = T.export(s)
    local loaded = assert(T.import(data))
    check("ledger: completed id retained across reload", loaded.records.tx1.state == "COMMITTED")
    check("ledger: unfinished state never automatically replayed", loaded.records.tx2.state == "NEEDS_RECONCILIATION")
    check("ledger: recovery gate blocks new transactions", select(2, T.begin(loaded, "tx3", "SALE", "third", { "farm:2" })) == "RECOVERY_REQUIRED")
    data.records.tx1.state = "PREPARED"
    check("ledger: import is independent of exported mutable table", loaded.records.tx1.state == "COMMITTED")
end
do
    local s = start("SALE", { "farm:1" })
    assert(T.begin(s, "tx2", "CONTRACT", "second", { "farm:2" }))
    local loaded = assert(T.import(T.export(s)))
    check("ledger: several unfinished records all loaded and locked", loaded.records.tx1.state == "NEEDS_RECONCILIATION"
        and loaded.records.tx2.state == "NEEDS_RECONCILIATION" and loaded.locks["farm:1"] == "tx1"
        and loaded.locks["farm:2"] == "tx2")
end
do
    local s, a = start(), adapter()
    T.executeContract(s, "tx1", a)
    local loaded = assert(T.import(T.export(s)))
    local _, reason = T.executeContract(loaded, "tx1", a)
    check("ledger: completed retry after reload still replay only", reason == "REPLAY")
    check("ledger: complete-only reload does not freeze unrelated work", not loaded.recoveryRequired)
    local data = T.export(s)
    data.version = 99
    check("ledger: unknown schema rejected", T.import(data) == nil)
    data.version = T.VERSION
    data.records.tx1.state = "made up"
    check("ledger: unknown persisted state rejected", T.import(data) == nil)
end
