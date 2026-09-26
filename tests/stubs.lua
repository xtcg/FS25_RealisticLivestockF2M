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

-- XMLFile over a real file on disk: elements and attributes only (comments and the
-- declaration dropped), addressed with the engine's "root.child(i).grandchild(j)#attr" keys.
function loadXMLFileFromDisk(path)
    local handle = io.open(path, "r")
    if handle == nil then return nil end
    local text = handle:read("a"):gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
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

    local function get(key)
        local node, attr = key:match("^(.*)#(.*)$")
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
            for i = 0, (counts[key] or 0) - 1 do fn(i, string.format("%s(%d)", key, i)) end
        end,
        delete = function() end,
    }
end
