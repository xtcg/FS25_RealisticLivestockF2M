-- Semen straws are non-store tools. Supply their icon and sire ear tag to HB's
-- backpack without creating a shop item or changing the underlying straw.
RLStrawBackpackIcon = {}
local B = RLStrawBackpackIcon
local SPEC = "spec_" .. g_currentModName .. ".aiStraw"
local iconFilename = g_currentModDirectory .. "gui/handTools/aiStraw.dds"

function B.getEarTag(handTool)
    local spec = handTool ~= nil and handTool[SPEC] or nil
    if spec == nil then return nil end
    local animal = spec.animal or {}
    local code = RLConstants.AREA_CODES[animal.country]
    return string.format("%s %s %s", code ~= nil and code.code or "?",
        tostring(animal.farmId or "?"), tostring(animal.uniqueId or "?"))
end

function B.decorateItem(item, handTool)
    local earTag = B.getEarTag(handTool)
    if item == nil or earTag == nil then return item end
    item.imageFilename = iconFilename
    item.title = earTag
    item.description = ""
    return item
end

function B.install()
    -- Map scripts can load after this mod, and live in the map's own environment.
    local env = _G.FS25_HofBergmann
    local class = env ~= nil and env.LSFMPlayerBackpackDialog or nil
    if class == nil or type(class.getHandToolItem) ~= "function"
        or type(class.updateDetails) ~= "function" then return false end
    if class.rlStrawBackpackIconInstalled then return true end

    local originalGet = class.getHandToolItem
    class.getHandToolItem = function(self, handTool, player)
        return B.decorateItem(originalGet(self, handTool, player), handTool)
    end
    local originalDetails = class.updateDetails
    class.updateDetails = function(self, ...)
        originalDetails(self, ...)
        local item = self.items ~= nil and self.items[self.selectedIndex] or nil
        if item ~= nil and item.kind == "handTool" and B.getEarTag(item.object) ~= nil
            and self.detailText ~= nil then
            -- HB appends an equipped-state sentence even to an empty description.
            -- Keep its equipment action, but show no extra text on the straw.
            self.detailText:setText("")
        end
    end
    class.rlStrawBackpackIconInstalled = true
    Log:info("Straw backpack: installed HB icon and ear-tag display")
    return true
end

function B:loadMap()
    self.retryMs = 0
    self.installed = self.install()
end

function B:update(dt)
    if self.installed then return end
    self.retryMs = (self.retryMs or 0) + dt
    if self.retryMs < 1000 then return end
    self.retryMs = 0
    self.installed = self.install()
end

function B:deleteMap()
    self.installed = false
    self.retryMs = 0
end

addModEventListener(B)
