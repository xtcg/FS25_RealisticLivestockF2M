-- Stored trough contents are restored before the save's nutrition setting is loaded.
-- Engine-shaped load/add/capacity path from FS25 PlaceableHusbandryFood: restoring existing
-- stock must not use the later runtime gate for NEW unloading. The base supported-fill and
-- capacity checks still apply, including when curves are off or an uncovered animal shares a sheep pen.
loadMod("tests/sheepsim.lua")

Utils = {
    appendedFunction = function(base, after)
        return function(self, ...)
            if base ~= nil then base(self, ...) end
            return after(self, ...)
        end
    end,
    overwrittenFunction = function(base, replacement)
        return function(self, ...) return replacement(self, base, ...) end
    end,
}
SpecializationUtil = { registerOverwrittenFunction = function() end }
PlaceableHusbandryFood = {}
function PlaceableHusbandryFood:getFreeFoodCapacity(index)
    if not self.spec_husbandryFood.supportedFillTypes[index] then return 0 end
    local total = 0
    for _, liters in pairs(self.spec_husbandryFood.fillLevels) do total = total + liters end
    return self.spec_husbandryFood.capacity - total
end
function PlaceableHusbandryFood:loadFromXMLFile(xml, key)
    xml:iterate(key .. ".fillLevel", function(_, path)
        local index = g_fillTypeManager:getFillTypeIndexByName(xml:getString(path .. "#fillType"))
        if index ~= nil and self.spec_husbandryFood.supportedFillTypes[index] ~= nil then
            self:addFood(self:getOwnerFarmId(), xml:getFloat(path .. "#fillLevel"), index)
        end
    end)
    if xml.fail then error("restore failure") end
end
-- RLFeed installs its real capacity guard when the engine class exists.
AnimalFoodSystem = { consumeFood = function() return 1 end, consumeFoodGroup = function(_, _, amount) return amount end }
loadMod("scripts/feed/RLFeed.lua")
loadMod("scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryFood.lua")

local function penFor(animals, capacity)
    local pen = SheepSim.makePen(animals or {})
    pen.spec_husbandryFood.capacity = capacity or 3000
    pen.getFreeFoodCapacity = PlaceableHusbandryFood.getFreeFoodCapacity
    pen.getOwnerFarmId = function() return 1 end
    pen.addFood = function(self, _, liters, index)
        if not self.spec_husbandryFood.supportedFillTypes[index] then return 0 end
        local added = math.min(liters, self:getFreeFoodCapacity(index))
        if added > 0 then self.spec_husbandryFood.fillLevels[index] = (self.spec_husbandryFood.fillLevels[index] or 0) + added end
        return added
    end
    return pen
end
local function stored(rows, fail)
    local values = {}
    for i, row in ipairs(rows) do
        values["food.fillLevel(" .. i .. ")#fillType"] = row[1]
        values["food.fillLevel(" .. i .. ")#fillLevel"] = row[2]
    end
    return {
        fail = fail,
        iterate = function(_, path, fn)
            if path == "food.fillLevel" then for i in ipairs(rows) do fn(i, path .. "(" .. i .. ")") end end
        end,
        getString = function(_, key) return values[key] end,
        getFloat = function(_, key, default) return values[key] or default end,
        getInt = function(_, key, default) return values[key] or default end,
        getBool = function(_, _, default) return default end,
    }
end
local function restore(pen, rows, fail)
    return PlaceableHusbandryFood.loadFromXMLFile(pen, stored(rows, fail), "food")
end
local FILL = FeedSim.FILL
SheepSim.enable(true)
local pen = penFor({ SheepSim.ewe("SHEEP_LANDRACE", "S1") })
restore(pen, { { "DRYGRASS_WINDROW", 1000 }, { "SILAGE", 400 }, { "BARLEY", 300 }, { "PEA", 100 } })
check("stock restore: startup preserves saved sheep hay/silage/barley/peas",
    pen:level("DRYGRASS_WINDROW") == 1000 and pen:level("SILAGE") == 400 and pen:level("BARLEY") == 300 and pen:level("PEA") == 100
    and pen.spec_husbandryFood.rlRestoringFood == nil)
GrowthSim.advanceHour()
check("stock restore: the sheep pen accepts new silage/grain (the unified model is the only one)",
    pen:getFreeFoodCapacity(FILL.SILAGE) > 0 and pen:getFreeFoodCapacity(FILL.BARLEY) > 0)
local feeding = penFor({ SheepSim.ewe("SHEEP_LANDRACE", "S2") })
restore(feeding, { { "SILAGE", 400 } })
FeedSim.hour(feeding)
check("stock restore: saved silage is actually available to the next model feeding", feeding:level("SILAGE") < 400
    and feeding.animals[1].rlFeedIntake.byFill.SILAGE ~= nil)

SheepSim.enable(false)
local off = penFor({ SheepSim.ewe("SHEEP_LANDRACE", "S3") })
restore(off, { { "SILAGE", 400 }, { "BARLEY", 300 } })
check("stock restore: disabled sheep curves retain existing stock without opening new unloading",
    off:level("SILAGE") == 400 and off:level("BARLEY") == 300 and off:getFreeFoodCapacity(FILL.SILAGE) == 0)
SheepSim.enable(true)
-- An uncovered animal (a vanilla cluster) in the sheep pen keeps it out of the mode. (A goat no longer does:
-- it is covered on its own GOAT section.)
local goat = GrowthSim.makeAnimal("SHEEP_LANDRACE", { age = 24 })
goat.isIndividual = false
local mixed = penFor({ SheepSim.ewe("SHEEP_LANDRACE", "S4"), goat })
restore(mixed, { { "SILAGE", 400 }, { "BARLEY", 300 } })
check("stock restore: a pen with an uncovered animal retains existing silage/grain and still rejects new unloading",
    mixed:level("SILAGE") == 400 and mixed:level("BARLEY") == 300 and mixed:getFreeFoodCapacity(FILL.BARLEY) == 0)

local small = penFor({}, 100)
restore(small, { { "SILAGE", 400 } })
check("stock restore: engine capacity still limits restored contents", small:level("SILAGE") == 100)
local unsupported = penFor({})
unsupported.spec_husbandryFood.supportedFillTypes[FILL.SILAGE] = nil
restore(unsupported, { { "SILAGE", 400 } })
check("stock restore: engine supported-fill check still refuses unsupported contents", unsupported:level("SILAGE") == 0)
local failed = penFor({})
local ok, why = pcall(restore, failed, {}, true)
check("stock restore: load errors propagate and never leave runtime admission bypassed", not ok
    and tostring(why):find("restore failure", 1, true) ~= nil and failed.spec_husbandryFood.rlRestoringFood == nil)
