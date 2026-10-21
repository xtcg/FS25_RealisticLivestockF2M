-- Semen batch identity (batch 2): ids, legacy ids, same-batch rule, stream and XML round trips
-- through the dewar, object storage and insemination, the straw ledger and straw return.

g_currentMission = { environment = { currentYear = 3, currentPeriod = 5 }, animalSystem = {} }
g_i18n = { getText = function(_, k) return k end, formatPeriod = function(_, p) return "P" .. p end }
g_xmlManager = { addInitSchemaFunction = function() end }
loadMod("scripts/insemination/RLSemenBatch.lua")
loadMod("scripts/insemination/RLSemenCollection.lua")
loadMod("scripts/insemination/RLStrawLedger.lua")
loadMod("scripts/insemination/DewarObjectStorageHook.lua")

local B = RLSemenBatch
local MONTH = 3 * 12 + 5 - 1

local function sire(extra)
    local s = { country = 6, farmId = "12", uniqueId = "77", name = "Max", typeIndex = 1, subTypeIndex = 1, success = 0.5,
        genetics = { metabolism = 1, fertility = 1.2, health = 1, quality = 1.1, productivity = 1 } }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

-- Ids
local live = { fatherId = "DE 5 101", motherId = "DE 5 102" }
local c = B.stamp(sire(), B.SOURCE.COLLECTED, MONTH, live)
check("stamp: collected id carries sire and month", c.batchId == "C-6-12-77-" .. MONTH)
check("stamp: source, month, price rule and the sire's parents",
    c.batchSource == "COLLECTED" and c.batchMonth == MONTH and c.priceRule == B.PRICE_RULE
    and c.sireFatherId == "DE 5 101" and c.sireMotherId == "DE 5 102")
local p = B.stamp(sire(), B.SOURCE.PURCHASED, MONTH)
check("stamp: purchased id differs from collected", p.batchId == "P-6-12-77-" .. MONTH and p.batchId ~= c.batchId)
local nextMonth = B.stamp(sire(), B.SOURCE.COLLECTED, MONTH + 1)
check("same sire, next month: another batch", not B.isSameBatch(c, nextMonth))
check("same id: same batch", B.isSameBatch(c, B.stamp(sire(), B.SOURCE.COLLECTED, MONTH)))

-- A collection snapshot is stamped
local animal = { birthday = { country = 6 }, farmId = "12", uniqueId = "77", animalTypeIndex = 1, subTypeIndex = 1,
    genetics = { fertility = 1 }, fatherId = "DE 5 101", getName = function() return "Max" end }
local snap = RLSemenCollection.createSnapshot(animal)
check("collection snapshot: this month's collected batch with the sire's father",
    snap.batchId == "C-6-12-77-" .. MONTH and snap.collected == true and snap.sireFatherId == "DE 5 101")

-- Legacy
local old = sire({ collected = true })
check("legacy: id from the dewar", B.ensure(old, "dewar-9") and old.batchId == "L-dewar-9"
    and old.batchSource == "COLLECTED" and old.batchMonth == nil and old.priceRule == 0)
check("legacy: an id is never replaced", not B.ensure(old, "other") and old.batchId == "L-dewar-9")
local oldStraw = sire()
B.ensure(oldStraw, nil)
check("legacy: a straw without its dewar falls back to the sire", oldStraw.batchId == "L-6-12-77" and oldStraw.batchSource == "LEGACY")
check("legacy: without ids on either side the sire decides", B.isSameBatch(sire(), sire()) and not B.isSameBatch(sire(), sire({ uniqueId = "78" })))

-- Stream
local q = {}
local function w(v) q[#q + 1] = v end
local function r() return table.remove(q, 1) end
streamWriteString, streamReadString = function(_, v) w(v) end, function() return r() end
streamWriteInt32, streamReadInt32 = function(_, v) w(v) end, function() return r() end
streamWriteUInt8, streamReadUInt8 = function(_, v) w(v) end, function() return r() end
streamWriteUInt16, streamReadUInt16 = function(_, v) w(v) end, function() return r() end
streamWriteFloat32, streamReadFloat32 = function(_, v) w(v) end, function() return r() end
streamWriteBool, streamReadBool = function(_, v) w(v) end, function() return r() end

q = {}
B.writeStream(1, c)
local got = B.readStream(1, {})
check("stream: every batch field round-trips", #q == 0 and got.batchId == c.batchId and got.batchSource == "COLLECTED"
    and got.batchMonth == MONTH and got.priceRule == 1 and got.sireFatherId == "DE 5 101" and got.sireMotherId == "DE 5 102")
q = {}
B.writeStream(1, sire())
got = B.readStream(1, {})
check("stream: missing fields come back nil", #q == 0 and got.batchId == nil and got.batchMonth == nil and got.sireFatherId == nil)

-- XML (typed and generic)
local function fakeXML()
    local x = { v = {} }
    function x:setString(k, v) self.v[k] = v end
    function x:setInt(k, v) self.v[k] = v end
    function x:getString(k) return self.v[k] end
    function x:getInt(k) return self.v[k] end
    function x:setValue(k, v) self.v[k] = v end
    function x:getValue(k) return self.v[k] end
    function x:hasProperty(k)
        for key in pairs(self.v) do if key:sub(1, #k) == k then return true end end
        return false
    end
    return x
end
local xml = fakeXML()
B.saveToXML(xml, "a", c)
got = B.loadFromXML(xml, "a", {})
check("xml: typed round trip", got.batchId == c.batchId and got.batchMonth == MONTH and got.sireMotherId == "DE 5 102")
xml = fakeXML()
B.saveToXML(xml, "a", sire())
check("xml: nothing written for a snapshot without batch fields", next(xml.v) == nil)

-- Object storage keeps the batch
DewarData = { SPEC_TABLE_NAME = "spec" }
local vehicle = { isDewar = true, spec = { straws = 40, animal = c }, getUniqueId = function() return "D1" end }
local state = DewarObjectStorageHook.snapshot(vehicle)
check("storage: snapshot keeps the batch", state.animal.batchId == c.batchId and state.animal.sireFatherId == "DE 5 101")
xml = fakeXML()
DewarObjectStorageHook.writeStateToXML(state, xml, "o")
local back = DewarObjectStorageHook.readStateFromXML(xml, "o")
check("storage: XML round trip keeps batch id, source and month",
    back.animal.batchId == c.batchId and back.animal.batchSource == "COLLECTED" and back.animal.batchMonth == MONTH and back.straws == 40)

-- Insemination: the batch rides on the female's pending insemination
local ins = B.copyFields(c, { uniqueId = "77" })
check("insemination: batch fields copied", ins.batchId == c.batchId and ins.sireMotherId == "DE 5 102")

-- Ledger: return to any dewar of the batch, use only the batch held
local function dewar(id, snapshot, owner)
    local d = { isDewar = true, straws = 10, uniqueId = id }
    function d:getUniqueId() return self.uniqueId end
    function d:getAnimal() return snapshot end
    function d:getOwnerFarmId() return owner or 1 end
    return d
end
local emptyGone = dewar("D-A", c)
local sameBatch = dewar("D-B", B.stamp(sire(), B.SOURCE.COLLECTED, MONTH))
local otherBatch = dewar("D-C", nextMonth)
RLStrawLedger.held = {}
RLStrawLedger.record("u", emptyGone)
check("ledger: no return into another batch's dewar", not RLStrawLedger.spendForReturn("u", otherBatch))
check("ledger: return into another dewar of the same batch", RLStrawLedger.spendForReturn("u", sameBatch) and RLStrawLedger.count("u") == 0)
RLStrawLedger.record("u", emptyGone)
RLStrawLedger.record("u", otherBatch)
local used = RLStrawLedger.spendForSemen("u", { country = 6, farmId = "12", uniqueId = "77", batchId = nextMonth.batchId })
check("ledger: insemination spends the straw of the batch named, not the sire's first",
    used ~= nil and used.batchId == nextMonth.batchId and RLStrawLedger.count("u") == 1
    and RLStrawLedger.held.u[1].snapshot.batchId == c.batchId)
RLStrawLedger.held = {}
RLStrawLedger.record("u", dewar("D-L", sire()))
check("ledger: legacy straw without batch matches its sire", RLStrawLedger.spendForSemen("u", sire()) ~= nil)

-- Dewar: full sync stream, savegame, and old data
loadMod("scripts/insemination/DewarData.lua")
DewarData.syncCompatProperties = function() end
DewarData.registerWithManager = function() end
DewarData.updateStrawVisuals = function() end
DewarData.updateAnimalVisuals = function() end
local function mkVehicle(id, snapshot)
    local v = { [DewarData.SPEC_TABLE_NAME] = { straws = 25, animal = snapshot } }
    function v:getUniqueId() return id end
    function v:setUniqueId() end
    function v:getOwnerFarmId() return 1 end
    return v
end
q = {}
DewarData.onWriteStream(mkVehicle("D1", c), 1)
local client = mkVehicle("D1", nil)
DewarData.onReadStream(client, 1)
local ca = client[DewarData.SPEC_TABLE_NAME].animal
check("dewar stream: batch arrives on the client", #q == 0 and ca.batchId == c.batchId and ca.batchMonth == MONTH
    and ca.sireFatherId == "DE 5 101" and ca.genetics.quality == 1.1)
function fakeXMLTyped()
    local x = fakeXML()
    function x:setFloat(k, v) self.v[k] = v end
    function x:getFloat(k) return self.v[k] end
    function x:setBool(k, v) self.v[k] = v end
    function x:getBool(k, d) local v = self.v[k] if v == nil then return d end return v end
    return x
end
g_currentMission.animalSystem = { getSubTypeByIndex = function() return { typeIndex = 1, name = "BULL" } end, typeIndexToName = { "COW" } }
g_server = nil
xml = fakeXMLTyped()
DewarData.saveToXMLFile(mkVehicle("D1", c), xml, "v")
local loaded = mkVehicle("D1", nil)
DewarData.loadDewarFromSavegame(loaded, xml, "v")
check("dewar savegame: batch reloads", loaded[DewarData.SPEC_TABLE_NAME].animal.batchId == c.batchId
    and loaded[DewarData.SPEC_TABLE_NAME].animal.batchSource == "COLLECTED")
xml = fakeXMLTyped()
DewarData.saveToXMLFile(mkVehicle("D9", sire({ collected = true })), xml, "v")
local legacy = mkVehicle("D9", nil)
DewarData.loadDewarFromSavegame(legacy, xml, "v")
check("dewar savegame: an old dewar gets its own legacy batch", legacy[DewarData.SPEC_TABLE_NAME].animal.batchId == "L-D9")
local bought = mkVehicle("D5", nil)
DewarData.setAnimal(bought, { birthday = { country = 6 }, farmId = "5", uniqueId = "DB1", animalTypeIndex = 1, subTypeIndex = 1,
    genetics = { fertility = 1 }, success = 0.6, fatherId = "DE 1 2", getName = function() return "Dealer" end })
local ba = bought[DewarData.SPEC_TABLE_NAME].animal
check("dewar: a purchase is this month's purchased batch", ba.batchId == "P-6-5-DB1-" .. MONTH and ba.batchSource == "PURCHASED"
    and ba.sireFatherId == "DE 1 2")
local raw = mkVehicle("D6", nil)
DewarData.setAnimal(raw, sire())
check("dewar: raw old data set on a dewar gets the dewar's legacy id", raw[DewarData.SPEC_TABLE_NAME].animal.batchId == "L-D6")

-- Hand-tool straw: back to its own dewar or another of its batch, never into another batch
loadMod("scripts/insemination/RLStrawReturn.lua")
loadMod("scripts/handTools/specializations/HandToolAIStraw.lua")
local function straw(fromDewar, snapshot, owner)
    local t = { ["spec_FS25_RealisticLivestockRM.aiStraw"] = { dewarUniqueId = fromDewar, animal = snapshot } }
    function t:getOwnerFarmId() return owner or 1 end
    return t
end
local st = straw("D-A", c)
check("straw: own dewar", HandToolAIStraw.getBelongsToDewar(st, dewar("D-A", c)))
check("straw: another dewar of the same batch", HandToolAIStraw.getBelongsToDewar(st, sameBatch))
check("straw: not another batch of the same sire", not HandToolAIStraw.getBelongsToDewar(st, otherBatch))
check("straw: not another farm's dewar of the batch", not HandToolAIStraw.getBelongsToDewar(st, dewar("D-X", c, 2)))
check("straw: a legacy straw only into its own dewar", not HandToolAIStraw.getBelongsToDewar(straw("D-L", sire()), dewar("D-M", sire())))

-- The reason a straw is refused, as its prompt shows it
local RR = RLStrawReturn.REFUSAL
local why = HandToolAIStraw.getReturnRefusal
check("refusal: another batch of the same sire", why(st, otherBatch) == RR.OTHER_BATCH)
check("refusal: own dewar sold to another farm", why(st, dewar("D-A", c, 2)) == RR.OTHER_FARM)
local full = dewar("D-A", c)
full.straws = 1000
check("refusal: a full dewar", why(st, full) == RR.FULL)
local usedStraw = straw("D-A", c)
usedStraw["spec_FS25_RealisticLivestockRM.aiStraw"].isEmpty = true
check("refusal: a used straw", why(usedStraw, dewar("D-A", c)) == RR.USED)
local waiting = straw("D-A", c)
waiting["spec_FS25_RealisticLivestockRM.aiStraw"].awaitingServer = true
check("refusal: a straw waiting for the server", why(waiting, dewar("D-A", c)) == RR.PENDING)
local gone = dewar("D-A", c)
gone.isDeleted = true
check("refusal: a deleted dewar", why(st, gone) == RR.MISSING)
local emptyOwn = dewar("D-A", c)
emptyOwn.straws = 0
check("refusal: none for its own empty dewar", why(st, emptyOwn) == nil)
for code, key in pairs(RLStrawReturn.TEXT) do
    check("refusal text: " .. code .. " has a key", RR[code] ~= nil and type(key) == "string")
end

-- A dewar's collision node, or a child below it, finds the dewar; other objects find none
local dewarObject = dewar("D-A", c)
local objects = { [10] = dewarObject, [30] = { isDewar = false } }
local parents = { [11] = 10, [12] = 11, [31] = 30 }
local function obj(n) return objects[n] end
local function parentOf(n) return parents[n] or 0 end
check("target: the dewar's own node", RLStrawReturn.findDewar(10, obj, parentOf) == dewarObject)
check("target: a collision child two levels down", RLStrawReturn.findDewar(12, obj, parentOf) == dewarObject)
check("target: a tractor is no dewar", RLStrawReturn.findDewar(31, obj, parentOf) == nil)
check("target: nothing hit", RLStrawReturn.findDewar(0, obj, parentOf) == nil and RLStrawReturn.findDewar(99, obj, parentOf) == nil)

-- Display
local lines = B.getInfoLines(c)
check("info: batch, source and month", #lines == 3 and lines[1][2] == c.batchId and lines[2][2] == "rl_semen_sourceCOLLECTED"
    and lines[3][2] == "P5 3")
check("info: legacy batch shows no month", #B.getInfoLines(old) == 2)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end

-- The straw's targeter sees vehicles: a dewar is a pallet whose collision is in the VEHICLE group
do
    local f = io.open(REPO .. "scripts/handTools/specializations/HandToolAIStraw.lua", "r")
    local source = f:read("a")
    f:close()
    check("target: the straw targets VEHICLE collisions", source:find("CollisionFlag%.VEHICLE") ~= nil)
    local i3d = io.open(REPO .. "objects/dewar/dewar.i3d", "r")
    local group = i3d:read("a"):match('collisionFilterGroup="0x(%x+)"')
    i3d:close()
    check("target: the dewar's collision group is VEHICLE (bit 16)", group ~= nil and (tonumber(group, 16) >> 16) & 1 == 1)
    local xml = io.open(REPO .. "objects/straw/straw.xml", "r")
    check("name: the straw's type text is a translation key", xml:read("a"):find("<typeDesc>%$l10n_rl_ui_aiStraw</typeDesc>") ~= nil)
    xml:close()
end
