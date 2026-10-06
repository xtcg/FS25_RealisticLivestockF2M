-- The herdsman's automatic sale through the real AIAnimalSellEvent, RLHerdsmanExecutor,
-- RLHerdsmanMessages and RLHerdsmanPlanner: the server re-checks and re-prices the planned batch,
-- refuses a bad batch whole, pays sell price plus transport only for animals it removed, and the
-- executor and messages report what was actually sold. The network event never sells.
AnimalSellEvent = { SELL_ERROR_OBJECT_DOES_NOT_EXIST = 5 }
AnimalBuyEvent = { BUY_ERROR_OBJECT_DOES_NOT_EXIST = 1, BUY_ERROR_NOT_ENOUGH_SPACE = 2, BUY_ERROR_NOT_ENOUGH_MONEY = 3 }
MoneyType = { SOLD_ANIMALS = 7, NEW_ANIMALS_COST = 8, HERDSMAN_WAGES = 9 }
-- RLAnimalUtil.lua has Luau syntax plain Lua cannot load; these copy its identity functions.
RLAnimalUtil = {}
function RLAnimalUtil.toKey(farmId, uniqueId, country) return farmId .. " " .. uniqueId .. " " .. country end
function RLAnimalUtil.find(animals, farmId, uniqueId, country)
    for _, animal in pairs(animals) do
        if animal.farmId == farmId and animal.uniqueId == uniqueId and animal.birthday.country == country then return animal end
    end
    return nil
end
local wireQueue = {}
function RLAnimalUtil.readStreamIdentifiers() return table.remove(wireQueue, 1) end
NetworkUtil = { readNodeObject = function() return table.remove(wireQueue, 1) end }
streamReadUInt16 = function() return table.remove(wireQueue, 1) end
streamReadFloat32 = function() return table.remove(wireQueue, 1) end

local marks = {}
AnimalMarkEvent = { new = function(placeable, animal, key, value) return { mark = key, animal = animal } end }

loadMod("scripts/disease/RLDiseaseSaleGate.lua")
loadMod("scripts/animals/shop/events/AIAnimalSellEvent.lua")
loadMod("scripts/animals/shop/events/AIAnimalBuyEvent.lua")
loadMod("scripts/herdsman/RLHerdsmanRuleService.lua")
loadMod("scripts/filters/RLFilterEvaluator.lua")
loadMod("scripts/herdsman/RLHerdsmanPlanner.lua")
loadMod("scripts/herdsman/RLHerdsmanExecutor.lua")
loadMod("scripts/herdsman/RLHerdsmanMessages.lua")

RLHusbandryProfiles = { checkAnimal = function() return true end }

local wallet, balance, failAddMoney
local mission = {
    addMoney = function(_, amount, farmId, moneyType)
        wallet[#wallet + 1] = { amount = amount, farmId = farmId, moneyType = moneyType }
        if failAddMoney and moneyType == MoneyType.SOLD_ANIMALS then error("addMoney boom") end
        balance[farmId] = (balance[farmId] or 0) + amount
    end,
    getMoney = function(_, farmId) return balance[farmId] or 0 end,
}
g_currentMission = mission

local broadcasts = {}
local server = { broadcastEvent = function(_, event) broadcasts[#broadcasts + 1] = event end }
local saleCtx = { server = server, mission = mission }

local function reset()
    wallet, broadcasts, LOG, failAddMoney = {}, {}, {}, false
    balance = { [1] = 0, [2] = 0 }
end

local function paidOf(moneyType)
    local total, n = 0, 0
    for _, entry in ipairs(wallet) do
        if entry.moneyType == moneyType then total, n = total + entry.amount, n + 1 end
    end
    return total, n
end

local nextId = 0
local function makeAnimal(price, fee, opts)
    opts = opts or {}
    nextId = nextId + 1
    return {
        farmId = "1", uniqueId = tostring(nextId), birthday = { country = 4 }, animalTypeIndex = 1, subTypeIndex = 1, age = 20,
        price = price, fee = fee, sick = opts.sick, canBeSold = opts.canBeSold, marked = {},
        getCanBeSold = function(self) return self.canBeSold ~= false end,
        getHasAnyDisease = function(self) return self.sick == true end,
        getSellPrice = function(self) return self.price end,
        getTranportationFee = function(self, factor) return self.fee * factor end,
        setMarked = function(self, key, value) self.marked[key] = value end,
    }
end

local function key(animal) return RLAnimalUtil.toKey(animal.farmId, animal.uniqueId, animal.birthday.country) end

-- A pen with the engine's queue-then-flush removal. failAfter: the flush throws after removing that
-- many; failQueue: queueing throws; keep: the flush silently leaves that animal; failListAfterFlush:
-- getClusters throws once a flush has run.
local function makePen(animals, opts)
    opts = opts or {}
    local pen = { ownerFarmId = opts.owner or 1, freeSlots = opts.freeSlots or 10, messages = {}, added = {} }
    local system = { animals = animals, clustersToRemove = {}, flushes = 0 }
    function system:getClusters()
        if opts.failListAfterFlush and self.flushes > 0 then error("list boom") end
        return self.animals
    end
    function system:addPendingRemoveCluster(cluster)
        if opts.failQueue then error("queue boom") end
        self.clustersToRemove[cluster] = true
        self.queued = (self.queued or 0) + 1
        if opts.failQueueAfter ~= nil and self.queued > opts.failQueueAfter then error("queue boom after " .. opts.failQueueAfter) end
    end
    function system:updateNow()
        self.flushes = self.flushes + 1
        local removedNow = 0
        for i = #self.animals, 1, -1 do
            local animal = self.animals[i]
            if self.clustersToRemove[animal] and animal ~= opts.keep then
                if opts.failAfter ~= nil and removedNow >= opts.failAfter then error("flush boom") end
                table.remove(self.animals, i)
                self.clustersToRemove[animal] = nil
                removedNow = removedNow + 1
            end
        end
        if opts.failAfter == nil then self.clustersToRemove = {} end
    end
    pen.system = system
    function pen:getClusterSystem() return self.system end
    function pen:getClusters() return self.system.animals end
    function pen:getOwnerFarmId() return self.ownerFarmId end
    function pen:getNumOfFreeAnimalSlots() return self.freeSlots end
    function pen:addAnimals(list) for _, a in ipairs(list) do self.added[#self.added + 1] = a end end
    function pen:addRLMessage(id, _, args) self.messages[#self.messages + 1] = { id = id, args = args } end
    return pen
end

local function ids(animals)
    local list = {}
    for i, a in ipairs(animals) do
        list[i] = { farmId = a.farmId, uniqueId = a.uniqueId, country = a.birthday.country,
            birthday = { country = a.birthday.country }, animalTypeIndex = a.animalTypeIndex }
    end
    return list
end

local function sum(animals)
    local total = 0
    for _, a in ipairs(animals) do total = total + a.price + a.fee end
    return total
end

local function sellNow(pen, list, ...)
    reset()
    local seller = 1
    if select("#", ...) > 0 then seller = ... end
    return AIAnimalSellEvent.executeServer(pen, list, seller, saleCtx)
end

-- ---------------------------------------------------------------------------------------------
-- executeServer
-- ---------------------------------------------------------------------------------------------

local a1 = makeAnimal(1000, 40)
local pen = makePen({ a1, makeAnimal(500, 40) })
local r = sellNow(pen, ids({ a1 }))
check("one animal: sold", r.status == AIAnimalSellEvent.STATUS_SOLD and r.requestedCount == 1 and r.removedCount == 1
    and r.settledCount == 1 and r.failureStage == nil)
check("one animal: paid sell price plus transport to the seller", near(r.amountGained, 1040) and #wallet == 1
    and near(wallet[1].amount, 1040) and wallet[1].farmId == 1 and wallet[1].moneyType == MoneyType.SOLD_ANIMALS)
check("one animal: removed, the other stays", #pen.system.animals == 1 and pen.system.animals[1] ~= a1)

local m1, m2, m3 = makeAnimal(1000, 40), makeAnimal(800, 30), makeAnimal(600, 20)
pen = makePen({ m1, m2, m3 })
r = sellNow(pen, ids({ m1, m2, m3 }))
check("three animals: sold, paid per-head sum", r.status == AIAnimalSellEvent.STATUS_SOLD and r.settledCount == 3
    and near(r.amountGained, 2490) and #wallet == 1 and #pen.system.animals == 0)

-- The same frozen plan again: nothing to sell, nothing paid twice.
r = sellNow(pen, ids({ m1, m2, m3 }))
check("repeat old plan: refused, no second payment", r.status == AIAnimalSellEvent.STATUS_REFUSED
    and r.failureStage == "identity" and #wallet == 0 and pen.system.flushes == 1)

-- Whole-batch refusals: nothing queued, flushed, removed or paid.
local function refusedClean(name, pen, r, stage, count)
    check(name .. ": refused at " .. stage, r.status == AIAnimalSellEvent.STATUS_REFUSED and r.failureStage == stage
        and r.settledCount == 0 and r.amountGained == 0 and r.removedCount == 0)
    check(name .. ": nothing changed", #wallet == 0 and #pen.system.animals == count and pen.system.flushes == 0
        and next(pen.system.clustersToRemove) == nil)
end

local b1, b2 = makeAnimal(1000, 40), makeAnimal(800, 40)
pen = makePen({ b1, b2 })
local list = ids({ b1 })
list[2] = { farmId = "1", uniqueId = "missing", country = 4, birthday = { country = 4 } }
refusedClean("real + missing", pen, sellNow(pen, list), "identity", 2)

list = ids({ b1, b1 })
refusedClean("duplicate", pen, sellNow(pen, list), "identity", 2)

refusedClean("no country", pen, sellNow(pen, { { farmId = "1", uniqueId = b1.uniqueId } }), "identity", 2)
refusedClean("non-table identity", pen, sellNow(pen, { "1 1 4" }), "identity", 2)
refusedClean("empty batch", pen, sellNow(pen, {}), "identity", 2)
list = ids({ b1, b2 })
list[2] = nil
list[3] = ids({ b2 })[1]
r = sellNow(pen, list)
refusedClean("identity list with a hole", pen, r, "identity", 2)
check("identity list with a hole: not sold as its prefix", pen.system.animals[1] == b1)
list = ids({ b1 })
list.extra = ids({ b2 })[1]
refusedClean("identity list with a non-index key", pen, sellNow(pen, list), "identity", 2)
list = ids({ b1 })
list[1.5] = ids({ b2 })[1]
refusedClean("identity list with a fractional key", pen, sellNow(pen, list), "identity", 2)
refusedClean("nil batch", pen, sellNow(pen, nil), "identity", 2)

local other = makeAnimal(5000, 40)
local otherPen = makePen({ other })
list = ids({ b1, other })
refusedClean("animal from another pen", pen, sellNow(pen, list), "identity", 2)

-- The pen changed owner after the plan: the old plan never sells, to either farm.
pen.ownerFarmId = 2
refusedClean("pen changed owner", pen, sellNow(pen, ids({ b1 }), 1), "ownership", 2)
pen.ownerFarmId = 1
refusedClean("no seller farm", pen, sellNow(pen, ids({ b1 }), nil), "ownership", 2)
refusedClean("no source", makePen({}), sellNow(nil, ids({ b1 })), "source", 0)

b2.sick = true
refusedClean("fell sick since the plan", pen, sellNow(pen, ids({ b1, b2 })), "animal", 2)
b2.sick, b2.canBeSold = false, false
refusedClean("no longer sellable", pen, sellNow(pen, ids({ b1, b2 })), "animal", 2)
b2.canBeSold = nil

for _, case in ipairs({ { "NaN price", 0 / 0, 40 }, { "infinite price", math.huge, 40 }, { "negative price", -5, 40 },
    { "nil price", nil, 40 }, { "NaN fee", 1000, 0 / 0 }, { "infinite fee", 1000, math.huge }, { "negative fee", 1000, -40 },
    { "string price", "1000", 40 } }) do
    local h = makeAnimal(case[2], case[3])
    local p = makePen({ h })
    refusedClean("server " .. case[1], p, sellNow(p, ids({ h })), "price", 1)
end
for _, method in ipairs({ "getSellPrice", "getTranportationFee", "getCanBeSold" }) do
    local h = makeAnimal(1000, 40)
    h[method] = function() error(method .. " boom") end
    local p = makePen({ h })
    refusedClean(method .. " throws", p, sellNow(p, ids({ h })), "price", 1)
end
local big1, big2 = makeAnimal(1.7e308, 0), makeAnimal(1.7e308, 0)
local bigPen = makePen({ big1, big2 })
refusedClean("batch total overflows", bigPen, sellNow(bigPen, ids({ big1, big2 })), "price", 2)

-- Other removals already queued: this sale would flush them unpaid or mixed in, so it waits.
local q1, q2, queuedElsewhere = makeAnimal(1000, 40), makeAnimal(800, 40), makeAnimal(700, 40)
pen = makePen({ q1, q2, queuedElsewhere })
pen.system.clustersToRemove[queuedElsewhere] = true
r = sellNow(pen, ids({ q1 }))
check("pending removals: refused", r.status == AIAnimalSellEvent.STATUS_REFUSED and r.failureStage == "pending" and #wallet == 0)
check("pending removals: other queue untouched, nothing flushed", pen.system.clustersToRemove[queuedElsewhere] == true
    and pen.system.clustersToRemove[q1] == nil and pen.system.flushes == 0 and #pen.system.animals == 3)

-- A queued key with a false value is still removed by the flush (it removes on ~= nil).
local pf1, pf2 = makeAnimal(1000, 40), makeAnimal(700, 40)
pen = makePen({ pf1, pf2 })
pen.system.clustersToRemove[pf2] = false
r = sellNow(pen, ids({ pf1 }))
check("pending key with false value: refused", r.status == AIAnimalSellEvent.STATUS_REFUSED and r.failureStage == "pending"
    and #wallet == 0 and pen.system.flushes == 0 and #pen.system.animals == 2 and pen.system.clustersToRemove[pf2] == false)

-- The price moved since the plan: today's price is paid, the planned amount never is.
local c1 = makeAnimal(1000, 40)
pen = makePen({ c1 })
c1.price = 1200
r = sellNow(pen, ids({ c1 }))
check("price moved: today's price paid", r.status == AIAnimalSellEvent.STATUS_SOLD and near(r.amountGained, 1240)
    and near(paidOf(MoneyType.SOLD_ANIMALS), 1240))

-- The transport fee moved since the plan: today's fee is paid.
local tf1 = makeAnimal(1000, 40)
pen = makePen({ tf1 })
tf1.fee = 75
r = sellNow(pen, ids({ tf1 }))
check("transport fee moved: today's fee paid", r.status == AIAnimalSellEvent.STATUS_SOLD and near(r.amountGained, 1075)
    and near(paidOf(MoneyType.SOLD_ANIMALS), 1075))

-- Queueing throws after some animals were queued: no flush, nothing removed or paid, the queued
-- part taken off the queue.
local fq1, fq2, fq3 = makeAnimal(1000, 40), makeAnimal(800, 40), makeAnimal(600, 40)
pen = makePen({ fq1, fq2, fq3 }, { failQueueAfter = 1 })
r = sellNow(pen, ids({ fq1, fq2, fq3 }))
check("queue throws part way: failed at queue", r.status == AIAnimalSellEvent.STATUS_FAILED and r.failureStage == "queue"
    and r.removedCount == 0 and r.settledCount == 0 and r.amountGained == 0)
check("queue throws part way: no flush, no money, queue cleared", pen.system.queued == 2 and pen.system.flushes == 0
    and #wallet == 0 and #pen.system.animals == 3 and next(pen.system.clustersToRemove) == nil)
pen.system.updateNow(pen.system)
check("queue throws part way: a later flush removes nothing", #pen.system.animals == 3)

-- Queueing throws: no flush, nothing removed or paid, nothing left queued.
local f1, f2 = makeAnimal(1000, 40), makeAnimal(800, 40)
pen = makePen({ f1, f2 }, { failQueue = true })
r = sellNow(pen, ids({ f1, f2 }))
check("queue throws: failed at queue", r.status == AIAnimalSellEvent.STATUS_FAILED and r.failureStage == "queue"
    and r.removedCount == 0 and r.settledCount == 0 and r.amountGained == 0)
check("queue throws: no flush, no money", pen.system.flushes == 0 and #wallet == 0 and #pen.system.animals == 2
    and next(pen.system.clustersToRemove) == nil)

-- The flush throws half way: pay each removed animal its own price, not an average.
local p1, p2, p3 = makeAnimal(3000, 40), makeAnimal(800, 30), makeAnimal(100, 20)
pen = makePen({ p1, p2, p3 }, { failAfter = 1 })
r = sellNow(pen, ids({ p1, p2, p3 }))
-- The flush walks from the end, so the cheapest animal (p3) leaves first.
check("flush throws: partial", r.status == AIAnimalSellEvent.STATUS_PARTIAL and r.failureStage == "flush"
    and r.removedCount == 1 and r.settledCount == 1)
check("flush throws: removed animal's own price paid", near(r.amountGained, 120) and #wallet == 1 and near(wallet[1].amount, 120)
    and pen.system.animals[1] == p1 and pen.system.animals[2] == p2)
check("flush throws: survivors unqueued", next(pen.system.clustersToRemove) == nil)
pcall(pen.system.updateNow, pen.system)
check("flush throws: a later flush removes nothing unpaid", #pen.system.animals == 2)

-- The flush quietly keeps one animal.
local k1, k2 = makeAnimal(1000, 40), makeAnimal(800, 40)
pen = makePen({ k1, k2 }, { keep = k2 })
pen.system.updateNow = function(self)
    self.flushes = self.flushes + 1
    for i = #self.animals, 1, -1 do
        if self.clustersToRemove[self.animals[i]] and self.animals[i] ~= k2 then table.remove(self.animals, i) end
    end
    self.clustersToRemove[k1] = nil
end
r = sellNow(pen, ids({ k1, k2 }))
check("animal kept by the flush: partial at removal", r.status == AIAnimalSellEvent.STATUS_PARTIAL and r.failureStage == "removal"
    and r.settledCount == 1 and near(r.amountGained, 1040))
check("animal kept by the flush: its queue entry cleared", pen.system.clustersToRemove[k2] == nil and #pen.system.animals == 1)

-- The source list cannot be read after the flush: unknown removal, nothing paid, no retry.
local v1 = makeAnimal(1000, 40)
pen = makePen({ v1 }, { failListAfterFlush = true })
r = sellNow(pen, ids({ v1 }))
check("list unreadable: failed at verify, removal unknown", r.status == AIAnimalSellEvent.STATUS_FAILED
    and r.failureStage == "verify" and r.removedCount == nil and r.settledCount == 0 and r.amountGained == 0)
check("list unreadable: no payment, one flush", #wallet == 0 and pen.system.flushes == 1)

-- addMoney throws: it may have paid, so the settlement is unknown, and it is not called again.
local w1, w2 = makeAnimal(1000, 40), makeAnimal(800, 40)
pen = makePen({ w1, w2 })
reset()
failAddMoney = true
r = AIAnimalSellEvent.executeServer(pen, ids({ w1, w2 }), 1, saleCtx)
check("payment throws: failed at payment, settlement unknown", r.status == AIAnimalSellEvent.STATUS_FAILED
    and r.failureStage == "payment" and r.removedCount == 2 and r.settledCount == nil and r.amountGained == nil)
check("payment throws: addMoney called once, no retry", #wallet == 1 and pen.system.flushes == 1)

-- Not on the server.
reset()
r = AIAnimalSellEvent.executeServer(makePen({ makeAnimal(1, 1) }), ids({ makeAnimal(1, 1) }), 1, { mission = mission })
check("no server: refused", r.status == AIAnimalSellEvent.STATUS_REFUSED and r.failureStage == "server" and #wallet == 0)

-- ---------------------------------------------------------------------------------------------
-- The network event never sells
-- ---------------------------------------------------------------------------------------------

local n1 = makeAnimal(1000, 40)
pen = makePen({ n1 })
for _, case in ipairs({ { "from a client", makeConnection("alice", false) }, { "from the server", makeConnection(nil, true) } }) do
    reset()
    wireQueue = { pen, 1, ids({ n1 })[1], 99999 }
    local event = AIAnimalSellEvent.emptyNew()
    event:readStream(1, case[2])
    check("network event " .. case[1] .. ": parsed", event.object == pen and #event.animals == 1 and event.price == 99999)
    check("network event " .. case[1] .. ": nothing removed or paid", #wallet == 0 and #pen.system.animals == 1
        and pen.system.flushes == 0 and next(pen.system.clustersToRemove) == nil)
end
reset()
AIAnimalSellEvent.new(pen, { n1 }, 99999):run()
check("local event run: nothing removed or paid", #wallet == 0 and #pen.system.animals == 1 and pen.system.flushes == 0)

-- ---------------------------------------------------------------------------------------------
-- Executor and messages
-- ---------------------------------------------------------------------------------------------

local function execCtx(placeables)
    return { server = server, mission = mission, husbandryPlaceablesById = placeables, ruleService = {},
        animalNameSystem = {}, defer = function() end }
end

local function sellAction(animals, opts)
    opts = opts or {}
    local action = { ruleId = "r1", operation = "sell", husbandryId = "pen1", animals = animals, mark = opts.mark == true,
        wage = opts.wage or 50, amountGained = opts.amountGained or sum(animals) }
    if not opts.mark then
        action.sellerFarmId = opts.seller == nil and 1 or opts.seller
        if opts.seller == false then action.sellerFarmId = nil end
        action.identities = opts.identities or ids(animals)
    end
    return action
end

local function runPlan(plan, placeables)
    reset()
    local summary = RLHerdsmanExecutor.executeActions(plan, execCtx(placeables))
    local built = RLHerdsmanMessages.buildMessages(summary.results, function(v) return string.format("%.2f", v) end)
    return summary, built
end

local function sentSellEvent()
    for _, event in ipairs(broadcasts) do
        if getmetatable(event) ~= nil and getmetatable(event).__index == AIAnimalSellEvent then return true end
    end
    return false
end

-- A normal sale: the row and the message carry the server's count and money; the wage is unchanged.
local e1, e2 = makeAnimal(1000, 40), makeAnimal(800, 40)
pen = makePen({ e1, e2 })
local summary, built = runPlan({ sellAction({ e1, e2 }, { amountGained = 1 }) }, { pen1 = pen })
local row = summary.results[1]
check("executor sale: dispatched with the server's figures", row.dispatched == true and row.count == 2
    and near(row.amountGained, 1880) and row.saleStatus == "sold" and row.plannedAmountGained == 1 and row.plannedCount == 2)
check("executor sale: proceeds and wage", near(paidOf(MoneyType.SOLD_ANIMALS), 1880) and near(paidOf(MoneyType.HERDSMAN_WAGES), -50)
    and summary.wageByFarm[1] == 50)
check("executor sale: no AI sell event broadcast", not sentSellEvent())
check("executor sale: message with actual figures", #built.records == 1 and built.records[1].id == "AI_MANAGER_SOLD_MULTIPLE"
    and built.records[1].args[1] == "2" and built.records[1].args[2] == "1880.00")

-- A partial sale: the message reports what was sold, the wage stays the planned wage.
local g1, g2, g3 = makeAnimal(3000, 40), makeAnimal(800, 30), makeAnimal(100, 20)
pen = makePen({ g1, g2, g3 }, { failAfter = 1 })
summary, built = runPlan({ sellAction({ g1, g2, g3 }, { wage = 90 }) }, { pen1 = pen })
row = summary.results[1]
check("executor partial: row reports the one sold", row.dispatched == true and row.count == 1 and near(row.amountGained, 120)
    and row.saleStatus == "partial" and row.failureStage == "flush" and row.skipReason == nil)
check("executor partial: wage not scaled", summary.wageByFarm[1] == 90)
check("executor partial: single message for the one sold", #built.records == 1 and built.records[1].id == "AI_MANAGER_SOLD_SINGLE"
    and built.records[1].args[1] == "120.00")

-- A refused sale: no message, no money, wage charged as for any other runtime rejection.
local h1 = makeAnimal(1000, 40)
pen = makePen({ h1 })
h1.sick = true
summary, built = runPlan({ sellAction({ h1 }) }, { pen1 = pen })
row = summary.results[1]
check("executor refused: not dispatched", row.dispatched == false and row.skipReason == "sale-refused" and row.count == 0
    and row.amountGained == 0 and row.failureStage == "animal")
check("executor refused: no proceeds, no message, wage charged", paidOf(MoneyType.SOLD_ANIMALS) == 0 and #built.records == 0
    and summary.wageByFarm[1] == 50)
h1.sick = false

-- Payment outcome unknown: never announced as a sale.
local j1 = makeAnimal(1000, 40)
pen = makePen({ j1 })
reset()
failAddMoney = true
summary = RLHerdsmanExecutor.executeActions({ sellAction({ j1 }) }, execCtx({ pen1 = pen }))
failAddMoney = false
built = RLHerdsmanMessages.buildMessages(summary.results, function(v) return string.format("%.2f", v) end)
row = summary.results[1]
check("executor payment unknown: not reported as sold", row.dispatched == false and row.skipReason == "sale-failed"
    and row.amountGained == nil and row.settledCount == nil and row.saleStatus == "failed" and #built.records == 0)
local _, sales = paidOf(MoneyType.SOLD_ANIMALS)
check("executor payment unknown: one attempt only", sales == 1)

-- The plan was made for farm 1, the pen now belongs to farm 2: no sale and no wage to either.
local o1 = makeAnimal(1000, 40)
pen = makePen({ o1 }, { owner = 2 })
summary = runPlan({ sellAction({ o1 }) }, { pen1 = pen })
row = summary.results[1]
check("executor owner changed: skipped without wage", row.dispatched == false and row.skipReason == "owner-changed"
    and #wallet == 0 and next(summary.wageByFarm) == nil and #pen.system.animals == 1)

-- A plan without the frozen snapshot is never sold on the live objects.
summary = runPlan({ sellAction({ o1 }, { seller = false }) }, { pen1 = makePen({ o1 }) })
check("executor no seller snapshot: bad-data, no wage", summary.results[1].skipReason == "bad-data" and #wallet == 0)
local short = sellAction({ o1 })
short.identities = {}
summary = runPlan({ short }, { pen1 = makePen({ o1 }) })
check("executor identities missing: bad-data, no wage", summary.results[1].skipReason == "bad-data" and #wallet == 0)
local hole1, hole2 = makeAnimal(1000, 40), makeAnimal(800, 40)
pen = makePen({ hole1, hole2 })
local holed = sellAction({ hole1, hole2 })
holed.identities = { ids({ hole1 })[1], nil, ids({ hole2 })[1] }
holed.animals = { hole1, nil, hole2 }
summary = runPlan({ holed }, { pen1 = pen })
check("executor identity list with a hole: nothing sold", summary.results[1].dispatched == false
    and paidOf(MoneyType.SOLD_ANIMALS) == 0 and #pen.system.animals == 2)

-- The frozen identities decide, not the live objects the plan holds.
local s1, s2 = makeAnimal(1000, 40), makeAnimal(800, 40)
pen = makePen({ s1, s2 })
local action = sellAction({ s1 })
s1.uniqueId = "renamed"
summary = runPlan({ action }, { pen1 = pen })
check("executor identity changed since plan: refused", summary.results[1].skipReason == "sale-refused" and #pen.system.animals == 2)
s1.uniqueId = "s1-restored"

-- A failed sale does not fund a later buy: the buy still checks the real wallet and space.
local t1 = makeAnimal(1000, 40)
pen = makePen({ t1 })
t1.sick = true
local dealerCow = makeAnimal(900, 40)
local buy = { ruleId = "r2", operation = "buy", husbandryId = "pen1", animals = { dealerCow }, amountSpent = 940, wage = 20 }
summary = runPlan({ sellAction({ t1 }), buy }, { pen1 = pen })
check("failed sale, then buy: buy refused for money", summary.results[1].skipReason == "sale-refused"
    and summary.results[2].skipReason == "no-money" and #pen.added == 0)
t1.sick = false
local fullPen = makePen({ makeAnimal(1000, 40) }, { freeSlots = 0 })
fullPen.system.animals[1].sick = true
reset()
balance[1] = 1e6
summary = RLHerdsmanExecutor.executeActions({ sellAction(fullPen.system.animals), buy }, execCtx({ pen1 = fullPen }))
check("failed sale, then buy: buy refused for space", summary.results[2].skipReason == "no-space" and #fullPen.added == 0)

-- Mark mode is unchanged: it marks, sells nothing and charges the mark wage.
local x1 = makeAnimal(1000, 40)
pen = makePen({ x1 })
summary, built = runPlan({ sellAction({ x1 }, { mark = true, wage = 10 }) }, { pen1 = pen })
row = summary.results[1]
check("mark mode: marked, not sold", x1.marked.AI_MANAGER_SELL == true and row.skipReason == "mark-mode" and row.count == 1
    and #pen.system.animals == 1 and paidOf(MoneyType.SOLD_ANIMALS) == 0)
check("mark mode: wage and message", summary.wageByFarm[1] == 10 and built.records[1].id == "AI_MANAGER_MARK_SELL_SINGLE")

-- ---------------------------------------------------------------------------------------------
-- Planner snapshot
-- ---------------------------------------------------------------------------------------------

RLFilterEvaluator.evaluate = function() return true end
RLHerdsmanPlanner._resolveAnimalTypeIndexMap = function() return {} end
local y1, y2 = makeAnimal(1000, 40), makeAnimal(800, 40)
local plan = RLHerdsmanPlanner.planActions(
    { { id = "r1", farmId = 1, operation = "sell", enabled = true, filterId = "f", targetHusbandries = { "pen1" },
        params = { maxAnimals = 5 } } },
    { husbandries = { pen1 = { animalTypeIndex = 1, animals = { y1, y2 }, freeSlots = 0 } }, filtersById = { f = {} },
      animalSystem = { getAnimalTransportFee = function() return 40 end }, farmBalanceByFarmId = { [1] = 0 }, buyMarkup = 1 })
local planned = plan[1]
local y1Copy
for _, identity in ipairs(planned and planned.identities or {}) do
    if identity.uniqueId == y1.uniqueId then y1Copy = identity end
end
check("planner: sell carries seller farm and identity copies", planned ~= nil and planned.sellerFarmId == 1
    and #planned.identities == 2 and planned.identities[1] ~= planned.animals[1]
    and planned.identities[1].uniqueId == planned.animals[1].uniqueId and planned.identities[1].country == 4
    and planned.identities[1].birthday.country == 4 and near(planned.amountGained, 1880))
local y1Original = y1.uniqueId
y1.uniqueId = "changed-later"
y1.birthday.country = 9
check("planner: the changed animal's own copy is frozen", y1Copy ~= nil and y1Copy.uniqueId == y1Original
    and y1Copy.country == 4 and y1Copy.birthday.country == 4 and y1Copy.farmId == "1")
y1.birthday.country = 4

-- Planned and executed end to end.
y1.uniqueId = "y1"
pen = makePen({ y1, y2 })
plan = RLHerdsmanPlanner.planActions(
    { { id = "r1", farmId = 1, operation = "sell", enabled = true, filterId = "f", targetHusbandries = { "pen1" },
        params = { maxAnimals = 5 } } },
    { husbandries = { pen1 = { animalTypeIndex = 1, animals = { y1, y2 }, freeSlots = 0 } }, filtersById = { f = {} },
      animalSystem = { getAnimalTransportFee = function() return 40 end }, farmBalanceByFarmId = { [1] = 0 }, buyMarkup = 1 })
summary = runPlan(plan, { pen1 = pen })
check("planned and executed: both sold for price plus transport", summary.results[1].count == 2
    and near(paidOf(MoneyType.SOLD_ANIMALS), 1880) and #pen.system.animals == 0)
local markPlan = RLHerdsmanPlanner.planActions(
    { { id = "r1", farmId = 1, operation = "sell", enabled = true, filterId = "f", targetHusbandries = { "pen1" },
        params = { maxAnimals = 5, mark = true } } },
    { husbandries = { pen1 = { animalTypeIndex = 1, animals = { makeAnimal(1, 1) }, freeSlots = 0 } }, filtersById = { f = {} },
      animalSystem = { getAnimalTransportFee = function() return 40 end }, farmBalanceByFarmId = { [1] = 0 }, buyMarkup = 1 })
check("planner: marked sell carries no sale snapshot", markPlan[1].mark == true and markPlan[1].sellerFarmId == nil
    and markPlan[1].identities == nil and markPlan[1].amountGained == nil)
