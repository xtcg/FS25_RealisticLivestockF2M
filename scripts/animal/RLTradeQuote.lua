--[[
    Read-only trade quote: what one animal is at a facility, in that facility's own units, next
    to what the carcass model says it is in meat.

        modelMeat           carcass yield factor x meatPerHead (RLMeatMath), kg of the meat fill type
        inputQuantity       what the facility's delivery path would credit, in its unit
        effectiveRecipeMeat that input through the recipe that is in effect now, nominal kg

    Facility semantics (describeFacility):
        HEAD               taken by head; the quantity is a head count
        WEIGHTED_BATCH     contract facility (Hof Bergmann's public slaughterhouse): the input is
                           the yield factor in standard batches ("typical animals"), not kg
        PRODUCTION_UNIT    unit-based farm butcher: production storage units, converted through
                           the butcher's real recipe ratio
        ANIMAL_CONVERSION  the input becomes another live animal (insemination system): whole
                           head, no carcass yield

    Three layers, so a quote can be checked without the game:
        snapshotFacility / getRole  read the live facility and config (read-only)
        describeFacility            pure: semantics, recipe, unit, fee source, support status
        quote                       pure: quantities, difference, fees

    Nothing here aligns recipes, delivers, charges, reserves room or sets up animal state. A
    quote is no promise of output: the recipe can change, the facility can take less, prices
    are not part of it. A client reads its own copy of the config, so its quotes are marked not
    authoritative.
]]

RLTradeQuote = {}

RLTradeQuote.HEAD = "HEAD"
RLTradeQuote.WEIGHTED_BATCH = "WEIGHTED_BATCH"
RLTradeQuote.PRODUCTION_UNIT = "PRODUCTION_UNIT"
RLTradeQuote.ANIMAL_CONVERSION = "ANIMAL_CONVERSION"

--- Support status of a description or quote.
RLTradeQuote.SUPPORTED = "SUPPORTED"
RLTradeQuote.AMBIGUOUS = "AMBIGUOUS"
RLTradeQuote.UNKNOWN = "UNKNOWN"
RLTradeQuote.UNSUPPORTED = "UNSUPPORTED"

--- Relative tolerance when comparing amounts (doubles).
RLTradeQuote.EPSILON = 1e-6


local function sameAmount(a, b)
    return a ~= nil and b ~= nil and math.abs(a - b) <= RLTradeQuote.EPSILON * math.max(1, math.abs(a), math.abs(b))
end


local function fillTypeName(fillType)
    if fillType == nil then return nil end
    local manager = g_fillTypeManager
    local name = manager ~= nil and manager.getFillTypeNameByIndex ~= nil and manager:getFillTypeNameByIndex(fillType) or nil
    return name or tostring(fillType)
end


--- Copy of a list of {type|fillType|fillTypeIndex, amount} entries, array or keyed by fill type.
local function copyAmounts(entries)
    local list = {}
    for _, entry in pairs(entries or {}) do
        list[#list + 1] = { fillType = entry.type or entry.fillType or entry.fillTypeIndex, amount = entry.amount }
    end
    table.sort(list, function(a, b) return (a.fillType or 0) < (b.fillType or 0) end)
    return list
end


-- =============================================================================
-- Snapshots (read the game, change nothing)
-- =============================================================================

--- The meat profile of a subtype's animal type: meat per typical animal, meat fill type and
--- the contract fee settings. Read-only.
--- @param subTypeIndex number
--- @return table role {subTypeIndex, typeIndex, typeName, meatPerHead, meatFillType, meatFillTypeName, processingFeePerKg, slaughterFee}
function RLTradeQuote.getRole(subTypeIndex)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    local subType = animalSystem ~= nil and animalSystem:getSubTypeByIndex(subTypeIndex) or nil
    local typeName = RLBreedTraits.getTypeName(subType)
    local layers = AnimalMoveEvent.getCarcassConfig().layers
    local meatName = typeName ~= nil and AnimalMoveEvent.getCarcassConfig().meatFillTypes[typeName:upper()] or nil
    return {
        subTypeIndex = subTypeIndex,
        subTypeName = subType ~= nil and subType.name or nil,
        typeIndex = subType ~= nil and subType.typeIndex or nil,
        typeName = typeName,
        meatPerHead = AnimalMoveEvent.getMeatPerHead(typeName),
        meatFillType = meatName ~= nil and g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName(meatName) or nil,
        meatFillTypeName = meatName,
        processingFeePerKg = AnimalMoveEvent.getProcessingFeePerKg(typeName),
        slaughterFee = subType ~= nil and RLBreedTraits.resolve(layers, subType, "slaughterFee", nil) or nil,
    }
end


--- Frozen copy of what a facility does with one subtype: its kind, input fill type, the animal
--- types sharing that input, its recipes or productions, the farm's orders and fee credit.
--- Reads tables only; calls no facility method that changes state.
--- @param target table The move target (husbandry placeable, contract placeable, or EPP production point)
--- @param subTypeIndex number
--- @param farmId number|nil The delivering farm
--- @return table snapshot
function RLTradeQuote.snapshotFacility(target, subTypeIndex, farmId)
    local snapshot = {
        name = target ~= nil and target.getName ~= nil and target:getName() or (target ~= nil and target.name) or "?",
        isServer = target ~= nil and target.isServer == true or false,
        subTypeIndex = subTypeIndex,
        farmId = farmId,
        kind = "UNKNOWN",
        sharers = {},
    }
    if target == nil then return snapshot end

    local subTypeToFillType = target.animalSubTypeToFillType
    local fillType = type(subTypeToFillType) == "table" and subTypeToFillType[subTypeIndex] or nil
    snapshot.inputFillType = fillType
    snapshot.inputFillTypeName = fillTypeName(fillType)

    -- Every animal type that goes in as the same fill type, with its meat profile.
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if fillType ~= nil and animalSystem ~= nil then
        local seen = {}
        for otherIndex, otherFillType in pairs(subTypeToFillType) do
            if otherFillType == fillType then
                local typeName = RLBreedTraits.getTypeName(animalSystem:getSubTypeByIndex(otherIndex))
                if typeName ~= nil and not seen[typeName] then
                    seen[typeName] = true
                    local role = RLTradeQuote.getRole(otherIndex)
                    table.insert(snapshot.sharers, { typeName = typeName, meatPerHead = role.meatPerHead,
                        meatFillType = role.meatFillType })
                end
            end
        end
        table.sort(snapshot.sharers, function(a, b) return a.typeName < b.typeName end)
    end

    local subType = animalSystem ~= nil and animalSystem:getSubTypeByIndex(subTypeIndex) or nil
    local typeData = type(target.animalsTypeData) == "table" and subType ~= nil and target.animalsTypeData[subType.typeIndex] or nil
    if typeData ~= nil then
        snapshot.minimumAge, snapshot.maximumAge = typeData.minimumAge, typeData.maximumAge
    end

    if target.spec_husbandryAnimals ~= nil then
        snapshot.kind = "HUSBANDRY"
        return snapshot
    end

    local serviceSpec = target.spec_contractProductionService
    if type(target.contractProductionAddAnimals) == "function" then
        snapshot.kind = "CONTRACT"
        -- The facility's delivery calls decide the unit, whether or not a farm is known.
        snapshot.weighted = AnimalMoveEvent._hasWeighedContractDelivery(target)
        snapshot.recipes = {}
        snapshot.recipesReadable = serviceSpec ~= nil and type(serviceSpec.recipes) == "table"
        for _, recipe in ipairs(snapshot.recipesReadable and serviceSpec.recipes or {}) do
            local primary = recipe.primaryOutputFillTypeIndex
            table.insert(snapshot.recipes, {
                id = recipe.id,
                inputs = copyAmounts(recipe.inputs),
                outputs = copyAmounts(recipe.outputs),
                primaryOutputFillType = primary,
                feePerBatch = recipe.feePerBatch,
                feeInputFillType = recipe.feeInputFillTypeIndex,
                shippedPrimaryAmount = recipe.rlShippedOutputAmounts ~= nil and primary ~= nil
                    and recipe.rlShippedOutputAmounts[primary] or nil,
                shippedFeePerBatch = recipe.rlShippedFeePerBatch,
            })
        end

        -- The order a delivery from this farm goes to, picked by the delivery code's own rule.
        snapshot.ordersReadable = serviceSpec ~= nil and type(serviceSpec.orders) == "table"
            and type(serviceSpec.recipeById) == "table"
        if snapshot.ordersReadable and farmId ~= nil and fillType ~= nil then
            local order = RLFacilityRules.selectContractOrder(serviceSpec.orders, serviceSpec.recipeById, farmId, fillType)
            if order ~= nil then
                local input = order.inputs ~= nil and order.inputs[fillType] or nil
                snapshot.order = { id = order.id, recipeId = order.recipeId, feeCredit = order.feeCredit,
                    buffered = input ~= nil and input.buffered or nil }
            end
        end
        if fillType ~= nil and farmId ~= nil and snapshot.weighted then
            snapshot.room = AnimalMoveEvent._getContractRoom(target, farmId, fillType)
        end
        if farmId ~= nil and g_currentMission ~= nil and g_currentMission.getMoney ~= nil then
            local ok, money = pcall(g_currentMission.getMoney, g_currentMission, farmId)
            if ok and type(money) == "number" and money == money then snapshot.money = money end
        end
        return snapshot
    end

    if type(target.animalsTypeData) == "table" and type(target.addCluster) == "function" then
        snapshot.kind = "PRODUCTION"
        snapshot.conversion = fillType ~= nil and AnimalMoveEvent._isAnimalConversionInput(target, fillType) or false
        local units = target.eppAnimalInputUnitsByFillType
        snapshot.scaled = target.eppHasScaledAnimalInputs == true and type(units) == "table"
            and fillType ~= nil and units[fillType] ~= nil
        snapshot.unitsPerAnimal = type(units) == "table" and fillType ~= nil and units[fillType] or nil
        snapshot.productionsReadable = type(target.productions) == "table"
        snapshot.productions = {}
        for _, production in ipairs(snapshot.productionsReadable and target.productions or {}) do
            table.insert(snapshot.productions, {
                id = production.id,
                inputs = copyAmounts(production.inputs),
                outputs = copyAmounts(production.outputs),
                costsPerActiveHour = production.costsPerActiveHour,
                cyclesPerHour = production.cyclesPerHour,
            })
        end
        return snapshot
    end

    return snapshot
end


-- =============================================================================
-- Description (pure)
-- =============================================================================

local function amountOf(list, fillType)
    for _, entry in ipairs(list or {}) do
        if entry.fillType == fillType then return entry.amount end
    end
    return nil
end


--- Shared input: types without a meat profile are a known mix (Hof Bergmann's MILKCOW next to
--- COW on BEEF); two types with different meat profiles cannot be told apart.
local function classifySharers(snapshot, role, description)
    local others = {}
    for _, sharer in ipairs(snapshot.sharers or {}) do
        if sharer.typeName ~= role.typeName then
            others[#others + 1] = sharer.typeName
            if sharer.meatPerHead == nil then
                table.insert(description.notes, "MIXED_INPUT:" .. sharer.typeName)
            elseif role.meatPerHead ~= nil and (not sameAmount(sharer.meatPerHead, role.meatPerHead)
                or sharer.meatFillType ~= role.meatFillType) then
                description.conflict = true
                table.insert(description.reasons, "SHARED_INPUT_CONFLICT:" .. sharer.typeName)
            else
                table.insert(description.notes, "SHARED_INPUT:" .. sharer.typeName)
            end
        end
    end
    description.sharedWith = others
end


--- Picks the contract recipe a delivery of this input goes to: the farm's open order's (picked
--- by RLFacilityRules in the snapshot). With no order a delivery is refused; the only recipe
--- that takes the input is still described, under NO_OPEN_ORDER (or NO_FARM). Several recipes
--- and no order: ambiguous.
local function pickContractRecipe(snapshot, description)
    local byId, candidates = {}, {}
    for _, recipe in ipairs(snapshot.recipes or {}) do
        byId[recipe.id] = recipe
        if amountOf(recipe.inputs, snapshot.inputFillType) ~= nil then candidates[#candidates + 1] = recipe end
    end

    local order = snapshot.order
    if order ~= nil and byId[order.recipeId] ~= nil then
        description.order = order
        return byId[order.recipeId], "order " .. tostring(order.id)
    end
    table.insert(description.reasons, snapshot.farmId == nil and "NO_FARM" or "NO_OPEN_ORDER")
    if #candidates == 1 then return candidates[1], "only recipe, no open order" end
    if #candidates == 0 then
        table.insert(description.reasons, snapshot.recipesReadable and "NO_RECIPE" or "RECIPES_UNREADABLE")
    else
        table.insert(description.reasons, "MULTIPLE_RECIPES")
    end
    return nil
end


--- Picks the farm butcher production for this input: single input, the role's meat as output
--- (RLFacilityRules, the delivery code's rule). The delivery code takes the first such
--- production; with more than one the quote is ambiguous, and what delivery would use is
--- reported beside it (description.deliveryRecipe).
local function pickProduction(snapshot, role, description)
    local matches = RLFacilityRules.getButcherProductions(snapshot.productions, snapshot.inputFillType, role.meatFillType)
    if #matches == 1 then return matches[1].production end
    if #matches == 0 then
        table.insert(description.reasons, snapshot.productionsReadable and "NO_RECIPE" or "RECIPES_UNREADABLE")
    else
        table.insert(description.reasons, "MULTIPLE_RECIPES")
        local first = matches[1]
        description.deliveryRecipe = { id = first.production.id, inputAmount = first.input.amount,
            meatAmount = first.output.amount, meatPerInputUnit = first.output.amount / first.input.amount }
        table.insert(description.notes, "DELIVERY_USES_FIRST:" .. tostring(first.production.id))
    end
    return nil
end


--- Fill in recipe, alignment and fee from a contract recipe.
local function describeContractRecipe(recipe, source, snapshot, role, description)
    local inputAmount = amountOf(recipe.inputs, snapshot.inputFillType)
    description.recipe = { id = recipe.id, source = source, inputAmount = inputAmount, inputs = #recipe.inputs,
        outputs = recipe.outputs, primaryOutputFillType = recipe.primaryOutputFillType,
        primaryOutputFillTypeName = fillTypeName(recipe.primaryOutputFillType),
        shippedPrimaryAmount = recipe.shippedPrimaryAmount, alignedAtLoad = recipe.shippedPrimaryAmount ~= nil }

    if #recipe.inputs ~= 1 then table.insert(description.reasons, "MULTI_INPUT_RECIPE") end
    if inputAmount == nil or inputAmount <= 0 then table.insert(description.reasons, "BAD_RECIPE_INPUT") end

    if role.meatFillType ~= nil then
        local meatAmount = amountOf(recipe.outputs, role.meatFillType)
        if meatAmount == nil then
            table.insert(description.reasons, "OUTPUT_NOT_MEAT:" .. tostring(description.recipe.primaryOutputFillTypeName))
        elseif inputAmount ~= nil and inputAmount > 0 then
            description.recipe.meatAmount = meatAmount
            description.recipe.meatPerInputUnit = meatAmount / inputAmount
            if role.meatPerHead ~= nil then
                -- One input unit is one typical animal, as delivery credits it.
                description.recipe.alignment = sameAmount(description.recipe.meatPerInputUnit, role.meatPerHead)
                    and "ALIGNED" or "MISALIGNED"
            end
        end
    end

    -- The fee is the recipe's per batch as it stands: the map's, plus the cutting fee and the
    -- difficulty multiplier when RLRM aligned it at load. Never added again here.
    if recipe.feeInputFillType == snapshot.inputFillType and (recipe.feePerBatch or 0) > 0 and inputAmount ~= nil and inputAmount > 0 then
        description.fee = { perBatch = recipe.feePerBatch, batchInput = inputAmount,
            shippedPerBatch = recipe.shippedFeePerBatch,
            source = recipe.shippedFeePerBatch ~= nil and "recipe feePerBatch (map fee + RLRM cutting fee, x difficulty, set at load)"
                or "recipe feePerBatch (map)" }
    else
        description.fee = { perBatch = 0, source = "none for this input" }
    end
end


--- What a facility does with an animal of this role. Pure: reads only its arguments.
--- @param snapshot table From snapshotFacility
--- @param role table From getRole
--- @return table description {semantics, unit, status, reasons, notes, recipe, fee, runCost, ...}
function RLTradeQuote.describeFacility(snapshot, role)
    local description = {
        facility = snapshot.name,
        kind = snapshot.kind,
        inputFillType = snapshot.inputFillType,
        inputFillTypeName = snapshot.inputFillTypeName,
        authoritative = snapshot.isServer == true,
        money = snapshot.money,
        minimumAge = snapshot.minimumAge,
        maximumAge = snapshot.maximumAge,
        reasons = {},
        notes = {},
        sharedWith = {},
    }
    local function finish(status) description.status = status return description end

    if snapshot.kind == "HUSBANDRY" then
        description.semantics, description.unit = RLTradeQuote.HEAD, "head"
        return finish(RLTradeQuote.SUPPORTED)
    end

    if snapshot.inputFillType == nil then
        table.insert(description.reasons, snapshot.kind == "UNKNOWN" and "UNKNOWN_FACILITY" or "NOT_ACCEPTED")
        return finish(RLTradeQuote.UNSUPPORTED)
    end

    if snapshot.kind == "PRODUCTION" and snapshot.conversion then
        description.semantics, description.unit = RLTradeQuote.ANIMAL_CONVERSION, "head (whole-animal conversion)"
        description.unitsPerAnimal = snapshot.unitsPerAnimal
        table.insert(description.notes, "NO_CARCASS_YIELD")
        return finish(RLTradeQuote.SUPPORTED)
    end

    classifySharers(snapshot, role, description)
    if role.meatPerHead == nil then table.insert(description.reasons, "NO_MEAT_PROFILE") end

    if snapshot.kind == "CONTRACT" then
        if snapshot.weighted then
            description.semantics = RLTradeQuote.WEIGHTED_BATCH
            description.unit = "standard batch input of " .. tostring(snapshot.inputFillTypeName) .. " (typical animals, not kg)"
        else
            description.semantics, description.unit = RLTradeQuote.HEAD, "head (one input unit each)"
        end
        local recipe, source = pickContractRecipe(snapshot, description)
        if recipe ~= nil then describeContractRecipe(recipe, source, snapshot, role, description) end
        description.room = snapshot.room
    elseif snapshot.kind == "PRODUCTION" then
        if not snapshot.scaled then
            description.semantics, description.unit = RLTradeQuote.HEAD, "head (unscaled production input)"
            description.unitsPerAnimal = snapshot.unitsPerAnimal
            table.insert(description.notes, "UNSCALED_INPUT")
            return finish(RLTradeQuote.UNKNOWN)
        end
        description.semantics = RLTradeQuote.PRODUCTION_UNIT
        description.unit = "production units of " .. tostring(snapshot.inputFillTypeName)
        description.unitsPerAnimal = snapshot.unitsPerAnimal
        local production = pickProduction(snapshot, role, description)
        if production ~= nil then
            local inputAmount = production.inputs[1].amount
            local meatAmount = amountOf(production.outputs, role.meatFillType)
            description.recipe = { id = production.id, source = "production", inputAmount = inputAmount,
                meatAmount = meatAmount, meatPerInputUnit = meatAmount / inputAmount, outputs = production.outputs }
            -- Delivery credits meatPerHead / ratio units per typical animal, so the butcher agrees with the model by construction.
            if role.meatPerHead ~= nil then
                description.recipe.unitsPerTypicalAnimal = role.meatPerHead / description.recipe.meatPerInputUnit
            end
            -- Running cost is per active hour while the production is on, whatever it makes:
            -- a nominal figure at full throughput with this production alone, not a fee.
            if (production.costsPerActiveHour or 0) > 0 and (production.cyclesPerHour or 0) > 0 then
                description.runCost = { costsPerActiveHour = production.costsPerActiveHour,
                    cyclesPerHour = production.cyclesPerHour,
                    perInputUnit = production.costsPerActiveHour / production.cyclesPerHour / inputAmount,
                    source = "production costsPerActiveHour (time-based, nominal at full throughput)" }
            end
        end
        description.fee = { perBatch = 0, source = "none (farm production)" }
    else
        table.insert(description.reasons, "UNKNOWN_FACILITY")
        return finish(RLTradeQuote.UNSUPPORTED)
    end

    local has = {}
    for _, reason in ipairs(description.reasons) do has[reason] = true end
    if description.conflict or has.MULTIPLE_RECIPES then return finish(RLTradeQuote.AMBIGUOUS) end
    if has.NO_MEAT_PROFILE then return finish(RLTradeQuote.UNSUPPORTED) end
    return finish(#description.reasons > 0 and RLTradeQuote.UNKNOWN or RLTradeQuote.SUPPORTED)
end


-- =============================================================================
-- Quote (pure)
-- =============================================================================

--- Quantities and fees of one animal at a described facility. Pure.
--- @param meat table RLMeatMath.compute result in this facility's context
--- @param meatReasons table RLMeatMath.check reasons
--- @param description table From describeFacility
--- @param animal table {age} frozen with the meat snapshot
--- @return table quote
function RLTradeQuote.quote(meat, meatReasons, description, animal)
    local quote = {
        facility = description.facility,
        semantics = description.semantics,
        unit = description.unit,
        status = description.status,
        authoritative = description.authoritative,
        reasons = {},
        notes = {},
        factor = meat ~= nil and meat.factor or nil,
        modelMeat = meat ~= nil and meat.modelMeat or nil,
        meatPerHead = meat ~= nil and meat.meatPerHead or nil,
        recipe = description.recipe,
        feeSource = description.fee ~= nil and description.fee.source or nil,
    }
    for _, reason in ipairs(description.reasons) do quote.reasons[#quote.reasons + 1] = reason end
    for _, note in ipairs(description.notes) do quote.notes[#quote.notes + 1] = note end
    for _, reason in ipairs(meatReasons or {}) do
        if reason ~= "NO_MEAT_PROFILE" or description.semantics == RLTradeQuote.ANIMAL_CONVERSION then
            quote.notes[#quote.notes + 1] = "MODEL:" .. reason
        end
    end
    -- A model built on a fallback is no authority for the difference.
    if #(meatReasons or {}) > 0 and quote.modelMeat ~= nil then quote.modelMeatUnsound = true end

    local age = animal ~= nil and animal.age or nil
    if age ~= nil and description.minimumAge ~= nil and age < description.minimumAge then
        quote.reasons[#quote.reasons + 1] = "TOO_YOUNG"
    elseif age ~= nil and description.maximumAge ~= nil and age > description.maximumAge then
        quote.reasons[#quote.reasons + 1] = "TOO_OLD"
    end

    local semantics = description.semantics
    local recipe = description.recipe
    local factor = quote.factor or 1

    if semantics == RLTradeQuote.HEAD and description.kind ~= "CONTRACT" then
        quote.inputQuantity = 1
    elseif semantics == RLTradeQuote.ANIMAL_CONVERSION then
        quote.inputQuantity = description.unitsPerAnimal or 1
        quote.unit = description.unit .. ", " .. tostring(description.unitsPerAnimal) .. " units per head"
    elseif semantics == RLTradeQuote.WEIGHTED_BATCH or semantics == RLTradeQuote.HEAD then
        -- Contract: the yield factor (weighted) or one unit (head) of the input fill type.
        quote.inputQuantity = semantics == RLTradeQuote.WEIGHTED_BATCH and factor or 1
        if recipe ~= nil and recipe.inputAmount ~= nil and recipe.inputAmount > 0 then
            quote.batches = quote.inputQuantity / recipe.inputAmount
            if recipe.meatAmount ~= nil and quote.status ~= RLTradeQuote.AMBIGUOUS then
                quote.effectiveRecipeMeat = quote.batches * recipe.meatAmount
            end
            local fee = description.fee
            if fee ~= nil and (fee.perBatch or 0) > 0 then
                quote.fee = RLFacilityRules.getBatchFee(quote.inputQuantity, recipe.inputAmount, fee.perBatch, true)
                local order = description.order
                if order ~= nil and type(order.feeCredit) == "number" then
                    quote.feeCreditUse, quote.cashDue = RLFacilityRules.splitFee(quote.fee, order.feeCredit)
                    -- The delivery code refuses what the farm's money cannot pay (the facility would take only part).
                    if description.money == nil then
                        quote.notes[#quote.notes + 1] = "WALLET_UNKNOWN"
                    elseif not RLFacilityRules.canPayCash(quote.cashDue, description.money) then
                        quote.reasons[#quote.reasons + 1] = "CANNOT_AFFORD"
                    end
                else
                    quote.notes[#quote.notes + 1] = order == nil and "CASH_DUE_UNKNOWN:no open order" or "CASH_DUE_UNKNOWN:credit unreadable"
                end
            else
                quote.fee = 0
            end
        end
        if description.room ~= nil and quote.inputQuantity > description.room + 0.001 then
            quote.reasons[#quote.reasons + 1] = "NO_ROOM"
        end
    elseif semantics == RLTradeQuote.PRODUCTION_UNIT then
        -- As AnimalMoveEvent._getScaledButcherUnits: meatPerHead / recipe ratio per typical
        -- animal, the configured units per animal when the recipe is not readable; x factor.
        local units = description.unitsPerAnimal
        if recipe ~= nil and recipe.meatPerInputUnit ~= nil and quote.meatPerHead ~= nil then
            units = quote.meatPerHead / recipe.meatPerInputUnit
        end
        -- Ambiguous recipe: no quantity of our own, but what the delivery code would credit
        -- through the first production is shown beside it.
        local delivery = description.deliveryRecipe
        if delivery ~= nil and quote.meatPerHead ~= nil then
            quote.deliveryInputQuantity = quote.meatPerHead / delivery.meatPerInputUnit * factor
            quote.deliveryRecipeId = delivery.id
        end
        if quote.status ~= RLTradeQuote.AMBIGUOUS and units ~= nil then
            quote.inputQuantity = units * factor
            if recipe ~= nil and recipe.meatPerInputUnit ~= nil then
                quote.effectiveRecipeMeat = quote.inputQuantity * recipe.meatPerInputUnit
            end
            quote.fee = 0
            if description.runCost ~= nil then
                quote.runCostEstimate = quote.inputQuantity * description.runCost.perInputUnit
                quote.runCostSource = description.runCost.source
            end
        end
    end

    if quote.effectiveRecipeMeat ~= nil and quote.modelMeat ~= nil then
        quote.difference = quote.effectiveRecipeMeat - quote.modelMeat
        quote.ratio = quote.modelMeat > 0 and quote.effectiveRecipeMeat / quote.modelMeat or nil
        quote.matches = sameAmount(quote.effectiveRecipeMeat, quote.modelMeat)
    end
    if quote.status == RLTradeQuote.SUPPORTED and #quote.reasons > 0 then quote.status = RLTradeQuote.UNKNOWN end
    return quote
end


--- Quote one live animal at a move target. Read-only glue over the three layers.
--- @param animal table The live animal
--- @param target table Move target
--- @param farmId number|nil Delivering farm
--- @return table quote
--- @return table description
function RLTradeQuote.quoteAnimal(animal, target, farmId)
    local subTypeIndex = animal.subTypeIndex
    -- Checked before computing: a value of the wrong type is named (BAD_INPUT:key), not thrown.
    local snapshot, params, formula = AnimalMoveEvent.getCarcassSnapshot(animal, target, subTypeIndex, true)
    local meatReasons = RLMeatMath.check(snapshot, params, formula)
    local meat
    local badInput = false
    for _, reason in ipairs(meatReasons) do
        if reason:sub(1, 10) == "BAD_INPUT:" then badInput = true end
    end
    if not badInput then meat = RLMeatMath.compute(snapshot, params, formula) end
    local facility = RLTradeQuote.snapshotFacility(target, subTypeIndex, farmId)
    local description = RLTradeQuote.describeFacility(facility, RLTradeQuote.getRole(subTypeIndex))
    local quote = RLTradeQuote.quote(meat, meatReasons, description, { age = animal.age })
    if badInput then
        for _, reason in ipairs(meatReasons) do
            if reason:sub(1, 10) == "BAD_INPUT:" then quote.reasons[#quote.reasons + 1] = "MODEL_" .. reason end
        end
        quote.inputQuantity, quote.effectiveRecipeMeat, quote.fee, quote.cashDue = nil, nil, nil, nil
        quote.status = RLTradeQuote.UNKNOWN
    end
    return quote, description
end
