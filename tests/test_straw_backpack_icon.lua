g_currentModName = "FS25_RealisticLivestockF2M"
local SPEC = "spec_" .. g_currentModName .. ".aiStraw"
RLConstants = { AREA_CODES = { [6] = { code = "CN" } } }
local listener
addModEventListener = function(value) listener = value end
loadMod("scripts/gui/RLStrawBackpackIcon.lua")
local B = RLStrawBackpackIcon
check("straw backpack: no HB is a safe no-op", listener == B and not B.install())
B:loadMap()
local calls = 0
local class = { getHandToolItem = function(_, tool, player)
    calls = calls + 1
    if tool == player.hands then return nil end
    return { kind = "handTool", object = tool, title = tool:getName(),
        imageFilename = "original.dds", description = "original", isEquipped = player.currentHandTool == tool }
end, updateDetails = function(self)
    local item = self.items[self.selectedIndex]
    self.detailText:setText(item.description .. (item.isEquipped and " equipped" or ""))
    self.action = item.isEquipped and "holster" or "equip"
end }
FS25_HofBergmann = { LSFMPlayerBackpackDialog = class }
B:update(1000)
local wrapped, wrappedDetails = class.getHandToolItem, class.updateDetails
B.install()
check("straw backpack: late map namespace is hooked once", B.installed
    and wrapped == class.getHandToolItem and wrappedDetails == class.updateDetails)
local animal = { country = 6, farmId = 91, uniqueId = 310004, name = "Sire A", batchId = "B-1", success = 0.57 }
local straw = { [SPEC] = { animal = animal }, getName = function() return "Semen straw" end }
local player = { currentHandTool = straw, hands = {} }
local item = class:getHandToolItem(straw, player)
check("straw backpack: real equipped object uses DDS and only the full ear tag",
    item.object == straw and item.kind == "handTool" and item.isEquipped
    and item.imageFilename == "/mod/gui/handTools/aiStraw.dds"
    and item.title == "CN 91 310004" and item.description == "")
local detailText = { setText = function(self, text) self.text = text end }
local dialog = { items = { item }, selectedIndex = 1, detailText = detailText }
class.updateDetails(dialog)
check("straw backpack: equipped sentence is removed but holster action remains",
    detailText.text == "" and dialog.action == "holster")
straw[SPEC].isEmpty = true
player.currentHandTool = nil
item = class:getHandToolItem(straw, player)
dialog.items[1] = item
class.updateDetails(dialog)
check("straw backpack: used/unequipped state adds no prose and keeps equip action",
    item.title == "CN 91 310004" and item.description == "" and detailText.text == ""
    and not item.isEquipped and dialog.action == "equip")
check("straw backpack: presentation does not change sire, batch or consumed state",
    straw[SPEC].animal == animal and animal.name == "Sire A" and animal.batchId == "B-1"
    and animal.success == 0.57 and straw[SPEC].isEmpty)
straw[SPEC].animal = { farmId = "00091", uniqueId = "00310004" }
check("straw backpack: incomplete legacy ID is safe and preserves leading zeros",
    B.getEarTag(straw) == "? 00091 00310004")
straw[SPEC].animal = nil
check("straw backpack: missing snapshot never invents a sire ID", B.getEarTag(straw) == "? ? ?")
local fork = { getName = function() return "Fork" end }
item = class:getHandToolItem(fork, player)
dialog.items[1] = item
class.updateDetails(dialog)
check("straw backpack: other tools keep their original image and text",
    item.title == "Fork" and item.imageFilename == "original.dds" and item.description == "original"
    and detailText.text == "original")
check("straw backpack: hands stay excluded", class:getHandToolItem(player.hands, player) == nil)
check("straw backpack: repeated installation does not add original calls", calls == 4)
B:deleteMap()
FS25_HofBergmann = { LSFMPlayerBackpackDialog = { getHandToolItem = function() return nil end,
    updateDetails = function() end } }
B:loadMap()
check("straw backpack: a new map class is hooked after changing maps", B.installed
    and FS25_HofBergmann.LSFMPlayerBackpackDialog.rlStrawBackpackIconInstalled)
