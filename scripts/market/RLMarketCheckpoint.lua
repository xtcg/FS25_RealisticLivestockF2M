-- Pure shared-save coordinator. Not installed into the engine. An integration
-- must supply synchronous native XML inspectors/commit writers and freeze hooks.
-- Callback occurrence is never disk evidence; every participant is read in full.
RLMarketCheckpoint={}
local C=RLMarketCheckpoint
local roles={"placeables","vehicles","farms","animals","identity","acquisition","broker","months"}
local text=RLPlain.text
local function integer(v,min)return type(v)=="number" and v==v and v>=min and v<2^52 and v%1==0 end
local function requireValue(ok,reason)if not ok then error(reason,0)end end
local function copy(v)
    requireValue(RLTradePersistence.check(v,RLBrokerPersistence.LIMITS)==nil,"INVALID_CHECKPOINT_DATA")
    return assert(RLTradePersistence.parse(RLTradePersistence.canonical(v),RLBrokerPersistence.LIMITS))
end
local function digest(v)return RLBrokerPersistence.digest(v)end
local function same(a,b)return RLTradePersistence.canonical(a)==RLTradePersistence.canonical(b)end
local function exactKeys(value,allowed)for key in pairs(value)do requireValue(allowed[key],"EXTRA_CHECKPOINT_FIELD")end end
function C.new(storage,contracts,hooks)
    for _,key in ipairs({"read","inspectParticipant","inspectCareer","careerBody","commitCareer","journals"})do
        if type(storage)~="table" or type(storage[key])~="function" then return nil,"NATIVE_STORAGE_ADAPTER_REQUIRED:"..key end
    end
    if type(hooks)~="table" then return nil,"FREEZE_HOOKS_REQUIRED" end
    for _,name in ipairs({"transactions","sources","identity"})do
        if type(hooks[name])~="table" or type(hooks[name].freeze)~="function" or type(hooks[name].release)~="function" then return nil,"FREEZE_HOOK_REQUIRED:"..name end
    end
    local ok,config=pcall(copy,contracts)
    if not ok or type(config)~="table" or type(config.participants)~="table" or not text(config.careerPath)then return nil,"INVALID_PARTICIPANT_CONTRACTS"end
    local paths={[config.careerPath]=true}
    for _,role in ipairs(roles)do
        local v=config.participants[role]
        if type(v)~="table" or not text(v.path) or not integer(v.schemaVersion,1) or paths[v.path] then return nil,"INVALID_PARTICIPANT:"..role end
        for key in pairs(v)do if key~="path" and key~="schemaVersion" then return nil,"EXTRA_PARTICIPANT_FIELD"end end
        paths[v.path]=true
    end
    local count=0;for _ in pairs(config.participants)do count=count+1 end
    if count~=#roles or config.participants.acquisition.schemaVersion~=2 or config.participants.broker.schemaVersion~=1 then return nil,"UNSUPPORTED_PARTICIPANT_SCHEMA"end
    for key in pairs(config)do if key~="careerPath" and key~="participants"then return nil,"EXTRA_CONTRACT_FIELD"end end
    local state,reason,active,lastProof,evidence="DORMANT",nil,nil,nil,nil
    local lastBrokerCanonical
    local seenSaveIds={}
    local frozen={}
    local function freezeAll()
        local errors={}
        for _,name in ipairs({"transactions","sources","identity"})do
            if frozen[name]~="FROZEN"then
                frozen[name]="FREEZING"
                local okay,accepted=pcall(hooks[name].freeze)
                frozen[name]=okay and accepted==true and "FROZEN" or "UNKNOWN"
                if frozen[name]~="FROZEN"then errors[#errors+1]=name end
            end
        end
        requireValue(#errors==0,"FREEZE_FAILED:"..table.concat(errors,","))
    end
    local function close(why)
        state,reason="RECOVERY_REQUIRED",why
        local okay=pcall(freezeAll)
        if not okay then reason=reason..":FREEZE_UNCERTAIN"end
        return nil,reason
    end
    local function scope(marker,expected,role,contract)
        requireValue(type(marker)=="table" and marker.role==role and marker.schemaVersion==contract.schemaVersion
            and marker.lineage==expected.lineage and marker.generation==expected.generation
            and marker.checkpointId==expected.checkpointId and marker.sharedSaveId==expected.sharedSaveId,"PARTICIPANT_SCOPE_MISMATCH:"..role)
    end
    local function inspectParticipants(expected)
        local manifest,references,committed={},{},{}
        local brokerCanonical
        for _,role in ipairs(roles)do
            local contract=config.participants[role]
            local raw=storage.read(contract.path)
            requireValue(type(raw)=="string","PARTICIPANT_MISSING:"..role)
            local marker=storage.inspectParticipant(role,raw,copy(contract));marker=copy(marker)
            scope(marker,expected,role,contract)
            local item={path=contract.path,schemaVersion=contract.schemaVersion,length=#raw,digest=RLTradePersistence.checksum(raw)}
            manifest[role]=item
            if role=="broker" or role=="acquisition" or role=="identity" or role=="months"then
                requireValue(marker.payloadValidated==true and type(marker.payload)=="table","VALIDATED_PAYLOAD_REQUIRED:"..role)
                local payload=marker.payload
                if role=="acquisition" then requireValue(payload.schemaVersion==2,"ACQUISITION_SCHEMA_REQUIRED")end
                if role=="broker" then
                    brokerCanonical=RLTradePersistence.canonical(payload)
                    requireValue(payload.schemaVersion==1 and payload.kind=="BROKER_TRANSACTIONS" and integer(payload.sequence,0) and type(payload.records)=="table","BROKER_PAYLOAD_REQUIRED")
                    requireValue(payload.sequence==expected.sequence,"BROKER_SEQUENCE_MISMATCH")
                    for id,record in pairs(payload.records)do
                        requireValue(text(id) and type(record)=="table" and record.requestId==id,"INVALID_SAVED_RECEIPT")
                        if record.state=="COMMITTED"then committed[id]=RLTradePersistence.canonical(record)end
                    end
                end
                references[role]={path=contract.path,digest=item.digest,payloadDigest=digest(payload),schemaVersion=contract.schemaVersion}
            end
        end
        return manifest,references,committed,brokerCanonical
    end
    -- journals() must enumerate every relevant WAL/staging file through the
    -- real storage adapter. Only complete, exactly absorbed snapshots qualify;
    -- unknown, older unaligned, future or staged evidence keeps delivery closed.
    local function journals(expected,references)
        local list=copy(storage.journals())
        requireValue(type(list)=="table","JOURNAL_SCAN_REQUIRED")
        local count=0
        for key,row in pairs(list)do
            count=count+1;requireValue(integer(key,1) and key<=#list and type(row)=="table","INVALID_JOURNAL_SCAN")
            exactKeys(row,{role=true,verified=true,staging=true,lineage=true,generation=true,checkpointId=true,sharedSaveId=true,sequence=true,payloadDigest=true})
            requireValue(row.verified==true and row.staging==false and references[row.role]~=nil
                and row.lineage==expected.lineage and row.generation==expected.generation and row.checkpointId==expected.checkpointId
                and row.sharedSaveId==expected.sharedSaveId and integer(row.sequence,0)
                and row.payloadDigest==references[row.role].payloadDigest,"UNABSORBED_OR_UNKNOWN_JOURNAL")
            if row.role=="broker"then requireValue(row.sequence==expected.sequence,"JOURNAL_SEQUENCE_MISMATCH")end
        end
        requireValue(count==#list,"SPARSE_JOURNAL_SCAN")
    end
    local function validateProof(raw)
        local p=copy(raw)
        exactKeys(p,{schemaVersion=true,kind=true,lineage=true,generation=true,checkpointId=true,sharedSaveId=true,sequence=true,participants=true,references=true,committed=true,careerBodyDigest=true,digest=true})
        requireValue(p.schemaVersion==1 and p.kind=="MARKET_SHARED_CHECKPOINT" and text(p.lineage) and integer(p.generation,1)
            and text(p.checkpointId) and text(p.sharedSaveId) and integer(p.sequence,0),"INVALID_SHARED_CHECKPOINT")
        local saved=p.digest;p.digest=nil;requireValue(saved==digest(p),"SHARED_CHECKPOINT_DIGEST_MISMATCH");p.digest=saved
        local manifest,refs,committed,brokerCanonical=inspectParticipants(p)
        journals(p,refs)
        requireValue(same(manifest,p.participants) and same(refs,p.references) and same(committed,p.committed),"SHARED_PARTICIPANT_SET_MISMATCH")
        return p,brokerCanonical
    end
    local api={}
    local busy=false
    function api.begin(sharedSaveId,rawScope)
        if state=="RECOVERY_REQUIRED" or active~=nil then return close("OVERLAPPING_OR_UNRESOLVED_SAVE")end
        local okay,why=pcall(function()
            local s=copy(rawScope)
            exactKeys(s,{lineage=true,generation=true,checkpointId=true,sequence=true})
            requireValue(text(sharedSaveId) and not seenSaveIds[sharedSaveId] and text(s.lineage) and integer(s.generation,1) and text(s.checkpointId) and integer(s.sequence,0),"INVALID_SHARED_SAVE_SCOPE")
            if lastProof then requireValue(s.lineage==lastProof.lineage and s.generation>lastProof.generation and s.checkpointId~=lastProof.checkpointId,"SAVE_GENERATION_NOT_ADVANCED")end
            freezeAll();s.sharedSaveId=sharedSaveId
            seenSaveIds[sharedSaveId]=true;active={scope=s,callbacks={}};state,reason="SAVING",nil
        end)
        if not okay then return close(tostring(why))end
        return {allowEngineSave=true,sharedSaveId=sharedSaveId,scope=copy(active.scope)}
    end
    function api.markParticipant(sharedSaveId,role)
        if active==nil or state~="SAVING" or active.scope.sharedSaveId~=sharedSaveId or config.participants[role]==nil then return close("LATE_OR_FOREIGN_SAVE_CALLBACK")end
        if active.callbacks[role]then return close("DUPLICATE_SAVE_CALLBACK")end
        active.callbacks[role]=true;return true
    end
    function api.finish(sharedSaveId)
        if active==nil or state~="SAVING" or active.scope.sharedSaveId~=sharedSaveId then return close("SAVE_NOT_ACTIVE")end
        local okay,proof,brokerCanonical=pcall(function()
            for _,role in ipairs(roles)do requireValue(active.callbacks[role],"SAVE_CALLBACK_MISSING:"..role)end
            state="VERIFYING"
            local manifest,refs,committed=inspectParticipants(active.scope)
            journals(active.scope,refs)
            local career=storage.read(config.careerPath);requireValue(type(career)=="string","CAREER_MISSING")
            local body=storage.careerBody(career);requireValue(type(body)=="string","CAREER_BODY_UNREADABLE")
            local p=copy(active.scope);p.schemaVersion=1;p.kind="MARKET_SHARED_CHECKPOINT";p.participants=manifest;p.references=refs;p.committed=committed;p.careerBodyDigest=RLTradePersistence.checksum(body);p.digest=digest(p)
            evidence={previous=lastProof and copy(lastProof) or {},proposed=copy(p)}
            requireValue(storage.commitCareer(config.careerPath,copy(p))==true,"CAREER_COMMIT_WRITE_UNCERTAIN")
            local actual=storage.read(config.careerPath);requireValue(type(actual)=="string","CAREER_COMMIT_READ_FAILED")
            local reread=copy(storage.inspectCareer(actual));requireValue(type(reread)=="table" and same(reread,p),"CAREER_COMMIT_READBACK_MISMATCH")
            requireValue(RLTradePersistence.checksum(storage.careerBody(actual))==p.careerBodyDigest,"CAREER_BODY_CHANGED_DURING_COMMIT")
            local _,savedBroker=validateProof(reread) -- Re-read all participants after the final marker.
            for _,name in ipairs({"identity","sources","transactions"})do requireValue(hooks[name].release()==true,"RELEASE_FAILED:"..name);frozen[name]=nil end
            return p,savedBroker
        end)
        if not okay then return close(tostring(proof))end
        lastProof=proof;lastBrokerCanonical=brokerCanonical;active=nil;evidence=nil;state,reason="READY",nil
        return copy(proof)
    end
    function api.load()
        if active~=nil then return close("SAVE_ACTIVE")end
        if state=="RECOVERY_REQUIRED"then return nil,reason end
        local okay,proof,brokerCanonical=pcall(function()
            freezeAll()
            local raw=storage.read(config.careerPath);requireValue(type(raw)=="string","CAREER_PROOF_MISSING")
            local p,savedBroker=validateProof(storage.inspectCareer(raw))
            requireValue(RLTradePersistence.checksum(storage.careerBody(raw))==p.careerBodyDigest,"CAREER_BODY_MISMATCH")
            for _,name in ipairs({"identity","sources","transactions"})do requireValue(hooks[name].release()==true,"RELEASE_FAILED:"..name);frozen[name]=nil end
            return p,savedBroker
        end)
        if not okay then return close(tostring(proof))end
        lastProof=proof;lastBrokerCanonical=brokerCanonical;seenSaveIds[proof.sharedSaveId]=true;state,reason="READY",nil
        return copy(proof)
    end
    function api.settleCommitted(record,proof)
        local okay,value=pcall(function()
            local r,p=copy(record),copy(proof)
            requireValue(not busy and lastProof~=nil and state=="READY" and same(p,lastProof),"VERIFIED_CHECKPOINT_REQUIRED")
            requireValue(r.state=="COMMITTED" and text(r.requestId) and p.committed[r.requestId]==RLTradePersistence.canonical(r),"SAVED_COMMITTED_RECEIPT_REQUIRED")
            r.originalState=r.state;r.state="HISTORICAL_SETTLED";r.settledCheckpoint={lineage=p.lineage,generation=p.generation,checkpointId=p.checkpointId,sharedSaveId=p.sharedSaveId,proofDigest=p.digest}
            return r
        end)
        if not okay then return nil,tostring(value)end;return value
    end
    -- Server-only bridge to Transaction.restore. Authority comes from this
    -- coordinator's completed physical read barrier, never a caller's bool.
    -- The complete saved document is retained canonically, not by checksum.
    function api.brokerRestoreProof(document,proof)
        local okay,value=pcall(function()
            local doc,p=copy(document),copy(proof)
            requireValue(not busy and state=="READY" and lastProof~=nil and same(p,lastProof),"VERIFIED_CHECKPOINT_REQUIRED")
            requireValue(lastBrokerCanonical~=nil and RLTradePersistence.canonical(doc)==lastBrokerCanonical,"SAVED_BROKER_DOCUMENT_REQUIRED")
            requireValue(RLMarketData~=nil and type(RLMarketData.fingerprint)=="function","MARKET_DATA_REQUIRED")
            local fingerprint=RLMarketData.fingerprint(doc)
            requireValue(fingerprint~=nil,"INVALID_BROKER_DOCUMENT")
            return {verified=true,checkpointRef="market-checkpoint:"..RLTradePersistence.canonical({lineage=p.lineage,generation=p.generation,checkpointId=p.checkpointId,sharedSaveId=p.sharedSaveId}),documentFingerprint=fingerprint}
        end)
        if not okay then return nil,tostring(value)end;return value
    end
    -- Reentrant lifecycle calls are explicitly refused without changing the
    -- outer operation's scope/state. Read-only status/evidence remain available.
    for _,name in ipairs({"begin","markParticipant","finish","load"})do
        local operation=api[name]
        api[name]=function(...)
            if busy then return nil,"MARKET_CHECKPOINT_BUSY"end
            busy=true
            local okay,value,why=pcall(operation,...)
            if not okay then value,why=close(tostring(value))end
            busy=false
            return value,why
        end
    end
    function api.status()return {state=state,reason=reason,busy=busy,freezes=copy(frozen),allowNewTransactions=state=="READY" and not busy,allowEngineSave=true}end
    function api.evidence()return evidence and copy(evidence)or nil end
    return api
end
