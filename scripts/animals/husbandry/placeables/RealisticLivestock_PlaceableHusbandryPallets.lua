RealisticLivestock_PlaceableHusbandryPallets = {}


function RealisticLivestock_PlaceableHusbandryPallets.registerOverwrittenFunctions(placeable)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateInputAndOutput", PlaceableHusbandryPallets.updateInputAndOutput)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateOutput", RealisticLivestock_PlaceableHusbandryPallets.updateOutput)
end

PlaceableHusbandryPallets.registerOverwrittenFunctions = Utils.appendedFunction(PlaceableHusbandryPallets.registerOverwrittenFunctions, RealisticLivestock_PlaceableHusbandryPallets.registerOverwrittenFunctions)


function RealisticLivestock_PlaceableHusbandryPallets:onHusbandryAnimalsUpdate(superFunc, clusters)
	-- Skip superFunc (no base game cluster-based litersPerHour calculation)
	-- But populate activeFillTypes for UI display on both server and client
	local spec = self.spec_husbandryPallets
	if spec ~= nil then
		spec.activeFillTypes = {}
		for _, animal in ipairs(clusters) do
			local subType = animal:getSubType()
			if subType ~= nil then
				local pallets = subType.output.pallets
				if pallets ~= nil and spec.litersPerHour[pallets.fillType] ~= nil then
					table.addElement(spec.activeFillTypes, pallets.fillType)
				end
			end
		end
	end
end

PlaceableHusbandryPallets.onHusbandryAnimalsUpdate = Utils.overwrittenFunction(PlaceableHusbandryPallets.onHusbandryAnimalsUpdate, RealisticLivestock_PlaceableHusbandryPallets.onHusbandryAnimalsUpdate)


function PlaceableHusbandryPallets:updateInputAndOutput(superFunc, animals)

    superFunc(self, animals)

    local spec = self.spec_husbandryPallets

    for fillType, _ in pairs(spec.litersPerHour) do
        spec.litersPerHour[fillType] = 0
    end

    -- Cow and buffalo milk cans whose liters went through the body condition budget.
    spec.rlManagedLitersPerHour = {}

    spec.activeFillTypes = {}

    for _, animal in pairs(animals) do

        local subType = animal:getSubType()

        if subType ~= nil then

            local pallets = subType.output.pallets

            if pallets ~= nil then

                if spec.litersPerHour[pallets.fillType] ~= nil then
                    local output = animal:getOutput("pallets")
                    spec.litersPerHour[pallets.fillType] = spec.litersPerHour[pallets.fillType] + output
                    table.addElement(spec.activeFillTypes, pallets.fillType)
                    if Animal.isCowMilkPalletFillType(pallets.fillType) and RLBodyCondition.isMilkManaged(animal) then
                        spec.rlManagedLitersPerHour[pallets.fillType] = (spec.rlManagedLitersPerHour[pallets.fillType] or 0) + output
                    end
                    if output > 0 then
                        Log:trace("Pallets: subType='%s' fillType=%s output=%.4f litersPerHour=%.4f",
                            tostring(subType.name),
                            tostring(g_fillTypeManager:getFillTypeNameByIndex(pallets.fillType)),
                            output,
                            spec.litersPerHour[pallets.fillType])
                    end
                else
                    Log:debug("Pallets: fillType %s (index=%s) for subType '%s' not in building's litersPerHour - output dropped. Registered: %s",
                        tostring(g_fillTypeManager:getFillTypeNameByIndex(pallets.fillType)),
                        tostring(pallets.fillType),
                        tostring(subType.name),
                        tostring(table.concat(
                            (function() local keys = {} for k, _ in pairs(spec.litersPerHour) do table.insert(keys, tostring(g_fillTypeManager:getFillTypeNameByIndex(k) or k)) end return keys end)(),
                            ", ")))
                end

            end

        end

    end

end


--- Milk cans from cattle under the body condition rules: like the tank milk
--- (RealisticLivestock_PlaceableHusbandryMilk.depositSplit), the base spawner only gets the other
--- animals' share of litersPerHour, and the budgeted share is queued here without the feed factors.
function RealisticLivestock_PlaceableHusbandryPallets:updateOutput(superFunc, foodFactor, productionFactor, globalProductionFactor)
    local spec = self.spec_husbandryPallets
    local managed = spec ~= nil and spec.rlManagedLitersPerHour or nil

    if not self.isServer or managed == nil or next(managed) == nil then
        superFunc(self, foodFactor, productionFactor, globalProductionFactor)
        return
    end

    local saved = {}
    for fillTypeIndex, liters in pairs(managed) do
        local total = spec.litersPerHour[fillTypeIndex]
        if total ~= nil then
            saved[fillTypeIndex] = total
            spec.litersPerHour[fillTypeIndex] = math.max(total - liters, 0)
        end
    end

    superFunc(self, foodFactor, productionFactor, globalProductionFactor)

    for fillTypeIndex, total in pairs(saved) do spec.litersPerHour[fillTypeIndex] = total end

    local timeAdjustment = g_currentMission.environment.timeAdjustment
    local factor = RLBodyCondition.getNonFeedProductionFactor(foodFactor, productionFactor, true)
    local queued = false
    for fillTypeIndex, liters in pairs(managed) do
        if saved[fillTypeIndex] ~= nil and liters > 0 and spec.pendingLiters[fillTypeIndex] ~= nil then
            spec.pendingLiters[fillTypeIndex] = spec.pendingLiters[fillTypeIndex] + liters * factor * timeAdjustment
            queued = true
        end
    end
    if queued then self:updatePallets() end
end
