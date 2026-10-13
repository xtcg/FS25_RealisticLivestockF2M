loadMod("scripts/dealer/RLDealerPurchaseProtocol.lua")
loadMod("scripts/dealer/RLDealerQuoteProtocol.lua")
loadMod("scripts/dealer/RLDealerClientRequest.lua")
local C=RLDealerClientRequest
local function selection() return {destination="pen:1",items={{saleId="a",revision=1}}} end
local function quoted(id) return {requestId=id,status="QUOTED",reason="",credential="server-quote",subtotal=100,transportFee=5,amount=105,ttlMs=15000} end
local function bought(id) return {requestId=id,status="COMMITTED",reason="",amount=105,transferIds={"server-animal-1"}} end
local serial=0
local function fixture()
    serial=serial+1
    local w={ms=10,quotes={},purchases={},confirmations={},completions={}}
    local a={monotonicMs=function() return w.ms end,sendQuote=function(req) w.quotes[#w.quotes+1]=req; return true end,
        sendPurchase=function(req) w.purchases[#w.purchases+1]=req; return true end,
        confirm=function(q,respond) w.confirmations[#w.confirmations+1]={quote=q,respond=respond} end,
        complete=function(result) w.completions[#w.completions+1]=result end}
    return assert(C.new("client-"..serial,a)),a,w
end
local client,a,w=fixture(); local id=assert(C.begin(client,selection()))
check("dealer client: begin sends quote IDs/revisions/destination only",#w.quotes==1 and w.quotes[1].requestId==id and not w.quotes[1].price and client.pending.phase=="QUOTE" and #w.purchases==0)
local _,why=C.begin(client,selection())
check("dealer client: one request pending at a time",why=="REQUEST_IN_PROGRESS" and #w.quotes==1)
assert(C.receiveQuote(client,quoted(id)))
check("dealer client: authoritative quote reaches confirmation before purchase",client.pending.phase=="CONFIRM" and w.confirmations[1].quote.amount==105 and #w.purchases==0)
w.confirmations[1].quote.amount=1
assert(w.confirmations[1].respond(true))
check("dealer client: purchase carries credential and no amount or animals",client.pending.phase=="PURCHASE" and #w.purchases==1 and w.purchases[1].quoteCredential=="server-quote"
    and not w.purchases[1].amount and not w.purchases[1].animals and w.purchases[1].requestId==id)
assert(C.receivePurchase(client,bought(id)))
check("dealer client: matching purchase settles once and clears pending",not client.pending and #w.completions==1 and w.completions[1].status=="COMMITTED")
_,why=C.receivePurchase(client,bought(id))
check("dealer client: duplicate purchase reply cannot consume completion twice",why=="STALE_REPLY" and #w.completions==1)
local second=assert(C.begin(client,selection()))
_,why=C.receivePurchase(client,bought(id))
check("dealer client: late old purchase cannot clear new quote pending",why=="STALE_REPLY" and client.pending.request.requestId==second and client.pending.phase=="QUOTE")
_,why=C.receiveQuote(client,quoted(id))
check("dealer client: late old quote cannot clear new pending",why=="STALE_REPLY" and client.pending.request.requestId==second)
_,why=C.receivePurchase(client,bought(second))
check("dealer client: correct-ID purchase reply in quote phase rejects",why=="WRONG_PHASE" and client.pending.phase=="QUOTE")
C.receiveQuote(client,quoted(second)); local oldConfirm=w.confirmations[2].respond
_,why=C.receiveQuote(client,quoted(second))
check("dealer client: duplicate quote cannot overwrite confirmation",why=="WRONG_PHASE" and #w.confirmations==2)
C.cancel(client); local third=assert(C.begin(client,selection())); _,why=oldConfirm(true)
check("dealer client: old asynchronous confirmation cannot send new purchase",why=="STALE_CONFIRMATION" and client.pending.request.requestId==third and #w.purchases==1)
C.receiveQuote(client,RLDealerQuoteProtocol.rejected(third,"STALE_REVISION"))
check("dealer client: quote refusal finishes without confirmation or purchase",not client.pending and w.completions[#w.completions].reason=="STALE_REVISION" and #w.purchases==1)
client,a,w=fixture(); id=C.begin(client,selection()); C.receiveQuote(client,quoted(id)); w.confirmations[1].respond(false)
check("dealer client: declined authoritative confirmation sends no purchase",not client.pending and #w.purchases==0 and w.completions[1].reason=="CANCELLED")
for _,phase in ipairs({"QUOTE","CONFIRM","PURCHASE"}) do
    client,a,w=fixture(); id=C.begin(client,selection())
    if phase~="QUOTE" then C.receiveQuote(client,quoted(id)) end
    if phase=="PURCHASE" then w.confirmations[1].respond(true) end
    w.ms=client.pending.deadline; C.tick(client)
    check("dealer client: "..phase.." phase timeout clears only its pending",not client.pending and #w.completions==1
        and w.completions[1].reason==(phase=="CONFIRM" and "QUOTE_EXPIRED" or phase.."_TIMEOUT"))
end
client,a,w=fixture(); id=C.begin(client,selection()); C.receiveQuote(client,quoted(id)); w.ms=client.pending.deadline
w.confirmations[1].respond(true)
check("dealer client: expired confirmation refuses even without tick",#w.purchases==0 and w.completions[1].reason=="QUOTE_EXPIRED")
client,a,w=fixture(); id=C.begin(client,selection()); w.ms=client.pending.deadline
C.receiveQuote(client,quoted(id))
check("dealer client: quote response at timeout cannot open confirmation",#w.confirmations==0 and w.completions[1].reason=="QUOTE_TIMEOUT")
client,a,w=fixture(); id=C.begin(client,selection()); C.receiveQuote(client,quoted(id)); w.confirmations[1].respond(true); w.ms=client.pending.deadline
C.receivePurchase(client,bought(id))
check("dealer client: a real purchase reply is the outcome even after the deadline",not client.pending and #w.completions==1 and w.completions[1].status~="REJECTED")
client,a,w=fixture(); id=C.begin(client,selection()); w.ms=9; C.tick(client)
client,a,w=fixture(); id=C.begin(client,selection()); C.receiveQuote(client,quoted(id)); w.confirmations[1].respond(true); w.ms=client.pending.deadline; C.tick(client)
check("dealer client: an unanswered purchase is UNCERTAIN, never a refusal, and keeps the order id for a status query",
    not client.pending and w.completions[1].status=="UNCERTAIN" and w.completions[1].reason=="PURCHASE_TIMEOUT"
    and C.statusQuery(client).orderId==id and #w.purchases==1)
local answer=C.receiveOrderStatus(client,{status="PENDING"})
check("dealer client: PENDING keeps the query open; the same id is asked again",answer.status=="PENDING" and C.statusQuery(client).orderId==id)
answer=C.receiveOrderStatus(client,{status="COMMITTED",amount=210,transferIds={"t1"}})
check("dealer client: a COMMITTED status settles it once and clears the query",answer.status=="COMMITTED" and C.statusQuery(client)==nil
    and w.completions[2].status=="COMMITTED" and #w.purchases==1 and select(2,C.receiveOrderStatus(client,{status="COMMITTED"}))=="NOTHING_UNRESOLVED")
client,a,w=fixture(); id=C.begin(client,selection()); w.ms=9; C.tick(client)
check("dealer client: monotonic regression closes pending safely",not client.pending and w.completions[1].reason=="BAD_LOCAL_CLOCK")
client,a,w=fixture(); a.sendQuote=function() return false end
_,why=C.begin(client,selection())
check("dealer client: failed quote dispatch clears pending",why=="QUOTE_NOT_DISPATCHED" and not client.pending)
client,a,w=fixture(); a.sendQuote=function() error("network") end
_,why=C.begin(client,selection())
check("dealer client: quote dispatch exception clears pending",why=="QUOTE_DISPATCH_ERROR" and not client.pending)
client,a,w=fixture(); a.confirm=function() error("closed UI") end; id=C.begin(client,selection()); C.receiveQuote(client,quoted(id))
check("dealer client: confirmation exception cannot strand pending",not client.pending and w.completions[1].reason=="CONFIRMATION_ERROR")
client,a,w=fixture(); a.sendPurchase=function() return false end; id=C.begin(client,selection()); C.receiveQuote(client,quoted(id)); w.confirmations[1].respond(true)
check("dealer client: failed purchase dispatch clears pending",not client.pending and w.completions[1].reason=="PURCHASE_NOT_DISPATCHED")
client,a,w=fixture(); a.sendPurchase=function() error("network") end; id=C.begin(client,selection()); C.receiveQuote(client,quoted(id)); w.confirmations[1].respond(true)
check("dealer client: purchase dispatch exception clears pending",not client.pending and w.completions[1].reason=="PURCHASE_DISPATCH_ERROR")
client,a,w=fixture(); a.complete=function() error("closed frame") end; id=C.begin(client,selection()); C.cancel(client)
check("dealer client: completion callback exception does not retain lock",not client.pending and client.lastResult.reason=="CANCELLED")
client,a,w=fixture(); local invalid=selection(); invalid.price=1
_,why=C.begin(client,invalid)
check("dealer client: client amount cannot enter quote request",why=="MALFORMED_QUOTE_REQUEST" and #w.quotes==0)
check("dealer client: no adapter is explicitly disabled",select(2,C.begin(assert(C.new("disabled")),selection()))=="DEALER_V2_DISABLED")
client,a,w=fixture(); client.sequence=9007199254740991
_,why=C.begin(client,selection())
check("dealer client: sequence exhaustion never reuses request ID",why=="CLIENT_SEQUENCE_EXHAUSTED")
-- Fully synchronous host transport can complete inside begin() without resurrecting pending.
client,a,w=fixture()
a.sendQuote=function(req) C.receiveQuote(client,quoted(req.requestId)); return true end
a.confirm=function(q,respond) respond(true) end
a.sendPurchase=function(req) C.receivePurchase(client,bought(req.requestId)); return true end
id=C.begin(client,selection())
check("dealer client: synchronous quote-confirm-buy completion is safe",id and not client.pending and #w.completions==1 and w.completions[1].status=="COMMITTED")
client,a,w=fixture(); local rng=math.random; math.random=function() error("no generation") end
local safe=pcall(function() local req=C.begin(client,selection()); C.receiveQuote(client,quoted(req)); w.confirmations[1].respond(true); C.receivePurchase(client,bought(req)) end)
math.random=rng
check("dealer client: full request lifecycle consumes no generation RNG",safe)

client,a,w=fixture(); id=C.begin(client,selection()); C.receiveQuote(client,quoted(id)); w.confirmations[1].respond(true)
_,why=C.cancel(client)
check("dealer client: cannot pretend dispatched authority purchase was cancelled",why=="PURCHASE_ALREADY_DISPATCHED" and client.pending.phase=="PURCHASE")
check("dealer client: exact immutable purchase is retained for idempotent retry",client.lastPurchase.requestId==id and client.lastPurchase.quoteCredential=="server-quote" and not client.lastPurchase.amount)

-- review: unresolved orders
do
    local client2, a2, w2 = fixture(); local id2 = C.begin(client2, selection()); C.receiveQuote(client2, quoted(id2)); w2.confirmations[1].respond(true)
    w2.ms = client2.pending.deadline; C.tick(client2)
    check("R4 a new order cannot start while a purchase is unresolved", select(2, C.begin(client2, selection())) == "ORDER_UNRESOLVED")
    local answer = C.receiveOrderStatus(client2, { status = "UNKNOWN_REQUEST" })
    check("R4 a server that has no such order means it was never received: settled as a refusal, nothing bought", answer.status == "REJECTED"
        and answer.reason == "NOT_RECEIVED" and C.statusQuery(client2) == nil and C.begin(client2, selection()) ~= nil)
    local client3, a3, w3 = fixture(); local id3 = C.begin(client3, selection()); C.receiveQuote(client3, quoted(id3)); w3.confirmations[1].respond(true)
    w3.ms = 1
    C.tick(client3)
    check("R4 a local clock fault after dispatch is UNCERTAIN, not a refusal", client3.unresolved ~= nil and w3.completions[1].status == "UNCERTAIN")
end
