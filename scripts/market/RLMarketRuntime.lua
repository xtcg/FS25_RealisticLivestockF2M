-- Lifecycle and capability boundaries. Loading this framework does not install
-- price hooks, start Dealer stock, publish demand, mutate animals or pay money.
RLMarketRuntime = {}
local R = RLMarketRuntime
local Log = RmLogging.getLogger("RLRM")
local modDirectory = g_currentModDirectory
function R.reset()
    if RLMarketEnginePrice~=nil then RLMarketEnginePrice.clear() end
    R.configState, R.requestedMode, R.mode = {}, "legacy", "legacy"
    R.state, R.reason = "DORMANT", nil
end
function R.loadConfig(deps)
    deps = deps or {}
    local handles = {}
    local function load()
        local exists = deps.fileExists or fileExists
        local open = deps.openXml or function(path) return XMLFile.loadIfExists("rlLivestockMarket", path) end
        local root = deps.modDirectory or modDirectory
        if type(root) ~= "string" or type(exists) ~= "function" then return nil, "MARKET_CONFIG_ENVIRONMENT_MISSING" end
        local profile = deps.profilePath
        if profile == nil and getUserProfileAppPath ~= nil then profile = getUserProfileAppPath() end
        local override = type(profile) == "string" and profile .. RLMarketConfig.SETTINGS_PATH or nil
        local selected = override ~= nil and exists(override) and override or root .. "xml/livestockMarket.xml"
        if not exists(selected) then return nil, "MARKET_CONFIG_MISSING" end
        local xml = open(selected)
        if xml == nil then return nil, "MARKET_CONFIG_UNREADABLE" end
        handles[#handles + 1] = xml
        local parsed, reason = RLMarketConfig.reload(R.configState, xml)
        if parsed == nil then return nil, reason end
        R.requestedMode = parsed.mode
        -- A config expresses intent. Runtime evidence must independently permit
        -- a scope before any future price or settlement adapter can use it.
        R.mode, R.state, R.reason = "legacy", "LOADED", nil
        return true
    end
    local ok, result, reason = pcall(load)
    for _, xml in ipairs(handles) do if type(xml.delete) == "function" then pcall(xml.delete, xml) end end
    if not ok then result, reason = nil, "MARKET_CONFIG_LOAD_ERROR" end
    if result == nil then
        R.reason = reason
        if R.configState.current == nil then R.state, R.mode = "UNAVAILABLE", "legacy" end
        return false, reason
    end
    return true
end
function R.marketPricingReady(scope)
    return false, "MARKET_PRICING_NOT_VERIFIED"
end
function R.brokerPreviewReady(scope)
    return false, "BROKER_PREVIEW_NOT_IMPLEMENTED"
end
function R.brokerSettlementReady(scope, transportMode)
    return false, "BROKER_SETTLEMENT_NOT_VERIFIED"
end
function R.getConfig()
    if R.configState.current == nil then return nil, R.reason or "MARKET_CONFIG_NOT_LOADED" end
    return RLMarketData.copy(R.configState.current)
end
function R:loadMap()
    R.reset()
    local ok, reason = R.loadConfig()
    if not ok then Log:warning("Market framework remains on legacy prices: %s", tostring(reason)) end
end
function R:deleteMap()
    -- No asset evidence is owned by this loader. Persistent channel stores must
    -- implement their own checkpoint lifecycle before they can be registered.
    R.reset()
end
function R.install()
    if R.installed then return true end
    if type(addModEventListener) ~= "function" then return false, "NO_MOD_LIFECYCLE" end
    addModEventListener(R)
    R.installed = true
    return true
end
R.reset()
