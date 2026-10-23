-- Husbandries that are still under construction (RLPenConstruction): Hof Bergmann's calf igloos sit
-- in SETUP (1000 CALFIGLU missing) and must take no animal until DONE, on every path in - the
-- destination lists, the real AnimalBuyEvent / AnimalMoveEvent runs, the herdsman's buy and move -
-- while animals already inside stay, are logged and can leave.

g_currentModDirectory = REPO
XMLFile = { loadIfExists = function(_, path) return loadXMLFileFromDisk(path) end }
RLMapBridge = { activeBridges = { { resolvedConfigPath = "mod_support/FS25_HofBergmann/v1.5/" } } }

-- Engine pieces the scripts hook or call -----------------------------------------------------------

Utils = {
    appendedFunction = function(old, new) return function(...) old(...); new(...) end end,
    overwrittenFunction = function(old, new) return function(self, ...) return new(self, old, ...) end end,
}
ConstructibleState = { activate = function() end }
MoneyType = { NEW_ANIMALS_COST = "NEW_ANIMALS_COST", HERDSMAN_WAGES = "HERDSMAN_WAGES" }
getTimeSec = function() return 0 end
g_i18n = { getText = function(_, key) return key end, formatMoney = function(_, v) return tostring(v) end }
g_messageCenter = { publish = function() end }
AnimalType = { COW = 1 }

-- The base game's event classes as far as RLRM's scripts lean on them: codes, reply constructors,
-- and the base buy check (subtype, space, money) that RLRM's validate wraps.
local function reply(class) return function(code) return setmetatable({ errorCode = code }, { __index = class }) end end
AnimalBuyEvent = { BUY_SUCCESS = 0, BUY_ERROR_NO_PERMISSION = 1, BUY_ERROR_NOT_ENOUGH_MONEY = 2, BUY_ERROR_NOT_ENOUGH_SPACE = 3,
    BUY_ERROR_ANIMAL_NOT_SUPPORTED = 4, BUY_ERROR_ANIMAL_GLOBAL_LIMIT_REACHED = 5, BUY_ERROR_OBJECT_DOES_NOT_EXIST = 6,
    BUY_ERROR_NO_BARN_AVAILABLE = 7 }
AnimalBuyEvent.newServerToClient = reply(AnimalBuyEvent)
AnimalBuyEvent.emptyNew = function() return setmetatable({}, { __index = AnimalBuyEvent }) end
function AnimalBuyEvent.validate(object, subTypeIndex, _, numAnimals, buyPrice, feePrice, farmId)
    if object == nil then return AnimalBuyEvent.BUY_ERROR_OBJECT_DOES_NOT_EXIST end
    if not object:getSupportsAnimalSubType(subTypeIndex) then return AnimalBuyEvent.BUY_ERROR_ANIMAL_NOT_SUPPORTED end
    if object:getNumOfFreeAnimalSlots(subTypeIndex) < numAnimals then return AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_SPACE end
    if g_currentMission:getMoney(farmId) + buyPrice + feePrice < 0 then return AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_MONEY end
    return nil
end
AnimalMoveEvent = { MOVE_SUCCESS = 0, MOVE_ERROR_NO_PERMISSION = 1, MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST = 2,
    MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST = 3, MOVE_ERROR_INVALID_CLUSTER = 4, MOVE_ERROR_ANIMAL_NOT_SUPPORTED = 5,
    MOVE_ERROR_NOT_ENOUGH_SPACE = 6, MOVE_ERROR_NOT_ENOUGH_ANIMALS = 7 }
AnimalMoveEvent.newServerToClient = reply(AnimalMoveEvent)
AnimalScreenDealerFarm = { BUY_ERROR_CODE_MAPPING = { [4] = { warning = true, text = "shop_messageAnimalTypeNotSupported" } } }
AnimalScreenTrailerFarm = { MOVE_TO_FARM_ERROR_CODE_MAPPING = {}, MOVE_TO_TRAILER_ERROR_CODE_MAPPING = {} }
RLAnimalEventRequest = { TIMEOUT_CODE = -1 }
RLTrailerEndpointService = { hasRoom = function(free, queued) return free > queued end }
RLDiseaseSaleGate = { check = function() return true end }
RLAnimalUtil = {
    toKey = function(farmId, uniqueId, country) return tostring(farmId) .. "|" .. tostring(uniqueId) .. "|" .. tostring(country) end,
}
RLAnimalUtil.toKeyFromIdentifiers = function(id) return RLAnimalUtil.toKey(id.farmId, id.uniqueId, id.country) end

-- Cattle as RLRM registers them on Hof Bergmann (enough of them for every pen's profile).
local SUBS = {
    { name = "COW_HOLSTEIN", gender = "female", breed = "HOLSTEIN" },
    { name = "BULL_HOLSTEIN", gender = "male", breed = "HOLSTEIN" },
    { name = "COW_ANGUS", gender = "female", breed = "ANGUS" },
    { name = "BULL_ANGUS", gender = "male", breed = "ANGUS" },
}
local BY_NAME, COW_TYPE = {}, { name = "COW", subTypes = {} }
for i, sub in ipairs(SUBS) do
    sub.subTypeIndex, sub.typeIndex, sub.reproductionMinAgeMonth = i, 1, 12
    sub.visuals = { { minAge = 0, visualAnimalIndex = 1 } }
    BY_NAME[sub.name] = i
    COW_TYPE.subTypes[i] = i
end

-- The farm, the dealer and the money: every mutation a buy or move makes is recorded.
local MONEY, removedFromDealer, moneyChanges, broadcasts = {}, {}, {}, {}
g_currentMission = {
    animalSystem = {
        getSubTypeByIndex = function(_, i) return SUBS[i] end,
        getTypeByIndex = function(_, i) return i == 1 and COW_TYPE or nil end,
        getVisualByAge = function() return { visualAnimalIndex = 1 } end,
        removeSaleAnimal = function(_, typeIndex, country, farmId, uniqueId) removedFromDealer[#removedFromDealer + 1] = uniqueId end,
    },
    getMoney = function(_, farmId) return MONEY[farmId] or 0 end,
    addMoney = function(_, amount, farmId, moneyType)
        MONEY[farmId] = (MONEY[farmId] or 0) + amount
        moneyChanges[#moneyChanges + 1] = { amount = amount, farmId = farmId, moneyType = moneyType }
    end,
    getHasPlayerPermission = function() return true end,
    userManager = { getUniqueUserIdByConnection = function(_, c) return c.user end },
    accessHandler = { canFarmAccess = function(_, farmId, object) return object.farmId == nil or object.farmId == farmId end },
}
local FARM = { farmId = 1 }
g_farmManager = {
    getFarmForUniqueUserId = function() return FARM end,
    getFarmById = function(_, id) return id == 1 and { money = MONEY[1] } or nil end,
}
g_server = { broadcastEvent = function(_, event, runLocal) broadcasts[#broadcasts + 1] = event; if runLocal then event:run() end end }

-- Every log record, so the RLPEN lines can be read back (RLPEN_DUMP=path appends them as log lines).
RECORDS = {}
local emit = RLPenLog.emit
RLPenLog.emit = function(kind, data, warn)
    local line = emit(kind, data, warn)
    RECORDS[#RECORDS + 1] = { kind = kind, data = data, line = line, warn = warn == true }
    DUMP(line)
    return line
end
local function records(kind)
    local list = {}
    for _, r in ipairs(RECORDS) do if r.kind == kind then list[#list + 1] = r end end
    return list
end

-- The modules under test, the gate reloaded so it hooks ConstructibleState.activate.
loadMod("scripts/bridge/RLPenConstruction.lua")
loadMod("scripts/bridge/RLHusbandryProfiles.lua")
loadMod("scripts/utils/RLMoveDestinationHelper.lua")
loadMod("scripts/animals/shop/events/AnimalBuyEvent.lua")
loadMod("scripts/animals/shop/events/AnimalMoveEvent.lua")
loadMod("scripts/animals/shop/events/AIAnimalBuyEvent.lua")
loadMod("scripts/animals/shop/events/AIAnimalMoveEvent.lua")
loadMod("scripts/gui/rlmenu/services/RLAnimalBuyService.lua")
loadMod("scripts/herdsman/RLHerdsmanExecutor.lua")
RLAnimalBuyService.computeBuyPrice = function(animal) return animal.price or 1000 end

-- Placeables -------------------------------------------------------------------------------------------

-- A construction state machine as PlaceableConstructible:onLoad builds it from the map XML.
local function machine(states, transitions)
    local spec = { stateMachine = {}, stateNameToIndex = {}, stateTransitions = {}, stateIndex = -1 }
    for i, s in ipairs(states) do
        local state = setmetatable({ name = s.name, inputs = {} }, { __index = ConstructibleState })
        for _, input in ipairs(s.inputs or {}) do
            state.inputs[#state.inputs + 1] = { fillType = { name = input[1] }, amount = input[2], remainingAmount = input[2] }
        end
        spec.stateMachine[i] = state
        spec.stateNameToIndex[s.name] = i
    end
    for from, to in pairs(transitions) do spec.stateTransitions[spec.stateNameToIndex[from]] = spec.stateNameToIndex[to] end
    return spec
end
local IGLOO_STATES = { { name = "SETUP", inputs = { { "CALFIGLU", 1000 } } }, { name = "FINALIZE" }, { name = "DONE" } }
local IGLOO_FLOW = { SETUP = "FINALIZE", FINALIZE = "DONE" }

local nextId = 0
local function makePen(config, name, maxAnimals, constructible)
    nextId = nextId + 1
    local p = { configFileName = "/mods/FS25_HofBergmann/" .. config, uniqueId = "pen" .. nextId, farmId = 1, isServer = true,
        animals = {}, maxAnimals = maxAnimals, added = {},
        spec_husbandryAnimals = { animalTypeIndex = 1 },
        spec_husbandryFood = { fillLevels = { [1] = 40, [2] = 0 } } }
    function p:getName() return name end
    function p:getOwnerFarmId() return self.farmId end
    function p:getNumOfAnimals() return #self.animals end
    function p:getMaxNumOfAnimals() return self.maxAnimals end
    function p:getNumOfFreeAnimalSlots() return self.maxAnimals - #self.animals end
    function p:getSupportsAnimalSubType(i)
        local allowed = self.spec_husbandryAnimals.subtypeFilterAllowedSubTypes
        return allowed == nil or allowed[i] == true
    end
    function p:addAnimals(list) for _, a in ipairs(list) do self.animals[#self.animals + 1] = a; self.added[#self.added + 1] = a end end
    function p:getAnimalTypeIndex() return 1 end
    local clusters = { getClusters = function() return p.animals end }
    function clusters:getClusterById(key)
        for _, a in ipairs(p.animals) do if RLAnimalUtil.toKey(a.farmId, a.uniqueId, a.birthday.country) == key then return a end end
    end
    p.spec_husbandryAnimals.clusterSystem = clusters
    function p:getClusterSystem() return clusters end
    if constructible ~= nil then
        p.spec_constructible = machine(constructible.states, constructible.flow)
        for _, state in ipairs(p.spec_constructible.stateMachine) do state.constructible = p end
        function p:getConstructibleStateIndexByName(n) return self.spec_constructible.stateNameToIndex[n:upper()] end
    end
    return p
end

--- A state change as PlaceableConstructible:setConstructibleState makes it: the index first, then
--- the new state's activate (where RLRM's record hook sits).
local function setState(p, name)
    local spec = p.spec_constructible
    spec.stateIndex = spec.stateNameToIndex[name]
    spec.stateMachine[spec.stateIndex]:activate()
end

local idCounter = 0
local function calf(name, age, extra)
    idCounter = idCounter + 1
    local sub = SUBS[BY_NAME[name]]
    local a = { subTypeIndex = sub.subTypeIndex, animalTypeIndex = 1, age = age, gender = sub.gender, isCastrated = false,
        farmId = 1, uniqueId = "a" .. idCounter, birthday = { country = 1 }, health = 100, weight = 45, price = 1000 }
    function a:getIdentifiers() return self.farmId .. "-" .. self.uniqueId end
    function a:setRecentlyBoughtByAI() end
    function a:getTranportationFee()return 50 end
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end

local function igloo(n)
    local p = makePen("placeables/animalHusbandry/calfIglus/calfIglu0" .. n .. ".xml", "Calf igloo 0" .. n, 1,
        { states = IGLOO_STATES, flow = IGLOO_FLOW })
    setState(p, "SETUP")
    RLHusbandryProfiles.apply(p)
    return p
end

local setup1 = igloo(1)
local done2 = igloo(2)
local boxA = makePen("placeables/animalHusbandry/bullStable/bullCalfZone01.xml", "Calf rearing box A (bulls)", 3)
RLHusbandryProfiles.apply(boxA)
local dairy = makePen("placeables/animalHusbandry/cowHusbandryOldFarm/cowHusbandryOldFarm.xml", "Cow barn (farm)", 30,
    { states = { { name = "STEP1", inputs = { { "MILKTANK", 1000 } } }, { name = "STEP2", inputs = { { "MILKROBOT", 1000 } } },
        { name = "FINALIZE" }, { name = "DONE" } }, flow = { STEP1 = "STEP2", STEP2 = "FINALIZE", FINALIZE = "DONE" } })
setState(dairy, "STEP1")
RLHusbandryProfiles.apply(dairy)
local pasture = makePen("placeables/constructibles/constructible_cowPasture.xml", "Cow pasture (buildable)", 20,
    { states = { { name = "SETUP", inputs = { { "CONSTRUCTIONTOOLS", 500 } } }, { name = "STATE_1" }, { name = "FINALIZE" }, { name = "DONE" } },
      flow = { SETUP = "STATE_1", STATE_1 = "FINALIZE", FINALIZE = "DONE" } })
setState(pasture, "SETUP")
RLHusbandryProfiles.apply(pasture)
g_currentMission.placeableSystem = { placeables = { setup1, done2, boxA, dairy, pasture } }

-- Config ------------------------------------------------------------------------------------------------

local config = RLHusbandryProfiles.getConfig()
check("config: 8 <construction> entries; igloos and pasture ready only in DONE, the cow barn in all four states",
    #config.constructions == 8 and table.concat(RLPenConstruction.getDefinition(setup1).names, " ") == "DONE"
    and table.concat(RLPenConstruction.getDefinition(dairy).names, " ") == "DONE FINALIZE STEP1 STEP2"
    and table.concat(RLPenConstruction.getDefinition(pasture).names, " ") == "DONE")

-- C01 status ---------------------------------------------------------------------------------------------

local s = RLPenConstruction.getStatus(setup1)
check("C01 igloo in SETUP: NOT_READY / UNFINISHED_STATE, 1000 CALFIGLU missing, state read by name",
    s.status == "NOT_READY" and not s.admit and s.reason == "UNFINISHED_STATE" and s.stateName == "SETUP"
    and s.stateIndex == 1 and s.numStates == 3 and #s.unfinishedInputs == 1
    and s.unfinishedInputs[1].fillType == "CALFIGLU" and s.unfinishedInputs[1].remaining == 1000)
setState(done2, "FINALIZE")
check("C01 FINALIZE takes no animal", not RLPenConstruction.canAdmit(done2)
    and RLPenConstruction.getStatus(done2).reason == "UNFINISHED_STATE")
setState(done2, "DONE")
check("C01 DONE: READY / READY_STATE", RLPenConstruction.canAdmit(done2) and RLPenConstruction.getStatus(done2).status == "READY")
check("C01 the farm cow barn takes animals in STEP1 (its construction is milking equipment only)",
    RLPenConstruction.canAdmit(dairy) and RLPenConstruction.getStatus(dairy).reason == "READY_STATE")
check("C01 the buildable pasture in SETUP takes none", not RLPenConstruction.canAdmit(pasture))
check("C01 a pen without construction is READY / NO_CONSTRUCTION (unchanged)",
    RLPenConstruction.canAdmit(boxA) and RLPenConstruction.getStatus(boxA).reason == "NO_CONSTRUCTION"
    and RLPenConstruction.describe(boxA).present == false)
check("C01 not a husbandry: no opinion", RLPenConstruction.canAdmit({ spec_constructible = machine(IGLOO_STATES, IGLOO_FLOW) }))

-- C05.4: state names, not indices; missing state and missing definition are named.
local reordered = makePen("placeables/animalHusbandry/calfIglus/calfIglu03.xml", "igloo, states reordered", 1,
    { states = { { name = "DONE" }, { name = "FINALIZE" }, { name = "SETUP", inputs = { { "CALFIGLU", 1000 } } } },
      flow = { SETUP = "FINALIZE", FINALIZE = "DONE" } })
setState(reordered, "DONE")
local readyAt1 = RLPenConstruction.canAdmit(reordered)
setState(reordered, "SETUP")
check("C05.4 another state order: DONE at index 1 is ready, SETUP at index 3 is not (no index hard coded)",
    readyAt1 and not RLPenConstruction.canAdmit(reordered) and RLPenConstruction.getStatus(reordered).stateIndex == 3)
local renamed = makePen("placeables/animalHusbandry/calfIglus/calfIglu04.xml", "igloo, states renamed", 1,
    { states = { { name = "BUILD" }, { name = "FINISHED" } }, flow = { BUILD = "FINISHED" } })
setState(renamed, "FINISHED")
check("C05.4 bridge names match none of the building's states: UNKNOWN / DEFINITION_UNRESOLVED, refused",
    not RLPenConstruction.canAdmit(renamed) and RLPenConstruction.getStatus(renamed).status == "UNKNOWN"
    and RLPenConstruction.getStatus(renamed).reason == "DEFINITION_UNRESOLVED")
local noState = makePen("placeables/animalHusbandry/calfIglus/calfIglu05.xml", "igloo, before placement", 1,
    { states = IGLOO_STATES, flow = IGLOO_FLOW })
check("C05.4 no current state (index -1): UNKNOWN / NO_STATE, refused",
    not RLPenConstruction.canAdmit(noState) and RLPenConstruction.getStatus(noState).reason == "NO_STATE")
local otherMap = makePen("placeables/someOtherMapIgloo.xml", "other map igloo", 1, { states = IGLOO_STATES, flow = IGLOO_FLOW })
setState(otherMap, "SETUP")
local otherSetup = RLPenConstruction.getStatus(otherMap)
setState(otherMap, "DONE")
local otherDone = RLPenConstruction.getStatus(otherMap)
check("C05.4 no bridge entry: UNKNOWN / NO_DEFINITION while building (refused), UNCHECKED in the final state (taken)",
    otherSetup.status == "UNKNOWN" and otherSetup.reason == "NO_DEFINITION" and not otherSetup.admit
    and otherDone.status == "UNCHECKED" and otherDone.reason == "NO_DEFINITION_FINAL_STATE" and otherDone.admit)

-- C02 destination lists --------------------------------------------------------------------------------

local terminalBuilding = makePen("placeables/otherTerminalPen.xml", "terminal pen with materials missing", 1,
    { states = { { name = "BUILD", inputs = { { "CALFIGLU", 1000 } } } }, flow = {} })
setState(terminalBuilding, "BUILD")
check("terminal state with unfulfilled material inputs is not completed construction",
    not RLPenConstruction.canAdmit(terminalBuilding)
    and RLPenConstruction.getStatus(terminalBuilding).status == "UNKNOWN")

local function names(list)
    local out = {}
    for _, d in ipairs(list) do out[#out + 1] = d.name end
    return table.concat(out, " | ")
end
local heifer = calf("COW_HOLSTEIN", 0)
check("C02 buy destinations: the SETUP igloo is left out, the built one offered (with animals)",
    names(RLMoveDestinationHelper.getValidDestinations(nil, 1, heifer.subTypeIndex, { heifer }))
        == "Calf igloo 02 | Calf rearing box A (bulls)")
check("C02 ... and without animals or with an empty list (the gate does not depend on them)",
    names(RLMoveDestinationHelper.getValidDestinations(nil, 1, heifer.subTypeIndex, nil)) == "Calf igloo 02 | Calf rearing box A (bulls) | Cow barn (farm)"
    and names(RLMoveDestinationHelper.getValidDestinations(nil, 1, heifer.subTypeIndex, {})) == "Calf igloo 02 | Calf rearing box A (bulls) | Cow barn (farm)")
local ok, reason, detail = RLHusbandryProfiles.checkAnimal(setup1, heifer)
check("C02 checkAnimal: PEN_NOT_BUILT with the state in the detail, before breed or age",
    not ok and reason == "PEN_NOT_BUILT" and detail:find("NOT_READY SETUP", 1, true) ~= nil
    and select(2, RLHusbandryProfiles.checkAnimal(setup1, calf("COW_HOLSTEIN", 9))) == "PEN_NOT_BUILT")
local moveResult = RLMoveDestinationHelper.buildMoveValidationResult({ heifer }, { name = "x", placeable = setup1, freeSlots = 1, isEPP = false }, 1)
check("C02 move screen: refused as PEN_NOT_BUILT, not as a breed or age rule",
    #moveResult.valid == 0 and moveResult.rejected[1].reason == "PEN_NOT_BUILT")

-- C02 / C05.1 real buy event --------------------------------------------------------------------------

local function runBuy(target, animals,price,fee)
    local sent = {}
    local event = AnimalBuyEvent.new(target, animals, price or -1000 * #animals, fee or -50)
    event:run(makeConnection("player", false, sent))
    return sent[1] ~= nil and sent[1].errorCode or nil
end
local function snapshot()
    return { money = MONEY[1], dealer = #removedFromDealer, changes = #moneyChanges, setup = #setup1.animals, done = #done2.animals }
end
local function same(a, b) return a.money == b.money and a.dealer == b.dealer and a.changes == b.changes and a.setup == b.setup and a.done == b.done end

MONEY[1] = 100000
RECORDS = {}
local before = snapshot()
local code = runBuy(setup1, { heifer })
local buyCheck = records("BUY_CHECK")[1]
check("C05.1 SETUP igloo with room, money and a legal 0-month heifer: AnimalBuyEvent:run answers PEN_NOT_BUILT (8)",
    code == AnimalBuyEvent.BUY_ERROR_PEN_NOT_BUILT and code == 8)
check("C05.1 ... money, dealer stock, the pen and the money log unchanged", same(before, snapshot()) and #setup1.added == 0)
check("C02/C04 BUY_CHECK record: errorCode 8 and the construction gate in the same record",
    buyCheck ~= nil and buyCheck.data.errorCode == 8 and buyCheck.data.verdict.construction.status == "NOT_READY"
    and buyCheck.data.verdict.construction.stateName == "SETUP" and buyCheck.data.verdict.construction.ready == false
    and buyCheck.data.verdict.construction.unfinishedInputs[1].fillType == "CALFIGLU"
    and buyCheck.data.verdict.rlrm.reason == "PEN_NOT_BUILT" and buyCheck.data.verdict.profile == "NURSERY")
MONEY[1] = 0
check("C02 not built outranks no money (the building is the first thing wrong)", runBuy(setup1, { calf("COW_HOLSTEIN", 0) }) == 8)
MONEY[1] = 100000
check("C02 a nil object is still OBJECT_DOES_NOT_EXIST", AnimalBuyEvent.validate(nil, 1, 0, 1, 0, 0, 1) == AnimalBuyEvent.BUY_ERROR_OBJECT_DOES_NOT_EXIST)
check("C02 the base screens and RLRM's menu get a text for code 8",
    AnimalScreenDealerFarm.BUY_ERROR_CODE_MAPPING[8].text == "rl_ui_penNotBuilt"
    and AnimalScreenTrailerFarm.MOVE_TO_FARM_ERROR_CODE_MAPPING[8].text == "rl_ui_penNotBuilt"
    and RLAnimalBuyService.getErrorText(8) == "rl_ui_penNotBuilt")
local filtered = RLAnimalBuyService.filterBuyableAnimals(setup1, { calf("COW_HOLSTEIN", 0) }, 1, AnimalBuyEvent.validate)
check("C02 RLRM buy menu filter: rejected with code 8", #filtered.valid == 0 and filtered.firstErrorCode == 8)

local oldBuyPrice=RLAnimalBuyService.computeBuyPrice
for _,value in ipairs({"nil","throw","negative","nan","inf"})do
    RLAnimalBuyService.computeBuyPrice=function()
        if value=="nil"then return nil elseif value=="throw"then error("quote unavailable")
        elseif value=="negative"then return -1 elseif value=="nan"then return 0/0 else return math.huge end
    end
    local prior=snapshot()
    local refused=runBuy(done2,{heifer})
    check("market buy authority: unavailable "..value.." quote cannot spend client money or move stock",refused~=nil and refused~=AnimalBuyEvent.BUY_SUCCESS and same(prior,snapshot()))
end
RLAnimalBuyService.computeBuyPrice=oldBuyPrice
for _,case in ipairs({{"cheap body",-1,-50},{"positive body",1000,-50},{"free delivery",-1000,0},
    {"positive delivery",-1000,50},{"same total wrong split",-1050,0},{"nan body",0/0,-50},{"nan delivery",-1000,0/0}})do
    local prior=snapshot();local refused=runBuy(done2,{heifer},case[2],case[3])
    check("market buy authority: forged "..case[1].." rejected before assets",refused==AnimalBuyEvent.BUY_ERROR_PRICE_UNAVAILABLE and same(prior,snapshot()))
end
local wire=string.unpack("f",string.pack("f",-1000.12345))
check("market buy authority: real float32 roundtrip allowed without changing server amount",AnimalBuyEvent.matchesWirePrice(wire,-1000.12345))
check("market buy authority: component change above float32 precision refused",not AnimalBuyEvent.matchesWirePrice(-1000.11345,-1000.12345))

-- C05.2: normal construction finishes, the pen opens at once.
local a1 = calf("COW_ANGUS", 1)
local moneyBefore, dealerBefore = MONEY[1], #removedFromDealer
setState(setup1, "FINALIZE")
local finalizeCode = runBuy(setup1, { a1 })
setState(setup1, "DONE")
local offered = names(RLMoveDestinationHelper.getValidDestinations(nil, 1, a1.subTypeIndex, { a1 }))
local doneCode = runBuy(setup1, { a1 })
check("C05.2 FINALIZE still refused (8); at DONE the igloo is offered and the same buy succeeds without a reload",
    finalizeCode == 8 and offered:find("Calf igloo 01", 1, true) ~= nil and doneCode == AnimalBuyEvent.BUY_SUCCESS)
local bought = records("BUY_RESULT")[#records("BUY_RESULT")]
check("C04 BUY_RESULT of the buy at DONE carries the construction state it was bought in",
    bought ~= nil and bought.data.construction.stateName == "DONE" and bought.data.construction.ready == true)
check("C05.2 ... charged exactly price + fee, one animal added, one taken from the dealer",
    MONEY[1] == moneyBefore - 1050 and #setup1.animals == 1 and setup1.animals[1] == a1
    and #removedFromDealer == dealerBefore + 1 and moneyChanges[#moneyChanges].moneyType == "NEW_ANIMALS_COST")

-- A request that was valid when the client sent it, run after the pen fell back to construction.
setup1.animals = {}
RLPenConstruction.started = false
setState(setup1, "SETUP")
before = snapshot()
check("C05.5 a buy sent while DONE and run after the igloo was reset to SETUP: refused, nothing changes",
    runBuy(setup1, { calf("COW_HOLSTEIN", 0) }) == 8 and same(before, snapshot()))

-- C05.3: pens without construction behave as before.
check("C05.3 rearing box (no construction): legal calf bought, a 6-month heifer still refused as not supported",
    runBuy(boxA, { calf("COW_HOLSTEIN", 2) }) == AnimalBuyEvent.BUY_SUCCESS
    and runBuy(boxA, { calf("COW_HOLSTEIN", 6) }) == AnimalBuyEvent.BUY_ERROR_ANIMAL_NOT_SUPPORTED)
boxA.animals, boxA.added = {}, {}

-- C02 real move event ----------------------------------------------------------------------------------

local function runMove(source, target, animal)
    local sent = {}
    local event = setmetatable({ sourceObject = source, targetObject = target, animals = { animal }, moveType = "HUSBANDRY" }, { __index = AnimalMoveEvent })
    event:run(makeConnection("player", false, sent))
    return sent[1] ~= nil and sent[1].errorCode or nil
end
local inBox = calf("COW_HOLSTEIN", 1)
boxA.animals = { inBox }
RECORDS = {}
check("C02 move into the SETUP igloo: AnimalMoveEvent:run answers MOVE_ERROR_PEN_NOT_BUILT (8), the calf stays",
    runMove(boxA, setup1, inBox) == AnimalMoveEvent.MOVE_ERROR_PEN_NOT_BUILT and #boxA.animals == 1 and #setup1.animals == 0)
local moveCheck = records("MOVE_CHECK")[1]
check("C04 MOVE_CHECK record for the refusal: errorCode 8, source pen and the gate in one record",
    moveCheck ~= nil and moveCheck.data.errorCode == 8 and moveCheck.data.ok == false
    and moveCheck.data.source.name == "Calf rearing box A (bulls)" and moveCheck.data.verdict.construction.stateName == "SETUP")
check("C03 moving OUT of an unbuilt igloo is allowed (the gate is on the target only)",
    AnimalMoveEvent.validate(setup1, boxA, 1, inBox.subTypeIndex) == nil
    and names(RLMoveDestinationHelper.getValidDestinations(setup1, 1, inBox.subTypeIndex, { inBox })):find("Calf rearing box A", 1, true) ~= nil)
boxA.animals = {}

-- C02 herdsman buy and move -----------------------------------------------------------------------------

local function execCtx()
    return { server = g_server, mission = g_currentMission, ruleService = {}, animalNameSystem = {},
        husbandryPlaceablesById = { igloo1 = setup1, igloo2 = done2, box = boxA }, defer = function() end }
end
broadcasts = {}
RECORDS = {}
before = snapshot()
local buyAction = { ruleId = "r-buy", operation = "buy", husbandryId = "igloo1", animals = { calf("COW_HOLSTEIN", 0) },
    amountSpent = 1000, wage = 10 }
local summary = RLHerdsmanExecutor.executeActions({ buyAction }, execCtx())
check("C02 herdsman buy into the SETUP igloo: skipped pen-not-built, no event, no animal, only the wage moves",
    summary.results[1].skipReason == "pen-not-built" and not summary.results[1].dispatched and #broadcasts == 0
    and #setup1.animals == 0 and #removedFromDealer == before.dealer and MONEY[1] == before.money - 10)
local herdsmanCheck = records("HERDSMAN_CHECK")[1]
check("C04 HERDSMAN_CHECK record: op buy, errorCode 8, gate attached",
    herdsmanCheck ~= nil and herdsmanCheck.data.op == "buy" and herdsmanCheck.data.errorCode == 8
    and herdsmanCheck.data.verdict.construction.status == "NOT_READY")

broadcasts = {}
before = snapshot()
summary = RLHerdsmanExecutor.executeActions({ { ruleId = "r-buy2", operation = "buy", husbandryId = "igloo2",
    animals = { calf("COW_HOLSTEIN", 0) }, amountSpent = 1000, wage = 10 } }, execCtx())
check("C05.2 herdsman buy into the built igloo goes through: dispatched, the calf in, price and wage paid",
    summary.results[1].dispatched == true and summary.results[1].skipReason == nil and #done2.animals == 1
    and MONEY[1] == before.money - 1000 - 10 and #removedFromDealer == before.dealer + 1)
done2.animals, done2.added = {}, {}

local mover = calf("COW_HOLSTEIN", 1)
boxA.animals = { mover }
broadcasts = {}
local moveAction = { ruleId = "r-move", operation = "move", husbandryId = "box", destinationHusbandry = "igloo1",
    animals = { { farmId = 1, uniqueId = mover.uniqueId, country = 1, subTypeIndex = mover.subTypeIndex } }, wage = 0 }
summary = RLHerdsmanExecutor.executeActions({ moveAction }, execCtx())
check("C02 herdsman move into the SETUP igloo: skipped pen-not-built, nothing dispatched, the calf stays",
    summary.results[1].skipReason == "pen-not-built" and #broadcasts == 0 and #boxA.animals == 1 and #setup1.animals == 0)

-- The AI events' own backstops: a dispatched event that meets an unbuilt pen changes nothing.
before = snapshot()
RECORDS = {}
AIAnimalBuyEvent.new(setup1, { calf("COW_HOLSTEIN", 0) }, 1000):run()
check("C05.5 AIAnimalBuyEvent run against the SETUP igloo: dealer, pen and money untouched, AI_BUY_REFUSED logged",
    same(before, snapshot()) and #records("AI_BUY_REFUSED") == 1 and records("AI_BUY_REFUSED")[1].data.errorCode == 8)
AIAnimalMoveEvent.new(boxA, setup1, moveAction.animals):run()
check("C05.5 AIAnimalMoveEvent run against the SETUP igloo: the calf stays in the box",
    #boxA.animals == 1 and #setup1.animals == 0 and records("AI_MOVE_CHECK")[1].data.ok == false)
boxA.animals = {}

-- Wire: code 8 needs 4 bits ------------------------------------------------------------------------------

local wire = {}
streamWriteUIntN = function(_, value, bits) wire[#wire + 1] = { value = value, bits = bits } end
streamReadUIntN = function(_, bits) local w = table.remove(wire, 1); return w.bits == bits and w.value or -1 end
local serverConnection = { getIsServer = function() return false end }
AnimalBuyEvent.newServerToClient(8):writeStream(1, serverConnection)
AnimalMoveEvent.newServerToClient(8):writeStream(1, serverConnection)
local written = { wire[1].bits, wire[2].bits }
local readBuy = AnimalBuyEvent.emptyNew()
readBuy.run = function() end
readBuy:readStream(1, { getIsServer = function() return true end })
local readMove = setmetatable({ run = function() end }, { __index = AnimalMoveEvent })
readMove:readStream(1, { getIsServer = function() return true end })
check("wire: buy and move replies written in 4 bits, code 8 reads back intact",
    written[1] == 4 and written[2] == 4 and readBuy.errorCode == 8 and readMove.errorCode == 8)

-- C03 residents of unbuilt pens -------------------------------------------------------------------------

setup1.animals = {}
local resident = calf("COW_ANGUS", 1, { health = 0, weight = 0.001 })
setup1.animals = { resident }
RECORDS = {}
RLPenConstruction.started = false
RLPenConstruction.onMissionStarted()
local invalid = records("INVALID_RESIDENT_UNBUILT")
check("C03 load: the calf in the SETUP igloo is logged INVALID_RESIDENT_UNBUILT (warning) with identity, age, health, weight, trough, missing input",
    #invalid == 1 and invalid[1].warn and invalid[1].data.trigger == "LOAD" and invalid[1].data.animal.uniqueId == resident.uniqueId
    and invalid[1].data.animal.age == 1 and invalid[1].data.animal.health == 0 and invalid[1].data.animal.weight == 0.001
    and invalid[1].data.trough ~= nil and invalid[1].data.construction.unfinishedInputs[1].remaining == 1000)
check("C03 ... left exactly as it was (not sold, moved, healed or fed; the igloo not built)",
    #setup1.animals == 1 and setup1.animals[1] == resident and resident.health == 0 and resident.weight == 0.001
    and RLPenConstruction.getStatus(setup1).stateName == "SETUP")
local loadStates = records("CONSTRUCTION_STATE")
check("C04 load: a CONSTRUCTION_STATE record for every constructible husbandry (igloos, cow barn, pasture)",
    #loadStates == 4 and loadStates[1].data.trigger == "LOAD")

RECORDS = {}
RLPenConstruction.checkResidents(setup1, "DAY")
check("C03 next day: the same resident logged again, not as new", #records("INVALID_RESIDENT_UNBUILT") == 1
    and not records("INVALID_RESIDENT_UNBUILT")[1].warn)
local newborn = calf("COW_ANGUS", 0, { motherId = resident:getIdentifiers() })
local stray = calf("COW_HOLSTEIN", 1)
setup1.animals = { resident, newborn, stray }
RECORDS = {}
RLPenConstruction.checkResidents(setup1, "DAY")
check("C03 a calf born in the unbuilt igloo is RESIDENT_BORN_UNBUILT, kept (birth is not a buy)",
    #records("RESIDENT_BORN_UNBUILT") == 1 and records("RESIDENT_BORN_UNBUILT")[1].data.animal.uniqueId == newborn.uniqueId
    and #setup1.animals == 3)
check("C03/C04 an animal that appeared another way is ADMITTED_WHILE_UNBUILT (the analyzer's FAIL)",
    #records("ADMITTED_WHILE_UNBUILT") == 1 and records("ADMITTED_WHILE_UNBUILT")[1].data.animal.uniqueId == stray.uniqueId)
setup1.animals = { resident }

-- C04 construction progress -----------------------------------------------------------------------------

RECORDS = {}
setState(setup1, "FINALIZE")
setState(setup1, "DONE")
local changes = records("CONSTRUCTION_STATE")
check("C04 SETUP -> FINALIZE -> DONE: two CHANGE records, the second marks the pen opened",
    #changes == 2 and changes[1].data.from.stateName == "SETUP" and changes[1].data.construction.stateName == "FINALIZE"
    and changes[1].data.opened == false and changes[2].data.opened == true and changes[2].data.direction == "FORWARD"
    and changes[2].data.construction.ready == true)
RLPenConstruction.checkResidents(setup1, "DAY")
check("C03 once built, its resident is no longer logged as invalid and can stay", #records("INVALID_RESIDENT_UNBUILT") == 0
    and #setup1.animals == 1)
RECORDS = {}
setState(setup1, "SETUP")
local back = records("CONSTRUCTION_STATE")[1]
check("C04 a reset back to SETUP is recorded BACK and closed (warning)",
    back ~= nil and back.data.direction == "BACK" and back.data.closed == true and back.warn)
setState(setup1, "SETUP")
check("C04 activating the same state again writes no record", #records("CONSTRUCTION_STATE") == 1)

-- C04 PROFILE_APPLIED carries the construction state ----------------------------------------------------

RECORDS = {}
local fresh = makePen("placeables/animalHusbandry/calfIglus/calfIglu05.xml", "Calf igloo 05", 1, { states = IGLOO_STATES, flow = IGLOO_FLOW })
setState(fresh, "SETUP")
RLHusbandryProfiles.apply(fresh)
local applied = records("PROFILE_APPLIED")[1]
check("C04 a newly placed igloo's first state is recorded PLACED (no previous state)",
    #records("CONSTRUCTION_STATE") == 1 and records("CONSTRUCTION_STATE")[1].data.trigger == "PLACED"
    and records("CONSTRUCTION_STATE")[1].data.from == nil)
check("C04 PROFILE_APPLIED: construction present, SETUP, not ready, reason, the missing input and the bridge file",
    applied ~= nil and applied.data.construction.present and applied.data.construction.stateName == "SETUP"
    and applied.data.construction.ready == false and applied.data.construction.reason == "UNFINISHED_STATE"
    and applied.data.construction.unfinishedInputs[1].fillType == "CALFIGLU"
    and applied.data.construction.source == "mod_support/FS25_HofBergmann/v1.5/husbandryProfiles.xml"
    and applied.line:find('"stateName":"SETUP"', 1, true) ~= nil)

-- E farm butcher: a production point that takes animals, built SETUP -> STATE_1-3 -> FINALIZE -> DONE ------

local BUTCHER_STATES = { { name = "SETUP", inputs = { { "CONSTRUCTIONTOOLS", 500 } } }, { name = "STATE_1", inputs = { { "WOODBEAM", 1000 } } },
    { name = "STATE_2", inputs = { { "WALLBOARDS", 95 } } }, { name = "STATE_3", inputs = { { "CEMENT", 3000 } } },
    { name = "FINALIZE" }, { name = "DONE" } }
local BUTCHER_FLOW = { SETUP = "STATE_1", STATE_1 = "STATE_2", STATE_2 = "STATE_3", STATE_3 = "FINALIZE", FINALIZE = "DONE" }

-- The map's EPP placeable and its production point (what AnimalMoveEvent carries as the target).
local butcher = { configFileName = "/mods/FS25_HofBergmann/placeables/productionPoints/farmButcher/farmButcher.xml",
    uniqueId = "butcher1", farmId = 1, isServer = true }
function butcher:getName() return "Farm butcher" end
function butcher:getOwnerFarmId() return self.farmId end
local pp = { owningPlaceable = butcher, delivered = {},
    animalsTypeData = { [1] = { minimumAge = 6, maximumAge = 60, maxNumAnimals = 10, unitsPerAnimal = 750 } } }
function pp:getName() return butcher:getName() end
function pp:getSupportsAnimalSubType() return true end
function pp:getNumOfFreeAnimalSlots() return 10 - #self.delivered end
function pp:addCluster(animal) self.delivered[#self.delivered + 1] = animal; return 1 end
function pp:getClusterSystem() return nil end
butcher.spec_extendedProductionPoint = { productionPoint = pp }
butcher.spec_constructible = machine(BUTCHER_STATES, BUTCHER_FLOW)
for _, state in ipairs(butcher.spec_constructible.stateMachine) do state.constructible = butcher end
function butcher:getConstructibleStateIndexByName(n) return self.spec_constructible.stateNameToIndex[n:upper()] end
RLPenConstruction.started = false
setState(butcher, "SETUP")
g_currentMission.placeableSystem.placeables[#g_currentMission.placeableSystem.placeables + 1] = butcher

check("E01 config: the farm butcher is defined, ready only in DONE (8 <construction> entries)",
    #RLHusbandryProfiles.getConfig().constructions == 8
    and table.concat(RLPenConstruction.getDefinition(butcher).names, " ") == "DONE")
check("E01 the production point resolves to its placeable; not a husbandry, not a production point: no building",
    RLPenConstruction.getBuilding(pp) == butcher and RLPenConstruction.getBuilding(butcher) == butcher
    and RLPenConstruction.getBuilding({ animalsTypeData = {} }) == nil and RLPenConstruction.getBuilding(nil) == nil)
local butcherStatus = select(2, RLPenConstruction.canAdmit(pp))
check("E01 butcher in SETUP: the placeable and its production point take no animal (NOT_READY, CONSTRUCTIONTOOLS missing)",
    not RLPenConstruction.canAdmit(butcher) and not RLPenConstruction.canAdmit(pp)
    and butcherStatus.status == "NOT_READY" and butcherStatus.stateName == "SETUP"
    and butcherStatus.unfinishedInputs[1].fillType == "CONSTRUCTIONTOOLS"
    and RLPenConstruction.describe(pp).stateName == "SETUP" and RLPenConstruction.describe(pp).present == true)
setState(butcher, "STATE_3")
local state3 = RLPenConstruction.canAdmit(pp)
setState(butcher, "FINALIZE")
local finalize = RLPenConstruction.canAdmit(pp)
setState(butcher, "SETUP")
check("E01 STATE_3 and FINALIZE still take none", not state3 and not finalize)

local cow = calf("COW_HOLSTEIN", 12)
dairy.animals = { cow }
local function offersButcher(list)
    for _, d in ipairs(list) do if d.name == "Farm butcher" then return d end end
end
check("E02 move menu: the butcher in SETUP is not offered for a 12-month cow; the cow barn's other pens still are judged as before",
    offersButcher(RLMoveDestinationHelper.getValidDestinations(dairy, 1, cow.subTypeIndex, { cow })) == nil
    and offersButcher(RLMoveDestinationHelper.getValidDestinations(dairy, 1, cow.subTypeIndex, nil)) == nil)
check("E03 AnimalMoveEvent.validate to the SETUP butcher's production point: PEN_NOT_BUILT (8)",
    AnimalMoveEvent.validate(dairy, pp, 1, cow.subTypeIndex) == AnimalMoveEvent.MOVE_ERROR_PEN_NOT_BUILT)
check("E03 AnimalMoveEvent:run to the SETUP butcher: answers 8, the cow stays, nothing reaches the butcher",
    runMove(dairy, pp, cow) == AnimalMoveEvent.MOVE_ERROR_PEN_NOT_BUILT and #dairy.animals == 1 and #pp.delivered == 0)
local trailer = { getClusterSystem = function() return nil end }
check("E03 the gate is on the butcher only: a trailer target still has no opinion", RLPenConstruction.canAdmit(trailer))

local function butcherCtx()
    return { server = g_server, mission = g_currentMission, ruleService = {}, animalNameSystem = {},
        husbandryPlaceablesById = { dairy = dairy }, eppPlaceablesById = { butcher = butcher }, defer = function() end }
end
broadcasts = {}
local wageBefore = MONEY[1]
local butcherMove = { ruleId = "r-butcher", operation = "move", husbandryId = "dairy", destinationHusbandry = "butcher",
    animals = { { farmId = 1, uniqueId = cow.uniqueId, country = 1, subTypeIndex = cow.subTypeIndex, age = 12 } }, wage = 10 }
summary = RLHerdsmanExecutor.executeActions({ butcherMove }, butcherCtx())
check("E04 herdsman move to the SETUP butcher: skipped pen-not-built, nothing dispatched, the cow stays, the wage is charged",
    summary.results[1].skipReason == "pen-not-built" and not summary.results[1].dispatched and #broadcasts == 0
    and #dairy.animals == 1 and #pp.delivered == 0 and MONEY[1] == wageBefore - 10)
check("E04 AIAnimalMoveEvent.validate to the SETUP butcher: PEN_NOT_BUILT (8)",
    AIAnimalMoveEvent.validate(dairy, butcher, 1, cow.subTypeIndex) == AnimalMoveEvent.MOVE_ERROR_PEN_NOT_BUILT)
AIAnimalMoveEvent.new(dairy, butcher, butcherMove.animals):run()
check("E04 AIAnimalMoveEvent run against the SETUP butcher (backstop): the cow stays, nothing delivered",
    #dairy.animals == 1 and #pp.delivered == 0)

-- E05 records and opening
RECORDS = {}
RLPenConstruction.started = false
RLPenConstruction.onMissionStarted()
local butcherLoad = nil
for _, r in ipairs(records("CONSTRUCTION_STATE")) do
    if r.data.pen ~= nil and r.data.pen.name == "Farm butcher" then butcherLoad = r end
end
check("E05 load: a CONSTRUCTION_STATE record for the butcher (SETUP, not ready, the missing input)",
    butcherLoad ~= nil and butcherLoad.data.trigger == "LOAD" and butcherLoad.data.construction.stateName == "SETUP"
    and butcherLoad.data.construction.ready == false
    and butcherLoad.data.construction.unfinishedInputs[1].fillType == "CONSTRUCTIONTOOLS")
RECORDS = {}
setState(butcher, "STATE_1")
setState(butcher, "STATE_2")
setState(butcher, "STATE_3")
setState(butcher, "FINALIZE")
setState(butcher, "DONE")
local opened = records("CONSTRUCTION_STATE")
check("E05 SETUP -> ... -> DONE: one CHANGE record per state, only the last one marks the butcher opened",
    #opened == 5 and opened[4].data.construction.stateName == "FINALIZE" and opened[4].data.opened == false
    and opened[5].data.construction.stateName == "DONE" and opened[5].data.opened == true)

local offered = offersButcher(RLMoveDestinationHelper.getValidDestinations(dairy, 1, cow.subTypeIndex, { cow }))
check("E06 at DONE the butcher is offered at once (EPP entry with its age window), and validate passes",
    offered ~= nil and offered.isEPP == true and offered.placeable == pp and offered.minAge == 6 and offered.maxAge == nil
    and AnimalMoveEvent.validate(dairy, pp, 1, cow.subTypeIndex) == nil
    and AIAnimalMoveEvent.validate(dairy, butcher, 1, cow.subTypeIndex) == nil)
dairy.animals = {}
