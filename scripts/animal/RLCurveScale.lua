--[[
    RLCurveScale.lua
    Scales whole age curves of a subtype once, after every map bridge and animal pack has loaded,
    by factors from xml/breedTraits.xml (subType > breed > animalType, default 1):

        woolScale    output.pallets curve (wool; set only on wool producers)
        waterScale   input.water
        strawScale   input.straw
        manureScale  output.manure
        priceScale   buyPrice and sellPrice, the whole age curve (solved for a ram lamb's live price at its
                     real finishing age; breeding rams and newborn ram lambs move by the same factor, by design)

    The engine reads curve keys as integers (AnimalSystem:loadAnimCurve, getInt), so a fleece of
    half a liter a month cannot be written into animals.xml; scaling the loaded keyframes keeps
    fractions and needs no edit to a pack's own files (FS25_SheepBreedsRLRM belongs to its author).
    Each curve object is scaled once (a flag on the curve), so a second call or two subtypes sharing
    one curve never scale it twice; a shared curve asked for a different factor logs a warning.
    A wool curve no breedTraits entry configures keeps the old 12 C cold gate (Animal:updateOutput).
]]

RLCurveScale = {}

local Log = RmLogging.getLogger("RLRM")

--- Scaled curves in order: { trait, function(subType) returning the curve it scales, or nil }.
--- Both price curves follow priceScale.
RLCurveScale.CURVES = {
    { "woolScale", function(subType)
        local pallets = subType.output ~= nil and subType.output.pallets or nil
        return pallets ~= nil and pallets.curve or nil
    end },
    { "waterScale", function(subType) return subType.input ~= nil and subType.input.water or nil end },
    { "strawScale", function(subType) return subType.input ~= nil and subType.input.straw or nil end },
    { "manureScale", function(subType) return subType.output ~= nil and subType.output.manure or nil end },
    { "priceScale", function(subType) return subType.buyPrice end },
    { "priceScale", function(subType) return subType.sellPrice end },
}


--- Multiply every keyframe value of a curve by `factor`, once per curve. The factor is kept on the
--- curve (`rlCurveScaled`), also for a factor of 1, so a curve carries whether breedTraits configured it.
--- @return boolean scaled
function RLCurveScale.scaleCurve(curve, factor)
    if curve == nil or curve.keyframes == nil or curve.rlCurveScaled then return false end
    if factor ~= 1 then
        for _, keyframe in ipairs(curve.keyframes) do
            if type(keyframe[1]) == "number" then keyframe[1] = keyframe[1] * factor end
        end
    end
    curve.rlCurveScaled = factor
    return true
end


--- Whether a curve was configured by breedTraits (any factor, 1 included).
--- @param curve table|nil
--- @return boolean
function RLCurveScale.isConfigured(curve)
    return curve ~= nil and curve.rlCurveScaled ~= nil
end


--- Apply the configured factors to every subtype of the animal system.
--- @param animalSystem table
--- @return number count Curves scaled
function RLCurveScale.apply(animalSystem)
    if animalSystem == nil or animalSystem.subTypes == nil then return 0 end
    local count = 0
    for _, subType in ipairs(animalSystem.subTypes) do
        local parts = {}
        for _, entry in ipairs(RLCurveScale.CURVES) do
            local trait, getCurve = entry[1], entry[2]
            local factor = RLBreedTraits.resolve(RLBreedTraits.getConfig().layers, subType, trait, nil)
            local curve = type(factor) == "number" and factor >= 0 and getCurve(subType) or nil
            if curve ~= nil then
                if RLCurveScale.scaleCurve(curve, factor) then
                    count = count + 1
                    table.insert(parts, string.format("%s=%.5g", trait, factor))
                elseif curve.rlCurveScaled ~= factor then
                    -- Two subtypes share one curve object: the first factor stays, so this one is lost.
                    Log:warning("RLCurveScale: %s %s=%.5g not applied, its curve is shared and already scaled by %.5g",
                        tostring(subType.name), trait, factor, curve.rlCurveScaled)
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
