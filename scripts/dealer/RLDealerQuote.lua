-- Volatile authority-only quotes. No serialization, RNG, generation or growth calls.
-- serverEpoch MUST be fresh per authoritative load; it is supplied by the server session.
-- Prices are existing RLAnimalBuyService.computeBuyPrice(serverAnimal) through adapters.
RLDealerQuote = {}
local Q = RLDealerQuote
Q.VERSION = 1
Q.TTL_MS = 15000
Q.MAX_ACTIVE = 256
local finite=RLPlain.finite
local function text(v) return type(v)=="string" and #v>0 and #v<=4096 end
local copy=RLPlain.copy
local function call(a,name,...)
    local ok,v,why=pcall(a[name],...)
    if not ok then return nil,"ADAPTER_ERROR:"..name end
    return v,why
end
local function adapterOK(a)
    if type(a)~="table" then return false end
    for _,name in ipairs({"isServer","authorize","currentClock","monotonicMs","readListing","eligible","computeBuyPrice","computeTransportFee"}) do
        if type(a[name])~="function" then return false end
    end
    return true
end
local function normalize(selection,principal)
    if type(selection)~="table" or RLTradePersistence.check(selection) or not text(principal) then return nil,"BAD_QUOTE_REQUEST" end
    for k in pairs(selection) do if k~="destination" and k~="items" then return nil,"BAD_QUOTE_REQUEST" end end
    local request,why=RLDealerPurchaseProtocol.request({requestId="quote",destination=selection.destination,
        items=selection.items,quoteCredential="quote"})
    if not request then return nil,why end
    table.sort(request.items,function(a,b) return a.saleId<b.saleId end)
    return {principal=principal,destination=request.destination,items=request.items}
end
function Q.new(serverEpoch)
    if not text(serverEpoch) or #serverEpoch>256 then return nil,"INVALID_SERVER_EPOCH" end
    return {version=Q.VERSION,serverEpoch=serverEpoch,sequence=0,records={}}
end
local function now(store,a)
    local ms,why=call(a,"monotonicMs")
    if not finite(ms) or ms<0 or (store.lastMs and ms<store.lastMs) then return nil,why or "BAD_MONOTONIC_CLOCK" end
    store.lastMs=ms; return ms
end
local function preflight(store,selection,principal,a)
    if not adapterOK(a) then return nil,"QUOTE_ADAPTER_REQUIRED" end
    if call(a,"isServer")~=true then return nil,"SERVER_ONLY" end
    local binding,why=normalize(selection,principal); if not binding then return nil,why end
    local allowed,reason=call(a,"authorize",principal,binding.destination)
    if allowed~=true then return nil,reason or "NO_PERMISSION" end
    local ms; ms,why=now(store,a); if not ms then return nil,why end
    return binding,ms
end
local function inspect(binding,a)
    local clock,why=call(a,"currentClock")
    if not finite(clock) or clock<0 then return nil,why or "BAD_CURRENT_CLOCK" end
    local context={principal=binding.principal,destination=binding.destination,currentClock=clock}
    local subtotal,fee=0,0
    local cursors={}
    local snapshots={}
    for _,item in ipairs(binding.items) do
        local listing,reason=call(a,"readListing",item.saleId)
        if type(listing)~="table" or RLTradePersistence.check(listing) then return nil,reason or "SALE_NOT_FOUND" end
        snapshots[item.saleId]=RLTradePersistence.canonical(listing)
        if listing.saleId~=item.saleId or listing.recordRevision~=item.revision then return nil,"STALE_REVISION" end
        if listing.state~="LISTED" then return nil,"SALE_NOT_LISTED" end
        if not finite(listing.listedAtMonths) or listing.listedAtMonths>clock
            or not finite(listing.expiresAtMonths) or listing.expiresAtMonths<=clock then return nil,"SALE_EXPIRED" end
        if listing.lastProgressedAtMonths~=clock then return nil,"PHYSIOLOGY_NOT_CURRENT" end
        local accepted; accepted,reason=call(a,"eligible",copy(listing),copy(context))
        if accepted~=true then return nil,reason or "INELIGIBLE" end
        local price; price,reason=call(a,"computeBuyPrice",copy(listing),copy(context))
        if not finite(price) or price<0 then return nil,reason or "INVALID_SERVER_PRICE" end
        local transport; transport,reason=call(a,"computeTransportFee",copy(listing),copy(context))
        if not finite(transport) or transport<0 then return nil,reason or "INVALID_TRANSPORT_FEE" end
        subtotal,fee=subtotal+price,fee+transport
        if not finite(subtotal) or not finite(fee) or not finite(subtotal+fee) then return nil,"INVALID_SERVER_TOTAL" end
        cursors[#cursors+1]={saleId=item.saleId,revision=item.revision,currentClock=listing.lastProgressedAtMonths,price=price,transportFee=transport}
    end
    if call(a,"currentClock")~=clock then return nil,"CURRENT_CLOCK_CHANGED" end
    for _,item in ipairs(binding.items) do
        local latest=call(a,"readListing",item.saleId)
        if type(latest)~="table" or RLTradePersistence.check(latest)
            or RLTradePersistence.canonical(latest)~=snapshots[item.saleId] then return nil,"QUOTE_SNAPSHOT_CHANGED" end
    end
    if call(a,"currentClock")~=clock then return nil,"CURRENT_CLOCK_CHANGED" end
    return {currentClock=clock,subtotal=subtotal,transportFee=fee,amount=subtotal+fee,cursors=cursors}
end
function Q.issue(store,selection,principal,adapter)
    local binding,ms=preflight(store,selection,principal,adapter)
    if not binding then return nil,ms end
    local priced,why=inspect(binding,adapter); if not priced then return nil,why end
    local finalMs; finalMs,why=now(store,adapter); if not finalMs then return nil,why end
    -- Time spent in callbacks cannot create an already expired credential.
    if Q.TTL_MS-(finalMs-ms)<1 then return nil,"QUOTE_TIMEOUT" end
    local count=0
    for id,record in pairs(store.records) do
        if finalMs>=record.expiresMs then store.records[id]=nil else count=count+1 end
    end
    if count>=Q.MAX_ACTIVE then return nil,"QUOTE_CAPACITY" end
    if store.sequence>=9007199254740991 then return nil,"QUOTE_SEQUENCE_EXHAUSTED" end
    store.sequence=store.sequence+1
    local credential="dq1:"..#store.serverEpoch..":"..store.serverEpoch..":"..string.format("%.0f",store.sequence)
    local quote={version=Q.VERSION,credential=credential,serverEpoch=store.serverEpoch,sequence=store.sequence,
        principal=binding.principal,destination=binding.destination,items=copy(binding.items),currentClock=priced.currentClock,
        subtotal=priced.subtotal,transportFee=priced.transportFee,amount=priced.amount,cursors=priced.cursors,
        issuedMs=ms,expiresMs=ms+Q.TTL_MS,ttlMs=math.floor(ms+Q.TTL_MS-finalMs)}
    store.records[credential]={quote=copy(quote),binding=RLTradePersistence.canonical(binding),expiresMs=quote.expiresMs}
    return copy(quote)
end
function Q.validate(store,credential,selection,principal,adapter)
    local binding,ms=preflight(store,selection,principal,adapter)
    if not binding then return nil,ms end
    if not text(credential) then return nil,"INVALID_QUOTE_CREDENTIAL" end
    local record=store.records[credential]
    if not record or record.quote.serverEpoch~=store.serverEpoch then return nil,"UNKNOWN_QUOTE" end
    if ms>=record.expiresMs then store.records[credential]=nil; return nil,"QUOTE_EXPIRED" end
    if record.binding~=RLTradePersistence.canonical(binding) then return nil,"QUOTE_BINDING_MISMATCH" end
    local priced,why=inspect(binding,adapter); if not priced then return nil,why end
    if priced.currentClock~=record.quote.currentClock then return nil,"CURRENT_CLOCK_CHANGED" end
    if priced.subtotal~=record.quote.subtotal or priced.transportFee~=record.quote.transportFee or priced.amount~=record.quote.amount
        or RLTradePersistence.canonical(priced.cursors)~=RLTradePersistence.canonical(record.quote.cursors) then return nil,"SERVER_PRICE_CHANGED" end
    local finalMs; finalMs,why=now(store,adapter); if not finalMs then return nil,why end
    if record.expiresMs-finalMs<1 then store.records[credential]=nil; return nil,"QUOTE_EXPIRED" end
    local quote=copy(record.quote); quote.ttlMs=math.floor(record.expiresMs-finalMs)
    return quote
end
