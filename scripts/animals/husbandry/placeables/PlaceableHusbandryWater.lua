RL_PlaceableHusbandryWater = {}


function RL_PlaceableHusbandryWater.registerOverwrittenFunctions(placeable)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateInputAndOutput", PlaceableHusbandryWater.updateInputAndOutput)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateFeeding", RL_PlaceableHusbandryWater.updateFeeding)
end

PlaceableHusbandryWater.registerOverwrittenFunctions = Utils.appendedFunction(PlaceableHusbandryWater.registerOverwrittenFunctions, RL_PlaceableHusbandryWater.registerOverwrittenFunctions)


function RL_PlaceableHusbandryWater:onHusbandryAnimalsUpdate(_, _) end


--- Record the share of its water need the pen got this hour, for the body condition budget
--- (RLBodyCondition.recordWater): milk is capped by it there, and nowhere else.
function RL_PlaceableHusbandryWater:updateFeeding(superFunc)
	local spec = self.spec_husbandryWater
	if not self.isServer or spec == nil or (spec.litersPerHour or 0) <= 0 or spec.automaticWaterSupply then
		local factor = superFunc(self)
		if self.isServer then RLBodyCondition.recordWater(self, 1) end
		return factor
	end

	local delta = spec.litersPerHour * g_currentMission.environment.timeAdjustment
	local before = self:getHusbandryFillLevel(spec.fillType)
	local factor = superFunc(self)
	local drunk = before - self:getHusbandryFillLevel(spec.fillType)

	RLBodyCondition.recordWater(self, delta > 0 and drunk / delta or 1)

	return factor
end

PlaceableHusbandryWater.onHusbandryAnimalsUpdate = Utils.overwrittenFunction(PlaceableHusbandryWater.onHusbandryAnimalsUpdate, RL_PlaceableHusbandryWater.onHusbandryAnimalsUpdate)


function PlaceableHusbandryWater:updateInputAndOutput(superFunc, animals)

	superFunc(self, animals)

    local spec = self.spec_husbandryWater
    spec.litersPerHour = 0

    for _, animal in pairs(animals) do

        local subType = animal:getSubType()

        if subType ~= nil then

            local water = subType.input.water

            if water ~= nil then

                spec.litersPerHour = spec.litersPerHour + animal:getInput("water")

            end

        end

    end

end