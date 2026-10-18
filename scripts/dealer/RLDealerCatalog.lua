--[[
    Dealer v2 T5: the read-only projection of the dealer's stock for the player's screens. Pure over the
    store: a page, a detail and a status are DTOs of plain values (never an animal, never a table the
    server keeps), computed from what the last tick left. Reading never advances time, draws a random
    number, builds an animal or touches a listing - the tests compare the whole store before and after.

    A page is one snapshot: `catalogEpoch` (this server session) and `snapshotSequence` (a digest of every
    LISTED saleId and revision) identify it. A request that names a snapshot which is no longer current gets
    STALE_SNAPSHOT and starts again from the first page; a client never joins pages of different snapshots.
    Rows are ordered by the requested key with the saleId as the final tie-break, so equal prices never
    repeat or skip a row between pages. Sort keys and filters are a closed list.
]]

RLDealerCatalog = { VERSION = 1, PAGE_SIZE = 50, MAX_PAGE_SIZE = 50 }
local C = RLDealerCatalog

C.SORTS = { price = true, age = true, weight = true, breed = true }
C.FILTERS = { breed = "string", purpose = "string", gender = "string", maxPrice = "number" }


local function round(v, places)
    local m = 10 ^ (places or 0)
    return math.floor(v * m + 0.5) / m
end


local function listed(store)
    local out = {}
    for _, row in pairs(store.listings.records) do
        if row.state == "LISTED" then out[#out + 1] = row end
    end
    table.sort(out, function(a, b) return a.saleId < b.saleId end)
    return out
end


--- A digest of the LISTED set and the clock: changes when any listing appears, goes, or changes revision.
function C.snapshotSequence(store)
    local parts = { string.format("%.6f", store.farm.clock.months) }
    for _, row in ipairs(listed(store)) do parts[#parts + 1] = row.saleId .. ":" .. tostring(row.recordRevision) end
    return RLTradePersistence.checksum(table.concat(parts, "|"))
end


local function sourceAnimal(store, row)
    local sourceId = row.payload and row.payload.sourceId
    local binding = sourceId and store.sourceBindings[sourceId]
    local owner = binding and store.sourceOwners[binding.ownerId]
    return owner and owner.byId[binding.animalId] or nil, store.farm.sources[sourceId]
end


local function rowDto(store, row, deps)
    local animal, record = sourceAnimal(store, row)
    if animal == nil or record == nil then return nil end
    local price = deps.refPrice(animal)
    if type(price) ~= "number" then return nil end
    return { saleId = row.saleId, revision = row.recordRevision, subType = animal.subType, breed = animal.breed,
        gender = animal.gender, purpose = row.payload.purpose, source = row.payload.source,
        ageMonths = math.floor(record.ageMonths + 1e-9), weightKg = round(animal.weight, 1), parity = animal.birthCount or 0,
        pregnant = animal.isPregnant == true, lactating = animal.isLactating == true, price = round(price, 2) }
end


local function matches(dto, filter)
    if filter.breed ~= nil and dto.breed ~= filter.breed then return false end
    if filter.purpose ~= nil and dto.purpose ~= filter.purpose then return false end
    if filter.gender ~= nil and dto.gender ~= filter.gender then return false end
    if filter.maxPrice ~= nil and dto.price > filter.maxPrice then return false end
    return true
end


--- query = { snapshot?, cursor (rows already seen, default 0), pageSize, sort, descending, filter }
--- Returns a reply table or nil and a reason.
function C.page(store, query, deps)
    if type(query) ~= "table" then return nil, "BAD_QUERY" end
    local sort = query.sort or "price"
    if not C.SORTS[sort] then return nil, "BAD_SORT" end
    local size = query.pageSize or C.PAGE_SIZE
    if type(size) ~= "number" or size % 1 ~= 0 or size < 1 or size > C.MAX_PAGE_SIZE then return nil, "BAD_PAGE_SIZE" end
    local cursor = query.cursor or 0
    if type(cursor) ~= "number" or cursor % 1 ~= 0 or cursor < 0 then return nil, "BAD_CURSOR" end
    local filter = query.filter or {}
    for key, value in pairs(filter) do
        if C.FILTERS[key] == nil or type(value) ~= C.FILTERS[key] then return nil, "BAD_FILTER" end
    end
    local sequence = C.snapshotSequence(store)
    if query.snapshot ~= nil and query.snapshot ~= sequence then
        return { status = "STALE_SNAPSHOT", catalogEpoch = deps.epoch, snapshotSequence = sequence }
    end
    local rows = {}
    for _, row in ipairs(listed(store)) do
        local dto = rowDto(store, row, deps)
        if dto ~= nil and matches(dto, filter) then rows[#rows + 1] = dto end
    end
    local key = ({ price = "price", age = "ageMonths", weight = "weightKg", breed = "breed" })[sort]
    local descending = query.descending == true
    table.sort(rows, function(a, b)
        if a[key] ~= b[key] then
            if descending then return a[key] > b[key] end
            return a[key] < b[key]
        end
        return a.saleId < b.saleId
    end)
    local page = {}
    for i = cursor + 1, math.min(#rows, cursor + size) do page[#page + 1] = rows[i] end
    local nextCursor = cursor + #page
    return { status = "OK", catalogEpoch = deps.epoch, snapshotSequence = sequence, total = #rows, rows = page,
        nextCursor = nextCursor < #rows and nextCursor or nil }
end


local function identityText(animal)
    local country = animal.birthday and animal.birthday.country
    local code = RLConstants ~= nil and RLConstants.AREA_CODES ~= nil and RLConstants.AREA_CODES[country] and RLConstants.AREA_CODES[country].code or nil
    return (code and (code .. " ") or "") .. tostring(animal.farmId) .. " " .. tostring(animal.uniqueId)
end


--- The detail of one listing at one revision. Unknown values are absent, never filled in.
function C.detail(store, saleId, revision, deps)
    local row = RLDealerListingRegistry.get(store.listings, saleId)
    if row == nil or row.state ~= "LISTED" then return { status = "NOT_LISTED" } end
    if row.recordRevision ~= revision then return { status = "STALE_REVISION", revision = row.recordRevision } end
    local animal, record = sourceAnimal(store, row)
    if animal == nil or record == nil then return { status = "NOT_LISTED" } end
    local dto = rowDto(store, row, deps)
    if dto == nil then return { status = "NOT_LISTED" } end
    local detail = { earTag = identityText(animal), traceability = record.history and record.history.traceability,
        evidence = record.history and record.history.evidence, health = animal.health and round(animal.health, 0), genetics = nil }
    if type(animal.genetics) == "table" then
        detail.genetics = {}
        for _, trait in ipairs({ "metabolism", "quality", "productivity", "fertility", "health" }) do
            if animal.genetics[trait] ~= nil then detail.genetics[trait] = round(animal.genetics[trait], 2) end
        end
    end
    if animal.rlGrowth ~= nil and animal.rlGrowth.reserveMassKg ~= nil and animal.weight and animal.weight > 0 then
        detail.reserveShare = round(animal.rlGrowth.reserveMassKg / animal.weight, 3)
    end
    local weaning = record.history and record.history.weanedAtMonths
    if weaning ~= nil then detail.weaned = record.ageMonths >= weaning end
    if animal.isPregnant and animal.pregnancy ~= nil then
        detail.pregnancy = { fetuses = animal.pregnancy.pregnancies and #animal.pregnancy.pregnancies or nil,
            progress = animal.reproduction and round(animal.reproduction / 100, 2) or nil }
    end
    detail.monthsSinceLastBirth = animal.isParent and animal.monthsSinceLastBirth or nil
    for k, v in pairs(dto) do detail[k] = v end
    detail.status = "OK"
    return detail
end
