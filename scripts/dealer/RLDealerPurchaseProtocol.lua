-- Dealer request protocol is independent from configuration/listing/weight versions.
-- No Animal, client price, physiology, identity allocation or generation RNG crosses here.
RLDealerPurchaseProtocol = {}
local P = RLDealerPurchaseProtocol
P.VERSION = 1
P.MAX_BATCH = 1000
P.MAX_STRING = 4096
P.REQUEST = 1
P.REPLY = 2
local function integer(v, min, max) return type(v)=="number" and v==v and v%1==0 and v>=min and v<=max end
local function text(v, empty) return type(v)=="string" and (empty or #v>0) and #v<=P.MAX_STRING end
local function fields(t, allowed)
    if type(t)~="table" or getmetatable(t)~=nil then return false end
    for k in pairs(t) do if not allowed[k] then return false end end
    return true
end
local function dense(t, allowEmpty)
    if type(t)~="table" or getmetatable(t)~=nil or #t>P.MAX_BATCH or (not allowEmpty and #t==0) then return false end
    local n=0
    for k in pairs(t) do if not integer(k,1,#t) then return false end; n=n+1 end
    return n==#t
end
local function listCopy(t) local out={}; for i,v in ipairs(t) do out[i]=v end; return out end
function P.request(value)
    if not fields(value,{requestId=true,items=true,destination=true,quoteCredential=true}) or not text(value.requestId)
        or not text(value.destination) or not text(value.quoteCredential) or not dense(value.items) then return nil,"MALFORMED_REQUEST" end
    local out={requestId=value.requestId,destination=value.destination,quoteCredential=value.quoteCredential,items={}}
    local seen={}
    for i,item in ipairs(value.items) do
        if not fields(item,{saleId=true,revision=true}) or not text(item.saleId) or not integer(item.revision,1,4294967295)
            then return nil,"MALFORMED_ITEM" end
        if seen[item.saleId] then return nil,"DUPLICATE_SALE_ID" end
        seen[item.saleId]=true; out.items[i]={saleId=item.saleId,revision=item.revision}
    end
    return out
end
-- Stable reply shape: result for COMMITTED/ROLLED_BACK; error reason for REJECTED.
-- amount and transfer identities are authoritative server results, never request fields.
function P.reply(value)
    if not fields(value,{requestId=true,status=true,reason=true,amount=true,transferIds=true}) or not text(value.requestId,true)
        or not text(value.reason,true) then return nil,"MALFORMED_REPLY" end
    if value.status=="REJECTED" then
        if #value.reason==0 or value.amount~=nil or value.transferIds~=nil then return nil,"MALFORMED_REPLY" end
        return {requestId=value.requestId,status=value.status,reason=value.reason}
    end
    if (value.status~="COMMITTED" and value.status~="ROLLED_BACK") or #value.requestId==0 or type(value.amount)~="number"
        or value.amount~=value.amount or value.amount<0 or value.amount==math.huge or not dense(value.transferIds)
        then return nil,"MALFORMED_REPLY" end
    local seen={}
    for _,id in ipairs(value.transferIds) do if not text(id) or seen[id] then return nil,"MALFORMED_REPLY" end; seen[id]=true end
    return {requestId=value.requestId,status=value.status,reason=value.reason,amount=value.amount,transferIds=listCopy(value.transferIds)}
end
function P.rejected(requestId,reason)
    return {requestId=text(requestId,true) and requestId or "",status="REJECTED",reason=text(reason) and reason or "INTERNAL_ERROR"}
end
function P.fromResult(result,requestId,reason)
    if not result then return P.rejected(requestId,reason) end
    if type(result)~="table" then return P.rejected(requestId,"INVALID_SERVICE_RESULT") end
    local reply=P.reply({requestId=result.requestId,status=result.status,reason=reason or "",amount=result.amount,transferIds=result.transferIds})
    return reply or P.rejected(requestId,"INVALID_SERVICE_RESULT")
end
function P.write(streamId,kind,value)
    local payload,why
    if kind==P.REQUEST then payload,why=P.request(value) elseif kind==P.REPLY then payload,why=P.reply(value) end
    if not payload then return nil,why or "UNKNOWN_MESSAGE_KIND" end
    streamWriteUIntN(streamId,P.VERSION,8); streamWriteUIntN(streamId,kind,2)
    streamWriteString(streamId,payload.requestId)
    if kind==P.REQUEST then
        streamWriteString(streamId,payload.destination); streamWriteString(streamId,payload.quoteCredential)
        streamWriteUIntN(streamId,#payload.items,16)
        for _,item in ipairs(payload.items) do streamWriteString(streamId,item.saleId); streamWriteUIntN(streamId,item.revision,32) end
    else
        streamWriteString(streamId,payload.status); streamWriteString(streamId,payload.reason)
        if payload.status~="REJECTED" then
            streamWriteString(streamId,string.format("%.17g",payload.amount)); streamWriteUIntN(streamId,#payload.transferIds,16)
            for _,id in ipairs(payload.transferIds) do streamWriteString(streamId,id) end
        end
    end
    return true
end
local function read(streamId)
    if streamReadUIntN(streamId,8)~=P.VERSION then return nil,"UNKNOWN_PROTOCOL_VERSION" end
    local kind=streamReadUIntN(streamId,2)
    if kind~=P.REQUEST and kind~=P.REPLY then return nil,"UNKNOWN_MESSAGE_KIND" end
    local value={requestId=streamReadString(streamId)}
    if not text(value.requestId,kind==P.REPLY) then return nil,"MALFORMED_REQUEST_ID" end
    if kind==P.REQUEST then
        value.destination=streamReadString(streamId); value.quoteCredential=streamReadString(streamId)
        local n=streamReadUIntN(streamId,16)
        if not integer(n,1,P.MAX_BATCH) then return nil,"BATCH_LIMIT" end
        value.items={}
        for i=1,n do value.items[i]={saleId=streamReadString(streamId),revision=streamReadUIntN(streamId,32)} end
        local request,why=P.request(value); if not request then return nil,why end
        return {kind=kind,payload=request}
    end
    value.status=streamReadString(streamId); value.reason=streamReadString(streamId)
    if value.status~="REJECTED" then
        local amountText=streamReadString(streamId)
        if type(amountText)~="string" or #amountText>64 then return nil,"MALFORMED_AMOUNT" end
        value.amount=tonumber(amountText)
        local n=streamReadUIntN(streamId,16)
        if not integer(n,1,P.MAX_BATCH) then return nil,"BATCH_LIMIT" end
        value.transferIds={}; for i=1,n do value.transferIds[i]=streamReadString(streamId) end
    end
    local reply,why=P.reply(value); if not reply then return nil,why end
    return {kind=kind,payload=reply}
end
function P.read(streamId)
    local ok,result,why=pcall(read,streamId)
    if not ok then return nil,"MALFORMED_STREAM" end
    return result,why
end
