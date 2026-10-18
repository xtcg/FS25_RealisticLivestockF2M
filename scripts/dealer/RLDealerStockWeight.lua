--[[
    RLDealerStockWeight.lua
    The weight of the dealer's own stock (the sale pool AnimalSystem:createNewSaleAnimal fills,
    DEALER-WEIGHT-SPREAD-01): its breed's growth curve (weightProfiles.xml) at its age with its
    genes, the curve a source farm's standard rearing follows, also while its species' curves
    (PIG, SHEEP) are switched off for the pens. The old rules' line instead swung with the
    metabolism gene (a 3-month Landrace gilt 15-138 kg, mean 64 against the curve's 39), and a
    listed animal aged a month a shelf day without gaining (an 8-month gilt at 28 kg).

    New stock: the curve's weight (an animal the model covers already has it, Animal.new). On the
    shelf: each month it ages it gains what the curve gains (its own offset to the curve is kept,
    never cut). Either way one warning when it is more than WARN_DEVIATION off its breed's curve
    for standard genes (an engineering threshold, not a biological one). A subtype without a curve
    (a goat, horses, poultry) and a game with the weight model off keep the old rules' weight.
]]

RLDealerStockWeight = {}

local W = RLDealerStockWeight
local Log = RmLogging.getLogger("RLRM")

--- Off its breed curve for standard genes by more than this share: logged once per animal.
W.WARN_DEVIATION = 0.25


--- The profile a subtype grows on, also while its type's curves are off for the pens; nil
--- without the weight model or a profile for the subtype.
--- @param subType table|nil
--- @return table|nil binding
function W.getBinding(subType)
    if subType == nil or RLGrowth == nil or RLWeightProfiles == nil or not RLGrowth.isEnabled() then return nil end
    return RLGrowth.getBinding(subType) or RLWeightProfiles.getCurveBinding(subType, true)
end


--- The breed curve of an animal of `subType` with a metabolism gene (1: standard genes).
--- @return table|nil curve RLGrowthCurve
function W.getCurve(subType, metabolism)
    local binding = W.getBinding(subType)
    if binding == nil then return nil end
    local size, _, _, birth = RLGrowth.getGeneFactors(metabolism or 1, subType)
    return RLGrowth.buildCurve(binding, RLGrowth.getAdultReference(binding) * size, RLGrowth.getBirthMean(binding) * birth)
end


--- The breed curve's weight for standard genes at an age (months); nil without a curve.
function W.getStandardWeight(subType, age)
    local curve = W.getCurve(subType, 1)
    return curve ~= nil and curve:value(math.max(age or 0, 0)) or nil
end


local function describe(animal, subType)
    return string.format("%s %s/%s age %s", tostring(subType ~= nil and subType.name or "?"), tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(animal.age))
end


--- How far an animal is off its breed curve for standard genes (weight / curve - 1), with one
--- warning per animal past WARN_DEVIATION. nil without a curve.
--- @param animal table
--- @param subType table
--- @param stage string "NEW" or "SHELF", for the log
--- @return number|nil deviation
function W.check(animal, subType, stage)
    local standard = W.getStandardWeight(subType, animal.age)
    if standard == nil or standard <= 0 or animal.weight == nil then return nil end
    local deviation = animal.weight / standard - 1
    if math.abs(deviation) > W.WARN_DEVIATION then
        if not animal.rlDealerWeightWarned then
            animal.rlDealerWeightWarned = true
            Log:warning("Dealer stock %s weighs %.1f kg, %+.0f%% off its breed curve's %.1f kg for standard genes (%s, metabolism %.2f)",
                describe(animal, subType), animal.weight, deviation * 100, standard, stage,
                animal.genetics ~= nil and animal.genetics.metabolism or 1)
        end
    else
        animal.rlDealerWeightWarned = nil
    end
    return deviation
end


--- A new listing (AnimalSystem:_tryCreateSaleAnimal, right after Animal.new): its weight is its
--- breed curve's at its age with its genes. Not above the old rules' own target weight for an
--- animal the model does not cover (they would pull it back down).
--- @param animal table
--- @param subType table
--- @return number|nil deviation (W.check)
function W.applyToNewStock(animal, subType)
    if animal == nil or subType == nil then return nil end
    -- Covered by the model: Animal.new gave it its curve's weight and a generated state.
    if animal.rlGrowth == nil and animal.genetics ~= nil then
        local curve = W.getCurve(subType, animal.genetics.metabolism)
        if curve ~= nil then
            local weight = curve:value(math.max(animal.age or 0, 0))
            if animal.targetWeight ~= nil and animal.targetWeight > 0 then weight = math.min(weight, animal.targetWeight) end
            animal.weight = weight
        end
    end
    return W.check(animal, subType, "NEW")
end


--- A listed animal aged on the shelf (AnimalSystem:onDayChanged, server): it gains what its curve
--- gains from `oldAge` to its age, as its source farm's standard rearing would. Never loses weight.
--- An animal the model covers gets its generated state again at its new age and weight.
--- @param animal table
--- @param oldAge number Months before the day's ageing
function W.onShelfAged(animal, oldAge)
    if animal == nil or animal.age == nil or oldAge == nil or animal.age <= oldAge or animal.isDead then return end
    local subType = animal.getSubType ~= nil and animal:getSubType() or nil
    local curve = subType ~= nil and animal.genetics ~= nil and W.getCurve(subType, animal.genetics.metabolism) or nil
    if curve == nil then return end
    local gain = math.max(curve:value(animal.age) - curve:value(math.max(oldAge, 0)), 0)
    local weight = animal.weight + gain
    if animal.rlGrowth == nil and animal.targetWeight ~= nil and animal.targetWeight > 0 then
        weight = math.min(weight, math.max(animal.targetWeight, animal.weight))
    end
    animal.weight = weight
    if animal.rlGrowth ~= nil and animal.rlGrowth.source == "generated" and RLGrowth.covers(animal) then
        -- Daily pool progression owns the clock; a birthday's weight refresh must not reset it.
        local ageMonths = animal.rlGrowth.ageMonths
        animal.rlGrowth = RLGrowth.createGeneratedState(animal)
        if ageMonths ~= nil then animal.rlGrowth.ageMonths = ageMonths end
    end
    W.check(animal, subType, "SHELF")
end
