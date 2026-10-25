-- Broker payment receipts use the real farm/finance/HUD witnesses. No SALE
-- transaction is created and no pcall return is treated as a payment receipt.
RLBrokerMoneyAdapter = {}
local A=RLBrokerMoneyAdapter
local function copy(v)return assert(RLMarketData.copy(v))end
local function fingerprint(v)return assert(RLMarketData.fingerprint(v))end
local finite=RLPlain.finite
function A.new(options)
    if type(options)~="table" or type(options.persistReceipt)~="function" or type(options.moneyType)~="table" then return nil,"MONEY_CONTEXT_REQUIRED" end
    local receipts,payments,busyFarms={},{},{}
    if options.receipts~=nil then
        local imported=RLMarketData.copy(options.receipts)
        if type(imported)~="table" then return nil,"INVALID_IMPORTED_MONEY_RECEIPTS" end
        for id,receipt in pairs(imported) do
            if type(id)~="string" or type(receipt)~="table" or receipt.version~=1 or receipt.kind~="BROKER"
                or receipt.paymentId~=id or type(receipt.action)~="table"
                or receipt.actionFingerprint~=fingerprint(receipt.action) then return nil,"INVALID_IMPORTED_MONEY_RECEIPT" end
            local original=receipt.historicalEvidence or copy(receipt)
            if type(original)~="table" or original.version~=1 or original.kind~="BROKER" or original.paymentId~=id
                or type(original.action)~="table" or original.action.paymentId~=id
                or original.actionFingerprint~=receipt.actionFingerprint
                or fingerprint(original.action)~=receipt.actionFingerprint then return nil,"INVALID_HISTORICAL_PAYMENT_BINDING" end
            local verified=false
            if type(options.verifyHistoricalReceipt)=="function" and type(options.checkpointRef)=="string" and options.checkpointRef~="" then
                local worked,accepted=pcall(options.verifyHistoricalReceipt,copy(original),options.checkpointRef)
                verified=worked and accepted==true and original.status=="APPLIED"
            end
            receipt.historicalEvidence=copy(original)
            receipt.status=verified and "HISTORICAL_SETTLED" or "UNKNOWN"
            receipt.reason=verified and "VERIFIED_SAVED_TERMINAL" or "RELOADED_RECEIPT_REQUIRES_CHECKPOINT_PROOF"
            receipt.stage="LOADED_HISTORY"
            receipt.keepLocked=not verified
            receipt.settledCheckpoint=verified and options.checkpointRef or nil
            receipts[id]=receipt
        end
    end
    options={mission=options.mission,persistReceipt=options.persistReceipt,
        moneyType={id=options.moneyType.id,statistic=options.moneyType.statistic}}
    local a={}
    function a:receipt(id)return receipts[id] and copy(receipts[id]) or nil end
    function a:pay(action)
        if type(action)~="table" or type(action.paymentId)~="string" or action.paymentId=="" or type(action.requestId)~="string"
            or action.requestId=="" or not finite(action.netAmount) or action.netAmount<=0 or not finite(action.farmId)
            or action.farmId<1 or action.farmId%1~=0 then return {status="NOT_APPLIED",reason="INVALID_BROKER_PAYMENT"} end
        action={paymentId=action.paymentId,requestId=action.requestId,farmId=action.farmId,netAmount=action.netAmount}
        local identity={kind="BROKER",paymentId=action.paymentId,requestId=action.requestId,farmId=action.farmId,netAmount=action.netAmount,
            moneyTypeId=options.moneyType.id,moneyStatistic=options.moneyType.statistic}
        local key=fingerprint(identity)
        local existing=receipts[action.paymentId]
        if existing then
            if existing.actionFingerprint~=key then return {status="UNKNOWN",reason="PAYMENT_ID_CONFLICT",keepLocked=true} end
            return copy(existing),"REPLAY"
        end
        if busyFarms[action.farmId] then return {status="NOT_APPLIED",reason="FARM_PAYMENT_BUSY",keepLocked=true} end
        local receipt={version=1,kind="BROKER",paymentId=action.paymentId,action=identity,actionFingerprint=key,status="UNKNOWN",stage="PREPARING",keepLocked=true}
        receipts[action.paymentId]=receipt;busyFarms[action.farmId]=true
        local ok,err=pcall(function()
            local before,why=RLSaleSettlement.observe(options.mission,action.farmId,options.moneyType)
            if not before then receipt.status,receipt.reason,receipt.stage="NOT_APPLIED",why,"REFUSED";return end
            receipt.before,receipt.stage=copy(before),"BEFORE"
            if options.persistReceipt(copy(receipt))~=true then receipt.status,receipt.reason,receipt.stage="NOT_APPLIED","BEFORE_RECEIPT_NOT_DURABLE","REFUSED";return end
            local check=RLSaleSettlement.observe(options.mission,action.farmId,options.moneyType)
            if not check or fingerprint(check)~=fingerprint(before) then receipt.status,receipt.reason,receipt.stage="NOT_APPLIED","MONEY_CHANGED_BEFORE_CALL","REFUSED";return end
            receipt.stage="CALLING"
            local settled=RLSaleSettlement.apply(payments,{paymentId=action.paymentId,ref=action.requestId,kind="BROKER",
                farmId=action.farmId,amount=action.netAmount,moneyType=options.moneyType},options.mission)
            receipt.settlement=copy(settled)
            local after;after,why=RLSaleSettlement.observe(options.mission,action.farmId,options.moneyType)
            receipt.after,receipt.stage=after and copy(after),"AFTER"
            if after then
                local observed,evidence=RLSaleSettlement.classify(before,after,action.netAmount,settled.callError~=nil)
                receipt.status=observed==settled.status and observed or "UNKNOWN"
                receipt.reason=evidence
            else receipt.status,receipt.reason="UNKNOWN","MONEY_AFTER_UNREADABLE:"..tostring(why) end
            receipt.keepLocked=receipt.status=="UNKNOWN"
            if options.persistReceipt(copy(receipt))~=true then receipt.status,receipt.reason,receipt.keepLocked="UNKNOWN","AFTER_RECEIPT_NOT_DURABLE",true end
        end)
        if not ok then receipt.status,receipt.reason,receipt.keepLocked="UNKNOWN","MONEY_ADAPTER_ERROR:"..tostring(err),true end
        busyFarms[action.farmId]=nil
        return copy(receipt)
    end
    return a
end
