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

-- The keepModels the shipped Hof Bergmann bridge declares.
local bridge = loadXMLFileFromDisk(REPO .. "mod_support/FS25_HofBergmann/v1.5/animals.xml")
local KEEP = {}
bridge:iterate("animals.keepModels", function(_, key)
    local typeName = bridge:getString(key .. "#type")
    KEEP[typeName] = {}
    bridge:iterate(key .. ".subType", function(_, subKey) table.insert(KEEP[typeName], bridge:getString(subKey .. "#name")) end)
end)

local function copyVisuals(pairs_)
    local out = {}
    for _, p in ipairs(pairs_) do out[#out + 1] = { minAge = p[1], index = p[2] } end
    return out
end

-- Effective visuals as the loaders layer them: RLRM's own subtypes, then the map's NEW subtypes
-- (an existing name is skipped), then the pack (new subtypes, and per-minAge overrides of existing ones).
local function layered(typeName, pack)
    local subTypes, from = {}, {}
    for name, v in pairs(MODEL_SLOTS.RLRM[typeName].subTypes) do subTypes[name] = copyVisuals(v); from[name] = "RLRM" end
    for name, v in pairs(MODEL_SLOTS.HB[typeName].subTypes) do
        if subTypes[name] == nil then subTypes[name] = copyVisuals(v); from[name] = "HB" end
    end
    local snapshot = {}
    for name, v in pairs(subTypes) do snapshot[name] = copyVisuals({}); for i, x in ipairs(v) do snapshot[name][i] = { minAge = x.minAge, index = x.index } end end
    local packWrote = {}
    for name, v in pairs(pack[typeName].subTypes) do
        packWrote[name] = true
        if subTypes[name] == nil then
            subTypes[name] = copyVisuals(v); from[name] = "pack"
        else
            for _, p in ipairs(v) do
                local hit = false
                for _, x in ipairs(subTypes[name]) do if x.minAge == p[1] then x.index = p[2]; hit = true end end
                if not hit then table.insert(subTypes[name], { minAge = p[1], index = p[2] }) end
            end
        end
    end
    return subTypes, snapshot, packWrote, from
end

local function slotText(names, dir)
    local list = {}
    for _, name in ipairs(names) do list[#list + 1] = animalXml(name .. ".i3d") end
    return configXml(list, { "eat", "yell" })
end

local function modelName(path) return path:match("([^/]+)%.i3d$") end

local function replay(typeName, packLabel, withKeep)
    local pack = MODEL_SLOTS[packLabel]
    local hbSlots, packSlots = MODEL_SLOTS.HB[typeName].slots, pack[typeName].slots
    local subTypes, snapshot, packWrote, from = layered(typeName, pack)
    local table_ = packSlots
    if withKeep then
        local slots = {}
        for _, name in ipairs(KEEP[typeName] or {}) do
            for i, x in ipairs(subTypes[name]) do
                if x.index == snapshot[name][i].index then slots[#slots + 1] = x.index end
            end
        end
        local res = RLModelMerge.merge(slotText(packSlots), "/pack/", slotText(hbSlots), "/hb/", slots)
        assert(res ~= nil, "merge failed for " .. typeName)
        table_ = {}
        for i, path in ipairs(assets(res.text)) do table_[i] = modelName(path) end
        for _, name in ipairs(KEEP[typeName]) do
            for i, x in ipairs(subTypes[name]) do
                if x.index == snapshot[name][i].index then x.index = res.indexMap[x.index] end
            end
        end
    end
    return { subTypes = subTypes, snapshot = snapshot, packWrote = packWrote, from = from, table = table_, hb = hbSlots,
        packCount = #packSlots }
end

-- Every visual has a slot; a subtype the pack did not re-point shows the model it showed on the map's own table.
local function audit(r, keep)
    local outOfRange, changed, packMoved = {}, {}, {}
    for name, v in pairs(r.subTypes) do
        for i, x in ipairs(v) do
            if r.table[x.index] == nil then outOfRange[#outOfRange + 1] = name .. "@" .. x.index end
            local snap = r.snapshot[name] and r.snapshot[name][i]
            if snap ~= nil and not r.packWrote[name] and r.table[x.index] ~= r.hb[snap.index] then
                changed[#changed + 1] = string.format("%s %s->%s", name, tostring(r.hb[snap.index]), tostring(r.table[x.index]))
            end
            if r.packWrote[name] and r.from[name] == "pack" and x.index > r.packCount then packMoved[#packMoved + 1] = name end
        end
    end
    table.sort(outOfRange); table.sort(changed)
    return outOfRange, changed, packMoved
end

check("HB bridge declares keepModels: the 4 sheared sheep, the generic BULL",
    KEEP.SHEEP ~= nil and #KEEP.SHEEP == 4 and KEEP.COW ~= nil and #KEEP.COW == 1 and KEEP.COW[1] == "BULL")

-- The bug as reported: the pack's table alone.
local rawSheep = replay("SHEEP", "SheepBreeds", false)
local outS, changedS = audit(rawSheep)
check("without keepModels (sheep): Black Welsh sheared slot 19 missing from the 18-slot pack table",
    #rawSheep.table == 18 and #outS == 1 and outS[1] == "LSFM_SHEEP_BLACK_WELSH_SHEARED@19")
check("without keepModels (sheep): the other three sheared looks show pack lambs/ewes",
    #changedS == 4 and changedS[2] == "LSFM_SHEEP_LANDRACE_SHEARED sheepSheared->sheepLambBaby"
    and changedS[3] == "LSFM_SHEEP_STEINSCHAF_SHEARED sheepSheared->sheepLamb"
    and changedS[4] == "LSFM_SHEEP_SWISS_MOUNTAIN_SHEARED sheepSheared->sheepEwe")
local rawCow = replay("COW", "CowBreeds", false)
local outC, changedC = audit(rawCow)
check("without keepModels (cow): BULL in range but shows Highland models",
    #outC == 0 and #changedC == 4 and changedC[4] == "BULL calf->cattleHighland"
    and changedC[3] == "BULL bullYoung->cattleCalfHighland" and changedC[1] == "BULL bull->cattleCalfHighlandBaby")

-- With the shipped keepModels.
local sheep = replay("SHEEP", "SheepBreeds", true)
local outS2, changedS2, movedS2 = audit(sheep)
check("sheep: pack 18 + 4 sheared = 22 slots (<= 32)", #sheep.table == 22)
check("sheep: every subtype visual index exists", #outS2 == 0)
check("sheep: no subtype outside the pack's own changed model (sheared looks kept, base breeds/goats same model)",
    #changedS2 == 0)
check("sheep: sheared subtypes on 19-22, each the sheared model",
    sheep.subTypes.LSFM_SHEEP_LANDRACE_SHEARED[1].index == 19 and sheep.subTypes.LSFM_SHEEP_BLACK_WELSH_SHEARED[1].index == 22
    and sheep.table[19] == "sheepSheared" and sheep.table[22] == "sheepSheared")
check("sheep: the pack's own breeds untouched (16-18)", #movedS2 == 0
    and sheep.subTypes.SHEEP_TEXEL ~= nil and sheep.subTypes.SHEEP_TEXEL[1].index == 16)

local cow = replay("COW", "CowBreeds", true)
local outC2, changedC2, movedC2 = audit(cow)
check("cow: pack 21 + 3 bull = 24 slots (<= 32)", #cow.table == 24)
check("cow: every subtype visual index exists", #outC2 == 0)
check("cow: no subtype outside the pack's own changed model", #changedC2 == 0)
check("cow: BULL calf/young/adult on 22/23/24 = calf, bullYoung, bull",
    cow.subTypes.BULL[1].index == 22 and cow.subTypes.BULL[2].index == 23 and cow.subTypes.BULL[3].index == 24
    and cow.table[22] == "calf" and cow.table[23] == "bullYoung" and cow.table[24] == "bull")
check("cow: the pack's own subtypes untouched", #movedC2 == 0)

check("hash: stable 8 hex digits, differs on change",
    RLModelMerge.hash("abc") == RLModelMerge.hash("abc") and #RLModelMerge.hash("abc") == 8
    and RLModelMerge.hash("abc") ~= RLModelMerge.hash("abd"))
