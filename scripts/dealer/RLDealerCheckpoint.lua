-- Actual engine save hooks for the dormant dealer runtime. This is asynchronous
-- save validation, NEVER a synchronous durable RLDealerPurchase.checkpoint adapter.
RLDealerCheckpoint = {}
local C = RLDealerCheckpoint
C.MARKER = "rlDealerStockCheckpoint"
C.MAX_FILE_BYTES = 64 * 1024 * 1024
C.DISABLED,C.UNARMED,C.ARMED,C.LOADING,C.READY,C.RECOVERY_REQUIRED = "DISABLED","UNARMED","ARMED","LOADING","READY","RECOVERY_REQUIRED"
local roles={"placeables","vehicles","farms"}
local function clone(v) if type(v) ~= "table" then return v end; local o={}; for k,x in pairs(v) do o[k]=clone(x) end; return o end
local function defaultStorage()
    return {
        exists=function(path) return fileExists(path) end,
        read=function(path)
            local h=io.open(path,"rb"); if not h then return nil end
            local text=h:read(C.MAX_FILE_BYTES+1);h:close()
            if not text or #text>C.MAX_FILE_BYTES then return nil end
            return text
        end,
        load=function(path) return XMLFile.loadIfExists("rlDealerCheckpointRead",path) end,
        create=function(path) return XMLFile.create("rlDealerCheckpointWrite",path,RLDealerPersistence.ROOT) end,
        careerSet=function(handle,key,value) setXMLString(handle,key,value) end,
    }
end
local function storage() return C.runtime and C.runtime.storage or defaultStorage() end
local function active() return C.state~=C.DISABLED and C.runtime~=nil and C.armed end
local function close(reason,evidence)
    C.state,C.reason=C.RECOVERY_REQUIRED,reason
    if evidence then C.quarantine=evidence end
end
function C.reset(isServer,runtime)
    C.runtime=runtime;C.server=isServer==true;C.armed=false;C.lineage=nil;C.generation=0
    C.pass,C.last,C.quarantine=nil,nil,nil
    C.state,C.reason=C.server and C.LOADING or C.DISABLED,C.server and "WAITING_FOR_MISSION" or "CLIENT"
end
function C.setRuntime(runtime) C.runtime=runtime end
function C.admit() return C.state==C.READY and C.pass==nil and not (C.last and C.last.status=="WRITTEN") end
function C.arm(lineage)
    if not C.server or C.runtime==nil or C.state~=C.UNARMED then return nil,"NOT_ARMABLE" end
    if type(lineage)~="string" or not lineage:match("^DL[%w%-]+$") then return nil,"BAD_LINEAGE" end
    C.armed,C.lineage,C.state,C.reason=true,lineage,C.ARMED,"AWAITING_FIRST_VERIFIED_SAVE"
    return true
end
local function readParticipant(directory,role,lineage,generation)
    local ioAdapter=storage();local path=directory .. "/" .. role .. ".xml"
    local x=ioAdapter.load(path);if not x then return nil,"MISSING_PARTICIPANT:" .. role end
    local marker=x:getString(role .. "#" .. C.MARKER);x:delete()
    local wanted=lineage .. ":" .. tostring(generation)
    if marker~=wanted then return nil,"PARTICIPANT_GENERATION:" .. role end
    local text=ioAdapter.read(path);if not text then return nil,"PARTICIPANT_UNREADABLE:" .. role end
    return {lineage=lineage,generation=generation,checkpointId=wanted,digest=RLTradePersistence.checksum(text)}
end
local function readCareer(directory)
    local x=storage().load(directory .. "/careerSavegame.xml");if not x then return nil,"MISSING_CAREER" end
    local encoded=x:getString("careerSavegame#" .. C.MARKER);x:delete()
    if type(encoded)~="string" then return nil,"MISSING_CAREER_MARKER" end
    local text=RLTradePersistence.decodeText(encoded);if not text then return nil,"BAD_CAREER_MARKER" end
    return RLTradePersistence.parse(text)
end
function C.verifyDisk(directory,expected,resolver)
    if type(directory)~="string" then return nil,"NO_DIRECTORY" end
    local career,why=readCareer(directory);if not career then return nil,why end
    if expected and (career.lineage~=expected.lineage or career.generation~=expected.generation
        or career.dealerStockDigest~=expected.digest) then return nil,"LATE_OR_MIXED_COMPLETION" end
    local participants={}
    for _,role in ipairs(roles) do
        participants[role],why=readParticipant(directory,role,career.lineage,career.generation)
        if not participants[role] then return nil,why end
    end
    local x=storage().load(directory .. "/" .. RLDealerPersistence.FILENAME)
    if not x then return nil,"MISSING_DEALER_DOCUMENT" end
    local doc,q;doc,why,q=RLDealerPersistence.readDocument(x,participants,resolver,career);x:delete()
    return doc,why,q
end
function C.onSaveBegin(missionInfo)
    if not active() then return end
    if C.state==C.RECOVERY_REQUIRED or C.state==C.LOADING then return end
    if C.pass or (C.last and C.last.status=="WRITTEN") then
        -- No generation re-use or newer pass while an old async save is pending.
        close("OVERLAPPING_SAVE");return
    end
    if type(C.runtime.getSnapshot)~="function" then close("NO_SNAPSHOT_RUNTIME");return end
    C.generation=C.generation+1
    local meta={lineage=C.lineage,generation=C.generation,parentGeneration=C.generation-1,
        checkpointId=C.lineage .. ":" .. tostring(C.generation)}
    C.pass={meta=meta,directory=missionInfo.savegameDirectory,participants={}}
    C.state,C.reason="SAVING","WAITING_FOR_PARTICIPANTS"
end
function C.markParticipant(role,xml,root)
    if not C.pass or C.state==C.RECOVERY_REQUIRED then return end
    local allowed={placeables=true,vehicles=true,farms=true}
    if not allowed[role] or xml==nil then close("BAD_PARTICIPANT_HOOK");return end
    xml:setString(root .. "#" .. C.MARKER,C.pass.meta.checkpointId)
    C.pass.participants[role]=true
end
function C.onSaveEnd(missionInfo)
    local pass=C.pass;if not pass then return end
    C.pass=nil
    if C.state==C.RECOVERY_REQUIRED then return end
    local participants,why={},nil
    for _,role in ipairs(roles) do
        if not pass.participants[role] then close("PARTICIPANT_HOOK_MISSING:" .. role);return end
        participants[role],why=readParticipant(pass.directory,role,pass.meta.lineage,pass.meta.generation)
        if not participants[role] then close(why);return end
    end
    local snapshot; snapshot,why=C.runtime.getSnapshot(clone(pass.meta),clone(participants))
    if not snapshot then close("SNAPSHOT_FAILED:" .. tostring(why));return end
    if snapshot.lineage~=pass.meta.lineage or snapshot.generation~=pass.meta.generation then close("SNAPSHOT_GENERATION");return end
    local ioAdapter=storage();local path=pass.directory .. "/" .. RLDealerPersistence.FILENAME
    local x=ioAdapter.create(path);if not x then close("DEALER_WRITE_CREATE_FAILED");return end
    local written,digest=RLDealerPersistence.writeDocument(x,snapshot,participants)
    written=written and x:save()==true;x:delete()
    if not written then close("DEALER_WRITE_FAILED:" .. tostring(digest));return end
    local commit=RLDealerPersistence.commitMarker(snapshot,digest)
    x=ioAdapter.load(path);if not x then close("DEALER_READBACK_MISSING");return end
    local check;check,why=RLDealerPersistence.readDocument(x,participants,C.runtime.resolver,commit);x:delete()
    if not check or check.digest~=digest then close("DEALER_READBACK_FAILED:" .. tostring(why));return end
    if missionInfo.xmlFile==nil or missionInfo.xmlFile==0 then close("NO_CAREER_DOCUMENT");return end
    ioAdapter.careerSet(missionInfo.xmlFile,"careerSavegame#" .. C.MARKER,RLTradePersistence.encodeText(RLTradePersistence.canonical(commit)))
    C.last={lineage=pass.meta.lineage,generation=pass.meta.generation,digest=digest,directory=pass.directory,status="WRITTEN"}
    C.state,C.reason="WAITING_ENGINE","AWAITING_DISK_COMPLETION"
end
function C.onSaveComplete(errorCode,directory,generation)
    if not active() then return end
    local last=C.last
    if generation~=nil and (not last or generation~=last.generation) then close("LATE_COMPLETE");return end
    if C.pass then close("COMPLETE_DURING_SAVE_PASS");return end
    if not last or last.status~="WRITTEN" then return end
    if C.state==C.RECOVERY_REQUIRED then return end
    if Savegame==nil or errorCode~=Savegame.ERROR_OK then last.status="FAILED";close("ENGINE_ERROR");return end
    local doc,why,q=C.verifyDisk(directory or last.directory,last,C.runtime.resolver)
    if not doc then last.status="INCOMPLETE";close("FINAL_READBACK:" .. tostring(why),q);return end
    if doc.sourceResolution~="RESOLVED" and next(doc.data.sources)~=nil then close("SOURCE_RESOLVER_REQUIRED");return end
    if doc.restored.recoveryRequired then last.status="RECOVERY_REQUIRED";close("OWNERSHIP_RECOVERY_REQUIRED",doc);return end
    last.status="COMMITTED";C.state,C.reason=C.READY,"DISK_VERIFIED"
end
function C.onMissionStarted(mission,evidence)
    if not C.server or C.state~=C.LOADING then return end
    if C.runtime==nil then C.state,C.reason=C.DISABLED,"NO_RUNTIME";return end
    local directory=mission.missionInfo and mission.missionInfo.savegameDirectory
    if not directory then close("NO_DIRECTORY");return end
    local path=directory .. "/" .. RLDealerPersistence.FILENAME
    if not storage().exists(path) then
        -- A leftover external/career marker without stock is a broken checkpoint.
        local careerFile=storage().load(directory .. "/careerSavegame.xml")
        if careerFile then
            local marker=careerFile:getString("careerSavegame#" .. C.MARKER);careerFile:delete()
            if marker~=nil then close("MISSING_DEALER_DOCUMENT");return end
        end
        for _,role in ipairs(roles) do
            local x=storage().load(directory .. "/" .. role .. ".xml")
            if x then local marker=x:getString(role .. "#" .. C.MARKER);x:delete();if marker then close("ORPHAN_PARTICIPANT");return end end
        end
        C.state,C.reason=C.UNARMED,"EMPTY_STOCK_CHECKPOINT";return
    end
    C.armed=true;C.state="VERIFYING"
    local doc,why,q=C.verifyDisk(directory,nil,C.runtime.resolver)
    if not doc then close("LOAD:" .. tostring(why),q or {raw=storage().read(path)});return end
    C.lineage,C.generation=doc.data.lineage,doc.data.generation
    if type(evidence)=="table" and type(evidence.identityRepairs)=="number" and evidence.identityRepairs>0 then
        close("IDENTITY_REPAIRS_AFTER_CHECKPOINT",doc);return
    end
    if doc.sourceResolution~="RESOLVED" and next(doc.data.sources)~=nil then close("SOURCE_RESOLVER_REQUIRED",doc);return end
    if doc.restored.recoveryRequired then close("OWNERSHIP_RECOVERY_REQUIRED",doc);return end
    if type(C.runtime.acceptLoaded)~="function" or C.runtime.acceptLoaded(doc.data,doc.restored)~=true then close("LOAD_RUNTIME_REJECTED",doc);return end
    C.state,C.reason=C.READY,"LOADED_VERIFIED"
end
-- Protected wrappers also apply to direct lifecycle calls; failure never aborts
-- the engine save or clears a failed dealer gate.
for _,name in ipairs({"onSaveBegin","markParticipant","onSaveEnd","onSaveComplete","onMissionStarted"}) do
    local fn=C[name]
    C[name]=function(...)
        local ok,a,b=pcall(fn,...)
        if not ok then close("HOOK_FAILED:" .. name .. ":" .. tostring(a));return nil,C.reason end
        return a,b
    end
end
function C.install()
    if C.installed then return end
    C.installed=true
    if FSCareerMissionInfo and FSCareerMissionInfo.saveToXMLFile then
        FSCareerMissionInfo.saveToXMLFile=Utils.prependedFunction(FSCareerMissionInfo.saveToXMLFile,function(self) C.onSaveBegin(self) end)
        FSCareerMissionInfo.saveToXMLFile=Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile,function(self) C.onSaveEnd(self) end)
    end
    if PlaceableSystem and PlaceableSystem.saveToXML then
        PlaceableSystem.saveToXML=Utils.prependedFunction(PlaceableSystem.saveToXML,function(_,xml) C.markParticipant("placeables",xml,"placeables") end)
    end
    if VehicleSystem and VehicleSystem.saveToXML then
        VehicleSystem.saveToXML=Utils.prependedFunction(VehicleSystem.saveToXML,function(_,_,xml) C.markParticipant("vehicles",xml,"vehicles") end)
    end
    if Farm and Farm.saveToXMLFile then
        Farm.saveToXMLFile=Utils.appendedFunction(Farm.saveToXMLFile,function(_,xml) C.markParticipant("farms",xml,"farms") end)
    end
    if SavegameController and SavegameController.onSaveComplete then
        SavegameController.onSaveComplete=Utils.appendedFunction(SavegameController.onSaveComplete,function(controller,code,directory)
            local savegame=controller and controller.currentSavegame
            C.onSaveComplete(code,directory or (savegame and savegame.savegameDirectory))
        end)
    end
end
