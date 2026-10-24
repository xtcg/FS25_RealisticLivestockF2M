-- T02 shadow preparation. Pure: consumes frozen server quotes, never changes a game object.
-- A SUPPORTED quote is a description, not permission to trade. The caller must separately
-- check ownership, unique live identities, disease/age gates and source pending queues.
RLContractPlan = {}

local finite=RLPlain.finite

local function reject(reason)
    return nil, reason
end

-- Each entry: {key, quote, orderId, recipeId, inputFillType, room, feeCredit}.
-- room is shared facility/farm/input capacity; feeCredit is shared per order.
-- Preserve input order; collect demand before allocating any shared resource.
function RLContractPlan.prepare(entries, money)
    if type(entries) ~= "table" or getmetatable(entries) ~= nil then return reject("BAD_ENTRIES") end
    if not finite(money) or money < 0 then return reject("BAD_WALLET") end
    local count = 0
    for k in pairs(entries) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > #entries then return reject("BAD_ENTRIES") end
        count = count + 1
    end
    if count == 0 or count ~= #entries then return reject("EMPTY_OR_SPARSE_BATCH") end
    local plan = { entries = {}, orders = {}, inputs = {}, fee = 0, creditUse = 0, cashDue = 0,
        moneyBefore = money, semantics = "WEIGHTED_BATCH", mode = "SHADOW" }
    local seen = {}
    for _, entry in ipairs(entries) do
        if type(entry) ~= "table" then return reject("BAD_ENTRY") end
        if type(entry.key) ~= "string" or entry.key == "" then return reject("BAD_IDENTITY") end
        if seen[entry.key] then return reject("DUPLICATE_IDENTITY") end
        seen[entry.key] = true
        local q = entry.quote
        if type(q) ~= "table" or q.authoritative ~= true then return reject("NOT_AUTHORITATIVE") end
        -- A quote that is UNKNOWN only because the farm has no order (NO_OPEN_ORDER, NO_FARM)
        -- refuses as NO_ORDER; one that is UNKNOWN only for its own CANNOT_AFFORD is left to the
        -- whole-batch cash check below, which also shares each order's credit across heads.
        local status = q.status
        if status == "UNKNOWN" and type(q.reasons) == "table" then
            local onlyBudget, noOrder = true, false
            for _, reason in ipairs(q.reasons) do
                if reason == "NO_OPEN_ORDER" or reason == "NO_FARM" then noOrder = true
                elseif reason ~= "CANNOT_AFFORD" then onlyBudget = false end
            end
            if onlyBudget and noOrder then return reject("NO_ORDER") end
            if onlyBudget then status = "SUPPORTED" end
        end
        if status ~= "SUPPORTED" then return reject("QUOTE_" .. tostring(q.status)) end
        if q.semantics ~= "WEIGHTED_BATCH" then return reject("NOT_CONTRACT_BATCH") end
        if not finite(q.inputQuantity) or q.inputQuantity <= 0.001 then return reject("BAD_INPUT_AMOUNT") end
        if not finite(q.fee) or q.fee < 0 then return reject("BAD_FEE") end
        if type(entry.orderId) ~= "number" or entry.orderId % 1 ~= 0 or entry.orderId < 1 then return reject("NO_ORDER") end
        if type(entry.recipeId) ~= "string" or entry.recipeId == "" then return reject("NO_RECIPE") end
        if type(entry.inputFillType) ~= "number" or entry.inputFillType % 1 ~= 0 or entry.inputFillType < 1 then
            return reject("BAD_FILL_TYPE")
        end
        if not finite(entry.room) or entry.room < 0 then return reject("CAPACITY_UNKNOWN") end
        if not finite(entry.feeCredit) or entry.feeCredit < 0 then return reject("CREDIT_UNKNOWN") end
        local order = plan.orders[entry.orderId]
        if order == nil then
            order = { recipeId = entry.recipeId, feeCredit = entry.feeCredit, fee = 0 }
            plan.orders[entry.orderId] = order
        elseif order.recipeId ~= entry.recipeId or order.feeCredit ~= entry.feeCredit then
            return reject("INCONSISTENT_ORDER_SNAPSHOT")
        end
        local input = plan.inputs[entry.inputFillType]
        if input == nil then
            input = { room = entry.room, amount = 0 }
            plan.inputs[entry.inputFillType] = input
        elseif input.room ~= entry.room then return reject("INCONSISTENT_CAPACITY_SNAPSHOT") end
        input.amount = input.amount + q.inputQuantity
        order.fee = order.fee + q.fee
        plan.fee = plan.fee + q.fee
        if not finite(input.amount) or not finite(order.fee) or not finite(plan.fee) then return reject("NUMERIC_OVERFLOW") end
        plan.entries[#plan.entries + 1] = { key = entry.key, orderId = entry.orderId,
            recipeId = entry.recipeId, inputFillType = entry.inputFillType, amount = q.inputQuantity, fee = q.fee }
    end
    for _, input in pairs(plan.inputs) do
        -- Refuse even a tiny shortfall: the HB function can accept it partially. Display
        -- tolerances must never authorize a partial live-animal conversion.
        if input.amount > input.room then return reject("INSUFFICIENT_CAPACITY") end
    end
    for _, order in pairs(plan.orders) do
        order.creditUse = math.min(order.feeCredit, order.fee)
        order.cashDue = order.fee - order.creditUse
        plan.creditUse = plan.creditUse + order.creditUse
        plan.cashDue = plan.cashDue + order.cashDue
    end
    if not finite(plan.cashDue) or not finite(plan.creditUse) then return reject("NUMERIC_OVERFLOW") end
    if plan.cashDue > money then return reject("INSUFFICIENT_CASH") end
    plan.moneyAfter = money - plan.cashDue
    return plan
end
