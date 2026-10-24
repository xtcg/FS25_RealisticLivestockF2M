-- Expected values only: no RNG, game time, animals or public-order liquidity.
RLMarketMath = {}
local M = RLMarketMath
local function finite(n) return type(n) == "number" and n == n and math.abs(n) ~= math.huge end
function M.waiting(input)
    if type(input) ~= "table" or not finite(input.months) or input.months < 0
        or input.months % 1 ~= 0 or input.months > 120
        or not finite(input.resale) or input.resale < 0 or not finite(input.liquidation) or input.liquidation < 0 then
        return nil, "INVALID_WAITING_INPUT"
    end
    local function series(value, probability)
        if type(value) ~= "table" then
            return finite(value) and value >= 0 and (not probability or value <= 1)
        end
        local count = 0
        for key, n in pairs(value) do
            if not finite(key) or key % 1 ~= 0 or key < 1 or key > input.months
                or not finite(n) or n < 0 or (probability and n > 1) then return false end
            count = count + 1
        end
        return count == input.months
    end
    if not series(input.probability, true) or not series(input.monthlyCost, false) then
        return nil, "INVALID_MONTHLY_INPUT"
    end
    local survival, revenue, cost, months = 1, 0, 0, 0
    local rows = {}
    for k = 1, input.months do
        local p = type(input.probability) == "table" and input.probability[k] or input.probability
        local c = type(input.monthlyCost) == "table" and input.monthlyCost[k] or input.monthlyCost
        if not finite(p) or p < 0 or p > 1 or not finite(c) or c < 0 then return nil, "INVALID_MONTHLY_INPUT" end
        local sold = survival * p
        months, cost, revenue = months + survival, cost + survival * c, revenue + sold * input.resale
        rows[k] = { month = k, survivalBefore = survival, probability = p, soldProbability = sold,
            expectedRevenue = sold * input.resale, expectedCost = survival * c }
        survival = survival * (1 - p)
    end
    revenue = revenue + survival * input.liquidation
    if not finite(revenue) or not finite(cost) then return nil, "VALUE_OVERFLOW" end
    return { saleProbability = 1 - survival, survival = survival, expectedMonths = months,
        expectedRevenue = revenue, expectedHoldingCost = cost, months = rows }
end
function M.fixed(resale, liquidation, probability, months, monthlyCost)
    -- Validate even H=0, where there is no loop to validate these fields.
    if not finite(probability) or probability < 0 or probability > 1 or not finite(monthlyCost) or monthlyCost < 0 then
        return nil, "INVALID_MONTHLY_INPUT"
    end
    return M.waiting({ resale = resale, liquidation = liquidation, probability = probability,
        months = months, monthlyCost = monthlyCost })
end
function M.seasonal(resale, liquidation, probability, months, monthlyCost, calendarMonth, season)
    if not finite(calendarMonth) or calendarMonth % 1 ~= 0 or calendarMonth < 1 or calendarMonth > 12
        or type(season) ~= "table" or not finite(probability) or probability < 0 or probability > 1 then
        return nil, "INVALID_SEASON"
    end
    for month = 1, 12 do if not finite(season[month]) or season[month] < 0 then return nil, "INVALID_SEASON" end end
    if not finite(months) or months < 0 or months % 1 ~= 0 or months > 120 then return nil, "INVALID_MONTHS" end
    local probabilities = {}
    for k = 1, months do probabilities[k] = math.min(1, probability * season[(calendarMonth + k - 2) % 12 + 1]) end
    return M.waiting({ resale = resale, liquidation = liquidation, probability = probabilities,
        months = months, monthlyCost = monthlyCost })
end
