-- Dealer v2 T5: the browsing RPC (pages, detail, destinations, order status). Dormant: no service, no answer.
-- The service answers from the server's last tick; a request never advances stock or draws a number.
RLDealerCatalogEvent = {}
local E = RLDealerCatalogEvent
local E_mt = Class(E, Event)
InitEventClass(E, "RLDealerCatalogEvent")
function E.isServer() return g_server ~= nil end
function E.getService() return E.service end
function E.emptyNew() return Event.new(E_mt) end
function E.new(kind, direction, requestId, payload)
    local valid, why = RLDealerCatalogProtocol.validate(kind, direction, payload)
    if not valid or type(requestId) ~= "string" or #requestId == 0 then return nil, why or "MALFORMED_REQUEST_ID" end
    local self = E.emptyNew()
    self.kind, self.direction, self.requestId, self.payload = kind, direction, requestId, payload
    return self
end
function E:writeStream(s, connection)
    local ok, why = RLDealerCatalogProtocol.write(s, self.kind, self.direction, self.requestId, self.payload)
    if not ok then error("RLDealerCatalogEvent:" .. tostring(why)) end
end
function E:readStream(s, connection)
    local message, why = RLDealerCatalogProtocol.read(s)
    if not message then self.errorReason = why; return end
    self.kind, self.direction, self.requestId, self.payload = message.kind, message.direction, message.requestId, message.payload
    self:run(connection)
end
local function send(connection, kind, requestId, payload, request)
    -- An order-status answer always names the order it was asked about, whatever produced it.
    if kind == RLDealerCatalogProtocol.ORDER and type(request) == "table" then payload.orderId = request.orderId end
    local reply = E.new(kind, RLDealerCatalogProtocol.REPLY, requestId, payload)
    if reply ~= nil and type(connection.sendEvent) == "function" then connection:sendEvent(reply) end
end
function E:run(connection)
    local P = RLDealerCatalogProtocol
    if not connection or type(connection.getIsServer) ~= "function" then return nil, "INVALID_CONNECTION" end
    local remoteServer = connection:getIsServer()
    local service = E.getService()
    if E.isServer() then
        if remoteServer or self.direction ~= P.REQUEST then return nil, "WRONG_DIRECTION" end
        if type(service) ~= "table" or type(service.browse) ~= "function" then
            send(connection, self.kind, self.requestId, { status = "REJECTED", reason = "DEALER_V2_DISABLED" }, self.payload)
            return nil, "DEALER_V2_DISABLED"
        end
        local ok, payload = pcall(service.browse, connection, self.kind, self.payload)
        if not ok or type(payload) ~= "table" then payload = { status = "REJECTED", reason = "SERVICE_ERROR" } end
        if not P.validate(self.kind, P.REPLY, payload) then payload = { status = "REJECTED", reason = "INVALID_SERVICE_RESULT" } end
        send(connection, self.kind, self.requestId, payload, self.payload)
        return payload
    end
    if not remoteServer or self.direction ~= P.REPLY then return nil, "WRONG_DIRECTION" end
    if type(service) == "table" and type(service.onCatalogReply) == "function" then
        local ok = pcall(service.onCatalogReply, self.kind, self.requestId, self.payload)
        if not ok then return nil, "REPLY_CONSUMER_ERROR" end
    end
    return self.payload
end
