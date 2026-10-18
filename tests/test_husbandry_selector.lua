-- Exercise the real three frame callbacks with a minimal GUI surface. In particular,
-- a group-local selector index must never select a different species in the full farm list.
-- Strip the unrelated GIANTS numeric cast for the plain-Lua headless runner.
local utilFile = assert(io.open(REPO .. "scripts/utils/RLAnimalUtil.lua", "r"))
local utilSource = utilFile:read("*a"); utilFile:close()
assert(load((utilSource:gsub("::number", "")), "RLAnimalUtil"))()
loadMod("scripts/gui/rlmenu/services/RLAnimalQuery.lua")
loadMod("scripts/gui/rlmenu/RLMenuHusbandryAnchor.lua")
loadMod("scripts/gui/rlmenu/services/RLHusbandrySelector.lua")
loadMod("scripts/gui/rlmenu/frames/RLMenuInfoFrame.lua")
loadMod("scripts/gui/rlmenu/frames/RLMenuMoveFrame.lua")
loadMod("scripts/gui/rlmenu/frames/RLMenuSellFrame.lua")

local noop = function() end
local function pen(name, typeIndex)
    return { getName = function() return name end, getAnimalTypeIndex = function() return typeIndex end,
        spec_husbandryAnimals = {} }
end
local cowA, cowB, sheep, duck = pen("A", 1), pen("B", 1), pen("A", 3), pen("Duck", 17)
local unnamed, unknown = pen("", 3), pen("Unknown", nil)
local farmLists = { [1] = { sheep, cowB, duck, cowA, unnamed, unknown }, [2] = {} }
local types = { [1] = { groupTitle = "牛" }, [3] = { title = "羊" }, [17] = { name = "DUCK" } }
g_i18n = { hasText = function(_, key) return key == "ui_ducks" end,
    getText = function() return "鸭" end }
g_currentMission = {
    husbandrySystem = { getPlaceablesByFarm = function(_, id) return farmLists[id] end },
    animalSystem = { getTypeByIndex = function(_, index) return types[index] end },
}
local currentFarm = 1
RLAnimalInfoService = { getCurrentFarmId = function() return currentFarm end }
RLDetailPaneHelper = { updatePenDisplay = noop, updateMoneyDisplay = noop, clearDetail = noop }

local function element()
    return { visible = true, state = 1, texts = {}, links = {},
        setVisible = function(self, value) self.visible = value end,
        getIsVisible = function(self) return self.visible end,
        setText = function(self, value) self.text = value end,
        setTexts = function(self, values) self.texts = values; self.state = math.min(self.state, #values) end,
        setState = function(self, state, forceEvent)
            self.state = math.max(1, math.min(state, #self.texts))
            if forceEvent then self.callback(self.state) end
        end,
    }
end
FocusManager = { TOP = "top", BOTTOM = "bottom",
    linkElements = function(_, source, direction, target) source.links[direction] = target end,
    setFocus = function(self, target) self.focused = target end }
g_messageCenter = { subscribe = noop, unsubscribe = noop }
MessageType = { MONEY_CHANGED = 1 }
local lifecycleBase = { onFrameOpen = noop, onFrameClose = noop }
for _, class in ipairs({ RLMenuInfoFrame, RLMenuMoveFrame, RLMenuSellFrame }) do
    class.superClass = function() return lifecycleBase end
end

local function frame(class)
    local f = setmetatable({ filters = {}, sortedHusbandries = {}, items = {}, sectionOrder = {},
        itemsBySection = {}, titlesBySection = {}, selectedAnimals = {},
        speciesSelector = element(), subCategorySelector = element(), husbandryCounter = element(),
        noHusbandriesText = element(), animalList = element(), reloads = 0, validations = 0 }, { __index = class })
    f.subCategorySelector.callback = function(state) f:onHusbandryChanged(state) end
    f.speciesSelector.callback = function(state) f:onSpeciesChanged(state) end
    -- Leave refreshHusbandries, onSpeciesChanged and onHusbandryChanged real.
    f.reloadAnimalList = function(self) self.reloads = self.reloads + 1 end
    f.revalidateActiveFilter = function(self) self.validations = self.validations + 1 end
    f.animalList.reloadData = function()
        assert(#f.sectionOrder == 0 and next(f.itemsBySection) == nil, "empty farm exposes old list sections")
    end
    f.animalList.getItemCount = function() return 0 end
    for _, method in ipairs({ "updateFilterChip", "updatePenDisplay", "updateMoneyDisplay", "updatePenHeader",
        "updateCartDisplay", "updateEmptyState", "updateButtonVisibility", "clearDetail" }) do f[method] = noop end
    f.getTrailerDealerContext = function() return nil end
    return f
end

local groups = RLHusbandrySelector.buildGroups(RLAnimalQuery.listHusbandriesForFarm(1))
check("selector: registered types are ordered numerically, map types included, unknown last",
    #groups == 4 and groups[1].typeIndex == 1 and groups[2].typeIndex == 3
    and groups[3].typeIndex == 17 and groups[4].typeIndex == 0)
check("selector: pens keep their name sort and empty/unnamed pens remain accessible",
    #groups[1].husbandries == 2 and groups[1].husbandries[1] == cowA and groups[1].husbandries[2] == cowB
    and #groups[2].husbandries == 2 and groups[2].husbandries[1] == unnamed)

for _, entry in ipairs({ { "Info", RLMenuInfoFrame }, { "Move", RLMenuMoveFrame }, { "Sell", RLMenuSellFrame } }) do
    local name, class = entry[1], entry[2]
    local function test(label, condition) check("selector " .. name .. ": " .. label, condition) end
    currentFarm = 1
    g_rlMenu = {}
    local f = frame(class)
    f:refreshHusbandries()
    test("first open selects the first type's first pen and refreshes exactly once",
        f.selectedHusbandry == cowA and f.speciesSelector.state == 1 and f.reloads == 1)
    test("localized species counts and local pen position",
        f.speciesSelector.texts[1] == "牛 (2)" and f.speciesSelector.texts[3] == "鸭 (1)"
        and f.husbandryCounter.text == "1 / 2" and #f.subCategorySelector.texts == 2)
    f.subCategorySelector:setState(2, true)
    f.filters = { age = 12 }
    f.selectedAnimals = { old = true }
    local before = f.validations
    f.speciesSelector:setState(2, true)
    test("switching type chooses a pen in that group, clears Quick filters and revalidates saved filters",
        f.selectedHusbandry == unnamed and next(f.filters) == nil and f.validations == before + 1)
    if name ~= "Info" then test("switching type clears the previous animal multi-selection", next(f.selectedAnimals) == nil) end
    f.speciesSelector:setState(1, true)
    test("returning to a type restores its last pen by object identity", f.selectedHusbandry == cowB
        and f.subCategorySelector.state == 2 and f.husbandryCounter.text == "2 / 2")
    f.filters = { age = 20 }
    f.subCategorySelector:setState(1, true)
    test("same-type pen switches retain Quick filters", f.filters.age == 20 and f.selectedHusbandry == cowA)

    -- A new sibling frame imports the pen ref, not the previous frame's group-local index.
    g_rlMenu.sharedSelection = { husbandry = duck }
    local sibling = frame(class)
    sibling:refreshHusbandries()
    test("shared selection restores both type and pen even when indices differ",
        sibling.selectedHusbandry == duck and sibling.speciesSelector.state == 3 and #sibling.sortedHusbandries == 1)
    test("single-pen group is skipped by keyboard focus so species remains reachable",
        sibling.animalList.links.top == sibling.speciesSelector and sibling.speciesSelector.links.bottom == sibling.animalList)
    sibling.speciesSelector:setState(1, true)
    test("per-type memory is shared across frame instances", sibling.selectedHusbandry == cowA)
    test("multi-pen group links species to pen to list in both directions",
        sibling.speciesSelector.links.bottom == sibling.subCategorySelector
        and sibling.subCategorySelector.links.top == sibling.speciesSelector
        and sibling.subCategorySelector.links.bottom == sibling.animalList
        and sibling.animalList.links.top == sibling.subCategorySelector)
    g_rlMenu.sharedSelection = { husbandry = duck }
    sibling:onFrameOpen()
    test("opening an empty single-pen group focuses species rather than the unfocusable pen selector",
        FocusManager.focused == sibling.speciesSelector and sibling.selectedHusbandry == duck)

    g_rlMenu.anchoredHusbandry = sheep
    sibling:refreshHusbandries()
    test("one-shot anchor wins over shared selection and selects the correct local index",
        sibling.selectedHusbandry == sheep and sibling.speciesSelector.state == 2
        and sibling.subCategorySelector.state == 2 and g_rlMenu.anchoredHusbandry == nil)
    sibling:refreshHusbandries()
    test("anchor is consumed once", sibling.selectedHusbandry == duck)
    g_rlMenu.anchoredHusbandry = pen("foreign", 1)
    sibling:refreshHusbandries()
    test("foreign or deleted anchor falls back to the shared pen", sibling.selectedHusbandry == duck
        and g_rlMenu.anchoredHusbandry == nil)

    -- Replacing an identically named pen must not resurrect a sold object from memory.
    local replacement = pen("B", 1)
    farmLists[1] = { sheep, cowA, replacement }
    g_rlMenu.sharedSelection = nil
    g_rlMenu.husbandrySelectionByFarm[1][1] = cowB
    sibling:refreshHusbandries()
    sibling:onSpeciesChanged(1)
    test("sold pen memory falls back to a live pen, never a matching label", sibling.selectedHusbandry == cowA)
    local beforeReload = sibling.reloads
    sibling:onSpeciesChanged(0)
    sibling:onHusbandryChanged(99)
    test("invalid selector states are ignored", sibling.reloads == beforeReload)

    -- No pens: no stale animal sections, hidden navigation, anchor still consumed.
    currentFarm = 2
    g_rlMenu.anchoredHusbandry = sheep
    sibling.filters = { age = 20 }
    sibling.sectionOrder, sibling.itemsBySection = { "old" }, { old = { {} } }
    sibling:refreshHusbandries()
    test("empty farm clears old groups/sections and hides navigation", sibling.selectedHusbandry == nil
        and #sibling.sortedHusbandries == 0 and #sibling.sectionOrder == 0
        and not sibling.speciesSelector.visible and not sibling.subCategorySelector.visible
        and not sibling.husbandryCounter.visible and sibling.noHusbandriesText.visible
        and g_rlMenu.anchoredHusbandry == nil)
    local farmTwoSheep = pen("Farm two", 3)
    farmLists[2] = { farmTwoSheep }
    sibling:refreshHusbandries()
    test("new pens restore navigation and farm memory stays isolated", sibling.selectedHusbandry == farmTwoSheep
        and sibling.speciesSelector.visible and sibling.subCategorySelector.visible
        and not sibling.noHusbandriesText.visible and g_rlMenu.husbandrySelectionByFarm[2][3] == farmTwoSheep
        and g_rlMenu.husbandrySelectionByFarm[1][1] == cowA)
    test("type-scoped Quick filters are cleared even across an intervening empty farm", next(sibling.filters) == nil)
    RLHusbandrySelector.linkFocus(sibling)
    test("single species and single pen are skipped rather than trapping keyboard focus",
        sibling.animalList.links.top == nil and sibling.subCategorySelector.links.top == nil)
    farmLists[1] = { sheep, cowB, duck, cowA, unnamed, unknown }
    farmLists[2] = {}
end

-- All three classes exchange the same husbandry object through existing sharedSelection.
currentFarm, g_rlMenu = 1, {}
local info, move, sell = frame(RLMenuInfoFrame), frame(RLMenuMoveFrame), frame(RLMenuSellFrame)
info:onFrameOpen()
info:onHusbandryChanged(2)
info:onFrameClose()
move:onFrameOpen()
move:onFrameClose()
sell:onFrameOpen()
check("selector: Info -> Move -> Sell preserves the same pen", info.selectedHusbandry == cowB
    and move.selectedHusbandry == cowB and sell.selectedHusbandry == cowB)

-- Trailer dealer Sell bypasses grouping and never overwrites per-type pen memory.
local trailer = { getName = function() return "Trailer" end }
sell.getTrailerDealerContext = function() return trailer end
RLTrailerEndpointService = { getDisplayData = function() return { name = "Trailer", used = 2, total = 6 } end }
RLTransferAdapter = { formatCapacityLabel = function(name) return name .. " (2/6)" end }
RLHusbandrySelector.linkFocus(sell)
sell:refreshHusbandries()
RLHusbandrySelector.linkFocus(sell)
check("selector: trailer sale stays fixed and hides species and counter", sell.selectedHusbandry == trailer
    and #sell.sortedHusbandries == 1 and not sell.speciesSelector.visible and not sell.husbandryCounter.visible
    and sell.subCategorySelector.visible and sell.subCategorySelector.texts[1] == "Trailer (2/6)")
check("selector: trailer sale preserves farm memory and removes the old hidden-species focus link",
    g_rlMenu.husbandrySelectionByFarm[1][1] == cowB and sell.subCategorySelector.links.top == nil)
sell.getTrailerDealerContext = function() return nil end
sell:refreshHusbandries()
check("selector: returning from trailer sale restores the shared pen and species controls",
    sell.selectedHusbandry == cowB and sell.speciesSelector.visible and sell.husbandryCounter.visible)

-- Stress the mapping and counter without spawning a GUI element per husbandry.
local many = {}
for i = 1, 120 do many[i] = pen(string.format("Pen %03d", i), i % 2 == 0 and 1 or 17) end
farmLists[1] = many
g_rlMenu.anchoredHusbandry = many[119]
info:refreshHusbandries()
check("selector: 120 pens become two 60-pen groups with the anchor at local 60/60",
    #info.husbandryGroups == 2 and #info.sortedHusbandries == 60 and info.selectedHusbandry == many[119]
    and info.husbandryCounter.text == "60 / 60")
