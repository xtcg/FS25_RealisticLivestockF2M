RealisticLivestock_PlaceableHusbandryFood = {}


function RealisticLivestock_PlaceableHusbandryFood.registerOverwrittenFunctions(placeable)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateInputAndOutput", PlaceableHusbandryFood.updateInputAndOutput)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateFeeding", RealisticLivestock_PlaceableHusbandryFood.updateFeeding)
	SpecializationUtil.registerOverwrittenFunction(placeable, "removeFood", RealisticLivestock_PlaceableHusbandryFood.removeFood)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateInfo", RealisticLivestock_PlaceableHusbandryFood.updateInfo)
	SpecializationUtil.registerOverwrittenFunction(placeable, "getFoodInfos", RealisticLivestock_PlaceableHusbandryFood.getFoodInfos)
end

PlaceableHusbandryFood.registerOverwrittenFunctions = Utils.appendedFunction(PlaceableHusbandryFood.registerOverwrittenFunctions, RealisticLivestock_PlaceableHusbandryFood.registerOverwrittenFunctions)


--- The pen's animals changed (AnimalClusterSystem flush): refresh all its per-hour totals now, not
--- the base game's sum over cluster age curves (RL_PlaceableHusbandry.refreshInputAndOutput). The
--- other specs' listeners leave their totals to this one call.
function RealisticLivestock_PlaceableHusbandryFood:onHusbandryAnimalsUpdate(superFunc, animals)
    RL_PlaceableHusbandry.refreshInputAndOutput(self, animals)
end

PlaceableHusbandryFood.onHusbandryAnimalsUpdate = Utils.overwrittenFunction(PlaceableHusbandryFood.onHusbandryAnimalsUpdate, RealisticLivestock_PlaceableHusbandryFood.onHusbandryAnimalsUpdate)


--- Record what the pen ate in this feeding: by forage category for the breed forage traits
--- (in a calf rearing pen the trough is drawn down within each animal's milk and solid limits,
--- RLCalfRearing)
--- (RLBreedTraits.getForageEfficiency, read by Animal:updateWeight), and liters per fill type
--- for the body condition budget (RLBodyCondition: trough removals inside this feeding plus
--- what the meadow lost, so food a feeding robot mixes in or a player adds is not counted).
function RealisticLivestock_PlaceableHusbandryFood:updateFeeding(superFunc)
    local spec = self.spec_husbandryFood
    if spec == nil or spec.fillLevels == nil then return superFunc(self) end

    local before = {}
    for fillTypeIndex, fillLevel in pairs(spec.fillLevels) do before[fillTypeIndex] = fillLevel end

    -- Real-equivalent nutrition (RLFeed): when the pen runs it this hour, the engine's food
    -- consumption is the ration planner's (AnimalFoodSystem.consumeFood), not the calf caps'.
    local realEquivalent = false
    if self.isServer then
        realEquivalent = RLFeed.beginFeeding(self)
        RLBodyCondition.beginFeeding(self)
        if not realEquivalent then RLCalfRearing.beginFeeding(self) end
    end

    local foodFactor = superFunc(self)

    if self.isServer then
        RLBodyCondition.endFeeding(self)
        if realEquivalent then RLFeed.endFeeding(self) else RLCalfRearing.settle(self) end
    end

    spec.rlForageShares = RLBreedTraits.getForageShares(before, spec.fillLevels, self.spec_husbandryMeadow ~= nil)

    return foodFactor
end


--- Cattle pens: body condition and last hour's ration in the pen's info box (RLBodyCondition.getPenInfo),
--- and the real-equivalent nutrition mode's state, ration and first feed to run out (RLFeedInfoService).
function RealisticLivestock_PlaceableHusbandryFood:updateInfo(superFunc, infoTable)
    superFunc(self, infoTable)

    local spec = self.spec_husbandryFood
    if spec == nil then return end

    local rows = RLBodyCondition.getPenInfo(self) or {}
    for _, row in ipairs(RLFeedInfoService.getPenInfoRows(self)) do table.insert(rows, row) end
    if #rows == 0 then return end

    spec.rlInfoRows = spec.rlInfoRows or {}
    for index, row in ipairs(rows) do
        local info = spec.rlInfoRows[index]
        if info == nil or info.titleKey ~= row.titleKey then
            info = { titleKey = row.titleKey, title = g_i18n:getText(row.titleKey), text = "" }
            spec.rlInfoRows[index] = info
        end
        info.text = row.text
        -- A warning row (calves without milk) is shown in the info box's accent colour.
        info.accentuate = row.warning == true or nil
        table.insert(infoTable, info)
    end
end


--- Cattle pens' food rows: per feed in the real-equivalent nutrition mode, the grain group marked
--- as not eaten under the old rules (RLFeedInfoService.adjustFoodInfos).
function RealisticLivestock_PlaceableHusbandryFood:getFoodInfos(superFunc)
    return RLFeedInfoService.adjustFoodInfos(self, superFunc(self))
end


--- Count what the trough loses while a feeding is open (RLBodyCondition.recordRemoved).
function RealisticLivestock_PlaceableHusbandryFood:removeFood(superFunc, deltaToRemove, fillTypeIndex)
    local spec = self.spec_husbandryFood
    local before = spec ~= nil and spec.fillLevels ~= nil and spec.fillLevels[fillTypeIndex] or nil

    local removed = superFunc(self, deltaToRemove, fillTypeIndex)

    if before ~= nil and spec.rlFeedingWindow ~= nil then
        RLBodyCondition.recordRemoved(self, fillTypeIndex, before - (spec.fillLevels[fillTypeIndex] or 0))
    end

    return removed
end


--- The pen's ration settings and feed months (RLFeed), saved with its trough.
function RealisticLivestock_PlaceableHusbandryFood:saveToXMLFile(xmlFile, key)
    RLFeed.savePen(self, xmlFile, key)
end

PlaceableHusbandryFood.saveToXMLFile = Utils.appendedFunction(PlaceableHusbandryFood.saveToXMLFile, RealisticLivestock_PlaceableHusbandryFood.saveToXMLFile)


function RealisticLivestock_PlaceableHusbandryFood:loadFromXMLFile(xmlFile, key)
    RLFeed.loadPen(self, xmlFile, key)
end

PlaceableHusbandryFood.loadFromXMLFile = Utils.appendedFunction(PlaceableHusbandryFood.loadFromXMLFile, RealisticLivestock_PlaceableHusbandryFood.loadFromXMLFile)


function RealisticLivestock_PlaceableHusbandryFood.onSettingChanged(name, state)

    RealisticLivestock_PlaceableHusbandryFood[name] = state

end


function PlaceableHusbandryFood:updateInputAndOutput(superFunc, animals)

    superFunc(self, animals)

    local spec = self.spec_husbandryFood
    spec.litersPerHour = 0

    for _, animal in pairs(animals) do

        local subType = animal:getSubType()

        if subType ~= nil then

            local food = subType.input.food

            if food ~= nil then

                spec.litersPerHour = spec.litersPerHour + animal:getInput("food")

            end

        end

    end

end