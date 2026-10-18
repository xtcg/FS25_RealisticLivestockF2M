--[[
    RLModelMerge.lua
    Builds one husbandry model config out of two: the config an animal pack put in place, plus the
    model slots a map defined for its own subtypes.

    An animal pack's <configOverride> swaps the WHOLE model table of a type. The pack's table keeps
    the base game's slots but knows nothing of a map's own ones, so a map subtype then points at a
    slot that is missing or holds another model:
      - Hof Bergmann SHEEP: slots 16-19 are the four LSFM_*_SHEARED looks; SheepBreeds has 18 slots
        (16-18 its own breeds), so the Black Welsh sheared look (19) is out of range and the other
        three show lambs/ewes of the pack's breeds.
      - Hof Bergmann COW: slots 19-21 are the generic BULL calf/young/adult; CowBreeds has 21 slots
        of its own layout, so BULL shows Highland cows.

    merge() keeps the pack's table as it is (its subtypes, and the base subtypes it remaps, stay
    right) and appends the listed map slots after it. The caller then points the map subtypes at
    the appended slots. Pure text work, no engine calls: the engine reads the result from disk.
]]

RLModelMerge = {}

--- Model slots one husbandry config may hold (the visual animal index the engine takes is 0-31).
RLModelMerge.MAX_SLOTS = 32


--- Short content hash (djb2, 32 bit) for the generated file name: a changed table gets a new path,
--- so nothing the engine may have cached under the old path is reused.
---@param text string
---@return string 8 hex digits
function RLModelMerge.hash(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end


--- Drop XML comments: they may contain tag-like text such as "<animal>".
---@param text string
---@return string
function RLModelMerge.stripComments(text)
    return (text:gsub("<!%-%-.-%-%->", ""))
end


--- True for a path the engine resolves against the config's own folder.
---@param path string
---@return boolean
function RLModelMerge.isRelative(path)
    if path == nil or path == "" then return false end
    local first = path:sub(1, 1)
    if first == "$" or first == "/" or first == "\\" then return false end
    return path:match("^%a:") == nil
end


--- Make every relative file attribute absolute against `dir` (the folder of the config the text
--- came from), so the text still finds its files once it is written somewhere else. File
--- attributes: any name containing "filename" (filename, filenamePosed, sample filename) and
--- "animation".
---@param text string
---@param dir string Folder ending in "/"
---@return string
function RLModelMerge.absolutizePaths(text, dir)
    local function fix(lead, name, value)
        if RLModelMerge.isRelative(value) then value = dir .. value end
        return lead .. name .. '="' .. value .. '"'
    end
    text = text:gsub('(%s)([%w_]*[fF]ilename[%w_]*)="([^"]*)"', fix)
    text = text:gsub('(%s)(animation)="([^"]*)"', fix)
    return text
end


--- The `tag` elements inside text[from..to], in order (an element of the same tag never nests
--- inside another here: <animal> inside <animals>, <soundGroup> inside <sound>).
---@param text string
---@param tag string
---@param from number|nil
---@param to number|nil
---@return table list of { s, e, text }
function RLModelMerge.elements(text, tag, from, to)
    local list = {}
    local pos = from or 1
    local limit = to or #text
    while true do
        local s = text:find("<" .. tag .. "[%s/>]", pos)
        if s == nil or s > limit then break end
        local openEnd = text:find(">", s, true)
        if openEnd == nil then break end
        local e
        if text:sub(openEnd - 1, openEnd) == "/>" then
            e = openEnd
        else
            local _, closeEnd = text:find("</" .. tag .. "%s*>", openEnd)
            if closeEnd == nil then break end
            e = closeEnd
        end
        list[#list + 1] = { s = s, e = e, text = text:sub(s, e) }
        pos = e + 1
    end
    return list
end


--- Start of the block's opening tag, end of its opening tag and start of its closing tag.
---@param text string
---@param tag string e.g. "animals"
---@return number|nil, number|nil, number|nil
function RLModelMerge.block(text, tag)
    local s = text:find("<" .. tag .. "[%s>]")
    if s == nil then return nil end
    local openEnd = text:find(">", s, true)
    local closeStart = openEnd ~= nil and text:find("</" .. tag .. "%s*>", openEnd) or nil
    if closeStart == nil then return nil end
    return s, openEnd, closeStart
end


--- The <animal> elements of a config's <animals> block.
---@param text string Comment-free config text
---@return table|nil
function RLModelMerge.animals(text)
    local _, openEnd, closeStart = RLModelMerge.block(text, "animals")
    if openEnd == nil then return nil end
    return RLModelMerge.elements(text, "animal", openEnd + 1, closeStart - 1)
end


--- Names of the sound groups a config defines in its <sound> block.
---@param text string
---@return table set name -> element text
function RLModelMerge.soundGroups(text)
    local groups = {}
    local _, openEnd, closeStart = RLModelMerge.block(text, "sound")
    if openEnd == nil then return groups end
    for _, element in ipairs(RLModelMerge.elements(text, "soundGroup", openEnd + 1, closeStart - 1)) do
        local name = element.text:match('^<soundGroup[^>]-%sname="([^"]*)"')
        if name ~= nil then groups[name] = element.text end
    end
    return groups
end


--- Merge the map's model slots `slots` (1-based, in the map config) onto the base config.
---@param baseText string Current config (the pack's)
---@param baseDir string Folder of the base config, ending in "/"
---@param mapText string The map's own config
---@param mapDir string Folder of the map config, ending in "/"
---@param slots table Map slot indices to keep
---@return table|nil result { text, count, baseCount, indexMap = { [mapSlot] = mergedSlot }, soundGroups = { names added } }
---@return string|nil error
function RLModelMerge.merge(baseText, baseDir, mapText, mapDir, slots)
    if baseText == nil or mapText == nil then return nil, "config text missing" end

    local base = RLModelMerge.absolutizePaths(RLModelMerge.stripComments(baseText), baseDir)
    local map = RLModelMerge.absolutizePaths(RLModelMerge.stripComments(mapText), mapDir)

    local baseAnimals = RLModelMerge.animals(base)
    local mapAnimals = RLModelMerge.animals(map)
    if baseAnimals == nil then return nil, "base config has no <animals> block" end
    if mapAnimals == nil then return nil, "map config has no <animals> block" end

    local ordered, seen = {}, {}
    for _, slot in ipairs(slots) do
        if mapAnimals[slot] == nil then
            return nil, string.format("map slot %s not in the map config (%d slots)", tostring(slot), #mapAnimals)
        end
        if not seen[slot] then
            seen[slot] = true
            ordered[#ordered + 1] = slot
        end
    end
    table.sort(ordered)

    local count = #baseAnimals + #ordered
    if count > RLModelMerge.MAX_SLOTS then
        return nil, string.format("%d base + %d map slots exceed the %d-slot limit", #baseAnimals, #ordered, RLModelMerge.MAX_SLOTS)
    end

    local indexMap, appended = {}, {}
    local wantedGroups, wantedOrder = {}, {}
    for i, slot in ipairs(ordered) do
        indexMap[slot] = #baseAnimals + i
        local element = mapAnimals[slot].text
        appended[#appended + 1] = string.format("<!-- map slot %d -> %d -->\n%s", slot, indexMap[slot], element)
        for group in element:gmatch('[%w_]*SoundGroup="([^"]*)"') do
            if not wantedGroups[group] then
                wantedGroups[group] = true
                wantedOrder[#wantedOrder + 1] = group
            end
        end
    end

    local _, _, closeStart = RLModelMerge.block(base, "animals")
    local text = base:sub(1, closeStart - 1) .. table.concat(appended, "\n") .. "\n" .. base:sub(closeStart)

    -- Sound groups the appended slots use but the base config lacks (Hof Bergmann's yellBull).
    local baseGroups = RLModelMerge.soundGroups(text)
    local mapGroups = RLModelMerge.soundGroups(map)
    local addedGroups, missing = {}, {}
    for _, group in ipairs(wantedOrder) do
        if baseGroups[group] == nil then
            if mapGroups[group] == nil then
                missing[#missing + 1] = group
            else
                addedGroups[#addedGroups + 1] = group
            end
        end
    end
    if #missing > 0 then
        return nil, "sound group(s) not defined in either config: " .. table.concat(missing, ", ")
    end
    if #addedGroups > 0 then
        local groupText = {}
        for _, group in ipairs(addedGroups) do groupText[#groupText + 1] = mapGroups[group] end
        local _, soundOpenEnd, soundClose = RLModelMerge.block(text, "sound")
        if soundOpenEnd ~= nil then
            text = text:sub(1, soundClose - 1) .. table.concat(groupText, "\n") .. "\n" .. text:sub(soundClose)
        else
            local _, animalsCloseEnd = text:find("</animals%s*>")
            text = text:sub(1, animalsCloseEnd) .. "\n<sound>\n" .. table.concat(groupText, "\n") .. "\n</sound>" .. text:sub(animalsCloseEnd + 1)
        end
    end

    return { text = text, count = count, baseCount = #baseAnimals, indexMap = indexMap, soundGroups = addedGroups }
end
