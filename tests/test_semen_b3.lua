-- Semen B3: pedigree inbreeding bands, AI compatibility groups, deterministic batch quality and the
-- one-roll conception chance the AI dialog shows.

RLConstants = { AREA_CODES = { [1] = { code = "DE" }, [2] = { code = "UK" } } }
g_i18n = { getText = function(_, key) return "[" .. key .. "]%s" end }
RLMapBridge = { groups = {} }
function RLMapBridge.isBreedingCompatible(male, female)
    local mg, fg = RLMapBridge.groups[male], RLMapBridge.groups[female]
    if mg == nil and fg == nil then return nil end
    return mg == fg
end

local P = RLPedigree
local L = P.LEVEL

-- A family tree by name; ids are "DE 1 <name>".
local function id(name) return "DE 1 " .. name end
local function family(rows)
    P.reset()
    for child, parents in pairs(rows) do P.register(id(child), parents[1] and id(parents[1]), parents[2] and id(parents[2])) end
end
local function F(a, b) return P.getOffspringInbreeding(id(a), id(b)) end

-- Two founders (S, D) and their descendants, so each relationship of the table has one pair.
--   S x D -> A, B (full sibs); S x E -> C (half sib of A)
--   A x X -> A1; B x Y -> B1 (first cousins A1, B1)
--   A1 x X2 -> A2; B1 x Y2 -> B2 (second cousins)
--   A2 x X3 -> A3; B2 x Y3 -> B3 (third cousins); A3 x X4 -> A4; B3 x Y4 -> B4 (fourth cousins)
family({
    A = { "S", "D" }, B = { "S", "D" }, C = { "S", "E" },
    A1 = { "X", "A" }, B1 = { "B", "Y" },
    A2 = { "A1", "X2" }, B2 = { "Y2", "B1" },
    A3 = { "X3", "A2" }, B3 = { "B2", "Y3" },
    A4 = { "A3", "X4" }, B4 = { "Y4", "B3" },
    HC = { "C", "Q" },  -- A1 and HC are half first cousins
})

check("father x daughter 25%", F("S", "A") == 0.25)
check("mother x son 25%", F("A", "D") == 0.25)
check("full sibs 25%", F("A", "B") == 0.25)
check("half sibs 12.5%", F("A", "C") == 0.125)
check("grandfather x granddaughter 12.5%", F("S", "A1") == 0.125)
check("first cousins 6.25%", F("A1", "B1") == 0.0625)
check("half first cousins 3.125%", F("A1", "HC") == 0.03125)
check("second cousins 1.5625%", F("A2", "B2") == 0.015625)
check("third cousins 0.39%", F("A3", "B3") == 0.00390625)
check("fourth cousins 0.098%", F("A4", "B4") == 0.0009765625)
check("unrelated 0", F("X", "Y") == 0 and F("A4", "Q") == 0)
check("unknown or self 0", P.getOffspringInbreeding(nil, id("A")) == 0 and P.getOffspringInbreeding("-1", id("A")) == 0
    and F("A", "A") == 0)
check("symmetric", F("B2", "A2") == F("A2", "B2") and F("B1", "A1") == 0.0625)

check("bands: first cousins and closer are forbidden",
    P.getLevel(F("S", "A")) == L.FORBIDDEN and P.getLevel(F("A", "C")) == L.FORBIDDEN
    and P.getLevel(F("S", "A1")) == L.FORBIDDEN and P.getLevel(F("A1", "B1")) == L.FORBIDDEN)
check("bands: second cousins (and half first cousins) advised against",
    P.getLevel(F("A2", "B2")) == L.ADVISE_AGAINST and P.getLevel(F("A1", "HC")) == L.ADVISE_AGAINST)
check("bands: third and fourth cousins shown without advice",
    P.getLevel(F("A3", "B3")) == L.INFO and P.getLevel(F("A4", "B4")) == L.INFO)
check("bands: unrelated none", P.getLevel(0) == L.NONE)

-- Inbred common ancestor: the offspring of full sibs (A x B -> I) mated to a full sib J of I
family({ A = { "S", "D" }, B = { "S", "D" }, I = { "A", "B" }, J = { "A", "B" } })
check("inbred parents' kinship counts their own inbreeding (Wright 1+F_A)", near(F("I", "J"), 0.375, 1e-12))

-- The walk stops MAX_GENERATIONS above each parent: 6th cousins (common ancestor 7 up) read 0.
do
    local rows, left, right = { L1 = { "R", "D0" }, R1 = { "R", "D1" } }, "L1", "R1"
    for g = 2, 7 do
        rows["L" .. g] = { left, "XL" .. g }; rows["R" .. g] = { right, "XR" .. g }
        left, right = "L" .. g, "R" .. g
    end
    family(rows)
    check("5th cousins still found (common ancestor 6 up)", F("L6", "R6") > 0)
    check("6th cousins beyond the walk read 0", F("L7", "R7") == 0)
end

-- Register: unknown parents never overwrite known; animals with no known parent are not stored.
P.reset()
P.register(id("K"), id("S"), "-1")
P.register(id("K"), "-1", id("D"))
local f1, m1 = P.getParents(id("K"))
check("register merges known parents", f1 == id("S") and m1 == id("D"))
P.register(id("Z"), "-1", "")
check("founder not stored", P.entries[id("Z")] == nil)
P.register(id("K"), id("K"), nil)
check("self-parent ignored", (P.getParents(id("K"))) == id("S"))

-- Animals and semen records
local function mkAnimal(uniqueId, fatherId, motherId, extra)
    local a = { uniqueId = uniqueId, farmId = "1", birthday = { country = 1 }, fatherId = fatherId or "-1",
        motherId = motherId or "-1", gender = "female", animalTypeIndex = 1, subTypeIndex = 2, subType = "COW_ANGUS",
        age = 30, genetics = { fertility = 1, metabolism = 1, quality = 1, health = 1 }, monthsSinceLastBirth = 10 }
    for k, v in pairs(extra or {}) do a[k] = v end
    function a:getIdentifiers() return string.format("%s %s %s", RLConstants.AREA_CODES[self.birthday.country].code, self.farmId, self.uniqueId) end
    function a:getSubType() return { reproductionMinAgeMonth = 12 } end
    function a:getDiseaseMultipliers() return nil end
    return a
end

P.reset()
-- A collected batch from bull "SIRE" (father "GS", mother "GD") whose registry entry was pruned:
-- the batch's own parent fields still find that he is the dam's half brother.
local straw = { country = 1, farmId = "1", uniqueId = "SIRE", typeIndex = 1, subTypeIndex = 1, success = 0.5,
    sireFatherId = id("GS"), sireMotherId = id("GD") }
local dam = mkAnimal("HEIFER", id("GS"), id("OTHER"))
local f, level = P.checkMating(dam, straw)
check("straw parents from the batch: half sibs forbidden", f == 0.125 and level == L.FORBIDDEN)
check("checkMating records the dam", (P.getParents(id("HEIFER"))) == id("GS"))
check("text names the band and the coefficient", P.getText(f, level) == "[rl_pedigree_forbidden]12.5%"
    and P.getText(0.015625, L.ADVISE_AGAINST) == "[rl_pedigree_adviseAgainst]1.56%"
    and P.getText(0.00390625, L.INFO) == "[rl_pedigree_info]0.391%" and P.getText(0, L.NONE) == nil)

-- Cache: a later registration that makes them related is seen
P.reset()
local bull = mkAnimal("B", nil, nil, { gender = "male" })
local cow = mkAnimal("C")
check("unrelated before", (P.checkMating(cow, bull)) == 0)
P.register(id("C"), id("B"), nil)
check("cache dropped on a new entry: father x daughter now 25%", (P.checkMating(cow, bull)) == 0.25)

-- Prune keeps MAX_GENERATIONS + 1 generations above the anchors and drops the rest
do
    local rows, child = {}, "G0"
    for g = 1, 9 do rows["G" .. (g - 1)] = { "G" .. g, "M" .. g } end
    rows.STRAY = { "SP", "SM" }
    family(rows)
    local removed = P.prune({ id("G0") })
    check("prune drops unreachable entries", P.entries[id("STRAY")] == nil)
    check("prune keeps MAX_GENERATIONS + 1 generations of ancestry", P.entries[id("G7")] ~= nil and P.entries[id("G8")] == nil
        and removed == 2)
end

-- XML and stream round trips
do
    family({ A = { "S", "D" }, B = { "S", nil } })
    local store = {}
    local xml = {
        setString = function(_, k, v) store[k] = v end,
        getString = function(_, k) return store[k] end,
        iterate = function(_, key, fn)
            local i = 0
            while store[string.format("%s(%d)#id", key, i)] ~= nil do fn(i, string.format("%s(%d)", key, i)); i = i + 1 end
        end,
    }
    g_currentMission = nil
    g_dewarManager = nil
    local stream = {}
    streamWriteInt32 = function(_, v) stream[#stream + 1] = v end
    streamWriteString = function(_, v) stream[#stream + 1] = v end
    local pos = 0
    streamReadInt32 = function() pos = pos + 1; return stream[pos] end
    streamReadString = function() pos = pos + 1; return stream[pos] end
    P.writeStream(1)
    P.reset()
    P.readStream(1)
    check("stream round trip", F("A", "B") == 0.125 and (select(2, P.getParents(id("B")))) == nil)

    -- The save prunes against live anchors; with none (no mission) it would drop everything.
    P.reset()
    P.register(id("A"), id("S"), id("D"))
    P.prune = function() return 0 end
    P.saveToXMLFile(xml, "rm.pedigree")
    P.reset()
    P.loadFromXMLFile(xml, "rm.pedigree")
    check("xml round trip", (P.getParents(id("A"))) == id("S") and select(2, P.getParents(id("A"))) == id("D"))
    loadMod("scripts/animal/RLPedigree.lua")
    P = RLPedigree
end

-- AnimalReproduction: compatibility, the refusal, the chance
local fh = assert(io.open(REPO .. "scripts/animal/AnimalReproduction.lua", "r"))
local source = fh:read("*a")
fh:close()
assert(load(source:gsub("%f[%a]continue%f[%A]", "break"), "AnimalReproduction"))()
local R = AnimalReproduction

check("goat ram cannot sire a ewe", not R.isSubTypeCompatible("RAM_GOAT", "SHEEP_TEXEL"))
check("sheep ram cannot sire a goat", not R.isSubTypeCompatible("RAM_TEXEL", "GOAT"))
check("goat x goat", R.isSubTypeCompatible("RAM_GOAT", "GOAT"))
check("buffalo only with buffalo", not R.isSubTypeCompatible("BULL_ANGUS", "COW_WATERBUFFALO")
    and not R.isSubTypeCompatible("BULL_WATERBUFFALO", "COW_HOLSTEIN") and R.isSubTypeCompatible("BULL_WATERBUFFALO", "COW_WATERBUFFALO"))
check("cross-breeding within a species allowed", R.isSubTypeCompatible("BULL_ANGUS", "COW_HOLSTEIN")
    and R.isSubTypeCompatible("RAM_SUFFOLK", "SHEEP_TEXEL"))
RLMapBridge.groups = { BULL_HIGHLAND = "HIGHLAND", COW_HIGHLAND = "HIGHLAND" }
check("map breeding group only within the group", not R.isSubTypeCompatible("BULL_ANGUS", "COW_HIGHLAND")
    and R.isSubTypeCompatible("BULL_HIGHLAND", "COW_HIGHLAND"))
RLMapBridge.groups = {}
check("unknown names do not block", R.isSubTypeCompatible(nil, "GOAT"))

local SUBS = { [1] = { name = "BULL_ANGUS" }, [2] = { name = "COW_ANGUS" }, [3] = { name = "RAM_GOAT" } }
local typeFertility = 80
g_currentMission = { animalSystem = {
    getSubTypeByIndex = function(_, i) return SUBS[i] end,
    getTypeByIndex = function() return { fertility = { get = function() return typeFertility end },
        pregnancy = { average = 1, get = function() return 2 end } } end,
} }

P.reset()
local ewe = mkAnimal("EWE", nil, nil, { animalTypeIndex = 3, subType = "SHEEP_TEXEL" })
local goatStraw = { country = 1, farmId = "1", uniqueId = "G", typeIndex = 3, subTypeIndex = 3, success = 0.5 }
local ok, reason = R.getCanBeInseminatedByAnimal(ewe, goatStraw)
check("AI: goat straw refused for a ewe", ok == false and reason == "[rl_insemination_incompatible]%s")

local cowStraw = { country = 1, farmId = "1", uniqueId = "SIRE", typeIndex = 1, subTypeIndex = 1, success = 0.5 }
local heifer = mkAnimal("H")
check("AI: unrelated allowed", R.getCanBeInseminatedByAnimal(heifer, cowStraw) == true)
local daughter = mkAnimal("DAU", id("SIRE"))
local okF, reasonF = R.getCanBeInseminatedByAnimal(daughter, cowStraw)
check("AI: own father still refused by the old rule", okF == false and reasonF == "[rl_insemination_father]%s")

family({ SIRE = { "P1", "Q1" }, CZ = { "P2", "Q2" }, P1 = { "GG", "M1" }, P2 = { "GG", "M2" } })
local cousin = mkAnimal("CZ", id("P2"), id("Q2"))
local okC, reasonC = R.getCanBeInseminatedByAnimal(cousin, cowStraw)
check("AI: half first cousin (3.125%) allowed, advised against", okC == true and reasonC == nil
    and select(2, P.checkMating(cousin, cowStraw)) == L.ADVISE_AGAINST)
family({ SIRE = { "P1", "Q1" }, CZ = { "P2", "Q2" }, P1 = { "GG", "GM" }, P2 = { "GG", "GM" } })
local okC2, reasonC2 = R.getCanBeInseminatedByAnimal(cousin, cowStraw)
check("AI: first cousin refused with the coefficient", okC2 == false and reasonC2 == "[rl_pedigree_forbidden]6.25%")

-- Chance = dam fertility (gene x age curve) x conception x batch quality
heifer.genetics.fertility = 1
typeFertility = 80
local chance, parts = R.getInseminationChance(heifer, { success = 0.5 })
check("chance parts: fertility 0.8, conception 0.75, quality 0.5", near(parts.fertility, 0.8, 1e-9)
    and near(parts.conception, 0.75, 1e-9) and parts.quality == 0.5)
check("chance is their product", near(chance, 0.3, 1e-9))
heifer.genetics.fertility = 1.5
typeFertility = 100
local chance2, parts2 = R.getInseminationChance(heifer, { success = 0.8 })
check("chance clamps the dam's fertility at 1", parts2.fertility == 1 and near(parts2.conception, 0.875, 1e-9)
    and near(chance2, 0.7, 1e-9))
heifer.genetics.fertility = 1

-- resolveInsemination: one roll against the chance, the litter drawn only on success
do
    local start = assert(source:find("local function resolveInsemination", 1, true))
    local finish = assert(source:find("--- Advance pregnancy or attempt natural conception.", start, true))
    local resolve = assert(load("local AnimalReproduction, RLConstants = ...\n" .. source:sub(start, finish - 1)
        .. "\nreturn resolveInsemination"))(R, RLConstants)
    AnimalInseminationResultEvent = { new = function(_, _, success) return success end }
    local broadcast = {}
    g_server = { broadcastEvent = function(_, e) broadcast[#broadcast + 1] = e end }
    local function run(roll)
        local cow2 = mkAnimal("R")
        local created
        cow2.clusterSystem = { owner = {} }
        cow2.addMessage = function(self, m) self.message = m end
        cow2.createPregnancy = function(_, n, _, _, father) created = { n = n, father = father } end
        cow2.insemination = { country = 1, farmId = "1", uniqueId = "SIRE", subTypeIndex = 1, success = 0.5,
            genetics = { metabolism = 1, quality = 1, health = 1, fertility = 1 } }
        local rolls = { roll, 0.9 }
        local oldRandom = math.random
        math.random = function(...) if select("#", ...) > 0 then return oldRandom(...) end return table.remove(rolls, 1) end
        typeFertility = 80
        resolve(cow2, 1, 1)
        math.random = oldRandom
        return cow2, created
    end
    local cowA, createdA = run(0.29)
    check("roll under the 30% chance conceives", cowA.message == "INSEMINATION_SUCCESS" and createdA ~= nil
        and createdA.n == 1 and createdA.father.uniqueId == "DE 1 SIRE" and cowA.insemination == nil)
    local cowB, createdB = run(0.31)
    check("roll over the 30% chance fails", cowB.message == "INSEMINATION_FAIL" and createdB == nil and cowB.insemination == nil)
end

-- Batch quality: the mean of the old roll, no random
loadMod("scripts/insemination/RLSemenBatch.lua")
loadMod("scripts/insemination/RLSemenCollection.lua")
local Q = RLSemenCollection.getBatchQuality
local function oldMean(fert)
    local s = 0
    for k = 35, 50 do s = s + math.clamp(k * fert / 100, 0.5, 1) end
    return s / 16
end
check("average sire: 50%", Q(1) == 0.5 and Q(nil) == 0.5)
check("quality is the old roll's mean", near(Q(1.3), oldMean(1.3), 1e-12) and near(Q(1.8), oldMean(1.8), 1e-12))
check("quality rises with fertility, capped at 1", Q(1.2) > Q(1.1) and Q(1.6) > Q(1.3) and Q(3) == 1)
local q1, q2 = Q(1.4), Q(1.4)
check("same sire, same quality every batch", q1 == q2)

local function sourceOf(path)
    local h = assert(io.open(REPO .. path, "r"))
    local t = h:read("*a")
    h:close()
    return t
end
check("no roll left in collection or the AI dealer", not sourceOf("scripts/insemination/RLSemenCollection.lua"):find("math.random", 1, true)
    and sourceOf("scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua"):find("RLSemenCollection.getBatchQuality(genetics.fertility)", 1, true) ~= nil)
check("no 80-120% second roll in the insemination", not source:find("math.random(80, 120)", 1, true))
check("natural mating skips forbidden relatives", sourceOf("scripts/core/RealisticLivestock.lua"):find("RLPedigree.LEVEL.FORBIDDEN", 1, true) ~= nil
    and source:find("RLPedigree.checkMating(animal, otherAnimal)", 1, true) ~= nil)
check("registry saved, loaded and pushed on join",
    sourceOf("scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua"):find('RLPedigree.saveToXMLFile(xmlFile, "rm_RlAnimalSystem.pedigree")', 1, true) ~= nil
    and sourceOf("scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua"):find('RLPedigree.loadFromXMLFile(xmlFile, rootKey .. ".pedigree")', 1, true) ~= nil
    and sourceOf("scripts/core/RealisticLivestock_FSBaseMission.lua"):find("RLPedigreeStateEvent.new()", 1, true) ~= nil)

-- Saving keeps the ancestors of every semen record still in the game: a dewar in object storage,
-- a hand-tool straw, a straw on the server's ledger and a pending insemination (review B3 #1).
do
    local savedMission, savedDewars, savedLedger = g_currentMission, g_dewarManager, RLStrawLedger
    local function cousins()
        P.reset()
        P.register(id("A"), id("GS"), id("GD"))
        P.register(id("B"), id("GS"), id("GD"))
        P.register(id("D"), id("B"), id("V"))
    end
    -- Sire S (child of A) has left the game; only his batch remembers him.
    local batch = { country = 1, farmId = "1", uniqueId = "S", sireFatherId = id("A"), sireMotherId = id("U") }
    local dam = mkAnimal("D", id("B"), id("V"))
    local xml = { setString = function() end }
    local function afterSave(mission, ledger)
        cousins()
        g_currentMission, g_dewarManager, RLStrawLedger = mission, { farms = {} }, ledger
        local before = P.checkMating(dam, batch)
        P.saveToXMLFile(xml, "pedigree")
        return before, (P.checkMating(dam, batch))
    end
    local function pen(animals, extra)
        local placeable = { getClusters = function() return animals end }
        for k, v in pairs(extra or {}) do placeable[k] = v end
        return placeable
    end
    local base = { animalSystem = { animals = {}, aiAnimals = {} } }

    local m = table.clone(base, 3)
    m.husbandrySystem = { placeables = { pen({ dam }) } }
    m.placeableSystem = { placeables = { { spec_objectStorage = { storedObjects = { { rlDewarData = { animal = batch } } } } } } }
    local b, a = afterSave(m, nil)
    check("save keeps the ancestors of a stored dewar's sire (first cousins stay 6.25%)", b == 0.0625 and a == 0.0625)

    m = table.clone(base, 3)
    m.husbandrySystem = { placeables = { pen({ dam }) } }
    m.handToolSystem = { handTools = { { [P.STRAW_SPEC] = { animal = batch } } } }
    b, a = afterSave(m, nil)
    check("save keeps the ancestors of a hand-tool straw's sire", b == 0.0625 and a == 0.0625)

    m = table.clone(base, 3)
    m.husbandrySystem = { placeables = { pen({ dam }) } }
    b, a = afterSave(m, { held = { alice = { { dewarId = "D1", snapshot = batch } } } })
    check("save keeps the ancestors of a straw on the ledger", b == 0.0625 and a == 0.0625)

    local inseminated = mkAnimal("X", nil, nil, { insemination = batch })
    m = table.clone(base, 3)
    m.husbandrySystem = { placeables = { pen({ dam, inseminated }) } }
    b, a = afterSave(m, nil)
    check("save keeps the ancestors of a pending insemination's sire", b == 0.0625 and a == 0.0625)

    m = table.clone(base, 3)
    m.husbandrySystem = { placeables = { pen({ dam }) } }
    b, a = afterSave(m, nil)
    check("without any record of the sire his line may go", b == 0.0625)

    g_currentMission, g_dewarManager, RLStrawLedger = savedMission, savedDewars, savedLedger
end
