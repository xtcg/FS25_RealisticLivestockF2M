--[[
    RLDealerConsole.lua
    rlDealerCatalog: what the dealer can sell, per subtype, from xml/dealerStock.xml - its coverage,
    each purpose with the ages it can be offered at, and why the others cannot be offered - and the
    current dealer pool by purpose. Read-only: it draws nothing, generates nothing and changes no
    listing. Lines start with "RLDEALER" for grep.
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
        table.insert(offered, string.format("%s[%s]w%g", candidate.purpose.id, formatSegments(candidate.segments),
            candidate.purpose.weight))
    end
    for _, gap in ipairs(gaps) do table.insert(missing, gap.purpose.id .. ":" .. gap.reason) end

    return string.format("%s profile=%s slow=%s cap=%d buyable=[%s] offered={%s} notOffered={%s}",
        head, entry.profile.name, tostring(entry.slow), RLDealerStockPolicy.getCap(entry, subType.gender),
        formatSegments(ctx.union), table.concat(offered, " "), table.concat(missing, " "))
end


--- @param typeFilter string|nil Animal type name (COW, PIG...); empty for all
--- @return string
function RLDealerConsole.catalog(_, typeFilter)
    local animalSystem = g_currentMission.animalSystem
    local config = RLDealerStockPolicy.getConfig()
    typeFilter = typeFilter ~= nil and typeFilter ~= "" and typeFilter:upper() or nil

    local lines = 0
    for _, animalType in ipairs(RLDealerSaleCatalog.sortedTypes(animalSystem:getTypes())) do
        if typeFilter == nil or animalType.name == typeFilter then
            for _, subTypeIndex in ipairs(animalType.subTypes) do
                local subType = animalSystem:getSubTypeByIndex(subTypeIndex)
                if subType ~= nil then
                    Log:info(RLDealerConsole.describeSubType(config, animalSystem, animalType, subType))
                    lines = lines + 1
                end
            end

            -- The pool as the server holds it (a client's copy carries no purposes).
            local byPurpose, total = {}, 0
            for _, animal in ipairs(animalSystem:getSaleAnimalsByTypeIndex(animalType.typeIndex)) do
                total = total + 1
                local key = animal.sale ~= nil and animal.sale.purpose or "-"
                byPurpose[key] = (byPurpose[key] or 0) + 1
            end
            Log:info("RLDEALER POOL type=%s listings=%d byPurpose={%s} generationFailures={%s}",
                tostring(animalType.name), total, RLDealerStockPolicy.formatCounts(byPurpose),
                AnimalSystem._formatSaleGenerationFailures(animalType.typeIndex, false, true))
        end
    end

    return string.format("rlDealerCatalog: %d subtype(s), see log.txt (RLDEALER CATALOG / POOL)", lines)
end
