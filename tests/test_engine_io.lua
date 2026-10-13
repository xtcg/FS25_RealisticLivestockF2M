-- FS25's io.open (dataS/scripts/io.lua) only writes: whatever mode is asked it creates the file for
-- WRITE, emptying it, and the handle has no read. A script that "reads" a save file through it
-- destroys that file (PR34's RLTradeCheckpoint.readRaw, PR55's dealer checkpoint). Files are read
-- with XMLFile (RLTradePersistence.readXMLText); io.open is for writing only, mode "w".

local function scripts()
    local list = {}
    for _, path in ipairs(listRepoLua("scripts")) do list[#list + 1] = REPO .. path end
    return list
end

local offenders, calls = {}, 0
for _, path in ipairs(scripts()) do
    local handle = assert(io.open(path, "r"))
    local text = handle:read("*a")
    handle:close()
    for args in text:gmatch("io%.open%s*(%b())") do
        calls = calls + 1
        local mode = args:match(',%s*"([^"]*)"%s*%)$')
        if mode ~= "w" then offenders[#offenders + 1] = path:sub(#REPO + 1) .. " " .. args end
    end
end
check(string.format("engine io: every io.open in scripts/ writes with mode \"w\" (%d calls; offenders: %s)", calls,
    #offenders > 0 and table.concat(offenders, "; ") or "none"), calls > 0 and #offenders == 0)

-- The shared reader goes through XMLFile and leaves the file as it was.
loadMod("tests/fixtures/xml_disk.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
local dir = os.tmpname()
os.remove(dir)
local path = dir .. "_engine_io.xml"
XMLDisk.save(path, '<placeables a="1"><placeable id="7"/></placeables>\n')
local before = XMLDisk.read(path)
local text = RLTradePersistence.readXMLText(path, 1000000)
check("readXMLText: the document's text, the file unchanged", text ~= nil and text:find('id="7"', 1, true) ~= nil
    and XMLDisk.read(path) == before)
check("readXMLText: nil when longer than the limit", RLTradePersistence.readXMLText(path, 10) == nil)
XMLDisk.save(path, "not xml <<<")
check("readXMLText: nil for a file that is not XML, which stays as it was", RLTradePersistence.readXMLText(path, 1000)
    == nil and XMLDisk.read(path) == "not xml <<<")
check("readXMLText: nil for a missing file", RLTradePersistence.readXMLText(dir .. "_missing.xml", 1000) == nil)
os.remove(path)
