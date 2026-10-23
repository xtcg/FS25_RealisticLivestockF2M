loadMod("tests/brokerdemandfixture.lua")
loadMod("scripts/market/RLBrokerMonth.lua")
local F,M=BrokerDemandFixture,RLBrokerMonth
local function fixture(allow)
    local w={disk=nil,writes=0,reads=0,fault=nil}
    w.store={}
    function w.store.read()
        w.reads=w.reads+1
        if w.fault=="READ_THROW" then error("read fault")end
        if w.disk==nil then return nil,"NOT_FOUND"end
        local d=F.copy(w.disk)
        if w.fault=="READBACK_CHANGE"and w.writes>0 then d.currentAbsoluteMonth=d.currentAbsoluteMonth+1 end
        if w.fault=="READBACK_MISSING"and w.writes>0 then return nil,"NOT_FOUND"end
        return d
    end
    function w.store.write(data)
        w.writes=w.writes+1
        if w.onWrite then w.onWrite()end
        if w.fault=="WRITE_THROW"then error("write fault")end
        if w.fault=="WRITE_FALSE"then return false end
        w.disk=F.copy(data)
        return true
    end
    w.deps={seed="month-seed",generatorVersion="generator:1",balance=F.balance(),catalog=F.catalog(),store=w.store,allowTestCatalog=allow==true}
    w.runtime=assert(M.new(w.deps))
    return w
end
local w=fixture(true)
local s=assert(w.runtime:ensureCurrent(35))
check("month: publish only after full write and readback",w.writes==1 and w.reads==2 and w.runtime:getStatus().state=="READY")
local again=assert(w.runtime:ensureCurrent(35))
check("month: same month never rerolls or rewrites",again.revision==s.revision and w.writes==1)
s.orders[1].quantityTotal=999
check("month: returned snapshot cannot mutate published order",w.runtime:getCurrent().orders[1].quantityTotal~=999)
local old=assert(w.runtime:getCurrent())
local changed=F.balance();changed.capacityScale=.5
local empty=F.catalog();empty.entries={};empty.configRevision="next-month:2"
assert(w.runtime:setInputs(changed,empty))
check("month: changed configuration cannot alter current published rules",assert(w.runtime:ensureCurrent(35)).revision==old.revision)
local nextMonth=assert(w.runtime:ensureCurrent(36))
check("month: year boundary keeps actual absolute month and new config",nextMonth.calendarMonth==1 and nextMonth.absoluteMonth==36
    and nextMonth.quotaDefinition.species.COW.monthlyHeadCap==4 and #nextMonth.orders==0)
check("month: historical rules remain for old pending coordinators",assert(w.runtime:getMonth(35)).revision==old.revision)
local resumed=assert(M.new(w.deps))
local reloaded=assert(resumed:ensureCurrent(36))
check("month: reload uses frozen snapshot despite constructor's earlier config",reloaded.revision==nextMonth.revision and w.writes==2)
local jumped=assert(resumed:ensureCurrent(40))
check("month: jumping creates only current month",jumped.absoluteMonth==40 and resumed:getMonth(37)==nil and resumed:getMonth(38)==nil and resumed:getMonth(39)==nil)
local status=assert(resumed:orderState(old.monthId,old.orders[1].orderId,40,0,{order=1,species=0,breed=1}))
check("month: expiration independent of shared species capacity",status.status=="EXPIRED"and status.capacityStatus=="SPECIES_CAP_REACHED")
local fresh=fixture(true);local current=assert(fresh.runtime:ensureCurrent(10));local order=current.orders[1]
local projected=assert(fresh.runtime:orderState(current.monthId,order.orderId,10,0,{order=1,species=0,breed=1}))
check("month: public pool exhaustion does not fill this order",projected.status=="OPEN"and projected.capacityStatus=="SPECIES_CAP_REACHED")
projected=assert(fresh.runtime:orderState(current.monthId,order.orderId,10,order.quantityTotal,{order=0,species=0,breed=0}))
check("month: own committed total drives FILLED",projected.status=="FILLED")
check("month: preflight reads current immutable order by ID",assert(fresh.runtime:readOrder(order.orderId)).packageRevision==order.packageRevision)
check("month: old order not exposed through current order endpoint",resumed:readOrder(order.orderId)==nil)
local previousWrites=fresh.writes
local backward,why=fresh.runtime:ensureCurrent(9)
check("month: clock rollback cannot regenerate a previous pool",backward==nil and why=="BROKER_CLOCK_ROLLBACK_REQUIRED"
    and fresh.writes==previousWrites and fresh.runtime:getCurrent()==nil)
local synthetic=fixture(false)
local rejected,reason=synthetic.runtime:ensureCurrent(1)
check("month: default production path never publishes synthetic U51 fixture evidence",rejected==nil and reason=="TEST_CATALOG_NOT_PUBLISHABLE"and synthetic.writes==0)
for _,fault in ipairs({"WRITE_FALSE","WRITE_THROW","READBACK_CHANGE","READBACK_MISSING"})do
    local broken=fixture(true);broken.fault=fault
    local value=broken.runtime:ensureCurrent(1)
    check("month: publication "..fault.." returns no usable new month",value==nil and broken.runtime:getCurrent()==nil
        and broken.runtime:getStatus().state=="RECOVERY_REQUIRED"and broken.runtime:getEvidence()~=nil)
    local writes=broken.writes;broken.fault=nil
    check("month: publication "..fault.." cannot auto-retry over unknown evidence",broken.runtime:ensureCurrent(1)==nil and broken.writes==writes)
end
local corrupt=fixture(true);corrupt.disk={schemaVersion=999,kind="BROKER_MONTH_HISTORY",sentinel="retain"}
local original=F.copy(corrupt.disk)
local invalid=corrupt.runtime:ensureCurrent(1)
check("month: unknown schema retained and quarantined without overwriting",invalid==nil and corrupt.writes==0
    and RLMarketData.fingerprint(corrupt.disk)==RLMarketData.fingerprint(original)and corrupt.runtime:getEvidence().sentinel=="retain")
local uncertain=fixture(true);uncertain.store.read=function()return nil,"IO_FAILURE"end
-- The store methods are captured when new() is called, as production adapters are.
uncertain.runtime=assert(M.new(uncertain.deps))
check("month: read failure is not interpreted as a pristine save",uncertain.runtime:ensureCurrent(1)==nil and uncertain.writes==0)
local recursive=fixture(true)
local nested,nestedReason,premature
recursive.onWrite=function()
    nested,nestedReason=recursive.runtime:ensureCurrent(2)
    premature=recursive.runtime:getCurrent()
end
local outer=recursive.runtime:ensureCurrent(1)
check("month: storage callbacks cannot recursively publish or view staged orders",outer~=nil and nested==nil
    and nestedReason=="BROKER_MONTH_BUSY"and premature==nil and recursive.writes==1)
local failNext=fixture(true);local saved=assert(failNext.runtime:ensureCurrent(1));failNext.fault="WRITE_FALSE"
check("month: failed next publication still preserves old pending month",failNext.runtime:ensureCurrent(2)==nil
    and assert(failNext.runtime:getMonth(1)).revision==saved.revision)
local reload=fixture(true);assert(reload.runtime:ensureCurrent(1))
local accepted=reload.runtime:setInputs({}, {})
check("month: malformed hot reload cannot replace a valid queued config",accepted==false)
local still=assert(reload.runtime:ensureCurrent(2))
check("month: next publication retains prior inputs after rejected hot reload",still.configRevision=="test-config:1"
    and still.quotaDefinition.species.COW.monthlyHeadCap==8 and #still.orders>=5)
local missingCalendar=F.catalog();missingCalendar.calendarOriginMonth=nil
check("month: queued input requires an explicit calendar projection",not reload.runtime:setInputs(F.balance(),missingCalendar))
local unavailableCatalog=F.catalog();for _,entry in ipairs(unavailableCatalog.entries)do entry.verified=false end
local admitted,diagnostics=reload.runtime:setInputs(F.balance(),unavailableCatalog)
check("month: missing individual scope evidence is diagnosed rather than a malformed config",admitted and #diagnostics>0)
