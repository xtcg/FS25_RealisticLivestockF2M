--[[
    RLFeedRationPlanner.lua
    One feeding of a pen in the real-equivalent mode, pure: what each animal plans to eat, what the
    pen takes from its stock and what each animal ends up with. No engine globals; RLFeed builds
    the request from the pen and its animals and removes the liters this returns.

    Order, per feeding:
    1. Milk. A calf on milk plans its milk allowance (milkMax applied), within its total appetite;
       the pen's milk is taken in feed order and shared by plan.
    2. Ration. Each animal's ration is the pen's forage (complete rations and forages, taken in feed
       order, so the forage the pen will actually eat sets its quality) and the concentrate its
       feeding stage may eat (a calf on milk: a starter) at share c of the DM:
           c = min(the pen's target share (none: as much as allowed),
                   what keeps the ration's effective fibre, starch + sugar and each capped feed
                   (wheat, peas: maxShare) in bounds,
                   what the animal's rumen is adapted to + stepAllowance)
       and less in step when the concentrate in stock cannot cover every animal's share. Its intake
       is the least of its appetite (a calf on milk: its rumen's solid capacity beside the milk),
       what the ration's bulk lets it eat (NDF fill) and - when it eats for a target rather than
       freely - its energy demand over the ration's ME. A calf's rumen draws less from forage
       (solidEnergy); concentrate counts at its own ME. A calf eating freely is scored on the
       protein of milk and solids together.
       This is worked out twice: first on the forage the stock would give for the animals'
       appetites, then on the forage their planned intake actually takes.
    3. Forage is taken; when it runs short every animal gets the same share of its plan.
    4. Concentrate is taken, at most what each animal's forage eaten keeps within its share (no
       concentrate without roughage: what is not eaten stays in the trough), each capped feed at
       most its maxShare of the pen's ration.
    5. Each animal's DM, ME and crude protein from what it got; liters per fill type by its share of
       each feed taken.
    A shortage is never made up by valuing the rest higher: what was not eaten carries nothing.
]]

RLFeedRationPlanner = {}


--- Take kg DM from a stock list in order (each entry { name, profile, availableKg }, entries'
--- usedKg counted when `commit`), each cap group (a feed's capGroup, else its name) at most
--- caps[group] together.
--- @return table taken name -> kg
--- @return number total kg
--- @return table parts { { profile, kg }, ... }
function RLFeedRationPlanner.takeSerial(list, needKg, caps, commit)
    local taken, total, parts, left, capped = {}, 0, {}, math.max(needKg or 0, 0), {}
    for _, entry in ipairs(list) do
        if left <= 0 then break end
        local available = math.max(entry.availableKg - (entry.usedKg or 0), 0)
        local group = entry.profile ~= nil and entry.profile.capGroup or entry.name
        local cap = caps ~= nil and caps[group] or nil
        if cap ~= nil then available = math.min(available, math.max(cap - (capped[group] or 0), 0)) end
        local kg = math.min(left, available)
        if kg > 0 then
            taken[entry.name] = (taken[entry.name] or 0) + kg
            capped[group] = (capped[group] or 0) + kg
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


--- Each cap group's most kg in a ration of `rationKg` DM (its feeds' maxShare: wheat's 30 %, which
--- grain grist shares).
local function feedCaps(list, rationKg)
    local caps = {}
    for _, entry in ipairs(list) do
        if entry.profile.maxShare ~= nil then
            local group = entry.profile.capGroup or entry.name
            local cap = entry.profile.maxShare * rationKg
            if caps[group] == nil or cap < caps[group] then caps[group] = cap end
        end
    end
    return caps
end


--- The cap groups' shares of a concentrate mix: { { name (the group), share, max }, ... } in stock
--- order.
local function cappedShares(list, mix)
    local out, byGroup = {}, {}
    if mix == nil then return out end
    for _, entry in ipairs(list) do
        local share = mix.shares[entry.name]
        if entry.profile.maxShare ~= nil and share ~= nil and share > 0 then
            local group = entry.profile.capGroup or entry.name
            local row = byGroup[group]
            if row == nil then
                row = { name = group, share = 0, max = entry.profile.maxShare }
                byGroup[group] = row
                out[#out + 1] = row
            end
            row.share, row.max = row.share + share, math.min(row.max, entry.profile.maxShare)
        end
    end
    return out
end


--- A concentrate mix as the stock would give it for `needKg`, each capped feed at most its share
--- of a ration of `rationKg`, and the capped feeds' shares of it.
local function concentrateMix(list, needKg, rationKg)
    local _, total, parts = RLFeedRationPlanner.takeSerial(list, needKg, feedCaps(list, rationKg), false)
    local mix = RLFeedMath.compose(parts)
    return mix, cappedShares(list, mix), total
end


--- Most solid DM an animal may eat over a step: its appetite; a calf on milk its rumen's solid
--- capacity (solidCap, kg a day) and what its total appetite leaves beside the milk it drinks.
function RLFeedRationPlanner.getSolidCap(a, dt)
    if a.milkMax ~= nil and a.milkMax > 0 then
        local solid = a.solidCap ~= nil and a.solidCap * dt or (a.solidMax or 1) * a.appetite * dt
        return math.max(math.min(solid, a.appetite * dt - (a.milkKg or a.milkPlanKg or 0)), 0)
    end
    return a.appetite * dt
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
    -- A calf's rumen draws less from forage (solidEnergy); concentrate it eats at its own worth.
    local forageEff = forageMix
    if forageMix ~= nil and (a.solidEnergy or 1) < 1 then
        forageEff = { me = forageMix.me * a.solidEnergy, cp = forageMix.cp, ndf = forageMix.ndf, peNdf = forageMix.peNdf,
            fermentable = forageMix.fermentable, starch = forageMix.starch }
    end
    local mix = RLFeedMath.blend(forageEff, concEff, c)
    if mix == nil or forageMix == nil then return nil end

    local dt = request.dtDays
    local cap = RLFeedRationPlanner.getSolidCap(a, dt)
    local me = mix.me
    local needs = a.needs or {}
    local maintenance = (needs.maintenance or 0) + (needs.pregnancy or 0)
    local production = (needs.growth or 0) + (needs.milk or 0)
    local protein = RLFeedMath.getProductionProteinFactor(RLFeedMath.getProteinFactor(mix.cp, a.proteinNeed or 0,
        request.proteinMaintenance or 0), needs.growth, needs.milk, request.proteinMilkResponse)

    local demandStep
    if a.target == "GROW" then
        demandStep = (maintenance + protein * production + (needs.deposit or 0)) * dt
    elseif a.target == "MAINTAIN" then
        demandStep = maintenance * dt
    end
    if demandStep ~= nil then demandStep = math.max(demandStep - a.milkKg * (a.milkME or 0), 0) end
    local kg, limit = RLFeedMath.getIntake(cap, a.fill * dt, { me = me, ndf = mix.ndf }, demandStep)
    if demandStep == nil and (a.milkKg or 0) > 0 and kg + a.milkKg > 0 then
        -- A calf eating freely: the protein of all it takes, milk and solids together (as settled).
        local cp = (kg * mix.cp + a.milkKg * (a.milkCP or 0)) / (kg + a.milkKg)
        protein = RLFeedMath.getProductionProteinFactor(RLFeedMath.getProteinFactor(cp, a.proteinNeed or 0,
            request.proteinMaintenance or 0), needs.growth, needs.milk, request.proteinMilkResponse)
    end

    local energy = dt > 0 and (kg * me + a.milkKg * (a.milkME or 0)) / dt - maintenance or 0
    local paid = protein * math.min(math.max(energy, 0), production)
    local laid = math.min(math.max(energy - paid, 0), needs.deposit or 0)
    -- gap: what its maintenance and production (not reserve laid down freely) still want a day.
    return { c = c, kg = kg, limit = limit, score = paid + 0.5 * laid, me = me, util = util, gap = production - math.max(energy, 0) }
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
---   An animal with a concentrate route (a.concRoute: sheep males, RLFeed.getConcentrateRoute) is
---   held at its cap; on AUTO at its target, above it only as far as its maintenance and growth
---   want (the least grid share that covers them), never above the best-scoring share; and its share
---   rises from the last step's by at most the route's rate (a.routeC keeps what the route allowed).
local function planAnimal(a, forageMix, concMix, capped, concScale, request)
    local ration = request.ration
    local c, limit = 0, nil
    local route = a.concRoute
    a.routeC = nil
    if a.concEligible and concMix ~= nil then
        local cLimit, why = RLFeedMath.getConcentrateLimit(forageMix, concMix, request.classes[a.class], capped)
        c, limit = cLimit, why
        local routeCap, routeTarget = route ~= nil and route.cap or nil, route ~= nil and route.target or nil
        if route ~= nil and (a.forageFill or 1) < 1 - 1e-9 then
            -- Too little forage in stock for the route's share: concentrate makes up the forage that
            -- is missing (the same forage kg, the rest of its appetite), up to the intensive cap.
            routeCap = math.max(routeCap, math.min(route.finishingCap or routeCap, 1 - (1 - routeCap) * math.max(a.forageFill, 0)))
            routeTarget = nil
        end
        if routeCap ~= nil and routeCap < c then c, limit = routeCap, "TARGET" end
        cLimit = c
        if request.share ~= nil then
            if request.share < c then c, limit = request.share, "TARGET" end
        elseif c > 0 then
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
            if best ~= nil and best.c < c - 1e-9 then c, limit = best.c, "PROTEIN_OR_DEMAND" end
            if routeTarget ~= nil and c > 0 then
                -- The least grid share whose energy covers its needs (scored fully adapted, as above).
                local needed, g2 = c, 0
                while true do
                    local option = evaluate(a, math.min(g2, c), forageMix, concMix, request)
                    if option ~= nil and option.gap <= 1e-9 then needed = option.c break end
                    if g2 >= c then break end
                    g2 = g2 + RLFeedRationPlanner.AUTO_STEP
                end
                local want = math.max(routeTarget, needed)
                if want < c - 1e-9 then c, limit = want, "TARGET" end
            end
            a.adapted = adapted
        end
        if route ~= nil then
            if route.maxNow ~= nil and route.maxNow < c then c, limit = math.max(route.maxNow, 0), "ADAPTATION" end
            a.routeC = c
        end
        local adaptedLimit = RLFeedMath.getAdaptedLimit(a.adapted, ration, request.dtDays)
        if adaptedLimit < c then c, limit = adaptedLimit, "ADAPTATION" end
        if concScale < 1 then c, limit = c * concScale, "STOCK" end
    elseif a.concEligible and request.concentrateWanted then
        limit = "NO_CONCENTRATE"
    end

    local best = evaluate(a, c, forageMix, concMix, request)
    -- A young animal at foot eats at most concMaxKgPerDay of concentrate (the creep gate): its
    -- share is held so its concentrate stays there, its appetite filled with forage.
    local creep = a.concMaxKgPerDay ~= nil and a.concMaxKgPerDay * request.dtDays or nil
    if best ~= nil and creep ~= nil then
        for _ = 1, 3 do
            if best == nil or best.kg * best.c <= creep * (1 + 1e-9) or best.kg <= 0 then break end
            c = creep / best.kg
            limit = "CREEP"
            best = evaluate(a, c, forageMix, concMix, request)
        end
        if best ~= nil and best.kg > 0 and best.kg * best.c > creep then best.c = creep / best.kg end
    end
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
    local kg, me, cpKg, lysKg = 0, 0, 0, 0
    for _, fill in pairs(a.byFill) do kg, me, cpKg, lysKg = kg + fill.kg, me + fill.me, cpKg + fill.cpKg, lysKg + (fill.lysKg or 0) end
    if a.damMilk ~= nil then
        kg, me, cpKg, lysKg = kg + a.damMilk.kg, me + a.damMilk.me, cpKg + a.damMilk.cpKg, lysKg + (a.damMilk.lysKg or 0)
    end
    a.kg, a.me = kg, me
    a.cp = kg > 0 and cpKg / kg or 0
    -- SID lysine eaten (kg) and per MJ of ME (g/MJ): read by monogastric sections (pigs) only.
    a.lysKg = lysKg
    a.lysPerMe = RLFeedMath.getLysinePerME(lysKg, me)
end


--- Plan and share one feeding.
--- @param request table {
---     animals = { { appetite (kg DM/day), fill (kg NDF/day), class, stage (PRE_WEANING, WEANING,
---                   WEANED: the feeds it may eat), target (FINISH eats freely, GROW for its needs,
---                   MAINTAIN for maintenance and pregnancy), concEligible, adapted,
---                   needs = { maintenance, pregnancy, growth, milk, deposit } (MJ/day), proteinNeed,
---                   milkMax, milkMaxKgPerDay (DM ceiling of the trough's milk), nursingMaxKgPerDay (real ceiling at its dam), solidMax, solidEnergy }, ... },
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

    -- 1. Milk for calves: a calf drinks its milk allowance (milkMaxKgPerDay, already at its
    -- milkMax), within its total appetite; without an allowance, milkMax of its appetite. A calf
    -- with its dam (damPool) drinks her milk first - twins share it by their plans - and the
    -- trough's milk only makes up what she does not give, within the same allowance.
    local pools = {}
    for _, a in ipairs(request.animals) do
        a.milkPlanKg, a.damMilkKg = 0, 0
        if a.milkMax ~= nil and a.milkMax > 0 then
            local allowance = a.milkMaxKgPerDay ~= nil and math.max(a.milkMaxKgPerDay, 0) or math.min(a.milkMax, 1) * a.appetite
            -- With its dam it drinks real whole milk: the real allowance, not the trough's game strength.
            if a.damPool ~= nil and a.nursingMaxKgPerDay ~= nil then allowance = math.max(a.nursingMaxKgPerDay, 0) end
            a.milkPlanKg = math.min(allowance, a.appetite) * dt
        end
        local pool = a.damPool
        if pool ~= nil and a.milkPlanKg > 0 then
            if pools[pool] == nil then pools[pool] = 0; pool.calves = {} end
            pools[pool] = pools[pool] + a.milkPlanKg
            table.insert(pool.calves, a)
        end
    end
    for pool, wanted in pairs(pools) do
        local share = wanted > 0 and math.min(1, math.max(pool.kg or 0, 0) / wanted) or 0
        pool.plannedKg = 0
        for _, a in ipairs(pool.calves) do
            a.damMilkKg = a.milkPlanKg * share
            pool.plannedKg = pool.plannedKg + a.damMilkKg
        end
    end
    for _, group in ipairs(groups) do
        local need = 0
        for _, a in ipairs(group.animals) do
            a.troughMilkPlanKg = a.damMilkKg > 0 and math.max(a.milkPlanKg - a.damMilkKg, 0) or a.milkPlanKg
            need = need + a.troughMilkPlanKg
        end
        local parts
        group.milkTaken, group.milkTotal, parts = RLFeedRationPlanner.takeSerial(group.milk, need, nil, true)
        group.milkMix = RLFeedMath.compose(parts)
        if group.milkMix == nil and #group.milk > 0 then group.milkMix = RLFeedMath.compose({ { group.milk[1].profile, 1 } }) end
        local fulfil = need > 0 and group.milkTotal / need or 0
        local troughME = group.milkMix ~= nil and group.milkMix.me or 0
        local troughCP = group.milkMix ~= nil and group.milkMix.cp or 0
        for _, a in ipairs(group.animals) do
            a.troughMilkKg = a.troughMilkPlanKg * fulfil
            if a.damMilkKg > 0 then
                local pool = a.damPool
                a.milkKg = a.damMilkKg + a.troughMilkKg
                a.milkME = (a.damMilkKg * pool.me + a.troughMilkKg * troughME) / a.milkKg
                a.milkCP = (a.damMilkKg * pool.cp + a.troughMilkKg * troughCP) / a.milkKg
                a.milkPlanMe = a.damMilkKg * pool.me + a.troughMilkPlanKg * troughME
            else
                a.milkKg = a.troughMilkKg
                a.milkME, a.milkCP = troughME, troughCP
            end
        end
    end

    -- 2. Rations, twice: on the forage the appetites would take, then on what the plan takes.
    for _, group in ipairs(groups) do
        local appetite, eligibleAppetite = 0, 0
        for _, a in ipairs(group.animals) do
            local solids = RLFeedRationPlanner.getSolidCap(a, dt)
            appetite = appetite + solids
            if a.concEligible then eligibleAppetite = eligibleAppetite + solids end
        end
        local _, _, forageParts = RLFeedRationPlanner.takeSerial(group.forage, appetite, nil, false)
        local forageMix = RLFeedMath.compose(forageParts)
        local concMix, capped = concentrateMix(group.concentrate, eligibleAppetite, eligibleAppetite)
        local concScale = 1
        for pass = 1, 2 do
            local forageNeed, concNeed, eligibleIntake = 0, 0, 0
            for _, a in ipairs(group.animals) do
                planAnimal(a, forageMix, concMix, capped, concScale, request)
                forageNeed, concNeed = forageNeed + a.forageKg, concNeed + a.concKg
                if a.concEligible then eligibleIntake = eligibleIntake + a.forageKg + a.concKg end
            end
            if pass == 1 then
                -- A routed animal (a.concRoute) whose forage the stock cannot give replaces it with
                -- concentrate in the second pass (planAnimal).
                local fill = forageNeed > 0 and math.min(availableKg(group.forage) / forageNeed, 1) or 1
                for _, a in ipairs(group.animals) do if a.concRoute ~= nil then a.forageFill = fill end end
                _, _, forageParts = RLFeedRationPlanner.takeSerial(group.forage, forageNeed, nil, false)
                forageMix = RLFeedMath.compose(forageParts) or forageMix
                local mix, shares, total = concentrateMix(group.concentrate, concNeed, eligibleIntake)
                if mix ~= nil then concMix, capped = mix, shares end
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
            a.plannedMe = (a.damMilkKg > 0 and a.milkPlanMe or a.milkPlanKg * a.milkME) + solids * (a.solidMe or 0)
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
            addLiters(group.milkMix, a.troughMilkPlanKg)
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
            feedCaps(group.concentrate, eligibleEaten), true)
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
                        fill.factor = factor
                        a.byFill[entry.name] = fill
                    end
                end
            end
            share(group.milkTaken, group.milkTotal, a.troughMilkKg, group.milk, 1)
            -- Its dam's milk is no trough feed: kept apart (RLFeed settles it against what she paid).
            a.damMilk = nil
            if a.damMilkKg > 0 then
                a.damMilk = { kg = a.damMilkKg, me = a.damMilkKg * a.damPool.me, cpKg = a.damMilkKg * a.damPool.cp,
                    lysKg = a.damMilkKg * (a.damPool.lys or 0) }
            end
            share(group.forageTaken, group.forageTotal, a.forageEaten, group.forage, energy)
            share(group.concTaken, group.concTotal, a.concEaten, group.concentrate, util)
            RLFeedRationPlanner.sumAnimal(a)
            result.eatenMe, result.eatenKg = result.eatenMe + a.me, result.eatenKg + a.kg
        end
    end
    return result
end


-- =============================================================================
-- Monogastric (pigs)
-- =============================================================================

--- The shares (of DM) of a mix of `entries` in proportion to their stock, each feed at most its
--- maxShare: a capped feed is held at its cap and the rest share what is left in proportion
--- (repeated until no feed is over its cap). Entries with no stock get no share.
--- @return table name -> share (summing to 1, or empty when nothing is stocked)
function RLFeedRationPlanner.getStockShares(entries)
    local shares, fixed, free = {}, {}, {}
    for _, entry in ipairs(entries) do
        if (entry.availableKg or 0) > 0 then free[#free + 1] = entry end
    end
    local left = 1
    for _ = 1, #entries + 1 do
        local total = 0
        for _, entry in ipairs(free) do total = total + entry.availableKg end
        if total <= 0 then break end
        local over = false
        for _, entry in ipairs(free) do
            local share = left * entry.availableKg / total
            local cap = entry.profile.maxShare
            if cap ~= nil and share > cap + 1e-12 then
                fixed[entry.name], left, over = cap, left - cap, true
            end
        end
        if not over then
            for _, entry in ipairs(free) do shares[entry.name] = left * entry.availableKg / total end
            break
        end
        local rest = {}
        for _, entry in ipairs(free) do if fixed[entry.name] == nil then rest[#rest + 1] = entry end end
        free = rest
    end
    for name, share in pairs(fixed) do shares[name] = share end
    return shares
end


--- Plan and share one feeding of a monogastric pen (pigs, NRC 2012 ch. 8): no forage, no
--- concentrate, no rumen. Each animal eats one mix of every feed in the trough it may eat (a feed's
--- maxWeightKg: piglet feed for light pigs only), in proportion to the stock and each feed at most its
--- maxShare. Its intake is the least of what it can physically eat (appetite, kg DM a day), and
--- - freely (FINISH) - its energy appetite (energyCap, MJ a day) or - for a target (GROW,
--- MAINTAIN) - its energy demand, over the mix's ME. Growth is scored on the mix's SID lysine per MJ
--- of ME against its need (proteinNeed, g/MJ). A feed the trough holds less of than planned is
--- shared by plan; nothing short is made up from the rest or valued higher.
--- @param request table { animals = descriptors (appetite, energyCap, weight, target, needs, proteinNeed),
---     feeds = { { name, profile, liters } }, scale, realDaysPerPeriod, dtDays, proteinMaintenance }
--- @return table As RLFeedRationPlanner.plan (forageMix: the pen's mix as planned)
function RLFeedRationPlanner.planMonogastric(request)
    local scale, dt = request.scale, request.dtDays
    local feeds = request.feeds or {}
    for _, entry in ipairs(feeds) do
        entry.availableKg = RLFeedUnits.litersToKg(math.max(entry.liters or 0, 0), scale, entry.profile.density, entry.profile.dm)
        entry.usedKg = 0
    end
    local mixes = {}
    local function mixFor(a)
        local entries, key = {}, {}
        for _, entry in ipairs(feeds) do
            local limit = entry.profile.maxWeightKg
            if limit == nil or (a.weight or 0) <= limit then
                entries[#entries + 1] = entry
                key[#key + 1] = entry.name
            end
        end
        local id = table.concat(key, " ")
        local cached = mixes[id]
        if cached ~= nil then return cached end
        local shares = RLFeedRationPlanner.getStockShares(entries)
        local parts = {}
        for _, entry in ipairs(entries) do
            if (shares[entry.name] or 0) > 0 then parts[#parts + 1] = { entry.profile, shares[entry.name] } end
        end
        -- Shares summing to less than 1: every stocked feed is at its cap (only soybean in the
        -- trough): the animal eats that much of its intake and goes without the rest.
        local total = 0
        for _, share in pairs(shares) do total = total + share end
        cached = { mix = RLFeedMath.compose(parts), shares = shares, entries = entries, total = math.min(total, 1) }
        mixes[id] = cached
        return cached
    end

    -- Milk first: a piglet at its sow plans its own demand (within its appetite); a litter shares
    -- her pool by its plans (each the same share), as a ruminant's young do.
    local pools = {}
    for _, a in ipairs(request.animals) do
        a.milkPlanKg, a.damMilkKg, a.milkKg, a.troughMilkKg = 0, 0, 0, 0
        local pool = a.damPool
        if pool ~= nil and (a.milkMax or 0) > 0 then
            a.milkPlanKg = math.min(math.max(a.nursingMaxKgPerDay or 0, 0), math.max(a.appetite or 0, 0)) * dt
            if a.milkPlanKg > 0 then
                if pools[pool] == nil then pools[pool] = 0; pool.calves = {} end
                pools[pool] = pools[pool] + a.milkPlanKg
                table.insert(pool.calves, a)
            end
        end
    end
    for pool, wanted in pairs(pools) do
        local share = wanted > 0 and math.min(1, math.max(pool.kg or 0, 0) / wanted) or 0
        pool.plannedKg = 0
        for _, a in ipairs(pool.calves) do
            a.damMilkKg = a.milkPlanKg * share
            a.milkKg = a.damMilkKg
            pool.plannedKg = pool.plannedKg + a.damMilkKg
        end
    end

    local need = {}
    local plannedMe, plannedKg = 0, 0
    local main
    for _, a in ipairs(request.animals) do
        local milkMe = a.damMilkKg > 0 and a.damMilkKg * a.damPool.me or 0
        a.c, a.cEaten, a.util, a.concLimit, a.forageKg, a.concKg = 0, 0, 1, nil, 0, 0
        local m = mixFor(a)
        a.monoMix = m
        local mix = m.mix
        local kg, limit = 0, "NO_FEED"
        if mix ~= nil and mix.me > 0 then
            main = main or mix
            local needs = a.needs or {}
            local maintenance = (needs.maintenance or 0) + (needs.pregnancy or 0)
            local production = (needs.growth or 0) + (needs.milk or 0)
            local protein = RLFeedMath.getProteinFactor(RLFeedMath.getLysinePerME(mix.lys, mix.me), a.proteinNeed or 0,
                request.proteinMaintenance or 0)
            -- A piglet on milk eats creep feed up to what its age takes (solidCap), its milk beside it.
            local cap = math.max(a.solidCap or a.appetite or 0, 0) * dt
            local energy
            if a.target == "GROW" then
                energy = (maintenance + protein * production + (needs.deposit or 0)) * dt
            elseif a.target == "MAINTAIN" then
                energy = maintenance * dt
            else
                energy = math.max(a.energyCap or 0, 0) * dt
            end
            energy = energy - milkMe
            local byEnergy = math.max(energy, 0) / mix.me
            kg, limit = cap, "APPETITE"
            if byEnergy < kg then kg, limit = byEnergy, (a.target == "GROW" or a.target == "MAINTAIN") and "DEMAND" or "ENERGY" end
            -- Every stocked feed it may eat is capped and the caps leave part of the ration unfilled
            -- (only soybean, 25%): no ration keeps each feed within its share of what is eaten, so it
            -- eats none of it (maxShare is a share of the DM eaten, never a smaller meal of the feed).
            if m.total < 1 - 1e-9 then kg, limit = 0, "FEED_CAP" end
        end
        a.intakeLimit, a.solidMe, a.monoKg = limit, mix ~= nil and mix.me or 0, kg
        a.plannedKg, a.plannedMe = kg + a.damMilkKg, kg * (mix ~= nil and mix.me or 0) + milkMe
        plannedMe, plannedKg = plannedMe + a.plannedMe, plannedKg + a.plannedKg
        local perMonth = request.realDaysPerPeriod / dt
        a.plannedByFill, a.litersPerPeriod = {}, 0
        for name, share in pairs(m.shares) do
            local kgFeed = kg * share
            if kgFeed > 0 then
                need[name] = (need[name] or 0) + kgFeed
                local profile
                for _, entry in ipairs(m.entries) do if entry.name == name then profile = entry.profile end end
                local liters = RLFeedUnits.kgToLiters(kgFeed * perMonth, scale, profile.density, profile.dm)
                a.plannedByFill[name] = (a.plannedByFill[name] or 0) + liters
                a.litersPerPeriod = a.litersPerPeriod + liters
            end
        end
    end

    -- Take each feed from the stock. A feed the trough holds less of than planned shrinks every meal it
    -- is part of as a whole (to its fulfilment, the least of its feeds'), so each animal's mix - and every
    -- maxShare - holds for what it eats; the other feeds' rest stays in the trough. Nothing short is made
    -- up from the rest or valued higher.
    local fulfil, result = {}, { withdraw = {}, plannedMe = plannedMe, plannedKg = plannedKg, eatenMe = 0, eatenKg = 0,
        forageMix = main, concentrateMix = nil, milkMix = nil, animals = request.animals, monogastric = true }
    for _, entry in ipairs(feeds) do
        local wanted = need[entry.name] or 0
        fulfil[entry.name] = wanted > 0 and math.min(entry.availableKg / wanted, 1) or 1
    end
    local takenKg = {}
    for _, a in ipairs(request.animals) do
        local m = a.monoMix
        local meal = 1
        for name, share in pairs(m.shares) do
            if share > 0 and a.monoKg > 0 then meal = math.min(meal, fulfil[name] or 0) end
        end
        if meal < 1 - 1e-12 and a.monoKg > 0 then a.intakeLimit = "FEED_SHORT" end
        a.byFill = {}
        a.damMilk = nil
        if a.damMilkKg > 0 then
            -- Its sow's milk is no trough feed: kept apart (RLFeed settles it against what she paid).
            local pool = a.damPool
            a.damMilk = { kg = a.damMilkKg, me = a.damMilkKg * pool.me, cpKg = a.damMilkKg * pool.cp, lysKg = a.damMilkKg * (pool.lys or 0) }
        end
        for _, entry in ipairs(m.entries) do
            local got = a.monoKg * (m.shares[entry.name] or 0) * meal
            if got > 0 then
                local profile = entry.profile
                a.byFill[entry.name] = { kg = got, liters = RLFeedUnits.kgToLiters(got, scale, profile.density, profile.dm),
                    me = got * profile.me, cpKg = got * profile.cp, lysKg = got * (profile.sidLys or 0), factor = 1 }
                takenKg[entry.name] = (takenKg[entry.name] or 0) + got
            end
        end
        a.monoMix = nil
        RLFeedRationPlanner.sumAnimal(a)
        result.eatenMe, result.eatenKg = result.eatenMe + a.me, result.eatenKg + a.kg
    end
    for _, entry in ipairs(feeds) do
        local kg = math.min(takenKg[entry.name] or 0, entry.availableKg)
        entry.usedKg = kg
        if kg > 0 then result.withdraw[entry.name] = RLFeedUnits.kgToLiters(kg, scale, entry.profile.density, entry.profile.dm) end
    end
    return result
end
