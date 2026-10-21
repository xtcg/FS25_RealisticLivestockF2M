-- Read the shipping setting and exercise the real saved-state codec: changing a default
-- must enable a new/missing setting without overwriting an explicit Legacy choice.
local f = assert(io.open(REPO .. "scripts/core/RLSettings.lua", "r"))
local source = f:read("*a"); f:close()
RLFeed = { onSettingChanged = function() end }
local block = assert(source:match('%["nutritionMode"%] = (%b{})'))
local setting = assert(load("return " .. block))()
RLSettings = { SETTINGS = { nutritionMode = setting } }
local first = assert(source:find("function RLSettings.readSettingStates(", 1, true))
local last = assert(source:find("--- Load persisted setting states", first, true))
-- GIANTS adds continue; use Lua's equivalent label in this test-only extracted chunk.
local codec = source:sub(first, last - 1):gsub("continue", "goto nextSetting")
codec = codec:gsub("\n\tend\n\nend%s*$", "\n\t\t::nextSetting::\n\tend\n\nend")
assert(load(codec))()
local function read(saved)
    RLSettings.readSettingStates({ getInt = function(_, key, default)
        if key == "rm_RlSettings.nutritionMode#value" then return saved or default end
        return default
    end }, "rm_RlSettings")
    return setting.values[setting.state]
end
check("release default: absent saved nutrition choice selects Real-equivalent", read(nil) == 2)
check("release migration: explicit saved Legacy remains Legacy", read(1) == 1)
check("release migration: explicit saved Real-equivalent remains Real-equivalent", read(2) == 2)
local weight = loadXMLFileFromDisk(REPO .. "xml/weightProfiles.xml")
check("release default: sheep and pig growth switches are on",
    weight:getBool("weightProfiles.animalType(0)#enabled") and weight:getBool("weightProfiles.animalType(1)#enabled"))
local body = loadXMLFileFromDisk(REPO .. "xml/bodyCondition.xml")
local calf = loadXMLFileFromDisk(REPO .. "xml/calfRearing.xml")
check("release default: cattle growth, body condition and calf rearing stay on",
    weight:getBool("weightProfiles#enabled") and body:getBool("bodyCondition#enabled") and calf:getBool("calfRearing#enabled"))
