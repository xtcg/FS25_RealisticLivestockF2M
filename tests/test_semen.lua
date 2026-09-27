-- Semen collection and sale, the straw ledger, and server-side semen purchase.

DewarData = { CAPACITY = 1000, PRICE_PER_STRAW = 0.85 }
RLDiseaseSaleGate = { check = function(a) return not a.sick end }
MoneyType = { SEMEN_SALE = "semenSale", SEMEN_PURCHASE = "semenPurchase" }
RLConstants = { DEWAR_QUANTITIES = { 1, 2, 5, 10, 25, 50, 100 } }
Animal = { isSemenFillType = function(fillType) return fillType == "BULLSPERM" end }

TYPES = { [1] = { name = "COW" }, [2] = { name = "CHICKEN" }, [3] = { name = "SHEEP" } }
SUBS = {
    [1] = { name = "BULL_ANGUS", typeIndex = 1, gender = "male", reproductionMinAgeMonth = 12, output = {} },
    [2] = { name = "COW_ANGUS", typeIndex = 1, gender = "female", reproductionMinAgeMonth = 12, output = {} },
    [3] = { name = "CHICKEN_ROOSTER", typeIndex = 2, gender = "male", reproductionMinAgeMonth = 6, output = {} },
    [4] = { name = "BULL", typeIndex = 1, gender = "male", output = { milk = { fillType = "BULLSPERM" } } },
    [5] = { name = "RAM_LANDRACE", typeIndex = 3, gender = "male", reproductionMinAgeMonth = 5, output = {} },
}
MONEY = {}
PERMISSION = true
DEALER_BULLS = {}

g_currentMission = {
    animalSystem = {
        getTypeByIndex = function(_, i) return TYPES[i] end,
        getSubTypeByIndex = function(_, i) return SUBS[i] end,
        getFarmSemenPrice = function(_, country, farmId) return farmId == "77" and 0.2 or 1 end,
        getAIAnimalsByTypeIndex = function(_, typeIndex) return DEALER_BULLS end,
    },
    getHasPlayerPermission = function() return PERMISSION end,
    getMoney = function(_, farmId) return MONEY[farmId] or 0 end,
    addMoney = function(_, v, farmId) MONEY[farmId] = (MONEY[farmId] or 0) + v end,
    userManager = { getUniqueUserIdByConnection = function(_, c) return c.user end },
    accessHandler = { canFarmAccess = function(_, farmId, obj) return obj.farm == farmId end },
}
g_farmManager = { getFarmForUniqueUserId = function(_, u) return { farmId = (u == "alice" and 1) or 2 } end }
RLAnimalUtil = { find = function(list, farmId, uniqueId, country)
    for _, a in ipairs(list) do
        if a.uniqueId == uniqueId and tostring(a.farmId) == tostring(farmId) then return a end
    end
end }

function mkAnimal(sub, age, fertility, extra)
    local a = { subTypeIndex = sub, animalTypeIndex = SUBS[sub].typeIndex, age = age, gender = SUBS[sub].gender,
        genetics = { fertility = fertility, quality = 1, health = 1, metabolism = 1, productivity = 1 },
        farmId = "12", uniqueId = "U" .. sub .. "-" .. age, birthday = { country = 6 }, output = { milk = 0.04 } }
    for k, v in pairs(extra or {}) do a[k] = v end
    a.getSubType = function(self) return SUBS[self.subTypeIndex] end
    a.getName = function() return "Max" end
    return a
end

function mkDewar(owner, snapshot, straws)
    local d = { isDewar = true, straws = straws, uniqueId = "D" .. tostring(math.random(1e6)) }
    function d:getOwnerFarmId() return owner end
    function d:getAnimal() return snapshot end
    function d:getUniqueId() return self.uniqueId end
    function d:changeStraws(delta) self.straws = self.straws + delta end
    function d:delete() self.isDeleted = true end
    return d
end

loadMod("scripts/insemination/RLSemenCollection.lua")
loadMod("scripts/insemination/RLStrawLedger.lua")
loadMod("scripts/events/SemenSellEvent.lua")
loadMod("scripts/events/SemenCollectEvent.lua")
loadMod("scripts/events/TakeStrawEvent.lua")
loadMod("scripts/events/ReturnStrawEvent.lua")
loadMod("scripts/animals/shop/events/AnimalInseminationEvent.lua")
loadMod("scripts/animals/shop/events/SemenBuyEvent.lua")

local R = RLSemenCollection.REFUSAL
local refuse = RLSemenCollection.getRefusal

-- Eligibility
check("female refused", refuse(mkAnimal(2, 30, 1)) == R.NOT_MALE)
check("rooster refused (no AI trade for poultry)", refuse(mkAnimal(3, 20, 1)) == R.SPECIES)
check("castrated refused", refuse(mkAnimal(1, 30, 1, { isCastrated = true })) == R.INFERTILE)
check("bull at 10 months too young", refuse(mkAnimal(1, 10, 1)) == R.TOO_YOUNG)
check("bull at 140 months, fertility 1 (limit 132) too old", refuse(mkAnimal(1, 140, 1)) == R.TOO_OLD)
check("fertility 1.5 extends the limit to 198 months", refuse(mkAnimal(1, 140, 1.5)) == nil)
check("collected this month refused", refuse(mkAnimal(1, 30, 1, { semenCollectedAge = 30 })) == R.COLLECTED)
check("next month allowed", refuse(mkAnimal(1, 31, 1, { semenCollectedAge = 30 })) == nil)
check("semen already stored by the stable this month refused", refuse(mkAnimal(4, 30, 1, { semenProducedAge = 30 })) == R.PRODUCED)
check("stored last month does not block", refuse(mkAnimal(4, 31, 1, { semenProducedAge = 30 })) == nil)
check("sick refused", refuse(mkAnimal(1, 30, 1, { sick = true })) == R.SICK)
check("HB BULL saved as female still counts as male, default min age 12",
    refuse(mkAnimal(4, 13, 1, { gender = "female" })) == nil and refuse(mkAnimal(4, 11, 1, { gender = "female" })) == R.TOO_YOUNG)
check("ram eligible", refuse(mkAnimal(5, 12, 1)) == nil)

-- Straw yield
local yield = RLSemenCollection.getStrawYield
check("bull at peak, fertility 1 -> 300 straws", yield(mkAnimal(1, 24, 1)) == 300)
check("bull in its first month -> 150", yield(mkAnimal(1, 12, 1)) == 150)
check("fertility 1.5 at peak -> 450", yield(mkAnimal(1, 30, 1.5)) == 450)
check("bull at 120 months declines -> 154", yield(mkAnimal(1, 120, 1)) == 154)
check("ram at peak -> 100", yield(mkAnimal(5, 10, 1)) == 100)
check("yield: too young -> 0", yield(mkAnimal(1, 11, 1)) == 0)
check("yield: at the cutoff age -> 0", yield(mkAnimal(1, 132, 1)) == 0)
check("yield: infertile -> 0", yield(mkAnimal(1, 30, 0)) == 0)

-- Age share the bull stable's BULLSPERM output follows too (same curve as the straw yield)
local share = RLSemenCollection.getAgeOutputFactor
check("stable: HB BULL under 12 months gives nothing", share(mkAnimal(4, 11, 1)) == 0)
check("stable: half at 12 months, full from 18", near(share(mkAnimal(4, 12, 1)), 0.5) and share(mkAnimal(4, 18, 1)) == 1)
check("stable: full until 70% of 132 months", share(mkAnimal(4, 92, 1)) == 1)
check("stable: 120 months declines like the straw yield", near(share(mkAnimal(4, 120, 1)), 154 / 300, 0.002))
check("stable: nothing from the cutoff age, over 30% the month before", share(mkAnimal(4, 132, 1)) == 0 and share(mkAnimal(4, 131, 1)) > 0.3)
check("stable: fertility 1.5 still at full at 135 months, producing at 190", share(mkAnimal(4, 135, 1.5)) == 1 and share(mkAnimal(4, 190, 1.5)) > 0.3)

-- Sale value
local average = { collected = true, success = 0.6, country = 6, farmId = "12",
    genetics = { fertility = 1, quality = 1, health = 1, metabolism = 1, productivity = 1 } }
local elite = { collected = true, success = 0.9, country = 6, farmId = "12",
    genetics = { fertility = 1.5, quality = 1.5, health = 1.4, metabolism = 1.2, productivity = 1.6 } }
local cheapDealer = { collected = false, success = 0.6, country = 6, farmId = "77",
    genetics = { fertility = 1, quality = 1, health = 1, metabolism = 1, productivity = 1 } }
local averageValue = RLSemenCollection.getSellValue(average, 300)
check("average sire, 300 straws = 300*0.85*0.6*2.25*0.6 = 206.55", near(averageValue, 206.55))
check("elite sire worth 9.072x the average", near(RLSemenCollection.getSellValue(elite, 300) / averageValue, 9.072, 0.001))
check("bought semen resells below its buy price",
    RLSemenCollection.getSellValue(cheapDealer, 300) < 0.2 * 300 * 0.85 * 0.6 * 2.25)

-- SemenSellEvent
local alice = makeConnection("alice", false)
MONEY = {}
local d = mkDewar(2, average, 300)
SemenSellEvent.new(d):run(alice)
check("sell: another farm's dewar refused", MONEY[1] == nil and not d.isDeleted)
d = mkDewar(1, average, 300)
PERMISSION = false
SemenSellEvent.new(d):run(alice)
PERMISSION = true
check("sell: no tradeAnimals permission refused", MONEY[1] == nil and not d.isDeleted)
SemenSellEvent.new(d):run(alice)
check("sell: own dewar sold at the server's value and removed", near(MONEY[1], 206.55) and d.isDeleted)
SemenSellEvent.new(mkDewar(1, average, 300)):run(makeConnection("alice", true))
check("sell: event arriving from the server side is ignored", near(MONEY[1], 206.55))

-- SemenCollectEvent request (server)
local sent, broadcast = {}, {}
local aliceClient = makeConnection("alice", false, sent)
g_server = { broadcastEvent = function(_, e) broadcast[#broadcast + 1] = e end }
g_storeManager = { getItemByXMLFilename = function() return {} end }
VehiclePropertyState = { OWNED = 1 }
VehicleLoadingState = { OK = 0, ERROR = 1 }
LOAD_STATE = 0
local spawned
VehicleLoadingData = { new = function()
    local data = {}
    function data:setStoreItem() end
    function data:setPropertyState() end
    function data:setOwnerFarmId(f) self.owner = f end
    function data:setPosition() end
    function data:setRotation() end
    function data:load(callback, target)
        spawned = { owner = self.owner }
        function spawned:setAnimal(a) self.animal = a end
        function spawned:setStraws(n) self.straws = n end
        callback(target, { spawned }, LOAD_STATE)
    end
    return data
end }

local bull = mkAnimal(4, 30, 1.2)
local pen = { farm = 1, getClusterSystem = function() return { animals = { bull } } end }
local function request(animal, targetPen)
    return SemenCollectEvent.newRequest(targetPen, { farmId = animal.farmId, uniqueId = animal.uniqueId, country = 6 },
        { 1, 2, 3 }, { 0, 0, 0 })
end
request(bull, pen):run(aliceClient)
check("collect: dewar spawned for farm 1 with 360 straws, marked collected",
    spawned ~= nil and spawned.owner == 1 and spawned.straws == 360 and spawned.animal.collected == true)
check("collect: month recorded and broadcast", bull.semenCollectedAge == 30 and #broadcast == 1
    and broadcast[1].mode == SemenCollectEvent.MODE_STATE and broadcast[1].collectedAge == 30)
check("collect: cached BULLSPERM rate dropped at once", bull.output.milk == 0)
check("collect: requester told success", #sent == 1 and sent[1].resultKey == "" and sent[1].straws == 360)
spawned = nil
request(bull, pen):run(aliceClient)
check("collect: second request in the same month refused", spawned == nil and sent[2].resultKey == R.COLLECTED)

local bull2 = mkAnimal(1, 30, 1)
pen = { farm = 1, getClusterSystem = function() return { animals = { bull2 } } end }
LOAD_STATE = 1
request(bull2, pen):run(aliceClient)
LOAD_STATE = 0
check("collect: a failed dewar load releases the month", bull2.semenCollectedAge == nil and sent[3].resultKey == SemenCollectEvent.RESULT_FAILED)

spawned = nil
local foreign = mkAnimal(1, 30, 1)
request(foreign, { farm = 2, getClusterSystem = function() return { animals = { foreign } } end }):run(aliceClient)
check("collect: another farm's pen refused", spawned == nil and sent[4].resultKey == SemenCollectEvent.RESULT_FAILED)

-- Direction checks (review item 1)
local victim = mkAnimal(1, 40, 1, { semenCollectedAge = 40 })
local victimPen = { farm = 1, getClusterSystem = function() return { animals = { victim } } end }
SemenCollectEvent.newState(victimPen, { farmId = victim.farmId, uniqueId = victim.uniqueId, country = 6 }, 1):run(aliceClient)
check("direction: STATE from a client is dropped (cooldown cannot be rewound)", victim.semenCollectedAge == 40)
SemenCollectEvent.newState(victimPen, { farmId = victim.farmId, uniqueId = victim.uniqueId, country = 6 }, 41):run(makeConnection("x", true))
check("direction: STATE from the server is applied", victim.semenCollectedAge == 41)
local shown = false
InfoDialog = { show = function() shown = true end }
DialogElement = { TYPE_INFO = 1, TYPE_WARNING = 2 }
g_i18n = { getText = function(_, k) return k end }
SemenCollectEvent.newResult("", 5):run(aliceClient)
check("direction: RESULT from a client is dropped", not shown)
SemenCollectEvent.newResult("", 5):run(makeConnection("x", true))
check("direction: RESULT from the server is shown", shown)
spawned = nil
local fresh = mkAnimal(1, 50, 1)
request(fresh, { farm = 1, getClusterSystem = function() return { animals = { fresh } } end }):run(makeConnection("alice", true))
check("direction: REQUEST arriving from the server side is dropped", spawned == nil)

-- Straw ledger (review item 3)
local ownDewar = mkDewar(1, average, 10)
local otherDewar = mkDewar(2, average, 10)
TakeStrawEvent.new(otherDewar):run(aliceClient)
check("ledger: taking from another farm's dewar refused", otherDewar.straws == 10 and RLStrawLedger.count("alice") == 0)
ReturnStrawEvent.new(ownDewar):run(aliceClient)
check("ledger: return without a straw on record refused", ownDewar.straws == 10)
TakeStrawEvent.new(ownDewar):run(aliceClient)
check("ledger: take from own dewar recorded", ownDewar.straws == 9 and RLStrawLedger.count("alice") == 1)
ReturnStrawEvent.new(ownDewar):run(aliceClient)
ReturnStrawEvent.new(ownDewar):run(aliceClient)
check("ledger: one straw returns once", ownDewar.straws == 10 and RLStrawLedger.count("alice") == 0)
ReturnStrawEvent.new(ownDewar):run(makeConnection("x", true))
check("ledger: return mirrored from the server applies", ownDewar.straws == 11)

local cow = mkAnimal(2, 30, 1)
cow.setInsemination = function(self, semen) self.insemination = semen end
local cowPen = { farm = 1, getClusterSystem = function() return { animals = { cow } } end }
local forged = table.clone(average, 3)
forged.genetics = { fertility = 1.75, quality = 1.75, health = 1.75, metabolism = 1.75, productivity = 1.75 }
local ids = { farmId = cow.farmId, uniqueId = cow.uniqueId, country = 6 }
AnimalInseminationEvent.new(cowPen, ids, forged):run(aliceClient)
check("ledger: hand-tool insemination without a straw on record refused", cow.insemination == nil)
TakeStrawEvent.new(ownDewar):run(aliceClient)
AnimalInseminationEvent.new(cowPen, ids, forged):run(aliceClient)
check("ledger: insemination uses the server's sire genetics, not the client's",
    cow.insemination ~= nil and cow.insemination.genetics.quality == 1 and RLStrawLedger.count("alice") == 0)

-- Server-side purchase (review item 3)
local dealerBull = mkAnimal(1, 40, 1, { farmId = "5", uniqueId = "DB1", success = 0.6 })
DEALER_BULLS = { dealerBull }
RLAIStockService = { getPriceForQuantity = function(animal, quantity) return 10 * quantity * animal.genetics.quality end }
MONEY = { [1] = 1000 }
local clientCopy = mkAnimal(1, 40, 1, { farmId = "5", uniqueId = "DB1" })
clientCopy.genetics.quality = 1.75
local req = SemenBuyEvent.resolveServerRequest({ animal = clientCopy, quantity = 5, price = -0.01, farmId = 2 }, aliceClient)
check("buy: price from the server's bull and farm from the connection",
    req ~= nil and req.price == -50 and req.farmId == 1 and req.animal == dealerBull)
check("buy: quantity the dealer does not sell refused",
    SemenBuyEvent.resolveServerRequest({ animal = clientCopy, quantity = 999 }, aliceClient) == nil)
local ghost = mkAnimal(1, 40, 1, { farmId = "5", uniqueId = "NOPE" })
check("buy: bull not in dealer stock refused", SemenBuyEvent.resolveServerRequest({ animal = ghost, quantity = 5 }, aliceClient) == nil)
MONEY = { [1] = 10 }
check("buy: cannot afford refused", SemenBuyEvent.resolveServerRequest({ animal = clientCopy, quantity = 5 }, aliceClient) == nil)

-- Wire round trip of the collect event
local q = {}
local function w(v) q[#q + 1] = v end
local function r() return table.remove(q, 1) end
streamWriteUIntN, streamReadUIntN = function(_, v) w(v) end, function() return r() end
streamWriteString, streamReadString = function(_, v) w(v) end, function() return r() end
streamWriteUInt16, streamReadUInt16 = function(_, v) w(v) end, function() return r() end
streamWriteInt32, streamReadInt32 = function(_, v) w(v) end, function() return r() end
streamWriteFloat32, streamReadFloat32 = function(_, v) w(v) end, function() return r() end
NetworkUtil = { writeNodeObject = function(_, o) w(o) end, readNodeObject = function() return r() end }
RLAnimalUtil.writeStreamIdentifiers = function(a) w(a.uniqueId) end
RLAnimalUtil.readStreamIdentifiers = function() return { uniqueId = r(), country = 6 } end
local function roundTrip(event)
    q = {}
    event:writeStream(1, nil)
    local got = SemenCollectEvent.emptyNew()
    got.run = function() end
    got:readStream(1, nil)
    return got, #q
end
local got, left = roundTrip(SemenCollectEvent.newRequest(pen, { uniqueId = "X" }, { 1, 2, 3 }, { 4, 5, 6 }))
check("wire: request round-trips", left == 0 and got.object == pen and got.animal.uniqueId == "X" and got.position[3] == 3 and got.rotation[1] == 4)
got, left = roundTrip(SemenCollectEvent.newState(pen, { uniqueId = "X" }, 42))
check("wire: state round-trips", left == 0 and got.mode == SemenCollectEvent.MODE_STATE and got.collectedAge == 42)
got, left = roundTrip(SemenCollectEvent.newResult("", 360))
check("wire: result round-trips", left == 0 and got.resultKey == "" and got.straws == 360)

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
