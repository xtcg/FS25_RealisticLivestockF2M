-- Synchronous dealer write-ahead journal. XML save+exact readback is a required
-- barrier; it is not an engine asset save or a power-loss/fsync guarantee.
-- A WAL ahead of the coordinated asset checkpoint requires ownership rechecking
-- of EVERY record, including terminal receipts (Purchase.import forceReconciliation).
RLDealerJournal = { VERSION = 1, FILENAME = "rm_RlDealerPurchaseJournal.xml", ROOT = "rlDealerPurchaseJournal" }
local J = RLDealerJournal
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function integer(v) return finite(v) and v >= 0 and v % 1 == 0 end
local function text(v) return type(v) == "string" and #v > 0 and #v <= 256 end
local function keys(t, allowed)
    if type(t) ~= "table" then return false end
    for k in pairs(t) do if not allowed[k] then return false end end
    return true
end
function J.new(lineage, epoch)
    if not text(lineage) or not lineage:match("^DL[%w%-]+$") or not text(epoch) then return nil, "JOURNAL_IDENTITY" end
    return { version = J.VERSION, lineage = lineage, epoch = epoch, sequence = 0, recoveryRequired = false }
end
local function valid(data)
    if not keys(data,{version=true,lineage=true,epoch=true,sequence=true,baseGeneration=true,purchase=true,recovery=true})
        or RLTradePersistence.check(data, RLDealerPersistence.LIMITS)
        or data.version ~= J.VERSION or not text(data.lineage) or not data.lineage:match("^DL[%w%-]+$")
        or not text(data.epoch) or not integer(data.sequence) or data.sequence < 1
        or not integer(data.baseGeneration) then return nil, "BAD_JOURNAL_HEADER" end
    local store, why = RLDealerPurchase.import(data.purchase)
    if not store then return nil, why end
    if data.recovery ~= nil then
        local r=data.recovery
        if not keys(r,{version=true,clockMonths=true,sources=true,sourceOwnership=true,money=true}) or r.version~=1
            or not finite(r.clockMonths) or r.clockMonths<0 or type(r.sources)~="table" or r.sourceOwnership==nil
            or RLDealerOwnedStock==nil then return nil,"BAD_JOURNAL_RECOVERY" end
        local owned;owned,why=RLDealerOwnedStock.validate(r.sourceOwnership,r.sources,r.clockMonths)
        if not owned then return nil,why end
        if r.money~=nil then
            if RLDealerMoneyAdapter==nil then return nil,"JOURNAL_MONEY_CAPABILITY" end
            local money;money,why=RLDealerMoneyAdapter.validate(r.money)
            if not money then return nil,why end
        end
    end
    return store
end
local function write(xml, data)
    local store, why = valid(data); if not store then return nil, why end
    local canonical = RLTradePersistence.canonical(data)
    local encoded = RLTradePersistence.encodeText(canonical)
    if #encoded > RLDealerPersistence.MAX_ENCODED_BYTES then return nil, "JOURNAL_TOO_LARGE" end
    local digest = RLTradePersistence.checksum(canonical)
    xml:setString(J.ROOT .. "#version", tostring(J.VERSION))
    xml:setString(J.ROOT .. "#digest", digest)
    xml:setString(J.ROOT .. ".data#length", tostring(#encoded))
    local index = 0
    for start = 1, #encoded, RLTradePersistence.CHUNK do
        xml:setString(string.format("%s.data.chunk(%d)#v", J.ROOT, index), encoded:sub(start, start + RLTradePersistence.CHUNK - 1))
        index = index + 1
    end
    return true, digest
end
local function read(xml)
    if tonumber(xml:getString(J.ROOT .. "#version")) ~= J.VERSION then return nil, "JOURNAL_VERSION" end
    local parts, size = {}, 0
    xml:iterate(J.ROOT .. ".data.chunk", function(_, key)
        local part = xml:getString(key .. "#v")
        if type(part) ~= "string" then size = math.huge; return end
        size = size + #part
        if size <= RLDealerPersistence.MAX_ENCODED_BYTES then parts[#parts + 1] = part end
    end)
    if size > RLDealerPersistence.MAX_ENCODED_BYTES then return nil, "JOURNAL_TOO_LARGE" end
    local encoded = table.concat(parts)
    if tonumber(xml:getString(J.ROOT .. ".data#length")) ~= #encoded then return nil, "JOURNAL_LENGTH" end
    local canonical = RLTradePersistence.decodeText(encoded)
    if not canonical then return nil, "JOURNAL_ENCODING" end
    local digest = RLTradePersistence.checksum(canonical)
    if digest ~= xml:getString(J.ROOT .. "#digest") then return nil, "JOURNAL_DIGEST" end
    local data, why = RLTradePersistence.parse(canonical, RLDealerPersistence.LIMITS)
    if not data then return nil, why end
    local store; store, why = valid(data)
    if not store then return nil, why end
    return data, digest
end
local defaultStorage = {}
function defaultStorage.save(path, data)
    local xml = XMLFile.create("rlDealerJournalWrite", path, J.ROOT)
    if xml == nil then return nil, "JOURNAL_CREATE" end
    local ok, digest = write(xml, data)
    local saved = ok and xml:save() == true
    xml:delete()
    if not saved then return nil, digest or "JOURNAL_SAVE" end
    return true, digest
end
function defaultStorage.load(path)
    local xml = XMLFile.loadIfExists("rlDealerJournalRead", path)
    if xml == nil then return nil, "JOURNAL_MISSING" end
    local data, digest = read(xml); xml:delete()
    return data, digest
end
function J.checkpoint(journal, directory, purchase, baseGeneration, storage, recovery)
    if type(journal) ~= "table" or journal.version ~= J.VERSION or journal.recoveryRequired
        or not text(directory) or not integer(journal.sequence) or not integer(baseGeneration) then return nil, "JOURNAL_CLOSED" end
    storage = storage or defaultStorage
    local data = { version = J.VERSION, lineage = journal.lineage, epoch = journal.epoch,
        sequence = journal.sequence + 1, baseGeneration = baseGeneration, purchase = purchase, recovery = recovery }
    local store, why = valid(data); if not store then return nil, why end
    local canonical = RLTradePersistence.canonical(data)
    local digest = RLTradePersistence.checksum(canonical)
    local path = directory .. "/" .. J.FILENAME
    -- Once writing starts, any unknown result closes this handle. Never retry
    -- uncertain storage over an older successful stage and then proceed to effects.
    local ok, saved = pcall(storage.save, path, data)
    if not ok or saved ~= true then journal.recoveryRequired = true; return nil, "JOURNAL_WRITE_UNCERTAIN" end
    local readOK, actual, actualDigest = pcall(storage.load, path)
    if not readOK or type(actual) ~= "table" or actualDigest ~= digest
        or RLTradePersistence.check(actual, RLDealerPersistence.LIMITS)
        or RLTradePersistence.canonical(actual) ~= canonical then
        journal.recoveryRequired = true; return nil, "JOURNAL_READBACK_UNCERTAIN"
    end
    journal.sequence, journal.digest, journal.baseGeneration = data.sequence, digest, baseGeneration
    return true
end
-- The caller compares this WAL with the independently verified game checkpoint.
-- This method never authorizes a replay or mutates assets, source inventory or money.
function J.load(directory, storage)
    if not text(directory) then return nil, "JOURNAL_DIRECTORY" end
    local ok, data, digest = pcall((storage or defaultStorage).load, directory .. "/" .. J.FILENAME)
    if not ok or data == nil then return nil, ok and digest or "JOURNAL_READ_ERROR" end
    local store, why = valid(data); if not store then return nil, why end
    if RLTradePersistence.checksum(RLTradePersistence.canonical(data)) ~= digest then return nil, "JOURNAL_DIGEST" end
    return { data = data, digest = digest }
end
J.writeDocument, J.readDocument = write, read
