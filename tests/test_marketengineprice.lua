loadMod("tests/fixtures/market_production.lua")
for _,name in ipairs({"RLMarketMoney","RLMarketMath","RLDealerPricePolicy","RLMarketDealerQuote","RLMarketEnginePrice"}) do loadMod("scripts/market/"..name..".lua") end
loadMod("tests/breedingvalue_fixture.lua")
loadMod("scripts/gui/rlmenu/services/RLAnimalBuyService.lua")
local E,F,D=RLMarketEnginePrice,MarketProductionFixture,RLMarketData
local function cp(v)return assert(D.copy(v))end
local animal=bvAnimal("BULL_HOLSTEIN",18)
local old=animal:getLegacySellPrice()
local markupReads=0
RLDealerQualityResolver={getMarkup=function()markupReads=markupReads+1;return 1.3 end}
check("engine price: unbound actual Animal preserves old BID",animal:getSellPrice()==old)
check("engine price: unbound actual purchase uses old BID markup",RLAnimalBuyService.computeBuyPrice(animal)==old*1.3)
local registry=RLAnimalValueProvider.new();assert(RLMarketProviders.register(registry))
local s=F.snapshot("COW");s.traitCapabilities.tradeEligibility=true;s.eligibility={tradeAllowed=true}
local context=F.context(s,F.input())
local mode,ready,time,observed="market",true,1000,nil
local scopeQuote=assert(RLMarketDealerQuote.new({registry=registry,nowMs=function()return time end,
    policy=function(a,c)return {currencyBasis="HARD",scopeFingerprint=RLMarketDealerQuote.scope(a,c),publishedOrderInformDealerBid=false,
        retailServiceFactor=1.2,retailFixedFee=10,minSpreadAbs=10,minSpreadRate=.1,commodityTradeCost=5,commodityProfit=5,
        liquidation={currencyBasis="HARD",net=80,basis="NET_RECOVERY_AFTER_PROCESSING_BEFORE_LISTED_TRADE_COSTS"},
        fees={ASK={{id="purchase",amount=3}},BID={{id="sale",amount=2}}},bonuses={ASK={},BID={}},quoteTTLms=15000}end,
    routePolicy=function(_,a,c)return {currencyBasis="HARD",scopeFingerprint=RLMarketDealerQuote.scope(a,c),holdingMonths=1,monthlySaleProbability=1,
        season={1,1,1,1,1,1,1,1,1,1,1,1},holdingCost={feed=5,care=2,risk=2,finance=1},tradeCost=5,profit=5,expectedNegotiationFactor=.9}end}))
local deps={mode=function()return mode end,ready=function()return ready end,
    capture=function(side)
        local c=cp(context);c.channel=side=="ASK" and "DEALER_BUY" or "DEALER_SELL";return cp(s),c
    end,
    nowMs=function()return time end,marketQuote=function(side,a,c)return scopeQuote:quote(side,a,c)end,
    observe=function(report)observed=report end}
local service=assert(E.new(deps))
local legacyCalls=0
local function legacy()legacyCalls=legacyCalls+1;return 99 end
local bid=assert(service:price("BID",animal,legacy));local ask=assert(service:price("ASK",animal,legacy))
check("engine price: real provider pair includes nontransport fees exactly once",bid==185 and ask==289 and legacyCalls==0)
ready=false
local fallback,detail=service:price("ASK",animal,legacy)
check("engine price: unreleased scope retains explicit legacy",fallback==99 and detail.mode=="legacy" and detail.reason=="MARKET_SCOPE_NOT_ADMITTED")
ready=true;mode="shadow";legacyCalls=0
local shadow=assert(service:price("BID",animal,legacy))
check("engine price: shadow returns old cash once and reports new pair",shadow==99 and legacyCalls==1 and observed.candidate.netToPlayer==185)
local normalQuote=deps.marketQuote
deps.marketQuote=function()error("provider exploded")end
shadow=assert(service:price("ASK",animal,legacy))
check("engine price: shadow provider failure cannot change live price",shadow==99 and observed.candidate==nil and observed.reason=="ENGINE_PRICE_CALLBACK_ERROR")
deps.marketQuote=normalQuote
local normalClock=deps.nowMs;deps.nowMs=function()error("clock failed")end
check("engine price: shadow clock failure still returns legacy",service:price("ASK",animal,legacy)==99 and observed.reason=="INVALID_ENGINE_PRICE_CLOCK")
deps.nowMs=normalClock
local normalCapture=deps.capture;deps.capture=function()return 17,{}end
check("engine price: malformed scalar shadow snapshot preserves legacy",service:price("ASK",animal,legacy)==99 and observed.candidate==nil)
deps.capture=normalCapture
mode="market";deps.marketQuote=function()return nil,"BASIS_MISSING"end;legacyCalls=0
local no,why=service:price("BID",animal,legacy)
check("engine price: admitted market error cannot silently use legacy",no==nil and why=="BASIS_MISSING" and legacyCalls==0)
deps.marketQuote=function(side,a,c)local q=assert(normalQuote(side,a,c));q.priceRevision="old";return q end
no,why=service:price("ASK",animal,legacy)
check("engine price: quote must retain captured full version scope",no==nil and why=="ENGINE_PRICE_VERSION_MISMATCH")
for _,field in ipairs({"difficulty","reference","calendar","absolute","raw reference inputs"})do
    deps.marketQuote=function(side,a,c)
        local other=cp(c)
        if field=="difficulty"then other.difficultyMultiplier=2
        elseif field=="reference"then other.referenceRevision="other";other.referenceInputs.referenceRevision="other"
        elseif field=="calendar"then other.calendarMonth=2
        elseif field=="absolute"then other.absoluteMonths=9
        else other.referenceInputs.commodity.rearing.futureGross=1000 end
        return scopeQuote:quote(side,a,other)
    end
    no,why=service:price("ASK",animal,legacy)
    check("engine price: cached "..field.." basis cannot be substituted",no==nil and why=="ENGINE_PRICE_BASIS_MISMATCH")
end
deps.marketQuote=function(side,a,c)local q=assert(normalQuote(side,a,c));q.money.netToPlayer=q.money.netToPlayer+1;return q end
no,why=service:price("ASK",animal,legacy)
check("engine price: altered quote money arithmetic rejected",no==nil and why=="ENGINE_PRICE_MONEY_MISMATCH")
deps.marketQuote=function(side,a,c)local q=assert(normalQuote(side,a,c));q.transportIncluded=true;return q end
no,why=service:price("ASK",animal,legacy)
check("engine price: external transport leg cannot be included twice",no==nil and why=="ENGINE_PRICE_MONEY_REQUIRED")
deps.marketQuote=function(side,a,c)local q=assert(normalQuote(side,a,c));q.expiresAt=time;return q end
no,why=service:price("ASK",animal,legacy)
check("engine price: quote expiry checked after all provider callbacks",no==nil and why=="ENGINE_PRICE_EXPIRED")
deps.marketQuote=normalQuote
deps.marketQuote=function(side,a,c)local q=assert(normalQuote(side,a,c));ready=false;return q end
no,why=service:price("ASK",animal,legacy)
check("engine price: admission revoked during pricing cannot return new cash",no==nil and why=="MARKET_PRICE_ADMISSION_CHANGED")
ready=true;deps.marketQuote=normalQuote
local nested
deps.ready=function()local _,reason=service:price("ASK",animal,legacy);nested=reason;return true end
check("engine price: readiness callback cannot recurse",service:price("ASK",animal,legacy)==289 and nested=="RECURSIVE_ENGINE_PRICE")
deps.ready=function()return true end
-- Bind the actual Animal/BuyService entry points, with the production gate
-- represented explicitly by this sandbox runtime. No production gate is opened.
RLMarketRuntime={marketPricingReady=function()return false end}
assert(E.bind(deps))
check("engine price: binding cannot bypass independent runtime admission",animal:getSellPrice()==old and RLAnimalBuyService.computeBuyPrice(animal)==old*1.3)
RLMarketRuntime.marketPricingReady=function()return true end
assert(E.bind(deps))
check("engine price: actual ordinary sell and single purchase use independent BID/ASK",animal:getSellPrice()==185 and RLAnimalBuyService.computeBuyPrice(animal)==289 and animal:getLegacySellPrice()==old)
check("engine price: legacy numeric entry points return exactly one success value",select("#",animal:getSellPrice())==1 and select("#",RLAnimalBuyService.computeBuyPrice(animal))==1)
animal.getTranportationFee=function()return 12 end
local body,fee,total,count=RLAnimalBuyService.computeBulkTotal({animal,animal})
check("engine price: actual batch is sum of single ASK with separate once-per-head fees",body==578 and fee==24 and total==602 and count==2)
mode="legacy";markupReads=0
body,fee,total,count=RLAnimalBuyService.computeBulkTotal({animal,animal})
check("engine price: batch legacy numeric parity and one preset read retained",body==old*1.3*2 and fee==24 and total==body+fee and count==2 and markupReads==1)
mode="market";deps.marketQuote=function()return nil,"NOT_QUOTABLE"end;assert(E.bind(deps))
body,fee,total,count,why=RLAnimalBuyService.computeBulkTotal({animal})
check("engine price: batch with an unavailable animal yields no partial totals",body==nil and fee==nil and total==nil and count==0 and why=="NOT_QUOTABLE")
E.clear()
check("engine price: clearing runtime restores legacy without replacing methods",animal:getSellPrice()==old and RLAnimalBuyService.computeBuyPrice(animal)==old*1.3)
loadMod("scripts/disease/RLDiseaseCull.lua")
local forbidden={animalTypeIndex=AnimalType.COW,uniqueId="forced-cull",
    getSellPrice=function()error("live trade forbidden")end,getLegacySellPrice=function()return 1200 end}
check("engine price: forced culling retains explicit compensation basis without a live BID",RLDiseaseCull.salvageFor(forbidden)==1200*.33)
local badTransport={getSellPrice=function()return 10 end,getTranportationFee=function()return 0/0 end}
body,fee,total,count,why=RLAnimalBuyService.computeBulkTotal({badTransport})
check("engine price: invalid external transport cannot be hidden in a batch",body==nil and count==0 and why=="BUY_TRANSPORT_UNAVAILABLE")
badTransport.getSellPrice=function()return 1e308 end;badTransport.getTranportationFee=function()return 0 end
body,fee,total,count,why=RLAnimalBuyService.computeBulkTotal({badTransport,badTransport})
check("engine price: complete batch overflow cannot produce an infinite payable total",body==nil and count==0 and why=="BUY_TOTAL_OVERFLOW")
loadAnimalSection("function Animal:showInfo(box)","function Animal:showGeneticsInfo(box)")
loadAnimalSection("function Animal:showMonitorInfo(box)","function Animal:getVisibleDiseases()")
g_i18n={getText=function(_,key)return key end,formatMoney=function(_,value)assert(type(value)=="number" and value==value and math.abs(value)<math.huge);return tostring(value)end}
g_fillTypeManager.getFillTypeTitleByIndex=function()return "Cattle"end
RealisticLivestock={formatAge=function()return "12"end}
local rows={};local box={addLine=function(_,key,value)rows[key]=value end}
local display={monitor={active=true,fee=1},health=99,gender="male",weight=500,targetWeight=600,input={},output={},age=12,
    getSellPrice=function()return nil end,getSubTypeIndex=function()return 1 end,getSubType=function()return {name="BULL",fillTypeIndex=1}end,
    getName=function()return ""end,isHorse=function()return false end}
Animal.showInfo(display,box);Animal.showMonitorInfo(display,box)
check("engine price: actual info and monitor display unavailable price without arithmetic/formatter calls",rows.rl_ui_value=="-" and rows.rl_ui_valuePerKilo=="-")
