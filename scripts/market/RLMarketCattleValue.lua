-- Objective-specific raw reference cash flows. No alpha/rho, excellence gate,
-- old price floors, Dealer spread, implicit milk prices or live animal methods.
RLMarketCattleValue = {}
local V = RLMarketCommodityValue
function RLMarketCattleValue.evaluate(snapshot, objective, input)
    local p, score = V.parameters(snapshot, objective, input, "COW")
    if not p then return nil, score end
    if objective ~= "DAIRY" and objective ~= "TERMINAL" and objective ~= "MATERNAL" then return nil, "UNSUPPORTED_OBJECTIVE" end
    if objective == "DAIRY" and not snapshot.traitCapabilities.milkProductivity then return nil, "NO_DAIRY_CAPABILITY" end
    local perChild, why = V.offspringDelta(snapshot.genes, input, objective)
    if perChild == nil then return nil, why end
    if snapshot.gender == "male" then
        for _, key in ipairs({ "sireFemalesPerSeason", "sireSeasons", "sireConception", "standardSireReference" }) do
            if not V.nonnegative(p[key]) then return nil, "MISSING_CATTLE_" .. key end
        end
        if p.sireSeasons > 20 or p.sireSeasons % 1 ~= 0 or p.sireConception > 1 then return nil, "INVALID_SIRE_PARAMETERS" end
        local calves = 0
        for season = 0, p.sireSeasons - 1 do
            local t = math.max(p.minBreedingAge - snapshot.ageMonths, 0) + 12 * season
            if snapshot.ageMonths + t >= p.exitAge then break end
            calves = calves + p.sireFemalesPerSeason * p.sireConception * V.weight(t + p.gestationMonths, snapshot.genes, p)
        end
        local hered = calves * perChild
        return V.result(p.standardSireReference + hered, 0, hered, score, { expectedCalves = calves, ownMilk = 0 })
    end
    local standard = { health = 1, fertility = 1, productivity = 1 }
    local function pv(genes, includeHered)
        local events, err = V.events(snapshot, input, genes)
        if not events then return nil, err end
        local amount, hered, existingValue = 0, 0, 0
        for _, event in ipairs(events) do
            local child = p.offspringBaseNet
            local litter = 1
            if event.existing then
                local known = input.existingFetusNetValues
                if not V.dense(known) or #known ~= #snapshot.reproductive.pregnancy.pregnancies then return nil, "MISSING_FETUS_REFERENCE" end
                child, litter = 0, 1
                for _, value in ipairs(known) do if not V.nonnegative(value) then return nil, "INVALID_FETUS_REFERENCE" end; child = child + value end
            end
            local weight = V.weight(event.time, genes, p)
            amount = amount + weight * child * litter
            if event.existing then existingValue = existingValue + weight * child
            elseif includeHered then hered = hered + weight * perChild end
        end
        if objective == "DAIRY" then
            if not V.nonnegative(genes.productivity) or not V.dense(input.lactationNetByMonth) or #input.lactationNetByMonth == 0
                or not V.dense(input.lactationIncrementNetByMonth) or #input.lactationIncrementNetByMonth ~= #input.lactationNetByMonth then return nil, "MISSING_MILK_REFERENCE" end
            local function lactation(start, from, parity, untilTime)
                local factor = input.parityFactors and input.parityFactors[parity]
                if not V.nonnegative(factor) then return nil end
                for month = from, #input.lactationNetByMonth - 1 do
                    local baseNet = input.lactationNetByMonth[month + 1]
                    local incrementNet = input.lactationIncrementNetByMonth[month + 1]
                    if not V.finite(baseNet) or not V.finite(incrementNet) then return nil end
                    local net = baseNet + (genes.productivity - 1) * incrementNet
                    local t = start + month - from + 0.5
                    if snapshot.ageMonths + t <= p.exitAge and (untilTime == nil or t < untilTime) then amount = amount + V.weight(t, genes, p) * net * factor end
                end
                return true
            end
            if snapshot.reproductive.lactating then
                local since = snapshot.reproductive.monthsSinceLastBirth
                if not V.nonnegative(since) or not lactation(0, math.floor(since), snapshot.reproductive.parity, events[1] and events[1].time) then return nil, "MISSING_LACTATION_STATE" end
            end
            for index, event in ipairs(events) do
                if not lactation(event.time, 0, snapshot.reproductive.parity + index, events[index + 1] and events[index + 1].time) then return nil, "MISSING_PARITY_REFERENCE" end
            end
        end
        return { own = amount, hered = hered, existing = existingValue, births = #events }
    end
    local base, err = pv(standard, false)
    if not base then return nil, err end
    local actual; actual, err = pv(snapshot.genes, true)
    if not actual then return nil, err end
    return V.result(actual.own + actual.hered, actual.own - base.own, actual.hered, score,
        { standardPV = base.own, ownPV = actual.own, existingFetusValue = actual.existing, futureBirths = actual.births })
end
