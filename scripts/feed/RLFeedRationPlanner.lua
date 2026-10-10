--[[
    RLFeedRationPlanner.lua
    One feeding of a pen in the real-equivalent mode, pure: what each animal plans to eat, what the
    pen takes from its stock and what each animal ends up with. No engine globals; RLFeed builds
    the request from the pen and its animals and removes the liters this returns.

    Order, per feeding:
    1. Milk. A calf on milk plans milkMax of its appetite, capped by its real milk allowance;
       the pen's milk is taken in feed order and shared by plan.
    2. Ration. Each animal's ration is the pen's forage (complete rations and forages, taken in feed
       order, so the forage the pen will actually eat sets its quality) and, for an animal past
       weaning, the pen's concentrate at share c of the DM:
           c = min(the pen's target share (none: as much as allowed),
                   what keeps the ration's effective fibre, starch + sugar and wheat in bounds,
                   what the animal's rumen is adapted to + stepAllowance)
       and less in step when the concentrate in stock cannot cover every animal's share. Its intake
       is the least of its appetite, what the ration's bulk lets it eat (NDF fill) and - when it
       eats for a target rather than freely - its energy demand over the ration's ME.
       This is worked out twice: first on the forage the stock would give for the animals'
       appetites, then on the forage their planned intake actually takes.
    3. Forage is taken; when it runs short every animal gets the same share of its plan.
    4. Concentrate is taken, at most what each animal's forage eaten keeps within its share (no
       concentrate without roughage: what is not eaten stays in the trough), wheat at most
       wheatMaxShare of the pen's ration.
    5. Each animal's DM, ME and crude protein from what it got; liters per fill type by its share of
       each feed taken.
    A shortage is never made up by valuing the rest higher: what was not eaten carries nothing.
]]

RLFeedRationPlanner = {}


--- Take kg DM from a stock list in order (each entry { name, profile, availableKg }, entries'
--- usedKg counted when `commit`), each name at most caps[name].
--- @return table taken name -> kg
--- @return number total kg
--- @return table parts { { profile, kg }, ... }
function RLFeedRationPlanner.takeSerial(list, needKg, caps, commit)
    local taken, total, parts, left = {}, 0, {}, math.max(needKg or 0, 0)
    for _, entry in ipairs(list) do
        if left <= 0 then break end
        local available = math.max(entry.availableKg - (entry.usedKg or 0), 0)
        local cap = caps ~= nil and caps[entry.name] or nil
        if cap ~= nil then available = math.min(available, math.max(cap - (taken[entry.name] or 0), 0)) end
        local kg = math.min(left, available)
        if kg > 0 then
            taken[entry.name] = (taken[entry.name] or 0) + kg
            total, left = total + kg, left - kg
            table.insert(parts, { entry.profile, kg })
            if commit then entry.usedKg = (entry.usedKg or 0) + kg end
        end
    end
    return taken, total, parts
end


local function availableKg(list)
    local total = 0
    for _, entry in ipairs(list) do total = total + math.max(entry.availableKg - (entry.usedKg or 0), 0) end
    return total
end


--- A concentrate mix as the stock would give it for `needKg`, and wheat's share of it.
local function concentrateMix(list, needKg, wheatCapKg)
    local _, total, parts = RLFeedRationPlanner.takeSerial(list, needKg, { WHEAT = wheatCapKg }, false)
    local mix = RLFeedMath.compose(parts)
    return mix, mix ~= nil and (mix.shares.WHEAT or 0) or 0, total
end


--- What an animal would eat and gain from at concentrate share c: its intake (appetite, the
--- ration's bulk, and - for GROW and MAINTAIN - its energy demand, protein-limited production
--- counted only as far as the protein allows), and a score of the production it buys: growth and
--- milk as the protein allows, plus half the reserve it can lay down.
--- @return table|nil { c, kg, limit, score, me (per kg, as the animal uses it) }
local function evaluate(a, c, forageMix, concMix, request)
    local util = RLFeedMath.getUtilisation(c, a.adapted, request.ration)
    local concEff = concMix
    if concMix ~= nil and util < 1 then
        concEff = { me = concMix.me * util, cp = concMix.cp, ndf = concMix.ndf, peNdf = concMix.peNdf,
            fermentable = concMix.fermentable, starch = concMix.starch }
    end
    local mix = RLFeedMath.blend(forageMix, concEff, c)
    if mix == nil or forageMix == nil then return nil end

    local dt = request.dtDays
    local cap = a.appetite * dt
    if a.milkMax ~= nil and a.milkMax > 0 then
        cap = math.max(math.min((a.solidMax or 1) * a.appetite * dt, a.appetite * dt - a.milkKg), 0)
    end
    local me = mix.me * (a.solidEnergy or 1)
    local needs = a.needs or {}
    local maintenance = (needs.maintenance or 0) + (needs.pregnancy or 0)
    local production = (needs.growth or 0) + (needs.milk or 0)
    local protein = RLFeedMath.getProteinFactor(mix.cp, a.proteinNeed or 0, request.proteinMaintenance or 0)

    local demandStep
    if a.target == "GROW" then
        demandStep = (maintenance + protein * production + (needs.deposit or 0)) * dt
    elseif a.target == "MAINTAIN" then
        demandStep = maintenance * dt
    end
    if demandStep ~= nil then demandStep = math.max(demandStep - a.milkKg * (a.milkME or 0), 0) end
    local kg, limit = RLFeedMath.getIntake(cap, a.fill * dt, { me = me, ndf = mix.ndf }, demandStep)

    local energy = dt > 0 and (kg * me + a.milkKg * (a.milkME or 0)) / dt - maintenance or 0
    local paid = protein * math.min(math.max(energy, 0), production)
    local laid = math.min(math.max(energy - paid, 0), needs.deposit or 0)
    return { c = c, kg = kg, limit = limit, score = paid + 0.5 * laid, me = me, util = util }
end


--- Concentrate shares tried for AUTO: 0 to the limit in steps of AUTO_STEP, and the limit.
RLFeedRationPlanner.AUTO_STEP = 0.05


--- One animal's plan on these mixes. The share c is chosen, then held where the rumen is:
---   the pen's target share, within what keeps fibre, starch + sugar and wheat in bounds; without
---   a target (AUTO), the share in that range that buys the most production for a fully adapted
---   animal (on a coarse grid, AUTO_STEP); more grain is not always more: it dilutes protein and,
---   eaten to a demand, need not add energy;
---   then at most what the animal's rumen is adapted to (continuous, so the step-up is the same
---   at any hour length), and less in step when the stock cannot cover every animal's share.
local function planAnimal(a, forageMix, concMix, wheatShare, concScale, request, estimate)
    local ration = request.ration
    local c, limit = 0, nil
    if a.concEligible and concMix ~= nil then
        local cLimit, why = RLFeedMath.getConcentrateLimit(forageMix, concMix, request.classes[a.class], wheatShare,
            ration.wheatMaxShare)
        c, limit = cLimit, why
        if request.share ~= nil then
            if request.share < c then c, limit = request.share, "TARGET" end
        elseif c > 0 and not estimate then
            -- The best-scoring share on the AUTO_STEP grid for a fully adapted animal: a coarse
            -- choice, steady from hour to hour while the scores barely move.
            local adapted = a.adapted
            a.adapted = 1
            local best, g = nil, 0
            while true do
                local option = evaluate(a, math.min(g, cLimit), forageMix, concMix, request)
                if option ~= nil and (best == nil or option.score > best.score + 1e-9) then best = option end
                if g >= cLimit then break end
                g = g + RLFeedRationPlanner.AUTO_STEP
            end
            a.adapted = adapted
            if best ~= nil and best.c < c - 1e-9 then c, limit = best.c, "PROTEIN_OR_DEMAND" end
        end
        local adaptedLimit = RLFeedMath.getAdaptedLimit(a.adapted, ration, request.dtDays)
        if adaptedLimit < c then c, limit = adaptedLimit, "ADAPTATION" end
        if concScale < 1 then c, limit = c * concScale, "STOCK" end
    elseif a.concEligible and request.concentrateWanted then
        limit = "NO_CONCENTRATE"
    end

    local best = evaluate(a, c, forageMix, concMix, request)
    a.forageKg, a.concKg = 0, 0
    if best == nil then
        a.c, a.concLimit, a.util, a.intakeLimit, a.solidMe = 0, limit, 1, "NO_FEED", 0
        return
    end
    a.c, a.concLimit, a.util, a.intakeLimit, a.solidMe = best.c, limit, best.util, best.limit, best.me
    a.forageKg = best.kg * (1 - best.c)
    a.concKg = best.kg * best.c
end


--- An animal's totals from its byFill: kg DM, ME, crude protein share. Run again after a fill
--- type's liters are scaled to what was actually removed.
--- @param a table
function RLFeedRationPlanner.sumAnimal(a)
    local kg, me, cpKg = 0, 0, 0
    for _, fill in pairs(a.byFill) do kg, me, cpKg = kg + fill.kg, me + fill.me, cpKg + fill.cpKg end
    a.kg, a.me = kg, me
    a.cp = kg > 0 and cpKg / kg or 0
end


--- Plan and share one feeding.
--- @param request table {
---     animals = { { appetite (kg DM/day), fill (kg NDF/day), class, stage (PRE_WEANING, WEANING,
---                   WEANED: the feeds it may eat), target (FINISH eats freely, GROW for its needs,
---                   MAINTAIN for maintenance and pregnancy), concEligible, adapted,
---                   needs = { maintenance, pregnancy, growth, milk, deposit } (MJ/day), proteinNeed,
---                   milkMax, milkMaxKgPerDay (real-equivalent DM ceiling), solidMax, solidEnergy }, ... },
---     forage, concentrate, milk = { { name, profile, liters }, ... } in the order they are taken,
---     scale, realDaysPerPeriod, dtDays, share (nil: AUTO), ration, classes, proteinMaintenance,
---     concentrateWanted (the pen offers concentrate) }
--- @return table { withdraw = { name -> liters }, plannedMe, eatenMe, plannedKg, eatenKg,
---     forageMix, concentrateMix, milkMix, animals (the request's, filled in: plannedKg, plannedMe,
---     litersPerPeriod, plannedByFill (liters a month), kg, me, cp, c, byFill = { name -> { kg,
---     liters, me, cpKg } }, limits) }
--- Feeding stages in the order their groups take from the shared stock.
RLFeedRationPlanner.STAGES = { "PRE_WEANING", "WEANING", "WEANED" }


--- The entries of a stock list a feeding stage may eat (the feed profile's stages).
local function forStage(list, stage)
    local out = {}
    for _, entry in ipairs(list) do
        if entry.profile.stages == nil or entry.profile.stages[stage] then out[#out + 1] = entry end
    end
    return out
end


function RLFeedRationPlanner.plan(request)
    local scale, dt = request.scale, request.dtDays
    local profiles = {}
    for _, list in ipairs({ request.forage, request.concentrate, request.milk }) do
        for _, entry in ipairs(list) do
            profiles[entry.name] = entry.profile
            entry.availableKg = RLFeedUnits.litersToKg(math.max(entry.liters or 0, 0), scale, entry.profile.density, entry.profile.dm)
            entry.usedKg = 0
        end
    end

    -- The animals by feeding stage: each eats only the feeds its stage may have (a feed's
    -- stages), from the one stock all groups share.
    local groups, byStage = {}, {}
    for _, a in ipairs(request.animals) do
        local stage = a.stage or "WEANED"
        local group = byStage[stage]
        if group == nil then
            group = { stage = stage, animals = {}, forage = forStage(request.forage, stage),
                concentrate = forStage(request.concentrate, stage), milk = forStage(request.milk, stage) }
            byStage[stage] = group
        end
        table.insert(group.animals, a)
    end
    for _, stage in ipairs(RLFeedRationPlanner.STAGES) do
        if byStage[stage] ~= nil then groups[#groups + 1] = byStage[stage]; byStage[stage] = nil end
    end
    local others = {}
    for stage in pairs(byStage) do others[#others + 1] = stage end
    table.sort(others)
    for _, stage in ipairs(others) do groups[#groups + 1] = byStage[stage] end

    -- 1. Milk for calves.
    for _, group in ipairs(groups) do
        local need = 0
        for _, a in ipairs(group.animals) do
            a.milkPlanKg = (a.milkMax ~= nil and a.milkMax > 0) and math.min(a.milkMax, 1) * a.appetite * dt or 0
            if a.milkMaxKgPerDay ~= nil then
                a.milkPlanKg = math.min(a.milkPlanKg, math.max(a.milkMaxKgPerDay, 0) * dt)
            end
            need = need + a.milkPlanKg
        end
        local parts
        group.milkTaken, group.milkTotal, parts = RLFeedRationPlanner.takeSerial(group.milk, need, nil, true)
        group.milkMix = RLFeedMath.compose(parts)
        if group.milkMix == nil and #group.milk > 0 then group.milkMix = RLFeedMath.compose({ { group.milk[1].profile, 1 } }) end
        local fulfil = need > 0 and group.milkTotal / need or 0
        for _, a in ipairs(group.animals) do
            a.milkKg = a.milkPlanKg * fulfil
            a.milkME = group.milkMix ~= nil and group.milkMix.me or 0
        end
    end

    -- 2. Rations, twice: on the forage the appetites would take, then on what the plan takes.
    for _, group in ipairs(groups) do
        local appetite, eligibleAppetite = 0, 0
        for _, a in ipairs(group.animals) do
            appetite = appetite + a.appetite * dt
            if a.concEligible then eligibleAppetite = eligibleAppetite + a.appetite * dt end
        end
        local wheatCap = request.ration.wheatMaxShare * eligibleAppetite
        local _, _, forageParts = RLFeedRationPlanner.takeSerial(group.forage, appetite, nil, false)
        local forageMix = RLFeedMath.compose(forageParts)
        local concMix, wheatShare = concentrateMix(group.concentrate, eligibleAppetite, wheatCap)
        local concScale = 1
        for pass = 1, 2 do
            local forageNeed, concNeed, eligibleIntake = 0, 0, 0
            for _, a in ipairs(group.animals) do
                -- The first pass only sizes the forage the plan takes: no AUTO search there.
                planAnimal(a, forageMix, concMix, wheatShare, concScale, request, pass == 1)
                forageNeed, concNeed = forageNeed + a.forageKg, concNeed + a.concKg
                if a.concEligible then eligibleIntake = eligibleIntake + a.forageKg + a.concKg end
            end
            if pass == 1 then
                _, _, forageParts = RLFeedRationPlanner.takeSerial(group.forage, forageNeed, nil, false)
                forageMix = RLFeedMath.compose(forageParts) or forageMix
                wheatCap = request.ration.wheatMaxShare * eligibleIntake
                local mix, share, total = concentrateMix(group.concentrate, concNeed, wheatCap)
                if mix ~= nil then concMix, wheatShare = mix, share end
                if concNeed > 0 and total < concNeed then concScale = total / concNeed end
            end
        end
        group.forageMix, group.concMix = forageMix, concMix
    end

    -- Planned intake (before any shortage) and the liters a month it stands for.
    local plannedMe, plannedKg = 0, 0
    for _, group in ipairs(groups) do
        for _, a in ipairs(group.animals) do
            local solids = a.forageKg + a.concKg
            a.plannedKg = a.milkPlanKg + solids
            a.plannedMe = a.milkPlanKg * a.milkME + solids * (a.solidMe or 0)
            plannedMe, plannedKg = plannedMe + a.plannedMe, plannedKg + a.plannedKg
            local perMonth = request.realDaysPerPeriod / dt
            local liters = 0
            a.plannedByFill = {}
            local function addLiters(mix, kg)
                if mix == nil or kg <= 0 then return end
                for name, share in pairs(mix.shares) do
                    local profile = profiles[name]
                    local amount = RLFeedUnits.kgToLiters(kg * share * perMonth, scale, profile.density, profile.dm)
                    liters = liters + amount
                    a.plannedByFill[name] = (a.plannedByFill[name] or 0) + amount
                end
            end
            addLiters(group.milkMix, a.milkPlanKg)
            addLiters(group.forageMix, a.forageKg)
            addLiters(group.concMix, a.concKg)
            a.litersPerPeriod = liters
        end
    end

    -- 3. Forage, group by group from the shared stock.
    for _, group in ipairs(groups) do
        local need = 0
        for _, a in ipairs(group.animals) do need = need + a.forageKg end
        local parts
        group.forageTaken, group.forageTotal, parts = RLFeedRationPlanner.takeSerial(group.forage, need, nil, true)
        group.forageEatenMix = RLFeedMath.compose(parts)
        local fulfil = need > 0 and group.forageTotal / need or 0
        for _, a in ipairs(group.animals) do a.forageEaten = a.forageKg * fulfil end
    end

    -- 4. Concentrate within each animal's share of its forage eaten.
    for _, group in ipairs(groups) do
        local need, eligibleEaten = 0, 0
        for _, a in ipairs(group.animals) do
            a.concAllowed = 0
            if a.concKg > 0 and a.c < 1 then a.concAllowed = math.min(a.concKg, a.forageEaten * a.c / (1 - a.c)) end
            if a.concAllowed < a.concKg - 1e-12 and a.forageEaten < a.forageKg then a.fibreHeld = true end
            need = need + a.concAllowed
            if a.concEligible then eligibleEaten = eligibleEaten + a.forageEaten + a.concAllowed end
        end
        local parts
        group.concTaken, group.concTotal, parts = RLFeedRationPlanner.takeSerial(group.concentrate, need,
            { WHEAT = request.ration.wheatMaxShare * eligibleEaten }, true)
        group.concEatenMix = RLFeedMath.compose(parts)
        local fulfil = need > 0 and group.concTotal / need or 0
        for _, a in ipairs(group.animals) do a.concEaten = a.concAllowed * fulfil end
    end

    -- 5. What each animal got.
    local main = groups[#groups] or {}
    local result = { withdraw = {}, plannedMe = plannedMe, plannedKg = plannedKg, eatenMe = 0, eatenKg = 0,
        forageMix = main.forageEatenMix or main.forageMix, concentrateMix = main.concEatenMix or main.concMix, milkMix = main.milkMix,
        animals = request.animals }
    local function addWithdraw(taken, list)
        for _, entry in ipairs(list) do
            local kg = taken[entry.name]
            if kg ~= nil and kg > 0 then
                result.withdraw[entry.name] = (result.withdraw[entry.name] or 0)
                    + RLFeedUnits.kgToLiters(kg, scale, entry.profile.density, entry.profile.dm)
            end
        end
    end
    for _, group in ipairs(groups) do
        addWithdraw(group.milkTaken, group.milk)
        addWithdraw(group.forageTaken, group.forage)
        addWithdraw(group.concTaken, group.concentrate)

        for _, a in ipairs(group.animals) do
            local solids = a.forageEaten + a.concEaten
            a.cEaten = solids > 0 and a.concEaten / solids or 0
            local util = RLFeedMath.getUtilisation(a.cEaten, a.adapted, request.ration)
            local energy = a.solidEnergy or 1
            a.byFill = {}
            -- Each feed its group took is shared by what each animal got of it; its energy is the
            -- feed's own ME (a calf's solid feed at its rumen's worth, concentrate above the
            -- animal's adaptation at unadaptedUtilisation).
            local function share(taken, total, mine, list, factor)
                if total <= 0 or mine <= 0 then return end
                for _, entry in ipairs(list) do
                    local kg = taken[entry.name]
                    if kg ~= nil and kg > 0 then
                        local got = kg * mine / total
                        local fill = a.byFill[entry.name] or { kg = 0, liters = 0, me = 0, cpKg = 0 }
                        fill.kg = fill.kg + got
                        fill.liters = fill.liters + RLFeedUnits.kgToLiters(got, scale, entry.profile.density, entry.profile.dm)
                        fill.me = fill.me + got * entry.profile.me * factor
                        fill.cpKg = fill.cpKg + got * entry.profile.cp
                        a.byFill[entry.name] = fill
                    end
                end
            end
            share(group.milkTaken, group.milkTotal, a.milkKg, group.milk, 1)
            share(group.forageTaken, group.forageTotal, a.forageEaten, group.forage, energy)
            share(group.concTaken, group.concTotal, a.concEaten, group.concentrate, energy * util)
            RLFeedRationPlanner.sumAnimal(a)
            result.eatenMe, result.eatenKg = result.eatenMe + a.me, result.eatenKg + a.kg
        end
    end
    return result
end
