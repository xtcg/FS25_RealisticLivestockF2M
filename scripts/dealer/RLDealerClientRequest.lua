-- Pure client orchestration: quote -> authoritative confirmation -> purchase.
-- Adapters own UI/transport/timers; no local sale removal, money, animals or generation.
RLDealerClientRequest={}
local C=RLDealerClientRequest
C.QUOTE_TIMEOUT_MS,C.PURCHASE_TIMEOUT_MS=15000,30000
local function copy(t) if type(t)~="table" then return t end; local out={}; for k,v in pairs(t) do out[k]=copy(v) end; return out end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function now(client)
    local ok,ms=pcall(client.adapter.monotonicMs)
    if not ok or not finite(ms) or ms<0 or (client.lastMs and ms<client.lastMs) then return nil,"BAD_LOCAL_CLOCK" end
    client.lastMs=ms; return ms
end
local function finish(client,pending,result)
    if client.pending~=pending then return nil,"STALE_REPLY" end
    client.pending=nil; client.lastResult=copy(result)
    if type(client.adapter.complete)=="function" then pcall(client.adapter.complete,copy(result)) end
    return copy(result)
end
local function refused(client,pending,reason)
    return finish(client,pending,{requestId=pending.request.requestId,status="REJECTED",reason=reason})
end
function C.new(clientEpoch,adapter)
    if type(clientEpoch)~="string" or #clientEpoch==0 or #clientEpoch>256 then return nil,"INVALID_CLIENT_EPOCH" end
    if adapter~=nil and type(adapter)~="table" then return nil,"INVALID_CLIENT_ADAPTER" end
    return {epoch=clientEpoch,sequence=0,adapter=adapter or {}}
end
function C.begin(client,selection)
    if client.pending then return nil,"REQUEST_IN_PROGRESS" end
    local a=client.adapter
    for _,name in ipairs({"monotonicMs","sendQuote","confirm","sendPurchase"}) do
        if type(a[name])~="function" then return nil,"DEALER_V2_DISABLED" end
    end
    if type(selection)~="table" then return nil,"MALFORMED_QUOTE_REQUEST" end
    for k in pairs(selection) do if k~="destination" and k~="items" then return nil,"MALFORMED_QUOTE_REQUEST" end end
    if client.sequence>=9007199254740991 then return nil,"CLIENT_SEQUENCE_EXHAUSTED" end
    local id="dealer-ui:"..#client.epoch..":"..client.epoch..":"..string.format("%.0f",client.sequence+1)
    local request,why=RLDealerQuoteProtocol.request({requestId=id,destination=selection.destination,items=selection.items})
    if not request then return nil,why end
    local ms; ms,why=now(client); if not ms then return nil,why end
    client.sequence=client.sequence+1
    local pending={request=request,phase="QUOTE",deadline=ms+C.QUOTE_TIMEOUT_MS}
    client.pending=pending -- before dispatch: host transport may complete synchronously
    local ok,accepted=pcall(a.sendQuote,copy(request))
    if (not ok or accepted~=true) and client.pending==pending and pending.phase=="QUOTE" then
        refused(client,pending,ok and "QUOTE_NOT_DISPATCHED" or "QUOTE_DISPATCH_ERROR")
        return nil,ok and "QUOTE_NOT_DISPATCHED" or "QUOTE_DISPATCH_ERROR"
    end
    return id
end
function C.receiveQuote(client,value)
    local reply,why=RLDealerQuoteProtocol.reply(value); if not reply then return nil,why end
    local pending=client.pending
    if not pending or reply.requestId~=pending.request.requestId then return nil,"STALE_REPLY" end
    if pending.phase~="QUOTE" then return nil,"WRONG_PHASE" end
    local ms; ms,why=now(client)
    if not ms then return refused(client,pending,why) end
    if ms>=pending.deadline then return refused(client,pending,"QUOTE_TIMEOUT") end
    if reply.status=="REJECTED" then return finish(client,pending,reply) end
    pending.phase,pending.quote,pending.deadline="CONFIRM",copy(reply),ms+reply.ttlMs
    local function respond(accepted)
        if client.pending~=pending or pending.phase~="CONFIRM" then return nil,"STALE_CONFIRMATION" end
        local current,reason=now(client)
        if not current then return refused(client,pending,reason) end
        if current>=pending.deadline then return refused(client,pending,"QUOTE_EXPIRED") end
        if accepted~=true then return refused(client,pending,"CANCELLED") end
        local request={requestId=pending.request.requestId,destination=pending.request.destination,
            items=copy(pending.request.items),quoteCredential=pending.quote.credential}
        pending.phase,pending.purchase,pending.deadline="PURCHASE",request,current+C.PURCHASE_TIMEOUT_MS
        client.lastPurchase=copy(request) -- exact request available for idempotent reconciliation/retry
        local ok,dispatched=pcall(client.adapter.sendPurchase,copy(request))
        if (not ok or dispatched~=true) and client.pending==pending and pending.phase=="PURCHASE" then
            return refused(client,pending,ok and "PURCHASE_NOT_DISPATCHED" or "PURCHASE_DISPATCH_ERROR")
        end
        return true
    end
    local ok=pcall(client.adapter.confirm,copy(reply),respond)
    if not ok and client.pending==pending and pending.phase=="CONFIRM" then return refused(client,pending,"CONFIRMATION_ERROR") end
    return true
end
function C.receivePurchase(client,value)
    local reply,why=RLDealerPurchaseProtocol.reply(value); if not reply then return nil,why end
    local pending=client.pending
    if not pending or reply.requestId~=pending.request.requestId then return nil,"STALE_REPLY" end
    if pending.phase~="PURCHASE" then return nil,"WRONG_PHASE" end
    local ms; ms,why=now(client)
    if not ms then return refused(client,pending,why) end
    if ms>=pending.deadline then return refused(client,pending,"PURCHASE_TIMEOUT") end
    return finish(client,pending,reply)
end
function C.cancel(client)
    if not client.pending then return nil,"NO_PENDING_REQUEST" end
    if client.pending.phase=="PURCHASE" then return nil,"PURCHASE_ALREADY_DISPATCHED" end
    return refused(client,client.pending,"CANCELLED")
end
function C.tick(client)
    local pending=client.pending; if not pending then return false end
    local ms,why=now(client); if not ms then return refused(client,pending,why) end
    if ms>=pending.deadline then
        return refused(client,pending,pending.phase=="CONFIRM" and "QUOTE_EXPIRED" or pending.phase.."_TIMEOUT")
    end
    return false
end
