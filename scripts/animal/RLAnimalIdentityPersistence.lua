--[[
    Dealer v2 T2b: the identity ledger and the unsaved-key journal as XML documents. Pure: reads and
    writes through an XMLFile-like object (setString / getString / iterate), no game state.

    Same encoding as RLTradePersistence (canonical text, percent-encoded, cut into <chunk v=""/>),
    with its own roots, so a damaged or foreign document is refused by its digest and header.
    Ledger document: lineage, generation, the exported RLAnimalIdentity ledger, mode and the
    participants of that save. Journal document: the full keys allocated since the last complete
    save, bound to the generation that save had; it is read on load only to burn those keys.
]]

RLAnimalIdentityPersistence = {}
local P = RLAnimalIdentityPersistence
local T = RLTradePersistence

P.SCHEMA = 1
P.FILENAME = "rm_RlAnimalIdentityLedger.xml"
P.ROOT = "rlAnimalIdentity"
P.JOURNAL_FILENAME = "rm_RlAnimalIdentityJournal.xml"
P.JOURNAL_ROOT = "rlAnimalIdentityJournal"
P.LIMITS = { maxNodes = 1500000, maxString = 16 * 1024 * 1024, maxDepth = 12 }
P.MAX_JOURNAL_KEYS = 20000


local function write(xml, root, meta, data)
    local why = T.check(data, P.LIMITS)
    if why ~= nil then return nil, "BAD_DOCUMENT:" .. why end
    local text = T.canonical(data)
    local digest = T.checksum(text)
    xml:setString(root .. "#schema", tostring(P.SCHEMA))
    xml:setString(root .. "#lineage", meta.lineage)
    xml:setString(root .. "#generation", string.format("%d", meta.generation))
    xml:setString(root .. "#digest", digest)
    local encoded = T.encodeText(text)
    xml:setString(root .. ".data#length", tostring(#encoded))
    local index = 0
    for start = 1, #encoded, T.CHUNK do
        xml:setString(string.format("%s.data.chunk(%d)#v", root, index), encoded:sub(start, start + T.CHUNK - 1))
        index = index + 1
    end
    return true, digest
end


local function read(xml, root)
    local schema = tonumber(xml:getString(root .. "#schema"))
    if schema == nil then return nil, "NO_SCHEMA" end
    if schema ~= P.SCHEMA then return nil, (schema > P.SCHEMA and "NEWER_SCHEMA:" or "UNKNOWN_SCHEMA:") .. schema end
    local meta = { lineage = xml:getString(root .. "#lineage"), generation = tonumber(xml:getString(root .. "#generation")),
        digest = xml:getString(root .. "#digest") }
    if type(meta.lineage) ~= "string" or not meta.lineage:match("^L[%w%-]+$") then return nil, "BAD_LINEAGE" end
    if meta.generation == nil or meta.generation < 0 or meta.generation % 1 ~= 0 then return nil, "BAD_GENERATION" end
    local parts = {}
    xml:iterate(root .. ".data.chunk", function(_, key) parts[#parts + 1] = xml:getString(key .. "#v") or "" end)
    local encoded = table.concat(parts)
    if tonumber(xml:getString(root .. ".data#length")) ~= #encoded then return nil, "BAD_DATA:LENGTH" end
    local text = T.decodeText(encoded)
    if text == nil then return nil, "BAD_DATA:ENCODING" end
    if T.checksum(text) ~= meta.digest then return nil, "DIGEST_MISMATCH" end
    local data, why = T.parse(text, P.LIMITS)
    if data == nil then return nil, "BAD_DATA:" .. tostring(why) end
    if data.lineage ~= meta.lineage or data.generation ~= meta.generation then return nil, "HEADER_MISMATCH" end
    return { meta = meta, data = data }
end


--- data = { lineage, generation, mode, ledger = <RLAnimalIdentity.export>, participants = { name = true } }
function P.writeLedger(xml, data)
    if type(data) ~= "table" or type(data.ledger) ~= "table" then return nil, "BAD_DOCUMENT" end
    return write(xml, P.ROOT, { lineage = data.lineage, generation = data.generation }, data)
end


--- Returns { meta, data, ledger } with the ledger already imported (digest and structure checked), or nil and why.
function P.readLedger(xml)
    local doc, why = read(xml, P.ROOT)
    if doc == nil then return nil, why end
    local ledger
    ledger, why = RLAnimalIdentity.import(doc.data.ledger)
    if ledger == nil then return nil, "BAD_LEDGER:" .. tostring(why) end
    if ledger.lineage ~= doc.data.lineage then return nil, "LEDGER_LINEAGE" end
    if type(doc.data.participants) ~= "table" then return nil, "NO_PARTICIPANTS" end
    doc.ledger = ledger
    return doc
end


--- data = { lineage, generation = baseGeneration, sequence, keys = { "farm uniqueId country", ... } }
function P.writeJournal(xml, data)
    if type(data) ~= "table" or type(data.keys) ~= "table" or #data.keys > P.MAX_JOURNAL_KEYS then return nil, "BAD_JOURNAL" end
    return write(xml, P.JOURNAL_ROOT, { lineage = data.lineage, generation = data.generation }, data)
end


function P.readJournal(xml)
    local doc, why = read(xml, P.JOURNAL_ROOT)
    if doc == nil then return nil, why end
    local keys = doc.data.keys
    if type(keys) ~= "table" or #keys > P.MAX_JOURNAL_KEYS then return nil, "BAD_JOURNAL" end
    for i, key in ipairs(keys) do
        if type(key) ~= "string" or RLAnimalIdentity.parseKey(key) == nil then return nil, "BAD_JOURNAL_KEY:" .. i end
    end
    return doc
end
