loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLBrokerPersistence.lua")
loadMod("scripts/market/RLMarketCheckpoint.lua")
local C,T=RLMarketCheckpoint,RLTradePersistence
local function copy(v)return assert(T.parse(T.canonical(v),RLBrokerPersistence.LIMITS))end
local roles={"placeables","vehicles","farms","animals","identity","acquisition","broker","months"}
local function fixture()
    local w={files={},freezes={},releases={},journalRows={},fault=nil}
    w.scope={lineage="L-save",generation=7,checkpointId="checkpoint7",sequence=2}
    w.contract={careerPath="career.xml",participants={}}
    for _,role in ipairs(roles)do w.contract.participants[role]={path=role..".xml",schemaVersion=role=="acquisition"and 2 or 1}end
    w.records={done={requestId="done",state="COMMITTED",animalKey="1 2 3",payment={status="APPLIED",amount=100}},pending={requestId="pending",state="UNKNOWN",resources={"animal:1 4 3","quota:OLD:1"}}}
    w.payloads={broker={schemaVersion=1,kind="BROKER_TRANSACTIONS",sequence=2,records=copy(w.records),quota={oldMonth="OLD:1",reserved=1}},identity={schemaVersion=1,consumed={"1 2 3","1 4 3"}},acquisition={schemaVersion=2,animals={},requests={}},months={schemaVersion=1,currentAbsoluteMonth=10,months={OLD={rules="retained"}}}}
    function w.writeParticipants(shared)
        for _,role in ipairs(roles)do
            local marker=copy(w.scope);marker.sharedSaveId=shared;marker.role=role;marker.sequence=nil
            marker.schemaVersion=w.contract.participants[role].schemaVersion
            marker.payload=w.payloads[role]and copy(w.payloads[role]);marker.payloadValidated=marker.payload~=nil
            local content='<native role="'..role..'" market="'..T.encodeText(T.canonical(marker))..'"><body>'..role..':saved</body></native>'
            w.files[role..".xml"]=content
        end
    end
    function w.rewriteMarker(role,change)
        local raw=w.files[role..".xml"]
        local encoded=assert(raw:match('market="([^"]+)"'))
        local marker=assert(T.parse(assert(T.decodeText(encoded)),RLBrokerPersistence.LIMITS))
        change(marker)
        w.files[role..".xml"]=raw:gsub('market="[^"]+"','market="'..T.encodeText(T.canonical(marker))..'"')
    end
    w.files["career.xml"]='<careerSavegame><money>1000</money></careerSavegame>'
    w.storage={}
    function w.storage.read(path)
        if w.onRead then w.onRead(path)end
        return w.files[path]
    end
    function w.storage.inspectParticipant(role,raw)
        if w.onInspect then w.onInspect(role)end
        local encoded=raw:match('market="([^"]+)"')
        return assert(T.parse(assert(T.decodeText(encoded)),RLBrokerPersistence.LIMITS))
    end
    function w.storage.careerBody(raw)return (raw:gsub('<marketCommit v="[^"]*"/>',''))end
    function w.storage.inspectCareer(raw)
        local encoded=raw:match('<marketCommit v="([^"]*)"/>')
        if not encoded then return nil end
        return assert(T.parse(assert(T.decodeText(encoded)),RLBrokerPersistence.LIMITS))
    end
    function w.storage.commitCareer(path,proof)
        if w.onCommit then w.onCommit(proof)end
        if w.fault=="COMMIT_FALSE"then return false end
        if w.fault=="WRONG_COMMIT"then proof.generation=8 end
        w.files[path]=w.storage.careerBody(w.files[path]):gsub('</careerSavegame>','<marketCommit v="'..T.encodeText(T.canonical(proof))..'"/></careerSavegame>')
        if w.fault=="PARTICIPANT_AFTER_COMMIT"then w.files["farms.xml"]=w.files["farms.xml"].."changed"end
        return true
    end
    function w.storage.journals()return copy(w.journalRows)end
    w.hooks={}
    for _,name in ipairs({"transactions","sources","identity"})do
        w.hooks[name]={freeze=function()w.freezes[name]=(w.freezes[name]or 0)+1;if w.onFreeze then w.onFreeze(name)end;return w.fault~="FREEZE_FALSE"end,
            release=function()w.releases[name]=(w.releases[name]or 0)+1;if w.onRelease then w.onRelease(name)end;return w.fault~="RELEASE_FALSE"end}
    end
    w.api=assert(C.new(w.storage,w.contract,w.hooks))
    return w
end
local function start(w,id)
    id=id or "shared7";assert(w.api.begin(id,w.scope));w.writeParticipants(id)
    for _,role in ipairs(roles)do assert(w.api.markParticipant(id,role))end
    return id
end
local w=fixture();local id=start(w)
local proof=assert(w.api.finish(id))
check("checkpoint: all independent domains share exact save identity",w.api.status().allowNewTransactions and proof.references.acquisition.schemaVersion==2 and proof.references.identity.digest~=nil and proof.references.broker.payloadDigest~=nil)
check("checkpoint: all transaction/source/identity freezes release after proof",w.freezes.transactions==1 and w.freezes.sources==1 and w.freezes.identity==1 and w.releases.transactions==1 and w.releases.sources==1 and w.releases.identity==1)
check("checkpoint: career native body survives final commit",w.storage.careerBody(w.files["career.xml"])=='<careerSavegame><money>1000</money></careerSavegame>')
local historical=assert(w.api.settleCommitted(w.records.done,proof))
check("checkpoint: exact saved committed receipt becomes historical settled",historical.state=="HISTORICAL_SETTLED" and historical.settledCheckpoint.checkpointId=="checkpoint7"and w.records.done.state=="COMMITTED")
check("checkpoint: pending locks/old-month quota are never silently settled",w.api.settleCommitted(w.records.pending,proof)==nil and w.payloads.broker.quota.reserved==1 and w.payloads.broker.quota.oldMonth=="OLD:1")
local altered=copy(w.records.done);altered.payment.amount=101
check("checkpoint: cannot settle a different receipt by request ID alone",w.api.settleCommitted(altered,proof)==nil)
local reloaded=assert(C.new(w.storage,w.contract,w.hooks))
local loaded=assert(reloaded.load())
check("checkpoint: complete same-cohort physical files reload",loaded.digest==proof.digest and reloaded.status().allowNewTransactions)
check("checkpoint: historical query never requires current wallet or living location",reloaded.settleCommitted(w.records.done,loaded).state=="HISTORICAL_SETTLED")
local restoreProof=assert(reloaded.brokerRestoreProof(w.payloads.broker,loaded))
check("checkpoint: restore bridge binds the entire saved broker document",restoreProof.verified==true and restoreProof.documentFingerprint==RLMarketData.fingerprint(w.payloads.broker) and type(restoreProof.checkpointRef)=="string")
local changedDoc=copy(w.payloads.broker);changedDoc.quota.oldMonth="OTHER:1"
check("checkpoint: same records with changed old-month quota cannot acquire proof",reloaded.brokerRestoreProof(changedDoc,loaded)==nil)
changedDoc=copy(w.payloads.broker);changedDoc.records.pending.resources[1]="animal:1 4 4"
check("checkpoint: changed nonterminal resource cannot acquire restore proof",reloaded.brokerRestoreProof(changedDoc,loaded)==nil)
local invented=copy(loaded);invented.sharedSaveId="unverified"
check("checkpoint: caller-provided verified bool cannot authorize restore",reloaded.brokerRestoreProof(w.payloads.broker,{verified=true})==nil and reloaded.brokerRestoreProof(w.payloads.broker,invented)==nil)
assert(not reloaded.markParticipant("late","broker"))
check("checkpoint: closed coordinator cannot reuse prior restore authority",reloaded.brokerRestoreProof(w.payloads.broker,loaded)==nil)
w=fixture();assert(w.api.begin("missing",w.scope))
for _,role in ipairs(roles)do assert(w.api.markParticipant("missing",role))end
check("checkpoint: every callback without physical files is not save proof",w.api.finish("missing")==nil and not w.api.status().allowNewTransactions and w.api.status().allowEngineSave)
w=fixture();assert(w.api.begin("duplicate",w.scope));assert(w.api.markParticipant("duplicate","farms"))
check("checkpoint: duplicate callback closes new transactions",not w.api.markParticipant("duplicate","farms") and w.api.status().state=="RECOVERY_REQUIRED")
w=fixture();id=start(w);assert(w.api.finish(id))
check("checkpoint: late callback does not reopen or overwrite proof",not w.api.markParticipant(id,"farms") and w.api.status().state=="RECOVERY_REQUIRED")
for _,role in ipairs(roles)do
    local bad=fixture();id=start(bad)
    bad.rewriteMarker(role,function(m)m.sharedSaveId="other-save"end)
    check("checkpoint: generation alone cannot hide mixed cohort "..role,bad.api.finish(id)==nil and bad.api.status().allowEngineSave)
end
for _,field in ipairs({"generation","checkpointId","lineage","schemaVersion"})do
    local bad=fixture();id=start(bad)
    bad.rewriteMarker("farms",function(m)if type(m[field])=="number"then m[field]=m[field]+1 else m[field]="another"end end)
    check("checkpoint: valid serialized marker cannot hide mixed "..field,bad.api.finish(id)==nil)
end
for _,fault in ipairs({"COMMIT_FALSE","WRONG_COMMIT","PARTICIPANT_AFTER_COMMIT","RELEASE_FALSE"})do
    local bad=fixture();id=start(bad);bad.fault=fault
    check("checkpoint: final barrier "..fault.." keeps delivery closed",bad.api.finish(id)==nil and bad.api.status().state=="RECOVERY_REQUIRED"and bad.api.evidence()~=nil)
end
w=fixture();id=start(w);proof=assert(w.api.finish(id));w.files["animals.xml"]=w.files["animals.xml"].."later-file-edit"
check("checkpoint: complete content digest catches unchanged marker with changed animals",assert(C.new(w.storage,w.contract,w.hooks)).load()==nil)
for _,kind in ipairs({"UNKNOWN","STAGING","FUTURE","OLD_MONTH"})do
    local bad=fixture();id=start(bad)
    bad.journalRows={{role="broker",verified=kind~="UNKNOWN",staging=kind=="STAGING",lineage="L-save",generation=kind=="FUTURE"and 8 or 7,checkpointId="checkpoint7",sharedSaveId="shared7",sequence=kind=="OLD_MONTH"and 1 or 2,payloadDigest=RLBrokerPersistence.digest(bad.payloads.broker)}}
    check("checkpoint: unabsorbed "..kind.." journal cannot authorize fresh trade",bad.api.finish(id)==nil and not bad.api.status().allowNewTransactions)
end
w=fixture();id=start(w)
w.journalRows={{role="broker",verified=true,staging=false,lineage="L-save",generation=7,checkpointId="checkpoint7",sharedSaveId="shared7",sequence=2,payloadDigest=RLBrokerPersistence.digest(w.payloads.broker)}}
check("checkpoint: exactly absorbed broker WAL is verified without replay",w.api.finish(id)~=nil)
for _,phase in ipairs({"READ","INSPECT","COMMIT","RELEASE","FREEZE","LOAD"})do
    local bad=fixture();local nested,nestedWhy
    local function reenter()nested,nestedWhy=bad.api.begin("nested",bad.scope)end
    if phase=="FREEZE"then bad.onFreeze=reenter end
    id=start(bad)
    if phase=="READ"then bad.onRead=reenter elseif phase=="INSPECT"then bad.onInspect=reenter elseif phase=="COMMIT"then bad.onCommit=reenter elseif phase=="RELEASE"then bad.onRelease=reenter end
    local complete=bad.api.finish(id)
    if phase=="LOAD"then bad.onRead=reenter;complete=bad.api.load()end
    check("checkpoint: "..phase.." callback cannot reenter save lifecycle",complete~=nil and nested==nil and nestedWhy=="MARKET_CHECKPOINT_BUSY"and bad.api.status().state=="READY")
end
w=fixture();w.fault="FREEZE_FALSE"
check("checkpoint: failed freeze remains uncertain not falsely frozen",w.api.begin("freeze",w.scope)==nil and w.api.status().freezes.transactions=="UNKNOWN" and w.api.status().freezes.identity=="UNKNOWN" and w.freezes.transactions>=2)
check("checkpoint: freeze failure cannot block native engine save",w.api.status().allowEngineSave and not w.api.status().allowNewTransactions)
w=fixture();id=start(w);proof=assert(w.api.finish(id));local before=w.files["career.xml"]
check("checkpoint: same generation cannot be reused with another shared ID",w.api.begin("shared-other",w.scope)==nil and w.files["career.xml"]==before)

-- Compose the real transaction schema/restore gate with the shared-save proof.
for _,name in ipairs({"RLMarketResourceLock","RLBrokerQuota","RLBrokerTransaction"})do loadMod("scripts/market/"..name..".lua")end
w=fixture()
w.payloads.broker={schemaVersion=1,kind="BROKER_TRANSACTIONS",serverEpoch="prior-epoch",sequence=2,records={},quota=RLBrokerQuota.new():export()}
assert(RLBrokerTransaction.validateDocument(w.payloads.broker))
id=start(w);proof=assert(w.api.finish(id))
local deps={serverEpoch="new-epoch",orderService={},locks=RLMarketResourceLock.new(),quota=RLBrokerQuota.new(),source={},store={}}
for _,name in ipairs({"authorize","prepareSource","createMoneyAdapter","nowMs","ready","saveFence"})do deps[name]=function()return true end end
local transaction=assert(RLBrokerTransaction.new(deps))
local actualRestoreProof=assert(w.api.brokerRestoreProof(w.payloads.broker,proof))
check("checkpoint: real Transaction.restore consumes only saved whole-doc bridge",transaction:restore(w.payloads.broker,actualRestoreProof)==true and transaction:export().sequence==2)
local changed=copy(w.payloads.broker);changed.serverEpoch="other-epoch"
check("checkpoint: real transaction document single-field mutation cannot get bridge",w.api.brokerRestoreProof(changed,proof)==nil)
local allClosed,checks=true,0
w.onRead=function()
    checks=checks+1
    allClosed=allClosed and not w.api.status().allowNewTransactions
        and w.api.brokerRestoreProof(w.payloads.broker,proof)==nil
        and w.api.settleCommitted(w.records.done,proof)==nil
end
check("checkpoint: reloading READY closes transactions and proof authority inside reads",w.api.load()~=nil and checks>0 and allClosed and w.api.status().allowNewTransactions)
w.onRead=nil
allClosed,checks=true,0
w.onFreeze=function()
    checks=checks+1
    allClosed=allClosed and not w.api.status().allowNewTransactions
        and w.api.brokerRestoreProof(w.payloads.broker,proof)==nil
        and w.api.settleCommitted(w.records.done,proof)==nil
end
local nextScope=copy(w.scope);nextScope.generation=8;nextScope.checkpointId="checkpoint8"
check("checkpoint: new begin denies old proof even before READY state changes",w.api.begin("shared8",nextScope)~=nil and checks==3 and allClosed and not w.api.status().allowNewTransactions)
