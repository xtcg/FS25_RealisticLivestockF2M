--[[
    RLPenConsole.lua
    rlPenReport: one RLPEN PEN_REPORT record per profiled pen - its rule, the map filter fields,
    what its trough and water take, its construction state - and one PEN_REPORT_ANIMAL per animal in it: age, feeding
    stage, whether it has outgrown the pen and its last hour's calf feeding. Read-only: it changes
    no rule, animal or pen.
]]

RLPenConsole = {}


--- @param filter string|nil Part of a pen name; empty for every profiled pen
--- @return string
function RLPenConsole.report(_, filter)
    filter = filter ~= nil and filter:lower() or nil
    local count = 0
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables or {}) do
        local rule = RLHusbandryProfiles.getRule(placeable)
        local spec = placeable.spec_husbandryAnimals
        local name = placeable.getName ~= nil and placeable:getName() or ""
        if rule ~= nil and spec ~= nil and (filter == nil or filter == "" or name:lower():find(filter, 1, true)) then
            count = count + 1
            local animals = {}
            for _, animal in pairs(spec.clusterSystem ~= nil and spec.clusterSystem:getClusters() or {}) do
                local entry = RLPenLog.animal(animal)
                entry.health = animal.health
                entry.overage = RLHusbandryProfiles.isOutgrown(placeable, animal)
                if animal.animalTypeIndex == AnimalType.COW and (animal.age or 0) < 12 then
                    entry.stage = RLCalfRearing.getStage(animal)
                end
                local feed = animal.rlCalfFeed
                if feed ~= nil then
                    entry.lastFeed = { tick = feed.tick, factor = feed.factor, milk = feed.milk, solid = feed.solid, request = feed.request }
                end
                animals[#animals + 1] = entry
            end
            table.sort(animals, function(a, b) return tostring(a.key) < tostring(b.key) end)
            local pen = RLPenLog.pen(placeable)
            RLPenLog.emit("PEN_REPORT", {
                pen = pen,
                profile = rule.name,
                rearing = rule.rearing == true and RLCalfRearing.appliesToPen(placeable),
                map = RLHusbandryProfiles.getMapFilterState(placeable),
                feed = RLHusbandryProfiles.getFeedAcceptance(placeable),
                capacity = placeable.getMaxNumOfAnimals ~= nil and placeable:getMaxNumOfAnimals() or nil,
                numAnimals = #animals,
                construction = RLPenConstruction.describe(placeable),
            })
            -- One line per animal, so a full pen stays under the log's line length.
            for _, entry in ipairs(animals) do
                RLPenLog.emit("PEN_REPORT_ANIMAL", { pen = pen, animal = entry })
            end
        end
    end
    return string.format("rlPenReport: %d pen(s), see log.txt (RLPEN PEN_REPORT)", count)
end
