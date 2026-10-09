-- T02 contract diagnostics (RLContractDiag): the RLCT records a contract move writes while
-- rlTradeTxMode is SHADOW or TEST, and the read-only gate preview test tools call.
--
-- Same world as test_contract_trade.lua: the real HB deliver excerpt, the base game's cluster
-- queue, RLRM's cluster system, quote, plan, coordinator and adapters, driven through
-- AnimalMoveEvent:run. Engine stand-ins: farm money (FS25 Farm:changeBalance arithmetic), the
-- pen's visual animals, the trailer's slots, events and messages. HB's free slot count is its own
-- arithmetic (PlaceableContractProductionAnimalInput:contractProductionGetAnimalFreeSlots).

AnimalMoveEvent = { MOVE_SUCCESS = 0, MOVE_ERROR_NO_PERMISSION = 1, MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST = 2,
    MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST = 3, MOVE_ERROR_INVALID_CLUSTER = 4, MOVE_ERROR_ANIMAL_NOT_SUPPORTED = 5,
    MOVE_ERROR_NOT_ENOUGH_SPACE = 6 }
loadMod("tests/fixtures/hb_beta2.lua")
loadMod("tests/fixtures/hb_contract_delivery.lua")
loadMod("tests/fixtures/giants_lua.lua")
loadMod("tests/fixtures/fs25_farm_money.lua")

TYPES = { [1] = { name = "COW" } }
SUBS = {
    [1] = { typeIndex = 1, typeName = "COW", targetWeight = 1100, name = "BULL_HOLSTEIN", breed = "HOLSTEIN", gender = "male" },
    [2] = { typeIndex = 1, typeName = "COW", targetWeight = 1000, name = "BULL_ANGUS", breed = "ANGUS", gender = "male" },
}
local HOLSTEIN, ANGUS = 1, 2

MoneyType = { PRODUCTION_COSTS = { id = 7, statistic = "productionCosts" } }
FARMS = {}
local function setFarm(id, money)
    local farm = setmetatable({ money = money, stats = { finances = { productionCosts = 0 }, financesVersionCounter = 0 }, earned = 0 },
        { __index = ContractTestFarm })
    function farm.stats:changeFinanceStats(amount, statistic) ContractTestFarmStats.changeFinanceStats(self, amount, statistic) end
    function farm.stats:addHeroStat(_, amount) farm.earned = farm.earned + amount end
    FARMS[id] = farm
end
local moneyUnreadable = false
g_farmManager = { getFarmById = function(_, id) return FARMS[id] end, getFarmForUniqueUserId = function() return { farmId = 1 } end }
g_currentMission = {
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    getIsServer = function() return true end,
    getFarmId = function() return 1 end,
    accessHandler = { canFarmAccess = function() return true end },
    userManager = { getUniqueUserIdByConnection = function() return "user1" end },
    getMoney = function(_, farmId)
        if moneyUnreadable then error("money unreadable") end
        return FARMS[farmId] ~= nil and FARMS[farmId].money or 0
    end,
    addMoney = function(_, amount, farmId, moneyType) FARMS[farmId]:changeBalance(amount, moneyType) end,
}
g_modManager = { getModByName = function(_, name) return name == "FS25_HofBergmann" and { version = "1.5.0.0 Beta2" } or nil end }
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) return HB.FILLTYPES[name] end,
    getFillTypeNameByIndex = function(_, index) return HB.FILLTYPE_NAMES[index] end }
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

string.contains = function(text, part) return text:find(part, 1, true) ~= nil end
getTimeSec = os.clock
g_server = { netIsRunning = false, broadcastEvent = function() end }
g_messageCenter = { publish = function() end }
AnimalClusterUpdateEvent = { new = function(owner, animals) return { owner = owner, count = #animals } end }
removeHusbandryAnimal = function() end
RLAnimalUtil = {
    toKey = function(farmId, uniqueId, country) return farmId .. " " .. uniqueId .. " " .. country end,
    toShortKey = function(farmId, uniqueId) return farmId .. " " .. uniqueId end,
}

loadMod("tests/fixtures/fs25_cluster_queue.lua")
loadGiantsMod("scripts/animals/husbandry/cluster/RealisticLivestock_AnimalClusterSystem.lua")
loadAnimalSection("function Animal:setClusterSystem", "function Animal:getSupportsMerging")
loadAnimalSection("function Animal:getNumAnimals", "function Animal:getSubTypeIndex")
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
loadMod("scripts/animal/RLContractDiag.lua")

local CT, D = RLContractTrade, RLContractDiag
local BEEF = HB.FILLTYPES.BEEF

-- Every record as written: kind, its data table and the line.
local RECORDS = {}
local emit = D.emit
D.emit = function(kind, data)
    local line = emit(kind, data)
    RECORDS[#RECORDS + 1] = { kind = kind, data = data, line = line }
    return line
end
local function records(kind)
    local list = {}
    for _, r in ipairs(RECORDS) do if kind == nil or r.kind == kind then list[#list + 1] = r end end
    return list
end
local function only(kind)
    local list = records(kind)
    return #list == 1 and list[1].data or nil
end

-- World ------------------------------------------------------------------------------------------

local serial = 0
local function animal(sub, fields)
    serial = serial + 1
    local a = setmetatable({ isIndividual = true, numAnimals = 1, farmId = "1001", uniqueId = tostring(20000 + serial),
        birthday = { country = 1, day = 3 }, subTypeIndex = sub, animalTypeIndex = SUBS[sub].typeIndex,
        gender = SUBS[sub].gender, age = 18, weight = 640, targetWeight = SUBS[sub].targetWeight, health = 100,
        genetics = { quality = 1.1, metabolism = 1, fertility = 0.9 }, bodyCondition = { reserve = 0.5, lossRateEMA = 0 },
        monitor = { active = true }, isDead = false, isSold = false }, { __index = Animal })
    for k, v in pairs(fields or {}) do a[k] = v end
    return a
end

local penSerial = 0
local function newSource(kind, farmId, animals)
    penSerial = penSerial + 1
    local source = { uniqueId = "source" .. penSerial, isServer = true }
    local husbandryId = 70 + penSerial
    local visuals = { husbandryIds = { [1] = husbandryId }, husbandryIdsToVisualAnimalCount = { [husbandryId] = 0 },
        visualAnimalCount = 0, animalIdToCluster = { [1] = {} }, nextId = 0 }
    source.visuals = visuals
    if kind == "PEN" then
        source.spec_husbandryAnimals = { clusterHusbandry = visuals }
        function source.spec_husbandryAnimals:updateVisualAnimals()
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
        -- Engine stand-in for LivestockTrailer:updateAnimals: one used slot per animal.
        local place = { usedSlots = 0 }
        source.spec_livestockTrailer = { animalTypeIndexToPlaces = { [1] = place } }
        function source:updatedClusters() place.usedSlots = #self.clusterSystem.animals end
    end
    function source:getName() return kind .. self.uniqueId end
    function source:getOwnerFarmId() return farmId end
    function source:raiseActive() end
    function source:getClusterSystem() return self.clusterSystem end
    source.clusterSystem = AnimalClusterSystem.new(true, source)
    for _, a in ipairs(animals) do source.clusterSystem:addPendingAddCluster(a) end
    source.clusterSystem:updateNow()
    if source.updatedClusters ~= nil then source:updatedClusters() end
    return source
end

local function newHouse(credit)
    local house = HB.newSlaughterhouse(SUBS)
    house.uniqueId, house.customEnvironment = "slaughterhouse1", "FS25_HofBergmann"
    house.contractProductionDeliver = PlaceableContractProductionService.contractProductionDeliver
    function house:raiseActive() end
    function house:contractProductionRefreshAnimalVisuals() end
    function house:getSupportsAnimalSubType() return true end
    function house:addCluster() end
    function house:getClusterSystem() return { addPendingAddCluster = function() end, updateNow = function() end } end
    -- HB's own free slot count: room, then (money + order credit) / fee per batch, rounded down.
    function house:contractProductionGetAnimalFreeSlots(farmId, subTypeIndex)
        local spec = self.spec_contractProductionService
        local fillType = self.animalSubTypeToFillType[subTypeIndex]
        local free = 0
        for _, order in pairs(spec.orders) do
            local recipe = order.farmId == farmId and spec.recipeById[order.recipeId] or nil
            local recipeInput = recipe ~= nil and recipe.inputs[fillType] or nil
            if recipeInput ~= nil then
                free = 100
                if fillType == recipe.feeInputFillTypeIndex and recipe.feePerBatch > 0 then
                    local budget = math.max(g_currentMission:getMoney(farmId), 0) + math.max(order.feeCredit or 0, 0)
                    free = math.min(free, math.floor(budget / recipe.feePerBatch * recipeInput.amount + 0.000001))
                end
                break
            end
        end
        return free
    end
    AnimalMoveEvent.alignContractRecipes(house)
    local order = HB.addOrder(house, 1, 1, "cows_processing", credit or 0)
    order.fee, order.totalDeliveredAmount, order.state = 0, 0, "DELIVERY"
    order.inputs[BEEF].totalDelivered = 0
    return house, order
end

local function keyOf(a) return RLAnimalUtil.toKey(a.farmId, a.uniqueId, a.birthday.country) end

local CODES = {}
AnimalMoveEvent.newServerToClient = function(code) CODES[#CODES + 1] = code return { code = code } end
RLHusbandryProfiles = { apply = function() end, checkAnimal = function() return true end, logDecision = function() end }
RLPermissionHelper = { authorizeConnection = function() return true end }

local function runEvent(source, house, animals)
    CODES = {}
    local event = setmetatable({ sourceObject = source, targetObject = house, animals = animals, moveType = "TARGET" },
        { __index = AnimalMoveEvent })
    AnimalMoveEvent.run(event, { getIsServer = function() return false end, sendEvent = function() end })
    return CODES[#CODES]
end

local function contains(list, item)
    for _, v in ipairs(list or {}) do if v == item then return true end end
    return false
end

local function feePerBatch(house)
    return house.spec_contractProductionService.recipeById.cows_processing.feePerBatch
end

-- D01: the encoding --------------------------------------------------------------------------------
do
    local json = D.encode({ b = 0.1 + 0.2, a = 3, list = { "x", 'q"\\' }, flag = true, none = nil })
    check("D01 keys sorted, integers plain, other numbers with 17 significant digits, strings escaped",
        json == '{"a":3,"b":0.30000000000000004,"flag":true,"list":["x","q\\"\\\\"]}')
    check("D01 a non-finite number is a string, not invalid JSON", D.encode({ x = 0 / 0 }):find('"x":"') ~= nil)
end

-- D02: OFF writes nothing --------------------------------------------------------------------------
do
    CT.reset()
    RECORDS = {}
    setFarm(1, 1000)
    local house = newHouse(0)
    local pen = newSource("PEN", 1, { animal(HOLSTEIN) })
    local event = { sourceObject = pen, targetObject = house, animals = pen.clusterSystem.animals }
    check("D02 OFF: open records nothing", D.open(event, 1) == nil and #RECORDS == 0)
    CT.setMode("TEST")
    local other = { sourceObject = pen, targetObject = { getName = function() return "Bull barn" end }, animals = {} }
    check("D02 TEST, target not a contract slaughterhouse: nothing recorded", D.open(other, 1) == nil and #RECORDS == 0)
end

-- D03: a committed delivery from a pen, through AnimalMoveEvent:run --------------------------------
do
    CT.reset() CT.setMode("TEST")
    RECORDS = {}
    setFarm(1, 1000)
    local house, order = newHouse(0)
    local bull, other = animal(HOLSTEIN), animal(ANGUS)
    local pen = newSource("PEN", 1, { bull, other })
    local quote = RLTradeQuote.quoteAnimal(bull, house, 1)
    local code = runEvent(pen, house, { bull })
    local request, result, target, source = only("CT_REQUEST"), only("CT_RESULT"), only("CT_TARGET"), only("CT_SOURCE")
    local scopes = records("CT_SCOPE")
    local before, after = scopes[1] and scopes[1].data, scopes[2] and scopes[2].data
    check("D03 commit: CT_REQUEST, CT_SCOPE BEFORE, CT_RESULT, CT_TARGET, CT_SOURCE, CT_SCOPE AFTER in that order",
        code == AnimalMoveEvent.MOVE_SUCCESS and #RECORDS == 6 and RECORDS[1].kind == "CT_REQUEST" and RECORDS[2].kind == "CT_SCOPE"
        and RECORDS[3].kind == "CT_RESULT" and RECORDS[6].kind == "CT_SCOPE" and before.at == "BEFORE" and after.at == "AFTER")
    check("D03 request: id, mode, farm, the requested identity, source PEN with id and name",
        request.requestId == "rq1" and request.mode == "TEST" and request.farmId == 1 and request.count == 1
        and request.keys[1] == keyOf(bull) and request.source.kind == "PEN" and request.source.id == pen.uniqueId
        and request.target.id == "slaughterhouse1")
    check("D03 result: COMMITTED, the stages, the plan, the error code sent, the same request id",
        result.state == "COMMITTED" and result.requestId == "rq1" and result.errorCode == 0 and result.txId ~= nil
        and contains(result.history, "TARGET_APPLIED") and result.amount == quote.inputQuantity and result.fillType == "BEEF"
        and result.plan.creditUse == 0 and result.plan.cashDue == result.plan.fee)
    check("D03 target receipt: verified, money and order fields before and after, payment APPLIED",
        target.receipt.verified == true and target.receipt.paymentStatus == "APPLIED"
        and target.receipt.moneyBefore == 1000 and target.receipt.moneyAfter == 1000 + (-result.plan.cashDue)
        and target.receipt.after.buffered == result.amount)
    check("D03 source receipt: the bull removed, verified", source.receipt.verified == true and source.receipt.removed[1] == keyOf(bull)
        and source.receipt.kind == "PEN")
    check("D03 scope before: money, statistic, the order (credit 0, nothing delivered), both animals, visual 2, no locks",
        before.scope.money == 1000 and before.scope.productionCosts == 0 and before.scope.orders[1].feeCredit == 0
        and before.scope.orders[1].inputs.BEEF.buffered == 0 and before.scope.source.count == 2
        and before.scope.source.visual == 2 and before.scope.ledger.locks == 0 and before.scope.errors == nil)
    check("D03 scope after: the other animal stays, visual 1, money less the cash, order buffered the amount, locks 0, queues empty",
        after.scope.source.count == 1 and after.scope.source.members[1] == keyOf(other) and after.scope.source.visual == 1
        and after.scope.money == 1000 + (-result.plan.cashDue) and after.scope.orders[1].inputs.BEEF.buffered == result.amount
        and after.scope.ledger.locks == 0 and after.scope.ledger.records == 1
        and after.scope.source.queueAdd == 0 and after.scope.source.queueRemove == 0)
    check("D03 changed: money, statistic, order fields and the source; not the ledger locks",
        contains(after.changed, "money") and contains(after.changed, "productionCosts") and contains(after.changed, "orders/#1/fee")
        and contains(after.changed, "source/members") and contains(after.changed, "source/visual")
        and not contains(after.changed, "ledger/locks"))
    check("D03 the line carries the exact cash: money after parses back to the same double",
        RECORDS[6].line:find('"money":' .. string.format("%.17g", after.scope.money), 1, true) ~= nil
        and tonumber(string.format("%.17g", after.scope.money)) == FARMS[1].money)
    check("D03 the order really changed as recorded", order.inputs[BEEF].buffered == result.amount and FARMS[1].money == after.scope.money)
end

-- D04: two heads, the order's credit then cash, the batch-outside animal untouched -----------------
do
    CT.reset() CT.setMode("TEST")
    RECORDS = {}
    setFarm(1, 2000)
    local house = newHouse(0)
    local a, b, outside = animal(HOLSTEIN), animal(ANGUS, { weight = 600 }), animal(ANGUS)
    local pen = newSource("PEN", 1, { a, b, outside })
    house.spec_contractProductionService.orders[1].feeCredit = feePerBatch(house) * 0.5
    local code = runEvent(pen, house, { a, b })
    local result, target, after = only("CT_RESULT"), only("CT_TARGET"), records("CT_SCOPE")[2].data
    -- HB charges the fee of the batch total; the plan sums per-head fees (equal to ~1e-13)
    local fee = result.amount / 1 * feePerBatch(house)
    local cash = math.max(fee - feePerBatch(house) * 0.5, 0)
    check("D04 two heads: COMMITTED, credit half a batch used once, the rest cash by HB's formula on the batch total",
        code == 0 and result.state == "COMMITTED" and #result.keys == 2 and result.plan.creditUse == feePerBatch(house) * 0.5
        and near(result.plan.cashDue, cash, 1e-9) and target.receipt.expected.cash == cash
        and after.scope.orders[1].feeCredit == 0 and after.scope.money == 2000 + (-cash))
    check("D04 the animal outside the batch is the only member left", after.scope.source.count == 1
        and after.scope.source.members[1] == keyOf(outside))
end

-- D05: whole-batch cash refusal at T02 (HB's free slots still say one) -----------------------------
do
    CT.reset() CT.setMode("TEST")
    RECORDS = {}
    setFarm(1, 0)
    local house = newHouse(0)
    local heavy = animal(HOLSTEIN, { weight = 1150, age = 30 })
    local pen = newSource("PEN", 1, { heavy })
    local q = RLTradeQuote.quoteAnimal(heavy, house, 1)
    local fee = feePerBatch(house)
    FARMS[1].money = fee * (1 + q.inputQuantity) / 2
    check(string.format("D05 setup: the heavy bull is %.4f batches (> 1), money between one batch and its fee", q.inputQuantity),
        q.inputQuantity > 1 and house:contractProductionGetAnimalFreeSlots(1, HOLSTEIN) == 1)
    local preview = D.preview({ farmId = 1, source = pen, target = house, animals = { heavy } })
    local code = runEvent(pen, house, { heavy })
    local refused, after = only("CT_REFUSED"), records("CT_SCOPE")[2].data
    check("D05 preview names the same gate: T02_PREPARE INSUFFICIENT_CASH, free slots 1",
        preview.stage == "T02_PREPARE" and preview.reason == "INSUFFICIENT_CASH" and preview.freeSlots == 1
        and preview.errorCode == AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE)
    check("D05 refused: CT_REFUSED T02_PREPARE INSUFFICIENT_CASH, code NOT_ENOUGH_SPACE, no result, nothing changed",
        code == AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE and refused ~= nil and refused.stage == "T02_PREPARE"
        and refused.reason == "INSUFFICIENT_CASH" and refused.errorCode == code and only("CT_RESULT") == nil
        and #after.changed == 0 and after.scope.source.count == 1 and next(CT.store.records) == nil)
end

-- D06: under one batch of budget HB's free slots refuse first (MOVE_VALIDATE) ------------------------
do
    CT.reset() CT.setMode("TEST")
    RECORDS = {}
    setFarm(1, 0)
    local house = newHouse(0)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    FARMS[1].money = feePerBatch(house) * 0.5
    local preview = D.preview({ farmId = 1, source = pen, target = house, animals = { bull } })
    local code = runEvent(pen, house, { bull })
    local refused, after = only("CT_REFUSED"), records("CT_SCOPE")[2].data
    check("D06 half a batch of money: refused by the move's validate (HB free slots 0) before T02, recorded as MOVE_VALIDATE",
        code == AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE and refused.stage == "MOVE_VALIDATE" and refused.errorCode == code
        and #after.changed == 0 and preview.stage == "MOVE_VALIDATE" and preview.freeSlots == 0)
end

-- D07: from a livestock trailer --------------------------------------------------------------------
do
    CT.reset() CT.setMode("TEST")
    RECORDS = {}
    setFarm(1, 1000)
    local house = newHouse(0)
    local bull = animal(HOLSTEIN)
    local trailer = newSource("TRAILER", 1, { bull })
    local code = runEvent(trailer, house, { bull })
    local request, result, scopes = only("CT_REQUEST"), only("CT_RESULT"), records("CT_SCOPE")
    check("D07 trailer: COMMITTED, source kind TRAILER, used slots 1 before",
        code == 0 and result.state == "COMMITTED" and request.source.kind == "TRAILER"
        and scopes[1].data.scope.source.kind == "TRAILER" and scopes[1].data.scope.source.visual == 1
        and scopes[2].data.scope.source.count == 0)
end

-- D08: preview reads only ----------------------------------------------------------------------------
do
    CT.reset() CT.setMode("TEST")
    RECORDS = {}
    setFarm(1, 1000)
    local house = newHouse(0)
    local a, b = animal(HOLSTEIN), animal(ANGUS)
    local pen = newSource("PEN", 1, { a, b })
    local scope = D.readScope({ farmId = 1, source = pen, target = house })
    local preview = D.preview({ farmId = 1, source = pen, target = house, animals = { a, b } })
    local again = D.readScope({ farmId = 1, source = pen, target = house })
    check("D08 preview READY: amount, plan, per-animal entries, order fee per batch, permission not checked",
        preview.stage == "READY" and #preview.entries == 2 and preview.plan.cashDue == preview.plan.fee
        and preview.order.feePerBatch == feePerBatch(house) and preview.order.inputPerBatch == 1
        and preview.permissionChecked == false and near(preview.amount, preview.entries[1].amount + preview.entries[2].amount, 1e-12))
    check("D08 preview changes nothing: same scope, no record, no lock, no RLCT line",
        #D.changed(scope, again) == 0 and next(CT.store.records) == nil and next(CT.store.locks) == nil and #RECORDS == 0)
end

-- D09: a failed read is recorded, the delivery goes on ------------------------------------------------
do
    CT.reset() CT.setMode("TEST")
    RECORDS = {}
    setFarm(1, 1000)
    local house = newHouse(0)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local getFarm = g_farmManager.getFarmById
    local calls = 0
    -- the statistic is unreadable for the diagnostics' first read only
    g_farmManager.getFarmById = function(self, id)
        calls = calls + 1
        if calls == 1 then error("farm table busy") end
        return getFarm(self, id)
    end
    local code = runEvent(pen, house, { bull })
    g_farmManager.getFarmById = getFarm
    local before = records("CT_SCOPE")[1].data
    check("D09 the scope names its failed part, the delivery still commits", code == 0 and only("CT_RESULT").state == "COMMITTED"
        and before.scope.errors ~= nil and before.scope.errors[1]:find("^wallet:") ~= nil)
end

-- D10: SHADOW writes what TEST would do ------------------------------------------------------------
do
    CT.reset() CT.setMode("SHADOW")
    RECORDS = {}
    setFarm(1, 1000)
    local house = newHouse(0)
    local bull = animal(HOLSTEIN)
    local pen = newSource("PEN", 1, { bull })
    local diag = D.open({ sourceObject = pen, targetObject = house, animals = { bull }, moveType = "TARGET" }, 1)
    local context, reason = CT.shadow({ farmId = 1, source = pen, target = house, animals = { bull } })
    D.shadow(diag, context, reason)
    local shadow = only("CT_SHADOW")
    check("D10 SHADOW: CT_SHADOW WOULD_DELIVER with the plan; nothing locked", shadow ~= nil and shadow.verdict == "WOULD_DELIVER"
        and shadow.requestId == diag.requestId and shadow.plan.fee > 0 and next(CT.store.locks) == nil)
end

-- D11: an over-long record becomes a marker --------------------------------------------------------
do
    RECORDS = {}
    local long = {}
    for i = 1, 400 do long[i] = "1001 " .. (30000 + i) .. " 1" end
    local line = D.emit("CT_SCOPE", { requestId = "rqX", scope = { members = long } })
    check("D11 a line over 3800 characters is replaced by LINE_TOO_LONG with its request id",
        #line <= D.MAX_LINE and line:find('"kind":"LINE_TOO_LONG"', 1, true) ~= nil and line:find('"requestId":"rqX"', 1, true) ~= nil)
end
