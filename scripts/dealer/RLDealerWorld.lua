-- Read-only engine inventory witness. No queue flush, generation or progression.
-- Cross-domain object aliases (including a rideable still registered in a pen)
-- are ambiguous ownership transitions and deliberately hold admission.
RLDealerWorld = {}
local W = RLDealerWorld
local function fail(reason) error(reason, 0) end
local dense=RLPlain.dense
local function empty(t) return type(t) == "table" and next(t) == nil end
local function capture(t)
    if not dense(t) then fail("REGISTRY_UNREADABLE") end
    local out = {}; for i, value in ipairs(t) do out[i] = value end; return out
end
local function unchanged(t, before)
    if not dense(t) or #t ~= #before then return false end
    for i, value in ipairs(before) do if t[i] ~= value then return false end end
    return true
end
local function id(v) return type(v) == "string" and v ~= "" and v ~= "-1" and not v:find("%s") end
local function stableId(v) return id(v) and v ~= "0" and v ~= "0-0" and v ~= "1-1" end
local function guarded(fn)
    local ok, a, b = pcall(fn)
    if not ok then return nil, "WORLD_UNSAFE:" .. tostring(a) end
    return a, b
end
function W.new(ctx)
    if type(ctx) ~= "table" or ctx.isServer ~= true or type(ctx.mission) ~= "table" then return nil, "WORLD_SERVER_REQUIRED" end
    local mission = ctx.mission
    local function registryReady()
        if mission ~= g_currentMission then fail("MISSION_CHANGED") end
        if type(mission.getIsServer) ~= "function" or mission:getIsServer() ~= true then fail("SERVER_REQUIRED") end
        if mission ~= g_currentMission then fail("MISSION_CHANGED") end
        local p, v = mission.placeableSystem, mission.vehicleSystem
        if type(p) ~= "table" or type(v) ~= "table" or not dense(p.placeables) or not dense(v.vehicles) then fail("REGISTRY_UNREADABLE") end
        if not empty(p.pendingPlaceableLoadingData) or not empty(p.placeablesToDelete)
            or not empty(v.pendingVehicleLoadingData) or not empty(v.pendingVehicleSavegameLoadings)
            or not empty(v.vehiclesToDelete) then fail("REGISTRY_BUSY") end
        if (p.placeablesToLoad ~= nil and p.placeablesToLoad ~= 0)
            or (v.vehiclesToLoad ~= nil and v.vehiclesToLoad ~= 0) then fail("REGISTRY_LOADING") end
        return p, v
    end
    local function inventory()
        local p, v = registryReady()
        local witness = {p=p,v=v,placeablesRef=p.placeables,vehiclesRef=v.vehicles,
            placeables=capture(p.placeables),vehicles=capture(v.vehicles),clusters={}}
        local owners, seen = {}, {}
        local function register(object, expected, domain)
            if type(object) ~= "table" or seen[object] then fail("REGISTRY_OBJECT_ALIAS:" .. domain) end
            seen[object] = true
            if object[expected] ~= nil then
                if object.spec_husbandryAnimals ~= nil and object.spec_livestockTrailer ~= nil then fail("OWNER_KIND_AMBIGUOUS") end
                if RLTradeSourceAdapter == nil then fail("SUPPORT_UNAVAILABLE") end
                local c, why = RLTradeSourceAdapter.getSupport(object)
                if not c then fail(why) end
                if not empty(c.clustersToAdd) or not empty(c.clustersToRemove) then fail("OWNER_QUEUE_BUSY") end
                owners[#owners + 1] = object
                witness.clusters[object] = c
            end
        end
        for _, object in ipairs(witness.placeables) do register(object, "spec_husbandryAnimals", "PLACEABLE") end
        for _, object in ipairs(witness.vehicles) do register(object, "spec_livestockTrailer", "VEHICLE") end
        return owners, witness.vehicles, witness
    end
    local function verify(owners, witness, members)
        -- Resolve every owner again before the final pure checks: a getter can
        -- mutate a previously checked owner or a registry as well as itself.
        for _, owner in ipairs(owners) do
            local c = RLTradeSourceAdapter.getSupport(owner)
            if c ~= witness.clusters[owner] then fail("OWNER_CLUSTER_CHANGED") end
        end
        local p, v = registryReady()
        if p ~= witness.p or v ~= witness.v or p.placeables ~= witness.placeablesRef or v.vehicles ~= witness.vehiclesRef
            or not unchanged(p.placeables,witness.placeables) or not unchanged(v.vehicles,witness.vehicles) then fail("REGISTRY_CHANGED") end
        for _, owner in ipairs(owners) do
            local c = witness.clusters[owner]
            if not empty(c.clustersToAdd) or not empty(c.clustersToRemove) then fail("OWNER_QUEUE_BUSY") end
            if members and (c.animals ~= members[owner].ref or not unchanged(c.animals,members[owner].items)) then fail("MEMBERS_CHANGED") end
            if members then
                for _, animal in ipairs(members[owner].items) do
                    if animal.clusterSystem ~= c then fail("MEMBERS_MISMATCH") end
                end
            end
        end
    end
    local adapter = {}
    adapter.allOwners = function() return guarded(function()
        local owners, _, witness = inventory(); verify(owners,witness); return owners
    end) end
    adapter.checkGlobalIdentities = function(encoded)
        return guarded(function()
            local owners, vehicles, witness = inventory()
            local memberWitness = {}
            if RLAnimalUtil == nil or type(RLAnimalUtil.toKey) ~= "function" then fail("IDENTITY_HELPER_REQUIRED") end
            if RLConstants == nil or type(RLConstants.AREA_CODES) ~= "table" then fail("COUNTRY_REGISTRY_REQUIRED") end
            local objects, keys, identities, external = {}, {}, {}, {}
            local function identity(a, domain, unborn, encodedAnimal, damIdentity)
                if type(a) ~= "table" then fail("ANIMAL_UNREADABLE:" .. domain) end
                if objects[a] then fail("OBJECT_ALIAS:" .. objects[a] .. ":" .. domain) end
                objects[a] = domain
                local data = a
                if encodedAnimal then data = a.identity end
                if type(data) ~= "table" then fail("IDENTITY_UNREADABLE:" .. domain) end
                local children = a.pregnancy and (encodedAnimal and a.pregnancy.fetuses or a.pregnancy.pregnancies)
                identities[#identities + 1] = {animal=a,data=data,encoded=encodedAnimal,
                    farmId=data.farmId,uniqueId=data.uniqueId,birthday=data.birthday,
                    country=type(data.birthday)=="table" and data.birthday.country,
                    age=a.age,pregnancy=a.pregnancy,children=children,
                    members=children and capture(children)}
                -- Ordinary engine fetuses acquire IDs at actual birth. Only actual
                -- unborn shells may be unassigned; encoded owned fetuses are fixed.
                if not encodedAnimal and unborn and a.uniqueId == nil and type(a.age) == "number" and a.age < 0 then
                    if (a.farmId ~= nil and not id(a.farmId)) or a.pregnancy ~= nil then fail("UNBORN_IDENTITY_AMBIGUOUS:" .. domain) end
                    return
                end
                local country
                if type(data.birthday) == "table" then country = data.birthday.country end
                -- Fixed private source fetuses have no birthday until birth.
                -- Source-birth v1 explicitly assigns the dam's country then;
                -- this rule does not establish provenance for world fetuses.
                if encodedAnimal and unborn then
                    if damIdentity == nil or AnimalReproduction == nil or AnimalReproduction.SOURCE_BIRTH_VERSION ~= 1
                        or data.farmId ~= damIdentity.farmId then fail("SOURCE_UNBORN_PROVENANCE:" .. domain) end
                    local birthCountry = type(damIdentity.birthday) == "table" and damIdentity.birthday.country
                    if country ~= nil and country ~= birthCountry then fail("SOURCE_UNBORN_COUNTRY:" .. domain) end
                    country = birthCountry
                end
                if not stableId(data.uniqueId) or not stableId(data.farmId) or (data.uniqueId=="1" and data.farmId=="1") or type(country) ~= "number"
                    or country < 1 or country % 1 ~= 0 or country == math.huge
                    or RLConstants.AREA_CODES[country] == nil then fail("IDENTITY_UNREADABLE:" .. domain) end
                local key = RLAnimalUtil.toKey(data.farmId, data.uniqueId, country)
                if type(key) ~= "string" or key == "" then fail("IDENTITY_HELPER_INVALID") end
                if keys[key] then fail("IDENTITY_CONFLICT:" .. key .. ":" .. keys[key] .. ":" .. domain) end
                keys[key] = domain
                if a.pregnancy ~= nil then
                    if unborn or type(a.pregnancy) ~= "table" then fail("PREGNANCY_UNREADABLE:" .. domain) end
                    local children = encodedAnimal and a.pregnancy.fetuses or a.pregnancy.pregnancies
                    if not dense(children) or #children == 0 then fail("PREGNANCY_UNREADABLE:" .. domain) end
                    for i, child in ipairs(children) do identity(child, domain .. "/FETUS:" .. i, true, encodedAnimal, data) end
                end
            end
            for i, owner in ipairs(owners) do
                local c = witness.clusters[owner]
                memberWitness[owner] = {ref=c.animals,items=capture(c.animals)}
                local list = c:getClusters()
                if not dense(list) or not dense(c.animals) or #list ~= #c.animals then fail("MEMBERS_UNREADABLE") end
                if c.animals ~= memberWitness[owner].ref or not unchanged(c.animals,memberWitness[owner].items) then fail("MEMBERS_CHANGED") end
                for j, animal in ipairs(list) do
                    if animal ~= c.animals[j] or type(animal) ~= "table" or animal.clusterSystem ~= c then fail("MEMBERS_MISMATCH") end
                    identity(animal, "OWNER:" .. i .. "/ANIMAL:" .. j, false, false)
                end
            end
            for i, vehicle in ipairs(vehicles) do
                if vehicle.spec_rideable ~= nil then
                    if vehicle.isServer ~= true or type(vehicle.spec_rideable) ~= "table" or vehicle.spec_rideable.cluster == nil then fail("RIDEABLE_UNREADABLE") end
                    external[#external + 1] = {vehicle=vehicle,spec=vehicle.spec_rideable,animal=vehicle.spec_rideable.cluster}
                    identity(vehicle.spec_rideable.cluster, "RIDEABLE:" .. i, false, false)
                end
            end
            local animalSystem = mission.animalSystem
            if type(animalSystem) ~= "table" then fail("LEGACY_REGISTRY_UNREADABLE") end
            local legacy = {}
            for _, name in ipairs({"animals", "aiAnimals"}) do
                if type(animalSystem[name]) ~= "table" then fail("LEGACY_REGISTRY_UNREADABLE") end
                legacy[name] = {ref=animalSystem[name],types={}}
                for typeIndex, animals in pairs(animalSystem[name]) do
                    if type(typeIndex) ~= "number" or typeIndex < 1 or typeIndex % 1 ~= 0 or not dense(animals) then fail("LEGACY_REGISTRY_UNREADABLE") end
                    legacy[name].types[typeIndex] = {ref=animals,items=capture(animals)}
                    for i, animal in ipairs(animals) do identity(animal, name .. ":" .. typeIndex .. "/ANIMAL:" .. i, false, false) end
                end
            end
            if type(encoded) ~= "table" or encoded.version ~= 1 or type(encoded.owners) ~= "table" then fail("PRIVATE_REGISTRY_UNREADABLE") end
            for ownerId, owner in pairs(encoded.owners) do
                if type(ownerId) ~= "string" or ownerId == "" or type(owner) ~= "table" or not dense(owner.animals) then fail("PRIVATE_REGISTRY_UNREADABLE") end
                for i, animal in ipairs(owner.animals) do identity(animal, "PRIVATE:" .. ownerId .. "/ANIMAL:" .. i, false, true) end
            end
            verify(owners,witness,memberWitness)
            if mission.animalSystem ~= animalSystem then fail("LEGACY_REGISTRY_CHANGED") end
            for name, saved in pairs(legacy) do
                if animalSystem[name] ~= saved.ref then fail("LEGACY_REGISTRY_CHANGED") end
                for typeIndex in pairs(saved.ref) do if not saved.types[typeIndex] then fail("LEGACY_REGISTRY_CHANGED") end end
                for typeIndex, list in pairs(saved.types) do
                    if saved.ref[typeIndex] ~= list.ref or not unchanged(list.ref,list.items) then fail("LEGACY_REGISTRY_CHANGED") end
                end
            end
            for _, saved in ipairs(external) do
                if saved.vehicle.spec_rideable ~= saved.spec or saved.spec.cluster ~= saved.animal
                    or saved.vehicle.isServer ~= true then fail("RIDEABLE_CHANGED") end
            end
            for _, saved in ipairs(identities) do
                local a,data=saved.animal,saved.data
                if (saved.encoded and a.identity ~= data) or data.farmId ~= saved.farmId or data.uniqueId ~= saved.uniqueId
                    or data.birthday ~= saved.birthday or (type(data.birthday)=="table" and data.birthday.country) ~= saved.country
                    or a.age ~= saved.age or a.pregnancy ~= saved.pregnancy then fail("IDENTITY_CHANGED") end
                if saved.children then
                    local children=saved.encoded and a.pregnancy.fetuses or a.pregnancy.pregnancies
                    if children ~= saved.children or not unchanged(children,saved.members) then fail("PREGNANCY_CHANGED") end
                end
            end
            return true
        end)
    end
    return adapter
end
