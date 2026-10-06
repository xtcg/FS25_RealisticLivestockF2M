-- T02 batch 2 (PR #32): a batch of animals to Hof Bergmann's public slaughterhouse as one server
-- transaction (RLContractTrade, RLHBContractAdapter, RLTradeSourceAdapter).
--
-- Real code under test: the HB deliver (tests/fixtures/hb_contract_delivery.lua, exact excerpt),
-- the base game's cluster queue (tests/fixtures/fs25_cluster_queue.lua, exact excerpt), RLRM's
-- cluster system (scripts/animals/husbandry/cluster, loaded through tests/fixtures/giants_lua.lua),
-- Animal:setClusterSystem / getNumAnimals, RLDiseaseSaleGate, the quote, the plan and the
-- coordinator. Engine stand-ins, marked below: farm money (FS25 Farm:changeBalance arithmetic),
-- the pen's visual animals, events and messages. They are no proof of the engine's visuals,
-- network sync or saving. Case ids follow docs/T02_TEST_WORKFLOW.md (A, B, C groups).

AnimalMoveEvent = { MOVE_SUCCESS = 0, MOVE_ERROR_NO_PERMISSION = 1, MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST = 2,
    MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST = 3, MOVE_ERROR_INVALID_CLUSTER = 4, MOVE_ERROR_ANIMAL_NOT_SUPPORTED = 5,
    MOVE_ERROR_NOT_ENOUGH_SPACE = 6 }
loadMod("tests/fixtures/hb_beta2.lua")
loadMod("tests/fixtures/hb_contract_delivery.lua")
loadMod("tests/fixtures/giants_lua.lua")

-- Animal types and subtypes ------------------------------------------------------------------
TYPES = { [1] = { name = "COW" }, [2] = { name = "PIG" }, [3] = { name = "SHEEP" }, [4] = { name = "MILKCOW" } }
SUBS = {
    [1] = { typeIndex = 1, typeName = "COW", targetWeight = 1100, name = "BULL_HOLSTEIN", breed = "HOLSTEIN", gender = "male" },
    [2] = { typeIndex = 1, typeName = "COW", targetWeight = 1000, name = "BULL_ANGUS", breed = "ANGUS", gender = "male" },
    [3] = { typeIndex = 2, typeName = "PIG", targetWeight = 300, name = "BOAR_LANDRACE", breed = "LANDRACE", gender = "male" },
    [4] = { typeIndex = 4, typeName = "MILKCOW", targetWeight = 700, name = "MILKCOW_HOLSTEIN", breed = "HOLSTEIN", gender = "female" },
}
local HOLSTEIN, ANGUS, BOAR, MILKCOW = 1, 2, 3, 4

-- Engine stand-in: farm money as FS25 Farm:changeBalance keeps it (money, finance statistic, money earned).
MoneyType = { PRODUCTION_COSTS = { id = 7, statistic = "productionCosts" } }
FARMS = {}
local moneyFault, moneyExtra, moneyUnreadable = nil, 0, false
local function setFarm(id, money) FARMS[id] = { money = money, stats = { productionCosts = 0 }, earned = 0 } end
g_currentMission = {
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    getIsServer = function() return true end,
    getFarmId = function() return 1 end,
    accessHandler = { canFarmAccess = function() return true end },
    getMoney = function(_, farmId)
        if moneyUnreadable then error("money unreadable") end
        return FARMS[farmId] ~= nil and FARMS[farmId].money or 0
    end,
    addMoney = function(_, amount, farmId, moneyType)
        if moneyFault == "before" then moneyFault = nil error("addMoney failed before the change") end
        local farm = FARMS[farmId]
        farm.money = farm.money + amount
        farm.stats[moneyType.statistic] = (farm.stats[moneyType.statistic] or 0) + amount
        if amount > 0 then farm.earned = farm.earned + amount end
        -- A MONEY_CHANGED listener of another mod that moves money too.
        if moneyExtra ~= 0 then farm.money = farm.money + moneyExtra moneyExtra = 0 end
        if moneyFault == "after" then moneyFault = nil error("addMoney failed after the change") end
    end,
}
g_modManager = { getModByName = function(_, name) return name == "FS25_HofBergmann" and { version = "1.5.0.0 Beta2" } or nil end }
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) return HB.FILLTYPES[name] end,
    getFillTypeNameByIndex = function(_, index) return HB.FILLTYPE_NAMES[index] end }
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

-- Engine stand-ins for what the cluster flush calls.
string.contains = function(text, part) return text:find(part, 1, true) ~= nil end
getTimeSec = os.clock
BROADCASTS, PUBLISHED, REMOVED_VISUALS = 0, 0, {}
g_server = { netIsRunning = true, broadcastEvent = function() BROADCASTS = BROADCASTS + 1 end }
local publishHook
g_messageCenter = { publish = function(_, ...) PUBLISHED = PUBLISHED + 1 if publishHook ~= nil then publishHook(...) end end }
AnimalClusterUpdateEvent = { new = function(owner, animals) return { owner = owner, count = #animals } end }
removeHusbandryAnimal = function(husbandryId, animalId) REMOVED_VISUALS[#REMOVED_VISUALS + 1] = husbandryId .. "-" .. animalId end
RLAnimalUtil = {
    toKey = function(farmId, uniqueId, country) return farmId .. " " .. uniqueId .. " " .. country end,
    toShortKey = function(farmId, uniqueId) return farmId .. " " .. uniqueId end,
}

loadMod("tests/fixtures/fs25_cluster_queue.lua")
loadGiantsMod("scripts/animals/husbandry/cluster/RealisticLivestock_AnimalClusterSystem.lua")
loadAnimalSection("function Animal:setClusterSystem", "function Animal:getSupportsMerging")
loadAnimalSection("function Animal:getNumAnimals", "function Animal:getSubTypeIndex")
-- Disease stand-in: Animal:getHasAnyDisease reads the animal's diseases in the mod.
function Animal:getHasAnyDisease() return self.sick == true end

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadMod("scripts/disease/RLDiseaseSaleGate.lua")
loadMod("scripts/animal/RLTradeQuote.lua")
loadMod("scripts/animal/RLContractPlan.lua")
loadMod("scripts/animal/RLTradeTransaction.lua")
loadMod("scripts/animal/RLHBContractAdapter.lua")
loadMod("scripts/animal/RLTradeSourceAdapter.lua")
loadMod("scripts/animal/RLContractTrade.lua")

local CT = RLContractTrade
local BEEF = HB.FILLTYPES.BEEF

local function has(text, part) return type(text) == "string" and text:find(part, 1, true) ~= nil end

-- World --------------------------------------------------------------------------------------

local serial = 0
local function animal(sub, fields)
    serial = serial + 1
    local a = setmetatable({ isIndividual = true, numAnimals = 1, farmId = "1001", uniqueId = tostring(10000 + serial),
        birthday = { country = 1, day = 3 }, subTypeIndex = sub, animalTypeIndex = SUBS[sub].typeIndex,
        gender = SUBS[sub].gender, age = 18, weight = 640, targetWeight = SUBS[sub].targetWeight, health = 100,
        genetics = { quality = 1.1, metabolism = 1, fertility = 0.9 }, bodyCondition = { reserve = 0.5, lossRateEMA = 0 },
        pregnancy = nil, monitor = { active = true }, isDead = false, isSold = false }, { __index = Animal })
    for k, v in pairs(fields or {}) do a[k] = v end
    return a
end

-- A pen (with the engine stand-in for its visual animals) or a livestock trailer, filled through
-- the real queue and flush.
local penSerial = 0
local function newSource(kind, farmId, animals)
    penSerial = penSerial + 1
    local source = { uniqueId = "source" .. penSerial, raised = 0, isServer = true }
    local husbandryId = 70 + penSerial
    local visuals = { husbandryIds = { [1] = husbandryId }, husbandryIdsToVisualAnimalCount = { [husbandryId] = 0 },
        visualAnimalCount = 0, animalIdToCluster = { [1] = {} }, nextId = 0 }
    source.visuals = visuals
    if kind == "PEN" then
        source.spec_husbandryAnimals = { clusterHusbandry = visuals }
        -- Engine stand-in: every member without a visual animal gets a new one; ids are never reused.
        function source.spec_husbandryAnimals:updateVisualAnimals()
            if source.visualFault then source.visualFault = nil error("visual update failed") end
            for _, member in ipairs(source.clusterSystem.animals) do
                if member.idFull == nil then
                    visuals.nextId = visuals.nextId + 1
                    member.idFull = husbandryId .. "-" .. visuals.nextId
                    member.id = member.idFull
                    visuals.husbandryIdsToVisualAnimalCount[husbandryId] = visuals.husbandryIdsToVisualAnimalCount[husbandryId] + 1
                    visuals.visualAnimalCount = visuals.visualAnimalCount + 1
                    visuals.animalIdToCluster[1][visuals.nextId] = member
                end
            end
        end
    else
        source.spec_livestockTrailer = {}
    end
    function source:getName() return kind .. self.uniqueId end
    function source:getOwnerFarmId() return farmId end
    function source:raiseActive() self.raised = self.raised + 1 end
    function source:getClusterSystem() return self.clusterSystem end
    source.clusterSystem = AnimalClusterSystem.new(true, source)
    for _, a in ipairs(animals) do source.clusterSystem:addPendingAddCluster(a) end
    source.clusterSystem:updateNow()
    return source
end

local function newHouse(credit)
    local house = HB.newSlaughterhouse(SUBS)
    house.uniqueId, house.customEnvironment, house.activations, house.visualRefreshes = "slaughterhouse1", "FS25_HofBergmann", 0, 0
    house.contractProductionDeliver = PlaceableContractProductionService.contractProductionDeliver   -- the real HB function
    function house:raiseActive()
        if self.raiseFault then self.raiseFault = nil error("raiseActive failed") end
        self.activations = self.activations + 1
    end
    function house:contractProductionRefreshAnimalVisuals()
        if self.visualFault then self.visualFault = nil error("contract visuals failed") end
        self.visualRefreshes = self.visualRefreshes + 1
    end
    AnimalMoveEvent.alignContractRecipes(house)
    local order = HB.addOrder(house, 1, 1, "cows_processing", credit or 20)
    return house, order
end

local function keyOf(a) return RLAnimalUtil.toKey(a.farmId, a.uniqueId, a.birthday.country) end

local function members(source)
    local keys = {}
    for _, a in ipairs(source.clusterSystem.animals) do keys[#keys + 1] = keyOf(a) end
    table.sort(keys)
    return table.concat(keys, ",")
end

-- Everything a transaction may change, as one string.
local function state(house, source, farmId)
    local parts = {}
    for _, order in ipairs(house.spec_contractProductionService.orders) do
        local input = order.inputs[BEEF] or {}
        parts[#parts + 1] = string.format("o%s:%s/%s/%s/%s/%s/%s", tostring(order.id), tostring(input.buffered),
            tostring(input.totalDelivered), tostring(order.totalDeliveredAmount), tostring(order.fee), tostring(order.feeCredit),
            tostring(order.state))
    end
    -- Money and the production cost statistic to 1e-6 (a refund puts back (x - c) + c); the
    -- "money earned" statistic is left out: a refund adds to it (known, checked on its own).
    local farm = FARMS[farmId or 1]
    local function amount(x) return math.abs(x) < 5e-7 and "0" or string.format("%.6f", x) end
    parts[#parts + 1] = "m" .. amount(farm.money) .. "/" .. amount(farm.stats.productionCosts)
    if source ~= nil then
        local cs = source.clusterSystem
        parts[#parts + 1] = "a:" .. members(source)
        parts[#parts + 1] = string.format("q%s%s", tostring(next(cs.clustersToAdd)), tostring(next(cs.clustersToRemove)))
    end
    return table.concat(parts, " ")
end

local function request(source, house, animals, farmId)
    return { farmId = farmId or 1, source = source, target = house, animals = animals }
end

CT.setMode("TEST")

-- B01: one head, full acceptance ------------------------------------------------------------
do
    setFarm(1, 1000)
    local house, order = newHouse(20)
    local bull = animal(HOLSTEIN)
    local other = animal(ANGUS)
    local pen = newSource("PEN", 1, { bull, other })
    local quote = RLTradeQuote.quoteAnimal(bull, house, 1)
    local visualsBefore = pen.visuals.visualAnimalCount
    local record = CT.execute(request(pen, house, { bull }))
    local input = order.inputs[BEEF]
    check("B01 one head: COMMITTED", record ~= nil and record.state == "COMMITTED")
    check(string.format("B01 one head: input %.6f standard batches = the quote, credit 20 then cash %.2f", quote.inputQuantity, quote.cashDue),
        input.buffered == quote.inputQuantity and input.totalDelivered == quote.inputQuantity
        and order.totalDeliveredAmount == quote.inputQuantity and order.feeCredit == 0
        and near(order.fee, quote.fee, 1e-9) and near(FARMS[1].money, 1000 - quote.cashDue, 1e-9))
    check("B01 one head: the bull left the pen through the real flush, the other stays with its visual",
        members(pen) == keyOf(other) and bull.clusterSystem == nil and pen.visuals.visualAnimalCount == visualsBefore - 1
        and #REMOVED_VISUALS >= 1 and other.idFull ~= nil)
    check("B01 one head: locks released, receipt kept", next(CT.store.locks) == nil and CT.receipts[record.id].target.verified
        and CT.receipts[record.id].source.verified)
end

-- B02 / A09: three heads, one order credit used once, one deliver call --------------------------
do
    setFarm(1, 1000)
    local house, order = newHouse(20)
    local animals = { animal(HOLSTEIN), animal(ANGUS, { weight = 600 }), animal(ANGUS, { weight = 700 }) }
    local pen = newSource("PEN", 1, animals)
    local calls, deliver = 0, house.contractProductionDeliver
    house.contractProductionDeliver = function(...) calls = calls + 1 return deliver(...) end
    local amount, fee = 0, 0
    for _, a in ipairs(animals) do
        local q = RLTradeQuote.quoteAnimal(a, house, 1)
        amount, fee = amount + q.inputQuantity, fee + q.fee
    end
    local record = CT.execute(request(pen, house, animals))
    check(string.format("B02 three heads: COMMITTED in one deliver call (%.4f batches)", amount),
        record.state == "COMMITTED" and calls == 1 and near(order.inputs[BEEF].buffered, amount, 1e-12) and members(pen) == "")
    check("A09 three heads: the order's credit 20 used once, the rest cash",
        order.feeCredit == 0 and near(FARMS[1].money, 1000 - (fee - 20), 1e-6))
end

-- A10: money exactly enough / a hair short -----------------------------------------------------
do
    setFarm(1, 0)
    local house = newHouse(0)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local q = RLTradeQuote.quoteAnimal(bull, house, 1)
    FARMS[1].money = q.cashDue * (1 - 1e-9)
    local before = state(house, pen)
    local record, reason = CT.execute(request(pen, house, { bull }))
    check("A10 money a hair short: refused before start, nothing changed (no partial delivery)",
        record == nil and (has(reason, "INSUFFICIENT") or has(reason, "CANNOT_AFFORD")) and state(house, pen) == before)
    FARMS[1].money = q.cashDue
    record = CT.execute(request(pen, house, { bull }))
    check("A10 money exactly the cash due: COMMITTED, money 0", record.state == "COMMITTED" and near(FARMS[1].money, 0, 1e-9))
end

-- A01 / A02: bad batches ------------------------------------------------------------------------
do
    setFarm(1, 1000)
    local house = newHouse(20)
    local bull, other = animal(HOLSTEIN), animal(ANGUS)
    local pen = newSource("PEN", 1, { bull, other })
    local before = state(house, pen)
    local cases = {
        { "empty", {}, "EMPTY_OR_SPARSE_BATCH" },
        { "sparse", { [1] = bull, [3] = other }, "EMPTY_OR_SPARSE_BATCH" },
        { "string key", { bull, x = other }, "BAD_BATCH" },
        { "duplicate identity", { bull, { farmId = bull.farmId, uniqueId = bull.uniqueId, birthday = { country = 1 } } }, "DUPLICATE_IDENTITY" },
        { "missing country", { { farmId = bull.farmId, uniqueId = bull.uniqueId, birthday = {} } }, "BAD_IDENTITY" },
        { "same uniqueId, other country", { { farmId = bull.farmId, uniqueId = bull.uniqueId, birthday = { country = 2 } } }, "ANIMAL_NOT_FOUND" },
        { "metatable batch", setmetatable({ bull }, {}), "BAD_BATCH" },
    }
    for _, case in ipairs(cases) do
        local record, reason = CT.execute(request(pen, house, case[2]))
        check("A01/A02 " .. case[1] .. ": refused whole (" .. tostring(reason) .. "), nothing changed",
            record == nil and has(reason, case[3]) and state(house, pen) == before)
    end
end

-- A03: ownership and permission -----------------------------------------------------------------
do
    setFarm(1, 1000) setFarm(2, 1000)
    local house = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 2, { bull })
    local before = state(house, pen)
    local record, reason = CT.execute(request(pen, house, { bull }, 1))
    check("A03 another farm's pen: NOT_OWNER, nothing changed", record == nil and reason == "NOT_OWNER" and state(house, pen) == before)
    local mine = newSource("PEN", 1, { animal(HOLSTEIN) })
    RLPermissionHelper = { authorizeConnection = function() return false, "NO_PERMISSION" end }
    local r = request(mine, house, { mine.clusterSystem.animals[1] })
    r.connection = {}
    record, reason = CT.execute(r)
    check("A03 no trade permission: refused", record == nil and has(reason, "NO_PERMISSION")
        and CT.toMoveErrorCode(nil, reason) == AnimalMoveEvent.MOVE_ERROR_NO_PERMISSION)
    RLPermissionHelper = nil
end

-- A04 / A05: live animal and source state ------------------------------------------------------
do
    setFarm(1, 1000)
    local house = newHouse(20)
    local sick = animal(HOLSTEIN, { sick = true })
    local pen = newSource("PEN", 1, { sick })
    local record, reason = CT.execute(request(pen, house, { sick }))
    check("A04 sick animal: refused (" .. tostring(reason) .. ")", record == nil and has(reason, "SICK"))

    local calf = animal(HOLSTEIN, { age = 3, weight = 120 })
    pen = newSource("PEN", 1, { calf })
    record, reason = CT.execute(request(pen, house, { calf }))
    check("A04 too young for the facility: refused (" .. tostring(reason) .. ")", record == nil and has(reason, "TOO_YOUNG"))

    local bull, ridden = animal(HOLSTEIN), animal(ANGUS)
    pen = newSource("PEN", 1, { bull, ridden })
    ridden.beingRidden = true
    record, reason = CT.execute(request(pen, house, { bull }))
    check("A04 a member the flush would remove on its own: refused", record == nil and reason == "SOURCE_FLUSH_WOULD_REMOVE")
    ridden.beingRidden = nil

    pen.clusterSystem.clustersToRemove[ridden] = false
    record, reason = CT.execute(request(pen, house, { bull }))
    check("A05 a queued entry, even false: SOURCE_QUEUE_BUSY", record == nil and reason == "SOURCE_QUEUE_BUSY")
    pen.clusterSystem.clustersToRemove[ridden] = nil

    local cow = animal(MILKCOW)
    local mixed = newSource("PEN", 1, { cow })
    record, reason = CT.execute(request(mixed, house, { cow }))
    check("A04 MILKCOW (no meat profile): TYPE_UNSUPPORTED", record == nil and has(reason, "TYPE_UNSUPPORTED:MILKCOW"))

    bull.sale = { day = 2 }
    record, reason = CT.execute(request(pen, house, { bull }))
    check("A04 an animal carrying a dealer listing: refused (restore would drop it)", record == nil and has(reason, "LISTED_FOR_SALE"))
    bull.sale = nil
end

-- A06: no order, two orders (HB's pick) ---------------------------------------------------------
do
    setFarm(1, 1000)
    local house, order = newHouse(20)
    house.spec_contractProductionService.orders = {}
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local record, reason = CT.execute(request(pen, house, { bull }))
    check("A06 no open order: refused, NOT_ENOUGH_SPACE to the client", record == nil and has(reason, "NO_OPEN_ORDER")
        and CT.toMoveErrorCode(nil, reason) == AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE)
    local high = HB.addOrder(house, 9, 1, "cows_processing", 0)
    local low = HB.addOrder(house, 4, 1, "cows_processing", 50)
    record = CT.execute(request(pen, house, { bull }))
    check("A06 two orders: the lowest id (HB's own pick) took it", record.state == "COMMITTED"
        and low.inputs[BEEF].buffered > 0 and high.inputs[BEEF].buffered == 0)
end

-- A07 / A08 / B09: the world changes between prepare and run -------------------------------------
do
    setFarm(1, 1000)
    local house, order = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local context = CT.prepare(request(pen, house, { bull }))
    local recipe = house.spec_contractProductionService.recipeById.cows_processing
    local savedFee = recipe.feePerBatch
    recipe.feePerBatch = savedFee + 1
    local before = state(house, pen)
    local record = CT.run(context)
    check("A07 recipe fee changed after prepare: REJECTED in preflight, nothing changed",
        record.state == "REJECTED" and has(context.preflightError, "RECIPE_CHANGED") and state(house, pen) == before)
    recipe.feePerBatch = savedFee

    context = CT.prepare(request(pen, house, { bull }))
    local replacement = HB.addOrder(house, 1, 1, "cows_processing", 20)
    house.spec_contractProductionService.orders = { replacement }
    before = state(house, pen)
    record = CT.run(context)
    check("A08 order rebuilt under the same id: REJECTED (ORDER_CHANGED), nothing changed",
        record.state == "REJECTED" and context.preflightError == "ORDER_CHANGED" and state(house, pen) == before)
    house.spec_contractProductionService.orders = { order }

    context = CT.prepare(request(pen, house, { bull }))
    HB.addOrder(house, 0, 1, "cows_processing", 0)
    record = CT.run(context)
    check("B09 a lower-id order opened after prepare (delivery would go there): REJECTED", record.state == "REJECTED"
        and context.preflightError == "ORDER_CHANGED")
    table.remove(house.spec_contractProductionService.orders)

    context = CT.prepare(request(pen, house, { bull }))
    local newcomer = animal(ANGUS)
    pen.clusterSystem:addPendingAddCluster(newcomer)
    record = CT.run(context)
    check("A04 the source changed after prepare (queued add): REJECTED", record.state == "REJECTED"
        and context.preflightError == "SOURCE_QUEUE_BUSY")
    pen.clusterSystem:updateNow()

    context = CT.prepare(request(pen, house, { bull }))
    CT.setMode("SHADOW")
    record = CT.run(context)
    check("mode switched off before run: REJECTED, never delivered", record.state == "REJECTED" and context.preflightError == "MODE")
    CT.setMode("TEST")
end

-- B03: the facility takes only part of the batch -> everything undone ----------------------------
do
    setFarm(1, 1000)
    local house, order = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local real = house.contractProductionDeliver
    house.contractProductionDeliver = function(self, farmId, fillType, amount) return real(self, farmId, fillType, amount / 2) end
    local before = state(house, pen)
    local record = CT.execute(request(pen, house, { bull }))
    local receipt = CT.receipts[record.id]
    check("B03 half accepted: not a whole head - ROLLED_BACK, order, credit and money as before, animal kept",
        record.state == "ROLLED_BACK" and has(receipt.target.verifyError, "ACCEPTED") and state(house, pen) == before
        and bull.clusterSystem == pen.clusterSystem)
    check("B03 half accepted: the refund nets out the production cost statistic", FARMS[1].stats.productionCosts == 0
        or near(FARMS[1].stats.productionCosts, 0, 1e-9))

    house.contractProductionDeliver = function() return 0 end
    before = state(house, pen)
    record = CT.execute(request(pen, house, { bull }))
    check("B03 nothing accepted (returns 0, no change): ROLLED_BACK, nothing changed", record.state == "ROLLED_BACK"
        and state(house, pen) == before)

    house.contractProductionDeliver = function(self, farmId, fillType, amount) real(self, farmId, fillType, amount) return true end
    record = CT.execute(request(pen, house, { bull }))
    check("B03 full deltas but a non-number return: not trusted - ROLLED_BACK", record.state == "ROLLED_BACK" and state(house, pen) == before)
    house.contractProductionDeliver = real
end

-- B05 / B06 / B07 / B08: the real HB deliver throws at each stage --------------------------------
local function throwCase(label, setup, expectState, extra)
    setFarm(1, 1000)
    local house, order = newHouse(20)
    order.feeCredit = 20
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local before = state(house, pen)
    setup(house)
    local record = CT.execute(request(pen, house, { bull }))
    local ok = record.state == expectState and (expectState ~= "ROLLED_BACK" or state(house, pen) == before)
    check(label .. ": " .. record.state, ok and (extra == nil or extra(house, pen, record)))
    moneyFault, moneyExtra = nil, 0
    return house, pen, record
end
throwCase("B05 throw in addMoney before money moved (credit already taken by HB): credit restored, no refund", function()
    moneyFault = "before"
end, "ROLLED_BACK", function() return FARMS[1].earned == 0 end)
throwCase("B06 throw in addMoney after money moved: the charged cash refunded once", function()
    moneyFault = "after"
end, "ROLLED_BACK", function(_, _, record) return CT.receipts[record.id].target.refunded ~= nil end)
throwCase("B07 throw in raiseActive after every order field moved: all undone", function(house)
    house.raiseFault = true
end, "ROLLED_BACK")
throwCase("B08 contract visuals throw at the end of the deliver: treated as failed, all undone, visuals refreshed again",
    function(house) house.visualFault = true end, "ROLLED_BACK", function(house) return house.visualRefreshes >= 1 end)

-- B06 unknown money: another mod moved money inside addMoney -> cannot prove the inverse --------------
do
    local house, pen, record = throwCase("B06 money moved by another amount: NEEDS_RECONCILIATION, no refund, locks held",
        function() moneyExtra = 5 end, "NEEDS_RECONCILIATION",
        function(_, _, rec) return FARMS[1].earned == 0 and next(CT.store.locks) ~= nil end)
    local bull = pen.clusterSystem.animals[1]
    check("B06 unknown money: the animal stays in the pen (source never touched)", bull ~= nil and bull.clusterSystem == pen.clusterSystem)
    local again, reason = CT.execute(request(pen, house, { bull }))
    check("A11/B12 a new request for the same animal while it waits for reconciliation: RESOURCE_BUSY",
        again == nil and reason == "RESOURCE_BUSY")
    local replay, why = RLTradeTransaction.executeContract(CT.store, record.id, {})
    check("B10 the reconciliation record is never retried automatically", why == "REPLAY" and replay.state == "NEEDS_RECONCILIATION")
    CT.reset() CT.setMode("TEST")
end

-- B10: the refund itself fails -> reconciliation, no second refund ----------------------------------
do
    setFarm(1, 1000)
    local house = newHouse(0)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local real = house.contractProductionDeliver
    house.contractProductionDeliver = function(self, farmId, fillType, amount) return real(self, farmId, fillType, amount / 2) end
    local addMoney = g_currentMission.addMoney
    g_currentMission.addMoney = function(mission, amount, ...)
        if amount > 0 then error("refund failed") end
        return addMoney(mission, amount, ...)
    end
    local record = CT.execute(request(pen, house, { bull }))
    g_currentMission.addMoney = addMoney
    local receipt = CT.receipts[record.id]
    check("B10 the refund throws: NEEDS_RECONCILIATION, order fields left as HB set them, reason recorded",
        record.state == "NEEDS_RECONCILIATION" and has(receipt.target.rollbackError, "REFUND_THREW") and receipt.target.refunded == nil)
    CT.reset() CT.setMode("TEST")
end

-- B11: another change to the order during or after the deliver -> not overwritten ------------------
do
    setFarm(1, 1000)
    local house, order = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    -- A listener that adds 0.5 to the buffer when visuals refresh (after the deliver changed it).
    local refresh = house.contractProductionRefreshAnimalVisuals
    house.contractProductionRefreshAnimalVisuals = function(self)
        order.inputs[BEEF].buffered = (order.inputs[BEEF].buffered or 0) + 0.5
        refresh(self)
        error("visual failed after a foreign change")
    end
    local record = CT.execute(request(pen, house, { bull }))
    local receipt = CT.receipts[record.id]
    check("B11 a change inside the deliver that HB's code does not make: unexplained - NEEDS_RECONCILIATION",
        record.state == "NEEDS_RECONCILIATION" and has(receipt.target.rollbackError, "DELTA_UNEXPLAINED"))
    CT.reset() CT.setMode("TEST")
end
do
    setFarm(1, 1000)
    local house, order = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    -- After the target committed, the source flush publishes; a listener changes the order, then the pen's visuals fail.
    publishHook = function() order.inputs[BEEF].buffered = order.inputs[BEEF].buffered + 0.25 publishHook = nil end
    pen.visualFault = true
    local record = CT.execute(request(pen, house, { bull }))
    local receipt = CT.receipts[record.id]
    check("B11 the order changed after the delivery, the source then failed: source put back, target not overwritten - NEEDS_RECONCILIATION",
        record.state == "NEEDS_RECONCILIATION" and has(receipt.target.rollbackError, "CHANGED_SINCE:buffered")
        and pen.clusterSystem.animals[1] == bull and has(record.reason, "TARGET_ROLLBACK_UNKNOWN"))
    publishHook = nil
    CT.reset() CT.setMode("TEST")
end

-- B12: money unreadable after the deliver ------------------------------------------------------
do
    setFarm(1, 1000)
    local house = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local real = house.contractProductionDeliver
    house.contractProductionDeliver = function(...) local r = real(...) moneyUnreadable = true return r end
    local record = CT.execute(request(pen, house, { bull }))
    moneyUnreadable = false
    check("B12 money unreadable after delivery: not guessed - NEEDS_RECONCILIATION, animal kept",
        record.state == "NEEDS_RECONCILIATION" and pen.clusterSystem.animals[1] == bull)
    CT.reset() CT.setMode("TEST")
end

-- B13: credit covers all / part / none ------------------------------------------------------------
for _, credit in ipairs({ 1000, 50, 0 }) do
    setFarm(1, 1000)
    local house, order = newHouse(credit)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local q = RLTradeQuote.quoteAnimal(bull, house, 1)
    local record = CT.execute(request(pen, house, { bull }))
    local cash = math.max(q.fee - credit, 0)
    check(string.format("B13 credit %d: credit first, cash %.2f, fee once from the recipe (199.9 x factor = %.2f)", credit, cash, q.fee),
        record.state == "COMMITTED" and near(order.feeCredit, math.max(credit - q.fee, 0), 1e-9)
        and near(FARMS[1].money, 1000 - cash, 1e-9) and near(q.fee, 199.9 * q.factor, 1e-9))
end

-- C01: the queue call throws part way ------------------------------------------------------------
do
    setFarm(1, 1000)
    local house = newHouse(20)
    local a1, a2, a3 = animal(HOLSTEIN), animal(ANGUS), animal(ANGUS)
    local pen = newSource("PEN", 1, { a1, a2, a3 })
    local before = state(house, pen)
    local cs = pen.clusterSystem
    local queue, calls = cs.addPendingRemoveCluster, 0
    cs.addPendingRemoveCluster = function(self, cluster)
        calls = calls + 1
        if calls == 2 then error("queue failed") end
        return queue(self, cluster)
    end
    local record = CT.execute(request(pen, house, { a1, a2 }))
    cs.addPendingRemoveCluster = nil
    check("C01 queue throws on the second animal: ROLLED_BACK, source and target as before", record.state == "ROLLED_BACK"
        and state(house, pen) == before)
    cs:addPendingRemoveCluster(a3)
    cs:updateNow()
    check("C06 a later normal flush removes only what it queued, not this batch's survivors",
        members(pen) == table.concat({ keyOf(a1), keyOf(a2) }, ",") or members(pen) == table.concat({ keyOf(a2), keyOf(a1) }, ","))
end

-- C02 / C03 / C04: the flush removes the batch, then the pen's visual update throws ------------------
do
    setFarm(1, 1000)
    local house = newHouse(20)
    local a1 = animal(HOLSTEIN, { pregnancy = { pregnancies = { { duration = 9 } } }, isPregnant = true, reproduction = 40 })
    local a2 = animal(ANGUS)
    local keep = animal(ANGUS)
    local pen = newSource("PEN", 1, { a1, a2, keep })
    local before = state(house, pen)
    local oldIds = { a1.idFull, a2.idFull }
    local visualsBefore = pen.visuals.visualAnimalCount
    local genetics = a1.genetics
    local cs = pen.clusterSystem
    local flush = cs.updateNow
    local calls = 0
    cs.updateNow = function(self)
        calls = calls + 1
        if calls == 1 then pen.visualFault = true end
        return flush(self)
    end
    local record = CT.execute(request(pen, house, { a1, a2 }))
    cs.updateNow = nil
    local receipt = CT.receipts[record.id]
    check("C02 flush removed both then threw: ROLLED_BACK from the real member list, target undone",
        record.state == "ROLLED_BACK" and #receipt.source.restored == 2 and state(house, pen) == before)
    check("C03 restored as the same objects with their genes, weight, condition and pregnancy",
        cs.animals[2] ~= nil and a1.genetics == genetics and a1.genetics.quality == 1.1 and a1.weight == 640
        and a1.bodyCondition.reserve == 0.5 and a1.pregnancy.pregnancies[1].duration == 9 and a1.clusterSystem == cs)
    check("C04 restored animals got new visual ids (removed ones not reused); visual count back",
        a1.idFull ~= nil and a1.idFull ~= oldIds[1] and a2.idFull ~= oldIds[2] and pen.visuals.visualAnimalCount == visualsBefore
        and #cs.animals == 3 and cs.idToIndex[RLAnimalUtil.toShortKey(a1.farmId, a1.uniqueId)] ~= nil)
    check("C10 the member outside the batch kept its visual and place", keep.clusterSystem == cs and keep.idFull ~= nil)
end

-- C05: the source cannot be restored -> target left, reconciliation ---------------------------------
do
    setFarm(1, 1000)
    local house, order = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local cs = pen.clusterSystem
    local flush, add = cs.updateNow, cs.addPendingAddCluster
    local calls = 0
    cs.updateNow = function(self) calls = calls + 1 if calls == 1 then pen.visualFault = true end return flush(self) end
    cs.addPendingAddCluster = function() error("re-add failed") end
    local record = CT.execute(request(pen, house, { bull }))
    cs.updateNow, cs.addPendingAddCluster = nil, nil
    check("C05 source restore fails: NEEDS_RECONCILIATION and the target is NOT undone (no double loss)",
        record.state == "NEEDS_RECONCILIATION" and order.inputs[BEEF].buffered > 0 and has(record.reason, "SOURCE_ROLLBACK_UNKNOWN"))
    check("C05 locks held for the animal, order and cash", next(CT.store.locks) ~= nil)
    CT.reset() CT.setMode("TEST")
end

-- C08: a livestock trailer as the source --------------------------------------------------------
do
    setFarm(1, 1000)
    local house = newHouse(20)
    local bull, other = animal(HOLSTEIN), animal(ANGUS)
    local trailer = newSource("TRAILER", 1, { bull, other })
    local record = CT.execute(request(trailer, house, { bull }))
    check("C08 trailer: COMMITTED, the other animal stays", record.state == "COMMITTED" and members(trailer) == keyOf(other))
    local bull2 = animal(HOLSTEIN)
    trailer = newSource("TRAILER", 1, { bull2 })
    local real = house.contractProductionDeliver
    house.contractProductionDeliver = function(self, farmId, fillType, amount) return real(self, farmId, fillType, amount / 2) end
    record = CT.execute(request(trailer, house, { bull2 }))
    house.contractProductionDeliver = real
    check("C08 trailer, target failure: ROLLED_BACK and the source never touched", record.state == "ROLLED_BACK"
        and trailer.clusterSystem.animals[1] == bull2)
end

-- A12: the same animals again after a commit ---------------------------------------------------
do
    setFarm(1, 1000)
    local house = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local record = CT.execute(request(pen, house, { bull }))
    local again, reason = CT.execute(request(pen, house, { bull }))
    check("A12 a repeated request for an animal already delivered: ANIMAL_NOT_FOUND, nothing delivered twice",
        record.state == "COMMITTED" and again == nil and has(reason, "ANIMAL_NOT_FOUND"))
end

-- SHADOW and OFF change nothing ---------------------------------------------------------------
do
    setFarm(1, 1000)
    local house = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    CT.reset() CT.setMode("SHADOW")
    local before = state(house, pen)
    local context, reason = CT.shadow(request(pen, house, { bull }))
    check("SHADOW: prepares (would deliver), no lock, no record, nothing changed",
        context ~= nil and reason == nil and next(CT.store.locks) == nil and next(CT.store.records) == nil and state(house, pen) == before)
    local record, why = CT.execute(request(pen, house, { bull }))
    check("SHADOW: execute is refused outright", record == nil and why == "MODE_SHADOW" and state(house, pen) == before)
    CT.reset()
    check("reset: mode OFF and an empty ledger (map load)", CT.getMode() == "OFF" and next(CT.store.records) == nil)
    CT.setMode("TEST")
end

-- Unsupported HB version ----------------------------------------------------------------------
do
    setFarm(1, 1000)
    local house = newHouse(20)
    house.customEnvironment = "FS25_HofBergmann_old"
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local record, reason = CT.execute(request(pen, house, { bull }))
    check("an HB version not audited: refused (" .. tostring(reason) .. ")", record == nil and has(reason, "UNSUPPORTED_HB_VERSION"))
end

-- The move event: TEST goes through the transaction and never the old path; OFF keeps the old path ----
do
    newServerToClientCodes = {}
    AnimalMoveEvent.newServerToClient = function(code) newServerToClientCodes[#newServerToClientCodes + 1] = code return { code = code } end
    RLHusbandryProfiles = { apply = function() end, checkAnimal = function() return true end }
    RmSafeUtils = { safeCall = function(_, fn) local ok, err = pcall(fn) if not ok then error(err) end end }
    g_currentMission.userManager = { getUniqueUserIdByConnection = function() return "user1" end }
    g_farmManager = { getFarmForUniqueUserId = function() return { farmId = 1 } end }

    local function runEvent(pen, house, animals)
        newServerToClientCodes = {}
        local event = setmetatable({ sourceObject = pen, targetObject = house, animals = animals, moveType = "TARGET" },
            { __index = AnimalMoveEvent })
        function house:getSupportsAnimalSubType() return true end
        function house:addCluster() end   -- HB registers addCluster on the contract placeable
        function house:getClusterSystem() return { addPendingAddCluster = function() end, updateNow = function() end } end
        AnimalMoveEvent.run(event, { getIsServer = function() return false end,
            sendEvent = function() end })
        return newServerToClientCodes[#newServerToClientCodes]
    end

    setFarm(1, 1000)
    local house, order = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local deliverCalls, real = 0, house.contractProductionDeliver
    house.contractProductionDeliver = function(...) deliverCalls = deliverCalls + 1 return real(...) end
    CT.setMode("TEST")
    local code = runEvent(pen, house, { bull })
    check("move event TEST: one transaction, success to the client, one deliver call", code == AnimalMoveEvent.MOVE_SUCCESS
        and deliverCalls == 1 and members(pen) == "" and next(CT.store.records) ~= nil)

    local bull2 = animal(HOLSTEIN)
    pen = newSource("PEN", 1, { bull2 })
    house.contractProductionDeliver = function(self, farmId, fillType, amount) deliverCalls = deliverCalls + 1 return real(self, farmId, fillType, amount / 2) end
    deliverCalls = 0
    code = runEvent(pen, house, { bull2 })
    check("move event TEST, half accepted: error to the client, animal kept, no fallback to the old per-head path",
        code ~= AnimalMoveEvent.MOVE_SUCCESS and deliverCalls == 1 and pen.clusterSystem.animals[1] == bull2)

    CT.setMode("OFF")
    deliverCalls = 0
    local recordsBefore = 0
    for _ in pairs(CT.store.records) do recordsBefore = recordsBefore + 1 end
    code = runEvent(pen, house, { bull2 })
    local recordsAfter = 0
    for _ in pairs(CT.store.records) do recordsAfter = recordsAfter + 1 end
    check("move event OFF: the old per-head path runs (and still credits a half acceptance as a head - known, unchanged)",
        recordsAfter == recordsBefore and deliverCalls == 1 and code == AnimalMoveEvent.MOVE_SUCCESS)
    house.contractProductionDeliver = real
end

-- The transaction report reads only ------------------------------------------------------------
do
    loadMod("scripts/console/RLTradeReportConsole.lua")
    CT.reset() CT.setMode("TEST")
    setFarm(1, 1000)
    local house = newHouse(20)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    CT.execute(request(pen, house, { bull }))
    local lines, savedPrint = {}, print
    print = function(text) lines[#lines + 1] = text end
    local before = state(house, pen)
    local result = RLTradeReportConsole:txReport()
    local again = RLTradeReportConsole:txReport()
    print = savedPrint
    local text = table.concat(lines, "\n")
    check("rlTradeTxReport: lists the committed transaction with its stages and receipts, changes nothing",
        has(result, "1 transaction(s)") and has(text, "COMMITTED") and has(text, "APPLYING_TARGET > TARGET_APPLIED")
        and has(text, "standard batches (not kg)") and state(house, pen) == before and result == again)
    check("rlTradeTxMode: shows and sets the mode", has(RLTradeReportConsole:txMode(), "TEST")
        and has(RLTradeReportConsole:txMode("off"), "OFF") and CT.getMode() == "OFF"
        and has(RLTradeReportConsole:txMode("bogus"), "OFF, SHADOW or TEST"))
end
