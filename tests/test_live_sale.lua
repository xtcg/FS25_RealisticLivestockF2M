-- T02 batch 3 (PR #33): the player's and the herdsman's live sale as one server transaction with a
-- money receipt (RLLiveSale, RLSaleSettlement, RLSaleRecovery, RLTradeTransaction.executeLiveSale,
-- RLTradeSourceAdapter.observe/clearBatchQueue), and the herdsman wage as its own money action.
--
-- Real code under test: the base game's money path (tests/fixtures/fs25_money.lua: addMoney,
-- addMoneyChange, Farm:changeBalance, FarmStats), the base cluster queue and flush
-- (tests/fixtures/fs25_cluster_queue.lua), RLRM's cluster system (through giants_lua.lua),
-- Animal:setClusterSystem / getNumAnimals, AnimalSellEvent, AIAnimalSellEvent, RLHerdsmanExecutor,
-- RLHerdsmanMessages, RLDiseaseSaleGate and the T02 modules. Engine stand-ins, marked below: the
-- farm tables, HUD/notifications, the pen's visual animals, events and messages, network
-- connections. They are no proof of the engine's visuals, network sync or saving.
-- Case ids follow docs/T02_TEST_WORKFLOW.md (S group; A/C/E regressions).

AnimalSellEvent = {
    SELL_SUCCESS = 0, SELL_ERROR_NO_PERMISSION = 1, SELL_ERROR_INVALID_CLUSTER = 2,
    SELL_ERROR_NOT_ENOUGH_ANIMALS = 3, SELL_ERROR_CANNOT_BE_SOLD = 4, SELL_ERROR_OBJECT_DOES_NOT_EXIST = 5,
}
function AnimalSellEvent.emptyNew() return setmetatable({}, { __index = AnimalSellEvent }) end
function AnimalSellEvent.newServerToClient(errorCode)
    local event = AnimalSellEvent.emptyNew()
    event.errorCode = errorCode
    return event
end
AnimalBuyEvent = { BUY_ERROR_OBJECT_DOES_NOT_EXIST = 1, BUY_ERROR_NOT_ENOUGH_SPACE = 2, BUY_ERROR_NOT_ENOUGH_MONEY = 3 }
AnimalMoveEvent = { MOVE_SUCCESS = 0 }
loadMod("tests/fixtures/giants_lua.lua")
loadMod("tests/fixtures/fs25_money.lua")

TYPES = { [1] = { name = "COW" } }
SUBS = { [1] = { typeIndex = 1, typeName = "COW", targetWeight = 1000, name = "BULL_ANGUS", breed = "ANGUS", gender = "male" } }

-- Money types as registered (MoneyType.register: id + statistic).
MoneyType = { SOLD_ANIMALS = { id = 7, statistic = "soldAnimals" }, NEW_ANIMALS_COST = { id = 8, statistic = "newAnimalsCost" },
    HERDSMAN_WAGES = { id = 30, statistic = "herdsmanWages" }, OTHER = { id = 9, statistic = "other" } }
MessageType = { MONEY_CHANGED = "MONEY_CHANGED" }
Logging = { error = function() end }
printError, printCallstack = function() end, function() end

-- Engine stand-ins: farms (FarmMoney.newFarm), HUD, notifications.
FARMS = {}
local function setFarm(id, money)
    FARMS[id] = FarmMoney.newFarm(id, money, { "soldAnimals", "newAnimalsCost", "herdsmanWages", "other" })
end
local farmLookupFault, hudFault, notifyFault = nil, nil, nil
NOTIFIED = {}
MoneyChangeEvent = { new = function(amount, moneyType, farmId, text) return { amount = amount, moneyType = moneyType, farmId = farmId, text = text } end }
g_farmManager = {
    getFarmById = function(_, id)
        if farmLookupFault ~= nil then
            farmLookupFault = farmLookupFault - 1
            if farmLookupFault == 0 then farmLookupFault = nil error("farm lookup failed") end
        end
        return FARMS[id]
    end,
    getFarmForUniqueUserId = function(_, userId) return { farmId = userId == "bob" and 2 or 1 } end,
}
local permitted = true
g_currentMission = {
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    missionDynamicInfo = { isMultiplayer = false },
    moneyChanges = {},
    hud = { addMoneyChange = function() if hudFault then hudFault = nil error("hud failed") end end, showMoneyChange = function() end },
    getIsServer = function() return true end,
    getFarmId = function() return 1 end,
    getHasPlayerPermission = function(_, permission) return permission == "tradeAnimals" and permitted end,
    userManager = { getUniqueUserIdByConnection = function(_, connection) return connection.user end },
    broadcastNotifications = FSBaseMissionMoney.broadcastNotifications,
    -- Stand-in for the network send of the farm's money change.
    broadcastEventToFarm = function(_, event, farmId)
        if notifyFault then notifyFault = nil error("notification failed") end
        NOTIFIED[#NOTIFIED + 1] = { amount = event.amount, statistic = event.moneyType.statistic, farmId = farmId }
    end,
    getMoney = function(_, farmId) return FARMS[farmId] ~= nil and FARMS[farmId].money or 0 end,
    addMoney = FSBaseMissionMoney.addMoney,
    addMoneyChange = FSBaseMissionMoney.addMoneyChange,
}
local mission = g_currentMission
local baseAddMoney = mission.addMoney
g_i18n = { formatMoney = function(_, v) return string.format("%.2f", v) end }

-- Engine stand-ins for what the cluster flush calls; listeners of MONEY_CHANGED and of the
-- cluster update can be installed by a test.
string.contains = function(text, part) return text:find(part, 1, true) ~= nil end
getTimeSec = os.clock
local moneyListener, clusterListener
g_server = { netIsRunning = true, broadcastEvent = function() end }
g_messageCenter = { publish = function(_, kind, ...)
    if kind == MessageType.MONEY_CHANGED then
        if moneyListener ~= nil then moneyListener(...) end
    elseif clusterListener ~= nil then
        clusterListener(...)
    end
end }
AnimalClusterUpdateEvent = { new = function(owner, animals) return { owner = owner, count = #animals } end }
local visualRemovals, removalFaultAt = 0, nil
removeHusbandryAnimal = function()
    visualRemovals = visualRemovals + 1
    if removalFaultAt ~= nil and visualRemovals >= removalFaultAt then removalFaultAt = nil error("visual removal failed") end
end
RLAnimalUtil = {
    toKey = function(farmId, uniqueId, country) return farmId .. " " .. uniqueId .. " " .. country end,
    toShortKey = function(farmId, uniqueId) return farmId .. " " .. uniqueId end,
}
function RLAnimalUtil.toKeyFromIdentifiers(ids)
    local country = ids.country or (ids.birthday and ids.birthday.country)
    if country == nil then return nil end
    return RLAnimalUtil.toKey(ids.farmId, ids.uniqueId, country)
end
function RLAnimalUtil.find(animals, farmId, uniqueId, country)
    for _, a in pairs(animals) do
        if a.farmId == farmId and a.uniqueId == uniqueId and a.birthday.country == country then return a end
    end
end
local wireQueue = {}
function RLAnimalUtil.readStreamIdentifiers() return table.remove(wireQueue, 1) end
NetworkUtil = { readNodeObject = function() return table.remove(wireQueue, 1) end }
streamReadUInt16 = function() return table.remove(wireQueue, 1) end
streamReadFloat32 = function() return table.remove(wireQueue, 1) end
AnimalMarkEvent = { new = function(_, animal, key) return { mark = key, animal = animal } end }
RLHusbandryProfiles = { checkAnimal = function() return true end, logDecision = function() end }

loadMod("tests/fixtures/fs25_cluster_queue.lua")
loadGiantsMod("scripts/animals/husbandry/cluster/RealisticLivestock_AnimalClusterSystem.lua")
loadAnimalSection("function Animal:setClusterSystem", "function Animal:getSupportsMerging")
loadAnimalSection("function Animal:getNumAnimals", "function Animal:getSubTypeIndex")
-- Stand-ins for the animal's own price, fee and sale gates (their values are the test's).
function Animal:getHasAnyDisease() return self.sick == true end
function Animal:getSellPrice() return self.price end
function Animal:getTranportationFee(factor) return self.fee * factor end
function Animal:getCanBeSold() return self.canBeSold ~= false end
function Animal:setMarked(key, value) self.marked = self.marked or {} self.marked[key] = value end

loadMod("scripts/disease/RLDiseaseSaleGate.lua")
loadMod("scripts/animals/shop/events/AnimalSellEvent.lua")
loadMod("scripts/animals/shop/events/AIAnimalSellEvent.lua")
loadMod("scripts/animals/shop/events/AIAnimalBuyEvent.lua")
loadMod("scripts/herdsman/RLHerdsmanRuleService.lua")
loadMod("scripts/filters/RLFilterEvaluator.lua")
loadMod("scripts/herdsman/RLHerdsmanPlanner.lua")
loadMod("scripts/herdsman/RLHerdsmanExecutor.lua")
loadMod("scripts/herdsman/RLHerdsmanMessages.lua")
loadMod("scripts/animal/RLTradeTransaction.lua")
loadMod("scripts/animal/RLTradeSourceAdapter.lua")
loadMod("scripts/animal/RLContractTrade.lua")
loadMod("scripts/animal/RLSaleSettlement.lua")
loadMod("scripts/animal/RLSaleRecovery.lua")
loadMod("scripts/animal/RLLiveSale.lua")
loadMod("scripts/console/RLTradeReportConsole.lua")

local LS, S, T = RLLiveSale, RLSaleSettlement, RLTradeTransaction
local function has(text, part) return type(text) == "string" and text:find(part, 1, true) ~= nil end
local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

-- ===========================================================================================
-- Pure: the receipt's explanation of one addMoney call
-- ===========================================================================================

local function witnesses(over)
    local w = { money = 1000, finance = 50, counter = 7, hero = 0, heroActive = true, change = nil }
    for k, v in pairs(over or {}) do w[k] = v end
    return w
end
do
    local before = witnesses()
    local status, evidence = S.classify(before, witnesses({ money = 1100, finance = 150, counter = 8, hero = 100 }), 100, false)
    check("receipt classify: every step once, the HUD total sent and cleared -> APPLIED", status == "APPLIED" and evidence == "ALL_STEPS")
    status = S.classify(witnesses({ change = 30 }), witnesses({ money = 1100, finance = 150, counter = 8, hero = 100 }), 100, false)
    check("receipt classify: another pending HUD total is sent and cleared with it -> APPLIED", status == "APPLIED")
    status = S.classify(before, witnesses({ money = 1100, finance = 150, counter = 8, hero = 100, change = 100 }), 100, false)
    check("receipt classify: returned but the total not cleared -> UNKNOWN", status == "UNKNOWN")
    status, evidence = S.classify(before, witnesses({ money = 1100, finance = 150, counter = 8, hero = 100, change = 100 }), 100, true)
    check("receipt classify: throw after the last step -> APPLIED, the throw kept", status == "APPLIED" and evidence == "THREW_AFTER_ALL_STEPS")
    status, evidence = S.classify(before, witnesses(), 100, true)
    check("receipt classify: throw and no step -> NOT_APPLIED", status == "NOT_APPLIED" and evidence == "THREW_BEFORE_ANY_STEP")
    status, evidence = S.classify(before, witnesses(), 100, false)
    check("receipt classify: returned and no step -> UNKNOWN (the base function returns quietly too)", status == "UNKNOWN"
        and evidence == "RETURNED_WITHOUT_ANY_STEP")
    status, evidence = S.classify(before, witnesses({ money = 1100, finance = 150, counter = 8, hero = 100 }), 100, true)
    check("receipt classify: money and statistics but no HUD total (listener threw) -> UNKNOWN", status == "UNKNOWN"
        and evidence == "NOTIFICATION_STEP_NOT_REACHED")
    status = S.classify(before, witnesses({ money = 1100 }), 100, true)
    check("receipt classify: money only -> UNKNOWN", status == "UNKNOWN")
    status = S.classify(before, witnesses({ money = 1150, finance = 150, counter = 8, hero = 100 }), 100, false)
    check("receipt classify: money off by another amount (another listener) -> UNKNOWN", status == "UNKNOWN")
    status = S.classify(before, witnesses({ money = 1100, finance = 150, counter = 9, hero = 100 }), 100, false)
    check("receipt classify: statistic counter moved twice (a second money call inside) -> UNKNOWN", status == "UNKNOWN")
    status = S.classify(before, witnesses({ money = 900, finance = -50, counter = 8 }), -100, false)
    check("receipt classify: a negative amount leaves the hero accumulator alone -> APPLIED", status == "APPLIED")
    status = S.classify(before, witnesses({ money = 900, finance = -50, counter = 8, hero = -100 }), -100, false)
    check("receipt classify: a negative amount that touched the hero accumulator -> UNKNOWN", status == "UNKNOWN")
    status = S.classify(before, witnesses({ counter = 8 }), 0, false)
    check("receipt classify: zero amount proven by the statistic counter -> APPLIED", status == "APPLIED")
    status = S.classify(before, witnesses(), 0, true)
    check("receipt classify: zero amount, threw, counter unmoved -> NOT_APPLIED", status == "NOT_APPLIED")
    status = S.classify(witnesses({ counter = 999999 }), witnesses({ money = 1100, finance = 150, counter = 0, hero = 100 }), 100, false)
    check("receipt classify: statistic counter wraps after 999999 like FarmStats", status == "APPLIED")
end

-- ===========================================================================================
-- Pure: recovery decisions
-- ===========================================================================================

do
    local R = RLSaleRecovery
    local function o(removed, survivors, extra)
        local t = { known = true, sameSystem = true, othersIntact = true, removed = removed, survivors = survivors }
        for k, v in pairs(extra or {}) do t[k] = v end
        return t
    end
    check("decision: unreadable -> SOURCE_UNKNOWN", R.afterSource({ known = false, reason = "X" }) == R.SOURCE_UNKNOWN)
    check("decision: no outcome -> SOURCE_UNKNOWN", R.afterSource(nil) == R.SOURCE_UNKNOWN)
    check("decision: cluster system replaced -> SOURCE_UNKNOWN", R.afterSource(o({ 1 }, {}, { sameSystem = false })) == R.SOURCE_UNKNOWN)
    check("decision: a member outside the batch changed -> SOURCE_UNKNOWN", R.afterSource(o({ 1 }, {}, { othersIntact = false })) == R.SOURCE_UNKNOWN)
    check("decision: none left -> NONE_REMOVED", R.afterSource(o({}, { 1, 2 })) == R.NONE_REMOVED)
    check("decision: some left -> SETTLE", R.afterSource(o({ 1 }, { 2 })) == R.SETTLE)
    check("decision: all left, APPLIED -> COMMITTED", R.afterSettlement(o({ 1, 2 }, {}), "APPLIED") == R.COMMITTED)
    check("decision: some left, APPLIED -> COMMITTED_PARTIAL", R.afterSettlement(o({ 1 }, { 2 }), "APPLIED") == R.COMMITTED_PARTIAL)
    check("decision: NOT_APPLIED -> RESTORE", R.afterSettlement(o({ 1 }, { 2 }), "NOT_APPLIED") == R.RESTORE)
    check("decision: UNKNOWN or no receipt -> RECONCILE", R.afterSettlement(o({ 1 }, {}), "UNKNOWN") == R.RECONCILE
        and R.afterSettlement(o({ 1 }, {}), nil) == R.RECONCILE and R.afterSettlement(o({ 1 }, {}), "bogus") == R.RECONCILE)
end

-- ===========================================================================================
-- The coordinator with fault-injecting adapters (coordinator behaviour, not engine contracts)
-- ===========================================================================================

do
    local function fake(over)
        local log = { calls = {} }
        local outcome = { known = true, sameSystem = true, othersIntact = true, removed = { 1, 2 }, survivors = {},
            removedKeys = { "k1", "k2" }, survivorKeys = {} }
        local a = {
            preflight = function() return true end,
            applySource = function() log.calls[#log.calls + 1] = "apply" return true end,
            observeSource = function() return outcome end,
            clearSourceQueue = function() log.calls[#log.calls + 1] = "clear" return true end,
            settle = function() log.calls[#log.calls + 1] = "settle" return { status = "APPLIED", paymentId = "p", amount = 10 } end,
            restoreSource = function() log.calls[#log.calls + 1] = "restore" return true end,
            verifySourceRestored = function() return true end,
            notify = function() log.calls[#log.calls + 1] = "notify" end,
        }
        for k, v in pairs(over or {}) do a[k] = v end
        return a, log, outcome
    end
    local function run(over, mutate)
        local store = T.new()
        assert(T.begin(store, "s1", "SALE", "fp", { "animal:k1", "animal:k2", "cash:farm1" }))
        local a, log, outcome = fake(over)
        if mutate then mutate(outcome) end
        return T.executeLiveSale(store, "s1", a), store, log, a
    end
    local record, store, log, a = run()
    check("coordinator: all left, APPLIED -> COMMITTED, locks released, notified once", record.state == "COMMITTED"
        and next(store.locks) == nil and table.concat(log.calls, ",") == "apply,clear,settle,clear,notify")
    local replay, why = T.executeLiveSale(store, "s1", a)
    check("coordinator: replay calls nothing", why == "REPLAY" and #log.calls == 5 and replay.state == "COMMITTED")
    record, store = run({ preflight = function() error("boom") end })
    check("coordinator: preflight throws -> REJECTED, released", record.state == "REJECTED" and next(store.locks) == nil)
    record, store = run({ observeSource = function() error("boom") end })
    check("coordinator: observe throws -> SOURCE_UNKNOWN, held, nothing paid", record.state == "NEEDS_RECONCILIATION"
        and has(record.reason, "SOURCE_UNKNOWN:OBSERVE_THREW") and store.locks["cash:farm1"] == "s1" and record.sale.payment == nil)
    record, store, log = run(nil, function(o) o.removed, o.survivors, o.removedKeys, o.survivorKeys = { 1 }, { 2 }, { "k1" }, { "k2" } end)
    check("coordinator: some left, APPLIED -> COMMITTED_PARTIAL, survivors unqueued before money",
        record.state == "COMMITTED_PARTIAL" and table.concat(log.calls, ",") == "apply,clear,settle,clear,notify")
    record, store = run({ clearSourceQueue = function() return false end })
    check("coordinator: survivors not unqueued -> money stands, NEEDS_RECONCILIATION", record.state == "NEEDS_RECONCILIATION"
        and record.reason == "SURVIVOR_QUEUE_NOT_CLEARED" and record.sale.payment == "APPLIED")
    record, store = run({ settle = function() error("boom") end })
    check("coordinator: settle throws -> UNKNOWN, held, no restore", record.state == "NEEDS_RECONCILIATION"
        and record.sale.payment == "UNKNOWN" and store.locks["animal:k1"] == "s1")
    record, store, log = run({ settle = function() return { status = "NOT_APPLIED", paymentId = "p", amount = 10 } end })
    check("coordinator: NOT_APPLIED -> restore verified -> ROLLED_BACK", record.state == "ROLLED_BACK"
        and has(table.concat(log.calls, ","), "restore") and #record.sale.restored == 2 and next(store.locks) == nil)
    record, store = run({ settle = function() return { status = "NOT_APPLIED" } end, restoreSource = function() error("boom") end })
    check("coordinator: NOT_APPLIED, restore throws -> held, not ROLLED_BACK", record.state == "NEEDS_RECONCILIATION"
        and has(record.reason, "SOURCE_RESTORE_UNKNOWN"))
    record = run({ settle = function() return { status = "NOT_APPLIED" } end, verifySourceRestored = function() return false end })
    check("coordinator: NOT_APPLIED, restore returns true but unverified -> held", record.state == "NEEDS_RECONCILIATION")
    record = run({ settle = function() return { status = "made up" } end })
    check("coordinator: an unknown receipt status -> held", record.state == "NEEDS_RECONCILIATION")
    record, store, log = run(nil, function(o) o.removed, o.survivors, o.removedKeys, o.survivorKeys = {}, { 1, 2 }, {}, { "k1", "k2" } end)
    check("coordinator: none left -> nothing paid, put back -> ROLLED_BACK", record.state == "ROLLED_BACK"
        and not has(table.concat(log.calls, ","), "settle") and has(record.reason, "NONE_REMOVED"))
    record = run({ applySource = function() error("half way") end })
    check("coordinator: apply throws but all left -> paid, COMMITTED with the error kept", record.state == "COMMITTED"
        and has(record.sale.applyError, "half way"))
    record = run({ notify = function() error("boom") end })
    check("coordinator: notify throws after commit -> COMMITTED, error noted", record.state == "COMMITTED"
        and has(record.notificationError, "boom"))
    local store2 = T.new()
    assert(T.begin(store2, "s1", "SALE", "fp", { "animal:k1" }))
    local inner
    local reentrant = fake({ settle = function()
        inner = { T.executeLiveSale(store2, "s1", fake()) }
        return { status = "APPLIED" }
    end })
    T.executeLiveSale(store2, "s1", reentrant)
    check("coordinator: re-entry with the same id while settling -> IN_PROGRESS", inner[1] == nil and inner[2] == "IN_PROGRESS")
    store2 = T.new()
    assert(T.begin(store2, "s1", "SALE", "fp", { "animal:k1" }))
    check("coordinator: a missing method refuses before anything", T.executeLiveSale(store2, "s1", { preflight = function() return true end }).state == "REJECTED")
    store2 = T.new()
    assert(T.begin(store2, "c1", "CONTRACT", "fp", { "animal:k1" }))
    check("coordinator: a contract record is not run as a sale", select(2, T.executeLiveSale(store2, "c1", fake())) == "WRONG_KIND")
end

-- ===========================================================================================
-- The receipt against the base game's money code
-- ===========================================================================================

do
    setFarm(1, 1000)
    mission.moneyChanges = {}
    local payments = {}
    local receipt = S.apply(payments, { paymentId = "p1", kind = "SALE", farmId = 1, amount = 250, moneyType = MoneyType.SOLD_ANIMALS }, mission)
    check("receipt + game addMoney: APPLIED, money/statistic/counter/hero/HUD total each once", receipt.status == "APPLIED"
        and FARMS[1].money == 1250 and FARMS[1].stats.finances.soldAnimals == 250 and FARMS[1].stats.financesVersionCounter == 1
        and FARMS[1].stats.moneyEarnedHeroAccum == 250 and mission.moneyChanges[7][1] == nil and NOTIFIED[#NOTIFIED].amount == 250
        and receipt.delta.counter == 1)
    receipt = S.apply(payments, { paymentId = "p2", kind = "SALE", farmId = 0, amount = 5, moneyType = MoneyType.SOLD_ANIMALS }, mission)
    check("receipt: spectator farm refused before the call (the game would return quietly)", receipt.status == "NOT_APPLIED"
        and has(receipt.evidence, "NOT_CALLED") and FARMS[1].money == 1250)
    receipt = S.apply(payments, { paymentId = "p3", kind = "SALE", farmId = 9, amount = 5, moneyType = MoneyType.SOLD_ANIMALS }, mission)
    check("receipt: no such farm refused before the call", receipt.status == "NOT_APPLIED" and has(receipt.evidence, "NO_FARM"))
    receipt = S.apply(payments, { paymentId = "p4", kind = "SALE", farmId = 1, amount = 0 / 0, moneyType = MoneyType.SOLD_ANIMALS }, mission)
    check("receipt: a bad amount is never passed to addMoney", receipt.status == "NOT_APPLIED" and FARMS[1].money == 1250)
    receipt = S.apply(payments, { paymentId = "p5", kind = "SALE", farmId = 1, amount = 5, moneyType = { id = 99, statistic = "nope" } }, mission)
    check("receipt: a money type without a farm statistic refused before the call", receipt.status == "NOT_APPLIED"
        and has(receipt.evidence, "STATISTIC_UNKNOWN"))
    mission.moneyChanges[7] = { [1] = 30 }   -- another change still waiting for the HUD
    receipt = S.apply(payments, { paymentId = "p1b", kind = "SALE", farmId = 1, amount = 20, moneyType = MoneyType.SOLD_ANIMALS }, mission)
    check("receipt: a pending HUD total is sent with it and cleared, as the game does -> APPLIED", receipt.status == "APPLIED"
        and NOTIFIED[#NOTIFIED].amount == 50 and mission.moneyChanges[7][1] == nil and FARMS[1].money == 1270)
    FARMS[1].money = 1250
    farmLookupFault = 2   -- the lookup inside addMoney throws, the receipt's own reads do not
    receipt = S.apply(payments, { paymentId = "p6", kind = "SALE", farmId = 1, amount = 5, moneyType = MoneyType.SOLD_ANIMALS }, mission)
    check("receipt: the game's own farm lookup throws -> NOT_APPLIED (no step)", receipt.status == "NOT_APPLIED"
        and receipt.evidence == "THREW_BEFORE_ANY_STEP" and FARMS[1].money == 1250)
    hudFault = true
    receipt = S.apply(payments, { paymentId = "p7", kind = "WAGE", farmId = 1, amount = -40, moneyType = MoneyType.HERDSMAN_WAGES }, mission)
    check("receipt: the HUD throws after every step -> APPLIED with the error kept", receipt.status == "APPLIED"
        and receipt.callError ~= nil and FARMS[1].money == 1210 and FARMS[1].stats.finances.herdsmanWages == -40)
    local savedServer = mission.getIsServer
    mission.getIsServer = function() return false end
    receipt = S.apply(payments, { paymentId = "p8", kind = "SALE", farmId = 1, amount = 5, moneyType = MoneyType.SOLD_ANIMALS }, mission)
    mission.getIsServer = savedServer
    check("receipt: not on the server -> refused before the call", receipt.status == "NOT_APPLIED" and FARMS[1].money == 1210)
    local reentered
    moneyListener = function()
        moneyListener = nil
        reentered = select(2, S.apply(payments, { paymentId = "p9", kind = "SALE", farmId = 1, amount = 5, moneyType = MoneyType.SOLD_ANIMALS }, mission))
    end
    receipt = S.apply(payments, { paymentId = "p9", kind = "SALE", farmId = 1, amount = 5, moneyType = MoneyType.SOLD_ANIMALS }, mission)
    check("receipt: the same paymentId re-entered during its own call is not paid twice", reentered == "REPLAY"
        and receipt.status == "APPLIED" and FARMS[1].money == 1215)
    check("receipt: no object references kept", (function()
        for _, r in pairs(payments) do for _, v in pairs(r) do
            if type(v) == "table" then for _, w in pairs(v) do if type(w) == "table" or type(w) == "function" then return false end end
            elseif type(v) == "function" then return false end
        end end
        return true
    end)())
end

-- ===========================================================================================
-- The world: a pen or trailer filled through the real queue and flush
-- ===========================================================================================

local serial = 0
local function animal(price, fee, fields)
    serial = serial + 1
    local a = setmetatable({ isIndividual = true, numAnimals = 1, farmId = "1001", uniqueId = tostring(20000 + serial),
        birthday = { country = 1, day = 3 }, subTypeIndex = 1, animalTypeIndex = 1, gender = "male", age = 18, weight = 640,
        targetWeight = 1000, health = 100, genetics = { quality = 1.1, metabolism = 1 }, bodyCondition = { reserve = 0.5 },
        monitor = { active = true }, isDead = false, isSold = false, price = price, fee = fee }, { __index = Animal })
    for k, v in pairs(fields or {}) do a[k] = v end
    return a
end
local function keyOf(a) return RLAnimalUtil.toKey(a.farmId, a.uniqueId, a.birthday.country) end

local penSerial = 0
local function newSource(kind, farmId, animals)
    penSerial = penSerial + 1
    local source = { uniqueId = "pen" .. penSerial, isServer = true, messages = {} }
    local husbandryId = 80 + penSerial
    local visuals = { husbandryIds = { [1] = husbandryId }, husbandryIdsToVisualAnimalCount = { [husbandryId] = 0 },
        visualAnimalCount = 0, animalIdToCluster = { [1] = {} }, nextId = 0 }
    source.visuals = visuals
    if kind == "PEN" then
        source.spec_husbandryAnimals = { clusterHusbandry = visuals }
        -- Engine stand-in: every member without a visual animal gets a new one; ids are never reused.
        function source.spec_husbandryAnimals:updateVisualAnimals()
            if source.visualFault then source.visualFault = nil error("visual update failed") end
            for _, member in ipairs(source.clusterSystem.animals) do
                if member.idFull == nil then
                    visuals.nextId = visuals.nextId + 1
                    member.idFull = husbandryId .. "-" .. visuals.nextId
                    member.id = member.idFull
                    visuals.husbandryIdsToVisualAnimalCount[husbandryId] = visuals.husbandryIdsToVisualAnimalCount[husbandryId] + 1
                    visuals.visualAnimalCount = visuals.visualAnimalCount + 1
                    visuals.animalIdToCluster[1][visuals.nextId] = member
                end
            end
        end
        function source:addRLMessage(id, _, args)
            if self.messageFault then self.messageFault = nil error("message failed") end
            self.messages[#self.messages + 1] = { id = id, args = args }
        end
    else
        source.spec_livestockTrailer = {}
    end
    function source:getName() return kind .. self.uniqueId end
    function source:raiseActive() end
    function source:getOwnerFarmId() return farmId end
    function source:getClusterSystem() return self.clusterSystem end
    function source:getClusterById(id) return self.clusterSystem:getClusterById(id) end
    function source:getNumOfFreeAnimalSlots() return self.freeSlots or 10 end
    function source:addAnimals(list) self.added = (self.added or 0) + #list end
    source.clusterSystem = AnimalClusterSystem.new(true, source)
    -- One flush per animal: the pen's order is the list's (the add queue is a set).
    for _, a in ipairs(animals) do
        source.clusterSystem:addPendingAddCluster(a)
        source.clusterSystem:updateNow()
    end
    return source
end

local function members(source)
    local keys = {}
    for _, a in ipairs(source.clusterSystem.animals) do keys[#keys + 1] = keyOf(a) end
    table.sort(keys)
    return table.concat(keys, ",")
end

local function ids(animals)
    local list = {}
    for i, a in ipairs(animals) do
        list[i] = { farmId = a.farmId, uniqueId = a.uniqueId, country = a.birthday.country,
            birthday = { country = a.birthday.country }, animalTypeIndex = a.animalTypeIndex }
    end
    return list
end

-- The farm's money as the engine keeps it: balance, the statistic, the HUD total.
-- The farm's money as the engine keeps it: balance, the statistic, the money changes sent to it.
local function wallet(farmId, statistic)
    local farm, moneyType = FARMS[farmId], MoneyType[statistic or "SOLD_ANIMALS"]
    local sent = 0
    for _, n in ipairs(NOTIFIED) do
        if n.farmId == farmId and n.statistic == moneyType.statistic then sent = sent + n.amount end
    end
    return farm.money, farm.stats.finances[moneyType.statistic], sent
end

local function resetAll()
    RLContractTrade.reset()
    LS.reset()
    LS.setMode("TEST")
    mission.addMoney = baseAddMoney
    mission.moneyChanges = {}
    NOTIFIED = {}
    moneyListener, clusterListener, removalFaultAt, farmLookupFault, hudFault, notifyFault = nil, nil, nil, nil, nil, nil
    setFarm(1, 1000)
    setFarm(2, 1000)
    LOG = {}
end

-- The player's sale through the real AnimalSellEvent:run, as the server receives it.
local function sell(source, list, user, sentFault)
    local sent = {}
    local connection = makeConnection(user or "alice", false, sent)
    if sentFault then connection.sendEvent = function() error("reply failed") end end
    AnimalSellEvent.new(source, list, 1, 0):run(connection)
    return sent[1] and sent[1].errorCode, #sent
end

local function lastRecord()
    local best
    for _, r in pairs(LS.ledger().records) do if best == nil or r.sequence > best.sequence then best = r end end
    return best
end

-- ===========================================================================================
-- S01: the player's and the herdsman's normal sale, each with its own fee sign
-- ===========================================================================================

do
    resetAll()
    local a, b, c = animal(1000, 40), animal(800, 30), animal(600, 20)
    local pen = newSource("PEN", 1, { a, b, c })
    local code, replies = sell(pen, ids({ a, b }))
    local record = lastRecord()
    local money, stat, hud = wallet(1)
    check("S01 player two heads: SUCCESS, one reply", code == AnimalSellEvent.SELL_SUCCESS and replies == 1)
    check("S01 player two heads: paid (1000-40)+(800-30) once, statistic and the money change sent match",
        money == 1000 + 960 + 770 and stat == 1730 and hud == 1730 and count(LS.ledger().payments) == 1)
    check("S01 player two heads: COMMITTED, receipt APPLIED with all steps, locks released",
        record.state == "COMMITTED" and record.sale.payment == "APPLIED" and record.sale.amount == 1730
        and next(LS.ledger().locks) == nil and LS.ledger().payments[record.sale.paymentId].evidence == "ALL_STEPS")
    check("S01 player two heads: left through the real flush, the third stays with its visual",
        members(pen) == keyOf(c) and a.clusterSystem == nil and c.idFull ~= nil and pen.visuals.visualAnimalCount == 1)
    check("S01 player two heads: message from the paid amount", pen.messages[1].id == "SOLD_ANIMALS_MULTIPLE"
        and pen.messages[1].args[1] == 2 and pen.messages[1].args[2] == "1730.00")

    -- The same amount as the old path, bit for bit: the same accumulation order.
    local x, y, z = animal(0.1, 0.07), animal(0.2, 0.01), animal(1e16, 1.5)
    local pen2 = newSource("PEN", 1, { x, y, z })
    local oldCredit = 0
    for _, h in ipairs({ x, y, z }) do oldCredit = oldCredit + h.price - h.fee end
    local before = FARMS[1].money
    sell(pen2, ids({ x, y, z }))
    check("S01 player: the paid amount is the old path's credit + price - fee, bit for bit",
        lastRecord().sale.amount == oldCredit and FARMS[1].money == before + oldCredit)

    -- The herdsman: price plus fee, through executeServer.
    resetAll()
    local h1, h2 = animal(1000, 40), animal(800, 30)
    local pen3 = newSource("PEN", 1, { h1, h2 })
    local r = AIAnimalSellEvent.executeServer(pen3, ids({ h1, h2 }), 1, { server = g_server, mission = mission }, "hrX-a1")
    money, stat = wallet(1)
    check("S01 herdsman two heads: SOLD, paid (1000+40)+(800+30)", r.status == "sold" and r.settledCount == 2
        and r.removedCount == 2 and r.amountGained == 1870 and money == 2870 and stat == 1870 and r.txState == "COMMITTED")
    check("S01 herdsman: the network event class is not used, the id is the round's", LS.ledger().records["hrX-a1"] ~= nil)
end

-- ===========================================================================================
-- S02: known partial removal
-- ===========================================================================================

do
    resetAll()
    local a, b, c = animal(1000, 40), animal(800, 30), animal(600, 20)
    local pen = newSource("PEN", 1, { a, b, c })
    removalFaultAt = visualRemovals + 2   -- the flush removes the last-indexed one, then throws
    local code = sell(pen, ids({ a, b, c }))
    local record = lastRecord()
    check("S02 player partial: reply is the old failure code, no message", code == AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST
        and #pen.messages == 0)
    check("S02 player partial: COMMITTED_PARTIAL, paid only the one that left (600-20)", record.state == "COMMITTED_PARTIAL"
        and #record.sale.removed == 1 and record.sale.removed[1] == keyOf(c) and record.sale.amount == 580 and FARMS[1].money == 1580)
    check("S02 player partial: survivors stay, unqueued, locks released", members(pen) == table.concat({ keyOf(a), keyOf(b) }, ",")
        and next(pen.clusterSystem.clustersToRemove) == nil and next(LS.ledger().locks) == nil)
    pen.clusterSystem:updateNow()
    check("S02 player partial: a later flush removes nothing unpaid", members(pen) == table.concat({ keyOf(a), keyOf(b) }, ","))
    check("S02 player partial: reason names the flush", has(record.reason, "FLUSH_THREW"))

    resetAll()
    local d, e = animal(1000, 40), animal(500, 10)
    local pen2 = newSource("PEN", 1, { d, e })
    removalFaultAt = visualRemovals + 2
    local r = AIAnimalSellEvent.executeServer(pen2, ids({ d, e }), 1, { server = g_server, mission = mission }, "hrP-a1")
    check("S02 herdsman partial: PARTIAL at flush, settled 1 for 510", r.status == "partial" and r.failureStage == "flush"
        and r.removedCount == 1 and r.settledCount == 1 and r.amountGained == 510 and FARMS[1].money == 1510)

    -- Everything left but the visual update threw afterwards: paid in full; reported as before
    -- (the player gets the failure code, the herdsman PARTIAL at flush), never paid twice.
    resetAll()
    local f, g = animal(1000, 40), animal(500, 10)
    local pen3 = newSource("PEN", 1, { f, g })
    pen3.visualFault = true
    code = sell(pen3, ids({ f, g }))
    record = lastRecord()
    check("S02 all left, flush threw after: COMMITTED with the flush error kept, paid 1450 once",
        record.state == "COMMITTED" and has(record.reason, "FLUSH_THREW") and FARMS[1].money == 2450
        and code == AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST and #pen3.messages == 0)
    resetAll()
    local f2, g2 = animal(1000, 40), animal(500, 10)
    local pen4 = newSource("PEN", 1, { f2, g2 })
    pen4.visualFault = true
    local r2 = AIAnimalSellEvent.executeServer(pen4, ids({ f2, g2 }), 1, { server = g_server, mission = mission }, "hrV-a1")
    check("S02 herdsman, all left, flush threw after: PARTIAL at flush as before, settled 2 for 1550",
        r2.status == "partial" and r2.failureStage == "flush" and r2.settledCount == 2 and r2.amountGained == 1550
        and FARMS[1].money == 2550)
end

-- ===========================================================================================
-- S03: the removal cannot be read
-- ===========================================================================================

do
    resetAll()
    local a, b = animal(1000, 40), animal(800, 30)
    local pen = newSource("PEN", 1, { a, b })
    local cs = pen.clusterSystem
    clusterListener = function() cs.getClusters = function() error("list unreadable") end end
    local code = sell(pen, ids({ a }))
    clusterListener = nil
    local record = lastRecord()
    check("S03 list unreadable: NEEDS_RECONCILIATION as SOURCE_UNKNOWN, nothing paid", record.state == "NEEDS_RECONCILIATION"
        and has(record.reason, "SOURCE_UNKNOWN") and FARMS[1].money == 1000 and count(LS.ledger().payments) == 0)
    check("S03 list unreadable: locks held, failure code", LS.ledger().locks["animal:" .. keyOf(a)] == record.id
        and LS.ledger().locks["cash:farm1"] == record.id and code == AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST)
    cs.getClusters = nil
    check("S03 list unreadable: nothing removed again, nothing put back", #cs.animals == 1 and next(cs.clustersToRemove) == nil)
    -- A second request for the same animal while it awaits reconciliation.
    local b2 = animal(10, 1)
    local other = newSource("PEN", 1, { b2 })
    code = sell(pen, ids({ b }))
    check("S03 held: another sale from the same pen is refused (source lock)", code == AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD
        and #cs.animals == 1)
    code = sell(other, ids({ b2 }))
    check("S03 held: the farm's cash lock refuses its next sale too (conservative)", code == AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD)

    -- A member outside the batch changed during the flush: the effects cannot be attributed.
    resetAll()
    local c, d, stranger = animal(1000, 40), animal(800, 30), animal(5, 1)
    local pen2 = newSource("PEN", 1, { c, d })
    clusterListener = function() table.insert(pen2.clusterSystem.animals, stranger) end
    local r = AIAnimalSellEvent.executeServer(pen2, ids({ c }), 1, { server = g_server, mission = mission }, "hrU-a1")
    clusterListener = nil
    check("S03 member outside the batch changed: herdsman FAILED at verify, removal unknown, nothing paid",
        r.status == "failed" and r.failureStage == "verify" and r.removedCount == nil and r.settledCount == 0
        and r.amountGained == 0 and FARMS[1].money == 1000 and r.txState == "NEEDS_RECONCILIATION")

    -- A stale id index after a failed flush points the removed animal's key at another one; the
    -- removal is read by object, so the removed one is the one paid.
    resetAll()
    local e, f, g = animal(1000, 40), animal(2000, 40), animal(500, 40)
    local pen3 = newSource("PEN", 1, { e, f, g })
    -- f (index 2) and g (3) are queued; the flush removes g, then throws on f.
    removalFaultAt = visualRemovals + 2
    sell(pen3, ids({ f, g }))
    record = lastRecord()
    check("S03 stale index: only the animal that left is paid (500-40)", record.state == "COMMITTED_PARTIAL"
        and record.sale.removed[1] == keyOf(g) and record.sale.amount == 460 and FARMS[1].money == 1460)
end

-- ===========================================================================================
-- S04: refused before the money call -> NOT_APPLIED -> the very animals put back
-- ===========================================================================================

do
    resetAll()
    local a, b, c = animal(1000, 40), animal(800, 30), animal(600, 20)
    local pen = newSource("PEN", 1, { a, b, c })
    local genetics, weight = a.genetics, a.weight
    -- The farm disappears between the preparation and the money: settlement refuses before calling.
    clusterListener = function() FARMS[1] = nil end
    local code = sell(pen, ids({ a, b }))
    clusterListener = nil
    local record = lastRecord()
    local payment = LS.ledger().payments[record.sale.paymentId]
    setFarm(1, 1000)
    check("S04 not called: receipt NOT_APPLIED (NOT_CALLED), ROLLED_BACK", payment.status == "NOT_APPLIED"
        and has(payment.evidence, "NOT_CALLED") and record.state == "ROLLED_BACK" and record.reason == "SETTLEMENT_NOT_APPLIED")
    check("S04 not called: the same animal objects back, fields kept, new visual ids",
        members(pen) == table.concat({ keyOf(a), keyOf(b), keyOf(c) }, ",") and a.clusterSystem == pen.clusterSystem
        and a.genetics == genetics and a.weight == weight and a.idFull ~= nil and pen.visuals.visualAnimalCount == 3)
    check("S04 not called: failure reply, locks released, restored subset recorded", code == AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST
        and next(LS.ledger().locks) == nil and #record.sale.restored == 2)

    -- Another mod's wrapper throws before the game's addMoney ran: no step seen -> put back.
    resetAll()
    local d = animal(1000, 40)
    local pen2 = newSource("PEN", 1, { d })
    mission.addMoney = function() error("wrapper refused") end
    local r = AIAnimalSellEvent.executeServer(pen2, ids({ d }), 1, { server = g_server, mission = mission }, "hrN-a1")
    mission.addMoney = baseAddMoney
    check("S04 threw before any step: herdsman FAILED at payment, animal back, removedCount 0 with original 1 / restored 1",
        r.status == "failed" and r.failureStage == "payment" and r.removedCount == 0 and r.originalRemovedCount == 1
        and r.restoredCount == 1 and r.settledCount == 0 and r.amountGained == 0 and members(pen2) == keyOf(d)
        and r.paymentStatus == "NOT_APPLIED" and FARMS[1].money == 1000)

    -- Nothing left at all (the queue threw): nothing to pay, queue cleared.
    resetAll()
    local e, f = animal(1000, 40), animal(800, 30)
    local pen3 = newSource("PEN", 1, { e, f })
    local queued = 0
    pen3.clusterSystem.addPendingRemoveCluster = function(self, cluster)
        queued = queued + 1
        if queued == 2 then error("queue failed") end
        return AnimalClusterSystem.addPendingRemoveCluster(self, cluster)
    end
    r = AIAnimalSellEvent.executeServer(pen3, ids({ e, f }), 1, { server = g_server, mission = mission }, "hrQ-a1")
    pen3.clusterSystem.addPendingRemoveCluster = nil
    check("S04 queue threw: nothing removed or paid, queue cleared, FAILED at queue (old stage)", r.status == "failed"
        and r.failureStage == "queue" and r.removedCount == 0 and r.settledCount == 0 and count(LS.ledger().payments) == 0
        and next(pen3.clusterSystem.clustersToRemove) == nil and #pen3.clusterSystem.animals == 2 and r.txState == "ROLLED_BACK")
    pen3.clusterSystem:updateNow()
    check("S04 queue threw: a later flush removes nothing", #pen3.clusterSystem.animals == 2)
end

-- ===========================================================================================
-- S05 / S06: money faults and unreadable receipts
-- ===========================================================================================

do
    -- A MONEY_CHANGED listener throws: money and statistics moved, the HUD total did not.
    resetAll()
    local a, b = animal(1000, 40), animal(800, 30)
    local pen = newSource("PEN", 1, { a, b })
    moneyListener = function() error("listener failed") end
    local code = sell(pen, ids({ a }))
    moneyListener = nil
    local record = lastRecord()
    local payment = LS.ledger().payments[record.sale.paymentId]
    check("S05 listener threw mid-call: UNKNOWN, NEEDS_RECONCILIATION, locks held", payment.status == "UNKNOWN"
        and record.state == "NEEDS_RECONCILIATION" and has(record.reason, "SETTLEMENT_UNKNOWN")
        and LS.ledger().locks["cash:farm1"] == record.id)
    check("S05 listener threw: money moved once, no refund, no resurrection, no second call", FARMS[1].money == 1960
        and members(pen) == keyOf(b) and payment.callError ~= nil and payment.steps.money and not payment.steps.change)
    local again = LS.ledger().payments[record.sale.paymentId]
    local _, replay = S.apply(LS.ledger().payments, { paymentId = record.sale.paymentId, kind = "SALE", farmId = 1, amount = 960,
        moneyType = MoneyType.SOLD_ANIMALS }, mission)
    check("S05 the same paymentId is never attempted again", replay == "REPLAY" and FARMS[1].money == 1960 and again.status == "UNKNOWN")
    check("S05 player told it failed", code == AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST and #pen.messages == 0)

    -- The HUD / notification throws after every step: the money stands, committed once.
    resetAll()
    local c = animal(1000, 40)
    local pen2 = newSource("PEN", 1, { c })
    notifyFault = true
    code = sell(pen2, ids({ c }))
    record = lastRecord()
    payment = LS.ledger().payments[record.sale.paymentId]
    check("S05 notification threw after all steps: APPLIED, COMMITTED, paid once", payment.status == "APPLIED"
        and payment.evidence == "THREW_AFTER_ALL_STEPS" and record.state == "COMMITTED" and FARMS[1].money == 1960
        and code == AnimalSellEvent.SELL_SUCCESS)

    -- A listener moves the same farm's money as well: the delta is not this payment's alone.
    resetAll()
    local d = animal(1000, 40)
    local pen3 = newSource("PEN", 1, { d })
    moneyListener = function() moneyListener = nil baseAddMoney(mission, 5, 1, MoneyType.OTHER, true, false) end
    local r = AIAnimalSellEvent.executeServer(pen3, ids({ d }), 1, { server = g_server, mission = mission }, "hrL-a1")
    check("S05/S09 another money change inside the call: UNKNOWN, amount unknown, not refunded",
        r.status == "failed" and r.failureStage == "payment" and r.settledCount == nil and r.amountGained == nil
        and r.removedCount == 1 and FARMS[1].money == 1000 + 1040 + 5)

    -- A wrapper that swallows the call: returned, no step -> UNKNOWN, never assumed unpaid.
    resetAll()
    local e = animal(1000, 40)
    local pen4 = newSource("PEN", 1, { e })
    mission.addMoney = function() end
    sell(pen4, ids({ e }))
    mission.addMoney = baseAddMoney
    record = lastRecord()
    check("S05 call returned without any step: UNKNOWN, animal not put back", record.state == "NEEDS_RECONCILIATION"
        and record.sale.payment == "UNKNOWN" and #pen4.clusterSystem.animals == 0)

    -- S06: the receipt fields cannot be read after the call.
    resetAll()
    local f = animal(1000, 40)
    local pen5 = newSource("PEN", 1, { f })
    moneyListener = function(farmId) moneyListener = nil FARMS[farmId].stats.financesVersionCounter = "gone" end
    sell(pen5, ids({ f }))
    record = lastRecord()
    payment = LS.ledger().payments[record.sale.paymentId]
    check("S06 receipt unreadable after the call: UNKNOWN (UNREADABLE_AFTER), held", payment.status == "UNKNOWN"
        and has(payment.evidence, "UNREADABLE_AFTER") and record.state == "NEEDS_RECONCILIATION")

    -- S06: a receipt already under this paymentId (not this sale's) is never taken as this payment.
    resetAll()
    local g = animal(1000, 40)
    local pen6 = newSource("PEN", 1, { g })
    LS.ledger().payments["pay:ls1-f1"] = { paymentId = "pay:ls1-f1", kind = "SALE", farmId = 2, amount = 7, status = "APPLIED" }
    sell(pen6, ids({ g }))
    record = lastRecord()
    check("S06 a foreign receipt under the id: not paid, not taken as APPLIED -> held", record.id == "ls1-f1"
        and record.state == "NEEDS_RECONCILIATION" and record.sale.payment == "UNKNOWN" and FARMS[1].money == 1000)

    -- S06: the farm's statistic is missing at preparation: refused before anything moves.
    resetAll()
    local h = animal(1000, 40)
    local pen7 = newSource("PEN", 1, { h })
    FARMS[1].stats.finances.soldAnimals = nil
    code = sell(pen7, ids({ h }))
    check("S06 no receipt possible: refused before removal", code == AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST
        and #pen7.clusterSystem.animals == 1 and count(LS.ledger().records) == 0)
end

-- ===========================================================================================
-- S07: putting the subset back fails or is incomplete
-- ===========================================================================================

do
    resetAll()
    local a, b, c = animal(1000, 40), animal(800, 30), animal(600, 20)
    local pen = newSource("PEN", 1, { a, b, c })
    removalFaultAt = visualRemovals + 2   -- c leaves, then the flush throws: a, b stay
    mission.addMoney = function() error("wrapper refused") end
    sell(pen, ids({ a, b, c }))
    mission.addMoney = baseAddMoney
    local record = lastRecord()
    check("S07 partial + NOT_APPLIED: only the one that left is put back, nothing duplicated",
        record.state == "ROLLED_BACK" and #pen.clusterSystem.animals == 3
        and members(pen) == table.concat({ keyOf(a), keyOf(b), keyOf(c) }, ",") and #record.sale.restored == 1)

    resetAll()
    local d, e = animal(1000, 40), animal(800, 30)
    local pen2 = newSource("PEN", 1, { d, e })
    mission.addMoney = function() error("wrapper refused") end
    -- The re-add's flush throws (visual update) after putting the animal back.
    local flushes = 0
    clusterListener = function()
        flushes = flushes + 1
        if flushes == 2 then pen2.visualFault = true end
    end
    sell(pen2, ids({ d }))
    mission.addMoney, clusterListener = baseAddMoney, nil
    record = lastRecord()
    check("S07 re-add flush threw: not reported ROLLED_BACK, held for reconciliation", record.state == "NEEDS_RECONCILIATION"
        and has(record.reason, "SOURCE_RESTORE_UNKNOWN") and LS.ledger().locks["animal:" .. keyOf(d)] == record.id)
    local present = 0
    for _, m in ipairs(pen2.clusterSystem.animals) do if m == d then present = present + 1 end end
    check("S07 re-add flush threw: the animal is in the pen once, never added twice, nothing paid", present == 1
        and FARMS[1].money == 1000)

    -- Fields changed during the put-back are not reported as restored.
    resetAll()
    local f = animal(1000, 40)
    local pen3 = newSource("PEN", 1, { f })
    mission.addMoney = function() f.weight = 1 error("wrapper refused") end
    sell(pen3, ids({ f }))
    mission.addMoney = baseAddMoney
    record = lastRecord()
    check("S07 put back with a changed field: NEEDS_RECONCILIATION, not ROLLED_BACK", record.state == "NEEDS_RECONCILIATION")
end

-- ===========================================================================================
-- S08: replays, collisions, resales
-- ===========================================================================================

do
    resetAll()
    local a, b = animal(1000, 40), animal(800, 30)
    local pen = newSource("PEN", 1, { a, b })
    removalFaultAt = visualRemovals + 2
    local ctx = { server = g_server, mission = mission }
    local first = AIAnimalSellEvent.executeServer(pen, ids({ a, b }), 1, ctx, "hrR-a1")
    local moneyAfter = FARMS[1].money
    local again = AIAnimalSellEvent.executeServer(pen, ids({ a, b }), 1, ctx, "hrR-a1")
    check("S08 partial replay: the first result again, marked replayed, nothing sold or paid", again.replayed == true
        and again.status == first.status and again.settledCount == 1 and again.amountGained == first.amountGained
        and FARMS[1].money == moneyAfter and #pen.clusterSystem.animals == 1 and count(LS.ledger().payments) == 1)
    check("S08 partial replay: the record stays COMMITTED_PARTIAL", LS.ledger().records["hrR-a1"].state == "COMMITTED_PARTIAL")
    local changed = AIAnimalSellEvent.executeServer(pen, ids({ a }), 1, ctx, "hrR-a1")
    check("S08 same id, other payload: refused as a collision", changed.status == "refused" and changed.failureStage == "replay"
        and FARMS[1].money == moneyAfter)
    local other = AIAnimalSellEvent.executeServer(pen, ids({ b }), 1, ctx, "hrR-a2")
    check("S08 another id for the animal that left: refused at identity", other.status == "refused" and other.failureStage == "identity")

    -- The player sends the same request twice.
    resetAll()
    local c = animal(1000, 40)
    local pen2 = newSource("PEN", 1, { c })
    sell(pen2, ids({ c }))
    local code = sell(pen2, ids({ c }))
    check("S08 player repeat: refused, paid once", code == AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER and FARMS[1].money == 1960
        and count(LS.ledger().payments) == 1)
end

-- ===========================================================================================
-- S09: re-entry during the money call; unrelated money outside the call
-- ===========================================================================================

do
    resetAll()
    local a, b = animal(1000, 40), animal(800, 30)
    local pen = newSource("PEN", 1, { a, b })
    local inner
    moneyListener = function()
        moneyListener = nil
        inner = { sell(pen, ids({ b })) }
    end
    sell(pen, ids({ a }))
    check("S09 re-entrant sale of the same pen during the money call: refused (lock), not sold",
        inner[1] == AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD and members(pen) == keyOf(b))

    resetAll()
    local c = animal(1000, 40)
    local pen2 = newSource("PEN", 1, { c })
    -- A legitimate change of the farm's money during the flush, before the payment.
    clusterListener = function() clusterListener = nil baseAddMoney(mission, -300, 1, MoneyType.OTHER, true, false) end
    sell(pen2, ids({ c }))
    local record = lastRecord()
    check("S09 money changed before the call (not inside it): the receipt still APPLIED, both stand",
        record.state == "COMMITTED" and record.sale.payment == "APPLIED" and FARMS[1].money == 1000 - 300 + 960)
end

-- ===========================================================================================
-- S10: zero and negative totals, bad numbers
-- ===========================================================================================

do
    resetAll()
    local a = animal(40, 40)
    local pen = newSource("PEN", 1, { a })
    local code = sell(pen, ids({ a }))
    local record = lastRecord()
    local _, stat, hud = wallet(1)
    check("S10 zero net: paid 0 as the old path (proven by the statistic counter, a 0 change sent), COMMITTED",
        code == AnimalSellEvent.SELL_SUCCESS and record.sale.amount == 0 and record.sale.payment == "APPLIED"
        and FARMS[1].money == 1000 and stat == 0 and hud == 0)

    resetAll()
    local b = animal(10, 40)
    local pen2 = newSource("PEN", 1, { b })
    code = sell(pen2, ids({ b }))
    record = lastRecord()
    check("S10 negative net: -30 charged as the old path, no abs or clamp", code == AnimalSellEvent.SELL_SUCCESS
        and record.sale.amount == -30 and FARMS[1].money == 970 and FARMS[1].stats.moneyEarnedHeroAccum == 0)

    resetAll()
    for _, case in ipairs({ { "NaN price", 0 / 0 }, { "infinite price", math.huge }, { "negative price", -5 } }) do
        local c = animal(case[2], 40)
        local p = newSource("PEN", 1, { c })
        code = sell(p, ids({ c }))
        check("S10 " .. case[1] .. ": refused by the server quote, nothing recorded", code == AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD
            and #p.clusterSystem.animals == 1 and count(LS.ledger().records) == 0)
    end
    local big1, big2 = animal(1.7e308, 0), animal(1.7e308, 0)
    local bigPen = newSource("PEN", 1, { big1, big2 })
    local r = AIAnimalSellEvent.executeServer(bigPen, ids({ big1, big2 }), 1, { server = g_server, mission = mission }, "hrB-a1")
    check("S10 total overflows: refused at price, nothing touched", r.status == "refused" and r.failureStage == "price"
        and #bigPen.clusterSystem.animals == 2)
end

-- ===========================================================================================
-- S11: the reply or a message fails after the sale
-- ===========================================================================================

do
    resetAll()
    local a = animal(1000, 40)
    local pen = newSource("PEN", 1, { a })
    pen.messageFault = true
    local code = sell(pen, ids({ a }))
    local record = lastRecord()
    check("S11 message failed after the sale: SUCCESS still sent, paid once, failure noted", code == AnimalSellEvent.SELL_SUCCESS
        and record.state == "COMMITTED" and FARMS[1].money == 1960 and has(record.notificationError, "message failed"))

    resetAll()
    local b = animal(1000, 40)
    local pen2 = newSource("PEN", 1, { b })
    local _, replies = sell(pen2, ids({ b }), "alice", true)
    record = lastRecord()
    check("S11 reply failed: the sale stands, paid once, no second reply attempt that sells", record.state == "COMMITTED"
        and FARMS[1].money == 1960 and count(LS.ledger().payments) == 1 and replies == 0)
end

-- ===========================================================================================
-- S12: the network never moves money or the ledger
-- ===========================================================================================

do
    resetAll()
    local a = animal(1000, 40)
    local pen = newSource("PEN", 1, { a })
    for _, case in ipairs({ { "from a client", makeConnection("alice", false) }, { "from the server", makeConnection(nil, true) } }) do
        wireQueue = { pen, 1, ids({ a })[1], 99999 }
        local event = AIAnimalSellEvent.emptyNew()
        event:readStream(1, case[2])
        check("S12 AI sell event " .. case[1] .. " in TEST: nothing sold, no record", #pen.clusterSystem.animals == 1
            and count(LS.ledger().records) == 0 and FARMS[1].money == 1000)
    end
    local savedServer = mission.getIsServer
    mission.getIsServer = function() return false end
    check("S12 console on a client: sale mode and report refuse", has(RLTradeReportConsole:saleMode("OFF"), "server only")
        and has(RLTradeReportConsole:txReport(), "server only") and LS.getMode() == "TEST")
    mission.getIsServer = savedServer
end

-- ===========================================================================================
-- S13-S16: the herdsman executor, its wage and what follows a sale
-- ===========================================================================================

local function execCtx(placeables, roundId)
    return { server = g_server, mission = mission, husbandryPlaceablesById = placeables, ruleService = {},
        animalNameSystem = {}, defer = function() end, roundId = roundId }
end
local function sellAction(animals, opts)
    opts = opts or {}
    local action = { ruleId = "r1", operation = "sell", husbandryId = opts.pen or "pen1", animals = animals, mark = opts.mark == true,
        wage = opts.wage or 50, amountGained = 1 }
    if not opts.mark then action.sellerFarmId, action.identities = opts.seller or 1, ids(animals) end
    return action
end
local function wages(farmId)
    return FARMS[farmId].stats.finances.herdsmanWages
end

do
    -- S13: owner changed, refused, failed, mark mode - wage rules as before.
    resetAll()
    local a = animal(1000, 40)
    local foreign = newSource("PEN", 2, { a })
    local summary = RLHerdsmanExecutor.executeActions({ sellAction({ a }) }, execCtx({ pen1 = foreign }))
    check("S13 owner changed: skipped, no wage, no record", summary.results[1].skipReason == "owner-changed"
        and wages(1) == 0 and wages(2) == 0 and count(LS.ledger().records) == 0)

    resetAll()
    local b = animal(1000, 40, { sick = true })
    local pen = newSource("PEN", 1, { b })
    summary = RLHerdsmanExecutor.executeActions({ sellAction({ b }) }, execCtx({ pen1 = pen }))
    check("S13 sale refused: wage charged once as its own action", summary.results[1].skipReason == "sale-refused"
        and wages(1) == -50 and summary.wageReceipts[1].status == "APPLIED" and FARMS[1].money == 950)

    resetAll()
    local c = animal(1000, 40)
    local pen2 = newSource("PEN", 1, { c })
    mission.addMoney = function(m, amount, farmId, moneyType, ...)
        if moneyType == MoneyType.SOLD_ANIMALS then error("wrapper refused") end
        return baseAddMoney(m, amount, farmId, moneyType, ...)
    end
    summary = RLHerdsmanExecutor.executeActions({ sellAction({ c }) }, execCtx({ pen2 = nil, pen1 = pen2 }))
    mission.addMoney = baseAddMoney
    check("S13 sale failed (put back): sale-failed, wage charged", summary.results[1].skipReason == "sale-failed"
        and wages(1) == -50 and #pen2.clusterSystem.animals == 1)

    resetAll()
    local d = animal(1000, 40)
    local pen3 = newSource("PEN", 1, { d })
    summary = RLHerdsmanExecutor.executeActions({ sellAction({ d }, { mark = true, wage = 10 }) }, execCtx({ pen1 = pen3 }))
    check("S13 mark mode: marked, nothing sold, mark wage", d.marked.AI_MANAGER_SELL == true and summary.results[1].skipReason == "mark-mode"
        and wages(1) == -10 and count(LS.ledger().records) == 0)

    -- S14: one round replayed; two rounds the same day; several actions for one farm.
    resetAll()
    local e, f = animal(1000, 40), animal(800, 30)
    local pen4 = newSource("PEN", 1, { e, f })
    local plan = { sellAction({ e }, { wage = 30 }), sellAction({ f }, { wage = 20 }) }
    local ctx = execCtx({ pen1 = pen4 }, "hrDay1")
    summary = RLHerdsmanExecutor.executeActions(plan, ctx)
    check("S14 several actions, one farm: one wage action for their sum", summary.wageReceipts[1].amount == -50
        and wages(1) == -50 and count(LS.ledger().payments) == 3 and summary.results[1].txId == "hrDay1-a1")
    local built = RLHerdsmanMessages.buildMessages(summary.results, function(v) return string.format("%.2f", v) end)
    local moneyAfter = FARMS[1].money
    local replay = RLHerdsmanExecutor.executeActions(plan, ctx)
    local rebuilt = RLHerdsmanMessages.buildMessages(replay.results, function(v) return string.format("%.2f", v) end)
    check("S14 the same round again: nothing sold, earned or charged, no message", FARMS[1].money == moneyAfter
        and wages(1) == -50 and replay.results[1].skipReason == "replayed" and replay.results[1].replayed == true
        and #rebuilt.records == 0 and #built.records == 2 and count(LS.ledger().payments) == 3)
    local g = animal(700, 10)
    pen4.clusterSystem:addPendingAddCluster(g)
    pen4.clusterSystem:updateNow()
    local second = RLHerdsmanExecutor.executeActions({ sellAction({ g }, { wage = 30 }) }, execCtx({ pen1 = pen4 }))
    check("S14 a second legitimate round the same day: its own wage, not merged", second.roundId ~= "hrDay1"
        and wages(1) == -80 and second.wageReceipts[1].paymentId ~= summary.wageReceipts[1].paymentId)

    -- S15: the wage call fails.
    resetAll()
    local h = animal(1000, 40)
    local pen5 = newSource("PEN", 1, { h })
    mission.addMoney = function(m, amount, farmId, moneyType, ...)
        if moneyType == MoneyType.HERDSMAN_WAGES then error("wage wrapper refused") end
        return baseAddMoney(m, amount, farmId, moneyType, ...)
    end
    ctx = execCtx({ pen1 = pen5 }, "hrW")
    summary = RLHerdsmanExecutor.executeActions({ sellAction({ h }) }, ctx)
    mission.addMoney = baseAddMoney
    check("S15 wage threw before any step: NOT_APPLIED recorded, the sale stands", summary.wageReceipts[1].status == "NOT_APPLIED"
        and summary.results[1].saleStatus == "sold" and FARMS[1].money == 2040 and wages(1) == 0)
    summary = RLHerdsmanExecutor.executeActions({ sellAction({ h }) }, ctx)
    check("S15 replaying that round: no second wage attempt, no resale", wages(1) == 0 and FARMS[1].money == 2040
        and summary.wageReceipts[1] == nil and summary.results[1].skipReason == "replayed"
        and LS.ledger().payments["wage:hrW:f1"].status == "NOT_APPLIED")

    resetAll()
    local i = animal(1000, 40)
    local pen6 = newSource("PEN", 1, { i })
    moneyListener = function(farmId, money)
        if money < 2000 then error("listener failed on the wage") end
    end
    summary = RLHerdsmanExecutor.executeActions({ sellAction({ i }) }, execCtx({ pen1 = pen6 }))
    moneyListener = nil
    check("S15 wage listener threw mid-call: UNKNOWN, not charged again, the sale untouched",
        summary.wageReceipts[1].status == "UNKNOWN" and summary.results[1].saleStatus == "sold" and FARMS[1].money == 2040 - 50)

    -- S16: what follows a sale.
    resetAll()
    local j = animal(1000, 40)
    local pen7 = newSource("PEN", 1, { j })
    moneyListener = function() moneyListener = nil error("listener failed") end
    local dealerCow = animal(100, 0)
    local buy = { ruleId = "r2", operation = "buy", husbandryId = "pen1", animals = { dealerCow }, amountSpent = 100, wage = 20 }
    summary = RLHerdsmanExecutor.executeActions({ sellAction({ j }), buy }, execCtx({ pen1 = pen7 }))
    check("S16 sale payment unknown, then a buy: the buy is skipped (cash held), nothing bought",
        summary.results[1].skipReason == "sale-failed" and summary.results[2].skipReason == "cash-held" and pen7.added == nil)

    resetAll()
    local k = animal(1000, 40)
    local pen8 = newSource("PEN", 1, { k })
    FARMS[1].money = 0
    buy.amountSpent = 900
    summary = RLHerdsmanExecutor.executeActions({ sellAction({ k }), buy }, execCtx({ pen1 = pen8 }))
    check("S16 sale paid, then a buy: the buy checks the real wallet and goes through", summary.results[1].saleStatus == "sold"
        and summary.results[2].dispatched == true)
    resetAll()
    local l = animal(1000, 40, { sick = true })
    local pen9 = newSource("PEN", 1, { l })
    FARMS[1].money = 0
    summary = RLHerdsmanExecutor.executeActions({ sellAction({ l }), buy }, execCtx({ pen1 = pen9 }))
    check("S16 sale refused, then a buy: refused for money on the real wallet", summary.results[2].skipReason == "no-money")
end

-- ===========================================================================================
-- S17: COMMITTED_PARTIAL and receipts through export / import
-- ===========================================================================================

do
    resetAll()
    local a, b = animal(1000, 40), animal(800, 30)
    local pen = newSource("PEN", 1, { a, b })
    removalFaultAt = visualRemovals + 2
    AIAnimalSellEvent.executeServer(pen, ids({ a, b }), 1, { server = g_server, mission = mission }, "hrE-a1")
    local c = animal(500, 10)
    local pen2 = newSource("PEN", 1, { c })
    moneyListener = function() moneyListener = nil error("listener failed") end
    AIAnimalSellEvent.executeServer(pen2, ids({ c }), 1, { server = g_server, mission = mission }, "hrE-a2")
    local data = T.export(LS.ledger())
    local loaded, why = T.import(data)
    check("S17 export/import: COMMITTED_PARTIAL kept, its locks not taken again", loaded ~= nil
        and loaded.records["hrE-a1"].state == "COMMITTED_PARTIAL" and loaded.locks["animal:" .. keyOf(a)] == nil, why)
    check("S17 export/import: the unknown sale still held, payments kept", loaded.records["hrE-a2"].state == "NEEDS_RECONCILIATION"
        and loaded.locks["cash:farm1"] == "hrE-a2" and loaded.payments["pay:hrE-a1"].status == "APPLIED"
        and loaded.payments["pay:hrE-a2"].status == "UNKNOWN" and #loaded.records["hrE-a1"].sale.removed == 1)
    local replay, reason = T.executeLiveSale(loaded, "hrE-a1", {})
    check("S17 a partial record after import: replay only, never PREPARED again", reason == "REPLAY" and replay.state == "COMMITTED_PARTIAL")
    data.payments["pay:hrE-a1"].status = nil
    data.payments["pay:hrE-a1"].stage = "CALLING"
    loaded = T.import(data)
    check("S17 a payment stopped mid-call imports as UNKNOWN", loaded.payments["pay:hrE-a1"].status == "UNKNOWN"
        and loaded.payments["pay:hrE-a1"].evidence == "INTERRUPTED_BEFORE_RECEIPT")
    data.records["hrE-a1"].sale.amount = 0 / 0
    check("S17 a bad amount in a sale record is refused", T.import(data) == nil)
    data.records["hrE-a1"].sale.amount = 510
    data.payments["pay:hrE-a1"].status = "PAID"
    check("S17 an unknown payment status is refused", T.import(data) == nil)
    data.payments["pay:hrE-a1"].status = "APPLIED"
    data.version = 1
    data.payments = nil
    for _, record in pairs(data.records) do record.sale = nil end
    check("S17 a schema-1 ledger still imports", T.import(data) ~= nil)
    check("S17 this is a run's ledger only: nothing writes it to the savegame", LS.persist == nil and RLContractTrade.save == nil)
end

-- ===========================================================================================
-- S18: trailer source, prices moving, the gate at the last moment
-- ===========================================================================================

do
    resetAll()
    local a = animal(1000, 40)
    local trailer = newSource("TRAILER", 1, { a })
    local code = sell(trailer, ids({ a }))
    local record = lastRecord()
    check("S18 trailer: no transport fee, COMMITTED, no pen message", code == AnimalSellEvent.SELL_SUCCESS
        and record.sale.amount == 1000 and FARMS[1].money == 2000 and #trailer.messages == 0)

    resetAll()
    local b = animal(1000, 40)
    local pen = newSource("PEN", 1, { b })
    clusterListener = function() b.price = 5 end   -- moves after the quote was frozen
    sell(pen, ids({ b }))
    clusterListener = nil
    check("S18 price moved during the sale: the frozen server quote is paid", lastRecord().sale.amount == 960 and FARMS[1].money == 1960)

    resetAll()
    local c, d = animal(1000, 40), animal(800, 30, { beingRidden = true })
    local pen2 = newSource("PEN", 1, { c })
    table.insert(pen2.clusterSystem.animals, d)
    code = sell(pen2, ids({ c }))
    check("S18 a member the flush would remove on its own: refused before anything (TEST is stricter than OFF)",
        code == AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST and count(LS.ledger().records) == 0)

    resetAll()
    local e = animal(1000, 40)
    local pen3 = newSource("PEN", 1, { e })
    permitted = false
    code = sell(pen3, ids({ e }))
    permitted = true
    check("S18 no trade permission: refused by the old gate", code == AnimalSellEvent.SELL_ERROR_NO_PERMISSION
        and count(LS.ledger().records) == 0)
    code = sell(pen3, ids({ e }), "bob")
    check("S18 another farm's pen: refused by the old gate", code == AnimalSellEvent.SELL_ERROR_NO_PERMISSION)

    -- A contract transaction awaiting reconciliation holds the animal: the sale path sees the lock.
    resetAll()
    local f = animal(1000, 40)
    local pen4 = newSource("PEN", 1, { f })
    assert(T.begin(LS.ledger(), "ct9-f1-o1", "CONTRACT", "fp", { "animal:" .. keyOf(f) }))
    code = sell(pen4, ids({ f }))
    check("S18 an animal held by a contract transaction cannot be sold", code == AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD
        and #pen4.clusterSystem.animals == 1)
end

-- ===========================================================================================
-- OFF and SHADOW: the old paths, unchanged
-- ===========================================================================================

do
    resetAll()
    LS.setMode("OFF")
    local a, b = animal(1000, 40), animal(800, 30)
    local pen = newSource("PEN", 1, { a, b })
    local code = sell(pen, ids({ a }))
    local r = AIAnimalSellEvent.executeServer(pen, ids({ b }), 1, { server = g_server, mission = mission }, "ignored")
    local summary = RLHerdsmanExecutor.executeActions({}, execCtx({}))
    check("OFF: the old paths sell and pay, no record, no receipt, no round", code == AnimalSellEvent.SELL_SUCCESS
        and r.status == "sold" and FARMS[1].money == 1000 + 960 + 830 and count(LS.ledger().records) == 0
        and count(LS.ledger().payments) == 0 and summary.roundId == nil)

    resetAll()
    LS.setMode("SHADOW")
    local c = animal(1000, 40)
    local pen2 = newSource("PEN", 1, { c })
    code = sell(pen2, ids({ c }))
    local logged = false
    for _, line in ipairs(LOG) do logged = logged or has(line, "RLLiveSale shadow") end
    check("SHADOW: the old path sells, no record, lock or receipt", code == AnimalSellEvent.SELL_SUCCESS and FARMS[1].money == 1960
        and count(LS.ledger().records) == 0 and next(LS.ledger().locks) == nil and count(LS.ledger().payments) == 0)
    LS.setMode("TEST")
    check("modes: per run, OFF after reset", (function() LS.reset() return LS.getMode() == "OFF" end)())
    check("modes: bad mode refused", LS.setMode("bogus") == false)
end

-- ===========================================================================================
-- The report reads only
-- ===========================================================================================

do
    resetAll()
    local a, b = animal(1000, 40), animal(800, 30)
    local pen = newSource("PEN", 1, { a, b })
    removalFaultAt = visualRemovals + 2
    sell(pen, ids({ a, b }))
    RLHerdsmanExecutor.executeActions({ sellAction({ a }, { wage = 5 }) }, execCtx({ pen1 = pen }, "hrRep"))
    local lines, savedPrint = {}, print
    print = function(text) lines[#lines + 1] = text end
    local moneyBefore, membersBefore = FARMS[1].money, members(pen)
    local result = RLTradeReportConsole:txReport()
    local again = RLTradeReportConsole:txReport()
    print = savedPrint
    local text = table.concat(lines, "\n")
    check("rlTradeTxReport: sales with subset, signed amount, receipt and wage actions; changes nothing",
        has(result, "wage action(s)") and has(text, "COMMITTED_PARTIAL") and has(text, "left 1, stayed 1")
        and has(text, "money SALE pay:") and has(text, "money WAGE wage:hrRep:f1") and FARMS[1].money == moneyBefore
        and members(pen) == membersBefore and result == again)
    check("rlTradeSaleMode: shows and sets", has(RLTradeReportConsole:saleMode(), "TEST") and has(RLTradeReportConsole:saleMode("off"), "OFF")
        and LS.getMode() == "OFF" and has(RLTradeReportConsole:saleMode("bogus"), "OFF, SHADOW or TEST"))
end


-- PR33 review: money callbacks may change the source; refusals are replayable too.
do
    resetAll()
    local a, b = animal(1000, 40), animal(800, 30)
    local pen = newSource("PEN", 1, { a, b })
    removalFaultAt = visualRemovals + 2
    moneyListener = function()
        moneyListener = nil
        for _, survivor in ipairs(pen.clusterSystem.animals) do
            pen.clusterSystem:addPendingRemoveCluster(survivor)
        end
    end
    sell(pen, ids({ a, b }))
    local record = lastRecord()
    check("review: partial sale clears survivors queued by money listeners", record.state == "COMMITTED_PARTIAL"
        and #pen.clusterSystem.animals == 1 and next(pen.clusterSystem.clustersToRemove) == nil)
    local moneyAfter = FARMS[1].money
    pen.clusterSystem:updateNow()
    check("review: later flush preserves unpaid survivor", #pen.clusterSystem.animals == 1 and FARMS[1].money == moneyAfter)

    resetAll()
    local sold, other = animal(1000, 40), animal(600, 20)
    local source = newSource("PEN", 1, { sold, other })
    mission.addMoney = function()
        source.clusterSystem:addPendingRemoveCluster(other)
        error("refused before moving money")
    end
    sell(source, ids({ sold }))
    record = lastRecord()
    check("review: NOT_APPLIED restore never flushes a foreign removal", record.state == "NEEDS_RECONCILIATION"
        and record.sale.payment == "NOT_APPLIED" and other.clusterSystem == source.clusterSystem
        and source.clusterSystem.clustersToRemove[other] == true and FARMS[1].money == 1000)

    resetAll()
    local restored = animal(1000, 40)
    local source2 = newSource("PEN", 1, { restored })
    moneyListener = function()
        moneyListener = nil
        restored.id, restored.idFull = nil, nil
        source2.clusterSystem:addPendingAddCluster(restored)
        source2.clusterSystem:updateNow()
    end
    local result = AIAnimalSellEvent.executeServer(source2, ids({ restored }), 1,
        { server = g_server, mission = mission }, "review-source-a1")
    check("review: money listener re-add changes subset, holds locks without another payment",
        result.txState == "NEEDS_RECONCILIATION" and result.paymentStatus == "APPLIED"
        and result.settledCount == 1 and result.amountGained == 1040 and result.removedCount == nil
        and LS.isCashHeld(1) and FARMS[1].money == 2040)

    resetAll()
    local sick = animal(1000, 40, { sick = true })
    local source3 = newSource("PEN", 1, { sick })
    local plan = { sellAction({ sick }) }
    local ctx = execCtx({ pen1 = source3 }, "review-refused")
    local first = RLHerdsmanExecutor.executeActions(plan, ctx)
    sick.sick = false
    local replay = RLHerdsmanExecutor.executeActions(plan, ctx)
    check("review: quote refusal replay stays refused after disease clears", first.results[1].saleStatus == "refused"
        and replay.results[1].saleStatus == "refused" and replay.results[1].replayed == true
        and #source3.clusterSystem.animals == 1 and FARMS[1].money == 950 and wages(1) == -50)
    local collision = AIAnimalSellEvent.executeServer(source3, ids({ animal(500, 20) }), 1,
        { server = g_server, mission = mission }, "review-refused-a1")
    check("review: refused id rejects a different payload", collision.reason == "ID_COLLISION" and collision.replayed ~= true)

    resetAll()
    local queued = animal(1000, 40)
    local source4 = newSource("PEN", 1, { queued })
    source4.clusterSystem:addPendingRemoveCluster(queued)
    local request = ids({ queued })
    local original = AIAnimalSellEvent.executeServer(source4, request, 1,
        { server = g_server, mission = mission }, "review-prepare")
    source4.clusterSystem.clustersToRemove[queued] = nil
    local repeated = AIAnimalSellEvent.executeServer(source4, request, 1,
        { server = g_server, mission = mission }, "review-prepare")
    check("review: prepare refusal replay stays refused after queue clears", original.status == "refused"
        and repeated.status == "refused" and repeated.replayed == true and #source4.clusterSystem.animals == 1
        and FARMS[1].money == 1000)
end
