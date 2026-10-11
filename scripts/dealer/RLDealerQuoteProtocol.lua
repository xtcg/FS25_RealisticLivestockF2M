-- Independent quote RPC codec. No animals, client prices, principal or growth calls.
RLDealerQuoteProtocol = {}
local P=RLDealerQuoteProtocol
P.VERSION,P.REQUEST,P.REPLY,P.MAX_TTL_MS=1,1,2,15000
local function text(v,empty) return type(v)=="string" and (empty or #v>0) and #v<=4096 end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function fields(v,allowed)
    if type(v)~="table" or getmetatable(v)~=nil then return false end
    for k in pairs(v) do if not allowed[k] then return false end end
    return true
end
function P.request(value)
    if not fields(value,{requestId=true,destination=true,items=true}) then return nil,"MALFORMED_QUOTE_REQUEST" end
    local valid,why=RLDealerPurchaseProtocol.request({requestId=value.requestId,destination=value.destination,items=value.items,quoteCredential="quote"})
    if not valid then return nil,why end
    return {requestId=valid.requestId,destination=valid.destination,items=valid.items}
end
function P.reply(value)
    if not fields(value,{requestId=true,status=true,reason=true,credential=true,subtotal=true,transportFee=true,amount=true,ttlMs=true})
        or not text(value.requestId,true) or not text(value.reason,true) then return nil,"MALFORMED_QUOTE_REPLY" end
    if value.status=="REJECTED" then
        if #value.reason==0 or value.credential~=nil or value.subtotal~=nil or value.transportFee~=nil
            or value.amount~=nil or value.ttlMs~=nil then return nil,"MALFORMED_QUOTE_REPLY" end
        return {requestId=value.requestId,status="REJECTED",reason=value.reason}
    end
    if value.status~="QUOTED" or #value.requestId==0 or not text(value.credential)
        or not finite(value.subtotal) or value.subtotal<0 or not finite(value.transportFee) or value.transportFee<0
        or not finite(value.amount) or value.amount~=value.subtotal+value.transportFee
        or not finite(value.ttlMs) or value.ttlMs%1~=0 or value.ttlMs<1 or value.ttlMs>P.MAX_TTL_MS then return nil,"MALFORMED_QUOTE_REPLY" end
    return {requestId=value.requestId,status="QUOTED",reason=value.reason,credential=value.credential,
        subtotal=value.subtotal,transportFee=value.transportFee,amount=value.amount,ttlMs=value.ttlMs}
end
function P.rejected(id,reason)
    return {requestId=text(id,true) and id or "",status="REJECTED",reason=text(reason) and reason or "INTERNAL_ERROR"}
end
function P.fromQuote(quote,request,principal,reason)
    if not quote then return P.rejected(request.requestId,reason) end
    if type(quote)~="table" or quote.principal~=principal or quote.destination~=request.destination then
        return P.rejected(request.requestId,"INVALID_QUOTE_SERVICE_RESULT")
    end
    local selected=P.request({requestId=request.requestId,destination=quote.destination,items=quote.items})
    if not selected or #selected.items~=#request.items then return P.rejected(request.requestId,"INVALID_QUOTE_SERVICE_RESULT") end
    local expected={}; for _,item in ipairs(request.items) do expected[item.saleId]=item.revision end
    for _,item in ipairs(selected.items) do if expected[item.saleId]~=item.revision then return P.rejected(request.requestId,"INVALID_QUOTE_SERVICE_RESULT") end end
    local ttl=quote.ttlMs
    if ttl==nil and finite(quote.expiresMs) and finite(quote.issuedMs) then ttl=math.floor(quote.expiresMs-quote.issuedMs) end
    local reply=P.reply({requestId=request.requestId,status="QUOTED",reason="",credential=quote.credential,
        subtotal=quote.subtotal,transportFee=quote.transportFee,amount=quote.amount,ttlMs=ttl})
    return reply or P.rejected(request.requestId,"INVALID_QUOTE_SERVICE_RESULT")
end
function P.write(s,kind,value)
    local payload,why
    if kind==P.REQUEST then payload,why=P.request(value) elseif kind==P.REPLY then payload,why=P.reply(value) end
    if not payload then return nil,why or "UNKNOWN_QUOTE_MESSAGE_KIND" end
    streamWriteUIntN(s,P.VERSION,8); streamWriteUIntN(s,kind,2); streamWriteString(s,payload.requestId)
    if kind==P.REQUEST then
        streamWriteString(s,payload.destination); streamWriteUIntN(s,#payload.items,16)
        for _,item in ipairs(payload.items) do streamWriteString(s,item.saleId); streamWriteUIntN(s,item.revision,32) end
    else
        streamWriteString(s,payload.status); streamWriteString(s,payload.reason)
        if payload.status=="QUOTED" then
            streamWriteString(s,payload.credential)
            for _,key in ipairs({"subtotal","transportFee","amount"}) do streamWriteString(s,string.format("%.17g",payload[key])) end
            streamWriteUIntN(s,payload.ttlMs,16)
        end
    end
    return true
end
local function read(s)
    if streamReadUIntN(s,8)~=P.VERSION then return nil,"UNKNOWN_QUOTE_PROTOCOL_VERSION" end
    local kind=streamReadUIntN(s,2)
    if kind~=P.REQUEST and kind~=P.REPLY then return nil,"UNKNOWN_QUOTE_MESSAGE_KIND" end
    local value={requestId=streamReadString(s)}
    if not text(value.requestId,kind==P.REPLY) then return nil,"MALFORMED_REQUEST_ID" end
    if kind==P.REQUEST then
        value.destination=streamReadString(s); local count=streamReadUIntN(s,16)
        if type(count)~="number" or count%1~=0 or count<1 or count>RLDealerPurchaseProtocol.MAX_BATCH then return nil,"BATCH_LIMIT" end
        value.items={}; for i=1,count do value.items[i]={saleId=streamReadString(s),revision=streamReadUIntN(s,32)} end
        local request,why=P.request(value); if not request then return nil,why end
        return {kind=kind,payload=request}
    end
    value.status=streamReadString(s); value.reason=streamReadString(s)
    if value.status=="QUOTED" then
        value.credential=streamReadString(s)
        for _,key in ipairs({"subtotal","transportFee","amount"}) do
            local encoded=streamReadString(s)
            if type(encoded)~="string" or #encoded>64 then return nil,"MALFORMED_AMOUNT" end
            value[key]=tonumber(encoded)
        end
        value.ttlMs=streamReadUIntN(s,16)
    end
    local reply,why=P.reply(value); if not reply then return nil,why end
    return {kind=kind,payload=reply}
end
function P.read(s)
    local ok,result,why=pcall(read,s)
    if not ok then return nil,"MALFORMED_QUOTE_STREAM" end
    return result,why
end
