--[[
    T02 batch 3: one money action (a sale's proceeds or a herdsman wage) with a receipt.

    The action goes through the game's own g_currentMission:addMoney(amount, farmId, moneyType,
    true, true), once per paymentId. addMoney returns nothing, and returning is no proof: the
    base function returns quietly for a missing farm, and a MONEY_CHANGED listener can throw half
    way. So the receipt is read off the fields addMoney changes, in its own order (FS25 v1.23.1,
    FSBaseMission:addMoney -> Farm:changeBalance -> FarmStats -> addMoneyChange):

        1 money        farm.money + amount
        2 finance      farm.stats.finances[moneyType.statistic] + amount, and
                       farm.stats.financesVersionCounter + 1 (wraps after 999999)
        3 hero         farm.stats.moneyEarnedHeroAccum + amount (only amount > 0)
           (MONEY_CHANGED is published here: other mods' listeners run, unobservable)
        4 change       mission.moneyChanges[moneyType.id][farmId] + amount (the HUD total), then
                       broadcastNotifications (forceShow) sends that total to the farm and clears
                       it: nil after a whole call; the sum still there when the HUD or the
                       broadcast threw

    Read just before and just after the one call:

        APPLIED      steps 1-3 exactly once with this amount, and step 4 completed (call
                     returned, total cleared) or reached (call threw, total = before + amount:
                     the HUD or broadcast failed, kept as callError; the money stands).
        NOT_APPLIED  addMoney was never called (a check before it refused), or it threw and no
                     step changed. Limit: what a wrapper of another mod did before throwing,
                     outside these fields, cannot be seen.
        UNKNOWN      anything else: some steps only, a step off by another amount (a listener
                     moved money too), returned without any step, fields unreadable after.

    Never a wallet snapshot restored, never a global addMoney replacement, never a fixed status.
    A paymentId is attempted once: a second call returns the first receipt and calls nothing, so
    an UNKNOWN is never paid again. Receipts live in the ledger in memory (this run only).
]]

RLSaleSettlement = {}

RLSaleSettlement.APPLIED = "APPLIED"
RLSaleSettlement.NOT_APPLIED = "NOT_APPLIED"
RLSaleSettlement.UNKNOWN = "UNKNOWN"

local COUNTER_WRAP = 999999


local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end


--- The fields addMoney changes for this farm and money type, or nil and why they cannot be read.
--- Reads only. The farm object itself is returned for the caller's use, never kept in a receipt.
--- @param mission table g_currentMission
--- @param farmId number
--- @param moneyType table A registered MoneyType ({id, statistic})
--- @return table|nil witnesses {money, finance, counter, hero, heroActive, change}
--- @return string|nil reason
function RLSaleSettlement.observe(mission, farmId, moneyType)
    if mission == nil or type(mission.getIsServer) ~= "function" or not mission:getIsServer() then return nil, "NOT_SERVER" end
    if type(farmId) ~= "number" or farmId % 1 ~= 0 or farmId < 1 then return nil, "BAD_FARM" end
    if type(moneyType) ~= "table" or moneyType.id == nil or type(moneyType.statistic) ~= "string" then return nil, "BAD_MONEY_TYPE" end
    if g_farmManager == nil then return nil, "NO_FARM_MANAGER" end
    local ok, farm = pcall(g_farmManager.getFarmById, g_farmManager, farmId)
    if not ok or type(farm) ~= "table" then return nil, "NO_FARM" end
    local stats = farm.stats
    if type(stats) ~= "table" or type(stats.finances) ~= "table" then return nil, "NO_STATS" end
    local finance = stats.finances[moneyType.statistic]
    if not isFinite(farm.money) then return nil, "MONEY_UNREADABLE" end
    if not isFinite(finance) then return nil, "STATISTIC_UNKNOWN:" .. moneyType.statistic end
    if not isFinite(stats.financesVersionCounter) then return nil, "COUNTER_UNREADABLE" end
    if not isFinite(stats.moneyEarnedHeroAccum) then return nil, "HERO_UNREADABLE" end
    if type(mission.moneyChanges) ~= "table" then return nil, "CHANGES_UNREADABLE" end
    local byType = mission.moneyChanges[moneyType.id]
    if byType ~= nil and type(byType) ~= "table" then return nil, "CHANGES_UNREADABLE" end
    local change = byType ~= nil and byType[farmId] or nil
    if change ~= nil and not isFinite(change) then return nil, "CHANGES_UNREADABLE" end
    return { money = farm.money, finance = finance, counter = stats.financesVersionCounter, hero = stats.moneyEarnedHeroAccum,
        heroActive = type(stats.heroStats) == "table" and stats.heroStats.moneyEarned ~= nil, change = change }
end


--- Explain what one call did, from the witnesses before and after. Pure.
--- @param before table From observe
--- @param after table From observe
--- @param amount number The signed amount of the call
--- @param threw boolean Whether the call threw
--- @return string status APPLIED, NOT_APPLIED or UNKNOWN
--- @return string evidence
--- @return table steps {money, finance, hero, change} each true when seen exactly
function RLSaleSettlement.classify(before, after, amount, threw)
    local nextCounter = before.counter + 1
    if nextCounter > COUNTER_WRAP then nextCounter = 0 end
    local heroAdds = amount > 0 and before.heroActive
    local accumulated = (before.change or 0) + amount
    local done = {
        money = after.money == before.money + amount,
        finance = after.finance == before.finance + amount and after.counter == nextCounter,
        hero = after.hero == (heroAdds and before.hero + amount or before.hero),
        -- A whole call sends and clears the total; a throw in the HUD or broadcast leaves the sum.
        change = (not threw and after.change == nil) or (threw and after.change ~= nil and after.change == accumulated),
    }
    local same = {
        money = after.money == before.money,
        finance = after.finance == before.finance and after.counter == before.counter,
        hero = after.hero == before.hero,
        change = after.change == before.change,
    }
    if done.money and done.finance and done.hero then
        if done.change then return RLSaleSettlement.APPLIED, threw and "THREW_AFTER_ALL_STEPS" or "ALL_STEPS", done end
        -- Money and statistics moved, the HUD step not reached: a MONEY_CHANGED listener threw
        -- and the listeners after it did not run.
        return RLSaleSettlement.UNKNOWN, "NOTIFICATION_STEP_NOT_REACHED", done
    end
    if same.money and same.finance and same.hero and same.change then
        if threw then return RLSaleSettlement.NOT_APPLIED, "THREW_BEFORE_ANY_STEP", done end
        return RLSaleSettlement.UNKNOWN, "RETURNED_WITHOUT_ANY_STEP", done
    end
    return RLSaleSettlement.UNKNOWN, "STEPS_INCOMPLETE_OR_UNEXPLAINED", done
end


local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end


--- Pay (or charge) once. The receipt is recorded before the call, so a re-entrant or repeated
--- request for the same paymentId sees it and calls nothing.
--- @param payments table The ledger's payment receipts by paymentId
--- @param action table {paymentId, ref, kind ("SALE"|"WAGE"), farmId, amount, moneyType}
--- @param mission table g_currentMission (or the executor's ctx.mission)
--- @return table receipt A copy
--- @return string|nil replay "REPLAY" when the paymentId already had a receipt
function RLSaleSettlement.apply(payments, action, mission)
    local id = type(action) == "table" and action.paymentId or nil
    if type(payments) ~= "table" or type(id) ~= "string" or id == "" then
        return { status = RLSaleSettlement.NOT_APPLIED, evidence = "BAD_ACTION", stage = "REFUSED" }
    end
    if payments[id] ~= nil then return copy(payments[id]), "REPLAY" end

    local moneyType = action.moneyType
    local receipt = { paymentId = id, ref = action.ref, kind = action.kind, farmId = action.farmId, amount = action.amount,
        moneyType = type(moneyType) == "table" and moneyType.statistic or nil,
        moneyTypeId = type(moneyType) == "table" and moneyType.id or nil, addChange = true, forceShow = true,
        stage = "RECORDED" }
    payments[id] = receipt

    if not isFinite(action.amount) then
        receipt.status, receipt.evidence, receipt.stage = RLSaleSettlement.NOT_APPLIED, "NOT_CALLED:BAD_AMOUNT", "REFUSED"
        return copy(receipt)
    end
    local before, why = RLSaleSettlement.observe(mission, action.farmId, moneyType)
    if before == nil or type(mission.addMoney) ~= "function" then
        receipt.status, receipt.evidence, receipt.stage = RLSaleSettlement.NOT_APPLIED, "NOT_CALLED:" .. tostring(why or "NO_ADD_MONEY"), "REFUSED"
        return copy(receipt)
    end

    receipt.stage = "CALLING"
    local ok, err = pcall(mission.addMoney, mission, action.amount, action.farmId, moneyType, true, true)
    if not ok then receipt.callError = tostring(err) end
    local after
    after, why = RLSaleSettlement.observe(mission, action.farmId, moneyType)
    receipt.stage = "DONE"
    if after == nil then
        receipt.status, receipt.evidence = RLSaleSettlement.UNKNOWN, "UNREADABLE_AFTER:" .. tostring(why)
        return copy(receipt)
    end
    local status, evidence, steps = RLSaleSettlement.classify(before, after, action.amount, not ok)
    receipt.status, receipt.evidence, receipt.steps = status, evidence, steps
    receipt.delta = { money = after.money - before.money, finance = after.finance - before.finance,
        counter = after.counter - before.counter, hero = after.hero - before.hero,
        change = (after.change or 0) - (before.change or 0) }
    return copy(receipt)
end
