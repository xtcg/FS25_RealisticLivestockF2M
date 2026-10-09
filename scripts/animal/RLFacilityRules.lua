--[[
    The rules a delivery to a slaughter facility follows, in one place, so the delivery code
    (AnimalMoveEvent) and the trade quote (RLTradeQuote) cannot drift apart. Pure: these read
    only their arguments.

    Contract facility (Hof Bergmann's public slaughterhouse, PlaceableContractProductionService):
      - a delivery goes to the farm's lowest-id order whose recipe takes the fill type
        (contractProductionDeliver sorts the farm's orders by id and takes the first match);
      - its fee is amount / recipe input amount x feePerBatch when the fill type is the recipe's
        fee input; the order's fee credit pays first, the farm's money the rest.
    Unit-based farm butcher: the first production with this single input and the meat as an
    output sets the recipe ratio (AnimalMoveEvent._getButcherRecipeRatio).
]]

RLFacilityRules = {}


--- The order and recipe a contract delivery of `fillType` from `farmId` goes to.
--- @param orders table|nil The service's orders (any key), each {id, farmId, recipeId}
--- @param recipeById table|nil recipeId -> recipe with inputs keyed by fill type
--- @param farmId number|nil
--- @param fillType number|nil
--- @return table|nil order
--- @return table|nil recipe
--- @return table|nil recipeInput
function RLFacilityRules.selectContractOrder(orders, recipeById, farmId, fillType)
    if type(orders) ~= "table" or type(recipeById) ~= "table" or farmId == nil or fillType == nil then return nil end
    local order, recipe, recipeInput
    for _, candidate in pairs(orders) do
        local candidateRecipe = candidate.farmId == farmId and recipeById[candidate.recipeId] or nil
        local input = candidateRecipe ~= nil and candidateRecipe.inputs ~= nil and candidateRecipe.inputs[fillType] or nil
        if input ~= nil and (order == nil or (candidate.id or 0) < (order.id or 0)) then
            order, recipe, recipeInput = candidate, candidateRecipe, input
        end
    end
    return order, recipe, recipeInput
end


--- Fee for `amount` of a recipe's input: amount / input amount x feePerBatch, or 0 when the input
--- is not the recipe's fee input or the recipe charges nothing.
--- @param amount number
--- @param inputAmount number Recipe input amount per batch
--- @param feePerBatch number|nil
--- @param isFeeInput boolean
--- @return number
function RLFacilityRules.getBatchFee(amount, inputAmount, feePerBatch, isFeeInput)
    if not isFeeInput or (feePerBatch or 0) <= 0 then return 0 end
    return amount / inputAmount * feePerBatch
end


--- What the order's fee credit pays of a fee, and the cash left for the farm's money.
--- @param fee number
--- @param feeCredit number|nil
--- @return number creditUse
--- @return number cash
function RLFacilityRules.splitFee(fee, feeCredit)
    local creditUse = math.min(math.max(feeCredit or 0, 0), fee)
    return creditUse, math.max(fee - math.max(feeCredit or 0, 0), 0)
end


--- Whether the farm's money covers `cash`, with the contract facility's rounding.
--- @param cash number
--- @param money number
--- @return boolean
function RLFacilityRules.canPayCash(cash, money)
    return cash <= 0.001 or math.max(money, 0) + 0.001 >= cash
end


--- Butcher productions that turn this single input into the meat fill type, in the order the
--- delivery code looks at them; the first is the one it uses.
--- @param productions table|nil Array of {inputs = {{type|fillType, amount}}, outputs = {...}}
--- @param fillType number
--- @param meatFillType number|nil
--- @return table matches Array of {production, input, output}
function RLFacilityRules.getButcherProductions(productions, fillType, meatFillType)
    local matches = {}
    if type(productions) ~= "table" or meatFillType == nil then return matches end
    for _, production in ipairs(productions) do
        local input, inputs = nil, 0
        for _, candidate in ipairs(production.inputs or {}) do
            inputs = inputs + 1
            if (candidate.type or candidate.fillType) == fillType then input = candidate end
        end
        if input ~= nil and inputs == 1 and (input.amount or 0) > 0 then
            for _, output in ipairs(production.outputs or {}) do
                if (output.type or output.fillType) == meatFillType and (output.amount or 0) > 0 then
                    table.insert(matches, { production = production, input = input, output = output })
                    break
                end
            end
        end
    end
    return matches
end
