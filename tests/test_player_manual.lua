-- Read-only handbook parsing, selection, layout and input lifecycle.
loadMod("scripts/gui/rlmenu/services/RLPlayerManual.lua")
local xml = loadXMLFileFromDisk(REPO .. "xml/playerManual_cs.xml")
local chapters = RLPlayerManual.parse(xml)
local englishXml = loadXMLFileFromDisk(REPO .. "xml/playerManual_en.xml")
local englishChapters = RLPlayerManual.parse(englishXml)
check("handbook language: Simplified and Traditional Chinese use Chinese",
    RLPlayerManual.getLanguage("cs") == "cs" and RLPlayerManual.getLanguage("ct") == "cs")
local nonChinese = { "en", "de", "fr", "es", "cz", "br", "da", "fi", "hu", "it", "nl", "pl", "pt", "ru", "tr", "uk", "jp", "kr", "unknown", "" }
local allEnglish = RLPlayerManual.getLanguage(nil) == "en"
for _, language in ipairs(nonChinese) do
    allEnglish = allEnglish and RLPlayerManual.getLanguage(language) == "en"
end
check("handbook language: every non-Chinese locale and unknown locale use English", allEnglish)
check("handbook language: case-insensitive and English tab outside Chinese",
    RLPlayerManual.getLanguage("CS") == "cs" and RLPlayerManual.getTabTitle("de") == "Player guide"
    and RLPlayerManual.getTabTitle("ct") == "玩家指南")
check("English handbook: same 16-part structure including author appendix",
    #englishChapters == #chapters and englishChapters[15].title == "Appendix - Author checks")
local englishText, englishNative = "", true
for _, chapter in ipairs(englishChapters) do
    for _, paragraph in ipairs(chapter.paragraphs) do
        englishText = englishText .. "\n" .. paragraph.text
        englishNative = englishNative and paragraph.image == nil
    end
end
local numbered = true
for n = 1, 58 do numbered = numbered and englishText:find("\n" .. n .. "%.") ~= nil end
for n = 1, 30 do numbered = numbered and englishText:find("\nQ" .. n .. "%.") ~= nil end
check("English handbook: all 58 numbered sections and 30 FAQs", numbered)
check("English handbook: native text does not add DDS textures", englishNative)
check("English handbook: baseline and opt-in/disabled boundaries retained",
    englishXml:getString("playerManual#baselineCommit") == xml:getString("playerManual#baselineCommit")
    and englishText:find("S5_CALIBRATION_OFF", 1, true) ~= nil
    and englishText:find("0.125", 1, true) ~= nil
    and englishText:find("199.90", 1, true) ~= nil)

check("handbook: 16 nonempty chapters", #chapters == 16)
local paragraphs, headings = 0, 0
for _, chapter in ipairs(chapters) do
    for _, paragraph in ipairs(chapter.paragraphs) do
        paragraphs = paragraphs + 1
        if paragraph.isHeading then headings = headings + 1 end
    end
end
check("handbook: long-form content and navigation headings", paragraphs >= 300 and headings >= 90)
check("handbook: author appendix separate from player chapters", chapters[15].title:find("附录", 1, true) ~= nil)
local glyphs = {}
local glyphFile = assert(io.open(REPO .. "tests/fs25_font_glyphs.txt", "r"))
for line in glyphFile:lines() do
    if line:sub(1, 1) ~= "#" then
        for _, code in utf8.codes(line) do glyphs[code] = true end
    end
end
glyphFile:close()
local safeTitles, completeImages, validCrops, validHeaders = true, true, true, true
for _, chapter in ipairs(chapters) do
    for _, code in utf8.codes(chapter.title) do
        if code > 0x2000 and not glyphs[code] then safeTitles = false end
    end
    for _, paragraph in ipairs(chapter.paragraphs) do
        completeImages = completeImages and paragraph.image ~= nil
        validCrops = validCrops and paragraph.imageY >= 0 and paragraph.imageHeight > 0
            and paragraph.imageY + paragraph.imageHeight <= 2048
        local file = paragraph.image and io.open(REPO .. paragraph.image, "rb")
        if file then
            local header = file:read(20)
            file:close()
            validHeaders = validHeaders and header:sub(1, 4) == "DDS "
                and string.unpack("<I4", header, 13) == 2048
                and string.unpack("<I4", header, 17) == 2048
        else
            validHeaders = false
        end
    end
end
check("handbook: navigation uses native drawable glyphs", safeTitles)
check("handbook: every source paragraph has a generated image", completeImages)
check("handbook: image crops stay inside atlas bounds", validCrops)
check("handbook: all packaged atlases are valid 2048-square DDS files", validHeaders)
local closed = false
XMLFile = { load = function(_, filename)
    check("handbook: loads packaged XML", filename == "/mod/xml/playerManual_cs.xml")
    return { iterate = function(_, ...) return xml:iterate(...) end,
        getString = function(_, ...) return xml:getString(...) end,
        getBool = function(_, ...) return xml:getBool(...) end,
        getInt = function(_, ...) return xml:getInt(...) end,
        delete = function() closed = true end }
end }
check("handbook: loader closes file", #RLPlayerManual.load("/mod/xml/playerManual_cs.xml") == 16 and closed)
XMLFile.load = function() return nil end
check("handbook: missing file has readable fallback", #RLPlayerManual.load("missing") == 1)
local fallbackAttempts = {}
XMLFile.load = function(_, filename)
    fallbackAttempts[#fallbackAttempts + 1] = filename
    if filename:match("_en%.xml$") then return englishXml end
end
local fallback = RLPlayerManual.load("/mod/xml/playerManual_cs.xml")
check("handbook: missing Chinese file falls back to English",
    #fallbackAttempts == 2 and fallback[1].title == englishChapters[1].title)
local emptyClosed = false
XMLFile.load = function() return { iterate = function() end, delete = function() emptyClosed = true end } end
check("handbook: empty XML has a readable message and is closed",
    #RLPlayerManual.load("empty") == 1 and emptyClosed)


TabbedMenuFrameElement = {}
loadMod("scripts/gui/rlmenu/frames/RLMenuSettingsFrame.lua")
unpack = table.unpack
g_screenAspectRatio = 1920 / 1080
Utils = { getFilename = function(path, directory) return directory .. path end }
GuiUtils = { getUVs = function() return { 0, 0, 0, 1, 1, 0, 1, 1 } end }
local links = {}
FocusManager = { BOTTOM = "bottom", TOP = "top", RIGHT = "right", LEFT = "left",
    removeElement = function() end,
    linkElements = function(_, a, direction, b) links[a] = links[a] or {}; links[a][direction] = b end }
local registered, removed, loads = 0, 0, 0
local content = { elements = {}, invalidateLayout = function(self) self.laidOut = true end,
    scrollTo = function(self, offset) self.offset = offset end,
    registerActionEvents = function() registered = registered + 1 end,
    removeActionEvents = function() removed = removed + 1 end }
local function template()
    return { unlinkElement = function(self) self.detached = true end,
        delete = function(self) self.deleted = true end,
        clone = function(self, parent)
            local row = { absSize = { 1050 / 1920, 0 },
                setImageFilename = function(self, image) self.image = image end,
                setImageUVs = function(self, ...) self.uvs = { ... } end,
                setText = function(self, text) self.text = text end,
                getTextHeight = function(self) return #self.text * 0.001 end,
                setSize = function(self, _, height) self.height = height end,
                delete = function(self)
                    for i, e in ipairs(parent.elements) do
                        if e == self then table.remove(parent.elements, i); break end
                    end
                end }
            table.insert(parent.elements, row)
            return row
        end }
end
local list = { setDataSource = function(self, adapter) self.dataSource = adapter end,
    setDelegate = function(self, adapter) self.delegate = adapter end,
    reloadData = function(self) self.delegate:onListSelectionChanged(self, 1, 1) end,
    setSelectedItem = function(self, section, index) self.delegate:onListSelectionChanged(self, section, index) end }
g_languageShort = "cs"
local frame = setmetatable({ manualContent = content, manualChapters = list,
    manualTitle = { setText = function(self, text) self.text = text end },
    manualParagraphTemplate = template(), manualHeadingTemplate = template(), manualImageTemplate = template(),
    manualContentSlider = {}, subCategoryPaging = {}, filtersList = {} }, { __index = RLMenuSettingsFrame })
RLPlayerManual.load = function(filename)
    loads = loads + 1
    return filename:match("_en%.xml$") and englishChapters or chapters
end
frame:setManualActive(true)
check("handbook: works with no farm or admin context", loads == 1 and frame.manualChapterIndex == 1)
check("handbook: own list adapter does not reuse saved filters", list.dataSource ~= frame and list.delegate == list.dataSource)
check("handbook: detach templates only on live instance", frame.manualParagraphTemplate.detached and frame.manualHeadingTemplate.detached)
check("handbook: controller links chapter and content", links[list].right == frame.manualContentSlider)
check("handbook: renders full chapter as correctly sized glyph-safe images", #content.elements == #chapters[1].paragraphs and content.elements[1].height > 0 and content.elements[1].image ~= nil)
frame:showManualChapter(12)
check("handbook: switching deletes previous rows and resets scroll", #content.elements == #chapters[12].paragraphs and content.offset == 0)
frame:showManualChapter(999)
check("handbook: invalid selection is harmless", frame.manualChapterIndex == 12)
frame:setManualActive(true)
check("handbook: repeated activation has one input registration", registered == 1 and loads == 1)
frame:setManualActive(false)
frame:setManualActive(false)
check("handbook: leaving releases actions once and restores filter focus", removed == 1 and links[frame.subCategoryPaging].bottom == frame.filtersList)
frame:setManualActive(true)
check("handbook: reentry remembers chapter without duplicated rows", frame.manualChapterIndex == 12 and #content.elements == #chapters[12].paragraphs and registered == 2)
-- Exercise the actual pager callback, not only the manual helper.
local function page()
    return { setVisible = function(self, visible) self.visible = visible end }
end
frame.subCategoryPages = { page(), page(), page() }
frame.generalSettingsSliderBox = page()
frame.subCategoryPaging.texts = { "1", "2", "3" }
frame.updateButtonVisibility = function() end
FocusManager.setFocus = function(_, element) frame.focus = element end
frame:updateSubCategoryPages(3)
check("handbook: third pane hides general scrollbar and focuses chapters",
    frame.subCategoryPages[3].visible and not frame.subCategoryPages[1].visible
    and not frame.subCategoryPages[2].visible and not frame.generalSettingsSliderBox.visible
    and frame.focus == frame.manualChapters)
frame:updateSubCategoryPages(1)
check("handbook: general pane restores its scrollbar and releases manual actions",
    frame.subCategoryPages[1].visible and not frame.subCategoryPages[3].visible
    and frame.generalSettingsSliderBox.visible and not frame.manualActionsRegistered
    and frame.focus == frame.subCategoryPaging)
frame:setManualActive(true)
local previousAdapter = frame.manualListAdapter
g_languageShort = "de"
frame:setManualActive(true)
check("handbook: non-Chinese game renders English native text without stale images",
    frame.manualLanguage == "en" and frame.manualChapterIndex == 1 and loads == 2
    and content.elements[1].text == englishChapters[1].paragraphs[1].text
    and content.elements[1].image == nil and content.elements[1].height > 0)
g_languageShort = "fr"
frame:setManualActive(true)
check("handbook: switching between non-Chinese languages keeps English cache", loads == 2)
g_languageShort = "ct"
frame:setManualActive(true)
check("handbook: switching back to Chinese reloads once without detaching templates again",
    loads == 3 and frame.manualLanguage == "cs" and content.elements[1].image ~= nil
    and frame.manualListAdapter == previousAdapter and registered == 3)
local deleted = false
RLMenuSettingsFrame.superClass = function() return { delete = function() deleted = true end } end
frame:delete()
check("handbook: deleting releases inputs and detached templates", removed == 3 and deleted and frame.manualParagraphTemplate.deleted and frame.manualHeadingTemplate.deleted and frame.manualImageTemplate.deleted)
