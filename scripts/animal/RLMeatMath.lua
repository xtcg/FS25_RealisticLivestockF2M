--[[
    Carcass yield and model meat of one animal as pure arithmetic over a frozen snapshot.

        reference = params.referenceWeight, or targetWeight x maleMaturity / femaleMaturity,
                    or the facility mean
        anchor    = params.anchorWeight, or the facility mean, or reference
        size      = clamp((reference / anchor) ^ sizeExponent, minSizeFactor, maxSizeFactor)
        weight    = clamp((weight / reference) ^ finishExponent, minFinishFactor, maxFinishFactor)
        quality   = 1 + qualitySwing x (meat gene - 1)
        factor    = size x weight x carcassFactor x quality x condition    ("typical animals")
        modelMeat = factor x meatPerHead                                   (kg of the meat fill type)

    Nothing here reads a game global, loads a config, sets up animal state or rolls a random
    number: AnimalMoveEvent.getCarcassSnapshot reads the animal, the resolved carcassYield
    parameters, the facility mean and the body condition factor; these functions only compute.
    compute() keeps the old entry points' fallbacks (size and weight completion 1 when the
    reference is missing, a missing weight counts as complete) so their results do not change;
    check() is the strict side for diagnostics, and names what a quote cannot rely on instead of
    correcting it.
]]

RLMeatMath = {}


--- Whether the reference or anchor falls back to the facility mean for these inputs, so the
--- snapshot reads it only when the old code would have.
--- @param snapshot table {targetWeight}
--- @param params table Resolved parameters
--- @return boolean
function RLMeatMath.needsFacilityMean(snapshot, params)
    if params.anchorWeight == nil then return true end
    local targetWeight = snapshot.targetWeight
    return params.referenceWeight == nil and not (type(targetWeight) == "number" and targetWeight > 0)
end


--- Reference and anchor weight.
--- @param snapshot table {targetWeight, gender, facilityMean}
--- @param params table {referenceWeight, anchorWeight, maleMaturity, femaleMaturity}
--- @return number|nil reference
--- @return number|nil anchor
function RLMeatMath.getReference(snapshot, params)
    local targetWeight = snapshot.targetWeight
    local maturity = snapshot.gender == "male" and params.maleMaturity or params.femaleMaturity
    local facilityMean = snapshot.facilityMean
    local reference = params.referenceWeight
        or (targetWeight ~= nil and targetWeight > 0 and targetWeight * maturity)
        or facilityMean
    local anchor = params.anchorWeight or facilityMean or reference
    return reference, anchor
end


--- Every step of the carcass yield.
--- @param snapshot table {weight, targetWeight, gender, quality, conditionFactor, facilityMean}
--- @param params table Resolved parameters; meatPerHead may be nil (no model meat then)
--- @param formula table {sizeExponent, minSizeFactor, maxSizeFactor, finishExponent, minFinishFactor, maxFinishFactor}
--- @return table result {reference, anchor, size, weightCompletion, qualityFactor, conditionFactor, factor, meatPerHead, modelMeat}
function RLMeatMath.compute(snapshot, params, formula)
    local reference, anchor = RLMeatMath.getReference(snapshot, params)

    local size, weightCompletion = 1, 1
    if reference ~= nil and reference > 0 then
        if anchor ~= nil and anchor > 0 then
            size = math.clamp((reference / anchor) ^ formula.sizeExponent, formula.minSizeFactor, formula.maxSizeFactor)
        end
        if snapshot.weight ~= nil then
            weightCompletion = math.clamp((snapshot.weight / reference) ^ formula.finishExponent, formula.minFinishFactor,
                formula.maxFinishFactor)
        end
    end

    local qualityFactor = 1 + params.qualitySwing * ((snapshot.quality or 1) - 1)
    local conditionFactor = snapshot.conditionFactor or 1
    -- Same order of multiplication as the old single expression, so the result is the same double.
    local factor = size * weightCompletion * params.carcassFactor * qualityFactor * conditionFactor

    return {
        reference = reference,
        anchor = anchor,
        size = size,
        weightCompletion = weightCompletion,
        qualityFactor = qualityFactor,
        conditionFactor = conditionFactor,
        factor = factor,
        meatPerHead = params.meatPerHead,
        modelMeat = params.meatPerHead ~= nil and factor * params.meatPerHead or nil,
    }
end


local isFinite=RLPlain.finite


--- What a quote cannot rely on: the reasons compute() would have fallen back or produced a
--- value that is no meat yield. Empty when the inputs and result are sound.
--- @param snapshot table
--- @param params table
--- @param formula table
--- @param result table|nil From compute(); computed when nil
--- @return table reasons Array of reason codes
function RLMeatMath.check(snapshot, params, formula, result)
    local reasons = {}
    local function add(code) reasons[#reasons + 1] = code end

    -- A value of the wrong type would make compute() itself fail: named, nothing computed.
    local numeric = {
        { snapshot, { "weight", "targetWeight", "quality", "conditionFactor", "facilityMean" } },
        { params, { "referenceWeight", "anchorWeight", "maleMaturity", "femaleMaturity", "carcassFactor", "qualitySwing", "meatPerHead" } },
        { formula, { "sizeExponent", "minSizeFactor", "maxSizeFactor", "finishExponent", "minFinishFactor", "maxFinishFactor" } },
    }
    for _, group in ipairs(numeric) do
        for _, key in ipairs(group[2]) do
            local value = group[1][key]
            if value ~= nil and type(value) ~= "number" then add("BAD_INPUT:" .. key) end
        end
    end
    -- compute() needs these whatever else is missing.
    local maturity = snapshot.gender == "male" and "maleMaturity" or "femaleMaturity"
    for _, required in ipairs({ { params, "carcassFactor" }, { params, "qualitySwing" }, { params, maturity },
        { formula, "sizeExponent" }, { formula, "minSizeFactor" }, { formula, "maxSizeFactor" },
        { formula, "finishExponent" }, { formula, "minFinishFactor" }, { formula, "maxFinishFactor" } }) do
        if required[1][required[2]] == nil then add("BAD_INPUT:" .. required[2]) end
    end
    if #reasons > 0 then return reasons end

    result = result or RLMeatMath.compute(snapshot, params, formula)

    if params.meatPerHead == nil then add("NO_MEAT_PROFILE")
    elseif not isFinite(params.meatPerHead) or params.meatPerHead <= 0 then add("BAD_MEAT_PER_HEAD") end
    if not isFinite(snapshot.weight) or snapshot.weight <= 0 then add("NO_WEIGHT") end
    if not isFinite(result.reference) or result.reference <= 0 then add("NO_REFERENCE") end
    if not isFinite(result.anchor) or result.anchor <= 0 then add("NO_ANCHOR") end
    if not isFinite(params.carcassFactor) or params.carcassFactor <= 0 then add("BAD_CARCASS_FACTOR") end
    if not isFinite(params.qualitySwing) then add("BAD_QUALITY_SWING") end
    if not isFinite(snapshot.quality) then add("BAD_QUALITY") end
    if not isFinite(result.qualityFactor) or result.qualityFactor <= 0 then add("BAD_QUALITY_FACTOR") end
    if not isFinite(result.conditionFactor) or result.conditionFactor < 0 then add("BAD_CONDITION_FACTOR") end
    for _, bounds in ipairs({ { "minSizeFactor", "maxSizeFactor" }, { "minFinishFactor", "maxFinishFactor" } }) do
        local low, high = formula[bounds[1]], formula[bounds[2]]
        if not isFinite(low) or not isFinite(high) or low > high then add("BAD_FORMULA_BOUNDS") break end
    end
    if not isFinite(result.factor) or result.factor < 0 then add("BAD_FACTOR") end

    return reasons
end
