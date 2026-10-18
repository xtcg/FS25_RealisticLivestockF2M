--[[
    ID-COLLISION-01: the load repair of duplicate full keys. A full key (farmId, uniqueId, country)
    has no species and the old counters were per species, so a save can hold a newborn lamb with the
    exact key of a pig of its herd (joint test batch E: three such pairs). At the end of the load
    (onStartMission, server, before the T02 / dealer checks, which are told how many changed) every
    group of live animals sharing one key keeps it for one animal and gives each other one a new key
    from its own domain (the herd's counter past every taken key: RLAnimalIdentityRuntime.freeRaw).

    Who keeps the key: an owned animal (pen, trailer) before a sale or AI pool listing, then the
    older one (whole months, then the earlier birthday), then the first in the world's order. The
    renumbered one keeps everything else - species, subtype, weight, genes, state, money - only its
    uniqueId changes.

    References are followed only when they resolve to one animal. A parent named by the old key
    (motherId, fatherId, a pregnancy's sire, an unborn's parents) is the renumbered one only when it
    is the only animal of the group of the naming animal's species (and the right sex); a parent's
    children list entry for the old key is the renumbered one only when no other member of the group
    is a child of that parent. Anything else is left as it was and reported (IDENTITY_REPAIR_CONFLICT):
    no parent is guessed, no animal removed or added. Semen straws keep the sire they were taken
    from as written.
]]

RLAnimalIdentityRepair = {}
local Repair = RLAnimalIdentityRepair

Repair.MAX_LINES = 60


local function log(level, fmt, ...)
    if Log ~= nil and Log[level] ~= nil then Log[level](Log, fmt, ...) end
end


local function areaCode(country)
    local entry = RLConstants ~= nil and RLConstants.AREA_CODES ~= nil and RLConstants.AREA_CODES[country] or nil
    return entry ~= nil and entry.code or nil
end


--- The identifiers text Animal:getIdentifiers writes for (country, farmId, uniqueId), or nil.
function Repair.identifiers(country, farmId, uniqueId)
    local code = areaCode(country)
    if code == nil then return nil end
    return string.format("%s %s %s", code, tostring(farmId), tostring(uniqueId))
end


local function typeOf(animal)
    if animal.animalTypeIndex ~= nil then return animal.animalTypeIndex end
    local mission = g_currentMission
    if mission ~= nil and mission.animalSystem ~= nil and animal.subTypeIndex ~= nil then
        local subType = mission.animalSystem:getSubTypeByIndex(animal.subTypeIndex)
        if subType ~= nil then return subType.typeIndex end
    end
    return nil
end


--- Every animal of the world with where it is: { animal, where, owned }, the unborn of each pregnancy
--- listed apart (they hold parent references, no key of their own yet).
function Repair.collect(mission)
    local entries, unborn = {}, {}
    local function add(animal, where, owned)
        if type(animal) ~= "table" then return end
        entries[#entries + 1] = { animal = animal, where = where, owned = owned, order = #entries + 1 }
        local pregnancy = animal.pregnancy
        if type(pregnancy) == "table" and type(pregnancy.pregnancies) == "table" then
            for _, child in ipairs(pregnancy.pregnancies) do
                if type(child) == "table" then unborn[#unborn + 1] = { animal = child, dam = animal } end
            end
        end
    end
    for _, placeable in pairs(mission.placeableSystem.placeables) do
        local spec = placeable.spec_husbandryAnimals
        local cs = spec ~= nil and spec.clusterSystem or (placeable.spec_livestockTrailer ~= nil and placeable.spec_livestockTrailer.clusterSystem) or nil
        if cs ~= nil then
            for _, animal in ipairs(cs.animals or {}) do add(animal, "pen", true) end
            for _, animal in ipairs(cs.clustersToAdd or {}) do add(animal, "pen-queue", true) end
        end
    end
    for _, vehicle in pairs(mission.vehicleSystem.vehicles) do
        local spec = vehicle.spec_livestockTrailer
        if spec ~= nil and spec.clusterSystem ~= nil then
            for _, animal in ipairs(spec.clusterSystem.animals or {}) do add(animal, "trailer", true) end
            for _, animal in ipairs(spec.clusterSystem.clustersToAdd or {}) do add(animal, "trailer-queue", true) end
        end
    end
    for _, animals in pairs(mission.animalSystem.animals or {}) do
        for _, animal in pairs(animals) do add(animal, "sale", false) end
    end
    for _, animals in pairs(mission.animalSystem.aiAnimals or {}) do
        for _, animal in pairs(animals) do add(animal, "ai", false) end
    end
    return entries, unborn
end


local function keyOf(animal)
    if animal.isIndividual == false or animal.uniqueId == nil or animal.farmId == nil or type(animal.birthday) ~= "table"
        or animal.birthday.country == nil then return nil end
    if tostring(animal.uniqueId) == "1" and tostring(animal.farmId) == "1" then return nil end   -- the placeholder (repaired apart)
    return RLAnimalIdentity.keyString(animal.farmId, animal.uniqueId, animal.birthday.country)
end


-- Keeper first: owned, older, earlier born, earlier in the world.
local function keeperOrder(a, b)
    if a.owned ~= b.owned then return a.owned end
    local x, y = a.animal, b.animal
    if (x.age or 0) ~= (y.age or 0) then return (x.age or 0) > (y.age or 0) end
    local bx, by = x.birthday, y.birthday
    local dx = (bx.year or 0) * 400 + (bx.month or 0) * 32 + (bx.day or 0)
    local dy = (by.year or 0) * 400 + (by.month or 0) * 32 + (by.day or 0)
    if dx ~= dy then return dx < dy end
    return a.order < b.order
end


--- The numbering context of an animal's own domain (country, herd): its owner farm's counter when the
--- herd is a player farm's, a country farm's counter when it is a sale / AI farm's, else a cursor above
--- the domain's highest live raw.
local function domainContext(mission, animal, typeIndex, scan)
    local country, herd = animal.birthday.country, tostring(animal.farmId)
    for _, farm in pairs(g_farmManager.farmIdToFarm) do
        local stats = farm.stats
        if stats ~= nil and stats.statistics ~= nil and stats.statistics.farmId ~= nil and tostring(stats.statistics.farmId) == herd
            and stats.getNextAnimalId ~= nil then
            local ctx = RLAnimalIdentityWorld.statsContext("repair", farm, typeIndex, country, "auto")
            if ctx ~= nil then return ctx, function() return stats:getNextAnimalId(typeIndex) end end
        end
    end
    local c = mission.animalSystem.countries ~= nil and mission.animalSystem.countries[country] or nil
    for _, farm in pairs(c ~= nil and c.farms or {}) do
        if tostring(farm.id) == herd and farm.ids ~= nil and farm.ids[typeIndex] ~= nil then
            return RLAnimalIdentityWorld.systemContextForFarm("repair", country, farm, typeIndex, "auto"), function()
                farm.ids[typeIndex] = farm.ids[typeIndex] + 1
                return farm.ids[typeIndex]
            end
        end
    end
    local cursor = 0
    for _, r in ipairs(scan.records) do
        if tostring(r.farmId) == herd and r.country == country then
            local raws = RLAnimalIdentity.rawsOf(r.farmId, r.uniqueId)
            for _, raw in ipairs(raws or {}) do cursor = math.max(cursor, raw) end
        end
    end
    return { entry = "repair", country = country, herd = herd, typeKey = typeIndex, role = "auto" }, function()
        cursor = cursor + 1
        return cursor
    end
end


--- Repair the world's duplicate keys. Returns a summary { groups, renumbered, references, conflicts,
--- changes = { { where, type, old, new, keeper } }, conflictList = { text } }.
function Repair.run(mission)
    mission = mission or g_currentMission
    local R, I = RLAnimalIdentityRuntime, RLAnimalIdentity
    local summary = { groups = 0, renumbered = 0, references = 0, conflicts = 0, changes = {}, conflictList = {} }
    local entries, unborn = Repair.collect(mission)

    local groups, order = {}, {}
    for _, e in ipairs(entries) do
        local key = keyOf(e.animal)
        if key ~= nil then
            if groups[key] == nil then groups[key] = {}; order[#order + 1] = key end
            table.insert(groups[key], e)
        end
    end
    local duplicates = {}
    for _, key in ipairs(order) do if #groups[key] > 1 then duplicates[#duplicates + 1] = key end end
    if #duplicates == 0 then return summary end

    -- The taken keys before anything is renumbered: every live key and every parent named.
    local scan = RLAnimalIdentityWorld.scan(mission)
    R.setLive(scan.records, scan.refs)

    local lines = 0
    local function conflict(fmt, ...)
        local text = string.format(fmt, ...)
        summary.conflicts = summary.conflicts + 1
        summary.conflictList[#summary.conflictList + 1] = text
        if lines < Repair.MAX_LINES then
            lines = lines + 1
            log("warning", "IDENTITY_REPAIR_CONFLICT: %s - left as it was", text)
        end
    end

    -- Animals by their identifiers text, to find a renumbered animal's parents.
    local byIdentifiers = {}
    for _, e in ipairs(entries) do
        local a = e.animal
        if keyOf(a) ~= nil then
            local text = Repair.identifiers(a.birthday.country, a.farmId, a.uniqueId)
            if text ~= nil then
                byIdentifiers[text] = byIdentifiers[text] or {}
                table.insert(byIdentifiers[text], a)
            end
        end
    end

    -- Every animal (live and unborn) holding a parent reference, with its species.
    local holders = {}
    for _, e in ipairs(entries) do holders[#holders + 1] = { animal = e.animal, typeIndex = typeOf(e.animal) } end
    for _, u in ipairs(unborn) do holders[#holders + 1] = { animal = u.animal, typeIndex = typeOf(u.animal) or typeOf(u.dam) } end

    for _, key in ipairs(duplicates) do
        local group = groups[key]
        summary.groups = summary.groups + 1
        table.sort(group, keeperOrder)
        local keeper = group[1].animal
        local oldText = Repair.identifiers(keeper.birthday.country, keeper.farmId, keeper.uniqueId)

        -- Members that could be a given holder's mother / father: its species and sex.
        local function candidates(typeIndex, gender)
            local out = {}
            for _, e in ipairs(group) do
                if typeOf(e.animal) == typeIndex and (gender == nil or e.animal.gender == gender) then out[#out + 1] = e.animal end
            end
            return out
        end

        for i = 2, #group do
            local e = group[i]
            local animal = e.animal
            local typeIndex = typeOf(animal)
            local oldUniqueId = animal.uniqueId
            local ctx, legacy = domainContext(mission, animal, typeIndex, scan)
            local raw = R.freeRaw(ctx, legacy)
            local newUniqueId = raw ~= nil and I.format(animal.farmId, raw) or nil
            if newUniqueId == nil then
                conflict("%s has no free key in %s (%s)", key, I.domainKey(animal.birthday.country, animal.farmId), e.where)
            else
                animal.uniqueId = newUniqueId
                if animal.setDirty ~= nil then pcall(animal.setDirty, animal) end
                local newText = Repair.identifiers(animal.birthday.country, animal.farmId, newUniqueId)
                -- A child repaired later may already name this parent's new key. Keep the
                -- original group too: unresolved old references must retain their ambiguity.
                if newText ~= nil then byIdentifiers[newText] = { animal } end
                summary.renumbered = summary.renumbered + 1
                summary.changes[#summary.changes + 1] = { where = e.where, type = typeIndex, old = key,
                    new = I.keyString(animal.farmId, newUniqueId, animal.birthday.country), keeperType = typeOf(keeper) }
                log("info", "IDENTITY_REPAIR: %s %s (type %s, %s) renumbered %s -> %s; kept by type %s (%s)", e.where,
                    tostring(animal.subType), tostring(typeIndex), tostring(animal.gender), key,
                    summary.changes[#summary.changes].new, tostring(typeOf(keeper)), group[1].where)

                -- Parent references naming the old key: this animal's only when it alone fits.
                if oldText ~= nil and newText ~= nil then
                    for _, h in ipairs(holders) do
                        local a = h.animal
                        local function follow(field, get, set, gender)
                            local value = get(a)
                            if value ~= oldText then return end
                            local fits = candidates(h.typeIndex, gender)
                            if #fits == 1 and fits[1] == animal then
                                set(a, newText)
                                summary.references = summary.references + 1
                            elseif #fits > 1 then
                                local mine = false
                                for _, f in ipairs(fits) do if f == animal then mine = true end end
                                if mine then
                                    conflict("%s of %s/%s (type %s) names %s, which %d animals of its species share", field,
                                        tostring(a.farmId), tostring(a.uniqueId), tostring(h.typeIndex), key, #fits)
                                end
                            end
                        end
                        follow("motherId", function(x) return x.motherId end, function(x, v) x.motherId = v end, "female")
                        follow("fatherId", function(x) return x.fatherId end, function(x, v) x.fatherId = v end, "male")
                        if type(a.impregnatedBy) == "table" then
                            follow("impregnatedBy", function(x) return x.impregnatedBy.uniqueId end,
                                function(x, v) x.impregnatedBy.uniqueId = v end, "male")
                        end
                    end

                    -- The parents' children lists: the entry for the old key is this animal's only when no
                    -- other member of the group is that parent's child.
                    for _, field in ipairs({ "motherId", "fatherId" }) do
                        local parents = byIdentifiers[animal[field]] or {}
                        local ofKind = {}
                        for _, p in ipairs(parents) do if typeOf(p) == typeIndex then ofKind[#ofKind + 1] = p end end
                        if #ofKind == 1 and type(ofKind[1].children) == "table" then
                            local parent = ofKind[1]
                            local siblings = 0
                            for _, m in ipairs(group) do
                                if m.animal ~= animal and typeOf(m.animal) == typeIndex and m.animal[field] == animal[field] then siblings = siblings + 1 end
                            end
                            local matches = {}
                            for _, child in ipairs(parent.children) do
                                if type(child) == "table" and tostring(child.farmId) == tostring(animal.farmId) and tostring(child.uniqueId) == tostring(oldUniqueId) then
                                    matches[#matches + 1] = child
                                end
                            end
                            if #matches == 1 and siblings == 0 then
                                matches[1].uniqueId = newUniqueId
                                summary.references = summary.references + 1
                            elseif #matches > 0 then
                                conflict("children of %s list %s %d time(s) with %d other member(s) of its kind", tostring(animal[field]),
                                    key, #matches, siblings)
                            end
                        elseif #ofKind > 1 then
                            conflict("%s of %s names %s, which %d animals of its species share", field, newText, tostring(animal[field]), #ofKind)
                        end
                    end
                end
            end
        end
    end
    log("info", "IDENTITY_REPAIR: %d duplicate key group(s), %d animal(s) renumbered, %d reference(s) followed, %d conflict(s)",
        summary.groups, summary.renumbered, summary.references, summary.conflicts)
    Repair.last = summary
    return summary
end
