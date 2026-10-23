-- Pig-only litter production, with explicit pig service scale and life limits.
RLMarketPigValue = {}
local V = RLMarketCommodityValue
function RLMarketPigValue.evaluate(snapshot, objective, input)
    if objective ~= "TERMINAL" and objective ~= "MATERNAL" then return nil, "PIG_OBJECTIVE_UNSUPPORTED" end
    local p, score = V.parameters(snapshot, objective, input, "PIG")
    if not p then return nil, score end
    if not V.nonnegative(p.expectedLitter) or not V.nonnegative(p.pigletSurvival) or p.pigletSurvival > 1 then return nil, "MISSING_PIG_LITTER_PARAMETERS" end
    if (input.weights[objective].productivity or 0) ~= 0 or ((input.offspringDeltaPerGene and input.offspringDeltaPerGene[objective] or {}).productivity or 0) ~= 0 then return nil, "PIG_PRODUCTIVITY_MAPPING_UNSUPPORTED" end
    local delta, why = V.offspringDelta(snapshot.genes, input, objective)
    if delta == nil then return nil, why end
    if snapshot.gender == "male" then
        for _, name in ipairs({ "sireLittersPerYear", "sireYears", "sireConception", "standardSireReference" }) do
            if not V.nonnegative(p[name]) then return nil, "MISSING_PIG_" .. name end
        end
        if p.sireYears > 20 or p.sireYears % 1 ~= 0 or p.sireConception > 1 then return nil, "INVALID_PIG_SIRE_PARAMETERS" end
        local piglets = 0
        for year = 0, p.sireYears - 1 do
            local t = math.max(p.minBreedingAge - snapshot.ageMonths, 0) + year * 12
            if snapshot.ageMonths + t >= p.exitAge then break end
            piglets = piglets + p.sireLittersPerYear * p.sireConception * p.expectedLitter * p.pigletSurvival * V.weight(t + p.gestationMonths, snapshot.genes, p)
        end
        return V.result(p.standardSireReference + piglets * delta, 0, piglets * delta, score, { expectedPiglets = piglets, ownLitters = 0 })
    end
    local function pv(genes, hered)
        local events, err = V.events(snapshot, input, genes)
        if not events then return nil, err end
        local own, gain, knownValue = 0, 0, 0
        for _, event in ipairs(events) do
            local litter, per = p.expectedLitter * p.pigletSurvival, p.offspringBaseNet
            if event.existing then
                local known = input.existingFetusNetValues
                if not V.dense(known) or #known ~= #snapshot.reproductive.pregnancy.pregnancies then return nil, "MISSING_FETUS_REFERENCE" end
                litter, per = 1, 0
                for _, value in ipairs(known) do if not V.nonnegative(value) then return nil, "INVALID_FETUS_REFERENCE" end; per = per + value end
            end
            local weight = V.weight(event.time, genes, p)
            own = own + weight * litter * per
            if event.existing then knownValue = knownValue + weight * per
            elseif hered then gain = gain + weight * litter * delta end
        end
        return { own = own, hered = gain, existing = knownValue }
    end
    local baseline, err = pv({ fertility = 1, health = 1 }, false)
    if not baseline then return nil, err end
    local actual; actual, err = pv(snapshot.genes, true)
    if not actual then return nil, err end
    return V.result(actual.own + actual.hered, actual.own - baseline.own, actual.hered, score,
        { standardPV = baseline.own, ownPV = actual.own, existingFetusValue = actual.existing, ownMilk = 0 })
end
