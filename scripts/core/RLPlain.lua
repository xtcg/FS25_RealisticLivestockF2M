-- Plain-data primitives the protocol, checkpoint and adapter modules each used to define for
-- themselves (identical bodies, one copy per file). Only behaviour that was identical in every
-- copy lives here; validated copies (RLMarketData.copy, RLTradePersistence.parse) and the
-- bounded checks of the wire protocols keep their own limits and stay with their owners.
-- Pure: no engine access. Sourced before every consumer binds it at file scope (tests/
-- check_load_order.py enforces that). RLMarketSchema keeps private copies on purpose: its test
-- loads it with only Lua primitives, proving the wire schema needs no mod globals.
RLPlain = {}
local P = RLPlain

-- A real number: not NaN, not an infinity.
function P.finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end

-- A string with at least one non-space character.
function P.text(v) return type(v) == "string" and v:match("%S") ~= nil end

-- Recursive copy of a tree of plain tables. No cycle guard and metatables are dropped: callers
-- pass data that was already validated or built by this mod.
function P.copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = P.copy(x) end
    return out
end

-- Structural equality of two trees of plain tables: same keys, equal leaves (NaN equals nothing).
function P.equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not P.equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- A table whose keys are exactly 1..#t.
function P.dense(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or k > #t then return false end
        n = n + 1
    end
    return n == #t
end
