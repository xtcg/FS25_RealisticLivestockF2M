-- Minimal stand-ins for the GIANTS engine globals the tested scripts touch at load and run time.
-- Each test file gets a fresh Lua state with these loaded, then overrides what it needs.

math.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end

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
