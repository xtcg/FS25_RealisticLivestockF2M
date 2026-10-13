loadMod("scripts/dealer/RLDealerPurchaseProtocol.lua")
loadMod("scripts/dealer/RLDealerQuoteProtocol.lua")
local P=RLDealerQuoteProtocol
local function request() return {requestId="q1",destination="pen:1",items={{saleId="b",revision=2},{saleId="a",revision=4294967295}}} end
local function quote() return {requestId="q1",status="QUOTED",reason="",credential="epoch:1",subtotal=123.4567891234567,transportFee=11,amount=134.4567891234567,ttlMs=15000} end
local function stream(values) return {values=values or {},cursor=1} end
local function put(s,v) s.values[#s.values+1]=v end
local function take(s) local v=s.values[s.cursor]; s.cursor=s.cursor+1; assert(v~=nil); return v end
streamWriteUIntN=function(s,v,b) assert(type(v)=="number" and v%1==0 and v>=0 and v<2^b); put(s,v) end
streamReadUIntN=function(s,b) local v=take(s); assert(type(v)=="number" and v%1==0 and v>=0 and v<2^b); return v end
streamWriteString=function(s,v) assert(type(v)=="string"); put(s,v) end
streamReadString=function(s) local v=take(s); assert(type(v)=="string"); return v end
local s=stream(); assert(P.write(s,P.REQUEST,request())); local message=P.read(s)
check("quote RPC: request roundtrip preserves references and uint32 revisions",message.payload.items[2].revision==4294967295 and message.payload.destination=="pen:1")
s=stream(); local q=quote(); q.amount=q.subtotal+q.transportFee; assert(P.write(s,P.REPLY,q)); message=P.read(s)
check("quote RPC: authoritative totals preserve binary precision",message.payload.amount==q.amount and message.payload.subtotal==q.subtotal and message.payload.ttlMs==15000)
s=stream(); assert(P.write(s,P.REPLY,P.rejected("q1","STALE_REVISION"))); message=P.read(s)
check("quote RPC: stable refusal roundtrip",message.payload.reason=="STALE_REVISION" and message.payload.requestId=="q1")
for _,key in ipairs({"animal","animals","price","amount","principal","farmId","quoteCredential"}) do
    local r=request(); r[key]=1
    check("quote RPC: request forbids "..key,not P.request(r))
end
local r=request(); r.items[1].weight=500
check("quote RPC: item physiology payload rejects",not P.request(r))
r=request(); r.items[2].saleId="b"
check("quote RPC: duplicate sale IDs reject",not P.request(r))
r=request(); r.items={}
check("quote RPC: empty batch rejects",not P.request(r))
-- Events carry no length: a rejected event is still read to its end, so the stream stays aligned.
s=stream({99,P.REQUEST,"q1","pen:1",1,"sale1",4,"NEXT"}); message,why=P.read(s)
check("quote RPC: unknown independent version is read to its end, then rejected",
    not message and why=="UNKNOWN_QUOTE_PROTOCOL_VERSION" and s.values[s.cursor]=="NEXT")
s=stream({1,3}); message,why=P.read(s)
check("quote RPC: unknown route kind rejects",not message and why=="UNKNOWN_QUOTE_MESSAGE_KIND")
local over={1,P.REQUEST,"q1","pen:1",1001}
for i=1,1001 do over[#over+1]="s"..i; over[#over+1]=1 end
over[#over+1]="NEXT"
s=stream(over); message,why=P.read(s)
check("quote RPC: oversized count reads every record, then rejects (stream aligned)",
    not message and why=="BATCH_LIMIT" and s.values[s.cursor]=="NEXT")
s=stream({1,P.REQUEST}); message,why=P.read(s)
check("quote RPC: truncated frame returns stable error",not message and why=="MALFORMED_QUOTE_STREAM")
for _,case in ipairs({{"sum",function(v) v.amount=v.amount+1 end},{"nan",function(v) v.amount=0/0 end},
    {"ttl",function(v) v.ttlMs=15001 end},{"expired",function(v) v.ttlMs=0 end},{"fractional ttl",function(v) v.ttlMs=1.5 end},
    {"credential",function(v) v.credential="" end},{"negative fee",function(v) v.transportFee=-1 end},{"extra field",function(v) v.principal="u1" end}}) do
    q=quote(); q.amount=q.subtotal+q.transportFee; case[2](q)
    check("quote RPC: malformed "..case[1].." reply rejects",not P.reply(q))
end
local authority={principal="u1",destination="pen:1",items=request().items,credential="epoch:1",subtotal=100,transportFee=5,amount=105,issuedMs=2,expiresMs=15002}
local reply=P.fromQuote(authority,request(),"u1")
check("quote RPC: private quote projects only public authority fields",reply.status=="QUOTED" and reply.amount==105 and not reply.principal and not reply.items and reply.ttlMs==15000)
authority.principal="u2"
check("quote RPC: service cannot issue quote for wrong principal",P.fromQuote(authority,request(),"u1").reason=="INVALID_QUOTE_SERVICE_RESULT")
authority.principal="u1"; authority.items[1].revision=3
check("quote RPC: service cannot bind quote to wrong revision",P.fromQuote(authority,request(),"u1").reason=="INVALID_QUOTE_SERVICE_RESULT")
check("quote RPC: scalar quote service result becomes refusal",P.fromQuote(7,request(),"u1").reason=="INVALID_QUOTE_SERVICE_RESULT")
local rng=math.random; math.random=function() error("no RNG") end
local safe=pcall(function() local wire=stream(); assert(P.write(wire,P.REQUEST,request())); assert(P.read(wire)) end)
math.random=rng
check("quote RPC: read/write never consumes RNG",safe)
