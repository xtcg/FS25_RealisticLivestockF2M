--[[
    Slaughter value of a live animal, the floor under Animal:getSellPrice.

        meat  = carcass yield (typical animals, AnimalMoveEvent.getCarcassYieldFactor) x meatPerHead
        value = meat x best current price for the type's meatFillType x share
                (cattle: what slaughtering by contract earns after the fees, less maxSlaughterMargin)

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
local annualCache = {}


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


--- Annual mean price per unit of a fill type at the best selling point: each station's own price
--- (pricePerLiter x its priceScale) x the mean of the fill type's 12 seasonal factors x the
--- difficulty price multiplier, the highest over the stations getMeatPrice reads. The seasonal
--- curve is a closed Catmull-Rom spline through the 12 factors, so its mean over a year is the
--- factors' mean. Random price noise and great demand average out and are left out. Falls back to
--- the fill type's own price when no selling point takes it.
--- @param fillTypeIndex number
--- @return number price 0 when nothing prices it
function RLMeatValue.getAnnualMeanPrice(fillTypeIndex)
    local cached = annualCache[fillTypeIndex]
    if cached ~= nil then return cached end

    local fillType = g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil
        and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
    local factors = fillType ~= nil and fillType.economy ~= nil and fillType.economy.factors or nil
    local total, count = 0, 0
    for period = 1, 12 do
        local factor = factors ~= nil and factors[period] or nil
        if type(factor) == "number" then total, count = total + factor, count + 1 end
    end
    local seasonal = count > 0 and total / count or 1
    local multiplier = EconomyManager ~= nil and EconomyManager.getPriceMultiplier ~= nil and EconomyManager.getPriceMultiplier() or 1

    local best = 0
    local storageSystem = g_currentMission ~= nil and g_currentMission.storageSystem or nil
    local stations = storageSystem ~= nil and storageSystem.getUnloadingStations ~= nil
        and storageSystem:getUnloadingStations() or nil
    for _, station in pairs(stations or {}) do
        local base = station.originalFillTypePrices ~= nil and station.originalFillTypePrices[fillTypeIndex] or nil
        if station.isSellingPoint and not station.hideFromPricesMenu and station.acceptedFillTypes ~= nil
            and station.acceptedFillTypes[fillTypeIndex] and type(base) == "number" and base > best then
            best = base
        end
    end
    local fromStation = best > 0
    if not fromStation and fillType ~= nil then best = fillType.pricePerLiter or 0 end

    -- Cached only when a station priced it: before the map's stations are loaded it is the fallback.
    local price = best * seasonal * multiplier
    if price > 0 and fromStation then
        annualCache[fillTypeIndex] = price
        Log:debug("RLMeatValue.getAnnualMeanPrice: fillType=%s %.3f/l (seasonal mean %.4f)", tostring(fillTypeIndex), price, seasonal)
    end
    return price
end


--- Clear the price cache (tests, and after a map's prices change wholesale).
function RLMeatValue.resetPriceCache()
    priceCache = {}
    annualCache = {}
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


--- Whether the animal is old enough to sell as processing meat (cullAgeMonth).
--- @param animal table
--- @param subType table|nil
--- @return boolean
function RLMeatValue.isCull(animal, subType)
    local layers = AnimalMoveEvent.getCarcassConfig().layers
    local cullAge = RLBreedTraits.resolve(layers, subType, "cullAgeMonth", nil)
    return cullAge ~= nil and (animal.age or 0) >= cullAge
end


--- The part of its meat's value an animal fetches live: cullShare from cullAgeMonth on, else
--- slaughterShare. Used for the types that set no processingFeePerKg.
--- @param animal table
--- @param subType table|nil
--- @return number
function RLMeatValue.getShare(animal, subType)
    local layers = AnimalMoveEvent.getCarcassConfig().layers
    if RLMeatValue.isCull(animal, subType) then
        return RLBreedTraits.resolve(layers, subType, "cullShare", 0)
    end
    return RLBreedTraits.resolve(layers, subType, "slaughterShare", 0)
end


--- How the beef market moves the live price of a bull. The net revenue of one typical animal
--- slaughtered by contract (meat x price - slaughterFee - processingFeePerKg x meat) at the current
--- best meat price over the same at the annual mean price (getAnnualMeanPrice, or referencePrice
--- when set), passed through at marketPassThrough and bounded by marketFactorMin..marketFactorMax:
---   factor = 1 + marketPassThrough x (net now / net at the mean - 1)
--- It is 1 in an average month. At a pass-through under 1 the live price moves less than the meat,
--- so slaughtering by contract pays less in a cheap-beef month and more in a dear one, and about
--- the calibrated margin over the year. Only male animals of a type with processingFeePerKg (cows
--- are priced by their milk); 1 otherwise or when no meat price is known.
--- @param subType table|nil
--- @param gender string|nil
--- @return number
function RLMeatValue.getMarketFactor(subType, gender)
    if subType == nil or gender ~= "male" then return 1 end

    local layers = AnimalMoveEvent.getCarcassConfig().layers
    local perKg = RLBreedTraits.resolve(layers, subType, "processingFeePerKg", nil)
    local typeName = RLBreedTraits.getTypeName(subType)
    local meatPerHead = typeName ~= nil and AnimalMoveEvent.getMeatPerHead(typeName) or nil
    local fillType = typeName ~= nil and RLMeatValue.getMeatFillType(typeName) or nil
    if perKg == nil or meatPerHead == nil or fillType == nil then return 1 end

    local price = RLMeatValue.getMeatPrice(fillType)
    local referencePrice = RLBreedTraits.resolve(layers, subType, "referencePrice", nil)
        or RLMeatValue.getAnnualMeanPrice(fillType)
    if price <= 0 or referencePrice <= 0 then return 1 end

    local fee = RLBreedTraits.resolve(layers, subType, "slaughterFee", 0) + perKg * meatPerHead
    local reference = meatPerHead * referencePrice - fee
    if reference <= 0 then return 1 end

    local passThrough = RLBreedTraits.resolve(layers, subType, "marketPassThrough", 1)
    local factor = 1 + passThrough * ((meatPerHead * price - fee) / reference - 1)
    return math.clamp(factor, RLBreedTraits.resolve(layers, subType, "marketFactorMin", 0),
        RLBreedTraits.resolve(layers, subType, "marketFactorMax", 10))
end


--- What a slaughterhouse pays for the animal live, before disease; 0 when it has no floor.
---
--- A type with processingFeePerKg is priced from what slaughtering it yourself earns:
---   net   = meat kg x price - (slaughterFee per typical animal + processingFeePerKg x meat kg)
---   value = net / (1 + maxSlaughterMargin), x cullFloorFactor from cullAgeMonth on
--- so slaughtering by contract never earns more than maxSlaughterMargin over selling it live (great
--- demand, a heavy or high-quality animal); the live price is then lifted to it. Other types: meat x price x share.
--- @param animal table
--- @return number value
--- @return number meatKg
--- @return number price Per kg of meat
function RLMeatValue.getSlaughterValue(animal)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    local subType = animalSystem ~= nil and animalSystem:getSubTypeByIndex(animal.subTypeIndex) or nil
    if subType == nil then return 0, 0, 0 end

    local typeName = RLBreedTraits.getTypeName(subType)
    local fillType = RLMeatValue.getMeatFillType(typeName)
    if fillType == nil then return 0, 0, 0 end

    local meatKg = RLMeatValue.getMeatKg(animal, subType)
    if meatKg <= 0 then return 0, 0, 0 end

    local price = RLMeatValue.getMeatPrice(fillType)
    local layers = AnimalMoveEvent.getCarcassConfig().layers
    local perKg = RLBreedTraits.resolve(layers, subType, "processingFeePerKg", nil)
    if perKg == nil then
        return meatKg * price * RLMeatValue.getShare(animal, subType), meatKg, price
    end

    local meatPerHead = AnimalMoveEvent.getMeatPerHead(typeName)
    local typical = meatPerHead ~= nil and meatKg / meatPerHead or 1
    local fee = RLBreedTraits.resolve(layers, subType, "slaughterFee", 0) * typical + perKg * meatKg
    local value = math.max(meatKg * price - fee, 0) / (1 + RLBreedTraits.resolve(layers, subType, "maxSlaughterMargin", 0))
    if RLMeatValue.isCull(animal, subType) then
        value = value * RLBreedTraits.resolve(layers, subType, "cullFloorFactor", 1)
    end
    return value, meatKg, price
end


Log:debug("RLMeatValue loaded")
