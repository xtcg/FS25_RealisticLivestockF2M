--[[
    RLPenLog.lua
    One-line JSON records for pen admission, calf rearing and outgrown residents, so a test run's
    verdict can be read from log.txt alone:

        [RLRM|H] RLPEN {"kind":"BUY_CHECK","pen":{...},"animal":{...},...}

    Keys are written in sorted order and numbers with at most 4 decimals, so the same state
    always gives the same line. Records are read-only observations: building one never changes
    an animal, a pen or a rule.
]]

RLPenLog = {}

local Log = RmLogging.getLogger("RLRM")

RLPenLog.TAG = "RLPEN"

--- Longest line written to log.txt; a longer record is replaced by a LINE_TOO_LONG marker (the
--- engine's log cuts long lines, and a cut JSON line would read as a different record).
RLPenLog.MAX_LINE = 3800


local function encode(value, out)
    local kind = type(value)
    if kind == "nil" then
        out[#out + 1] = "null"
    elseif kind == "boolean" then
        out[#out + 1] = value and "true" or "false"
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            out[#out + 1] = "null"
        elseif value == math.floor(value) and math.abs(value) < 2 ^ 53 then
            out[#out + 1] = string.format("%d", value)
        else
            out[#out + 1] = (string.format("%.4f", value):gsub("0+$", ""):gsub("%.$", ""))
        end
    elseif kind == "string" then
        out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(c)
            if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
            return string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif kind == "table" then
        if #value > 0 or next(value) == nil then
            out[#out + 1] = "["
            for i, item in ipairs(value) do
                if i > 1 then out[#out + 1] = "," end
                encode(item, out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for key in pairs(value) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, key in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                encode(key, out)
                out[#out + 1] = ":"
                local item = value[key]
                if item == nil then item = value[tonumber(key)] end
                encode(item, out)
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = '"' .. tostring(value) .. '"'
    end
end


--- @param value any
--- @return string json
function RLPenLog.encode(value)
    local out = {}
    encode(value, out)
    return table.concat(out)
end


--- Write one record.
--- @param kind string Record kind (PROFILE_APPLIED, BUY_CHECK, ...)
--- @param data table Fields; kind is added
--- @param warn boolean|nil Log as a warning
function RLPenLog.emit(kind, data, warn)
    data = data or {}
    data.kind = kind
    local line = RLPenLog.TAG .. " " .. RLPenLog.encode(data)
    if #line > RLPenLog.MAX_LINE then
        line = RLPenLog.TAG .. " " .. RLPenLog.encode({ kind = "LINE_TOO_LONG", record = kind, length = #line,
            pen = data.pen, animal = data.animal })
        warn = true
    end
    if warn then Log:warning("%s", line) else Log:info("%s", line) end
    return line
end


--- A pen's identity for a record.
--- @param placeable table|nil
--- @return table|nil
function RLPenLog.pen(placeable)
    if placeable == nil then return nil end
    local name = placeable.getName ~= nil and placeable:getName() or nil
    local farmId = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
    local config = placeable.configFileName
    if config ~= nil then config = config:gsub("\\", "/"):match("[^/]+/[^/]+$") or config end
    return { name = name, farmId = farmId, config = config, uniqueId = placeable.uniqueId }
end


--- An animal's identity and the fields admission depends on.
--- @param animal table|nil RLRM animal (or its stream copy)
--- @return table|nil
function RLPenLog.animal(animal)
    if animal == nil then return nil end
    local subType = g_currentMission ~= nil and g_currentMission.animalSystem ~= nil
        and animal.subTypeIndex ~= nil and g_currentMission.animalSystem:getSubTypeByIndex(animal.subTypeIndex) or nil
    local country = animal.birthday ~= nil and animal.birthday.country or nil
    return {
        key = (animal.farmId ~= nil and animal.uniqueId ~= nil and country ~= nil)
            and (tostring(animal.farmId) .. " " .. tostring(animal.uniqueId) .. " " .. tostring(country)) or nil,
        farmId = animal.farmId,
        uniqueId = animal.uniqueId,
        country = country,
        subType = subType ~= nil and subType.name or animal.subTypeIndex,
        breed = subType ~= nil and subType.breed or nil,
        gender = animal.gender or (subType ~= nil and subType.gender or nil),
        castrated = animal.isCastrated == true,
        age = animal.age,
        weight = animal.weight,
    }
end
