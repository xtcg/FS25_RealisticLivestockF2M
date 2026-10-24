loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/animal/RLTradeSourceAdapter.lua")
loadMod("scripts/dealer/RLDealerTargetAdapter.lua")
RLAnimalUtil={toKey=function(farm,id,country) return tostring(farm) .. "|" .. tostring(id) .. "|" .. tostring(country) end}
local A=RLDealerTargetAdapter
local function animal(id,weight)
    return {farmId=1,uniqueId=id,birthday={country="GB",day=1},isIndividual=true,weight=weight or 100,
        rlGrowth={weightKg=weight or 100,reserveMassKg=10,developmentMonths=8,feedAdapted=0.8},
        getNumAnimals=function() return 1 end,setClusterSystem=function(self,c) self.clusterSystem=c end}
end
-- Queue/flush stand-in follows the real direct-animal updateClusters branch;
-- refusal/partial effects and listener callbacks are explicit fault injection.
local function fixture(kind)
    local c={animals={},clustersToAdd={},clustersToRemove={},flushes=0,fault=nil}
    local d={isServer=true,getClusterSystem=function() return c end,getOwnerFarmId=function() return 1 end}
    if kind=="TRAILER" then d.spec_livestockTrailer={} else d.spec_husbandryAnimals={} end
    c.owner=d
    function c:getClusters() if self.fault=="UNREADABLE" then error("unreadable") end;return self.animals end
    function c:addPendingAddCluster(a)
        if self.fault=="REFUSE" then return end
        self.clustersToAdd[a]=true
        if self.onAdd then self.onAdd(a) end
    end
    function c:addPendingRemoveCluster(a)
        if self.fault=="REMOVE_REFUSE" then return end
        self.clustersToRemove[a]=true
        if self.onRemove then self.onRemove(a) end
    end
    function c:updateNow()
        self.flushes=self.flushes+1
        local count=0
        for a,value in pairs(self.clustersToAdd) do
            if value then
                count=count+1
                if self.fault~="SILENT" and (self.fault~="PARTIAL" or count==1) then self.animals[#self.animals+1]=a;a:setClusterSystem(self) end
                if self.fault=="THROW_PARTIAL" then self.clustersToAdd={};error("partial add") end
            end
        end
        for i=#self.animals,1,-1 do
            local a=self.animals[i]
            if self.clustersToRemove[a]~=nil then table.remove(self.animals,i);a:setClusterSystem(nil) end
        end
        self.clustersToAdd={};self.clustersToRemove={}
        if self.afterFlush then self.afterFlush() end
    end
    local existing=animal("existing",200);existing.clusterSystem=c;c.animals={existing}
    local batch={animal("one",101),animal("two",102)}
    return d,c,batch,existing
end
for _,kind in ipairs({"PEN","TRAILER"}) do
    local d,c,batch,other=fixture(kind)
    local b=assert(A.bind(d,batch));local initial=other.weight
    local ok,o=A.apply(b)
    check("dealer target: " .. kind .. " directly queues real objects and observes exact physiology", ok and c.flushes==1 and #o.added==2 and batch[1].clusterSystem==c and batch[1].rlGrowth.weightKg==101 and other.weight==initial)
    check("dealer target: " .. kind .. " repeated apply cannot duplicate animals", not A.apply(b) and #c.animals==3)
    check("dealer target: " .. kind .. " rollback removes only batch and preserves existing object state", A.rollback(b)==true and #c.animals==1 and c.animals[1]==other and other.weight==initial and A.verifyRestored(b))
    check("dealer target: " .. kind .. " rollback is idempotent without an extra flush", A.rollback(b)==true and c.flushes==2)
end
local d,c,batch,other=fixture();d.isServer=false
check("dealer target: clients cannot bind authoritative destination", not A.bind(d,batch))
d,c,batch=fixture();batch[1].isIndividual=false
check("dealer target: non-individual payload cannot masquerade as one animal", not A.bind(d,batch))
d,c,batch=fixture();c.clustersToAdd[{}]=false
check("dealer target: even false foreign pending queue refuses bind", not A.bind(d,batch))
d,c,batch=fixture();batch[2].uniqueId=batch[1].uniqueId
check("dealer target: duplicate complete batch identities reject", not A.bind(d,batch))
d,c,batch=fixture();batch[1].uniqueId="existing"
check("dealer target: existing same identity different object refuses bind", not A.bind(d,batch))
d,c,batch=fixture();batch[1].birthday.country=nil
check("dealer target: incomplete birth-country identity refuses bind", not A.bind(d,batch))
d,c,batch=fixture();batch[1].clusterSystem={}
check("dealer target: already-owned prepared batch refuses bind", not A.bind(d,batch))
d,c,batch=fixture();local b=assert(A.bind(d,batch));c.fault="SILENT"
local ok,why,o=A.apply(b)
check("dealer target: silent successful engine calls cannot claim target ownership", not ok and o.known and #o.added==0 and c.flushes==1)
c.fault=nil
check("dealer target: silently refused add rolls back without touching unrelated members", A.rollback(b)==true and #c.animals==1)
d,c,batch,other=fixture();b=assert(A.bind(d,batch));c.fault="PARTIAL"
ok,why,o=A.apply(b)
check("dealer target: partial flush is observed as incomplete batch", not ok and o.known and #o.added==1 and #o.missing==1)
c.fault=nil
check("dealer target: partial target effects compensate exactly added own object", A.rollback(b)==true and c.animals[1]==other and #c.animals==1 and A.verifyRestored(b))
d,c,batch=fixture();b=assert(A.bind(d,batch));c.fault="THROW_PARTIAL"
ok,why,o=A.apply(b)
check("dealer target: throwing partial flush returns actual member observation", not ok and o.known and #o.added==1)
c.fault=nil;assert(A.rollback(b))
d,c,batch=fixture();b=assert(A.bind(d,batch));c.fault="REFUSE"
check("dealer target: add queue refusal cannot be flushed or treated as added", not A.apply(b) and c.flushes==0 and A.rollback(b))
d,c,batch,other=fixture();b=assert(A.bind(d,batch));local foreign=animal("foreign")
c.onAdd=function() c.clustersToAdd[foreign]=true end
check("dealer target: enqueue listener foreign add prevents unsafe flush", not A.apply(b) and c.flushes==0 and c.clustersToAdd[foreign]==true)
local before=#c.animals
check("dealer target: rollback refuses foreign queued ownership and clears none", not A.rollback(b) and c.clustersToAdd[foreign]==true and #c.animals==before)
d,c,batch,other=fixture();b=assert(A.bind(d,batch));c.onAdd=function() other.weight=999 end
check("dealer target: listener changes to unrelated business state refuse before flush", not A.apply(b) and c.flushes==0 and not A.rollback(b) and other.weight==999)
d,c,batch=fixture();b=assert(A.bind(d,batch));c.onAdd=function(a) a.weight=999 end
check("dealer target: prepared state mutation during queue callback fails before flush", not A.apply(b) and c.flushes==0)
d,c,batch,other=fixture();b=assert(A.bind(d,batch));assert(A.apply(b))
local impostor=animal(batch[1].uniqueId,101);impostor.clusterSystem=c
for i,a in ipairs(c.animals) do if a==batch[1] then c.animals[i]=impostor end end
check("dealer target: rollback never deletes foreign object with identical business ID", not A.rollback(b) and c.animals[2]~=nil and impostor.clusterSystem==c)
d,c,batch=fixture();b=assert(A.bind(d,batch));assert(A.apply(b));c.fault="REMOVE_REFUSE"
check("dealer target: refused remove queue keeps compensation unresolved", not A.rollback(b) and not A.verifyRestored(b))
d,c,batch=fixture();b=assert(A.bind(d,batch));assert(A.apply(b));local f=animal("foreign-remove")
c.onRemove=function() c.clustersToRemove[f]=true end
local flushes=c.flushes
check("dealer target: rollback enqueue callback cannot flush unknown foreign removal", not A.rollback(b) and c.flushes==flushes and c.clustersToRemove[f]==true)
d,c,batch=fixture();b=assert(A.bind(d,batch));assert(A.apply(b));c.fault="UNREADABLE"
check("dealer target: unreadable members are unknown and never assumed removed", not A.observe(b).known and not A.rollback(b))
d,c,batch=fixture();b=assert(A.bind(d,batch));local evidence=A.exportBinding(b);assert(A.apply(b))
local loaded={}
for i,a in ipairs(c.animals) do
    local copy=animal(a.uniqueId,a.weight);copy.clusterSystem=c;loaded[i]=copy
end
c.animals=loaded
local rebound=assert(A.rebind(d,evidence,{d}))
check("dealer target: reload rebind resolves actual new objects by full stable identity", rebound.entries[1].animal~=batch[1] and A.observe(rebound).known and #A.observe(rebound).added==2)
check("dealer target: rebound compensation removes only reloaded batch", A.rollback(rebound)==true and #c.animals==1 and A.verifyRestored(rebound))
local otherD,otherC=fixture("TRAILER");otherC.animals[1].uniqueId="existing"
check("dealer target: pure scan detects duplicate identities across pen and trailer", not A.scanOwners({d,otherD}))
otherC.animals[1].uniqueId="different"
check("dealer target: reload requires destination included in complete-world scan", not A.rebind(d,evidence,{otherD}))
local conflict=animal("one",101);conflict.clusterSystem=otherC;otherC.animals[#otherC.animals+1]=conflict
check("dealer target: missing target batch found in another owner cannot be rebound as absent", not A.rebind(d,evidence,{d,otherD}))

d,c,batch=fixture();batch[1].farmId="654321";batch[2].farmId="987654"
b=assert(A.bind(d,batch));local beforeIdentity=A.identityKey(batch[1]);assert(A.apply(b))
check("dealer target: source business herd identity differs from destination player farm index without remapping", b.ownerFarmId==1 and batch[1].farmId=="654321" and A.identityKey(batch[1])==beforeIdentity)
assert(A.rollback(b))
local malformed=A.exportBinding(b);malformed.entries[1].snapshot.self=malformed.entries[1].snapshot
check("dealer target: cyclic saved rebind evidence rejects before copying or touching target", not A.rebind(d,malformed,{d}) and #c.animals==1)

d,c,batch=fixture();local foreignD,foreignC=fixture("TRAILER");foreignC.animals[1].uniqueId="different"
b=assert(A.bind(d,batch,{d,foreignD}));assert(A.apply(b))
local cloneIdentity=animal("one",101);cloneIdentity.clusterSystem=foreignC;foreignC.animals[#foreignC.animals+1]=cloneIdentity
check("dealer target: world-scoped binding catches listener duplicate identity before target compensation", not A.observe(b).known and not A.rollback(b) and cloneIdentity.clusterSystem==foreignC)
d,c,batch=fixture();b=assert(A.bind(d,batch));assert(A.apply(b))
c.afterFlush=function() batch[1].clusterSystem={} end
check("dealer target: target absence cannot prove compensation if original object acquired another owner", not A.rollback(b) and not A.verifyRestored(b))

-- r6 game test: every animal in a pen has a 3D visual that links back to it (Animal:createVisual), so
-- binding an occupied pen failed (TARGET_STATE_UNREADABLE) and the visual the flush gave a new animal
-- read as a changed field (TARGET_FIELDS_OR_MEMBERS_CHANGED). The visual is the pen's, not the animal's.
do
    -- as AnimalClusterHusbandry:updateVisuals: visual slot index, a texture variation when the animal has none, visual
    local function giveVisual(a) local v={husbandryId=7,nodeId=12345};v.animal=a;a.visualAnimal=v;a.visualAnimalIndex=4;a.variation=a.variation or 2 end
    local d,c,batch,other=fixture()
    giveVisual(other)
    local b,why=A.bind(d,batch)
    check("dealer target: an occupied pen whose animals have 3D visuals binds", b~=nil, why)
    c.afterFlush=function() for _,a in ipairs(c.animals) do if a.visualAnimal==nil then giveVisual(a) end end end
    local ok,o=A.apply(b or {})
    check("dealer target: visuals the pen gives the new animals are not a field change", ok and #o.added==2 and batch[1].visualAnimal~=nil)
    check("dealer target: rollback after visuals still restores the pen", A.rollback(b)==true and #c.animals==1 and c.animals[1]==other)
    d,c,batch,other=fixture();giveVisual(other);b=assert(A.bind(d,batch))
    c.onAdd=function() other.weight=999 end
    check("dealer target: business state of a visual animal is still guarded", not A.apply(b) and c.flushes==0)
    -- r7 game test: the pen re-laid out the visual slots of the animals already in it on the same flush
    d,c,batch,other=fixture();giveVisual(other);b=assert(A.bind(d,batch))
    c.afterFlush=function() for _,a in ipairs(c.animals) do giveVisual(a);a.visualAnimalIndex=a==other and 9 or 5 end end
    ok,o=A.apply(b)
    check("dealer target: visual slot index the flush moves is not a field change", ok and o.othersIntact and o.fieldsIntact, ok==nil and o or nil)
    d,c,batch,other=fixture();giveVisual(other);b=assert(A.bind(d,batch))
    c.afterFlush=function() other.variation=other.variation+1 end
    ok,o=A.apply(b)
    check("dealer target: a texture the animal already had is still guarded", not ok)
    -- evidence written by r7 still carries visualAnimalIndex in the snapshots; a rebind must not read it as a change
    d,c,batch,other=fixture();giveVisual(other);b=assert(A.bind(d,batch))
    c.afterFlush=function() for _,a in ipairs(c.animals) do giveVisual(a) end end
    assert(A.apply(b))
    local evidence=A.exportBinding(b)
    for _,section in ipairs({"entries","others"}) do for _,e in ipairs(evidence[section]) do e.snapshot.visualAnimalIndex=3 end end
    for _,a in ipairs(c.animals) do a.visualAnimalIndex=6 end
    local rb,rwhy=A.rebind(d,evidence,{d})
    check("dealer target: rebind ignores visual slot index saved by an older build", rb~=nil, rwhy)
end
