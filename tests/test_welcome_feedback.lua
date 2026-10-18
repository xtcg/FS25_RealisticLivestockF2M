-- First-load feedback is local to the player, independent of the map or savegame.
g_currentModSettingsDirectory = "/local/modSettings/RLRM/"
FSBaseMission = {}
Utils = { prependedFunction = function(_, fn) return fn end }
local saved, pendingSave, timer, closeDialog, text
XMLFile = {
    loadIfExists = function(_, path)
        assert(path == g_currentModSettingsDirectory .. "Welcome.xml")
        if saved == nil then return nil end
        return { getBool = function() return saved end, delete = function() end }
    end,
    create = function(_, path, root)
        assert(path == g_currentModSettingsDirectory .. "Welcome.xml" and root == "Welcome")
        return {
            setBool = function(_, key, value) assert(key == "Welcome#feedbackShown"); pendingSave = value end,
            save = function() saved = pendingSave end,
            delete = function() end,
        }
    end,
}
createFolder = function() end
Timer = { createOneshot = function(_, fn) timer = fn end }
InfoDialog = { show = function(body, callback) text, closeDialog = body, callback end }
g_i18n = { getText = function(_, key) assert(key == "rl_welcome_feedback"); return "feedback invitation" end }
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
local mission = { getIsServer = function() return false end }
check("first load: invitation queued for a joining client on any map", M._needsWelcome())
showStartup(mission)
check("first load: not persisted before the dialog renders", saved == nil and timer ~= nil)
-- Backing out during startup must not consume the first-load invitation.
g_currentMission = nil
timer()
check("interrupted load: invitation remains pending", M._needsWelcome() and closeDialog == nil)
g_currentMission = {}
showStartup(mission)
timer()
check("first load: localized invitation rendered", text == "feedback invitation" and saved == nil)
closeDialog()
check("dismissed: preference persisted locally", saved == true and not M._needsWelcome())
timer = nil
showStartup(mission)
check("next map or save: no repeat dialog", timer == nil)
saved = false
g_dedicatedServer = {}
check("dedicated server: no invitation and no preference written", not M._needsWelcome() and saved == false)
g_dedicatedServer = nil
local q = M._buildStartupQueue({ hasWelcome = true, hasMigration = true, isServer = true,
    hasConfigOverrideConflict = true, configOverrideConflictText = "collision" })
check("migration and actual configuration conflicts retain their queue order",
    #q == 3 and q[1].kind == "migration" and q[2].kind == "welcome"
    and q[3].kind == "bridge-conflict" and q[3].text == "collision")
q = M._buildStartupQueue({ hasWelcome = true, hasConflict = true })
check("blocking mod conflict defers the welcome until a successful load", #q == 1 and q[1].kind == "conflict")
q = M._buildStartupQueue({ hasBridgeWarning = true, bridgeText = "old version warning" })
check("untested map version never creates a startup notice", #q == 0)
