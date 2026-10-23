-- UI-RATION-01: the ration dialog opens (the click reached RLMenuInfoFrame:onClickRation, but no
-- window showed). Class() lets RLFeedRationDialog fall back to MessageDialog, so a plain read of
-- RLFeedRationDialog.INSTANCE answered with the base game's MessageDialog: the dialog was never
-- loaded and showDialog("RLFeedRationDialog") found nothing. Also: Back changes nothing, a
-- client's Apply is checked on the server (mode, pen, permission, values).

loadMod("tests/feedsim.lua")
loadMod("scripts/events/RLFeedRationEvent.lua")
loadMod("scripts/gui/rlmenu/services/RLFeedRationModel.lua")

FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(7)

-- The game's MessageDialog: registered by the base game before any mod dialog, INSTANCE set.
MessageDialog = {}
local MessageDialog_mt = Class(MessageDialog, nil)
function MessageDialog.new(_target, mt) return setmetatable({}, mt or MessageDialog_mt) end
MessageDialog.INSTANCE = MessageDialog.new()

local loaded, shown = {}, {}
g_gui = { guis = {} }
function g_gui:loadGui(path, name, controller)
    loaded[#loaded + 1] = { path = path, name = name, controller = controller }
    local gui = { name = name, target = controller }
    self.guis[name] = gui
    return gui
end
function g_gui:showDialog(name) shown[#shown + 1] = name end

loadMod("scripts/gui/RLFeedRationDialog.lua")

local pen = FeedSim.makePen({ (GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })) }, { DRYGRASS_WINDROW = 10000, MAIZE = 1000 })
RLFeedRationDialog.show(pen, nil, nil)
local dialog = rawget(RLFeedRationDialog, "INSTANCE") or {}
check("UI-RATION-01: the first show loads the dialog's own XML although MessageDialog.INSTANCE is set",
    #loaded == 1 and loaded[1].name == "RLFeedRationDialog" and loaded[1].path:find("gui/RLFeedRationDialog.xml", 1, true) ~= nil)
check("UI-RATION-01: the dialog's instance is its own, not the base game's MessageDialog",
    dialog ~= MessageDialog.INSTANCE and getmetatable(dialog) ~= nil and getmetatable(dialog).__index == RLFeedRationDialog)
check("UI-RATION-01: show asks the GUI for the ration dialog with the pen set on it",
    shown[1] == "RLFeedRationDialog" and dialog.placeable == pen)
check("UI-RATION-01: the base game's MessageDialog is left alone", MessageDialog.INSTANCE.placeable == nil)
RLFeedRationDialog.show(pen, nil, nil)
check("UI-RATION-01: a second show reuses the loaded dialog", #loaded == 1 and #shown == 2)

-- Registered with the other dialogs at mission start.
local file = assert(io.open(REPO .. "scripts/core/RealisticLivestock_FSBaseMission.lua", "r"))
local mission = file:read("*a")
file:close()
check("UI-RATION-01: the ration dialog is registered at mission start", mission:find("RLFeedRationDialog.register()", 1, true) ~= nil)

-- Back: the draft is dropped, nothing is sent, the pen's ration stays as it was.
local sent = {}
local savedSend = RLFeedRationEvent.sendEvent
RLFeedRationEvent.sendEvent = function(object, ration) sent[#sent + 1] = { object = object, ration = ration } end
RLFeed.setRation(pen, { target = "AUTO", grain = "AUTO", share = nil, substitute = true })
local before = RLFeed.getRation(pen)
dialog.model = RLFeedRationModel.new(pen)
dialog.model:setTargetIndex(2)
local closed, callbackSent = 0, nil
dialog.close = function() closed = closed + 1 end
dialog.callback = function(_, value) callbackSent = value end
dialog.callbackTarget = {}
RLFeedRationDialog.onClickBack(dialog)
local after = RLFeed.getRation(pen)
check("UI-RATION-01: Back sends nothing and leaves the pen's ration as it was",
    #sent == 0 and closed == 1 and callbackSent == false and after.target == before.target and after.grain == before.grain
    and after.share == before.share and after.substitute == before.substitute)
RLFeedRationEvent.sendEvent = savedSend

-- A client's Apply: the server checks the mode and that the pen runs the mode's rations.
local broadcasts = {}
g_server = { broadcastEvent = function(_, event) broadcasts[#broadcasts + 1] = event end }
RLPermissionHelper = { authorizeConnection = function() return true, nil, "tester" end }
pen.getOwnerFarmId = function() return 1 end
local logged = #LOG
local horses = FeedSim.makePen({}, {})
horses.getOwnerFarmId = function() return 1 end
horses.getAnimalTypeIndex = function() return 99 end
RLFeedRationEvent.new(horses, { target = "MAINTAIN", grain = "AUTO", share = nil, substitute = true }):run(makeConnection(5, false))
check("UI-RATION-01: a pen without the mode's rations is not changed by a client",
    horses.spec_husbandryFood.rlFeedRation == nil and #broadcasts == 0)
RLFeedRationEvent.new(pen, { target = "MAINTAIN", grain = "AUTO", share = nil, substitute = true }):run(makeConnection(5, false))
check("UI-RATION-01: a permitted client's ration on a mode pen is applied and sent on",
    RLFeed.getRation(pen).target == "MAINTAIN" and #broadcasts == 1)
while #LOG > logged do table.remove(LOG) end
g_server = nil
