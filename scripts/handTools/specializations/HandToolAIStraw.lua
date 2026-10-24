HandToolAIStraw = {}

HandToolAIStraw.numHeldStraws = 0
local specName = "spec_" .. g_currentModName .. ".aiStraw"
local saveNamespace = "." .. g_currentModName .. ".aiStraw"


function HandToolAIStraw.registerFunctions(handTool)

	SpecializationUtil.registerFunction(handTool, "setAnimal", HandToolAIStraw.setAnimal)
	SpecializationUtil.registerFunction(handTool, "setDewarUniqueId", HandToolAIStraw.setDewarUniqueId)
	SpecializationUtil.registerFunction(handTool, "showInfo", HandToolAIStraw.showInfo)
	SpecializationUtil.registerFunction(handTool, "updateStraw", HandToolAIStraw.updateStraw)
	SpecializationUtil.registerFunction(handTool, "renderErrorText", HandToolAIStraw.renderErrorText)
	SpecializationUtil.registerFunction(handTool, "getBelongsToDewar", HandToolAIStraw.getBelongsToDewar)
	SpecializationUtil.registerFunction(handTool, "getReturnRefusal", HandToolAIStraw.getReturnRefusal)
	SpecializationUtil.registerFunction(handTool, "onInseminate", HandToolAIStraw.onInseminate)
	SpecializationUtil.registerFunction(handTool, "onReturnToDewar", HandToolAIStraw.onReturnToDewar)

end


function HandToolAIStraw.registerOverwrittenFunctions(handTool)
	SpecializationUtil.registerOverwrittenFunction(handTool, "getShowInHandToolsOverview", HandToolAIStraw.getShowInHandToolsOverview)
	SpecializationUtil.registerOverwrittenFunction(handTool, "getName", HandToolAIStraw.getName)
end


function HandToolAIStraw.registerEventListeners(handTool)
	SpecializationUtil.registerEventListener(handTool, "onPostLoad", HandToolAIStraw)
	SpecializationUtil.registerEventListener(handTool, "onDelete", HandToolAIStraw)
	SpecializationUtil.registerEventListener(handTool, "onDraw", HandToolAIStraw)
	SpecializationUtil.registerEventListener(handTool, "onHeldStart", HandToolAIStraw)
	SpecializationUtil.registerEventListener(handTool, "onHeldEnd", HandToolAIStraw)
	SpecializationUtil.registerEventListener(handTool, "onRegisterActionEvents", HandToolAIStraw)
	SpecializationUtil.registerEventListener(handTool, "onReadStream", HandToolAIStraw)
	SpecializationUtil.registerEventListener(handTool, "onWriteStream", HandToolAIStraw)
end


function HandToolAIStraw.prerequisitesPresent()
	return true
end


function HandToolAIStraw:onPostLoad(savegame)

	HandToolAIStraw.numHeldStraws = HandToolAIStraw.numHeldStraws + 1

	local spec = self[specName]

	if self.isClient then spec.defaultCrosshair = self:createCrosshairOverlay("gui.crosshairDefault") end

	spec.inseminateText = g_i18n:getText("rl_ui_inseminateAnimal")
	spec.returnText = g_i18n:getText("rl_ui_returnStraw")
	spec.isEmpty = false
	spec.textAlpha = 1
	spec.textAlphaReverse = false

	if savegame == nil or savegame.xmlFile == nil then return end

	local xmlFile, key = savegame.xmlFile, savegame.key

	-- Try new namespace first, fall back to old namespace (migration support)
	local namespace = saveNamespace
	if not xmlFile:hasProperty(key .. namespace) then
		namespace = ".FS25_RealisticLivestockRM.aiStraw"
	end
	if not xmlFile:hasProperty(key .. namespace) then
		namespace = ".FS25_RealisticLivestock.aiStraw"  -- Legacy fallback
	end

	if not xmlFile:hasProperty(key .. namespace) then return end

	local baseKey = key .. namespace
	local animalKey = baseKey .. ".animal"

	spec.isEmpty = xmlFile:getBool(baseKey .. "#isEmpty", false)
	spec.dewarUniqueId = xmlFile:getString(baseKey .. "#dewarUniqueId")

	if xmlFile:hasProperty(animalKey) then

		local animal = {}

		animal.country = xmlFile:getInt(animalKey .. "#country")
		animal.farmId = xmlFile:getString(animalKey .. "#farmId")
		animal.uniqueId = xmlFile:getString(animalKey .. "#uniqueId")
		animal.name = xmlFile:getString(animalKey .. "#name")
		animal.typeIndex = xmlFile:getInt(animalKey .. "#typeIndex")
		animal.subTypeIndex = xmlFile:getInt(animalKey .. "#subTypeIndex")
		animal.success = xmlFile:getFloat(animalKey .. "#success")
		RLSemenBatch.loadFromXML(xmlFile, animalKey, animal)
		RLSemenBatch.ensure(animal, spec.dewarUniqueId)

		animal.genetics = {
			["metabolism"] = xmlFile:getFloat(animalKey .. ".genetics#metabolism"),
			["fertility"] = xmlFile:getFloat(animalKey .. ".genetics#fertility"),
			["health"] = xmlFile:getFloat(animalKey .. ".genetics#health"),
			["quality"] = xmlFile:getFloat(animalKey .. ".genetics#quality"),
			["productivity"] = xmlFile:getFloat(animalKey .. ".genetics#productivity")
		}
		-- A beef sire's straw has no milk gene (RLRearingPolicy).
		if RLRearingPolicy ~= nil and select(2, RLRearingPolicy.normalizeByIndex(animal.subTypeIndex, animal.genetics)) then
			RLRearingPolicy.noteMigrated("straw", animal.uniqueId)
		end

		self.animal = animal

		local animalSystem = g_currentMission.animalSystem
		local st = animalSystem:getSubTypeByIndex(animal.subTypeIndex)
		Log:debug("AIStraw load: subTypeIndex=%d -> resolved name=%s (type=%s)",
			animal.subTypeIndex, st and st.name or "nil",
			st and (animalSystem.typeIndexToName[st.typeIndex] or "?") or "nil")
		if st == nil then
			Log:warning("AIStraw load: subTypeIndex=%d has no matching subtype - straw data may be from removed pack", animal.subTypeIndex)
		elseif st.typeIndex ~= animal.typeIndex then
			local savedTypeName = animalSystem.typeIndexToName[animal.typeIndex] or "nil"
			local resolvedTypeName = animalSystem.typeIndexToName[st.typeIndex] or "nil"
			Log:warning("AIStraw load: type mismatch! saved typeIndex=%d(%s) but subTypeIndex=%d resolves to typeIndex=%d(%s) - index may be stale",
				animal.typeIndex, savedTypeName, animal.subTypeIndex, st.typeIndex, resolvedTypeName)
		end

	end

end


function HandToolAIStraw:onDelete()

	HandToolAIStraw.numHeldStraws = HandToolAIStraw.numHeldStraws - 1
	
	local spec = self[specName]

	if spec.defaultCrosshair ~= nil then
		spec.defaultCrosshair:delete()
		spec.defaultCrosshair = nil
	end

end


function HandToolAIStraw:saveToXMLFile(xmlFile, key)

	local animal = self[specName].animal

	xmlFile:setBool(key .. "#isEmpty", self[specName].isEmpty or false)
	xmlFile:setString(key .. "#dewarUniqueId", self[specName].dewarUniqueId or "")

	if animal ~= nil then

		xmlFile:setInt(key .. ".animal#country", animal.country)
		xmlFile:setString(key .. ".animal#farmId", animal.farmId)
		xmlFile:setString(key .. ".animal#uniqueId", animal.uniqueId)
		xmlFile:setString(key .. ".animal#name", animal.name)
		xmlFile:setInt(key .. ".animal#typeIndex", animal.typeIndex)
		xmlFile:setInt(key .. ".animal#subTypeIndex", animal.subTypeIndex)
		xmlFile:setFloat(key .. ".animal#success", animal.success)
		RLSemenBatch.saveToXML(xmlFile, key .. ".animal", animal)
		
		for type, value in pairs(animal.genetics) do
			xmlFile:setFloat(key .. ".animal.genetics#" .. type, value)
		end

	end

end


--- Deserialize straw state from the network stream (client join sync).
--- @param streamId number Network stream id
--- @param connection table Network connection
function HandToolAIStraw:onReadStream(streamId, connection)

	local spec = self[specName]

	spec.isEmpty = streamReadBool(streamId)
	spec.dewarUniqueId = streamReadString(streamId)

	local hasAnimal = streamReadBool(streamId)
	local animal

	if hasAnimal then

		animal = { ["genetics"] = {} }

		animal.country = streamReadUInt8(streamId)
		animal.farmId = streamReadString(streamId)
		animal.uniqueId = streamReadString(streamId)
		animal.name = streamReadString(streamId)
		animal.typeIndex = streamReadUInt8(streamId)
		animal.subTypeIndex = streamReadUInt8(streamId)
		animal.success = streamReadFloat32(streamId)

		animal.genetics.metabolism = streamReadFloat32(streamId)
		animal.genetics.fertility = streamReadFloat32(streamId)
		animal.genetics.health = streamReadFloat32(streamId)
		animal.genetics.quality = streamReadFloat32(streamId)
		animal.genetics.productivity = streamReadFloat32(streamId)

		if animal.genetics.productivity < 0 then animal.genetics.productivity = nil end
		if RLRearingPolicy ~= nil then RLRearingPolicy.normalizeByIndex(animal.subTypeIndex, animal.genetics) end
		RLSemenBatch.readStream(streamId, animal)

	end

	spec.animal = animal

	if animal ~= nil then
		local animalSystem = g_currentMission.animalSystem
		local st = animalSystem:getSubTypeByIndex(animal.subTypeIndex)
		Log:debug("AIStraw readStream: subTypeIndex=%d -> resolved name=%s",
			animal.subTypeIndex, st and st.name or "nil")
		if st == nil then
			Log:warning("AIStraw readStream: subTypeIndex=%d has no matching subtype", animal.subTypeIndex)
		end
	end

end


function HandToolAIStraw:onWriteStream(streamId, connection)

	local spec = self[specName]

	streamWriteBool(streamId, spec.isEmpty or false)
	streamWriteString(streamId, spec.dewarUniqueId or "")

	streamWriteBool(streamId, spec.animal ~= nil)

	if spec.animal ~= nil then

		local animal = spec.animal

		streamWriteUInt8(streamId, animal.country)
		streamWriteString(streamId, animal.farmId)
		streamWriteString(streamId, animal.uniqueId)
		streamWriteString(streamId, animal.name or "")
		streamWriteUInt8(streamId, animal.typeIndex)
		streamWriteUInt8(streamId, animal.subTypeIndex)
		streamWriteFloat32(streamId, animal.success)

		streamWriteFloat32(streamId, animal.genetics.metabolism)
		streamWriteFloat32(streamId, animal.genetics.fertility)
		streamWriteFloat32(streamId, animal.genetics.health)
		streamWriteFloat32(streamId, animal.genetics.quality)
		streamWriteFloat32(streamId, animal.genetics.productivity or -1)
		RLSemenBatch.writeStream(streamId, animal)

	end

end


--- Update straw targeting each frame: find insemination target or dewar for return.
--- @param dT number Delta time in ms
function HandToolAIStraw:updateStraw(dT)

	local spec = self[specName]
	local player = self:getCarryingPlayer()

	if player == nil then
		spec.textAlpha = 1
		g_inputBinding:setActionEventActive(spec.activateActionEventId, false)
		return
	end

	spec.targetedPlaceable, spec.targetedAnimal, spec.targetedDewar = nil, nil, nil

	-- Waiting for the server's answer: the straw can be neither used again nor put back.
	if not player.isOwner or spec.awaitingServer then
		spec.textAlpha = 1
		spec.textAlphaReverse = false
		g_inputBinding:setActionEventActive(spec.activateActionEventId, false)
		return 
	end

	local node = player.targeter:getClosestTargetedNodeFromType(HandToolAIStraw)

	if node == nil or node == 0 then
		spec.textAlpha = 1
		spec.textAlphaReverse = false
		g_inputBinding:setActionEventActive(spec.activateActionEventId, false)
		return
	end

	local placeable, animal = HandToolAIStraw.getHusbandryAndClusterFromNode(player, node)

	if placeable == nil or animal == nil then

		-- A dewar is a vehicle (pallet): its collision is in the VEHICLE group.
		local object = RLStrawReturn.findDewar(node, function(n) return g_currentMission:getNodeObject(n) end, getParent)

        if object ~= nil then

			local refusal = self:getReturnRefusal(object)

			if refusal == nil then
				
				spec.targetedDewar = object
				spec.actionContext = "return"
				g_inputBinding:setActionEventActive(spec.activateActionEventId, true)
				g_inputBinding:setActionEventText(spec.activateActionEventId, spec.returnText)

			else

				g_inputBinding:setActionEventActive(spec.activateActionEventId, false)

				self:renderErrorText(RLStrawReturn.getText(refusal))

			end

		else

			g_inputBinding:setActionEventActive(spec.activateActionEventId, false)
			spec.textAlpha = 1
			spec.textAlphaReverse = false

		end

		return

	end

	local canBeInseminated, error = animal:getCanBeInseminatedByAnimal(spec.animal)

	-- Another straw of this player already waits for the server's answer about this animal.
	if canBeInseminated and g_server == nil and AnimalInseminationEvent.isAwaiting(animal) then
		canBeInseminated, error = false, g_i18n:getText("rl_insemination_pending")
	end

	if spec.isEmpty or not canBeInseminated then

		if spec.isEmpty then error = g_i18n:getText("rl_ui_strawEmpty") end

		g_inputBinding:setActionEventActive(spec.activateActionEventId, false)

		self:renderErrorText(error)

		return

	end

	spec.targetedPlaceable, spec.targetedAnimal = placeable, animal
	
				
	spec.actionContext = "inseminate"
	g_inputBinding:setActionEventActive(spec.activateActionEventId, true)
	local actionText = string.format(spec.inseminateText, animal:getIdentifiers())
	local inbreeding = RLPedigree.getText(RLPedigree.checkMating(animal, spec.animal))
	if inbreeding ~= nil then actionText = actionText .. " - " .. inbreeding end
	g_inputBinding:setActionEventText(spec.activateActionEventId, actionText)

end


function HandToolAIStraw:onHeldStart()

	if g_localPlayer == nil or self:getCarryingPlayer() ~= g_localPlayer or not g_localPlayer.isOwner then return end
	
	g_localPlayer.targeter:addTargetType(HandToolAIStraw, CollisionFlag.ANIMAL + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.VEHICLE, 0.5, 3)
	g_localPlayer.hudUpdater:setCarriedItem(self)
	g_aiStrawUpdater:setStraw(self)
	g_currentMission:addUpdateable(g_aiStrawUpdater)

	local spec = self[specName]
	spec.textAlpha = 1
	spec.textAlphaReverse = false

end


function HandToolAIStraw:onHeldEnd()

	if g_localPlayer == nil or g_localPlayer.hudUpdater:getCarriedItem() ~= self then return end

	if g_localPlayer.isOwner then g_localPlayer.targeter:removeTargetType(HandToolAIStraw) end

	g_localPlayer.hudUpdater:setCarriedItem()
	g_aiStrawUpdater:setStraw()
	g_currentMission:removeUpdateable(g_aiStrawUpdater)

end


function HandToolAIStraw:onRegisterActionEvents()

	if self:getIsActiveForInput(true) then

		local _, eventId = self:addActionEvent(InputAction.ACTIVATE_HANDTOOL, self, HandToolAIStraw.onActionFired, false, true, false, true, nil)
		self[specName].activateActionEventId = eventId
		g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_VERY_HIGH)
		g_inputBinding:setActionEventText(eventId, "")
		g_inputBinding:setActionEventActive(eventId, false)

	end

end


function HandToolAIStraw:setAnimal(animal)

	self[specName].animal = animal

end


function HandToolAIStraw:setDewarUniqueId(dewarUniqueId)

	self[specName].dewarUniqueId = dewarUniqueId

end


function HandToolAIStraw:showInfo(box)

	local animal = self[specName].animal

	if animal == nil then return end

	local animalSystem = g_currentMission.animalSystem
	local subType = animalSystem:getSubTypeByIndex(animal.subTypeIndex)
	
    box:addLine(g_i18n:getText("rl_ui_averageSuccess"), string.format("%s%%", tostring(math.round(animal.success * 100))))
    box:addLine(g_i18n:getText("rl_ui_species"), animalSystem:getTypeByIndex(animal.typeIndex).groupTitle)
    box:addLine(g_i18n:getText("infohud_type"), g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex))
	box:addLine(g_i18n:getText("infohud_name"), animal.name)
	box:addLine(g_i18n:getText("rl_ui_earTag"), string.format("%s %s %s", RLConstants.AREA_CODES[animal.country].code, animal.farmId, animal.uniqueId))
	for _, line in ipairs(RLSemenBatch.getInfoLines(animal)) do box:addLine(line[1], line[2]) end

	for type, value in pairs(animal.genetics) do

		local valueText

		if value >= 1.65 then
            valueText = "extremelyHigh"
        elseif value >= 1.4 then
            valueText = "veryHigh"
        elseif value >= 1.1 then
            valueText = "high"
        elseif value >= 0.9 then
            valueText = "average"
        elseif value >= 0.7 then
            valueText = "low"
        elseif value >= 0.35 then
            valueText = "veryLow"
        else
            valueText = "extremelyLow"
        end

		box:addLine(g_i18n:getText("rl_ui_" .. type), g_i18n:getText("rl_ui_genetics_" .. valueText))

	end

end


function HandToolAIStraw.getHusbandryAndClusterFromNode(player, node)

    if node == nil or not entityExists(node) then return nil, nil end

	local husbandryId, animalId = getAnimalFromCollisionNode(node)

	if husbandryId ~= nil and husbandryId ~= 0 then

		local clusterHusbandry = g_currentMission.husbandrySystem:getClusterHusbandryById(husbandryId)

		if clusterHusbandry ~= nil then

			local placeable = clusterHusbandry:getPlaceable()
			local animal = clusterHusbandry:getClusterByAnimalId(animalId, husbandryId)

			if animal ~= nil and (g_currentMission.accessHandler:canFarmAccess(player.farmId, placeable) and (animal.changeDirt ~= nil and animal.getName ~= nil)) then return placeable, animal end

		end

	end

	return nil, nil

end


function HandToolAIStraw:onActionFired()

	local spec = self[specName]
	if spec.awaitingServer then return end

	if spec.actionContext == "inseminate" then
		self:onInseminate()
	elseif spec.actionContext == "return" then
		self:onReturnToDewar()
	end

end


--- Apply insemination from this straw to the targeted animal, sync via event, and delete the straw.
--- A remote client only sends the request and holds the straw: the server answers through
--- AnimalInseminationEvent, and onServerAnswer then uses it up or gives it back.
function HandToolAIStraw:onInseminate()

	local spec = self[specName]

	local husbandry, animal = spec.targetedPlaceable, spec.targetedAnimal
	Log:trace("onInseminate: animal=%s husbandry=%s isServer=%s", tostring(animal), tostring(husbandry), tostring(self.isServer))

	g_inputBinding:setActionEventActive(spec.activateActionEventId, false)

	if g_server == nil then
		if g_client == nil or not AnimalInseminationEvent.awaitServer(animal, self) then return end
		spec.awaitingServer = true
		spec.requestedAnimal = animal
		g_client:getServerConnection():sendEvent(AnimalInseminationEvent.new(husbandry, animal, spec.animal))
		Log:debug("onInseminate: straw held until the server answers")
		return
	end

	animal:setInsemination(spec.animal)
	g_server:broadcastEvent(AnimalInseminationEvent.new(husbandry, animal, spec.animal))
	if AnimalReproduction ~= nil then AnimalReproduction.notifySubmitted(animal) end

	spec.isEmpty = true
	g_currentMission.handToolSystem:markHandToolForDeletion(self)
	Log:debug("onInseminate: straw emptied and marked for deletion (isServer=%s)", tostring(self.isServer))

end


--- Client: the server's answer to this straw's insemination request. Accepted uses the straw up;
--- refused gives it back to the player.
function HandToolAIStraw:onServerAnswer(accepted)

	local spec = self[specName]
	if self.isDeleted or spec == nil or not spec.awaitingServer then return end
	spec.awaitingServer = false

	if accepted then
		spec.isEmpty = true
		g_currentMission.handToolSystem:markHandToolForDeletion(self)
		if AnimalReproduction ~= nil then AnimalReproduction.notifySubmitted(spec.requestedAnimal) end
		Log:debug("onServerAnswer: insemination accepted, straw marked for deletion")
	else
		Log:debug("onServerAnswer: insemination refused, straw kept")
	end

end


--- Put this straw back into the targeted dewar. A host or single player checks the return rule
--- and applies it here; a remote client sends a request and holds the straw until the server
--- answers (ReturnStrawEvent -> onReturnAnswer), so a refused straw is never lost.
function HandToolAIStraw:onReturnToDewar()

	local spec = self[specName]

	local dewar = spec.targetedDewar
	Log:trace("onReturnToDewar: dewar=%s isServer=%s", tostring(dewar), tostring(self.isServer))

	g_inputBinding:setActionEventActive(spec.activateActionEventId, false)

	local refusal = self:getReturnRefusal(dewar)
	if refusal ~= nil then
		HandToolAIStraw.showReturnRefusal(refusal)
		return
	end

	if g_server == nil then
		if g_client == nil then return end
		spec.awaitingServer = true
		local requestId = ReturnStrawEvent.request(self, dewar, spec)
		Log:debug("onReturnToDewar: request %d sent, straw held until the server answers", requestId)
		return
	end

	dewar:changeStraws(1)
	spec.isEmpty = true
	g_currentMission.handToolSystem:markHandToolForDeletion(self)
	Log:debug("onReturnToDewar: straw returned to dewar=%s straws=%s", tostring(dewar:getUniqueId()), tostring(dewar.straws))

end


--- Client: the server's answer to this straw's return. nil refusal: the dewar has it, the straw
--- is used up; otherwise the player keeps the straw and sees why.
function HandToolAIStraw:onReturnAnswer(refusal)

	local spec = self[specName]
	if self.isDeleted or spec == nil or not spec.awaitingServer then return end
	spec.awaitingServer = false

	if refusal == nil then
		spec.isEmpty = true
		g_currentMission.handToolSystem:markHandToolForDeletion(self)
		Log:debug("onReturnAnswer: return accepted, straw marked for deletion")
	else
		HandToolAIStraw.showReturnRefusal(refusal)
		Log:debug("onReturnAnswer: return refused (%s), straw kept", tostring(refusal))
	end

end


function HandToolAIStraw.showReturnRefusal(refusal)

	if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
		g_currentMission:showBlinkingWarning(RLStrawReturn.getText(refusal), 3000)
	end

end


function HandToolAIStraw:getShowInHandToolsOverview()

	return false

end


--- The straw has no store item, so the base getName (the store item's name) would be nil.
function HandToolAIStraw:getName(superFunc)

	return superFunc(self) or g_i18n:getText("rl_ui_aiStraw")

end


function HandToolAIStraw:renderErrorText(text)

	local spec = self[specName]

	setTextAlignment(RenderText.ALIGN_CENTER)
	setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
	setTextColor(1, 0, 0, spec.textAlpha)
	renderText(0.5, 0.6, 0.023, text)

	spec.textAlpha = spec.textAlpha + (spec.textAlphaReverse and 0.015 or -0.015)

	if spec.textAlpha <= 0 or spec.textAlpha >= 1 then spec.textAlphaReverse = not spec.textAlphaReverse end

end


--- Why this straw cannot go into `dewar` (RLStrawReturn.REFUSAL), or nil when it can: its own
--- dewar or another of the same batch, on the straw's farm, with room left.
function HandToolAIStraw:getReturnRefusal(dewar)

	return RLStrawReturn.getRefusal(self[specName], dewar, self:getOwnerFarmId())

end


function HandToolAIStraw:getBelongsToDewar(dewar)

	return HandToolAIStraw.getReturnRefusal(self, dewar) == nil

end


function HandToolAIStraw:onDraw()

	self[specName].defaultCrosshair:render()

end