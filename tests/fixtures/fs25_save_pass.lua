-- The game's save pass, FS25 v1.23.1 (decompiled source), for the T02 ledger tests.
--
-- Exact excerpts (bodies unchanged):
--   dataS/scripts/utils/Utils.lua 386-399 (appendedFunction, prependedFunction)
--     sha256 ea9c8b23e6311b7d8b3e0d228005f778e3aab64768bb4b69553586cd8cc3ac23
--   dataS/scripts/xml/XMLFile.lua 247-259 (setTable)
--     sha256 75c391b6858cdcbed619b324f1ce942ef6f5f9a92d7b471a344f10ce7672a148
--   dataS/scripts/placeables/PlaceableSystem.lua 403-410 (save)
--     sha256 5dc6308a7162fbba6510848e2b6cb0c6dc786904e04a1dae0e6c9d8b34de057a
--   dataS/scripts/vehicles/VehicleSystem.lua 285-303 (save, saveToXML)
--     sha256 b08812b9e8d94927245f4a62890a96c3258939c53140c6212fe5b20e5d3dff6d
--   dataS/scripts/farms/FarmManager.lua 59-70 (saveToXMLFile)
--     sha256 e852949d76956d64496e2e0444aebf3472ef1b1c72b2593e8670ca831f5ff76a
--
-- Stand-ins, reduced (marked): FSCareerMissionInfo:saveToXMLFile keeps only what matters here
-- from lines 246-375 (sha256 f56a64dfb4a11394ce488986c8f4319fe64e27d2291913be5c9a239a02a9b759),
-- in the game's order - careerSavegame document created WITHOUT a filename, placeables,
-- vehicles, farms, then saveXMLFile on the career document, which fails as in the game;
-- PlaceableSystem:saveToXML / VehicleSystem.saveVehicleToXML / Farm:saveToXMLFile write a few
-- test fields; SavegameController.finishSave stands in for the engine's end of the save
-- (SavegameController.lua 641-647, 363-366, 668-684): the career document serialized with
-- saveXMLFileToMemory, written as careerSavegame.xml by saveWriteSavegameFinish, then
-- onSaveComplete(errorCode, finalSavegameDirectory); onSaveComplete itself only records.

Utils = Utils or {}
function Utils.appendedFunction(oldFunc, newFunc)
	return oldFunc ~= nil and function(...)
		-- upvalues: (copy) oldFunc, (copy) newFunc
		oldFunc(...)
		newFunc(...)
	end or newFunc
end
function Utils.prependedFunction(oldFunc, newFunc)
	return oldFunc ~= nil and function(...)
		-- upvalues: (copy) newFunc, (copy) oldFunc
		newFunc(...)
		oldFunc(...)
	end or newFunc
end

function XMLFile.setTable(_, path, tbl, closure)
	local i = 0
	for key, value in pairs(tbl) do
		local res = closure((path .. "(") .. i .. ")", value, key)
		if res == false then
			break
		end
		if res ~= 0 then
			i = i + 1
		end
	end
	return i
end

PlaceableSystem = { version = 1 }
PlaceableSystem.__index = PlaceableSystem
function PlaceableSystem:save(xmlFilename, usedModNames)
	local xmlFile = XMLFile.create("placeablesXML", xmlFilename, "placeables", Placeable.xmlSchemaSavegame)
	if xmlFile ~= nil then
		self:saveToXML(xmlFile, usedModNames)
		xmlFile:save()
		xmlFile:delete()
	end
end
-- Stand-in body: every placeable writes its own fields.
function PlaceableSystem:saveToXML(xmlFile, usedModNames)
	xmlFile:setString("placeables#version", tostring(self.version))
	for i, placeable in ipairs(self.placeables) do
		placeable:saveToXMLFile(xmlFile, string.format("placeables.placeable(%d)", i - 1), usedModNames)
	end
end
Placeable = { xmlSchemaSavegame = {} }

VehicleSystem = {}
VehicleSystem.__index = VehicleSystem
function VehicleSystem:save(xmlFilename, usedModNames)
	local xmlFile = XMLFile.create("vehiclesXML", xmlFilename, "vehicles", Vehicle.xmlSchemaSavegame)
	if xmlFile ~= nil then
		self:saveToXML(self.vehicles, xmlFile, usedModNames)
		xmlFile:delete()
	end
end
function VehicleSystem:saveToXML(vehicles, xmlFile, usedModNames)
	if xmlFile ~= nil then
		local xmlIndex = 0
		for i, vehicle in ipairs(vehicles) do
			if vehicle:getNeedsSaving() then
				self:saveVehicleToXML(vehicle, xmlFile, xmlIndex, i, usedModNames)
				xmlIndex = xmlIndex + 1
			end
		end
		xmlFile:save(false, true)
	end
end
-- Stand-in body.
function VehicleSystem.saveVehicleToXML(_, vehicle, xmlFile, index)
	vehicle:saveToXMLFile(xmlFile, string.format("vehicles.vehicle(%d)", index))
end
Vehicle = { xmlSchemaSavegame = {} }

FarmManager = { SPECTATOR_FARM_ID = 0, GUIDED_TOUR_FARM_ID = 15 }
FarmManager.__index = FarmManager
function FarmManager:saveToXMLFile(xmlFilename)
	local xmlFile = XMLFile.create("farmsXML", xmlFilename, "farms")
	xmlFile:setTable("farms.farm", self.farms, function(path, farm)
		-- upvalues: (copy) xmlFile
		if farm.farmId == FarmManager.SPECTATOR_FARM_ID or farm.farmId == FarmManager.GUIDED_TOUR_FARM_ID then
			return 0
		end
		farm:saveToXMLFile(xmlFile, path)
	end)
	xmlFile:save()
	xmlFile:delete()
end

-- Stand-in: the farm's money, exact to the bit.
Farm = {}
Farm.__index = Farm
function Farm:saveToXMLFile(xmlFile, key)
	xmlFile:setInt(key .. "#farmId", self.farmId)
	xmlFile:setString(key .. "#money", string.format("%.17g", self.money))
end

-- Stand-in, reduced to the order of FSCareerMissionInfo:saveToXMLFile (lines 246-375).
FSCareerMissionInfo = {}
FSCareerMissionInfo.__index = FSCareerMissionInfo
function FSCareerMissionInfo:saveToXMLFile()
	local xmlFile = createXMLFile("careerSavegameXML", "", "careerSavegame")
	self.xmlFile = xmlFile
	setXMLString(xmlFile, "careerSavegame.settings.savegameName", self.savegameName or "test")
	local mission = g_currentMission
	mission.placeableSystem:save(self.placeablesXML, {})
	mission.vehicleSystem:save(self.vehiclesXML, {})
	g_farmManager:saveToXMLFile(self.farmsXML)
	saveXMLFile(xmlFile)
end

SavegameController = { calls = {} }
SavegameController.__index = SavegameController
function SavegameController:onSaveComplete(errorCode, finalSavegameDirectory)
	SavegameController.calls[#SavegameController.calls + 1] = errorCode
end
Savegame = { ERROR_OK = 0, ERROR_SAVE_NO_SPACE = 3 }

-- Stand-in: the engine's end of a save. The career document, serialized after the pass, is
-- written only when the pass finished and the engine has no error to report; a failed write
-- is reported as an error code. passOk = false: the pass threw; no career file is written, and
-- onSaveComplete is still called so the run's state can be checked (what the game does after a
-- Lua error inside its pass is not modelled).
function SavegameController.finishSave(savegame, errorCode, passOk)
	errorCode = errorCode or Savegame.ERROR_OK
	if passOk ~= false and errorCode == Savegame.ERROR_OK then
		local metadata = saveXMLFileToMemory(savegame.xmlFile)
		local ok, written = pcall(XMLDisk.save, savegame.savegameDirectory .. "/careerSavegame.xml", metadata)
		if not ok or not written then errorCode = Savegame.ERROR_SAVE_NO_SPACE end
	end
	SavegameController.onSaveComplete(nil, errorCode, savegame.savegameDirectory)
	return errorCode
end
