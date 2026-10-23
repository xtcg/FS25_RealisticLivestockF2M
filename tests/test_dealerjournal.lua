loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/dealer/RLDealerPurchase.lua")
loadMod("scripts/dealer/RLDealerPersistence.lua")
loadMod("scripts/dealer/RLDealerJournal.lua")
local J, P, Codec = RLDealerJournal, RLDealerPurchase, RLTradePersistence
local disk, calls = {}, 0
local storage = {
    save = function(path, data) calls = calls + 1; disk[path] = Codec.canonical(data); return true end,
    load = function(path) local raw = disk[path]; if not raw then return nil, "MISSING" end
        return assert(Codec.parse(raw, RLDealerPersistence.LIMITS)), Codec.checksum(raw) end
}
local journal = assert(J.new("DLtest", "server-1"))
local store = P.new()
check("journal: exact synchronous write/readback advances WAL sequence", J.checkpoint(journal, "/save", P.export(store), 3, storage)
    and journal.sequence == 1 and journal.baseGeneration == 3 and calls == 1)
local loaded = assert(J.load("/save", storage))
check("journal: load retains checkpoint lineage and asset generation without claiming asset commit", loaded.data.lineage == "DLtest"
    and loaded.data.epoch == "server-1" and loaded.data.sequence == 1 and loaded.data.baseGeneration == 3)
check("journal: next complete barrier retains monotonic sequence", J.checkpoint(journal, "/save", P.export(store), 3, storage)
    and journal.sequence == 2)
local corruptRead = { save = storage.save, load = function(path) local data, digest = storage.load(path); data.sequence = 100; return data, digest end }
local no, why = J.checkpoint(journal, "/save", P.export(store), 3, corruptRead)
check("journal: stale or changed readback closes handle and preserves last acknowledged sequence", no == nil
    and why == "JOURNAL_READBACK_UNCERTAIN" and journal.recoveryRequired and journal.sequence == 2)
local count = calls
check("journal: uncertain barrier cannot be retried into an effects authorization", not J.checkpoint(journal, "/save", P.export(store), 3, storage)
    and calls == count)
local failed = assert(J.new("DLtest", "server-2"))
no, why = J.checkpoint(failed, "/save", P.export(store), 3, { save = function() error("disk") end, load = storage.load })
check("journal: write exception fails closed before any asset effect", no == nil and why == "JOURNAL_WRITE_UNCERTAIN"
    and failed.recoveryRequired and failed.sequence == 0)
local invalid = P.export(store); invalid.version = 99
local fresh = assert(J.new("DLtest", "server-3")); count = calls
check("journal: invalid purchase schema refuses before touching prior evidence", not J.checkpoint(fresh, "/save", invalid, 3, storage)
    and calls == count and not fresh.recoveryRequired)
local xml = { values = {} }
function xml:setString(key, value) self.values[key] = value end
function xml:getString(key) return self.values[key] end
function xml:iterate(key, fn)
    local i = 0
    while self.values[key .. "(" .. i .. ")#v"] do fn(i, key .. "(" .. i .. ")"); i = i + 1 end
end
local data = { version = J.VERSION, lineage = "DLtest", epoch = "server-1", sequence = 4, baseGeneration = 3, purchase = P.export(store) }
local ok, digest = J.writeDocument(xml, data)
local decoded, readDigest = J.readDocument(xml)
check("journal: independent XML codec preserves exact whole purchase journal", ok and digest == readDigest
    and Codec.canonical(data) == Codec.canonical(decoded))
xml.values[J.ROOT .. ".data.chunk(0)#v"] = xml.values[J.ROOT .. ".data.chunk(0)#v"] .. "x"
check("journal: damaged chunks are rejected without rewriting evidence", not J.readDocument(xml))
check("journal: invalid directory and unknown identity refuse cleanly", not J.load(nil, storage) and not J.new("bad", "epoch"))
-- Header and payload versions remain bound for legacy and current journal codecs.
xml.values={};data.version=1
assert(J.writeDocument(xml,data))
local legacy=assert(J.readDocument(xml))
check("journal: legacy XML retains its original version and payload",legacy.version==1
    and xml.values[J.ROOT.."#version"]=="1" and Codec.canonical(legacy)==Codec.canonical(data))
xml.values[J.ROOT.."#version"]=tostring(J.VERSION)
local no,why=J.readDocument(xml)
check("journal: new XML header cannot relabel a legacy payload",no==nil and why=="JOURNAL_VERSION")
local no,why=J.load("/save",{load=function() return 42,"invalid" end})
check("journal: malformed storage payload rejects without indexing a scalar",no==nil and why=="BAD_JOURNAL_HEADER")
