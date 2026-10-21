-- RL money types carry RL's environment, so the HUD money popup finds their titles: the HUD runs
-- in the global environment and looks the title up with g_i18n:getText(title, moneyType.customEnv).
-- Checked for every translation file, against the game's own I18N, MoneyType and HUD code.

loadMod("tests/fixtures/fs25_i18n.lua")

local LANGUAGES = { "br", "cs", "cz", "da", "de", "en", "es", "fi", "fr", "hu", "it", "nl", "pl", "pt", "ru", "tr", "uk" }
local MOD = "FS25_RealisticLivestock"
local EXPECTED = {
    { "HERDSMAN_WAGES", "herdsmanWages", "rl_ui_herdsmanWages" },
    { "SEMEN_PURCHASE", "semenPurchase", "rl_ui_semenPurchase" },
    { "MEDICINE", "medicine", "rl_ui_medicine" },
    { "SEMEN_SALE", "semenSale", "rl_semen_sale" },
    { "SEMEN_COLLECTION", "semenCollection", "rl_semen_collectionFee" },
}

local handle = assert(io.open(REPO .. "scripts/core/RealisticLivestock.lua", "r"))
local source = handle:read("a")
handle:close()

check("RealisticLivestock.lua names its environment modName", source:find("\nlocal modName = g_currentModName\n", 1, true) ~= nil)

-- Each registration as written, in order, with the LAST_ID bump straight after it.
local registrations = {}
for name, args, bump in source:gmatch("MoneyType%.([%u_]+) = MoneyType%.register%(([^)]*)%)%s*\n%s*(MoneyType%.LAST_ID = MoneyType%.LAST_ID %+ 1)") do
    local env = { modName = MOD }
    local statistic, title, customEnv = assert(load("return " .. args, name, "t", env))()
    registrations[#registrations + 1] = { name = name, statistic = statistic, title = title, customEnv = customEnv, bump = bump }
end

check("five RL money types, each followed by the LAST_ID bump", #registrations == #EXPECTED)
for i, want in ipairs(EXPECTED) do
    local got = registrations[i] or {}
    check(string.format("%d. %s keeps statistic '%s' and title '%s'", i, want[1], want[2], want[3]),
        got.name == want[1] and got.statistic == want[2] and got.title == want[3])
    check(want[1] .. " registered with RL's environment", got.customEnv == MOD)
end

local missingWith, missingWithout = {}, 0
for _, lang in ipairs(LANGUAGES) do
    g_languageSuffix = "_" .. lang
    FS25I18N.reset()
    local texts = FS25I18N.readTranslation(REPO .. "translations/translation_" .. lang .. ".xml")
    FS25I18N.addMod(MOD, texts)
    for _, reg in ipairs(registrations) do
        local moneyType = FS25I18N.registerMoneyType(reg.statistic, reg.title, reg.customEnv)
        local shown = FS25I18N.hudMoneyTitle(moneyType)
        if shown ~= texts[reg.title] or shown:find("^Missing") then
            missingWith[#missingWith + 1] = lang .. ":" .. reg.title .. "=" .. tostring(shown)
        end
        -- Control: the same lookup without the environment is what the HUD did before.
        local bare = FS25I18N.registerMoneyType(reg.statistic, reg.title, nil)
        if FS25I18N.hudMoneyTitle(bare):find("^Missing") then missingWithout = missingWithout + 1 end
    end
end
check("HUD shows each RL money title in all 17 languages: " .. table.concat(missingWith, ", "), #missingWith == 0)
check("control: without the environment the HUD shows 'Missing' for all of them",
    missingWithout == #LANGUAGES * #EXPECTED)

-- The titles stay out of the global table.
local translationsAdded = {}
for name in pairs(FS25I18N.global.texts) do translationsAdded[#translationsAdded + 1] = name end
check("no RL money title copied into the global texts", #translationsAdded == 0)
