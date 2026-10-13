-- Wire references are session-local node IDs. Durable transaction plans use
-- server-resolved save identities instead; a reused node ID cannot recover a sale.
RLDealerDestination = { VERSION = 1 }
local D = RLDealerDestination
local function integer(v) return type(v) == "number" and v == v and v > 0 and v % 1 == 0 and v < 2 ^ 53 end
local function text(v) return type(v) == "string" and #v > 0 and #v <= 4096 end
local function kind(object)
    if type(object) ~= "table" or object.isServer ~= true or type(object.getOwnerFarmId) ~= "function"
        or type(object.getClusterSystem) ~= "function" then return nil end
    if object.spec_husbandryAnimals ~= nil then return "PEN" end
    if object.spec_livestockTrailer ~= nil then return "TRAILER" end
end
function D.wireReference(object)
    if NetworkUtil == nil or type(NetworkUtil.getObjectId) ~= "function" then return nil, "NETWORK_REFERENCE_UNAVAILABLE" end
    local ok, id = pcall(NetworkUtil.getObjectId, object)
    if not ok or not integer(id) then return nil, "NETWORK_REFERENCE_UNAVAILABLE" end
    return "net:" .. string.format("%.0f", id)
end
function D.resolveWire(reference)
    if not text(reference) or not reference:match("^net:[1-9][0-9]*$") then return nil, "INVALID_DESTINATION_REFERENCE" end
    local id = tonumber(reference:sub(5))
    if not integer(id) or NetworkUtil == nil or type(NetworkUtil.getObject) ~= "function" then return nil, "INVALID_DESTINATION_REFERENCE" end
    local ok, object = pcall(NetworkUtil.getObject, id)
    if not ok or kind(object) == nil then return nil, "DESTINATION_NOT_FOUND" end
    return object
end
function D.persistedIdentity(object)
    local class = kind(object)
    if class == nil or type(object.getUniqueId) ~= "function" then return nil, "DESTINATION_SAVE_ID_REQUIRED" end
    local ok, uid = pcall(object.getUniqueId, object)
    local ownerOK, owner = pcall(object.getOwnerFarmId, object)
    if not ok or not text(uid) or not ownerOK or not integer(owner) then return nil, "DESTINATION_SAVE_ID_REQUIRED" end
    return { version = D.VERSION, kind = class, uniqueId = uid, ownerFarmId = owner }
end
-- The caller supplies a complete live pen/trailer inventory, never the client's
-- remembered node ID. Duplicate save IDs and changed owners remain ambiguous.
function D.resolvePersisted(identity, owners)
    if type(identity) ~= "table" or identity.version ~= D.VERSION or not text(identity.uniqueId)
        or (identity.kind ~= "PEN" and identity.kind ~= "TRAILER") or not integer(identity.ownerFarmId)
        or type(owners) ~= "table" then return nil, "INVALID_DESTINATION_IDENTITY" end
    local found, count = nil, 0
    for index, object in pairs(owners) do
        if not integer(index) or index > #owners then return nil, "DESTINATION_INVENTORY_UNREADABLE" end
        count = count + 1
        local current = D.persistedIdentity(object)
        if current == nil then return nil, "DESTINATION_INVENTORY_UNREADABLE" end
        if current.kind == identity.kind and current.uniqueId == identity.uniqueId then
            if found then return nil, "DESTINATION_IDENTITY_CONFLICT" end
            if current.ownerFarmId ~= identity.ownerFarmId then return nil, "DESTINATION_OWNER_CHANGED" end
            found = object
        end
    end
    if count ~= #owners then return nil, "DESTINATION_INVENTORY_UNREADABLE" end
    if found == nil then return nil, "DESTINATION_NOT_FOUND" end
    return found
end
-- Principal and player farm are resolved from the connection. Animal.farmId is
-- its source herd identity and is never used as the player's permission scope.
function D.authorize(connection, reference, mission, farmManager)
    if type(mission) ~= "table" or type(mission.getIsServer) ~= "function" or mission:getIsServer() ~= true
        or type(connection) ~= "table" or type(connection.getIsServer) ~= "function" or connection:getIsServer()
        or type(mission.getHasPlayerPermission) ~= "function" then return nil, "SERVER_ONLY" end
    local permitted, allowed = pcall(mission.getHasPlayerPermission, mission, "tradeAnimals", connection)
    if not permitted or allowed ~= true then return nil, "NO_PERMISSION" end
    local object, why = D.resolveWire(reference); if not object then return nil, why end
    local identity; identity, why = D.persistedIdentity(object); if not identity then return nil, why end
    if type(mission.userManager) ~= "table" or type(mission.userManager.getUniqueUserIdByConnection) ~= "function"
        or type(farmManager) ~= "table" or type(farmManager.getFarmForUniqueUserId) ~= "function" then return nil, "NO_PLAYER_FARM" end
    local userOK, userId = pcall(mission.userManager.getUniqueUserIdByConnection, mission.userManager, connection)
    if not userOK or not text(userId) then return nil, "NO_PLAYER_FARM" end
    local farmOK, farm = pcall(farmManager.getFarmForUniqueUserId, farmManager, userId)
    if not farmOK or type(farm) ~= "table" or not integer(farm.farmId) then return nil, "NO_PLAYER_FARM" end
    if farm.farmId ~= identity.ownerFarmId then return nil, "DESTINATION_NOT_OWNED" end
    return { principal = "farm:" .. tostring(farm.farmId) .. ":user:" .. userId,
        farmId = farm.farmId, destination = object, identity = identity }
end
