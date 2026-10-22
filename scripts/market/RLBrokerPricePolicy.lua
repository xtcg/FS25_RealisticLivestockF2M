-- Single-animal value and caps. Financial input is HARD except actual provenance
-- spend/cap and the engine transport fee, which are explicitly CURRENT currency.
-- No order completion reward, no slaughter fee deducted from a live sale.
RLBrokerPricePolicy={}
local P=RLBrokerPricePolicy
local function nonnegative(v) return RLMarketMoney.finite(v) and v>=0 end
function P.quote(raw,policy)
    local input,reason=RLMarketData.copy(raw)
    if input==nil then return nil,reason end
    if type(input)~="table" then return nil,"INVALID_BROKER_VALUE" end
    for _,key in ipairs({"buyerReference","bonus","commissionRate","ask","minSpreadAbs","minSpreadRate",
        "difficultyMultiplier","pickupFee"}) do if not nonnegative(input[key]) then return nil,"INVALID_BROKER_"..key end end
    if input.commissionRate>1 or input.minSpreadRate>1 or input.difficultyMultiplier<=0 or type(input.finished)~="boolean" then return nil,"INVALID_BROKER_POLICY" end
    if policy==nil then policy=assert(RLMarketMoney.new()) end
    local multiplier=input.difficultyMultiplier
    local body=RLMarketMoney.convert(input.buyerReference,"HARD","CURRENT",multiplier)
    local bonus=RLMarketMoney.convert(input.bonus,"HARD","CURRENT",multiplier)
    local commission=RLMarketMoney.convert((input.buyerReference+input.bonus)*input.commissionRate,"HARD","CURRENT",multiplier)
    if body==nil or bonus==nil or commission==nil then return nil,"MONEY_OVERFLOW" end
    local retailCap=math.max(0,input.ask-math.max(input.minSpreadAbs,input.ask*input.minSpreadRate))*multiplier
    local cap,capSources=retailCap,{retail=retailCap}
    if input.finished then
        local slaughter=input.slaughter
        if type(slaughter)~="table" or slaughter.available~=true or not nonnegative(slaughter.net)
            or type(slaughter.basis)~="table" or slaughter.basis.moneyBasis~="HARD"
            or not nonnegative(input.finishedSpreadAbs) or not nonnegative(input.finishedSpreadRate)
            or input.finishedSpreadRate>1 then return nil,"FINISHED_SLAUGHTER_BASIS_REQUIRED" end
        local finishedCap=math.max(0,slaughter.net-math.max(input.finishedSpreadAbs,slaughter.net*input.finishedSpreadRate))*multiplier
        capSources.finished=finishedCap;cap=math.min(cap,finishedCap)
    end
    if input.sourceResult~=nil and type(input.sourceResult)~="table" then return nil,"INVALID_SOURCE_CAP" end
    local sourceVerified=input.sourceResult~=nil and input.sourceResult.verified==true
    if sourceVerified and input.sourceResult.limited==true then
        if not nonnegative(input.sourceResult.maximumBeforeTransport) then return nil,"INVALID_SOURCE_CAP" end
        capSources.source=input.sourceResult.maximumBeforeTransport
        cap=math.min(cap,capSources.source)
    elseif sourceVerified and input.sourceResult.limited~=false then return nil,"INVALID_SOURCE_CAP" end
    local baseline,why=policy:breakdown(body,{{id="commission",amount=commission}},{{id="qualityBonus",amount=bonus}},"IN")
    if baseline==nil then return nil,why end
    local maximum=policy:quantize(cap,"DOWN")
    if maximum==nil then return nil,"INVALID_BROKER_CAP" end
    local discount=policy:quantize(math.max(0,baseline.netToPlayer-maximum),"UP")
    if discount==nil then return nil,"INVALID_BROKER_CAP" end
    local fees={{id="commission",amount=baseline.fees[1].amount},{id="priceConstraint",amount=discount}}
    local selfDelivery=policy:breakdown(baseline.bodyAmount,fees,baseline.bonuses,"IN")
    if selfDelivery==nil then return nil,"INVALID_BROKER_BREAKDOWN" end
    local fee=policy:quantize(input.pickupFee)
    if fee==nil then return nil,"INVALID_TRANSPORT" end
    fees[#fees+1]={id="pickup",amount=fee}
    local pickup=policy:breakdown(baseline.bodyAmount,fees,baseline.bonuses,"IN")
    if pickup==nil then return nil,"INVALID_BROKER_BREAKDOWN" end
    if not RLMarketMoney.finite(pickup.netToPlayer) then return nil,"MONEY_OVERFLOW" end
    return {currencyBasis="CURRENT",selfDelivery=selfDelivery,pickup=pickup,pickupFee=fee,
        selfDeliveryAvailable=selfDelivery.netToPlayer>0,pickupAvailable=pickup.netToPlayer>0,
        preTransportCap=maximum,capSources=capSources,constraintDiscount=discount,
        sourceVerified=sourceVerified,settlementReady=sourceVerified,
        reason=not sourceVerified and "SOURCE_PROOF_REQUIRED" or nil}
end
