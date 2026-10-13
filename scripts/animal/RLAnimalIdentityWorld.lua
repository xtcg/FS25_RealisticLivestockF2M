--[[
    Dealer v2 T2: the game-facing side of the identity runtime. Builds the allocation context each
    entry hands to RLAnimalIdentityRuntime.raw and reads the world for the migration scan. Reads only
    (apart from the counter mirror an ON allocation asks for), through pcall, never flushes a queue.

    Domains. A player herd is the farm's statistics.farmId (a random 6 digit number made when the farm
    first needs one) with the animal's birth country; an AI / sale farm is a country farm of
    AnimalSystem with its own numeric id. FarmStats counters are per species and per herd, not per
    country, so a herd-level counter bounds every country domain of that herd.
]]

RLAnimalIdentityWorld = {}
local W = RLAnimalIdentityWorld

local COUNTER_FIELDS = { "cowId", "pigId", "sheepId", "horseId", "chickenId" }


local function number(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v or nil end


--- The farm's herd id, made the way the old code makes it when the farm has none yet.
function W.ensureHerd(farm)
    if farm == nil or farm.stats == nil then return nil end
    local herd = farm.stats.statistics.farmId
    if herd == nil then
        herd = math.random(100000, 999999)
        farm.stats.statistics.farmId = herd
    end
    return herd
end


--- Highest raw any species counter of a farm's statistics reached.
function W.statsCounterMax(stats)
    local max = 0
    local s = stats.statistics
    for _, field in ipairs(COUNTER_FIELDS) do max = math.max(max, number(s[field]) or 0) end
    for _, nextId in pairs(s.typeIds or {}) do max = math.max(max, number(nextId) or 0) end
    return max
end


--- Move the counter of one species up to `raw` (never down), matching FarmStats.getNextAnimalId's choice of field.
function W.statsRaise(stats, animalTypeIndex, raw)
    local s = stats.statistics
    local field
    if animalTypeIndex == AnimalType.COW then field = "cowId"
    elseif animalTypeIndex == AnimalType.PIG then field = "pigId"
    elseif animalTypeIndex == AnimalType.SHEEP then field = "sheepId"
    elseif animalTypeIndex == AnimalType.HORSE then field = "horseId"
    elseif animalTypeIndex == AnimalType.CHICKEN then field = "chickenId" end
    if field ~= nil then
        s[field] = math.max(number(s[field]) or 0, raw)
        return
    end
    local typeObj = g_currentMission.animalSystem:getTypeByIndex(animalTypeIndex)
    local name = typeObj ~= nil and typeObj.name or tostring(animalTypeIndex)
    s.typeIds = s.typeIds or {}
    s.typeIds[name] = math.max(number(s.typeIds[name]) or 0, raw)
end


--- Context for an entry that numbers by a player farm's statistics.
function W.statsContext(entry, farm, animalTypeIndex, country, role, litter)
    local herd = W.ensureHerd(farm)
    if herd == nil then return nil, "NO_HERD" end
    return { entry = entry, country = country, herd = herd, typeKey = animalTypeIndex, role = role,
        litter = litter,
        counterMax = function() return W.statsCounterMax(farm.stats) end,
        mirror = function(raw) W.statsRaise(farm.stats, animalTypeIndex, raw) end }
end


local function systemFarm(animalSystem, countryIndex, farmId)
    local country = animalSystem.countries[countryIndex]
    if country == nil then return nil end
    if type(farmId) == "string" then farmId = tonumber(farmId) end
    for _, farm in pairs(country.farms) do
        if farm.id == farmId then return farm end
    end
    return nil
end


--- Context for an entry that numbers by a country farm table of AnimalSystem (sale, AI).
function W.systemContextForFarm(entry, countryIndex, farm, animalTypeIndex, role, litter)
    return { entry = entry, country = countryIndex, herd = tostring(farm.id), typeKey = animalTypeIndex, role = role, litter = litter,
        counterMax = function()
            local max = 0
            for _, id in pairs(farm.ids) do max = math.max(max, number(id) or 0) end
            return max
        end,
        mirror = function(raw)
            if farm.ids[animalTypeIndex] ~= nil then farm.ids[animalTypeIndex] = math.max(farm.ids[animalTypeIndex], raw) end
        end }
end


function W.systemContext(entry, animalSystem, countryIndex, farmId, animalTypeIndex, role, litter)
    local farm = systemFarm(animalSystem, countryIndex, farmId)
    if farm == nil then return nil, "NO_FARM" end
    return W.systemContextForFarm(entry, countryIndex, farm, animalTypeIndex, role, litter)
end


--- The raw value for an entry that numbers by a player farm's statistics (FarmStats:getNextAnimalId).
--- Answers nil and why only when the ledger is the allocator and refused.
function W.nextStatsRaw(entry, farm, animalTypeIndex, country, role)
    local R = RLAnimalIdentityRuntime
    local function legacy() return farm.stats:getNextAnimalId(animalTypeIndex) end
    if not R.authoritative() and (R.mode == R.OFF or R.state ~= "READY") then return legacy() end
    local ctx = W.statsContext(entry, farm, animalTypeIndex, country, role, role == "birth" and R.currentLitter() or nil)
    if ctx == nil then
        if R.authoritative() then return nil, "NO_DOMAIN" end
        return legacy()
    end
    return R.raw(ctx, legacy)
end


--- The raw value for an entry that numbers by a country farm table of AnimalSystem; `legacy` is the old increment.
function W.nextSystemRaw(entry, animalSystem, countryIndex, farm, animalTypeIndex, role, legacy)
    local R = RLAnimalIdentityRuntime
    if not R.authoritative() and (R.mode == R.OFF or R.state ~= "READY") then return legacy() end
    local ctx = W.systemContextForFarm(entry, countryIndex, farm, animalTypeIndex, role, role == "birth" and R.currentLitter() or nil)
    return R.raw(ctx, legacy)
end


--- The context for a newborn or a fixed-id animal: attached to a pen it numbers by its owner's statistics,
--- a sale animal (no cluster system) by the country farm named by `farmId`.
function W.animalContext(animal, farmIdArg, entry, litter)
    local mission = g_currentMission
    local country = animal.birthday ~= nil and animal.birthday.country or nil
    if animal.clusterSystem ~= nil then
        local owner = animal.clusterSystem.owner
        local ownerFarmId = owner ~= nil and owner.ownerFarmId or nil
        local farm = ownerFarmId ~= nil and g_farmManager.farmIdToFarm[ownerFarmId] or nil
        if farm == nil then return nil, "NO_OWNER_FARM" end
        local typeIndex = mission.animalSystem:getSubTypeByIndex(animal.subTypeIndex).typeIndex
        return W.statsContext(entry or "birth", farm, typeIndex, country or RealisticLivestock.getMapCountryIndex(), "birth", litter)
    end
    if farmIdArg == nil or country == nil then return nil, "NO_DOMAIN" end
    return W.systemContext(entry or "sale-birth", mission.animalSystem, country, farmIdArg, animal.animalTypeIndex, "birth", litter)
end


--- The pregnancy's stable event id: the mother, the due date and the litter size.
function W.birthEventId(animal, country)
    local due = animal.pregnancy ~= nil and animal.pregnancy.expected or nil
    local pregnancies = animal.pregnancy ~= nil and animal.pregnancy.pregnancies or {}
    return string.format("%s|%s|%s|%s|%s|%d", tostring(animal.farmId), tostring(animal.uniqueId), tostring(country),
        due ~= nil and (tostring(due.year) .. "-" .. tostring(due.month) .. "-" .. tostring(due.day)) or "?",
        tostring(animal.animalTypeIndex), #pregnancies)
end


--- Context and event id for the birth of `animal` (player pen or sale animal), or nil and why.
function W.birthContext(animal, isSaleAnimal)
    if animal.pregnancy == nil or type(animal.pregnancy.pregnancies) ~= "table" then return nil, "NO_PREGNANCY" end
    local context, why
    if isSaleAnimal then
        local country = animal.birthday ~= nil and animal.birthday.country or nil
        context, why = W.systemContext("sale-birth", g_currentMission.animalSystem, country, animal.farmId, animal.animalTypeIndex, "birth")
        return context, why or W.birthEventId(animal, country)
    end
    context, why = W.animalContext({ clusterSystem = animal.clusterSystem, subTypeIndex = animal.subTypeIndex,
        birthday = { country = RealisticLivestock.getMapCountryIndex() }, animalTypeIndex = animal.animalTypeIndex }, nil, "birth")
    if context == nil then return nil, why end
    return context, W.birthEventId(animal, context.country)
end


-- -------------------------------------------------------------------------------------------
-- Scan
-- -------------------------------------------------------------------------------------------

local function addRecord(records, animal, where)
    if type(animal) ~= "table" or animal.uniqueId == nil or animal.farmId == nil then return end
    local birthday = animal.birthday
    local country = type(birthday) == "table" and birthday.country or nil
    records[#records + 1] = { farmId = animal.farmId, uniqueId = animal.uniqueId, country = country,
        type = animal.animalTypeIndex ~= nil and tostring(animal.animalTypeIndex) or "?", where = where }
end


--- Every animal of the world with an identity, plus the native counters. Read only, tolerant of
--- missing parts: `partial` lists what could not be read. Returns { records, counters, partial }.
function W.scan(mission)
    mission = mission or g_currentMission
    local records, counters, partial, uncovered = {}, {}, {}, {}
    local function try(name, fn)
        local ok, err = pcall(fn)
        if not ok then partial[#partial + 1] = name .. ":" .. tostring(err) end
    end
    try("placeables", function()
        for _, placeable in pairs(mission.placeableSystem.placeables) do
            local spec = placeable.spec_husbandryAnimals
            local cs = spec ~= nil and spec.clusterSystem or (placeable.spec_livestockTrailer ~= nil and placeable.spec_livestockTrailer.clusterSystem) or nil
            if cs ~= nil then
                for _, animal in ipairs(cs.animals or {}) do addRecord(records, animal, "pen") end
                for _, animal in ipairs(cs.clustersToAdd or {}) do addRecord(records, animal, "pen-queue") end
            end
        end
    end)
    try("vehicles", function()
        for _, vehicle in pairs(mission.vehicleSystem.vehicles) do
            local spec = vehicle.spec_livestockTrailer
            if spec ~= nil and spec.clusterSystem ~= nil then
                for _, animal in ipairs(spec.clusterSystem.animals or {}) do addRecord(records, animal, "trailer") end
                for _, animal in ipairs(spec.clusterSystem.clustersToAdd or {}) do addRecord(records, animal, "trailer-queue") end
            end
        end
    end)
    try("animalSystem", function()
        for _, animals in pairs(mission.animalSystem.animals) do
            for _, animal in pairs(animals) do addRecord(records, animal, "sale") end
        end
        for _, animals in pairs(mission.animalSystem.aiAnimals) do
            for _, animal in pairs(animals) do addRecord(records, animal, "ai") end
        end
        for countryIndex, country in pairs(mission.animalSystem.countries) do
            for _, farm in pairs(country.farms) do
                for typeIndex, last in pairs(farm.ids) do
                    counters[#counters + 1] = { country = country.index or countryIndex, farmId = tostring(farm.id),
                        type = "T" .. tostring(typeIndex), nextRaw = (number(last) or 0) + 1 }
                end
            end
        end
    end)
    -- Herd-level counters of the player farms apply to every country the herd has animals in.
    try("farms", function()
        local countriesOf = {}
        for _, r in ipairs(records) do
            if r.country ~= nil then
                countriesOf[tostring(r.farmId)] = countriesOf[tostring(r.farmId)] or {}
                countriesOf[tostring(r.farmId)][r.country] = true
            end
        end
        for _, farm in pairs(g_farmManager.farmIdToFarm) do
            if farm.stats ~= nil and farm.stats.statistics ~= nil and farm.stats.statistics.farmId ~= nil then
                local herd = tostring(farm.stats.statistics.farmId)
                local s = farm.stats.statistics
                local named = {}
                for _, field in ipairs(COUNTER_FIELDS) do named[#named + 1] = { field, number(s[field]) or 0 } end
                for name, nextId in pairs(s.typeIds or {}) do named[#named + 1] = { name, number(nextId) or 0 } end
                if next(countriesOf[herd] or {}) == nil and #named > 0 then
                    local highest = 0
                    for _, entry in ipairs(named) do highest = math.max(highest, entry[2]) end
                    -- A herd that used counters but holds no animal now: its history is unknown too.
                    if highest > 0 then uncovered[#uncovered + 1] = "*/" .. herd end
                end
                for country in pairs(countriesOf[herd] or {}) do
                    for _, entry in ipairs(named) do
                        counters[#counters + 1] = { country = country, farmId = herd, type = entry[1], nextRaw = entry[2] + 1 }
                    end
                end
            end
        end
    end)
    return { records = records, counters = counters, partial = partial, uncoveredHerds = uncovered }
end
