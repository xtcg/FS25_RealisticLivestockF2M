RealisticLivestock_PlaceableHusbandryPallets = {}


function RealisticLivestock_PlaceableHusbandryPallets.registerOverwrittenFunctions(placeable)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateInputAndOutput", PlaceableHusbandryPallets.updateInputAndOutput)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateOutput", RealisticLivestock_PlaceableHusbandryPallets.updateOutput)
end

PlaceableHusbandryPallets.registerOverwrittenFunctions = Utils.appendedFunction(PlaceableHusbandryPallets.registerOverwrittenFunctions, RealisticLivestock_PlaceableHusbandryPallets.registerOverwrittenFunctions)


--- A map's pallet remap (RLMapBridge.palletAliases, Hof Bergmann: SHEEP WOOL -> SHEEPWOOL_SHEARED)
--- changes every sheep's wool to the map's fill type, but a building that spawns only `from`
--- (the base game's sheep barns and HB's goat stable: WOOL GOATMILK) would drop all of it. Such a
--- building spawns `to` from the same spawner, places and pallet limit instead: it does make wool
--- pallets, only of the base game's fill type, which the map does not trade. A building with no
--- wool spawner at all gets nothing (noteUnsupported says so once). Server and client both run it
--- at load, so spec.fillTypes (the stream order) stays the same on both.
function RealisticLivestock_PlaceableHusbandryPallets.installPalletAliases(placeable)
    local spec = placeable.spec_husbandryPallets
    local aliases = RLMapBridge ~= nil and RLMapBridge.palletAliases or nil
    if spec == nil or spec.fillTypeIndexToPalletSpawner == nil or aliases == nil or #aliases == 0 then return 0 end
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    local typeIndex = placeable.getAnimalTypeIndex ~= nil and placeable:getAnimalTypeIndex() or nil
    if animalSystem == nil or animalSystem.nameToType == nil or typeIndex == nil then return 0 end

    local count = 0
    for _, alias in ipairs(aliases) do
        local animalType = animalSystem.nameToType[alias.typeName]
        local spawner = spec.fillTypeIndexToPalletSpawner[alias.from]
        if animalType ~= nil and animalType.typeIndex == typeIndex and spawner ~= nil
            and spec.fillTypeIndexToPalletSpawner[alias.to] == nil then
            local to = alias.to
            spec.fillTypeIndexToPalletSpawner[to] = spawner
            table.insert(spec.fillTypes, to)
            spec.litersPerHour[to] = 0
            spec.maxNumPallets[to] = spec.maxNumPallets[alias.from]
            spec.capacities[to] = 0
            spec.capacitiesPending[to] = 0
            spec.capacitiesSent[to] = 0
            spec.maxCapacitiesPending[to] = 0
            spec.fillLevels[to] = 0
            spec.fillLevelsPending[to] = 0
            spec.fillLevelsSent[to] = 0
            spec.pendingLiters[to] = 0
            count = count + 1
            Log:info("Pallets: '%s' spawns %s in place of %s (%s pallet remap)",
                tostring(placeable.getName ~= nil and placeable:getName() or "?"),
                tostring(g_fillTypeManager:getFillTypeNameByIndex(to)), tostring(g_fillTypeManager:getFillTypeNameByIndex(alias.from)),
                tostring(alias.bridgeName))
        end
    end
    return count
end


function RealisticLivestock_PlaceableHusbandryPallets:onLoad(savegame)
    RmSafeUtils.safeCall("Pallets.installPalletAliases", function()
        RealisticLivestock_PlaceableHusbandryPallets.installPalletAliases(self)
    end)
end

PlaceableHusbandryPallets.onLoad = Utils.appendedFunction(PlaceableHusbandryPallets.onLoad, RealisticLivestock_PlaceableHusbandryPallets.onLoad)


--- A subtype's pallet output this building cannot spawn: said once per building and fill type
--- (an info line, not every hour), so a pen that makes no wool says why.
function RealisticLivestock_PlaceableHusbandryPallets.noteUnsupported(placeable, subType, fillType)
    local spec = placeable.spec_husbandryPallets
    spec.rlUnsupportedNoted = spec.rlUnsupportedNoted or {}
    if spec.rlUnsupportedNoted[fillType] then return end
    spec.rlUnsupportedNoted[fillType] = true
    local names = {}
    for _, index in ipairs(spec.fillTypes or {}) do names[#names + 1] = tostring(g_fillTypeManager:getFillTypeNameByIndex(index)) end
    Log:info("Pallets: '%s' has no pallet output for %s (it spawns: %s), so %s produce none of it here",
        tostring(placeable.getName ~= nil and placeable:getName() or "?"), tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType)),
        #names > 0 and table.concat(names, " ") or "nothing", tostring(subType ~= nil and subType.name or "?"))
end


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

    -- Each covered cow's share of litersPerHour in cow or buffalo milk cans (updateOutput below).
    spec.rlMilkContributions = {}
    -- Each sheep's wool liters, for the shearing season (RLWoolShearing).
    spec.rlWoolContributions = {}

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
                    RLWoolShearing.addContribution(spec, animal, pallets.fillType, output)
                    if Animal.isCowMilkPalletFillType(pallets.fillType) and RLBodyCondition.isEligible(animal) then
                        table.insert(spec.rlMilkContributions, { animal = animal, fillType = pallets.fillType, liters = output })
                    end
                    if output > 0 then
                        Log:trace("Pallets: subType='%s' fillType=%s output=%.4f litersPerHour=%.4f",
                            tostring(subType.name),
                            tostring(g_fillTypeManager:getFillTypeNameByIndex(pallets.fillType)),
                            output,
                            spec.litersPerHour[pallets.fillType])
                    end
                else
                    RealisticLivestock_PlaceableHusbandryPallets.noteUnsupported(self, subType, pallets.fillType)
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


--- Milk cans from cattle under the body condition rules: like the tank milk, the base spawner
--- only gets the other animals' share of litersPerHour, and the liters the covered cows' budgets
--- paid for this hour are queued here without the feed factors (RLBodyCondition.depositMilk).
function RealisticLivestock_PlaceableHusbandryPallets:updateOutput(superFunc, foodFactor, productionFactor, globalProductionFactor)
    local spec = self.spec_husbandryPallets

    if not self.isServer or spec == nil then
        superFunc(self, foodFactor, productionFactor, globalProductionFactor)
        return
    end

    local queued = false
    -- Sheep wool goes to the pallets or onto the sheep by the map's shearing season (RLWoolShearing).
    local function base() superFunc(self, foodFactor, productionFactor, globalProductionFactor) end
    RLBodyCondition.depositMilk(self, spec.litersPerHour, spec.rlMilkContributions,
        function() RLWoolShearing.runOutput(self, base, productionFactor, globalProductionFactor) end,
        function(fillType, liters)
            if spec.pendingLiters[fillType] ~= nil then
                spec.pendingLiters[fillType] = spec.pendingLiters[fillType] + liters
                queued = true
                return liters
            end
            return 0
        end)
    if queued then self:updatePallets() end
end


--- The pen's last shearing (RLWoolShearing), saved with its pending pallet liters.
function RealisticLivestock_PlaceableHusbandryPallets:saveToXMLFile(xmlFile, key)
    RLWoolShearing.savePen(self, xmlFile, key)
end

PlaceableHusbandryPallets.saveToXMLFile = Utils.appendedFunction(PlaceableHusbandryPallets.saveToXMLFile, RealisticLivestock_PlaceableHusbandryPallets.saveToXMLFile)


function RealisticLivestock_PlaceableHusbandryPallets:loadFromXMLFile(xmlFile, key)
    RLWoolShearing.loadPen(self, xmlFile, key)
end

PlaceableHusbandryPallets.loadFromXMLFile = Utils.appendedFunction(PlaceableHusbandryPallets.loadFromXMLFile, RealisticLivestock_PlaceableHusbandryPallets.loadFromXMLFile)
