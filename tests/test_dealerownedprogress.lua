loadMod("tests/dealerownedfixture.lua")
local F,U,T=DealerOwnedFixture,RLDealerOwnedProgress,RLTradePersistence
local function encode(stock)
    return assert(RLDealerOwnedStock.export(stock.sourceOwners,stock.sourceBindings,stock.sourceRecordsByOwner,
        stock.observedChildren,stock.farm.sources,stock.farm.clock.months))
end
for _,days in ipairs({1,3,7}) do
    local stock,ctx,id=F.new({child=true})
    local oldOwner,oldDam,oldChild=stock.sourceOwners.OWNER,stock.sourceOwners.OWNER.byId.DAM,stock.sourceOwners.OWNER.byId.CHILD
    local calls=0;ctx.persistBarrier=function(payload) calls=calls+1;return RLDealerOwnedStock.validate(payload.recovery.sourceOwnership,payload.recovery.sources,payload.recovery.clockMonths)~=nil end
    local random,ensure=math.random,RLGrowth.ensureState
    math.random=function() error("owned progress RNG") end;RLGrowth.ensureState=function() error("owned progress migration") end
    local result,why=U.advance(stock,{{hours=24*days,daysPerMonth=days}},ctx)
    math.random,RLGrowth.ensureState=random,ensure
    assert(result,why)
    local owner=stock.sourceOwners.OWNER
    check("owned progress: "..days.." day calendar advances real mother and observed child together without RNG",result.months==101
        and stock.farm.sources.source.ageMonths==9.5 and stock.observedChildren.OWNER.CHILD.cursorMonths==101
        and owner.byId.CHILD.rlGrowth.ageMonths==1 and owner.byId.CHILD.genetics.fertility==0 and owner.byId.CHILD.genetics.metabolism==2.1
        and owner.byId.CHILD.rlGrowth.birthWeightKg==41.23456789 and calls==1 and stock.listings.records[id].lastProgressedAtMonths==101)
    check("owned progress: "..days.." day staging preserves old objects until complete publication",oldOwner.byId.DAM==oldDam and oldDam.age==8
        and oldChild.age==0 and owner~=oldOwner and owner.clusterSystem.owner==owner and owner.byId.CHILD.rlHistoryReplay==nil)
    check("owned progress: "..days.." day full owned inventory can save and restore exact progressed kg",RLDealerOwnedStock.restore(encode(stock),stock.farm.sources,101,ctx.resolveSubType,{isServer=true})~=nil)
end
local stock,ctx,id=F.new({child=true})
local before=T.canonical(encode(stock));local writes=0;ctx.persistBarrier=function() writes=writes+1;return true end
local result,why=U.advance(stock,{{hours=24,daysPerMonth=1},{hours=24,daysPerMonth=0}},ctx)
check("owned progress: invalid later segment leaves all real animals and source cursor untouched",not result and T.canonical(encode(stock))==before and stock.farm.clock.months==100 and writes==0 and not stock.recoveryRequired)
stock,ctx,id=F.new({child=true});before=T.canonical(encode(stock));ctx.persistBarrier=function() return false end
result,why=U.advance(stock,{{hours=24,daysPerMonth=1}},ctx)
check("owned progress: uncertain write retains before/staged evidence and never publishes half the inventory",not result and why=="SOURCE_PROGRESS_BARRIER_UNCERTAIN"
    and stock.recoveryRequired and stock.farm.clock.months==100 and T.canonical(encode(stock))==before
    and stock.sourceProgressEvidence.staged.clock.months==101 and not stock.sourceUpdateInProgress)
check("owned progress: uncertain write cannot retry into duplicate source feeding",not U.advance(stock,{{hours=24,daysPerMonth=1}},ctx) and stock.farm.clock.months==100)
stock,ctx,id=F.new({child=true});ctx.persistBarrier=function() stock.sourceOwners.OWNER.byId.DAM.health=99;return true end
result,why=U.advance(stock,{{hours=1,daysPerMonth=1}},ctx)
check("owned progress: callback mutation after barrier closes rather than overwriting a foreign source change",not result
    and why=="SOURCE_SNAPSHOT_CHANGED_AFTER_BARRIER" and stock.recoveryRequired and stock.farm.clock.months==100
    and stock.sourceOwners.OWNER.byId.DAM.health==99 and stock.sourceProgressEvidence.staged.clock.months>100)
stock,ctx,id=F.new({pregnant=true});before=T.canonical(encode(stock));writes=0;ctx.persistBarrier=function() writes=writes+1;return true end
result,why=U.advance(stock,{{hours=24*7,daysPerMonth=1}},ctx)
check("owned progress: due real birth is an explicit boundary with no synthetic history or partial time loss",not result and why=="SOURCE_CALVING_REQUIRED"
    and T.canonical(encode(stock))==before and stock.farm.clock.months==100 and writes==0 and not stock.recoveryRequired)
stock,ctx,id=F.new({child=true});ctx.eligible=function() return false,"MATURED" end
assert(U.advance(stock,{{hours=24,daysPerMonth=1}},ctx))
check("owned progress: withdrawn listings retain growing source mothers and actual calves",stock.listings.records[id].state=="WITHDRAWN"
    and stock.sourceOwners.OWNER.byId.DAM~=nil and stock.sourceOwners.OWNER.byId.CHILD.rlGrowth.ageMonths==1)
stock,ctx,id=F.new();stock.sourceUpdateInProgress=true
check("owned progress: concurrent source update cannot acquire the same inventory",not U.advance(stock,{},ctx))
stock,ctx,id=F.new();stock.purchase.records.pending={stage="APPLYING"}
check("owned progress: interrupted purchase owns sources until reconciliation",not U.advance(stock,{},ctx))
stock,ctx,id=F.new({child=true})
local old=stock.sourceOwners.OWNER;writes=0;ctx.persistBarrier=function() writes=writes+1;return true end
assert(U.advance(stock,{},ctx));assert(U.advance(stock,{{hours=0,daysPerMonth=1}},ctx))
check("owned progress: zero elapsed time neither reconstructs owners nor writes a progress barrier",stock.sourceOwners.OWNER==old and writes==0 and stock.farm.clock.months==100)
check("owned progress: invalid zero-duration calendar still rejects",not U.advance(stock,{{hours=0,daysPerMonth=32}},ctx) and writes==0)
stock,ctx,id=F.new({child=true});local split,splitCtx=F.new({child=true})
assert(U.advance(stock,{{hours=24,daysPerMonth=1},{hours=24,daysPerMonth=3},{hours=24,daysPerMonth=7}},ctx))
assert(U.advance(split,{{hours=24,daysPerMonth=1}},splitCtx))
assert(U.advance(split,{{hours=24,daysPerMonth=3},{hours=24,daysPerMonth=7}},splitCtx))
check("owned progress: mixed month lengths match split persisted source and child continuation",T.canonical(encode(stock))==T.canonical(encode(split)))
