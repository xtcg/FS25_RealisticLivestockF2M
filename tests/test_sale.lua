-- The server side of a live sale through the real AnimalSellEvent: the server prices the batch
-- from the source's own animals, refuses a bad batch whole, and pays only for animals it removed.
AnimalSellEvent = {
    SELL_SUCCESS = 0, SELL_ERROR_NO_PERMISSION = 1, SELL_ERROR_INVALID_CLUSTER = 2,
    SELL_ERROR_NOT_ENOUGH_ANIMALS = 3, SELL_ERROR_CANNOT_BE_SOLD = 4, SELL_ERROR_OBJECT_DOES_NOT_EXIST = 5,
}
function AnimalSellEvent.emptyNew() return setmetatable({}, { __index = AnimalSellEvent }) end
function AnimalSellEvent.newServerToClient(errorCode)
    local event = AnimalSellEvent.emptyNew()
    event.errorCode = errorCode
    return event
end
-- RLAnimalUtil.lua has Luau syntax plain Lua cannot load; these two copy its key functions.
RLAnimalUtil = {}
function RLAnimalUtil.toKey(farmId, uniqueId, country) return farmId .. " " .. uniqueId .. " " .. country end
function RLAnimalUtil.toKeyFromIdentifiers(ids)
    local country = ids.country or (ids.birthday and ids.birthday.country)
    if country == nil then return nil end
    return RLAnimalUtil.toKey(ids.farmId, ids.uniqueId, country)
end
loadMod("scripts/disease/RLDiseaseSaleGate.lua")
loadMod("scripts/animals/shop/events/AnimalSellEvent.lua")

MoneyType = { SOLD_ANIMALS = 7 }
g_i18n = { formatMoney = function(_, v) return string.format("%.2f", v) end }

local wallet, permitted
local farms = { alice = 1, bob = 2 }
g_currentMission = {
    getHasPlayerPermission = function(_, permission) return permission == "tradeAnimals" and permitted end,
    userManager = { getUniqueUserIdByConnection = function(_, connection) return connection.user end },
    addMoney = function(_, amount, farmId, moneyType)
        wallet[#wallet + 1] = { amount = amount, farmId = farmId, moneyType = moneyType }
    end,
}
g_farmManager = { getFarmForUniqueUserId = function(_, userId) return { farmId = farms[userId] } end }

local nextId = 0
local function makeAnimal(price, fee, opts)
    opts = opts or {}
    nextId = nextId + 1
    return {
        farmId = "1", uniqueId = tostring(nextId), birthday = { country = 4 }, animalTypeIndex = 1,
        price = price, fee = fee, sick = opts.sick, canBeSold = opts.canBeSold,
        getCanBeSold = function(self) return self.canBeSold ~= false end,
        getHasAnyDisease = function(self) return self.sick == true end,
        getSellPrice = function(self) return self.price end,
        getTranportationFee = function(self, factor) return self.fee * factor end,
    }
end

local function key(animal) return RLAnimalUtil.toKey(animal.farmId, animal.uniqueId, animal.birthday.country) end

-- A source with the engine's queue-then-flush removal; failAfter makes the flush throw after
-- removing that many animals, failQueue makes queueing throw.
local function makeSource(animals, opts)
    opts = opts or {}
    local source = { ownerFarmId = opts.owner or 1, spec_livestockTrailer = opts.trailer and {} or nil, messages = {} }
    local system = { animals = animals, clustersToRemove = {}, flushes = 0 }
    function system:addPendingRemoveCluster(cluster)
        if opts.failQueue then error("queue boom") end
        self.clustersToRemove[cluster] = true
    end
    function system:updateNow()
        self.flushes = self.flushes + 1
        local removedNow = 0
        for i = #self.animals, 1, -1 do
            local animal = self.animals[i]
            if self.clustersToRemove[animal] then
                if opts.failAfter ~= nil and removedNow >= opts.failAfter then error("flush boom") end
                table.remove(self.animals, i)
                self.clustersToRemove[animal] = nil
                removedNow = removedNow + 1
            end
        end
    end
    source.system = system
    function source:getClusterSystem() return self.system end
    function source:getOwnerFarmId() return self.ownerFarmId end
    function source:getClusterById(id)
        for _, animal in ipairs(self.system.animals) do
            if key(animal) == id then return animal end
        end
        return nil
    end
    if not opts.trailer then
        function source:addRLMessage(id, _, args) self.messages[#self.messages + 1] = { id = id, args = args } end
    end
    return source
end

-- Identifiers as the server reads them off the wire.
local function ids(animals)
    local list = {}
    for i, animal in ipairs(animals) do
        list[i] = { farmId = animal.farmId, uniqueId = animal.uniqueId, country = animal.birthday.country,
            birthday = { country = animal.birthday.country }, animalTypeIndex = animal.animalTypeIndex }
    end
    return list
end

local function sell(source, list, price, transportPrice, user)
    wallet, LOG = {}, {}
    local sent = {}
    local event = AnimalSellEvent.new(source, list, price, transportPrice)
    event:run(makeConnection(user or "alice", false, sent))
    local paid = 0
    for _, entry in ipairs(wallet) do paid = paid + entry.amount end
    return sent[1] and sent[1].errorCode, paid, #sent
end

permitted = true

-- One real sellable animal: server price minus transport, removed once.
local a = makeAnimal(1000, 40)
local pen = makeSource({ a, makeAnimal(500, 40) })
local code, paid, replies = sell(pen, ids({ a }), 1000, -40)
check("one animal: success", code == AnimalSellEvent.SELL_SUCCESS and replies == 1)
check("one animal: paid server price minus fee", near(paid, 960) and #wallet == 1
    and wallet[1].farmId == 1 and wallet[1].moneyType == MoneyType.SOLD_ANIMALS)
check("one animal: removed once", #pen.system.animals == 1 and pen:getClusterById(key(a)) == nil)
check("one animal: message from server total", pen.messages[1].id == "SOLD_ANIMALS_SINGLE" and pen.messages[1].args[1] == "960.00")

-- Same request again: the animal is gone, nothing is paid twice.
code, paid = sell(pen, ids({ a }), 1000, -40)
check("repeat request: refused", code == AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER)
check("repeat request: no second income", paid == 0 and #wallet == 0 and #pen.system.animals == 1)

-- The client's price never decides the money.
for _, case in ipairs({ { "high", 999999, 0 }, { "low", 1, -5000 }, { "NaN", 0 / 0, 0 },
    { "infinity", math.huge, 0 }, { "minus infinity", -math.huge, 0 }, { "wrong-sign fee", 1000, 40 } }) do
    local b = makeAnimal(1000, 40)
    local source = makeSource({ b })
    code, paid = sell(source, ids({ b }), case[2], case[3])
    check("client price " .. case[1] .. ": server total paid", code == AnimalSellEvent.SELL_SUCCESS and near(paid, 960)
        and #source.system.animals == 0)
end

-- A husbandry sale pays transport even when the client sends none; a trailer at the dealer pays none.
local c = makeAnimal(1000, 40)
local source = makeSource({ c })
code, paid = sell(source, ids({ c }), 1000, 0)
check("pen sale: server applies transport fee", code == AnimalSellEvent.SELL_SUCCESS and near(paid, 960))
local d = makeAnimal(1000, 40)
local trailer = makeSource({ d }, { trailer = true })
code, paid = sell(trailer, ids({ d }), 1000, -40)
check("trailer sale: no transport fee", code == AnimalSellEvent.SELL_SUCCESS and near(paid, 1000)
    and #trailer.system.animals == 0 and #trailer.messages == 0)

-- The audit's counterexample (static-probes.json missing_animal_credit = 1234): now no money.
local e = makeAnimal(1000, 40)
source = makeSource({ e })
code, paid, replies = sell(source, { { farmId = "1", uniqueId = "missing", country = 4 } }, 1234, 0)
check("missing animal: refused with a reply", code == AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER and replies == 1)
check("missing animal: nothing paid or removed", paid == 0 and #wallet == 0 and #source.system.animals == 1
    and source.system.flushes == 0)

code, paid = sell(source, {}, 1234, 0)
check("empty batch: refused, nothing changes", code == AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER and paid == 0
    and #source.system.animals == 1 and source.system.flushes == 0)

code, paid = sell(source, nil, 1234, 0)
check("nil batch: refused, nothing changes", code == AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER and paid == 0
    and #source.system.animals == 1)

code, paid = sell(source, { { farmId = "1", uniqueId = e.uniqueId } }, 1000, 0)
check("unreadable identifiers: refused", code == AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER and paid == 0
    and #source.system.animals == 1)

-- One real and one missing: the real one is not sold first.
local list = ids({ e })
list[2] = { farmId = "1", uniqueId = "missing", country = 4 }
code, paid = sell(source, list, 2000, 0)
check("real + missing: whole batch refused", code == AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER and paid == 0
    and #source.system.animals == 1 and next(source.system.clustersToRemove) == nil)

-- The same animal twice.
local twice = ids({ e })
twice[2] = twice[1]
code, paid = sell(source, twice, 2000, 0)
check("duplicate id: whole batch refused", code == AnimalSellEvent.SELL_ERROR_INVALID_CLUSTER and paid == 0
    and #source.system.animals == 1 and source.system.flushes == 0)

-- The client's view is stale: the server reads the animal as it is now.
local f, g = makeAnimal(1000, 40), makeAnimal(800, 40)
source = makeSource({ f, g })
g.sick = true
code, paid = sell(source, ids({ f, g }), 1800, -80)
check("fell sick since quote: batch refused", code == AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD and paid == 0
    and #source.system.animals == 2)
g.sick, g.canBeSold = false, false
code, paid = sell(source, ids({ f, g }), 1800, -80)
check("no longer sellable: batch refused", code == AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD and paid == 0
    and #source.system.animals == 2)
g.canBeSold = nil
g.price = 900
code, paid = sell(source, ids({ f, g }), 1800, -80)
check("price moved since quote: today's server price paid", code == AnimalSellEvent.SELL_SUCCESS and near(paid, 1820)
    and #source.system.animals == 0)
check("batch message counts removed animals", source.messages[1].id == "SOLD_ANIMALS_MULTIPLE"
    and source.messages[1].args[1] == 2 and source.messages[1].args[2] == "1820.00")

-- A price the server cannot compute refuses the sale; it never falls back to the client's.
for _, case in ipairs({ { "NaN price", 0 / 0, 40 }, { "infinite price", math.huge, 40 }, { "negative price", -5, 40 },
    { "NaN fee", 1000, 0 / 0 }, { "infinite fee", 1000, math.huge }, { "negative fee", 1000, -40 },
    { "nil price", nil, 40 } }) do
    local h = makeAnimal(case[2], case[3])
    source = makeSource({ h })
    code, paid = sell(source, ids({ h }), 1000, -40)
    check("server " .. case[1] .. ": refused, nothing changes", code == AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD
        and paid == 0 and #source.system.animals == 1)
end

-- Another farm's pen, or a player without the trade permission.
local k = makeAnimal(1000, 40)
source = makeSource({ k }, { owner = 2 })
code, paid = sell(source, ids({ k }), 1000, -40, "alice")
check("other farm's source: refused", code == AnimalSellEvent.SELL_ERROR_NO_PERMISSION and paid == 0
    and #source.system.animals == 1)
code, paid = sell(source, ids({ k }), 1000, -40, "bob")
check("owner farm can sell it", code == AnimalSellEvent.SELL_SUCCESS and near(paid, 960) and wallet[1].farmId == 2)

local m = makeAnimal(1000, 40)
source = makeSource({ m })
permitted = false
code, paid = sell(source, ids({ m }), 1000, -40)
check("no trade permission: refused", code == AnimalSellEvent.SELL_ERROR_NO_PERMISSION and paid == 0
    and #source.system.animals == 1)
permitted = true

code, paid, replies = sell(nil, ids({ m }), 1000, -40)
check("source gone: refused with a reply", code == AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST and replies == 1
    and paid == 0)

-- Queueing throws: nothing removed, nothing paid, nothing left queued.
local n1, n2 = makeAnimal(1000, 40), makeAnimal(800, 40)
source = makeSource({ n1, n2 }, { failQueue = true })
code, paid = sell(source, ids({ n1, n2 }), 1800, -80)
check("queue throws: error, nothing paid or removed", code == AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST
    and paid == 0 and #source.system.animals == 2 and next(source.system.clustersToRemove) == nil)

-- The flush throws half way: pay exactly the animals that left, report failure, unqueue the rest.
local p1, p2, p3 = makeAnimal(1000, 40), makeAnimal(800, 40), makeAnimal(600, 40)
source = makeSource({ p1, p2, p3 }, { failAfter = 1 })
code, paid = sell(source, ids({ p1, p2, p3 }), 2400, -120)
local left = #source.system.animals
check("flush throws: no success reported", code == AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST)
check("flush throws: only removed animals paid", left == 2 and #wallet == 1 and near(paid, 560))
check("flush throws: survivors unqueued", next(source.system.clustersToRemove) == nil)
pcall(source.system.updateNow, source.system)
check("flush throws: a later flush removes nothing unpaid", #source.system.animals == 2)
local logged = false
for _, line in ipairs(LOG) do logged = logged or line:find("1 of 3 removed", 1, true) ~= nil end
check("flush throws: logged as partial", logged)

-- Single player: the request carries the client's Animal objects, not wire identifiers.
local q = makeAnimal(1000, 40)
source = makeSource({ q })
code, paid = sell(source, { q }, 5, 0)
check("single player objects: resolved by key, server price paid", code == AnimalSellEvent.SELL_SUCCESS
    and near(paid, 960) and #source.system.animals == 0)

-- The quote alone changes nothing, however often it runs.
local r = makeAnimal(1000, 40)
source = makeSource({ r })
local quote = nil
if AnimalSellEvent.quoteSale ~= nil then
    for _ = 1, 100 do AnimalSellEvent.quoteSale(source, ids({ r }), 1) end
    quote = AnimalSellEvent.quoteSale(source, ids({ r }), 1)
end
check("quote is read-only", quote ~= nil and near(quote.total, 960) and #source.system.animals == 1
    and next(source.system.clustersToRemove) == nil and source.system.flushes == 0)
