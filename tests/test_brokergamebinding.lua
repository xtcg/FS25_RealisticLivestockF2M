-- Exercise the production assembly, XML codec, live WAL, native checkpoint,
-- save callbacks and reload together. The fixture replaces engine XML I/O and
-- inventory inspection only; no payment, quota or recovery protocol is mocked.
loadMod("tests/marketsavefixture.lua")
loadMod("tests/brokerruntimefixture.lua")
loadMod("scripts/animal/RLAnimalIdentityRuntime.lua")
loadMod("scripts/market/RLBrokerHBSupport.lua")
loadMod("scripts/market/RLBrokerGameBinding.lua")
local G,D,I,R=RLBrokerGameBinding,RLMarketData,RLAnimalIdentity,RLAnimalIdentityRuntime
local nativeFactory=RLMarketSaveAdapter.new
local function setup()
    G.reset()
    local x=BrokerRuntimeFixture.setup()
    local w=MarketSaveFixture.new()
    -- Real XMLFile shapes over memory, including exact full serialized reads.
    XMLFile={loadIfExists=w.io.load,create=w.io.create};fileExists=w.io.exists
    copyFile=function(source,target) w.files[target]=assert(D.copy(w.files[source]));return true end
    setXMLString=function(xml,key,value) xml:setString(key,value) end
    getXMLNumOfAttributes=function(handle,root) local n=0;for _ in pairs(handle.doc.nodes[root] or {}) do n=n+1 end return n end
    getXMLAttributeName=function(handle,root,index) local names={};for name in pairs(handle.doc.nodes[root] or {}) do names[#names+1]=name end;table.sort(names);return names[index+1] end
    local load=XMLFile.loadIfExists
    XMLFile.loadIfExists=function(...)
        local xml=load(...);if xml then function xml:getHandle() return self end end;return xml
    end
    local create=XMLFile.create
    XMLFile.create=function(...)
        local xml=create(...);function xml:getHandle() return self end;return xml
    end
    RLMarketSaveAdapter.new=function(options)
        options.attributeNames=w.options.attributeNames
        return nativeFactory(options)
    end
    RLMarketNativeAnimals={fromMission=function() return w.options.inspectAnimals end}
    x.m.missionInfo={savegameDirectory="test-save"}
    RLMarketRuntime={getConfig=function() return {brokerBalance=BrokerDemandFixture.balance()} end}
    R.reset(true);R.lineage="Ltest";R.state="READY";R.ledger=assert(I.new("Ltest"));R.ledger.policy.mode=R.SHADOW
    R.ledger.generation=100
    RLAnimalIdentityCheckpoint={state="READY",lineage="Ltest",generation=100,last={status="COMMITTED"}}
    local function scan()
        local records={}
        for _,a in ipairs(x.s.system.animals) do records[#records+1]={farmId=a.farmId,uniqueId=a.uniqueId,country=a.birthday.country,type="COW"} end
        return {records=records,refs={},counters={},partial={},uncoveredHerds={}}
    end
    RLAnimalIdentityWorld={scan=scan}
    g_time=1000;Savegame={ERROR_OK=0}
    RLBrokerRuntime.current=nil;RLMarketResourceLock.instance=nil
    assert(G.start(x.m))
    x.r=RLBrokerRuntime.current
    function x.save(directory)
        directory=directory or "test-save"
        G.beginSave({savegameDirectory="test-save"})
        local p=assert(G.pass)
        for path in pairs(w.files) do
            if path:find("rm_RlBrokerLive_",1,true) or path:find("rm_RlMarket",1,true) then w.files[path]=nil end
        end
        RLAnimalIdentityCheckpoint.generation=RLAnimalIdentityCheckpoint.generation+1
        local gen=RLAnimalIdentityCheckpoint.generation
        local ledger=assert(R.exportLedger(gen))
        local marker=ledger.lineage..":"..gen
        -- As the real engine: create the whole cohort; the Broker writes only
        -- its own root markers, retaining complete native contents.
        for _,role in ipairs({"placeables","vehicles","farms"}) do
            local xml=assert(XMLFile.create("engine","test-save/"..role..".xml",role))
            xml:setString(role.."#"..RLMarketSaveAdapter.IDENTITY_MARKER,marker)
            if role=="placeables" then
                for n,a in ipairs(x.s.system.animals) do
                    xml:setString(role..".animal("..(n-1)..")#identityKey",RLTradeSourceAdapter.identityKey(a))
                end
            elseif role=="farms" then xml:setString(role.."#money",tostring(x.f.money)) end
            G.markNative(role,xml);assert(xml:save());xml:delete()
        end
        local system=assert(XMLFile.create("engine","test-save/rm_RlAnimalSystem.xml","rm_RlAnimalSystem"))
        system:setString("rm_RlAnimalSystem#"..RLMarketSaveAdapter.IDENTITY_MARKER,marker)
        G.observeIdentity("system",system);assert(system:save());system:delete()
        local owner=assert(XMLFile.create("identity","test-save/"..RLAnimalIdentityPersistence.FILENAME,RLAnimalIdentityPersistence.ROOT))
        assert(RLAnimalIdentityPersistence.writeLedger(owner,{schema=RLAnimalIdentityPersistence.SCHEMA,
            lineage=ledger.lineage,generation=gen,mode=R.mode,ledger=ledger,
            participants={placeables=true,vehicles=true,farms=true,animalSystem=true}}))
        G.observeIdentity("owner",owner);assert(owner:save());owner:delete()
        local career=assert(XMLFile.create("engine","test-save/careerSavegame.xml","careerSavegame"))
        career:setString("careerSavegame#"..RLMarketSaveAdapter.IDENTITY_MARKER,marker)
        assert(career:save());career:delete()
        if directory~="test-save" then
            local moved={};for path,doc in pairs(w.files) do moved[directory..path:sub(#"test-save"+1)]=doc end
            for path,doc in pairs(moved) do w.files[path]=doc end
        end
        G.completeSave({currentSavegame={savegameDirectory=directory}},0,directory)
        return p
    end
    return x,w
end
local x,w=setup()
check("broker game: new save browses demand but cannot transact",#x.r:listOrders()==1 and x.r.state=="SAVE_REQUIRED")
x.save()
check("broker game: native initial save opens settlement",x.r:ready() and x.r.generation==1 and G.pass==nil)
local req={orderId=x.r:listOrders()[1].orderId,animalKey=RLTradeSourceAdapter.identityKey(x.a),sourceRef=x.s.uniqueId,transportMode="PICKUP"}
local quote=assert(x.r:preview(req))
local result=assert(x.r:confirm(quote))
check("broker game: native WAL records real one-head delivery",result.status=="COMMITTED" and x.f.money==1987.5 and x.m.calls==1 and w.files["test-save/rm_RlBrokerLive_broker.xml"]~=nil)
x.save()
local paid=x.f.money
G.reset();assert(G.start(x.m));local loaded=RLBrokerRuntime.current
check("broker game: common native cohort restores paid quota without replay",loaded:ready() and loaded:listOrders()[1].remaining.breed==3 and x.f.money==paid and x.m.calls==1)
local original=assert(loaded.tx:lookup(loaded:principal(),quote.requestId,quote.credential,quote.request))
check("broker game: historical response retained with original binding",original.status=="COMMITTED" and original.historicalSettled~=nil)
local savedMonth=x.m.environment.currentPeriod
x.m.environment.currentPeriod=savedMonth+1
local future=assert(loaded:listOrders())[1].orderId
x.m.environment.currentPeriod=savedMonth
G.reset();assert(G.start(x.m));loaded=RLBrokerRuntime.current
check("broker game: unsaved month generation resumes saved date without reroll",loaded:ready() and loaded.current.absoluteMonth==13)
local cohort=assert(loaded.month:checkpointDocument())
check("broker game: checkpoint pins game month while retaining live future history",cohort.currentAbsoluteMonth==13 and cohort.months['14']==nil and G.stores.months.read().months['14']~=nil)
x.m.environment.currentPeriod=savedMonth+1
check("broker game: previously generated future demand is reused",loaded:listOrders()[1].orderId==future)
x.m.environment.currentPeriod=savedMonth
G.reset();assert(G.start(x.m));loaded=RLBrokerRuntime.current
-- A post-save delivery is durable in the WAL, but the native save still has
-- the earlier animal/wallet. Startup must preserve and reject that mismatch.
req.animalKey=RLTradeSourceAdapter.identityKey(x.b)
quote=assert(loaded:preview(req));assert(loaded:confirm(quote))
G.reset();local ok,why=pcall(G.start,x.m)
check("broker game: unsaved WAL cannot be treated as saved assets",not ok and tostring(why):find("BROKER_UNSAVED_OR_MIXED_TRANSACTION",1,true)~=nil)
x,w=setup();x.save("renamed-save")
check("broker game: engine staging rename verifies final paths",x.r:ready() and G.directory=="renamed-save")
x,w=setup();G.beginSave({savegameDirectory="test-save"})
ok,why=pcall(G.completeSave,nil,1,"test-save")
check("broker game: failed engine save keeps transaction fence closed",not ok and x.r.frozen and not x.r:ready())
x,w=setup();x.save()
req={orderId=x.r:listOrders()[1].orderId,animalKey=RLTradeSourceAdapter.identityKey(x.a),sourceRef=x.s.uniqueId,transportMode="PICKUP"}
quote=assert(x.r:preview(req));x.m.mode="PARTIAL";assert(x.r:confirm(quote))
local evidence=D.fingerprint(w.files['test-save/rm_RlBrokerLive_broker.xml'])
G.beginSave({savegameDirectory="recovery-stage"})
local career=assert(XMLFile.create("engine","recovery-stage/careerSavegame.xml","careerSavegame"))
G.finishSave({savegameDirectory="recovery-stage",xmlFile=career});assert(career:save());career:delete()
G.completeSave({currentSavegame={savegameDirectory="recovery-stage"}},0,"recovery-stage")
check("broker game: saving recovery retains opaque WAL and a closed marker",D.fingerprint(w.files['recovery-stage/rm_RlBrokerLive_broker.xml'])==evidence
    and w.files['recovery-stage/careerSavegame.xml'].nodes.careerSavegame[G.RECOVERY_MARKER]:sub(1,7)=="ASSETS:")
G.reset();x.m.missionInfo.savegameDirectory="recovery-stage"
local resumed=G.start(x.m)
check("broker game: another save cannot launder an unknown transaction",not resumed and RLBrokerRuntime.current.state=="RECOVERY_REQUIRED" and not RLBrokerRuntime.mutationAllowed() and x.m.calls==1)
RLMarketSaveAdapter.new=nativeFactory
G.reset()
