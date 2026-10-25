-- Native lifecycle/save integration. No replay of payments or animal creation.
RLBrokerGameBinding = {}
local G=RLBrokerGameBinding
local D=RLMarketData
local P=RLBrokerCattlePolicy
G.RECOVERY_MARKER="rlBrokerRecovery"
local function need(v,why) if not v then error(why or "BROKER_GAME_BINDING_FAILED",0) end return v end
local function same(a,b) return D.fingerprint(a)==D.fingerprint(b) end
local function recoveryMarker(dir)
    local xml=XMLFile.loadIfExists("rlBrokerRecoveryRead",dir.."/careerSavegame.xml")
    if not xml then return nil end
    local marker=xml:getString("careerSavegame#"..G.RECOVERY_MARKER)
    xml:delete();return marker
end
local function carryEvidence(from,to)
    if not from or from==to then return end
    for _,name in ipairs({"rm_RlMarketIdentity.xml","rm_RlMarketAcquisition.xml","rm_RlMarketBroker.xml",
        "rm_RlMarketMonths.xml","rm_RlBrokerLive_broker.xml","rm_RlBrokerLive_months.xml"}) do
        for _,suffix in ipairs({"",".staging"}) do
            local source,target=from.."/"..name..suffix,to.."/"..name..suffix
            if fileExists(source) then need(copyFile(source,target,true)==true,"BROKER_RECOVERY_EVIDENCE_COPY_FAILED") end
        end
    end
end
local function archivePresent(dir)
    for _,name in ipairs({"rm_RlMarketIdentity.xml","rm_RlMarketAcquisition.xml","rm_RlMarketBroker.xml","rm_RlMarketMonths.xml"}) do
        if fileExists(dir.."/"..name) or fileExists(dir.."/"..name..".staging") then return true end
    end
    local xml=XMLFile.loadIfExists("rlBrokerPresence",dir.."/careerSavegame.xml")
    if xml then
        local marker=xml:getString("careerSavegame#"..RLMarketSaveAdapter.CAREER_MARKER)
        xml:delete();return marker~=nil
    end
    return false
end
local function newStores(dir,lineage)
    local validators={broker=RLBrokerTransaction.validateDocument,months=function(doc)
        local probe=RLBrokerMonth.new({seed=lineage,generatorVersion=1,balance=G.balance,catalog=P.catalog(),
            store={read=function() return doc end,write=function() return false end}})
        local current=probe and probe:ensureCurrent(doc.currentAbsoluteMonth)
        return current~=nil
    end}
    local native=need(RLBrokerNativeStorage.new({validatePayload=function(doc)
        return doc.kind=="BROKER_TRANSACTIONS" and validators.broker(doc) or
            doc.kind=="BROKER_MONTH_HISTORY" and validators.months(doc)
    end}))
    local stores={}
    for _,role in ipairs({"broker","months"}) do
        stores[role]=need(RLBrokerPersistence.newStore(native,{path=dir.."/rm_RlBrokerLive_"..role..".xml",
            kind=role=="broker" and "WAL" or "MONTHS",lineage=lineage,generation=0,
            checkpointId="BROKER_LIVE:"..role,validatePayload=validators[role]}))
    end
    return stores
end
local function adapter(dir,r)
    local inspect=need(RLMarketNativeAnimals.fromMission(r.mission,{trustedCompanion=RLBrokerHBSupport.trustedCompanion}))
    return need(RLMarketSaveAdapter.new({directory=dir,lineage=G.lineage,
        monthSeedFingerprint=need(D.fingerprint(G.lineage)),inspectAnimals=inspect}))
end
local function checkpoint(a,r)
    local hooks={}
    for _,name in ipairs({"transactions","sources","identity"}) do
        hooks[name]={freeze=function() r.frozen=true;return not r.busy end,
            release=function() return true end}
    end
    return need(RLMarketCheckpoint.new(a.storage,a.contracts,hooks))
end
function G.start(m)
    if not m:getIsServer() or not m.missionDynamicInfo or m.missionDynamicInfo.isMultiplayer~=false then
        G.disabledReason="BROKER_SINGLEPLAYER_ONLY";return false,G.disabledReason
    end
    local I,R=RLAnimalIdentityCheckpoint,RLAnimalIdentityRuntime
    if I.state~="READY" or R.state~="READY" then return false,"WAITING_FOR_IDENTITY" end
    local dir=m.missionInfo and m.missionInfo.savegameDirectory
    if not dir or not I.lineage then return false,"BROKER_SAVEGAME_REQUIRED" end
    G.directory=dir
    -- Persist a SHADOW ledger for common-save evidence; native allocation mode
    -- is preserved. No weaker historical allocation guarantee is accepted here.
    if not R.ledger then
        R.ledger=need(RLAnimalIdentity.new(I.lineage))
        R.ledger.policy.mode=R.mode
        need(R.reconcile(RLAnimalIdentityWorld.scan(m),{excludeTransient=true}))
        need(I.arm())
    end
    G.lineage=I.lineage
    local config=need(RLMarketRuntime.getConfig())
    G.balance=config.brokerBalance
    G.balance.species.SHEEP,G.balance.species.PIG=nil,nil
    local cow=G.balance.species.COW
    cow.baseMax,cow.secondSlotChance=1,0
    G.balance=need(RLBrokerDemand.validateBalance(G.balance))
    local stores=newStores(dir,G.lineage)
    local binding={current=stores}
    local function proxy(role)
        return {read=function() return binding.current[role].read() end,
            write=function(payload) return binding.current[role].write(payload) end}
    end
    local stamp=type(getDate)=="function" and getDate("%Y%m%d%H%M%S") or tostring(g_time)
    local epoch=G.lineage..":g"..tostring(I.generation)..":"..stamp..":"..tostring(g_time)
    local r=need(RLBrokerRuntime.new({mission=m,lineage=G.lineage,epoch=epoch,balance=G.balance,
        monthStore=proxy("months"),transactionStore=proxy("broker")}))
    G.stores,G.directory,G.storeBinding=stores,dir,binding
    RLBrokerRuntime.current=r
    G.carryRecovery=recoveryMarker(dir)
    if G.carryRecovery then
        r.assetRisk=G.carryRecovery:sub(1,7)=="ASSETS:"
        r:block("BROKER_RECOVERY_CARRIED:"..G.carryRecovery)
        return false,r.reason
    end
    local archived=archivePresent(dir)
    r.assetRisk=archived or fileExists(dir.."/rm_RlBrokerLive_broker.xml") or fileExists(dir.."/rm_RlBrokerLive_broker.xml.staging")
    local a=adapter(dir,r)
    if archived then
        local c=checkpoint(a,r)
        local proof=need(c.load())
        need(proof.lineage==G.lineage,"BROKER_LINEAGE_MISMATCH")
        local doc=need(a.readPayload("broker"))
        local live,why=stores.broker.read()
        need((not live and why=="NOT_FOUND") or (live and same(live,doc)),"BROKER_UNSAVED_OR_MIXED_TRANSACTION")
        local history=need(a.readPayload("months"))
        local liveMonths,monthWhy=stores.months.read()
        if not liveMonths then need(monthWhy=="NOT_FOUND",monthWhy);need(stores.months.write(history)) end
        need(r.month:resumeCheckpoint(history))
        need(r.acquisition:restore(need(a.readPayload("acquisition"))))
        need(r:restore(doc,need(c.brokerRestoreProof(doc,proof))))
        r.generation=proof.generation
        r.state,r.reason,r.frozen,r.assetRisk="READY",nil,false,false
    else
        local live,why=stores.broker.read()
        need(not live and why=="NOT_FOUND","BROKER_WAL_WITHOUT_CHECKPOINT")
        r.state,r.reason="SAVE_REQUIRED","BROKER_INITIAL_SAVE_REQUIRED"
    end
    need(r:publish())
    return true
end
function G.update()
    if G.started or G.disabledReason or not g_currentMission then return end
    local I=RLAnimalIdentityCheckpoint
    if not I or I.state=="LOADING" then return end
    if I.state~="READY" then
        G.disabledReason="BROKER_IDENTITY_NOT_READY"
        local m=g_currentMission
        local dir=m.missionInfo and m.missionInfo.savegameDirectory
        if dir and (archivePresent(dir) or fileExists(dir.."/rm_RlBrokerLive_broker.xml") or recoveryMarker(dir)) then
            G.directory=dir;G.carryRecovery="ASSETS:BROKER_IDENTITY_NOT_READY"
            RLBrokerRuntime.recoveryHold=true
        end
        return
    end
    G.started=true
    local ok,result,why=pcall(G.start,g_currentMission)
    if not ok or result~=true then
        local reason=ok and why or tostring(result)
        if RLBrokerRuntime.current then RLBrokerRuntime.current:block(reason) end
        G.disabledReason=reason
        RmLogging.getLogger("RLRM"):warning("Broker unavailable: %s",tostring(reason))
    end
end
function G.beginSave(info)
    local r=RLBrokerRuntime.current
    if G.carryRecovery or (r and r.state=="RECOVERY_REQUIRED") then
        G.carryRecovery=G.carryRecovery or ((r.assetRisk and "ASSETS:" or "SCOPE:")..tostring(r.reason))
        carryEvidence(G.directory,info.savegameDirectory)
        return
    end
    if not r then return end
    need(not r.busy and not G.pass,"BROKER_OVERLAPPING_SAVE")
    local identity=RLAnimalIdentityRuntime
    if identity.mode~=identity.ON then need(identity.reconcile(RLAnimalIdentityWorld.scan(r.mission),{excludeTransient=true})) end
    need(r:publish())
    r.frozen=true
    need(r.tx:saveDocument())
    local a=adapter(info.savegameDirectory,r)
    local c=checkpoint(a,r)
    local generation=r.generation+1
    local id=G.lineage..":broker-save:"..generation
    local scope={lineage=G.lineage,generation=generation,checkpointId=id,sequence=r.tx:export().sequence}
    need(c.begin(id,scope))
    scope.sharedSaveId=id
    need(a.begin(scope))
    -- The engine replaces the save folder. Capture sidecar-owned payloads
    -- BEFORE that replacement; never depend on a live WAL surviving the save.
    G.pass={adapter=a,checkpoint=c,id=id,generation=generation,directory=info.savegameDirectory,
        liveMonths=need(r:monthDocument()),
        payloads={broker=r.tx:export(),months=need(r.month:checkpointDocument()),acquisition=r.acquisition:export()}}
end
function G.finishSave(info)
    local r=RLBrokerRuntime.current
    if r and r.state=="RECOVERY_REQUIRED" then
        G.carryRecovery=G.carryRecovery or ((r.assetRisk and "ASSETS:" or "SCOPE:")..tostring(r.reason))
        carryEvidence(G.directory,info.savegameDirectory)
    end
    if G.carryRecovery and info.xmlFile and info.xmlFile~=0 then
        setXMLString(info.xmlFile,"careerSavegame#"..G.RECOVERY_MARKER,G.carryRecovery)
    end
end
function G.markNative(role,xml)
    local p=G.pass;if not p then return end
    need(p.adapter.markNative(p.id,role,xml))
    need(p.checkpoint.markParticipant(p.id,role))
end
function G.markIdentity(kind,xml)
    local p=G.pass;if not p then return end
    if kind=="owner" then need(p.adapter.markIdentityOwner(p.id,xml))
    else need(p.adapter.markIdentitySystem(p.id,xml)) end
end
function G.observeIdentity(kind,xml)
    local ok,why=pcall(G.markIdentity,kind,xml)
    if not ok and RLBrokerRuntime.current then RLBrokerRuntime.current:block(tostring(why)) end
end
function G.completeSave(controller,code,directory)
    local actual=controller and controller.currentSavegame and controller.currentSavegame.savegameDirectory or directory
    local p=G.pass
    if not p then if G.carryRecovery and actual then G.directory=actual end return end
    local r=RLBrokerRuntime.current
    need(r.state~="RECOVERY_REQUIRED","BROKER_SAVE_ALREADY_FAILED")
    need(Savegame and code==Savegame.ERROR_OK,"BROKER_ENGINE_SAVE_FAILED")
    need(RLAnimalIdentityCheckpoint.last and RLAnimalIdentityCheckpoint.last.status=="COMMITTED","BROKER_IDENTITY_SAVE_INCOMPLETE")
    -- The engine may rename its staging directory. Build an inspector against
    -- the final folder, carrying the SAME scope; C.finish still rereads all files.
    local a=p.adapter
    if actual and actual~=p.directory then
        a=adapter(actual,r)
        local scope={lineage=G.lineage,generation=p.generation,checkpointId=p.id,sharedSaveId=p.id,sequence=r.tx:export().sequence}
        need(a.begin(scope))
    end
    local payloads=p.payloads
    payloads.identity=need(RLAnimalIdentityRuntime.exportLedger(RLAnimalIdentityCheckpoint.generation))
    for _,role in ipairs({"identity","acquisition","broker","months"}) do
        need(a.writePayload(p.id,role,payloads[role]))
    end
    -- Recreate C for the actual final paths. Marking callbacks only records
    -- occurrence; finish independently reads every native marker and payload.
    local c=checkpoint(a,r)
    need(c.begin(p.id,{lineage=G.lineage,generation=p.generation,checkpointId=p.id,sequence=payloads.broker.sequence}))
    for _,role in ipairs({"placeables","vehicles","farms","animals","identity","acquisition","broker","months"}) do need(c.markParticipant(p.id,role)) end
    need(c.finish(p.id))
    need(a.endScope(p.id))
    r.generation=p.generation
    -- Engine folder replacement can drop live sidecars. The exact committed
    -- cohort becomes their new baseline; no payment/source operation is replayed.
    G.directory=actual or G.directory
    local stores=newStores(G.directory,G.lineage)
    need(stores.broker.write(payloads.broker))
    need(stores.months.write(p.liveMonths))
    -- Existing closures use the original paths, which point to the final folder.
    G.stores=stores
    G.storeBinding.current=stores
    r.state,r.reason,r.frozen,r.assetRisk="READY",nil,false,false
    G.pass=nil
end
function G.install()
    if G.installed then return end
    G.installed=true
    for _,entry in ipairs({{AnimalBuyEvent,"run"},{AIAnimalBuyEvent,"run"},{AnimalSellEvent,"run"},
        {AIAnimalSellEvent,"run"},{AIAnimalSellEvent,"executeServer"},{AnimalMoveEvent,"run"},
        {RLDealerPurchase,"execute"},{RLContractTrade,"execute"}}) do RLBrokerRuntime.guardLegacy(entry[1],entry[2]) end
    local function guard(fn)
        return function(...)
            local ok,why=pcall(fn,...)
            if not ok then
                local r=RLBrokerRuntime.current
                if r then r:block(tostring(why)) end
                G.carryRecovery=G.carryRecovery or ((r and r.assetRisk and "ASSETS:" or "SCOPE:")..tostring(why))
                if fn==G.completeSave then
                    -- A verification failure occurs after the engine committed
                    -- the folder. Persist its closed state now; a later normal
                    -- save must never erase the failed cohort and reopen quotas.
                    local m=g_currentMission
                    local dir=m and m.missionInfo and m.missionInfo.savegameDirectory or G.directory
                    G.directory=dir or G.directory
                    if dir then pcall(function()
                        local xml=XMLFile.loadIfExists("rlBrokerRecoveryWrite",dir.."/careerSavegame.xml")
                        if xml then xml:setString("careerSavegame#"..G.RECOVERY_MARKER,G.carryRecovery);xml:save();xml:delete() end
                    end) end
                    G.pass=nil
                end
                RmLogging.getLogger("RLRM"):error("Broker save paused: %s",tostring(why))
            end
        end
    end
    RLNativeSaveHooks.install(G,{
        begin=guard(G.beginSave),
        finish=guard(G.finishSave),
        placeables=guard(function(_,xml) G.markNative("placeables",xml) end),
        vehicles=guard(function(_,_,xml) G.markNative("vehicles",xml) end),
        farms=guard(function(_,xml)
            -- Farm.saveToXMLFile runs for each farm in the same document.
            if G.pass and not G.pass.farms then G.markNative("farms",xml);G.pass.farms=true end
        end),
        complete=guard(G.completeSave)
    })
end
function G.reset()
    G.started,G.disabledReason,G.pass,G.stores,G.lineage,G.directory,G.balance,G.storeBinding=nil,nil,nil,nil,nil,nil,nil,nil
    G.carryRecovery=nil
    RLBrokerRuntime.current=nil
    RLBrokerRuntime.recoveryHold=nil
    RLBrokerRuntime.legacyDepth=0
    RLMarketResourceLock.instance=nil
end
