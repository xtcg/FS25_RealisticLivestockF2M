loadMod("scripts/dealer/RLDealerPurchaseProtocol.lua")
loadMod("scripts/dealer/RLDealerQuoteProtocol.lua")
loadMod("scripts/events/RLDealerQuoteEvent.lua")
local P,E=RLDealerQuoteProtocol,RLDealerQuoteEvent
local request={requestId="q1",destination="pen:1",items={{saleId="a",revision=1}}}
local quote={principal="u1",destination="pen:1",items=request.items,credential="epoch:1",subtotal=100,transportFee=5,amount=105,issuedMs=0,expiresMs=15000}
local sent={}; local client=makeConnection("u1",false,sent); local server=makeConnection("server",true,{})
E.isServer=function() return true end; E.service=nil
local event=assert(E.newRequest(request)); local value,why=event:run(client)
check("quote Event: default nil service explicitly disables endpoint",not value and why=="DEALER_V2_DISABLED" and sent[1].payload.reason==why)
local calls,principals=0,0
E.service={authorize=function() return false,"WRONG_FARM" end,resolvePrincipal=function() principals=principals+1; return "u1" end,
    quote=function() calls=calls+1; return quote end}
sent={}; client=makeConnection("u1",false,sent); event:run(client)
check("quote Event: authorization precedes identity resolution and quote",calls==0 and principals==0 and sent[1].payload.reason=="WRONG_FARM")
E.service.authorize=function() error("fault") end
sent={}; client=makeConnection("u1",false,sent); event:run(client)
check("quote Event: authorization exception refuses safely",calls==0 and sent[1].payload.reason=="AUTHORIZATION_ERROR")
E.service.authorize=function(conn,dest) return conn.user=="u1" and dest=="pen:1" end
E.service.resolvePrincipal=function(conn) principals=principals+1; return conn.user end
sent={}; client=makeConnection("u1",false,sent); event:run(client)
check("quote Event: server resolves actual connection principal and issues bound quote",calls==1 and sent[1].payload.status=="QUOTED" and sent[1].payload.requestId=="q1")
E.service.resolvePrincipal=function() return nil end
sent={}; client=makeConnection("u1",false,sent); event:run(client)
check("quote Event: missing server principal cannot issue quote",calls==1 and sent[1].payload.reason=="INVALID_PRINCIPAL")
E.service.resolvePrincipal=function() return "u1" end
E.service.quote=function() error("quote fault") end
sent={}; client=makeConnection("u1",false,sent); event:run(client)
check("quote Event: quote exception returns stable refusal",sent[1].payload.reason=="QUOTE_SERVICE_ERROR")
E.service.quote=function() return nil,"PHYSIOLOGY_NOT_CURRENT" end
sent={}; client=makeConnection("u1",false,sent); event:run(client)
check("quote Event: not-current physiology returns refusal without progression",sent[1].payload.reason=="PHYSIOLOGY_NOT_CURRENT")
local forged=E.emptyNew(); forged.kind=P.REQUEST; forged.payload={requestId="q1",destination="pen:1",items=request.items,price=1}
sent={}; client=makeConnection("u1",false,sent); forged:run(client)
check("quote Event: direct-run payload schema rejects client price",sent[1].payload.reason=="MALFORMED_QUOTE_REQUEST")
local reply=assert(E.newReply(P.fromQuote(quote,request,"u1")))
value,why=reply:run(client)
check("quote Event: server rejects client forged quote reply",not value and why=="WRONG_DIRECTION")
value,why=event:run(server)
check("quote Event: server peer cannot impersonate client request",not value and why=="WRONG_DIRECTION")
local consumed=0; E.isServer=function() return false end
E.service={onReply=function(q) consumed=consumed+1; assert(q.amount==105) end,quote=function() error("client authority") end}
value=reply:run(server)
check("quote Event: client consumes server quote only",value.amount==105 and consumed==1)
value,why=event:run(server)
check("quote Event: client never executes incoming quote request",not value and why=="WRONG_DIRECTION" and consumed==1)
value,why=reply:run(client)
check("quote Event: client rejects peer-originated authority reply",not value and why=="WRONG_DIRECTION" and consumed==1)
E.service.onReply=function() error("closed frame") end
value,why=reply:run(server)
check("quote Event: closed client consumer cannot throw through Event",not value and why=="REPLY_CONSUMER_ERROR")
-- Version-drop path reaches neither endpoint nor authority.
-- A whole frame of another version: version 99, a request with one item (read to its end, then dropped).
local reads={99,RLDealerQuoteProtocol.REQUEST,1,4}
streamReadUIntN=function() return table.remove(reads,1) end
local readString=streamReadString
streamReadString=function() return "x" end
local incoming=E.emptyNew(); incoming:readStream({},server)
streamReadString=readString
check("quote Event: unknown-version frame drops before consumer",incoming.errorReason=="UNKNOWN_QUOTE_PROTOCOL_VERSION")
