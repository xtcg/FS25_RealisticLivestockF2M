--[[
    RLCurveScale.lua
    Scales whole age curves of a subtype once, after every map bridge and animal pack has loaded,
    by factors from xml/breedTraits.xml (subType > breed > animalType, default 1):

        woolScale    output.pallets curve (wool; set only on wool producers)
        waterScale   input.water
        strawScale   input.straw
        manureScale  output.manure
        priceScale   buyPrice and sellPrice (a ram lamb's live price at its real finishing age)

    The engine reads curve keys as integers (AnimalSystem:loadAnimCurve, getInt), so a fleece of
    half a liter a month cannot be written into animals.xml; scaling the loaded keyframes keeps
    fractions and needs no edit to a pack's own files (FS25_SheepBreedsRLRM belongs to its author).
    Each curve object is scaled once (a flag on the curve), so a second call or two subtypes sharing
    one curve never scale it twice.
]]

RLCurveScale = {}

local Log = RmLogging.getLogger("RLRM")

--- Trait name -> function(subType) returning the curve it scales, or nil.
RLCurveScale.CURVES = {
    woolScale = function(subType)
        local pallets = subType.output ~= nil and subType.output.pallets or nil
        return pallets ~= nil and pallets.curve or nil
    end,
    waterScale = function(subType) return subType.input ~= nil and subType.input.water or nil end,
    strawScale = function(subType) return subType.input ~= nil and subType.input.straw or nil end,
    manureScale = function(subType) return subType.output ~= nil and subType.output.manure or nil end,
    buyPriceScale = function(subType) return subType.buyPrice end,
    sellPriceScale = function(subType) return subType.sellPrice end,
}

--- Trait read for each scaled curve (both price curves follow priceScale).
RLCurveScale.TRAIT_OF = { woolScale = "woolScale", waterScale = "waterScale", strawScale = "strawScale",
    manureScale = "manureScale", buyPriceScale = "priceScale", sellPriceScale = "priceScale" }

RLCurveScale.ORDER = { "woolScale", "waterScale", "strawScale", "manureScale", "buyPriceScale", "sellPriceScale" }


--- Multiply every keyframe value of a curve by `factor`, once per curve.
--- @return boolean scaled
function RLCurveScale.scaleCurve(curve, factor)
    if curve == nil or curve.keyframes == nil or curve.rlCurveScaled then return false end
    for _, keyframe in ipairs(curve.keyframes) do
        if type(keyframe[1]) == "number" then keyframe[1] = keyframe[1] * factor end
    end
    curve.rlCurveScaled = factor
    return true
end


--- Apply the configured factors to every subtype of the animal system.
--- @param animalSystem table
--- @return number count Curves scaled
function RLCurveScale.apply(animalSystem)
    if animalSystem == nil or animalSystem.subTypes == nil then return 0 end
    local layers = RLBreedTraits.getConfig().layers
    local count = 0
    for _, subType in ipairs(animalSystem.subTypes) do
        local parts = {}
        for _, trait in ipairs(RLCurveScale.ORDER) do
            local factor = RLBreedTraits.resolve(layers, subType, RLCurveScale.TRAIT_OF[trait], 1)
            if type(factor) == "number" and factor >= 0 and factor ~= 1 then
                if RLCurveScale.scaleCurve(RLCurveScale.CURVES[trait](subType), factor) then
                    count = count + 1
                    table.insert(parts, string.format("%s=%.5g", trait, factor))
                end
            end
        end
        if #parts > 0 then
            Log:debug("RLCurveScale: %s %s", tostring(subType.name), table.concat(parts, " "))
        end
    end
    Log:info("RLCurveScale: %d curve(s) scaled from breedTraits.xml", count)
    return count
end
