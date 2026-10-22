-- Sheep-only seasonal lambs and real wool. No implicit goat or dairy mapping.
RLMarketSheepValue = {}
local V = RLMarketCommodityValue
function RLMarketSheepValue.evaluate(snapshot, objective, input)
    if type(snapshot) ~= "table" or type(input) ~= "table" or type(snapshot.traitCapabilities) ~= "table" then return nil, "PRODUCTION_UNSUPPORTED" end
    local dairy = objective == "DAIRY"
    if dairy and (not snapshot.traitCapabilities.milkProductivity or type(input.dairyCapability) ~= "table"
        or input.dairyCapability.speciesKey ~= "SHEEP" or input.dairyCapability.milkOutputVerified ~= true
        or input.dairyCapability.traitMappingRevision ~= snapshot.traitMappingRevision) then
        return nil, "SHEEP_DAIRY_PROVIDER_UNSUPPORTED"
    end
    if objective ~= "DAIRY" and objective ~= "TERMINAL" and objective ~= "MATERNAL" then return nil, "SHEEP_OBJECTIVE_UNSUPPORTED" end
    local p, score = V.parameters(snapshot, objective, input, "SHEEP")
    if not p then return nil, score end
    if not V.nonnegative(p.expectedLitter) or not V.nonnegative(p.lambSurvival) or p.lambSurvival > 1
        or type(input.breedingSeason) ~= "table" or type(input.woolNetByMonth) ~= "table"
        or not V.nonnegative(input.calendarMonth) or input.calendarMonth < 1 or input.calendarMonth > 12 or input.calendarMonth % 1 ~= 0 then return nil, "MISSING_SHEEP_PARAMETERS" end
    for month = 1, 12 do
        if type(input.breedingSeason[month]) ~= "boolean" or not V.finite(input.woolNetByMonth[month]) then return nil, "MISSING_SHEEP_SEASON" end
    end
    if not dairy and (((input.weights[objective] or {}).productivity or 0) ~= 0 or ((input.offspringDeltaPerGene and input.offspringDeltaPerGene[objective] or {}).productivity or 0) ~= 0) then return nil, "WOOL_IS_NOT_MATERNAL_GENETICS" end
    local delta, why = V.offspringDelta(snapshot.genes, input, objective)
    if delta == nil then return nil, why end
    local function seasonTime(time)
        for offset = 0, 12 do
            local month = (input.calendarMonth - 1 + math.floor(time) + offset) % 12 + 1
            if input.breedingSeason[month] then return time + offset end
        end
    end
    if snapshot.gender == "male" then
        for _, name in ipairs({ "sireEwesPerSeason", "sireSeasons", "sireConception", "standardSireReference" }) do
            if not V.nonnegative(p[name]) then return nil, "MISSING_SHEEP_" .. name end
        end
        if p.sireSeasons > 20 or p.sireSeasons % 1 ~= 0 or p.sireConception > 1 then return nil, "INVALID_SHEEP_SIRE_PARAMETERS" end
        local lambs = 0
        for index = 0, p.sireSeasons - 1 do
            local t = seasonTime(math.max(p.minBreedingAge - snapshot.ageMonths, 0) + index * 12)
            if t == nil then return nil, "NO_SHEEP_BREEDING_SEASON" end
            if snapshot.ageMonths + t >= p.exitAge then break end
            lambs = lambs + p.sireEwesPerSeason * p.sireConception * p.expectedLitter * p.lambSurvival * V.weight(t + p.gestationMonths, snapshot.genes, p)
        end
        return V.result(p.standardSireReference + lambs * delta, 0, lambs * delta, score, { expectedLambs = lambs, ownMilk = 0 })
    end
    local function pv(genes, includeHered)
        local initial, err = V.events(snapshot, input, genes)
        if not initial then return nil, err end
        local own, hered, births, previous = 0, 0, 0, nil
        local birthEvents = {}
        for index, event in ipairs(initial) do
            local t = previous and previous + p.recoveryMonths + p.openMonths / genes.fertility + p.gestationMonths or event.time
            if not event.existing then
                local conception = seasonTime(math.max(0, t - p.gestationMonths))
                if conception == nil then return nil, "NO_SHEEP_BREEDING_SEASON" end
                t = conception + p.gestationMonths
            end
            if not event.existing and snapshot.ageMonths + t > p.exitAge then break end
            previous, births = t, births + 1
            birthEvents[#birthEvents + 1] = t
            local litter, per = p.expectedLitter * p.lambSurvival, p.offspringBaseNet
            if event.existing then
                local known = input.existingFetusNetValues
                if not V.dense(known) or #known ~= #snapshot.reproductive.pregnancy.pregnancies then return nil, "MISSING_FETUS_REFERENCE" end
                litter, per = 1, 0
                for _, value in ipairs(known) do if not V.nonnegative(value) then return nil, "INVALID_FETUS_REFERENCE" end; per = per + value end
            end
            local weight = V.weight(t, genes, p)
            own = own + weight * litter * per
            if not event.existing and includeHered then hered = hered + weight * litter * delta end
        end
        local wool = 0
        for month = 0, math.min(240, math.floor(p.exitAge - snapshot.ageMonths)) - 1 do
            local amount = input.woolNetByMonth[(input.calendarMonth + month - 1) % 12 + 1]
            if amount ~= 0 then
                if not snapshot.traitCapabilities.woolProductivity or not V.nonnegative(genes.productivity) then return nil, "MISSING_WOOL_CAPABILITY" end
                wool = wool + V.weight(month + 0.5, genes, p) * amount * genes.productivity
            end
        end
        local milk = 0
        if dairy then
            if not V.nonnegative(genes.productivity) or not V.dense(input.lactationNetByMonth) or #input.lactationNetByMonth == 0
                or not V.dense(input.lactationIncrementNetByMonth) or #input.lactationIncrementNetByMonth ~= #input.lactationNetByMonth then return nil, "MISSING_SHEEP_MILK_REFERENCE" end
            local function lactation(start, from, parity, untilTime)
                local factor = input.parityFactors and input.parityFactors[parity]
                if not V.nonnegative(factor) then return nil end
                for month = from, #input.lactationNetByMonth - 1 do
                    local base, increment = input.lactationNetByMonth[month + 1], input.lactationIncrementNetByMonth[month + 1]
                    if not V.finite(base) or not V.finite(increment) then return nil end
                    local t = start + month - from + 0.5
                    if snapshot.ageMonths + t <= p.exitAge and (untilTime == nil or t < untilTime) then
                        milk = milk + V.weight(t, genes, p) * (base + (genes.productivity - 1) * increment) * factor
                    end
                end
                return true
            end
            if snapshot.reproductive.lactating then
                local since = snapshot.reproductive.monthsSinceLastBirth
                if not V.nonnegative(since) or not lactation(0, math.floor(since), snapshot.reproductive.parity, birthEvents[1]) then return nil, "MISSING_SHEEP_LACTATION_STATE" end
            end
            for index, time in ipairs(birthEvents) do
                if not lactation(time, 0, snapshot.reproductive.parity + index, birthEvents[index + 1]) then return nil, "MISSING_SHEEP_PARITY_REFERENCE" end
            end
        end
        return { own = own + wool + milk, hered = hered, wool = wool, milk = milk, births = births }
    end
    local base, err = pv({ fertility = 1, health = 1, productivity = 1 }, false)
    if not base then return nil, err end
    local actual; actual, err = pv(snapshot.genes, true)
    if not actual then return nil, err end
    return V.result(actual.own + actual.hered, actual.own - base.own, actual.hered, score,
        { standardPV = base.own, ownPV = actual.own, woolPV = actual.wool, milkPV = actual.milk, births = actual.births })
end
