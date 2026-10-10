--[[
    RLGrowthCurve.lua
    A continuous growth curve through (month, kg) knots: monotone cubic Hermite interpolation
    (Fritsch-Butland). Pure: no engine globals, no randomness.

    Slopes. Each interior knot takes the weighted harmonic mean of its two neighbouring secants
    (weights 2h_i + h_{i-1} and h_i + 2h_{i-1}), or 0 where the secants change sign or one is
    flat; the first knot takes its secant; the last knot (maturity) takes 0, and the curve is
    flat after it. Weight and its first derivative are continuous at every knot, and the curve
    never overshoots its knots: with non-decreasing knots it never decreases.

    Used by RLGrowth for each weight profile's reference curve and each animal's own curve
    (scaled by its size gene, its actual birth weight faded in over the first months).
]]

RLGrowthCurve = {}

local Curve = {}
Curve.__index = Curve


--- Smooth fade from 1 at x <= 0 to 0 at x >= 1: 1 - 3x^2 + 2x^3.
--- @param x number
--- @return number
function RLGrowthCurve.fade(x)
    if x <= 0 then return 1 end
    if x >= 1 then return 0 end
    return 1 - 3 * x * x + 2 * x * x * x
end


--- Check knots: at least two, months strictly increasing from 0, finite kg >= 0, kg never
--- decreasing.
--- @param knots table { {month, kg}, ... }
--- @return boolean ok
--- @return string|nil reason
function RLGrowthCurve.validate(knots)
    if type(knots) ~= "table" or #knots < 2 then return false, "needs at least two knots" end
    for i, knot in ipairs(knots) do
        local t, w = knot[1], knot[2]
        if type(t) ~= "number" or type(w) ~= "number" or t ~= t or w ~= w or w < 0
            or t == math.huge or w == math.huge then
            return false, string.format("knot %d is not a finite number >= 0", i)
        end
        if i == 1 and t ~= 0 then return false, "the first knot must be at month 0" end
        if i > 1 then
            if t <= knots[i - 1][1] then return false, string.format("knot %d: months must increase", i) end
            if w < knots[i - 1][2] then return false, string.format("knot %d: kg must not decrease", i) end
        end
    end
    return true
end


--- Build a curve. The knots are copied.
--- @param knots table { {month, kg}, ... } valid (RLGrowthCurve.validate)
--- @return table curve
function RLGrowthCurve.new(knots)
    local n = #knots
    local t, w, h, d, s = {}, {}, {}, {}, {}
    for i = 1, n do t[i], w[i] = knots[i][1], knots[i][2] end
    for i = 1, n - 1 do
        h[i] = t[i + 1] - t[i]
        d[i] = (w[i + 1] - w[i]) / h[i]
    end

    s[1] = d[1]
    for i = 2, n - 1 do
        if d[i - 1] * d[i] <= 0 then
            s[i] = 0
        else
            local w1, w2 = 2 * h[i] + h[i - 1], h[i] + 2 * h[i - 1]
            s[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
        end
    end
    s[n] = 0

    return setmetatable({ t = t, w = w, h = h, s = s, n = n, endMonth = t[n], endWeight = w[n],
        startWeight = w[1] }, Curve)
end


--- Segment index i with t[i] <= x < t[i + 1] (x inside the knots).
local function segment(self, x)
    local lo, hi = 1, self.n - 1
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if self.t[mid] <= x then lo = mid else hi = mid - 1 end
    end
    return lo
end


--- Weight at month x: the first knot's before it, the last knot's after it.
--- @param x number Months
--- @return number kg
function Curve:value(x)
    if x <= self.t[1] then return self.w[1] end
    if x >= self.t[self.n] then return self.w[self.n] end
    local i = segment(self, x)
    local h = self.h[i]
    local u = (x - self.t[i]) / h
    local u2, u3 = u * u, u * u * u
    return (2 * u3 - 3 * u2 + 1) * self.w[i] + (u3 - 2 * u2 + u) * h * self.s[i]
        + (-2 * u3 + 3 * u2) * self.w[i + 1] + (u3 - u2) * h * self.s[i + 1]
end


--- Gain per month at month x (the derivative): 0 before the first knot and after the last.
--- @param x number Months
--- @return number kg per month
function Curve:slope(x)
    if x < self.t[1] or x >= self.t[self.n] then return 0 end
    local i = segment(self, x)
    local h = self.h[i]
    local u = (x - self.t[i]) / h
    local u2 = u * u
    return ((6 * u2 - 6 * u) * self.w[i] + (3 * u2 - 4 * u + 1) * h * self.s[i]
        + (-6 * u2 + 6 * u) * self.w[i + 1] + (3 * u2 - 2 * u) * h * self.s[i + 1]) / h
end


--- The earliest month at which the curve reaches `weight` (bisection): 0 at or below the first
--- knot's weight, endMonth at or above the last knot's.
--- @param weight number kg
--- @return number months
function Curve:inverse(weight)
    if weight <= self.w[1] then return self.t[1] end
    if weight >= self.w[self.n] then return self.t[self.n] end

    -- The segment holding the weight, then bisection inside it (the curve is monotone).
    local i = 1
    while i < self.n - 1 and self.w[i + 1] < weight do i = i + 1 end
    local lo, hi = self.t[i], self.t[i + 1]
    for _ = 1, 48 do
        local mid = (lo + hi) / 2
        if self:value(mid) < weight then lo = mid else hi = mid end
    end
    return (lo + hi) / 2
end


--- The knots as a new list (for reports).
--- @return table { {month, kg}, ... }
function Curve:getKnots()
    local knots = {}
    for i = 1, self.n do knots[i] = { self.t[i], self.w[i] } end
    return knots
end
