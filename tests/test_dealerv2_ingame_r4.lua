-- Dealer v2 first game test (r4, 2026-10-24): regressions for what blocked it on a real save.

local function source(path)
    local h = assert(io.open(REPO .. path, "r")); local t = h:read("*a"); h:close(); return t
end

-- A flat XML double: values by full key, hasProperty for elements and attributes, iterate over "(i)".
local function flatXml(values)
    local x = {}
    local function has(key)
        if values[key] ~= nil then return true end
        local prefix = key .. "."
        local attr = key .. "#"
        for k in pairs(values) do
            if k:sub(1, #prefix) == prefix or k:sub(1, #attr) == attr or k:sub(1, #key + 1) == key .. "(" then return true end
        end
        return false
    end
    function x:hasProperty(key) return has(key) end
    function x:getString(key, d) local v = values[key]; if v == nil then return d end return tostring(v) end
    function x:getFloat(key, d) return tonumber(values[key]) or d end
    function x:getInt(key, d) local v = tonumber(values[key]); return v ~= nil and math.floor(v) or d end
    function x:getBool(key, d) local v = values[key]; if v == nil then return d end return v == true or v == "true" end
    function x:iterate(key, fn)
        local i = 0
        while has(string.format("%s(%d)", key, i)) do fn(i, string.format("%s(%d)", key, i)); i = i + 1 end
    end
    return x
end

-- 1. Fetuses read from a save are unborn (age -1), as createPregnancy makes them.
do
    local oldMission, oldAnimal, oldPolicy, oldWool = g_currentMission, Animal, RLRearingPolicy, RLWoolShearing
    RLRearingPolicy, RLWoolShearing = nil, nil
    g_currentMission = { animalSystem = {
        getSubTypeIndexByName = function(_, name) return ({ COW_HOLSTEIN = 1, BULL_HOLSTEIN = 2 })[name] end,
        getSubTypeByIndex = function(_, i) return { name = i == 1 and "COW_HOLSTEIN" or "BULL_HOLSTEIN" } end } }
    Animal = setmetatable({ getDefaultMarks = function() return setmetatable({}, { __index = function(t, k) local m = {}; rawset(t, k, m); return m end }) end },
        { __index = function() return function() end end })
    Animal.new = function(cfg)
        local a = {}; for k, v in pairs(cfg) do a[k] = v end
        a.age = cfg.age or 0
        return setmetatable(a, { __index = function() return function() end end })
    end
    loadMod("scripts/animal/AnimalPersistence.lua")
    local k = "a"
    local xml = flatXml({
        [k .. "#subType"] = "COW_HOLSTEIN", [k .. "#age"] = 30, [k .. "#gender"] = "female", [k .. "#id"] = "310060", [k .. "#farmId"] = "916632",
        [k .. ".pregnancy#day"] = 6, [k .. ".pregnancy#month"] = 10, [k .. ".pregnancy#year"] = 3, [k .. ".pregnancy#duration"] = 9,
        [k .. ".pregnancy.pregnancies.pregnancy(0)#subType"] = "BULL_HOLSTEIN", [k .. ".pregnancy.pregnancies.pregnancy(0)#gender"] = "male",
        [k .. ".pregnancy.pregnancies.pregnancy(0)#health"] = 100,
        [k .. ".pregnancy.pregnancies.pregnancy(1)#subType"] = "COW_HOLSTEIN", [k .. ".pregnancy.pregnancies.pregnancy(1)#gender"] = "female",
        [k .. ".pregnancy.pregnancies.pregnancy(1)#age"] = 0,
    })
    local ok, mother = pcall(AnimalPersistence.loadFromXMLFile, xml, k, nil, false)
    local children = ok and mother ~= nil and mother.pregnancy ~= nil and mother.pregnancy.pregnancies or {}
    check("r4 fetus: a fetus loaded from the save is unborn (age -1), not a born calf without an ID",
        ok and #children == 2 and children[1].age == -1 and mother.age == 30, tostring(ok and #children or mother))
    check("r4 fetus: an explicit saved age is kept", ok and children[2] ~= nil and children[2].age == 0)
    g_currentMission, Animal, RLRearingPolicy, RLWoolShearing = oldMission, oldAnimal, oldPolicy, oldWool
end
do
    local text = source("scripts/animal/AnimalSerialization.lua")
    check("r4 fetus: a fetus read from the network stream is unborn (age -1)",
        text:find("age = -1,  -- unborn", 1, true) ~= nil and text:find("Animal.new({\n                age = 0,", 1, true) == nil)
end

-- 2. The replay reads the milk curve the game actually loads: output.milk = { fillType, curve }.
do
    loadMod("tests/dealerreplaysim.lua")
    local R, S = RLDealerReplay, DealerReplaySim
    local seed = S.seed("HOLSTEIN", "female", 1)
    local entry = { breedingWeightRatio = 0.55, profile = { minRecoveryMonth = 3 } }
    local production = S.history(seed, 30.25, "NORMAL_PRODUCTION", {
        { kind = "CONCEPTION", atMonths = 17.125, parity = 1 },
        { kind = "CALVING", atMonths = 27.125, parity = 1 },
    })
    local options = { daysPerMonth = 1, entry = entry, pregnancySubTypes = { [4] = { seed.subType } } }
    local stubMilk = seed.subType.output.milk
    local function withOutput(output, fn)
        local saved = seed.subType.output
        seed.subType.output = output
        local a, b = fn()
        seed.subType.output = saved
        return a, b
    end
    local real, why = withOutput({ milk = { fillType = 7, curve = stubMilk } }, function() return R.run(seed, production, options) end)
    -- (The totals differ from the stub shape: RLFeed.getMatureMilk still reads milk.get - a separate finding.)
    check("r4 milk: the game's { fillType, curve } output replays a calved cow (not MILK_RULES)",
        real ~= nil and real.ledger.milkLiters > 0, why and why.reason)
    local oldLactation = Animal.isLactationPalletFillType
    Animal.isLactationPalletFillType = function(f) return f == 99 end
    local cans
    cans, why = withOutput({ pallets = { fillType = 99, curve = stubMilk } }, function() return R.run(seed, production, options) end)
    check("r4 milk: milk sold in cans (Hof Bergmann output.pallets) is a milk curve too", cans ~= nil and cans.ledger.milkLiters > 0, why and why.reason)
    local eggs
    eggs, why = withOutput({ pallets = { fillType = 5, curve = stubMilk } }, function() return R.run(seed, production, options) end)
    check("r4 milk: other pallets are not milk", eggs == nil and why.reason == "MILK_RULES")
    Animal.isLactationPalletFillType = oldLactation
    local none
    none, why = withOutput({}, function() return R.run(seed, production, options) end)
    check("r4 milk: a calved dairy cow without any milk curve still refuses", none == nil and why.reason == "MILK_RULES")
    local oldBeef = RLRearingPolicy.isBeef
    RLRearingPolicy.isBeef = function(sub) return sub == seed.subType end
    local beef
    beef, why = withOutput({}, function() return R.run(seed, production, options) end)
    RLRearingPolicy.isBeef = oldBeef
    check("r4 milk: a beef dam needs no milk curve to have calved", beef ~= nil or why.reason ~= "MILK_RULES", why and why.reason)
    check("r4 milk: getMilkCurve reads both shapes and ignores a curve-less entry",
        R.getMilkCurve({ output = { milk = { fillType = 1, curve = stubMilk } } }) == stubMilk
        and R.getMilkCurve({ output = { milk = stubMilk } }) == stubMilk
        and R.getMilkCurve({ output = { milk = { fillType = 1 } } }) == nil and R.getMilkCurve({}) == nil)
end

-- 5. The old dealer's hour/day/period callbacks run as one identity batch each.
do
    local text = source("scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua")
    local from = assert(text:find("-- The old dealer's restock and rotation", 1, true))
    local oldSystem, oldRuntime = AnimalSystem, RLAnimalIdentityRuntime
    local seen = {}
    AnimalSystem = {}
    for _, name in ipairs({ "onHourChanged", "onDayChanged", "onPeriodChanged" }) do
        AnimalSystem[name] = function(self, arg) seen[#seen + 1] = name .. ":" .. tostring(self) .. ":" .. tostring(arg); return name end
    end
    local batches = 0
    RLAnimalIdentityRuntime = { batch = function(fn, ...) batches = batches + 1; return fn(...) end }
    assert(load(text:sub(from), "AnimalSystem batch wrappers"))()
    local r1 = AnimalSystem.onHourChanged("sys", 1)
    local r2 = AnimalSystem.onDayChanged("sys")
    local r3 = AnimalSystem.onPeriodChanged("sys")
    check("r4 batch: hour, day and period callbacks each run inside one identity batch with their own self",
        batches == 3 and r1 == "onHourChanged" and r3 == "onPeriodChanged" and seen[1] == "onHourChanged:sys:1" and seen[2] == "onDayChanged:sys:nil")
    RLAnimalIdentityRuntime = nil
    check("r4 batch: without the identity runtime the callback runs as before", AnimalSystem.onDayChanged("sys") == "onDayChanged")
    AnimalSystem, RLAnimalIdentityRuntime = oldSystem, oldRuntime
end

-- 6. Console: the typed words reach the handlers; a second enable says so; ticks say why.
do
    loadMod("scripts/console/RLIdentityConsole.lua")
    local C = RLIdentityConsole
    local got = {}
    local saved = { activate = C.activate, dealerOrder = C.dealerOrder, dealerQuote = C.dealerQuote }
    C.activate = function(arg) got.activate = arg; return "ok" end
    C.dealerOrder = function(id) got.order = id end
    C.dealerQuote = function(dest, a, b) got.quote = { dest, a, b } end
    -- What the engine does with addConsoleCommand(name, help, fn, target): target[fn](target, words...).
    local function console(fn, ...) local target = C.commands; return target[fn](target, ...) end
    console("activate", "accept"); console("dealerOrder", "console-e1-2"); console("dealerQuote", "pen:1", "S1", "S2")
    check("r4 console: rlIdentityActivate accept reaches activate as \"accept\"", got.activate == "accept")
    check("r4 console: order ids and quote words arrive in place", got.order == "console-e1-2"
        and got.quote[1] == "pen:1" and got.quote[2] == "S1" and got.quote[3] == "S2")
    check("r4 console: direct callers (test kit) keep the plain call", C.activate("accept") == "ok" and C.commands.nothing == nil)
    for k, v in pairs(saved) do C[k] = v end
    local manager = source("scripts/console/RLConsoleCommandManager.lua")
    check("r4 console: every RLIdentityConsole command registers the dropping target",
        select(2, manager:gsub(", RLIdentityConsole%.commands, ", "")) == 15 and manager:find(", RLIdentityConsole, ", 1, true) == nil)

    local oldId, oldD = RLAnimalIdentityRuntime, RLDealerRuntime
    RLAnimalIdentityRuntime = { server = true }
    local enables = 0
    RLDealerRuntime = { CHANNEL_ENABLED = true, state = "READY", service = {}, enable = function() enables = enables + 1; return nil, "MONEY_RECONCILIATION_REQUIRED" end }
    local text = C.dealerEnable()
    check("r4 enable: a second rlDealerV2Enable in the session answers already enabled, not a money error",
        enables == 0 and text:find("already enabled", 1, true) ~= nil)
    RLAnimalIdentityRuntime, RLDealerRuntime = oldId, oldD
end
do
    loadMod("scripts/dealer/RLDealerRuntime.lua")
    local R = RLDealerRuntime
    local lines = {}
    local L = { info = function(_, f, ...) lines[#lines + 1] = "I " .. string.format(f, ...) end,
        warning = function(_, f, ...) lines[#lines + 1] = "W " .. string.format(f, ...) end }
    R.lastTickBlock, R.lastTickPause = nil, nil
    R.logTick(L, { filled = 0, empty = 0, deficit = 0 })
    check("r4 tick log: a quiet tick logs nothing", #lines == 0)
    R.logTick(L, { filled = 0, empty = 1, deficit = 198, emptyReason = "EMPTY:REPLAY:MILK_RULES", emptyReasons = { "REPLAY:MILK_RULES", "ADMIT:X" } })
    check("r4 tick log: an empty place names every attempt's reason", lines[1] ~= nil and lines[1]:find("EMPTY:REPLAY:MILK_RULES", 1, true)
        and lines[1]:find("ADMIT:X", 1, true) and lines[1]:sub(1, 1) == "W")
    R.logTick(L, nil, "TRANSACTION_IN_PROGRESS"); R.logTick(L, nil, "TRANSACTION_IN_PROGRESS")
    check("r4 tick log: a blocked tick is logged once per new reason", #lines == 2)
    R.logTick(L, { filled = 1, empty = 0, deficit = 3, months = 0.5 })
    check("r4 tick log: a filled place is logged", lines[3] ~= nil and lines[3]:find("filled=1", 1, true) ~= nil)
end

-- r5 game test: a refused console order raised "attempt to index nil with 'text'" - RLDealerMessages was
-- never sourced, so the refusal reason was lost. Every dealer file the runtime or the console uses is loaded,
-- before the console.
do
    local main = source("scripts/main.lua")
    local console = main:find('"scripts/console/RLIdentityConsole.lua"', 1, true)
    -- every dealer module the console and the service name, when it has its own file
    local seen = {}
    for _, user in ipairs({ "scripts/console/RLIdentityConsole.lua", "scripts/dealer/RLDealerService.lua", "scripts/dealer/RLDealerRuntime.lua" }) do
        for name in source(user):gmatch("(RLDealer%w+)") do
            local path = "scripts/dealer/" .. name .. ".lua"
            local file = io.open(REPO .. path, "r")
            if file ~= nil and not seen[path] then
                file:close()
                seen[path] = true
                local at = main:find('"' .. path .. '"', 1, true)
                check("main.lua sources " .. path .. " before the console", at ~= nil and console ~= nil and at < console)
            end
        end
    end
    check("the console's message table is among them", seen["scripts/dealer/RLDealerMessages.lua"] == true)
    local service = source("scripts/dealer/RLDealerService.lua")
    local _, logged = service:gsub('Log:error%("RLDEALERV2 purchase failed with an error: %%s", tostring%(result%)%)', "")
    check("a purchase that raises is logged with its error (both routes)", logged == 2)
end
