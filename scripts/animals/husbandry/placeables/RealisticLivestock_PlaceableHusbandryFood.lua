RealisticLivestock_PlaceableHusbandryFood = {}


function RealisticLivestock_PlaceableHusbandryFood.registerOverwrittenFunctions(placeable)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateInputAndOutput", PlaceableHusbandryFood.updateInputAndOutput)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateFeeding", RealisticLivestock_PlaceableHusbandryFood.updateFeeding)
end

PlaceableHusbandryFood.registerOverwrittenFunctions = Utils.appendedFunction(PlaceableHusbandryFood.registerOverwrittenFunctions, RealisticLivestock_PlaceableHusbandryFood.registerOverwrittenFunctions)


function RealisticLivestock_PlaceableHusbandryFood:onHusbandryAnimalsUpdate(superFunc, animals) end

PlaceableHusbandryFood.onHusbandryAnimalsUpdate = Utils.overwrittenFunction(PlaceableHusbandryFood.onHusbandryAnimalsUpdate, RealisticLivestock_PlaceableHusbandryFood.onHusbandryAnimalsUpdate)


--- Record what the pen ate in this feeding, by forage category, for the breed forage traits
--- (RLBreedTraits.getForageEfficiency, read by Animal:updateWeight).
function RealisticLivestock_PlaceableHusbandryFood:updateFeeding(superFunc)
    local spec = self.spec_husbandryFood
    if spec == nil or spec.fillLevels == nil then return superFunc(self) end

    local before = {}
    for fillTypeIndex, fillLevel in pairs(spec.fillLevels) do before[fillTypeIndex] = fillLevel end

    local foodFactor = superFunc(self)

    spec.rlForageShares = RLBreedTraits.getForageShares(before, spec.fillLevels, self.spec_husbandryMeadow ~= nil)

    return foodFactor
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