-- Read-only whole-batch capacity witness. This is neither a reservation nor a
-- purchase endpoint; the coordinator must repeat it immediately before effects.
RLDealerCapacity={}
local C=RLDealerCapacity
local function copy(v) if type(v)~="table" then return v end;local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out end
local function fail(reason) error(reason,0) end
local function integer(v) return type(v)=="number" and v==v and v>=0 and v<math.huge and v%1==0 end
local function dense(t)
    if type(t)~="table" then return false end
    local n=0;for k in pairs(t) do if not integer(k) or k<1 or k>#t then return false end;n=n+1 end
    return n==#t
end
local function equal(a,b) return RLTradePersistence.canonical(a)==RLTradePersistence.canonical(b) end
local function call(object,name,...)
    if type(object[name])~="function" then fail("CAPABILITY:"..name) end
    return object[name](object,...)
end
local function stockSnapshot(s)
    local encoded,why=RLDealerOwnedStock.export(s.sourceOwners,s.sourceBindings,s.sourceRecordsByOwner,
        s.observedChildren,s.farm.sources,s.farm.clock.months,s.retiredSources)
    if not encoded then fail(why) end
    local valid=RLDealerOwnedStock.validate(encoded,s.farm.sources,s.farm.clock.months)
    if valid.recoveryRequired then fail("SOURCE_OWNERSHIP_UNCERTAIN") end
    return {owned=encoded,sources=s.farm.sources,clock=RLDealerClock.export(s.farm.clock),
        listings=RLDealerListingRegistry.export(s.listings)}
end
function C.new(ctx)
    if type(ctx)~="table" or ctx.isServer~=true or type(ctx.mission)~="table" or type(ctx.stock)~="table"
        or type(ctx.resolveSubType)~="function" or type(ctx.allOwners)~="function" then return nil,"CAPACITY_CONTEXT" end
    if RLDealerWorld==nil then return nil,"CAPACITY_WORLD_REQUIRED" end
    local world,why=RLDealerWorld.new({isServer=true,mission=ctx.mission});if not world then return nil,why end
    local mission,stock=ctx.mission,ctx.stock
    local function owners(destination)
        local provided,reason=ctx.allOwners();if not dense(provided) then fail(reason or "WORLD_OWNERS_UNREADABLE") end
        local authoritative;authoritative,reason=world.allOwners();if not authoritative then fail(reason) end
        local expected,seen={},{}
        for _,owner in ipairs(authoritative) do expected[owner]=true end
        if #provided~=#authoritative then fail("WORLD_OWNERS_INCOMPLETE") end
        for _,owner in ipairs(provided) do
            if seen[owner] or not expected[owner] then fail("WORLD_OWNERS_MISMATCH") end
            seen[owner]=true
        end
        if not seen[destination] then fail("DESTINATION_NOT_IN_WORLD") end
    end
    local function validate(destination,listings,context)
        if mission~=g_currentMission or call(mission,"getIsServer")~=true then fail("SERVER_REQUIRED") end
        if stock.recoveryRequired or stock.purchase.recoveryRequired then fail("RECOVERY_REQUIRED") end
        if stock.sourceUpdateInProgress then fail("SOURCE_UPDATE_IN_PROGRESS") end
        if type(context)~="table" or context.currentClock~=stock.farm.clock.months then fail("SOURCE_CLOCK") end
        if not dense(listings) or #listings==0 then fail("EMPTY_OR_INVALID_BATCH") end
        owners(destination)
        local cluster,kind=RLTradeSourceAdapter.getSupport(destination);if not cluster then fail(kind) end
        local members=call(cluster,"getClusters")
        if not dense(members) or not dense(cluster.animals) or #members~=#cluster.animals then fail("DESTINATION_UNREADABLE") end
        local used,initialMembers,initialCounts=0,{},{}
        for i,animal in ipairs(members) do
            if type(animal)~="table" or animal~=cluster.animals[i] or animal.clusterSystem~=cluster then fail("DESTINATION_MEMBERS_MISMATCH") end
            local n=call(animal,"getNumAnimals");if not integer(n) or n<1 then fail("DESTINATION_MEMBER_COUNT") end
            used=used+n
            initialMembers[i],initialCounts[i]=animal,n
        end
        local count=call(destination,"getNumOfAnimals")
        if not integer(count) or count~=used then fail("DESTINATION_COUNT_MISMATCH") end
        local before=stockSnapshot(stock)
        -- Sources in this proof must not alias later callback mutations.
        before.sources=copy(before.sources)
        local batchType,subtypes,sales,sources=nil,{},{},{}
        local system=mission.animalSystem
        if type(system)~="table" then fail("ANIMAL_SYSTEM_REQUIRED") end
        for _,listing in ipairs(listings) do
            if type(listing)~="table" or type(listing.payload)~="table" or sales[listing.saleId] then fail("DUPLICATE_OR_INVALID_LISTING") end
            sales[listing.saleId]=true
            local current=stock.listings.records[listing.saleId]
            if not current or (current.state~="LISTED" and current.state~="RESERVED") or not equal(current.payload,listing.payload)
                or current.lastProgressedAtMonths~=context.currentClock or current.expiresAtMonths<=context.currentClock then fail("LISTING_NOT_CURRENT") end
            local sourceId=listing.payload.sourceId
            if sources[sourceId] then fail("DUPLICATE_SOURCE") end;sources[sourceId]=true
            local record=stock.farm.sources[sourceId]
            local binding=stock.sourceBindings[sourceId]
            local owner=binding and stock.sourceOwners[binding.ownerId]
            local animal=owner and owner.byId[binding.animalId]
            if not record or record.cursorMonths~=context.currentClock or not animal or animal.isDead or animal.isSold
                or animal.clusterSystem~=owner.clusterSystem then fail("SOURCE_NOT_CURRENT") end
            local sub,index=ctx.resolveSubType(record.animal.subType)
            index=index or (sub and sub.subTypeIndex)
            if type(sub)~="table" or not integer(index) or index<1 or sub.name~=record.animal.subType
                or call(system,"getSubTypeByIndex",index)~=sub or call(animal,"getSubType")~=sub
                or sub.breed~=record.animal.breed or sub.gender~=record.animal.gender
                or sub.typeIndex~=record.animal.animalTypeIndex or animal.animalTypeIndex~=sub.typeIndex
                or animal.age~=record.animal.age or animal.gender~=record.animal.gender
                or animal.isCastrated~=record.animal.isCastrated or call(animal,"getNumAnimals")~=1 then fail("SOURCE_SUBTYPE_OR_PHYSIOLOGY") end
            if call(destination,"getSupportsAnimalSubType",index)~=true then fail("ANIMAL_NOT_SUPPORTED") end
            if kind=="PEN" then
                local admitted,reason=RLHusbandryProfiles.checkAnimalReadOnly(destination,
                    {subTypeIndex=index,age=animal.age,gender=animal.gender,isCastrated=animal.isCastrated})
                if not admitted then fail(reason or "PEN_RULES") end
            end
            local animalType=call(system,"getTypeByIndex",sub.typeIndex)
            if type(animalType)~="table" or animalType.typeIndex~=sub.typeIndex then fail("ANIMAL_TYPE_UNREADABLE") end
            if kind=="TRAILER" and batchType~=nil and batchType~=animalType then fail("TRAILER_MIXED_TYPES") end
            batchType=batchType or animalType;subtypes[index]=animalType
        end
        if kind=="TRAILER" then
            local currentType=call(destination,"getCurrentAnimalType")
            if currentType~=nil and currentType~=batchType then fail("TRAILER_CURRENT_TYPE") end
            for _,animal in ipairs(members) do
                local sub=call(animal,"getSubType")
                if type(sub)~="table" or sub.typeIndex~=batchType.typeIndex then fail("TRAILER_RESIDENT_TYPE") end
            end
        end
        local maximum=kind=="TRAILER" and call(destination,"getMaxNumOfAnimals",batchType) or call(destination,"getMaxNumOfAnimals")
        if not integer(maximum) or used>maximum or #listings>maximum-used then fail("NOT_ENOUGH_SPACE") end
        for index in pairs(subtypes) do
            local free=call(destination,"getNumOfFreeAnimalSlots",index)
            if not integer(free) or free>maximum-used then fail("CAPACITY_INCONSISTENT") end
            -- Every subtype shares the same total batch, never just its own count.
            if #listings>free then fail("NOT_ENOUGH_SPACE") end
        end
        if RLTradeSourceAdapter.getSupport(destination)~=cluster then fail("DESTINATION_CLUSTER_CHANGED") end
        local finalMembers=call(cluster,"getClusters")
        if call(destination,"getNumOfAnimals")~=used or not dense(finalMembers) or not dense(cluster.animals)
            or #finalMembers~=#initialMembers or #cluster.animals~=#initialMembers then fail("DESTINATION_CHANGED") end
        for i,animal in ipairs(initialMembers) do
            if finalMembers[i]~=animal or cluster.animals[i]~=animal or animal.clusterSystem~=cluster
                or call(animal,"getNumAnimals")~=initialCounts[i] then fail("DESTINATION_MEMBERS_CHANGED") end
        end
        local after=stockSnapshot(stock)
        if not equal(before,after) then fail("SOURCE_SNAPSHOT_CHANGED") end
        owners(destination)
        if next(cluster.clustersToAdd)~=nil or next(cluster.clustersToRemove)~=nil then fail("DESTINATION_QUEUE_CHANGED") end
        -- World inventory getters run above. Recheck stored members without
        -- invoking another getter that could replace an already checked member.
        if not dense(cluster.animals) or #cluster.animals~=#initialMembers then fail("DESTINATION_CHANGED") end
        for i,animal in ipairs(initialMembers) do
            if cluster.animals[i]~=animal or animal.clusterSystem~=cluster then fail("DESTINATION_MEMBERS_CHANGED") end
        end
        return true
    end
    return function(destination,listings,context)
        local ok,result=pcall(validate,destination,listings,context)
        if not ok then return false,"CAPACITY_UNSAFE:"..tostring(result) end
        return result
    end
end
