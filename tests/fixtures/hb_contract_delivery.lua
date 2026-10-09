-- Exact function excerpts from supplied HB Beta2 PlaceableContractProductionService.lua.
-- Source SHA256: 4ff2508fd07cf7a3632a4a79c6eb723969098d6df95fdcf39164eed36f0f3f55
-- Production arithmetic and mutation order are unchanged; engine globals supplied by tests.
PlaceableContractProductionService = { SPEC_KEY = "spec_contractProductionService", STATE_DELIVERY = 1, STATE_QUEUED = 2, STATE_PROCESSING = 3 }
local function getSpec(placeable)
    return placeable[PlaceableContractProductionService.SPEC_KEY] or placeable.spec_contractProductionService
end

local function getRecipeById(spec, recipeId)
    return spec.recipeById[recipeId]
end

local function getFarmOrders(spec, farmId)
    local orders = {}

    for _, order in pairs(spec.orders) do
        if order.farmId == farmId then
            table.insert(orders, order)
        end
    end

    table.sort(orders, function(a, b)
        return a.id < b.id
    end)

    return orders
end

local function getAvailableBatches(order, recipe)
    local availableBatches = math.huge

    for fillTypeIndex, recipeInput in pairs(recipe.inputs) do
        local input = order.inputs[fillTypeIndex]
        local buffered = input ~= nil and input.buffered or 0
        availableBatches = math.min(availableBatches, buffered / recipeInput.amount)
    end

    return availableBatches == math.huge and 0 or math.max(availableBatches, 0)
end

function PlaceableContractProductionService:contractProductionDeliver(farmId, fillTypeIndex, amount)
    local spec = getSpec(self)

    if not self.isServer or spec == nil or amount <= 0 then
        return 0
    end

    local order = nil
    local recipe = nil

    for _, candidate in ipairs(getFarmOrders(spec, farmId)) do
        local candidateRecipe = getRecipeById(spec, candidate.recipeId)

        if candidateRecipe ~= nil and candidateRecipe.inputs[fillTypeIndex] ~= nil then
            order = candidate
            recipe = candidateRecipe
            break
        end
    end

    if order == nil then
        return 0
    end

    local input = order.inputs[fillTypeIndex]
    local recipeInput = recipe.inputs[fillTypeIndex]

    if input == nil or recipeInput == nil then
        return 0
    end

    local accepted = amount
    local fee = 0

    if fillTypeIndex == recipe.feeInputFillTypeIndex and recipe.feePerBatch > 0 then
        local availableBudget = math.max(g_currentMission:getMoney(farmId), 0) + math.max(order.feeCredit or 0, 0)
        local maxAffordableAmount = availableBudget / recipe.feePerBatch * recipeInput.amount
        accepted = math.min(accepted, maxAffordableAmount)
        fee = accepted / recipeInput.amount * recipe.feePerBatch
    end

    if accepted <= 0.001 then
        return 0
    end

    if fee > 0 then
        local creditUsed = math.min(math.max(order.feeCredit or 0, 0), fee)
        order.feeCredit = math.max((order.feeCredit or 0) - creditUsed, 0)
        local cashFee = math.max(fee - creditUsed, 0)

        if cashFee > 0.001 then
            g_currentMission:addMoney(-cashFee, farmId, MoneyType.PRODUCTION_COSTS, false, true)
        end

        order.fee = (order.fee or 0) + fee
    end

    input.buffered = (input.buffered or 0) + accepted
    input.totalDelivered = (input.totalDelivered or 0) + accepted
    order.totalDeliveredAmount = (order.totalDeliveredAmount or 0) + accepted

    if getAvailableBatches(order, recipe) > 0.000001 then
        order.state = PlaceableContractProductionService.STATE_QUEUED
        self:raiseActive()
    elseif order.state ~= PlaceableContractProductionService.STATE_PROCESSING then
        order.state = PlaceableContractProductionService.STATE_DELIVERY
    end

    if self.contractProductionRefreshAnimalVisuals ~= nil then
        self:contractProductionRefreshAnimalVisuals()
    end

    return accepted
end
