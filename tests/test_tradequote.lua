-- Read-only trade quote (RLTradeQuote) on Hof Bergmann Beta2's real recipes: facility semantics,
-- model vs effective recipe meat before and after the contract recipe alignment, the shared
-- COW/MILKCOW input, conflicts, animal conversion, unknown and unreadable recipes, fees, and
-- that quoting changes nothing.

AnimalMoveEvent = { MOVE_SUCCESS = 0 }
loadMod("tests/fixtures/hb_beta2.lua")

TYPES = { [1] = { name = "COW" }, [2] = { name = "PIG" }, [3] = { name = "SHEEP" }, [4] = { name = "MILKCOW" },
    [5] = { name = "HORSE" } }
SUBS = {
    [1] = { typeIndex = 1, typeName = "COW", targetWeight = 1100, name = "BULL_HOLSTEIN", breed = "HOLSTEIN", gender = "male" },
    [2] = { typeIndex = 1, typeName = "COW", targetWeight = 730, name = "COW_HOLSTEIN", breed = "HOLSTEIN", gender = "female" },
    [3] = { typeIndex = 1, typeName = "COW", targetWeight = 1000, name = "BULL_ANGUS", breed = "ANGUS", gender = "male" },
    [4] = { typeIndex = 2, typeName = "PIG", targetWeight = 300, name = "BOAR_LANDRACE", breed = "LANDRACE", gender = "male" },
    [5] = { typeIndex = 3, typeName = "SHEEP", targetWeight = 75, name = "RAM_LANDRACE", breed = "LANDRACE", gender = "male" },
    [6] = { typeIndex = 4, typeName = "MILKCOW", targetWeight = 700, name = "MILKCOW_HOLSTEIN", breed = "HOLSTEIN", gender = "female" },
    [7] = { typeIndex = 5, typeName = "HORSE", targetWeight = 575, name = "STALLION_GRAY", breed = "GRAY", gender = "male" },
}
local BULL, COW, ANGUS, BOAR, RAM, MILKCOW, STALLION = 1, 2, 3, 4, 5, 6, 7

MONEY = { [1] = 5000 }
local moneyCalls = 0
g_currentMission = {
    animalSystem = { getSubTypeByIndex = function(_, i) return SUBS[i] end, getTypeByIndex = function(_, i) return TYPES[i] end },
    getMoney = function(_, farmId) return MONEY[farmId] or 0 end,
    addMoney = function(_, delta, farmId) moneyCalls = moneyCalls + 1; MONEY[farmId] = (MONEY[farmId] or 0) + delta end,
}
g_fillTypeManager = {
    getFillTypeIndexByName = function(_, name) return HB.FILLTYPES[name] end,
    getFillTypeNameByIndex = function(_, index) return HB.FILLTYPE_NAMES[index] end,
}
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
fileExists = function() return false end
g_currentModDirectory = REPO

loadMod("scripts/animal/RLBreedTraits.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadMod("scripts/animal/RLTradeQuote.lua")

local Q = RLTradeQuote
local function near6(a, b) return a ~= nil and b ~= nil and math.abs(a - b) <= 1e-6 * math.max(1, math.abs(a), math.abs(b)) end
local function has(list, item)
    for _, value in ipairs(list or {}) do if value == item then return true end end
    return false
end
local function animal(sub, weight, fields)
    local a = { subTypeIndex = sub, weight = weight, age = 17, gender = SUBS[sub].gender,
        targetWeight = SUBS[sub].targetWeight, genetics = { quality = 1 }, uniqueId = "A" .. sub }
    for k, v in pairs(fields or {}) do a[k] = v end
    return a
end

-- The audit's representative bull: 649 kg Holstein bull, 17 months, average genes.
local bull = animal(BULL, 649)
local factor = AnimalMoveEvent.getCarcassYieldFactor(bull, nil, BULL)
check(string.format("representative: factor %.8f (audit 0.95863044)", factor), near(factor, 0.95863044, 1e-7))

-- Public slaughterhouse, shipped recipes, before RLRM aligns them (a historical or unaligned state).
do
    local house = HB.newSlaughterhouse(SUBS)
    HB.addOrder(house, 1, 1, "cows_processing", 0)
    local quote, d = Q.quoteAnimal(bull, house, 1)
    check("unaligned: weighted contract input is a standard batch, not kg",
        quote.semantics == Q.WEIGHTED_BATCH and d.unit:find("not kg") ~= nil and near6(quote.inputQuantity, factor))
    check(string.format("unaligned: model %.4f kg vs recipe %.4f kg reported as a mismatch (x%.4f)",
        quote.modelMeat, quote.effectiveRecipeMeat, quote.ratio),
        near(quote.modelMeat, 258.8302, 1e-3) and near(quote.effectiveRecipeMeat, 958.6304, 1e-3)
        and quote.matches == false and d.recipe.alignment == "MISALIGNED" and near6(quote.ratio, 1000 / 270))
    check("unaligned: the recipe is the farm's open order's, the map's fee per batch",
        d.recipe.id == "cows_processing" and d.recipe.source == "order 1" and d.recipe.alignedAtLoad == false
        and near(quote.fee, 100 * factor, 1e-9) and d.fee.source == "recipe feePerBatch (map)")
    check("unaligned: MILKCOW on BEEF is reported as a mixed input, the quote stays supported",
        quote.status == Q.SUPPORTED and has(quote.notes, "MIXED_INPUT:MILKCOW") and has(d.sharedWith, "MILKCOW"))
end

-- Same facility after the real alignment ran at load (PR #27: MILKCOW has no meat profile).
local house = HB.newSlaughterhouse(SUBS)
local patched = AnimalMoveEvent.alignContractRecipes(house)
HB.addOrder(house, 1, 1, "cows_processing", 20)
do
    local quote, d = Q.quoteAnimal(bull, house, 1)
    check(string.format("aligned: %d recipes aligned at load (COW, PIG, SHEEP here); model and recipe agree (%.4f kg)", patched, quote.effectiveRecipeMeat),
        patched == 3 and d.recipe.alignment == "ALIGNED" and quote.matches and near6(quote.effectiveRecipeMeat, quote.modelMeat)
        and d.recipe.alignedAtLoad and d.recipe.shippedPrimaryAmount == 1000)
    check(string.format("aligned: fee once, from the recipe (%.2f = 199.9 x factor), not cutting fee again", quote.fee),
        near6(quote.fee, (100 + 0.37 * 270) * factor) and d.fee.shippedPerBatch == 100 and d.fee.source:find("RLRM cutting fee") ~= nil)
    check(string.format("aligned: fee credit 20 used first, cash due %.2f", quote.cashDue),
        near6(quote.feeCreditUse, 20) and near6(quote.cashDue, quote.fee - 20))
    check("aligned: authoritative on the server", quote.authoritative == true)

    -- The quoted input is what the real delivery path would credit (on a copy, so this facility is untouched).
    local copy = HB.newSlaughterhouse(SUBS)
    AnimalMoveEvent.alignContractRecipes(copy)
    local order = HB.addOrder(copy, 1, 1, "cows_processing", 20)
    local accepted = AnimalMoveEvent._deliverToContractTarget(copy, BULL, bull, 1)
    check("aligned: the quote's input and fee match the real delivery path",
        accepted == 1 and near6(order.inputs[HB.FILLTYPES.BEEF].buffered, quote.inputQuantity)
        and near6(order.cashCharged, quote.cashDue))
end

-- No open order: delivery would be refused, so the quote is not SUPPORTED; the only recipe is
-- still described and cash due is not made up.
do
    local quote, d = Q.quoteAnimal(bull, house, 2)
    check("no order: NO_OPEN_ORDER, not supported; only recipe described, cash due unknown",
        quote.status == Q.UNKNOWN and has(quote.reasons, "NO_OPEN_ORDER") and d.recipe.source == "only recipe, no open order"
        and quote.fee > 0 and quote.cashDue == nil and has(quote.notes, "CASH_DUE_UNKNOWN:no open order"))
    -- The delivery path agrees: no free slot without an order, so the batch is refused.
    local copy = HB.newSlaughterhouse(SUBS)
    function copy:contractProductionGetAnimalFreeSlots(farmId)
        for _, order in pairs(self.spec_contractProductionService.orders) do if order.farmId == farmId then return 100 end end
        return 0
    end
    AnimalMoveEvent.alignContractRecipes(copy)
    local delivered = AnimalMoveEvent._deliverToEPPTarget(copy, { { animal = { subTypeIndex = BULL }, sourceCluster = bull } }, 2)
    check("no order: the delivery path refuses the same animal", #delivered == 0)
end

-- No farm known (a dedicated server's console): still a weighted batch, orders not read.
do
    local quote, d = Q.quoteAnimal(bull, house, nil)
    check("no farm: WEIGHTED_BATCH semantics kept, NO_FARM reason, not supported",
        quote.semantics == Q.WEIGHTED_BATCH and has(quote.reasons, "NO_FARM") and quote.status == Q.UNKNOWN
        and d.recipe.alignment == "ALIGNED")
end

-- Money short of the cash due: the delivery code refuses the batch, the quote says why.
do
    local poor = HB.newSlaughterhouse(SUBS)
    AnimalMoveEvent.alignContractRecipes(poor)
    HB.addOrder(poor, 1, 3, "cows_processing", 0)
    MONEY[3] = 50
    local quote = Q.quoteAnimal(bull, poor, 3)
    local canTake = AnimalMoveEvent._canTakeEPPBatch(poor, { { animal = { subTypeIndex = BULL }, sourceCluster = bull } }, 3)
    check(string.format("money short: CANNOT_AFFORD (cash %.2f, money 50), and the delivery path refuses", quote.cashDue),
        quote.status == Q.UNKNOWN and has(quote.reasons, "CANNOT_AFFORD") and not canTake)
    MONEY[3] = quote.cashDue + 0.0005
    quote = Q.quoteAnimal(bull, poor, 3)
    canTake = AnimalMoveEvent._canTakeEPPBatch(poor, { { animal = { subTypeIndex = BULL }, sourceCluster = bull } }, 3)
    check("money just enough: SUPPORTED, same rounding as the delivery path", quote.status == Q.SUPPORTED and canTake)
    MONEY[3] = nil
end

-- A bad parameter type is named, not thrown.
do
    local shipped = AnimalMoveEvent.carcassConfig
    local config = table.clone(shipped, 4)
    config.layers.breeds.COW.HOLSTEIN = table.clone(config.layers.breeds.COW.HOLSTEIN)
    config.layers.breeds.COW.HOLSTEIN.carcassFactor = "heavy"
    AnimalMoveEvent.carcassConfig = config
    local ok, quote = pcall(Q.quoteAnimal, bull, house, 1)
    AnimalMoveEvent.carcassConfig = shipped
    check("bad input: quote names MODEL_BAD_INPUT:carcassFactor instead of throwing",
        ok and quote.status == Q.UNKNOWN and has(quote.reasons, "MODEL_BAD_INPUT:carcassFactor") and quote.inputQuantity == nil)
end

-- Client copy: not authoritative.
do
    local client = HB.newSlaughterhouse(SUBS, { isServer = false })
    AnimalMoveEvent.alignContractRecipes(client)
    local quote = Q.quoteAnimal(bull, client, 1)
    check("client: quote marked not authoritative", quote.authoritative == false)
end

-- MILKCOW itself: no meat profile, so no model and no meat recipe for it - unsupported, not guessed.
do
    local cow = animal(MILKCOW, 650)
    local quote = Q.quoteAnimal(cow, house, 1)
    check("MILKCOW: no meat profile is UNSUPPORTED with the input still in its unit",
        quote.status == Q.UNSUPPORTED and has(quote.reasons, "NO_MEAT_PROFILE") and quote.modelMeat == nil
        and quote.effectiveRecipeMeat == nil and quote.inputQuantity ~= nil)
end

-- Two meat profiles on one input (a map putting SHEEP on BEEF): a conflict, no meat figure.
do
    local animals = table.clone(HB.CONTRACT_ANIMALS)
    animals.SHEEP = "BEEF"
    local mixed = HB.newSlaughterhouse(SUBS, { animals = animals })
    HB.addOrder(mixed, 1, 1, "cows_processing", 0)
    local quote, d = Q.quoteAnimal(bull, mixed, 1)
    check("conflict: two meat profiles on BEEF are AMBIGUOUS with no effective meat",
        quote.status == Q.AMBIGUOUS and has(d.reasons, "SHARED_INPUT_CONFLICT:SHEEP") and quote.effectiveRecipeMeat == nil)
end

-- Two recipes taking BEEF: without an order it cannot be told which; with one the order decides.
do
    local recipes = table.clone(HB.CONTRACT_RECIPES)
    recipes[#recipes + 1] = { id = "cows_premium", input = "BEEF", output = "BEEFMEAT", amount = 300, fee = 150 }
    local two = HB.newSlaughterhouse(SUBS, { recipes = recipes })
    local quote, d = Q.quoteAnimal(bull, two, 1)
    check("several recipes: AMBIGUOUS without an order, not the first one found",
        quote.status == Q.AMBIGUOUS and has(d.reasons, "MULTIPLE_RECIPES") and d.recipe == nil and quote.effectiveRecipeMeat == nil)
    HB.addOrder(two, 7, 1, "cows_premium", 0)
    quote, d = Q.quoteAnimal(bull, two, 1)
    check("several recipes: the farm's order picks one",
        quote.status == Q.SUPPORTED and d.recipe.id == "cows_premium" and near6(quote.effectiveRecipeMeat, 300 * factor))
end

-- A recipe whose output is not the type's meat, a multi-input recipe, and unreadable recipes.
do
    local recipes = { { id = "cows_leather", input = "BEEF", output = "LEATHER", amount = 50, fee = 10 } }
    local odd = HB.newSlaughterhouse(SUBS, { recipes = recipes })
    local quote = Q.quoteAnimal(bull, odd, 1)
    check("unknown output: UNKNOWN with the output named, no meat assumed",
        quote.status == Q.UNKNOWN and has(quote.reasons, "OUTPUT_NOT_MEAT:LEATHER") and quote.effectiveRecipeMeat == nil)

    recipes = { { id = "cows_salt", input = "BEEF", output = "BEEFMEAT", amount = 1000, fee = 100, extraInputs = { { "LEATHER", 5 } } } }
    quote = Q.quoteAnimal(bull, HB.newSlaughterhouse(SUBS, { recipes = recipes }), 1)
    check("multi-input recipe: UNKNOWN (MULTI_INPUT_RECIPE)", quote.status == Q.UNKNOWN and has(quote.reasons, "MULTI_INPUT_RECIPE"))

    local blind = HB.newSlaughterhouse(SUBS)
    blind.spec_contractProductionService.recipes = nil
    quote = Q.quoteAnimal(bull, blind, 1)
    check("unreadable recipes: UNKNOWN (RECIPES_UNREADABLE), no meat",
        quote.status == Q.UNKNOWN and has(quote.reasons, "RECIPES_UNREADABLE") and quote.effectiveRecipeMeat == nil)
end

-- Farm butcher: production units through the real 1500 -> 900 recipe.
local butcher = HB.newFarmButcher(SUBS)
do
    local quote, d = Q.quoteAnimal(bull, butcher, 1)
    check(string.format("butcher: %.2f production units (450 x factor), %.4f kg from the recipe = model",
        quote.inputQuantity, quote.effectiveRecipeMeat),
        quote.semantics == Q.PRODUCTION_UNIT and near6(quote.inputQuantity, 450 * factor) and quote.matches
        and near6(d.recipe.meatPerInputUnit, 0.6) and d.unitsPerAnimal == 750)
    check(string.format("butcher: no contract fee; running cost is a labelled estimate (%.3f)", quote.runCostEstimate),
        quote.fee == 0 and near6(quote.runCostEstimate, 450 * factor * 2.0 / 1500) and quote.runCostSource:find("nominal") ~= nil)
    local fillType, _, scaled = AnimalMoveEvent._getScaledButcherUnits(butcher, BULL, bull)
    check("butcher: the quote's units equal the delivery path's", fillType == HB.FILLTYPES.BEEF and near6(scaled, quote.inputQuantity))

    local pig = animal(BOAR, 120, { age = 7 })
    quote = Q.quoteAnimal(pig, butcher, 1)
    check("butcher: pigs through 240 -> 150", quote.matches and near6(quote.inputQuantity * 150 / 240, quote.modelMeat))
end

-- Butcher with productions unreadable: delivery falls back to configured units, the quote names it.
do
    local blind = HB.newFarmButcher(SUBS, { productions = false })
    local quote = Q.quoteAnimal(bull, blind, 1)
    check("butcher unreadable: UNKNOWN, configured 750 x factor, no effective meat",
        quote.status == Q.UNKNOWN and has(quote.reasons, "RECIPES_UNREADABLE") and near6(quote.inputQuantity, 750 * factor)
        and quote.effectiveRecipeMeat == nil)
end

-- Two butcher productions for BEEF -> BEEFMEAT: not guessed, but what delivery uses is shown.
do
    local productions = table.clone(HB.BUTCHER_PRODUCTIONS)
    productions[#productions + 1] = { id = "cows_quick", input = "BEEF", inputAmount = 1000, output = "BEEFMEAT", amount = 500, waste = 100 }
    local two = HB.newFarmButcher(SUBS, { productions = productions })
    local quote = Q.quoteAnimal(bull, two, 1)
    local _, _, scaled = AnimalMoveEvent._getScaledButcherUnits(two, BULL, bull)
    check(string.format("butcher: two meat productions are AMBIGUOUS; delivery would use the first (%.2f units, same as the delivery path)",
        quote.deliveryInputQuantity), quote.status == Q.AMBIGUOUS and quote.inputQuantity == nil
        and quote.deliveryRecipeId == "cows_processing" and near6(quote.deliveryInputQuantity, scaled)
        and has(quote.notes, "DELIVERY_USES_FIRST:cows_processing"))
end

-- Insemination system: COW_HOLSTEIN in, a live cow out - a whole head, no carcass yield.
do
    local mvb = HB.newFarmButcher(SUBS, { productions = {} , eao_specs = { { animals = { { inputFillTypeIndex = HB.FILLTYPES.BEEF } } } } })
    mvb.eppAnimalInputUnitsByFillType[HB.FILLTYPES.BEEF] = 1000
    local light = animal(COW, 300)
    local quote = Q.quoteAnimal(light, mvb, 1)
    check("conversion: whole head of 1000 units whatever the weight, no meat figure",
        quote.semantics == Q.ANIMAL_CONVERSION and quote.inputQuantity == 1000 and quote.effectiveRecipeMeat == nil
        and has(quote.notes, "NO_CARCASS_YIELD"))
    check("conversion: delivery path does not scale it either", AnimalMoveEvent._getScaledButcherUnits(mvb, COW, light) == nil)
end

-- A husbandry takes heads.
do
    local pen = { spec_husbandryAnimals = {}, animalSubTypeToFillType = nil, isServer = true }
    function pen:getName() return "Pen" end
    local quote = Q.quoteAnimal(bull, pen, 1)
    check("husbandry: HEAD, one head", quote.semantics == Q.HEAD and quote.inputQuantity == 1 and quote.status == Q.SUPPORTED)
end

-- Facility that does not take the animal, and a calf below the facility minimum.
do
    local quote = Q.quoteAnimal(animal(STALLION, 500), butcher, 1)
    check("not accepted: UNSUPPORTED (NOT_ACCEPTED)", quote.status == Q.UNSUPPORTED and has(quote.reasons, "NOT_ACCEPTED"))
    quote = Q.quoteAnimal(animal(BULL, 120, { age = 3 }), house, 1)
    check("too young: reason TOO_YOUNG, status not SUPPORTED", quote.status == Q.UNKNOWN and has(quote.reasons, "TOO_YOUNG"))
end

-- Quoting changes nothing: animal, orders, wallet, storage, recipes, queues, random draws.
do
    local function deep(value, seen)
        if type(value) ~= "table" then return tostring(value) end
        seen = seen or {}
        if seen[value] then return "<cycle>" end
        seen[value] = true
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            if type(value[k]) ~= "function" then parts[#parts + 1] = tostring(k) .. "=" .. deep(value[k], seen) end
        end
        seen[value] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end

    -- Body condition on for cattle, so its factor is read too; the bull has no state yet.
    AnimalType = { COW = 1, HORSE = -1 }
    local cow = animal(ANGUS, 610, { animalTypeIndex = 1, bodyCondition = { reserve = 0.8 } })
    bull.animalTypeIndex = 1
    local state = function()
        return deep({ bull = bull, cow = cow, house = house, butcher = butcher, money = MONEY,
            config = AnimalMoveEvent.carcassConfig })
    end

    local counts = { random = 0, align = 0, ensure = 0 }
    local saved = { random = math.random, align = AnimalMoveEvent.alignContractRecipes, ensure = RLBodyCondition.ensureState }
    math.random = function(...) counts.random = counts.random + 1 return saved.random(...) end
    AnimalMoveEvent.alignContractRecipes = function(...) counts.align = counts.align + 1 return saved.align(...) end
    RLBodyCondition.ensureState = function(...) counts.ensure = counts.ensure + 1 return saved.ensure(...) end

    local before, moneyBefore, callsBefore = state(), moneyCalls, #house.calls + #butcher.calls
    local first = Q.quoteAnimal(bull, house, 1)
    local once = state()
    local last
    for _ = 1, 100 do
        Q.quoteAnimal(cow, house, 1)
        Q.quoteAnimal(cow, butcher, 1)
        last = Q.quoteAnimal(bull, house, 1)
    end
    local after = state()

    math.random, AnimalMoveEvent.alignContractRecipes, RLBodyCondition.ensureState = saved.random, saved.align, saved.ensure
    local conditionRead = AnimalMoveEvent.getCarcassYield(cow, house, ANGUS).conditionFactor
    AnimalType, bull.animalTypeIndex = nil, nil
    check(string.format("no side effects: the condition factor was in play (%.3f) and the bull got no state", conditionRead),
        conditionRead < 1 and bull.bodyCondition == nil)
    check("no side effects: one quote leaves animals, orders, wallet, storage, recipes and config unchanged", before == once)
    check("no side effects: 301 more quotes leave them unchanged and give the same answer",
        before == after and near6(first.effectiveRecipeMeat, last.effectiveRecipeMeat) and near6(first.cashDue, last.cashDue))
    check(string.format("no side effects: no money, delivery, alignment, state set-up or random calls (%d/%d/%d/%d/%d)",
        moneyCalls - moneyBefore, #house.calls + #butcher.calls - callsBefore, counts.align, counts.ensure, counts.random),
        moneyCalls == moneyBefore and #house.calls + #butcher.calls == callsBefore and counts.align == 0
        and counts.ensure == 0 and counts.random == 0)
end

-- Pure layers: describe and quote run on snapshots alone.
do
    local snapshot = Q.snapshotFacility(house, BULL, 1)
    local role = Q.getRole(BULL)
    local saved = { g_currentMission = g_currentMission, AnimalMoveEvent = AnimalMoveEvent, g_fillTypeManager = g_fillTypeManager }
    g_currentMission, AnimalMoveEvent, g_fillTypeManager = nil, nil, nil
    local ok, quote = pcall(function()
        local d = Q.describeFacility(snapshot, role)
        return Q.quote({ factor = 1, modelMeat = 270, meatPerHead = 270 }, {}, d, { age = 20 })
    end)
    g_currentMission, AnimalMoveEvent, g_fillTypeManager = saved.g_currentMission, saved.AnimalMoveEvent, saved.g_fillTypeManager
    check("pure: describe and quote on a snapshot need no game globals", ok and quote.matches and near6(quote.effectiveRecipeMeat, 270))
end

-- Console report: the list shows the 1000 -> 270 state as it is now, quotes print per animal,
-- and neither changes anything.
do
    loadMod("scripts/console/RLTradeReportConsole.lua")
    local lines = {}
    local savedPrint = print
    print = function(text) lines[#lines + 1] = text end
    local function run(...)
        lines = {}
        local result = RLTradeReportConsole:report(...)
        return result, table.concat(lines, "\n")
    end

    local unaligned = HB.newSlaughterhouse(SUBS)
    function unaligned:getName() return "Old slaughterhouse" end
    local butcherPlaceable = { spec_extendedProductionPoint = { productionPoint = butcher } }
    function butcherPlaceable:getName() return "Farm butcher" end
    local pen = { animals = { bull, animal(ANGUS, 600, { uniqueId = "B2" }) } }
    function pen:getName() return "Bull barn" end
    function pen:getClusters() return self.animals end
    function pen:getOwnerFarmId() return 1 end
    -- Another farm's pen of the same name and an animal with the same uniqueId.
    local otherPen = { animals = { animal(ANGUS, 610, { uniqueId = "B2" }), animal(BULL, 500, { uniqueId = "X9" }) } }
    function otherPen:getName() return "Bull barn" end
    function otherPen:getClusters() return self.animals end
    function otherPen:getOwnerFarmId() return 2 end

    g_currentMission.placeableSystem = { placeables = { house, unaligned, butcherPlaceable, pen, otherPen } }
    g_currentMission.husbandrySystem = { placeables = { pen, otherPen } }
    g_currentMission.getFarmId = function() return 1 end
    g_currentMission.getIsServer = function() return true end

    local before = moneyCalls .. #house.calls .. #butcher.calls
    local result, text = run()
    check("console list: three facilities, aligned and unaligned BEEF reported as they are",
        result:find("3 facilities") ~= nil and text:find("== 1 Slaughterhouse") ~= nil
        and text:find("270.000 kg BEEFMEAT per input unit, model 270.000 kg per typical animal %-> ALIGNED %(map shipped 1000.0%)") ~= nil
        and text:find("1000.000 kg BEEFMEAT per input unit, model 270.000 kg per typical animal %-> MISALIGNED") ~= nil)
    check("console list: MILKCOW mix, fee source and butcher running cost shown",
        text:find("MIXED_INPUT:MILKCOW") ~= nil and text:find("RLRM cutting fee") ~= nil and text:find("per active hour") ~= nil)

    result, text = run("old", bull.uniqueId)
    check("console quote: the unaligned facility prints the mismatch for the bull",
        text:find("MISMATCH") ~= nil and text:find("958.6") ~= nil and text:find("258.8") ~= nil)
    result, text = run("1", "pen:bull")
    check("console quote: by pen, both animals, aligned facility matches",
        text:find("2 animal%(s%)") ~= nil and select(2, text:gsub("matches", "")) == 2)
    result, text = run("butcher", "B2", "1")
    check("console quote: butcher in production units", text:find("PRODUCTION_UNIT") ~= nil and text:find("matches") ~= nil)
    result = run("nowhere", "A1")
    check("console: unknown facility is named", result:find("no facility 'nowhere'") ~= nil)
    result, text = run("1", "pen:bull", "farm:2")
    check("console: farm:2 quotes only farm 2's pen", text:find("2 animal%(s%)") ~= nil and text:find("X9") ~= nil
        and text:find("A1 ") == nil)
    result = run("1", "X9", "1")
    check("console: another farm's animal is not found for farm 1", result:find("no animal 'X9' in farm 1") ~= nil)

    -- A dedicated server's console: no player farm. The list keeps the unit, flags NO_FARM, and farm:1 reads orders.
    g_currentMission.getFarmId = function() return 0 end
    result, text = run()
    check("console list, no farm: weighted batch kept, NO_FARM shown",
        result:find("farm none") ~= nil and text:find("COW       BEEF       WEIGHTED_BATCH") ~= nil and text:find("NO_FARM") ~= nil)
    result, text = run("all", "farm:1")
    check("console list, farm:1: the open order is read", result:find("farm 1") ~= nil and text:find("%(order 1%)") ~= nil)
    g_currentMission.getFarmId = function() return 1 end

    g_currentMission.getIsServer = function() return false end
    local clientHouse = HB.newSlaughterhouse(SUBS, { isServer = false })
    AnimalMoveEvent.alignContractRecipes(clientHouse)
    g_currentMission.placeableSystem.placeables = { clientHouse }
    result, text = run("1", bull.uniqueId)
    check("console client: quotes marked not authoritative", text:find("not authoritative") ~= nil)

    print = savedPrint
    check("console: no money, delivery or production calls", before == moneyCalls .. #house.calls .. #butcher.calls)
end
