--[[
    Slaughter value of a live animal, the floor under Animal:getSellPrice.

        meat  = carcass yield (typical animals, AnimalMoveEvent.getCarcassYieldFactor) x meatPerHead
        value = meat x best current price for the type's meatFillType x share

    share is what a slaughterhouse pays for the animal live, as a part of its meat's value:
    slaughterShare, or cullShare from cullAgeMonth on (old cows and bulls, sows and boars, mutton).
    The rest is the processing margin, so slaughtering an animal yourself pays 1 - share more
    than selling it live. With the dealer's markup on top, buying an animal to slaughter it
    leaves only a small margin.

    Every setting is read from xml/carcassYield.xml. A type without meatPerHead or meatFillType,
    or whose meat fill type the map lacks, has no floor.
]]

RLMeatValue = {}

local Log = RmLogging.getLogger("RLRM")

--- How long a looked-up meat price is reused, in ms of g_time. getSellPrice runs for every row
--- of the animal screens.
RLMeatValue.PRICE_CACHE_MS = 2000

local priceCache = {}


--- The meat fill type index of an animal type, or nil when it sets none or the map lacks it.
--- @param typeName string|nil
--- @return number|nil
function RLMeatValue.getMeatFillType(typeName)
    if typeName == nil or g_fillTypeManager == nil then return nil end
    local name = AnimalMoveEvent.getCarcassConfig().meatFillTypes[typeName:upper()]
    return name ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
end


--- Best current price per unit (kg for the meat types) of a fill type: the highest price a
--- selling point shown in the prices menu pays for it now, season and demand included. Falls
--- back to the economy's base price when no selling point takes it.
--- @param fillTypeIndex number
--- @return number price 0 when nothing prices it
--- @return string source "station", "economy" or "none"
function RLMeatValue.getMeatPrice(fillTypeIndex)
    local now = g_time
    local cached = priceCache[fillTypeIndex]
    if cached ~= nil and now ~= nil and now - cached.time < RLMeatValue.PRICE_CACHE_MS then
        return cached.price, cached.source
    end

    local best, source = 0, "none"
    local storageSystem = g_currentMission ~= nil and g_currentMission.storageSystem or nil
    local stations = storageSystem ~= nil and storageSystem.getUnloadingStations ~= nil
        and storageSystem:getUnloadingStations() or nil
    for _, station in pairs(stations or {}) do
        if station.isSellingPoint and not station.hideFromPricesMenu and station.acceptedFillTypes ~= nil
            and station.acceptedFillTypes[fillTypeIndex] and station.getEffectiveFillTypePrice ~= nil then
            local ok, price = pcall(station.getEffectiveFillTypePrice, station, fillTypeIndex)
            if ok and type(price) == "number" and price == price and price > best then
                best, source = price, "station"
            end
        end
    end

    if best <= 0 then
        local economy = g_currentMission ~= nil and g_currentMission.economyManager or nil
        local price = economy ~= nil and economy.getPricePerLiter ~= nil and economy:getPricePerLiter(fillTypeIndex) or 0
        if type(price) == "number" and price > 0 then best, source = price, "economy" end
    end

    if cached == nil or cached.source ~= source then
        Log:debug("RLMeatValue.getMeatPrice: fillType=%s %.3f/l from %s", tostring(fillTypeIndex), best, source)
    end
    priceCache[fillTypeIndex] = { price = best, source = source, time = now or 0 }
    return best, source
end


--- Clear the price cache (tests, and after a map's prices change wholesale).
function RLMeatValue.resetPriceCache()
    priceCache = {}
end


--- Kilograms of meat the animal would give at the farm butcher, or 0 when it is too young to
--- be slaughtered or its type sets no meatPerHead.
--- @param animal table
--- @param subType table|nil
--- @return number
function RLMeatValue.getMeatKg(animal, subType)
    local config = AnimalMoveEvent.getCarcassConfig()
    local minAge = RLBreedTraits.resolve(config.layers, subType, "slaughterMinAgeMonth", 0)
    if (animal.age or 0) < minAge then return 0 end

    local meatPerHead = AnimalMoveEvent.getMeatPerHead(RLBreedTraits.getTypeName(subType))
    if meatPerHead == nil then return 0 end
    return AnimalMoveEvent.getCarcassYieldFactor(animal, nil, animal.subTypeIndex) * meatPerHead
end


--- The part of its meat's value an animal fetches live: cullShare from cullAgeMonth on, else
--- slaughterShare.
--- @param animal table
--- @param subType table|nil
--- @return number
function RLMeatValue.getShare(animal, subType)
    local layers = AnimalMoveEvent.getCarcassConfig().layers
    local cullAge = RLBreedTraits.resolve(layers, subType, "cullAgeMonth", nil)
    if cullAge ~= nil and (animal.age or 0) >= cullAge then
        return RLBreedTraits.resolve(layers, subType, "cullShare", 0)
    end
    return RLBreedTraits.resolve(layers, subType, "slaughterShare", 0)
end


--- What a slaughterhouse pays for the animal live, before disease; 0 when it has no floor.
--- @param animal table
--- @return number value
--- @return number meatKg
--- @return number price Per kg of meat
function RLMeatValue.getSlaughterValue(animal)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    local subType = animalSystem ~= nil and animalSystem:getSubTypeByIndex(animal.subTypeIndex) or nil
    if subType == nil then return 0, 0, 0 end

    local fillType = RLMeatValue.getMeatFillType(RLBreedTraits.getTypeName(subType))
    if fillType == nil then return 0, 0, 0 end

    local meatKg = RLMeatValue.getMeatKg(animal, subType)
    if meatKg <= 0 then return 0, 0, 0 end

    local price = RLMeatValue.getMeatPrice(fillType)
    return meatKg * price * RLMeatValue.getShare(animal, subType), meatKg, price
end


Log:debug("RLMeatValue loaded")
