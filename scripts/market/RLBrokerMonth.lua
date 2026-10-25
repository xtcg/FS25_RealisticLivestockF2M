-- Publish only a completely persisted and exactly read-back demand history.
-- This pure lifecycle owns no animals, money or quotas. Historical months remain
-- available to pending coordinators; quota checkpoint participation is separate.
RLBrokerMonth = {}
local M=RLBrokerMonth
local text=RLPlain.text
local function integer(v)return type(v)=="number" and v==v and v>=0 and v<2^52 and v%1==0 end
local function fp(v)return RLMarketData.fingerprint(v) end
local function copy(v)return RLMarketData.copy(v) end
local function monthKey(v)return string.format("%.0f",v) end
local function validateHistory(raw,seedFingerprint,allowTest)
    local doc,reason=copy(raw)
    if type(doc)~="table" then return nil,reason or "INVALID_BROKER_HISTORY" end
    if doc.schemaVersion~=1 or doc.kind~="BROKER_MONTH_HISTORY" then return nil,"UNSUPPORTED_BROKER_HISTORY_SCHEMA" end
    local revision=doc.revision;doc.revision=nil
    if revision~=fp(doc) then return nil,"BROKER_HISTORY_REVISION_MISMATCH" end
    doc.revision=revision
    if doc.seedFingerprint~=seedFingerprint or type(doc.months)~="table" or not integer(doc.currentAbsoluteMonth) then return nil,"BROKER_HISTORY_SCOPE_MISMATCH" end
    local current
    for key,value in pairs(doc.months) do
        local snapshot,why=RLBrokerDemand.validateSnapshot(value)
        if snapshot==nil then return nil,why end
        if type(key)~="string" or key~=monthKey(snapshot.absoluteMonth) or snapshot.seedFingerprint~=seedFingerprint
            or snapshot.absoluteMonth>doc.currentAbsoluteMonth then return nil,"BROKER_HISTORY_MONTH_MISMATCH" end
        if snapshot.testOnly and not allowTest then return nil,"TEST_CATALOG_NOT_PUBLISHABLE" end
        if snapshot.absoluteMonth==doc.currentAbsoluteMonth then current=snapshot end
    end
    if current==nil then return nil,"BROKER_HISTORY_CURRENT_MISSING" end
    return doc
end
function M.new(deps)
    if type(deps)~="table" or type(deps.store)~="table" or type(deps.store.read)~="function" or type(deps.store.write)~="function" then return nil,"BROKER_STORE_REQUIRED" end
    local seed,why=copy(deps.seed)
    if not (text(seed) or (type(seed)=="number" and seed==seed and math.abs(seed)<math.huge)) then return nil,why or "INVALID_MARKET_SEED" end
    local balance=copy(deps.balance);local catalog=copy(deps.catalog)
    if type(balance)~="table" or type(catalog)~="table" then return nil,"BROKER_INPUTS_REQUIRED" end
    local version=deps.generatorVersion
    if not text(version) and not (integer(version) and version>=1) then return nil,"INVALID_GENERATOR_VERSION" end
    local allowTest=deps.allowTestCatalog==true
    local read,write=deps.store.read,deps.store.write
    local seedFingerprint=assert(fp(seed))
    local loaded,busy,document=false,false,nil
    local savedHistory,currentCursor
    local state,reason,evidence="DORMANT",nil,nil
    local runtime={}
    -- The game binding calls this only after verifying the native shared-save
    -- cohort and ruling out any newer transaction WAL. Future demand generated
    -- in an unsaved session is retained and reused, so loading the saved date
    -- cannot reroll it or permanently disable an otherwise consistent save.
    function runtime:resumeCheckpoint(history)
        if loaded or busy or savedHistory then return false,"BROKER_MONTH_ALREADY_LOADED" end
        local checked,why=validateHistory(history,seedFingerprint,allowTest)
        if not checked then return false,why end
        savedHistory=checked
        return true
    end
    function runtime:setInputs(nextBalance,nextCatalog)
        if busy then return false,"BROKER_MONTH_BUSY" end
        local checked,why=RLBrokerDemand.validateInputs(nextBalance,nextCatalog)
        if checked==nil then return false,why end
        balance,catalog=checked.balance,checked.catalog
        return true,checked.diagnostics
    end
    function runtime:ensureCurrent(absoluteMonth)
        if not integer(absoluteMonth) then return nil,"INVALID_ABSOLUTE_MONTH" end
        if busy then return nil,"BROKER_MONTH_BUSY" end
        if state=="RECOVERY_REQUIRED" then return nil,reason end
        busy=true
        local function ensure()
            if not loaded then
                state="VERIFYING"
                local existing,readReason=read()
                if existing==nil then
                    if readReason~="NOT_FOUND" then error("BROKER_STORE_READ_UNCERTAIN",0) end
                    document={schemaVersion=1,kind="BROKER_MONTH_HISTORY",seedFingerprint=seedFingerprint,months={}}
                else
                    evidence=existing
                    local verified,why=validateHistory(existing,seedFingerprint,allowTest)
                    if verified==nil then error(why,0) end
                    document=verified;evidence=nil
                end
                loaded=true
                if savedHistory then
                    for key,value in pairs(savedHistory.months) do
                        if fp(document.months[key])~=fp(value) then error("BROKER_CHECKPOINT_HISTORY_MISMATCH",0) end
                    end
                end
            end
            if document.currentAbsoluteMonth~=nil and absoluteMonth<document.currentAbsoluteMonth then
                if not savedHistory or absoluteMonth<savedHistory.currentAbsoluteMonth then
                    state,reason="RECOVERY_REQUIRED","BROKER_CLOCK_ROLLBACK_REQUIRED";return nil,reason
                end
            end
            local current=document.months[monthKey(absoluteMonth)]
            if current~=nil then currentCursor=absoluteMonth;state,reason="READY",nil;return assert(copy(current)) end
            state="GENERATING"
            local prior=document.months[monthKey(absoluteMonth-1)]
            local snapshot,why=RLBrokerDemand.generate(seed,absoluteMonth,version,balance,catalog,prior)
            if snapshot==nil then state,reason="UNAVAILABLE",why;return nil,why end
            if snapshot.testOnly and not allowTest then state,reason="UNAVAILABLE","TEST_CATALOG_NOT_PUBLISHABLE";return nil,reason end
            local valid
            valid,why=RLBrokerDemand.validateSnapshot(snapshot)
            if valid==nil then state,reason="UNAVAILABLE",why;return nil,why end
            local staged=assert(copy(document));staged.revision=nil
            staged.currentAbsoluteMonth=absoluteMonth;staged.months[monthKey(absoluteMonth)]=valid
            staged.revision=assert(fp(staged))
            state="PUBLISHING";evidence={before=assert(copy(document)),staged=assert(copy(staged))}
            if write(assert(copy(staged)))~=true then error("BROKER_PUBLISH_WRITE_UNCERTAIN",0) end
            local actual=read()
            local checked,readWhy=validateHistory(actual,seedFingerprint,allowTest)
            if checked==nil or fp(checked)~=fp(staged) then error(readWhy or "BROKER_PUBLISH_READBACK_MISMATCH",0) end
            document=checked;state,reason,evidence="READY",nil,nil
            currentCursor=absoluteMonth
            return assert(copy(document.months[monthKey(absoluteMonth)]))
        end
        local ok,snapshot,why=pcall(ensure)
        busy=false
        if not ok then
            state,reason="RECOVERY_REQUIRED",tostring(snapshot)
            return nil,reason
        end
        if snapshot==nil and state~="UNAVAILABLE" then reason=why end
        return snapshot,why
    end
    function runtime:getCurrent()
        if state~="READY" or document==nil or document.currentAbsoluteMonth==nil then return nil,reason or "BROKER_MONTH_NOT_READY" end
        return copy(document.months[monthKey(currentCursor or document.currentAbsoluteMonth)])
    end
    function runtime:getMonth(reference)
        if document==nil then return nil,"BROKER_HISTORY_NOT_LOADED" end
        if integer(reference) then
            local found=document.months[monthKey(reference)]
            if found~=nil then return copy(found) end
            return nil,"UNKNOWN_BROKER_MONTH"
        end
        if text(reference) then for _,snapshot in pairs(document.months) do if snapshot.monthId==reference then return copy(snapshot) end end end
        return nil,"UNKNOWN_BROKER_MONTH"
    end
    function runtime:checkpointDocument()
        if state~="READY" or not currentCursor then return nil,"BROKER_MONTH_NOT_READY" end
        local saved=assert(copy(document));saved.revision=nil
        saved.currentAbsoluteMonth=currentCursor
        for key,value in pairs(saved.months) do if value.absoluteMonth>currentCursor then saved.months[key]=nil end end
        saved.revision=assert(fp(saved))
        return saved
    end
    function runtime:readOrder(orderId)
        if not text(orderId) then return nil,"INVALID_BROKER_ORDER_ID" end
        local current,why=self:getCurrent();if current==nil then return nil,why end
        for _,order in ipairs(current.orders) do if order.orderId==orderId then return copy(order) end end
        return nil,"UNKNOWN_BROKER_ORDER"
    end
    function runtime:orderState(monthId,orderId,currentAbsoluteMonth,committedHeads,available)
        if not integer(currentAbsoluteMonth) or not integer(committedHeads) then return nil,"INVALID_ORDER_STATE_CONTEXT" end
        local snapshot,why=self:getMonth(monthId);if snapshot==nil then return nil,why end
        local order
        for _,candidate in ipairs(snapshot.orders) do if candidate.orderId==orderId then order=candidate end end
        if order==nil then return nil,"UNKNOWN_BROKER_ORDER" end
        if committedHeads>order.quantityTotal then return nil,"ORDER_COUNTER_OVERFLOW" end
        local status=currentAbsoluteMonth~=snapshot.absoluteMonth and "EXPIRED" or (committedHeads==order.quantityTotal and "FILLED" or "OPEN")
        local capacity="UNKNOWN"
        if available~=nil then
            local a=copy(available)
            if type(a)~="table" or not integer(a.order) or not integer(a.species) or (a.breed~=nil and not integer(a.breed)) then return nil,"INVALID_CAPACITY_STATUS" end
            capacity=a.order==0 and "ORDER_CAP_REACHED" or a.species==0 and "SPECIES_CAP_REACHED" or a.breed==0 and "BREED_CAP_REACHED" or "AVAILABLE"
        end
        return {status=status,capacityStatus=capacity,monthId=snapshot.monthId,orderId=orderId}
    end
    function runtime:getStatus()return {state=state,reason=reason,busy=busy,currentAbsoluteMonth=currentCursor or (document and document.currentAbsoluteMonth or nil)}end
    function runtime:getEvidence()return copy(evidence)end
    return runtime
end
