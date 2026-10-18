--[[
    RLPedigree

    The parents of every animal the game has seen, kept after the animal is sold or dead, so a
    mating can be checked against its ancestors several generations back. An animal itself only
    knows its parents (motherId / fatherId); this registry is what makes grandparents and
    great-grandparents reachable.

    Ids are the "<country> <herd> <id>" strings of Animal:getIdentifiers(). An entry is
    { father = id|nil, mother = id|nil }; animals with neither parent known are not stored.

    The inbreeding coefficient of a mating is the kinship of sire and dam, by Wright's path
    method: for every common ancestor A and every pair of paths from sire and dam up to A that
    meet only at A, (1/2)^(n1 + n2 + 1) x (1 + F_A). The paths go at most MAX_GENERATIONS above
    each parent (at most 127 ancestor positions a side), so the work per pair is bounded.

    The registry lives in rm_RlAnimalSystem.xml (pedigree.entry), is pushed to joining clients,
    and is filled as animals are loaded, added to a husbandry or streamed. Saving drops entries
    no living animal, sale animal or semen batch can reach within MAX_GENERATIONS + 1.
]]

RLPedigree = {}

-- 4th cousins share great-great-great-grandparents, 5 generations above each parent; one more
-- for the inbreeding of those common ancestors.
RLPedigree.MAX_GENERATIONS = 6

-- Bands of the offspring's inbreeding coefficient (user rule, 2026-10-18): first cousins (6.25%)
-- and anything closer is refused, second cousins (1.5625%) are advised against, anything more
-- distant is shown without advice.
RLPedigree.LEVEL = { NONE = 0, INFO = 1, ADVISE_AGAINST = 2, FORBIDDEN = 3 }
RLPedigree.FORBIDDEN_F = 0.0625
RLPedigree.ADVISE_AGAINST_F = 0.015625
local EPSILON = 1e-9

RLPedigree.entries = {}
-- Offspring inbreeding by pair and depth (and of every common ancestor on the way), dropped
-- whenever an entry changes: the straw prompt asks every frame, natural mating every day.
RLPedigree.cache = {}


local function known(id)
    return type(id) == "string" and id ~= "" and id ~= "-1" and id ~= "-2" and id ~= "?"
end

RLPedigree.isKnownId = known


function RLPedigree.reset()
    RLPedigree.entries = {}
    RLPedigree.cache = {}
end


--- Record an animal's parents. Unknown parents never overwrite known ones.
function RLPedigree.register(id, fatherId, motherId)
    if not known(id) then return end
    local father, mother = known(fatherId) and fatherId or nil, known(motherId) and motherId or nil
    if father == nil and mother == nil then return end
    if father == id or mother == id then return end

    local entry = RLPedigree.entries[id]
    if entry == nil then
        RLPedigree.entries[id] = { father = father, mother = mother }
        RLPedigree.cache = {}
    elseif (father ~= nil and father ~= entry.father) or (mother ~= nil and mother ~= entry.mother) then
        entry.father = father or entry.father
        entry.mother = mother or entry.mother
        RLPedigree.cache = {}
    end
end


--- Record a live animal (an Animal instance) by its identifiers and parents.
function RLPedigree.noteAnimal(animal)
    if type(animal) ~= "table" or animal.birthday == nil or animal.uniqueId == nil or animal.farmId == nil then return end
    if RLConstants == nil or RLConstants.AREA_CODES == nil then return end
    local area = RLConstants.AREA_CODES[animal.birthday.country]
    if area == nil then return end
    RLPedigree.register(string.format("%s %s %s", area.code, animal.farmId, animal.uniqueId), animal.fatherId, animal.motherId)
end


--- Record every animal in a list.
function RLPedigree.noteAnimals(animals)
    if type(animals) ~= "table" then return end
    for _, animal in pairs(animals) do RLPedigree.noteAnimal(animal) end
end


--- The id of a dewar / straw / insemination record ("<country> <herd> <id>"), and its parents
--- from the batch when the registry has none.
function RLPedigree.noteSire(record)
    local id = RLPedigree.getSireId(record)
    if id ~= nil then RLPedigree.register(id, record.sireFatherId, record.sireMotherId) end
    return id
end


function RLPedigree.getSireId(record)
    if type(record) ~= "table" or record.uniqueId == nil or record.farmId == nil then return nil end
    local area = RLConstants ~= nil and RLConstants.AREA_CODES ~= nil and RLConstants.AREA_CODES[record.country] or nil
    if area == nil then return nil end
    return string.format("%s %s %s", area.code, record.farmId, record.uniqueId)
end


function RLPedigree.getParents(id)
    local entry = RLPedigree.entries[id]
    if entry == nil then return nil, nil end
    return entry.father, entry.mother
end


-- Every path from an animal up its known pedigree, at most maxDepth generations: one record per
-- ancestor position (the animal itself at 0), each linked to the record below it.
local function ancestry(id, maxDepth)
    local positions = {}
    local function visit(node, depth, below)
        local position = { id = node, n = depth, below = below }
        table.insert(positions, position)
        if depth >= maxDepth then return end
        local father, mother = RLPedigree.getParents(node)
        if father ~= nil then visit(father, depth + 1, position) end
        if mother ~= nil then visit(mother, depth + 1, position) end
    end
    visit(id, 0, nil)
    return positions
end


-- Whether two paths meet only at their common top (Wright's rule for a path through A).
local function pathsDisjoint(a, b)
    local seen = {}
    local node = a.below
    while node ~= nil do seen[node.id] = true; node = node.below end
    node = b.below
    while node ~= nil do
        if seen[node.id] then return false end
        node = node.below
    end
    return true
end


-- Wright's path coefficient of the offspring of a and b: the sum over common ancestors A and
-- each pair of disjoint paths of (1/2)^(n1 + n2 + 1) x (1 + F_A), within maxDepth generations
-- of a and b. F_A uses what is left of the depth.
local function offspringInbreeding(a, b, maxDepth, memo)
    if not known(a) or not known(b) or a == b or maxDepth < 0 then return 0 end
    local key = (a < b and (a .. "|" .. b) or (b .. "|" .. a)) .. "|" .. maxDepth
    local cached = memo[key]
    if cached ~= nil then return cached end
    memo[key] = 0

    local fromB = {}
    for _, position in ipairs(ancestry(b, maxDepth)) do
        local list = fromB[position.id]
        if list == nil then list = {}; fromB[position.id] = list end
        table.insert(list, position)
    end

    local f = 0
    for _, pa in ipairs(ancestry(a, maxDepth)) do
        local matches = fromB[pa.id]
        if matches ~= nil then
            for _, pb in ipairs(matches) do
                if pathsDisjoint(pa, pb) then
                    local father, mother = RLPedigree.getParents(pa.id)
                    local fA = offspringInbreeding(father, mother, maxDepth - math.max(pa.n, pb.n) - 1, memo)
                    f = f + 0.5 ^ (pa.n + pb.n + 1) * (1 + fA)
                end
            end
        end
    end

    memo[key] = f
    return f
end


--- Kinship coefficient of two animals by id (0 when unrelated or unknown), which is the
--- inbreeding coefficient of their offspring.
function RLPedigree.getKinship(a, b)
    return offspringInbreeding(a, b, RLPedigree.MAX_GENERATIONS, RLPedigree.cache)
end


--- Inbreeding coefficient of the offspring of a sire and a dam (ids).
function RLPedigree.getOffspringInbreeding(sireId, damId)
    if not known(sireId) or not known(damId) or sireId == damId then return 0 end
    return RLPedigree.getKinship(sireId, damId)
end


function RLPedigree.getLevel(f)
    if f == nil or f <= EPSILON then return RLPedigree.LEVEL.NONE end
    if f >= RLPedigree.FORBIDDEN_F - EPSILON then return RLPedigree.LEVEL.FORBIDDEN end
    if f >= RLPedigree.ADVISE_AGAINST_F - EPSILON then return RLPedigree.LEVEL.ADVISE_AGAINST end
    return RLPedigree.LEVEL.INFO
end


--- The offspring's inbreeding coefficient and its band for a dam (Animal) and a sire, the sire
--- either an Animal or a semen record (dewar / straw / insemination).
function RLPedigree.checkMating(dam, sire)
    if type(dam) ~= "table" or type(sire) ~= "table" then return 0, RLPedigree.LEVEL.NONE end
    RLPedigree.noteAnimal(dam)
    local damId = dam.getIdentifiers ~= nil and dam:getIdentifiers() or nil
    local sireId
    if sire.getIdentifiers ~= nil and sire.birthday ~= nil then
        RLPedigree.noteAnimal(sire)
        sireId = sire:getIdentifiers()
    else
        sireId = RLPedigree.noteSire(sire)
    end
    local f = RLPedigree.getOffspringInbreeding(sireId, damId)
    return f, RLPedigree.getLevel(f)
end


--- "1.56%" style text of an inbreeding coefficient.
function RLPedigree.formatPercent(f)
    local percent = (f or 0) * 100
    if percent >= 10 then return string.format("%.1f%%", percent) end
    if percent >= 1 then return string.format("%.2f%%", percent) end
    return string.format("%.3f%%", percent)
end


--- The player-facing line for a mating's inbreeding, nil when unrelated.
function RLPedigree.getText(f, level)
    if level == nil or level == RLPedigree.LEVEL.NONE then return nil end
    local key = (level == RLPedigree.LEVEL.FORBIDDEN and "rl_pedigree_forbidden")
        or (level == RLPedigree.LEVEL.ADVISE_AGAINST and "rl_pedigree_adviseAgainst")
        or "rl_pedigree_info"
    return string.format(g_i18n:getText(key), RLPedigree.formatPercent(f))
end


-- =============================================================================
-- PERSISTENCE, PRUNING AND SYNC
-- =============================================================================

--- Keep only entries reachable from the anchor ids within MAX_GENERATIONS + 1 generations.
--- @param anchors table list of ids
--- @return number removed
function RLPedigree.prune(anchors)
    local keep, frontier = {}, {}
    for _, id in pairs(anchors or {}) do
        if known(id) and not keep[id] then keep[id] = true; table.insert(frontier, id) end
    end

    for _ = 1, RLPedigree.MAX_GENERATIONS + 1 do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local father, mother = RLPedigree.getParents(id)
            for _, parent in ipairs({ father or false, mother or false }) do
                if parent and not keep[parent] then keep[parent] = true; table.insert(nextFrontier, parent) end
            end
        end
        frontier = nextFrontier
        if #frontier == 0 then break end
    end

    local removed = 0
    for id in pairs(RLPedigree.entries) do
        if not keep[id] then RLPedigree.entries[id] = nil; removed = removed + 1 end
    end
    if removed > 0 then RLPedigree.cache = {} end
    return removed
end


--- Ids the pruning keeps: every husbandry animal, every sale and AI-dealer animal, every dewar
--- sire. Also records them, so a save always holds the current parents.
function RLPedigree.collectAnchors()
    local anchors = {}
    local function addAnimal(animal)
        RLPedigree.noteAnimal(animal)
        if type(animal) == "table" and animal.getIdentifiers ~= nil and animal.birthday ~= nil
            and RLConstants.AREA_CODES[animal.birthday.country] ~= nil then
            table.insert(anchors, animal:getIdentifiers())
        end
    end

    local mission = g_currentMission
    local husbandrySystem = mission ~= nil and mission.husbandrySystem or nil
    if husbandrySystem ~= nil and husbandrySystem.placeables ~= nil then
        for _, placeable in pairs(husbandrySystem.placeables) do
            local animals = placeable.getClusters ~= nil and placeable:getClusters() or nil
            for _, animal in pairs(animals or {}) do addAnimal(animal) end
        end
    end

    local animalSystem = mission ~= nil and mission.animalSystem or nil
    if animalSystem ~= nil then
        for _, list in pairs(animalSystem.animals or {}) do for _, animal in pairs(list) do addAnimal(animal) end end
        for _, list in pairs(animalSystem.aiAnimals or {}) do for _, animal in pairs(list) do addAnimal(animal) end end
    end

    for _, farm in pairs(g_dewarManager ~= nil and g_dewarManager.farms or {}) do
        for _, dewars in pairs(farm) do
            for _, dewar in pairs(dewars) do
                local id = RLPedigree.noteSire(dewar.animal)
                if id ~= nil then table.insert(anchors, id) end
            end
        end
    end

    return anchors
end


function RLPedigree.saveToXMLFile(xmlFile, key)
    local removed = RLPedigree.prune(RLPedigree.collectAnchors())
    local ids = {}
    for id in pairs(RLPedigree.entries) do table.insert(ids, id) end
    table.sort(ids)

    for i, id in ipairs(ids) do
        local entryKey = string.format("%s.entry(%d)", key, i - 1)
        local entry = RLPedigree.entries[id]
        xmlFile:setString(entryKey .. "#id", id)
        if entry.father ~= nil then xmlFile:setString(entryKey .. "#father", entry.father) end
        if entry.mother ~= nil then xmlFile:setString(entryKey .. "#mother", entry.mother) end
    end

    if Log ~= nil then Log:debug("RLPedigree: saved %d entries (%d pruned)", #ids, removed) end
end


function RLPedigree.loadFromXMLFile(xmlFile, key)
    local count = 0
    xmlFile:iterate(key .. ".entry", function(_, entryKey)
        RLPedigree.register(xmlFile:getString(entryKey .. "#id"), xmlFile:getString(entryKey .. "#father"),
            xmlFile:getString(entryKey .. "#mother"))
        count = count + 1
    end)
    if Log ~= nil then Log:debug("RLPedigree: loaded %d entries", count) end
end


function RLPedigree.writeStream(streamId)
    local ids = {}
    for id in pairs(RLPedigree.entries) do table.insert(ids, id) end
    streamWriteInt32(streamId, #ids)
    for _, id in ipairs(ids) do
        local entry = RLPedigree.entries[id]
        streamWriteString(streamId, id)
        streamWriteString(streamId, entry.father or "")
        streamWriteString(streamId, entry.mother or "")
    end
end


function RLPedigree.readStream(streamId)
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local id = streamReadString(streamId)
        local father = streamReadString(streamId)
        local mother = streamReadString(streamId)
        RLPedigree.register(id, father, mother)
    end
end
