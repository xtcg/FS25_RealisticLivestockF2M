-- Formatting regressions through the real message-to-display-row path.
loadMod("scripts/messaging/RLMessage.lua")
loadMod("scripts/gui/rlmenu/services/RLMessageService.lua")
local template
local translations = { rl_cow = "奶牛" }
g_i18n = {
    getText = function(_, key)
        if key:sub(1, 11) == "rl_message_" then return template end
        return translations[key] or key
    end,
    hasText = function(_, key) return translations[key] ~= nil end,
}
local pen = { getName = function() return "北区牛棚" end }
local function expect(name, text, args, expected, id)
    template = text
    local message = { id = id or "MOVED_ANIMALS_SOURCE_MULTIPLE",
        args = args, date = "28/9/2026", uniqueId = 42 }
    local row = RLMessageService.formatMessage(message, pen, 1, 1)
    check(name, row.messageText == expected)
    check(name .. " metadata", row.date == "28/9/2026" and row.husbandryName == "北区牛棚"
        and row.uniqueId == 42 and row.husbandryRef == pen and message.args == args)
end
expect("Chinese purchase", "购买%s头牲畜，花费%s。", {12, "€1,200.00"},
    "购买12头牲畜，花费€1,200.00。", "BOUGHT_ANIMALS_MULTIPLE")
expect("Chinese move", "%s头牲畜已移动至‘%s’。", {12, "南区牛棚"}, "12头牲畜已移动至‘南区牛棚’。")
expect("punctuation and ordering", "%s, moved to '%s'.", {"12", "Barn A"}, "12, moved to 'Barn A'.")
expect("English compatibility", "%s animals were moved to %s", {"12", "Barn A"}, "12 animals were moved to Barn A")
expect("literal percent in names", "%s/%s", {0, "100% %s %1 Barn"}, "0/100% %s %1 Barn")
expect("localized argument", "%s：%s", {"rl_cow", 5}, "奶牛：5")
expect("literal names containing rl_", "%s/%s", {"Carl_rl_barn", "rl_customBarn"}, "Carl_rl_barn/rl_customBarn")
expect("missing arguments", "[%s][%s]", nil, "[][]")
expect("sparse arguments", "[%s][%s]", {[2] = "Barn"}, "[][Barn]")
expect("preserve whitespace", "  %s\n\t'%s'  ", {2, "Barn"}, "  2\n\t'Barn'  ")
