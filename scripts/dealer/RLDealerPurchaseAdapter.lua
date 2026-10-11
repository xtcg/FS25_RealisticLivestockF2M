-- Dormant composition of real private sources, target queues and witnessed money.
-- Engine capacity/eligibility/world enumeration and synchronous persistence are
-- mandatory server capabilities; constructing this module never enables a route.
RLDealerPurchaseAdapter = { VERSION=1 }
local A=RLDealerPurchaseAdapter
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    return RLTradePersistence.canonical(a)==RLTradePersistence.canonical(b)
end
local function receipt(token,plan,status)
    return {status=status,token=token,amount=plan.amount,transferIds=copy(plan.transferIds),
        sourceComplete=true,targetComplete=true,moneyComplete=true}
end
function A.new(ctx)
    if type(ctx)~="table" or type(ctx.stock)~="table" or type(ctx.stock.sourceOwners)~="table"
        or type(ctx.quotes)~="table" or type(ctx.quoteAdapter)~="table" or type(ctx.epoch)~="string" then return nil,"PURCHASE_CONTEXT_REQUIRED" end
    for _,key in ipairs({"resolveSubType","monotonicMs","allOwners","eligible","validateCapacity","persistBarrier"}) do
        if type(ctx[key])~="function" then return nil,"PURCHASE_CAPABILITY:"..key end
    end
    local stock=ctx.stock
    local a={durableDealerOwnershipVersion=1,active={},busy=false}
    local function hold(reason)
        stock.recoveryRequired=true;a.reason=reason
        return nil,reason
    end
    local function authority(principal,reference)
        local resolved,why=RLDealerDestination.authorize(ctx.connection,reference,ctx.mission,ctx.farmManager)
        if not resolved then return nil,why end
        if resolved.principal~=principal then return nil,"PRINCIPAL_CHANGED" end
        return resolved
    end
    local function selection(context) return {destination=context.request.destination,items=context.request.items} end
    local function quote(context,active)
        local qa=ctx.quoteAdapter
        if active and active.reserved then
            qa={};for k,v in pairs(ctx.quoteAdapter) do qa[k]=v end
            local original={};for _,row in ipairs(active.listings) do original[row.saleId]=row end
            qa.readListing=function(id)
                local current=ctx.quoteAdapter.readListing(id)
                if original[id] and equal(current,active.reserved.records[id]) then return copy(original[id]) end
                return current
            end
        end
        return RLDealerQuote.validate(ctx.quotes,context.request.quoteCredential,selection(context),context.request.principal,qa)
    end
    local function recovery()
        -- Detached animals no longer belong to the source inventory. Retain their
        -- original physiology and identities in the prepared compensation plan.
        local sources,bindings=copy(stock.farm.sources),copy(stock.sourceBindings)
        for sourceId,b in pairs(bindings) do
            local owner=stock.sourceOwners[b.ownerId]
            if owner==nil or owner.byId[b.animalId]==nil then sources[sourceId],bindings[sourceId]=nil,nil end
        end
        local owned,why=RLDealerOwnedStock.export(stock.sourceOwners,bindings,stock.sourceRecordsByOwner,
            stock.observedChildren,sources,stock.farm.clock.months)
        if not owned then return nil,why end
        return {version=1,clockMonths=stock.farm.clock.months,sources=sources,sourceOwnership=owned,
            money=RLDealerMoneyAdapter.export(a.money)}
    end
    a.checkpoint=function(purchase)
        local evidence,why=recovery();if not evidence then return hold(why) end
        local ok,saved=pcall(ctx.persistBarrier,{purchase=copy(purchase),recovery=evidence,listings=RLDealerListingRegistry.export(stock.listings)})
        if not ok or saved~=true then return hold("PURCHASE_BARRIER_UNCERTAIN") end
        return true
    end
    local moneyContext={epoch=ctx.epoch,mission=ctx.mission,farmManager=ctx.farmManager,
        persistPrepared=function() return a.checkpoint(RLDealerPurchase.export(stock.purchase)) end,
        persistCommitted=function() return a.checkpoint(RLDealerPurchase.export(stock.purchase)) end}
    local why;a.money,why=RLDealerMoneyAdapter.new(moneyContext)
    if not a.money then return nil,why end
    -- A previously bound receipt store requires explicit reconciliation, never
    -- replacement by a new epoch and a second payment.
    if stock.money~=nil or stock.moneyEvidence~=nil then return nil,"MONEY_RECONCILIATION_REQUIRED" end
    stock.money=a.money
    a.isServer=function() return ctx.mission and ctx.mission:getIsServer()==true end
    a.authorize=function(principal,reference)
        if a.busy or stock.recoveryRequired or stock.sourceUpdateInProgress then return false end
        return authority(principal,reference)~=nil
    end
    a.monotonicMs=ctx.monotonicMs
    a.currentClock=function() return stock.farm.clock.months end
    a.readListing=function(id) return RLDealerListingRegistry.get(stock.listings,id) end
    a.validateListing=function(listing,context)
        local sourceId=listing.payload and listing.payload.sourceId
        local source=stock.farm.sources[sourceId]
        local binding=stock.sourceBindings[sourceId]
        local owner=binding and stock.sourceOwners[binding.ownerId]
        if not source or not owner or not owner.byId[binding.animalId] or owner.quarantine[binding.animalId]
            or source.cursorMonths~=context.currentClock or listing.lastProgressedAtMonths~=context.currentClock
            or listing.expiresAtMonths<=context.currentClock then return false,"SOURCE_NOT_CURRENT" end
        local valid,reason=RLDealerSourceState.validate(source);if not valid then return false,reason end
        return ctx.eligible(source,listing,context)
    end
    a.validateQuote=function(_,context) local q,reason=quote(context);return q~=nil,reason end
    a.validateDestination=function(listings,context)
        local dest,reason=authority(context.request.principal,context.request.destination)
        if not dest then return false,reason end
        return ctx.validateCapacity(dest.destination,listings,context)
    end
    local function previewMoney(context)
        local q,reason=quote(context);if not q then return nil,reason end
        if q.amount<=0 then return nil,"POSITIVE_PURCHASE_AMOUNT_REQUIRED" end
        local dest;dest,reason=authority(context.request.principal,context.request.destination);if not dest then return nil,reason end
        local temporary=assert(RLDealerMoneyAdapter.new(moneyContext))
        return RLDealerMoneyAdapter.bind(temporary,dest.farmId,context.token,q.amount)
    end
    a.validateFunds=function(_,context) local m,reason=previewMoney(context);return m~=nil,reason end
    a.prepare=function(listings,context)
        if a.active[context.token] then
            if stock.purchase.records[context.request.requestId] or a.money.records[context.token] then return nil,"PREPARED_TOKEN_CONFLICT" end
            -- A previous side-effect-free preparation can have timed out before
            -- the coordinator created a durable record. It owns no assets.
            a.active[context.token]=nil
        end
        local dest,reason=authority(context.request.principal,context.request.destination);if not dest then return nil,reason end
        local q;q,reason=quote(context);if not q then return nil,reason end
        local preview;preview,reason=previewMoney(context);if not preview then return nil,reason end
        local owned;owned,reason=RLDealerOwnedStock.export(stock.sourceOwners,stock.sourceBindings,
            stock.sourceRecordsByOwner,stock.observedChildren,stock.farm.sources,context.currentClock)
        if not owned then return nil,reason end
        local groups,ownerIds={},{}
        for _,listing in ipairs(listings) do
            local binding=stock.sourceBindings[listing.payload.sourceId]
            if not groups[binding.ownerId] then groups[binding.ownerId]={ids={}};ownerIds[#ownerIds+1]=binding.ownerId end
            local group=groups[binding.ownerId];group.ids[#group.ids+1]=binding.animalId
        end
        table.sort(ownerIds)
        local clones,sourceEvidence={},{}
        for _,ownerId in ipairs(ownerIds) do
            local group=groups[ownerId]
            group.binding,reason=RLDealerSourceAdapter.bind(stock.sourceOwners[ownerId],group.ids,stock.sourceRecordsByOwner[ownerId])
            if not group.binding then return nil,reason end
            sourceEvidence[ownerId]=assert(RLDealerSourceAdapter.exportBinding(group.binding))
            local single=copy(owned.owners[ownerId]);single.animals={}
            local selected={};for _,id in ipairs(group.ids) do selected[id]=true end
            for _,animal in ipairs(owned.owners[ownerId].animals) do if selected[animal.identity.uniqueId] then single.animals[#single.animals+1]=copy(animal) end end
            local cloned,failure=RLDealerSourceOwnership.restore(single,ctx.resolveSubType,
                {isServer=true,resolveDiseaseModel=ctx.resolveDiseaseModel})
            if not cloned then return nil,failure.reason end
            clones[ownerId]=cloned
        end
        local batch,transferIds={},{}
        for _,listing in ipairs(listings) do
            local sourceId=listing.payload.sourceId
            local binding=stock.sourceBindings[sourceId]
            local animal=clones[binding.ownerId].byId[binding.animalId]
            animal.clusterSystem=nil
            local installed,failure=RLDealerHandoff.install(stock.farm.sources[sourceId],animal,{isServer=true})
            if not installed then return nil,failure.reason end
            batch[#batch+1]=animal;transferIds[#transferIds+1]=context.token..":"..listing.saleId
        end
        local owners=ctx.allOwners()
        if type(owners)~="table" then return nil,"COMPLETE_OWNER_INVENTORY_REQUIRED" end
        local target;target,reason=RLDealerTargetAdapter.bind(dest.destination,batch,owners)
        if not target then return nil,reason end
        local plan={amount=q.amount,transferIds=transferIds,compensation={source=sourceEvidence,
            target=RLDealerTargetAdapter.exportBinding(target),destination=copy(dest.identity),money=preview,
            listings=copy(listings),ownership=owned,sources=copy(stock.farm.sources)}}
        if plan.compensation.target==nil or RLTradePersistence.check(plan,RLDealerPurchase.LIMITS) then return nil,"PREPARED_EVIDENCE_INVALID" end
        a.active[context.token]={plan=copy(plan),groups=groups,ownerIds=ownerIds,target=target,
            destination=dest,listings=copy(listings),reserved=nil}
        return plan
    end
    local function world(active)
        local owners=ctx.allOwners()
        local target,reason=RLDealerDestination.resolvePersisted(active.destination.identity,owners)
        if target~=active.destination.destination then return nil,reason or "TARGET_CHANGED" end
        local scanned;scanned,reason=RLDealerTargetAdapter.scanOwners(owners);if not scanned then return nil,reason end
        active.target.worldOwners=owners
        return true
    end
    local function fence(active,context,removed,paid)
        if stock.farm.clock.months~=context.currentClock then return nil,"CURRENT_CLOCK_CHANGED" end
        local resolved,why=authority(context.request.principal,context.request.destination)
        if not resolved or resolved.destination~=active.destination.destination or not equal(resolved.identity,active.destination.identity) then return nil,why or "DESTINATION_CHANGED" end
        if not equal(stock.farm.sources,active.plan.compensation.sources)
            or not equal(stock.sourceBindings,active.plan.compensation.ownership.bindings) then return nil,"SOURCE_RECORD_CHANGED" end
        if active.reserved then
            if not equal(stock.listings,active.reserved) then return nil,"RESERVATION_CHANGED" end
            local ms=ctx.monotonicMs()
            for _,row in ipairs(active.listings) do
                if ms>=active.reserved.records[row.saleId].lock.expiresAtReal then return nil,"LOCK_EXPIRED" end
            end
        end
        local currentQuote;currentQuote,why=quote(context,active)
        if not currentQuote or currentQuote.amount~=active.plan.amount then return nil,why or "SERVER_PRICE_CHANGED" end
        for _,row in ipairs(active.listings) do
            local valid;valid,why=ctx.eligible(stock.farm.sources[row.payload.sourceId],row,context)
            if valid~=true then return nil,why or "INELIGIBLE" end
        end
        if not world(active) then return nil,"WORLD_OWNERSHIP_UNKNOWN" end
        for _,ownerId in ipairs(active.ownerIds) do
            if RLDealerSourceAdapter.observe(active.groups[ownerId].binding)~=(removed and "REMOVED" or "PRESENT") then return nil,"SOURCE_CHANGED" end
        end
        if a.money.records[context.token] then
            local money=RLDealerMoneyAdapter.observe(a.money,context.token)
            if not money or money.status~=(paid and "APPLIED" or "NOT_APPLIED") then return nil,"MONEY_CHANGED" end
        end
        return true
    end
    local function commit(active,token,plan,context)
        local fenced,why=fence(active,context,true,true)
        if not fenced then return nil,why end
        if not world(active) then return hold("WORLD_OWNERSHIP_UNKNOWN") end
        local target=RLDealerTargetAdapter.observe(active.target)
        if not target.known or not target.othersIntact or not target.fieldsIntact or not target.queuesClean
            or #target.added~=#active.target.entries then return nil,"TARGET_INCOMPLETE" end
        for _,ownerId in ipairs(active.ownerIds) do
            if RLDealerSourceAdapter.observe(active.groups[ownerId].binding)~="REMOVED" then return nil,"SOURCE_INCOMPLETE" end
        end
        local money=RLDealerMoneyAdapter.observe(a.money,token)
        if not money or money.status~="APPLIED" then return nil,"MONEY_INCOMPLETE" end
        if stock.recoveryRequired then return nil,"RECOVERY_REQUIRED" end
        local listings=RLDealerListingRegistry.export(stock.listings)
        local ms=ctx.monotonicMs()
        for _,row in ipairs(active.listings) do
            local current=listings.records[row.saleId]
            local sold,reason=RLDealerListingRegistry.markSold(listings,row.saleId,context.request.requestId,
                current.recordRevision,context.currentClock,ms)
            if not sold or sold.state~="SOLD" then return nil,reason or "SALE_COMMIT_FAILED" end
        end
        stock.listings=listings
        for _,row in ipairs(active.listings) do
            local sourceId=row.payload.sourceId;local binding=stock.sourceBindings[sourceId]
            stock.sourceRecordsByOwner[binding.ownerId][binding.animalId]=nil
            stock.sourceBindings[sourceId],stock.farm.sources[sourceId]=nil,nil
        end
        active.receipt=receipt(token,plan,"COMMITTED")
        return copy(active.receipt)
    end
    a.apply=function(token,plan,context)
        local active=a.active[token]
        if not active or not equal(plan,active.plan) or a.busy or stock.recoveryRequired then return nil,"PREPARED_TRANSFER_REQUIRED" end
        if active.receipt then return copy(active.receipt) end
        local transaction=stock.purchase.records[context.request.requestId]
        if not transaction or transaction.stage~="APPLYING" or not equal(transaction.plan,plan)
            or not equal(transaction.context,context) then return nil,"DURABLE_APPLYING_STAGE_REQUIRED" end
        a.busy=true
        local ok,value,reason=pcall(function()
            local fenced,fenceReason=fence(active,context,false);if not fenced then return nil,fenceReason end
            for _,row in ipairs(active.listings) do
                if not equal(a.readListing(row.saleId),row) then return nil,"LISTING_CHANGED" end
                local valid,why=a.validateListing(row,context);if valid~=true then return nil,why end
            end
            for _,name in ipairs({"validateQuote","validateDestination","validateFunds"}) do
                local valid,why=a[name](active.listings,context);if valid~=true then return nil,why end
            end
            if not world(active) then return nil,"WORLD_OWNERSHIP_UNKNOWN" end
            for _,ownerId in ipairs(active.ownerIds) do
                if RLDealerSourceAdapter.observe(active.groups[ownerId].binding)~="PRESENT" then return nil,"SOURCE_CHANGED" end
            end
            local money,why=RLDealerMoneyAdapter.bind(a.money,active.destination.farmId,token,plan.amount)
            if not money or not equal(money,plan.compensation.money) then return nil,why or "MONEY_CHANGED" end
            local listings=RLDealerListingRegistry.export(stock.listings)
            local ms=ctx.monotonicMs()
            for _,row in ipairs(active.listings) do
                local reserved;reserved,why=RLDealerListingRegistry.reserve(listings,row.saleId,row.recordRevision,
                    context.request.requestId,context.currentClock,ms,RLDealerPurchase.LOCK_MS)
                if not reserved or reserved.state~="RESERVED" then return nil,why or "RESERVATION_FAILED" end
            end
            stock.listings,active.reserved=listings,copy(listings)
            if not a.checkpoint(RLDealerPurchase.export(stock.purchase)) then return nil,"PURCHASE_BARRIER_UNCERTAIN" end
            fenced,fenceReason=fence(active,context,false);if not fenced then return nil,fenceReason end
            local capacity;capacity,why=ctx.validateCapacity(active.destination.destination,active.listings,context)
            if capacity~=true then return nil,why or "CAPACITY_CHANGED" end
            for _,ownerId in ipairs(active.ownerIds) do
                local detached;detached,why=RLDealerSourceAdapter.apply(active.groups[ownerId].binding)
                if not detached then return nil,why end
            end
            local attached;attached,why=RLDealerTargetAdapter.apply(active.target)
            if not attached then return nil,why end
            fenced,fenceReason=fence(active,context,true);if not fenced then return nil,fenceReason end
            local observed=RLDealerTargetAdapter.observe(active.target)
            if not observed.known or not observed.othersIntact or not observed.fieldsIntact or not observed.queuesClean
                or #observed.added~=#active.target.entries then return nil,"TARGET_CHANGED" end
            local paid=RLDealerMoneyAdapter.apply(a.money,token)
            if not paid or paid.status~="APPLIED" then return nil,"MONEY_UNCERTAIN" end
            return commit(active,token,plan,context)
        end)
        a.busy=false
        if not ok then return hold("PURCHASE_EFFECT_ERROR") end
        return value,reason
    end
    a.reconcile=function(token,plan,context)
        local active=a.active[token]
        if not active or not equal(plan,active.plan) or stock.recoveryRequired or a.busy then return nil,"OWNERSHIP_RECONCILIATION_REQUIRED" end
        if active.receipt then return copy(active.receipt) end
        local money=a.money.records[token] and RLDealerMoneyAdapter.observe(a.money,token)
        if money and money.status=="APPLIED" then
            local committed=commit(active,token,plan,context)
            if committed then return committed end
            return hold("PAID_TRANSFER_REQUIRES_RECOVERY")
        end
        if money and money.status~="NOT_APPLIED" then return hold("MONEY_OWNERSHIP_UNKNOWN") end
        -- No debit happened. Only exact target/source compensation can produce
        -- ROLLED_BACK; after an actual debit we never infer a complete refund.
        a.busy=true
        local ok,value,why=pcall(function()
            if not world(active) then return hold("WORLD_OWNERSHIP_UNKNOWN") end
            if not a.checkpoint(RLDealerPurchase.export(stock.purchase)) then return nil,"PURCHASE_BARRIER_UNCERTAIN" end
            local restored,reason=RLDealerTargetAdapter.rollback(active.target)
            if not restored or not RLDealerTargetAdapter.verifyRestored(active.target) then return hold(reason or "TARGET_ROLLBACK_UNKNOWN") end
            for _,ownerId in ipairs(active.ownerIds) do
                restored,reason=RLDealerSourceAdapter.rollback(active.groups[ownerId].binding)
                if not restored then return hold(reason) end
            end
            if active.reserved then
                if not equal(stock.listings,active.reserved) then return hold("LISTING_ROLLBACK_CHANGED") end
                local listings=RLDealerListingRegistry.export(stock.listings)
                for _,row in ipairs(active.listings) do
                    local released;released,reason=RLDealerListingRegistry.release(listings,row.saleId,context.request.requestId,
                        context.currentClock,ctx.monotonicMs())
                    if not released then return hold(reason) end
                end
                stock.listings=listings
            end
            if money then
                local cancelled=RLDealerMoneyAdapter.cancel(a.money,token)
                if not cancelled or cancelled.status~="NOT_APPLIED" then return hold("MONEY_CANCEL_UNCERTAIN") end
            end
            active.receipt=receipt(token,plan,"ROLLED_BACK");return copy(active.receipt)
        end)
        a.busy=false
        if not ok then return hold("PURCHASE_COMPENSATION_ERROR") end
        return value,why
    end
    return a
end
