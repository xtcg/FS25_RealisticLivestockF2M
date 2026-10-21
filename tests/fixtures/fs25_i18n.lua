-- Excerpts of the base game's text lookup, FS25 v1.23.1 (decompiled source):
--   dataS/scripts/I18N.lua       lines 150-175 (addModI18N), 176-194 (getText), 195-210 (hasText),
--                                413-423 (convertText)
--     sha256 35ce86e65f4898fc248a72f26297ff5005d94e0c9a17a813e9775f7a8304299c
--   dataS/scripts/MoneyType.lua  lines 4-15 (register)
--     sha256 fc4c087fbd6d1420914e9beb8304f8eb491155c7326a2443b22e38a7aa79ac0f
--   dataS/scripts/gui/hud/HUD.lua line 304 (showMoneyChange: the money type's title)
--     sha256 5298b8eae45926d82311b13caf16dd3e06a59ad2dda4d3b129f69ee16971f3a6
--   dataS/scripts/mods.lua       line 455 (modEnv.g_i18n = g_i18n:addModI18N(modName)),
--                                819-826 (a mod's l10n file goes through modEnv.g_i18n:setText)
-- Bodies copied as they are, except convertText spells string.startsWith (a GIANTS helper) as
-- string.sub, and calls the global instance by name. Stand-ins (no engine proof): I18N.new keeps only texts and
-- modEnvironments; Logging.devWarning is not called (g_showDevelopmentWarnings is off).

FS25I18N = {}

local I18N = {}
local I18N_mt = { __index = I18N }
FS25I18N.class = I18N

function I18N.new()
    local self = setmetatable({}, I18N_mt)
    self.texts = {}
    self.modEnvironments = {}
    return self
end

-- I18N.lua 150-175
function I18N:addModI18N(modName)
    local modi18n = {
        ["texts"] = {}
    }
    setmetatable(modi18n, {
        ["__index"] = self
    })
    setmetatable(modi18n.texts, {
        ["__index"] = self.texts
    })
    self.modEnvironments[modName] = modi18n
    function modi18n.setText(i18nInstance, name, value)
        i18nInstance.texts[name] = value
    end
    function modi18n.hasModText(i18nInstance, name)
        return i18nInstance.texts[name] ~= nil
    end
    function modi18n.setGlobalText(_, name, value)
        name = modName .. "." .. name
        if self.texts[name] == nil then
            self.texts[name] = value
        end
    end
    return modi18n
end

-- I18N.lua 176-194
function I18N:getText(name, customEnv)
    local ret = nil
    if customEnv ~= nil then
        local modEnv = self.modEnvironments[customEnv]
        if modEnv ~= nil then
            ret = modEnv.texts[name]
        end
    end
    if ret == nil then
        ret = self.texts[name]
        if ret == nil then
            ret = string.format("Missing \'%s\' in l10n%s.xml", name, g_languageSuffix)
        end
    end
    return ret
end

-- I18N.lua 195-210
function I18N:hasText(name, customEnv)
    if name == nil then
        return false
    end
    local ret = nil
    if customEnv ~= nil then
        local modEnv = self.modEnvironments[customEnv]
        if modEnv ~= nil then
            ret = modEnv.texts[name]
        end
    end
    if ret == nil then
        ret = self.texts[name]
    end
    local modEnv = ret ~= nil
    return modEnv
end

-- I18N.lua 413-423
function I18N.convertText(_, textOrKey, customEnv)
    if textOrKey ~= nil then
        if string.sub(textOrKey, 1, 6) == "$l10n_" then
            textOrKey = FS25I18N.global:getText(string.sub(textOrKey, 7), customEnv)
        end
        return textOrKey
    end
    return nil
end

-- MoneyType.lua 4-15
local moneyTypeId = 0
function FS25I18N.registerMoneyType(statistic, title, customEnv)
    moneyTypeId = moneyTypeId + 1
    local value = {
        ["id"] = moneyTypeId,
        ["statistic"] = statistic,
        ["title"] = title,
        ["customEnv"] = customEnv
    }
    return value
end

-- HUD.lua 304: the HUD runs in the global environment, so g_i18n there is the global instance.
function FS25I18N.hudMoneyTitle(moneyType)
    return FS25I18N.global:getText(moneyType.title, moneyType.customEnv)
end

--- A fresh global instance; FS25I18N.global is what base-game code calls g_i18n.
function FS25I18N.reset()
    FS25I18N.global = I18N.new()
    return FS25I18N.global
end

--- Register a mod environment the way mods.lua does and fill it from a {name = text} table.
--- @return table the mod's g_i18n
function FS25I18N.addMod(modName, texts)
    local modi18n = FS25I18N.global:addModI18N(modName)
    for name, text in pairs(texts or {}) do modi18n:setText(name, text) end
    return modi18n
end

--- {name = text} from one of this repository's translation files (or any file with the
--- <text name="" text=""/> layout the mod loader reads at mods.lua 819-826).
function FS25I18N.readTranslation(path)
    local handle = assert(io.open(path, "r"))
    local content = handle:read("a")
    handle:close()
    local texts = {}
    for name, text in content:gmatch('<text%s+name="([^"]+)"%s+text="([^"]*)"') do
        if texts[name] == nil then texts[name] = text end
    end
    return texts
end
