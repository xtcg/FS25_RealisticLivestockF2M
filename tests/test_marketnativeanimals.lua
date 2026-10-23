-- RLMarketNativeAnimals: the read-only animal inventory of a native placeables/vehicles save.
loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLMarketNativeAnimals.lua")
loadMod("tests/marketnativexml.lua")
local N, X = RLMarketNativeAnimals, MarketNativeXml

local function pen(uid, animals, extra)
    return string.format('<placeable uniqueId="%s" filename="pen.xml" farmId="1"><husbandryAnimals><clusters>%s</clusters></husbandryAnimals>%s</placeable>',
        uid, animals, extra or "")
end
local function animal(id, subType, opts)
    opts = opts or {}
    return string.format('<animal numAnimals="%s" subType="%s" farmId="%s" id="%s"><birthday country="%s"/>%s</animal>',
        opts.num or "1", subType, opts.herd or "878704", id, opts.country or "6", opts.inner or "")
end
local function placeables(rows) return X.parse('<placeables version="1">' .. rows .. '</placeables>') end
local function vehicles(rows) return X.parse('<vehicles>' .. rows .. '</vehicles>') end

-- Resolvers read off the document's own layout (a fixture, not the world inventory).
local function inspector(opts)
    opts = opts or {}
    return N.new({
        resolveContainer = function(role, h)
            if opts.layout then return opts.layout(role, h) end
            local kind = h.uniqueId:match("^pen") and "PEN" or h.uniqueId:match("^trailer") and "TRAILER" or "NON_ANIMAL"
            local layout = { uniqueId = h.uniqueId, kind = kind }
            if kind ~= "NON_ANIMAL" then layout.animalTypeIndices = { 1, 2 } end
            return layout
        end,
        resolveSubtype = function(format, value)
            if opts.subtype then return opts.subtype(format, value) end
            local typeIndex = value:match("^PIG") and 2 or 1
            return { subTypeIndex = format == "LEGACY_RL" and tonumber(value) or 1, animalTypeIndex = typeIndex,
                subTypeName = format == "LEGACY_RL" and "COW_ANGUS" or value }
        end,
        validateInventory = opts.validateInventory })
end

-- A pen and a trailer -----------------------------------------------------------------------------

do
    local inspect = inspector()
    local doc = placeables(pen("pen-1", animal("12", "COW_ANGUS") .. animal("3", "COW_ANGUS", { inner = '<genetics quality="1.1"/><children><child id="9"/></children>' })
        .. '<RLAnimal subType="4" farmId="878704" id="7"><birthday country="6"/></RLAnimal>')
        .. '<placeable uniqueId="shed-1" filename="shed.xml" farmId="1"/>')
    local keys, diag = inspect(doc, "placeables")
    check("pen: every individual of the pen, current and legacy RL entries, keyed farm id + id + country, sorted",
        keys ~= nil and #keys == 3 and keys[1] == "878704 12 6" and keys[2] == "878704 3 6" and keys[3] == "878704 7 6")
    check("pen: diagnostics count containers and individuals, read only", diag.containers == 2 and diag.individuals == 3
        and diag.strawRecords == 0 and diag.source == "NATIVE_XML_READ_ONLY" and diag.role == "placeables")

    -- A trailer and a dewar: the straw's sire record (with its genetics) is not a live animal.
    local trailer = '<vehicle uniqueId="trailer-1" filename="t.xml" farmId="1"><livestockTrailer>' .. animal("21", "COW_ANGUS") .. '</livestockTrailer></vehicle>'
    local dewar = '<vehicle uniqueId="dewar-1" filename="d.xml" farmId="1"><FS_RealisticLivestockRM><dewarData straws="5">'
        .. '<animal country="6" farmId="878704" uniqueId="610017" name="Tornado" typeIndex="1" subTypeIndex="8" success="0.61">'
        .. '<genetics metabolism="1.37"/></animal></dewarData></FS_RealisticLivestockRM></vehicle>'
    keys, diag = inspect(vehicles(trailer .. dewar), "vehicles")
    check("vehicles: trailer animals are live inventory; a dewar's sire record is counted apart, not as an animal",
        keys ~= nil and #keys == 1 and keys[1] == "878704 21 6" and diag.strawRecords == 1 and diag.individuals == 1)
end

-- Refusals --------------------------------------------------------------------------------------------

local function refuses(label, doc, role, reason, opts)
    local keys, why = inspector(opts)(doc, role or "placeables")
    check(label .. " (" .. tostring(why) .. ")", keys == nil and why == reason)
end

refuses("a vanilla cluster (numAnimals 3) is not an individual inventory", placeables(pen("pen-1", animal("1", "COW_ANGUS", { num = "3" }))),
    nil, "VANILLA_CLUSTER_OR_NONLIVE_ENTRY_UNSUPPORTED")
refuses("the same animal key twice", placeables(pen("pen-1", animal("1", "COW_ANGUS")) .. pen("pen-2", animal("1", "COW_ANGUS"))),
    nil, "DUPLICATE_NATIVE_ANIMAL_KEY")
refuses("a pen of two animal types", placeables(pen("pen-1", animal("1", "COW_ANGUS") .. animal("2", "PIG_LANDRACE"))),
    nil, "NATIVE_MIXED_ANIMAL_TYPE_UNSUPPORTED")
refuses("an animal hidden in a non-animal object's own node", placeables('<placeable uniqueId="shed-1" filename="s.xml" farmId="1"><modData>'
    .. animal("5", "COW_ANGUS") .. '</modData></placeable>'), nil, "UNDECLARED_NATIVE_ANIMAL_LAYOUT")
refuses("a live count under dewarData is not a straw record", vehicles('<vehicle uniqueId="dewar-1" filename="d.xml" farmId="1"><dewarData>'
    .. animal("5", "COW_ANGUS") .. '</dewarData></vehicle>'), "vehicles", "UNDECLARED_NATIVE_ANIMAL_LAYOUT")
refuses("an animal nested inside a straw record", vehicles('<vehicle uniqueId="dewar-1" filename="d.xml" farmId="1"><dewarData><animal country="6">'
    .. animal("5", "COW_ANGUS") .. '</animal></dewarData></vehicle>'), "vehicles", "UNDECLARED_NATIVE_ANIMAL_LAYOUT")
refuses("an animal without its birth country", placeables(pen("pen-1", '<animal numAnimals="1" subType="COW_ANGUS" farmId="878704" id="1"/>')),
    nil, "NATIVE_BIRTH_COUNTRY_REQUIRED")
refuses("an unknown placeables save version", X.parse('<placeables version="2">' .. pen("pen-1", animal("1", "COW_ANGUS")) .. '</placeables>'),
    nil, "PLACEABLE_SAVE_VERSION_UNSUPPORTED")
refuses("a subtype the registry does not know", placeables(pen("pen-1", animal("1", "COW_X"))), nil, "NATIVE_SUBTYPE_UNSUPPORTED",
    { subtype = function() return nil end })
refuses("a world inventory the save does not cover", placeables(pen("pen-1", animal("1", "COW_ANGUS"))), nil,
    "NATIVE_WORLD_SAVE_COVERAGE_UNSUPPORTED", { validateInventory = function() return false end })
refuses("an unknown role", placeables(""), "items", "NATIVE_ANIMAL_ROLE_UNSUPPORTED")

do
    local inspect
    inspect = inspector({ layout = function(_, h)
        local again, why = inspect(placeables(""), "placeables")
        check("re-entry: an inspection inside a resolver is refused (" .. tostring(why) .. ")", again == nil and why == "NATIVE_ANIMAL_INSPECTOR_BUSY")
        return { uniqueId = h.uniqueId, kind = "NON_ANIMAL" }
    end })
    local keys = inspect(placeables('<placeable uniqueId="shed-1" filename="s.xml" farmId="1"/>'), "placeables")
    check("re-entry: the outer inspection completes and the inspector is free again", keys ~= nil and #keys == 0
        and inspect(placeables(""), "placeables") ~= nil)
end


-- fromMission: the world's objects decide each container -------------------------------------------------

do
    PlaceableHusbandryAnimals = PlaceableHusbandryAnimals or { name = "PlaceableHusbandryAnimals" }
    LivestockTrailer = LivestockTrailer or { name = "LivestockTrailer" }
    local otherSpec = {}
    local function object(uid, names, specs, opts)
        opts = opts or {}
        local o = { uniqueId = uid, specializationNames = names, specializations = specs, customEnvironment = opts.env }
        function o:getOwnerFarmId() return opts.farm or 1 end
        function o:getNeedsSaving() return opts.saved ~= false end
        if opts.pen then o.spec_husbandryAnimals = { animalTypeIndex = opts.pen } end
        return o
    end
    local subTypes = { [1] = { subTypeIndex = 1, typeIndex = 1, name = "COW_ANGUS" } }
    local function mission(placeableList)
        return { placeableSystem = { placeables = placeableList }, vehicleSystem = { vehicles = {} },
            animalSystem = { getSubTypeIndexByName = function(_, n) return n == "COW_ANGUS" and 1 or nil end,
                getSubTypeByIndex = function(_, i) return subTypes[i] end, getTypeByIndex = function(_, i) return i == 1 and {} or nil end } }
    end
    local doc = placeables(pen("pen-1", animal("1", "COW_ANGUS")) .. '<placeable uniqueId="shop-1" filename="s.xml" farmId="1"/>')
    -- A map's pen (its placeable from the map mod) on the stock writer, next to a mod's non-animal object.
    local mapPen = object("pen-1", { "husbandryAnimals", "husbandryFood" }, { PlaceableHusbandryAnimals, otherSpec }, { env = "FS25_HofBergmann", pen = 1 })
    local modShop = object("shop-1", { "FS25_SomeMod.sellingStation" }, { otherSpec }, { env = "FS25_SomeMod" })
    local inspect = assert(N.fromMission(mission({ mapPen, modShop })))
    local keys, diag = inspect(doc, "placeables")
    check("mission: a map/mod pen on the stock writer and a mod's non-animal object are read (" .. tostring(diag) .. ")",
        keys ~= nil and #keys == 1 and keys[1] == "878704 1 6")

    local function fails(label, objects, reason, document)
        local keysF, why = assert(N.fromMission(mission(objects)))(document or doc, "placeables")
        check(label .. " (" .. tostring(why) .. ")", keysF == nil and why == reason)
    end
    fails("mission: a pen on another writer module", { object("pen-1", { "husbandryAnimals" }, { otherSpec }, { pen = 1 }), modShop },
        "NATIVE_PEN_WRITER_UNSUPPORTED")
    fails("mission: a mod specialization that may hold animals", { mapPen, object("shop-1", { "FS25_SomeMod.animalStorage" }, { otherSpec }) },
        "NATIVE_ANIMAL_SPECIALIZATION_UNSUPPORTED")
    fails("mission: a container owner that does not match the save", { object("pen-1", { "husbandryAnimals" }, { PlaceableHusbandryAnimals }, { pen = 1, farm = 2 }), modShop },
        "NATIVE_CONTAINER_OWNER_MISMATCH")
    fails("mission: a saved object missing from the world", { mapPen }, "NATIVE_WORLD_CONTAINER_MISSING")
    fails("mission: a world pen absent from the save", { mapPen, modShop, object("pen-2", { "husbandryAnimals" }, { PlaceableHusbandryAnimals }, { pen = 1 }) },
        "NATIVE_ANIMAL_CONTAINER_ABSENT_FROM_SAVE")
    fails("mission: a pen that is not saved", { object("pen-1", { "husbandryAnimals" }, { PlaceableHusbandryAnimals }, { pen = 1, saved = false }), modShop },
        "UNPERSISTED_NATIVE_ANIMAL_CONTAINER")
    check("mission: an incomplete mission is unsupported", select(2, N.fromMission({})) == "NATIVE_MISSION_INVENTORY_UNSUPPORTED")
end
