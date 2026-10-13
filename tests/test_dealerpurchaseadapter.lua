loadMod("tests/dealerreplaysim.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/animal/RLTradeSourceAdapter.lua")
loadMod("tests/fixtures/fs25_money.lua")
for _,name in ipairs({"SourceState","SourceReproduction","SourceOwnership","SourceAdapter","ObservedGrowth","OwnedStock",
    "Handoff","Clock","SourceFarm","ListingRegistry","Purchase","PurchaseProtocol","Quote","Destination","TargetAdapter",
    "MoneyAdapter","Persistence","StockService","Journal","PurchaseAdapter"}) do loadMod("scripts/dealer/RLDealer"..name..".lua") end
loadAnimalSection("local Animal_mt = Class(Animal)", "function Animal:delete()")
loadAnimalSection("function Animal:getSubTypeIndex", "function Animal:increaseAge")
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
Animal.getDefaultMarks=function() return {} end
Animal.isHorse=function() return false end
Animal.getNumAnimals=function() return 1 end
Animal.updateInput=function(self) self.input.food=0 end
Animal.updateOutput=function(self) self.output.milk=0 end
RLAnimalUtil={toKey=function(farm,id,country) return tostring(farm).."|"..tostring(id).."|"..tostring(country) end}
local P,A=RLDealerPurchase,RLDealerPurchaseAdapter
local counter=0
local function fixture(pregnant)
    counter=counter+1
    local system=g_currentMission.animalSystem
    local environment=g_currentMission.environment
    local seed=DealerReplaySim.seed("HOLSTEIN","female",1)
    local index=Economics.find(seed.subType.name)
    system.getSubTypeByName=function(_,name) local _,sub=Economics.find(name);return sub end
    system.getTypeIndexBySubTypeIndex=function(_,i) local sub=system:getSubTypeByIndex(i);return sub and sub.typeIndex end
    system.types={};environment.weather={temperatureUpdater={currentMin=20}}
    local history=DealerReplaySim.history(seed,pregnant and 20.25 or 8.5,pregnant and "NORMAL_PRODUCTION" or nil,
        pregnant and {{kind="CONCEPTION",atMonths=17.125,parity=1}} or nil)
    local replay=assert(RLDealerReplay.run(seed,history,{daysPerMonth=1,
        entry={breedingWeightRatio=0.55,profile={minRecoveryMonth=3}},pregnancySubTypes={[4]={seed.subType}}}))
    local record=assert(RLDealerSourceState.capture(replay,100))
    local animals={}
    for i=1,2 do
        local animal=Animal.new({age=-1,weight=35,health=100,gender="female",subTypeIndex=index,
            genetics=copy(seed.genetics),uniqueId="SOURCE-"..i,farmId="SOURCE-HERD"})
        for k,v in pairs(record.animal) do if k~="subTypeIndex" then animal[k]=copy(v) end end
        animal.birthday={day=12,month=2,year=2025,country=4,lastAgeMonth=10}
        if pregnant then
            local unborn=Animal.new({age=-1,weight=35,health=100,gender="female",subTypeIndex=index,
                genetics={metabolism=2.1,quality=2.25,productivity=1.8,fertility=0,health=0.9},uniqueId="FETUS-"..i,farmId="SOURCE-HERD"})
            unborn.motherId,unborn.fatherId=animal.uniqueId,"SIRE"
            animal.pregnancy={duration=10,expected={day=4,month=5,year=2027},pregnancies={unborn}}
        end
        animals[i]=animal
    end
    local owner=assert(RLDealerSourceReproduction.createOwner("OWNER",10,animals))
    if pregnant then
        for _,animal in ipairs(animals) do assert(RLDealerSourceReproduction.pinSire(owner,animal.uniqueId,
            {uniqueId="SIRE",farmId="SIRE-HERD",breed="HOLSTEIN",genetics=copy(seed.genetics)})) end
    end
    local stock=assert(RLDealerStockService.new("adapter-"..counter,100))
    stock.sourceOwners={OWNER=owner};stock.sourceBindings={};stock.sourceRecordsByOwner={OWNER={}};stock.observedChildren={}
    local items={}
    for i=1,2 do
        local id="source-"..i
        stock.farm.sources[id]=copy(record)
        stock.sourceBindings[id]={ownerId="OWNER",animalId=animals[i].uniqueId}
        stock.sourceRecordsByOwner.OWNER[animals[i].uniqueId]=copy(record)
        local row=assert(RLDealerListingRegistry.createDraft(stock.listings,{sourceId=id},"GROWING",100))
        row=assert(RLDealerListingRegistry.list(stock.listings,row.saleId,100))
        items[i]={saleId=row.saleId,revision=row.recordRevision}
    end
    local w={writes=0,calls=0,ms=10,permitted=true,capacity=true,source=animals,owner=owner,stock=stock}
    local cluster={animals={},clustersToAdd={},clustersToRemove={}}
    local dest={isServer=true,spec_husbandryAnimals={},getClusterSystem=function() return cluster end,
        getOwnerFarmId=function() return 1 end,getUniqueId=function() return "PERSISTENT-PEN" end}
    cluster.owner=dest
    function cluster:getClusters() return self.animals end
    function cluster:addPendingAddCluster(animal) self.clustersToAdd[animal]=true;if w.onAdd then w.onAdd(animal) end end
    function cluster:addPendingRemoveCluster(animal) self.clustersToRemove[animal]=true end
    function cluster:updateNow()
        local n=0
        for animal in pairs(self.clustersToAdd) do
            n=n+1
            if w.targetFault~="SILENT" and (w.targetFault~="PARTIAL" or n==1) then self.animals[#self.animals+1]=animal;animal.clusterSystem=self end
        end
        for i=#self.animals,1,-1 do local animal=self.animals[i];if self.clustersToRemove[animal] then table.remove(self.animals,i);animal.clusterSystem=nil end end
        self.clustersToAdd,self.clustersToRemove={},{}
        if w.afterFlush then w.afterFlush() end
    end
    w.dest,w.cluster=dest,cluster
    NetworkUtil={getObject=function(id) return id==17 and dest end,getObjectId=function() return 17 end}
    local connection={getIsServer=function() return false end}
    local farm=FarmMoney.newFarm(1,1000,{"newAnimalsCost"})
    local manager={getFarmById=function(_,id) return id==1 and farm end,getFarmForUniqueUserId=function() return farm end}
    g_farmManager=manager
    MoneyType={NEW_ANIMALS_COST={id=9,statistic="newAnimalsCost"}}
    MessageType={MONEY_CHANGED=5};MoneyChangeEvent={new=function(...) return {...} end}
    g_messageCenter={publish=function() if w.moneyListener then w.moneyListener() end end}
    local mission={animalSystem=system,environment=environment,getIsServer=function() return true end,getFarmId=function() return 1 end,
        getHasPlayerPermission=function() return w.permitted end,userManager={getUniqueUserIdByConnection=function() return "test-user" end},
        missionDynamicInfo={isMultiplayer=true},moneyChanges={},hud={addMoneyChange=function() end,showMoneyChange=function() end},
        addMoneyChange=FSBaseMissionMoney.addMoneyChange,broadcastNotifications=FSBaseMissionMoney.broadcastNotifications,broadcastEventToFarm=function() end}
    mission.addMoney=function(self,...)
        w.calls=w.calls+1
        if w.moneyFault=="THROW_BEFORE" then error("before money") end
        FSBaseMissionMoney.addMoney(self,...)
        if w.moneyFault=="THROW_AFTER" then error("after money") end
    end
    g_currentMission=mission;w.farm=farm
    local principal="farm:1:user:test-user"
    local quotes=assert(RLDealerQuote.new("adapter-quote-"..counter))
    local qa={isServer=function() return true end,authorize=function() return w.permitted end,currentClock=function() return stock.farm.clock.months end,
        monotonicMs=function() return w.ms end,readListing=function(id) return RLDealerListingRegistry.get(stock.listings,id) end,
        eligible=function() return true end,computeBuyPrice=function() return w.price or 100 end,computeTransportFee=function() return 0 end}
    local selected={destination="net:17",items=items}
    local quoted=assert(RLDealerQuote.issue(quotes,selected,principal,qa))
    local request={requestId="request-"..counter,destination="net:17",items=items,quoteCredential=quoted.credential}
    local journal=assert(RLDealerJournal.new("DLadapter-"..counter,"epoch-"..counter))
    local disk={}
    local storage={save=function(path,data) disk[path]=RLTradePersistence.canonical(data);return true end,
        load=function(path) local text=disk[path];return assert(RLTradePersistence.parse(text,RLDealerPersistence.LIMITS)),RLTradePersistence.checksum(text) end}
    local ctx={stock=stock,mission=mission,farmManager=manager,connection=connection,epoch="epoch-"..counter,
        quotes=quotes,quoteAdapter=qa,resolveSubType=function(name) local i,sub=Economics.find(name);return sub,i end,
        monotonicMs=function() return w.ms end,allOwners=function() return {dest} end,eligible=function() return true end,
        validateCapacity=function() return w.capacity end,persistBarrier=function(payload)
            w.writes=w.writes+1
            if w.onWrite then w.onWrite(w.writes,payload) end
            if w.failWrite==w.writes then return false end
            w.lastPayload=copy(payload)
            return RLDealerJournal.checkpoint(journal,"/save",payload.purchase,1,storage,payload.recovery)
        end}
    local adapter=assert(A.new(ctx));w.adapter,w.journal,w.context=adapter,journal,ctx
    return stock,adapter,w,request,principal
end
local stock,adapter,w,request,principal=fixture()
local random,clone=math.random,Animal.clone
math.random=function() error("purchase cannot draw") end;Animal.clone=function() error("unsafe normal clone") end
local result,why=P.execute(stock.purchase,request,principal,adapter)
math.random,Animal.clone=random,clone
check("purchase adapter: real source/target/money composition commits complete batch",result and result.status=="COMMITTED" and #w.owner.animals==0 and #w.cluster.animals==2 and w.farm.money==800 and w.calls==1)
check("purchase adapter: handoff uses true cloned identities and exact physiology without normal constructor RNG",#w.cluster.animals==2
    and w.cluster.animals[1]~=w.source[1] and w.cluster.animals[1].uniqueId==w.source[1].uniqueId
    and w.cluster.animals[1].rlGrowth.birthWeightKg==w.source[1].rlGrowth.birthWeightKg and w.cluster.animals[1].rlHistoryReplay==nil
    and w.cluster.animals[1].farmId=="SOURCE-HERD")
check("purchase adapter: committed listings lose source bindings and durable WAL retains terminal receipts",result and next(stock.farm.sources)==nil and next(stock.sourceBindings)==nil
    and w.lastPayload.purchase.records[request.requestId].stage=="COMMITTED" and w.lastPayload.recovery.money.records["dealer:"..request.requestId].status=="APPLIED")
local replay=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: request replay never repeats queue or money effects",replay and replay.status=="COMMITTED" and w.calls==1 and #w.cluster.animals==2)
for _,fault in ipairs({"SILENT","PARTIAL"}) do
    local s,a,x,r,p=fixture();x.targetFault=fault
    local outcome=P.execute(s.purchase,r,p,a)
    check("purchase adapter: "..fault.." target failure restores exact source objects without debit",outcome and outcome.status=="ROLLED_BACK"
        and #x.cluster.animals==0 and #x.owner.animals==2 and x.owner.animals[1]==x.source[1] and x.farm.money==1000 and x.calls==0
        and a.money.locks[1]==nil and a.money.records["dealer:"..r.requestId].cancelled)
end
-- A slow durable write after the debit (a large save) outlasts the lock: the paid sale still commits.
stock,adapter,w,request,principal=fixture()
w.onWrite=function() if w.calls>=1 and not w.jumped then w.jumped=true;w.ms=w.ms+RLDealerPurchase.LOCK_MS+1 end end
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: a lock that expires during the post-debit checkpoint still commits the paid sale",w.jumped
    and result and result.status=="COMMITTED" and not stock.recoveryRequired and w.farm.money==800 and #w.cluster.animals==2 and w.calls==1)
-- Before the debit the lock still guards the reservation: expiry there rolls back with no money moved.
stock,adapter,w,request,principal=fixture()
w.onWrite=function(_,payload)
    if w.calls>0 or w.jumped or payload.listings==nil then return end
    for _,record in pairs(payload.listings.records) do
        if record.state=="RESERVED" then w.jumped=true;w.ms=w.ms+RLDealerPurchase.LOCK_MS+1;return end
    end
end
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: a lock that expires before the debit rolls back, no money moved",w.jumped
    and result and result.status=="ROLLED_BACK" and w.farm.money==1000 and w.calls==0 and #w.owner.animals==2)
stock,adapter,w,request,principal=fixture();w.moneyFault="THROW_BEFORE"
result=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: proven no-effect money throw compensates target/source and releases token",result and result.status=="ROLLED_BACK"
    and #w.owner.animals==2 and #w.cluster.animals==0 and w.farm.money==1000 and adapter.money.locks[1]==nil and w.calls==1)
local cancelled=RLDealerMoneyAdapter.apply(adapter.money,"dealer:"..request.requestId)
check("purchase adapter: cancelled money token cannot later debit",cancelled.status=="NOT_APPLIED" and w.calls==1)
local restoredMoney=assert(RLDealerMoneyAdapter.restore(RLDealerMoneyAdapter.export(adapter.money),{epoch="reload-cancelled",mission=w.context.mission,farmManager=w.context.farmManager}))
local twiceRestored=RLDealerMoneyAdapter.restore(RLDealerMoneyAdapter.export(restoredMoney),{epoch="reload-again",mission=w.context.mission,farmManager=w.context.farmManager})
check("purchase adapter: cancelled token survives repeated receipt restore without regaining debit authority",twiceRestored
    and RLDealerMoneyAdapter.apply(twiceRestored,"dealer:"..request.requestId).status=="UNKNOWN" and w.calls==1)
stock,adapter,w,request,principal=fixture();w.moneyFault="THROW_AFTER"
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: partial/throw-after debit never claims a complete refund or rollback",not result and why=="RECOVERY_REQUIRED"
    and stock.recoveryRequired and stock.purchase.recoveryRequired and w.farm.money==800 and #w.cluster.animals==2 and #w.owner.animals==0 and w.calls==1)
stock,adapter,w,request,principal=fixture();w.failWrite=1
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: uncertain first PREPARED barrier closes before every asset effect",not result and why=="CHECKPOINT_UNCERTAIN"
    and stock.recoveryRequired and #w.owner.animals==2 and #w.cluster.animals==0 and w.calls==0)
stock,adapter,w,request,principal=fixture();w.onWrite=function(n) if n==2 then w.permitted=false end end
result=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: permission loss in durable callback safely aborts prepared batch",result and result.status=="ROLLED_BACK"
    and #w.owner.animals==2 and #w.cluster.animals==0 and w.calls==0)
stock,adapter,w,request,principal=fixture();w.onAdd=function()
    local nested=P.execute(stock.purchase,{requestId="nested",destination=request.destination,items=request.items,quoteCredential=request.quoteCredential},principal,adapter)
    w.nested=nested
end
result=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: engine callbacks cannot reenter authoritative batch effects",result and result.status=="COMMITTED" and w.nested==nil and w.calls==1)
stock,adapter,w,request,principal=fixture();w.onWrite=function(n) if n==3 then w.capacity=false end end
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: capacity mutation in reservation barrier aborts before source or target effects",result and result.status=="ROLLED_BACK"
    and #w.owner.animals==2 and #w.cluster.animals==0 and w.calls==0)
stock,adapter,w,request,principal=fixture();w.afterFlush=function() w.permitted=false end
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: permission loss inside target callbacks compensates before money debit",result and result.status=="ROLLED_BACK"
    and #w.owner.animals==2 and #w.cluster.animals==0 and w.calls==0)
stock,adapter,w,request,principal=fixture();w.onWrite=function(n) if n==3 then w.ms=5011 end end
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: real-time lock expiry in reservation barrier prevents asset effects",result and result.status=="ROLLED_BACK"
    and #w.owner.animals==2 and #w.cluster.animals==0 and w.calls==0)
stock,adapter,w,request,principal=fixture();w.afterFlush=function() w.price=110 end
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: price mutation inside target callback compensates before debit",result and result.status=="ROLLED_BACK"
    and #w.owner.animals==2 and #w.cluster.animals==0 and w.calls==0)
stock,adapter,w,request,principal=fixture();w.onWrite=function(n) if n==3 then w.farm.money=999 end end
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: foreign money change at reservation barrier stops before source detach",not result and why=="RECOVERY_REQUIRED"
    and #w.owner.animals==2 and #w.cluster.animals==0 and w.calls==0 and w.farm.money==999)
stock,adapter,w,request,principal=fixture();w.onWrite=function(n) if n==3 then
    local replacement=copy(w.dest);NetworkUtil.getObject=function() return replacement end
end end
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: recycled network reference cannot redirect a prepared purchase",result and result.status=="ROLLED_BACK"
    and #w.owner.animals==2 and #w.cluster.animals==0 and w.calls==0)
stock,adapter,w,request,principal=fixture();w.failWrite=5
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: uncertain post-debit receipt preserves actual assets and never refunds blindly",not result and why=="RECOVERY_REQUIRED"
    and stock.recoveryRequired and #w.owner.animals==0 and #w.cluster.animals==2 and w.farm.money==800 and w.calls==1)
stock,adapter,w,request,principal=fixture();w.failWrite=6
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: uncertain terminal barrier keeps completed effects under recovery ownership",not result and why=="CHECKPOINT_UNCERTAIN"
    and stock.recoveryRequired and #w.owner.animals==0 and #w.cluster.animals==2 and w.farm.money==800 and w.calls==1)
stock,adapter,w,request,principal=fixture(true)
random,clone=math.random,Animal.clone
math.random=function() error("pregnant transfer cannot redraw") end;Animal.clone=function() error("shared pregnancy clone") end
result,why=P.execute(stock.purchase,request,principal,adapter)
math.random,Animal.clone=random,clone
check("purchase adapter: pregnant dam batch carries exact real fetuses and outlier genes without RNG",result and result.status=="COMMITTED"
    and w.cluster.animals[1].pregnancy.pregnancies[1].uniqueId==w.source[1].pregnancy.pregnancies[1].uniqueId
    and w.cluster.animals[1].pregnancy.pregnancies[1].genetics.fertility==0
    and w.cluster.animals[1].pregnancy.pregnancies[1].genetics.quality==2.25
    and w.cluster.animals[1].pregnancy~=w.source[1].pregnancy
    and w.cluster.animals[1].pregnancy.pregnancies[1]~=w.source[1].pregnancy.pregnancies[1])
stock,adapter,w,request,principal=fixture();w.moneyListener=function() w.stock.farm.clock.months=101 end
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: source clock mutation in money listeners prevents false terminal commit",not result and why=="RECOVERY_REQUIRED"
    and stock.recoveryRequired and #w.cluster.animals==2 and w.farm.money==800 and w.calls==1)
stock,adapter,w,request,principal=fixture();w.moneyListener=function() w.permitted=false end
result,why=P.execute(stock.purchase,request,principal,adapter)
check("purchase adapter: post-debit permission loss remains owned recovery rather than fabricated rollback",not result and why=="RECOVERY_REQUIRED"
    and stock.recoveryRequired and #w.cluster.animals==2 and w.farm.money==800 and w.calls==1)
check("purchase adapter: constructor requires every authoritative engine capability",not A.new({stock=stock,quotes={},quoteAdapter={},epoch="x"}))

-- SV-01 (dealer v2 T4): buy, save, reload, look up the old order, buy again. Nothing is paid twice, the
-- earlier order is answered from its saved receipt and needs no money record in the new session.
do
    local D = RLDealerPersistence
    local stock1, adapter1, w1, _, principal1 = fixture()
    local sent = {}
    local ids = {}
    for _, row in pairs(stock1.listings.records) do ids[#ids + 1] = { saleId = row.saleId, revision = row.recordRevision } end
    table.sort(ids, function(a, b) return a.saleId < b.saleId end)
    local function quoteAndBuy(stock, adapterCtx, adapterObj, item, requestId)
        local q = assert(RLDealerQuote.issue(adapterCtx.quotes, { destination = "net:17", items = { item } }, principal1, adapterCtx.quoteAdapter))
        local request = { requestId = requestId, destination = "net:17", items = { item }, quoteCredential = q.credential }
        sent[requestId] = request
        return P.execute(stock.purchase, request, principal1, adapterObj)
    end
    local first = quoteAndBuy(stock1, w1.context, adapter1, ids[1], "order-1")
    check("SV-01 first order commits and pays once", first and first.status == "COMMITTED" and w1.farm.money == 900 and w1.calls == 1)

    -- the engine save: three participants, the stock document, the career commit mark
    local parts = {}
    for _, role in ipairs({ "placeables", "vehicles", "farms" }) do parts[role] = assert(D.marker("DLsv1", 1, { role = role, content = role })) end
    local snapshot = assert(RLDealerStockService.buildSnapshot(stock1, { lineage = "DLsv1", generation = 1, parentGeneration = 0, checkpointId = "DLsv1:1" }, parts))
    local xml = { values = {} }
    function xml:setString(k, v) self.values[k] = v end
    function xml:getString(k) return self.values[k] end
    function xml:iterate(prefix, fn)
        local i = 0
        while self.values[prefix .. "(" .. i .. ")#v"] do fn(i, prefix .. "(" .. i .. ")"); i = i + 1 end
    end
    local written, digest = D.writeDocument(xml, snapshot, parts)
    local career = assert(D.commitMarker(snapshot, digest))
    local resolver = function(name) local i, sub = Economics.find(name); return sub, i end
    local doc, why = D.readDocument(xml, parts, resolver, career, { isServer = true })
    check("SV-01 the saved dealer document verifies against its participants and the career mark", written and doc and doc.state == "VERIFIED", tostring(why))
    check("SV-01 the verified load is not a recovery: terminal receipts need no reconciliation", doc and doc.restored.recoveryRequired == false)

    -- reload: a new store from the document, a new money epoch, the same world
    local stock2 = assert(RLDealerStockService.fromVerifiedDocument(doc))
    check("SV-01 the loaded store has no money record and no recovery flag", stock2.money == nil and stock2.moneyEvidence == nil and not stock2.recoveryRequired
        and not stock2.purchase.recoveryRequired and stock2.purchase.records["order-1"].stage == "COMMITTED")
    local ctx2 = {}
    for k, v in pairs(w1.context) do ctx2[k] = v end
    ctx2.stock, ctx2.epoch = stock2, "epoch-after-reload"
    ctx2.quotes = assert(RLDealerQuote.new("quote-after-reload"))
    ctx2.quoteAdapter = {}
    for k, v in pairs(w1.context.quoteAdapter) do ctx2.quoteAdapter[k] = v end
    ctx2.quoteAdapter.currentClock = function() return stock2.farm.clock.months end
    ctx2.quoteAdapter.readListing = function(id) return RLDealerListingRegistry.get(stock2.listings, id) end
    local journal2 = assert(RLDealerJournal.new("DLsv1", "epoch-after-reload"))
    local disk2 = {}
    local storage2 = { save = function(path, data) disk2[path] = RLTradePersistence.canonical(data); return true end,
        load = function(path) local text = disk2[path]; return assert(RLTradePersistence.parse(text, RLDealerPersistence.LIMITS)), RLTradePersistence.checksum(text) end }
    ctx2.persistBarrier = function(payload) return RLDealerJournal.checkpoint(journal2, "/save", payload.purchase, 1, storage2, payload.recovery) end
    -- the world after the reload: the first order's animal is in the pen, the second source is still the dealer's
    local adapter2 = assert(A.new(ctx2))
    w1.moneyBefore, w1.callsBefore = w1.farm.money, w1.calls
    local old = P.execute(stock2.purchase, sent["order-1"], principal1, adapter2)
    check("SV-01 the old order is answered from its saved receipt: same result, no money touched", old and old.status == "COMMITTED" and w1.farm.money == w1.moneyBefore and w1.calls == w1.callsBefore)
    local second = quoteAndBuy(stock2, ctx2, adapter2, ids[2], "order-2")
    check("SV-01 a new order after the reload commits and pays exactly once more", second and second.status == "COMMITTED" and w1.farm.money == 800 and w1.calls == w1.callsBefore + 1
        and #w1.cluster.animals == 2)
    local again = P.execute(stock2.purchase, sent["order-2"], principal1, adapter2)
    local changed = P.execute(stock2.purchase, { requestId = "order-2", destination = "net:17", items = { ids[1] }, quoteCredential = sent["order-2"].quoteCredential }, principal1, adapter2)
    check("SV-01 retrying the new order returns its result without a third debit", again and again.status == "COMMITTED" and w1.farm.money == 800)
    check("SV-01 the same order id with another payload is refused", changed == nil)
    check("SV-01 the new session never replays the old money record: its money store holds only order-2", adapter2.money.records["dealer:order-1"] == nil
        and adapter2.money.records["dealer:order-2"] ~= nil)
end

-- T4 service facade over the assembled parts
do
    loadMod("scripts/dealer/RLDealerAssembly.lua")
    loadMod("scripts/dealer/RLDealerService.lua")
    local stock, _, w, _, principal = fixture()
    stock.money = nil
    local items = {}
    for _, row in pairs(stock.listings.records) do items[#items + 1] = { saleId = row.saleId, revision = row.recordRevision } end
    table.sort(items, function(a, b) return a.saleId < b.saleId end)
    local realCapacity = RLDealerCapacity
    RLDealerCapacity = { new = function() return function() return w.capacity end end }
    local disk = {}
    local storage = { save = function(path, data) disk[path] = RLTradePersistence.canonical(data); return true end,
        load = function(path) local text = disk[path]; return assert(RLTradePersistence.parse(text, RLDealerPersistence.LIMITS)), RLTradePersistence.checksum(text) end }
    local parts, why = RLDealerAssembly.assemble({ mission = g_currentMission, farmManager = g_farmManager, stock = stock, epoch = "svc-epoch",
        directory = "/save", lineage = "DLsvc", generation = function() return 1 end, monotonicMs = function() return w.ms end,
        resolveSubType = function(name) local i, sub = Economics.find(name); return sub, i end, eligible = function() return true end,
        allOwners = function() return { w.dest } end, priceOf = function() return 100 end, feeOf = function() return 5 end, storage = storage })
    RLDealerCapacity = realCapacity
    check("T4 assembly builds the parts over an owned store", parts ~= nil, tostring(why))
    local open = true
    parts.gate = function() if open then return true end return false, "DEALER_V2_DISABLED" end
    local service = assert(RLDealerService.new(parts))
    local connection = { getIsServer = function() return false end }
    check("T4 authorize passes the gate, the permission and the farm's ownership of the destination", service.authorize(connection, "net:17") == true)
    local who = service.resolvePrincipal(connection)
    check("T4 the principal comes from the connection", who == principal)
    local quote = service.quote({ destination = "net:17", items = items }, who, connection)
    check("T4 a quote adds the shop's body price and transport fee per animal (2 x 100 + 2 x 5)", quote and quote.subtotal == 200 and quote.transportFee == 10 and quote.amount == 210)
    local request = { requestId = "svc-order", destination = "net:17", items = items, quoteCredential = quote.credential }
    local result = service.execute(connection, request)
    check("T4 execute runs the guarded purchase for the connection's principal", result and result.status == "COMMITTED" and w.farm.money == 790 and #w.cluster.animals == 2)
    local saved = service.lookup(connection, "svc-order")
    check("T4 lookup returns the owner's saved result", saved and saved.status == "COMMITTED" and saved.amount == 210)
    check("T4 another principal sees nothing of the order", select(2, RLDealerPurchase.lookup(stock.purchase, "svc-order", "farm:2:user:other")) == "UNKNOWN_REQUEST"
        and select(2, service.lookup(connection, "never-sent")) == "UNKNOWN_REQUEST")
    check("T4 the connection is not left on the shared purchase context", parts.purchaseContext.connection == nil)
    open = false
    check("T4 a closed gate refuses authorize, quote and execute with its reason", select(2, service.authorize(connection, "net:17")) == "DEALER_V2_DISABLED"
        and select(2, service.quote({ destination = "net:17", items = items }, who, connection)) == "DEALER_V2_DISABLED"
        and select(2, service.execute(connection, request)) == "DEALER_V2_DISABLED")
    open = true
    stock.recoveryRequired = true
    check("T4 a store in recovery is never ready", select(2, service.authorize(connection, "net:17")) == "RECOVERY_REQUIRED" and service.lookup(connection, "svc-order").status == "COMMITTED")
    check("T4 assembly refuses a legacy (not owned) store", select(2, RLDealerAssembly.assemble({ stock = RLDealerStockService.new("legacy-x", 100) })) == "OWNED_STORE_REQUIRED")
end
