-- Animal rates are month-normalised: changing the season length must not change
-- the displayed monthly inputs/outputs or their settlement over a complete month.
loadMod("scripts/utils/RLAnimalDisplayHelper.lua")
MathUtil = MathUtil or {}
MathUtil.round = function(value, precision)
    local scale = 10 ^ (precision or 0)
    return math.floor(value * scale + 0.5) / scale
end
g_i18n = {
    getText = function(_, key) assert(key == "rl_ui_amountPerMonth"); return "%s L / month" end,
    formatNumber = function(_, value, precision) return string.format("%." .. precision .. "f", value) end,
}
local rates = { food = 250, water = 42, straw = 16, manure = 46,
    liquidManure = 31, wool = 0.6824309184, milk = 800, eggs = 5.2 }
for name, monthly in pairs(rates) do
    local rate = monthly / 24
    local expected = RLAnimalDisplayHelper.formatMonthlyAmount(rate)
    for _, days in ipairs({ 1, 3, 5, 28 }) do
        g_currentMission = { environment = { daysPerPeriod = days, timeAdjustment = 1 / days } }
        local settled = 0
        for hour = 1, days * 24 do settled = settled + rate * g_currentMission.environment.timeAdjustment end
        check(name .. ": month stable at " .. days .. " days", near(settled, monthly, 1e-8)
            and RLAnimalDisplayHelper.formatMonthlyAmount(rate) == expected)
    end
end
check("monthly: fleece keeps two decimals", RLAnimalDisplayHelper.formatMonthlyAmount(0.6824309184 / 24) == "0.68 L / month")
check("monthly: small inputs keep one decimal", RLAnimalDisplayHelper.formatMonthlyAmount(5.24 / 24) == "5.2 L / month")
check("monthly: zero is explicit", RLAnimalDisplayHelper.formatMonthlyAmount(0) == "0 L / month")
check("monthly: large values round", RLAnimalDisplayHelper.formatMonthlyAmount(12.6 / 24) == "13 L / month")
