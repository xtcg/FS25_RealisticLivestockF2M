--[[
    RLGrowthMath.lua
    Pure arithmetic of the cattle weight model v2 (RLGrowth): one budget step that moves an
    animal's frame, reserve and development together. No engine globals, no randomness.

    State. Live weight W is the one authority. It is split into
        R  reserve mass (kg): what the animal can lay down and draw on,
        F  frame (kg): the rest, F = W - R,
    and the development phase u (months): how far along its growth curve the frame is. F is a
    model quantity, not a measured skeleton weight; R is not a fat percentage or a BCS.
    One unit of the reserve index r (0..1, what BCS and finish score are read from) is
    K = capacity(F) kg, so r = R / K. The capacity grows with the frame; a bigger capacity does
    not create reserve mass.

    Curve. The animal's own curve C(u) is its live weight at the reference reserve rRef. Its
    frame at development u is F_ref(u) = C(u) / (1 + rRef x kappa), kappa = K / F.

    Growth. At full feed development advances by speed x dt months (capped at the curve's end)
    and the frame by F_ref(u + du) - F_ref(u). New frame is laid down at the animal's current
    reserve index, so growing neither fattens nor thins it. Only the growth the budget pays for
    happens: a fraction f paid adds f of that frame, and u moves to where the curve has the new
    frame (never back while growing). A starving animal does not develop, and
    when it is fed again it continues from where it is - no jump to its calendar age, no
    unbounded catch-up. Once the frame is grown no more frame grows; a surplus can only go into
    the reserve, up to its ceiling and monthly rate.

    Budget, in this order: maintenance (maintenancePerKgMetabolic x W^0.75 x the maintenance
    gene), pregnancy, then growth and milk (milk weighted by milkPriority). A shortfall in
    maintenance and pregnancy is covered from the reserve (rate-limited, harder near its floor);
    a lactating cow may cover part of a milk shortfall from it, a thin one none. Maintenance the
    reserve cannot cover comes out of the frame (rate-limited, never below frameFloorKg); then u
    is put back where the curve has that frame. A surplus is laid down as reserve only in a step
    that drew none (no free cycling: depositNUPerKg > mobilizeNUPerKg).

    Ledger, every step: supply + mobilised + catabolised = paid + deposited + lost, and
    W' = W + frame grown + reserve laid with it + reserve deposited - mobilised - catabolised.
]]

RLGrowthMath = {}


--- Reserve capacity K (kg per unit of reserve index) of a frame: one unit is
--- reserveCapacityRatio of the live weight of that frame at the reference reserve.
--- K = c x F / (1 - c x rRef), so K / (F + rRef x K) = c.
--- @param frameKg number
--- @param ratio number reserveCapacityRatio (bodyCondition.xml)
--- @param referenceReserve number
--- @return number kg
function RLGrowthMath.getCapacity(frameKg, ratio, referenceReserve)
    return math.max(frameKg, 0) * RLGrowthMath.getKappa(ratio, referenceReserve)
end


--- kappa = K / F.
--- @param ratio number
--- @param referenceReserve number
--- @return number
function RLGrowthMath.getKappa(ratio, referenceReserve)
    return ratio / math.max(1 - ratio * referenceReserve, 0.05)
end


--- Split a live weight at reserve index r into frame and reserve: F = W / (1 + r x kappa),
--- R = W - F. The weight is unchanged: F + R = W.
--- @param weight number kg
--- @param reserve number Reserve index r
--- @param kappa number
--- @return number frameKg
--- @return number reserveKg
function RLGrowthMath.split(weight, reserve, kappa)
    local frame = weight / (1 + math.max(reserve, 0) * kappa)
    return frame, weight - frame
end


--- Frame on the curve at development u.
--- @param curve table RLGrowthCurve
--- @param u number Months
--- @param kappa number
--- @param referenceReserve number
--- @return number kg
function RLGrowthMath.getReferenceFrame(curve, u, kappa, referenceReserve)
    return curve:value(u) / (1 + referenceReserve * kappa)
end


--- Development phase of a frame: where the curve has this frame (0 at or below birth, the
--- curve's end at or above its adult frame).
--- @param curve table
--- @param frameKg number
--- @param kappa number
--- @param referenceReserve number
--- @return number months
function RLGrowthMath.getDevelopment(curve, frameKg, kappa, referenceReserve)
    return curve:inverse(frameKg * (1 + referenceReserve * kappa))
end


--- The frame growth a step would add at full feed, the development it takes, and the reserve
--- laid down with that frame at index `reserve`.
--- @param curve table
--- @param u number
--- @param frameKg number
--- @param speed number Development months per month at full feed (genes, stage, disease)
--- @param dt number Months
--- @param kappa number
--- @param referenceReserve number
--- @param reserve number Reserve index r new frame is laid down at
--- @return number frameKg
--- @return number developmentMonths
--- @return number reserveKg
function RLGrowthMath.getPotentialGrowth(curve, u, frameKg, speed, dt, kappa, referenceReserve, reserve)
    local du = math.max(math.min(math.max(speed, 0) * dt, curve.endMonth - u), 0)
    if du <= 0 then return 0, 0, 0 end
    local scale = 1 + referenceReserve * kappa
    local gain = math.max((curve:value(u + du) - curve:value(u)) / scale, 0)
    -- Never past the adult frame (a frame above it - an old savegame's - grows no more).
    gain = math.min(gain, math.max(curve.endWeight / scale - frameKg, 0))
    return gain, du, gain * math.max(reserve, 0) * kappa
end


--- Maintenance and pregnancy demand (per period) of an animal of weight W: maintenance x W^0.75
--- x the maintenance gene; a pregnancy adds pregnancyFactor of the maintenance per fetus, rising
--- from pregnancyRampStart of the pregnancy to term.
--- @return number maintenance
--- @return number pregnancy
--- @return number ramp 0..1
local function getMaintenanceAndPregnancy(W, input, cfg)
    local metabolic = math.max(W, 1) ^ 0.75
    local maintenance = cfg.maintenancePerKgMetabolic * metabolic * (input.maintenanceFactor or 1)
    local ramp = math.clamp(((input.pregnancyProgress or 0) - cfg.pregnancyRampStart) / (1 - cfg.pregnancyRampStart), 0, 1)
    local pregnancy = cfg.maintenancePerKgMetabolic * metabolic * cfg.pregnancyFactor * (input.numFetuses or 0) * ramp
    return maintenance, pregnancy, ramp
end


--- What a step would ask for, before any feed is eaten (RLFeed plans a ration on it): per period,
--- maintenance, pregnancy and milk at full feed; for the step, the growth at full feed (frame and
--- the reserve laid with it, development speed and disease applied) and the most reserve it could
--- lay down on top, up to `reserveCeiling` (the input's) at the monthly gain rate.
--- @param input table As for step
--- @param cfg table
--- @return table { maintenance, pregnancy, milk (per period), growthStep, growthKg, depositRoomKg (this
---         step), depositHeadroomKg (to the ceiling), depositRatePerMonthKg }
function RLGrowthMath.getStepDemands(input, cfg)
    local dt = input.dtMonths
    local kappa = input.kappa
    local curve = input.curve
    local W = input.weight
    local R = math.min(math.max(input.reserveKg or 0, 0), W)
    local F = W - R
    local u = math.min(math.max(input.development or 0, 0), curve.endMonth)
    local K = F * kappa
    local r = K > 0 and R / K or 0
    local disease = math.clamp(input.diseaseFactor or 1, 0, 1)
    local growF, _, growR = RLGrowthMath.getPotentialGrowth(curve, u, F, (input.speed or 1) * disease, dt, kappa,
        cfg.referenceReserve, r)
    local maintenance, pregnancy = getMaintenanceAndPregnancy(W, input, cfg)
    local capacityAfter = K + growF * kappa
    local rAfter = capacityAfter > 0 and (R + growR) / capacityAfter or 0
    local headroom = math.max((input.reserveCeiling or rAfter) - rAfter, 0)
    local room = math.min(headroom, cfg.gainRatePerMonth * dt) * capacityAfter
    return {
        maintenance = maintenance,
        pregnancy = pregnancy,
        milk = math.max(input.potentialMilk or 0, 0) * (input.milkCostPerLiter or cfg.milkNUPerLiter),
        growthStep = growF * (input.growthCostPerKg or cfg.growthNUPerKg) + growR * cfg.depositNUPerKg,
        growthKg = growF + growR,
        depositRoomKg = math.max(room, 0),
        -- As rates, the same at any step length: reserve that fits under the ceiling, and the most
        -- the monthly gain rate lays down in a month.
        depositHeadroomKg = headroom * capacityAfter,
        depositRatePerMonthKg = cfg.gainRatePerMonth * capacityAfter,
    }
end


--- One step.
--- @param input table See the field list at the top of the function
--- @param cfg table RLBodyConditionConfig values
--- @return table result
function RLGrowthMath.step(input, cfg)
    -- input fields (per period unless noted):
    --   dtMonths, weight, reserveKg, development, curve
    --   kappa, frameFloorKg
    --   speed                 development months per month at full feed (genes x stage)
    --   diseaseFactor         disease's weight-gain multiplier (0..1): slows development
    --   maintenanceFactor     maintenance gene
    --   potentialMilk, anchorMilk, isLactating, pregnancyProgress, numFetuses
    --   intakeLiters          liters of full ration eaten (energy and digestion applied)
    --   referenceLiters       liters the anchor's animal requests on full feed
    --   intakeCapacity        kappa_intake for the animal's state
    --   fixedPrice            true: anchor = referenceWeight / referenceGrowthNU (a reference
    --                         animal); false / nil: the animal's own full-feed demand
    --   referenceWeight, referenceGrowthNU
    --   reserveCeiling        highest reserve index a surplus fills to
    --   balanceEMA, lossRateEMA
    --   supplyPerPeriod       optional: the energy eaten (per period) as it is, replacing the
    --                         liters valued at the anchor above (RLFeed, real-equivalent mode)
    --   growthCostPerKg       optional: energy per kg of frame grown (default growthNUPerKg)
    --   milkCostPerLiter      optional: energy per liter of milk (default milkNUPerLiter)
    --   milkMobilizeShare     optional: share of the milk the reserve may fund (default the cfg's)
    local dt = input.dtMonths
    local kappa = input.kappa
    local rRef = cfg.referenceReserve
    local curve = input.curve
    local W = input.weight
    local R = math.min(math.max(input.reserveKg or 0, 0), W)
    local F = W - R
    local u = math.min(math.max(input.development or 0, 0), curve.endMonth)
    local K = F * kappa
    local r = K > 0 and R / K or 0
    local frameFloor = math.min(math.max(input.frameFloorKg or 0, 0), F)

    -- Growth at full feed. A disease slows development; under the fixed price its lost growth
    -- is still paid for (the energy is spent on the disease) and gains nothing.
    local disease = math.clamp(input.diseaseFactor or 1, 0, 1)
    local healthyF = RLGrowthMath.getPotentialGrowth(curve, u, F, input.speed or 1, dt, kappa, rRef, r)
    local growF, _, growR = RLGrowthMath.getPotentialGrowth(curve, u, F, (input.speed or 1) * disease, dt, kappa, rRef, r)
    local fixedPrice = input.fixedPrice == true
    local diseaseKg = fixedPrice and math.max(healthyF - growF, 0) or 0

    -- Demands (NU per period).
    local maintenance, pregnancy, ramp = getMaintenanceAndPregnancy(W, input, cfg)
    local growthNeedStep = (growF + diseaseKg) * (input.growthCostPerKg or cfg.growthNUPerKg) + growR * cfg.depositNUPerKg
    local growthNeed = dt > 0 and growthNeedStep / dt or 0
    local milkNeed = math.max(input.potentialMilk or 0, 0) * (input.milkCostPerLiter or cfg.milkNUPerLiter)

    -- Supply (NU per period). Given (supplyPerPeriod): the energy the feed eaten carries, fixed by
    -- the feed alone (RLFeed). Otherwise the liters eaten, valued at what the anchor's full feed
    -- pays for.
    local supply
    if input.supplyPerPeriod ~= nil then
        supply = math.max(input.supplyPerPeriod, 0)
    else
        local anchor
        if fixedPrice then
            local referenceMetabolic = math.max(input.referenceWeight or W, 1) ^ 0.75
            anchor = cfg.maintenancePerKgMetabolic * referenceMetabolic * (1 + cfg.pregnancyFactor * (input.numFetuses or 0) * ramp)
                + math.max(input.referenceGrowthNU or 0, 0)
        else
            anchor = maintenance + pregnancy + growthNeed
        end
        anchor = anchor + math.max(input.anchorMilk or 0, 0) * cfg.milkNUPerLiter
        local nuPerLiter = 0
        if (input.referenceLiters or 0) > 0 then nuPerLiter = (input.intakeCapacity or 1) * anchor / input.referenceLiters end
        supply = math.max(input.intakeLiters or 0, 0) * nuPerLiter
    end

    -- Step amounts.
    local avail = supply * dt
    local needM, needP, needG, needL = maintenance * dt, pregnancy * dt, growthNeedStep, milkNeed * dt

    local paidM = math.min(avail, needM); avail = avail - paidM
    local paidP = math.min(avail, needP); avail = avail - paidP

    local paidG, paidL, surplus = 0, 0, 0
    if avail >= needG + needL then
        paidG, paidL = needG, needL
        surplus = avail - needG - needL
    elseif avail > 0 then
        local wL = input.isLactating and cfg.milkPriority or 1
        local weightL, weightG = wL * needL, needG
        if weightL + weightG > 0 then paidL = math.min(needL, avail * weightL / (weightL + weightG)) end
        paidG = math.min(needG, avail - paidL)
        paidL = math.min(needL, avail - paidG)
    end

    -- Reserve mobilisation: rate-limited, harder near the floor, never below the reserve floor.
    local ease = math.clamp((r - cfg.minReserve) / cfg.mobilizeEaseRange, 0, 1)
    local maxDrop = math.max(math.min(r - cfg.minReserve, cfg.lossRatePerMonth * dt), 0) * ease
    local mobilizableNU = math.min(maxDrop * K, R) * cfg.mobilizeNUPerKg

    local deficitM, deficitP = needM - paidM, needP - paidP
    local mobilizedNU = 0

    local cover = math.min(mobilizableNU, deficitM)
    paidM = paidM + cover; deficitM = deficitM - cover; mobilizedNU = mobilizedNU + cover

    cover = math.min(mobilizableNU - mobilizedNU, deficitP)
    paidP = paidP + cover; deficitP = deficitP - cover; mobilizedNU = mobilizedNU + cover

    -- A thin cow stops giving her reserve to milk: below milkMobilizeFloor she gives less milk.
    if input.isLactating and needL > paidL then
        local milkEase = math.clamp((r - cfg.milkMobilizeFloor) / cfg.mobilizeEaseRange, 0, 1)
        cover = math.min(mobilizableNU - mobilizedNU, needL - paidL, (input.milkMobilizeShare or cfg.milkMobilizeShare) * needL * milkEase)
        cover = math.max(cover, 0)
        paidL = paidL + cover; mobilizedNU = mobilizedNU + cover
    end

    local mobilizedKg = mobilizedNU / cfg.mobilizeNUPerKg

    -- Maintenance the reserve could not cover comes out of the frame: at most
    -- maxCatabolismPerMonth of the weight a month, never below the frame floor.
    local catabolismKg, catabolismNU = 0, 0
    if deficitM > 0 then
        catabolismKg = math.max(math.min(deficitM / cfg.catabolismNUPerKg, W * cfg.maxCatabolismPerMonth * dt, F - frameFloor), 0)
        catabolismNU = catabolismKg * cfg.catabolismNUPerKg
        paidM = paidM + catabolismNU
        deficitM = deficitM - catabolismNU
    end

    -- Growth paid for: frame and the reserve laid down with it, development by the same share.
    local growthFraction = needG > 0 and paidG / needG or 1
    local frameGainKg = growF * growthFraction
    local growthReserveKg = growR * growthFraction

    -- Surplus into the reserve: one direction per step, so only when nothing was mobilised.
    local depositKg = 0
    if surplus > 0 and mobilizedNU <= 0 then
        local frameAfter = F + frameGainKg - catabolismKg
        local capacityAfter = frameAfter * kappa
        local reserveAfter = R + growthReserveKg
        local rAfter = capacityAfter > 0 and reserveAfter / capacityAfter or 0
        local room = math.min((input.reserveCeiling or rAfter) - rAfter, cfg.gainRatePerMonth * dt) * capacityAfter
        depositKg = math.min(surplus / cfg.depositNUPerKg, math.max(room, 0))
    end
    local depositNU = depositKg * cfg.depositNUPerKg
    local lostNU = surplus - depositNU

    local newF = F + frameGainKg - catabolismKg
    local newR = R + growthReserveKg + depositKg - mobilizedKg
    local newW = newF + newR

    -- Development is where the curve has the new frame, so frame and development never drift
    -- apart (a share f of a curved step is not f of its development); unchanged when the frame is.
    local newU = u
    if frameGainKg > 0 or catabolismKg > 0 then
        newU = math.min(RLGrowthMath.getDevelopment(curve, newF, kappa, rRef), curve.endMonth)
        if catabolismKg <= 0 then newU = math.max(newU, u) end
    end

    local newK = newF * kappa
    local newReserve = newK > 0 and newR / newK or 0

    -- Trends.
    local demand = maintenance + pregnancy + growthNeed + milkNeed
    local balance = demand > 0 and (supply - demand) / demand or 0
    local alpha = (cfg.trendTauMonths or 0) > 0 and 1 - math.exp(-dt / cfg.trendTauMonths) or 1
    local lossRate = dt > 0 and math.max(r - newReserve, 0) / dt or 0
    local milkFraction = needL > 0 and paidL / needL or 1

    return {
        weight = newW,
        reserveKg = newR,
        frameKg = newF,
        development = newU,
        reserve = newReserve,
        capacityKg = newK,
        balanceEMA = (input.balanceEMA or 0) + alpha * (balance - (input.balanceEMA or 0)),
        lossRateEMA = (input.lossRateEMA or 0) + alpha * (lossRate - (input.lossRateEMA or 0)),
        milkFraction = milkFraction,
        growthFraction = growthFraction,
        frameGainKg = frameGainKg,
        growthReserveKg = growthReserveKg,
        depositKg = depositKg,
        mobilizedKg = mobilizedKg,
        catabolismKg = catabolismKg,
        coverage = demand > 0 and supply / demand or 1,
        -- Ledger (NU this step): supply + mobilised + catabolism = paid + deposit + lost.
        supplyNU = supply * dt,
        mobilizedNU = mobilizedNU,
        catabolismNU = catabolismNU,
        paidNU = paidM + paidP + paidG + paidL,
        depositNU = depositNU,
        lostNU = lostNU,
        unmetNU = deficitM + deficitP + (needG - paidG) + (needL - paidL),
        maintenanceDeficitNU = deficitM,
        pregnancyDeficitNU = deficitP,
        maintenanceNU = needM,
        pregnancyNU = needP,
        demandNU = demand * dt,
    }
end
