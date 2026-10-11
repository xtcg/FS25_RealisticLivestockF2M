-- Frozen copy of the carcass yield functions at dev 9be38812da1cd75d0ee954fd0d71f62c784082e5
-- (scripts/animals/shop/events/AnimalMoveEvent.lua getFacilityMeanTargetWeight,
-- getCarcassReferenceWeight, getCarcassYieldFactor; scripts/animal/RLMeatValue.lua getMeatKg),
-- renamed onto LegacyCarcass: the oracle tests/test_meatmath.lua checks RLMeatMath and the
-- refactored entry points against. Do not edit: it is the baseline, not the code under test.
-- Only the function names changed; config, layers and body condition are read as they were.

LegacyCarcass = {}

--- Mean target weight of the subtypes a facility maps to the same input fill type as this one;
--- the subtype's own target weight when the facility has no mapping for it.
--- @return number|nil
function LegacyCarcass.getFacilityMeanTargetWeight(targetObject, subTypeIndex)
	local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
	if animalSystem == nil then return nil end

	local subType = animalSystem:getSubTypeByIndex(subTypeIndex)
	local subTypeToFillType = targetObject ~= nil and targetObject.animalSubTypeToFillType or nil
	local fillType = subTypeToFillType ~= nil and subTypeToFillType[subTypeIndex] or nil
	if fillType == nil then return subType ~= nil and subType.targetWeight or nil end

	local total, count = 0, 0
	for otherIndex, otherFillType in pairs(subTypeToFillType) do
		local other = otherFillType == fillType and animalSystem:getSubTypeByIndex(otherIndex) or nil
		if other ~= nil and other.targetWeight ~= nil and other.targetWeight > 0 then
			total, count = total + other.targetWeight, count + 1
		end
	end
	return count > 0 and total / count or nil
end


--- The slaughter reference weight of an animal (its own target weight x maleMaturity /
--- femaleMaturity, or a configured referenceWeight, else the facility's mean) and the anchor
--- weight its size is measured against. Also the weight the body condition's finishing curve
--- (RLBodyCondition) reads a bull's progress against.
--- @param animal table
--- @param targetObject table|nil The receiving facility
--- @param subTypeIndex number|nil
--- @return number|nil reference
--- @return number|nil anchor
function LegacyCarcass.getCarcassReferenceWeight(animal, targetObject, subTypeIndex)
	if animal == nil then return nil, nil end

	local config = AnimalMoveEvent.getCarcassConfig()
	local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
	local subType = animalSystem ~= nil and animalSystem:getSubTypeByIndex(subTypeIndex or animal.subTypeIndex) or nil
	local defaults = AnimalMoveEvent.CARCASS_ATTRIBUTE_DEFAULTS

	local function get(attr)
		return RLBreedTraits.resolve(config.layers, subType, attr, defaults[attr])
	end

	local facilityMean
	local function getFacilityMean()
		if facilityMean == nil then
			facilityMean = LegacyCarcass.getFacilityMeanTargetWeight(targetObject, subTypeIndex or animal.subTypeIndex) or false
		end
		return facilityMean or nil
	end

	local targetWeight = animal.targetWeight or (subType ~= nil and subType.targetWeight) or nil
	local maturity = get(animal.gender == "male" and "maleMaturity" or "femaleMaturity")
	local reference = get("referenceWeight")
		or (targetWeight ~= nil and targetWeight > 0 and targetWeight * maturity)
		or getFacilityMean()
	local anchor = get("anchorWeight") or getFacilityMean() or reference

	return reference, anchor
end


--- Carcass yield of one animal in "typical animals", the units a facility is configured for
--- per head:
---
---   reference = the animal's own target weight x maleMaturity / femaleMaturity
---               (or a configured referenceWeight)
---   size      = clamp((reference / anchorWeight) ^ sizeExponent, minSizeFactor, maxSizeFactor)
---   weight    = clamp((live weight / reference) ^ finishExponent, minFinishFactor, maxFinishFactor)
---   yield     = size x weight x carcassFactor x (1 + qualitySwing x (meat gene - 1)) x condition
---
--- So a larger-framed breed finished to its own reference yields more than a smaller one, but
--- less than in proportion. A type without an anchorWeight uses the mean target weight of the
--- subtypes the facility takes as the same fill type. finishExponent and its bounds keep their
--- names but measure weight completion only; how well finished the animal is comes from its
--- body condition (RLBodyCondition.getYieldFactor: 1 in the moderate finish band, less when
--- lean or overfat), applied here once so meat kg, both slaughter routes and the live price's
--- slaughter floor all see it.
---
--- The meat gene (0.25-1.75, 1 = average) prices the animal in Animal:getSellPrice. It is read
--- as carcass merit here because a facility's meat fill type carries no grade to price it by.
--- @param animal table|nil The live server Animal
--- @param targetObject table|nil The receiving facility
--- @param subTypeIndex number|nil
--- @return number factor
function LegacyCarcass.getCarcassYieldFactor(animal, targetObject, subTypeIndex)
	if animal == nil then return 1 end

	local config = AnimalMoveEvent.getCarcassConfig()
	local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
	local subType = animalSystem ~= nil and animalSystem:getSubTypeByIndex(subTypeIndex or animal.subTypeIndex) or nil
	local defaults = AnimalMoveEvent.CARCASS_ATTRIBUTE_DEFAULTS

	local function get(attr)
		return RLBreedTraits.resolve(config.layers, subType, attr, defaults[attr])
	end

	local reference, anchor = LegacyCarcass.getCarcassReferenceWeight(animal, targetObject, subTypeIndex)

	local size, weightCompletion = 1, 1
	if reference ~= nil and reference > 0 then
		if anchor ~= nil and anchor > 0 then
			size = math.clamp((reference / anchor) ^ config.sizeExponent, config.minSizeFactor, config.maxSizeFactor)
		end
		if animal.weight ~= nil then
			weightCompletion = math.clamp((animal.weight / reference) ^ config.finishExponent, config.minFinishFactor,
				config.maxFinishFactor)
		end
	end

	local quality = animal.genetics ~= nil and animal.genetics.quality or 1
	local condition = RLBodyCondition ~= nil and RLBodyCondition.getYieldFactor(animal) or 1
	return size * weightCompletion * get("carcassFactor") * (1 + get("qualitySwing") * (quality - 1)) * condition
end


--- Kilograms of meat the animal would give at the farm butcher, or 0 when it is too young to
--- be slaughtered or its type sets no meatPerHead.
--- @param animal table
--- @param subType table|nil
--- @return number
function LegacyCarcass.getMeatKg(animal, subType)
    local config = AnimalMoveEvent.getCarcassConfig()
    local minAge = RLBreedTraits.resolve(config.layers, subType, "slaughterMinAgeMonth", 0)
    if (animal.age or 0) < minAge then return 0 end

    local meatPerHead = AnimalMoveEvent.getMeatPerHead(RLBreedTraits.getTypeName(subType))
    if meatPerHead == nil then return 0 end
    return LegacyCarcass.getCarcassYieldFactor(animal, nil, animal.subTypeIndex) * meatPerHead
end
