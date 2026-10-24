-- Canonical, typed, length-delimited data encoding. This is deliberately a full
-- fingerprint, not a short hash: distinct finite protocol data cannot collide.
-- No executable tables, cycles, non-finite values or implicit tostring methods.
RLMarketData = {}
local function number(v)
    if v ~= v or v == math.huge or v == -math.huge then error("NON_FINITE_DATA") end
    if v == 0 then return "0" end
    if math.type ~= nil and math.type(v) == "integer" then return string.format("%d", v) end
    return string.format("%.17g", v)
end
local function encode(v, active, depth, count)
    count.n = count.n + 1
    if count.n > 100000 or depth > 24 then error("DATA_LIMIT") end
    local t = type(v)
    if t == "nil" then return "z" end
    if t == "boolean" then return v and "b1" or "b0" end
    if t == "number" then local n = number(v); return "n" .. #n .. ":" .. n end
    if t == "string" then return "s" .. #v .. ":" .. v end
    if t ~= "table" or getmetatable(v) ~= nil then error("NON_DATA_INPUT") end
    if active[v] then error("CYCLIC_DATA") end
    active[v] = true
    local entries = {}
    for k, item in pairs(v) do
        if type(k) ~= "string" and type(k) ~= "number" then error("NON_DATA_KEY") end
        local key = encode(k, active, depth + 1, count)
        entries[#entries + 1] = { key, encode(item, active, depth + 1, count) }
    end
    table.sort(entries, function(a, b) return a[1] < b[1] end)
    local out = { "t", tostring(#entries), ":" }
    for _, entry in ipairs(entries) do out[#out + 1] = entry[1]; out[#out + 1] = entry[2] end
    active[v] = nil
    return table.concat(out)
end
function RLMarketData.fingerprint(data)
    local ok, result = pcall(encode, data, {}, 0, { n = 0 })
    if not ok then return nil, "INVALID_MARKET_DATA" end
    return "market1:" .. result
end
function RLMarketData.copy(data)
    -- Validate while cloning; copying does not need a sorted canonical string.
    -- Count keys as well as values, preserving fingerprint's exact data budget.
    local active,count={},0
    local function clone(v,depth)
        count=count+1
        if count>100000 or depth>24 then error("DATA_LIMIT",0) end
        local kind=type(v)
        if kind=="number" then number(v);return v end
        if kind=="nil" or kind=="boolean" or kind=="string" then return v end
        if kind~="table" or getmetatable(v)~=nil then error("NON_DATA_INPUT",0) end
        if active[v] then error("CYCLIC_DATA",0) end
        active[v]=true
        local result={}
        for key,item in pairs(v) do
            if type(key)~="string" and type(key)~="number" then error("NON_DATA_KEY",0) end
            result[clone(key,depth+1)]=clone(item,depth+1)
        end
        active[v]=nil
        return result
    end
    local okay,result=pcall(clone,data,0)
    if not okay then return nil,"INVALID_MARKET_DATA" end
    return result
end
