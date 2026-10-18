--[[
    RLSemenBatch.lua
    Batch identity of semen: one dewar holds one batch, and a batch keeps who, when and where it
    came from through every copy of the sire snapshot (dewar, object storage, hand-tool straw,
    straw ledger, a female's pending insemination).

    A batch is one sire's semen from one source in one month:
        collected  "C-<country>-<herd>-<id>-<month>"   one collection per sire per month
        purchased  "P-<country>-<herd>-<id>-<month>"   the dealer's straws of that bull that month
        legacy     "L-<dewar or sire>"                 a dewar or straw saved before batches
    <month> is the running month index (RLSemenCollection.getMonthIndex). Splitting a batch over
    straws, storing or moving a dewar never changes these fields.

    Fields on the snapshot (all optional for old data):
        batchId       string
        batchSource   "COLLECTED" | "PURCHASED" | "LEGACY"
        batchMonth    running month index, nil when unknown (legacy)
        priceRule     version of the semen price rules the batch was valued under (1 = batch 1)
        sireFatherId  the sire's father ("<country> <herd> <id>"), "" or nil when unknown
        sireMotherId  the sire's mother, the same
]]

RLSemenBatch = {}

local Log = RmLogging.getLogger("RLRM")

RLSemenBatch.SOURCE = { COLLECTED = "COLLECTED", PURCHASED = "PURCHASED", LEGACY = "LEGACY" }

--- Semen price rules a new batch is valued under.
RLSemenBatch.PRICE_RULE = 1

local PREFIX = { COLLECTED = "C", PURCHASED = "P" }


--- The sire's ear tag in a snapshot, as "country-herd-id".
local function getSireTag(snapshot)
    return string.format("%s-%s-%s", tostring(snapshot.country), tostring(snapshot.farmId), tostring(snapshot.uniqueId))
end


--- The id a new batch of `source` from this sire in `month` gets.
function RLSemenBatch.makeId(source, snapshot, month)
    return string.format("%s-%s-%s", PREFIX[source] or "L", getSireTag(snapshot), tostring(month or "x"))
end


--- Stamp a sire snapshot as a new batch. The sire's parents come from `sire` (a live animal)
--- when given.
--- @param snapshot table Dewar snapshot
--- @param source string RLSemenBatch.SOURCE.COLLECTED or PURCHASED
--- @param month number|nil Running month index
--- @param sire table|nil Live animal with fatherId / motherId
--- @return table snapshot
function RLSemenBatch.stamp(snapshot, source, month, sire)
    snapshot.batchSource = source
    snapshot.batchMonth = month
    snapshot.batchId = RLSemenBatch.makeId(source, snapshot, month)
    snapshot.priceRule = RLSemenBatch.PRICE_RULE
    if sire ~= nil then
        snapshot.sireFatherId = sire.fatherId
        snapshot.sireMotherId = sire.motherId
    end
    return snapshot
end


--- Give a snapshot saved before batches a batch id of its own: `salt` is the dewar's unique id
--- (one dewar, one batch) or, for a straw, its dewar's id or else the sire. The source follows
--- the old `collected` flag; the month is unknown. A snapshot that has an id is left alone.
--- @return boolean added
function RLSemenBatch.ensure(snapshot, salt)
    if snapshot == nil or (snapshot.batchId ~= nil and snapshot.batchId ~= "") then return false end
    snapshot.batchId = "L-" .. tostring(salt ~= nil and salt ~= "" and salt or getSireTag(snapshot))
    snapshot.batchSource = snapshot.collected and RLSemenBatch.SOURCE.COLLECTED or RLSemenBatch.SOURCE.LEGACY
    snapshot.priceRule = snapshot.priceRule or 0
    Log:debug("RLSemenBatch.ensure: legacy batch %s for sire %s", snapshot.batchId, getSireTag(snapshot))
    return true
end


--- Whether two snapshots are the same batch: the same batch id, or for data without ids on
--- either side, the same sire.
function RLSemenBatch.isSameBatch(a, b)
    if a == nil or b == nil then return false end
    if a.batchId ~= nil and b.batchId ~= nil then return a.batchId == b.batchId end
    return tostring(a.country) == tostring(b.country) and tostring(a.farmId) == tostring(b.farmId)
        and tostring(a.uniqueId) == tostring(b.uniqueId)
end


--- Copy the batch fields from one snapshot to another (setInsemination, straws).
function RLSemenBatch.copyFields(from, to)
    if from == nil or to == nil then return to end
    to.batchId, to.batchSource, to.batchMonth = from.batchId, from.batchSource, from.batchMonth
    to.priceRule, to.sireFatherId, to.sireMotherId = from.priceRule, from.sireFatherId, from.sireMotherId
    return to
end


-- ---------------------------------------------------------------------------
-- Serialization: the batch fields follow a snapshot's existing ones
-- ---------------------------------------------------------------------------

function RLSemenBatch.writeStream(streamId, snapshot)
    streamWriteString(streamId, snapshot.batchId or "")
    streamWriteString(streamId, snapshot.batchSource or "")
    streamWriteInt32(streamId, snapshot.batchMonth or -1)
    streamWriteUInt8(streamId, snapshot.priceRule or 0)
    streamWriteString(streamId, snapshot.sireFatherId or "")
    streamWriteString(streamId, snapshot.sireMotherId or "")
end


function RLSemenBatch.readStream(streamId, snapshot)
    local function orNil(value) if value == "" then return nil end return value end
    snapshot.batchId = orNil(streamReadString(streamId))
    snapshot.batchSource = orNil(streamReadString(streamId))
    local month = streamReadInt32(streamId)
    snapshot.batchMonth = month >= 0 and month or nil
    snapshot.priceRule = streamReadUInt8(streamId)
    snapshot.sireFatherId = orNil(streamReadString(streamId))
    snapshot.sireMotherId = orNil(streamReadString(streamId))
    return snapshot
end


--- Attributes on a snapshot's XML element: name, XMLValueType name, typed setter, typed getter.
RLSemenBatch.XML_FIELDS = {
    { "batchId", "STRING", "setString", "getString" },
    { "batchSource", "STRING", "setString", "getString" },
    { "batchMonth", "INT", "setInt", "getInt" },
    { "priceRule", "INT", "setInt", "getInt" },
    { "sireFatherId", "STRING", "setString", "getString" },
    { "sireMotherId", "STRING", "setString", "getString" },
}


--- Write the batch attributes under `key` (the snapshot's element). `generic` uses
--- setValue / getValue (a schema-registered file such as object storage), otherwise the typed
--- setters (vehicle and hand-tool savegames).
function RLSemenBatch.saveToXML(xmlFile, key, snapshot, generic)
    for _, field in ipairs(RLSemenBatch.XML_FIELDS) do
        local value = snapshot[field[1]]
        if value ~= nil and value ~= "" then
            if generic then xmlFile:setValue(key .. "#" .. field[1], value) else xmlFile[field[3]](xmlFile, key .. "#" .. field[1], value) end
        end
    end
end


function RLSemenBatch.loadFromXML(xmlFile, key, snapshot, generic)
    for _, field in ipairs(RLSemenBatch.XML_FIELDS) do
        local value
        if generic then value = xmlFile:getValue(key .. "#" .. field[1]) else value = xmlFile[field[4]](xmlFile, key .. "#" .. field[1]) end
        if value ~= "" then snapshot[field[1]] = value end
    end
    return snapshot
end


--- Register the batch attributes under `key` in an XML schema.
function RLSemenBatch.registerXMLPaths(schema, key)
    for _, field in ipairs(RLSemenBatch.XML_FIELDS) do
        schema:register(XMLValueType[field[2]], key .. "#" .. field[1], "Semen batch " .. field[1])
    end
end


-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------

--- The batch's month as "<month name> <year>", nil when unknown.
function RLSemenBatch.getMonthText(snapshot)
    local month = snapshot ~= nil and snapshot.batchMonth or nil
    if month == nil then return nil end
    local period = month % 12 + 1
    return string.format("%s %d", g_i18n:formatPeriod(period), math.floor(month / 12))
end


--- Info lines of a batch for an info box: { title, value } pairs.
function RLSemenBatch.getInfoLines(snapshot)
    if snapshot == nil or snapshot.batchId == nil then return {} end
    local lines = { { g_i18n:getText("rl_semen_batch"), snapshot.batchId } }
    local sourceKey = snapshot.batchSource ~= nil and ("rl_semen_source" .. snapshot.batchSource) or nil
    if sourceKey ~= nil then lines[#lines + 1] = { g_i18n:getText("rl_semen_source"), g_i18n:getText(sourceKey) } end
    local monthText = RLSemenBatch.getMonthText(snapshot)
    if monthText ~= nil then lines[#lines + 1] = { g_i18n:getText("rl_semen_batchMonth"), monthText } end
    return lines
end


Log:debug("RLSemenBatch: loaded")
