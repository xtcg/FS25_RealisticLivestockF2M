--[[
    Dealer v2 T5: the browsing protocol - catalog pages, listing detail, destinations, order status. One
    envelope for all (version, kind, direction, requestId, payload text). The payload is a plain-data table
    in RLTradePersistence's canonical text, so a field is never positional; it is parsed with strict limits
    and then checked against a closed shape (unknown keys, wrong types, out-of-range numbers, oversized
    lists and long strings are refused). Every field is read from the stream before any check, so a
    refused message still leaves the stream aligned (events carry no length).

    Requests carry no price, no farm, no principal and no animal: only references (saleId and revision,
    destination reference, order id) and view parameters. The server decides everything else from the
    connection.
]]

RLDealerCatalogProtocol = { VERSION = 1, MAX_PAYLOAD = 49152 }
local P = RLDealerCatalogProtocol

P.PAGE, P.DETAIL, P.DESTINATIONS, P.ORDER = 1, 2, 3, 4
P.REQUEST, P.REPLY = 1, 2
P.LIMITS = { maxNodes = 4000, maxString = 512, maxDepth = 5 }
P.MAX_SELECTION = 100


local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function text(v, max) return type(v) == "string" and #v > 0 and #v <= (max or 256) end
local function integer(v, lo, hi) return finite(v) and v % 1 == 0 and v >= lo and (hi == nil or v <= hi) end


--- spec[key] = function(value) -> boolean; `required` lists the keys that must exist.
local function shape(value, spec, required)
    if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
    for key, v in pairs(value) do
        if spec[key] == nil or not spec[key](v) then return false end
    end
    for _, key in ipairs(required or {}) do if value[key] == nil then return false end end
    return true
end


local function list(v, max, each)
    if type(v) ~= "table" or #v > max then return false end
    local n = 0
    for k, item in pairs(v) do
        if not integer(k, 1, max) or not each(item) then return false end
        n = n + 1
    end
    return n == #v
end


local isString = function(v) return text(v) end
local isNumber = function(v) return finite(v) end
local isBool = function(v) return type(v) == "boolean" end
local isRevision = function(v) return integer(v, 1, 4294967295) end

local rowSpec = { saleId = isString, revision = isRevision, subType = isString, breed = isString, gender = isString,
    purpose = isString, source = isString, ageMonths = function(v) return integer(v, 0, 1000) end, weightKg = isNumber,
    parity = function(v) return integer(v, 0, 100) end, pregnant = isBool, lactating = isBool, price = isNumber }

local validators = {}
validators[P.PAGE .. ":" .. P.REQUEST] = function(v)
    return shape(v, { snapshot = isString, cursor = function(x) return integer(x, 0, 100000) end,
        pageSize = function(x) return integer(x, 1, 50) end, sort = isString, descending = isBool,
        filter = function(f) return shape(f, { breed = isString, purpose = isString, gender = isString, maxPrice = isNumber }) end })
end
validators[P.PAGE .. ":" .. P.REPLY] = function(v)
    return shape(v, { status = isString, reason = isString, catalogEpoch = isString, snapshotSequence = isString,
        total = function(x) return integer(x, 0, 100000) end, nextCursor = function(x) return integer(x, 1, 100000) end,
        rows = function(r) return list(r, 50, function(row) return shape(row, rowSpec) end) end }, { "status" })
end
validators[P.DETAIL .. ":" .. P.REQUEST] = function(v) return shape(v, { saleId = isString, revision = isRevision }, { "saleId", "revision" }) end
validators[P.DETAIL .. ":" .. P.REPLY] = function(v)
    local spec = {}
    for k, f in pairs(rowSpec) do spec[k] = f end
    spec.status, spec.revision = isString, isRevision
    spec.earTag, spec.traceability, spec.evidence = isString, isString, isString
    spec.health, spec.reserveShare, spec.monthsSinceLastBirth = isNumber, isNumber, isNumber
    spec.weaned = isBool
    spec.genetics = function(g) return shape(g, { metabolism = isNumber, quality = isNumber, productivity = isNumber, fertility = isNumber, health = isNumber }) end
    spec.pregnancy = function(g) return shape(g, { fetuses = function(x) return integer(x, 0, 10) end, progress = isNumber }) end
    return shape(v, spec, { "status" })
end
validators[P.DESTINATIONS .. ":" .. P.REQUEST] = function(v)
    return shape(v, { saleIds = function(l) return list(l, P.MAX_SELECTION, isString) end }, { "saleIds" })
end
validators[P.DESTINATIONS .. ":" .. P.REPLY] = function(v)
    return shape(v, { status = isString, reason = isString, destinations = function(l)
        return list(l, 64, function(d) return shape(d, { ref = isString, name = isString, freeSlots = function(x) return integer(x, 0, 100000) end,
            usable = isBool, reason = isString }, { "ref", "usable" }) end)
    end }, { "status" })
end
validators[P.ORDER .. ":" .. P.REQUEST] = function(v) return shape(v, { orderId = isString }, { "orderId" }) end
-- The reply names the order it answers (echoed from the request): the client settles only that order.
validators[P.ORDER .. ":" .. P.REPLY] = function(v)
    return shape(v, { orderId = isString, status = isString, reason = isString, amount = isNumber,
        transferIds = function(l) return list(l, P.MAX_SELECTION, isString) end }, { "status" })
end


--- Check a payload table for (kind, direction). Returns the table or nil and why.
function P.validate(kind, direction, payload)
    local check = validators[tostring(kind) .. ":" .. tostring(direction)]
    if check == nil then return nil, "UNKNOWN_CATALOG_MESSAGE" end
    if RLTradePersistence.check(payload, P.LIMITS) or not check(payload) then return nil, "MALFORMED_CATALOG_PAYLOAD" end
    return payload
end


function P.write(s, kind, direction, requestId, payload)
    if not text(requestId) then return nil, "MALFORMED_REQUEST_ID" end
    local valid, why = P.validate(kind, direction, payload)
    if not valid then return nil, why end
    local encoded = RLTradePersistence.canonical(payload)
    if #encoded > P.MAX_PAYLOAD then return nil, "CATALOG_PAYLOAD_TOO_LARGE" end
    streamWriteUIntN(s, P.VERSION, 8)
    streamWriteUIntN(s, kind, 3)
    streamWriteUIntN(s, direction, 2)
    streamWriteString(s, requestId)
    streamWriteString(s, encoded)
    return true
end


local function read(s)
    local version = streamReadUIntN(s, 8)
    local kind = streamReadUIntN(s, 3)
    local direction = streamReadUIntN(s, 2)
    local requestId = streamReadString(s)
    local encoded = streamReadString(s)
    if version ~= P.VERSION then return nil, "UNKNOWN_CATALOG_PROTOCOL_VERSION" end
    if not text(requestId) then return nil, "MALFORMED_REQUEST_ID" end
    if type(encoded) ~= "string" or #encoded > P.MAX_PAYLOAD then return nil, "CATALOG_PAYLOAD_TOO_LARGE" end
    local payload = RLTradePersistence.parse(encoded, P.LIMITS)
    if payload == nil then return nil, "MALFORMED_CATALOG_PAYLOAD" end
    local valid, why = P.validate(kind, direction, payload)
    if not valid then return nil, why end
    return { kind = kind, direction = direction, requestId = requestId, payload = payload }
end


function P.read(s)
    local ok, message, why = pcall(read, s)
    if not ok then return nil, "MALFORMED_CATALOG_STREAM" end
    return message, why
end
