-- Separate dormant quote RPC. Service nil by default; no stock progression.
RLDealerQuoteEvent={}
local E=RLDealerQuoteEvent
local E_mt=Class(E,Event)
InitEventClass(E,"RLDealerQuoteEvent")
function E.isServer() return g_server~=nil end
function E.getService() return E.service end
function E.emptyNew() return Event.new(E_mt) end
function E.newRequest(value)
    local valid,why=RLDealerQuoteProtocol.request(value); if not valid then return nil,why end
    local self=E.emptyNew(); self.kind=RLDealerQuoteProtocol.REQUEST; self.payload=valid; return self
end
function E.newReply(value)
    local valid,why=RLDealerQuoteProtocol.reply(value); if not valid then return nil,why end
    local self=E.emptyNew(); self.kind=RLDealerQuoteProtocol.REPLY; self.payload=valid; return self
end
function E:writeStream(s,connection)
    local ok,why=RLDealerQuoteProtocol.write(s,self.kind,self.payload)
    if not ok then error("RLDealerQuoteEvent:"..tostring(why)) end
end
function E:readStream(s,connection)
    local message,why=RLDealerQuoteProtocol.read(s)
    if not message then self.errorReason=why; return end
    self.kind,self.payload=message.kind,message.payload; self:run(connection)
end
local function send(connection,reply)
    if type(connection.sendEvent)=="function" then connection:sendEvent(E.newReply(reply)) end
end
function E:run(connection)
    local P=RLDealerQuoteProtocol
    if not connection or type(connection.getIsServer)~="function" then return nil,"INVALID_CONNECTION" end
    local remoteServer=connection:getIsServer(); local service=E.getService()
    if E.isServer() then
        if remoteServer or self.kind~=P.REQUEST then return nil,"WRONG_DIRECTION" end
        local request,why=P.request(self.payload)
        if not request then send(connection,P.rejected("",why)); return nil,why end
        if type(service)~="table" or type(service.authorize)~="function" or type(service.resolvePrincipal)~="function"
            or type(service.quote)~="function" then send(connection,P.rejected(request.requestId,"DEALER_V2_DISABLED")); return nil,"DEALER_V2_DISABLED" end
        local ok,allowed,reason=pcall(service.authorize,connection,request.destination)
        if not ok or allowed~=true then
            why=ok and (reason or "NO_PERMISSION") or "AUTHORIZATION_ERROR"
            send(connection,P.rejected(request.requestId,why)); return nil,why
        end
        local resolved,principal=pcall(service.resolvePrincipal,connection)
        if not resolved or type(principal)~="string" or #principal==0 or #principal>4096 then
            send(connection,P.rejected(request.requestId,"INVALID_PRINCIPAL")); return nil,"INVALID_PRINCIPAL"
        end
        local executed,quote,quoteReason=pcall(service.quote,request,principal,connection)
        if not executed then quote=nil; quoteReason="QUOTE_SERVICE_ERROR" end
        local reply=P.fromQuote(quote,request,principal,quoteReason)
        send(connection,reply); return reply
    end
    if not remoteServer or self.kind~=P.REPLY then return nil,"WRONG_DIRECTION" end
    local reply,why=P.reply(self.payload); if not reply then return nil,why end
    if type(service)=="table" and type(service.onReply)=="function" then
        local ok=pcall(service.onReply,reply); if not ok then return nil,"REPLY_CONSUMER_ERROR" end
    end
    return reply
end
