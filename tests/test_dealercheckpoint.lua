loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/dealer/RLDealerClock.lua")
loadMod("scripts/dealer/RLDealerListingRegistry.lua")
loadMod("scripts/dealer/RLDealerPurchase.lua")
loadMod("scripts/dealer/RLDealerSourceState.lua")
loadMod("scripts/dealer/RLDealerPersistence.lua")
loadMod("scripts/dealer/RLDealerCheckpoint.lua")
local C,D,T=RLDealerCheckpoint,RLDealerPersistence,RLTradePersistence
Savegame={ERROR_OK=0}
local function clone(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=clone(x) end;return o end
-- XML and storage stand-ins: no engine filesystem/durability claims.
local function fixture()
    local w={disk={},fault=nil,accepted=0,engine=0,writes=0}
    local function document(path,values)
        local x={path=path,values=values or {}}
        function x:getString(k) return self.values[k] end
        function x:setString(k,v) self.values[k]=v end
        function x:delete() end
        function x:save()
            if w.fault=="WRITE" and self.path:find(D.FILENAME,1,true) then return false end
            w.disk[self.path]=clone(self.values);w.writes=w.writes+1;return true
        end
        function x:iterate(prefix,fn)
            local indices={}
            for k in pairs(self.values) do if k:sub(1,#prefix+1)==prefix .. "(" and k:sub(-2)=="#v" then indices[#indices+1]=tonumber(k:match("%((%d+)%)#v$")) end end
            table.sort(indices);for _,i in ipairs(indices) do fn(i,prefix .. "(" .. i .. ")") end
        end
        return x
    end
    local storage={}
    storage.exists=function(path) return w.disk[path]~=nil end
    storage.read=function(path) return w.disk[path] and T.canonical(w.disk[path]) or nil end
    storage.load=function(path)
        if w.fault=="READBACK" and path:find(D.FILENAME,1,true) then return nil end
        return w.disk[path] and document(path,clone(w.disk[path])) or nil
    end
    storage.create=function(path) return document(path) end
    storage.careerSet=function(handle,k,v) handle:setString(k,v) end
    local runtime={storage=storage}
    runtime.getSnapshot=function(meta,participants)
        if w.fault=="BEGIN" then error("snapshot failure") end
        return D.capture(meta,RLDealerClock.new(),RLDealerListingRegistry.new("checkpoint"),{},RLDealerPurchase.new(),participants)
    end
    runtime.acceptLoaded=function() w.accepted=w.accepted+1;return w.fault~="ACCEPT" end
    local info={savegameDirectory="/save",xmlFile=document("/save/careerSavegame.xml")}
    w.info,w.runtime,w.document=info,runtime,document
    function w:pass()
        C.onSaveBegin(info)
        for _,role in ipairs({"placeables","vehicles","farms"}) do
            local x=document("/save/" .. role .. ".xml",{content=role})
            C.markParticipant(role,x,role);x:save()
        end
        C.onSaveEnd(info)
    end
    function w:complete(code)
        info.xmlFile:save();C.onSaveComplete(code or 0,"/save")
    end
    function w:arm()
        C.reset(true,runtime);C.onMissionStarted({missionInfo=info});assert(C.state==C.UNARMED);assert(C.arm("DLcheckpoint"))
    end
    return w
end
local w=fixture();C.reset(true,nil)
C.onMissionStarted({missionInfo=w.info});C.onSaveBegin(w.info);C.onSaveEnd(w.info)
check("dealer checkpoint: default runtime absence causes no dealer write or arming", C.state==C.DISABLED and w.writes==0 and not C.armed)
w=fixture();C.reset(true,w.runtime);C.onMissionStarted({missionInfo=w.info});C.onSaveBegin(w.info)
check("dealer checkpoint: fresh unarmed save has no dealer behavior", C.state==C.UNARMED and C.pass==nil and w.writes==0 and not C.admit())
w=fixture();w:arm();w:pass()
check("dealer checkpoint: synchronous engine pass ends WRITTEN with recovery gate closed", C.last.status=="WRITTEN" and not C.admit() and C.state=="WAITING_ENGINE")
check("dealer checkpoint: participant marker namespace leaves trade checkpoint untouched", w.disk["/save/farms.xml"]["farms#" .. C.MARKER]=="DLcheckpoint:1" and w.disk["/save/farms.xml"]["farms#rlTradeCheckpoint"]==nil)
w:complete()
check("dealer checkpoint: only final actual disk readback opens READY", C.state==C.READY and C.last.status=="COMMITTED" and C.admit())
C.reset(true,w.runtime);C.onMissionStarted({missionInfo=w.info})
check("dealer checkpoint: mission reload imports verified full disk generation once", C.state==C.READY and w.accepted==1 and C.generation==1)
w:pass();w:complete()
check("dealer checkpoint: next completed save advances lineage without reuse", C.generation==2 and C.state==C.READY)
w=fixture();w:arm();w.fault="BEGIN";w:pass()
check("dealer checkpoint: snapshot exception never aborts engine save but closes dealer", C.state==C.RECOVERY_REQUIRED and C.reason:find("HOOK_FAILED",1,true) and w.writes==3)
w=fixture();w:arm();w.fault="WRITE";w:pass()
check("dealer checkpoint: document write fault closes gate without career commit", C.state==C.RECOVERY_REQUIRED and w.info.xmlFile:getString("careerSavegame#" .. C.MARKER)==nil)
w=fixture();w:arm();w.fault="READBACK";w:pass()
check("dealer checkpoint: immediate document readback fault cannot publish career commit", C.state==C.RECOVERY_REQUIRED and w.info.xmlFile:getString("careerSavegame#" .. C.MARKER)==nil)
w=fixture();w:arm();w:pass();w:complete(9)
check("dealer checkpoint: engine completion failure keeps dealer recovery closed", C.state==C.RECOVERY_REQUIRED and C.last.status=="FAILED")
w=fixture();w:arm();w:pass();w.disk["/save/vehicles.xml"].content="changed-after-write";w:complete()
check("dealer checkpoint: final participant content digest detects post-pass corruption", C.state==C.RECOVERY_REQUIRED and C.last.status=="INCOMPLETE")
w=fixture();w:arm();w:pass();C.onSaveComplete(0,"/save")
check("dealer checkpoint: absent engine-serialized career commit cannot become READY", C.state==C.RECOVERY_REQUIRED)
w=fixture();w:arm();w:pass();local generation=C.generation;C.onSaveBegin(w.info)
check("dealer checkpoint: pending async save forbids starting a newer generation", C.generation==generation and C.state==C.RECOVERY_REQUIRED and C.pass==nil)
w:complete()
check("dealer checkpoint: old completion cannot launder overlapping save failure", C.state==C.RECOVERY_REQUIRED and not C.admit())
w=fixture();w:arm();w:pass();w:complete();w:pass();C.onSaveComplete(0,"/save",1)
check("dealer checkpoint: explicitly late old-generation completion cannot commit new save", C.state==C.RECOVERY_REQUIRED and C.last.status=="WRITTEN")
w=fixture();w:arm();C.onSaveBegin(w.info)
local broken=w.document("/save/placeables.xml");broken.setString=function() error("marker fail") end
C.markParticipant("placeables",broken,"placeables")
check("dealer checkpoint: marker hook exceptions are protected and close recovery", C.state==C.RECOVERY_REQUIRED and C.reason:find("HOOK_FAILED",1,true))
w=fixture();w:arm();w:pass();w:complete();w.disk["/save/farms.xml"]["farms#" .. C.MARKER]="DLother:2"
C.reset(true,w.runtime);C.onMissionStarted({missionInfo=w.info})
check("dealer checkpoint: mixed on-load participant generation is quarantined before runtime import", C.state==C.RECOVERY_REQUIRED and w.accepted==0)
w=fixture();w.disk["/save/careerSavegame.xml"]={["careerSavegame#" .. C.MARKER]="malformed"}
C.reset(true,w.runtime);C.onMissionStarted({missionInfo=w.info})
check("dealer checkpoint: orphan malformed career evidence never initializes an empty replacement stock", C.state==C.RECOVERY_REQUIRED and not C.arm("DLnew"))
w=fixture();w:arm();w:pass();w:complete();w.fault="ACCEPT"
C.reset(true,w.runtime);C.onMissionStarted({missionInfo=w.info})
check("dealer checkpoint: runtime rejected ownership import remains closed without automatic recovery", C.state==C.RECOVERY_REQUIRED)
w=fixture();C.reset(false,w.runtime);C.onSaveBegin(w.info);C.onMissionStarted({missionInfo=w.info})
check("dealer checkpoint: clients never save or import authoritative stock", C.state==C.DISABLED and w.writes==0 and w.accepted==0)
-- Installation uses real engine method signatures and protected appended hooks.
local engineCount=0
FSCareerMissionInfo={saveToXMLFile=function() engineCount=engineCount+1 end}
PlaceableSystem={saveToXML=function() end};VehicleSystem={saveToXML=function() end}
Farm={saveToXMLFile=function() end};SavegameController={onSaveComplete=function() engineCount=engineCount+1 end}
Utils=Utils or {}
Utils.prependedFunction=function(base,before) return function(...) before(...);return base(...) end end
Utils.appendedFunction=function(base,after) return function(...) local result=base(...);after(...);return result end end
C.installed=nil;C.install();C.install()
C.reset(true,nil);FSCareerMissionInfo.saveToXMLFile({savegameDirectory="/save"});SavegameController.onSaveComplete({},0,"/save")
check("dealer checkpoint: hook installation is idempotent and preserves base engine calls", engineCount==2)
-- Drive the hooks through checked-in FS25 save-pass excerpts. File IO remains
-- injected; this covers ordering/signatures rather than engine disk durability.
w=fixture()
XMLFile={}
XMLFile.create=function(_,path) return w.document(path) end
createXMLFile=function(_,path) return w.document(path) end
setXMLString=function(handle,key,value) handle:setString(key,value) end
saveXMLFile=function(handle) return handle:save() end
loadMod("tests/fixtures/fs25_save_pass.lua")
w.info.placeablesXML="/save/placeables.xml";w.info.vehiclesXML="/save/vehicles.xml";w.info.farmsXML="/save/farms.xml"
local sourceSaved=false
local snapshotBase=w.runtime.getSnapshot
w.runtime.getSnapshot=function(meta,markers) assert(sourceSaved,"dealer snapshot must follow RLRM AnimalSystem save");return snapshotBase(meta,markers) end
local placeable={saveToXMLFile=function(_,x,key) x:setString(key .. "#animal","pen-animal") end}
local vehicle={getNeedsSaving=function() return true end,saveToXMLFile=function(_,x,key) x:setString(key .. "#animal","trailer-animal") end}
g_currentMission={placeableSystem=setmetatable({placeables={placeable}},PlaceableSystem),vehicleSystem=setmetatable({vehicles={vehicle}},VehicleSystem),
    animalSystem={saveToXMLFile=function() sourceSaved=true end}}
g_farmManager=setmetatable({farms={setmetatable({farmId=1,money=100},Farm)}},FarmManager)
RLSettings={saveToXMLFile=function() end}
-- Fixture Farm requires setInt; add that method to emitted XML objects.
local documentBase=w.document
w.document=function(path,values) local x=documentBase(path,values);x.setInt=x.setString;x.setTable=XMLFile.setTable;return x end
-- Storage closures use the fixture's original document, which only affects our
-- dealer document; engine documents use the wrapper above.
loadMod("scripts/core/FSCareerMissionInfo.lua")
C.installed=nil;C.install();w:arm()
FSCareerMissionInfo.saveToXMLFile(w.info)
check("dealer checkpoint: FS25 excerpt pass calls dealer snapshot after RLRM source save", sourceSaved and C.state=="WAITING_ENGINE" and C.last.status=="WRITTEN")
w.disk["/save/careerSavegame.xml"]=clone(w.info.xmlFile.values) -- engine serializes the filename-less career document
SavegameController.onSaveComplete(nil,0,"/save")
check("dealer checkpoint: real-signature excerpt engine completion verifies all disk participants", C.state==C.READY and C.last.status=="COMMITTED")

w=fixture();w:arm();w:pass();w:complete()
C.reset(true,w.runtime);C.onMissionStarted({missionInfo=w.info},{identityRepairs=1})
check("dealer checkpoint: repaired live identities quarantine existing stock before accepting old ownership receipts", C.state==C.RECOVERY_REQUIRED and C.reason=="IDENTITY_REPAIRS_AFTER_CHECKPOINT" and w.accepted==0 and C.quarantine.data.generation==1)
w=fixture();C.reset(true,w.runtime);C.onMissionStarted({missionInfo=w.info},{identityRepairs=4})
check("dealer checkpoint: identity repair on an empty new save keeps stock unarmed", C.state==C.UNARMED and w.accepted==0 and not C.armed)
