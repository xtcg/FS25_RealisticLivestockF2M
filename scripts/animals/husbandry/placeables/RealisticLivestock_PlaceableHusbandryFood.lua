RealisticLivestock_PlaceableHusbandryFood = {}


function RealisticLivestock_PlaceableHusbandryFood.registerOverwrittenFunctions(placeable)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateInputAndOutput", PlaceableHusbandryFood.updateInputAndOutput)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateFeeding", RealisticLivestock_PlaceableHusbandryFood.updateFeeding)
	SpecializationUtil.registerOverwrittenFunction(placeable, "removeFood", RealisticLivestock_PlaceableHusbandryFood.removeFood)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateInfo", RealisticLivestock_PlaceableHusbandryFood.updateInfo)
end

PlaceableHusbandryFood.registerOverwrittenFunctions = Utils.appendedFunction(PlaceableHusbandryFood.registerOverwrittenFunctions, RealisticLivestock_PlaceableHusbandryFood.registerOverwrittenFunctions)


function RealisticLivestock_PlaceableHusbandryFood:onHusbandryAnimalsUpdate(superFunc, animals) end

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

    if self.isServer then
        RLBodyCondition.beginFeeding(self)
        RLCalfRearing.beginFeeding(self)
    end

    local foodFactor = superFunc(self)

    if self.isServer then
        RLBodyCondition.endFeeding(self)
        RLCalfRearing.settle(self)
    end

    spec.rlForageShares = RLBreedTraits.getForageShares(before, spec.fillLevels, self.spec_husbandryMeadow ~= nil)

    return foodFactor
end


--- Cattle pens: body condition and last hour's ration in the pen's info box (RLBodyCondition.getPenInfo).
function RealisticLivestock_PlaceableHusbandryFood:updateInfo(superFunc, infoTable)
    superFunc(self, infoTable)

    local spec = self.spec_husbandryFood
    if spec == nil then return end

    local rows = RLBodyCondition.getPenInfo(self)
    if rows == nil then return end

    spec.rlInfoRows = spec.rlInfoRows or {}
    for index, row in ipairs(rows) do
        local info = spec.rlInfoRows[index]
        if info == nil or info.titleKey ~= row.titleKey then
            info = { titleKey = row.titleKey, title = g_i18n:getText(row.titleKey), text = "" }
            spec.rlInfoRows[index] = info
        end
        info.text = row.text
        table.insert(infoTable, info)
    end
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