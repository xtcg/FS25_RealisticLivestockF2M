local log,engineCalls={},0
local function note(text)log[#log+1]=text end
local utils={}
-- FS25 Utils intentionally discards native return values. The registrar uses
-- these wrappers rather than inventing a different method calling convention.
function utils.prependedFunction(base,before)return function(...)before(...);base(...)end end
function utils.appendedFunction(base,after)return function(...)base(...);after(...)end end
local env={Utils=utils}
env.FSCareerMissionInfo={saveToXMLFile=function(self)engineCalls=engineCalls+1;note("engine");assert(self==env)end}
env.PlaceableSystem={saveToXML=function(_,xml)assert(xml=="placeable-xml");note("pen-engine")end}
env.VehicleSystem={saveToXML=function(_,unused,xml)assert(unused==nil and xml=="vehicle-xml");note("vehicle-engine")end}
env.Farm={saveToXMLFile=function()note("farm-engine")end}
env.SavegameController={onSaveComplete=function(_,code,directory)assert(code==0 and directory=="/final");note("complete-engine")end}
local hooks=RLNativeSaveHooks.new(env)
local a,b={},{}
local function listener(id)
    return {begin=function()note(id.."-begin")end,finish=function()note(id.."-end")end,
        placeables=function(_,xml)assert(xml=="placeable-xml");note(id.."-pen")end,
        vehicles=function(_,unused,xml)assert(unused==nil and xml=="vehicle-xml");note(id.."-vehicle")end,
        farms=function()note(id.."-farm")end,
        complete=function(_,code,directory)assert(code==0 and directory=="/final");note(id.."-complete")end}
end
assert(hooks.install(a,listener("a")));local wrapper=env.FSCareerMissionInfo.saveToXMLFile
assert(hooks.install(b,listener("b")));assert(hooks.install(a,listener("duplicate")))
check("save hooks: one native wrapper and idempotent owner registration",wrapper==env.FSCareerMissionInfo.saveToXMLFile)
env.FSCareerMissionInfo.saveToXMLFile(env)
check("save hooks: nested legacy before/after order preserved",table.concat(log,",")=="b-begin,a-begin,engine,a-end,b-end" and engineCalls==1)
log={};env.PlaceableSystem.saveToXML({},"placeable-xml");env.VehicleSystem.saveToXML({},nil,"vehicle-xml")
check("save hooks: native pen/vehicle signatures and order preserved",table.concat(log,",")=="b-pen,a-pen,pen-engine,b-vehicle,a-vehicle,vehicle-engine")
log={};env.Farm.saveToXMLFile({});env.SavegameController.onSaveComplete({},0,"/final")
check("save hooks: farm and engine completion appended in order",table.concat(log,",")=="farm-engine,a-farm,b-farm,complete-engine,a-complete,b-complete")
check("save hooks: malformed registration has no partial subscription",not hooks.install({}, {begin=function()note("bad")end,unknown=function()end}))
log={};env.FSCareerMissionInfo.saveToXMLFile(env)
check("save hooks: invalid listener did not alter order",table.concat(log,",")=="b-begin,a-begin,engine,a-end,b-end")
local lateEnv={Utils=utils};local late=RLNativeSaveHooks.new(lateEnv);local owner={};local calls=0
assert(late.install(owner,{begin=function()calls=calls+1 end}))
lateEnv.FSCareerMissionInfo={saveToXMLFile=function()calls=calls+10 end}
assert(late.install(owner,{}));lateEnv.FSCareerMissionInfo.saveToXMLFile()
check("save hooks: absent native classes can bind later without duplicate listeners",calls==11)
local reentrant,reason
assert(hooks.install({}, {begin=function()reentrant,reason=hooks.install({},listener("late"))end}))
env.FSCareerMissionInfo.saveToXMLFile(env)
check("save hooks: registration inside a callback cannot alter an active save",reentrant==false and reason=="SAVE_HOOK_REGISTRATION_DURING_CALLBACK")
local failedEnv={Utils=utils,FSCareerMissionInfo={saveToXMLFile=function()end}}
local failed=RLNativeSaveHooks.new(failedEnv)
assert(failed.install({}, {begin=function()error("observer")end}))
check("save hooks: observer errors preserve caller guard semantics",not pcall(failedEnv.FSCareerMissionInfo.saveToXMLFile))
check("save hooks: error clears dispatch fence",failed.install({}, {complete=function()end})==true)

-- The actual three checkpoint installers share this boundary. Their directory
-- precedence and error guards remain channel-owned, even when callbacks combine.
Utils=utils
FSCareerMissionInfo={saveToXMLFile=function()note("engine")end}
PlaceableSystem={saveToXML=function()note("pen-engine")end}
VehicleSystem={saveToXML=function()note("vehicle-engine")end}
Farm={saveToXMLFile=function()note("farm-engine")end}
SavegameController={onSaveComplete=function()note("complete-engine")end}
RLNativeSaveHooks.instance=RLNativeSaveHooks.new()
loadMod("scripts/animal/RLTradeCheckpoint.lua")
loadMod("scripts/dealer/RLDealerCheckpoint.lua")
loadMod("scripts/animal/RLAnimalIdentityCheckpoint.lua")
for _,entry in ipairs({{RLTradeCheckpoint,"trade"},{RLDealerCheckpoint,"dealer"},{RLAnimalIdentityCheckpoint,"identity"}}) do
    local checkpoint,id=entry[1],entry[2]
    checkpoint.onSaveBegin=function()note(id.."-begin")end
    checkpoint.onSaveEnd=function()note(id.."-end")end
    checkpoint.markParticipant=function(role)note(id.."-"..role)end
    checkpoint.onSaveComplete=function(_,directory)note(id..":"..directory)end
    checkpoint.install()
end
log={};FSCareerMissionInfo.saveToXMLFile({})
check("save hooks: three real installers preserve original save order",table.concat(log,",")=="identity-begin,dealer-begin,trade-begin,engine,trade-end,dealer-end,identity-end")
log={};SavegameController.onSaveComplete({currentSavegame={savegameDirectory="/controller"}},0,"/argument")
check("save hooks: channel-specific completion directory precedence preserved",table.concat(log,",")=="complete-engine,trade:/controller,dealer:/argument,identity:/controller")
log={};RLTradeCheckpoint.pass={data="before"}
RLTradeCheckpoint.onSaveBegin=function()note("trade-fault");error("injected trade observer failure")end
FSCareerMissionInfo.saveToXMLFile({})
check("save hooks: checkpoint guard keeps engine and other end callbacks running",table.concat(log,",")=="identity-begin,dealer-begin,trade-fault,engine,trade-end,dealer-end,identity-end" and RLTradeCheckpoint.pass.data==nil and RLTradeCheckpoint.pass.error:find("HOOK_FAILED",1,true)~=nil)
