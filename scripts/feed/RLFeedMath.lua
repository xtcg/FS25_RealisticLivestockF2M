--[[
    RLFeedMath.lua
    Pure arithmetic of the real-equivalent nutrition mode (xml/feedProfiles.xml): the energy units
    the budget step runs in, a ration's nutrient density from its feeds' DM shares, how much
    concentrate a ration can hold, how much an animal can eat, protein adequacy, rumen adaptation
    to concentrate and the nutrition health factor. No engine globals.

    Units: ME in MJ, intake in kg of dry matter (DM) a real day, shares of DM. The budget step
    (RLGrowthMath.step) counts per game month, so per-day values are x realDaysPerPeriod there.
]]

RLFeedMath = {}


-- =============================================================================
-- Budget energy units
-- =============================================================================

--- The budget step's config in ME per game month: the body condition config with its energy
--- values replaced by the feed profiles' (rates, ceilings and reserve rules stay).
--- @param bodyConfig table RLBodyConditionConfig values
--- @param feedConfig table RLFeedProfiles config
--- @return table
function RLFeedMath.getEnergyConfig(bodyConfig, feedConfig)
    local cfg = {}
    for key, value in pairs(bodyConfig) do cfg[key] = value end
    local req = feedConfig.requirements
    cfg.maintenancePerKgMetabolic = req.maintenanceMEPerKgMetabolic * feedConfig.realDaysPerPeriod
    cfg.growthNUPerKg = req.growthMEPerKgAt500
    cfg.depositNUPerKg = req.reserveDepositMEPerKg
    cfg.mobilizeNUPerKg = req.reserveMobilizeMEPerKg
    cfg.catabolismNUPerKg = req.catabolismMEPerKg
    cfg.pregnancyFactor = req.pregnancyFactor
    cfg.energyUnit = "ME_MJ"
    return cfg
end


--- ME (MJ) a kg of frame grown costs at this live weight: growthMEPerKgAt500 x (W / 500) ^ e,
--- at least growthMEPerKgMin. The energy in a kg of gain rises with weight (NRC 2000 NEg).
--- @param weight number kg
--- @param requirements table
--- @return number
function RLFeedMath.getGrowthCost(weight, requirements)
    local scaled = requirements.growthMEPerKgAt500 * (math.max(weight, 1) / 500) ^ requirements.growthWeightExponent
    return math.max(scaled, requirements.growthMEPerKgMin)
end


-- =============================================================================
-- Ration composition
-- =============================================================================

--- Nutrient density of a ration from its parts' DM: { { profile, kg }, ... }. Shares are of the
--- total DM. nil when the parts hold no DM.
--- @param parts table
--- @return table|nil { dm (kg), me, cp, ndf, peNdf, fermentable, starch, shares = { name -> share } }
function RLFeedMath.compose(parts)
    local total = 0
    for _, part in ipairs(parts) do total = total + math.max(part[2], 0) end
    if total <= 0 then return nil end
    local mix = { dm = total, me = 0, cp = 0, ndf = 0, peNdf = 0, fermentable = 0, starch = 0, shares = {} }
    for _, part in ipairs(parts) do
        local profile, share = part[1], math.max(part[2], 0) / total
        if share > 0 then
            mix.me = mix.me + share * profile.me
            mix.cp = mix.cp + share * profile.cp
            mix.ndf = mix.ndf + share * profile.ndf
            mix.peNdf = mix.peNdf + share * profile.peNdf
            mix.fermentable = mix.fermentable + share * profile.fermentable
            mix.starch = mix.starch + share * profile.starch
            mix.shares[profile.name] = (mix.shares[profile.name] or 0) + share
        end
    end
    return mix
end


--- A blend of two mixes: (1 - c) of a and c of b (either may be nil when its share is 0).
--- @return table|nil { me, cp, ndf, peNdf, fermentable, starch }
function RLFeedMath.blend(a, b, c)
    if c <= 0 or b == nil then return a end
    if c >= 1 or a == nil then return b end
    local out = {}
    for _, key in ipairs({ "me", "cp", "ndf", "peNdf", "fermentable", "starch" }) do
        out[key] = (1 - c) * a[key] + c * b[key]
    end
    return out
end


--- The most concentrate (share of DM) a ration of this forage and this concentrate may hold for a
--- ration class: physically effective NDF at least peNdfMin, starch + sugar at most
--- fermentableMax, wheat at most wheatMaxShare of the ration.
--- @param forage table|nil Forage mix (compose)
--- @param concentrate table|nil Concentrate mix (compose)
--- @param rules table { peNdfMin, fermentableMax }
--- @param wheatShare number Wheat's share of the concentrate DM
--- @param wheatMax number wheatMaxShare
--- @return number share 0..1
--- @return string|nil limit "FIBRE", "STARCH", "WHEAT" or "NO_FORAGE" (what holds it there)
function RLFeedMath.getConcentrateLimit(forage, concentrate, rules, wheatShare, wheatMax)
    if concentrate == nil then return 0, nil end
    if forage == nil then return 0, "NO_FORAGE" end
    local limit, reason = 1, nil
    -- (1 - c) pe_f + c pe_c >= min
    if concentrate.peNdf < rules.peNdfMin then
        local c = forage.peNdf > rules.peNdfMin and (forage.peNdf - rules.peNdfMin) / (forage.peNdf - concentrate.peNdf) or 0
        if c < limit then limit, reason = c, "FIBRE" end
    end
    -- (1 - c) f_f + c f_c <= max
    if concentrate.fermentable > rules.fermentableMax then
        local c = forage.fermentable < rules.fermentableMax
            and (rules.fermentableMax - forage.fermentable) / (concentrate.fermentable - forage.fermentable) or 0
        if c < limit then limit, reason = c, "STARCH" end
    end
    if wheatShare > 0 then
        local c = wheatMax / wheatShare
        if c < limit then limit, reason = c, "WHEAT" end
    end
    return math.clamp(limit, 0, 1), reason
end


-- =============================================================================
-- Intake
-- =============================================================================

--- What an animal can eat (kg DM a real day) before the ration's bulk: by ration class, per
--- kg^0.75 (a lactating cow also by her milk), a calf moving to the growing value around weaning;
--- x the intake gene.
--- @param weight number kg
--- @param class string CALF, GROWING, LACTATING, DRY
--- @param intake table feedProfiles intake values
--- @param ctx table { milkKgPerDay, weaningX (age - weaning month), gene }
--- @return number kg DM a day
function RLFeedMath.getAppetite(weight, class, intake, ctx)
    local metabolic = math.max(weight, 1) ^ 0.75
    local perKg
    if class == "LACTATING" then
        return (intake.lactatingPerKgMetabolic * metabolic + intake.lactatingPerKgMilk * math.max(ctx.milkKgPerDay or 0, 0))
            * (ctx.gene or 1)
    elseif class == "DRY" then
        perKg = intake.dryPerKgMetabolic
    elseif class == "CALF" then
        local t = math.clamp(((ctx.weaningX or -1) + 1) / 2, 0, 1)
        perKg = intake.calfPerKgMetabolic + (intake.growingPerKgMetabolic - intake.calfPerKgMetabolic) * t
    else
        perKg = intake.growingPerKgMetabolic
    end
    return perKg * metabolic * (ctx.gene or 1)
end


--- NDF (kg a day) an animal's rumen holds: ndfFill x live weight x gene, by class.
function RLFeedMath.getFillCapacity(weight, class, intake, gene)
    local share = intake.ndfFillGrowing
    if class == "LACTATING" then share = intake.ndfFillLactating
    elseif class == "DRY" then share = intake.ndfFillDry
    elseif class == "CALF" then share = intake.ndfFillCalf end
    return share * math.max(weight, 0) * (gene or 1)
end


--- Intake of a ration (kg DM over a period): what the animal can eat, what the ration's bulk lets
--- it (fill / NDF), and - unless it eats freely - what meets its energy demand. All three over the
--- same period (a day, or a step).
--- @param appetite number kg DM
--- @param fill number kg NDF
--- @param ration table { me, ndf }
--- @param demandME number|nil MJ it eats for; nil: eats freely
--- @return number kg DM
--- @return string limit "APPETITE", "FILL" or "DEMAND"
function RLFeedMath.getIntake(appetite, fill, ration, demandME)
    local intake, limit = appetite, "APPETITE"
    if ration.ndf > 0 then
        local bulk = fill / ration.ndf
        if bulk < intake then intake, limit = bulk, "FILL" end
    end
    if demandME ~= nil and ration.me > 0 then
        local demand = math.max(demandME, 0) / ration.me
        if demand < intake then intake, limit = demand, "DEMAND" end
    end
    return math.max(intake, 0), limit
end


-- =============================================================================
-- Protein
-- =============================================================================

--- Crude protein (share of DM) a ration needs for full growth or milk, by class and age; a calf's
--- moves from the young value to the calf value with the share of milk it may still drink.
--- @param class string
--- @param ageMonths number
--- @param protein table feedProfiles protein values
--- @param milkMax number|nil A calf's milk cap (0..1)
--- @return number
function RLFeedMath.getProteinNeed(class, ageMonths, protein, milkMax)
    if class == "CALF" then return protein.young + (protein.calf - protein.young) * math.clamp(milkMax or 1, 0, 1) end
    if class == "LACTATING" then return protein.lactating end
    if class == "DRY" then return protein.dry end
    if ageMonths < protein.youngUntilMonth then return protein.young end
    if ageMonths < protein.growingUntilMonth then return protein.growing end
    return protein.finishing
end


--- Share of its growth or milk potential a ration's protein allows: 1 at the need, falling
--- linearly to 0 at the maintenance level.
--- @param cp number Ration crude protein (share of DM)
--- @param need number
--- @param maintenance number
--- @return number 0..1
function RLFeedMath.getProteinFactor(cp, need, maintenance)
    if need <= maintenance then return 1 end
    return math.clamp((cp - maintenance) / (need - maintenance), 0, 1)
end


-- =============================================================================
-- Rumen adaptation
-- =============================================================================

--- Move the concentrate share an animal is adapted to toward the share it ate, by at most
--- adaptationMaxShare / adaptationDays a model day either way (a linear step-up or step-down).
--- @param adapted number 0..1
--- @param eaten number Concentrate share it ate this step
--- @param dtDays number Model days the step covers
--- @param ration table feedProfiles ration values
--- @return number
function RLFeedMath.adapt(adapted, eaten, dtDays, ration)
    local rate = ration.adaptationMaxShare / ration.adaptationDays * dtDays
    local delta = math.clamp(eaten - (adapted or 0), -rate, rate)
    return math.clamp((adapted or 0) + delta, 0, 1)
end


--- Most concentrate an animal adapted to `adapted` may eat over a step of dtDays: stepAllowance
--- above the adaptation it has halfway through the step (so the ramp is the same at any step
--- length).
function RLFeedMath.getAdaptedLimit(adapted, ration, dtDays)
    local midStep = 0.5 * ration.adaptationMaxShare / ration.adaptationDays * (dtDays or 0)
    return math.clamp((adapted or 0) + ration.stepAllowance + midStep, 0, 1)
end


--- What a kg DM of concentrate is worth to an animal eating share c of it while adapted to
--- `adapted`: the part above its adaptation at unadaptedUtilisation.
--- @return number factor 0..1 on the concentrate's ME
function RLFeedMath.getUtilisation(c, adapted, ration)
    if c <= 0 then return 1 end
    local within = math.min(c, math.max(adapted or 0, 0))
    return (within + (c - within) * ration.unadaptedUtilisation) / c
end


-- =============================================================================
-- Health
-- =============================================================================

--- The share of an hour's maintenance and pregnancy the feed and the reserve did not pay for:
--- frame broken down plus anything left unpaid, and - from below lowReserve - what the reserve had
--- to give as well.
--- @param ctx table { supply, maintenance, pregnancy, catabolism, unpaid, mobilized, reserve, lowReserve }
--- @return number 0..1
function RLFeedMath.getShortfall(ctx)
    local need = (ctx.maintenance or 0) + (ctx.pregnancy or 0)
    if need <= 0 or (ctx.supply or 0) >= need then return 0 end
    local short = (ctx.catabolism or 0) + (ctx.unpaid or 0)
    if (ctx.reserve or 1) < (ctx.lowReserve or 0) then short = short + (ctx.mobilized or 0) end
    return math.clamp(short / need, 0, 1)
end


--- Model days of shortfall an animal has built up: each step adds its shortfall share x its days,
--- a fully fed step takes days off at the same rate.
function RLFeedMath.updateShortDays(days, shortfall, fed, dtDays)
    if shortfall > 0 then return (days or 0) + shortfall * dtDays end
    if fed then return math.max((days or 0) - dtDays, 0) end
    return days or 0
end


--- The nutrition part of an hour's health change, from that hour's budget: positive while feed
--- pays for maintenance and pregnancy; none while the reserve covers a shortfall, or the frame
--- covers a short one (up to bufferDays of shortfall built up) from above lowReserve; otherwise
--- negative by the share left to frame breakdown or unpaid. Missing water and protein below the
--- maintenance level stop recovery and cost health by how short they are.
--- @param ctx table { supply, maintenance, pregnancy (energy this step), shortfall (getShortfall),
---        shortDays, bufferDays, reserve, lowReserve, water (0..1), cp, cpMaintenance, eatenDm }
--- @return number factor -1..1
--- @return string reason "FED", "BUFFERED", "SHORT", "WATER", "PROTEIN"
function RLFeedMath.getHealthFactor(ctx)
    local need = (ctx.maintenance or 0) + (ctx.pregnancy or 0)
    local factor, reason = 1, "FED"
    if need > 0 and (ctx.supply or 0) < need then
        local shortfall = ctx.shortfall or 0
        local low = (ctx.reserve or 1) < (ctx.lowReserve or 0)
        if shortfall > 0 and (low or (ctx.shortDays or 0) > (ctx.bufferDays or 0)) then
            factor, reason = -shortfall, "SHORT"
        else
            factor, reason = 0, "BUFFERED"
        end
    end
    -- Missing water or protein below the maintenance level: no recovery, and the larger loss.
    local function worse(value, why)
        if factor > 0 then factor = 0 end
        if value < factor then factor, reason = value, why end
    end
    local water = ctx.water or 1
    if water < 1 then worse(-(1 - math.clamp(water, 0, 1)), "WATER") end
    if (ctx.eatenDm or 0) > 0 and ctx.cpMaintenance ~= nil and ctx.cp ~= nil and ctx.cp < ctx.cpMaintenance then
        worse(-0.5 * (ctx.cpMaintenance - ctx.cp) / ctx.cpMaintenance, "PROTEIN")
    end
    return math.clamp(factor, -1, 1), reason
end
