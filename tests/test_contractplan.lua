loadMod("scripts/animal/RLContractPlan.lua")
local P = RLContractPlan
local function entry(key, order, amount, fee, credit, fillType, room)
    return { key = key, orderId = order, recipeId = "cows", inputFillType = fillType or 102,
        room = room or 100, feeCredit = credit or 0,
        quote = { authoritative = true, status = "SUPPORTED", semantics = "WEIGHTED_BATCH",
            inputQuantity = amount or 1, fee = fee or 100 } }
end
local function rejected(name, entries, money, reason)
    local plan, why = P.prepare(entries, money)
    check(name, plan == nil and why == reason)
end
do
    local entries = { entry("A", 1, 1, 100, 150), entry("B", 1, 1, 100, 150) }
    local plan = P.prepare(entries, 50)
    check("batch: credit shared per order once, exact wallet boundary succeeds",
        plan and plan.fee == 200 and plan.creditUse == 150 and plan.cashDue == 50 and plan.moneyAfter == 0)
    check("batch: aggregate capacity across heads", plan and plan.inputs[102].amount == 2)
    plan.entries[1].amount = 99
    check("plan: does not retain mutable quote references", entries[1].quote.inputQuantity == 1)
    rejected("batch: a tiny wallet shortfall cannot allow partial delivery", entries, 50 - 1e-8, "INSUFFICIENT_CASH")
    rejected("batch: no per-head reuse of the same credit", entries, 0, "INSUFFICIENT_CASH")
end
do
    local entries = { entry("A", 1, 1, 100, 20, 102), entry("B", 2, 1, 50, 0, 101) }
    rejected("orders: share one wallet across distinct inputs", entries, 100, "INSUFFICIENT_CASH")
    local plan = P.prepare(entries, 130)
    check("orders: separate credits and cash aggregate correctly", plan and plan.cashDue == 130 and plan.creditUse == 20)
end
do
    local entries = { entry("A", 1, 1, 100, 0), entry("B", 1, 1, 100, 1) }
    rejected("mixed snapshots: differing order credit refuses whole batch", entries, 1000, "INCONSISTENT_ORDER_SNAPSHOT")
    entries[2].feeCredit = 0
    entries[2].recipeId = "pigs"
    rejected("mixed snapshots: differing recipe refuses whole batch", entries, 1000, "INCONSISTENT_ORDER_SNAPSHOT")
    entries[2].recipeId = "cows"
    entries[2].room = 99
    rejected("mixed snapshots: differing capacity refuses whole batch", entries, 1000, "INCONSISTENT_CAPACITY_SNAPSHOT")
end
do
    local e = entry("A", 1, 1, 100, 0, 102, 1 - 1e-8)
    rejected("capacity: no tolerance-authorized short delivery", { e }, 100, "INSUFFICIENT_CAPACITY")
    e.room = 1
    check("capacity: exact boundary fits", P.prepare({ e }, 100) ~= nil)
    e.room = nil
    rejected("capacity: unknown capacity is not infinite", { e }, 100, "CAPACITY_UNKNOWN")
end
for _, status in ipairs({ "AMBIGUOUS", "UNKNOWN", "UNSUPPORTED" }) do
    local e = entry("A", 1)
    e.quote.status = status
    rejected("quote: " .. status .. " cannot authorize commit", { e }, 1000, "QUOTE_" .. status)
end
do
    local e = entry("A", 1)
    e.quote.authoritative = false
    rejected("client copy: cannot prepare server transaction", { e }, 1000, "NOT_AUTHORITATIVE")
    e.quote.authoritative = true
    e.quote.semantics = "ANIMAL_CONVERSION"
    rejected("conversion: not silently treated as weighted contract", { e }, 1000, "NOT_CONTRACT_BATCH")
    e.quote.semantics = "WEIGHTED_BATCH"
    e.orderId = nil
    rejected("no order: diagnostic quote is not a deliverable order", { e }, 1000, "NO_ORDER")
end
for _, field in ipairs({ "inputQuantity", "fee" }) do
    for _, value in ipairs({ -1, math.huge, -math.huge, "1" }) do
        local e = entry("A", 1)
        e.quote[field] = value
        rejected("invalid " .. field .. ": " .. tostring(value), { e }, 1000,
            field == "fee" and "BAD_FEE" or "BAD_INPUT_AMOUNT")
    end
end
do
    local e = entry("A", 1)
    e.quote.inputQuantity = 0/0
    rejected("NaN input refused", { e }, 1000, "BAD_INPUT_AMOUNT")
    rejected("duplicate identity refused", { entry("A", 1), entry("A", 1) }, 1000, "DUPLICATE_IDENTITY")
    rejected("empty batch refused", {}, 1000, "EMPTY_OR_SPARSE_BATCH")
    rejected("map key cannot hide an animal", { entry("A", 1), extra = entry("B", 1) }, 1000, "BAD_ENTRIES")
    rejected("metatable batch refused", setmetatable({ entry("A", 1) }, {}), 1000, "BAD_ENTRIES")
    rejected("non-finite wallet refused", { entry("A", 1) }, math.huge, "BAD_WALLET")
    local a, b = entry("A", 1, 1e308, 1e308, 0, 102, 1e308), entry("B", 1, 1e308, 1e308, 0, 102, 1e308)
    rejected("aggregate numeric overflow refused", { a, b }, 1e308, "NUMERIC_OVERFLOW")
end

-- Real HB Beta2 function, not the T01 fixture's simplified full-acceptance stub.
loadMod("tests/fixtures/hb_beta2.lua")
loadMod("tests/fixtures/hb_contract_delivery.lua")
MoneyType = { PRODUCTION_COSTS = 7 }
local money, debits = 0, 0
g_currentMission = { getMoney = function() return money end,
    addMoney = function(_, amount) debits = debits + 1; money = money + amount end }
local function house(credit)
    local h = HB.newSlaughterhouse({ [1] = { typeName = "COW", typeIndex = 1 } })
    local order = HB.addOrder(h, 1, 1, "cows_processing", credit or 0)
    h.contractProductionDeliver = PlaceableContractProductionService.contractProductionDeliver
    h.activations, h.visuals = 0, 0
    h.raiseActive = function(self) self.activations = self.activations + 1 end
    h.contractProductionRefreshAnimalVisuals = function(self) self.visuals = self.visuals + 1 end
    return h, order
end
do
    local h, order = house(20)
    money, debits = 30, 0
    local accepted = h:contractProductionDeliver(1, HB.FILLTYPES.BEEF, 1)
    check("REAL HB: partial acceptance when wallet plus credit is short", accepted == 0.5)
    check("REAL HB: partial target asset and full available money already mutated",
        order.inputs[102].buffered == 0.5 and order.inputs[102].totalDelivered == 0.5
        and order.totalDeliveredAmount == 0.5 and order.fee == 50 and order.feeCredit == 0 and money == 0 and debits == 1)
    check("REAL HB: activation and visual side effects also occur", h.activations == 1 and h.visuals == 1)
end
do
    local h, order = house(20)
    money = 100
    g_currentMission.addMoney = function() error("before cash effect") end
    local ok = pcall(h.contractProductionDeliver, h, 1, 102, 1)
    check("REAL HB: throw before cash still consumes credit but not input",
        not ok and order.feeCredit == 0 and order.inputs[102].buffered == 0 and money == 100)
end
do
    local h, order = house(20)
    money = 100
    g_currentMission.addMoney = function(_, amount) money = money + amount; error("after cash effect") end
    local ok = pcall(h.contractProductionDeliver, h, 1, 102, 1)
    check("REAL HB: throw after cash leaves cash and credit consumed without input",
        not ok and money == 20 and order.feeCredit == 0 and order.inputs[102].buffered == 0 and order.fee == nil)
end
do
    local h, order = house(20)
    money = 100
    g_currentMission.addMoney = function(_, amount) money = money + amount end
    local plan = P.prepare({ entry("A", 1, 1, 100, 20) }, money)
    local accepted = h:contractProductionDeliver(1, 102, plan.entries[1].amount)
    check("REAL HB: prepared full budget agrees with actual acceptance and cash",
        accepted == 1 and money == plan.moneyAfter and order.feeCredit == 20 - plan.creditUse
        and order.inputs[102].buffered == plan.inputs[102].amount)
end

-- Read-only live snapshot facade and console: using real T01 calculations and recipes.
TYPES = { [1] = { name = "COW" } }
SUBS = { [1] = { typeIndex = 1, typeName = "COW", targetWeight = 1100,
    name = "BULL_HOLSTEIN", breed = "HOLSTEIN", gender = "male" } }
AnimalMoveEvent = { MOVE_SUCCESS = 0 }
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) return HB.FILLTYPES[name] end,
    getFillTypeNameByIndex = function(_, index) return HB.FILLTYPE_NAMES[index] end }
g_currentMission.animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end,
    getTypeByIndex = function(_, i) return TYPES[i] end }
g_currentMission.getIsServer = function() return true end
g_currentMission.getFarmId = function() return 1 end
loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadMod("scripts/animal/RLTradeQuote.lua")
-- Only the identity utility used by the facade; the full file also has GIANTS-only casts.
RLAnimalUtil = { toKey = function(farm, id, country) return farm .. " " .. id .. " " .. country end }
loadMod("scripts/animal/RLContractPreview.lua")
loadMod("scripts/console/RLTradeReportConsole.lua")
do
    local h, order = house(20)
    AnimalMoveEvent.alignContractRecipes(h)
    money = 1000
    local animals = {
        { farmId = "1001", uniqueId = "10001", birthday = { country = 1 }, subTypeIndex = 1,
            weight = 649, targetWeight = 1100, gender = "male", age = 17, genetics = { quality = 1 } },
        { farmId = "1001", uniqueId = "10002", birthday = { country = 1 }, subTypeIndex = 1,
            weight = 649, targetWeight = 1100, gender = "male", age = 17, genetics = { quality = 1 } },
    }
    local quote = RLTradeQuote.quoteAnimal(animals[1], h, 1)
    local plan = RLContractPreview.prepare(animals, h, 1)
    check("preview: real quotes aggregate whole batch credit once", plan and near(plan.fee, quote.fee * 2, 1e-8)
        and plan.creditUse == 20 and near(plan.cashDue, quote.fee * 2 - 20, 1e-8))
    for _ = 1, 100 do assert(RLContractPreview.prepare(animals, h, 1)) end
    check("preview: 101 queries never deliver, charge, activate or consume credit", money == 1000
        and order.feeCredit == 20 and order.inputs[102].buffered == 0 and h.activations == 0 and h.visuals == 0)
    g_currentMission.getIsServer = function() return false end
    check("preview client: no authoritative server budget", select(2, RLContractPreview.prepare(animals, h, 1)) == "NOT_AUTHORITATIVE")
    g_currentMission.getIsServer = function() return true end
    check("preview: missing requested farm order refuses", select(2, RLContractPreview.prepare(animals, h, 2)) == "NO_ORDER")
    check("preview: fractional farm id refuses", select(2, RLContractPreview.prepare(animals, h, 1.5)) == "BAD_FARM")
    check("preview: empty batch refuses", select(2, RLContractPreview.prepare({}, h, 1)) == "EMPTY_OR_SPARSE_BATCH")
    local pen = { getName = function() return "Bulls" end, getClusters = function() return animals end }
    g_currentMission.husbandrySystem = { placeables = { pen } }
    g_currentMission.placeableSystem = { placeables = { h } }
    local result = RLTradeReportConsole:plan("1", "pen:Bulls")
    check("console plan: explicit shadow-only result", result:find("shadow only", 1, true) ~= nil)
    check("console plan: refuses bad explicit farm instead of using player farm",
        RLTradeReportConsole:plan("1", "pen:Bulls", "invalid"):find("invalid farmId", 1, true) ~= nil)
    check("console plan: empty pen fragment cannot select every animal",
        RLTradeReportConsole:plan("1", "pen:"):find("pen name required", 1, true) ~= nil)
    check("console plan: missing parameters gives usage", RLTradeReportConsole:plan():find("read-only", 1, true) ~= nil)
    check("console plan: missing facility named", RLTradeReportConsole:plan("999", "pen:Bulls"):find("not found", 1, true) ~= nil)
    local many = {}
    for i = 1, 41 do
        many[i] = table.clone(animals[1])
        many[i].uniqueId = tostring(10000 + i)
    end
    pen.getClusters = function() return many end
    local p, reason = RLContractPreview.prepare(many, h, 1)
    check("preview: does not silently truncate to report's 40 heads", p == nil and reason == "INSUFFICIENT_CASH")
    money = 10
    local single = RLTradeQuote.quoteAnimal(animals[1], h, 1)
    p, reason = RLContractPreview.prepare(animals, h, 1)
    check("preview: a head's own CANNOT_AFFORD is decided by the whole-batch cash check",
        single.status == "UNKNOWN" and p == nil and reason == "INSUFFICIENT_CASH")
    money = 1000
    g_currentMission.placeableSystem.placeables[2] = h
    check("console plan: ambiguous facility name is refused",
        RLTradeReportConsole:plan("Slaughter", "pen:Bulls"):find("AMBIGUOUS", 1, true) ~= nil)
    check("console plan: never changed game assets", money == 1000 and order.inputs[102].buffered == 0 and order.feeCredit == 20)
end
