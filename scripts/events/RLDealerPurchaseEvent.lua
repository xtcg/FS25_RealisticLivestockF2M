-- Dormant independent request/reply Event. Existing AnimalBuyEvent is unchanged.
RLDealerPurchaseEvent = {}
local E = RLDealerPurchaseEvent
local E_mt = Class(E, Event)
InitEventClass(E, "RLDealerPurchaseEvent")
function E.isServer() return g_server~=nil end
function E.getService() return E.service end -- nil by default: purchases closed
function E.emptyNew() return Event.new(E_mt) end
function E.newRequest(request)
    local payload,why=RLDealerPurchaseProtocol.request(request)
    if not payload then return nil,why end
    local self=E.emptyNew(); self.kind=RLDealerPurchaseProtocol.REQUEST; self.payload=payload; return self
end
function E.newReply(reply)
    local payload,why=RLDealerPurchaseProtocol.reply(reply)
    if not payload then return nil,why end
    local self=E.emptyNew(); self.kind=RLDealerPurchaseProtocol.REPLY; self.payload=payload; return self
end
function E:writeStream(streamId,connection)
    local ok,why=RLDealerPurchaseProtocol.write(streamId,self.kind,self.payload)
    if not ok then error("RLDealerPurchaseEvent:"..tostring(why)) end
end
function E:readStream(streamId,connection)
    local message,why=RLDealerPurchaseProtocol.read(streamId)
    if not message then self.errorReason=why; return end
    self.kind,self.payload=message.kind,message.payload
    self:run(connection)
end
local function sendReply(connection,reply)
    if connection and type(connection.sendEvent)=="function" then
        connection:sendEvent(E.newReply(reply))
    end
end
function E:run(connection)
    local P=RLDealerPurchaseProtocol
    if not connection or type(connection.getIsServer)~="function" then return nil,"INVALID_CONNECTION" end
    local remoteServer=connection:getIsServer()
    local service=E.getService()
    if E.isServer() then
        if remoteServer or self.kind~=P.REQUEST then return nil,"WRONG_DIRECTION" end
        local request,why=P.request(self.payload)
        if not request then sendReply(connection,P.rejected("",why)); return nil,why end
        if type(service)~="table" or type(service.authorize)~="function" or type(service.execute)~="function" then
            sendReply(connection,P.rejected(request.requestId,"DEALER_V2_DISABLED")); return nil,"DEALER_V2_DISABLED"
        end
        -- Service MUST resolve connection permission + farm ownership. No client principal.
        local authorized,allowed,reason=pcall(service.authorize,connection,request.destination)
        if not authorized or allowed~=true then
            why=authorized and reason or "AUTHORIZATION_ERROR"
            sendReply(connection,P.rejected(request.requestId,why or "NO_PERMISSION")); return nil,why or "NO_PERMISSION"
        end
        local ok,result,executeReason=pcall(service.execute,connection,request)
        if not ok then result=nil; executeReason="SERVICE_ERROR" end
        local reply=P.fromResult(result,request.requestId,executeReason)
        -- Cross-request service replies would settle the wrong client watchdog.
        if reply.requestId~=request.requestId then reply=P.rejected(request.requestId,"INVALID_SERVICE_RESULT") end
        sendReply(connection,reply)
        return reply
    end
    if not remoteServer or self.kind~=P.REPLY then return nil,"WRONG_DIRECTION" end
    local reply,why=P.reply(self.payload); if not reply then return nil,why end
    if type(service)=="table" and type(service.onReply)=="function" then
        local ok=pcall(service.onReply,reply); if not ok then return nil,"REPLY_CONSUMER_ERROR" end
    end
    return reply
end
