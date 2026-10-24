-- Price entry-point binding only. No wallet, sale queue, credentials or animal
-- update occurs here. Unsupported/unreleased scopes retain the legacy route;
-- errors inside an admitted market scope never turn into a different price.
RLMarketEnginePrice = {}
local E = RLMarketEnginePrice
local current
local revisions = {"classRevision", "traitMappingRevision", "marketEpoch", "configRevision", "formulaVersion", "priceRevision"}
local function copy(v) return assert(RLMarketData.copy(v)) end
local function finite(v) return RLMarketMoney.finite(v) end
local function call(fn, ...) local ok,a,b = pcall(fn,...); if not ok then return nil,"ENGINE_PRICE_CALLBACK_ERROR" end; return a,b end
function E.new(deps)
    if type(deps) ~= "table" then return nil,"ENGINE_PRICE_DEPENDENCIES_REQUIRED" end
    for _,key in ipairs({"mode","capture","ready","marketQuote","nowMs"}) do
        if type(deps[key]) ~= "function" then return nil,"MISSING_ENGINE_PRICE_"..key end
    end
    local api,busy,lastTime = {},false,nil
    function api:price(side,animal,legacy)
        if busy then return nil,"RECURSIVE_ENGINE_PRICE" end
        if (side~="BID" and side~="ASK") or type(legacy)~="function" then return nil,"INVALID_ENGINE_PRICE_REQUEST" end
        busy=true
        local ok,amount,detail=pcall(function()
            local mode=deps.mode()
            if mode~="legacy" and mode~="shadow" and mode~="market" then return nil,"INVALID_ENGINE_PRICE_MODE" end
            local legacyAmount
            local function old(reason)
                if legacyAmount==nil then
                    legacyAmount=legacy()
                    if not finite(legacyAmount) or legacyAmount<0 then return nil,"INVALID_LEGACY_PRICE" end
                end
                return legacyAmount,{mode="legacy",reason=reason}
            end
            if mode=="legacy" then return old() end
            if mode=="shadow" then local value,why=old();if value==nil then return nil,why end end
            local snapshot,context=call(deps.capture,side,animal)
            local s,c=RLMarketData.copy(snapshot),RLMarketData.copy(context)
            local valid,reason=RLMarketSchema.validateSnapshot(s)
            if valid then valid,reason=RLMarketSchema.validateQuoteContext(c) end
            if valid and (c.channel~=(side=="ASK" and "DEALER_BUY" or "DEALER_SELL")
                or s.classRevision~=c.classRevision or s.traitMappingRevision~=c.traitMappingRevision) then valid,reason=false,"ENGINE_PRICE_SCOPE_MISMATCH" end
            local admitted=valid and call(deps.ready,copy(s),copy(c))==true
            local quote,failure
            if admitted then
                quote,failure=call(deps.marketQuote,side,copy(s),copy(c))
                quote=RLMarketData.copy(quote)
                if quote then
                    local accepted,invalid=RLMarketSchema.validateQuote(quote,{side=side,identityKey=s.identityKey,stateRevision=s.stateRevision})
                    if not accepted then quote,failure=nil,invalid end
                end
                if quote then
                    for _,key in ipairs(revisions) do
                        if quote[key]~=c[key] then quote,failure=nil,"ENGINE_PRICE_VERSION_MISMATCH";break end
                    end
                end
                if quote and quote.scopeFingerprint~=RLMarketDealerQuote.scope(s,c) then quote,failure=nil,"ENGINE_PRICE_BASIS_MISMATCH" end
                if quote then
                    if quote.channel~=c.channel or quote.status~="OK" then quote,failure=nil,"ENGINE_PRICE_NOT_TRADABLE"
                    elseif type(quote.money)~="table" or quote.transportIncluded~=false then quote,failure=nil,"ENGINE_PRICE_MONEY_REQUIRED"
                    else
                        local m=quote.money
                        local expected=assert(RLMarketMoney.new()):breakdown(m.bodyAmount,m.fees,m.bonuses,quote.settlementDirection)
                        if expected==nil or m.currencyBasis~="CURRENT" or m.settlementDirection~=quote.settlementDirection
                            or expected.netToPlayer~=m.netToPlayer or expected.totalFees~=m.totalFees or expected.totalBonuses~=m.totalBonuses
                            or quote.bodyAmount~=m.bodyAmount or quote.netToPlayer~=m.netToPlayer
                            or quote.fees~=m.totalFees or quote.bonuses~=m.totalBonuses then quote,failure=nil,"ENGINE_PRICE_MONEY_MISMATCH" end
                    end
                end
                if quote and (call(deps.mode)~=mode or call(deps.ready,copy(s),copy(c))~=true) then quote,failure=nil,"MARKET_PRICE_ADMISSION_CHANGED" end
                local time=call(deps.nowMs)
                if not finite(time) or time<0 or (lastTime~=nil and time<lastTime) then quote,failure=nil,"INVALID_ENGINE_PRICE_CLOCK"
                else
                    lastTime=time
                    if quote and time>=quote.expiresAt then quote,failure=nil,"ENGINE_PRICE_EXPIRED" end
                end
            else failure=reason or "MARKET_SCOPE_NOT_ADMITTED" end
            if mode=="shadow" then
                local report={side=side,legacyAmount=legacyAmount,candidate=quote,reason=failure,
                    identityKey=type(s)=="table" and s.identityKey or nil,stateRevision=type(s)=="table" and s.stateRevision or nil}
                if type(deps.observe)=="function" then pcall(deps.observe,copy(report)) end
                return legacyAmount,{mode="shadow",report=report}
            end
            if not admitted then return old(failure) end
            if not quote then return nil,failure or "MARKET_PRICE_UNAVAILABLE" end
            -- The old numeric consumer owns only its external transportation
            -- leg. All non-transport quote fees/bonuses are included once here.
            local value=side=="ASK" and -quote.money.netToPlayer or quote.money.netToPlayer
            if not finite(value) or value<=0 then return nil,"NONPOSITIVE_ENGINE_PRICE" end
            return value,{mode="market",quote=quote}
        end)
        busy=false
        if not ok then return nil,"ENGINE_PRICE_ERROR" end
        return amount,detail
    end
    return api
end

-- Only an assembled runtime can bind game consumers. The independent runtime
-- admission gate remains mandatory even if a configuration requests market.
function E.bind(deps)
    if type(deps)~="table" or RLMarketRuntime==nil then return nil,"MARKET_RUNTIME_REQUIRED" end
    local wrapped={}
    for k,v in pairs(deps) do wrapped[k]=v end
    local ready=deps.ready
    if type(ready)~="function" then return nil,"MISSING_ENGINE_PRICE_ready" end
    wrapped.ready=function(s,c)
        return RLMarketRuntime.marketPricingReady({snapshot=copy(s),context=copy(c)})==true and ready(copy(s),copy(c))==true
    end
    local service,why=E.new(wrapped)
    if not service then return nil,why end
    current=service;return service
end
function E.clear() current=nil end
function E.reference(side,animal,legacy)
    if current then return current:price(side,animal,legacy) end
    return legacy(),{mode="legacy"}
end
function E.salePrice(animal)
    return E.reference("BID",animal,function()
        if type(animal.getLegacySellPrice)=="function" then return animal:getLegacySellPrice() end
        return animal:getSellPrice()
    end)
end
function E.price(side,animal,legacy)
    if current then
        local amount,detail=E.reference(side,animal,legacy)
        if amount==nil then return nil,detail end
        return amount
    end
    return legacy()
end
