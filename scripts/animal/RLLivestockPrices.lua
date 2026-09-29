--[[
    Livestock products at a fixed difficulty (xml/livestockPrices.xml).

    The economic difficulty multiplies every fill type's selling price (EASY x3, NORMAL x1.8, HARD x1).
    The mod's animals never read it: the dealer and the live price curves are the same on every
    difficulty. Only what animals give (meat, milk, eggs, wool) and the live-price floor that follows
    the meat price move with it. So the listed fill types are sold at the reference difficulty's
    multiplier whatever the game's difficulty is: on HARD with reference EASY, meat, milk and the other
    livestock products sell exactly as on EASY, and so do the live animals, whose floor and market
    factor read those prices. Crops, feed and every cost keep the game's difficulty.
]]

RLLivestockPrices = {}

local Log = RmLogging.getLogger("RLRM")

RLLivestockPrices.CONFIG_FILE = "livestockPrices.xml"
RLLivestockPrices.DIFFICULTIES = { EASY = 1, NORMAL = 2, HARD = 3 }


--- Read a config.
--- @param xmlFile table|nil An XMLFile with a livestockPrices root; nil turns it off
--- @return table config {difficulty = 1..3 or nil, fillTypes = {NAME = true}}
function RLLivestockPrices.parseConfig(xmlFile)
    local config = { fillTypes = {} }
    if xmlFile == nil then return config end

    local name = xmlFile:getString("livestockPrices#difficulty")
    if name ~= nil and name:upper() ~= "GAME" then
        config.difficulty = RLLivestockPrices.DIFFICULTIES[name:upper()]
        if config.difficulty == nil then
            Log:warning("RLLivestockPrices: difficulty '%s' is not EASY, NORMAL, HARD or GAME; using the game's", name)
        end
    end
    xmlFile:iterate("livestockPrices.fillTypes", function(_, key)
        for fillType in (xmlFile:getString(key .. "#names", "") or ""):gmatch("%S+") do
            config.fillTypes[fillType:upper()] = true
        end
    end)
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


--- Whether a fill type is sold at the reference difficulty.
--- @param fillTypeIndex number|nil
--- @return boolean
function RLLivestockPrices.isListed(fillTypeIndex)
    if fillTypeIndex == nil or g_fillTypeManager == nil then return false end
    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    return name ~= nil and RLLivestockPrices.getConfig().fillTypes[name:upper()] == true
end


--- The game's own difficulty price multiplier.
local function gameMultiplier()
    return EconomyManager ~= nil and EconomyManager.getPriceMultiplier ~= nil and EconomyManager.getPriceMultiplier() or 1
end


--- What a fill type's price is multiplied by for the difficulty: the reference difficulty's multiplier
--- for a listed fill type, the game's for any other.
--- @param fillTypeIndex number|nil
--- @return number
function RLLivestockPrices.getPriceMultiplier(fillTypeIndex)
    local difficulty = RLLivestockPrices.getConfig().difficulty
    if difficulty ~= nil and RLLivestockPrices.isListed(fillTypeIndex) and EconomyManager ~= nil
        and EconomyManager.PRICE_MULTIPLIER ~= nil and EconomyManager.PRICE_MULTIPLIER[difficulty] ~= nil then
        return EconomyManager.PRICE_MULTIPLIER[difficulty]
    end
    return gameMultiplier()
end


--- The extra factor a listed fill type's price gets on top of the game's multiplier (3 on HARD with
--- reference EASY; 1 when the game is on the reference difficulty or the fill type is not listed).
--- @param fillTypeIndex number|nil
--- @return number
function RLLivestockPrices.getFactor(fillTypeIndex)
    local game = gameMultiplier()
    if game == nil or game <= 0 then return 1 end
    return RLLivestockPrices.getPriceMultiplier(fillTypeIndex) / game
end


-- Selling points: the server's effective price (what a sale pays and what clients are sent).
if SellingStation ~= nil and SellingStation.getEffectiveFillTypePrice ~= nil then
    SellingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(SellingStation.getEffectiveFillTypePrice,
        function(self, superFunc, fillType, ...)
            local price = superFunc(self, fillType, ...)
            if not self.isServer or type(price) ~= "number" then return price end
            return price * RLLivestockPrices.getFactor(fillType)
        end)
end

-- The economy's price per litre (Hof Bergmann's farm shop sells at it, bales are valued by it).
if EconomyManager ~= nil and EconomyManager.getPricePerLiter ~= nil then
    EconomyManager.getPricePerLiter = Utils.overwrittenFunction(EconomyManager.getPricePerLiter,
        function(self, superFunc, fillTypeIndex, useMultiplier, ...)
            local price = superFunc(self, fillTypeIndex, useMultiplier, ...)
            if useMultiplier == false or type(price) ~= "number" then return price end
            return price * RLLivestockPrices.getFactor(fillTypeIndex)
        end)
end
