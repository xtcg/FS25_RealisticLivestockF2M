loadMod("scripts/dealer/RLDealerPurchaseProtocol.lua")
loadMod("scripts/events/RLDealerPurchaseEvent.lua")
local P,E=RLDealerPurchaseProtocol,RLDealerPurchaseEvent
local function request()
    return {requestId="q1",items={{saleId="sale1",revision=4294967295},{saleId="sale2",revision=2}},
        destination="husbandry:network-ref-17",quoteCredential="server-bound-quote"}
end
local function stream(values) return {values=values or {},cursor=1} end
local function put(s,value) s.values[#s.values+1]=value end
local function take(s) local v=s.values[s.cursor]; s.cursor=s.cursor+1; if v==nil then error("truncated") end; return v end
streamWriteUIntN=function(s,v,bits) assert(type(v)=="number" and v%1==0 and v>=0 and v<2^bits); put(s,v) end
streamReadUIntN=function(s,bits) local v=take(s); assert(type(v)=="number" and v%1==0 and v>=0 and v<2^bits); return v end
streamWriteString=function(s,v) assert(type(v)=="string"); put(s,v) end
streamReadString=function(s) local v=take(s); assert(type(v)=="string"); return v end
local s=stream(); assert(P.write(s,P.REQUEST,request())); local message=P.read(s)
check("dealer protocol: stable refs, IDs and uint32 revisions roundtrip",message.kind==P.REQUEST and message.payload.destination==request().destination
    and message.payload.items[1].revision==4294967295 and message.payload.quoteCredential==request().quoteCredential)
for _,field in ipairs({"animals","animal","price","buyPrice","transportPrice","principal","farmId","version"}) do
    local r=request(); r[field]=1
    local value,why=P.request(r)
    check("dealer protocol: request rejects client "..field,value==nil and why=="MALFORMED_REQUEST")
end
local r=request(); r.items[1].animal={weight=500}
check("dealer protocol: item object payload is forbidden",not P.request(r))
r=request(); r.items[2].saleId="sale1"
local _,why=P.request(r)
check("dealer protocol: duplicate sale IDs reject",why=="DUPLICATE_SALE_ID")
r=request(); r.items[1].revision=4294967296
check("dealer protocol: revision overflow rejects",not P.request(r))
r=request(); r.items[1].revision=0/0
check("dealer protocol: NaN revisions reject",not P.request(r))
r=request(); r.destination={getNetworkId=function() return 17 end}
check("dealer protocol: destination must be stable reference string",not P.request(r))
r=request(); r.quoteCredential=string.rep("x",P.MAX_STRING+1)
check("dealer protocol: overlong credential rejects",not P.request(r))
r=request(); r.items={}
check("dealer protocol: empty batch rejects",not P.request(r))
r=request(); r.items[4]={saleId="s4",revision=1}
check("dealer protocol: sparse batch rejects",not P.request(r))
r=request(); r.items={}
for i=1,P.MAX_BATCH+1 do r.items[i]={saleId="s"..i,revision=1} end
check("dealer protocol: batch count cap rejects before encoding",not P.request(r))
-- Events carry no length: a rejected event is still read to its end, so the stream stays aligned for what follows.
s=stream({99,P.REQUEST,"q1","pen","quote",1,"sale1",4,"NEXT"}); message,why=P.read(s)
check("dealer protocol: unknown version is read to its end, then rejected (the next value is untouched)",
    not message and why=="UNKNOWN_PROTOCOL_VERSION" and s.values[s.cursor]=="NEXT")
s=stream({P.VERSION,3}); message,why=P.read(s)
check("dealer protocol: unknown kind rejects",not message and why=="UNKNOWN_MESSAGE_KIND")
local over={P.VERSION,P.REQUEST,"q1","pen","quote",P.MAX_BATCH+1}
for i=1,P.MAX_BATCH+1 do over[#over+1]="s"..i; over[#over+1]=1 end
over[#over+1]="NEXT"
s=stream(over); message,why=P.read(s)
check("dealer protocol: count over the cap reads every item, then rejects (stream aligned)",
    not message and why=="BATCH_LIMIT" and s.values[s.cursor]=="NEXT")
s=stream({P.VERSION,P.REQUEST,"","pen","quote",1,"sale1",4,"NEXT"}); message,why=P.read(s)
check("dealer protocol: a bad request id is rejected after the whole event is read",
    not message and why=="MALFORMED_REQUEST_ID" and s.values[s.cursor]=="NEXT")
s=stream({P.VERSION,P.REQUEST,"q1"}); message,why=P.read(s)
check("dealer protocol: truncated stream returns stable error",not message and why=="MALFORMED_STREAM")
local result={requestId="q1",status="COMMITTED",amount=123.4567891234567,transferIds={"a","b"}}
local reply=P.fromResult(result,"q1")
s=stream(); assert(P.write(s,P.REPLY,reply)); message=P.read(s)
check("dealer protocol: authoritative amount preserves binary precision",message.payload.amount==result.amount and message.payload.status=="COMMITTED")
s=stream(); assert(P.write(s,P.REPLY,P.rejected("q1","STALE_QUOTE"))); message=P.read(s)
check("dealer protocol: stable refusal roundtrip",message.payload.status=="REJECTED" and message.payload.reason=="STALE_QUOTE")
check("dealer protocol: scalar service result becomes safe rejection",P.fromResult(7,"q1").reason=="INVALID_SERVICE_RESULT")
local calls=0; local sent={}; local client=makeConnection("user1",false,sent); local server=makeConnection("server",true,{})
E.isServer=function() return true end; E.service=nil
local event=assert(E.newRequest(request())); local value,reason=event:run(client)
check("dealer event: no service leaves v2 closed with explicit reply",not value and reason=="DEALER_V2_DISABLED" and sent[1].payload.reason==reason)
E.service={authorize=function(c,d) return false,"WRONG_FARM" end,execute=function() calls=calls+1 end}
sent={}; client=makeConnection("user1",false,sent); event:run(client)
check("dealer event: farm authorization rejects before execute",calls==0 and sent[1].payload.reason=="WRONG_FARM")
E.service.authorize=function() error("authorization fault") end
sent={}; client=makeConnection("user1",false,sent); event:run(client)
check("dealer event: authorization exception becomes stable refusal",calls==0 and sent[1].payload.reason=="AUTHORIZATION_ERROR")
E.service.authorize=function(c,d) return c.user=="user1" and d==request().destination end
E.service.execute=function(c,r) calls=calls+1; return result end
sent={}; client=makeConnection("user1",false,sent); event:run(client)
check("dealer event: authorized connection reaches service and receives stable result",calls==1 and sent[1].payload.status=="COMMITTED")
E.service.execute=function() return {requestId="other",status="COMMITTED",amount=1,transferIds={"a"}} end
sent={}; client=makeConnection("user1",false,sent); event:run(client)
check("dealer event: service cannot settle a different request",sent[1].payload.requestId=="q1" and sent[1].payload.reason=="INVALID_SERVICE_RESULT")
E.service.execute=function() error("service fault") end
sent={}; client=makeConnection("user1",false,sent); event:run(client)
check("dealer event: service exception returns stable refusal",sent[1].payload.reason=="SERVICE_ERROR")
local forged=E.emptyNew(); forged.kind=P.REQUEST; forged.payload=request(); forged.payload.price=1
sent={}; client=makeConnection("user1",false,sent); forged:run(client)
check("dealer event: direct run validates schema as well as stream decode",sent[1].payload.reason=="MALFORMED_REQUEST")
local replyEvent=assert(E.newReply(reply)); value,reason=replyEvent:run(client)
check("dealer event: server rejects forged reply direction",not value and reason=="WRONG_DIRECTION")
value,reason=event:run(server)
check("dealer event: server does not treat server peer as client requester",not value and reason=="WRONG_DIRECTION")
local consumed=0
E.isServer=function() return false end
E.service={onReply=function(v) consumed=consumed+1; assert(v.status=="COMMITTED") end,execute=function() error("client mutation") end}
value=replyEvent:run(server)
check("dealer event: client consumes authoritative reply only",value.status=="COMMITTED" and consumed==1)
value,reason=event:run(server)
check("dealer event: client never executes incoming request",not value and reason=="WRONG_DIRECTION" and consumed==1)
value,reason=replyEvent:run(client)
check("dealer event: client rejects reply from a client peer",not value and reason=="WRONG_DIRECTION" and consumed==1)
E.isServer=function() return true end; E.service={authorize=function() return true end,execute=function() calls=calls+1; return result end}
local before=calls
local malformed=E.emptyNew(); malformed:readStream(stream({99,P.REQUEST,"q1","pen","quote",1,"sale1",4}),client)
check("dealer event: malformed stream never invokes service",malformed.errorReason=="UNKNOWN_PROTOCOL_VERSION" and calls==before)
s=stream(); assert(E.newRequest(request())):writeStream(s,client)
local received=E.emptyNew(); received:readStream(s,client)
check("dealer event: decoded valid request runs one authorized service operation",calls==before+1)
-- Protocol reads and constructors have no physiology/generation entry points.
local rng=math.random; math.random=function() error("RNG must not run") end
local safe=pcall(function() local wire=stream(); assert(P.write(wire,P.REQUEST,request())); assert(P.read(wire)); assert(E.newRequest(request())) end)
math.random=rng
check("dealer protocol: read/write/construct consume no RNG",safe)
