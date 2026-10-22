-- Exercise the renamed environment rather than relying on RM-only engine stubs.
g_currentModName = "FS25_RealisticLivestockF2M"
loadMod("scripts/insemination/DewarData.lua")
loadMod("scripts/animal/RLPedigree.lua")
loadMod("scripts/handTools/specializations/HandToolAIStraw.lua")
check("F2M dewar specialization matches engine namespace", DewarData.SPEC_TABLE_NAME == "spec_FS25_RealisticLivestockF2M.dewarData")
check("F2M pedigree finds the active straw specialization", RLPedigree.STRAW_SPEC == "spec_FS25_RealisticLivestockF2M.aiStraw")
local function xml(values)
    return {
        getString = function(_, k) return values[k] end,
        setString = function(_, k, v) values[k] = v end,
        hasProperty = function(_, k) return values[k] ~= nil end,
        iterate = function(_, _, fn) fn(0, "handTools.handTool(0)") end,
        getBool = function(_, k, default) local v = values[k]; if v == nil then return default end; return v end,
    }
end
-- Drive the real onLoad through both saved namespaces; intercept only rendering and payload decoding.
getChildAt = function() return nil end
DewarData.loadDewarFromSavegame = function(self, _, key) self.loadedKey = key end
for _, namespace in ipairs({ "FS25_RealisticLivestockRM", g_currentModName }) do
    local k = "v." .. namespace .. ".dewarData"
    local vehicle = { [DewarData.SPEC_TABLE_NAME] = {}, components = {{ node = 0 }}, getNextDirtyFlag = function() return 1 end, getUniqueId = function() return "D1" end }
    DewarData.onLoad(vehicle, { key = "v", xmlFile = xml({[k] = true}) })
    check(namespace .. " dewar payload survives rename", vehicle.loadedKey == k)
end
g_i18n = { getText = function(_, key) return key end }
for _, namespace in ipairs({ "FS25_RealisticLivestock", "FS25_RealisticLivestockRM", g_currentModName }) do
    local spec = {}
    local tool = { [RLPedigree.STRAW_SPEC] = spec, isClient = false }
    local k = "h." .. namespace .. ".aiStraw"
    HandToolAIStraw.onPostLoad(tool, { key = "h", xmlFile = xml({[k] = true, [k .. "#isEmpty"] = true, [k .. "#dewarUniqueId"] = "D1"}) })
    check(namespace .. " straw retains empty state and source dewar", spec.isEmpty and spec.dewarUniqueId == "D1")
end
