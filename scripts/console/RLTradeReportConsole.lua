--[[
    RLTradeReportConsole.lua
    Read-only console report of what animals are at the slaughter facilities (RLTradeQuote):
    the carcass model's meat next to the facility's own input unit and the recipe in effect now.
    Registered by RLConsoleCommandManager on single player, host and client; nothing here aligns
    recipes, delivers, charges, reserves room or sets up animal state. Quotes read on a client
    use its own copy of the config and are marked "not authoritative".

    rlTradeReport                                   Every facility that takes animals: per input,
                                                    its unit, recipe meat per unit next to the
                                                    model's meat per typical animal, fee and source,
                                                    shared or conflicting inputs.
    rlTradeReport <facility> <uniqueId|pen:NAME> [farmId]
                                                    Quote animals at one facility. <facility> is
                                                    the number from the list or part of its name.
                                                    farmId defaults to the player's farm.

    A recipe figure is what the recipe would turn the input into, not output made or money paid.
]]

RLTradeReportConsole = {}

RLTradeReportConsole.MAX_ANIMALS = 40


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


--- Animals by uniqueId or pen:NAME (part of the pen's name), from the husbandries.
local function findAnimals(selector)
    local animals, penFilter = {}, nil
    if selector:lower():sub(1, 4) == "pen:" then penFilter = selector:sub(5):lower() end
    local husbandrySystem = g_currentMission.husbandrySystem
    for _, pen in ipairs(husbandrySystem ~= nil and husbandrySystem.placeables or {}) do
        local penName = pen.getName ~= nil and pen:getName() or "?"
        local penMatches = penFilter ~= nil and penName:lower():find(penFilter, 1, true) ~= nil
        if penFilter == nil or penMatches then
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
    local reasons, notes = listText(quote.reasons), listText(quote.notes)
    if reasons ~= nil or notes ~= nil then
        out(string.format("      %s%s", reasons ~= nil and ("reasons: " .. reasons .. "  ") or "", notes ~= nil and ("notes: " .. notes) or ""))
    end
end


--- rlTradeReport [facility] [uniqueId|pen:NAME] [farmId]
function RLTradeReportConsole:report(facilityArg, animalArg, farmArg)
    local farmId = tonumber(farmArg)
    if farmId == nil and g_currentMission.getFarmId ~= nil then farmId = g_currentMission:getFarmId() end
    if farmId == 0 then farmId = nil end
    local isServer = g_currentMission.getIsServer ~= nil and g_currentMission:getIsServer()

    if facilityArg == nil then
        local facilities = RLTradeReportConsole.getFacilities()
        if #facilities == 0 then return "rlTradeReport: no facility takes animals" end
        for i, facility in ipairs(facilities) do
            out(string.format("== %d %s (%s)", i, facility.name, facility.target.isServer and "server" or "client copy, not authoritative"))
            describeAll(facility, farmId)
        end
        return string.format("rlTradeReport: %d facilities, farm %s%s", #facilities, tostring(farmId),
            isServer and "" or "; client config, not authoritative")
    end

    local facility = findFacility(facilityArg)
    if facility == nil then return "rlTradeReport: no facility '" .. facilityArg .. "' (run rlTradeReport for the list)" end
    if animalArg == nil then
        out(string.format("== %s", facility.name))
        describeAll(facility, farmId)
        return "rlTradeReport: give a uniqueId or pen:NAME to quote animals"
    end

    local animals = findAnimals(animalArg)
    if #animals == 0 then return "rlTradeReport: no animal '" .. animalArg .. "'" end
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
