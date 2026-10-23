--[[
    RLYoungDemandMath.lua
    The unified nursing contract (2026-10-22 design), pure arithmetic: what each young animal at
    foot needs from its dam, what that costs her, and how what she actually paid is shared. No
    engine globals; RLFeed puts the step's animals in and settles what comes out.

    A young animal's demand belongs to it, never to a dam's milk table:
        D_i = milkShare(age) x (maintenance_i + growth_i)                (MJ ME a day)
    maintenance_i and growth_i are its own needs at its actual weight on its own curve (the
    weight model's step demands: maintenance at its weight's metabolic size, its curve's normal
    gain at its genes' speed, each species' young costs); milkShare is the part of them its
    stage still takes from milk (the weaning curve at its age). So a heavier or faster-growing
    young of the same age needs more, a newborn and a nearly weaned one of the same weight need
    different amounts, and solids its stage allows cover the rest. D_i is in ME and carried as the
    dam's milk (kg DM at the milk's ME, its protein and SID lysine come with it): different
    nutrients are never added together.

    The dam's cost of her young (NUTRITION_COVERAGE: beef cattle, meat sheep, pigs):
        C_d = sum(D_i / milkME) / milkDM x costPerKg                     (MJ ME a day)
    costPerKg is the ME a real kg of her milk costs her (her species' or breed's milk meMJPerKg:
    every loss of making it is in there). Her budget pays it as its milk line (maintenance and
    pregnancy first, milk before reserve laid down; part of it from her reserve within its safety
    bounds), q = paid / C_d, and every young of hers gets q x D_i: the same share for all, each
    its own amount. With q = 1 nothing else caps it - no dam milk curve, gene or litter table.

    A dairy dam (DAIRY_MILK: dairy cattle, goats) gives what her genes, lactation and budget
    make (M_actual); her young drink first, at most what they need, and the rest is collectable:
        toYoung_i = min(1, M_actual / sum(M_need)) x M_need_i
        collectable = max(M_actual - sum(toYoung_i), 0)
    All in one unit over one step.
]]

RLYoungDemandMath = {}


--- A young animal's demand on its dam: its stage's milk share of its own maintenance and growth.
--- @param maintenance number MJ ME a day at its actual weight
--- @param growth number MJ ME a day of its normal growth (its curve, genes, young growth cost)
--- @param milkShare number 0..1 the part of them its stage takes from milk
--- @return number MJ ME a day (0 when weaned or nothing is needed)
function RLYoungDemandMath.getDemandME(maintenance, growth, milkShare)
    local share = math.min(math.max(milkShare or 0, 0), 1)
    if share <= 0 then return 0 end
    return share * (math.max(maintenance or 0, 0) + math.max(growth or 0, 0))
end


--- An amount of ME as the dam's milk: kg DM, real kg as drunk, crude protein and SID lysine (kg).
--- @param me number MJ ME
--- @param milk table { dm (share of real milk), me (MJ per kg DM), cp (share of DM), sidLys (kg per kg DM, optional) }
--- @return table { me, kgDM, kgReal, cpKg, lysKg }
function RLYoungDemandMath.toMilk(me, milk)
    me = math.max(me or 0, 0)
    local kgDM = (milk.me or 0) > 0 and me / milk.me or 0
    return {
        me = me, kgDM = kgDM, kgReal = (milk.dm or 0) > 0 and kgDM / milk.dm or 0,
        cpKg = kgDM * (milk.cp or 0), lysKg = kgDM * (milk.sidLys or 0),
    }
end


--- The ME a dam spends on real kg of milk for her young.
--- @param kgReal number Real kg of milk (as drunk)
--- @param costPerKg number MJ ME a real kg of her milk costs her
--- @return number MJ ME
function RLYoungDemandMath.getDamCost(kgReal, costPerKg)
    return math.max(kgReal or 0, 0) * math.max(costPerKg or 0, 0)
end


--- The share of her young's demand a dam paid: clamp(paid / demand, 0, 1); nil without a demand
--- (no division, no ratio to show).
--- @param paid number
--- @param demand number
--- @return number|nil
function RLYoungDemandMath.getCoverage(paid, demand)
    if demand == nil or demand <= 0 then return nil end
    return math.min(math.max((paid or 0) / demand, 0), 1)
end


--- Each young's share of what its dam paid: q x D_i, in the list's order (the order itself never
--- changes anyone's amount).
--- @param demands table { D_1, D_2, ... } in any one unit
--- @param q number|nil
--- @return table received { S_1, S_2, ... }
--- @return number total
function RLYoungDemandMath.share(demands, q)
    local received, total = {}, 0
    q = math.min(math.max(q or 0, 0), 1)
    for i, d in ipairs(demands) do
        received[i] = q * math.max(d or 0, 0)
        total = total + received[i]
    end
    return received, total
end


--- A dairy dam's milk this step split between her young and the store: her young first, at most
--- what they need; what is left is collectable.
--- @param actual number The milk her budget made this step
--- @param needs table { M_need_1, ... } in the same unit
--- @return table toYoung { ... }
--- @return number q (nil without a need)
--- @return number collectable
--- @return number drunk Total her young drank
function RLYoungDemandMath.splitDairy(actual, needs)
    actual = math.max(actual or 0, 0)
    local total = 0
    for _, need in ipairs(needs) do total = total + math.max(need or 0, 0) end
    if total <= 0 then return {}, nil, actual, 0 end
    local q = math.min(actual / total, 1)
    local toYoung, drunk = RLYoungDemandMath.share(needs, q)
    return toYoung, q, math.max(actual - drunk, 0), drunk
end
