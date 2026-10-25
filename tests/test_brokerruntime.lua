loadMod("tests/brokerruntimefixture.lua")
local D=RLMarketData
local function cp(v) return assert(D.copy(v)) end
local setup=BrokerRuntimeFixture.setup
local x=setup()
local before=cp(x.r.quota:export())
local pre,why=x.r:preflight(x.req)
check("broker runtime: real snapshot complete eligibility assembled",pre and pre.eligibility.eligible and pre.price.pickup.netToPlayer==987.5)
check("broker runtime: browsing has no assets, wallet, quota or transaction writes",#x.s.system.animals==2 and x.m.calls==0 and x.writes()==0 and D.fingerprint(before)==D.fingerprint(x.r.quota:export()))
local quote=assert(x.r:preview(x.req))
check("broker runtime: preview gives 15-second credential without mutation",quote.expiresAt==16000 and x.m.calls==0 and x.writes()==0)
local fence
x.m.onMoney=function() fence=RLBrokerRuntime.mutationAllowed() end
local result,err=x.r:confirm(quote)
check("broker runtime: picker to source removal to payment and shared quota",result and result.status=="COMMITTED" and #x.s.system.animals==1 and x.f.money==1987.5 and x.m.calls==1 and x.r:listOrders()[1].remaining.breed==3)
check("broker runtime: legacy channels fenced inside payout callback",fence==false and RLBrokerRuntime.mutationAllowed())
check("broker runtime: a committed delivery blocks in-place recovery",x.r.confirmedThisSession==true)
local replay=x.r:confirm(quote)
check("broker runtime: repeated UI confirmation returns original outcome",replay and replay.status=="COMMITTED" and x.m.calls==1 and x.writes()==6)
x=setup();quote=assert(x.r:preview(x.req));x.m.time=16000
local no,reason=x.r:confirm(quote)
check("broker runtime: a refused confirmation does not count as a delivery for recovery",x.r.confirmedThisSession==nil)
check("broker runtime: 15-second expiry checked before removal",not no and reason=="BROKER_QUOTE_EXPIRED" and #x.s.system.animals==2 and x.m.calls==0)
x=setup();quote=assert(x.r:preview(x.req));x.m.environment.currentPeriod=3
no,reason=x.r:confirm(quote)
check("broker runtime: month rollover rejects old confirmation",not no and #x.s.system.animals==2 and x.m.calls==0 and x.r.current.absoluteMonth==14)
x=setup();quote=assert(x.r:preview(x.req));x.m.farm=2
no,reason=x.r:confirm(quote)
check("broker runtime: farm changed after dialog cannot sell old farm",not no and #x.s.system.animals==2 and x.m.calls==0)
x=setup();x.m.missionDynamicInfo.isMultiplayer=true
check("broker runtime: multiplayer cannot reach preflight or settlement",x.r:preview(x.req)==nil)
x=setup();x.r.state="SAVE_REQUIRED";x.r.reason="BROKER_INITIAL_SAVE_REQUIRED"
check("broker runtime: initial save gate still permits read-only preflight",x.r:preflight(x.req)~=nil and x.r:preview(x.req)==nil)
x=setup();quote=assert(x.r:preview(x.req));x.m.mode="PARTIAL"
result=x.r:confirm(quote)
check("broker runtime: partial funds pause Broker and legacy mutations",result and result.status=="UNKNOWN" and x.r.state=="RECOVERY_REQUIRED" and not RLBrokerRuntime.mutationAllowed())
x=setup();x.b.uniqueId=x.a.uniqueId
check("broker runtime: duplicated full world identity rejects preview",x.r:preview(x.req)==nil and x.m.calls==0)
x=setup();quote=assert(x.r:preview(x.req));x.r.frozen=true
check("broker runtime: native save fence rejects confirmation",x.r:confirm(quote)==nil and #x.s.system.animals==2)
x=setup();x.r:block("UNSUPPORTED_INITIAL_MAP")
check("broker runtime: unsupported fresh Broker scope leaves legacy trades usable",RLBrokerRuntime.mutationAllowed())
x=setup()
local owner={execute=function() return x.r:preview(x.req) end}
RLBrokerRuntime.guardLegacy(owner,"execute")
check("broker runtime: another channel's callback cannot start Broker",owner.execute()==nil and RLBrokerRuntime.legacyDepth==0 and x.m.calls==0)
owner={execute=function() error("legacy mutation error") end}
RLBrokerRuntime.guardLegacy(owner,"execute")
local protected=pcall(owner.execute)
check("broker runtime: legacy failure releases only the stack fence",not protected and RLBrokerRuntime.legacyDepth==0)
RLBrokerRuntime.current=nil

x=setup()
local crossing={execute=function() RLBrokerRuntime.resetFence();return "a",2,3,4 end}
RLBrokerRuntime.guardLegacy(crossing,"execute")
local r1,r2,r3,r4=crossing.execute()
check("broker runtime: a call running across a fence reset cannot make the depth negative, returns every value",
    RLBrokerRuntime.legacyDepth==0 and r1=="a" and r4==4)
x=setup()
local captureReal=RLMarketSnapshot.capture
RLMarketSnapshot.capture=function(...)
    local snapshot,why=captureReal(...)
    table.remove(x.s.system.animals,1)
    return snapshot,why
end
local vanished,vanishedWhy=x.r:preflight(x.req)
RLMarketSnapshot.capture=captureReal
check("broker runtime: animal vanishing before eligibility is a refusal, not a service error",
    vanishedWhy~="BROKER_SERVICE_ERROR" and (vanished==nil or vanished.eligibility.eligible==false))
