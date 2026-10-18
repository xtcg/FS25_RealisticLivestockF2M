RL_PlaceableHusbandry = {}


function RL_PlaceableHusbandry.registerFunctions(placeable)
	SpecializationUtil.registerFunction(placeable, "updateInputAndOutput", PlaceableHusbandry.updateInputAndOutput)
end

PlaceableHusbandry.registerFunctions = Utils.appendedFunction(PlaceableHusbandry.registerFunctions, RL_PlaceableHusbandry.registerFunctions)


function RL_PlaceableHusbandry:onHourChanged()
	RmSafeUtils.safeCall("PlaceableHusbandry:onHourChanged", function()

		local animals = self.spec_husbandryAnimals:getClusters()
		local temp = g_currentMission.environment.weather.temperatureUpdater.currentMin or 20

		for _, animal in pairs(animals) do
			RmSafeUtils.safeAnimalCall(animal, "onHourChanged", function()
				animal:updateInput()
				animal:updateOutput(temp)
			end)
		end

		if self.isServer then
			self:updateInputAndOutput(animals)

			-- Body condition: send this hour's steps to clients (RLBodyConditionStateEvent).
			local tick = RLBodyCondition.getTickId()
			if tick ~= nil and self.rlBodyConditionStepped == tick and g_server ~= nil
				and g_currentMission.missionDynamicInfo.isMultiplayer then
				g_server:broadcastEvent(RLBodyConditionStateEvent.new(self, tick))
			end
		end

	end)
end

PlaceableHusbandry.onHourChanged = Utils.appendedFunction(PlaceableHusbandry.onHourChanged, RL_PlaceableHusbandry.onHourChanged)


--- A husbandry's HOUR_CHANGED runs once per game hour: the engine raises it twice at a midnight
--- whose last frame lands in its 0.36 s pre-roll (RLBodyCondition.claimHour), which fed, aged and
--- settled the pen's hour twice. Other placeables keep the engine's callback as it is.
function RL_PlaceableHusbandry.hourChanged(self, superFunc, ...)
	if self.spec_husbandry ~= nil and not RLBodyCondition.claimHour(self) then return end
	return superFunc(self, ...)
end

if Placeable ~= nil then
	Placeable.hourChanged = Utils.overwrittenFunction(Placeable.hourChanged, RL_PlaceableHusbandry.hourChanged)
end


--- The animals in a pen changed (bought, moved, sold, born, died): set the pen's food, water,
--- straw, manure, milk and pallet liters per hour for the animals in it now, from each animal's
--- current per-hour input and output. The hourly hook above sets them after the hour's feeding,
--- for the next hour, so without this the next feeding would use the old herd: a pen empty last
--- hour asks for no food and its new animals go a whole hour unfed (foodFactor 0, health down by
--- decreasePerHour x health genetics), while the pen they left keeps eating for them.
--- Server only, and only once the mission runs: onStartMission sets every pen after load.
function RL_PlaceableHusbandry.refreshInputAndOutput(placeable, animals)
	if not placeable.isServer or g_currentMission == nil or not g_currentMission.isMissionStarted then return end

	RmSafeUtils.safeCall("PlaceableHusbandry:refreshInputAndOutput", function()
		placeable:updateInputAndOutput(animals)
	end)
end


function PlaceableHusbandry:updateInputAndOutput(animals) end