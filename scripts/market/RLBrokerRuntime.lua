-- Server assembly for the first playable Broker scope. UI carries identities,
-- never prices. The existing Month/Quota/OrderService/Transaction own their data.
RLBrokerRuntime = {}
local B=RLBrokerRuntime
local D=RLMarketData
local P=RLBrokerCattlePolicy
local function copy(v) return assert(D.copy(v)) end
local function need(v,why) if not v then error(why or "BROKER_ASSEMBLY_FAILED",0) end return v end
local function otherChannelsReady()
    if (B.legacyDepth or 0)>0 then return false end
    for _,channel in pairs({trade=RLTradeCheckpoint,dealer=RLDealerCheckpoint}) do
        if channel.state=="RECOVERY_REQUIRED" or channel.pass~=nil or (channel.last and channel.last.status=="WRITTEN") then return false end
    end
    return true
end
function B.new(options)
    local m=options.mission
    local r={mission=m,state="STARTING",generation=0,sequence=0,busy=false,frozen=false,
        locks=RLMarketResourceLock.shared(),quota=RLBrokerQuota.new(),acquisition=RLAnimalAcquisition.new()}
    local now=options.nowMs or function() return g_time end
    local epoch=options.epoch
    local function blocked(why)
        r.state,r.reason="RECOVERY_REQUIRED",why
        if not r.assetRisk then r.frozen=false end
        return nil,why
    end
    function r:principal()
        return {userId="local",farmId=m:getFarmId()}
    end
    local function authorize(actor,req)
        return type(actor)=="table" and actor.userId=="local" and actor.farmId==m:getFarmId()
            and actor.farmId>0 and m:getIsServer() and m.missionDynamicInfo.isMultiplayer==false
            and m:getHasPlayerPermission("tradeAnimals") and req.transportMode=="PICKUP"
    end
    local function resolve(req,actor)
        if not authorize(actor,req) then return nil,"BROKER_PERMISSION_DENIED" end
        local source,animal,count
        count=0
        -- A key duplicated anywhere in the world cannot be sold by selecting
        -- the more convenient copy. Container IDs are independently unique.
        local sourceMatches=0
        for _,s in pairs(m.placeableSystem.placeables) do
            if s.uniqueId==req.sourceRef then sourceMatches=sourceMatches+1;source=s end
        end
        if sourceMatches~=1 or source:getOwnerFarmId()~=actor.farmId then return nil,"SOURCE_OWNER_OR_ID_CHANGED" end
        for _,system in ipairs({m.placeableSystem.placeables,m.vehicleSystem.vehicles}) do
            for _,s in pairs(system) do
                if s.getClusterSystem then
                    local cs=s:getClusterSystem()
                    for _,a in ipairs(cs and cs:getClusters() or {}) do
                        if RLTradeSourceAdapter.identityKey(a)==req.animalKey then
                            count=count+1;if s==source then animal=a end
                        end
                    end
                end
            end
        end
        if count~=1 or not animal then return nil,"ANIMAL_IDENTITY_NOT_UNIQUE" end
        return animal,source
    end
    local function prepare(plan,actor)
        local a,s=resolve(plan.request,actor)
        if not a then return nil,s end
        return RLBrokerSourceAdapter.prepare(s,plan.request.animalKey,{kind="PEN",sourceId=plan.request.sourceRef,
            farmId=actor.farmId,mission=m,channel="BROKER_PICKUP"})
    end
    local function capture(actor,req)
        local a,s=resolve(req,actor);if not a then return nil,s end
        local snap,why=RLMarketSnapshot.capture(a,{classRevision=P.CLASS_REVISION,traitMappingRevision=P.TRAIT_REVISION})
        if not snap then return nil,why end
        local supported=select(1,RLBrokerSourceAdapter.prepare(s,req.animalKey,{kind="PEN",sourceId=req.sourceRef,
            farmId=actor.farmId,mission=m,channel="BROKER_PICKUP"}))~=nil
        return snap,{PICKUP=supported,SELF_DELIVERY=false}
    end
    local function clock()
        local e=m.environment
        need(RLPlain.finite(e.currentYear) and RLPlain.finite(e.currentPeriod),"BROKER_CLOCK_UNAVAILABLE")
        return e.currentYear*12+e.currentPeriod-1
    end
    local monthStore=options.monthStore
    r.month=need(RLBrokerMonth.new({seed=options.lineage,generatorVersion=1,balance=options.balance,
        catalog=P.catalog(),store=monthStore}))
    function r:publish()
        if self.state=="RECOVERY_REQUIRED" then return nil,self.reason end
        local current,why=self.month:ensureCurrent(clock())
        if not current then return blocked(why) end
        local ok;ok,why=self.quota:initialize(current.monthId,current.quotaDefinition)
        if not ok then return blocked(why) end
        self.current=current
        return current
    end
    function r:ready()
        return self.state=="READY" and not self.frozen and not self.busy
            and self.tx:getStatus()=="READY" and RLAnimalIdentityCheckpoint.state=="READY" and otherChannelsReady()
    end
    r.orders=need(RLBrokerOrderService.new({serverEpoch=epoch,authorize=authorize,nowMs=now,
        readOrder=function(id) if not r:publish() then return nil,r.reason end return r.month:readOrder(id) end,
        capture=capture,previewReady=function(s) return P.supported(s) and r.state~="RECOVERY_REQUIRED" end,
        settlementReady=function(s,_,req) return P.supported(s) and req.transportMode=="PICKUP"
            and r.state=="READY" and not r.frozen and otherChannelsReady() end,
        eligibilityContext=function(actor,req,snap,_,location)
            local a=resolve(req,actor)
            local facts,caps=P.facts(a,snap)
            local animalResource=RLMarketResourceLock.resource("ANIMAL",snap.identityKey)
            local oldSale=RLLiveSale and RLLiveSale.ledger()
            local oldContract=RLContractTrade and RLContractTrade.store
            local oldLocked
            for _,ledger in pairs({sale=oldSale,contract=oldContract}) do
                oldLocked=oldLocked or ledger.recoveryRequired or ledger.locks["animal:"..snap.identityKey]
                    or ledger.locks["cash:farm"..string.format("%.0f",actor.farmId)]
            end
            return {permissionGranted=true,ownershipVerified=true,identityVerified=true,
                unlocked=not oldLocked and (r.locks:owner(animalResource)==nil or r.locks:owner(animalResource)==r.confirmingRequestId),
                orderOpen=true,sourceSupported=location.PICKUP,
                quota=r.quota:available(r.current.monthId,req.orderId,snap.speciesKey,snap.breedId),
                facts=facts or {},factCapabilities=caps or {},request=req}
        end,
        price=function(snap,order,context)
            local a=resolve(context.request,r:principal())
            if not a then return nil,"ANIMAL_UNAVAILABLE" end
            return P.quote(a,snap,m)
        end}))
    r.tx=need(RLBrokerTransaction.new({serverEpoch=epoch,authorize=authorize,orderService=r.orders,
        locks=r.locks,quota=r.quota,source=RLBrokerSourceAdapter,prepareSource=prepare,
        store=options.transactionStore,nowMs=now,
        ready=function() return r.state=="READY" and not r.frozen and otherChannelsReady() end,
        saveFence=function() return not r.frozen end,
        createMoneyAdapter=function(persist)
            return RLBrokerMoneyAdapter.new({mission=m,moneyType=MoneyType.SOLD_ANIMALS,persistReceipt=persist})
        end}))
    function r:restore(doc,proof)
        local ok,why=self.tx:restore(doc,proof)
        if not ok then return blocked(why) end
        if self.tx:getStatus()~="READY" then return blocked("BROKER_UNRESOLVED_TRANSACTION") end
        return true
    end
    function r:listOrders()
        local current,why=self:publish();if not current then return nil,why end
        local rows={}
        for _,o in ipairs(current.orders) do
            local row=copy(o)
            row.remaining=self.quota:available(current.monthId,o.orderId,o.speciesKey,o.requiredBreedId)
            rows[#rows+1]=row
        end
        return rows
    end
    function r:listAnimals()
        local rows={};local farm=m:getFarmId()
        for _,s in pairs(m.placeableSystem.placeables) do
            if s.getOwnerFarmId and s:getOwnerFarmId()==farm and type(s.uniqueId)=="string" and s.spec_husbandryAnimals and s.getClusterSystem then
                for _,a in ipairs(s:getClusterSystem():getClusters()) do
                    local sub=m.animalSystem:getSubTypeByIndex(a.subTypeIndex)
                    if sub and (sub.name=="COW_ANGUS" or sub.name=="BULL_ANGUS") then
                        local key=RLTradeSourceAdapter.identityKey(a)
                        if key then rows[#rows+1]={animalKey=key,sourceRef=s.uniqueId,
                            label=(s.getName and s:getName() or s.uniqueId).." / "..tostring(a.uniqueId),
                            ageMonths=RLGrowth.getContinuousAge(a),weightKg=a.weight} end
                    end
                end
            end
        end
        table.sort(rows,function(a,b) return a.sourceRef..a.animalKey<b.sourceRef..b.animalKey end)
        return rows
    end
    function r:preflight(req) return self.orders:preflight(self:principal(),req) end
    function r:preview(req)
        if not self:ready() then return nil,self.reason or "BROKER_INITIAL_SAVE_REQUIRED" end
        local credential,why,details=self.orders:preview(self:principal(),req)
        if not credential then return nil,why,details end
        self.sequence=self.sequence+1
        credential.requestId=need(RLBrokerTransaction.requestId(epoch,self.sequence))
        return credential
    end
    function r:confirm(quote)
        if self.busy then return nil,"BROKER_BUSY" end
        -- Replay lookup precedes the ready gate, even after the animal left.
        if self.tx:hasRequest(quote.requestId) then return self.tx:lookup(self:principal(),quote.requestId,quote.credential,quote.request) end
        if not self:ready() then return nil,self.reason or "BROKER_NOT_READY" end
        local previousRisk=self.assetRisk
        self.assetRisk=true;self.busy=true;self.confirmingRequestId=quote.requestId
        local ok,result,why=pcall(self.tx.confirm,self.tx,self:principal(),quote.requestId,quote.credential,quote.request)
        self.busy=false;self.confirmingRequestId=nil
        if ok and self.tx:getStatus()=="READY" and not self.tx:hasRequest(quote.requestId) then self.assetRisk=previousRisk end
        if not ok or self.tx:getStatus()~="READY" then blocked(ok and "BROKER_UNRESOLVED_TRANSACTION" or "BROKER_CONFIRM_ERROR") end
        return ok and result or nil,ok and why or self.reason
    end
    function r:monthDocument() return monthStore.read() end
    function r:block(why) return blocked(why) end
    return r
end
-- Legacy channels consult this before mutation. Dormant/multiplayer sessions
-- keep their current behavior. An uncertain Broker operation is never bypassed.
function B.mutationAllowed()
    if B.recoveryHold then return false end
    local r=B.current
    return r==nil or (not r.busy and not r.frozen and not (r.state=="RECOVERY_REQUIRED" and r.assetRisk))
end
-- These legacy entry points are synchronous and return at most three values.
-- Broker cannot enter through a money/event callback while another channel is
-- midway through its mutation, and the depth is restored even if it throws.
function B.guardLegacy(owner,method)
    if type(owner)~="table" or type(owner[method])~="function" then return end
    local original=owner[method]
    owner[method]=function(...)
        local m=g_currentMission
        if not B.current or not m or not m:getIsServer() then return original(...) end
        B.legacyDepth=(B.legacyDepth or 0)+1
        local ok,a,b,c=pcall(original,...)
        B.legacyDepth=B.legacyDepth-1
        if not ok then error(a,0) end
        return a,b,c
    end
end
