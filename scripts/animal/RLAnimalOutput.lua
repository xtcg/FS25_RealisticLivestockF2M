-- Read-only output access shared by live production, feed forecasts, Dealer
-- replay and economic snapshots. Native outputs wrap AnimCurve in .curve;
-- older fixtures/maps may expose the curve directly. No cached engine objects.
RLAnimalOutput = {}
local O=RLAnimalOutput
function O.curve(entry)
    local curve=type(entry)=="table" and (entry.curve or entry) or nil
    if type(curve)=="table" and type(curve.get)=="function" then return curve end
end
function O.milkCurve(subType)
    local output=subType and subType.output
    if type(output)~="table" then return nil end
    local milk=output.milk
    if milk~=nil and (Animal==nil or Animal.isSemenFillType==nil or not Animal.isSemenFillType(milk.fillType)) then
        local curve=O.curve(milk)
        if curve then return curve,milk end
    end
    local pallets=output.pallets
    if pallets~=nil and Animal~=nil and Animal.isLactationPalletFillType~=nil and Animal.isLactationPalletFillType(pallets.fillType) then
        return O.curve(pallets),pallets
    end
end
