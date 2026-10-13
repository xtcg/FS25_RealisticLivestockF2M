-- T02 batch 4 (PR #34): the trade ledger saved with the savegame and checked on load
-- (RLTradePersistence, RLTradeRecovery, RLTradeCheckpoint and their hooks).
--
-- Every save here writes real files to a temporary savegame directory and every load reads them
-- back: placeables.xml, vehicles.xml, farms.xml, careerSavegame.xml, rm_RlAnimalSystem.xml (RLRM's
-- own append, the real scripts/core/FSCareerMissionInfo.lua) and rm_RlTradeLedger.xml.
-- Real code: the T02 modules, RLRM's careerSavegame append, the base game's money path
-- (tests/fixtures/fs25_money.lua) and the save pass excerpts (tests/fixtures/fs25_save_pass.lua:
-- Utils, XMLFile.setTable, PlaceableSystem:save, VehicleSystem:save/saveToXML,
-- FarmManager:saveToXMLFile). Engine stand-ins, marked there: the XML reader/writer
-- (tests/fixtures/xml_disk.lua), the reduced career save, the assets' own fields, the farms, the
-- HUD. A simulated file system is no proof of the engine's save, its temporary directory or
-- crash behaviour. Case ids follow docs/T02_TEST_WORKFLOW.md (J group).

loadMod("tests/fixtures/xml_disk.lua")
loadMod("tests/fixtures/fs25_save_pass.lua")
loadMod("tests/fixtures/fs25_money.lua")

MoneyType = { SOLD_ANIMALS = { id = 7, statistic = "soldAnimals" }, HERDSMAN_WAGES = { id = 30, statistic = "herdsmanWages" },
    PRODUCTION_COSTS = { id = 8, statistic = "productionCosts" }, OTHER = { id = 9, statistic = "other" } }
MessageType = { MONEY_CHANGED = "MONEY_CHANGED" }
Logging = { error = function() end }
printError, printCallstack = function() end, function() end
MoneyChangeEvent = { new = function(amount, moneyType, farmId) return { amount = amount, moneyType = moneyType, farmId = farmId } end }
local moneyListener
g_messageCenter = { publish = function(_, kind, ...) if kind == MessageType.MONEY_CHANGED and moneyListener ~= nil then moneyListener(...) end end }
RLAnimalUtil = { toKey = function(farmId, uniqueId, country) return farmId .. " " .. uniqueId .. " " .. country end }
local dateCounter = 0
getDate = function() dateCounter = dateCounter + 1 return string.format("20261007%06d", dateCounter) end

-- The savegame directory: a fresh temporary one per test world.
local function newDirectory()
    local base = os.tmpname()
    os.remove(base)
    assert(os.execute("mkdir -p '" .. base .. "'"))
    return base
end
local function copyFile(from, to)
    local text = XMLDisk.read(from)
    if text == nil then os.remove(to) return end
    XMLDisk.write(to, text)
end
local function listFiles(dir)
    return { "placeables.xml", "vehicles.xml", "farms.xml", "careerSavegame.xml", "rm_RlAnimalSystem.xml", "rm_RlTradeLedger.xml" }
end

-- RLRM's own careerSavegame append (the real file) and what it calls.
local rlrmFiles = 0
RLSettings = { saveToXMLFile = function() rlrmFiles = rlrmFiles + 1 end }
local function animalSystem(dir)
    return { saveToXMLFile = function(_, path)
        local xml = XMLFile.create("rm", path, "animalSystem")
        xml:setString("animalSystem#saved", "1")
        xml:save()
    end }
end

loadMod("scripts/animal/RLTradeTransaction.lua")
loadMod("scripts/animal/RLTradeSourceAdapter.lua")
loadMod("scripts/animal/RLSaleSettlement.lua")
loadMod("scripts/animal/RLSaleRecovery.lua")
loadMod("scripts/animal/RLContractTrade.lua")
loadMod("scripts/animal/RLLiveSale.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/animal/RLTradeRecovery.lua")
loadMod("scripts/animal/RLTradeCheckpoint.lua")
loadMod("scripts/core/FSCareerMissionInfo.lua")
RLTradeCheckpoint.install()
loadMod("scripts/console/RLTradeReportConsole.lua")

local C, P, R, T, S = RLTradeCheckpoint, RLTradePersistence, RLTradeRecovery, RLTradeTransaction, RLSaleSettlement
local function has(text, part) return type(text) == "string" and text:find(part, 1, true) ~= nil end
local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

-- ===========================================================================================
-- The world: farms (money), pens and Hof Bergmann's orders (placeables), trailers (vehicles)
-- ===========================================================================================

local world
local bindMission
local function newPen(uniqueId, keys)
    local pen = { uniqueId = uniqueId, animals = {} }
    for _, key in ipairs(keys or {}) do pen.animals[#pen.animals + 1] = key end
    function pen:saveToXMLFile(xmlFile, key)
        xmlFile:setString(key .. "#uniqueId", self.uniqueId)
        xmlFile:setString(key .. "#kind", self.orders ~= nil and "hb" or "pen")
        for i, animal in ipairs(self.animals) do xmlFile:setString(string.format("%s.animal(%d)#key", key, i - 1), animal) end
        for i, order in ipairs(self.orders or {}) do
            xmlFile:setString(string.format("%s.order(%d)#id", key, i - 1), tostring(order.id))
            xmlFile:setString(string.format("%s.order(%d)#buffered", key, i - 1), string.format("%.17g", order.buffered))
            xmlFile:setString(string.format("%s.order(%d)#ready", key, i - 1), string.format("%.17g", order.ready))
        end
    end
    return pen
end
local function newTrailer(uniqueId, keys)
    local trailer = newPen(uniqueId, keys)
    trailer.spec_livestockTrailer = {}
    function trailer:getNeedsSaving() return true end
    return trailer
end
local function addFarm(id, money)
    local farm = setmetatable(FarmMoney.newFarm(id, money, { "soldAnimals", "herdsmanWages", "productionCosts", "other" }), Farm)
    world.farmsById[id] = farm
    world.farms[#world.farms + 1] = farm
    return farm
end

local function newWorld(dir)
    world = { dir = dir, farms = {}, farmsById = {} }
    world.farms[1] = { farmId = 0 }   -- the spectator farm is never saved
    addFarm(1, 10000)
    addFarm(2, 5000)
    world.pens = { newPen("pen1", { "1 a 1", "1 b 1", "1 c 1", "1 d 1" }), newPen("pen2", { "1 e 1" }) }
    world.hb = newPen("hb", {})
    world.hb.orders = { { id = 1, buffered = 0, ready = 0 } }
    world.trailers = { newTrailer("trailer1", { "1 t 1" }) }
    bindMission()
end

local function info(dir)
    return setmetatable({ savegameDirectory = dir, placeablesXML = dir .. "/placeables.xml", vehiclesXML = dir .. "/vehicles.xml",
        farmsXML = dir .. "/farms.xml" }, FSCareerMissionInfo)
end

function bindMission()
    local placeables = {}
    for _, pen in ipairs(world.pens) do placeables[#placeables + 1] = pen end
    placeables[#placeables + 1] = world.hb
    g_farmManager = setmetatable({ farms = world.farms }, FarmManager)
    function g_farmManager:getFarmById(id) return world.farmsById[id] end
    g_currentMission = {
        missionInfo = info(world.dir), animalSystem = animalSystem(world.dir),
        placeableSystem = setmetatable({ placeables = placeables, version = 1 }, PlaceableSystem),
        vehicleSystem = setmetatable({ vehicles = world.trailers }, VehicleSystem),
        husbandrySystem = { placeables = world.pens },
        missionDynamicInfo = { isMultiplayer = false }, moneyChanges = {},
        hud = { addMoneyChange = function() end, showMoneyChange = function() end },
        getIsServer = function() return world.client ~= true end, getFarmId = function() return 1 end,
        broadcastNotifications = FSBaseMissionMoney.broadcastNotifications, broadcastEventToFarm = function() end,
        addMoney = FSBaseMissionMoney.addMoney, addMoneyChange = FSBaseMissionMoney.addMoneyChange,
    }
    -- The rebind report reads each owner's animals through getClusterSystem.
    for _, owner in ipairs(placeables) do
        function owner:getClusterSystem()
            local list = {}
            for _, key in ipairs(self.animals) do
                local farmId, uniqueId, country = key:match("^(%S+) (%S+) (%S+)$")
                list[#list + 1] = { farmId = farmId, uniqueId = uniqueId, birthday = { country = country } }
            end
            return { animals = list }
        end
    end
    for _, trailer in ipairs(world.trailers) do trailer.getClusterSystem = world.pens[1].getClusterSystem end
end

-- The game's save: the pass, then the engine's end of the save (the career file is written
-- there) and its completion callback. between(): runs after the pass, before the engine ends it.
local function save(errorCode, between)
    XMLDisk.saves = {}
    local ok, err = pcall(function() g_currentMission.missionInfo:saveToXMLFile() end)
    if between ~= nil then between() end
    SavegameController.finishSave(g_currentMission.missionInfo, errorCode, ok)
    return ok, err
end

-- The game's load: the assets from the files, then RLRM's loadMap and onStartMission.
local function load(dir, opts)
    opts = opts or {}
    local old = world
    world = { dir = dir, farms = { { farmId = 0 } }, farmsById = {}, pens = {}, trailers = {}, client = opts.client }
    local farms = XMLFile.loadIfExists("f", dir .. "/farms.xml")
    if farms ~= nil then
        farms:iterate("farms.farm", function(_, key)
            addFarm(farms:getInt(key .. "#farmId"), tonumber(farms:getString(key .. "#money")))
        end)
    end
    local placeables = XMLFile.loadIfExists("p", dir .. "/placeables.xml")
    if placeables ~= nil then
        placeables:iterate("placeables.placeable", function(_, key)
            local keys = {}
            placeables:iterate(key .. ".animal", function(_, a) keys[#keys + 1] = placeables:getString(a .. "#key") end)
            local pen = newPen(placeables:getString(key .. "#uniqueId"), keys)
            if placeables:getString(key .. "#kind") == "hb" then
                pen.orders = {}
                placeables:iterate(key .. ".order", function(_, o)
                    pen.orders[#pen.orders + 1] = { id = tonumber(placeables:getString(o .. "#id")),
                        buffered = tonumber(placeables:getString(o .. "#buffered")), ready = tonumber(placeables:getString(o .. "#ready")) }
                end)
                world.hb = pen
            else
                world.pens[#world.pens + 1] = pen
            end
        end)
    end
    local vehicles = XMLFile.loadIfExists("v", dir .. "/vehicles.xml")
    if vehicles ~= nil then
        vehicles:iterate("vehicles.vehicle", function(_, key)
            local keys = {}
            vehicles:iterate(key .. ".animal", function(_, a) keys[#keys + 1] = vehicles:getString(a .. "#key") end)
            world.trailers[#world.trailers + 1] = newTrailer(vehicles:getString(key .. "#uniqueId"), keys)
        end)
    end
    world.hb = world.hb or newPen("hb", {})
    world.hb.orders = world.hb.orders or { { id = 1, buffered = 0, ready = 0 } }
    bindMission()
    -- RealisticLivestock.loadMap
    RLContractTrade.reset()
    RLLiveSale.reset()
    C.reset(g_currentMission:getIsServer())
    if opts.beforeStart ~= nil then opts.beforeStart() end
    -- RealisticLivestock_FSBaseMission:onStartMission (end)
    if g_currentMission:getIsServer() then C.onMissionStarted(g_currentMission, { identityRepairs = opts.repairs or 0 }) end
    return old
end

local function fresh(dir)
    newWorld(dir or newDirectory())
    RLContractTrade.reset()
    RLLiveSale.reset()
    C.reset(true)
    C.onMissionStarted(g_currentMission, { identityRepairs = 0 })
end

-- -------------------------------------------------------------------------------------------
-- Transactions: real coordinator, real money receipts; the source is the world's pen list
-- -------------------------------------------------------------------------------------------

local function pen(id) for _, p in ipairs(world.pens) do if p.uniqueId == id then return p end end end
local function removeKeys(owner, keys)
    local gone = {}
    for _, key in ipairs(keys) do gone[key] = true end
    local kept = {}
    for _, animal in ipairs(owner.animals) do if not gone[animal] then kept[#kept + 1] = animal end end
    owner.animals = kept
end

-- A live sale of keys from a pen at `each` per head. opts.leave: keys that stay (partial);
-- opts.unknown: the money listener throws (UNKNOWN); opts.during(stage): called inside a stage.
local function sale(owner, keys, each, opts)
    opts = opts or {}
    local store = RLContractTrade.store
    RLLiveSale.sequence = RLLiveSale.sequence + 1
    local farmId = opts.farm or 1
    local id = string.format("ls%d-f%d%s", RLLiveSale.sequence, farmId, C.idTag())
    local resources = { "source:" .. owner.uniqueId, "cash:farm" .. farmId }
    for _, key in ipairs(keys) do resources[#resources + 1] = "animal:" .. key end
    local record, why = T.begin(store, id, "SALE", "sale|" .. owner.uniqueId .. "|" .. table.concat(keys, ";"), resources)
    if record == nil then return nil, why end
    if opts.prepareOnly then return record end
    local leave = {}
    for _, key in ipairs(opts.leave or {}) do leave[key] = true end
    local removed = {}
    local adapter = {
        preflight = function() return true end,
        applySource = function()
            if opts.during ~= nil then opts.during("apply") end
            for _, key in ipairs(keys) do if not leave[key] then removed[#removed + 1] = key end end
            removeKeys(owner, removed)
            return true
        end,
        observeSource = function()
            local o = { known = true, sameSystem = true, othersIntact = true, removed = {}, survivors = {}, removedKeys = {}, survivorKeys = {} }
            for i, key in ipairs(keys) do
                if leave[key] then o.survivors[#o.survivors + 1] = i o.survivorKeys[#o.survivorKeys + 1] = key
                else o.removed[#o.removed + 1] = i o.removedKeys[#o.removedKeys + 1] = key end
            end
            return o
        end,
        clearSourceQueue = function() return true end,
        settle = function(_, outcome)
            if opts.during ~= nil then opts.during("settle") end
            if opts.unknown then moneyListener = function() moneyListener = nil error("listener failed") end end
            local receipt = S.apply(store.payments, { paymentId = "pay:" .. id, ref = id, kind = "SALE", farmId = farmId,
                amount = each * #outcome.removed, moneyType = MoneyType.SOLD_ANIMALS }, g_currentMission)
            moneyListener = nil
            return receipt
        end,
        restoreSource = function() return true end,
        verifySourceRestored = function() return true end,
    }
    record = T.executeLiveSale(store, id, adapter)
    RLLiveSale.receipts[id] = { txId = id, kind = "MANUAL", keys = keys, quoted = each * #keys, weird = 0 / 0 }
    return record
end

-- A contract delivery into Hof Bergmann's order: buffered + amount, money - fee.
local function contract(owner, keys, amount, fee, opts)
    opts = opts or {}
    local store = RLContractTrade.store
    RLContractTrade.sequence = RLContractTrade.sequence + 1
    local id = string.format("ct%d-f1-o1%s", RLContractTrade.sequence, C.idTag())
    local resources = { "cash:farm1", "order:hb:1", "source:" .. owner.uniqueId }
    for _, key in ipairs(keys) do resources[#resources + 1] = "animal:" .. key end
    local record, why = T.begin(store, id, "CONTRACT", "contract|" .. table.concat(keys, ";"), resources)
    if record == nil then return nil, why end
    local order, farm = world.hb.orders[1], world.farmsById[1]
    local adapter = {
        preflight = function() return true end,
        applyTarget = function() order.buffered = order.buffered + amount farm.money = farm.money - fee return true end,
        verifyTarget = function() return true end,
        rollbackTarget = function() return opts.rollbackFails ~= true end,
        verifyTargetRestored = function() return opts.rollbackFails ~= true end,
        applySource = function() removeKeys(owner, keys) return opts.sourceFails ~= true end,
        verifySource = function() return opts.sourceFails ~= true end,
        rollbackSource = function() return false end,
        verifySourceRestored = function() return false end,
    }
    record = T.executeContract(store, id, adapter)
    RLContractTrade.receipts[id] = { txId = id, target = { before = { buffered = order.buffered - amount }, after = { buffered = order.buffered } },
        source = { removed = keys } }
    return record
end

local function marker(path, root)
    local xml = XMLFile.loadIfExists("m", path)
    return xml ~= nil and xml:getString(root .. "#rlTradeCheckpoint") or nil
end

local function enableTest()
    local ok, why = RLLiveSale.setMode("TEST")
    return ok, why
end

-- ===========================================================================================
-- Pure: encoding, checksum, limits
-- ===========================================================================================

do
    local value = { a = 1, b = "two & <three> \"q\"\n% \200\255", c = { 1, 2.5, -0.1, true, false, { nested = "x" } }, [7] = 0.1 + 0.2,
        big = 2 ^ 60 + 0.5, tiny = 1e-300, neg = -1234.5678901234567, empty = {} }
    local text = P.canonical(value)
    local back = P.parse(text)
    check("encode: strings (any byte), numbers bit for bit, booleans, nested lists and integer keys come back",
        back ~= nil and back.b == value.b and back[7] == value[7] and back.big == value.big and back.tiny == value.tiny
        and back.neg == value.neg and back.c[3] == -0.1 and back.c[4] == true and back.c[5] == false and back.c[6].nested == "x"
        and type(back.empty) == "table" and next(back.empty) == nil)
    local encoded = P.encodeText(text)
    check("encode: the stored text is plain ASCII without XML-special characters and decodes exactly",
        not encoded:find("[%c&<>\"'\128-\255]") and P.decodeText(encoded) == text)
    check("checksum: same canonical text for the same data", P.checksum(text) == P.checksum(P.canonical(back)))
    back.neg = -1234.5
    check("checksum: one value changed changes it", P.checksum(text) ~= P.checksum(P.canonical(back)))
    for _, case in ipairs({ { "NaN", { x = 0 / 0 } }, { "inf", { x = math.huge } }, { "function", { x = function() end } },
        { "fractional key", { [1.5] = 1 } }, { "boolean key", { [true] = 1 } } }) do
        check("check refuses " .. case[1], P.check(case[2]) ~= nil)
    end
    local cyclic = {}
    cyclic.self = cyclic
    check("check refuses a cycle", P.check(cyclic) == "CYCLE")
    local deep = {}
    local node = deep
    for _ = 1, 20 do node.x = {} node = node.x end
    check("check refuses too deep", P.check(deep) == "TOO_DEEP")
    check("check refuses too many values", P.check({ 1, 2, 3, 4 }, { maxNodes = 3, maxString = 10, maxDepth = 5 }) == "TOO_MANY_VALUES")
    check("check refuses a long string", P.check({ string.rep("x", 20) }, { maxNodes = 10, maxString = 10, maxDepth = 5 }) == "STRING_TOO_LONG")
    local sanitized = P.sanitize({ a = 0 / 0, b = function() end, c = cyclic })
    check("sanitize: evidence made storable (NaN text, function named, cycle cut)", P.check(sanitized) == nil
        and type(sanitized.a) == "string" and sanitized.b == "<function>")
    -- The parser refuses what the writer never produces.
    for _, case in ipairs({
        { "a repeated key", "{2:sa2:n12:sa2:n2}", "DUPLICATE_KEY:a" },
        { "a NaN", "{2:sa4:nnan}", "BAD_NUMBER" },
        { "an unknown type", "{2:sa2:x1}", "BAD_TYPE" },
        { "a fractional number key", "{4:n1.52:n1}", "BAD_NUMBER" },
        { "a boolean key", "{5:btrue2:n1}", "BAD_TYPE" },
        { "a wrong length", "{9:sa2:n1}", "TRUNCATED" },
        { "a missing end", "{2:sa2:n1", "TRUNCATED" },
        { "trailing text", "{2:sa2:n1}x", "TRAILING_TEXT" },
        { "a scalar document", "2:n1", "NOT_A_TABLE" },
        { "a bad length text", "{x:sa}", "BAD_LENGTH" },
    }) do
        local parsed, why = P.parse(case[2])
        check("parse refuses " .. case[1], parsed == nil and has(why, case[3]))
    end
    check("decode refuses a broken escape", P.decodeText("ab%4") == nil and P.decodeText("ab%zz") == nil)
end

-- ===========================================================================================
-- Pure: load decisions
-- ===========================================================================================

do
    local function doc(generation, participants, integrity)
        return { meta = { lineage = "Lx", generation = generation, integrity = integrity or "OK" },
            data = { participants = participants or { placeables = true, vehicles = true, farms = true } } }
    end
    local all = { career = "Lx:3", placeables = "Lx:3", vehicles = "Lx:3", farms = "Lx:3" }
    check("decide: nothing anywhere -> FRESH", R.decideLoad({ ledger = { present = false }, markers = {} }).state == "FRESH")
    check("decide: no ledger but markers -> LEDGER_MISSING", has(R.decideLoad({ ledger = { present = false }, markers = { farms = "Lx:2" } }).reason, "LEDGER_MISSING"))
    check("decide: no ledger, a file unreadable -> CANNOT_PROVE_FRESH", has(R.decideLoad({ ledger = { present = false },
        markers = { placeables = false } }).reason, "CANNOT_PROVE_FRESH"))
    check("decide: damaged ledger -> LEDGER_UNREADABLE", has(R.decideLoad({ ledger = { present = true, error = "X" }, markers = all }).reason, "LEDGER_UNREADABLE"))
    check("decide: all markers equal -> READY L1", R.decideLoad({ ledger = { present = true, doc = doc(3) }, markers = all }).level == "L1")
    local older = { career = "Lx:3", placeables = "Lx:2", vehicles = "Lx:3", farms = "Lx:3" }
    check("decide: one older file -> MIXED", has(R.decideLoad({ ledger = { present = true, doc = doc(3) }, markers = older }).reason, "placeables=Lx:2"))
    check("decide: other lineage -> MIXED", R.decideLoad({ ledger = { present = true, doc = doc(3) },
        markers = { career = "Ly:3", placeables = "Lx:3", vehicles = "Lx:3", farms = "Lx:3" } }).state == "RECOVERY_REQUIRED")
    check("decide: a marker on a file the pass did not mark -> MIXED", R.decideLoad({ ledger = { present = true,
        doc = doc(3, { placeables = true, vehicles = true }) }, markers = all }).state == "RECOVERY_REQUIRED")
    check("decide: a file the pass did not mark, without marker -> READY", R.decideLoad({ ledger = { present = true,
        doc = doc(3, { placeables = true, vehicles = true }) }, markers = { career = "Lx:3", placeables = "Lx:3", vehicles = "Lx:3" } }).state == "READY")
    check("decide: carried RECOVERY_REQUIRED is never laundered by matching markers",
        has(R.decideLoad({ ledger = { present = true, doc = doc(3, nil, "RECOVERY_REQUIRED") }, markers = all }).reason, "CARRIED"))
    check("decide record: never started PREPARED -> cancel", R.decideRecord({ state = "PREPARED", history = { "PREPARED" } }) == R.CANCEL_NEVER_STARTED)
    check("decide record: PREPARED with more history -> reconcile", R.decideRecord({ state = "PREPARED", history = { "PREPARED", "VALIDATING" } })
        == R.RECONCILE_MID_TRANSACTION)
    check("decide record: SETTLING -> reconcile", R.decideRecord({ state = "SETTLING", history = { "PREPARED", "SETTLING" } }) == R.RECONCILE_MID_TRANSACTION)
    check("decide record: COMMITTED_PARTIAL -> kept finished", R.decideRecord({ state = "COMMITTED_PARTIAL" }) == R.KEEP_FINISHED)
end

-- ===========================================================================================
-- J09 / J11: an old save, the gate before anything runs, arming
-- ===========================================================================================

do
    newWorld(newDirectory())
    save()   -- a save without RLRM's T02 ever enabled: the game's own files only
    load(world.dir, { beforeStart = function()
        local _, why = T.begin(RLContractTrade.store, "x1", "SALE", "fp", { "animal:1 a 1" })
        check("J11 before onStartMission: T02 refused (gate LOADING)", has(why, "RECOVERY_GATE:LOADING"))
        local set, refused = RLLiveSale.setMode("TEST")
        check("J11 before onStartMission: TEST cannot be set", set == false and has(refused, "LOADING"))
    end })
    check("J09 old save, never enabled: FRESH, ready, not armed", C.state == "READY" and C.load.state == "FRESH" and C.armed == false)
    save()
    check("J09 not enabled: no ledger, no marker written", not fileExists(world.dir .. "/rm_RlTradeLedger.xml")
        and marker(world.dir .. "/farms.xml", "farms") == nil and marker(world.dir .. "/careerSavegame.xml", "careerSavegame") == nil)
    check("J09 enabling TEST arms the ledger", enableTest() == true and C.armed and C.lineage ~= nil)
    RLLiveSale.setMode("OFF")
    save()
    local expected = C.lineage .. ":1"
    check("J20 modes OFF again: the armed ledger is still saved, with every marker", fileExists(world.dir .. "/rm_RlTradeLedger.xml")
        and marker(world.dir .. "/placeables.xml", "placeables") == expected and marker(world.dir .. "/vehicles.xml", "vehicles") == expected
        and marker(world.dir .. "/farms.xml", "farms") == expected and marker(world.dir .. "/careerSavegame.xml", "careerSavegame") == expected)
    check("J04 order: assets, RLRM's own file, the ledger, then the career file (with the commit mark) at the engine's end", (function()
        local order = {}
        for _, path in ipairs(XMLDisk.saves) do order[#order + 1] = path:match("[^/]+$") end
        return table.concat(order, ",") == "placeables.xml,vehicles.xml,farms.xml,rm_RlAnimalSystem.xml,rm_RlTradeLedger.xml,careerSavegame.xml"
    end)())
    check("J01 engine result recorded: COMMITTED", C.last.status == "COMMITTED" and C.last.engine == "0")
    -- A client loads and saves nothing.
    load(world.dir, { client = true })
    check("J17 client: DISABLED, no ledger read", C.state == "DISABLED" and C.load == nil)
end

-- ===========================================================================================
-- J01 / J14 / J15 / J16: a normal save and reload, replay only, nothing redone
-- ===========================================================================================

local savedDir
do
    fresh()
    enableTest()
    local p1 = pen("pen1")
    local full = sale(p1, { "1 a 1" }, 1000)
    local partial = sale(p1, { "1 b 1", "1 c 1" }, 500, { leave = { "1 c 1" } })
    local wage = RLLiveSale.chargeWage(g_currentMission, RLLiveSale.nextRoundId(), 1, 50)
    local delivered = contract(world.trailers[1], { "1 t 1" }, 1.5, 300)
    local unknown = sale(pen("pen2"), { "1 e 1" }, 700, { unknown = true })
    check("setup: committed, partial, unknown, wage, contract", full.state == "COMMITTED" and partial.state == "COMMITTED_PARTIAL"
        and unknown.state == "NEEDS_RECONCILIATION" and wage.status == "APPLIED" and delivered.state == "COMMITTED")
    local moneyAtSave, pen1AtSave = world.farmsById[1].money, table.concat(p1.animals, ",")
    save()
    savedDir = world.dir
    local ids = { full = full.id, partial = partial.id, unknown = unknown.id, delivered = delivered.id, wage = wage.paymentId }
    load(world.dir)
    local store = RLContractTrade.store
    check("J01 reload: READY at L1, generation 1", C.state == "READY" and C.load.level == "L1" and C.load.generation == 1)
    check("J01 reload: the money and the pens are those of the same save", world.farmsById[1].money == moneyAtSave
        and table.concat(pen("pen1").animals, ",") == pen1AtSave and world.hb.orders[1].buffered == 1.5)
    check("J01 reload: finished records kept replay-only, the unknown one held with its own reason",
        store.records[ids.full].state == "COMMITTED" and store.records[ids.partial].state == "COMMITTED_PARTIAL"
        and store.records[ids.delivered].state == "COMMITTED" and store.records[ids.unknown].state == "NEEDS_RECONCILIATION"
        and has(store.records[ids.unknown].reason, "SETTLEMENT_UNKNOWN"))
    check("J01 reload: only the unknown sale's locks, scoped (unrelated work allowed)", store.locks["animal:1 e 1"] == ids.unknown
        and store.locks["cash:farm1"] == ids.unknown and store.locks["animal:1 a 1"] == nil and store.recoveryRequired == false)
    check("J16 the unknown payment stays UNKNOWN, the others keep their receipts", store.payments["pay:" .. ids.unknown].status == "UNKNOWN"
        and store.payments["pay:" .. ids.full].status == "APPLIED" and store.payments[ids.wage].status == "APPLIED")
    check("J15 nothing was paid, refunded, removed or put back by the load", world.farmsById[1].money == moneyAtSave
        and table.concat(pen("pen1").animals, ",") == pen1AtSave)
    local record, why = T.begin(store, ids.full, "SALE", "sale|pen1|1 a 1", { "animal:1 a 1" })
    check("J14 the same id and request after reload: REPLAY, no new work", why == "REPLAY" and record.state == "COMMITTED")
    _, why = T.begin(store, ids.full, "SALE", "changed", { "animal:1 a 1" })
    check("J14 the same id with another request: ID_COLLISION", why == "ID_COLLISION")
    local again, replay = S.apply(store.payments, { paymentId = ids.wage, kind = "WAGE", farmId = 1, amount = -50,
        moneyType = MoneyType.HERDSMAN_WAGES }, g_currentMission)
    check("J14 the round's wage after reload: REPLAY, not charged again", replay == "REPLAY" and world.farmsById[1].money == moneyAtSave)
    _, why = T.begin(store, "n1", "SALE", "fp", { "animal:1 e 1" })
    check("J12 the held animal stays locked after reload", why == "RESOURCE_BUSY")
    check("J14 new ids carry the new epoch: never an id of the previous run", RLLiveSale.nextRoundId() ~= "hr1" .. "-e" .. "1"
        and C.epoch == 2 and has(C.idTag(), "-e2"))
    local _, busy = sale(pen("pen1"), { "1 d 1" }, 100)
    check("J01 after reload: the held sale still holds farm 1's cash (conservative)", busy == "RESOURCE_BUSY")
    local unrelated = sale(pen("pen1"), { "1 d 1" }, 100, { farm = 2 })
    check("J01 after reload: unrelated work (another farm) runs", unrelated ~= nil and unrelated.state == "COMMITTED")
    save()
    check("J01 second save: generation 2 everywhere", marker(world.dir .. "/farms.xml", "farms") == C.lineage .. ":2"
        and marker(world.dir .. "/careerSavegame.xml", "careerSavegame") == C.lineage .. ":2")
    local reasonBefore = RLContractTrade.store.records[ids.unknown].reason
    local historyBefore = #RLContractTrade.store.records[ids.unknown].history
    load(world.dir)
    check("J15 reloading again changes nothing: same reason, history not grown", RLContractTrade.store.records[ids.unknown].reason == reasonBefore
        and #RLContractTrade.store.records[ids.unknown].history == historyBefore and C.state == "READY")
end

-- ===========================================================================================
-- J02 / J04 / J05: a save inside a running transaction; the gate during the pass
-- ===========================================================================================

do
    fresh()
    enableTest()
    local insideBegin
    local inside = sale(pen("pen1"), { "1 a 1" }, 1000, { during = function(stage)
        if stage == "settle" then
            save()   -- a save started from inside the transaction's money step
        end
    end })
    check("J02 setup: the transaction itself still committed in this run", inside.state == "COMMITTED")
    local prepared = sale(pen("pen2"), { "1 e 1" }, 10, { prepareOnly = true })
    -- A save while a T02 begin is attempted inside the pass (another mod's save callback).
    local placeablesSave = PlaceableSystem.saveToXML
    PlaceableSystem.saveToXML = function(self, xmlFile, ...)
        insideBegin = select(2, T.begin(RLContractTrade.store, "during", "SALE", "fp", { "animal:1 b 1" }))
        world.farmsById[2].money = world.farmsById[2].money + 1   -- a legitimate non-T02 change in the pass
        return placeablesSave(self, xmlFile, ...)
    end
    save()
    PlaceableSystem.saveToXML = placeablesSave
    check("J04 a T02 begin inside the save pass is refused (SAVE_IN_PROGRESS)", insideBegin == "SAVE_IN_PROGRESS")
    check("J05 a non-T02 change made inside the pass is in the files written after it", (function()
        local xml = XMLFile.loadIfExists("f", world.dir .. "/farms.xml")
        local found
        xml:iterate("farms.farm", function(_, key) if xml:getInt(key .. "#farmId") == 2 then found = tonumber(xml:getString(key .. "#money")) end end)
        return found == 5001
    end)())
    check("J04 the gate reopens after the pass", T.begin(RLContractTrade.store, "after", "SALE", "fp", { "animal:1 c 1" }) ~= nil)
    load(world.dir)
    local store = RLContractTrade.store
    check("J02 the never-started PREPARED record is cancelled on load, nothing locked", store.records[prepared.id].state == "REJECTED"
        and store.records[prepared.id].reason == "CANCELLED_AT_RELOAD:NEVER_STARTED" and store.locks["animal:1 e 1"] == nil and C.load.cancelled >= 1)
    check("J02 the record caught by the first (inner) save is not in the last save as running",
        store.records[inside.id].state == "COMMITTED")
    -- Load the inner save's own files: the record was SETTLING there.
end

do
    -- J02 directly: the inner save's files alone.
    fresh()
    enableTest()
    local innerDir
    local inside = sale(pen("pen1"), { "1 a 1" }, 1000, { during = function(stage)
        if stage == "settle" then
            save()
            innerDir = newDirectory()
            for _, name in ipairs(listFiles()) do copyFile(world.dir .. "/" .. name, innerDir .. "/" .. name) end
        end
    end })
    load(innerDir)
    local record = RLContractTrade.store.records[inside.id]
    check("J02 saved while SETTLING: NEEDS_RECONCILIATION on load, stage named, locks held, not resumed",
        record.state == "NEEDS_RECONCILIATION" and has(record.reason, "RELOAD_REQUIRES_ASSET_CHECK:SETTLING")
        and RLContractTrade.store.locks["animal:1 a 1"] == inside.id and C.state == "READY")
    check("J02 saved while SETTLING: no payment receipt invented", RLContractTrade.store.payments["pay:" .. inside.id] == nil)
end

-- ===========================================================================================
-- J03: each file's save fails, throws or is cut short
-- ===========================================================================================

local function prepareArmed()
    fresh()
    enableTest()
    sale(pen("pen1"), { "1 a 1" }, 1000)
    save()
    return world.dir
end

for _, case in ipairs({
    { file = "placeables.xml", fault = "throw", run = "ABORTED", load = "OLD" },
    { file = "vehicles.xml", fault = false, run = "INCOMPLETE", load = "RECOVERY" },
    { file = "farms.xml", fault = "truncate", run = "INCOMPLETE", load = "RECOVERY" },
    { file = "farms.xml", fault = "throw", run = "ABORTED", load = "RECOVERY" },
    { file = "rm_RlTradeLedger.xml", fault = false, run = "INCOMPLETE", load = "RECOVERY" },
    { file = "rm_RlTradeLedger.xml", fault = "truncate", run = "INCOMPLETE", load = "RECOVERY" },
    -- The career file is written by the engine at the end of the save: a failed write is its
    -- error code, a cut one is found by the read-back of the finished save.
    { file = "careerSavegame.xml", fault = false, run = "FAILED", load = "RECOVERY" },
    { file = "careerSavegame.xml", fault = "truncate", run = "INCOMPLETE", load = "RECOVERY" },
}) do
    local dir = prepareArmed()
    local lost = sale(pen("pen1"), { "1 b 1" }, 1000)
    XMLDisk.onSave = function(path)
        if path:match("[^/]+$") ~= case.file then return nil end
        if case.fault == "throw" then error("disk error on " .. case.file) end
        return case.fault
    end
    save(Savegame.ERROR_OK)
    XMLDisk.onSave = nil
    local label = string.format("J03 %s %s", case.file, tostring(case.fault))
    check(label .. ": the run records the checkpoint " .. case.run, C.last.status == case.run and C.last.generation == 2)
    check(label .. ": new T02 work refused in this run until a save completes",
        has(select(2, T.begin(RLContractTrade.store, "z", "SALE", "fp", { "animal:x" })), "LAST_SAVE_" .. case.run))
    load(dir)
    if case.load == "OLD" then
        check(label .. ": nothing was overwritten, the previous checkpoint loads READY (generation 1, the later sale lost)",
            C.state == "READY" and C.load.generation == 1 and RLContractTrade.store.records[lost.id] == nil)
    else
        check(label .. ": load requires recovery (L2), not READY", C.state == "RECOVERY_REQUIRED" and C.load.level == "L2")
        check(label .. ": new T02 transactions and TEST refused", select(2, T.begin(RLContractTrade.store, "z", "SALE", "fp", { "animal:x" })) ~= nil
            and enableTest() == false)
    end
end

do
    -- An engine failure reported after a complete pass (e.g. no space when finishing).
    prepareArmed()
    sale(pen("pen1"), { "1 b 1" }, 1000)
    save(Savegame.ERROR_SAVE_NO_SPACE)
    check("J03 the engine reports the save failed: recorded as FAILED", C.last.status == "FAILED" and C.last.engine == "3")
    -- A later complete save in the same run makes the files one checkpoint again.
    local dir = world.dir
    local farmsSave = Farm.saveToXMLFile
    XMLDisk.onSave = function(path) if path:match("farms.xml$") then error("disk error") end end
    save()
    XMLDisk.onSave = nil
    save()
    load(dir)
    check("J03 after a failed pass, the next complete save reopens the run and is READY on load", C.state == "READY"
        and C.load.generation == 4)
end

-- ===========================================================================================
-- J25: the commit mark goes into the career document; the engine writes it (PERSIST01-01)
-- ===========================================================================================

do
    -- In the game the career document has no file: saveXMLFile on it fails, the mark reaches
    -- disk only when the engine finishes the save. That alone must not fail the checkpoint.
    local dir = prepareArmed()
    check("J25 fixture as the game: the career document cannot be saved by path",
        saveXMLFile(g_currentMission.missionInfo.xmlFile) == false)
    check("J25 a normal save commits: no CAREER_MARK_FAILED", C.last.status == "COMMITTED" and C.last.reason == nil
        and C.last.engine == "0")
    local seen = {}
    save(nil, function()
        seen.status = C.last.status
        seen.career = marker(dir .. "/careerSavegame.xml", "careerSavegame")
        seen.admit = C.admit(RLContractTrade.store)
    end)
    check("J25 between the pass and the engine's end: WRITTEN, the career file on disk still the previous mark, T02 open",
        seen.status == "WRITTEN" and seen.career == C.lineage .. ":1" and seen.admit == true)
    check("J25 after the engine's end: COMMITTED, the career file carries this generation",
        C.last.status == "COMMITTED" and C.last.generation == 2 and marker(dir .. "/careerSavegame.xml", "careerSavegame") == C.lineage .. ":2")
    -- Trading continues after the save, the next save keeps it, a reload shows both.
    local after = sale(pen("pen1"), { "1 b 1" }, 400)
    check("J25 a sale after a committed save is admitted", after ~= nil and after.state == "COMMITTED")
    RLLiveSale.setMode("OFF")
    save()
    check("J25 modes OFF, saved again: COMMITTED", C.last.status == "COMMITTED" and C.last.generation == 3)
    load(dir)
    check("J25 reload: READY at generation 3, the sale after the save kept", C.state == "READY" and C.load.generation == 3
        and RLContractTrade.store.records[after.id] ~= nil and RLContractTrade.store.records[after.id].state == "COMMITTED")
end

for _, case in ipairs({
    { name = "ledger missing at the end", reason = "LEDGER_NOT_IN_SAVE", damage = function(dir)
        os.remove(dir .. "/rm_RlTradeLedger.xml")
    end },
    { name = "a participant of the previous save at the end", reason = "PARTICIPANT_NOT_IN_SAVE:farms", damage = function(dir, old)
        XMLDisk.write(dir .. "/farms.xml", old)
    end },
}) do
    local dir = prepareArmed()
    local old = XMLDisk.read(dir .. "/farms.xml")
    sale(pen("pen1"), { "1 b 1" }, 1000)
    save(nil, function() case.damage(dir, old) end)
    local label = "J25 " .. case.name
    check(label .. ": the engine reports OK, the read-back finds it - INCOMPLETE", C.last.status == "INCOMPLETE"
        and C.last.engine == "0" and has(C.last.reason, case.reason))
    check(label .. ": new T02 work refused in this run", has(select(2, T.begin(RLContractTrade.store, "z", "SALE", "fp", { "animal:x" })),
        "LAST_SAVE_INCOMPLETE"))
    load(dir)
    check(label .. ": load requires recovery", C.state == "RECOVERY_REQUIRED")
end

do
    -- An INCOMPLETE save is followed by a complete one: the run reopens.
    prepareArmed()
    save(nil, function() os.remove(world.dir .. "/rm_RlTradeLedger.xml") end)
    local refused = select(2, T.begin(RLContractTrade.store, "z", "SALE", "fp", { "animal:x" }))
    save()
    check("J25 after INCOMPLETE, the next complete save commits and reopens T02", has(refused, "LAST_SAVE_INCOMPLETE")
        and C.last.status == "COMMITTED" and C.admit(RLContractTrade.store) == true)
end

-- ===========================================================================================
-- J06 / J07 / J18: a settings save; files of different saves; backups and copies
-- ===========================================================================================

do
    local dir = prepareArmed()
    local before = XMLDisk.read(dir .. "/rm_RlTradeLedger.xml")
    RLSettings.saveToXMLFile()
    check("J06 a settings save writes no ledger and no generation", XMLDisk.read(dir .. "/rm_RlTradeLedger.xml") == before and C.generation == 1)

    -- Keep generation 1 aside, write generation 2.
    local g1 = newDirectory()
    for _, name in ipairs(listFiles()) do copyFile(dir .. "/" .. name, g1 .. "/" .. name) end
    local soldInG2 = sale(pen("pen1"), { "1 b 1" }, 1000)
    save()
    local g2 = newDirectory()
    for _, name in ipairs(listFiles()) do copyFile(dir .. "/" .. name, g2 .. "/" .. name) end

    local mixed = newDirectory()
    for _, name in ipairs(listFiles()) do copyFile(g2 .. "/" .. name, mixed .. "/" .. name) end
    copyFile(g1 .. "/rm_RlTradeLedger.xml", mixed .. "/rm_RlTradeLedger.xml")
    load(mixed)
    check("J07 old ledger with new assets: MIXED_CHECKPOINT, closed", C.state == "RECOVERY_REQUIRED" and has(C.reason, "MIXED_CHECKPOINT"))
    check("J07 the next save of a mixed load continues above every generation on disk", C.generation == 2)
    copyFile(g2 .. "/rm_RlTradeLedger.xml", mixed .. "/rm_RlTradeLedger.xml")
    copyFile(g1 .. "/placeables.xml", mixed .. "/placeables.xml")
    load(mixed)
    check("J07 new ledger with an old placeables.xml: MIXED, the file named", C.state == "RECOVERY_REQUIRED" and has(C.reason, "placeables="))
    check("J07 a mixed load keeps the newer records for the report, all locks of unfinished ones",
        RLContractTrade.store.records[soldInG2.id] ~= nil)
    copyFile(g2 .. "/placeables.xml", mixed .. "/placeables.xml")
    copyFile(g1 .. "/careerSavegame.xml", mixed .. "/careerSavegame.xml")
    load(mixed)
    check("J07 only the career mark from the older save: MIXED", C.state == "RECOVERY_REQUIRED" and has(C.reason, "career="))

    load(g1)
    check("J18 a complete backup of generation 1: READY at generation 1", C.state == "READY" and C.load.generation == 1
        and RLContractTrade.store.records[soldInG2.id] == nil)
    local restoredId = sale(pen("pen1"), { "1 b 1" }, 1000).id
    check("J18 after restoring an older generation, new ids never repeat the lost ones", restoredId ~= soldInG2.id)
    save()
    check("J18 the restored history continues at a new generation", C.generation == 2 and marker(g1 .. "/farms.xml", "farms") == C.lineage .. ":2")
    local copyDir = newDirectory()
    for _, name in ipairs(listFiles()) do copyFile(g2 .. "/" .. name, copyDir .. "/" .. name) end
    load(copyDir)
    check("J18 a copied savegame loads READY (same lineage, its own future)", C.state == "READY" and C.load.generation == 2)
end

-- ===========================================================================================
-- J08: the ledger missing, damaged, newer, edited
-- ===========================================================================================

do
    local dir = prepareArmed()
    sale(pen("pen2"), { "1 e 1" }, 700, { unknown = true })
    save()
    local good = XMLDisk.read(dir .. "/rm_RlTradeLedger.xml")

    os.remove(dir .. "/rm_RlTradeLedger.xml")
    load(dir)
    check("J08 ledger deleted, markers present: LEDGER_MISSING, closed, not a fresh start", C.state == "RECOVERY_REQUIRED"
        and has(C.reason, "LEDGER_MISSING") and C.armed)

    XMLDisk.write(dir .. "/rm_RlTradeLedger.xml", "this is not xml <<<")
    load(dir)
    check("J08 ledger not XML: LEDGER_UNREADABLE, quarantined, the damaged file left as it was (never opened to read)",
        C.state == "RECOVERY_REQUIRED" and has(C.reason, "LEDGER_UNREADABLE") and C.quarantine ~= nil
        and XMLDisk.read(dir .. "/rm_RlTradeLedger.xml") == "this is not xml <<<")
    save()
    -- The engine reads files only as XML (FS25 io.open writes), so text that is not XML cannot be copied.
    local note = XMLDisk.read(dir .. "/rm_RlTradeLedger.quarantine.txt")
    check("J08 the next save leaves a quarantine note beside the save (not-XML text points to savegameBackup)",
        note ~= nil and note:find("savegameBackup", 1, true) ~= nil and note:find("LEDGER_UNREADABLE", 1, true) ~= nil)
    load(dir)
    check("J08 a save never launders recovery: the next load is still RECOVERY_REQUIRED (CARRIED)", C.state == "RECOVERY_REQUIRED"
        and has(C.reason, "CARRIED"))

    -- A document rewritten with a correct digest but a content the writer never produces.
    local function rewrite(path, edit)
        local xml = XMLFile.load("l", path)
        local parts = {}
        xml:iterate("rlTradeLedger.data.chunk", function(_, key) parts[#parts + 1] = xml:getString(key .. "#v") end)
        local text = edit(P.decodeText(table.concat(parts)))
        local out = XMLFile.create("l", path, "rlTradeLedger")
        for _, attr in ipairs({ "schema", "lineage", "generation", "integrity" }) do
            out:setString("rlTradeLedger#" .. attr, xml:getString("rlTradeLedger#" .. attr))
        end
        out:setString("rlTradeLedger#digest", P.checksum(text))
        local encoded = P.encodeText(text)
        out:setString("rlTradeLedger.data#length", tostring(#encoded))
        out:setString("rlTradeLedger.data.chunk(0)#v", encoded)
        out:save()
    end
    local cases = {
        { "newer schema", function(path) XMLDisk.write(path, (XMLDisk.read(path):gsub('schema="1"', 'schema="2"', 1))) end, "NEWER_SCHEMA" },
        { "edited chunk", function(path) XMLDisk.write(path, (XMLDisk.read(path):gsub('5:n1000', '5:n1001', 1))) end, "DIGEST_MISMATCH" },
        { "truncated", function(path) local t = XMLDisk.read(path) XMLDisk.write(path, t:sub(1, math.floor(#t * 0.6))) end, "PARSE_FAILED" },
        { "bad lineage", function(path) XMLDisk.write(path, (XMLDisk.read(path):gsub('lineage="L', 'lineage="X', 1))) end, "BAD_LINEAGE" },
        { "a NaN amount (digest recomputed)", function(path) rewrite(path, function(t) return (t:gsub("5:n1000", "4:nnan", 1)) end) end, "BAD_NUMBER" },
        { "a repeated key (digest recomputed)", function(path) rewrite(path, function(t)
            return (t:gsub("5:skind5:sSALE", "5:skind5:sSALE5:skind5:sSALE", 1)) end) end, "DUPLICATE_KEY" },
        { "a record with a bad state (digest recomputed)", function(path) rewrite(path, function(t)
            return (t:gsub("10:sCOMMITTED", "10:sCOMMITTEX", 1)) end) end, "BAD_RECORDS" },
    }
    for _, case in ipairs(cases) do
        local d = prepareArmed()
        case[2](d .. "/rm_RlTradeLedger.xml")
        load(d)
        check("J08 " .. case[1] .. ": refused (" .. case[3] .. "), closed", C.state == "RECOVERY_REQUIRED" and has(C.reason, case[3]))
    end
    -- Too large.
    d = prepareArmed()
    local saved = P.LIMITS.maxNodes
    P.LIMITS.maxNodes = 20
    load(d)
    P.LIMITS.maxNodes = saved
    check("J08 larger than the limit: refused, nothing truncated", C.state == "RECOVERY_REQUIRED" and has(C.reason, "TOO_MANY_VALUES"))
end

-- ===========================================================================================
-- J09: a schema-1 ledger inside the document (batch 2/3 records) and unfinished ones in it
-- ===========================================================================================

do
    local dir = prepareArmed()
    local store = RLContractTrade.store
    local v1 = { version = 1, sequence = 2, records = {
        old = { id = "old", kind = "CONTRACT", fingerprint = "f", resources = { "animal:1 z 1" }, state = "COMMITTED", sequence = 1, history = { "PREPARED", "COMMITTED" } },
        mid = { id = "mid", kind = "CONTRACT", fingerprint = "g", resources = { "animal:1 y 1" }, state = "APPLYING_TARGET", sequence = 2,
            history = { "PREPARED", "VALIDATING", "APPLYING_TARGET" } } } }
    local imported = T.import(v1)
    check("J09 a schema-1 ledger imports; its running record is held, not cleared", imported ~= nil
        and imported.records.mid.state == "NEEDS_RECONCILIATION" and imported.locks["animal:1 y 1"] == "mid"
        and imported.records.old.state == "COMMITTED")
end

-- ===========================================================================================
-- J10 / J12 / J13: identity repair, missing and re-created resources, orders processed later
-- ===========================================================================================

do
    fresh()
    enableTest()
    local order = world.hb.orders[1]
    local delivered = contract(pen("pen1"), { "1 a 1" }, 2, 300)
    local held = sale(pen("pen2"), { "1 e 1" }, 700, { unknown = true })
    -- Later, the map processes the order and money moves for other reasons.
    order.buffered, order.ready = 0.5, 3
    world.farmsById[1].money = world.farmsById[1].money + 12345
    -- The pen of the held sale is removed before the save.
    for i, p in ipairs(world.pens) do if p.uniqueId == "pen2" then table.remove(world.pens, i) break end end
    bindMission()
    save()
    load(world.dir, { repairs = 2 })
    local status = {}
    for _, resource in ipairs(C.load.resources) do status[resource.key] = resource.status end
    check("J13 an order processed and money moved after the delivery: READY, the delivery still COMMITTED",
        C.state == "READY" and RLContractTrade.store.records[delivered.id].state == "COMMITTED" and world.hb.orders[1].ready == 3)
    check("J12 the held sale's pen is gone: its locks kept, reported MISSING", status["source:pen2"] == "MISSING"
        and status["animal:1 e 1"] == "MISSING" and RLContractTrade.store.locks["source:pen2"] == held.id)
    check("J10 identity repairs at start are reported, no lock is moved or freed", C.load.identityRepairs == 2
        and count(RLContractTrade.store.locks) == count(held.resources))
    pen("pen1").animals[#pen("pen1").animals + 1] = "1 e 1"   -- another animal with the same identity appears
    local _, why = T.begin(RLContractTrade.store, "n", "SALE", "fp", { "animal:1 e 1" })
    check("J12 a re-created animal with the held identity stays locked (never bound silently)", why == "RESOURCE_BUSY")
end

-- ===========================================================================================
-- J19 / J20 / J21: another save in the same process; uninstall; progress after the last save
-- ===========================================================================================

do
    local a = prepareArmed()
    local held = sale(pen("pen2"), { "1 e 1" }, 700, { unknown = true })
    save()
    local b = newDirectory()
    fresh(b)
    save()
    load(b)
    check("J19 another save in the same process: its own empty ledger, no locks or records of the first",
        C.state == "READY" and count(RLContractTrade.store.records) == 0 and next(RLContractTrade.store.locks) == nil and not C.armed)
    load(a)
    check("J19 back to the first: its records and locks again", RLContractTrade.store.records[held.id] ~= nil
        and RLContractTrade.store.locks["animal:1 e 1"] == held.id)

    -- Progress after the last save is lost with the game; nothing is replayed from it.
    local after = sale(pen("pen1"), { "1 c 1" }, 999, { farm = 2 })
    local moneyAfter = world.farmsById[2].money
    load(a)
    check("J21 a sale after the last save is not in the reloaded ledger, its money not in the reloaded farm",
        RLContractTrade.store.records[after.id] == nil and world.farmsById[2].money == moneyAfter - 999)

    -- Uninstalled: the game saves without RLRM's hooks; reinstalled: the markers are gone.
    local hooked = { FSCareerMissionInfo.saveToXMLFile, PlaceableSystem.saveToXML, VehicleSystem.saveToXML, Farm.saveToXMLFile }
    local plain = setmetatable({}, { __index = FSCareerMissionInfo })
    FSCareerMissionInfo.saveToXMLFile = function(self)
        local xmlFile = createXMLFile("c", "", "careerSavegame")
        self.xmlFile = xmlFile
        g_currentMission.placeableSystem:save(self.placeablesXML, {})
        g_currentMission.vehicleSystem:save(self.vehiclesXML, {})
        g_farmManager:saveToXMLFile(self.farmsXML)
        saveXMLFile(xmlFile)
    end
    local savedState = C.state
    C.armed = false   -- without the mod nothing marks the files
    save()
    FSCareerMissionInfo.saveToXMLFile, PlaceableSystem.saveToXML, VehicleSystem.saveToXML, Farm.saveToXMLFile = hooked[1], hooked[2], hooked[3], hooked[4]
    load(a)
    check("J20 saved without the mod, then reinstalled: the old ledger no longer matches - closed", C.state == "RECOVERY_REQUIRED"
        and has(C.reason, "MIXED_CHECKPOINT") and enableTest() == false)
end

-- ===========================================================================================
-- J22 / J23: retention, limits, size and time
-- ===========================================================================================

do
    fresh()
    enableTest()
    -- 700 finished sales and 3 held ones in a first epoch.
    for i = 1, 700 do
        local key = "9 s" .. i .. " 1"
        sale(pen("pen1"), { key }, 1)
    end
    local held = {}
    addFarm(3, 100)
    bindMission()
    local owners = { pen("pen1"), pen("pen2"), world.trailers[1] }   -- a held sale also holds its source
    for i = 1, 3 do held[i] = sale(owners[i], { "9 h" .. i .. " 1" }, 1, { unknown = true, farm = i }) end
    for round = 1, 600 do RLLiveSale.chargeWage(g_currentMission, RLLiveSale.nextRoundId(), 1, 1) end
    save()
    load(world.dir)
    local store = RLContractTrade.store
    local detailed, tombstones = 0, 0
    for _, r in pairs(store.records) do
        if RLTradeTransaction.FINISHED[r.state] then
            if #r.history == 1 then tombstones = tombstones + 1 else detailed = detailed + 1 end
        end
    end
    check("J22 first save of an epoch prunes nothing of it (all its records are current)", count(store.records) == 703
        and held[3] ~= nil)
    -- A second epoch: the first epoch's records are now past, the window applies.
    save()
    load(world.dir)
    store = RLContractTrade.store
    detailed, tombstones = 0, 0
    for _, r in pairs(store.records) do
        if RLTradeTransaction.FINISHED[r.state] then
            if #r.history == 1 then tombstones = tombstones + 1 else detailed = detailed + 1 end
        end
    end
    local wages = 0
    for _, p in pairs(store.payments) do if p.kind == "WAGE" then wages = wages + 1 end end
    check(string.format("J22 past epoch: %d detailed + %d tombstones kept (100 + 500), the oldest pruned", detailed, tombstones),
        detailed == 100 and tombstones == 500)
    check("J22 held records and unknown payments are never pruned", store.records[held[1].id].state == "NEEDS_RECONCILIATION"
        and store.payments["pay:" .. held[3].id].status == "UNKNOWN" and store.locks["animal:9 h2 1"] == held[2].id)
    check(string.format("J22 past-epoch wage receipts beyond 500 pruned (%d kept)", wages), wages == 500)
    check("J22 pruning happened only where safe: the replay of a kept id still works",
        select(2, T.begin(store, held[1].id, "SALE", held[1].fingerprint, held[1].resources)) == "REPLAY")
    local savedMax = C.MAX_RECORDS
    C.MAX_RECORDS = 1
    addFarm(4, 100)
    bindMission()
    local spare = newPen("pen9", {})
    local first = sale(spare, { "9 x1 1" }, 1, { farm = 4 })
    local _, full = sale(spare, { "9 x2 1" }, 1, { farm = 4 })
    C.MAX_RECORDS = savedMax
    check("J22 an epoch at its record cap refuses new transactions (LEDGER_FULL), nothing dropped", first ~= nil and full == "LEDGER_FULL")

    -- J23: one 1000-head sale and 2000 records; time and size of a save and a load.
    fresh()
    enableTest()
    local keys = {}
    for i = 1, 1000 do keys[i] = "8 big" .. i .. " 1" pen("pen1").animals[#pen("pen1").animals + 1] = keys[i] end
    sale(pen("pen1"), keys, 2)
    for i = 1, 1999 do sale(pen("pen1"), { "7 r" .. i .. " 1" }, 1) end
    local t0 = os.clock()
    save()
    local t1 = os.clock()
    load(world.dir)
    local t2 = os.clock()
    local size = #XMLDisk.read(world.dir .. "/rm_RlTradeLedger.xml")
    print(string.format("J23 2000 records (one of 1000 heads): save %.2fs, load %.2fs, ledger %.1f KB", t1 - t0, t2 - t1, size / 1024))
    check(string.format("J23 2000 records incl. a 1000-head sale: saved and loaded READY (%.1f KB)", size / 1024),
        C.state == "READY" and count(RLContractTrade.store.records) == 2000)
end

-- ===========================================================================================
-- J24: the report reads only
-- ===========================================================================================

do
    fresh()
    enableTest()
    sale(pen("pen2"), { "1 e 1" }, 700, { unknown = true })
    save()
    load(world.dir, { repairs = 1 })
    local lines, savedPrint = {}, print
    print = function(text) lines[#lines + 1] = text end
    local moneyBefore, locksBefore = world.farmsById[1].money, count(RLContractTrade.store.locks)
    local result = RLTradeReportConsole:txReport()
    local again = RLTradeReportConsole:txReport()
    print = savedPrint
    local text = table.concat(lines, "\n")
    check("J24 report: ledger state, generation, load decision, each held lock and where it points",
        has(text, "ledger: READY") and has(text, "generation 1") and has(text, "load: READY L1") and has(text, "1 identity repair(s)")
        and has(text, "lock animal:1 e 1") and has(text, "FOUND"))
    check("J24 report changes nothing and has no unlock or repay command", world.farmsById[1].money == moneyBefore
        and count(RLContractTrade.store.locks) == locksBefore and result == again and RLTradeReportConsole.unlock == nil
        and RLTradeCheckpoint.unlock == nil and RLTradeCheckpoint.clear == nil)
    -- Recovery required: the report names the reason; new transactions refused, old paths unaffected.
    os.remove(world.dir .. "/rm_RlTradeLedger.xml")
    load(world.dir)
    lines = {}
    print = function(text) lines[#lines + 1] = text end
    RLTradeReportConsole:txReport()
    print = savedPrint
    check("J24 recovery required: the report names it", has(table.concat(lines, "\n"), "ledger: RECOVERY_REQUIRED (LEDGER_MISSING"))
    check("J24 recovery required: TEST refused with the reason", has(select(2, RLLiveSale.setMode("TEST")), "LEDGER_RECOVERY_REQUIRED"))
    check("J24 recovery required: SHADOW and OFF still allowed (they write nothing)", RLLiveSale.setMode("SHADOW") == true
        and RLLiveSale.setMode("OFF") == true)
end
