--[[
    Livestock price scale (xml/livestockPrices.xml): one factor for the live-animal prices, semen,
    the base prices of the fill types animals give, and the contract slaughter fees, so the whole
    livestock economy can be set against the map's (difficulty-scaled) crop and feed prices.
]]

RLLivestockPrices = {}

local Log = RmLogging.getLogger("RLRM")

RLLivestockPrices.CONFIG_FILE = "livestockPrices.xml"


--- Read a livestock price config.
--- @param xmlFile table|nil An XMLFile with a livestockPrices root; nil gives scale 1
--- @return table config {scale, feeScale, fillTypes = {NAME, ...}, basePrices = {NAME = price}}
function RLLivestockPrices.parseConfig(xmlFile)
    local config = { scale = 1, fillTypes = {}, basePrices = {} }
    if xmlFile ~= nil then
        config.scale = xmlFile:getFloat("livestockPrices#scale", 1)
        config.feeScale = xmlFile:getFloat("livestockPrices#feeScale")
        xmlFile:iterate("livestockPrices.basePrice", function(_, key)
            local name, price = xmlFile:getString(key .. "#fillType"), xmlFile:getFloat(key .. "#price")
            if name ~= nil and price ~= nil and price > 0 then
                config.basePrices[name:upper()] = price
            else
                Log:warning("RLLivestockPrices: %s needs a fillType and a price above 0, ignored", key)
            end
        end)
        xmlFile:iterate("livestockPrices.fillTypes", function(_, key)
            for name in (xmlFile:getString(key .. "#names", "") or ""):gmatch("%S+") do
                config.fillTypes[#config.fillTypes + 1] = name:upper()
            end
        end)
    end
    if config.scale == nil or config.scale <= 0 then
        Log:warning("RLLivestockPrices: scale must be above 0, using 1")
        config.scale = 1
    end
    if config.feeScale == nil or config.feeScale < 0 then config.feeScale = config.scale end
    return config
end


--- The config, loaded on the first call.
function RLLivestockPrices.getConfig()
    if RLLivestockPrices.config == nil then
        RLLivestockPrices.config = RLBreedTraits.loadConfig(RLLivestockPrices.CONFIG_FILE, "livestockPrices",
            RLLivestockPrices.parseConfig)
    end
    return RLLivestockPrices.config
end


--- Factor on live-animal prices, semen and the listed fill types.
--- @return number
function RLLivestockPrices.getScale()
    return RLLivestockPrices.getConfig().scale
end


--- Factor on contract slaughter fees.
--- @return number
function RLLivestockPrices.getFeeScale()
    return RLLivestockPrices.getConfig().feeScale
end


--- Set the configured base prices (basePrice, in place of the map's; the price history restarts from
--- them), then multiply the base price and price history of each listed fill type by the scale, once
--- per fill type object. Runs after the map's and other mods' fill types are loaded and before any
--- selling point reads a price.
--- @param fillTypeManager table
--- @return number scaled Number of fill types changed
function RLLivestockPrices.applyToFillTypes(fillTypeManager)
    local config = RLLivestockPrices.getConfig()
    local scale = config.scale
    if fillTypeManager == nil then return 0 end

    for name, price in pairs(config.basePrices or {}) do
        local fillType = fillTypeManager:getFillTypeByName(name)
        if fillType ~= nil and fillType.rlLivestockBasePrice == nil then
            Log:info("RLLivestockPrices: %s base price %.3f -> %.3f", name, fillType.pricePerLiter or 0, price)
            fillType.pricePerLiter = price
            local economy = fillType.economy
            if economy ~= nil and economy.history ~= nil then
                for period in pairs(economy.history) do
                    economy.history[period] = ((economy.factors ~= nil and economy.factors[period]) or 1) * price
                end
            end
            fillType.rlLivestockBasePrice = price
        end
    end
    if scale == 1 then return 0 end

    local scaled, missing = 0, {}
    for _, name in ipairs(config.fillTypes) do
        local fillType = fillTypeManager:getFillTypeByName(name)
        if fillType == nil then
            missing[#missing + 1] = name
        elseif fillType.rlLivestockPriceScale == nil then
            fillType.pricePerLiter = (fillType.pricePerLiter or 0) * scale
            local history = fillType.economy ~= nil and fillType.economy.history or nil
            for period, price in pairs(history or {}) do history[period] = price * scale end
            fillType.rlLivestockPriceScale = scale
            scaled = scaled + 1
        end
    end

    Log:info("RLLivestockPrices: %d livestock fill type price(s) x%.2f%s", scaled, scale,
        #missing > 0 and (" (not on this map: " .. table.concat(missing, " ") .. ")") or "")
    return scaled
end


if FillTypeManager ~= nil and FillTypeManager.loadModFillTypes ~= nil then
    FillTypeManager.loadModFillTypes = Utils.appendedFunction(FillTypeManager.loadModFillTypes, function(self)
        RLLivestockPrices.applyToFillTypes(self)
    end)
end
