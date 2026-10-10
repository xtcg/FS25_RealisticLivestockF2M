-- Exercise the new feed UI with the shipped translations, not a key-echo i18n stub. Missing
-- dynamic reason/limit keys otherwise pass the general translation parity check unnoticed.
loadMod("tests/feedsim.lua")
local Info = RLFeedInfoService
local languages = {"br", "cs", "cz", "da", "de", "en", "es", "fi", "fr", "hu", "it", "nl", "pl", "pt", "ru", "tr", "uk"}
local function textsFor(lang)
    local file = assert(io.open(REPO .. "translations/translation_" .. lang .. ".xml", "r"))
    local content = file:read("*a")
    file:close()
    local texts = {}
    for key, value in content:gmatch('<text name="([^"]+)" text="([^"]*)"') do texts[key] = value end
    return texts
end
local function translated(text)
    return text ~= nil and text ~= "" and not text:find("rl_feed_", 1, true)
end

FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(1)
local bull = GrowthSim.makeAnimal("BULL_ANGUS", {age = 14})
local pen = FeedSim.makePen({bull}, {DRYGRASS_WINDROW = 10000, MAIZE = 1000})
RLFeed.setRation(pen, {target = "FINISH", grain = "MAIZE", share = 0.3})
FeedSim.hour(pen)
local storedRecord = bull.rlFeedIntake

for _, lang in ipairs(languages) do
    local texts = textsFor(lang)
    g_i18n = {
        getText = function(_, key) return texts[key] or key end,
        hasText = function(_, key) return texts[key] ~= nil end,
        formatVolume = function(_, liters) return string.format("%.0f L", liters) end,
    }
    local ok = true
    for _, reason in ipairs({"OK", "MODE_OFF", "CONFIG_INVALID", "MODEL_OFF", "NOT_CATTLE", "MILKCOW_LEGACY",
        "NO_TROUGH", "UNCOVERED_ANIMAL", "SUCKLING_CALF", "FUTURE_REASON"}) do
        ok = ok and translated(Info.getReasonText(reason))
    end
    for _, limit in ipairs({"NONE", "FIBRE", "STARCH", "WHEAT", "NO_FORAGE", "TARGET", "PROTEIN_OR_DEMAND",
        "ADAPTATION", "STOCK", "NO_CONCENTRATE", "NO_FEED", "APPETITE", "FILL", "DEMAND", "PROTEIN", "FUTURE_LIMIT"}) do
        ok = ok and translated(Info.getLimitText(limit))
    end
    for _, target in ipairs({"AUTO", "GROW", "FINISH", "MAINTAIN", "FUTURE_TARGET"}) do
        ok = ok and translated(Info.getTargetText(target))
    end
    ok = ok and translated(Info.getLimitText(nil)) and translated(Info.getReasonText(nil))
        and translated(Info.getGrainText({grain = "AUTO"})) and translated(Info.getGrainText({grain = "NONE"}))
    check(lang .. ": every feed reason, limit and target resolves, including unknown remote values", ok)

    local foodRows = Info.adjustFoodInfos(pen, {})
    local wheat, maize
    for _, row in ipairs(foodRows) do
        ok = ok and translated(row.title) and translated(row.valueText)
        if row.rlFeedRow.name == "WHEAT" then wheat = row end
        if row.rlFeedRow.name == "MAIZE" then maize = row end
    end
    local plan = maize.rlFeedRow.plannedPerMonth
    check(lang .. ": live food rows show zero-stock wheat and maize's DM share and planned L/month",
        ok and wheat ~= nil and wheat.value == 0 and maize ~= nil and plan > 0
        and maize.title == string.format(texts.rl_feed_feedShareFormat, "MAIZE", maize.rlFeedRow.dmShare * 100)
        and maize.valueText == string.format(texts.rl_feed_feedPlanFormat, g_i18n:formatVolume(maize.value), plan, texts.rl_feed_monthsShort))

    local rows = Info.getAnimalRows(bull)
    local expected = string.format(texts.rl_feed_intakeFormat, storedRecord.kg / storedRecord.dtDays,
        math.clamp(storedRecord.me / storedRecord.plannedMe, 0, 9.99) * 100)
    ok = rows[1].valueText == expected
    for _, row in ipairs(rows) do ok = ok and translated(g_i18n:getText(row.titleKey)) and translated(row.valueText) end
    for _, row in ipairs(Info.getPenInfoRows(pen)) do ok = ok and translated(g_i18n:getText(row.titleKey)) and translated(row.text) end
    check(lang .. ": animal DM/day and energy-plan coverage use actual ledger values with translated labels", ok)
end
