--[[
    Livestock prices follow the economic difficulty.

    The game multiplies every fill type's selling price by the difficulty (EconomyManager.PRICE_MULTIPLIER:
    EASY x3, NORMAL x1.8, HARD x1), so meat, milk, eggs and wool already move with it. The mod's own
    livestock prices did not: live animals (and the dealer's buy price made from them), semen and the
    contract slaughter fees stayed at one level, which is the calibration level on HARD. They now take the
    same multiplier, so the livestock economy is the calibrated one on HARD and every price in it - animal,
    meat, milk, fee - is x1.8 on NORMAL and x3 on EASY, with the same margins (slaughtering by contract
    still earns about 12% over the year).
]]

RLLivestockPrices = {}

local Log = RmLogging.getLogger("RLRM")


--- The game's difficulty price multiplier (1 on HARD, the calibration level; 1.8 NORMAL; 3 EASY).
--- @return number
function RLLivestockPrices.getMultiplier()
    if EconomyManager == nil or EconomyManager.getPriceMultiplier == nil or g_currentMission == nil
        or g_currentMission.missionInfo == nil then
        return 1
    end
    local multiplier = EconomyManager.getPriceMultiplier()
    return type(multiplier) == "number" and multiplier > 0 and multiplier or 1
end


--- Re-apply the contract slaughterhouses' fees after the difficulty changes in game.
function RLLivestockPrices.onDifficultyChanged()
    local system = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    local patched = 0
    for _, placeable in ipairs(system ~= nil and system.placeables or {}) do
        patched = patched + (AnimalMoveEvent.alignContractRecipes(placeable) or 0)
    end
    Log:info("RLLivestockPrices: difficulty price multiplier x%.2f, %d contract recipe fee(s) updated",
        RLLivestockPrices.getMultiplier(), patched)
end


if FSBaseMission ~= nil and FSBaseMission.setEconomicDifficulty ~= nil then
    FSBaseMission.setEconomicDifficulty = Utils.appendedFunction(FSBaseMission.setEconomicDifficulty, function()
        RLLivestockPrices.onDifficultyChanged()
    end)
end
