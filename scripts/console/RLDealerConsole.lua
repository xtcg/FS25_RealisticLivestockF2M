--[[
    RLDealerConsole.lua
    rlDealerCatalog: what the dealer can sell, per subtype, from xml/dealerStock.xml - its coverage,
    breed use, each purpose with the ages it can be offered at and the sources that supply it, and
    why the others cannot be offered - the gaps per animal type (subtypes on the old rules, breeds
    with no use) and the current dealer pool by purpose and source. Read-only: it draws nothing,
    generates nothing and changes no listing. Lines start with "RLDEALER" for grep.
]]

RLDealerConsole = {}

local Log = RmLogging.getLogger("RLRM")


--- "a-b,c-d" for inclusive integer segments.
local function formatSegments(segments)
    local parts = {}
    for _, segment in ipairs(segments) do
        table.insert(parts, segment[1] == segment[2] and tostring(segment[1]) or string.format("%d-%d", segment[1], segment[2]))
    end
    return table.concat(parts, ",")
end


--- One CATALOG line for a subtype.
---@return string
function RLDealerConsole.describeSubType(config, animalSystem, animalType, subType)
    local entry = RLDealerStockPolicy.getEntry(config, subType, animalType.name)
    local head = string.format("RLDEALER CATALOG type=%s subType=%s breed=%s gender=%s status=%s weight=%s",
        tostring(animalType.name), tostring(subType.name), tostring(subType.breed), tostring(subType.gender),
        entry.status, RLDealerStockPolicy.WEIGHT_MODEL)

    if entry.status ~= RLDealerStockPolicy.COVERED then
        return head .. (entry.missingProfile ~= nil and (" missingProfile=" .. entry.missingProfile) or "")
    end

    local ctx = animalSystem:getSaleAgeContext(animalType, subType)
    local candidates, gaps = RLDealerStockPolicy.getCandidates(entry, subType, ctx)

    local offered, missing = {}, {}
    for _, candidate in ipairs(candidates) do
        local sources = {}
        for _, source in ipairs(RLDealerStockPolicy.getSources(entry, candidate.purpose, subType.gender)) do
            table.insert(sources, source.id)
        end
        table.insert(offered, string.format("%s[%s]w%g<%s>", candidate.purpose.id, formatSegments(candidate.segments),
            candidate.purpose.weight, table.concat(sources, ",")))
    end
    for _, gap in ipairs(gaps) do table.insert(missing, gap.purpose.id .. ":" .. gap.reason) end

    return string.format("%s profile=%s use=%s slow=%s cap=%d minHealth=%g milk=%s buyable=[%s] offered={%s} notOffered={%s}",
        head, entry.profile.name, entry.use or "?", tostring(entry.slow), RLDealerStockPolicy.getCap(entry, subType.gender),
        entry.profile.minHealth, tostring(ctx.lactates), formatSegments(ctx.union), table.concat(offered, " "),
        table.concat(missing, " "))
end


--- One GAPS line for an animal type: its subtypes on the old dealer rules (legacy or not covered)
--- and its covered breeds without a use where its sources need one (only sources taking any breed
--- supply them).
---@return string
function RLDealerConsole.describeGaps(config, animalType, subTypes)
    local oldRules, noUse, seenBreed, covered = {}, {}, {}, 0
    for _, subType in ipairs(subTypes) do
        local entry = RLDealerStockPolicy.getEntry(config, subType, animalType.name)
        if entry.status == RLDealerStockPolicy.COVERED then
            covered = covered + 1
            local breed = tostring(subType.breed)
            if RLDealerStockPolicy.isUseMissing(entry) and not seenBreed[breed] then
                seenBreed[breed] = true
                table.insert(noUse, breed)
            end
        else
            table.insert(oldRules, string.format("%s:%s", tostring(subType.name), entry.status))
        end
    end
    return string.format("RLDEALER GAPS type=%s subTypes=%d covered=%d oldRules={%s} breedsWithoutUse={%s}",
        tostring(animalType.name), #subTypes, covered, table.concat(oldRules, " "), table.concat(noUse, " "))
end


--- @param typeFilter string|nil Animal type name (COW, PIG...); empty for all
--- @return string
function RLDealerConsole.catalog(_, typeFilter)
    local animalSystem = g_currentMission.animalSystem
    local config = RLDealerStockPolicy.getConfig()
    typeFilter = typeFilter ~= nil and typeFilter ~= "" and typeFilter:upper() or nil

    local lines, counters = 0, { typesSkipped = 0 }
    for _, animalType in ipairs(RLDealerSaleCatalog.sortedTypes(animalSystem:getTypes(), counters)) do
        if typeFilter == nil or animalType.name == typeFilter then
            local subTypes = {}
            for _, subTypeIndex in ipairs(animalType.subTypes) do
                local subType = animalSystem:getSubTypeByIndex(subTypeIndex)
                if subType ~= nil then
                    Log:info(RLDealerConsole.describeSubType(config, animalSystem, animalType, subType))
                    table.insert(subTypes, subType)
                    lines = lines + 1
                end
            end
            Log:info(RLDealerConsole.describeGaps(config, animalType, subTypes))

            -- The pool as the server holds it (a client's copy carries no purposes or sources).
            local byPurpose, bySource, total = {}, {}, 0
            for _, animal in ipairs(animalSystem:getSaleAnimalsByTypeIndex(animalType.typeIndex)) do
                total = total + 1
                local purpose = animal.sale ~= nil and animal.sale.purpose or "-"
                local source = animal.sale ~= nil and animal.sale.source or "-"
                byPurpose[purpose] = (byPurpose[purpose] or 0) + 1
                bySource[source] = (bySource[source] or 0) + 1
            end
            Log:info("RLDEALER POOL type=%s listings=%d byPurpose={%s} bySource={%s} generationFailures={%s}",
                tostring(animalType.name), total, RLDealerStockPolicy.formatCounts(byPurpose),
                RLDealerStockPolicy.formatCounts(bySource),
                AnimalSystem._formatSaleGenerationFailures(animalType.typeIndex, false, true))
        end
    end

    return string.format("rlDealerCatalog: %d subtype(s)%s, see log.txt (RLDEALER CATALOG / GAPS / POOL)", lines,
        counters.typesSkipped > 0 and string.format(", %d type(s) without a type index skipped", counters.typesSkipped) or "")
end
