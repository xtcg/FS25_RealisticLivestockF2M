--[[
    RLBodyConditionConsole.lua
    Console commands for testing body condition (RLBodyCondition) in game. Single player / server
    only, registered by RLConsoleCommandManager. Open the console with the development controls on
    (game.xml: <development><controls>true</controls></development>, then the ~ key).

    rlBcReport [animals] [pen]            Per cattle pen: last hour's feed ledger, water, condition
                                          range; with "animals" one line per animal (and, under the
                                          weight model v2, its birth and adult weight, development,
                                          reserve kg and weight against its curve).
    rlBcSet <reserve|bcs|finish> <value> <all|pen:NAME|uniqueId>
                                          Set the condition of animals. Frame weight is kept, so
                                          live weight moves with the reserve as in the game.
    rlBcFastForward <hours> [pen]         Run that many hourly cycles of the cattle pens at once:
                                          the real feeding, budget, milk and pallet code, with
                                          food, water and straw really consumed. Ages, days,
                                          months, pregnancies and diseases do not advance.

    [pen] / pen:NAME match any part of a pen's name, case-insensitive.
]]

RLBodyConditionConsole = {}


local function out(text)
    print(text)
end


--- Cattle pens the commands act on, optionally filtered by part of their name.
local function getPens(filter)
    local pens = {}
    local husbandrySystem = g_currentMission.husbandrySystem
    filter = filter ~= nil and filter:lower() or nil

    for _, placeable in ipairs(husbandrySystem.placeables) do
        if placeable.getAnimalTypeIndex ~= nil and placeable:getAnimalTypeIndex() == AnimalType.COW then
            local name = placeable.getName ~= nil and placeable:getName() or "?"
            if filter == nil or name:lower():find(filter, 1, true) ~= nil then
                table.insert(pens, placeable)
            end
        end
    end

    return pens
end


local function getConditionText(animal)
    if not RLBodyCondition.isEligible(animal) then return "calf/legacy" end
    if animal.gender == "male" then
        return string.format("F%3.0f", RLBodyCondition.getFinishScore(animal))
    end
    return string.format("BCS %.2f", RLBodyCondition.getBCS(animal))
end


--- rlBcReport [animals] [pen]
function RLBodyConditionConsole:report(arg1, arg2)
    local showAnimals = arg1 ~= nil and arg1:lower() == "animals"
    local filter = arg1
    if showAnimals then filter = arg2 end

    if not RLBodyCondition.isEnabled() then
        local reason = RLBodyCondition.getConfig().invalidReason
        out("rlBcReport: body condition is OFF" .. (reason ~= nil and (" (" .. reason .. ")") or ""))
    end

    local pens = getPens(filter)
    if #pens == 0 then return "rlBcReport: no cattle pen" .. (filter ~= nil and (" matching '" .. filter .. "'") or "") end

    for _, pen in ipairs(pens) do
        local foodSpec = pen.spec_husbandryFood
        local supply = foodSpec ~= nil and foodSpec.rlNutritionSupply or nil
        local water = foodSpec ~= nil and foodSpec.rlWaterCoverage or nil

        out(string.format("== %s (tick %s)", pen:getName(), tostring(RLBodyCondition.getTickId())))

        if supply == nil then
            out("   feed ledger: none yet (wait for the next game hour)")
        else
            local parts = {}
            for category, share in pairs(supply.energyShare) do
                table.insert(parts, string.format("%s %.2f", category, share))
            end
            table.sort(parts)
            local eaten = {}
            for fillTypeIndex, liters in pairs(supply.consumed) do
                table.insert(eaten, string.format("%s %.1f l", tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)), liters))
            end
            table.sort(eaten)
            out(string.format("   feed ledger tick %s: requested %.1f l, eaten %.1f l (%.0f%%) [%s]",
                tostring(supply.tick), supply.requested, supply.eaten,
                supply.requested > 0 and supply.eaten / supply.requested * 100 or 0, table.concat(eaten, ", ")))
            out(string.format("   energy per liter requested: %s   water %.0f%% (tick %s)",
                #parts > 0 and table.concat(parts, ", ") or "none",
                (water ~= nil and water.coverage or 1) * 100, water ~= nil and tostring(water.tick) or "-"))
        end

        local count, covered = 0, 0
        local minBCS, maxBCS, sumBCS, females = 9, 0, 0, 0
        local minF, maxF, sumF, males = 999, -1, 0, 0
        local thin, fat, milkSum, lactating = 0, 0, 0, 0

        for _, animal in ipairs(pen:getClusters()) do
            count = count + 1
            if RLBodyCondition.isEligible(animal) then
                covered = covered + 1
                if animal.gender == "male" then
                    local score = RLBodyCondition.getFinishScore(animal)
                    minF, maxF, sumF, males = math.min(minF, score), math.max(maxF, score), sumF + score, males + 1
                    if score > 90 then fat = fat + 1 end
                else
                    local bcs = RLBodyCondition.getBCS(animal)
                    minBCS, maxBCS, sumBCS, females = math.min(minBCS, bcs), math.max(maxBCS, bcs), sumBCS + bcs, females + 1
                    if bcs < 2.5 then thin = thin + 1 elseif bcs > 3.75 then fat = fat + 1 end
                end
                local milkShare = animal.rlNutrition ~= nil and animal.rlNutrition.milkShare or nil
                if milkShare ~= nil then
                    lactating = lactating + 1
                    milkSum = milkSum + milkShare
                end
            end

            if showAnimals then
                local nutrition = animal.rlNutrition
                local state = animal.bodyCondition
                out(string.format("   %-14s %s %3dm %7.1f kg  r=%s %-9s intake=%s need=%s milk=%s trend=%s%s",
                    tostring(animal.uniqueId), animal.gender == "male" and (animal.isCastrated and "S" or "M") or "F",
                    animal.age or -1, animal.weight or 0,
                    state ~= nil and string.format("%.3f", state.reserve) or "  -  ",
                    getConditionText(animal),
                    nutrition ~= nil and string.format("%.2f", nutrition.intakeRatio or 0) or "-",
                    nutrition ~= nil and string.format("%.0f%%", (nutrition.coverage or 0) * 100) or "-",
                    nutrition ~= nil and nutrition.milkShare ~= nil and string.format("%.0f%%", nutrition.milkShare * 100) or "-",
                    state ~= nil and string.format("%+.2f", state.balanceEMA or 0) or "-",
                    nutrition ~= nil and nutrition.tick ~= RLBodyCondition.getTickId() and " (stale)" or ""))
                -- Weight model v2: the animal's growth state against its curve.
                local growth = animal.rlGrowth
                if growth ~= nil and RLGrowth.covers(animal) then
                    local curve = RLGrowth.getCurve(animal)
                    local onCurve = curve:value(math.max(animal.age or 0, 0))
                    out(string.format("      v2 born %.1f kg, adult %.0f kg, development %.2f / %d months, reserve %.1f kg, curve at age %.0f kg (%.0f%%), speed %.2f, intake %.2f, %s",
                        growth.birthWeightKg, growth.frameTargetKg, growth.developmentMonths, animal.age or 0,
                        growth.reserveMassKg, onCurve, onCurve > 0 and animal.weight / onCurve * 100 or 0,
                        growth.speedFactor or 1, growth.intakeFactor or 1, tostring(growth.source)))
                end
            end
        end

        out(string.format("   animals %d, covered %d | cows %d BCS %s | bulls/steers %d finish %s | thin %d, fat %d | lactating %d, milk %s of full",
            count, covered, females,
            females > 0 and string.format("%.2f..%.2f (mean %.2f)", minBCS, maxBCS, sumBCS / females) or "-",
            males, males > 0 and string.format("%.0f..%.0f (mean %.0f)", minF, maxF, sumF / males) or "-",
            thin, fat, lactating, lactating > 0 and string.format("%.0f%%", milkSum / lactating * 100) or "-"))
    end

    return string.format("rlBcReport: %d pen(s)", #pens)
end


--- Reserve for a finish score: the finish curve read backwards.
local function reserveForFinish(score)
    local points = RLBodyCondition.getConfig().curves.finishScore
    local inverse = {}
    for _, point in ipairs(points) do table.insert(inverse, { point[2], point[1] }) end
    return RLNutritionMath.interpolate(inverse, score)
end


--- rlBcSet <reserve|bcs|finish> <value> <all|pen:NAME|uniqueId>
function RLBodyConditionConsole:set(kind, value, target)
    local usage = "Usage: rlBcSet <reserve|bcs|finish> <value> <all|pen:NAME|uniqueId>"
    value = tonumber(value)
    if kind == nil or value == nil or target == nil then return usage end

    local reserve
    kind = kind:lower()
    if kind == "reserve" then
        reserve = value
    elseif kind == "bcs" then
        reserve = (value - 1) / 4
    elseif kind == "finish" then
        reserve = reserveForFinish(value)
    else
        return usage
    end
    reserve = math.clamp(reserve, 0, 1)

    local filter, uniqueId = nil, nil
    if target:lower():sub(1, 4) == "pen:" then
        filter = target:sub(5)
    elseif target:lower() ~= "all" then
        uniqueId = target
    end

    local changed = 0
    for _, pen in ipairs(getPens(filter)) do
        for _, animal in ipairs(pen:getClusters()) do
            if RLBodyCondition.isEligible(animal) and (uniqueId == nil or tostring(animal.uniqueId) == uniqueId) then
                local state = RLBodyCondition.ensureState(animal, "console")
                if RLGrowth.covers(animal) then
                    -- Weight model v2: the reserve mass moves, the frame stays.
                    RLGrowth.setReserveIndex(animal, reserve)
                    state.capacityKg = math.max((animal.weight - animal.rlGrowth.reserveMassKg) * RLGrowth.getKappa(), 1)
                else
                    animal.weight = math.max(animal.weight + state.capacityKg * (reserve - state.reserve), 1)
                end
                state.reserve = reserve
                state.balanceEMA, state.lossRateEMA = 0, 0
                animal:updateInput()
                animal:setDirty()
                changed = changed + 1
            end
        end
    end

    return string.format("rlBcSet: %d animal(s) set to reserve %.3f (BCS %.2f, finish %.0f)", changed, reserve,
        RLNutritionMath.getBCS(reserve), RLNutritionMath.interpolate(RLBodyCondition.getConfig().curves.finishScore, reserve))
end


--- rlBcFastForward <hours> [pen]
function RLBodyConditionConsole:fastForward(hours, filter)
    hours = tonumber(hours)
    if hours == nil or hours < 1 then return "Usage: rlBcFastForward <hours> [pen]   (24 x days per period = one month)" end
    hours = math.min(math.floor(hours), 24 * 28 * 3)

    local pens = getPens(filter)
    if #pens == 0 then return "rlBcFastForward: no cattle pen" end

    local function snapshot()
        local weight, reserve, n = 0, 0, 0
        for _, pen in ipairs(pens) do
            for _, animal in ipairs(pen:getClusters()) do
                if RLBodyCondition.isEligible(animal) then
                    weight = weight + animal.weight
                    reserve = reserve + RLBodyCondition.getReserve(animal)
                    n = n + 1
                end
            end
        end
        return n > 0 and weight / n or 0, n > 0 and reserve / n or 0, n
    end

    local weightBefore, reserveBefore = snapshot()
    local hour = g_currentMission.environment.currentHour or 0

    -- Each simulated hour gets its own tick, so the ledger and the once-per-hour guard see a new hour.
    for _ = 1, hours do
        RLBodyCondition.debugTickOffset = (RLBodyCondition.debugTickOffset or 0) + 1
        for _, pen in ipairs(pens) do pen:hourChanged(hour) end
    end

    for _, pen in ipairs(pens) do
        local clusterSystem = pen.spec_husbandryAnimals ~= nil and pen.spec_husbandryAnimals.clusterSystem or nil
        for _, animal in ipairs(pen:getClusters()) do animal:setDirty() end
        if clusterSystem ~= nil and clusterSystem.updateClusters ~= nil then clusterSystem:updateClusters() end
    end

    local weightAfter, reserveAfter, n = snapshot()
    local days = g_currentMission.environment.daysPerPeriod or 1
    return string.format("rlBcFastForward: %d hours (%.2f months at %d day(s)/period) on %d pen(s), %d animal(s): mean weight %.1f -> %.1f kg, mean reserve %.3f -> %.3f",
        hours, hours / (24 * days), days, #pens, n, weightBefore, weightAfter, reserveBefore, reserveAfter)
end
