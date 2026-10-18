loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/dealer/RLDealerPurchaseProtocol.lua")
loadMod("scripts/dealer/RLDealerPurchase.lua")
loadMod("scripts/dealer/RLDealerQuote.lua")
loadMod("scripts/gui/rlmenu/services/RLAnimalBuyService.lua")
local Q=RLDealerQuote
local function clone(t) if type(t)~="table" then return t end; local o={}; for k,v in pairs(t) do o[k]=clone(v) end; return o end
local epoch=0
local function selection() return {destination="pen:17",items={{saleId="b",revision=2},{saleId="a",revision=1}}} end
local function fixture()
    epoch=epoch+1
    local w={clock=5.25,ms=10,markup=1.2,prices={a=100,b=200},fees={a=5,b=6},reads=0,priceCalls=0,feeCalls=0}
    local listings={a={saleId="a",recordRevision=1,state="LISTED",listedAtMonths=5,lastProgressedAtMonths=5.25,expiresAtMonths=6},
        b={saleId="b",recordRevision=2,state="LISTED",listedAtMonths=5,lastProgressedAtMonths=5.25,expiresAtMonths=6}}
    local a={isServer=function() return true end,authorize=function() return true end,
        currentClock=function() return w.clock end,monotonicMs=function() return w.ms end,
        readListing=function(id) w.reads=w.reads+1; return clone(listings[id]) end,eligible=function() return true end}
    RLDealerQualityResolver={getMarkup=function() return w.markup end}
    a.computeBuyPrice=function(listing)
        w.priceCalls=w.priceCalls+1
        local animal={getSellPrice=function() return w.prices[listing.saleId] end}
        return RLAnimalBuyService.computeBuyPrice(animal)
    end
    a.computeTransportFee=function(listing) w.feeCalls=w.feeCalls+1; return w.fees[listing.saleId] end
    return assert(Q.new("server-load-"..epoch)),a,w,listings
end
local store,a,w,listings=fixture()
local quote=assert(Q.issue(store,selection(),"u1",a))
check("dealer quote: existing dealer price and server transport aggregate unchanged",quote.subtotal==360 and quote.transportFee==11 and quote.amount==371 and w.priceCalls==2 and w.feeCalls==2)
check("dealer quote: quote binds epoch sequence principal destination sorted revisions and cursor",quote.serverEpoch==store.serverEpoch and quote.sequence==1 and quote.principal=="u1"
    and quote.destination=="pen:17" and quote.items[1].saleId=="a" and quote.items[2].revision==2 and quote.currentClock==5.25 and quote.cursors[1].currentClock==5.25)
check("dealer quote: monotonic TTL uses real milliseconds",quote.issuedMs==10 and quote.expiresMs==15010)
local accepted=Q.validate(store,quote.credential,selection(),"u1",a)
check("dealer quote: current exact selection validates",accepted and accepted.amount==371 and store.sequence==1)
local ordered=selection(); ordered.items[1],ordered.items[2]=ordered.items[2],ordered.items[1]
check("dealer quote: item ordering does not change quote binding",Q.validate(store,quote.credential,ordered,"u1",a)~=nil)
quote.amount=0; quote.items[1].revision=55
check("dealer quote: returned quote is detached from authority",Q.validate(store,quote.credential,selection(),"u1",a).amount==371)
quote=Q.validate(store,quote.credential,selection(),"u1",a)
local _,why=Q.validate(store,quote.credential,selection(),"u2",a)
check("dealer quote: principal change rejects credential reuse",why=="QUOTE_BINDING_MISMATCH")
local changed=selection(); changed.destination="pen:18"
_,why=Q.validate(store,quote.credential,changed,"u1",a)
check("dealer quote: destination change rejects credential reuse",why=="QUOTE_BINDING_MISMATCH")
changed=selection(); changed.items[1].revision=3
_,why=Q.validate(store,quote.credential,changed,"u1",a)
check("dealer quote: selection revision change rejects",why=="QUOTE_BINDING_MISMATCH")
_,why=Q.validate(store,"forged",selection(),"u1",a)
check("dealer quote: invented credential is not authority",why=="UNKNOWN_QUOTE")
for _,field in ipairs({"amount","subtotal","transportFee","price","animals","principal","quoteCredential"}) do
    local s=selection(); s[field]=1
    local result,reason=Q.issue(store,s,"u1",a)
    check("dealer quote: client "..field.." cannot enter pricing",not result and reason=="BAD_QUOTE_REQUEST")
end
for _,case in ipairs({
    {"server authority",function(s,x) x.isServer=function() return false end end,"SERVER_ONLY"},
    {"permission",function(s,x) x.authorize=function() return false,"NO_PERMISSION" end end,"NO_PERMISSION"},
    {"clock",function(s,x) x.currentClock=function() return 0/0 end end,"BAD_CURRENT_CLOCK"},
    {"revision",function(s,x,z,l) l.a.recordRevision=2 end,"STALE_REVISION"},
    {"state",function(s,x,z,l) l.a.state="WITHDRAWN" end,"SALE_NOT_LISTED"},
    {"expiry",function(s,x,z,l) l.a.expiresAtMonths=z.clock end,"SALE_EXPIRED"},
    {"future listing",function(s,x,z,l) l.a.listedAtMonths=10 end,"SALE_EXPIRED"},
    {"missing physiology cursor",function(s,x,z,l) l.a.lastProgressedAtMonths=nil end,"PHYSIOLOGY_NOT_CURRENT"},
    {"stale physiology",function(s,x,z,l) l.a.lastProgressedAtMonths=5 end,"PHYSIOLOGY_NOT_CURRENT"},
    {"eligibility",function(s,x) x.eligible=function() return false,"MODEL_GAP" end end,"MODEL_GAP"},
    {"negative price",function(s,x) x.computeBuyPrice=function() return -1 end end,"INVALID_SERVER_PRICE"},
    {"NaN price",function(s,x) x.computeBuyPrice=function() return 0/0 end end,"INVALID_SERVER_PRICE"},
    {"negative transport",function(s,x) x.computeTransportFee=function() return -1 end end,"INVALID_TRANSPORT_FEE"},
    {"infinite total",function(s,x) x.computeBuyPrice=function() return 1e308 end end,"INVALID_SERVER_TOTAL"},
    {"price exception",function(s,x) x.computeBuyPrice=function() error("bad source") end end,"ADAPTER_ERROR:computeBuyPrice"},
    {"read exception",function(s,x) x.readListing=function() error("bad registry") end end,"ADAPTER_ERROR:readListing"},
    {"missing adapter",function(s,x) x.eligible=nil end,"QUOTE_ADAPTER_REQUIRED"},
    {"monotonic regression",function(s,x,z) s.lastMs=z.ms+1 end,"BAD_MONOTONIC_CLOCK"}
}) do
    local s,x,z,l=fixture(); case[2](s,x,z,l)
    local result,reason=Q.issue(s,selection(),"u1",x)
    check("dealer quote: "..case[1].." refuses issuance",not result and reason==case[3] and s.sequence==0 and not next(s.records))
end
store,a,w,listings=fixture(); quote=assert(Q.issue(store,selection(),"u1",a)); w.ms=quote.expiresMs
_,why=Q.validate(store,quote.credential,selection(),"u1",a)
check("dealer quote: exact real-time expiry refuses and removes credential",why=="QUOTE_EXPIRED" and not store.records[quote.credential])
store,a,w,listings=fixture(); quote=assert(Q.issue(store,selection(),"u1",a)); w.markup=1.3
_,why=Q.validate(store,quote.credential,selection(),"u1",a)
check("dealer quote: current server markup repricing invalidates quote",why=="SERVER_PRICE_CHANGED")
store,a,w,listings=fixture(); quote=assert(Q.issue(store,selection(),"u1",a)); w.fees.a=6
_,why=Q.validate(store,quote.credential,selection(),"u1",a)
check("dealer quote: server transport repricing invalidates quote",why=="SERVER_PRICE_CHANGED")
store,a,w,listings=fixture(); quote=assert(Q.issue(store,selection(),"u1",a)); w.prices.a=101; w.prices.b=199
_,why=Q.validate(store,quote.credential,selection(),"u1",a)
check("dealer quote: offsetting item price changes invalidate equal aggregate",why=="SERVER_PRICE_CHANGED")
store,a,w,listings=fixture(); quote=assert(Q.issue(store,selection(),"u1",a)); w.clock=5.5; listings.a.lastProgressedAtMonths=5.5; listings.b.lastProgressedAtMonths=5.5
_,why=Q.validate(store,quote.credential,selection(),"u1",a)
check("dealer quote: month cursor change invalidates even freshly progressed listings",why=="CURRENT_CLOCK_CHANGED")
store,a,w,listings=fixture(); quote=assert(Q.issue(store,selection(),"u1",a)); listings.a.recordRevision=2
_,why=Q.validate(store,quote.credential,selection(),"u1",a)
check("dealer quote: actual registry revision change invalidates old quote",why=="STALE_REVISION")
store,a,w,listings=fixture(); quote=assert(Q.issue(store,selection(),"u1",a)); local reset=assert(Q.new("new-load-epoch"))
_,why=Q.validate(reset,quote.credential,selection(),"u1",a)
check("dealer quote: reload clears credentials instead of restoring quotes",why=="UNKNOWN_QUOTE" and not next(reset.records))
store,a,w,listings=fixture(); local compute=a.computeBuyPrice
a.computeBuyPrice=function(...) local price=compute(...); w.ms=w.ms+Q.TTL_MS; return price end
_,why=Q.issue(store,selection(),"u1",a)
check("dealer quote: slow price callback cannot issue expired quote",why=="QUOTE_TIMEOUT" and store.sequence==0)
store,a,w,listings=fixture(); compute=a.computeBuyPrice
a.computeBuyPrice=function(...) local price=compute(...); listings.a.recordRevision=2; return price end
_,why=Q.issue(store,selection(),"u1",a)
check("dealer quote: source mutation during pricing refuses snapshot",why=="QUOTE_SNAPSHOT_CHANGED")
store,a,w,listings=fixture(); quote=assert(Q.issue(store,selection(),"u1",a)); compute=a.computeBuyPrice
a.computeBuyPrice=function(...) local price=compute(...); w.ms=quote.expiresMs; return price end
_,why=Q.validate(store,quote.credential,selection(),"u1",a)
check("dealer quote: TTL rechecks after validation callbacks",why=="QUOTE_EXPIRED")
store,a,w,listings=fixture(); local previousLimit=Q.MAX_ACTIVE; Q.MAX_ACTIVE=1
quote=assert(Q.issue(store,selection(),"u1",a)); _,why=Q.issue(store,selection(),"u1",a)
check("dealer quote: bounded active credentials fail closed",why=="QUOTE_CAPACITY")
w.ms=quote.expiresMs
check("dealer quote: expired credentials free volatile capacity",Q.issue(store,selection(),"u1",a)~=nil and store.sequence==2)
Q.MAX_ACTIVE=previousLimit
store,a,w,listings=fixture(); store.sequence=9007199254740991
_,why=Q.issue(store,selection(),"u1",a)
check("dealer quote: sequence exhaustion never reuses credential",why=="QUOTE_SEQUENCE_EXHAUSTED")
check("dealer quote: overlong epoch cannot generate unwireable credential",not Q.new(string.rep("x",257)))
store,a,w,listings=fixture(); local rng=math.random; math.random=function() error("RNG forbidden") end
local safe=pcall(function() local q=assert(Q.issue(store,selection(),"u1",a)); assert(Q.validate(store,q.credential,selection(),"u1",a)) end)
math.random=rng
check("dealer quote: issue and validation consume no generation RNG",safe and listings.a.lastProgressedAtMonths==5.25 and listings.a.recordRevision==1)
-- Coordinator bridge: quoted amount comes exclusively from the volatile server registry.
store,a,w,listings=fixture(); quote=assert(Q.issue(store,selection(),"u1",a))
local purchase=RLDealerPurchase.new(); local commits=0
local adapter={durableDealerOwnershipVersion=1,isServer=a.isServer,authorize=a.authorize,monotonicMs=a.monotonicMs,currentClock=a.currentClock,
    readListing=a.readListing,validateListing=a.eligible,validateDestination=function() return true end,validateFunds=function() return true end,
    checkpoint=function(snapshot) return true end}
adapter.validateQuote=function(_,context)
    local valid,reason=Q.validate(store,context.request.quoteCredential,{destination=context.request.destination,items=context.request.items},context.request.principal,a)
    return valid~=nil,reason
end
adapter.prepare=function(_,context)
    local valid,reason=Q.validate(store,context.request.quoteCredential,{destination=context.request.destination,items=context.request.items},context.request.principal,a)
    if not valid then return nil,reason end
    return {amount=valid.amount,transferIds={context.token..":a",context.token..":b"},compensation={}}
end
adapter.apply=function(token,plan)
    commits=commits+1
    return {status="COMMITTED",token=token,amount=plan.amount,transferIds=plan.transferIds,sourceComplete=true,targetComplete=true,moneyComplete=true}
end
adapter.reconcile=function() return "UNKNOWN" end
local req={requestId="buy-quote",destination=selection().destination,items=selection().items,quoteCredential=quote.credential}
local bought=RLDealerPurchase.execute(purchase,req,"u1",adapter)
check("dealer quote: coordinator bridge charges authoritative price plus transport only",bought and bought.status=="COMMITTED" and bought.amount==371 and commits==1)
w.ms=quote.expiresMs+1
check("dealer quote: already committed coordinator replay survives quote expiry without recharging",RLDealerPurchase.execute(purchase,req,"u1",adapter).amount==371 and commits==1)

store,a,w,listings=fixture(); local read=a.readListing
a.readListing=function(id) local result=read(id); if w.reads==4 then w.clock=w.clock+0.25 end; return result end
_,why=Q.issue(store,selection(),"u1",a)
check("dealer quote: clock change during final snapshot read refuses issuance",why=="CURRENT_CLOCK_CHANGED" and store.sequence==0)

store,a,w,listings=fixture(); local pricing=a.computeBuyPrice
a.computeBuyPrice=function(...) local price=pricing(...); w.ms=w.ms+5; return price end
quote=assert(Q.issue(store,selection(),"u1",a))
check("dealer quote: public remaining TTL discounts authority callback time",quote.ttlMs==Q.TTL_MS-10)
w.ms=w.ms+5
local validated=assert(Q.validate(store,quote.credential,selection(),"u1",a))
check("dealer quote: validation returns freshly reduced remaining TTL",validated.ttlMs==Q.TTL_MS-25)
