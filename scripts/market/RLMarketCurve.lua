-- Pure market curves. Calendar conversion consumes explicit elapsed game months,
-- never a game clock; month zero corresponds to the supplied calendar origin.
RLMarketCurve = {}
local C = RLMarketCurve
local finite=RLPlain.finite
function C.validate(curve)
    if type(curve) ~= "table" or getmetatable(curve) ~= nil or curve.interpolation ~= "linear"
        or (curve.axis ~= "breedingScore" and curve.axis ~= "calendarMonth")
        or type(curve.points) ~= "table" or getmetatable(curve.points) ~= nil or #curve.points == 0 then return false, "INVALID_CURVE" end
    local count, last = 0, -math.huge
    for k in pairs(curve.points) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > #curve.points then return false, "INVALID_POINTS" end
        count = count + 1
    end
    if count ~= #curve.points then return false, "INVALID_POINTS" end
    for _, p in ipairs(curve.points) do
        if type(p) ~= "table" or getmetatable(p) ~= nil or not finite(p.x) or not finite(p.value) or p.x <= last or p.value < 0 then return false, "INVALID_POINT" end
        if curve.axis == "breedingScore" and (p.x < 0 or p.value > 1) then return false, "INVALID_PROBABILITY_CURVE" end
        last = p.x
    end
    if curve.axis == "calendarMonth" then
        if #curve.points ~= 12 then return false, "INCOMPLETE_SEASON" end
        for month, p in ipairs(curve.points) do if p.x ~= month then return false, "INCOMPLETE_SEASON" end end
    end
    return true
end
function C.evaluate(curve, x)
    local ok, reason = C.validate(curve)
    if not ok then return nil, reason end
    if not finite(x) then return nil, "INVALID_INPUT" end
    local points = curve.points
    if x <= points[1].x then return points[1].value end
    if x >= points[#points].x then return points[#points].value end
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if x <= b.x then return a.value + (b.value - a.value) * (x - a.x) / (b.x - a.x) end
    end
end
function C.probability(liquidity, season)
    if not finite(liquidity) or liquidity < 0 or liquidity > 1 or not finite(season) or season < 0 then return nil, "INVALID_PROBABILITY_INPUT" end
    local product = liquidity * season
    if not finite(product) then return nil, "INVALID_PROBABILITY_INPUT" end
    return math.min(1, math.max(0, product))
end
function C.calendarMonth(absoluteMonths, originMonth)
    if not finite(absoluteMonths) or absoluteMonths < 0 or not finite(originMonth) or originMonth % 1 ~= 0 or originMonth < 1 or originMonth > 12 then return nil, "INVALID_CALENDAR_INPUT" end
    return ((originMonth - 1 + math.floor(absoluteMonths)) % 12) + 1
end
