-- Read-only server snapshot facade for T02's pure whole-batch budget planner.
-- It does not authorize a trade, reserve assets, align recipes or execute a transaction.
RLContractPreview = {}

function RLContractPreview.prepare(animals, target, farmId)
    local mission = g_currentMission
    if mission == nil or type(mission.getIsServer) ~= "function" or not mission:getIsServer()
        or target == nil or target.isServer ~= true then return nil, "NOT_AUTHORITATIVE" end
    if type(farmId) ~= "number" or farmId ~= farmId or farmId % 1 ~= 0 or farmId < 1 then return nil, "BAD_FARM" end
    if type(animals) ~= "table" or getmetatable(animals) ~= nil then return nil, "BAD_ANIMALS" end
    local count = 0
    for k in pairs(animals) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > #animals then return nil, "BAD_ANIMALS" end
        count = count + 1
    end
    if count == 0 or count ~= #animals then return nil, "EMPTY_OR_SPARSE_BATCH" end
    if type(mission.getMoney) ~= "function" then return nil, "WALLET_UNKNOWN" end
    local entries = {}
    for _, animal in ipairs(animals) do
        if type(animal) ~= "table" or animal.farmId == nil or type(animal.uniqueId) ~= "string"
            or animal.uniqueId == "" or type(animal.birthday) ~= "table" or animal.birthday.country == nil then
            return nil, "BAD_IDENTITY"
        end
        local ok, quote, d = pcall(RLTradeQuote.quoteAnimal, animal, target, farmId)
        if not ok then return nil, "QUOTE_FAILED:" .. tostring(quote) end
        entries[#entries + 1] = { key = RLAnimalUtil.toKey(animal.farmId, animal.uniqueId, animal.birthday.country),
            quote = quote, inputFillType = d.inputFillType, room = d.room,
            recipeId = d.recipe ~= nil and d.recipe.id or nil,
            orderId = d.order ~= nil and d.order.id or nil,
            feeCredit = d.order ~= nil and d.order.feeCredit or nil }
    end
    local ok, money = pcall(mission.getMoney, mission, farmId)
    if not ok then return nil, "WALLET_UNKNOWN" end
    return RLContractPlan.prepare(entries, money)
end
