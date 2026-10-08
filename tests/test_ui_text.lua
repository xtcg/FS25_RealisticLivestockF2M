-- UI text: every translation file carries the English keys with the same format placeholders,
-- the Chinese file has no English left, the menu's stat grid has a slot for every row an animal
-- can show, and the body condition texts fit the cells they are drawn in.

local LANGUAGES = { "br", "cs", "cz", "da", "de", "en", "es", "fi", "fr", "hu", "it", "nl", "pl", "pt", "ru", "tr", "uk" }

local function readFile(path)
    local handle = assert(io.open(REPO .. path, "r"))
    local text = handle:read("a")
    handle:close()
    return text
end

local function loadTranslation(lang)
    local list, byName = {}, {}
    for line in readFile("translations/translation_" .. lang .. ".xml"):gmatch("[^\n]+") do
        local name, text = line:match('<text name="([^"]+)" text="([^"]*)"')
        if name ~= nil then
            list[#list + 1] = name
            byName[name] = byName[name] == nil and text or false     -- false marks a duplicate
        end
    end
    return list, byName
end

local function placeholders(text)
    local out = {}
    for spec in text:gmatch("%%[%.%d]*[sdfi]") do out[#out + 1] = spec end
    return table.concat(out, " ")
end

local function hasCJK(text)
    for _, code in utf8.codes(text) do
        if code >= 0x4E00 and code <= 0x9FFF then return true end
    end
    return false
end

local function unescape(text)
    return (text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#10;", "\n"):gsub("&amp;", "&"))
end

local enList, en = loadTranslation("en")

-- Translation files ----------------------------------------------------------------------------

for _, lang in ipairs(LANGUAGES) do
    local list, texts = loadTranslation(lang)
    local missing, duplicate, extra, format = {}, {}, {}, {}
    for _, name in ipairs(enList) do
        if texts[name] == nil then missing[#missing + 1] = name
        elseif texts[name] ~= false and placeholders(texts[name]) ~= placeholders(en[name]) then format[#format + 1] = name end
    end
    for name, text in pairs(texts) do
        if text == false then duplicate[#duplicate + 1] = name end
        if en[name] == nil then extra[#extra + 1] = name end
    end
    check(lang .. ": carries every English key", #missing == 0)
    check(lang .. ": no key twice", #duplicate == 0)
    check(lang .. ": no key English does not have", #extra == 0)
    check(lang .. ": same format placeholders as English", #format == 0)
    if #missing + #duplicate + #extra + #format > 0 then
        print(lang, "missing", table.concat(missing, ","), "duplicate", table.concat(duplicate, ","),
            "extra", table.concat(extra, ","), "format", table.concat(format, ","))
    end
    check(lang .. ": the old one-line pen summary keys are gone",
        texts.rl_ui_ration == nil and texts.rl_ui_penConditionFormat == nil and texts.rl_ui_penRationFormat == nil)
end

do
    -- Entries that stay as they are in Chinese: a URL.
    local keep = { rl_mod_compat_url = true }
    local _, zh = loadTranslation("cs")
    local english = {}
    for name, text in pairs(zh) do
        if text and not keep[name] and not hasCJK(text) and text:find("%a%a%a") then english[#english + 1] = name end
    end
    table.sort(english)
    check("cs: every text is in Chinese", #english == 0)
    if #english > 0 then print("cs English:", table.concat(english, ",")) end

    -- The game's font holds only the characters its own texts use; any other draws as nothing.
    local font = {}
    for line in readFile("tests/fs25_font_glyphs.txt"):gmatch("[^\n]+") do
        if line:sub(1, 1) ~= "#" then
            for _, code in utf8.codes(line) do font[code] = true end
        end
    end
    local undrawable = {}
    for name, text in pairs(zh) do
        if text then
            for _, code in utf8.codes(unescape(text)) do
                if code > 0x2000 and not font[code] then
                    undrawable[#undrawable + 1] = name .. ":" .. utf8.char(code)
                    break
                end
            end
        end
    end
    table.sort(undrawable)
    check("cs: every character is in the game's font", next(font) ~= nil and #undrawable == 0)
    if #undrawable > 0 then print("cs not in font:", table.concat(undrawable, ",")) end
end

-- Body condition texts against the cells they are drawn in ------------------------------------
-- Stat grid (rlMenu_animalStatLabel / Value): bold upper-case label to 145 px, upper-case value
-- to 200 px at 14 px. Pen info box: key and value on one 296 px line at 14 px. Counted in
-- characters, a CJK character as two.

local function width(text)
    local n = 0
    for _, code in utf8.codes(unescape(text)) do n = n + ((code >= 0x2E80 and code <= 0xFFEF) and 2 or 1) end
    return n
end

local STAT_LABELS = { "rl_ui_finish", "rl_ui_bodyCondition", "rl_ui_finishVerdict", "rl_ui_finishWeight",
    "rl_ui_rationCoverage", "rl_ui_milkOfPotential", "rl_ui_conceptionCondition" }
local STAT_VALUES = { "rl_ui_conditionCalf", "rl_ui_finishVerdictReady", "rl_ui_finishVerdictNeedsFinish",
    "rl_ui_finishVerdictGrowing", "rl_ui_finishVerdictStore", "rl_ui_finishVerdictOverfat",
    "rl_ui_finishVerdictTooYoung", "rl_ui_finishVerdictBlocked" }
local PEN_KEYS = { "rl_ui_penBcs", "rl_ui_penCowsThinFat", "rl_ui_penBullsReady", "rl_ui_penBullsOverfat",
    "rl_ui_penFeedEaten", "rl_ui_penRationEnergy", "rl_ui_penWater" }

for _, lang in ipairs(LANGUAGES) do
    local _, texts = loadTranslation(lang)
    local long = {}
    local function limit(keys, chars)
        for _, key in ipairs(keys) do
            if texts[key] and width(texts[key]) > chars then long[#long + 1] = key .. "=" .. texts[key] end
        end
    end
    limit(STAT_LABELS, 16)
    limit(STAT_VALUES, 20)
    limit(PEN_KEYS, 20)
    check(lang .. ": body condition labels and values fit their cells", #long == 0)
    if #long > 0 then print(lang, "too long:", table.concat(long, " | ")) end
end

-- Reproduction reasons ---------------------------------------------------------------------------
-- The real Animal:addInfos with each language's texts and the base game's month format
-- ("%d %s" with ui_months). Stat grid value: 20 characters; the in-world animal box draws
-- "Can reproduce" and "No (...)" on one 296 px line: 36 characters together.

loadAnimalSection("function Animal:addInfos", "function Animal:showInfo")
RealisticLivestock = { hasMaleAnimalInPen = function(_, _, animal) return animal.hasMale end }
local MONTHS = { en = "months", de = "Monate", cs = "月" }

local function reproductionText(texts, lang, fields)
    g_i18n = {
        getText = function(_, key) return unescape(texts[key] or key) end,
        formatNumber = function(_, v) return string.format("%d", math.floor(v + 0.5)) end,
        formatNumMonth = function(_, n) return string.format("%d %s", n, MONTHS[lang] or "months") end,
    }
    local sub = { name = "COW_HOLSTEIN", reproductionMinAgeMonth = 12, reproductionMinHealth = 0.75 }
    local animal = setmetatable({ age = 20, gender = "male", isParent = false, monthsSinceLastBirth = 0,
        reproduction = 0, hasMale = true, health = 1, monitor = {},
        infoReproduction = { title = "Reproduction", titleOrg = "Reproduction" } }, { __index = Animal })
    for k, v in pairs(fields) do animal[k] = v end
    animal.getSubType = function() return sub end
    animal.getHealthFactor = function(self) return self.health end
    animal.getSupportsReproduction = function() return true end
    animal.getReproductionFactor = function() return 0 end
    animal.getCanReproduce = function() return false end
    animal.isHorse = function() return false end
    local infos = {}
    animal:addInfos(infos)
    return infos[1].valueText
end

do
    local CASES = {
        { "too young", { age = 8 } },
        { "recovering", { isParent = true, monthsSinceLastBirth = 0 } },
        { "no male", { hasMale = false } },
        { "unhealthy", { health = 0.5 } },
    }
    local _, enTexts = loadTranslation("en")
    check("reproduction: English reasons are short, the minimum health shows as 75 %",
        reproductionText(enTexts, "en", CASES[1][2]) == "Under 12 months"
        and reproductionText(enTexts, "en", CASES[2][2]) == "Recovers in 3 months"
        and reproductionText(enTexts, "en", CASES[3][2]) == "No suitable male"
        and reproductionText(enTexts, "en", CASES[4][2]) == "Health < 75 %")

    for _, lang in ipairs(LANGUAGES) do
        local _, texts = loadTranslation(lang)
        local long = {}
        for _, case in ipairs(CASES) do
            local text = reproductionText(texts, lang, case[2])
            if width(text) > 20 then long[#long + 1] = case[1] .. "=" .. text end
        end
        for _, key in ipairs({ "rl_ui_tooYoungBracketed", "rl_ui_recoveringLastBirthBracketed",
            "rl_ui_noMaleAnimalBracketed", "rl_ui_unhealthyBracketed" }) do
            if width(texts.rl_ui_canReproduce) + width(texts[key]) > 36 then long[#long + 1] = key .. "=" .. texts[key] end
        end
        -- Only the languages this fork maintains are held to the limit; the others' own translations are theirs.
        if lang == "en" or lang == "de" or lang == "cs" or texts.rl_ui_noMaleAnimal == enTexts.rl_ui_noMaleAnimal then
            check(lang .. ": reproduction reasons fit the stat grid and the in-world box", #long == 0)
            if #long > 0 then print(lang, "too long:", table.concat(long, " | ")) end
        end
    end
end

-- Stat grid ------------------------------------------------------------------------------------

loadMod("scripts/gui/rlmenu/services/RLDetailPaneHelper.lua")
local SLOTS = RLDetailPaneHelper.NUM_STAT_ROWS

-- A pregnant, lactating cow: age, health, reproduction, weight, condition, ration, milk,
-- fertility, pregnant, expecting, expected date, lactating.
check("grid: a slot for each of the 12 rows a pregnant lactating cow shows", SLOTS >= 12 and SLOTS % 2 == 0)

for _, frame in ipairs({ "aiFrame", "buyFrame", "infoFrame", "moveFrame", "sellFrame", "transferFrame" }) do
    local xml = readFile("gui/rlmenu/" .. frame .. ".xml")
    local rows, labels, values = 0, 0, 0
    for _ in xml:gmatch('id="statRow%[%d+%]"') do rows = rows + 1 end
    for _ in xml:gmatch('id="statLabel%[%d+%]"') do labels = labels + 1 end
    for _ in xml:gmatch('id="statValue%[%d+%]"') do values = values + 1 end
    check("grid: " .. frame .. " has every stat slot and the section id",
        rows == SLOTS and labels == SLOTS and values == SLOTS and xml:find('id="statRow%[' .. SLOTS .. '%]"') ~= nil
        and xml:find('id="statsSection"') ~= nil)
end

check("grid: the section shrinks to the rows in use (10 px pad + 35 px per row of two)",
    near(RLDetailPaneHelper.getStatsSectionShare(SLOTS), 1, 1e-12)
    and near(RLDetailPaneHelper.getStatsSectionShare(8), (10 + 4 * 35) / (10 + SLOTS / 2 * 35), 1e-12)
    and near(RLDetailPaneHelper.getStatsSectionShare(7), (10 + 4 * 35) / (10 + SLOTS / 2 * 35), 1e-12)
    and near(RLDetailPaneHelper.getStatsSectionShare(99), 1, 1e-12)
    and near(RLDetailPaneHelper.getStatsSectionShare(0), 10 / (10 + SLOTS / 2 * 35), 1e-12))

do
    local function element()
        local e = { visible = true, text = nil }
        function e:setVisible(v) self.visible = v end
        function e:setText(t) self.text = t end
        return e
    end
    local frame = { statRow = {}, statLabel = {}, statValue = {} }
    for i = 1, SLOTS do frame.statRow[i], frame.statLabel[i], frame.statValue[i] = element(), element(), element() end
    frame.statsSection = { size = { 1, 0.255 } }
    function frame.statsSection:setSize(x, y) self.size = { x or self.size[1], y or self.size[2] } end

    local rows = {}
    for i = 1, 13 do rows[i] = { title = "t" .. i, valueText = "v" .. i } end
    RLDetailPaneHelper.updateAnimalStats(frame, rows)
    check("grid: 13 rows all shown, the 14th slot hidden",
        frame.statRow[13].visible and frame.statValue[13].text == "v13" and not frame.statRow[14].visible)
    check("grid: the section keeps its full height for 7 rows of two", near(frame.statsSection.size[2], 0.255, 1e-12))

    RLDetailPaneHelper.updateAnimalStats(frame, { rows[1], rows[2], rows[3] })
    check("grid: 3 rows shrink the section to two grid rows from its full height",
        near(frame.statsSection.size[2], 0.255 * (10 + 2 * 35) / 255, 1e-12) and not frame.statRow[4].visible)
end
