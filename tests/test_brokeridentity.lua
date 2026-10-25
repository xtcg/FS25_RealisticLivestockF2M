loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/animal/RLAnimalIdentityRuntime.lua")
local R,I=RLAnimalIdentityRuntime,RLAnimalIdentity
R.reset(true);R.state="READY";R.lineage="Lbroker";R.ledger=assert(I.new(R.lineage))
local owned={farmId="123456",uniqueId="12341",country=2,type="1",where="pen"}
local listing={farmId="654321",uniqueId="12342",country=2,type="1",where="sale"}
local scan={records={owned,listing},counters={},partial={},refs={},herdNext={}}
assert(R.reconcile(scan,{excludeTransient=true}))
check("broker identity: owned live keys enter the common-save ledger",R.ledger.keys[I.keyString(owned.farmId,owned.uniqueId,2)]~=nil)
check("broker identity: transient listings stay outside permanent ledger",R.ledger.keys[I.keyString(listing.farmId,listing.uniqueId,2)]==nil)
check("broker identity: transient live keys still participate in collision checks",R.isTaken(I.keyString(listing.farmId,listing.uniqueId,2)))
for n=1,30 do
    scan.records[2]={farmId="654321",uniqueId=tostring(20000+n),country=2,type="1",where="sale"}
    assert(R.reconcile(scan,{excludeTransient=true}))
end
local count=0;for _ in pairs(R.ledger.keys) do count=count+1 end
check("broker identity: repeated saves cannot accumulate unsold daily stock",count==1)
