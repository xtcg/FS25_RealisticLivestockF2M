-- No informational notice at startup: neither an untested map version nor a first load
-- opens a dialog. Only migration and actual conflicts do.
g_currentModSettingsDirectory = "/local/modSettings/RLRM/"
FSBaseMission = {}
Utils = { prependedFunction = function(_, fn) return fn end }
local timer, shown
Timer = { createOneshot = function(_, fn) timer = fn end }
InfoDialog = { show = function(body) shown = body end }
RLMapBridge = {}
g_currentMission, g_gui = {}, {}
loadMod("scripts/core/RealisticLivestock_FSBaseMission.lua")
local M = RealisticLivestock_FSBaseMission
local showStartup
for i = 1, 30 do
    local name, value = debug.getupvalue(M.onStartMission, i)
    if name == nil then break end
    if name == "_showStartupDialogs" then showStartup = value end
end
assert(showStartup ~= nil)
showStartup({ getIsServer = function() return true end })
check("first load on any map: no dialog", timer == nil and shown == nil)
check("no welcome helpers left", M._needsWelcome == nil and M._markWelcomeShown == nil)
local q = M._buildStartupQueue({ hasWelcome = true, hasBridgeWarning = true, bridgeText = "old version warning" })
check("untested map version or first load never creates a startup notice", #q == 0)
q = M._buildStartupQueue({ hasMigration = true, isServer = true,
    hasConfigOverrideConflict = true, configOverrideConflictText = "collision" })
check("migration and actual configuration conflicts keep their queue order",
    #q == 2 and q[1].kind == "migration" and q[2].kind == "bridge-conflict" and q[2].text == "collision")
check("blocking mod conflict still shows", M._buildStartupQueue({ hasConflict = true })[1].kind == "conflict")
