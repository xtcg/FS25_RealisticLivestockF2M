--[[
    T02 target adapter for Hof Bergmann's public slaughterhouse (PlaceableContractProductionService,
    audited for HB 1.5.0.0 Beta2). Path A: the map's own contractProductionDeliver is called once
    for the whole batch, and every field it changes is read before and after so the delivery can
    be checked and, if needed, undone.

    HB's deliver, in order: picks the farm's lowest-id order whose recipe takes the fill type;
    caps the amount by (money + fee credit) / feePerBatch; takes the fee from the order's credit,
    then addMoney(-cash, PRODUCTION_COSTS); adds order.fee, input.buffered, input.totalDelivered,
    order.totalDeliveredAmount; sets order.state (raiseActive when a batch is ready); refreshes the
    animal visuals; returns the accepted amount.

    Receipt: before/after of those fields, money and productionCosts/version, the farm's other orders for the fill
    type and the recipe fingerprint. verify() requires the full amount and exactly the deltas
    HB's arithmetic gives for it; anything else - part, none, another order, a throw - is undone.
    rollback() undoes only this delivery's own changes and only while the fields still show
    them; money is refunded through addMoney with the same money type. It refuses (unknown) when
    something else has changed them, or the money moved by any other amount. A throw inside
    addMoney is UNKNOWN when its completion cannot be proven; matching money alone is not a receipt.

    Not undone, known: raiseActive (the facility updates once with nothing to do), the farm's
    "money earned" statistic counts the refund, and anything an override of the deliver call
    does outside these fields. A version other than the audited one is refused.
]]

RLHBContractAdapter = {}

local Log = RmLogging.getLogger("RLRM")

--- HB versions whose contractProductionDeliver this adapter was checked against.
RLHBContractAdapter.SUPPORTED_VERSIONS = { ["1.5.0.0 Beta2"] = true }

--- Relative tolerance only for money put back by a refund ((x - c) + c in doubles).
RLHBContractAdapter.REFUND_EPSILON = 1e-9


local function isNumber(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end


--- Whether a target is the audited HB contract service, on the server.
--- @param target table
--- @return table|nil support {version, modName}
--- @return string|nil reason
function RLHBContractAdapter.getSupport(target)
    if target == nil or target.isServer ~= true then return nil, "NOT_SERVER" end
    local spec = target.spec_contractProductionService
    if spec == nil or type(spec.recipes) ~= "table" or type(spec.recipeById) ~= "table" or type(spec.orders) ~= "table" then
        return nil, "SERVICE_UNREADABLE"
    end
    if type(target.contractProductionDeliver) ~= "function" then return nil, "NO_DELIVER" end
    local modName = target.customEnvironment
    local mod = modName ~= nil and g_modManager ~= nil and g_modManager.getModByName ~= nil and g_modManager:getModByName(modName) or nil
    local version = mod ~= nil and mod.version or nil
    if not RLHBContractAdapter.SUPPORTED_VERSIONS[version] then
        return nil, "UNSUPPORTED_HB_VERSION:" .. tostring(version)
    end
    return { version = version, modName = modName }
end


--- Recipe fingerprint: id, inputs, outputs, fee per batch, fee input and primary output.
--- @param recipe table
--- @return string
function RLHBContractAdapter.recipeFingerprint(recipe)
    local function amounts(list)
        local keys = {}
        for fillType in pairs(list or {}) do keys[#keys + 1] = fillType end
        table.sort(keys)
        local parts = {}
        for _, fillType in ipairs(keys) do
            parts[#parts + 1] = string.format("%s=%.17g", tostring(fillType), list[fillType].amount or 0)
        end
        return table.concat(parts, ",")
    end
    return string.format("%s|in:%s|out:%s|fee:%.17g@%s|primary:%s", tostring(recipe.id), amounts(recipe.inputs),
        amounts(recipe.outputs), recipe.feePerBatch or 0, tostring(recipe.feeInputFillTypeIndex),
        tostring(recipe.primaryOutputFillTypeIndex))
end


--- The fields of one order a delivery of `fillType` changes.
local function readOrder(order, fillType)
    local input = order.inputs ~= nil and order.inputs[fillType] or nil
    return { feeCredit = order.feeCredit, fee = order.fee, state = order.state,
        totalDeliveredAmount = order.totalDeliveredAmount, hasInput = input ~= nil,
        buffered = input ~= nil and input.buffered or nil, totalDelivered = input ~= nil and input.totalDelivered or nil }
end


--- The same fields of the farm's other orders, to see a delivery that went elsewhere.
local function readOtherOrders(spec, farmId, fillType, bound)
    local others = {}
    for key, order in pairs(spec.orders) do
        if order ~= bound and order.farmId == farmId then others[#others + 1] = { key = key, ref = order, fields = readOrder(order, fillType) } end
    end
    return others
end


local function sameFields(a, b)
    for _, field in ipairs({ "feeCredit", "fee", "state", "totalDeliveredAmount", "hasInput", "buffered", "totalDelivered" }) do
        if a[field] ~= b[field] then return false, field end
    end
    return true
end


local function readMoney(farmId)
    local ok, money = pcall(g_currentMission.getMoney, g_currentMission, farmId)
    if ok and isNumber(money) then return money end
    return nil
end

-- Native FarmStats:changeFinanceStats changes the productionCosts entry and then its
-- version counter. Keep object references outside the serializable receipt; an archive
-- or replacement of the finance table invalidates an inverse against the old table.
local function readFinance(farmId)
    local manager = g_farmManager
    if manager == nil or type(manager.getFarmById) ~= "function" then return nil end
    local ok, farm = pcall(manager.getFarmById, manager, farmId)
    local stats = ok and type(farm) == "table" and farm.stats or nil
    if type(stats) ~= "table" then return nil end
    local finances = stats.finances
    local statistic = MoneyType ~= nil and MoneyType.PRODUCTION_COSTS ~= nil and MoneyType.PRODUCTION_COSTS.statistic or nil
    local cost = type(finances) == "table" and statistic ~= nil and finances[statistic] or nil
    local version = stats ~= nil and stats.financesVersionCounter or nil
    if not isNumber(cost) or not isNumber(version) or version % 1 ~= 0 or version < 0 or version > 999999 then return nil end
    return { productionCosts = cost, version = version }, { farm = farm, stats = stats, finances = finances }
end

local function readBoundFinance(binding)
    local value, objects = readFinance(binding.farmId)
    local bound = binding.financeObjects
    if value == nil or bound == nil or objects.farm ~= bound.farm or objects.stats ~= bound.stats
        or objects.finances ~= bound.finances then return nil end
    return value
end

local function nextFinanceVersion(version)
    return version == 999999 and 0 or version + 1
end

local function sameFinance(a, b)
    return a ~= nil and b ~= nil and a.productionCosts == b.productionCosts and a.version == b.version
end

-- Used after mutations too: checking an old Lua object is not proof it remains an asset
-- of the live service. Never compensate a detached order/input/recipe.
local function checkLiveBinding(binding)
    local support, reason = RLHBContractAdapter.getSupport(binding.target)
    if support == nil then return false, reason end
    local spec, order = binding.target.spec_contractProductionService, binding.order
    if spec ~= binding.spec then return false, "SERVICE_CHANGED" end
    local count = 0
    for _, candidate in pairs(spec.orders) do
        if candidate == order then count = count + 1 end
    end
    if count ~= 1 or order.id ~= binding.orderId or order.farmId ~= binding.farmId
        or order.recipeId ~= binding.recipeId then return false, "ORDER_CHANGED" end
    if type(order.inputs) ~= "table" or order.inputs[binding.fillType] ~= binding.input then return false, "ORDER_INPUT_CHANGED" end
    if spec.recipeById[binding.recipeId] ~= binding.recipe
        or type(binding.recipe.inputs) ~= "table"
        or binding.recipe.inputs[binding.fillType] ~= binding.recipeInput
        or RLHBContractAdapter.recipeFingerprint(binding.recipe) ~= binding.recipeFingerprint then
        return false, "RECIPE_CHANGED"
    end
    return true
end

local function checkRoom(binding, demand)
    local room = AnimalMoveEvent._getContractRoom(binding.target, binding.farmId, binding.fillType)
    if not isNumber(room) then return false, "CAPACITY_UNKNOWN" end
    if room < demand then return false, "INSUFFICIENT_CAPACITY" end
    return true
end


--- What a full acceptance of `amount` does under HB's arithmetic, or why it would not be full.
--- @return table|nil expected {fee, creditUse, cash, charged, feeCreditAfter}
--- @return string|nil reason
local function expectFull(order, recipe, recipeInput, fillType, amount, money)
    local expected = { fee = 0, creditUse = 0, cash = 0, charged = false, feeCreditAfter = order.feeCredit }
    if fillType == recipe.feeInputFillTypeIndex and recipe.feePerBatch > 0 then
        local budget = math.max(money, 0) + math.max(order.feeCredit or 0, 0)
        -- HB accepts min(amount, budget / feePerBatch x input): anything less is a partial delivery.
        if amount > budget / recipe.feePerBatch * recipeInput.amount then return nil, "CANNOT_AFFORD" end
        local fee = amount / recipeInput.amount * recipe.feePerBatch
        local creditUsed = math.min(math.max(order.feeCredit or 0, 0), fee)
        local cash = math.max(fee - creditUsed, 0)
        expected.fee, expected.creditUse, expected.cash = fee, creditUsed, cash
        expected.charged = cash > 0.001
        expected.feeCreditAfter = math.max((order.feeCredit or 0) - creditUsed, 0)
    end
    return expected
end


--- Bind a delivery of `amount` of `fillType` from `farmId`: the order HB will pick, its recipe and
--- what a full acceptance must change. Reads only.
--- @return table|nil binding
--- @return string|nil reason
function RLHBContractAdapter.bind(target, farmId, fillType, amount)
    local support, reason = RLHBContractAdapter.getSupport(target)
    if support == nil then return nil, reason end
    if not isNumber(amount) or amount <= 0.001 then return nil, "BAD_AMOUNT" end
    local spec = target.spec_contractProductionService
    local order, recipe, recipeInput = RLFacilityRules.selectContractOrder(spec.orders, spec.recipeById, farmId, fillType)
    if order == nil then return nil, "NO_OPEN_ORDER" end
    if order.inputs == nil or order.inputs[fillType] == nil then return nil, "ORDER_INPUT_MISSING" end
    if not isNumber(recipeInput.amount) or recipeInput.amount <= 0 or not isNumber(recipe.feePerBatch) then
        return nil, "BAD_RECIPE"
    end
    local money = readMoney(farmId)
    if money == nil then return nil, "WALLET_UNKNOWN" end
    local expected, refused = expectFull(order, recipe, recipeInput, fillType, amount, money)
    if expected == nil then return nil, refused end
    local finance, financeObjects = readFinance(farmId)
    if expected.charged and finance == nil then return nil, "FINANCE_UNREADABLE" end

    return {
        target = target, spec = spec, farmId = farmId, fillType = fillType, amount = amount, support = support,
        order = order, orderId = order.id, recipeId = order.recipeId, recipe = recipe,
        input = order.inputs[fillType], recipeInput = recipeInput, financeObjects = financeObjects,
        recipeFingerprint = RLHBContractAdapter.recipeFingerprint(recipe),
        expected = expected,
        receipt = { stage = "BOUND", orderId = order.id, recipeId = order.recipeId, amount = amount,
            expected = { fee = expected.fee, creditUse = expected.creditUse, cash = expected.charged and expected.cash or 0 } },
    }
end


--- Re-check a binding just before it is applied: same order object and id, same recipe and
--- fingerprint, HB would still pick this order, and the money still covers a full acceptance.
--- @return boolean ok
--- @return string|nil reason
function RLHBContractAdapter.recheck(binding)
    local live, reason = checkLiveBinding(binding)
    if not live then return false, reason end
    local spec = binding.target.spec_contractProductionService
    if spec ~= binding.spec then return false, "SERVICE_CHANGED" end
    local order, recipe, recipeInput = RLFacilityRules.selectContractOrder(spec.orders, spec.recipeById, binding.farmId, binding.fillType)
    if order ~= binding.order or order.id ~= binding.orderId or order.recipeId ~= binding.recipeId then return false, "ORDER_CHANGED" end
    if recipe ~= binding.recipe or RLHBContractAdapter.recipeFingerprint(recipe) ~= binding.recipeFingerprint then
        return false, "RECIPE_CHANGED"
    end
    local money = readMoney(binding.farmId)
    if money == nil then return false, "WALLET_UNKNOWN" end
    local expected, refused = expectFull(order, recipe, recipeInput, binding.fillType, binding.amount, money)
    if expected == nil then return false, refused end
    if expected.fee ~= binding.expected.fee then return false, "FEE_CHANGED" end
    if expected.charged and readBoundFinance(binding) == nil then return false, "FINANCE_UNREADABLE" end
    local roomOk, roomReason = checkRoom(binding, binding.amount)
    if not roomOk then return false, roomReason end
    return true
end


--- Deliver the batch through the map's own call and record what changed.
--- @return boolean called The call returned (it may still have delivered less than asked)
function RLHBContractAdapter.apply(binding)
    local receipt = binding.receipt
    if receipt.applied ~= nil then return false end
    local ready, reason = RLHBContractAdapter.recheck(binding)
    if not ready then receipt.applyError = reason return false end
    local target = binding.target
    receipt.before = readOrder(binding.order, binding.fillType)
    receipt.moneyBefore = readMoney(binding.farmId)
    receipt.financeBefore = readBoundFinance(binding)
    receipt.others = readOtherOrders(binding.spec, binding.farmId, binding.fillType, binding.order)
    -- What a full acceptance must change, from the state right before the call.
    if receipt.moneyBefore == nil then return false end
    local expected = expectFull(binding.order, binding.recipe, binding.recipe.inputs[binding.fillType], binding.fillType,
        binding.amount, receipt.moneyBefore)
    if expected == nil then return false end
    if expected.charged and receipt.financeBefore == nil then return false end
    binding.expected = expected
    receipt.expected = { fee = expected.fee, creditUse = expected.creditUse, cash = expected.charged and expected.cash or 0 }
    receipt.paymentStatus = expected.charged and "UNKNOWN" or "NOT_APPLIED"
    receipt.stage = "APPLYING"
    local ok, accepted = pcall(target.contractProductionDeliver, target, binding.farmId, binding.fillType, binding.amount)
    receipt.applied = true
    receipt.callOk, receipt.accepted = ok, ok and accepted or nil
    receipt.error = not ok and tostring(accepted) or nil
    receipt.after = readOrder(binding.order, binding.fillType)
    receipt.moneyAfter = readMoney(binding.farmId)
    receipt.financeAfter = readBoundFinance(binding)
    receipt.stage = "APPLIED_UNVERIFIED"
    if not ok then
        Log:warning("RLHBContractAdapter.apply: deliver threw for order %s: %s", tostring(binding.orderId), receipt.error)
    end
    return ok
end


--- Whether the delivery took the full batch with exactly HB's deltas and nothing else.
--- @return boolean ok
--- @return string|nil reason
function RLHBContractAdapter.verify(binding)
    local r, e = binding.receipt, binding.expected
    local function fail(reason)
        r.verifyError = reason
        r.verified = false
        return false, reason
    end
    local live, liveReason = checkLiveBinding(binding)
    if not live then return fail(liveReason) end
    if not r.callOk then return fail("DELIVER_THREW") end
    if r.accepted ~= binding.amount then return fail("ACCEPTED:" .. tostring(r.accepted)) end
    local b, a = r.before, r.after
    local unchanged, changedField = sameFields(readOrder(binding.order, binding.fillType), a)
    if not unchanged then return fail("CHANGED_SINCE:" .. changedField) end
    if not b.hasInput or not a.hasInput then return fail("INPUT_MISSING") end
    -- HB adds with these very expressions, so a full acceptance matches them exactly.
    if a.buffered ~= (b.buffered or 0) + binding.amount then return fail("BUFFERED") end
    if a.totalDelivered ~= (b.totalDelivered or 0) + binding.amount then return fail("TOTAL_DELIVERED") end
    if a.totalDeliveredAmount ~= (b.totalDeliveredAmount or 0) + binding.amount then return fail("TOTAL_DELIVERED_AMOUNT") end
    if e.fee > 0 then
        if a.fee ~= (b.fee or 0) + e.fee then return fail("ORDER_FEE") end
        if a.feeCredit ~= e.feeCreditAfter then return fail("FEE_CREDIT") end
    elseif a.fee ~= b.fee or a.feeCredit ~= b.feeCredit then
        return fail("UNEXPECTED_FEE")
    end
    if r.moneyBefore == nil or r.moneyAfter == nil then return fail("MONEY_UNREADABLE") end
    local expectedMoney = e.charged and r.moneyBefore + (-e.cash) or r.moneyBefore
    if r.moneyAfter ~= expectedMoney then return fail("MONEY") end
    if readMoney(binding.farmId) ~= r.moneyAfter then return fail("MONEY_CHANGED_SINCE") end
    if e.charged then
        if r.financeBefore == nil or not sameFinance(r.financeAfter, {
            productionCosts = r.financeBefore.productionCosts + (-e.cash),
            version = nextFinanceVersion(r.financeBefore.version) }) then return fail("FINANCE_DELTA") end
        if not sameFinance(readBoundFinance(binding), r.financeAfter) then return fail("FINANCE_CHANGED_SINCE") end
    end
    for _, other in ipairs(r.others) do
        if binding.spec.orders[other.key] ~= other.ref or not sameFields(other.fields, readOrder(other.ref, binding.fillType)) then
            return fail("OTHER_ORDER_CHANGED")
        end
    end
    if RLHBContractAdapter.recipeFingerprint(binding.recipe) ~= binding.recipeFingerprint then return fail("RECIPE_CHANGED") end
    local roomOk, roomReason = checkRoom(binding, 0)
    if not roomOk then return fail(roomReason) end
    r.paymentStatus = e.charged and "APPLIED" or "NOT_APPLIED"
    r.verified, r.stage = true, "APPLIED"
    return true
end


--- HB's deliver changes the fields in this order; a throw leaves a prefix of them changed.
local STEPS = { "feeCredit", "money", "fee", "buffered", "totalDelivered", "totalDeliveredAmount", "state" }


--- Which accepted amount, and how far through HB's steps, explains what the receipt observed:
--- the full amount or the number the call returned, each computed with HB's own expressions,
--- with the fields changed as a prefix of STEPS and the rest untouched. nil when nothing does
--- (another mod changed something, or the call did something HB's code does not).
--- @return table|nil explanation {accepted, steps, charged, cash}
function RLHBContractAdapter.explain(binding)
    local r = binding.receipt
    if r.before == nil or r.after == nil or r.moneyBefore == nil or r.moneyAfter == nil then return nil end
    local b, a = r.before, r.after
    local recipe = binding.recipe
    local recipeInput = recipe.inputs[binding.fillType]
    local candidates = { binding.amount }
    if type(r.accepted) == "number" and r.accepted ~= binding.amount then candidates[2] = r.accepted end

    for _, accepted in ipairs(candidates) do
        local target = { money = r.moneyBefore, feeCredit = b.feeCredit, fee = b.fee,
            buffered = (b.buffered or 0) + accepted, totalDelivered = (b.totalDelivered or 0) + accepted,
            totalDeliveredAmount = (b.totalDeliveredAmount or 0) + accepted }
        local charged, cash = false, 0
        if binding.fillType == recipe.feeInputFillTypeIndex and recipe.feePerBatch > 0 then
            local fee = accepted / recipeInput.amount * recipe.feePerBatch
            local creditUsed = math.min(math.max(b.feeCredit or 0, 0), fee)
            target.feeCredit = math.max((b.feeCredit or 0) - creditUsed, 0)
            cash = math.max(fee - creditUsed, 0)
            charged = cash > 0.001
            if charged then target.money = r.moneyBefore + (-cash) end
            target.fee = (b.fee or 0) + fee
        end
        local observed = { money = r.moneyAfter, feeCredit = a.feeCredit, fee = a.fee, buffered = a.buffered,
            totalDelivered = a.totalDelivered, totalDeliveredAmount = a.totalDeliveredAmount, state = a.state }
        local original = { money = r.moneyBefore, feeCredit = b.feeCredit, fee = b.fee, buffered = b.buffered,
            totalDelivered = b.totalDelivered, totalDeliveredAmount = b.totalDeliveredAmount, state = b.state }
        -- Steps 1..k at their target (state: any value), steps after k untouched.
        for k = #STEPS, 0, -1 do
            local fits = true
            for i, step in ipairs(STEPS) do
                local value = observed[step]
                if i <= k then
                    if step ~= "state" and value ~= target[step] then fits = false break end
                elseif value ~= original[step] then
                    fits = false break
                end
            end
            if fits then
                local moneyApplied = charged and k >= 2
                if moneyApplied then
                    -- A throw inside addMoney may be after the wallet/stat write but before
                    -- dirty flags or synchronous listeners completed. HB writes order.fee
                    -- only after addMoney returns: without that marker, do not infer a receipt.
                    if not r.callOk and (k < 3 or a.fee == b.fee) then
                        r.paymentStatus = "UNKNOWN"
                        return nil
                    end
                    if r.financeBefore == nil or not sameFinance(r.financeAfter, {
                        productionCosts = r.financeBefore.productionCosts + (-cash),
                        version = nextFinanceVersion(r.financeBefore.version) }) then
                        r.paymentStatus = "UNKNOWN"
                        return nil
                    end
                elseif r.financeBefore ~= nil and not sameFinance(r.financeBefore, r.financeAfter) then
                    r.paymentStatus = "UNKNOWN"
                    return nil
                end
                r.paymentStatus = moneyApplied and "APPLIED" or "NOT_APPLIED"
                return { accepted = accepted, steps = k, charged = moneyApplied, cash = cash }
            end
        end
    end
    return nil
end


--- Undo this delivery's own changes. Idempotent: a second call does nothing and returns true.
--- Refuses (returns false: unknown, keep for reconciliation) when the fields no longer show
--- exactly this delivery's result, or the money moved by anything but this delivery's cash.
--- @return boolean ok
function RLHBContractAdapter.rollback(binding)
    local r = binding.receipt
    if not r.applied then r.rolledBack, r.stage = true, "NOT_APPLIED" return true end
    local live, reason = checkLiveBinding(binding)
    if not live then r.rollbackError = reason return false end
    if r.rolledBack then return true end
    if r.refundAttempted then return false end
    local order, fillType = binding.order, binding.fillType
    local current = readOrder(order, fillType)
    local same, field = sameFields(current, r.after)
    if not same then
        r.rollbackError = "CHANGED_SINCE:" .. field
        return false
    end
    for _, other in ipairs(r.others) do
        if not sameFields(other.fields, readOrder(other.ref, fillType)) then
            r.rollbackError = "OTHER_ORDER_CHANGED"
            return false
        end
    end

    -- Money first: an unknown outcome stops before any order field is touched.
    if r.moneyBefore == nil or r.moneyAfter == nil or readMoney(binding.farmId) ~= r.moneyAfter then
        r.rollbackError = "MONEY_UNKNOWN"
        return false
    end
    local explanation = RLHBContractAdapter.explain(binding)
    if explanation == nil then
        r.rollbackError = "DELTA_UNEXPLAINED"
        return false
    end
    r.explained = { accepted = explanation.accepted, steps = explanation.steps, charged = explanation.charged }
    local refund = explanation.charged and explanation.cash or 0
    if refund > 0 then
        if not sameFinance(readBoundFinance(binding), r.financeAfter) then
            r.rollbackError = "FINANCE_CHANGED_SINCE"
            return false
        end
        r.refundAttempted = true
        r.refundStatus = "UNKNOWN"
        local ok, err = pcall(g_currentMission.addMoney, g_currentMission, refund, binding.farmId, MoneyType.PRODUCTION_COSTS, false, true)
        r.moneyRefund = readMoney(binding.farmId)
        r.financeRefund = readBoundFinance(binding)
        if not ok then
            r.rollbackError = "REFUND_THREW:" .. tostring(err)
            return false
        end
        r.refunded = refund
        local finance = r.financeRefund
        local expectedCost = r.financeAfter.productionCosts + refund
        if finance == nil or finance.version ~= nextFinanceVersion(r.financeAfter.version)
            or finance.productionCosts ~= expectedCost then
            r.rollbackError = "REFUND_FINANCE_UNKNOWN"
            return false
        end
        local money = r.moneyRefund
        if money == nil or math.abs(money - r.moneyBefore)
            > RLHBContractAdapter.REFUND_EPSILON * math.max(1, math.abs(r.moneyBefore)) then
            r.rollbackError = "REFUND_MONEY_UNKNOWN"
            return false
        end
        r.refundStatus = "APPLIED"
    end

    -- Refund callbacks can cancel/replace an order or change its fields. A successful
    -- money call does not authorize writing an old object or overwriting foreign work.
    live, reason = checkLiveBinding(binding)
    if not live then r.rollbackError = reason return false end
    same, field = sameFields(readOrder(order, fillType), r.after)
    if not same then r.rollbackError = "CHANGED_SINCE:" .. field return false end

    local input = order.inputs ~= nil and order.inputs[fillType] or nil
    if input ~= nil then
        input.buffered, input.totalDelivered = r.before.buffered, r.before.totalDelivered
    end
    order.feeCredit, order.fee = r.before.feeCredit, r.before.fee
    order.totalDeliveredAmount = r.before.totalDeliveredAmount
    order.state = r.before.state
    local target = binding.target
    if target.contractProductionRefreshAnimalVisuals ~= nil then
        local ok, err = pcall(target.contractProductionRefreshAnimalVisuals, target)
        if not ok then r.visualError = tostring(err) end
    end
    r.rolledBack, r.stage = true, "ROLLED_BACK_UNVERIFIED"
    return true
end


--- Whether the order and money are back where they were before this delivery.
--- @return boolean ok
function RLHBContractAdapter.verifyRestored(binding)
    local r = binding.receipt
    if not r.applied then return true end
    if not r.rolledBack then return false end
    if not checkLiveBinding(binding) then return false end
    local same = sameFields(readOrder(binding.order, binding.fillType), r.before)
    if not same then return false end
    local money = readMoney(binding.farmId)
    if money == nil or r.moneyBefore == nil then return false end
    if math.abs(money - r.moneyBefore) > RLHBContractAdapter.REFUND_EPSILON * math.max(1, math.abs(r.moneyBefore)) then
        return false
    end
    if r.financeBefore ~= nil then
        local finance = readBoundFinance(binding)
        if finance == nil then return false end
        local version = r.financeBefore.version
        if r.refunded ~= nil then version = nextFinanceVersion(nextFinanceVersion(version)) end
        if finance.version ~= version or math.abs(finance.productionCosts - r.financeBefore.productionCosts)
            > RLHBContractAdapter.REFUND_EPSILON * math.max(1, math.abs(r.financeBefore.productionCosts)) then return false end
    end
    for _, other in ipairs(r.others) do
        if not sameFields(other.fields, readOrder(other.ref, binding.fillType)) then return false end
    end
    r.stage = "ROLLED_BACK"
    return true
end


--- The receipt as plain data (no object references), for the transaction record.
function RLHBContractAdapter.exportReceipt(binding)
    local r = binding.receipt
    local function copy(t)
        if type(t) ~= "table" then return t end
        local c = {}
        for k, v in pairs(t) do if k ~= "ref" then c[k] = copy(v) end end
        return c
    end
    return copy(r)
end
