--[[
    RLFeedConsole.lua
    Console commands for the real-equivalent nutrition mode (RLFeed), registered by
    RLConsoleCommandManager.

    rlFeedReport [animals] [pen]   Per cattle pen: mode and why, ration settings, the trough per
                                   feed (stock, profile status, last hour and month in liters, real
                                   DM and ME, planned liters a month and months left), the share of
                                   planned ME eaten and what held the animals; with "animals" one
                                   line per animal (class, target, real intake and ME a day,
                                   concentrate share and limit, protein, adaptation, health reason).
                                   Also the feed data in effect and the milk bridge per breed.
                                   Read-only; on a client it shows what the server last sent.
    rlFeedRation <pen> [target=AUTO|FINISH|GROW|MAINTAIN] [grain=AUTO|NONE|MAIZE|WHEAT|BARLEY|OAT]
                 [share=max|0..0.8] [substitute=yes|no]
                                   Set a pen's ration (through RLFeedRationEvent).

    <pen> / [pen] match any part of a pen's name, case-insensitive.
]]

RLFeedConsole = {}


local function out(text)
    print(text)
end


local function getPens(filter)
    local pens = {}
    filter = filter ~= nil and filter:lower() or nil
    for _, placeable in ipairs(g_currentMission.husbandrySystem.placeables) do
        if placeable.spec_husbandryFood ~= nil and placeable.getAnimalTypeIndex ~= nil and placeable:getAnimalTypeIndex() == AnimalType.COW then
            local name = placeable.getName ~= nil and placeable:getName() or "?"
            if filter == nil or name:lower():find(filter, 1, true) ~= nil then table.insert(pens, placeable) end
        end
    end
    return pens
end


local function fmt(value, digits)
    if value == nil then return "-" end
    return string.format("%." .. (digits or 1) .. "f", value)
end


--- rlFeedReport [animals] [pen]
function RLFeedConsole:report(arg1, arg2)
    local showAnimals = arg1 ~= nil and arg1:lower() == "animals"
    local filter = arg1
    if showAnimals then filter = arg2 end
    local config = RLFeed.getConfig()
    local ok, reason = RLFeed.canRun()
    out(string.format("rlFeedReport: nutrition model %s (%s); feed data v%s hash %s, scale %.3f, %s model days a month%s",
        RLFeed.mode == RLFeed.MODE_REAL and "REAL-EQUIVALENT" or "LEGACY", reason, tostring(config.version), config.hash,
        config.resourceScale, tostring(config.realDaysPerPeriod), config.valid and "" or (" - INVALID: " .. tostring(config.invalidReason))))

    local pens = getPens(filter)
    if #pens == 0 then return "rlFeedReport: no cattle pen" .. (filter ~= nil and (" matching '" .. filter .. "'") or "") end

    for _, pen in ipairs(pens) do
        local spec = pen.spec_husbandryFood
        local state = RLFeed.getPenState(pen, nil)
        local ration = RLFeed.getRation(pen)
        local last, month = spec.rlFeedLast, spec.rlFeedMonth
        local client = spec.rlFeedClient
        out(string.format("== %s: %s (%s), ration target=%s grain=%s share=%s substitute=%s%s", pen:getName(),
            state.active and "real-equivalent" or "old rules", tostring(state.reason), ration.target, ration.grain,
            ration.share ~= nil and fmt(ration.share, 2) or "max", tostring(ration.substitute),
            pen.spec_husbandryFeedingRobot ~= nil and ", feeding robot (mixes TMR)" or ""))
        if last ~= nil then
            out(string.format("   last hour: %d animals, %.2f kg DM, %.1f MJ of %.1f planned (%.0f%%), water %.0f%%",
                last.animals, last.eatenKg, last.eatenMe, last.plannedMe, (last.coverage or 0) * 100, (last.water or 1) * 100))
            local limits = {}
            for limit, count in pairs(last.limits) do limits[#limits + 1] = limit .. " x" .. count end
            table.sort(limits)
            if #limits > 0 then out("   held by: " .. table.concat(limits, ", ")) end
        elseif client ~= nil then
            out(string.format("   (client) last hour coverage %s", client.coverage ~= nil and string.format("%.0f%%", client.coverage * 100) or "-"))
        end

        local names, seen = {}, {}
        local function add(name) if name ~= nil and not seen[name] then seen[name] = true table.insert(names, name) end end
        for index, supported in pairs(spec.supportedFillTypes or {}) do
            if supported then add(g_fillTypeManager:getFillTypeNameByIndex(index)) end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local index = g_fillTypeManager:getFillTypeIndexByName(name)
            local stock = pen:getAvailableFood(index) or 0
            local profile = RLFeedProfiles.getFeed(name)
            local status = profile == nil and "UNLISTED" or (profile.valid and profile.status or ("UNUSABLE: " .. tostring(profile.invalidReason)))
            local hour = last ~= nil and last.byFill[name] or nil
            local inMonth = month ~= nil and month.byFill[name] or (client ~= nil and client.byFill[name]) or nil
            local planned = (last ~= nil and last.plannedPerMonth ~= nil and last.plannedPerMonth[name])
                or (client ~= nil and client.plannedPerMonth[name]) or 0
            local left = planned > 0 and string.format("%.1f mo", stock / planned) or "-"
            out(string.format("   %-17s stock %9.1f L  %-10s hour %7.2f L %6.2f kg %7.1f MJ  month %8.1f L %7.1f kg  plan %8.1f L/mo  left %s",
                name, stock, status, hour ~= nil and hour.liters or 0, hour ~= nil and hour.kg or 0, hour ~= nil and hour.me or 0,
                inMonth ~= nil and inMonth.liters or 0, inMonth ~= nil and inMonth.kg or 0, planned, left))
        end
        if month ~= nil then
            out(string.format("   month: %d of %d hours (%s), counted at scale %.3f, feed data %s", month.hours, month.hoursInMonth,
                month.startedAtStart and "from its start" or "partial", month.scale or 0, tostring(month.hash)))
        end

        if showAnimals then
            for _, animal in ipairs(pen:getClusters()) do
                local record = animal.rlFeedIntake
                local remote = animal.rlFeedClient
                if record ~= nil and record.dtDays ~= nil and record.dtDays > 0 then
                    local days = record.dtDays
                    out(string.format("   %s %-14s %-9s %-8s %6.1f kg  DM %5.2f/%5.2f kg/d  ME %6.1f/%6.1f MJ/d  conc %.2f (%s)  intake %s  protein %.2f  adapted %.2f  short %.1f d  health %d (%s)  trend %+.1f kg/mo",
                        tostring(animal.uniqueId), tostring(animal.subType), record.class or "-", record.target or "-", animal.weight,
                        record.kg / days, (record.plannedKg or 0) / days, record.me / days, (record.plannedMe or 0) / days,
                        record.concShare or 0, tostring(record.concLimit), tostring(record.intakeLimit), record.proteinFactor or 0,
                        animal.rlGrowth ~= nil and animal.rlGrowth.feedAdapted or 0, animal.rlGrowth ~= nil and animal.rlGrowth.feedShortDays or 0,
                        animal.health or 0, tostring(record.healthReason), record.gainPerMonth or 0))
                elseif remote ~= nil then
                    out(string.format("   %s %-14s %-9s %-8s %6.1f kg  DM %5.2f/%5.2f kg/d  ME %6.1f/%6.1f MJ/d  conc %.2f (%s)  intake %s  protein %.2f  health (%s)",
                        tostring(animal.uniqueId), tostring(animal.subType), remote.class or "-", remote.target or "-", animal.weight,
                        remote.kgPerDay, remote.plannedKgPerDay, remote.mePerDay, remote.plannedMePerDay, remote.concShare,
                        tostring(remote.concLimit), tostring(remote.intakeLimit), remote.proteinFactor, tostring(remote.healthReason)))
                else
                    out(string.format("   %s %-14s no hour in the mode yet", tostring(animal.uniqueId), tostring(animal.subType)))
                end
            end
        end
    end

    out("   milk bridge (real kg a day at the lactation average, ME per real kg):")
    local breeds = {}
    for name, breed in pairs(config.milk.breeds) do breeds[#breeds + 1] = string.format("%s %.0f kg %.1f MJ", name, breed.realKgPerDay, breed.meMJPerKg) end
    table.sort(breeds)
    out("   " .. table.concat(breeds, "; "))
    return string.format("rlFeedReport: %d pen(s)", #pens)
end


--- rlFeedRation <pen> [key=value ...]
function RLFeedConsole:ration(filter, ...)
    if filter == nil then return "rlFeedRation <pen> [target=AUTO|FINISH|GROW|MAINTAIN] [grain=AUTO|NONE|MAIZE|WHEAT|BARLEY|OAT] [share=max|0..0.8] [substitute=yes|no]" end
    local pens = getPens(filter)
    if #pens ~= 1 then return string.format("rlFeedRation: %d pens match '%s' - name exactly one", #pens, filter) end
    local pen = pens[1]
    local current = RLFeed.getRation(pen)
    local ration = { target = current.target, grain = current.grain, share = current.share, substitute = current.substitute }
    for _, arg in ipairs({ ... }) do
        local key, value = tostring(arg):match("^(%w+)=(.+)$")
        if key == nil then return "rlFeedRation: arguments are key=value (" .. tostring(arg) .. ")" end
        key = key:lower()
        if key == "target" then ration.target = value:upper()
        elseif key == "grain" then ration.grain = value:upper()
        elseif key == "share" then ration.share = value:lower() ~= "max" and tonumber(value) or nil
        elseif key == "substitute" then ration.substitute = value:lower() == "yes" or value:lower() == "true"
        else return "rlFeedRation: unknown key " .. key end
    end
    local _, valid = RLFeed.sanitizeRation(ration)
    if not valid then return "rlFeedRation: a value is out of range" end
    RLFeedRationEvent.sendEvent(pen, ration)
    return string.format("rlFeedRation: %s target=%s grain=%s share=%s substitute=%s", pen:getName(), ration.target, ration.grain,
        ration.share ~= nil and fmt(ration.share, 2) or "max", tostring(ration.substitute))
end
