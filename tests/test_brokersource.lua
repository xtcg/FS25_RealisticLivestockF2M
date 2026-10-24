loadMod("tests/fixtures/broker_engine.lua")
local F,A=BrokerEngineFixture,RLBrokerSourceAdapter
local function prepare(kind,extra)
    local s,a,b=F.source(kind);local o={farmId=1,kind=kind or "PEN",sourceId=s.uniqueId,mission=s.mission,channel=kind=="TRAILER" and "BROKER_DELIVERY" or "BROKER_PICKUP"}
    for k,v in pairs(extra or {})do o[k]=v end
    return A.prepare(s,RLTradeSourceAdapter.identityKey(a),o),s,a,b
end
local h,s,a,b=prepare("PEN");assert(h)
local e=A.portableEvidence(h)
check("broker source: portable evidence retains deep growth and unborn genetics",e.animal.rlGrowth.nested.a.b.c.d.e.f.g==19 and e.animal.pregnancy.pregnancies[1].genetics.quality==1.25
    and #e.members==2 and e.kind=="BROKER_SOURCE" and not e.reloadRestoreSupported and RLMarketData.fingerprint(e)~=nil)
e.animal.genetics.quality=9
check("broker source: caller cannot alter frozen portable state",A.portableEvidence(h).animal.genetics.quality==1)
local persisted=false
local removed=A.remove(h,function(doc)persisted=doc.animal.uniqueId==a.uniqueId;return true end)
check("broker source: one animal removed only after durable PREPARED",persisted and removed.status=="APPLIED" and #s.system.animals==1 and s.system.animals[1]==b)
check("broker source: observation follows real cluster membership",A.observe(h).status=="APPLIED")
local restored=A.restore(h)
check("broker source: exact original animal object restored with full data",restored.status=="APPLIED" and A.verifyRestored(h) and #s.system.animals==2
    and s.system.animals[2]==a and a.genetics.quality==1 and a.rlGrowth.nested.a.b.c.d.e.f.g==19)
check("broker source: repeated remove/restore causes no extra animal",A.remove(h).status=="APPLIED" and A.restore(h).status=="APPLIED" and #s.system.animals==2)
check("broker source: portable-only reload never blindly creates Animal",A.restore({evidence=A.portableEvidence(h)}).status=="UNKNOWN")
h,s,a,b=prepare("PEN")
local denied=A.remove(h,function()return false end)
check("broker source: failed durable barrier does not touch source",denied.status=="NOT_APPLIED" and #s.system.animals==2 and next(s.system.clustersToRemove)==nil)
h,s,a,b=prepare("PEN")
local nested
local result=A.remove(h,function()nested=A.remove(h,function()return true end);return true end)
check("broker source: callback reentry cannot remove twice",nested.status=="UNKNOWN" and result.status=="APPLIED" and #s.system.animals==1)
h,s,a,b=prepare("PEN")
s.system.onFlush=function()b.health=99 end
check("broker source: outside business mutation keeps reconciliation lock",A.remove(h,function()return true end).status=="UNKNOWN" and A.restore(h).status=="UNKNOWN")
h,s,a,b=prepare("PEN")
s.system.onQueue=function()s.system.clustersToRemove[b]=true end
local foreign=A.remove(h,function()return true end)
check("broker source: foreign queue never flushed or erased",foreign.status=="UNKNOWN" and #s.system.animals==2 and s.system.clustersToRemove[b]==true and A.restore(h).status=="UNKNOWN")
h,s,a,b=prepare("PEN")
s.system.onQueue=function()error("after queue")end
local queued=A.remove(h,function()return true end)
check("broker source: exact owned pending removal can be compensated",queued.status=="UNKNOWN" and A.restore(h).status=="APPLIED" and #s.system.animals==2 and next(s.system.clustersToRemove)==nil)
local noLocation=prepare("TRAILER")
check("broker source: trailer self delivery needs verified receiving point",noLocation==nil)
h,s,a,b=prepare("TRAILER",{locationEvidence={pointId="server-point"},verifyLocation=function()return true end})
check("broker source: trailer verified actual point allows single delivery",h~=nil and A.remove(h,function()return true end).status=="APPLIED")
h,s,a,b=prepare("PEN")
s.ownerFarmId=2
check("broker source: ownership changes refuse before removal",A.remove(h,function()return true end).status=="NOT_APPLIED" and #s.system.animals==2)
local s2,a2=F.source("PEN")
check("broker source: client alias cannot impersonate stable engine source ID",A.prepare(s2,RLTradeSourceAdapter.identityKey(a2),{farmId=1,kind="PEN",channel="BROKER_PICKUP",sourceId="client-alias"})==nil)
h,s,a,b=prepare("PEN")
s.mission.placeableSystem.placeables={}
check("broker source: retained object after world removal cannot be delivered",A.remove(h,function()return true end).status=="NOT_APPLIED" and #s.system.animals==2)
h,s,a,b=prepare("PEN")
local notDurable=A.remove(h,function() s.mission.placeableSystem.placeables={};return true end)
check("broker source: world membership rechecked after durable callback",notDurable.status=="NOT_APPLIED" and #s.system.animals==2)
local detached,animal=F.source("PEN");detached.mission.placeableSystem.placeables={}
check("broker source: detached source never prepares",A.prepare(detached,RLTradeSourceAdapter.identityKey(animal),
    {farmId=1,kind="PEN",channel="BROKER_PICKUP",sourceId=detached.uniqueId,mission=detached.mission})==nil)
