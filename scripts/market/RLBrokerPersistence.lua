-- Broker-owned portable persistence. No engine hooks, replay, log deletion, or
-- assumption that a successful write is durable. Native storage is injected.
RLBrokerPersistence = {}
local P=RLBrokerPersistence
P.SCHEMA=1
P.LIMITS={maxNodes=500000,maxString=4194304,maxDepth=32}
local T=function() return RLTradePersistence end
local function text(v) return type(v)=="string" and v:match("%S")~=nil end
local function integer(v,min) return type(v)=="number" and v==v and v>=min and v<2^52 and v%1==0 end
local function fail(ok,why) if not ok then error(why,0) end end
local function keys(v,allowed) for k in pairs(v) do fail(allowed[k],"EXTRA_FIELD:"..tostring(k)) end end
local function copy(v)
    fail(T().check(v,P.LIMITS)==nil,"INVALID_PORTABLE_DATA")
    return assert(T().parse(T().canonical(v),P.LIMITS))
end
local function digest(v) return T().checksum(T().canonical(v)) end
P.digest=digest
local function validate(v,validator)
    local d=copy(v)
    fail(d.schemaVersion==1,"UNSUPPORTED_BROKER_SCHEMA")
    keys(d,{schemaVersion=true,kind=true,lineage=true,generation=true,checkpointId=true,sequence=true,payload=true})
    fail(d.kind=="WAL" or d.kind=="CHECKPOINT" or d.kind=="MONTHS" or d.kind=="STAGING","INVALID_DOCUMENT_KIND")
    fail(text(d.lineage) and text(d.checkpointId) and integer(d.generation,0) and integer(d.sequence,0),"INVALID_DOCUMENT_SCOPE")
    fail(type(d.payload)=="table","INVALID_PAYLOAD")
    if d.kind=="STAGING" then
        local p=d.payload
        keys(p,{phase=true,previous=true,proposed=true,proposedDigest=true})
        fail((p.phase=="STAGED" or p.phase=="COMPLETED") and type(p.previous)=="string" and type(p.proposed)=="string" and text(p.proposedDigest),"INVALID_STAGING")
        fail(T().checksum(p.proposed)==p.proposedDigest,"INVALID_STAGING_DIGEST")
    else
        local sequence=d.payload.sequence or (d.kind=="MONTHS" and d.payload.currentAbsoluteMonth)
        fail(sequence==d.sequence,"PAYLOAD_SEQUENCE_MISMATCH")
        fail(type(validator)=="function","PAYLOAD_VALIDATOR_REQUIRED")
        local ok,accepted=pcall(validator,copy(d.payload),d.kind)
        fail(ok and accepted==true,"INVALID_BROKER_PAYLOAD")
    end
    return d
end
function P.validate(value,validator)
    local ok,d=pcall(validate,value,validator);if not ok then return nil,tostring(d) end;return d
end
function P.encode(value,validator)
    local d,why=P.validate(value,validator);if not d then return nil,why end
    local body=T().encodeText(T().canonical(d));local sum=T().checksum(body)
    local chunks={}
    for i=1,#body,T().CHUNK do
        local chunk=body:sub(i,i+T().CHUNK-1)
        chunks[#chunks+1]='<chunk index="'..#chunks..'" length="'..#chunk..'" digest="'..T().checksum(chunk)..'" v="'..chunk..'"/>'
    end
    return '<rlBrokerDocument schema="1" length="'..#body..'" digest="'..sum..'">'..table.concat(chunks)..'</rlBrokerDocument>'
end
function P.decode(xml,validator)
    local ok,result=pcall(function()
        fail(type(xml)=="string" and #xml<=64*1024*1024,"INVALID_BROKER_XML")
        -- Generated ASCII only. Reconstructing the exact grammar rejects extra
        -- attributes/nodes, duplicate/reordered chunks, trailing data and edits.
        local schema,length,sum,inside=xml:match('^<rlBrokerDocument schema="(%d+)" length="(%d+)" digest="(%x+)">(.*)</rlBrokerDocument>$')
        fail(schema=="1","UNSUPPORTED_BROKER_SCHEMA")
        local parts,pos,index={},1,0
        while pos<=#inside do
            local a,b,i,n,h,v=inside:find('<chunk index="(%d+)" length="(%d+)" digest="(%x+)" v="([^"]*)"/>',pos)
            fail(a==pos and tonumber(i)==index and tostring(index)==i and tonumber(n)==#v and tostring(#v)==n and #v>0 and #v<=T().CHUNK,"BAD_CHUNK")
            fail(T().checksum(v)==h,"CHUNK_DIGEST_MISMATCH")
            parts[#parts+1]=v;pos=b+1;index=index+1
        end
        local encoded=table.concat(parts)
        fail(tostring(#encoded)==length and T().checksum(encoded)==sum,"BROKER_LENGTH_OR_DIGEST_MISMATCH")
        local canonical=T().decodeText(encoded);fail(canonical~=nil,"BAD_BROKER_ENCODING")
        fail(T().encodeText(canonical)==encoded,"NONCANONICAL_BROKER_ENCODING")
        local d,why=T().parse(canonical,P.LIMITS);fail(d~=nil,why)
        fail(T().canonical(d)==canonical,"NONCANONICAL_BROKER_DATA")
        return validate(d,validator)
    end)
    if not ok then return nil,tostring(result) end;return result
end

-- storage.read(path) -> exact XML text or nil,"NOT_FOUND";
-- storage.write(path,text) -> true only after its synchronous write completed.
-- Completed staging remains as evidence; no slot or historical payload is deleted.
function P.newStore(storage,options)
    if type(storage)~="table" or type(storage.read)~="function" or type(storage.write)~="function" or type(options)~="table"
        or not text(options.path) or type(options.validatePayload)~="function" then return nil,"BROKER_STORAGE_REQUIRED" end
    local path,stage=options.path,options.path..".staging"
    local scope={lineage=options.lineage,generation=options.generation,checkpointId=options.checkpointId,kind=options.kind}
    local validatePayload=options.validatePayload
    if not text(scope.lineage) or not integer(scope.generation,0) or not text(scope.checkpointId)
        or (scope.kind~="WAL" and scope.kind~="CHECKPOINT" and scope.kind~="MONTHS") then return nil,"INVALID_STORE_SCOPE" end
    local blocked,evidence,busy=false,nil,false
    local function same(d)
        return d.kind==scope.kind and d.lineage==scope.lineage and d.generation==scope.generation and d.checkpointId==scope.checkpointId
    end
    local function readPath(name)
        local value,why=storage.read(name)
        if value==nil and why~="NOT_FOUND" then error("STORAGE_READ_UNCERTAIN",0) end
        return value
    end
    local function load()
        if blocked then return nil,"RECOVERY_REQUIRED" end
        local primary,pending=readPath(path),readPath(stage)
        evidence={primary=primary,staging=pending}
        if not primary and not pending then return nil,"NOT_FOUND" end
        if not primary then error("STAGING_WITHOUT_PRIMARY",0) end
        local d,why=P.decode(primary,validatePayload);fail(d~=nil,why);fail(same(d),"STORE_SCOPE_MISMATCH")
        fail(pending~=nil,"MISSING_STAGING_COMPLETION_EVIDENCE")
        local s; s,why=P.decode(pending);fail(s~=nil,why)
        fail(s.kind=="STAGING" and s.lineage==scope.lineage and s.generation==scope.generation and s.checkpointId==scope.checkpointId
            and s.sequence==d.sequence and s.payload.phase=="COMPLETED" and s.payload.proposed==primary,"INCOMPLETE_OR_MIXED_STAGING")
        if s.payload.previous~="" then
            local previous;previous,why=P.decode(s.payload.previous,validatePayload)
            fail(previous~=nil and same(previous) and previous.sequence<d.sequence,"INVALID_PREVIOUS_SLOT_EVIDENCE")
        end
        return d
    end
    local function guarded(fn)
        if busy then return nil,"BROKER_STORE_BUSY" end
        busy=true
        local ok,value,why=pcall(fn)
        busy=false
        if not ok then blocked=true;return nil,tostring(value) end
        return value,why
    end
    local api={}
    function api.readEnvelope() return guarded(load) end
    function api.read()
        local d,why=api.readEnvelope();if not d then return nil,why end
        return copy(d.payload)
    end
    function api.write(payload)
        local okay,why=guarded(function()
            local old,missing=load();fail(old~=nil or missing=="NOT_FOUND",missing)
            local p=copy(payload);local sequence=p.sequence or (scope.kind=="MONTHS" and p.currentAbsoluteMonth)
            fail(integer(sequence,0),"PAYLOAD_SEQUENCE_REQUIRED")
            if old then
                if sequence==old.sequence and T().canonical(p)==T().canonical(old.payload) then return true end
                fail(sequence>old.sequence,"SEQUENCE_NOT_ADVANCED")
            end
            local d={schemaVersion=1,kind=scope.kind,lineage=scope.lineage,generation=scope.generation,checkpointId=scope.checkpointId,sequence=sequence,payload=p}
            local proposed,bad=P.encode(d,validatePayload);fail(proposed~=nil,bad)
            local previous=old and assert(P.encode(old,validatePayload)) or ""
            local s={schemaVersion=1,kind="STAGING",lineage=scope.lineage,generation=scope.generation,checkpointId=scope.checkpointId,sequence=sequence,
                payload={phase="STAGED",previous=previous,proposed=proposed,proposedDigest=T().checksum(proposed)}}
            local staged=assert(P.encode(s));evidence={previous=previous,staged=staged,proposed=proposed}
            fail(storage.write(stage,staged)==true and readPath(stage)==staged,"STAGING_WRITE_OR_READBACK_FAILED")
            fail(storage.write(path,proposed)==true and readPath(path)==proposed,"PRIMARY_WRITE_OR_READBACK_FAILED")
            s.payload.phase="COMPLETED";local completed=assert(P.encode(s))
            fail(storage.write(stage,completed)==true and readPath(stage)==completed,"COMPLETION_WRITE_OR_READBACK_FAILED")
            fail(load()~=nil,"FINAL_STORE_READBACK_FAILED")
            return true
        end)
        return okay==true,why
    end
    function api.status() return {state=blocked and "RECOVERY_REQUIRED" or "READY",busy=busy,evidence=evidence and copy(evidence) or nil} end
    return api
end
