loadMod("scripts/market/RLMarketMoney.lua")
local M = RLMarketMoney
local policy = assert(M.new())
check("money: preserves engine double precision", policy:quantize(1.123456789) == 1.123456789)
check("money: explicit basis converted once", M.convert(180, "CURRENT", "HARD", 1.8) == 100
    and M.convert(100, "HARD", "CURRENT", 1.8) == 180 and M.convert(180, "CURRENT", "CURRENT", 1.8) == 180)
check("money: invalid and overflow rejected", M.convert(1/0, "HARD", "CURRENT", 3) == nil
    and M.convert(1e308, "HARD", "CURRENT", 3) == nil and M.convert(2, "UNKNOWN", "HARD", 1) == nil)
check("money: candidate cent requires payment roundtrip proof", M.new({ unit = 0.01 }) == nil
    and M.new({ unit = 0.01, verifyRoundTrip = function() return false end }) == nil)
check("money: broken unit verifier fails closed",M.new({unit=0.01,verifyRoundTrip=function() error("adapter unavailable") end})==nil)
local cents = assert(M.new({ unit = 0.01, verifyRoundTrip = function(unit) return unit == 0.01 end }))
check("money: half-unit rounding and conservative cap", near(cents:quantize(0.125), 0.13, 1e-12)
    and near(cents:quantize(-0.125), -0.13, 1e-12) and near(cents:quantize(0.129, "DOWN"), 0.12, 1e-12))
check("money: decimal grid values do not lose a cent", near(cents:quantize(0.29,"DOWN"),0.29,1e-12)
    and near(cents:quantize(1.15,"DOWN"),1.15,1e-12) and near(cents:quantize(-1.15,"DOWN"),-1.15,1e-12))
check("money: boundary neighbours retain direction", near(cents:quantize(0.29-1e-9,"DOWN"),0.28,1e-12)
    and near(cents:quantize(0.29+1e-9,"UP"),0.30,1e-12))
local large = (1e15+0.75)*0.01
check("money: large amount tolerance never absorbs fractional units",cents:quantize(large,"DOWN")<=large
    and cents:quantize(large,"UP")>=large)
local receipt = assert(policy:breakdown(100.125, { { id = "pickup", amount = 12.5 }, { id = "commission", amount = 7.25 } },
    { { id = "quality", amount = 2 } }, "IN"))
check("money: display items are actual settlement items", receipt.netToPlayer == 82.375
    and receipt.totalFees == 19.75 and receipt.totalBonuses == 2 and receipt.fees[1].amount == 12.5)
local buy = assert(policy:breakdown(100, { { id = "transport", amount = 12 } }, {}, "OUT"))
check("money: buy amount debits player", buy.netToPlayer == -112)
local pair = assert(cents:transportPair(100.129, 10.125))
check("money: transport net generated from common pre-transport amount", near(pair.selfDelivery, 100.12, 1e-12)
    and near(pair.pickupFee, 10.13, 1e-12) and pair.pickup == pair.selfDelivery - pair.pickupFee)
pair = assert(policy:transportPair(5, 10))
check("money: nonpositive pickup only disables pickup", pair.selfDeliveryAvailable and not pair.pickupAvailable)
check("money: malformed lines rejected", policy:breakdown(100, { [2] = { id = "fee", amount = 1 } }, {}, "IN") == nil
    and policy:breakdown(100, { { id = "fee", amount = 0/0 } }, {}, "IN") == nil)
