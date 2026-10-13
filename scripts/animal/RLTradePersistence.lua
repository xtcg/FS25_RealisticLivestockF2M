--[[
    T02 batch 4: the trade ledger as a savegame document. Pure: it reads and writes through an
    XMLFile-like object (setString / getString / iterate) and touches no game state.

    Encoding. The document is a tree of plain values. It is written as its canonical text (sorted
    keys; every key and scalar typed and length-prefixed: "{", 7:sledger, ..., "}"), percent-encoded
    to plain ASCII and split over <chunk v="..."/> elements of CHUNK characters. Numbers are written
    as integers or %.17g, so amounts and sequences come back bit for bit. Only strings, finite
    numbers, booleans and tables of them are accepted; functions, userdata, cycles, NaN/inf, a key
    that is neither a string nor an integer, deeper than LIMITS.maxDepth, more than
    LIMITS.maxNodes values or a string longer than LIMITS.maxString refuse the whole document.
    Reading (parse) refuses a repeated key, an unknown type, a bad length, trailing text, a
    non-integer number key and the same limits; nothing is truncated or guessed.

    Integrity. checksum() is two 31-bit polynomial hashes of a canonical, length-prefixed text of
    the data (sorted keys, typed values). It detects a damaged or edited document; it is not a
    proof that any action took place, and not a security measure.

    Retention (compact). Never dropped: a record that is not finished, a money receipt whose
    status is UNKNOWN, anything of the current load epoch. The newest LIMITS.detailed finished
    records keep their history and receipts; older ones keep a tombstone (id, kind, fingerprint,
    resources, final state and reason, sequence, sale subset). Finished records and their
    receipts from a past epoch beyond LIMITS.tombstones, and past-epoch wage receipts beyond
    LIMITS.wages, are pruned. That cannot open a replay: every transaction id and herdsman round
    carries the epoch it was issued in, no request brings an id from outside, and a player's
    repeated sale is refused by the animals being gone, not by a record.
]]

RLTradePersistence = {}
local P = RLTradePersistence

P.SCHEMA = 1
P.FILENAME = "rm_RlTradeLedger.xml"
P.ROOT = "rlTradeLedger"
P.INTEGRITY_OK = "OK"
P.INTEGRITY_RECOVERY = "RECOVERY_REQUIRED"
-- maxString: a 1000-head batch's request fingerprint lists every identity (~20 bytes each).
P.LIMITS = { maxNodes = 200000, maxString = 262144, maxDepth = 12, detailed = 100, tombstones = 500, wages = 500 }


local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end


local function sortedKeys(t)
    local numbers, strings = {}, {}
    for k in pairs(t) do
        if type(k) == "number" then numbers[#numbers + 1] = k else strings[#strings + 1] = k end
    end
    table.sort(numbers)
    table.sort(strings)
    for _, k in ipairs(strings) do numbers[#numbers + 1] = k end
    return numbers
end


--- Check a value is plain data within the limits. Returns nil or why not.
function P.check(value, limits)
    limits = limits or P.LIMITS
    local nodes, seen = 0, {}
    local function walk(v, depth)
        nodes = nodes + 1
        if nodes > limits.maxNodes then return "TOO_MANY_VALUES" end
        local tv = type(v)
        if tv == "string" then
            if #v > limits.maxString then return "STRING_TOO_LONG" end
            return nil
        elseif tv == "number" then
            if isFinite(v) then return nil end
            return "BAD_NUMBER"
        elseif tv == "boolean" then
            return nil
        elseif tv ~= "table" then
            return "BAD_TYPE:" .. tv
        end
        if depth >= limits.maxDepth then return "TOO_DEEP" end
        if seen[v] then return "CYCLE" end
        if getmetatable(v) ~= nil then return "METATABLE" end
        seen[v] = true
        for k, child in pairs(v) do
            if type(k) == "number" then
                if not isFinite(k) or k % 1 ~= 0 then return "BAD_KEY" end
            elseif type(k) ~= "string" then
                return "BAD_KEY"
            elseif #k > limits.maxString then
                return "STRING_TOO_LONG"
            end
            local why = walk(child, depth + 1)
            if why ~= nil then return why end
        end
        seen[v] = nil
        return nil
    end
    return walk(value, 0)
end


--- Evidence (receipts, reports) made safe to store: a non-finite number or another type becomes
--- its text, a cycle "<cycle>", too deep "<deep>", a long string cut with "...". Records and money
--- receipts are never passed through this: they must be valid as they are.
function P.sanitize(value, limits)
    limits = limits or P.LIMITS
    local seen = {}
    local function clean(v, depth)
        local tv = type(v)
        if tv == "string" then
            return #v > limits.maxString and (v:sub(1, limits.maxString - 3) .. "...") or v
        elseif tv == "number" then
            return isFinite(v) and v or tostring(v)
        elseif tv == "boolean" then
            return v
        elseif tv ~= "table" then
            return "<" .. tv .. ">"
        end
        if depth >= limits.maxDepth - 1 then return "<deep>" end
        if seen[v] then return "<cycle>" end
        seen[v] = true
        local out = {}
        for k, child in pairs(v) do
            local key = k
            if type(k) == "number" and (not isFinite(k) or k % 1 ~= 0) then key = tostring(k)
            elseif type(k) ~= "number" and type(k) ~= "string" then key = tostring(k) end
            if type(key) == "string" and #key > limits.maxString then key = key:sub(1, limits.maxString) end
            out[key] = clean(child, depth + 1)
        end
        seen[v] = nil
        return out
    end
    return clean(value, 0)
end


local function numberText(v)
    if v % 1 == 0 and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
    return string.format("%.17g", v)
end


--- Canonical text of a checked value: sorted keys, typed and length-prefixed.
function P.canonical(value)
    local out = {}
    local function emit(v)
        local tv = type(v)
        if tv == "table" then
            out[#out + 1] = "{"
            for _, k in ipairs(sortedKeys(v)) do
                local ks = type(k) == "number" and ("n" .. numberText(k)) or ("s" .. k)
                out[#out + 1] = #ks .. ":" .. ks
                emit(v[k])
            end
            out[#out + 1] = "}"
        else
            local vs = tv == "number" and ("n" .. numberText(v)) or tv == "boolean" and ("b" .. tostring(v)) or ("s" .. v)
            out[#out + 1] = #vs .. ":" .. vs
        end
    end
    emit(value)
    return table.concat(out)
end


--- Parse a canonical text back into a value. Returns the value, or nil and why.
function P.parse(text, limits)
    limits = limits or P.LIMITS
    local pos, nodes, n = 1, 0, #text
    local function fail(why) error({ reason = why }, 0) end
    local function lengthPrefixed()
        local colon = text:find(":", pos, true)
        if colon == nil or colon == pos or colon - pos > 9 then fail("BAD_LENGTH") end
        local length = tonumber(text:sub(pos, colon - 1))
        if length == nil or length < 1 or length % 1 ~= 0 or not text:sub(pos, colon - 1):match("^%d+$") then fail("BAD_LENGTH") end
        if colon + length > n then fail("TRUNCATED") end
        local piece = text:sub(colon + 1, colon + length)
        pos = colon + length + 1
        return piece
    end
    local function scalar(piece, isKey)
        local kind, body = piece:sub(1, 1), piece:sub(2)
        if #body > limits.maxString then fail("STRING_TOO_LONG") end
        if kind == "s" then return body end
        if kind == "n" then
            local number = tonumber(body)
            if not isFinite(number) or (isKey and number % 1 ~= 0) then fail("BAD_NUMBER:" .. body) end
            return number
        end
        if kind == "b" and not isKey then
            if body == "true" then return true elseif body == "false" then return false end
        end
        fail("BAD_TYPE:" .. kind)
    end
    local function value(depth)
        nodes = nodes + 1
        if nodes > limits.maxNodes then fail("TOO_MANY_VALUES") end
        if text:sub(pos, pos) ~= "{" then return scalar(lengthPrefixed(), false) end
        if depth >= limits.maxDepth then fail("TOO_DEEP") end
        pos = pos + 1
        local t = {}
        while true do
            if pos > n then fail("TRUNCATED") end
            if text:sub(pos, pos) == "}" then pos = pos + 1 return t end
            local key = scalar(lengthPrefixed(), true)
            if t[key] ~= nil then fail("DUPLICATE_KEY:" .. tostring(key)) end
            t[key] = value(depth + 1)
        end
    end
    local ok, result = pcall(function()
        local v = value(0)
        if pos ~= n + 1 then fail("TRAILING_TEXT") end
        if type(v) ~= "table" then fail("NOT_A_TABLE") end
        return v
    end)
    if not ok then return nil, type(result) == "table" and result.reason or tostring(result) end
    return result
end


-- Percent-encode to plain ASCII without XML-special characters, so chunks can be cut anywhere.
function P.encodeText(text)
    return (text:gsub("[%c%%&<>\"'\128-\255]", function(c) return string.format("%%%02X", c:byte()) end))
end
function P.decodeText(text)
    if text:find("%%[^%x]") or text:find("%%%x[^%x]") or text:find("%%%x?$") then return nil end
    return (text:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

P.CHUNK = 16384


--- The text of an XML file on disk, as the engine serializes it, or nil when the file is missing,
--- does not parse as XML or is longer than maxBytes. Never io.open: FS25's io.open opens every file
--- for WRITE whatever the mode asked (dataS/scripts/io.lua), so reading through it empties the file,
--- and the engine has no other raw read. A file that is not XML cannot be read back at all.
--- @param path string
--- @param maxBytes number|nil
--- @return string|nil
function P.readXMLText(path, maxBytes)
    if type(path) ~= "string" or XMLFile == nil or XMLFile.loadIfExists == nil then return nil end
    local ok, xml = pcall(XMLFile.loadIfExists, "rlReadXMLText", path)
    if not ok or xml == nil then return nil end
    local okText, text = pcall(function() return xml:getAsString() end)
    xml:delete()
    if not okText or type(text) ~= "string" or (maxBytes ~= nil and #text > maxBytes) then return nil end
    return text
end


--- Two 31-bit polynomial hashes of a text (exact in doubles, Lua 5.1 safe).
function P.checksum(text)
    local h1, h2 = 7, 11
    local m1, m2 = 2147483647, 2147483629
    for i = 1, #text do
        local b = text:byte(i)
        h1 = (h1 * 257 + b) % m1
        h2 = (h2 * 131 + b + 1) % m2
    end
    return string.format("%08x%08x", h1, h2)
end


local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end


-- A finished record kept as a tombstone: enough to show what it was and to dedupe it.
local function tombstone(record)
    local t = { id = record.id, kind = record.kind, fingerprint = record.fingerprint, resources = copy(record.resources),
        state = record.state, reason = record.reason, sequence = record.sequence, history = { record.state }, tombstone = true }
    if record.sale ~= nil then
        t.sale = { removed = copy(record.sale.removed), survivors = copy(record.sale.survivors), restored = copy(record.sale.restored),
            amount = record.sale.amount, payment = record.sale.payment, paymentId = record.sale.paymentId }
    end
    return t
end


local function roundNumber(paymentId)
    return tonumber(tostring(paymentId):match("^wage:hr(%d+)")) or 0
end


--- Apply the retention rules to an exported ledger and the receipts. Returns new tables.
--- @param ledger table RLTradeTransaction.export(store)
--- @param receipts table { contract = {[id] = receipt}, sale = {[id] = receipt} }
--- @param epochStart number The ledger sequence at the start of this load epoch
--- @param currentPayments table|nil Payment ids issued in this epoch
--- @return table ledger, table receipts, table stats {tombstoned, pruned, prunedPayments}
function P.compact(ledger, receipts, epochStart, currentPayments, limits)
    limits = limits or P.LIMITS
    local out = { version = ledger.version, sequence = ledger.sequence, records = {}, payments = {} }
    local kept = { contract = {}, sale = {} }
    local stats = { tombstoned = 0, pruned = 0, prunedPayments = 0 }
    local done = {}
    for id, record in pairs(ledger.records) do
        if RLTradeTransaction.FINISHED[record.state] then
            done[#done + 1] = record
        else
            out.records[id] = copy(record)
        end
    end
    table.sort(done, function(a, b) return a.sequence > b.sequence end)
    for i, record in ipairs(done) do
        if i <= limits.detailed and not record.tombstone then
            out.records[record.id] = copy(record)
        elseif i <= limits.detailed + limits.tombstones or record.sequence > epochStart then
            out.records[record.id] = tombstone(record)
            stats.tombstoned = stats.tombstoned + (record.tombstone and 0 or 1)
        else
            stats.pruned = stats.pruned + 1
        end
    end
    for kind, list in pairs(receipts or {}) do
        for id, receipt in pairs(list) do
            local record = out.records[id]
            if record ~= nil and not record.tombstone then kept[kind][id] = copy(receipt) end
        end
    end
    local wages = {}
    for id, payment in pairs(ledger.payments or {}) do
        local current = currentPayments ~= nil and currentPayments[id]
        if payment.status == "UNKNOWN" or payment.status == nil or current then
            out.payments[id] = copy(payment)
        elseif payment.kind == "WAGE" then
            wages[#wages + 1] = payment
        elseif out.records[payment.ref or ""] ~= nil then
            out.payments[id] = copy(payment)
        else
            stats.prunedPayments = stats.prunedPayments + 1
        end
    end
    table.sort(wages, function(a, b)
        local ra, rb = roundNumber(a.paymentId), roundNumber(b.paymentId)
        if ra ~= rb then return ra > rb end
        return a.paymentId > b.paymentId
    end)
    for i, payment in ipairs(wages) do
        if i <= limits.wages then out.payments[payment.paymentId] = copy(payment)
        else stats.prunedPayments = stats.prunedPayments + 1 end
    end
    return out, kept, stats
end


--- Write a document to an XMLFile-like object. Returns true, or nil and why (nothing written).
--- @param xml table XMLFile with setString
--- @param meta table {lineage, generation, integrity, reason}
--- @param data table The plain document data
function P.writeDocument(xml, meta, data)
    local why = P.check(data)
    if why ~= nil then return nil, "BAD_DOCUMENT:" .. why end
    local text = P.canonical(data)
    local digest = P.checksum(text)
    xml:setString(P.ROOT .. "#schema", tostring(P.SCHEMA))
    xml:setString(P.ROOT .. "#lineage", meta.lineage)
    xml:setString(P.ROOT .. "#generation", numberText(meta.generation))
    xml:setString(P.ROOT .. "#integrity", meta.integrity)
    if meta.reason ~= nil then xml:setString(P.ROOT .. "#reason", P.encodeText(meta.reason)) end
    xml:setString(P.ROOT .. "#digest", digest)
    local encoded = P.encodeText(text)
    xml:setString(P.ROOT .. ".data#length", tostring(#encoded))
    local index = 0
    for start = 1, #encoded, P.CHUNK do
        xml:setString(string.format("%s.data.chunk(%d)#v", P.ROOT, index), encoded:sub(start, start + P.CHUNK - 1))
        index = index + 1
    end
    return true, digest
end


--- Read and verify a document. Returns {meta, data} or nil and why.
function P.readDocument(xml)
    local schema = tonumber(xml:getString(P.ROOT .. "#schema"))
    if schema == nil then return nil, "NO_SCHEMA" end
    if schema ~= P.SCHEMA then return nil, (schema > P.SCHEMA and "NEWER_SCHEMA:" or "UNKNOWN_SCHEMA:") .. schema end
    local meta = { lineage = xml:getString(P.ROOT .. "#lineage"), generation = tonumber(xml:getString(P.ROOT .. "#generation")),
        integrity = xml:getString(P.ROOT .. "#integrity"), reason = P.decodeText(xml:getString(P.ROOT .. "#reason") or ""),
        digest = xml:getString(P.ROOT .. "#digest") }
    if type(meta.lineage) ~= "string" or not meta.lineage:match("^L[%w%-]+$") then return nil, "BAD_LINEAGE" end
    if not isFinite(meta.generation) or meta.generation < 1 or meta.generation % 1 ~= 0 then return nil, "BAD_GENERATION" end
    if meta.integrity ~= P.INTEGRITY_OK and meta.integrity ~= P.INTEGRITY_RECOVERY then return nil, "BAD_INTEGRITY" end
    local parts = {}
    xml:iterate(P.ROOT .. ".data.chunk", function(_, key) parts[#parts + 1] = xml:getString(key .. "#v") or "" end)
    local encoded = table.concat(parts)
    if tonumber(xml:getString(P.ROOT .. ".data#length")) ~= #encoded then return nil, "BAD_DATA:LENGTH" end
    local text = P.decodeText(encoded)
    if text == nil then return nil, "BAD_DATA:ENCODING" end
    if P.checksum(text) ~= meta.digest then return nil, "DIGEST_MISMATCH" end
    local data, why = P.parse(text)
    if data == nil then return nil, "BAD_DATA:" .. tostring(why) end
    if data.lineage ~= meta.lineage or data.generation ~= meta.generation then return nil, "HEADER_MISMATCH" end
    return { meta = meta, data = data }
end
