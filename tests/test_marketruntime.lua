loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLMarketCurve.lua")
loadMod("scripts/market/RLMarketConfig.lua")
loadMod("scripts/market/RLMarketRuntime.lua")
local R = RLMarketRuntime
local deletes, reads = 0, {}
local function open(path)
    reads[#reads+1] = path
    local xml = assert(loadXMLFileFromDisk(REPO .. "xml/livestockMarket.xml"))
    function xml:delete() deletes=deletes+1 end
    return xml
end
local deps = { modDirectory=REPO, profilePath="/profile/", fileExists=function(path) return path==REPO.."xml/livestockMarket.xml" end, openXml=open }
check("market lifecycle: config loads without channel enable", R.loadConfig(deps) and R.mode=="legacy" and R.state=="LOADED")
check("market lifecycle: xml closed and builtin selected",deletes==1 and reads[1]==REPO.."xml/livestockMarket.xml")
local cfg = assert(R.getConfig()); local revision=cfg.revision
cfg.mode="market"
check("market lifecycle: callers cannot mutate stored config",R.getConfig().mode=="legacy")
deps.fileExists=function() return true end
deps.openXml=function(path)
    reads[#reads+1]=path
    return {getString=function() return "invalid" end,delete=function() deletes=deletes+1 end}
end
local ok=R.loadConfig(deps)
check("market lifecycle: invalid override is not silently replaced by builtin",not ok
    and reads[#reads]=="/profile/modSettings/FS25_RealisticLivestockRM/livestockMarket.xml")
check("market lifecycle: failed reload keeps previous valid config",R.getConfig().revision==revision and R.mode=="legacy" and deletes==2)
check("market lifecycle: readiness domains stay separate and closed",not R.marketPricingReady({speciesKey="COW"})
    and not R.brokerPreviewReady({speciesKey="COW"}) and not R.brokerSettlementReady({speciesKey="COW"},"PICKUP"))
local listeners=0
addModEventListener=function(value) assert(value==R);listeners=listeners+1 end
check("market lifecycle: installs once",R.install() and R.install() and listeners==1)
R:deleteMap()
check("market lifecycle: unload resets config and mode",R.getConfig()==nil and R.mode=="legacy" and R.state=="DORMANT")
local h=assert(io.open(REPO.."scripts/main.lua","r"));local main=h:read("*a");h:close()
local last=0
for _, name in ipairs({"RLMarketData","RLMarketSchema","RLMarketMoney","RLMarketCurve","RLMarketConfig","RLMarketSpecies","RLMarketSnapshot","RLAnimalValueProvider","RLLegacyPriceAdapter","RLMarketMath","RLDealerPricePolicy",
    "RLBrokerConditionPackage","RLMarketCommodityValue","RLMarketCattleValue","RLMarketPigValue","RLMarketSheepValue","RLMarketValueAdapter","RLMarketProviders","RLMarketDealerQuote","RLMarketPriceService","RLMarketEnginePrice",
    "RLMarketResourceLock","RLAnimalAcquisition","RLBrokerEligibility","RLBrokerQuota","RLBrokerDemand","RLBrokerMonth","RLBrokerPricePolicy","RLBrokerOrderService","RLBrokerPublicRoute","RLBrokerSourceAdapter","RLBrokerMoneyAdapter","RLBrokerTransaction","RLBrokerPersistence","RLBrokerNativeStorage","RLMarketCheckpoint","RLMarketSaveAdapter","RLMarketRuntime"}) do
    local pos=assert(main:find('scripts/market/'..name..'.lua',1,true))
    check("market lifecycle: source order "..name,pos>last);last=pos
end
check("market lifecycle: no source-time pricing hook",not main:find("Animal.getSellPrice = RLMarket",1,true))
-- Execute the actual market source list, not a duplicate handwritten loader.
-- Pure definitions must be loadable before a mission/store is configured.
local previousSellPrice = Animal and Animal.getSellPrice
for path in main:gmatch('source%(modDirectory %.%. "(scripts/market/[^"]+%.lua)"%)') do
    if not path:find("RLMarketRuntime.lua",1,true) then loadMod(path) end
end
check("market lifecycle: complete main market module list loads without starting services",type(RLBrokerTransaction.new)=="function" and type(RLMarketCheckpoint.new)=="function" and type(RLMarketDealerQuote.new)=="function")
check("market lifecycle: definitions do not replace legacy prices or register another listener",(Animal and Animal.getSellPrice)==previousSellPrice and listeners==1)
check("market lifecycle: loading all pure modules keeps every admission gate closed",R.mode=="legacy" and not R.marketPricingReady({}) and not R.brokerPreviewReady({}) and not R.brokerSettlementReady({},"PICKUP"))
