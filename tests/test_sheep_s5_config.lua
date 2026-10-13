-- Sheep S5: species sections of the nutrition configs (xml/feedProfiles.xml, xml/bodyCondition.xml).
-- Cattle, goats and every other type keep reading the root, which a species section never changes.
loadMod("tests/growthsim.lua")

local F, B = RLFeedProfiles, RLBodyConditionConfig

local sheepType, cowType
for _, sub in ipairs(Economics.subTypes) do
    if sub.typeName == "SHEEP" then sheepType = sub.typeIndex end
    if sub.typeName == "COW" then cowType = sub.typeIndex end
end
local eweSub = { name = "SHEEP_LANDRACE", breed = "LANDRACE", gender = "female", typeIndex = sheepType }
local goatSub = { name = "GOAT", breed = "GOAT", gender = "female", typeIndex = sheepType }
local cowSub = select(2, Economics.find("BULL_ANGUS"))
local function animal(sub) return { getSubType = function() return sub end } end
local function pen(typeIndex) return { getAnimalTypeIndex = function() return typeIndex end } end

-- The shipped file without its species sections: the root must read the same.
local function withoutSpecies(path, root)
    local handle = assert(io.open(REPO .. path, "r"))
    local text = handle:read("*a")
    handle:close()
    text = text:gsub("<species .-</species>", "")
    local tmp = os.tmpname()
    handle = assert(io.open(tmp, "w"))
    handle:write(text)
    handle:close()
    local xml = loadXMLFileFromDisk(tmp)
    os.remove(tmp)
    return xml
end

local function sameValues(a, b, seen)
    seen = seen or {}
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
    if seen[a] then return true end
    seen[a] = true
    for k, v in pairs(a) do
        if k ~= "species" and not sameValues(v, b[k], seen) then return false end
    end
    for k in pairs(b) do
        if k ~= "species" and a[k] == nil then return false end
    end
    return true
end


-- Feed profiles ---------------------------------------------------------------------------------

local feed = F.parse(loadXMLFileFromDisk(REPO .. "xml/feedProfiles.xml"))
local plain = F.parse(withoutSpecies("xml/feedProfiles.xml"))
local sheep = feed.species.SHEEP

check("feed: the root is valid and reads exactly as without the species section (same values and fingerprint)",
    feed.valid and plain.valid and feed.hash == plain.hash and sameValues(feed, plain) and next(plain.species) == nil)
check("feed: the root has no species-only group (physiology, nursing)", feed.physiology == nil and feed.nursing == nil)
check("feed: the SHEEP section is valid, shares the root's feeds and has a fingerprint of its own",
    sheep ~= nil and sheep.valid and sheep.feeds == feed.feeds and sheep.hash ~= feed.hash and sheep.speciesName == "SHEEP")
check("feed: sheep values from AHDB/AFRC (maintenance 0.37, 8.3 MJ a kg of milk, pregnancy 0.55, 14-day adaptation)",
    sheep.requirements.maintenanceMEPerKgMetabolic == 0.37 and sheep.milk.meMJPerKg == 8.3
    and sheep.requirements.pregnancyFactor == 0.55 and sheep.ration.adaptationDays == 14)
check("feed: a group the section leaves an attribute out of keeps the root's (catabolism, health, calf milk)",
    sheep.requirements.catabolismMEPerKg == 10 and feed.requirements.catabolismMEPerKg == 10
    and sheep.health.shortageBufferDays == 3 and feed.health.shortageBufferDays == 3
    and sheep.calfMilk.realLitersPerDay == feed.calfMilk.realLitersPerDay)
check("feed: changing a section's groups never changes the root's (separate tables)",
    sheep.requirements ~= feed.requirements and sheep.classes ~= feed.classes and sheep.classes.GROWING ~= feed.classes.GROWING
    and feed.classes.GROWING.peNdfMin == 0.12 and sheep.classes.GROWING.peNdfMin == 0.10)
local lactation = sheep.nursing.lactation
check("feed: AHDB Table 28 milk rows, lowland default, hill breeds named",
    lactation.default == "LOWLAND" and lactation.systems.LOWLAND.twin[1] == 3.00 and lactation.systems.LOWLAND.single[3] == 1.05
    and lactation.systems.HILL.single[1] == 1.25 and lactation.breeds.BLACKFACE == "HILL" and lactation.breeds.TEXEL == nil)
check("feed: milk ends at weaning (3 months), solids reach full value there",
    F.interpolate(sheep.nursing.curves.milkMax, 3) == 0 and F.interpolate(sheep.nursing.curves.solidMax, 3) == 1
    and F.interpolate(sheep.nursing.curves.milkMax, 0.5) == 1)

local saved = F.getConfig
F.getConfig = function() return feed end
check("feed: an ewe, a sheep pen and the type name read the section; cattle, goats and unknown types the root",
    F.getConfigFor(animal(eweSub)) == sheep and F.getConfigFor(pen(sheepType)) == sheep and F.getConfigFor("SHEEP") == sheep
    and F.getConfigFor(animal(cowSub)) == feed and F.getConfigFor(pen(cowType)) == feed and F.getConfigFor(animal(goatSub)) == feed
    and F.getConfigFor("PIG") == feed and F.getConfigFor(nil) == feed)
check("feed: isValid without a subject is the root's; with a sheep subject also the section's",
    F.isValid() and F.isValid(animal(eweSub)) and F.isValid(animal(cowSub)))
F.getConfig = saved

-- A broken section stays off; the root is unaffected.
do
    local broken = F.parse(loadXMLFileFromDisk(REPO .. "xml/feedProfiles.xml"))
    local section = broken.species.SHEEP
    section.nursing.curves.milkMax = { { 0, 1 }, { 4, 0.5 } }
    local ok, reason = F.validateSpecies(section)
    check("feed: a nursing milk curve still above 0 at weaning fails the section's check", not ok and reason:find("milkMax") ~= nil)
    section.nursing.curves.milkMax = sheep.nursing.curves.milkMax
    section.nursing.lactation = { systems = { LOWLAND = { single = { 2 }, twin = { 3 } } }, breeds = { X = "NOPE" }, default = "LOWLAND" }
    ok, reason = F.validateSpecies(section)
    check("feed: a breed naming an unknown milk system fails the check", not ok and reason:find("unknown system") ~= nil)
end


-- Body condition --------------------------------------------------------------------------------

local body = B.parse(loadXMLFileFromDisk(REPO .. "xml/bodyCondition.xml"))
local bodyPlain = B.parse(withoutSpecies("xml/bodyCondition.xml"))
local bodySheep = body.species.SHEEP
check("body: the root reads exactly as without the species section",
    body.enabled and sameValues(body, bodyPlain) and body.femaleFinishShift == nil and body.fatClasses == nil)
check("body: the SHEEP section is on, 12% of the reference weight a BCS point (0.48 / 4), BCS 3 reference, no fertility effect",
    bodySheep ~= nil and bodySheep.enabled and bodySheep.reserveCapacityRatio == 0.48 and bodySheep.referenceReserve == 0.50
    and bodySheep.fertilityEffect == 0 and body.reserveCapacityRatio == 0.20)
check("body: seven EUROP fat classes ascending, 3L from 0.38", #bodySheep.fatClasses == 7 and bodySheep.fatClasses[3].name == "3L"
    and bodySheep.fatClasses[3].minReserve == 0.38)
check("body: sheep curves are their own, root curves untouched; the root's layers and feed energies are shared",
    bodySheep.curves.finishingTarget ~= body.curves.finishingTarget and body.curves.finishingTarget[3][2] == 0.52
    and bodySheep.curves.finishingTarget[3][2] == 0.45 and bodySheep.layers == body.layers and bodySheep.feedEnergy == body.feedEnergy)
check("body: a typical lamb at 3L keeps all its meat (yield 1 at reserve 0.45), 4H loses 4.5%",
    RLNutritionMath.interpolate(bodySheep.curves.yield, 45) == 1 and RLNutritionMath.interpolate(bodySheep.curves.yield, 70.5) == 0.955 and RLNutritionMath.interpolate(bodySheep.curves.yield, 60) == 0.97)
local savedGet = B.get
B.get = function() return body end
check("body: getFor gives an ewe the section and cattle and goats the root",
    B.getFor(animal(eweSub)) == bodySheep and B.getFor(animal(cowSub)) == body and B.getFor(animal(goatSub)) == body)
B.get = savedGet

-- Network: a client rebuilds the same sections from what the server sends.
do
    local received = { enabled = true, curves = body.curves, feedEnergy = body.feedEnergy, layers = body.layers, species = {} }
    for key in pairs(B.DEFAULTS) do received[key] = body[key] end
    local s = { curves = bodySheep.curves, fatClasses = bodySheep.fatClasses }
    for key in pairs(B.DEFAULTS) do s[key] = bodySheep[key] end
    for key in pairs(B.SPECIES_DEFAULTS) do s[key] = bodySheep[key] end
    received.species.SHEEP = s
    local before = B.config
    B.applyServerConfig(received)
    local client = B.config.species.SHEEP
    check("body: a client's sheep section from the server's values matches the server's",
        client ~= nil and client.enabled and client.reserveCapacityRatio == 0.48 and client.fertilityEffect == 0
        and #client.fatClasses == 7 and client.curves.yield == bodySheep.curves.yield)
    B.config = before
end
