loadMod("tests/dealerreplaysim.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/dealer/RLDealerClock.lua")
loadMod("scripts/dealer/RLDealerListingRegistry.lua")
loadMod("scripts/dealer/RLDealerSourceState.lua")
loadMod("scripts/dealer/RLDealerPurchase.lua")
loadMod("scripts/dealer/RLDealerPersistence.lua")
local D,T=RLDealerPersistence,RLTradePersistence
local function clone(t) if type(t) ~= "table" then return t end; local o={}; for k,v in pairs(t) do o[k]=clone(v) end; return o end
-- In-memory XMLFile stand-in, not the engine's filesystem or multi-file save pass.
local function xml()
    local x={values={}}
    function x:setString(key,v) self.values[key]=v end
    function x:getString(key) return self.values[key] end
    function x:iterate(prefix,fn)
        local keys={}
        for key in pairs(self.values) do
            if key:sub(1,#prefix+1)==prefix .. "(" and key:sub(-2)=="#v" then keys[#keys+1]=key:sub(1,-3) end
        end
        table.sort(keys,function(a,b) return tonumber(a:match("%((%d+)%)$")) < tonumber(b:match("%((%d+)%)$")) end)
        for i,key in ipairs(keys) do fn(i-1,key) end
    end
    return x
end
local Sim=DealerReplaySim
local seed=Sim.seed("HOLSTEIN","female",1)
local result=assert(RLDealerReplay.run(seed,Sim.history(seed,8.5),{daysPerMonth=1}))
local source=assert(RLDealerSourceState.capture(result,100.25))
local clock=assert(RLDealerClock.new(100.25))
local listings=assert(RLDealerListingRegistry.new("persist-stock"))
local draft=assert(RLDealerListingRegistry.createDraft(listings,{sourceId="dam-1"},"GROWING",100.25))
RLDealerListingRegistry.list(listings,draft.saleId,100.25)
local purchase=RLDealerPurchase.new()
local meta={lineage="DLsave-1",generation=1,parentGeneration=0,checkpointId="DLsave-1:1"}
local markers={}
for _,role in ipairs(D.REQUIRED_PARTICIPANTS) do markers[role]=assert(D.marker(meta.lineage,1,{file=role,receipt="saved"})) end
local snapshot=assert(D.capture(meta,clock,listings,{["dam-1"]=source},purchase,markers))
local function resolver(name) local _,sub=Economics.find(name); return sub end
local x=xml(); local ok,digest=D.writeDocument(x,snapshot,markers); assert(ok)
local commit=assert(D.commitMarker(snapshot,digest))
local loaded=assert(D.readDocument(x,markers,resolver,commit))
check("dealer persistence: independent root and filename never overwrite T02 ledger", D.ROOT ~= T.ROOT and D.FILENAME ~= T.FILENAME and x.values[T.ROOT .. "#schema"] == nil)
check("dealer persistence: strict full snapshot preserves exact source kg and stable listing identity", loaded.state=="VERIFIED" and loaded.sourceResolution=="RESOLVED" and loaded.restored.sources["dam-1"].animal.weight==source.animal.weight and loaded.restored.listings.records[draft.saleId].saleId==draft.saleId and loaded.restored.clock.months==100.25)
source.animal.weight=999
check("dealer persistence: capture is an independent data snapshot", snapshot.sources["dam-1"].animal.weight ~= 999)
local bad=clone(snapshot); bad.playerAnimals={}
check("dealer persistence: player animal payloads and unknown top-level fields reject", not D.validateSnapshot(bad,markers))
local changed=clone(markers); changed.farms.generation=2
check("dealer persistence: all external participant generations must match", not D.readDocument(x,changed,resolver,commit))
changed=clone(markers); changed.vehicles.digest="0000000000000000"
check("dealer persistence: mixed trailer participant content digest rejects", not D.readDocument(x,changed,resolver,commit))
changed=clone(markers); changed.placeables=nil
check("dealer persistence: missing target pen participant marker rejects", not D.readDocument(x,changed,resolver,commit))
changed=clone(markers); changed.sourceAnimals=clone(changed.farms)
check("dealer persistence: invented participant files reject", not D.readDocument(x,changed,resolver,commit))
local rejected,why,q=D.readDocument(x,markers,resolver,nil)
check("dealer persistence: dealer document alone cannot authorize a checkpoint", not rejected and why=="CAREER_COMMIT_REQUIRED" and q.state=="QUARANTINED")
local old=clone(commit); old.generation=2
check("dealer persistence: career commit generation mismatch quarantines", not D.readDocument(x,markers,resolver,old))
old=clone(commit); old.dealerStockDigest="0000000000000000"
check("dealer persistence: career commit binds complete dealer document digest", not D.readDocument(x,markers,resolver,old))
old=clone(commit); old.participantsDigest="0000000000000000"
check("dealer persistence: career commit binds complete external marker set", not D.readDocument(x,markers,resolver,old))
local broken=clone(x); setmetatable(broken,{__index=x})
broken.values[D.ROOT .. "#schema"]="999"
rejected,why,q=D.readDocument(broken,markers,resolver,commit)
check("dealer persistence: unknown XML schema retains original recovery evidence", not rejected and why=="UNKNOWN_SCHEMA" and #q.raw.encoded>0 and q.raw.schema=="999")
broken.values=clone(x.values); broken.values[D.ROOT .. "#digest"]="0000000000000000"
rejected,why,q=D.readDocument(broken,markers,resolver,commit)
check("dealer persistence: corrupt digest quarantines without repair", not rejected and why=="DIGEST_MISMATCH" and q.raw.digest=="0000000000000000")
broken.values=clone(x.values); broken.values[D.ROOT .. ".data#length"]="1"
check("dealer persistence: truncated document length rejects", not D.readDocument(broken,markers,resolver,commit))
local badMeta=clone(meta); badMeta.parentGeneration=9
check("dealer persistence: parent generation must be direct predecessor", not D.capture(badMeta,clock,listings,snapshot.sources,purchase,markers))
bad=clone(snapshot); bad.sources["dam-1"].cursorMonths=200
check("dealer persistence: source cursor or biological state corruption rejects", not D.validateSnapshot(bad,markers))
bad=clone(snapshot); bad.listings.records[draft.saleId].payload.sourceId="missing"
check("dealer persistence: listing cannot point to absent source stock", not D.validateSnapshot(bad,markers))
bad=clone(snapshot); bad.listings.records[draft.saleId].lastProgressedAtMonths=100
check("dealer persistence: listing and source physiology cursors must agree", not D.validateSnapshot(bad,markers))
rejected,why,q=D.readDocument(x,markers,function() return nil end,commit)
check("dealer persistence: missing installed subtype quarantines raw checkpoint without breed remapping", not rejected and why:find("SOURCE_RESOLVE",1,true) and #q.raw.encoded>0)
local unresolved=assert(D.readDocument(x,markers,nil,commit))
check("dealer persistence: data-only read explicitly reports unchecked installed source resolution", unresolved.sourceResolution=="NOT_CHECKED")
local player={weight=1234}; local random=math.random; math.random=function() error("persistence RNG") end
assert(D.readDocument(x,markers,resolver,commit)); math.random=random
check("dealer persistence: stock-only roundtrip draws no RNG and touches no player animals", player.weight==1234)
local reserved=clone(snapshot)
local row=reserved.listings.records[draft.saleId]
RLDealerListingRegistry.reserve(reserved.listings,row.saleId,row.recordRevision,"pending",100.25,0,5)
local rx=xml(); local wrote,rd=D.writeDocument(rx,reserved,markers); assert(wrote)
local reloaded=assert(D.readDocument(rx,markers,resolver,D.commitMarker(reserved,rd)))
check("dealer persistence: interrupted reservation remains quarantined for journal ownership recovery", reloaded.restored.recoveryRequired and reloaded.restored.listings.records[row.saleId].state=="QUARANTINED")
local empty=xml()
check("dealer persistence: absent document cannot silently create or reroll stock", not D.readDocument(empty,markers,resolver,commit))
local fresh=xml(); bad=clone(snapshot); bad.sources["dam-1"].animal.weight=0/0
check("dealer persistence: invalid write validates everything before touching XML", not D.writeDocument(fresh,bad,markers) and next(fresh.values)==nil)
local function rewriteRaw(raw)
    local z=xml(); local text=T.canonical(raw); local encoded=T.encodeText(text)
    z:setString(D.ROOT .. "#schema","1"); z:setString(D.ROOT .. "#lineage",raw.lineage)
    z:setString(D.ROOT .. "#generation",tostring(raw.generation)); z:setString(D.ROOT .. "#checkpointId",raw.checkpointId)
    z:setString(D.ROOT .. "#digest",T.checksum(text)); z:setString(D.ROOT .. ".data#length",tostring(#encoded))
    local index=0
    for start=1,#encoded,T.CHUNK do z:setString(D.ROOT .. ".data.chunk(" .. index .. ")#v",encoded:sub(start,start+T.CHUNK-1)); index=index+1 end
    return z
end
bad=clone(snapshot); bad.version=999
rejected,why,q=D.readDocument(rewriteRaw(bad),markers,resolver,commit)
check("dealer persistence: unknown snapshot version is quarantined without interpreting stock", not rejected and why=="UNKNOWN_SNAPSHOT_VERSION" and #q.raw.encoded>0)
bad=clone(snapshot); bad.participants=nil
rejected,why,q=D.readDocument(rewriteRaw(bad),markers,resolver,commit)
check("dealer persistence: corrupt marker section rejects without throwing or synthesizing markers", not rejected and q.state=="QUARANTINED")
local function transaction(saleId)
    local req={requestId="buy",principal="server-principal",destination="pen",quoteCredential="quote",items={{saleId=saleId,revision=2}}}
    return {request=req,fingerprint=T.canonical(req),stage="COMMITTED",plan={amount=1,transferIds={"transfer"},compensation={}},
        context={request=clone(req),currentClock=100.25,token="dealer:buy"},
        receipt={status="COMMITTED",token="dealer:buy",amount=1,sourceComplete=true,targetComplete=true,moneyComplete=true,transferIds={"transfer"}},result={status="COMMITTED",requestId="buy",amount=1,transferIds={"transfer"}}}
end
bad=clone(snapshot); bad.purchase.records.buy=transaction(draft.saleId)
check("dealer persistence: committed journal cannot coexist with unsold dealer listing", not D.validateSnapshot(bad,markers))
local live=bad.listings.records[draft.saleId]
live=assert(RLDealerListingRegistry.reserve(bad.listings,live.saleId,live.recordRevision,"buy",100.25,0,5))
assert(RLDealerListingRegistry.markSold(bad.listings,live.saleId,"buy",live.recordRevision,100.25,1))
check("dealer persistence: matching sold identity and committed ownership journal validate together", D.validateSnapshot(bad,markers) ~= nil)
bad.purchase.records.buy=transaction("absent")
check("dealer persistence: journal cannot refer to nonexistent stable sale identity", not D.validateSnapshot(bad,markers))
local cycle={};cycle.self=cycle
check("dealer persistence: cyclic participant input rejects without canonical recursion", not D.marker(meta.lineage,1,cycle))
check("dealer persistence: malformed commit snapshot cannot throw or generate a commit marker", not D.commitMarker({version=1,scope="DEALER_STOCK_ONLY",lineage="DLx",generation=1,parentGeneration=0,checkpointId="DLx:1"},"0000000000000000"))

local withdrawn=clone(snapshot)
RLDealerListingRegistry.withdraw(withdrawn.listings,draft.saleId,100.25,"INELIGIBLE")
withdrawn.listings.records[draft.saleId].lastProgressedAtMonths=100
check("dealer persistence: withdrawn listing cursor cannot block later source farm feeding", D.validateSnapshot(withdrawn,markers) ~= nil)
local growing=assert(RLDealerSourceState.restore(snapshot.sources["dam-1"],resolver))
local grown=assert(RLDealerReplay.resume(growing,8.75,{daysPerMonth=1}))
local afterWithdrawal=clone(snapshot)
RLDealerListingRegistry.withdraw(afterWithdrawal.listings,draft.saleId,100.25,"INELIGIBLE")
afterWithdrawal.sources["dam-1"]=assert(RLDealerSourceState.advanceCursor(snapshot.sources["dam-1"],grown,100.5))
RLDealerClock.advanceHours(afterWithdrawal.clock,6,1)
local grownXml=xml()
check("dealer persistence: actual source growth after listing withdrawal remains saveable", D.writeDocument(grownXml,afterWithdrawal,markers) == true and afterWithdrawal.sources["dam-1"].animal.weight ~= snapshot.sources["dam-1"].animal.weight)
local sold=clone(snapshot);local soldRow=sold.listings.records[draft.saleId]
soldRow=assert(RLDealerListingRegistry.reserve(sold.listings,soldRow.saleId,soldRow.recordRevision,"buy",100.25,0,5))
RLDealerListingRegistry.markSold(sold.listings,soldRow.saleId,"buy",soldRow.recordRevision,100.25,1)
sold.purchase.records.buy=transaction(soldRow.saleId);sold.sources["dam-1"]=nil
check("dealer persistence: sold source ownership may leave farm without terminal listing pinning it", D.validateSnapshot(sold,markers) ~= nil)
