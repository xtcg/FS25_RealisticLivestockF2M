-- Game 1.25 Animals page: list items answer getVisual, and a failing pen reload neither leaves
-- the list stubbed nor keeps the pen selector stepping on every frame.
Utils = {
    overwrittenFunction = function(old, new) return function(self, ...) return new(self, old, ...) end end,
    appendedFunction = function(old, new) return function(...) old(...); new(...) end end
}
Gui = { NAV_ACTIONS = {} }
InputAction = { RL_OPEN_ANIMAL_SCREEN = "RL_OPEN_ANIMAL_SCREEN" }
MessageType = { HUSBANDRY_ANIMALS_CHANGED = 1 }
g_messageCenter = { subscribers = {} }
getTimeSec = function() return 0 end
RLAnimalUtil = { compare = function(a, b) return a == b end }

local baseFails
InGameMenuAnimalsFrame = {
    reloadList = function(frame)
        frame.list:reloadData()
        if baseFails then error("InGameMenuAnimalsFrame.lua:567: attempt to call missing method 'getVisual'", 0) end
        frame.husbandrySubTypes = {}
    end,
    displayCluster = function() end,
    populateCellForItemInSection = function() end,
    onFrameOpen = function() end,
    onFrameClose = function() end,
    updateMenuButtons = function() end
}
loadMod("scripts/gui/RealisticLivestock_InGameMenuAnimalsFrame.lua")

-- getVisual: the same lookup the 1.24 page did by sub type and age.
loadAnimalSection("function Animal:getSubTypeIndex()", "function Animal:getName()")
local looked
g_currentMission = { animalSystem = { getVisualByAge = function(_, subTypeIndex, age)
    looked = { subTypeIndex, age }
    return { store = { imageFilename = "cow.dds" } }
end } }
local visual = Animal.getVisual({ subTypeIndex = 3, age = 14, getSubTypeIndex = Animal.getSubTypeIndex, getAge = Animal.getAge })
check("1.25 getVisual: an RL animal answers with its sub type and age visual",
    visual.store.imageFilename == "cow.dds" and looked[1] == 3 and looked[2] == 14)

check("1.25 getMaxNumAnimals: an RL animal holds exactly one animal", Animal.getMaxNumAnimals({}) == 1)

local function makeFrame()
    local listClass = {}
    local reloads = 0
    listClass.reloadData = function(list) reloads = reloads + 1 end
    local frame = {
        list = setmetatable({ selectedSectionIndex = 1, selectedIndex = 4 }, { __index = listClass }),
        subCategorySelector = { getState = function() return 30 end,
            isLeftButtonPressed = true, isRightButtonPressed = false, delayTime = 0 },
        husbandrySubTypes = {}, subTypeIndexToClusters = {}
    }
    g_gui = { currentGuiName = "InGameMenu" }
    g_inGameMenu = { currentPage = frame }
    return frame, function() return reloads end
end

-- A base reload that throws: the list's own reloadData comes back, the arrow is released,
-- and the original error still reaches the engine.
baseFails = true
local frame, reloads = makeFrame()
LOG = {}
local ok, err = pcall(InGameMenuAnimalsFrame.reloadList, frame)
check("failed reload: the original error is re-raised unchanged",
    not ok and err == "InGameMenuAnimalsFrame.lua:567: attempt to call missing method 'getVisual'")
check("failed reload: the list's reloadData is no longer stubbed", rawget(frame.list, "reloadData") == nil)
frame.list:reloadData()
check("failed reload: a later list reload reaches the list again", reloads() == 1)
check("failed reload: the held selector arrow stops repeating",
    frame.subCategorySelector.isLeftButtonPressed == false and frame.subCategorySelector.delayTime == math.huge)
check("failed reload: logged as an error", LOG[1] ~= nil and LOG[1]:find("^error: .*base reloadList failed") ~= nil)

-- The list rows themselves throw: the click sound is not left off.
baseFails = false
frame = makeFrame()
local suppressed
frame.list.setSoundSuppressed = function(_, value) suppressed = value end
frame.list.reloadData = function() error("SmoothListElement.lua:873: attempt to compare nil < number", 0) end
ok = pcall(InGameMenuAnimalsFrame.reloadList, frame)
check("failed row reload: sound flags restored and selector released",
    not ok and frame.list.soundDisabled == false and suppressed == false
    and frame.subCategorySelector.isLeftButtonPressed == false)

-- 1.25 Animals page log: a cell populate threw inside updateView, leaving a linked cell with no
-- row; every later reload then failed comparing its nil sectionIndex. The stale cell goes back to
-- the cache, the previous animal's details are hidden, and a repeat of the same error is not re-raised.
frame = makeFrame()
local hidden = {}
frame.animalBox = { setVisible = function(_, v) hidden.box = v end }
frame.detailDescriptionText = { setVisible = function(_, v) hidden.desc = v end }
local good = { sectionIndex = 1, indexInSection = 1, reusableName = "animalCell" }
local orphan = { reusableName = "animalCell" }
frame.list.elements = { good, orphan }
frame.list.cellCache = { animalCell = {} }
frame.list.queueReusableCell = function(list, cell)
    for i = #list.elements, 1, -1 do
        if list.elements[i] == cell then table.remove(list.elements, i) end
    end
    table.insert(list.cellCache[cell.reusableName], cell)
end
frame.list.reloadData = function() error("InGameMenuAnimalsFrame.lua:581: attempt to call missing method 'getMaxNumAnimals'", 0) end
LOG = {}
ok = pcall(InGameMenuAnimalsFrame.reloadList, frame)
check("failed populate: the first error is raised and the orphan cell is recycled",
    not ok and #frame.list.elements == 1 and frame.list.elements[1] == good
    and frame.list.cellCache.animalCell[1] == orphan)
check("failed populate: the previous animal's details are hidden", hidden.box == false and hidden.desc == false)
frame.subCategorySelector.isLeftButtonPressed = true
ok = pcall(InGameMenuAnimalsFrame.reloadList, frame)
check("repeated failure: the same error is counted, not raised again, and the arrow is released",
    ok and frame.rlReloadErrors["InGameMenuAnimalsFrame.lua:581: attempt to call missing method 'getMaxNumAnimals'"] == 2
    and frame.subCategorySelector.isLeftButtonPressed == false)
LOG = {}
InGameMenuAnimalsFrame.onFrameClose(frame)
check("page close: the repeat count is logged once and reset",
    frame.rlReloadErrors == nil and LOG[1] ~= nil and LOG[1]:find("repeated 2 times") ~= nil)

-- A normal reload into an empty pen keeps the selector working and resets a stale index.
frame, reloads = makeFrame()
ok = pcall(InGameMenuAnimalsFrame.reloadList, frame)
check("normal reload: the list is rebuilt once and the selector is untouched",
    ok and reloads() == 1 and frame.subCategorySelector.isLeftButtonPressed == true)

frame = makeFrame()
local animal = {}
frame.husbandrySubTypes = { 7 }
frame.subTypeIndexToClusters = { [7] = { animal } }
InGameMenuAnimalsFrame.reloadList = Utils.overwrittenFunction(function(f)
    f.husbandrySubTypes = { 7 }
    f.subTypeIndexToClusters = { [7] = { animal } }
end, RealisticLivestock_InGameMenuAnimalsFrame.reloadList)
frame.list.selectedSectionIndex, frame.list.selectedIndex = 2, 9
ok = pcall(InGameMenuAnimalsFrame.reloadList, frame)
check("pen switch: a selection past the new pen's rows is reset to the first animal",
    ok and frame.list.selectedSectionIndex == 1 and frame.list.selectedIndex == 1)

-- Closing the page releases a held arrow as well.
frame = makeFrame()
InGameMenuAnimalsFrame.onFrameClose(frame)
check("page close: the held selector arrow is released",
    frame.subCategorySelector.isLeftButtonPressed == false and frame.subCategorySelector.delayTime == math.huge)
