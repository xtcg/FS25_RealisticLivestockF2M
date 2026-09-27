local Log = RmLogging.getLogger("RLRM")

--- Log a one-line snapshot of a cluster husbandry's visual-count state.
--- Used by AnimalMoveEvent:run to make source/target visual-count drift
--- observable in the log on every move.
--- Trailer cluster systems have no clusterHusbandry; logged as "no clusterHusbandry".
--- @param side string "source" | "target"
--- @param stage string "before" | "after"
--- @param clusterSystem table The cluster system to inspect
function AnimalMoveEvent._logVisualCountSnapshot(side, stage, clusterSystem)
	local owner = clusterSystem and clusterSystem.owner
	local spec = owner and owner.spec_husbandryAnimals
	local clusterHusbandry = spec and spec.clusterHusbandry
	local ownerName = owner and owner.getName and owner:getName() or tostring(owner)

	if clusterHusbandry == nil then
		Log:debug("AnimalMoveEvent snapshot: side=%s stage=%s owner=%s (no clusterHusbandry)",
			side, stage, tostring(ownerName))
		return
	end

	local visualCount = clusterHusbandry.visualAnimalCount or 0
	local slotsParts = {}
	if type(clusterHusbandry.husbandryIdsToVisualAnimalCount) == "table" then
		for engineId, count in pairs(clusterHusbandry.husbandryIdsToVisualAnimalCount) do
			table.insert(slotsParts, string.format("%s=%s", tostring(engineId), tostring(count)))
		end
	end
	Log:debug("AnimalMoveEvent snapshot: side=%s stage=%s owner=%s visualCount=%d slots=[%s]",
		side, stage, tostring(ownerName), visualCount, table.concat(slotsParts, ","))
end

--- Abort reason when an EPP target ran without error but credited nothing (full storage,
--- no open contract order). Mapped to MOVE_ERROR_NOT_ENOUGH_SPACE for the client.
AnimalMoveEvent.EPP_NOT_ACCEPTED = "EPP target did not accept the animal"

--- Carcass yield settings, read from xml/carcassYield.xml, or from carcassYield.xml in this
--- mod's modSettings folder when that exists (it then replaces the shipped file). Yield is
--- worked out on the server, so the server's file is the one that counts. Loaded on first use.
AnimalMoveEvent.CARCASS_CONFIG_FILE = "carcassYield.xml"

--- Formula settings on the carcassYield element; used for whatever the file leaves out.
AnimalMoveEvent.CARCASS_CONFIG_DEFAULTS = {
	sizeExponent = 0.25,
	minSizeFactor = 0.88,
	maxSizeFactor = 1.15,
	finishExponent = 0.85,
	minFinishFactor = 0.5,
	maxFinishFactor = 1.3,
}

--- Per-animal settings, looked up subtype, then breed within the animal type, then animal type,
--- then on the carcassYield element (RLBreedTraits.resolve).
AnimalMoveEvent.CARCASS_ATTRIBUTES = { "anchorWeight", "referenceWeight", "maleMaturity", "femaleMaturity",
	"carcassFactor", "qualitySwing" }

--- Used when no layer sets them.
AnimalMoveEvent.CARCASS_ATTRIBUTE_DEFAULTS = { maleMaturity = 1, femaleMaturity = 1, carcassFactor = 1, qualitySwing = 0.2 }


--- Read a carcass yield config.
--- @param xmlFile table|nil An XMLFile with a carcassYield root; nil gives the defaults
--- @return table config The formula settings plus layers (RLBreedTraits.parseLayers)
function AnimalMoveEvent.parseCarcassConfig(xmlFile)
	local config = table.clone(AnimalMoveEvent.CARCASS_CONFIG_DEFAULTS)
	if xmlFile ~= nil then
		for key, default in pairs(AnimalMoveEvent.CARCASS_CONFIG_DEFAULTS) do
			config[key] = xmlFile:getFloat("carcassYield#" .. key, default)
		end
	end
	config.layers = RLBreedTraits.parseLayers(xmlFile, "carcassYield", AnimalMoveEvent.CARCASS_ATTRIBUTES)

	return config
end


--- The carcass yield config, loaded on the first call.
--- @return table config See parseCarcassConfig
function AnimalMoveEvent.getCarcassConfig()
	if AnimalMoveEvent.carcassConfig == nil then
		AnimalMoveEvent.carcassConfig = RLBreedTraits.loadConfig(AnimalMoveEvent.CARCASS_CONFIG_FILE, "carcassYield",
			AnimalMoveEvent.parseCarcassConfig)
	end
	return AnimalMoveEvent.carcassConfig
end


--- Mean target weight of the subtypes a facility maps to the same input fill type as this one;
--- the subtype's own target weight when the facility has no mapping for it.
--- @return number|nil
function AnimalMoveEvent.getFacilityMeanTargetWeight(targetObject, subTypeIndex)
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


--- Carcass yield of one animal in "typical animals", the units a facility is configured for
--- per head:
---
---   reference = the animal's own target weight x maleMaturity / femaleMaturity
---               (or a configured referenceWeight)
---   size      = clamp((reference / anchorWeight) ^ sizeExponent, minSizeFactor, maxSizeFactor)
---   finish    = clamp((live weight / reference) ^ finishExponent, minFinishFactor, maxFinishFactor)
---   yield     = size x finish x carcassFactor x (1 + qualitySwing x (meat gene - 1))
---
--- So a larger-framed breed finished to its own reference yields more than a smaller one, but
--- less than in proportion. A type without an anchorWeight uses the mean target weight of the
--- subtypes the facility takes as the same fill type.
---
--- The meat gene (0.25-1.75, 1 = average) prices the animal in Animal:getSellPrice. It is read
--- as carcass merit here because a facility's meat fill type carries no grade to price it by.
--- @param animal table|nil The live server Animal
--- @param targetObject table|nil The receiving facility
--- @param subTypeIndex number|nil
--- @return number factor
function AnimalMoveEvent.getCarcassYieldFactor(animal, targetObject, subTypeIndex)
	if animal == nil then return 1 end

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
			facilityMean = AnimalMoveEvent.getFacilityMeanTargetWeight(targetObject, subTypeIndex or animal.subTypeIndex) or false
		end
		return facilityMean or nil
	end

	local targetWeight = animal.targetWeight or (subType ~= nil and subType.targetWeight) or nil
	local maturity = get(animal.gender == "male" and "maleMaturity" or "femaleMaturity")
	local reference = get("referenceWeight")
		or (targetWeight ~= nil and targetWeight > 0 and targetWeight * maturity)
		or getFacilityMean()
	local anchor = get("anchorWeight") or getFacilityMean() or reference

	local size, finish = 1, 1
	if reference ~= nil and reference > 0 then
		if anchor ~= nil and anchor > 0 then
			size = math.clamp((reference / anchor) ^ config.sizeExponent, config.minSizeFactor, config.maxSizeFactor)
		end
		if animal.weight ~= nil then
			finish = math.clamp((animal.weight / reference) ^ config.finishExponent, config.minFinishFactor,
				config.maxFinishFactor)
		end
	end

	local quality = animal.genetics ~= nil and animal.genetics.quality or 1
	return size * finish * get("carcassFactor") * (1 + get("qualitySwing") * (quality - 1))
end


--- A unit-based butcher's configured units per animal (Hof Bergmann's farm butcher,
--- `animalInput.animal#unitsPerAnimal`) and what this animal is worth in them.
--- @return number|nil fillType nil when the target is no unit-based butcher for this subtype
--- @return number configured
--- @return number scaled
function AnimalMoveEvent._getScaledButcherUnits(targetObject, subTypeIndex, animal)
	local unitsByFillType = targetObject.eppAnimalInputUnitsByFillType
	local fillType = targetObject.animalSubTypeToFillType ~= nil and targetObject.animalSubTypeToFillType[subTypeIndex] or nil
	if targetObject.eppHasScaledAnimalInputs ~= true or type(unitsByFillType) ~= "table"
		or fillType == nil or unitsByFillType[fillType] == nil then
		return nil
	end

	if AnimalMoveEvent._isAnimalConversionInput(targetObject, fillType) then return nil end

	local configured = unitsByFillType[fillType]
	local factor = AnimalMoveEvent.getCarcassYieldFactor(animal, targetObject, subTypeIndex)
	return fillType, configured, configured * factor
end


--- Whether a production point turns this input back into live animals (Hof Bergmann's
--- insemination system: COW_HOLSTEIN in, MILK_COW out at 1000 units per animal). Such an
--- input is a head count, not meat, so carcass yield must not scale it - a light cow would
--- otherwise come out as less than one animal.
function AnimalMoveEvent._isAnimalConversionInput(targetObject, fillType)
	for _, spec in ipairs(targetObject.eao_specs or {}) do
		for _, mapping in ipairs(spec.animals or {}) do
			if mapping.inputFillTypeIndex == fillType then return true end
		end
	end
	return false
end


--- Scale a unit-based butcher's units per animal to this animal's yield for one addCluster
--- call. The target reads the table live, so its own capacity and storage logic stays
--- authoritative.
--- @return function|nil restore Puts the configured value back; nil when nothing was changed
function AnimalMoveEvent._applyCarcassYield(targetObject, subTypeIndex, animal)
	local fillType, configured, scaled = AnimalMoveEvent._getScaledButcherUnits(targetObject, subTypeIndex, animal)
	if fillType == nil then return nil end

	local unitsByFillType = targetObject.eppAnimalInputUnitsByFillType
	unitsByFillType[fillType] = scaled
	Log:debug("AnimalMoveEvent._applyCarcassYield: fillType=%s units %.1f -> %.1f (weight=%s)",
		tostring(fillType), configured, scaled, tostring(animal and animal.weight))

	return function() unitsByFillType[fillType] = configured end
end


--- The contract order a delivery of `fillType` goes to and its per-batch fee for `amount`.
--- Picks the order the facility's contractProductionDeliver picks: the farm's lowest-id order
--- whose recipe takes the fill type.
--- @return table|nil order nil when the facility's order data is not readable or has no match
--- @return number fee 0 when the fill type carries no fee
function AnimalMoveEvent._getContractFee(targetObject, farmId, fillType, amount)
	local serviceSpec = targetObject.spec_contractProductionService
	if serviceSpec == nil or serviceSpec.orders == nil or serviceSpec.recipeById == nil then return nil, 0 end

	local order, recipeInput, recipe
	for _, candidate in pairs(serviceSpec.orders) do
		local candidateRecipe = candidate.farmId == farmId and serviceSpec.recipeById[candidate.recipeId] or nil
		local input = candidateRecipe ~= nil and candidateRecipe.inputs ~= nil and candidateRecipe.inputs[fillType] or nil
		if input ~= nil and (order == nil or (candidate.id or 0) < (order.id or 0)) then
			order, recipeInput, recipe = candidate, input, candidateRecipe
		end
	end
	if order == nil or fillType ~= recipe.feeInputFillTypeIndex or (recipe.feePerBatch or 0) <= 0 then return order, 0 end
	return order, amount / recipeInput.amount * recipe.feePerBatch
end


--- Whether a farm can pay a contract facility's per-batch fees for a delivery. Mirrors the
--- facility's own budget rule - each order's unused fee credit first, then the farm's money,
--- which all orders share - so a weighted delivery is refused up front instead of being
--- credited only in part. True when the facility's order data is not readable - it then
--- applies its own limit.
--- @param amountByFillType table {[fillType] = amount} for everything delivered together
function AnimalMoveEvent._canAffordContractInputs(targetObject, farmId, amountByFillType)
	local feeByOrder = {}
	for fillType, amount in pairs(amountByFillType) do
		local order, fee = AnimalMoveEvent._getContractFee(targetObject, farmId, fillType, amount)
		if order ~= nil and fee > 0 then feeByOrder[order] = (feeByOrder[order] or 0) + fee end
	end

	local cash = 0
	for order, fee in pairs(feeByOrder) do
		cash = cash + math.max(fee - math.max(order.feeCredit or 0, 0), 0)
	end
	return cash <= 0.001 or math.max(g_currentMission:getMoney(farmId), 0) + 0.001 >= cash
end


--- Whether a target is a contract facility that takes weighted deliveries from this farm.
function AnimalMoveEvent._isWeighedContractTarget(targetObject, farmId)
	return farmId ~= nil and type(targetObject.contractProductionAddAnimals) == "function"
		and type(targetObject.contractProductionDeliver) == "function"
		and type(targetObject.contractProductionGetAnimalFreeSlots) == "function"
end


--- Room left in a farm's contract order input, in "typical animals". The facility caps what
--- sits unprocessed in a farm's orders at getCapacity (its maxAnimalsPerType); its own free
--- slot count rounds that down to whole heads.
--- @return number|nil room nil when the order data is not readable
function AnimalMoveEvent._getContractRoom(targetObject, farmId, fillType)
	local serviceSpec = targetObject.spec_contractProductionService
	if serviceSpec == nil or serviceSpec.orders == nil or type(targetObject.getCapacity) ~= "function" then return nil end

	local buffered = 0
	for _, order in pairs(serviceSpec.orders) do
		local input = order.farmId == farmId and order.inputs ~= nil and order.inputs[fillType] or nil
		buffered = buffered + (input ~= nil and input.buffered or 0)
	end
	return (targetObject:getCapacity(fillType) or 0) - buffered
end


--- Deliver one animal to a contract facility (Hof Bergmann's public slaughterhouse) as its
--- carcass yield in "typical animals", so the open order's meat output and per-head fee scale
--- with it. Falls back to one whole animal when the facility lacks the bulk deliver call.
---
--- Room and order checks are for the whole batch, in _canTakeEPPBatch: the facility's free
--- slots are whole heads, so checking them per animal would turn away a light animal that
--- still fits.
--- @return number accepted 1 when the animal was taken, else 0
function AnimalMoveEvent._deliverToContractTarget(targetObject, subTypeIndex, animal, farmId)
	local fillType = targetObject.animalSubTypeToFillType ~= nil and targetObject.animalSubTypeToFillType[subTypeIndex] or nil
	if fillType == nil or not AnimalMoveEvent._isWeighedContractTarget(targetObject, farmId) then
		return targetObject:contractProductionAddAnimals(farmId, subTypeIndex, 1) or 0
	end

	local amount = AnimalMoveEvent.getCarcassYieldFactor(animal, targetObject, subTypeIndex)
	if not AnimalMoveEvent._canAffordContractInputs(targetObject, farmId, { [fillType] = amount }) then return 0 end

	local credited = targetObject:contractProductionDeliver(farmId, fillType, amount) or 0
	Log:debug("AnimalMoveEvent._deliverToContractTarget: farmId=%s fillType=%s yield=%.3f credited=%.3f weight=%s",
		tostring(farmId), tostring(fillType), amount, credited, tostring(animal and animal.weight))
	if credited <= 0.001 then return 0 end

	if credited < amount - 0.001 then
		Log:warning("AnimalMoveEvent._deliverToContractTarget: facility credited %.3f of %.3f for one animal (farmId=%s)",
			credited, amount, tostring(farmId))
	end
	if targetObject.contractProductionRefreshAnimalVisuals ~= nil then
		targetObject:contractProductionRefreshAnimalVisuals()
	end
	return 1
end


--- Deliver one animal to an EPP target and return how many it credited (0 or 1).
---
--- Contract facilities credit a farm's open order, so they take the farm from the call; their
--- addCluster instead guesses it from the local animal-screen trailer, which a multiplayer
--- server never has. Everything else gets a single-animal cluster shim. The shim answers both
--- cluster access styles - fields (farm butcher) and getters (slaughterhouse) - and counts
--- what the target takes through changeNumAnimals, which targets call only for animals they
--- actually stored.
--- @param farmId number|nil The delivering farm, when known
--- @return number accepted
function AnimalMoveEvent._deliverOneToEPPTarget(targetObject, subTypeIndex, animal, farmId)
	if farmId ~= nil and type(targetObject.contractProductionAddAnimals) == "function" then
		return AnimalMoveEvent._deliverToContractTarget(targetObject, subTypeIndex, animal, farmId)
	end

	local accepted = 0
	local shim = {
		subTypeIndex = subTypeIndex,
		numAnimals = 1,
		getSubTypeIndex = function() return subTypeIndex end,
		getNumAnimals = function() return 1 end,
		changeNumAnimals = function(_, delta) accepted = accepted - delta end,
	}

	local restore = AnimalMoveEvent._applyCarcassYield(targetObject, subTypeIndex, animal)
	local ok, err = pcall(targetObject.addCluster, targetObject, shim)
	if restore ~= nil then restore() end
	if not ok then error(err, 0) end

	return accepted
end


--- Free slots at a move target. A contract facility is asked for the delivering farm's
--- slots directly, for the same reason _deliverOneToEPPTarget passes the farm.
function AnimalMoveEvent._getTargetFreeSlots(targetObject, farmId, subTypeIndex)
	if farmId ~= nil and targetObject.isServer
		and type(targetObject.contractProductionGetAnimalFreeSlots) == "function" then
		return targetObject:contractProductionGetAnimalFreeSlots(farmId, subTypeIndex)
	end
	return targetObject:getNumOfFreeAnimalSlots(subTypeIndex)
end


--- Whether a target that weighs deliveries (contract facility, unit-based butcher) can take
--- the whole batch: the summed carcass yield per fill type must fit its room, and a contract
--- farm must afford the fees for all of it, across fill types. Checked before the first animal goes in, so a batch
--- that would run out of room part-way is refused whole. Targets that count heads pass here
--- and are checked per head by the caller.
--- @param transferList table Array of {animal, sourceCluster} entries
--- @return boolean ok
function AnimalMoveEvent._canTakeEPPBatch(targetObject, transferList, farmId)
	local isContract = AnimalMoveEvent._isWeighedContractTarget(targetObject, farmId)
	local subTypeToFillType = targetObject.animalSubTypeToFillType or {}
	local demand, subTypeByFillType = {}, {}

	for _, entry in ipairs(transferList) do
		local subTypeIndex = entry.animal.subTypeIndex
		local liveAnimal = entry.sourceCluster or entry.animal
		local fillType, amount, _
		if isContract then
			fillType = subTypeToFillType[subTypeIndex]
			amount = AnimalMoveEvent.getCarcassYieldFactor(liveAnimal, targetObject, subTypeIndex)
		else
			fillType, _, amount = AnimalMoveEvent._getScaledButcherUnits(targetObject, subTypeIndex, liveAnimal)
		end
		if fillType ~= nil then
			demand[fillType] = (demand[fillType] or 0) + amount
			subTypeByFillType[fillType] = subTypeByFillType[fillType] or subTypeIndex
		end
	end

	for fillType, amount in pairs(demand) do
		local room
		if isContract then
			-- Open order, delivery mode and fee budget for at least one head, as the facility sees it.
			if targetObject:contractProductionGetAnimalFreeSlots(farmId, subTypeByFillType[fillType]) < 1 then
				Log:debug("AnimalMoveEvent._canTakeEPPBatch: no open order for fillType=%s", tostring(fillType))
				return false
			end
			room = AnimalMoveEvent._getContractRoom(targetObject, farmId, fillType)
		else
			local fillLevel = ProductionPoint ~= nil and ProductionPoint.getFillLevel(targetObject, fillType)
				or targetObject:getFillLevel(fillType)
			room = (targetObject:getCapacity(fillType) or 0) - (fillLevel or 0)
		end
		if room ~= nil and amount > room + 0.001 then
			Log:debug("AnimalMoveEvent._canTakeEPPBatch: fillType=%s needs %.3f, room %.3f", tostring(fillType), amount, room)
			return false
		end
	end

	-- Fees for every fill type together: the orders share the farm's money.
	if isContract and not AnimalMoveEvent._canAffordContractInputs(targetObject, farmId, demand) then
		Log:debug("AnimalMoveEvent._canTakeEPPBatch: farm %s cannot pay the fees for the batch", tostring(farmId))
		return false
	end
	return true
end


--- Whether _canTakeEPPBatch checks this target by yield rather than by head. Without a
--- subtype, any unit-based input counts; with one, only an input carcass yield scales (an
--- animal-conversion input is counted by head).
function AnimalMoveEvent._isWeighedTarget(targetObject, farmId, subTypeIndex)
	if AnimalMoveEvent._isWeighedContractTarget(targetObject, farmId) then return true end
	if targetObject.eppHasScaledAnimalInputs ~= true or type(targetObject.eppAnimalInputUnitsByFillType) ~= "table" then
		return false
	end
	return subTypeIndex == nil or AnimalMoveEvent._getScaledButcherUnits(targetObject, subTypeIndex, nil) ~= nil
end


--- Deliver animals to an extended-production-point target, one animal at a time.
---
--- Production-points exposing animalsTypeData and a per-instance addCluster (with
--- no spec_husbandryAnimals) accept animals via that override which bumps storage
--- fillLevel; their internal cluster system is a placeholder, so cluster-system
--- flush would never reach the override. A target that weighs deliveries is checked
--- for room for the whole batch first (_canTakeEPPBatch), and nothing goes in when it
--- lacks it. Each delivery runs inside a per-animal pcall, and an animal the target
--- does not credit aborts the batch too, so state stays consistent: every animal is
--- either still in source (and uncredited) or removed and credited. RLRM owns source-side bookkeeping in the staged
--- source-flush step the caller runs after this returns.
---
--- @param targetObject table Production-point factory exposing per-instance addCluster
--- @param transferList table Array of {animal, sourceCluster} entries to deliver
--- @param farmId number|nil The delivering farm, when known
--- @return table deliveredList Subset of transferList that the target accepted (in order)
--- @return string|nil abortError Error from the failed delivery, or nil if all succeeded
function AnimalMoveEvent._deliverToEPPTarget(targetObject, transferList, farmId)
	local deliveredList = {}
	if not AnimalMoveEvent._canTakeEPPBatch(targetObject, transferList, farmId) then
		Log:debug("AnimalMoveEvent._deliverToEPPTarget: no room for the batch of %d, nothing delivered", #transferList)
		return deliveredList, AnimalMoveEvent.EPP_NOT_ACCEPTED
	end
	for i, entry in ipairs(transferList) do
		-- Weight and genetics from the live server animal, never the client's payload copy.
		local liveAnimal = entry.sourceCluster or entry.animal
		local accepted = 0
		local ok, err = pcall(function()
			accepted = AnimalMoveEvent._deliverOneToEPPTarget(targetObject, entry.animal.subTypeIndex, liveAnimal, farmId)
		end)
		if ok and accepted < 1 - 0.001 then
			ok, err = false, AnimalMoveEvent.EPP_NOT_ACCEPTED
		end
		if ok then
			-- Clear engine identity only on the delivered branch. A failed addCluster
			-- leaves the animal in source; stripping its idFull there would orphan
			-- the source husbandry's visual-count bookkeeping for that animal.
			entry.animal.id, entry.animal.idFull = nil, nil
			table.insert(deliveredList, entry)
			Log:trace("AnimalMoveEvent._deliverToEPPTarget: i=%d subTypeIndex=%s ok",
				i, tostring(entry.animal.subTypeIndex))
		else
			Log:error("AnimalMoveEvent._deliverToEPPTarget: i=%d subTypeIndex=%s FAILED, aborting batch: %s",
				i, tostring(entry.animal.subTypeIndex), tostring(err))
			return deliveredList, err
		end
	end
	Log:debug("AnimalMoveEvent._deliverToEPPTarget: all %d animals delivered", #deliveredList)
	return deliveredList, nil
end


--- Dispatch animal delivery to the target object based on target type.
---
--- For EPP targets (animalsTypeData + callable addCluster + nil spec_husbandryAnimals)
--- delegates to _deliverToEPPTarget for per-animal-atomic delivery; the caller is
--- expected to stage source-flush against the returned deliveredList AFTER this call
--- so partial failure does not strand animals out of state. For husbandry targets
--- queues animals on the cluster system and flushes via updateNow with before/after
--- visual-count snapshots; the caller runs source-flush BEFORE this call to preserve
--- the husbandry-target source-first invariant (target's updateClusters tail-calls
--- updateVisualAnimals which reassigns idFull on the shared Animal entity, so source
--- bookkeeping must complete first).
---
--- @param targetObject table The destination of the move (husbandry placeable or EPP factory)
--- @param transferList table Array of {animal, sourceCluster} entries to deliver
--- @param targetClusterSystem table Cluster system retrieved from targetObject:getClusterSystem()
--- @param farmId number|nil The delivering farm, forwarded to EPP delivery
--- @return boolean ok True if all delivery succeeded
--- @return string|nil err Error message from the failing step, or nil
--- @return table deliveredList Entries successfully delivered (subset for EPP, equals transferList for husbandry)
--- Queue source-side cluster removals for the animals that were actually
--- delivered to the target. Caller is responsible for the eventual
--- updateNow() commit.
---
--- Extracted from :run's EPP branch so the staged-flush behavior can be
--- exercised by unit tests without stubbing the entire :run execution
--- context.
---
--- @param clusterSystemSource table Source cluster system retrieved from sourceObject:getClusterSystem()
--- @param deliveredList table Subset of transferList that the target accepted
function AnimalMoveEvent._stageSourceFlushForDelivered(clusterSystemSource, deliveredList)
	for _, entry in ipairs(deliveredList) do
		clusterSystemSource:addPendingRemoveCluster(entry.sourceCluster)
	end
	Log:trace("AnimalMoveEvent._stageSourceFlushForDelivered: queued %d source removes",
		#deliveredList)
end


function AnimalMoveEvent._dispatchTargetDelivery(targetObject, transferList, targetClusterSystem, farmId)
	local isEPPTarget = targetObject.animalsTypeData ~= nil
		and type(targetObject.addCluster) == "function"
		and targetObject.spec_husbandryAnimals == nil

	if isEPPTarget then
		Log:debug("AnimalMoveEvent._dispatchTargetDelivery: EPP target detected, delivering via addCluster (animals=%d)",
			#transferList)
		local deliveredList, abortError = AnimalMoveEvent._deliverToEPPTarget(targetObject, transferList, farmId)
		return abortError == nil, abortError, deliveredList
	end

	Log:trace("AnimalMoveEvent._dispatchTargetDelivery: husbandry target, using cluster system path (animals=%d)",
		#transferList)
	local ok1, err1 = pcall(function()
		for _, entry in ipairs(transferList) do
			entry.animal.id, entry.animal.idFull = nil, nil
			targetClusterSystem:addPendingAddCluster(entry.animal)
		end
	end)
	AnimalMoveEvent._logVisualCountSnapshot("target", "before", targetClusterSystem)
	local ok2, err2 = pcall(function() targetClusterSystem:updateNow() end)
	AnimalMoveEvent._logVisualCountSnapshot("target", "after", targetClusterSystem)

	local ok = ok1 and ok2
	local err = (not ok1) and err1 or err2
	return ok, err, transferList
end


function AnimalMoveEvent.new(sourceObject, targetObject, animals, moveType)

	local event = AnimalMoveEvent.emptyNew()

	event.sourceObject = sourceObject
	event.targetObject = targetObject
	event.animals = animals
	event.moveType = moveType

	return event

end


function AnimalMoveEvent:readStream(streamId, connection)

	if connection:getIsServer() then

		self.errorCode = streamReadUIntN(streamId, 3)
		Log:trace("AnimalMoveEvent:readStream (client): errorCode=%d", self.errorCode)

	else

		self.moveType = streamReadString(streamId)

		self.sourceObject = NetworkUtil.readNodeObject(streamId)
		self.targetObject = NetworkUtil.readNodeObject(streamId)

		local numAnimals = streamReadUInt16(streamId)
		Log:trace("AnimalMoveEvent:readStream (server): moveType='%s' numAnimals=%d source=%s target=%s",
			tostring(self.moveType), numAnimals,
			tostring(self.sourceObject), tostring(self.targetObject))

		self.animals = {}

		for i = 1, numAnimals do

			local animal = Animal.new()
			local success = animal:readStream(streamId, connection)
			table.insert(self.animals, animal)
			Log:trace("AnimalMoveEvent:readStream: animal %d read success=%s id='%s'",
				i, tostring(success), tostring(animal.uniqueId))

		end

	end

	self:run(connection)

end


function AnimalMoveEvent:writeStream(streamId, connection)

	if not connection:getIsServer() then
		Log:trace("AnimalMoveEvent:writeStream (server->client): errorCode=%d", self.errorCode)
		streamWriteUIntN(streamId, self.errorCode, 3)
		return
	end

	Log:trace("AnimalMoveEvent:writeStream (client->server): moveType='%s' numAnimals=%d",
		tostring(self.moveType), #self.animals)

	streamWriteString(streamId, self.moveType)

	NetworkUtil.writeNodeObject(streamId, self.sourceObject)
	NetworkUtil.writeNodeObject(streamId, self.targetObject)

	streamWriteUInt16(streamId, #self.animals)

	for i, animal in pairs(self.animals) do
		Log:trace("AnimalMoveEvent:writeStream: writing animal %d id='%s'", i, tostring(animal.uniqueId))
		local success = animal:writeStream(streamId, connection)
		Log:trace("AnimalMoveEvent:writeStream: animal %d write success=%s", i, tostring(success))
	end

end


--- Client: publish the reply code. Server: validate, skip EPP-refused animals, then move the rest.
---@param connection table The sender's connection (a client when this runs on the server)
function AnimalMoveEvent:run(connection)

	if connection:getIsServer() then
		Log:trace("AnimalMoveEvent:run (client): publishing errorCode=%d", self.errorCode)
		g_messageCenter:publish(AnimalMoveEvent, self.errorCode)
		return

	end

	RmSafeUtils.safeCall("AnimalMoveEvent:run", function()

		Log:debug("AnimalMoveEvent:run (server): moveType='%s' animals=%d source=%s target=%s",
			tostring(self.moveType), #self.animals,
			tostring(self.sourceObject and self.sourceObject.getName and self.sourceObject:getName()),
			tostring(self.targetObject and self.targetObject.getName and self.targetObject:getName()))

		local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
		local farmId = g_farmManager:getFarmForUniqueUserId(userId).farmId
		Log:trace("AnimalMoveEvent:run: userId=%s farmId=%d", tostring(userId), farmId)

		local validatedCount = 0

		for i, animal in pairs(self.animals) do

			Log:trace("AnimalMoveEvent:run: validating animal %d subTypeIndex=%s", i, tostring(animal.subTypeIndex))
			local errorCode = AnimalMoveEvent.validate(self.sourceObject, self.targetObject, farmId, animal.subTypeIndex)

			if errorCode ~= nil then
				Log:debug("AnimalMoveEvent:run: validation failed for animal %d, errorCode=%d", i, errorCode)
				connection:sendEvent(AnimalMoveEvent.newServerToClient(errorCode))
				return
			end

			-- Pen rules per animal (castration, maturity, age), read off the live server animal.
			local liveAnimal = self.sourceObject:getClusterSystem():getClusterById(
				RLAnimalUtil.toKey(animal.farmId, animal.uniqueId, animal.birthday.country)) or animal
			local penOk, penReason, penDetail = RLHusbandryProfiles.checkAnimal(self.targetObject, liveAnimal)
			if not penOk then
				Log:debug("AnimalMoveEvent:run: animal %d refused by the pen rules (%s %s)", i, tostring(penReason), tostring(penDetail))
				connection:sendEvent(AnimalMoveEvent.newServerToClient(AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED))
				return
			end

			validatedCount = validatedCount + 1

			-- A target that weighs deliveries checks the batch's summed yield at delivery instead.
			local slotsNeeded = AnimalMoveEvent._isWeighedTarget(self.targetObject, farmId, animal.subTypeIndex) and 1 or validatedCount
			if AnimalMoveEvent._getTargetFreeSlots(self.targetObject, farmId, animal.subTypeIndex) < slotsNeeded then
				Log:debug("AnimalMoveEvent:run: not enough space at target (need=%d)", slotsNeeded)
				connection:sendEvent(AnimalMoveEvent.newServerToClient(AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE))
				return
			end

		end

		Log:debug("AnimalMoveEvent:run: all %d animals validated, starting transfer", validatedCount)

		local clusterSystemSource = self.sourceObject:getClusterSystem()
		Log:trace("AnimalMoveEvent:run: got source cluster system: %s", tostring(clusterSystemSource))

		-- Check for EPP age constraints on target
		local eppTypeData = nil
		if self.targetObject.animalsTypeData ~= nil and #self.animals > 0 then
			local subType = g_currentMission.animalSystem:getSubTypeByIndex(self.animals[1].subTypeIndex)
			if subType ~= nil then
				eppTypeData = self.targetObject.animalsTypeData[subType.typeIndex]
			end
			Log:trace("AnimalMoveEvent:run: EPP typeData=%s", tostring(eppTypeData))
		end

		-- Pass 1: EPP filter + source-cluster lookup. Pre-resolving source references here
		-- avoids a second linear scan inside addPendingRemoveCluster, and skipping EPP-failed
		-- animals at this stage keeps them out of both pending queues entirely.
		local targetClusterSystem = self.targetObject:getClusterSystem()
		local transferList = {}
		local skippedSick = 0
		for i, animal in pairs(self.animals) do
			Log:trace("AnimalMoveEvent:run: processing animal %d id='%s' age=%s",
				i, tostring(animal.uniqueId), tostring(animal.age))

			local skip = false
			if eppTypeData ~= nil then
				local age = animal.age or 0
				local minAge = eppTypeData.minimumAge or 0
				local maxAge = eppTypeData.maximumAge or 999
				if age < minAge or age > maxAge then
					Log:trace("AnimalMoveEvent:run: skipping animal '%s' age=%d (EPP range %d-%d)",
						animal.uniqueId or "?", age, minAge, maxAge)
					skip = true
				end
			end

			if not skip then
				local clusterId = RLAnimalUtil.toKey(animal.farmId, animal.uniqueId, animal.birthday.country)
				local sourceCluster = clusterSystemSource:getClusterById(clusterId)
				if sourceCluster == nil then
					Log:warning("AnimalMoveEvent:run: source cluster not found for clusterId='%s' (skipping)",
						tostring(clusterId))
				elseif eppTypeData ~= nil and not RLDiseaseSaleGate.check(sourceCluster) then
					-- Read the live server animal, never the payload copy: the client's view can be stale.
					skippedSick = skippedSick + 1
					Log:debug("AnimalMoveEvent:run: skipping sick animal uniqueId=%s farmId=%s (butcher target=%s)",
						tostring(sourceCluster.uniqueId), tostring(sourceCluster.farmId),
						tostring(self.targetObject.getName and self.targetObject:getName()))
				else
					table.insert(transferList, { animal = animal, sourceCluster = sourceCluster })
				end
			end
		end
		if skippedSick > 0 then
			Log:debug("AnimalMoveEvent:run: %d sick animal(s) left in source, %d to deliver", skippedSick, #transferList)
		end

		-- Pass 2: ordering depends on target type.
		-- Husbandry target: source-first is mandatory. Target's updateClusters tail-calls
		-- updateVisualAnimals which reassigns animal.idFull on the shared entity; source's
		-- removeCluster must read source-side handles before that rewrite to keep
		-- husbandryIdsToVisualAnimalCount in sync.
		-- EPP target (animalsTypeData + per-instance addCluster, no spec_husbandryAnimals):
		-- target-first per-animal-atomic. Source-flush is staged for delivered animals only,
		-- so a per-animal failure leaves un-delivered animals in source uncredited (no loss,
		-- no duplication). EPP targets do not run updateVisualAnimals so the husbandry
		-- ordering hazard does not apply.
		local isEPPTarget = self.targetObject.animalsTypeData ~= nil
			and type(self.targetObject.addCluster) == "function"
			and self.targetObject.spec_husbandryAnimals == nil

		local ok1, err1, ok2, err2 = true, nil, true, nil
		local okTarget, errTarget, deliveredList = true, nil, transferList

		if isEPPTarget then
			okTarget, errTarget, deliveredList = AnimalMoveEvent._dispatchTargetDelivery(
				self.targetObject, transferList, targetClusterSystem, farmId)

			ok1, err1 = pcall(function()
				AnimalMoveEvent._stageSourceFlushForDelivered(clusterSystemSource, deliveredList)
			end)
			AnimalMoveEvent._logVisualCountSnapshot("source", "before", clusterSystemSource)
			ok2, err2 = pcall(function() clusterSystemSource:updateNow() end)
			AnimalMoveEvent._logVisualCountSnapshot("source", "after", clusterSystemSource)

			-- Source-flush failure after target credit means animals are credited to
			-- the target AND still in source = duplication. Source-flush is RLRM-internal
			-- (cluster bookkeeping) and idempotent under normal conditions, so this is
			-- a rare residual risk. When it happens, enumerate affected animals so the
			-- player can clean up. Duplication is a player-favoured failure mode in a
			-- leisure game; loss would not be.
			if (not ok1 or not ok2) and #deliveredList > 0 then
				local idList = {}
				for _, entry in ipairs(deliveredList) do
					table.insert(idList, string.format("farmId=%s uniqueId=%s",
						tostring(entry.animal.farmId), tostring(entry.animal.uniqueId)))
				end
				Log:error("AnimalMoveEvent:run: EPP source-flush FAILED after target credit; %d animal(s) duplicated (credited to target AND still in source): %s",
					#deliveredList, table.concat(idList, "; "))
			end
		else
			ok1, err1 = pcall(function()
				for _, entry in ipairs(transferList) do
					clusterSystemSource:addPendingRemoveCluster(entry.sourceCluster)
				end
			end)
			AnimalMoveEvent._logVisualCountSnapshot("source", "before", clusterSystemSource)
			ok2, err2 = pcall(function() clusterSystemSource:updateNow() end)
			AnimalMoveEvent._logVisualCountSnapshot("source", "after", clusterSystemSource)

			okTarget, errTarget, deliveredList = AnimalMoveEvent._dispatchTargetDelivery(
				self.targetObject, transferList, targetClusterSystem)
		end

		local okAll = ok1 and ok2 and okTarget

		if okAll then
			Log:debug("AnimalMoveEvent:run: transfer complete path=%s delivered=%d source=%s target=%s, sending success",
				isEPPTarget and "epp" or "cluster",
				#deliveredList,
				tostring(self.sourceObject and self.sourceObject.getName and self.sourceObject:getName()),
				tostring(self.targetObject and self.targetObject.getName and self.targetObject:getName()))
			connection:sendEvent(AnimalMoveEvent.newServerToClient(AnimalMoveEvent.MOVE_SUCCESS))
		else
			Log:error("AnimalMoveEvent:run: batch failed path=%s delivered=%d sourceQueue=%s sourceFlush=%s target=%s",
				isEPPTarget and "epp" or "cluster",
				#deliveredList,
				tostring(err1), tostring(err2), tostring(errTarget))
			local errorCode = AnimalMoveEvent.MOVE_ERROR_INVALID_CLUSTER
			if ok1 and ok2 and errTarget == AnimalMoveEvent.EPP_NOT_ACCEPTED then
				errorCode = AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE
			end
			connection:sendEvent(AnimalMoveEvent.newServerToClient(errorCode))
			return
		end

		if g_server ~= nil and not g_server.netIsRunning then return end

		local husbandry, trailer

		if self.moveType == "SOURCE" then
			husbandry, trailer = self.sourceObject, self.targetObject
		else
			husbandry, trailer = self.targetObject, self.sourceObject
		end

		if husbandry.addRLMessage ~= nil then
			if #self.animals == 1 then
				husbandry:addRLMessage(string.format("MOVED_ANIMALS_%s_SINGLE", self.moveType), nil, { trailer:getName() })
			elseif #self.animals > 0 then
				husbandry:addRLMessage(string.format("MOVED_ANIMALS_%s_MULTIPLE", self.moveType), nil, { #self.animals, trailer:getName() })
			end
		end

		Log:debug("AnimalMoveEvent:run: complete")

	end)

end


function AnimalMoveEvent.validate(sourceObject, targetObject, farmId, subTypeIndex)

	if sourceObject == nil then return AnimalMoveEvent.MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST end

	if targetObject == nil then return AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST end

	if not g_currentMission.accessHandler:canFarmAccess(farmId, sourceObject) or not g_currentMission.accessHandler:canFarmAccess(farmId, targetObject) then return AnimalMoveEvent.MOVE_ERROR_NO_PERMISSION end

	RLHusbandryProfiles.apply(targetObject)
	if not targetObject:getSupportsAnimalSubType(subTypeIndex) then return AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED end

	if AnimalMoveEvent._getTargetFreeSlots(targetObject, farmId, subTypeIndex) < 1 then return AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE end

	return nil

end
