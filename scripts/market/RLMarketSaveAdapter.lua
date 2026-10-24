-- Dormant native save seam. No hooks/listeners, mission globals, or file writes
-- at construction. Callers must integrate one shared save scope with engine
-- save callbacks and freeze hooks before using RLMarketCheckpoint admission.
RLMarketSaveAdapter={}
local A=RLMarketSaveAdapter
A.NATIVE_MARKER="rlMarketSharedSave"
A.CAREER_MARKER="rlMarketSharedCheckpoint"
A.IDENTITY_MARKER="rlIdentityCheckpoint"
A.ANIMALS_PATH="market-logical://native-animals/placeables+vehicles"
local roles={"identity","acquisition","broker","months"}
local roots={placeables="placeables",vehicles="vehicles",farms="farms",career="careerSavegame"}
local filenames={identity="rm_RlMarketIdentity.xml",acquisition="rm_RlMarketAcquisition.xml",broker="rm_RlMarketBroker.xml",months="rm_RlMarketMonths.xml"}
local function need(ok,why)if not ok then error(why,0)end end
local text=RLPlain.text
local function integer(v,min)return type(v)=="number" and v==v and v>=min and v<2^52 and v%1==0 end
local function cp(v)return assert(RLMarketData.copy(v))end
local function same(a,b)local fingerprint=RLMarketData.fingerprint(a);return fingerprint~=nil and fingerprint==RLMarketData.fingerprint(b)end
local function keys(v,allowed)need(type(v)=="table","EXPECTED_SAVE_TABLE");for k in pairs(v)do need(allowed[k],"UNKNOWN_SAVE_FIELD")end end
local function scope(v)
    keys(v,{lineage=true,generation=true,checkpointId=true,sharedSaveId=true,sequence=true})
    need(text(v.lineage) and integer(v.generation,1) and text(v.checkpointId) and text(v.sharedSaveId) and integer(v.sequence,0),"INVALID_SHARED_SAVE_SCOPE")
    return v
end
local function encoded(v)return RLTradePersistence.encodeText(RLTradePersistence.canonical(v))end
local function decoded(v)
    need(type(v)=="string","MARKET_MARKER_MISSING")
    local raw=RLTradePersistence.decodeText(v);need(raw~=nil,"MARKET_MARKER_ENCODING")
    local data=assert(RLTradePersistence.parse(raw,RLBrokerPersistence.LIMITS))
    need(encoded(data)==v,"NONCANONICAL_MARKET_MARKER")
    return data
end
-- Returned API: storage/contracts for C.new; begin(scope), markNative(sharedId,
-- role,XMLFile), writePayload(sharedId,role,payload), endScope(sharedId). Scope
-- is {lineage,generation,checkpointId,sharedSaveId,sequence=<broker sequence>}.
-- Callbacks are evidence-free until C.finish reloads every physical file.
-- Existing identity writers additionally call markIdentityOwner/shared system
-- helpers before their normal native save. writePayload(identity) runs AFTER
-- that complete engine save reached disk (including the original career mark).
-- No hook or callback ordering is installed by this module itself.
local function new(options)
    if type(options)~="table" or not text(options.directory) or not text(options.lineage)
        or not text(options.monthSeedFingerprint) then return nil,"MARKET_SAVE_OPTIONS_REQUIRED"end
    -- Actual animal persistence lives inside placeables/vehicles. There is no
    -- default guessed Animal XML path. A server integration must supply a real
    -- XML inspector; a portable keys list or payloadValidated flag is not it.
    if type(options.inspectAnimals)~="function"then return nil,"NATIVE_ANIMAL_INSPECTOR_UNSUPPORTED"end
    local inspectAnimals=options.inspectAnimals
    local lineage=options.lineage
    local monthSeedFingerprint,allowTestCatalog=options.monthSeedFingerprint,options.allowTestCatalog==true
    local io=options.io or {}
    if type(io)~="table"then return nil,"NATIVE_SAVE_IO_REQUIRED"end
    local exists=io.exists or fileExists
    local load=io.load or (XMLFile and XMLFile.loadIfExists)
    local create=io.create or (XMLFile and XMLFile.create)
    if type(exists)~="function" or type(load)~="function" or type(create)~="function"then return nil,"NATIVE_SAVE_IO_REQUIRED"end
    local attributeNames=options.attributeNames or function(xml,root)
        need(type(getXMLNumOfAttributes)=="function" and type(getXMLAttributeName)=="function" and type(xml.getHandle)=="function","NATIVE_ATTRIBUTE_INSPECTION_UNSUPPORTED")
        local list={};local handle=xml:getHandle()
        for i=0,getXMLNumOfAttributes(handle,root)-1 do list[#list+1]=getXMLAttributeName(handle,root,i)end
        return list
    end
    local dir=options.directory:gsub('/+$','')
    local paths={career=dir.."/careerSavegame.xml",animals=A.ANIMALS_PATH}
    for role in pairs(roots)do if role~="career"then paths[role]=dir.."/"..role..".xml"end end
    for _,role in ipairs(roles)do paths[role]=dir.."/"..filenames[role]end
    local identityPersistence=RLAnimalIdentityPersistence
    if type(identityPersistence)~="table" or type(identityPersistence.readLedger)~="function" or type(identityPersistence.readJournal)~="function"then return nil,"IDENTITY_OWNER_CODEC_REQUIRED"end
    local ownerPath=dir.."/"..identityPersistence.FILENAME
    local identityJournals={dir.."/"..identityPersistence.JOURNAL_FILENAME,dir.."/"..identityPersistence.JOURNAL_PENDING_FILENAME}
    local extra=cp(options.extraJournalPaths or {})
    local count=0;local seen={}
    for index,path in pairs(extra)do count=count+1;if not integer(index,1) or index>#extra or not text(path) or seen[path]then return nil,"INVALID_EXTRA_JOURNAL_PATHS"end;seen[path]=true end
    if count~=#extra then return nil,"INVALID_EXTRA_JOURNAL_PATHS"end
    -- Required identity journals are independently read/verified below, never
    -- suppressed by the optional list of additional unknown sidecars.
    for i=#extra,1,-1 do if extra[i]==identityJournals[1] or extra[i]==identityJournals[2]then table.remove(extra,i)end end
    local contracts={careerPath=paths.career,participants={}}
    for role,path in pairs(paths)do if role~="career"then contracts.participants[role]={path=path,schemaVersion=role=="acquisition" and 2 or 1}end end
    local function validateMonths(payload)
        keys(payload,{schemaVersion=true,kind=true,seedFingerprint=true,currentAbsoluteMonth=true,months=true,revision=true})
        need(payload.schemaVersion==1 and payload.kind=="BROKER_MONTH_HISTORY" and payload.seedFingerprint==monthSeedFingerprint
            and integer(payload.currentAbsoluteMonth,0) and type(payload.months)=="table","INVALID_SAVED_MONTH_HISTORY")
        local unhashed=cp(payload);unhashed.revision=nil
        need(payload.revision==RLMarketData.fingerprint(unhashed),"SAVED_MONTH_REVISION_MISMATCH")
        local current=false
        for key,entry in pairs(payload.months)do
            local valid,why=RLBrokerDemand.validateSnapshot(entry);need(valid~=nil,why)
            need(type(key)=="string" and key==string.format('%.0f',entry.absoluteMonth) and entry.absoluteMonth<=payload.currentAbsoluteMonth
                and entry.seedFingerprint==payload.seedFingerprint and (not entry.testOnly or allowTestCatalog),"SAVED_MONTH_SCOPE_MISMATCH")
            if entry.absoluteMonth==payload.currentAbsoluteMonth then current=true end
        end
        need(current,"SAVED_MONTH_CURRENT_MISSING")
    end
    local function validateWrapper(value)
        local okay=pcall(function()
            local v=cp(value)
            keys(v,{schemaVersion=true,kind=true,role=true,scope=true,sequence=true,payload=true,ownerEvidence=true})
            need(v.schemaVersion==1 and v.kind=="MARKET_PARTICIPANT" and filenames[v.role]~=nil,"INVALID_MARKET_PARTICIPANT")
            scope(v.scope);need(v.scope.lineage==lineage and v.sequence==v.scope.generation,"MARKET_PARTICIPANT_ARCHIVE_SEQUENCE")
            if v.role=="identity"then
                need(type(RLAnimalIdentity)=="table" and type(RLAnimalIdentity.import)=="function","IDENTITY_VALIDATOR_REQUIRED")
                need(RLAnimalIdentity.import(v.payload)~=nil,"INVALID_SAVED_IDENTITY")
                local owner=v.ownerEvidence
                keys(owner,{path=true,length=true,digest=true,meta=true,sharedScope=true,writerSequence=true,journals=true,participants=true,careerIdentityMarker=true})
                keys(owner.meta,{lineage=true,generation=true,digest=true})
                need(owner.path==ownerPath and integer(owner.length,1) and text(owner.digest) and type(owner.meta)=="table"
                    and owner.meta.lineage==v.payload.lineage and owner.meta.generation==v.payload.generation
                    and owner.writerSequence==v.payload.writerSequence and same(owner.sharedScope,v.scope) and type(owner.journals)=="table"
                    and type(owner.participants)=="table" and text(owner.meta.digest)
                    and owner.careerIdentityMarker==owner.meta.lineage..":"..string.format('%.0f',owner.meta.generation),"IDENTITY_OWNER_EVIDENCE_REQUIRED")
                keys(owner.participants,{placeables=true,vehicles=true,farms=true,animalSystem=true})
                for _,name in ipairs({"placeables","vehicles","farms","animalSystem"})do
                    local evidence=owner.participants[name];keys(evidence,{path=true,length=true,digest=true})
                    need(evidence.path==(paths[name] or dir.."/rm_RlAnimalSystem.xml") and integer(evidence.length,1) and text(evidence.digest),"INVALID_IDENTITY_PARTICIPANT_EVIDENCE")
                end
                keys(owner.journals,{[identityJournals[1]]=true,[identityJournals[2]]=true})
                for _,evidence in pairs(owner.journals)do
                    keys(evidence,{length=true,digest=true,meta=true,data=true})
                    keys(evidence.meta,{lineage=true,generation=true,digest=true})
                    keys(evidence.data,{lineage=true,generation=true,sequence=true,keys=true})
                    need(integer(evidence.length,1) and text(evidence.digest) and text(evidence.meta.digest)
                        and evidence.meta.lineage==owner.meta.lineage and integer(evidence.meta.generation,0)
                        and evidence.meta.generation<owner.meta.generation and evidence.data.lineage==evidence.meta.lineage
                        and evidence.data.generation==evidence.meta.generation and integer(evidence.data.sequence,0)
                        and evidence.data.sequence<=owner.writerSequence and type(evidence.data.keys)=="table","INVALID_ABSORBED_IDENTITY_JOURNAL")
                    local n,known=0,{}
                    for index,key in pairs(evidence.data.keys)do
                        n=n+1;need(integer(index,1) and index<=#evidence.data.keys and text(key) and not known[key] and v.payload.keys[key]~=nil,"INVALID_ABSORBED_IDENTITY_KEYS");known[key]=true
                    end
                    need(n==#evidence.data.keys,"SPARSE_ABSORBED_IDENTITY_KEYS")
                end
                local main,pending=owner.journals[identityJournals[1]],owner.journals[identityJournals[2]]
                need(pending==nil or (main~=nil and same(main.data,pending.data)),"IDENTITY_JOURNAL_PENDING_UNCONFIRMED")
            elseif v.ownerEvidence~=nil then error("UNEXPECTED_OWNER_EVIDENCE",0)
            end
            if v.role=="acquisition"then need(RLAnimalAcquisition.new():restore(v.payload)==true,"INVALID_SAVED_ACQUISITION")
            elseif v.role=="broker"then
                need(RLBrokerTransaction.validateDocument(v.payload)==true and v.payload.sequence==v.scope.sequence,"INVALID_SAVED_BROKER")
            elseif v.role=="months"then validateMonths(v.payload)end
        end)
        return okay
    end
    local native,why=RLBrokerNativeStorage.new({exists=exists,load=load,create=create,validatePayload=validateWrapper})
    if native==nil then return nil,why end
    local stores={}
    for _,role in ipairs(roles)do
        stores[role]=assert(RLBrokerPersistence.newStore(native,{path=paths[role],kind="CHECKPOINT",lineage=lineage,
            generation=0,checkpointId="MARKET_SAVE_ARCHIVE:"..role,validatePayload=validateWrapper}))
    end
    local busy,active=false,nil
    local nativeMarked={}
    local cache={};for role in pairs(paths)do cache[role]={}end
    local function withXML(path,fn)
        need(exists(path)==true,"NATIVE_PARTICIPANT_MISSING")
        local xml=load("rlMarketSaveRead",path);need(xml~=nil,"NATIVE_PARTICIPANT_LOAD_FAILED")
        local okay,value,second=pcall(fn,xml)
        local cleanup,result=pcall(function()return xml:delete()end)
        need(cleanup and result~=false,"NATIVE_SAVE_DELETE_UNCERTAIN")
        need(okay,tostring(value));return value,second
    end
    local function marketAttributes(xml,root,allowed)
        local names=attributeNames(xml,root);need(type(names)=="table","NATIVE_ATTRIBUTE_NAMES_REQUIRED")
        for _,name in ipairs(names)do need(type(name)=="string" and (not name:match('^rlMarket') or name==allowed),"UNKNOWN_MARKET_NATIVE_ATTRIBUTE")end
        need(type(xml.getNumOfChildren)=="function" and type(xml.getElementName)=="function","NATIVE_CHILD_INSPECTION_UNSUPPORTED")
        -- Mirrors FS25 XMLFile.iterateRecursively (dataS/scripts/xml/XMLFile.lua):
        -- getXMLNumOfChildren(handle,path), then getXMLElementName(handle,
        -- path..".*("..i..")"). These XMLFile methods are the native wrappers.
        for i=0,xml:getNumOfChildren(root)-1 do
            local name=xml:getElementName(root..".*("..i..")")
            need(type(name)=="string" and not name:match('^rlMarket'),"UNKNOWN_MARKET_NATIVE_NODE")
        end
    end
    local function readNative(role)
        return withXML(paths[role],function(xml)
            local root=roots[role];local attr=role=="career" and A.CAREER_MARKER or A.NATIVE_MARKER
            marketAttributes(xml,root,attr)
            local raw=xml:getAsString();need(type(raw)=="string" and #raw<=RLBrokerNativeStorage.MAX_BYTES,"NATIVE_PARTICIPANT_UNREADABLE")
            local marker=xml:getString(root.."#"..attr)
            local entry={}
            if role=="career"then
                if marker~=nil then entry.proof=decoded(marker)end
                need(type(xml.removeProperty)=="function","NATIVE_REMOVE_PROPERTY_UNSUPPORTED")
                xml:removeProperty(root.."#"..attr)
                need(xml:getString(root.."#"..attr)==nil,"CAREER_PROOF_NOT_REMOVED_IN_MEMORY")
                entry.body=xml:getAsString();need(type(entry.body)=="string","CAREER_BODY_UNREADABLE")
            else
                entry.marker=decoded(marker)
                keys(entry.marker,{schemaVersion=true,role=true,lineage=true,generation=true,checkpointId=true,sharedSaveId=true,sequence=true})
                local saved=cp(entry.marker);saved.schemaVersion=nil;saved.role=nil;scope(saved)
                need(entry.marker.schemaVersion==1 and entry.marker.role==role,"NATIVE_MARKER_ROLE_MISMATCH")
                if role=="placeables" or role=="vehicles"then
                    local animals=cp(inspectAnimals(xml,role))
                    need(type(animals)=="table","NATIVE_ANIMAL_INSPECTION_FAILED")
                    local n,keysSeen=0,{}
                    for i,key in pairs(animals)do
                        n=n+1;need(integer(i,1) and i<=#animals and text(key) and not keysSeen[key],"INVALID_NATIVE_ANIMAL_LIST")
                        local herd,id,country=RLAnimalIdentity.parseKey(key)
                        need(herd~=nil and RLAnimalIdentity.keyString(herd,id,country)==key,"INVALID_NATIVE_ANIMAL_KEY")
                        keysSeen[key]=true
                    end
                    need(n==#animals,"SPARSE_NATIVE_ANIMAL_LIST");table.sort(animals);entry.animals=animals
                end
            end
            -- C pairs read/inspect immediately. Retaining old serialized native
            -- files here would grow with every save and authorize stale reads.
            cache[role]={[raw]=entry}
            return raw
        end)
    end
    -- The identity subsystem owns its own generation. Its real checkpoint XML
    -- must carry this save's common marker and exactly the exported ledger
    -- being archived; equality of independently numbered generations is never
    -- accepted as a relationship between the two save protocols.
    local function identityOwner(payload,sharedScope)
        need(exists(ownerPath)==true,"IDENTITY_OWNER_EVIDENCE_REQUIRED")
        local result=withXML(ownerPath,function(xml)
            marketAttributes(xml,identityPersistence.ROOT,A.NATIVE_MARKER)
            local markerText=xml:getString(identityPersistence.ROOT.."#"..A.NATIVE_MARKER)
            need(type(markerText)=="string","IDENTITY_OWNER_EVIDENCE_REQUIRED")
            local marker=decoded(markerText)
            keys(marker,{schemaVersion=true,role=true,lineage=true,generation=true,checkpointId=true,sharedSaveId=true,sequence=true})
            need(marker.schemaVersion==1 and marker.role=="identity","IDENTITY_OWNER_EVIDENCE_REQUIRED")
            marker.schemaVersion=nil;marker.role=nil
            need(same(marker,sharedScope),"IDENTITY_OWNER_SHARED_SAVE_MISMATCH")
            local doc,reason=identityPersistence.readLedger(xml);need(doc~=nil,reason or "IDENTITY_OWNER_EVIDENCE_REQUIRED")
            keys(doc.data,{schema=true,lineage=true,generation=true,mode=true,ledger=true,participants=true,recovery=true})
            need(doc.data.schema==identityPersistence.SCHEMA and doc.data.recovery==nil
                and (doc.data.mode=="ON" or doc.data.mode=="OFF" or doc.data.mode=="SHADOW"),"IDENTITY_OWNER_RECOVERY_OR_SCHEMA")
            need(same(doc.data.ledger,payload) and doc.meta.lineage==payload.lineage and doc.meta.generation==payload.generation,"IDENTITY_OWNER_LEDGER_MISMATCH")
            local raw=xml:getAsString();need(type(raw)=="string" and #raw<=RLBrokerNativeStorage.MAX_BYTES,"IDENTITY_OWNER_UNREADABLE")
            return {path=ownerPath,length=#raw,digest=RLTradePersistence.checksum(raw),meta=cp(doc.meta),sharedScope=cp(sharedScope),writerSequence=payload.writerSequence,journals={},participants=cp(doc.data.participants)}
        end)
        local identityParticipants={placeables={path=paths.placeables,root=roots.placeables,role="placeables"},
            vehicles={path=paths.vehicles,root=roots.vehicles,role="vehicles"},farms={path=paths.farms,root=roots.farms,role="farms"},
            animalSystem={path=dir.."/rm_RlAnimalSystem.xml",root="rm_RlAnimalSystem",role="identitySystem"}}
        local ownerParticipants=result.participants;result.participants={}
        result.careerIdentityMarker=withXML(paths.career,function(xml)
            local marker=xml:getString(roots.career.."#"..A.IDENTITY_MARKER)
            need(marker==result.meta.lineage..":"..string.format('%.0f',result.meta.generation),"IDENTITY_OWNER_CAREER_GENERATION")
            return marker
        end)
        for name,spec in pairs(identityParticipants)do
            need(ownerParticipants[name]==true,"IDENTITY_OWNER_PARTICIPANT_NOT_SAVED")
            result.participants[name]=withXML(spec.path,function(xml)
                marketAttributes(xml,spec.root,A.NATIVE_MARKER)
                need(xml:getString(spec.root.."#"..A.IDENTITY_MARKER)==result.meta.lineage..":"..string.format('%.0f',result.meta.generation),"IDENTITY_OWNER_PARTICIPANT_GENERATION")
                local marker=decoded(xml:getString(spec.root.."#"..A.NATIVE_MARKER))
                need(marker.schemaVersion==1 and marker.role==spec.role,"IDENTITY_OWNER_PARTICIPANT_SCOPE")
                marker.schemaVersion=nil;marker.role=nil
                need(same(marker,sharedScope),"IDENTITY_OWNER_PARTICIPANT_SCOPE")
                local raw=xml:getAsString();need(type(raw)=="string" and #raw<=RLBrokerNativeStorage.MAX_BYTES,"IDENTITY_OWNER_PARTICIPANT_UNREADABLE")
                return {path=spec.path,length=#raw,digest=RLTradePersistence.checksum(raw)}
            end)
        end
        local journals={}
        for _,path in ipairs(identityJournals)do
            local present=exists(path);need(type(present)=="boolean","IDENTITY_JOURNAL_EXISTENCE_UNCERTAIN")
            if present then
                journals[path]=withXML(path,function(xml)
                    local doc,reason=identityPersistence.readJournal(xml);need(doc~=nil,reason or "IDENTITY_JOURNAL_UNREADABLE")
                    need(doc.meta.lineage==result.meta.lineage and doc.meta.generation<result.meta.generation
                        and doc.data.sequence<=payload.writerSequence,"IDENTITY_JOURNAL_NOT_ABSORBED")
                    for _,key in ipairs(doc.data.keys)do need(payload.keys[key]~=nil,"IDENTITY_JOURNAL_KEY_NOT_ABSORBED")end
                    local raw=xml:getAsString();need(type(raw)=="string" and #raw<=RLBrokerNativeStorage.MAX_BYTES,"IDENTITY_JOURNAL_UNREADABLE")
                    return {length=#raw,digest=RLTradePersistence.checksum(raw),meta=cp(doc.meta),data=cp(doc.data)}
                end)
            end
        end
        local main,pending=journals[identityJournals[1]],journals[identityJournals[2]]
        need(pending==nil or (main~=nil and same(main.data,pending.data)),"IDENTITY_JOURNAL_PENDING_UNCONFIRMED")
        result.journals=journals
        return result
    end
    local function readLedger(role)
        local wrapper,failure=stores[role].read();need(wrapper~=nil,failure)
        need(wrapper.role==role and validateWrapper(wrapper),"SAVED_PARTICIPANT_ROLE_MISMATCH")
        if role=="identity"then need(same(identityOwner(wrapper.payload,wrapper.scope),wrapper.ownerEvidence),"IDENTITY_OWNER_EVIDENCE_CHANGED")end
        local raw=assert(native.read(paths[role]))
        local envelope=assert(RLBrokerPersistence.decode(raw,validateWrapper))
        need(same(envelope.payload,wrapper),"PARTICIPANT_CHANGED_DURING_READ")
        cache[role]={[raw]=cp(wrapper)}
        return raw
    end
    local function animalsManifest()
        local files,common,all={},nil,{}
        for _,role in ipairs({"placeables","vehicles"})do
            local raw=readNative(role);local entry=cache[role][raw]
            local marker=cp(entry.marker);marker.role=nil
            if common then need(same(common,marker),"NATIVE_ANIMAL_SAVE_COHORT_MISMATCH")else common=marker end
            for _,key in ipairs(entry.animals)do need(not all[key],"NATIVE_ANIMAL_DUPLICATE_ACROSS_FILES");all[key]=true end
            files[role]={path=paths[role],length=#raw,digest=RLTradePersistence.checksum(raw),animals=entry.animals}
        end
        local manifest={schemaVersion=1,kind="NATIVE_ANIMALS_DERIVED_MANIFEST",files=files,marker=common}
        local raw=RLTradePersistence.canonical(manifest)
        local marker=cp(common);marker.role="animals";cache.animals={[raw]=marker}
        return raw
    end
    local function guarded(fn,...)
        if busy then return nil,"MARKET_SAVE_ADAPTER_BUSY"end
        busy=true;local okay,value,why=pcall(fn,...);busy=false
        if not okay then return nil,tostring(value)end;return value,why
    end
    local storage={}
    function storage.read(path)
        return guarded(function()
            for role,actual in pairs(paths)do if path==actual then
                if role=="animals"then return animalsManifest()elseif roots[role]then return readNative(role)else return readLedger(role)end
            end end
            error("UNDECLARED_MARKET_SAVE_PATH",0)
        end)
    end
    function storage.inspectParticipant(role,raw,contract)
        return guarded(function()
            need(contracts.participants[role]~=nil and same(contract,contracts.participants[role]),"SAVE_CONTRACT_MISMATCH")
            local entry=cache[role][raw];need(entry~=nil,"REAL_PARTICIPANT_READ_REQUIRED")
            if roots[role] or role=="animals"then return cp(role=="animals" and entry or entry.marker)end
            local marker=cp(entry.scope);marker.role=role;marker.schemaVersion=contract.schemaVersion
            marker.payload=cp(entry.payload);marker.payloadValidated=true
            return marker
        end)
    end
    function storage.inspectCareer(raw)return guarded(function()local entry=cache.career[raw];need(entry and entry.proof,"REAL_CAREER_PROOF_READ_REQUIRED");return cp(entry.proof)end)end
    function storage.careerBody(raw)return guarded(function()local entry=cache.career[raw];need(entry and entry.body,"REAL_CAREER_READ_REQUIRED");return entry.body end)end
    function storage.commitCareer(path,proof)
        local value,reason=guarded(function()
            need(path==paths.career and active~=nil,"ACTIVE_SHARED_SAVE_REQUIRED")
            for key,value in pairs(active)do need(proof[key]==value,"CAREER_COMMIT_SCOPE_MISMATCH")end
            return withXML(path,function(xml)
                marketAttributes(xml,roots.career,A.CAREER_MARKER)
                xml:setString(roots.career.."#"..A.CAREER_MARKER,encoded(cp(proof)))
                need(xml:save()==true,"CAREER_COMMIT_SAVE_UNCERTAIN");return true
            end)
        end)
        return value==true,reason
    end
    function storage.journals()
        return guarded(function()
            for _,path in ipairs(extra)do need(exists(path)==false,"UNABSORBED_EXTERNAL_SAVE_JOURNAL:"..path)end
            local list={}
            for _,role in ipairs(roles)do
                readLedger(role)
                local wrapper=assert(stores[role].read())
                local row=cp(wrapper.scope);row.role=role;row.verified=true;row.staging=false;row.payloadDigest=RLBrokerPersistence.digest(wrapper.payload)
                list[#list+1]=row
                if role=="identity"then
                    -- The native journal's independent metadata and full-file
                    -- hash are bound inside ownerEvidence in this archive.
                    -- Each absorbed log references that complete common-save
                    -- participant; its old identity generation is not relabeled
                    -- as a market generation in the underlying evidence.
                    for _ in pairs(wrapper.ownerEvidence.journals)do list[#list+1]=cp(row)end
                end
            end
            return list
        end)
    end
    local api={storage=storage,contracts=cp(contracts),inspectionMode="INJECTED_NATIVE_INSPECTOR",allowEngineSave=true}
    function api.begin(rawScope)
        return guarded(function()
            need(active==nil,"SHARED_SAVE_ALREADY_ACTIVE")
            local s=scope(cp(rawScope));need(s.lineage==lineage,"SAVE_LINEAGE_MISMATCH");active=s;nativeMarked={}
            return true
        end)
    end
    function api.markNative(sharedSaveId,role,xml)
        return guarded(function()
            need(active~=nil and active.sharedSaveId==sharedSaveId and roots[role]~=nil and role~="career","NATIVE_SAVE_NOT_ACTIVE")
            need(not nativeMarked[role],"DUPLICATE_NATIVE_SAVE_CALLBACK")
            marketAttributes(xml,roots[role],A.NATIVE_MARKER)
            local marker=cp(active);marker.schemaVersion=1;marker.role=role
            xml:setString(roots[role].."#"..A.NATIVE_MARKER,encoded(marker));nativeMarked[role]=true;return true
        end)
    end
    function api.writePayload(sharedSaveId,role,payload)
        return guarded(function()
            need(active~=nil and active.sharedSaveId==sharedSaveId and stores[role]~=nil,"PAYLOAD_SAVE_NOT_ACTIVE")
            local wrapper={schemaVersion=1,kind="MARKET_PARTICIPANT",role=role,scope=cp(active),sequence=active.generation,payload=cp(payload)}
            if role=="identity"then wrapper.ownerEvidence=identityOwner(wrapper.payload,wrapper.scope)end
            need(validateWrapper(wrapper),"INVALID_PARTICIPANT_PAYLOAD")
            local written,reason=stores[role].write(wrapper);need(written,reason);return true
        end)
    end
    -- Call from the existing identity checkpoint writer AFTER writeLedger and
    -- BEFORE its normal save. This only stamps the provided in-memory XMLFile;
    -- no owner metadata is invented and no independent save is started here.
    function api.markIdentityOwner(sharedSaveId,xml)
        return guarded(function()
            need(active~=nil and active.sharedSaveId==sharedSaveId,"IDENTITY_SAVE_NOT_ACTIVE")
            need(not nativeMarked.identity,"DUPLICATE_IDENTITY_SAVE_CALLBACK")
            marketAttributes(xml,identityPersistence.ROOT,A.NATIVE_MARKER)
            local doc,reason=identityPersistence.readLedger(xml);need(doc~=nil,reason)
            local marker=cp(active);marker.schemaVersion=1;marker.role="identity"
            xml:setString(identityPersistence.ROOT.."#"..A.NATIVE_MARKER,encoded(marker));nativeMarked.identity=true;return true
        end)
    end
    -- The existing identity checkpoint also participates through the real
    -- rm_RlAnimalSystem.xml counter file. Its own independent marker is checked
    -- along with the market cohort; no imaginary animals.xml is introduced.
    function api.markIdentitySystem(sharedSaveId,xml)
        return guarded(function()
            need(active~=nil and active.sharedSaveId==sharedSaveId,"IDENTITY_SAVE_NOT_ACTIVE")
            need(not nativeMarked.identitySystem,"DUPLICATE_IDENTITY_SYSTEM_CALLBACK")
            marketAttributes(xml,"rm_RlAnimalSystem",A.NATIVE_MARKER)
            local marker=cp(active);marker.schemaVersion=1;marker.role="identitySystem"
            xml:setString("rm_RlAnimalSystem#"..A.NATIVE_MARKER,encoded(marker));nativeMarked.identitySystem=true;return true
        end)
    end
    -- External engine integration may close an adapter only after C.finish;
    -- this does not release C's freeze gates or attest that any disk write ran.
    function api.endScope(sharedSaveId)
        return guarded(function()need(active~=nil and active.sharedSaveId==sharedSaveId,"SHARED_SAVE_NOT_ACTIVE");active=nil;return true end)
    end
    return api
end
function A.new(options)
    local okay,value,reason=pcall(new,options)
    if not okay then return nil,"MARKET_SAVE_FACTORY_ERROR:"..tostring(value)end
    return value,reason
end
