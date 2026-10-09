--[[
    RLNutritionMath.lua
    Pure body condition arithmetic: the hourly nutrition budget, the reserve and weight it moves,
    and the curves that turn the reserve into a finish score, a BCS and the yield, price and
    conception factors. No engine globals, no randomness: the same inputs give the same result.

    Units. Everything is per period (one in-game month) and multiplied by dtMonths for a step.
    Energy is in NU, a relative nutrition unit (not MJ): xml/bodyCondition.xml sets what a kg of
    growth, a kg of reserve, a liter of milk and a kg^0.75 of maintenance cost in it.

    The reserve r (0..1) is an abstract body reserve, not a fat percentage. One unit of r is
    capacityKg of live weight, so a change in r always moves the animal's weight.
]]

RLNutritionMath = {}


--- Piecewise linear interpolation over {{x, y}, ...} sorted by x, flat beyond the ends.
--- @param points table
--- @param x number
--- @return number
function RLNutritionMath.interpolate(points, x)
    local n = #points
    if n == 0 then return 1 end
    if x <= points[1][1] then return points[1][2] end
    if x >= points[n][1] then return points[n][2] end

    for i = 2, n do
        local x1, y1 = points[i][1], points[i][2]
        if x <= x1 then
            local x0, y0 = points[i - 1][1], points[i - 1][2]
            if x1 == x0 then return y1 end
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        end
    end

    return points[n][2]
end


--- Weight of the current sample in an exponential moving average with time constant tau.
--- Time-continuous, so a 1-day and a 28-day period remember the same number of months.
--- @param dtMonths number
--- @param tauMonths number
--- @return number alpha 0..1
function RLNutritionMath.emaAlpha(dtMonths, tauMonths)
    if tauMonths <= 0 then return 1 end
    return 1 - math.exp(-dtMonths / tauMonths)
end


--- BCS (1..5) of a reserve: 1 + 4r.
function RLNutritionMath.getBCS(reserve)
    return 1 + 4 * reserve
end


--- Weight the reserve stands for above (or below) the reference reserve: K x (r - rRef).
--- weight - this is the animal's frame (structural) weight.
--- @param reserve number
--- @param capacityKg number
--- @param referenceReserve number
--- @return number kg
function RLNutritionMath.getReserveWeightOffset(reserve, capacityKg, referenceReserve)
    return capacityKg * (reserve - referenceReserve)
end


--- One budget step for one animal.
---
--- Supply. What the animal ate this step, in liters of full TMR ration: the liters allocated to it
--- from the pen's actual consumption, each fill type times its energy and the breed's digestion of
--- it. A liter is worth what the reference intake (referenceLiters) pays for, times intakeCapacity:
---   need-based price (no referenceWeight): the animal's own full-feed demand - maintenance at its
---     weight, pregnancy, its growth line and the lactation-average milk at average productivity.
---     The same liters are worth more to an animal that needs more (a heavier body, a steer).
---   fixed price (referenceWeight given): the demand of a reference animal - maintenance at
---     referenceWeight, pregnancy, growth referenceGrowthKg, milk anchorMilk - whatever this
---     animal needs now. A disease's lost growth (diseaseLossKg) is then spent on the disease.
--- An animal eating its reference ration at its reference meets its demand and the old growth
--- line holds; one that eats more liters (a high-yield cow's extra intake, a bigger frame, more of
--- the trough) gets more, one that eats fewer or poorer liters gets less.
---
--- Allocation, in order: maintenance, pregnancy, then growth and milk (milk weighted by
--- milkPriority while lactating). A shortfall in maintenance and pregnancy is covered from the
--- reserve; a lactating animal may also cover part of a milk shortfall from it. What is still
--- missing comes from frame tissue (maintenance only) and then stays as an unmet deficit. A
--- surplus is stored in the reserve up to the ceiling and the monthly gain rate; the rest is lost.
---
--- Growth to reserve. While the reserve is below the stage target, part of the growth line is
--- laid down as reserve instead of frame, so the total gain is the old growth line.
---
--- Weight floor. No step takes the animal below minWeight: age loss, reserve drawn and frame
--- catabolised are limited before they are booked, so the weight change is always the sum of its
--- parts and the energy ledger closes.
---
--- @param input table See the field list at the top of the function
--- @param cfg table RLBodyConditionConfig values
--- @return table result
function RLNutritionMath.step(input, cfg)
    -- input fields (per period unless noted):
    --   dtMonths              months this step covers
    --   weight, reserve, capacityKg, minWeight
    --   targetWeight          frame weight the animal grows to
    --   potentialGrowthKg     growth line at full feed (>= 0)
    --   ageLossKg             age-driven frame loss (>= 0)
    --   potentialMilk         milk at full feed after the water cap (liters)
    --   anchorMilk            lactation-average milk at average productivity (liters)
    --   isLactating, pregnancyProgress (0..1), numFetuses
    --   intakeLiters          liters of full TMR ration it ate (energy and digestion applied)
    --   referenceLiters       liters the reference animal requests on full feed
    --   referenceWeight       fixed price: the reference animal's weight (nil = need-based price)
    --   referenceGrowthKg     fixed price: the reference animal's growth
    --   diseaseLossKg         fixed price: growth a disease takes (paid with growth, gains nothing)
    --   intakeCapacity        kappa for the animal's state
    --   reserveTarget         stage target that growth is diverted to (nil = no diversion)
    --   reserveCeiling        highest reserve a surplus fills to
    --   balanceEMA, lossRateEMA
    local dt = input.dtMonths
    local K = input.capacityKg
    local r = input.reserve
    local W = input.weight
    local floor = math.min(math.max(input.minWeight or 0, 0), W)

    -- Frame weight: the reserve's share of live weight taken out.
    local frame = W - RLNutritionMath.getReserveWeightOffset(r, K, cfg.referenceReserve)

    -- Growth line, split between frame and reserve. Above the target frame no frame grows.
    local growthKg = math.max(input.potentialGrowthKg or 0, 0)
    if frame >= input.targetWeight then growthKg = 0 end

    local divertKg = 0
    if input.reserveTarget ~= nil and r < input.reserveTarget and growthKg > 0 and dt > 0 then
        local wantedDelta = math.min(input.reserveTarget - r, cfg.gainRatePerMonth * dt)
        divertKg = math.min(growthKg, wantedDelta * K / dt)
    end
    local frameGrowthKg = growthKg - divertKg
    local fixedPrice = input.referenceWeight ~= nil
    local diseaseKg = (fixedPrice and growthKg > 0) and math.max(input.diseaseLossKg or 0, 0) or 0

    -- Demands (NU per period).
    local maintenance = cfg.maintenancePerKgMetabolic * math.max(W, 1) ^ 0.75
    local ramp = math.clamp(((input.pregnancyProgress or 0) - cfg.pregnancyRampStart) / (1 - cfg.pregnancyRampStart), 0, 1)
    local pregnancy = maintenance * cfg.pregnancyFactor * (input.numFetuses or 0) * ramp
    local growthNeed = (frameGrowthKg + diseaseKg) * cfg.growthNUPerKg + divertKg * cfg.depositNUPerKg
    local milkNeed = math.max(input.potentialMilk or 0, 0) * cfg.milkNUPerLiter

    -- Supply (NU per period): the liters eaten, valued at what the reference intake pays for.
    local anchor
    if fixedPrice then
        local referenceMaintenance = cfg.maintenancePerKgMetabolic * math.max(input.referenceWeight, 1) ^ 0.75
        anchor = referenceMaintenance * (1 + cfg.pregnancyFactor * (input.numFetuses or 0) * ramp)
            + math.max(input.referenceGrowthKg or 0, 0) * cfg.growthNUPerKg
    else
        anchor = maintenance + pregnancy + growthKg * cfg.growthNUPerKg
    end
    anchor = anchor + math.max(input.anchorMilk or 0, 0) * cfg.milkNUPerLiter
    local nuPerLiter = 0
    if (input.referenceLiters or 0) > 0 then nuPerLiter = input.intakeCapacity * anchor / input.referenceLiters end
    local supply = math.max(input.intakeLiters or 0, 0) * nuPerLiter

    -- Step amounts.
    local avail = supply * dt
    local needM, needP, needG, needL = maintenance * dt, pregnancy * dt, growthNeed * dt, milkNeed * dt

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

    -- Weight that may still be lost this step: age loss first, then reserve, then frame.
    local lossRoom = W - floor
    local ageLossKg = math.min(math.max(input.ageLossKg or 0, 0) * dt, lossRoom)
    lossRoom = lossRoom - ageLossKg

    -- Reserve mobilisation, capped by the floor, the monthly loss rate, how easily a thin animal
    -- gives up what it has left, and the weight floor.
    local ease = math.clamp((r - cfg.minReserve) / cfg.mobilizeEaseRange, 0, 1)
    local maxDrop = math.max(math.min(r - cfg.minReserve, cfg.lossRatePerMonth * dt), 0) * ease
    local mobilizableNU = math.min(maxDrop * K, lossRoom) * cfg.mobilizeNUPerKg

    local deficitM, deficitP = needM - paidM, needP - paidP
    local mobilizedNU = 0

    local cover = math.min(mobilizableNU, deficitM)
    paidM = paidM + cover; deficitM = deficitM - cover; mobilizedNU = mobilizedNU + cover

    cover = math.min(mobilizableNU - mobilizedNU, deficitP)
    paidP = paidP + cover; deficitP = deficitP - cover; mobilizedNU = mobilizedNU + cover

    -- A thin cow stops giving her reserve to milk: below milkMobilizeFloor she gives less milk.
    if input.isLactating and needL > paidL then
        local milkEase = math.clamp((r - cfg.milkMobilizeFloor) / cfg.mobilizeEaseRange, 0, 1)
        cover = math.min(mobilizableNU - mobilizedNU, needL - paidL, cfg.milkMobilizeShare * needL * milkEase)
        cover = math.max(cover, 0)
        paidL = paidL + cover; mobilizedNU = mobilizedNU + cover
    end

    local mobilizedKg = mobilizedNU / cfg.mobilizeNUPerKg
    lossRoom = math.max(lossRoom - mobilizedKg, 0)

    -- Maintenance the reserve could not cover comes out of the frame, at most
    -- maxCatabolismPerMonth of the weight a month and never below the floor; beyond that it
    -- stays unmet.
    local catabolismKg, catabolismNU = 0, 0
    if deficitM > 0 then
        catabolismKg = math.min(deficitM / cfg.catabolismNUPerKg, W * cfg.maxCatabolismPerMonth * dt, lossRoom)
        catabolismNU = catabolismKg * cfg.catabolismNUPerKg
        paidM = paidM + catabolismNU
        deficitM = deficitM - catabolismNU
        lossRoom = lossRoom - catabolismKg
    end

    -- Surplus into the reserve: one direction per step, so only when nothing was mobilised.
    local growthFraction = needG > 0 and paidG / needG or 1
    local divertedKg = divertKg * dt * growthFraction
    local depositKg = 0
    if surplus > 0 and mobilizedNU <= 0 then
        local divertedDelta = K > 0 and divertedKg / K or 0
        local room = math.min((input.reserveCeiling or r) - r - divertedDelta, cfg.gainRatePerMonth * dt - divertedDelta)
        depositKg = math.min(surplus / cfg.depositNUPerKg, math.max(room, 0) * K)
    end
    local depositNU = depositKg * cfg.depositNUPerKg
    local lostNU = surplus - depositNU

    -- Frame changes.
    local frameGainKg = frameGrowthKg * dt * growthFraction
    local frameAfter = frame + frameGainKg - ageLossKg - catabolismKg
    local excessDecayKg = 0
    if frameAfter > input.targetWeight then
        excessDecayKg = (frameAfter - input.targetWeight) * (1 - math.exp(-dt / cfg.frameExcessTauMonths))
    end
    excessDecayKg = math.min(excessDecayKg, math.max(lossRoom + frameGainKg + divertedKg + depositKg, 0))

    local reserveKg = divertedKg + depositKg - mobilizedKg
    local newReserve = K > 0 and r + reserveKg / K or r
    local newWeight = W + frameGainKg + reserveKg - ageLossKg - catabolismKg - excessDecayKg

    -- Trends.
    local demand = maintenance + pregnancy + growthNeed + milkNeed
    local balance = demand > 0 and (supply - demand) / demand or 0
    local alpha = RLNutritionMath.emaAlpha(dt, cfg.trendTauMonths)
    local lossRate = dt > 0 and math.max(r - newReserve, 0) / dt or 0

    local milkFraction = needL > 0 and paidL / needL or 1

    return {
        weight = newWeight,
        reserve = newReserve,
        balanceEMA = (input.balanceEMA or 0) + alpha * (balance - (input.balanceEMA or 0)),
        lossRateEMA = (input.lossRateEMA or 0) + alpha * (lossRate - (input.lossRateEMA or 0)),
        milkFraction = milkFraction,
        growthFraction = growthFraction,
        frameGainKg = frameGainKg,
        reserveKg = reserveKg,
        ageLossKg = ageLossKg,
        excessDecayKg = excessDecayKg,
        catabolismKg = catabolismKg,
        coverage = demand > 0 and supply / demand or 1,
        -- Ledger (NU this step): supply + mobilised + catabolism = paid + deposit + lost.
        -- paidNU includes the growth laid down as reserve (divertedNU).
        supplyNU = supply * dt,
        mobilizedNU = mobilizedNU,
        catabolismNU = catabolismNU,
        paidNU = paidM + paidP + paidG + paidL,
        depositNU = depositNU,
        divertedNU = divertedKg * cfg.depositNUPerKg,
        lostNU = lostNU,
        unmetNU = deficitM + deficitP + (needG - paidG) + (needL - paidL),
        maintenanceDeficitNU = deficitM,
        demandNU = demand * dt,
    }
end
