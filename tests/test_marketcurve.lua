loadMod("scripts/market/RLMarketCurve.lua")
local C = RLMarketCurve
local curve = {axis = "breedingScore", interpolation = "linear", points = {{x = 1, value = 0.03}, {x = 1.3, value = 0.07}, {x = 1.5, value = 0.10}, {x = 1.75, value = 0.06}}}
check("curve: valid liquidity", C.validate(curve))
check("curve: lower endpoint clamps", C.evaluate(curve, 0.25) == 0.03)
check("curve: upper endpoint clamps", C.evaluate(curve, 2) == 0.06)
check("curve: interpolation independent example", near(C.evaluate(curve, 1.15), 0.05, 1e-12))
check("curve: falling final segment", near(C.evaluate(curve, 1.625), 0.08, 1e-12))
check("curve: exact point", C.evaluate(curve, 1.5) == 0.10)
check("curve: zero monthly probability", C.probability(0, 2) == 0)
check("curve: one monthly probability", C.probability(1, 1) == 1)
check("curve: seasonal pm clamps at one", C.probability(0.75, 2) == 1)
check("curve: seasonal multiplication", near(C.probability(0.1, 0.4), 0.04, 1e-12))
check("curve: invalid raw probability rejected", C.probability(1.1, 1) == nil and C.probability(-0.1, 1) == nil)
check("curve: negative season rejected", C.probability(0.1, -1) == nil)
for _, value in ipairs({math.huge, -math.huge, 0 / 0}) do
    check("curve: rejects non-finite input", C.evaluate(curve, value) == nil and C.probability(value, 1) == nil and C.calendarMonth(value, 3) == nil)
end
local season = {axis = "calendarMonth", interpolation = "linear", points = {}}
for month = 1, 12 do season.points[month] = {x = month, value = month} end
check("curve: full explicit season", C.validate(season) and C.evaluate(season, 3) == 3)
table.remove(season.points, 2)
check("curve: missing season month rejected", not C.validate(season))
check("curve: zero elapsed month retains explicit March origin", C.calendarMonth(0, 3) == 3)
check("curve: within month no advancement", C.calendarMonth(0.99, 3) == 3)
check("curve: December boundary", C.calendarMonth(9.99, 3) == 12)
check("curve: year rollover January", C.calendarMonth(10, 3) == 1)
check("curve: multi-year rollover", C.calendarMonth(34, 3) == 1)
check("curve: explicit January origin", C.calendarMonth(12, 1) == 1)
check("curve: invalid calendar origin", C.calendarMonth(0, 0) == nil and C.calendarMonth(0, 1.5) == nil and C.calendarMonth(0, nil) == nil)
check("curve: invalid elapsed months", C.calendarMonth(-1, 3) == nil)
curve.points[2].x = 1
check("curve: duplicate x rejected", not C.validate(curve))
curve.points[2].x = 1.3; curve.points[2].value = 1.1
check("curve: invalid probability point rejected", not C.validate(curve))
curve.points[2].value = -0.1
check("curve: negative point rejected", not C.validate(curve))
curve.points[2].value = 0.07; curve.interpolation = "cubic"
check("curve: unknown interpolation rejected", not C.validate(curve))
local calls = 0
local malicious = setmetatable({}, {__index = function() calls = calls + 1; error("should not run") end})
local called, ok = pcall(C.validate, malicious)
check("curve: metatable not executed", called and not ok and calls == 0)
