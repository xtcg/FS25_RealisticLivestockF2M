-- Semen collection and sale, the straw ledger, and server-side semen purchase.

DewarData = { CAPACITY = 1000, PRICE_PER_STRAW = 4.65 }
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
    [6] = { name = "BULL_HOLSTEIN", typeIndex = 1, gender = "male", breed = "HOLSTEIN", reproductionMinAgeMonth = 12, output = {} },
    [7] = { name = "BULL_ANGUS", typeIndex = 1, gender = "male", breed = "ANGUS", reproductionMinAgeMonth = 12, output = {} },
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

loadMod("scripts/insemination/RLSemenBatch.lua")
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
check("average sire, 300 straws = 300*4.65*0.6*1.40*0.7 = 820.26", near(averageValue, 820.26))
-- Elite, meat weights: .35*1.5 + .25*1.2 + .20*1.5 + .10*1.4 + .10*1.6 = 1.425; conception 0.9 vs 0.6
check("elite sire worth 1.425^3 x 1.5 the average",
    near(RLSemenCollection.getSellValue(elite, 300) / averageValue, 1.425 ^ 3 * 1.5, 0.001))
check("bought semen resells at 70% of its buy price",
    near(RLSemenCollection.getSellValue(cheapDealer, 300), 0.7 * 300 * RLSemenCollection.getStrawPrice(cheapDealer, 0.2)))

-- Breeding index
local index = RLSemenCollection.getBreedingIndex
local milky = { fertility = 1, quality = 1, health = 1, metabolism = 1, productivity = 1.5 }
check("index: average sire is 1", near(index(average), 1))
check("index: dairy breed weights milk 40%", near(index({ subTypeIndex = 6, genetics = milky }), 1.2))
check("index: meat breed weights milk 10%", near(index({ subTypeIndex = 7, genetics = milky }), 1.05))
check("index: missing productivity leaves the rest averaged",
    near(index({ genetics = { fertility = 0.5, quality = 0.5, health = 0.5, metabolism = 0.5 } }), 0.5))
-- The playtest sire: every gene 0.67, 133 straws at conception 0.5
local ordinary = { collected = true, success = 0.5, genetics = { fertility = 0.67, quality = 0.67, health = 0.67, metabolism = 0.67, productivity = 0.67 } }
check("ordinary sire, 133 straws = 133*4.65*0.5*0.67^3*1.40*0.7",
    near(RLSemenCollection.getSellValue(ordinary, 133), 133 * 4.65 * 0.5 * 0.67 ^ 3 * 1.40 * 0.7, 0.01))

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
check("sell: own dewar sold at the server's value and removed", near(MONEY[1], averageValue) and d.isDeleted)
SemenSellEvent.new(mkDewar(1, average, 300)):run(makeConnection("alice", true))
check("sell: event arriving from the server side is ignored", near(MONEY[1], averageValue))

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
MONEY[1] = 10000 -- enough for the fee, so the load failure is what is tested
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
got, left = roundTrip(SemenCollectEvent.newState(pen, { uniqueId = "X" }, 42, 77))
check("wire: state round-trips", left == 0 and got.mode == SemenCollectEvent.MODE_STATE and got.collectedAge == 42
    and got.collectedMonth == 77)
got, left = roundTrip(SemenCollectEvent.newState(pen, { uniqueId = "X" }, 42, nil))
check("wire: state without a month record round-trips as nil", left == 0 and got.collectedMonth == nil)
got, left = roundTrip(SemenCollectEvent.newResult("", 360, 460))
check("wire: result round-trips", left == 0 and got.resultKey == "" and got.straws == 360 and got.fee == 460)

streamWriteUInt8, streamReadUInt8 = function(_, v) w(v) end, function() return r() end
local strawSemen = RLSemenBatch.stamp({ country = 6, farmId = "12", uniqueId = "U1", name = "Max", typeIndex = 1, subTypeIndex = 1,
    success = 0.5, genetics = { metabolism = 1, fertility = 1, health = 1, quality = 1, productivity = 1 } }, "COLLECTED", 41, { fatherId = "F" })
q = {}
AnimalInseminationEvent.new(pen, { uniqueId = "COW" }, strawSemen):writeStream(1, nil)
local insEvent = AnimalInseminationEvent.emptyNew()
insEvent.run = function() end
insEvent:readStream(1, nil)
check("wire: hand-tool insemination carries the straw's batch", #q == 0 and insEvent.semen.batchId == strawSemen.batchId
    and insEvent.semen.batchMonth == 41 and insEvent.semen.sireFatherId == "F")

-- Batch 1: calendar month record, body condition, no made-up straw, service fee, dialog texts
g_currentMission.environment = { currentYear = 3, currentPeriod = 5 }
local thisMonth = 3 * 12 + 5 - 1
check("month index: year x 12 + period - 1", RLSemenCollection.getMonthIndex() == thisMonth)
check("month: collected this calendar month refused, whatever his age now",
    refuse(mkAnimal(1, 31, 1, { semenCollectedMonth = thisMonth, semenCollectedAge = 30 })) == R.COLLECTED)
check("month: collected last calendar month allowed",
    refuse(mkAnimal(1, 31, 1, { semenCollectedMonth = thisMonth - 1, semenCollectedAge = 30 })) == nil)
check("month: an old save's age record still blocks its month", refuse(mkAnimal(1, 30, 1, { semenCollectedAge = 30 })) == R.COLLECTED)
local marked = mkAnimal(1, 30, 1)
RLSemenCollection.markCollected(marked)
check("month: markCollected records month and age", marked.semenCollectedMonth == thisMonth and marked.semenCollectedAge == 30)
g_currentMission.environment.currentPeriod = 6
check("month: next period frees him", refuse(marked) == nil)
g_currentMission.environment.currentPeriod = 5

-- Body condition: cattle only (fertilityEffect 0 sections read 1)
loadMod("scripts/nutrition/RLNutritionMath.lua")
local BCS, CONFIG = {}, { fertilityEffect = 1 }
RLBodyCondition = {
    appliesTo = function(a) return BCS[a] ~= nil end,
    getConfig = function() return CONFIG end,
    getBCS = function(a) return BCS[a] end,
}
local function withBCS(bcs, fertility, age)
    local a = mkAnimal(1, age or 30, fertility or 1)
    BCS[a] = bcs
    return a
end
check("condition: BCS 3 at peak keeps 300", yield(withBCS(3)) == 300)
check("condition: BCS 4.5 (a grown bull on full feed) keeps 300", yield(withBCS(4.5)) == 300)
check("condition: BCS 5 -> 270", yield(withBCS(5)) == 270)
check("condition: BCS 2 -> 210", yield(withBCS(2)) == 210)
check("condition: BCS 1.5 refused", refuse(withBCS(1.5)) == R.CONDITION and yield(withBCS(1.5)) == 0)
CONFIG = { fertilityEffect = 0 }
check("condition: a species whose condition leaves breeding alone reads 1", yield(withBCS(1.5)) == 300)
CONFIG = { fertilityEffect = 1 }
local bd = RLSemenCollection.getYieldBreakdown(withBCS(2, 1.2))
check("breakdown: base, gene, age, condition and the product", bd.base == 300 and near(bd.fertility, 1.2)
    and bd.age == 1 and near(bd.condition, 0.7) and bd.straws == 252)
RLBodyCondition = nil

-- No straw made up: a boar with a tiny yield is refused, not given one dose
SUBS[8] = { name = "BOAR_LANDRACE", typeIndex = 4, gender = "male", reproductionMinAgeMonth = 8, output = {} }
TYPES[4] = { name = "PIG" }
check("pig: 20 doses at peak", yield(mkAnimal(8, 12, 1)) == 20)
RLSemenCollection.STRAWS_PER_COLLECTION.PIG = 1
check("pig: under one dose -> 0 and refused, not rounded up to one",
    yield(mkAnimal(8, 8, 0.8)) == 0 and refuse(mkAnimal(8, 8, 0.8)) == R.NO_YIELD)
RLSemenCollection.STRAWS_PER_COLLECTION.PIG = 20

-- Fee: base + per straw, x the difficulty multiplier
RLLivestockPrices = { getMultiplier = function() return MULT or 1 end }
check("fee: bull 300 straws = 100 + 300 = 400", near(RLSemenCollection.getFee(mkAnimal(1, 24, 1)), 400))
check("fee: ram 100 straws = 30 + 100", near(RLSemenCollection.getFee(mkAnimal(5, 10, 1)), 130))
check("fee: boar 20 doses = 10 + 20", near(RLSemenCollection.getFee(mkAnimal(8, 12, 1)), 30))
MULT = 3
check("fee: x3 on EASY like the prices", near(RLSemenCollection.getFee(mkAnimal(1, 24, 1)), 1200))
MULT = 1
check("fee: none for a type without collection", RLSemenCollection.getCollectionFee("CHICKEN", 10) == 0)
check("fee: own semen sells for more than the fee for an average bull",
    RLSemenCollection.getSellValue({ collected = true, success = 0.5, genetics = average.genetics }, 300) > RLSemenCollection.getFee(mkAnimal(1, 24, 1)))

-- Server: fee checked before the load, charged after it
MoneyType.SEMEN_COLLECTION = "semenCollection"
local feeSent = {}
local feeClient = makeConnection("alice", false, feeSent)
local chargeLog = {}
g_currentMission.addMoney = function(_, v, farmId, moneyType) MONEY[farmId] = (MONEY[farmId] or 0) + v; chargeLog[#chargeLog + 1] = { v, moneyType } end
local poorBull = mkAnimal(1, 24, 1)
local poorPen = { farm = 1, getClusterSystem = function() return { animals = { poorBull } } end }
MONEY = { [1] = 399 }
spawned = nil
request(poorBull, poorPen):run(feeClient)
check("fee: cannot pay -> refused, nothing spawned or recorded", spawned == nil and poorBull.semenCollectedMonth == nil
    and feeSent[1].resultKey == RLSemenCollection.REFUSAL_NO_MONEY and near(feeSent[1].fee, 400) and #chargeLog == 0)
MONEY = { [1] = 400 }
request(poorBull, poorPen):run(feeClient)
check("fee: charged once after the dewar loaded", spawned ~= nil and spawned.straws == 300 and near(MONEY[1], 0)
    and #chargeLog == 1 and chargeLog[1][2] == "semenCollection" and feeSent[2].resultKey == "" and near(feeSent[2].fee, 400))
check("fee: month recorded on the sire and in the broadcast", poorBull.semenCollectedMonth == thisMonth
    and broadcast[#broadcast].collectedMonth == thisMonth)
local failBull = mkAnimal(1, 30, 1, { semenCollectedMonth = thisMonth - 3, semenCollectedAge = 27 })
MONEY = { [1] = 1000 }
LOAD_STATE = 1
request(failBull, { farm = 1, getClusterSystem = function() return { animals = { failBull } } end }):run(feeClient)
LOAD_STATE = 0
check("fee: a failed load charges nothing and restores the old record",
    near(MONEY[1], 1000) and #chargeLog == 1 and failBull.semenCollectedMonth == thisMonth - 3 and failBull.semenCollectedAge == 27)

-- Two collections in flight: the first one's fee is held, so the second cannot spend it too
do
    local pending = {}
    local originalNew = VehicleLoadingData.new
    VehicleLoadingData.new = function()
        local data = originalNew()
        data.load = function(self, cb, target)
            pending[#pending + 1] = function(state, vehicle)
                cb(target, { vehicle or { setAnimal = function() end, setStraws = function() end } }, state)
            end
        end
        return data
    end
    MONEY = { [1] = 400 }
    local b1, b2, b3 = mkAnimal(1, 24, 1), mkAnimal(1, 25, 1), mkAnimal(1, 26, 1)
    local p = { farm = 1, getClusterSystem = function() return { animals = { b1, b2, b3 } } end }
    local before = #feeSent
    request(b1, p):run(feeClient)
    request(b2, p):run(feeClient)
    check("fee held: second request on the same balance refused", #pending == 1
        and feeSent[before + 1].resultKey == RLSemenCollection.REFUSAL_NO_MONEY)
    pending[1](VehicleLoadingState.OK)
    check("fee held: the one collection charged, balance not negative", MONEY[1] == 0
        and SemenCollectEvent.reservedFees[1] == nil)
    MONEY = { [1] = 400 }
    request(b3, p):run(feeClient)
    pending[2](VehicleLoadingState.ERROR)
    check("fee held: a failed load releases the hold", MONEY[1] == 400 and SemenCollectEvent.reservedFees[1] == nil)

    -- Other spending of the farm during the load: checked again before charging
    local b4 = mkAnimal(1, 27, 1, { semenCollectedMonth = thisMonth - 2, semenCollectedAge = 25 })
    p = { farm = 1, getClusterSystem = function() return { animals = { b4 } } end }
    local dewar = { setAnimal = function() end, setStraws = function() end, delete = function(self) self.isDeleted = true end }
    request(b4, p):run(feeClient)
    local charges = #chargeLog
    MONEY[1] = 300
    pending[3](VehicleLoadingState.OK, dewar)
    check("fee recheck: balance spent during the load -> no charge, dewar removed, record restored",
        MONEY[1] == 300 and #chargeLog == charges and SemenCollectEvent.reservedFees[1] == nil
        and b4.semenCollectedMonth == thisMonth - 2 and b4.semenCollectedAge == 25
        and dewar.isDeleted and feeSent[#feeSent].resultKey == RLSemenCollection.REFUSAL_NO_MONEY)
    VehicleLoadingData.new = originalNew
end

-- Dialog texts
local TEXTS = { rl_semen_refuseCollected = "Collected.", rl_semen_nextCollection = "Next: %s.",
    rl_semen_refuseTooYoung = "Young.", rl_semen_minAge = "From %d.", rl_semen_preview = "%s|%d|%d|%.2f|%.2f|%.2f|%.2f|%s" }
g_i18n = { getText = function(_, k) return TEXTS[k] or k end, formatPeriod = function(_, p) return "P" .. p end,
    formatMoney = function(_, v) return string.format("$%d", math.floor(v + 0.5)) end }
check("text: collected names the next month", RLSemenCollection.getRefusalText(R.COLLECTED) == "Collected. Next: P6.")
g_currentMission.environment.currentPeriod = 12
check("text: next month wraps to period 1", RLSemenCollection.getRefusalText(R.COLLECTED) == "Collected. Next: P1.")
g_currentMission.environment.currentPeriod = 5
check("text: too young names the age", RLSemenCollection.getRefusalText(R.TOO_YOUNG, mkAnimal(1, 10, 1)) == "Young. From 12.")
PREVIEW = RLSemenCollection.getPreviewText(mkAnimal(1, 30, 1.2))
check("text: preview lists name, straws, factors, index and fee " .. PREVIEW, PREVIEW == "Max|360|300|1.20|1.00|1.00|1.04|$460")

-- B4: species prices, species index weights, buy-back below the cheapest buy, dealer quota
TYPES[4] = { name = "PIG" }
SUBS[8] = { name = "BOAR_LANDRACE", typeIndex = 4, gender = "male", reproductionMinAgeMonth = 8, output = {} }
local genes1 = { fertility = 1, quality = 1, health = 1, metabolism = 1, productivity = 1 }
local function sire(typeIndex, extra)
    local t = { collected = true, success = 0.5, country = 6, farmId = "12", uniqueId = "S" .. typeIndex, typeIndex = typeIndex,
        genetics = table.clone(genes1) }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
local cowPrice = RLSemenCollection.getStrawPrice(sire(1), 1)
check("B4 price: cattle straw keeps 4.65", near(cowPrice, 4.65 * 0.5, 1e-9))
check("B4 price: ram straw 3.90, boar dose 1.30", near(RLSemenCollection.getStrawPrice(sire(3), 1), 3.90 * 0.5, 1e-9)
    and near(RLSemenCollection.getStrawPrice(sire(4), 1), 1.30 * 0.5, 1e-9))
check("B4 price: an animal (animalTypeIndex) prices like its snapshot",
    near(RLSemenCollection.getStrawPrice({ animalTypeIndex = 4, success = 0.5, genetics = genes1 }, 1), 0.65, 1e-9))
-- Dealer average sire: farm factor ~1.55, conception ~0.65, index ~1.53 -> ~18 / ~15 / ~5
local dealerAvg = function(typeIndex) return RLSemenCollection.getStrawPrice(sire(typeIndex, { success = 0.65,
    genetics = { fertility = 1.53, quality = 1.53, health = 1.53, metabolism = 1.53, productivity = 1.53 } }), 1.55) end
-- (the dealer's mean over its spread of sires is ~18 for cattle, since the index is cubed)
check("B4 price: dealer sire ram/boar at 15/18 and 5/18 of cattle", near(dealerAvg(3) / dealerAvg(1), 15 / 18, 0.01)
    and near(dealerAvg(4) / dealerAvg(1), 5 / 18, 0.005))

local pigGenes = { fertility = 1, quality = 1.5, health = 1, metabolism = 1.5 }
check("B4 index: pig weights growth and lean 35% each", near(index({ typeIndex = 4, genetics = pigGenes }), 1.35, 1e-9))
local ramGenes = { fertility = 1, quality = 1.5, health = 1, metabolism = 1, productivity = 1 }
check("B4 index: sheep weights muscle 30%", near(index({ typeIndex = 3, genetics = ramGenes }), 1.15, 1e-9))
check("B4 index: beef cattle keep the meat weights", near(index({ typeIndex = 1, subTypeIndex = 7, genetics = ramGenes }), 1.175, 1e-9))

check("B4 buy-back: own semen sells under the cheapest dealer straw of the same genetics",
    RLSemenCollection.COLLECTED_PRICE_FACTOR * RLSemenCollection.SELL_SHARE < RLSemenCollection.DEALER_MIN_PRICE_FACTOR)
do
    local worst = 0
    for _, typeIndex in ipairs({ 1, 3, 4 }) do
        for _, pf in ipairs({ 1.0125, 1.3, 2.1875 }) do
            local s = sire(typeIndex, { collected = false })
            g_currentMission.animalSystem.getFarmSemenPrice = function() return pf end
            worst = math.max(worst, RLSemenCollection.getSellValue(s, 10) / (10 * RLSemenCollection.getStrawPrice(s, pf)))
            local own = sire(typeIndex)
            worst = math.max(worst, RLSemenCollection.getSellValue(own, 10) / (10 * RLSemenCollection.getStrawPrice(own, 1.0125)))
        end
    end
    check("B4 buy-back: every sale under its buy price " .. worst, worst < 1)
    g_currentMission.animalSystem.getFarmSemenPrice = function(_, country, farmId) return farmId == "77" and 0.2 or 1 end
end

-- Quota: 300 cattle straws per farm per month for collected semen
RLSemenCollection.quotaUsed = {}
local QS = RLSemenCollection.getSellableStraws
check("B4 quota: 250 of a fresh month all sellable", QS(sire(1), 250, 1) == 250)
check("B4 quota: 400 capped at 300", QS(sire(1), 400, 1) == 300)
check("B4 quota: bought semen unlimited", QS(sire(1, { collected = false }), 400, 1) == 400)
check("B4 quota: species without a quota unlimited", QS(sire(2), 400, 1) == 400)

local qBroadcast = {}
g_server = { broadcastEvent = function(_, e) qBroadcast[#qBroadcast + 1] = e end }
RLSemenQuotaEvent = { new = function(entries) return { quota = entries } end }
MONEY = {}
local big = mkDewar(1, sire(1), 400)
SemenSellEvent.new(big):run(alice)
local soldValue = RLSemenCollection.getSellValue(sire(1), 300)
check("B4 quota: partial sale pays 300 straws, leaves 100 in the dewar", near(MONEY[1], soldValue) and big.straws == 100
    and not big.isDeleted)
check("B4 quota: used recorded and broadcast", RLSemenCollection.getQuotaLeft(1, "COW") == 0 and #qBroadcast == 1
    and qBroadcast[1].quota[1].used == 300 and qBroadcast[1].quota[1].typeName == "COW")
SemenSellEvent.new(big):run(alice)
check("B4 quota: full -> refused, dewar kept", near(MONEY[1], soldValue) and big.straws == 100 and #qBroadcast == 1)
check("B4 quota: other farm and other species unaffected", RLSemenCollection.getQuotaLeft(2, "COW") == 300
    and RLSemenCollection.getQuotaLeft(1, "SHEEP") == 200)
local ramDewar = mkDewar(1, sire(3), 120)
SemenSellEvent.new(ramDewar):run(alice)
check("B4 quota: a ram dewar under quota sells whole", ramDewar.isDeleted and RLSemenCollection.getQuotaLeft(1, "SHEEP") == 80)
g_currentMission.environment.currentPeriod = 6
check("B4 quota: next month resets", RLSemenCollection.getQuotaLeft(1, "COW") == 300 and QS(sire(1), 100, 1) == 100)
g_currentMission.environment.currentPeriod = 5

-- Quota save/load: only the current month is kept
do
    local store = {}
    local xml = { setInt = function(_, k, v) store[k] = v end, setString = function(_, k, v) store[k] = v end,
        getInt = function(_, k, d) return store[k] or d end, getString = function(_, k) return store[k] end,
        iterate = function(_, key, fn)
            local i = 0
            while store[string.format("%s(%d)#farmId", key, i)] ~= nil do fn(i, string.format("%s(%d)", key, i)); i = i + 1 end
        end }
    RLSemenCollection.setQuotaUsed(3, "PIG", RLSemenCollection.getMonthIndex() - 1, 50)
    RLSemenCollection.saveQuotaToXMLFile(xml, "q")
    RLSemenCollection.quotaUsed = { [9] = { COW = { month = 0, used = 1 } } }
    RLSemenCollection.loadQuotaFromXMLFile(xml, "q")
    check("B4 quota: save/load keeps this month, drops last month's",
        RLSemenCollection.getQuotaLeft(1, "COW") == 0 and RLSemenCollection.getQuotaLeft(1, "SHEEP") == 80
        and RLSemenCollection.quotaUsed[3] == nil and RLSemenCollection.quotaUsed[9] == nil)
end

-- Hand-tool insemination: the server checks eligibility before spending the straw
do
    local male = mkAnimal(1, 30, 1)
    male.getCanBeInseminatedByAnimal = function() return false, "male" end
    male.setInsemination = function(self, semen) self.insemination = semen end
    local pen = { farm = 1, getClusterSystem = function() return { animals = { male } } end }
    TakeStrawEvent.new(ownDewar):run(aliceClient)
    local before = RLStrawLedger.count("alice")
    AnimalInseminationEvent.new(pen, { farmId = male.farmId, uniqueId = male.uniqueId, country = 6 }, average):run(aliceClient)
    check("B4 gate: ineligible animal refused, straw stays on record", male.insemination == nil and RLStrawLedger.count("alice") == before and before > 0)
end

-- Hand-tool insemination is checked against the ledger's sire, not the client's (review B4 #3),
-- and never replaces a pending insemination (review B4 #4)
do
    local actual = { country = 6, farmId = "12", uniqueId = "Real", typeIndex = 1, subTypeIndex = 1, batchId = "BATCH",
        genetics = { fertility = 1 } }
    RLStrawLedger.held = {}
    RLStrawLedger.record("alice", mkDewar(1, actual, 10))
    local female = mkAnimal(2, 30, 1)
    female.getCanBeInseminatedByAnimal = function(_, sireRecord) return sireRecord.uniqueId ~= "Real", "related" end
    female.setInsemination = function(self, sireRecord) self.insemination = sireRecord end
    local altered = table.clone(actual, 3)
    altered.uniqueId = "Unrelated"
    local femalePen = { getClusterSystem = function() return { animals = { female } } end }
    local femaleIds = { farmId = female.farmId, uniqueId = female.uniqueId, country = 6 }
    AnimalInseminationEvent.new(femalePen, femaleIds, altered):run(aliceClient)
    check("B4 gate: a changed sire id in the request does not pass the recorded sire",
        female.insemination == nil and RLStrawLedger.count("alice") == 1)

    female.getCanBeInseminatedByAnimal = function() return true end
    AnimalInseminationEvent.new(femalePen, femaleIds, altered):run(aliceClient)
    check("B4 gate: an allowed insemination uses the ledger's sire and spends the straw",
        female.insemination ~= nil and female.insemination.uniqueId == "Real" and RLStrawLedger.count("alice") == 0)

    local first = female.insemination
    RLStrawLedger.record("alice", mkDewar(1, actual, 10))
    AnimalInseminationEvent.new(femalePen, femaleIds, actual):run(aliceClient)
    check("B4 gate: a second straw for a pending insemination is refused and not spent",
        female.insemination == first and RLStrawLedger.count("alice") == 1)
end

for _, line in ipairs(LOG) do
    if line:find("^safeCall") or line:find("^error") then check("no script error: " .. line, false) end
end
