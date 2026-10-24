-- RLModelMerge: an animal pack's model table plus the map slots a map bridge keeps (keepModels).
-- Part 1 checks the text merge on small configs; part 2 replays Hof Bergmann 1.5 with
-- FS25_SheepBreedsRLRM / FS25_CowBreedsRLRM on their real slot tables (tests/fixtures/model_slots_hb15.lua).

loadMod("scripts/bridge/RLModelMerge.lua")
loadMod("tests/fixtures/model_slots_hb15.lua")

local function animalXml(asset, extra)
    return string.format('<animal radius="1"><assets filename="%s" filenamePosed="$dataS/x_posed.i3d" animation="anim/clips.i3d"><texture tileUIndex="0"/></assets>'
        .. '<locomotion filename="loco.xml"/><audio eatSoundGroup="eat" yellSoundGroup="%s"/></animal>', asset, extra or "yell")
end

local function configXml(animals, groups)
    local sound = {}
    for _, group in ipairs(groups or {}) do
        sound[#sound + 1] = string.format('<soundGroup name="%s" volume="1"><sample filename="snd/%s.wav"/></soundGroup>', group, group)
    end
    return '<?xml version="1.0" encoding="utf-8"?>\n<animalHusbandry>\n<!-- a comment with <animal> inside -->\n<animals milkRobotSoundGroup="eat">\n'
        .. table.concat(animals, "\n") .. "\n</animals>\n<sound>\n" .. table.concat(sound, "\n") .. "\n</sound>\n</animalHusbandry>\n"
end

local function assets(text)
    local list = {}
    for _, element in ipairs(RLModelMerge.animals(text)) do
        list[#list + 1] = element.text:match('<assets filename="([^"]*)"')
    end
    return list
end

-- ---------------------------------------------------------------- part 1: text merge

local base = configXml({ animalXml("a1.i3d"), animalXml("$dataS/a2.i3d"), animalXml("a3.i3d") }, { "eat", "yell" })
local map = configXml({ animalXml("m1.i3d"), animalXml("m2.i3d"), animalXml("m3.i3d"),
    animalXml("../bull/m4.i3d", "yellBull"), animalXml("m5.i3d", "yellBaby") }, { "eat", "yell", "yellBull", "yellBaby", "unused" })

local result, err = RLModelMerge.merge(base, "/mods/pack/models/", map, "/mods/map/cow/", { 5, 4, 4 })
check("merge: succeeds", result ~= nil and err == nil)
local list = assets(result.text)
check("merge: base slots first, map slots appended in slot order, duplicates once",
    result.count == 5 and result.baseCount == 3 and #list == 5
    and list[4] == "/mods/map/cow/../bull/m4.i3d" and list[5] == "/mods/map/cow/m5.i3d")
check("merge: index map old -> new", result.indexMap[4] == 4 and result.indexMap[5] == 5 and result.indexMap[1] == nil)
check("merge: relative base paths made absolute, $ paths kept",
    list[1] == "/mods/pack/models/a1.i3d" and list[2] == "$dataS/a2.i3d"
    and select(2, result.text:gsub('animation="/mods/pack/models/anim/clips.i3d"', "")) == 3
    and result.text:find('filenamePosed="$dataS/x_posed.i3d"', 1, true) ~= nil
    and result.text:find('<locomotion filename="/mods/map/cow/loco.xml"/>', 1, true) ~= nil)
check("merge: sound groups the appended slots need are copied from the map, nothing else",
    #result.soundGroups == 2 and result.soundGroups[1] == "yellBull" and result.soundGroups[2] == "yellBaby"
    and result.text:find('name="unused"', 1, true) == nil
    and result.text:find('<sample filename="/mods/map/cow/snd/yellBull.wav"/>', 1, true) ~= nil
    and select(2, result.text:gsub('<soundGroup name="yell"', "")) == 1)
check("merge: comments dropped (none can fake an <animal>)", result.text:find("<!-- a comment", 1, true) == nil)
check("merge: animals attributes of the base kept", result.text:find('<animals milkRobotSoundGroup="eat">', 1, true) ~= nil)

check("merge: map slot outside the map table refused", RLModelMerge.merge(base, "/p/", map, "/m/", { 6 }) == nil)
local many = {}
for i = 1, 31 do many[i] = animalXml("b" .. i .. ".i3d") end
check("merge: more than 32 slots refused", RLModelMerge.merge(configXml(many, { "eat", "yell" }), "/p/", map, "/m/", { 1, 2 }) == nil)
check("merge: a sound group neither config defines is refused",
    RLModelMerge.merge(base, "/p/", configXml({ animalXml("m1.i3d", "nowhere") }, { "eat" }), "/m/", { 1 }) == nil)
local noSound = configXml({ animalXml("a1.i3d") }):gsub("<sound>.-</sound>", "")
local merged = RLModelMerge.merge(noSound, "/p/", map, "/m/", { 4 })
check("merge: a base without <sound> gets one for the copied groups",
    merged ~= nil and merged.text:find("</animals>\n<sound>", 1, true) ~= nil and merged.text:find('name="yellBull"', 1, true) ~= nil)
check("isRelative: windows and unix absolute, $ paths, empty",
    not RLModelMerge.isRelative("C:/mods/x.i3d") and not RLModelMerge.isRelative("/mods/x.i3d")
    and not RLModelMerge.isRelative("$data/x.i3d") and not RLModelMerge.isRelative("") and RLModelMerge.isRelative("../x.i3d"))

-- ---------------------------------------------------------------- part 2: Hof Bergmann 1.5 + packs

-- What the shipped Hof Bergmann bridge declares: keepModels entries (in order) and visual index overrides.
local bridge = loadXMLFileFromDisk(REPO .. "mod_support/FS25_HofBergmann/v1.5/animals.xml")
local KEEP, OVERRIDES = {}, {}
bridge:iterate("animals.keepModels", function(_, key)
    local entry = { typeName = bridge:getString(key .. "#type"), source = (bridge:getString(key .. "#source") or "map"):lower(), names = {} }
    bridge:iterate(key .. ".subType", function(_, subKey) table.insert(entry.names, bridge:getString(subKey .. "#name")) end)
    table.insert(KEEP, entry)
end)
bridge:iterate("animals.animal", function(_, key)
    local typeName = bridge:getString(key .. "#type")
    bridge:iterate(key .. ".subType", function(_, subKey)
        local name = bridge:getString(subKey .. "#subType")
        bridge:iterate(subKey .. ".visuals.visual", function(_, vKey)
            local index = bridge:getInt(vKey .. "#visualAnimalIndex")
            if index ~= nil then
                table.insert(OVERRIDES, { typeName = typeName, name = name, minAge = bridge:getInt(vKey .. "#minAge"), index = index })
            end
        end)
    end)
end)

local function sigModel(sig) return sig ~= nil and sig:match("^([^|]*)") or nil end

-- Synthetic config whose slots carry the fixture's signatures ("model|u,v,n"), and the signatures read back.
local function slotText(sigs)
    local list = {}
    for _, sig in ipairs(sigs) do
        local model, u, v, n = sig:match("^([^|]*)|(%d+),(%d+),(%d+)$")
        model = model or sigModel(sig)
        list[#list + 1] = string.format('<animal><assets filename="%s.i3d"><texture tileUIndex="%s" tileVIndex="%s" numTilesU="%s"/></assets>'
            .. '<audio yellSoundGroup="yell"/></animal>', model, u or "0", v or "0", n or "1")
    end
    return configXml(list, { "eat", "yell" })
end
local function readSigs(text)
    local list = {}
    for _, element in ipairs(RLModelMerge.animals(text)) do
        local model = element.text:match('<assets filename="[^"]-([^/"]+)%.i3d"')
        local u, v, n = element.text:match('<texture tileUIndex="(%d+)" tileVIndex="(%d+)" numTilesU="(%d+)"')
        list[#list + 1] = u ~= nil and string.format("%s|%s,%s,%s", model, u, v, n) or model .. "|-"
    end
    return list
end

local stampSerial = 0
local function stamp() stampSerial = stampSerial + 1; return stampSerial end
local function visualsOf(pairs_, layer, tableName)
    local out = {}
    for _, p in ipairs(pairs_) do out[#out + 1] = { minAge = p[1], index = p[2], layer = layer, table = tableName, stamp = stamp() } end
    return out
end
local function write(visuals, minAge, index, layer, tableName)
    for _, x in ipairs(visuals) do
        if x.minAge == minAge then x.index = index; x.layer = layer; x.table = tableName; x.stamp = stamp(); return end
    end
    table.insert(visuals, { minAge = minAge, index = index, layer = layer, table = tableName, stamp = stamp() })
end

-- Replays the loaders on Hof Bergmann, optionally with one pack, with or without keepModels.
-- Each visual remembers the table its index was written for (`table`), so the model it should show
-- is that table's slot: RLRM subtypes RLRM's, map subtypes HB's, pack-written visuals the pack's.
local function replay(typeName, packLabel, withKeep)
    local tables = { RLRM = MODEL_SLOTS.RLRM[typeName].slots, HB = MODEL_SLOTS.HB[typeName].slots }
    local subTypes = {}
    for name, v in pairs(MODEL_SLOTS.RLRM[typeName].subTypes) do subTypes[name] = visualsOf(v, "RLRM", "RLRM") end
    for name, v in pairs(MODEL_SLOTS.HB[typeName].subTypes) do
        if subTypes[name] == nil then subTypes[name] = visualsOf(v, "HB", "HB") end
    end
    for _, o in ipairs(OVERRIDES) do        -- the bridge writes indices of HB's table
        if o.typeName == typeName and subTypes[o.name] ~= nil then write(subTypes[o.name], o.minAge, o.index, "bridge", "HB") end
    end

    local entries = {}                      -- keepModels snapshots, taken as the map bridge loads
    for _, keep in ipairs(KEEP) do
        if keep.typeName == typeName then
            local entry = { source = keep.source, snaps = {} }
            for _, name in ipairs(keep.names) do
                for _, x in ipairs(subTypes[name] or {}) do table.insert(entry.snaps, { visual = x, index = x.index, stamp = x.stamp }) end
            end
            table.insert(entries, entry)
        end
    end

    local current, packCount = tables.HB, nil
    if packLabel ~= nil then
        local pack = MODEL_SLOTS[packLabel][typeName]
        tables.pack, current, packCount = pack.slots, pack.slots, #pack.slots
        for name, v in pairs(pack.subTypes) do
            if subTypes[name] == nil then
                subTypes[name] = visualsOf(v, "pack", "pack")
            else
                for _, p in ipairs(v) do write(subTypes[name], p[1], p[2], "pack", "pack") end
            end
        end
    end

    local currentName = packLabel ~= nil and "pack" or "HB"
    if withKeep then
        for _, entry in ipairs(entries) do
            local sourceName = entry.source == "rlrm" and "RLRM" or "HB"
            if sourceName ~= currentName then
                local slots, live = {}, {}
                for _, snap in ipairs(entry.snaps) do
                    if snap.visual.index == snap.index and snap.visual.stamp == snap.stamp then
                        slots[#slots + 1] = snap.index; live[#live + 1] = snap
                    end
                end
                if #slots > 0 then
                    local res = assert(RLModelMerge.merge(slotText(current), "/cur/", slotText(tables[sourceName]), "/src/", slots))
                    current = readSigs(res.text)
                    for _, snap in ipairs(live) do snap.visual.index = res.indexMap[snap.index]; snap.visual.merged = true end
                    tables.merged = current
                    currentName = "merged"
                end
            end
        end
    end
    return { subTypes = subTypes, tables = tables, current = current, packCount = packCount }
end

-- Every visual has a slot, and shows the model its index was written for. A visual moved onto an
-- appended slot is checked against its source slot (exact signature); one left on a pack's own
-- slot is checked by model only (packs re-texture the base breeds on their own atlas).
local function audit(r)
    local outOfRange, wrong = {}, {}
    for name, v in pairs(r.subTypes) do
        for _, x in ipairs(v) do
            local shown = r.current[x.index]
            if shown == nil then
                outOfRange[#outOfRange + 1] = name .. "@" .. x.index
            elseif x.table ~= "pack" and not x.merged then
                local meant = r.tables[x.table][x.index]
                local same = (r.packCount ~= nil and x.index <= r.packCount) and sigModel(shown) == sigModel(meant) or shown == meant
                if not same then wrong[#wrong + 1] = string.format("%s@%d %s->%s", name, x.minAge, tostring(meant), shown) end
            end
        end
    end
    table.sort(outOfRange); table.sort(wrong)
    return outOfRange, wrong
end
local function shows(r, name, minAge)
    for _, x in ipairs(r.subTypes[name]) do if x.minAge == minAge then return sigModel(r.current[x.index]), x.index end end
end

local keepTypes = {}
for _, e in ipairs(KEEP) do keepTypes[#keepTypes + 1] = e.typeName .. ":" .. e.source .. ":" .. table.concat(e.names, ",") end
check("HB bridge keepModels: sheared sheep (map), BULL (map), Hereford (rlrm)",
    table.concat(keepTypes, " ") == "SHEEP:map:LSFM_SHEEP_LANDRACE_SHEARED,LSFM_SHEEP_STEINSCHAF_SHEARED,LSFM_SHEEP_SWISS_MOUNTAIN_SHEARED,LSFM_SHEEP_BLACK_WELSH_SHEARED"
        .. " COW:map:BULL COW:rlrm:COW_HEREFORD,BULL_HEREFORD")

-- Without keepModels: the reported bugs.
local o, w = audit(replay("SHEEP", "SheepBreeds", false))
check("without keepModels, SheepBreeds: Black Welsh sheared @19 out of range, the other sheared looks wrong",
    #o == 1 and o[1] == "LSFM_SHEEP_BLACK_WELSH_SHEARED@19" and #w == 3)
o, w = audit(replay("COW", "CowBreeds", false))
check("without keepModels, CowBreeds: BULL shows Highland cattle (4 stages)", #o == 0 and #w == 4 and w[1]:find("^BULL@") ~= nil)
o, w = audit(replay("COW", nil, false))
local herefordWrong = 0
for _, line in ipairs(w) do if line:find("HEREFORD") then herefordWrong = herefordWrong + 1 end end
check("without keepModels, no pack: Hereford shows HB's Highland (8 stages)", #o == 0 and #w == 8 and herefordWrong == 8)

-- With the shipped bridge.
local sheepPlain = replay("SHEEP", nil, true)
o, w = audit(sheepPlain)
check("HB sheep, no pack: unchanged 19-slot table, every visual right", #sheepPlain.current == 19 and #o == 0 and #w == 0)

local sheep = replay("SHEEP", "SheepBreeds", true)
o, w = audit(sheep)
check("HB + SheepBreeds: 18 + 4 = 22 slots, every visual in range and right", #sheep.current == 22 and #o == 0 and #w == 0)
check("HB + SheepBreeds: sheared looks on 19-22", select(2, shows(sheep, "LSFM_SHEEP_LANDRACE_SHEARED", 0)) == 19
    and select(2, shows(sheep, "LSFM_SHEEP_BLACK_WELSH_SHEARED", 0)) == 22 and shows(sheep, "LSFM_SHEEP_BLACK_WELSH_SHEARED", 0) == "sheepSheared")
check("HB + SheepBreeds: the pack's breeds keep their slots", select(2, shows(sheep, "SHEEP_TEXEL", 0)) == 16)

local cowPlain = replay("COW", nil, true)
o, w = audit(cowPlain)
check("HB cow, no pack: 21 + 3 Hereford = 24 slots, every visual in range and right", #cowPlain.current == 24 and #o == 0 and #w == 0)
check("HB cow, no pack: Hereford on RLRM's Hereford models (appended 22-24)",
    select(2, shows(cowPlain, "COW_HEREFORD", 12)) == 22 and cowPlain.current[22] == MODEL_SLOTS.RLRM.COW.slots[16]
    and select(2, shows(cowPlain, "BULL_HEREFORD", 0)) == 24 and cowPlain.current[24] == MODEL_SLOTS.RLRM.COW.slots[18])
check("HB cow, no pack: Highland on HB's own Highland 16-18, BULL on its bull models 19-21",
    shows(cowPlain, "COW_HIGHLAND_CATTLE", 0) == "cattleCalfHighlandBaby" and shows(cowPlain, "BULL_HIGHLAND_CATTLE", 12) == "cattleHighland"
    and shows(cowPlain, "BULL", 0) == "calf" and shows(cowPlain, "BULL", 24) == "bull")

local cow = replay("COW", "CowBreeds", true)
o, w = audit(cow)
check("HB + CowBreeds: 21 + 3 bull = 24 slots, every visual in range and right", #cow.current == 24 and #o == 0 and #w == 0)
check("HB + CowBreeds: BULL on 22/23/24 = calf, bullYoung, bull",
    select(2, shows(cow, "BULL", 0)) == 22 and shows(cow, "BULL", 0) == "calf" and shows(cow, "BULL", 6) == "bullYoung" and shows(cow, "BULL", 12) == "bull")
check("HB + CowBreeds: Hereford/Highland stay on the pack's own slots (no Hereford slots appended)",
    select(2, shows(cow, "COW_HEREFORD", 12)) == 7 and select(2, shows(cow, "BULL_HIGHLAND_CATTLE", 12)) == 17)

check("hash: stable 8 hex digits, differs on change",
    RLModelMerge.hash("abc") == RLModelMerge.hash("abc") and #RLModelMerge.hash("abc") == 8
    and RLModelMerge.hash("abc") ~= RLModelMerge.hash("abd"))

-- r6 game test: the LSFM animated livestock trailer resolves a type config's files with
-- Utils.getFilename(value, folder of the config), as base Utils does: "$" or join. The generated config's
-- absolute "D:/mods/..." became "<modSettings>/generated/D:/mods/..." and the trailer animals did not load.
do
    local gen = "C:/Users/p/Documents/My Games/FarmingSimulator2025/modSettings/FS25_RealisticLivestockRM/generated/"
    local U = {}
    function U.getFilename(filename, baseDir)
        if filename:sub(1, 1) == "$" then return "GAME/" .. filename:sub(2), false end
        if baseDir == nil or baseDir == "" then return filename, false end
        return baseDir .. filename, true
    end
    RLModelMerge.guardGeneratedPaths(U, gen)
    local wrapped = U.getFilename
    RLModelMerge.guardGeneratedPaths(U, gen)
    check("generated paths: guard installs once per folder", U.getFilename == wrapped)
    local path, relative = U.getFilename("D:/mods/fs25/FS25_CowBreedsRLRM/models/cow/angus/cattleCalf.i3d", gen)
    check("generated paths: a drive path in a generated config stays as written",
        path == "D:/mods/fs25/FS25_CowBreedsRLRM/models/cow/angus/cattleCalf.i3d" and relative == false)
    check("generated paths: backslash drive paths and root paths too",
        U.getFilename("D:\\mods\\x.xml", gen) == "D:\\mods\\x.xml" and U.getFilename("/mods/x.xml", gen) == "/mods/x.xml")
    check("generated paths: game paths and relative paths of the generated folder resolve as before",
        U.getFilename("$dataS/x_posed.i3d", gen) == "GAME/dataS/x_posed.i3d" and U.getFilename("loco.xml", gen) == gen .. "loco.xml")
    check("generated paths: other folders keep base behaviour, even for drive paths",
        U.getFilename("D:/mods/x.i3d", "D:/mods/fs25/FS25_HofBergmann/") == "D:/mods/fs25/FS25_HofBergmann/D:/mods/x.i3d"
        and U.getFilename("models/x.i3d", "D:/mods/fs25/FS25_HofBergmann/") == "D:/mods/fs25/FS25_HofBergmann/models/x.i3d")
end
