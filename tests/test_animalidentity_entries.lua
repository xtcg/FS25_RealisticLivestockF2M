-- Dealer v2 T2c: the seven entries, with the real source text of the changed functions (sliced out of
-- the mod scripts) run against the real runtime. OFF must behave exactly like the old code.
local f = assert(io.open(REPO .. "scripts/utils/RLAnimalUtil.lua", "r")); local src = f:read("*a"); f:close()
assert(load((src:gsub("::number", "")), "RLAnimalUtil"))()
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/animal/RLAnimalIdentityPersistence.lua")
loadMod("scripts/animal/RLAnimalIdentityRuntime.lua")
loadMod("scripts/animal/RLAnimalIdentityWorld.lua")
local I, R, W, U = RLAnimalIdentity, RLAnimalIdentityRuntime, RLAnimalIdentityWorld, RLAnimalUtil
AnimalType = { COW = 1, PIG = 2, SHEEP = 3, HORSE = 4, CHICKEN = 5 }

local function slice(path, from, to)
    local h = assert(io.open(REPO .. path, "r")); local text = h:read("*a"); h:close()
    local a = assert(text:find(from, 1, true), from)
    local b = assert(text:find(to, a, true), to)
    return text:sub(a, b - 1)
end
local function compile(code, name) return assert(load((code:gsub("::number", "")), name)) end

-- real FarmStats counter and real Animal:setUniqueId / AnimalSystem functions
Animal = {}
compile(slice("scripts/animal/RealisticLivestock_Animal.lua", "function Animal:setUniqueId(farmId)", "-- Delegate (backward"), "setUniqueId")()
RealisticLivestock = { getMapCountryIndex = function() return 2 end }
local farm = { stats = { statistics = { farmId = 123456, cowId = 0, pigId = 0, sheepId = 0, horseId = 0, chickenId = 0 } } }
RealisticLivestock_FarmStats = {}
compile(slice("scripts/farms/RealisticLivestock_FarmStats.lua", "function RealisticLivestock_FarmStats:getNextAnimalId", "FarmStats.getNextAnimalId ="), "getNext")()
farm.stats.getNextAnimalId = RealisticLivestock_FarmStats.getNextAnimalId
g_farmManager = { farmIdToFarm = { [1] = farm } }
local sys = { countries = { [2] = { index = 2, farms = { { id = 9, ids = { [1] = 0 } } } } } }
function sys:getSubTypeByIndex() return { typeIndex = AnimalType.COW } end
function sys:getTypeByIndex() return { name = "COW" } end
AnimalSystem = {}
compile(slice("scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua", "function AnimalSystem:getNextAnimalIdForFarm", "function AnimalSystem:removeSaleAnimal"), "getNextForFarm")()
sys.getNextAnimalIdForFarm = AnimalSystem.getNextAnimalIdForFarm
g_currentMission = { animalSystem = sys }

local function calf()
    local c = setmetatable({ clusterSystem = { owner = { ownerFarmId = 1 } }, subTypeIndex = 1, animalTypeIndex = 1, birthday = { country = 2 } }, { __index = Animal })
    c:setUniqueId()
    return c
end
local function saleCalf(farmId)
    local c = setmetatable({ subTypeIndex = 1, animalTypeIndex = 1, birthday = { country = 2 } }, { __index = Animal })
    c:setUniqueId(farmId)
    return c
end

-- OFF (and SHADOW): the old counters, the same ids
R.reset(true); R.setLoaded(nil, "READY", "TEST"); R.mode = R.OFF
local a, b = calf(), calf()
check("OFF: setUniqueId numbers by the farm's counter exactly as before", a.uniqueId == U.generateUniqueId(123456, 1) and b.uniqueId == U.generateUniqueId(123456, 2)
    and a.farmId == "123456" and farm.stats.statistics.cowId == 2)
local s1 = saleCalf(9)
check("OFF: a sale animal's birth numbers by the country farm counter", s1.uniqueId == U.generateUniqueId(9, 1) and s1.farmId == "9" and sys.countries[2].farms[1].ids[1] == 1)
check("OFF: the old raw-1 fallbacks are untouched", sys:getNextAnimalIdForFarm(77, 1, 9) == 1 and sys:getNextAnimalIdForFarm(2, 1, 12345) == 1)
R.setMode(R.SHADOW)
local c = calf()
check("SHADOW: same ids, observed", c.uniqueId == U.generateUniqueId(123456, 3) and R.shadow.observed == 1)

-- ON
R.reset(true); R.lineage = "Ltest-3"; R.setLoaded(nil, "READY", "TEST"); R.mode = R.SHADOW
local scan = W.scan({ placeableSystem = { placeables = {} }, vehicleSystem = { vehicles = {} }, animalSystem = sys })
assert(R.activate(scan, { accept = true }))
local n1 = calf()
check("ON: a player calf is numbered above the farm counter by the ledger", n1.uniqueId == U.generateUniqueId(123456, 4) and farm.stats.statistics.cowId == 4)
local s2 = saleCalf(9)
check("ON: a sale birth is numbered by the country farm's domain", s2.uniqueId == U.generateUniqueId(9, 2) and sys.countries[2].farms[1].ids[1] == 2)
check("ON: the raw-1 fallbacks now refuse instead of authorising a key", sys:getNextAnimalIdForFarm(77, 1, 9) == nil and sys:getNextAnimalIdForFarm(2, 1, 12345) == nil)
sys.countries[2].farms[2] = { id = 10, ids = { [AnimalType.PIG] = 0 } }   -- keeps pigs, not cows
check("ON: a farm that does not breed the type refuses instead of handing out raw 1", sys:getNextAnimalIdForFarm(2, 1, 10) == nil)
R.mode = R.OFF
check("OFF: the same farm still answers raw 1 like the old code", sys:getNextAnimalIdForFarm(2, 1, 10) == 1)
R.mode = R.ON
local ghost = saleCalf(12345)
check("ON: a sale birth that cannot be numbered gets the placeholder the repair pass knows", ghost.uniqueId == "1" and ghost.farmId == "1")

-- a litter
local ctx = W.statsContext("birth", farm, AnimalType.COW, 2, "birth")
assert(R.beginBirth(ctx, "dam|1", 3))
local k1, k2 = calf(), calf()
check("ON: children of one birth take the reserved litter in order", k1.uniqueId == U.generateUniqueId(123456, 5) and k2.uniqueId == U.generateUniqueId(123456, 6))
check("ON: the unused third key is burned at the end of the birth", R.endBirth() == 1 and R.ledger.keys[I.keyString("123456", U.generateUniqueId(123456, 7), 2)].state == I.BURNED)
local after = calf()
check("ON: the next calf does not reuse the burned key", after.uniqueId == U.generateUniqueId(123456, 8))

-- advancePregnancy with the hold
local code = slice("scripts/animal/AnimalReproduction.lua", "local function advancePregnancy", "-- =====")
AnimalReproduction = { _clearOrphanedPregnancy = function() error("not expected") end }
g_server = {}
Log = Log
local advance = compile(code .. "\nreturn advancePregnancy", "advance")()
local function mother(n)
    local pregnancies = {}
    for i = 1, n do pregnancies[i] = {} end
    local m = { reproduction = 100, isPregnant = true, clusterSystem = { owner = { ownerFarmId = 1 } }, subTypeIndex = 1, animalTypeIndex = 1,
        farmId = "123456", uniqueId = U.generateUniqueId(123456, 99), birthday = { country = 2 },
        pregnancy = { pregnancies = pregnancies, expected = { day = 1, month = 2, year = 3 } },
        impregnatedBy = { uniqueId = "-1", metabolism = 1, quality = 1, health = 1, fertility = 1, productivity = 1 },
        genetics = { metabolism = 1, quality = 1, health = 1, fertility = 1 }, reproduced = 0 }
    m.changeReproduction = function(self, d) self.reproduction = math.min(100, self.reproduction + d) end
    m.getReproductionDelta = function() return 1 end
    m.reproduce = function(self)
        self.reproduced = self.reproduced + 1
        self.keysSeen = { calf().uniqueId, calf().uniqueId }
        return n, false, 0, 0
    end
    return m
end
local mom = mother(2)
advance(mom, {}, 1, 1, 1, false)
check("ON: a birth runs with its litter reserved, then the pregnancy is cleared", mom.reproduced == 1 and mom.isPregnant == false and mom.pregnancy == nil
    and mom.keysSeen[1] == U.generateUniqueId(123456, 9) and mom.keysSeen[2] == U.generateUniqueId(123456, 10) and R.currentLitter() == nil)
R.ledger.policy.acceptWeak = nil
farm.stats.statistics.farmId = 654321   -- a herd the ledger cannot serve
farm.stats.statistics.cowId = 30
local held = mother(2)
local ret = { advance(held, {}, 1, 1, 1, false) }
check("ON: a birth the ledger cannot number is held: mother still pregnant, no reproduce, no draws, counter untouched",
    held.reproduced == 0 and held.isPregnant == true and held.pregnancy ~= nil and held.reproduction == 100 and held.impregnatedBy ~= nil
    and farm.stats.statistics.cowId == 30 and ret[1] == 0)
R.ledger.policy.acceptWeak = true
advance(held, {}, 1, 1, 1, false)
check("ON: the held birth goes ahead on a later day once the ledger can serve it", held.reproduced == 1 and held.pregnancy == nil)
local thrower = mother(1)
thrower.reproduce = function() calf(); error("boom") end
local okThrow = pcall(advance, thrower, {}, 1, 1, 1, false)
check("ON: an error inside the birth still closes the litter and propagates", okThrow == false and R.currentLitter() == nil)
R.setMode(R.OFF)
local plain = mother(2)
plain.reproduce = function(self) self.reproduced = self.reproduced + 1; return 2, false, 0, 0 end
advance(plain, {}, 1, 1, 1, false)
check("OFF: the birth block does not consult the ledger at all", plain.reproduced == 1 and plain.pregnancy == nil)

-- a pen no player farm owns is not numbered by the ledger and is never held
do
    R.mode, R.state = R.ON, "READY"
    assert(R.authoritative())
    local orphan = mother(1)
    orphan.clusterSystem = { owner = { ownerFarmId = 77 } }   -- no such farm
    advance(orphan, {}, 1, 1, 1, false)
    check("ON: a birth in a pen no player farm owns goes ahead as before (not held)", orphan.reproduced == 1 and orphan.pregnancy == nil)
end
