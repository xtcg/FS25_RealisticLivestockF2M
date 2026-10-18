-- A stale or invalid title must be refused before vaccine checks or any application.
loadMod("scripts/disease/RLDiseaseVaccination.lua")
loadMod("scripts/events/DiseaseVaccinateEvent.lua")

local applied, charged, broadcast, dispatched = 0, 0, 0, 0
local animal = { isDead = false, numAnimals = 1, uniqueId = "A", farmId = "F", diseases = {},
    getNumAnimals = function(self) return self.numAnimals end }
local object = { getOwnerFarmId = function() return 1 end,
    getClusterSystem = function() return { animals = { animal } } end }
local models = { VALID = { title = "VALID", vaccine = { protectionMonths = 12, cost = 10 } },
    NO_VACCINE = { title = "NO_VACCINE" } }
g_server = { broadcastEvent = function() broadcast = broadcast + 1 end }
g_currentMission = { userManager = { getUserByConnection = function() return { nickname = "tester" } end },
    addMoney = function() charged = charged + 1 end }
g_diseaseManager = { diseasesEnabled = true, getDiseaseByTitle = function(_, title) return models[title] end }
RLPermissionHelper = { authorizeConnection = function() return true, nil, "tester", 1, 1 end }
RLAnimalUtil = { find = function() return animal end }
-- Spy on the application boundary: a refused request must never reach it.
DiseaseVaccinateEvent.apply = function() applied = applied + 1; return true end
DiseaseVaccinateEvent.dispatchToServer = function() dispatched = dispatched + 1 end

for _, title in ipairs({ "UNKNOWN_TITLE", "" }) do
    local hostOk, accepted = pcall(DiseaseVaccinateEvent.sendEvent, object, animal, title)
    check("vaccination request: host refuses unknown title '" .. title .. "' without raising",
        hostOk and accepted == false and applied == 0)
    local event = DiseaseVaccinateEvent.new(object, { farmId = "F", uniqueId = "A", country = 6 }, title)
    local remoteOk = pcall(event.run, event, {})
    check("vaccination request: server refuses unknown title '" .. title .. "' without raising",
        remoteOk and applied == 0)
end
check("vaccination request: invalid titles leave disease, money, broadcasts and dispatch untouched",
    #animal.diseases == 0 and charged == 0 and broadcast == 0 and dispatched == 0)

local hostOk, accepted = pcall(DiseaseVaccinateEvent.sendEvent, object, animal, "NO_VACCINE")
check("vaccination request: a known disease without a vaccine is still refused",
    hostOk and accepted == false and applied == 0)
check("vaccination request: valid host request still reaches the application",
    DiseaseVaccinateEvent.sendEvent(object, animal, "VALID") == true and applied == 1)
local event = DiseaseVaccinateEvent.new(object, { farmId = "F", uniqueId = "A", country = 6 }, "VALID")
event:run({})
check("vaccination request: valid permitted remote request still reaches the application", applied == 2)
