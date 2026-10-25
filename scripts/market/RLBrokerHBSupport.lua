-- Reviewed HB 1.5 Beta1 companions. These extend intake, production, bedding,
-- navigation or presentation; live pen/trailer animals still use native writers.
-- Admission binds both the installed mod version and its real module table.
RLBrokerHBSupport = {}
local H=RLBrokerHBSupport
local companions={
    husbandryWoodShavings="PlaceableHusbandryWoodShavings",
    husbandryFoodSpillage="PlaceableHusbandryFoodSpillage",
    husbandryNavMeshSwitcher="PlaceableHusbandryNavMeshSwitcher",
    fullPalletHusbandryPallets="FullPalletHusbandryPallets",
    convertFillTypeToAnimalsFromStorage="ConvertFillTypeToAnimalsFromStorage",
    contractProductionAnimalInput="PlaceableContractProductionAnimalInput",
    extendedProductionAnimalOutput="PlaceableExtendedProductionAnimalOutput",
    extendedProductionAnimalUnits="PlaceableExtendedProductionAnimalUnits",
    livestockTrailerSpecial="LivestockTrailerSpecial",
    lsfmHorseTowPhysics="LSFM_HorseTowPhysics"
}
function H.trustedCompanion(name,module)
    local environment,short=name:match("^([^%.]+)%.([^%.]+)$")
    if environment~="FS25_HofBergmann" or not companions[short] then return false end
    local mod=g_modManager and g_modManager:getModByName(environment)
    local namespace=_G[environment]
    return mod~=nil and mod.version=="1.5.0.0 Beta1" and type(namespace)=="table"
        and type(module)=="table" and namespace[companions[short]]==module
end
