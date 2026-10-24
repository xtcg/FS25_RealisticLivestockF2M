-- ID-COLLISION-01: a full key (farmId, uniqueId, country) has no species and the old counters are
-- per species, so in the joint test (batch E) three newborn lambs got the exact keys of three pigs of
-- the same herd (6/916632/110002, 210003, 710001). Every allocation on the server now skips a key known
-- to be taken (live at load, named as a parent, handed out since) whatever the ledger mode, and the
-- load repair renumbers the duplicates an old save holds, following parent references only when they
-- resolve to one animal.
local f = assert(io.open(REPO .. "scripts/utils/RLAnimalUtil.lua", "r")); local src = f:read("*a"); f:close()
assert(load((src:gsub("::number", "")), "RLAnimalUtil"))()
loadMod("scripts/core/RLConstants.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/animal/RLAnimalIdentityPersistence.lua")
loadMod("scripts/animal/RLAnimalIdentityRuntime.lua")
-- This unit fixture omits engine storage; checkpoint tests exercise the real barrier.
RLAnimalIdentityRuntime.journalBarrier = function() return true end
loadMod("scripts/animal/RLAnimalIdentityWorld.lua")
loadMod("scripts/animal/RLAnimalIdentityRepair.lua")
local I, R, W, U, Repair = RLAnimalIdentity, RLAnimalIdentityRuntime, RLAnimalIdentityWorld, RLAnimalUtil, RLAnimalIdentityRepair
AnimalType = { COW = 1, PIG = 2, SHEEP = 3, HORSE = 4, CHICKEN = 5 }
local DE = 6
local HERD = 916632

local function slice(path, from, to)
    local h = assert(io.open(REPO .. path, "r")); local text = h:read("*a"); h:close()
    local a = assert(text:find(from, 1, true), from)
    local b = assert(text:find(to, a, true), to)
    return text:sub(a, b - 1)
end
local function compile(code, name) return assert(load((code:gsub("::number", "")), name)) end

-- The real FarmStats counter, Animal:setUniqueId and AnimalSystem:getNextAnimalIdForFarm.
Animal = {}
compile(slice("scripts/animal/RealisticLivestock_Animal.lua", "function Animal:setUniqueId(farmId)", "-- Delegate (backward"), "setUniqueId")()
RealisticLivestock = { getMapCountryIndex = function() return DE end }
RealisticLivestock_FarmStats = {}
compile(slice("scripts/farms/RealisticLivestock_FarmStats.lua", "function RealisticLivestock_FarmStats:getNextAnimalId", "FarmStats.getNextAnimalId ="), "getNext")()
AnimalSystem = {}
compile(slice("scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua", "function AnimalSystem:getNextAnimalIdForFarm", "function AnimalSystem:removeSaleAnimal"), "getNextForFarm")()

local subTypes = { [1] = { typeIndex = AnimalType.COW }, [2] = { typeIndex = AnimalType.PIG }, [3] = { typeIndex = AnimalType.SHEEP } }

local function world()
    local farm = { stats = { statistics = { farmId = HERD, cowId = 0, pigId = 0, sheepId = 0, horseId = 0, chickenId = 0 } } }
    farm.stats.getNextAnimalId = RealisticLivestock_FarmStats.getNextAnimalId
    g_farmManager = { farmIdToFarm = { [1] = farm } }
    local sys = { countries = { [DE] = { index = DE, farms = { { id = 404734, ids = { [AnimalType.COW] = 0, [AnimalType.PIG] = 0, [AnimalType.SHEEP] = 0 } } } } },
        animals = {}, aiAnimals = {} }
    function sys:getSubTypeByIndex(i) return subTypes[i] end
    function sys:getTypeByIndex(i) return { name = "T" .. tostring(i) } end
    sys.getNextAnimalIdForFarm = AnimalSystem.getNextAnimalIdForFarm
    local mission = { animalSystem = sys, placeableSystem = { placeables = {} }, vehicleSystem = { vehicles = {} } }
    g_currentMission = mission
    return mission, farm, sys
end

local function animal(typeIndex, raw, fields)
    local a = { animalTypeIndex = typeIndex, subTypeIndex = typeIndex, farmId = tostring(HERD), uniqueId = U.generateUniqueId(HERD, raw),
        birthday = { day = 1, month = 3, year = 1, country = DE }, age = 1, gender = "female", children = {}, weight = 100,
        motherId = "-1", fatherId = "-1", isIndividual = true }
    for k, v in pairs(fields or {}) do a[k] = v end
    return setmetatable(a, { __index = Animal })
end
local function ident(a) return Repair.identifiers(a.birthday.country, a.farmId, a.uniqueId) end
local function key(a) return I.keyString(a.farmId, a.uniqueId, a.birthday.country) end
local function pen(mission, animals)
    local cs = { animals = animals, owner = { ownerFarmId = 1 } }
    for _, a in ipairs(animals) do a.clusterSystem = cs end
    table.insert(mission.placeableSystem.placeables, { spec_husbandryAnimals = { clusterSystem = cs } })
    return cs
end
local function ready(mode, mission)
    R.reset(true)
    R.lineage = "Ltest-ic"
    R.setLoaded(nil, "READY", "TEST")
    R.mode = mode
    local scan = W.scan(mission)
    R.setLive(scan.records, scan.refs)
end

-- ---- the batch E case: three pigs 1..3 live, the first lambs of the herd ------------------------
for _, mode in ipairs({ R.SHADOW, R.OFF }) do
    local mission, farm = world()
    local pigs = { animal(AnimalType.PIG, 1, { age = 9 }), animal(AnimalType.PIG, 2, { age = 9 }), animal(AnimalType.PIG, 3, { age = 9 }) }
    farm.stats.statistics.pigId = 3
    pen(mission, pigs)
    ready(mode, mission)
    local cs = { owner = { ownerFarmId = 1 } }
    local lambs = {}
    for i = 1, 3 do
        local lamb = setmetatable({ clusterSystem = cs, subTypeIndex = AnimalType.SHEEP, animalTypeIndex = AnimalType.SHEEP, birthday = { country = DE } }, { __index = Animal })
        lamb:setUniqueId()
        lambs[i] = lamb
    end
    local clash = false
    for _, l in ipairs(lambs) do for _, p in ipairs(pigs) do if key(l) == key(p) then clash = true end end end
    check(string.format("%s: three lambs born in a herd whose pigs 1..3 live get none of their keys (%s, %s, %s)", mode,
        lambs[1].uniqueId, lambs[2].uniqueId, lambs[3].uniqueId), not clash and lambs[1].uniqueId == U.generateUniqueId(HERD, 4)
        and lambs[3].uniqueId == U.generateUniqueId(HERD, 6) and farm.stats.statistics.sheepId == 6 and farm.stats.statistics.pigId == 3)
    if mode == R.SHADOW then
        check("SHADOW: the taken keys passed are still counted and logged", R.shadow.collisions == 1 and R.shadow.observed == 3)
    end
    local pig = setmetatable({ clusterSystem = cs, subTypeIndex = AnimalType.PIG, animalTypeIndex = AnimalType.PIG, birthday = { country = DE } }, { __index = Animal })
    pig:setUniqueId()
    check(mode .. ": the next piglet does not take a lamb's key either (pig counter 3 -> 7)", pig.uniqueId == U.generateUniqueId(HERD, 7))
end

-- the client never numbers through the runtime
do
    local mission, farm = world()
    pen(mission, { animal(AnimalType.PIG, 1) })
    farm.stats.statistics.pigId = 1
    R.reset(false)
    check("client: the old counter as it is", W.nextStatsRaw("t", farm, AnimalType.SHEEP, DE, "auto") == 1)
end

-- padded ids alias: raw 10001 is raw 1's padded id
do
    local mission, farm = world()
    pen(mission, { animal(AnimalType.COW, 1) })
    farm.stats.statistics.cowId = 10000
    ready(R.SHADOW, mission)
    check("raw 10001 (alias of the live raw 1) is passed: 10002", W.nextStatsRaw("t", farm, AnimalType.COW, DE, "auto") == 10002)
end

-- a parent named by a live animal is taken even when it is gone
do
    local mission, farm = world()
    local goneMother = U.generateUniqueId(HERD, 1)
    pen(mission, { animal(AnimalType.SHEEP, 2, { motherId = "DE " .. HERD .. " " .. goneMother }) })
    farm.stats.statistics.sheepId = 2
    ready(R.SHADOW, mission)
    check("a dead dam's key a lamb still names is not handed to a new pig", W.nextStatsRaw("t", farm, AnimalType.PIG, DE, "auto") == 3)
end

-- a sale farm numbers per type too: a cow listing does not take a pig listing's key
do
    local mission, _, sys = world()
    local sf = sys.countries[DE].farms[1]
    sf.ids[AnimalType.PIG] = 5
    for raw = 1, 5 do
        local p = animal(AnimalType.PIG, raw); p.farmId = "404734"; p.uniqueId = U.generateUniqueId(404734, raw)
        sys.animals[AnimalType.PIG] = sys.animals[AnimalType.PIG] or {}
        table.insert(sys.animals[AnimalType.PIG], p)
    end
    ready(R.SHADOW, mission)
    local raw = sys:getNextAnimalIdForFarm(DE, AnimalType.COW, 404734)
    check("sale farm: the first cow listing passes the five pig listings' keys (6)", raw == 6 and sf.ids[AnimalType.COW] == 6)
end

-- ON: the ledger vetoes a live key it does not hold (one the load repair or the old counter gave)
do
    local mission, farm = world()
    pen(mission, {})
    ready(R.SHADOW, mission)
    assert(R.activate({ records = {}, counters = {} }, { accept = true }))
    R.setLive({ { farmId = tostring(HERD), uniqueId = U.generateUniqueId(HERD, 1), country = DE, type = "3" } })
    local onRaw, onWhy = W.nextStatsRaw("t", farm, AnimalType.PIG, DE, "auto")
    check("ON: the ledger passes a live key it never handed out (" .. tostring(onRaw or onWhy) .. ")", onRaw == 2)
end

-- ---- the load repair ----------------------------------------------------------------------------
local function snapshot(mission)
    local out = { n = 0, weight = 0, byType = {} }
    for _, e in ipairs((Repair.collect(mission))) do
        out.n = out.n + 1
        out.weight = out.weight + e.animal.weight
        out.byType[e.animal.animalTypeIndex] = (out.byType[e.animal.animalTypeIndex] or 0) + 1
    end
    return out
end

do
    local mission, farm = world()
    farm.stats.statistics.pigId, farm.stats.statistics.sheepId = 3, 3
    local sow = "DE 404734 " .. U.generateUniqueId(404734, 435)
    local pigs = {}
    for raw = 1, 3 do pigs[raw] = animal(AnimalType.PIG, raw, { age = 9, motherId = sow, gender = raw == 3 and "female" or "male", weight = 270 }) end
    local ewe = animal(AnimalType.SHEEP, 11, { age = 30, weight = 80 })
    local ram = animal(AnimalType.SHEEP, 219, { age = 20, gender = "male", weight = 110 })
    local lambs = {}
    for raw = 1, 3 do
        lambs[raw] = animal(AnimalType.SHEEP, raw, { age = 1, motherId = ident(ewe), fatherId = ident(ram), gender = raw == 3 and "female" or "male", weight = 15 })
        ewe.children[#ewe.children + 1] = { farmId = lambs[raw].farmId, uniqueId = lambs[raw].uniqueId }
        ram.children[#ram.children + 1] = { farmId = lambs[raw].farmId, uniqueId = lambs[raw].uniqueId }
    end
    -- lamb 3 (a ewe lamb) is already the dam of an unborn and of a lamb in another pen; a gilt (pig 3)
    -- shares her key - the references are the sheep's by species.
    lambs[3].pregnancy = { pregnancies = { { animalTypeIndex = AnimalType.SHEEP, subTypeIndex = AnimalType.SHEEP, motherId = ident(lambs[3]), fatherId = ident(ram) } } }
    local grandLamb = animal(AnimalType.SHEEP, 40, { age = 0, motherId = ident(lambs[3]), weight = 5 })
    lambs[3].children = { { farmId = grandLamb.farmId, uniqueId = grandLamb.uniqueId } }
    -- a piglet naming the gilt (pig 3) as its dam stays hers
    local piglet = animal(AnimalType.PIG, 50, { age = 0, motherId = ident(pigs[3]), weight = 2 })
    -- a sow mated by boar 1 (pig 1): its sire stays the boar, never lamb 1
    local mated = animal(AnimalType.PIG, 60, { age = 20, impregnatedBy = { uniqueId = ident(pigs[1]) } })
    pen(mission, { pigs[1], pigs[2], pigs[3], piglet, mated })
    pen(mission, { ewe, ram, lambs[1], lambs[2], lambs[3] })
    pen(mission, { grandLamb })
    local oldKeys = { key(lambs[1]), key(lambs[2]), key(lambs[3]) }
    local oldPig = { key(pigs[1]), key(pigs[2]), key(pigs[3]) }
    local before = snapshot(mission)
    R.reset(true)
    local s = Repair.run(mission)
    local after = snapshot(mission)

    check(string.format("repair: 3 groups, the 3 lambs renumbered (%s, %s, %s), the older pigs keep theirs", lambs[1].uniqueId, lambs[2].uniqueId,
        lambs[3].uniqueId), s.groups == 3 and s.renumbered == 3 and key(pigs[1]) == oldPig[1] and key(pigs[3]) == oldPig[3]
        and key(lambs[1]) ~= oldKeys[1] and key(lambs[3]) ~= oldKeys[3])
    local seen, unique = {}, true
    for _, e in ipairs((Repair.collect(mission))) do
        if seen[key(e.animal)] then unique = false end
        seen[key(e.animal)] = true
    end
    check("repair: every live key is unique afterwards; the new keys are past every counter of the herd", unique
        and lambs[1].uniqueId == U.generateUniqueId(HERD, 4) and lambs[3].uniqueId == U.generateUniqueId(HERD, 6))
    check("repair: count, weight and species are conserved", after.n == before.n and after.weight == before.weight
        and after.byType[AnimalType.PIG] == before.byType[AnimalType.PIG] and after.byType[AnimalType.SHEEP] == before.byType[AnimalType.SHEEP])
    local eweOk, ramOk = true, true
    for i, child in ipairs(ewe.children) do eweOk = eweOk and child.uniqueId == lambs[i].uniqueId end
    for i, child in ipairs(ram.children) do ramOk = ramOk and child.uniqueId == lambs[i].uniqueId end
    check("repair: the dam's and the sire's children lists follow their lambs", eweOk and ramOk)
    check("repair: the ewe lamb's unborn and her own lamb name her new key; the piglet still names the gilt",
        lambs[3].pregnancy.pregnancies[1].motherId == ident(lambs[3]) and grandLamb.motherId == ident(lambs[3])
        and piglet.motherId == ident(pigs[3]) and pigs[3].uniqueId == U.generateUniqueId(HERD, 3))
    check("repair: the sow's sire stays boar 1, the lambs' parents stay theirs", mated.impregnatedBy.uniqueId == ident(pigs[1])
        and lambs[1].motherId == ident(ewe) and lambs[1].fatherId == ident(ram))
    check("repair: nothing ambiguous here", s.conflicts == 0)
    local again = Repair.run(mission)
    check("repair: a second load finds nothing to do", again.groups == 0 and again.renumbered == 0)
end

-- ambiguous: two ewes of the same herd share one key and a lamb names it as its dam - left, reported
do
    local mission = world()
    local a = animal(AnimalType.SHEEP, 7, { age = 40 })
    local b = animal(AnimalType.SHEEP, 7, { age = 30 })
    local lamb = animal(AnimalType.SHEEP, 8, { age = 0, motherId = ident(a) })
    a.children = { { farmId = lamb.farmId, uniqueId = lamb.uniqueId } }
    b.children = { { farmId = lamb.farmId, uniqueId = lamb.uniqueId } }
    pen(mission, { a, lamb })
    pen(mission, { b })
    local oldA = key(a)
    R.reset(true)
    local s = Repair.run(mission)
    check(string.format("ambiguous dam: the younger ewe is renumbered, the lamb's dam is not guessed (motherId %s), %d conflict(s) reported",
        lamb.motherId, s.conflicts), s.renumbered == 1 and key(a) == oldA and key(b) ~= oldA and lamb.motherId == ident(a) and s.conflicts >= 1)
end

-- an owned animal keeps its key against a sale listing, whatever their ages
do
    local mission, _, sys = world()
    local owned = animal(AnimalType.COW, 5, { age = 2 })
    local listed = animal(AnimalType.SHEEP, 5, { age = 30 })
    sys.animals[AnimalType.SHEEP] = { listed }
    pen(mission, { owned })
    local ownedKey = key(owned)
    R.reset(true)
    local s = Repair.run(mission)
    check("owned before listed: the pen's cow keeps the key, the sale listing is renumbered", s.renumbered == 1 and key(owned) == ownedKey
        and key(listed) ~= ownedKey)
end

-- Both parents and their lamb need new keys: the parent's new identifiers must still
-- resolve when the lamb's children-list entry is repaired, in either group order.
for _, parentFirst in ipairs({ true, false }) do
    local mission, farm = world()
    farm.stats.statistics.pigId, farm.stats.statistics.sheepId = 3, 3
    local dam = animal(AnimalType.SHEEP, 1, { age = 30 })
    local sire = animal(AnimalType.SHEEP, 2, { age = 30, gender = "male" })
    local lamb = animal(AnimalType.SHEEP, 3, { age = 10, motherId = ident(dam), fatherId = ident(sire) })
    dam.children = { { farmId = lamb.farmId, uniqueId = lamb.uniqueId } }
    sire.children = { { farmId = lamb.farmId, uniqueId = lamb.uniqueId } }
    local pigs = {}
    for raw = 1, 3 do pigs[raw] = animal(AnimalType.PIG, raw, { age = 40 }) end
    pen(mission, parentFirst and { pigs[1], pigs[2], pigs[3], dam, sire, lamb }
        or { pigs[3], pigs[2], pigs[1], lamb, sire, dam })
    ready(R.SHADOW, mission)
    local summary = Repair.run(mission)
    local order = parentFirst and "parents first" or "lamb first"
    check("family repair (" .. order .. "): both parent references follow their new keys",
        summary.renumbered == 3 and summary.conflicts == 0 and lamb.motherId == ident(dam) and lamb.fatherId == ident(sire))
    check("family repair (" .. order .. "): both parents list the lamb's new key",
        dam.children[1].uniqueId == lamb.uniqueId and sire.children[1].uniqueId == lamb.uniqueId)
    local again = Repair.run(mission)
    check("family repair (" .. order .. "): a repeat leaves the family consistent",
        again.renumbered == 0 and lamb.motherId == ident(dam) and lamb.fatherId == ident(sire)
        and dam.children[1].uniqueId == lamb.uniqueId and sire.children[1].uniqueId == lamb.uniqueId)
end
