--[[
    RLTradeReportConsole.lua
    Read-only console report of what animals are at the slaughter facilities (RLTradeQuote):
    the carcass model's meat next to the facility's own input unit and the recipe in effect now.
    Registered by RLConsoleCommandManager on single player, host and client; nothing here aligns
    recipes, delivers, charges, reserves room or sets up animal state. Quotes read on a client
    use its own copy of the config and are marked "not authoritative".

    rlTradeReport [farm:N]                          Every facility that takes animals: per input,
                                                    its unit, recipe meat per unit next to the
                                                    model's meat per typical animal, fee and source,
                                                    shared or conflicting inputs, the farm's order.
    rlTradeReport <facility> [farm:N]               The same for one facility.
    rlTradeReport <facility> <uniqueId|pen:NAME> [farmId|farm:N]
                                                    Quote animals of that farm's pens at one
                                                    facility. <facility> is the number from the
                                                    list or part of its name.

    The farm defaults to the player's; on a dedicated server (no player farm) pass farm:N, or
    orders, fee credit and money are not read (NO_FARM).

    A recipe figure is what the recipe would turn the input into, not output made or money paid.
]]

RLTradeReportConsole = {}

RLTradeReportConsole.MAX_ANIMALS = 40

-- Unlike the per-animal report, this includes the entire selection; never silently
-- prepare only the first 40. SHADOW_OK means budget/capacity only, not trade permission.
function RLTradeReportConsole:plan(facilityArg, animalArg, farmArg)
    if facilityArg == nil or animalArg == nil then
        return "rlTradePlan <facility number> <uniqueId|pen:NAME> [farmId]; read-only, shadow budget only"
    end
    local facilities = RLTradeReportConsole.getFacilities()
    local target, name
    local index = tonumber(facilityArg)
    if index ~= nil then
        local facility = facilities[index]
        if facility ~= nil then target, name = facility.target, facility.name end
    else
        for _, facility in ipairs(facilities) do
            if facility.name:lower():find(facilityArg:lower(), 1, true) ~= nil then
                if target ~= nil then return "rlTradePlan: AMBIGUOUS facility name; use its number from rlTradeReport" end
                target, name = facility.target, facility.name
            end
        end
    end
    if target == nil then return "rlTradePlan: facility not found; run rlTradeReport" end
    local selected, penFilter = {}, nil
    if animalArg:lower():sub(1, 4) == "pen:" then penFilter = animalArg:sub(5):lower() end
    if penFilter == "" then return "rlTradePlan: pen name required" end
    for _, pen in ipairs(g_currentMission.husbandrySystem ~= nil and g_currentMission.husbandrySystem.placeables or {}) do
        local matches = penFilter ~= nil and pen:getName():lower():find(penFilter, 1, true) ~= nil
        if penFilter == nil or matches then
            for _, animal in ipairs(pen.getClusters ~= nil and pen:getClusters() or {}) do
                if matches or tostring(animal.uniqueId) == animalArg then selected[#selected + 1] = animal end
            end
        end
    end
    if penFilter == nil and #selected > 1 then
        return "rlTradePlan: AMBIGUOUS uniqueId; select a pen (identity includes herd and country)"
    end
    local farmId = tonumber(farmArg)
    if farmArg ~= nil and farmId == nil then return "rlTradePlan: invalid farmId" end
    if farmId == nil and g_currentMission.getFarmId ~= nil then farmId = g_currentMission:getFarmId() end
    local ok, result, reason = pcall(RLContractPreview.prepare, selected, target, farmId)
    if not ok then return "rlTradePlan: snapshot failed: " .. tostring(result) end
    if result == nil then return "rlTradePlan: REFUSED " .. tostring(reason) end
    print(string.format("== %s, farm %s: %d animals, SHADOW_OK (budget only)", name, tostring(farmId), #result.entries))
    print(string.format("   fee %.2f; credit %.2f; cash %.2f; wallet %.2f -> %.2f",
        result.fee, result.creditUse, result.cashDue, result.moneyBefore, result.moneyAfter))
    local fillTypes = {}
    for fillType in pairs(result.inputs) do fillTypes[#fillTypes + 1] = fillType end
    table.sort(fillTypes)
    for _, fillType in ipairs(fillTypes) do
        local input = result.inputs[fillType]
        print(string.format("   input %s: %.6f standard batches (not kg), room %.6f", tostring(fillType), input.amount, input.room))
    end
    return "rlTradePlan: shadow only; no authorization, reservation, delivery or charge"
end


local function out(text)
    print(text)
end


local function fmt(value, pattern)
    if value == nil then return "-" end
    return string.format(pattern or "%.2f", value)
end


--- Facilities that take animals: contract placeables and EPP production points, in placeable order.
--- @return table list of {target, name}
function RLTradeReportConsole.getFacilities()
    local list = {}
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    for _, placeable in ipairs(placeableSystem ~= nil and placeableSystem.placeables or {}) do
        local name = placeable.getName ~= nil and placeable:getName() or "?"
        if placeable.spec_contractProductionService ~= nil and type(placeable.animalSubTypeToFillType) == "table" then
            table.insert(list, { target = placeable, name = name })
        elseif placeable.spec_extendedProductionPoint ~= nil then
            local pp = placeable.spec_extendedProductionPoint.productionPoint
            if pp ~= nil and type(pp.animalsTypeData) == "table" and type(pp.animalSubTypeToFillType) == "table" then
                table.insert(list, { target = pp, name = name })
            end
        end
    end
    return list
end


local function findFacility(selector)
    local facilities = RLTradeReportConsole.getFacilities()
    local index = tonumber(selector)
    if index ~= nil then return facilities[index] end
    selector = selector:lower()
    for _, facility in ipairs(facilities) do
        if facility.name:lower():find(selector, 1, true) ~= nil then return facility end
    end
    return nil
end


--- Animals by uniqueId or pen:NAME (part of the pen's name), from the husbandries of the farm
--- (every farm's when farmId is nil).
function RLTradeReportConsole.findAnimals(selector, farmId)
    local animals, penFilter = {}, nil
    if selector:lower():sub(1, 4) == "pen:" then penFilter = selector:sub(5):lower() end
    local husbandrySystem = g_currentMission.husbandrySystem
    for _, pen in ipairs(husbandrySystem ~= nil and husbandrySystem.placeables or {}) do
        local owner = pen.getOwnerFarmId ~= nil and pen:getOwnerFarmId() or nil
        local penName = pen.getName ~= nil and pen:getName() or "?"
        local penMatches = penFilter ~= nil and penName:lower():find(penFilter, 1, true) ~= nil
        if (farmId == nil or owner == farmId) and (penFilter == nil or penMatches) then
            for _, animal in ipairs(pen.getClusters ~= nil and pen:getClusters() or {}) do
                if penMatches or tostring(animal.uniqueId) == selector then
                    table.insert(animals, animal)
                end
            end
        end
    end
    return animals
end


local function listText(list)
    return list ~= nil and #list > 0 and table.concat(list, ", ") or nil
end


--- One line per input fill type of a facility, for one subtype of each animal type it takes.
local function describeAll(facility, farmId)
    local target = facility.target
    local animalSystem = g_currentMission.animalSystem
    local seenTypes = {}
    local subTypeIndices = {}
    for subTypeIndex in pairs(target.animalSubTypeToFillType) do subTypeIndices[#subTypeIndices + 1] = subTypeIndex end
    table.sort(subTypeIndices)

    for _, subTypeIndex in ipairs(subTypeIndices) do
        local typeName = RLBreedTraits.getTypeName(animalSystem:getSubTypeByIndex(subTypeIndex))
        if typeName ~= nil and not seenTypes[typeName] then
            seenTypes[typeName] = true
            local role = RLTradeQuote.getRole(subTypeIndex)
            local d = RLTradeQuote.describeFacility(RLTradeQuote.snapshotFacility(target, subTypeIndex, farmId), role)
            local recipe = d.recipe
            out(string.format("   %-9s %-10s %-17s %s", typeName, tostring(d.inputFillTypeName), tostring(d.semantics), d.status))
            if recipe ~= nil and recipe.meatPerInputUnit ~= nil then
                out(string.format("      recipe %s (%s): %s kg %s per input unit, model %s kg per typical animal%s%s%s",
                    tostring(recipe.id), tostring(recipe.source), fmt(recipe.meatPerInputUnit, "%.3f"),
                    tostring(role.meatFillTypeName), fmt(role.meatPerHead, "%.3f"),
                    recipe.alignment ~= nil and (" -> " .. recipe.alignment) or "",
                    recipe.shippedPrimaryAmount ~= nil and string.format(" (map shipped %.1f)", recipe.shippedPrimaryAmount) or "",
                    recipe.unitsPerTypicalAnimal ~= nil and string.format(" -> %.1f units per typical animal", recipe.unitsPerTypicalAnimal) or ""))
            elseif recipe ~= nil then
                local outputs = {}
                for _, output in ipairs(recipe.outputs or {}) do
                    outputs[#outputs + 1] = string.format("%g %s", output.amount or 0, tostring(g_fillTypeManager:getFillTypeNameByIndex(output.fillType)))
                end
                out(string.format("      recipe %s (%s): %g input -> %s; no meat figure for this type",
                    tostring(recipe.id), tostring(recipe.source), recipe.inputAmount or 0, table.concat(outputs, ", ")))
            end
            if d.fee ~= nil and (d.fee.perBatch or 0) > 0 then
                out(string.format("      fee %.2f per batch of %s: %s", d.fee.perBatch, fmt(d.fee.batchInput, "%g"), d.fee.source))
            end
            if d.runCost ~= nil then
                out(string.format("      running cost %.2f per active hour, %g cycles per hour: %s",
                    d.runCost.costsPerActiveHour, d.runCost.cyclesPerHour, d.runCost.source))
            end
            if d.unitsPerAnimal ~= nil then out(string.format("      units per animal (configured) %g", d.unitsPerAnimal)) end
            local reasons, notes = listText(d.reasons), listText(d.notes)
            if reasons ~= nil then out("      reasons: " .. reasons) end
            if notes ~= nil then out("      notes: " .. notes) end
        end
    end
end


--- The farm a report is for: farm:N anywhere in the arguments, else the positional farm, else the
--- player's farm; nil when none (a dedicated server) or 0 (spectator).
--- @return table args Arguments without farm:N
--- @return number|nil farmId
--- @return string|nil error
local function parseArgs(...)
    local args, farmId = {}, nil
    for i = 1, select("#", ...) do
        local arg = select(i, ...)
        if arg ~= nil then
            local farm = arg:lower():match("^farm:(.*)$")
            if farm ~= nil then
                farmId = tonumber(farm)
                if farmId == nil then return nil, nil, "invalid " .. arg end
            else
                args[#args + 1] = arg
            end
        end
    end
    if farmId == nil and args[3] ~= nil then
        farmId = tonumber(args[3])
        if farmId == nil then return nil, nil, "invalid farmId " .. args[3] end
    end
    if farmId == nil and g_currentMission.getFarmId ~= nil then farmId = g_currentMission:getFarmId() end
    if farmId == 0 then farmId = nil end
    return args, farmId
end


local function quoteLine(animal, quote)
    local subType = g_currentMission.animalSystem:getSubTypeByIndex(animal.subTypeIndex)
    local head = string.format("   %-12s %-18s %3sm %7.1f kg  factor %s  model %s kg",
        tostring(animal.uniqueId), subType ~= nil and tostring(subType.name) or "?", tostring(animal.age),
        animal.weight or 0, fmt(quote.factor, "%.4f"), fmt(quote.modelMeat, "%.1f"))
    out(head)
    out(string.format("      %s: in %s %s -> recipe %s kg%s | fee %s%s%s%s | %s%s",
        tostring(quote.semantics), fmt(quote.inputQuantity, "%.3f"), tostring(quote.unit), fmt(quote.effectiveRecipeMeat, "%.1f"),
        quote.difference ~= nil and string.format(" (%+.1f kg, x%.4f%s)", quote.difference, quote.ratio or 0,
            quote.matches and ", matches" or ", MISMATCH") or "",
        fmt(quote.fee),
        quote.feeCreditUse ~= nil and string.format(" (credit %.2f, cash %.2f)", quote.feeCreditUse, quote.cashDue) or "",
        quote.runCostEstimate ~= nil and string.format(" running ~%.2f", quote.runCostEstimate) or "",
        quote.feeSource ~= nil and (" [" .. quote.feeSource .. "]") or "",
        quote.status, quote.authoritative and "" or " (not authoritative)"))
    if quote.deliveryInputQuantity ~= nil then
        out(string.format("      delivery would use production %s: %.3f units (recipe ambiguous, quote gives none)",
            tostring(quote.deliveryRecipeId), quote.deliveryInputQuantity))
    end
    local reasons, notes = listText(quote.reasons), listText(quote.notes)
    if reasons ~= nil or notes ~= nil then
        out(string.format("      %s%s", reasons ~= nil and ("reasons: " .. reasons .. "  ") or "", notes ~= nil and ("notes: " .. notes) or ""))
    end
end


--- rlTradeReport [facility] [uniqueId|pen:NAME] [farmId|farm:N]
function RLTradeReportConsole:report(...)
    local args, farmId, err = parseArgs(...)
    if args == nil then return "rlTradeReport: " .. err end
    local facilityArg, animalArg = args[1], args[2]
    local isServer = g_currentMission.getIsServer ~= nil and g_currentMission:getIsServer()
    local farmText = farmId ~= nil and tostring(farmId) or "none (pass farm:N; orders, credit and money not read)"

    if facilityArg == nil or facilityArg:lower() == "all" then
        local facilities = RLTradeReportConsole.getFacilities()
        if #facilities == 0 then return "rlTradeReport: no facility takes animals" end
        for i, facility in ipairs(facilities) do
            out(string.format("== %d %s (%s)", i, facility.name, facility.target.isServer and "server" or "client copy, not authoritative"))
            describeAll(facility, farmId)
        end
        return string.format("rlTradeReport: %d facilities, farm %s%s", #facilities, farmText,
            isServer and "" or "; client config, not authoritative")
    end

    local facility = findFacility(facilityArg)
    if facility == nil then return "rlTradeReport: no facility '" .. facilityArg .. "' (run rlTradeReport for the list)" end
    if animalArg == nil then
        out(string.format("== %s, farm %s", facility.name, farmText))
        describeAll(facility, farmId)
        return "rlTradeReport: give a uniqueId or pen:NAME to quote animals"
    end

    local animals = RLTradeReportConsole.findAnimals(animalArg, farmId)
    if #animals == 0 then
        return "rlTradeReport: no animal '" .. animalArg .. "'" .. (farmId ~= nil and (" in farm " .. farmId .. "'s pens") or "")
    end
    out(string.format("== %s, farm %s: %d animal(s)%s", facility.name, tostring(farmId), #animals,
        #animals > RLTradeReportConsole.MAX_ANIMALS and string.format(", first %d shown", RLTradeReportConsole.MAX_ANIMALS) or ""))
    for i, animal in ipairs(animals) do
        if i > RLTradeReportConsole.MAX_ANIMALS then break end
        local ok, quote = pcall(RLTradeQuote.quoteAnimal, animal, facility.target, farmId)
        if ok then
            quoteLine(animal, quote)
        else
            out(string.format("   %s: quote failed: %s", tostring(animal.uniqueId), tostring(quote)))
        end
    end
    return "rlTradeReport: recipe figures are nominal, not output made or money paid"
end


--- rlTradeTxMode [OFF|SHADOW|TEST]: show or set the T02 contract delivery mode (server only, this run only).
function RLTradeReportConsole:txMode(mode)
    if not g_currentMission:getIsServer() then return "rlTradeTxMode: server only" end
    if mode == nil then
        return string.format("rlTradeTxMode: %s (OFF old path; SHADOW logs what TEST would do; TEST transactions, test saves only)",
            RLContractTrade.getMode())
    end
    if not RLContractTrade.setMode(mode) then return "rlTradeTxMode: OFF, SHADOW or TEST" end
    if RLContractTrade.getMode() == RLContractTrade.MODE_TEST then
        return "rlTradeTxMode: TEST - contract deliveries run as transactions; records are not saved, use a test save"
    end
    return "rlTradeTxMode: " .. RLContractTrade.getMode()
end


--- rlTradeTxReport [txId]: this run's contract transactions. Reads only; never settles, unlocks or retries.
function RLTradeReportConsole:txReport(txId)
    if not g_currentMission:getIsServer() then return "rlTradeTxReport: server only (transactions run on the server)" end
    local store = RLContractTrade.store
    local ids = {}
    for id in pairs(store.records) do
        if txId == nil or id == txId then ids[#ids + 1] = id end
    end
    table.sort(ids, function(a, b) return store.records[a].sequence < store.records[b].sequence end)
    if #ids == 0 then
        return txId ~= nil and ("rlTradeTxReport: no transaction " .. txId) or
            ("rlTradeTxReport: no transactions this run (mode " .. RLContractTrade.getMode() .. ")")
    end
    local held = 0
    for _ in pairs(store.locks) do held = held + 1 end
    for _, id in ipairs(ids) do
        local record, receipt = store.records[id], RLContractTrade.receipts[id] or {}
        out(string.format("== %s %s%s", id, record.state, record.reason ~= nil and (" (" .. record.reason .. ")") or ""))
        out("   stages: " .. table.concat(record.history, " > "))
        if receipt.keys ~= nil then
            out(string.format("   farm %s, %d animal(s), %.6f standard batches (not kg), order %s; plan fee %.2f credit %.2f cash %.2f",
                tostring(receipt.farmId), #receipt.keys, receipt.amount or 0, tostring(receipt.target and receipt.target.orderId),
                receipt.plan.fee, receipt.plan.creditUse, receipt.plan.cashDue))
        end
        local t = receipt.target
        if t ~= nil and t.before ~= nil and t.after ~= nil then
            out(string.format("   target %s: accepted %s, buffered %s -> %s, credit %s -> %s, money %s -> %s%s%s",
                tostring(t.stage), tostring(t.accepted), tostring(t.before.buffered), tostring(t.after.buffered),
                tostring(t.before.feeCredit), tostring(t.after.feeCredit), tostring(t.moneyBefore), tostring(t.moneyAfter),
                t.verifyError ~= nil and (" verify:" .. t.verifyError) or "", t.rollbackError ~= nil and (" rollback:" .. t.rollbackError) or ""))
        end
        local src = receipt.source
        if src ~= nil then
            out(string.format("   source %s %s: removed %d, restored %d%s%s", tostring(src.kind), tostring(src.stage),
                #(src.removed or {}), #(src.restored or {}), src.error ~= nil and (" error:" .. src.error) or "",
                src.rollbackError ~= nil and (" rollback:" .. src.rollbackError) or ""))
        end
        if record.state == "NEEDS_RECONCILIATION" then
            out("   locks held: " .. table.concat(record.resources, ", "))
        end
    end
    return string.format("rlTradeTxReport: %d transaction(s), %d lock(s) held, mode %s", #ids, held, RLContractTrade.getMode())
end
