-- Minimal stand-ins for the GIANTS engine globals the tested scripts touch at load and run time.
-- Each test file gets a fresh Lua state with these loaded, then overrides what it needs.

math.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
math.pow = math.pow or function(a, b) return a ^ b end

table.clone = function(t, depth)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do
        c[k] = (type(v) == "table" and (depth or 1) > 1) and table.clone(v, depth - 1) or v
    end
    return c
end

LOG = {}
local function logger(level)
    return function(_, fmt, ...) LOG[#LOG + 1] = level .. ": " .. string.format(fmt, ...) end
end
local noop = function() end
RmLogging = { getLogger = function()
    return { trace = noop, debug = noop, info = noop, warning = logger("warning"), error = logger("error") }
end }
Log = RmLogging.getLogger()
RmSafeUtils = { safeCall = function(name, fn)
    local ok, err = pcall(fn)
    if not ok then LOG[#LOG + 1] = "safeCall " .. name .. ": " .. tostring(err) end
end }

Class = function(class, base)
    setmetatable(class, { __index = base })
    return { __index = class }
end
Event = { new = function(mt) return setmetatable({}, mt) end }
InitEventClass = noop
g_currentModDirectory = "/mod/"

-- A connection as seen by the receiving side: fromServer = the event came from the server.
function makeConnection(userId, fromServer, sent)
    return { user = userId, getIsServer = function() return fromServer end,
        sendEvent = function(_, e) if sent ~= nil then sent[#sent + 1] = e end end }
end

RESULTS = {}
function check(name, cond)
    RESULTS[#RESULTS + 1] = { name = name, ok = cond and true or false }
end

function near(a, b, eps) return a ~= nil and b ~= nil and math.abs(a - b) < (eps or 0.01) end

function loadMod(path)
    local chunk, err = loadfile(REPO .. path)
    assert(chunk, err)
    chunk()
end

-- XMLFile over a real file on disk: elements and attributes only (comments and the
-- declaration dropped), addressed with the engine's "root.child(i).grandchild(j)#attr" keys.
function loadXMLFileFromDisk(path)
    local handle = io.open(path, "r")
    if handle == nil then return nil end
    local text = handle:read("*a"):gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
    handle:close()

    local nodes, counts, stack = {}, {}, {}
    for closing, name, attrText, selfClosing in text:gmatch("<(/?)([%w_]+)([^>]-)(/?)>") do
        if closing == "/" then
            table.remove(stack)
        else
            local parent = stack[#stack]
            local key = name
            if parent ~= nil then
                local base = parent .. "." .. name
                counts[base] = (counts[base] or 0) + 1
                key = string.format("%s(%d)", base, counts[base] - 1)
            end
            local attrs = {}
            for attr, value in attrText:gmatch('([%w_]+)="([^"]*)"') do attrs[attr] = value end
            nodes[key] = attrs
            if selfClosing ~= "/" then table.insert(stack, key) end
        end
    end

    -- As in the engine, a path segment without an index is index 0 ("a.b.c" = "a.b(0).c(0)").
    local function normalize(path)
        local parts = {}
        for part in path:gmatch("[^%.]+") do
            parts[#parts + 1] = (#parts > 0 and not part:find("%(")) and part .. "(0)" or part
        end
        return table.concat(parts, ".")
    end
    local function get(key)
        local node, attr = key:match("^(.*)#(.*)$")
        node = normalize(node)
        return nodes[node] ~= nil and nodes[node][attr] or nil
    end
    return {
        getString = function(_, key, default) return get(key) or default end,
        getFloat = function(_, key, default) return tonumber(get(key)) or default end,
        getInt = function(_, key, default) local v = tonumber(get(key)); return v ~= nil and math.floor(v) or default end,
        getBool = function(_, key, default)
            local v = get(key)
            if v == nil then return default end
            return v:lower() == "true"
        end,
        iterate = function(_, key, fn)
            local parent, last = key:match("^(.*)%.([^%.]+)$")
            local base = parent ~= nil and normalize(parent) .. "." .. last or key
            for i = 0, (counts[base] or 0) - 1 do fn(i, string.format("%s(%d)", base, i)) end
        end,
        delete = function() end,
    }
end

-- Load part of scripts/animal/RealisticLivestock_Animal.lua, from the first line containing
-- `first` up to (not including) the line containing `last`. The whole file uses GIANTS Lua's
-- `continue`, which stock Lua cannot parse. Animal is created if missing.
function loadAnimalSection(first, last)
    local handle = assert(io.open(REPO .. "scripts/animal/RealisticLivestock_Animal.lua", "r"))
    local text = handle:read("*a")
    handle:close()
    local from = assert(text:find(first, 1, true), first)
    from = text:sub(1, from):match(".*()\n") or 1
    local to = assert(text:find(last, from, true), last)
    to = text:sub(1, to):match(".*()\n") or to
    Animal = Animal or {}
    assert(load("local Log = RmLogging.getLogger()\n" .. text:sub(from, to), "Animal section " .. first))()
end

-- Livestock prices at the calibration level (HARD, x1), so a test sees the calibrated prices;
-- tests/test_livestockprices.lua loads the real module over it.
RLLivestockPrices = { getMultiplier = function() return 1 end }

-- Body condition (scripts/nutrition). Loaded for every test: Animal and the price, carcass and
-- reproduction code read it. Without an AnimalType global no animal is covered, so its factors
-- are 1 and tests of other code see the old behaviour; tests/test_bodycondition.lua covers it.
loadMod("scripts/animal/RLWeightMath.lua")
loadMod("scripts/nutrition/RLNutritionMath.lua")
loadMod("scripts/nutrition/RLBodyConditionConfig.lua")
loadMod("scripts/nutrition/RLBodyCondition.lua")

-- Carcass yield arithmetic (pure): AnimalMoveEvent's carcass entry points compute through it.
loadMod("scripts/animal/RLMeatMath.lua")
-- Delivery rules (pure), shared by AnimalMoveEvent and RLTradeQuote.
loadMod("scripts/animal/RLFacilityRules.lua")
-- Pen records (RLPEN log lines), the construction gate and calf rearing; a placeable without a
-- construction spec is READY and outside a rearing pen nothing changes.
loadMod("scripts/utils/RLPenLog.lua")
loadMod("scripts/bridge/RLPenConstruction.lua")
loadMod("scripts/nutrition/RLCalfRearing.lua")

-- Weight model v2 (RLGrowth). It covers only individual animals (isIndividual = true) of a
-- covered subtype, with the breed traits config loaded; the other tests see the old rules.
loadMod("scripts/animal/RLGrowthCurve.lua")
loadMod("scripts/animal/RLGrowthMath.lua")
loadMod("scripts/animal/RLWeightProfiles.lua")
loadMod("scripts/animal/RLGrowth.lua")

-- Real-equivalent nutrition (RLFeed). The mode is the legacy one unless a test switches it on
-- (RLFeed.mode), so every other test sees the old rules; tests/test_feed.lua covers it.
loadMod("scripts/feed/RLFeedUnits.lua")
loadMod("scripts/feed/RLFeedProfiles.lua")
loadMod("scripts/feed/RLFeedMath.lua")
loadMod("scripts/feed/RLFeedRationPlanner.lua")
loadMod("scripts/feed/RLFeed.lua")

-- RLPEN_DUMP=path: tests that capture RLPEN records append them there as log.txt lines.
function DUMP(line)
    local path = os.getenv("RLPEN_DUMP")
    if path == nil or path == "" then return end
    local handle = io.open(path, "a")
    handle:write("2026-10-07 20:00:00.000   Info: [RLRM|H] " .. line .. "\n")
    handle:close()
end
