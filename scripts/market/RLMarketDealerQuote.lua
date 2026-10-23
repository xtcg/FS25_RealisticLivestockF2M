-- Pure U31/U32 composition. All economic parameters are injected and scoped;
-- nothing registers providers, changes prices, enables channels or reads orders.
RLMarketDealerQuote={}
local Q=RLMarketDealerQuote
local D=RLMarketData
local objectives={"COMMODITY","DAIRY","TERMINAL","MATERNAL"}
local revisions={"classRevision","traitMappingRevision","marketEpoch","configRevision","formulaVersion","priceRevision"}
local function copy(v)return assert(D.copy(v))end
local function fp(v)return assert(D.fingerprint(v))end
local function nonnegative(v)return RLMarketMoney.finite(v) and v>=0 end
local function text(v)return type(v)=="string" and v:match("%S")~=nil end
local function fields(v,allowed)
    if type(v)~="table" then return false end
    for key in pairs(v)do if not allowed[key] then return false end end
    return true
end
function Q.scope(snapshot,context)
    local scope={identityKey=snapshot.identityKey,stateRevision=snapshot.stateRevision,
        referenceRevision=context.referenceRevision,difficultyMultiplier=context.difficultyMultiplier,
        calendarMonth=context.calendarMonth,absoluteMonths=context.absoluteMonths}
    for _,key in ipairs(revisions)do scope[key]=context[key]end
    return D.fingerprint(scope)
end
local policyFields={currencyBasis=true,scopeFingerprint=true,publishedOrderInformDealerBid=true,
    retailServiceFactor=true,retailFixedFee=true,minSpreadAbs=true,minSpreadRate=true,
    commodityTradeCost=true,commodityProfit=true,liquidation=true,fees=true,bonuses=true,quoteTTLms=true}
local routeFields={currencyBasis=true,scopeFingerprint=true,holdingMonths=true,monthlySaleProbability=true,
    season=true,holdingCost=true,tradeCost=true,profit=true,expectedNegotiationFactor=true}
local function policyValid(p,scope)
    if not fields(p,policyFields) or p.currencyBasis~="HARD" or p.scopeFingerprint~=scope then return false,"DEALER_POLICY_SCOPE_REQUIRED" end
    if p.publishedOrderInformDealerBid~=false then return false,"PUBLIC_ORDER_BID_FORBIDDEN" end
    for _,key in ipairs({"retailServiceFactor","retailFixedFee","minSpreadAbs","minSpreadRate","commodityTradeCost","commodityProfit"})do
        if not nonnegative(p[key]) then return false,"INVALID_DEALER_POLICY_"..key end
    end
    if p.retailServiceFactor<=0 or p.minSpreadRate>1 or not nonnegative(p.quoteTTLms) or p.quoteTTLms<=0 or p.quoteTTLms>60000 then return false,"INVALID_DEALER_POLICY_RANGE" end
    if not fields(p.liquidation,{currencyBasis=true,net=true,basis=true}) or p.liquidation.currencyBasis~="HARD"
        or not nonnegative(p.liquidation.net) or p.liquidation.basis~="NET_RECOVERY_AFTER_PROCESSING_BEFORE_LISTED_TRADE_COSTS" then return false,"LIQUIDATION_BASIS_REQUIRED" end
    if not fields(p.fees,{ASK=true,BID=true}) or not fields(p.bonuses,{ASK=true,BID=true}) then return false,"DEALER_LINE_ITEMS_REQUIRED" end
    return true
end
local structural={UNSUPPORTED=true,UNSUPPORTED_BREEDING_ROLE=true,UNSUPPORTED_OBJECTIVE=true,NO_DAIRY_CAPABILITY=true,
    PIG_OBJECTIVE_UNSUPPORTED=true,SHEEP_OBJECTIVE_UNSUPPORTED=true,SHEEP_DAIRY_PROVIDER_UNSUPPORTED=true,
    CASTRATED=true,PAST_BREEDING_LIFE=true,INFERTILE=true}
function Q.new(deps)
    if type(deps)~="table" or type(deps.registry)~="table" or type(deps.registry.evaluate)~="function" then return nil,"VALUE_REGISTRY_REQUIRED" end
    for _,key in ipairs({"policy","routePolicy","nowMs"})do if type(deps[key])~="function" then return nil,"MISSING_DEALER_QUOTE_"..key end end
    local money=deps.moneyPolicy or assert(RLMarketMoney.new())
    if type(money)~="table" or type(money.breakdown)~="function" or type(money.quantize)~="function" then return nil,"MONEY_POLICY_REQUIRED" end
    local api,busy,lastTime={},false,nil
    local function quote(side,snapshot,context)
        if side~="ASK" and side~="BID" then return nil,"INVALID_SIDE" end
        local s,c=copy(snapshot),copy(context)
        local valid,reason=RLMarketSchema.validateSnapshot(s);if not valid then return nil,reason end
        valid,reason=RLMarketSchema.validateQuoteContext(c);if not valid then return nil,reason end
        if c.channel~=(side=="ASK" and "DEALER_BUY" or "DEALER_SELL") then return nil,"CHANNEL_MISMATCH" end
        if s.classRevision~=c.classRevision or s.traitMappingRevision~=c.traitMappingRevision then return nil,"SNAPSHOT_VERSION_MISMATCH" end
        if s.traitCapabilities.tradeEligibility~=true or type(s.eligibility)~="table" or type(s.eligibility.tradeAllowed)~="boolean" then return nil,"DEALER_TRADE_ELIGIBILITY_UNAVAILABLE" end
        if not s.eligibility.tradeAllowed then return nil,"DEALER_TRADE_FORBIDDEN" end
        if not text(c.referenceRevision) or type(c.referenceInputs)~="table" or c.referenceInputs.currencyBasis~="HARD" then return nil,"REFERENCE_BASIS_REQUIRED" end
        local scope=assert(Q.scope(s,c))
        local p=copy(deps.policy(copy(s),copy(c)))
        valid,reason=policyValid(p,scope);if not valid then return nil,reason end
        local values,diagnostics,routes={}, {}, {}
        local missingBasis=false
        for _,objective in ipairs(objectives)do
            local ctx=copy(c);ctx.breedingObjective=objective~="COMMODITY" and objective or nil
            local legal=objective=="COMMODITY"
            if not legal and s.castrated~=true and not (s.genes and s.genes.fertility==0) then
                for _,role in ipairs(s.supportedBreedingRoles)do if role==objective then legal=true end end
            end
            local value,why
            if legal then value,why=deps.registry:evaluate(copy(s),ctx)
            else why="UNSUPPORTED_BREEDING_ROLE" end
            if value==nil then
                diagnostics[#diagnostics+1]={purpose=objective,status="UNSUPPORTED",reason=why or "VALUE_UNAVAILABLE"}
                if objective=="COMMODITY" or not structural[why] then missingBasis=true end
            else
                value=copy(value);values[objective]=value
                if objective~="COMMODITY" then
                    local route=value.breeding.byObjective[objective]
                    if value.capabilities.production~=true or type(route)~="table" or value.productionReference~=route.referenceValue then return nil,"PRODUCTION_REFERENCE_MISMATCH" end
                    if not route.eligible then diagnostics[#diagnostics+1]={purpose=objective,status="INELIGIBLE",reasons=copy(route.reasons)}
                    else routes[#routes+1]={purpose=objective,referenceValue=route.referenceValue,value=value}end
                end
            end
        end
        if missingBasis or values.COMMODITY==nil or values.COMMODITY.capabilities.commodity~=true then return nil,"DEALER_REFERENCE_UNAVAILABLE",{diagnostics=diagnostics,values=values} end
        local retailBase,retailPurpose=values.COMMODITY.commodityValue,"COMMODITY"
        for _,route in ipairs(routes)do if route.referenceValue>retailBase then retailBase,retailPurpose=route.referenceValue,route.purpose end end
        local askHard=retailBase*p.retailServiceFactor+p.retailFixedFee
        local immediate=p.liquidation.net-p.commodityTradeCost-p.commodityProfit
        if not nonnegative(askHard) or not RLMarketMoney.finite(immediate) then return nil,"DEALER_VALUE_OVERFLOW" end
        local rawBid=math.max(0,immediate)
        local selected="COMMODITY"
        local paths={{purpose="COMMODITY",amountHard=rawBid,liquidation=copy(p.liquidation),tradeCostHard=p.commodityTradeCost,profitHard=p.commodityProfit}}
        for _,route in ipairs(routes)do
            local option=copy(deps.routePolicy(route.purpose,copy(s),copy(c),copy(route.value)))
            if not fields(option,routeFields) or option.currencyBasis~="HARD" or option.scopeFingerprint~=scope then return nil,"ROUTE_POLICY_SCOPE_REQUIRED" end
            for _,key in ipairs({"tradeCost","profit","expectedNegotiationFactor","monthlySaleProbability"})do
                if not nonnegative(option[key]) then return nil,"INVALID_ROUTE_POLICY_"..key end
            end
            if option.expectedNegotiationFactor>1 or option.monthlySaleProbability>1 then return nil,"INVALID_ROUTE_POLICY_RANGE" end
            if type(option.season)~="table" then return nil,"INVALID_SEASON" end
            local seasonCount=0
            for month in pairs(option.season)do
                if type(month)~="number" or month%1~=0 or month<1 or month>12 then return nil,"INVALID_SEASON" end
                seasonCount=seasonCount+1
            end
            if seasonCount~=12 then return nil,"INVALID_SEASON" end
            if not fields(option.holdingCost,{feed=true,care=true,risk=true,finance=true}) then return nil,"HOLDING_COST_REQUIRED" end
            local holding,invalid=RLDealerPricePolicy.holdingCost(option.holdingCost);if holding==nil then return nil,invalid end
            -- A is derived from the same all-use retail base as ASK (7.3).
            -- Production references already contain own/hereditary deltas.
            local resale=retailBase*option.expectedNegotiationFactor
            local waiting,why=RLMarketMath.seasonal(resale,p.liquidation.net,option.monthlySaleProbability,
                option.holdingMonths,holding.total,c.calendarMonth,option.season)
            if waiting==nil then return nil,why end
            local uncapped=waiting.expectedRevenue-waiting.expectedHoldingCost-option.tradeCost-option.profit
            if not RLMarketMoney.finite(uncapped) then return nil,"DEALER_VALUE_OVERFLOW" end
            local amount=math.max(0,uncapped)
            paths[#paths+1]={purpose=route.purpose,amountHard=amount,referenceValueHard=route.referenceValue,
                resaleHard=resale,waiting=waiting,policy=option,holdingCost=holding}
            if amount>rawBid then rawBid,selected=amount,route.purpose end
        end
        -- Convert each actual amount once; perform the spread check against the
        -- final quantized bodies as well as the actual fee/bonus cash totals.
        local askCurrent=RLMarketMoney.convert(askHard,"HARD","CURRENT",c.difficultyMultiplier)
        local bidCurrent=RLMarketMoney.convert(rawBid,"HARD","CURRENT",c.difficultyMultiplier)
        local absCurrent=RLMarketMoney.convert(p.minSpreadAbs,"HARD","CURRENT",c.difficultyMultiplier)
        if askCurrent==nil or bidCurrent==nil or absCurrent==nil then return nil,"MONEY_OVERFLOW" end
        local function lines(input)
            if type(input)~="table" then return nil end
            local n=0;for k in pairs(input)do if type(k)~="number" or k%1~=0 or k<1 or k>#input then return nil end;n=n+1 end
            if n~=#input then return nil end
            local result={}
            for _,item in ipairs(input)do
                if not fields(item,{id=true,amount=true}) or not text(item.id) or not nonnegative(item.amount) then return nil end
                local amount=RLMarketMoney.convert(item.amount,"HARD","CURRENT",c.difficultyMultiplier)
                if amount==nil then return nil end
                result[#result+1]={id=item.id,amount=amount}
            end
            return result
        end
        local fAsk,fBid,bAsk,bBid=lines(p.fees.ASK),lines(p.fees.BID),lines(p.bonuses.ASK),lines(p.bonuses.BID)
        if not fAsk or not fBid or not bAsk or not bBid then return nil,"INVALID_DEALER_LINE_ITEMS" end
        local ask,invalid=money:breakdown(askCurrent,fAsk,bAsk,"OUT");if ask==nil then return nil,invalid end
        local gap=math.max(absCurrent,ask.bodyAmount*p.minSpreadRate)
        local cap=math.max(0,ask.bodyAmount-gap)
        local bidBody=money:quantize(math.min(bidCurrent,cap),"DOWN")
        if bidBody==nil then return nil,"MONEY_OVERFLOW" end
        local bid;bid,invalid=money:breakdown(bidBody,fBid,bBid,"IN");if bid==nil then return nil,invalid end
        if not nonnegative(gap) or bid.bodyAmount>cap then return nil,"FINAL_BODY_SPREAD_VIOLATION" end
        local cashCap=math.max(0,-ask.netToPlayer-math.max(absCurrent,(-ask.netToPlayer)*p.minSpreadRate))
        if bid.bodyAmount>0 and (not nonnegative(cashCap) or bid.netToPlayer>cashCap) then return nil,"FINAL_SETTLEMENT_SPREAD_VIOLATION" end
        local time=deps.nowMs()
        if not nonnegative(time) or (lastTime~=nil and time<lastTime) or not nonnegative(time+p.quoteTTLms) then return nil,"INVALID_DEALER_QUOTE_CLOCK" end
        lastTime=time
        local selectedMoney=side=="ASK" and ask or bid
        local rejection=selectedMoney.bodyAmount<=0 or (side=="BID" and selectedMoney.netToPlayer<=0)
        local reasons=copy(diagnostics)
        if bidCurrent>cap then reasons[#reasons+1]={code="SPREAD_CAP_APPLIED"}end
        if rejection then reasons[#reasons+1]={code="NONPOSITIVE_DEALER_QUOTE"}end
        local result={schemaVersion=1,status=rejection and "REJECTED" or "OK",channel=c.channel,
            settlementDirection=side=="ASK" and "OUT" or "IN",identityKey=s.identityKey,stateRevision=s.stateRevision,
            expiresAt=time+p.quoteTTLms,candidatePaths=paths,reasons=reasons,
            eligibilityFingerprint=fp({snapshot=s,diagnostics=diagnostics}),
            settlementFingerprint=fp({scope=scope,policy=p,paths=paths,ask=ask,bid=bid}),
            references=values,retailBaseHard=retailBase,scopeFingerprint=scope,
            pair={ask=ask,bid=bid,spreadCapCurrent=cap,rawBidHard=rawBid,publicOrdersUsed=false}}
        for _,key in ipairs(revisions)do result[key]=c[key]end
        if not rejection then
            result.selectedUse=side=="ASK" and retailPurpose or selected
            result.bodyAmount,result.netToPlayer=selectedMoney.bodyAmount,selectedMoney.netToPlayer
            result.fees,result.bonuses=selectedMoney.totalFees,selectedMoney.totalBonuses
            result.money=copy(selectedMoney)
        end
        local accepted,why=RLMarketSchema.validateQuote(result,{side=side,identityKey=s.identityKey,stateRevision=s.stateRevision})
        if not accepted then return nil,why end
        return result
    end
    function api:quote(...)
        if busy then return nil,"RECURSIVE_DEALER_QUOTE" end
        busy=true
        local ok,result,reason,diagnostics=pcall(quote,...)
        busy=false
        if not ok then return nil,"DEALER_QUOTE_ERROR" end
        return result,reason,diagnostics
    end
    return api
end
