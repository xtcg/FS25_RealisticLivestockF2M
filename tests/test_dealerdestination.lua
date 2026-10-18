loadMod("scripts/dealer/RLDealerDestination.lua")
local D = RLDealerDestination
local pen = { isServer = true, spec_husbandryAnimals = {}, getClusterSystem = function() return {} end,
    getOwnerFarmId = function() return 2 end, getUniqueId = function() return "saved-pen-A" end }
local trailer = { isServer = true, spec_livestockTrailer = {}, getClusterSystem = pen.getClusterSystem,
    getOwnerFarmId = pen.getOwnerFarmId, getUniqueId = function() return "saved-trailer-A" end }
local registry = { [7] = pen, [9] = trailer }
NetworkUtil = { getObjectId = function(object) for id, value in pairs(registry) do if object == value then return id end end end,
    getObject = function(id) return registry[id] end }
check("dealer destination: wire uses session node ID for both pen and trailer", D.wireReference(pen) == "net:7"
    and D.resolveWire("net:9") == trailer)
check("dealer destination: alternate numeric spellings cannot alias a node", not D.resolveWire("net:07")
    and not D.resolveWire("net:7e0") and not D.resolveWire("net:0") and not D.resolveWire("7"))
local identity = assert(D.persistedIdentity(pen))
registry[7] = trailer; registry[11] = pen
check("dealer destination: reload recovery follows saved identity rather than reused node ID", D.resolvePersisted(identity, { pen, trailer }) == pen
    and D.resolveWire("net:7") == trailer and D.wireReference(pen) == "net:11")
local duplicate = { isServer = true, spec_husbandryAnimals = {}, getClusterSystem = pen.getClusterSystem,
    getOwnerFarmId = pen.getOwnerFarmId, getUniqueId = pen.getUniqueId }
check("dealer destination: duplicate save identities cannot settle ownership", not D.resolvePersisted(identity, { pen, duplicate }))
local owner = pen.getOwnerFarmId; pen.getOwnerFarmId = function() return 3 end
local no, why = D.resolvePersisted(identity, { pen, trailer })
pen.getOwnerFarmId = owner
check("dealer destination: transferred destination is refused during recovery", no == nil and why == "DESTINATION_OWNER_CHANGED")
local connection = { getIsServer = function() return false end }
local mission = { getIsServer = function() return true end, getHasPlayerPermission = function(_, permission) return permission == "tradeAnimals" end,
    userManager = { getUniqueUserIdByConnection = function() return "user-A" end } }
local farms = { getFarmForUniqueUserId = function(_, userId) if userId == "user-A" then return { farmId = 2 } end end }
local bound = assert(D.authorize(connection, "net:11", mission, farms))
check("dealer destination: server connection determines principal and player farm", bound.principal == "farm:2:user:user-A"
    and bound.farmId == 2 and bound.destination == pen and bound.identity.uniqueId == "saved-pen-A")
farms.getFarmForUniqueUserId = function() return { farmId = 3 } end
no, why = D.authorize(connection, "net:11", mission, farms)
check("dealer destination: permission does not grant ownership of another farm destination", no == nil and why == "DESTINATION_NOT_OWNED")
mission.getHasPlayerPermission = function() return false end
no, why = D.authorize(connection, "net:11", mission, farms)
check("dealer destination: revoked trade permission rejects before asset resolution", no == nil and why == "NO_PERMISSION")
trailer.getUniqueId = nil
check("dealer destination: unsupported persistent vehicle identity stays an explicit gap", not D.persistedIdentity(trailer))
check("dealer destination: incomplete recovery inventory cannot prove absence", not D.resolvePersisted(identity, { [2] = pen }))
