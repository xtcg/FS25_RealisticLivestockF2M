-- Two-level husbandry navigation shared by Info, Move and Sell. Selection memory is
-- session-only and scoped to a farm; remembered pens are placeable references, never labels or indices.
RLHusbandrySelector = {}
local Log = RmLogging.getLogger("RLRM")

--- Group the name-sorted farm list by registered animal type, retaining empty pens.
--- Unknown types stay accessible in a final fallback group.
function RLHusbandrySelector.buildGroups(husbandries)
    local groups, byType = {}, {}
    for _, husbandry in ipairs(husbandries) do
        local typeIndex = husbandry.getAnimalTypeIndex ~= nil and husbandry:getAnimalTypeIndex() or 0
        local group = byType[typeIndex]
        if group == nil then
            group = { typeIndex = typeIndex, husbandries = {} }
            byType[typeIndex] = group
            groups[#groups + 1] = group
        end
        group.husbandries[#group.husbandries + 1] = husbandry
    end
    table.sort(groups, function(a, b)
        if a.typeIndex == 0 then return false end
        if b.typeIndex == 0 then return true end
        return a.typeIndex < b.typeIndex
    end)
    return groups
end

function RLHusbandrySelector.locate(groups, husbandry)
    if husbandry == nil then return nil end
    for groupIndex, group in ipairs(groups) do
        for penIndex, pen in ipairs(group.husbandries) do
            if pen == husbandry then return groupIndex, penIndex end
        end
    end
    return nil
end

local function getMemory(frame)
    local owner = g_rlMenu or frame
    owner.husbandrySelectionByFarm = owner.husbandrySelectionByFarm or {}
    local farmKey = frame.farmId or 0
    owner.husbandrySelectionByFarm[farmKey] = owner.husbandrySelectionByFarm[farmKey] or {}
    return owner.husbandrySelectionByFarm[farmKey]
end

--- Rebuild the group-local pen selector and invoke the frame's existing change handler once.
function RLHusbandrySelector.selectGroup(frame, state, preferredHusbandry)
    local group = frame.husbandryGroups ~= nil and frame.husbandryGroups[state] or nil
    if group == nil then return end
    frame.selectedHusbandryGroup = state
    frame.sortedHusbandries = group.husbandries
    local remembered = preferredHusbandry or getMemory(frame)[group.typeIndex]
    local penState = 1
    local names = {}
    for index, husbandry in ipairs(group.husbandries) do
        names[index] = RLAnimalQuery.formatHusbandryLabel(husbandry, index)
        if husbandry == remembered then penState = index end
    end
    if frame.speciesSelector ~= nil then frame.speciesSelector:setState(state) end
    if frame.subCategorySelector ~= nil then
        frame.subCategorySelector:setTexts(names)
        frame.subCategorySelector:setState(penState)
    end
    Log:debug("RLHusbandrySelector: type=%s pens=%d selected=%d", tostring(group.typeIndex), #names, penState)
    frame:onHusbandryChanged(penState)
    RLHusbandrySelector.linkFocus(frame)
end

--- Called after a valid pen selection. Trailer sources never enter the group memory.
function RLHusbandrySelector.remember(frame, state)
    local group = frame.husbandryGroups ~= nil and frame.husbandryGroups[frame.selectedHusbandryGroup] or nil
    if group == nil then return end
    getMemory(frame)[group.typeIndex] = frame.selectedHusbandry
    if frame.husbandryCounter ~= nil then
        frame.husbandryCounter:setText(string.format("%d / %d", state, #group.husbandries))
    end
end

--- Refresh both levels, preserving the one-shot anchor and cross-tab selection priority.
--- Returns false for a farm with no husbandries; the frame renders its own empty state.
function RLHusbandrySelector.refresh(frame, husbandries)
    frame.allHusbandries = husbandries
    frame.husbandryGroups = RLHusbandrySelector.buildGroups(husbandries)
    frame.selectedHusbandryGroup = nil
    local anchor, shared
    if g_rlMenu ~= nil then
        anchor = g_rlMenu.anchoredHusbandry
        g_rlMenu.anchoredHusbandry = nil
        shared = g_rlMenu.sharedSelection ~= nil and g_rlMenu.sharedSelection.husbandry or nil
    end
    local names, ordered = {}, {}
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    for index, group in ipairs(frame.husbandryGroups) do
        local animalType = animalSystem ~= nil and animalSystem:getTypeByIndex(group.typeIndex) or nil
        local label = RLAnimalUtil.getAnimalTypeDisplayName(animalType)
        names[index] = string.format("%s (%d)", label, #group.husbandries)
        for _, husbandry in ipairs(group.husbandries) do ordered[#ordered + 1] = husbandry end
    end
    local hasPens = #ordered > 0
    if frame.speciesSelector ~= nil then
        frame.speciesSelector:setTexts(names)
        frame.speciesSelector:setVisible(hasPens)
    end
    if frame.subCategorySelector ~= nil then
        frame.subCategorySelector:setVisible(hasPens)
        if not hasPens then frame.subCategorySelector:setTexts({}) end
    end
    if frame.husbandryCounter ~= nil then frame.husbandryCounter:setVisible(hasPens) end
    if not hasPens then
        frame.sortedHusbandries = {}
        return false
    end
    if frame.noHusbandriesText ~= nil then frame.noHusbandriesText:setVisible(false) end
    local initial, anchorMatched = RLMenuHusbandryAnchor.resolveIndex(ordered, anchor, shared or frame.selectedHusbandry)
    Log:debug("RLHusbandrySelector: farm=%s groups=%d pens=%d anchorMatched=%s",
        tostring(frame.farmId), #names, #ordered, tostring(anchorMatched))
    local husbandry = ordered[initial]
    local groupState = RLHusbandrySelector.locate(frame.husbandryGroups, husbandry)
    RLHusbandrySelector.selectGroup(frame, groupState, husbandry)
    return true
end

--- The dealer's trailer source is fixed, with no farm/species navigation or memory writes.
function RLHusbandrySelector.useTrailer(frame)
    frame.husbandryGroups = {}
    frame.allHusbandries = {}
    frame.selectedHusbandryGroup = nil
    if frame.speciesSelector ~= nil then frame.speciesSelector:setVisible(false) end
    if frame.husbandryCounter ~= nil then frame.husbandryCounter:setVisible(false) end
    if frame.subCategorySelector ~= nil then frame.subCategorySelector:setVisible(true) end
end

function RLHusbandrySelector.linkFocus(frame)
    -- MultiTextOption refuses focus with a single entry when disableButtonsOnSingleText
    -- is enabled. Skip that row so a single empty pen cannot trap keyboard/controller users.
    local species = frame.speciesSelector
    if species ~= nil and (not species:getIsVisible() or #frame.husbandryGroups < 2) then species = nil end
    local pen = #frame.sortedHusbandries > 1 and frame.subCategorySelector or nil
    if frame.speciesSelector ~= nil then
        FocusManager:linkElements(frame.speciesSelector, FocusManager.BOTTOM, pen or frame.animalList)
    end
    if frame.subCategorySelector ~= nil then
        FocusManager:linkElements(frame.subCategorySelector, FocusManager.TOP, species)
        FocusManager:linkElements(frame.subCategorySelector, FocusManager.BOTTOM, frame.animalList)
    end
    if frame.animalList ~= nil then
        FocusManager:linkElements(frame.animalList, FocusManager.TOP, pen or species)
    end
end
