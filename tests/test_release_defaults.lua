-- The retired nutrition model choice (batch E): no nutritionMode row; a saved one is read once by
-- the migration, logged, and never written again. The shipping configs keep every covered species on.
local f = assert(io.open(REPO .. "scripts/core/RLSettings.lua", "r"))
local source = f:read("*a"); f:close()
check("retired: the settings table has no nutritionMode row", source:match('%["nutritionMode"%] = ') == nil)
local frame = assert(io.open(REPO .. "gui/rlmenu/settingsFrame.xml", "r"))
local frameXml = frame:read("*a"); frame:close()
check("retired: the settings page has no nutrition model row", frameXml:find("nutritionMode", 1, true) == nil)

-- The migration codec, extracted as the other settings codec tests do (no engine).
local first = assert(source:find("function RLSettings.migrateRetiredNutritionMode(", 1, true))
local last = assert(source:find("\nend\n", first, true))
Log = Log or { info = function() end }
local logged = {}
local savedInfo = Log.info
Log.info = function(_, fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
RLSettings = RLSettings or {}
assert(load(source:sub(first, last + 4)))()
local function migrate(saved)
    logged = {}
    return RLSettings.migrateRetiredNutritionMode({ getInt = function(_, key)
        if key == "rm_RlSettings.nutritionMode#value" then return saved end
        return nil
    end }, "rm_RlSettings")
end
check("migration: a save without the row needs nothing and logs nothing", migrate(nil) == nil and #logged == 0
    and RLSettings.retiredNutritionMode == nil)
check("migration: a saved Legacy choice is read once and logged (the unified model runs regardless)",
    migrate(1) == 1 and #logged == 1 and logged[1]:find("Legacy", 1, true) ~= nil and RLSettings.retiredNutritionMode == 1)
check("migration: a saved Real-equivalent choice is logged the same way", migrate(2) == 2 and #logged == 1)
Log.info = savedInfo

local weight = loadXMLFileFromDisk(REPO .. "xml/weightProfiles.xml")
check("release default: sheep and pig growth switches are on",
    weight:getBool("weightProfiles.animalType(0)#enabled") and weight:getBool("weightProfiles.animalType(1)#enabled"))
local body = loadXMLFileFromDisk(REPO .. "xml/bodyCondition.xml")
local calf = loadXMLFileFromDisk(REPO .. "xml/calfRearing.xml")
check("release default: cattle growth, body condition and calf rearing stay on",
    weight:getBool("weightProfiles#enabled") and body:getBool("bodyCondition#enabled") and calf:getBool("calfRearing#enabled"))
