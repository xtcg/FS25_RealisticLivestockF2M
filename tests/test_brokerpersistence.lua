loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/market/RLBrokerPersistence.lua")
local P,T=RLBrokerPersistence,RLTradePersistence
local function clone(v)return assert(T.parse(T.canonical(v),P.LIMITS))end
local function validator(d)
    if d.schemaVersion~=1 or d.kind~="BROKER_TRANSACTIONS" or type(d.sequence)~="number" or type(d.records)~="table" then return false end
    for key in pairs(d)do if key~="schemaVersion" and key~="kind" and key~="sequence" and key~="records"then return false end end
    return true
end
local function payload(sequence)return {schemaVersion=1,kind="BROKER_TRANSACTIONS",sequence=sequence,records={r1={state="UNKNOWN",monthId="OLD:1",resources={"animal:1 2 3","quota:OLD:1"}}}}end
local function envelope(sequence)return {schemaVersion=1,kind="WAL",lineage="L-save",generation=7,checkpointId="checkpoint:7",sequence=sequence,payload=payload(sequence)}end
local xml=assert(P.encode(envelope(1),validator))
check("broker persistence: canonical XML roundtrip preserves full old-month evidence",T.canonical(P.decode(xml,validator))==T.canonical(envelope(1)))
check("broker persistence: unknown envelope schema rejected",P.decode(xml:gsub('schema="1"','schema="2"',1),validator)==nil)
check("broker persistence: extra XML attribute rejected",P.decode(xml:gsub('<rlBrokerDocument ','<rlBrokerDocument extra="x" ',1),validator)==nil)
check("broker persistence: trailing XML rejected",P.decode(xml.."x",validator)==nil)
check("broker persistence: bad chunk length rejected",P.decode(xml:gsub('<chunk index="0" length="%d+"','<chunk index="0" length="1"',1),validator)==nil)
check("broker persistence: bad chunk digest rejected",P.decode(xml:gsub('digest="%x+"','digest="0000000000000000"',2),validator)==nil)
local bad=envelope(1);bad.extra=true
check("broker persistence: extra envelope field rejected",P.encode(bad,validator)==nil)
bad=envelope(1);bad.payload.extra=true
check("broker persistence: extra payload field delegated to strict validator",P.encode(bad,validator)==nil)
bad=envelope(1);bad.sequence=2
check("broker persistence: envelope sequence must bind payload",P.encode(bad,validator)==nil)
bad=envelope(1);bad.payload.records.r1.amount=math.huge
check("broker persistence: nonfinite never sanitized",P.encode(bad,validator)==nil)
bad=envelope(1);bad.payload.records.r1.deep={};bad.payload.records.r1.deep.self=bad.payload.records.r1.deep
check("broker persistence: cyclic payload rejected",P.encode(bad,validator)==nil)
local huge=envelope(1);huge.payload.records.r1.bytes=string.rep("中文<&\"",10000)
local chunked=assert(P.encode(huge,validator))
check("broker persistence: long Unicode full payload survives chunks",T.canonical(assert(P.decode(chunked,validator)))==T.canonical(huge))
local function fixture()
    local w={files={},writes=0,fault=nil}
    local storage={}
    function storage.read(path)
        if w.onRead then w.onRead(path)end
        local value=w.files[path]
        if value==nil then return nil,"NOT_FOUND"end
        if w.fault=="MUTATED_READ" and w.writes>=5 and path=="broker.xml"then return value.."x"end
        return value
    end
    function storage.write(path,value)
        w.writes=w.writes+1
        if w.onWrite then w.onWrite(path,value)end
        if w.fault=="WRITE_FALSE"then w.files[path]=value;return false end
        if w.fault=="MAIN_FALSE" and path=="broker.xml"then w.files[path]=value;return false end
        if w.fault=="COMPLETE_FALSE" and w.writes%3==0 then return false end
        w.files[path]=value;return true
    end
    w.storage=storage
    w.options={path="broker.xml",kind="WAL",lineage="L-save",generation=7,checkpointId="checkpoint:7",validatePayload=validator}
    w.store=assert(P.newStore(storage,w.options));return w
end
local w=fixture()
local empty,reason=w.store.read()
check("broker persistence: empty store is distinct from IO uncertainty",empty==nil and reason=="NOT_FOUND")
check("broker persistence: first write has all three synchronous barriers",w.store.write(payload(1)) and w.writes==3)
check("broker persistence: exact durable read returns whole payload",T.canonical(w.store.read())==T.canonical(payload(1)))
check("broker persistence: exact same sequence retry does not rewrite",w.store.write(payload(1)) and w.writes==3)
local changed=payload(1);changed.records.r1.name="changed"
check("broker persistence: same sequence changed payload rejected",not w.store.write(changed))
w=fixture();assert(w.store.write(payload(1)));local original=w.files["broker.xml"]
w.fault="WRITE_FALSE"
check("broker persistence: failed staging write does not overwrite main",not w.store.write(payload(2)) and w.files["broker.xml"]==original)
local reload=assert(P.newStore(w.storage,w.options));w.fault=nil
check("broker persistence: staging residual blocks load instead of choosing old or new",reload.read()==nil and reload.status().state=="RECOVERY_REQUIRED")
local staged=assert(P.decode(w.files["broker.xml.staging"]))
check("broker persistence: failed stage retains full previous and proposed evidence",staged.payload.previous==original and staged.payload.proposed~=original)
for _,fault in ipairs({"MAIN_FALSE","COMPLETE_FALSE","MUTATED_READ"})do
    local broken=fixture();assert(broken.store.write(payload(1)));broken.fault=fault
    check("broker persistence: uncertain "..fault.." blocks transaction",not broken.store.write(payload(2)) and broken.store.status().state=="RECOVERY_REQUIRED")
    local fresh=assert(P.newStore(broken.storage,broken.options));broken.fault=nil
    check("broker persistence: mixed slots "..fault.." cannot silently promote",fresh.read()==nil)
end
w=fixture();assert(w.store.write(payload(1)));assert(w.store.write(payload(2)))
local fresh=assert(P.newStore(w.storage,w.options))
check("broker persistence: completed slots reload exact latest sequence",fresh.read().sequence==2)
local wrong={};for k,v in pairs(w.options)do wrong[k]=v end;wrong.generation=8
check("broker persistence: future or mixed generation rejects despite valid XML",assert(P.newStore(w.storage,wrong)).read()==nil)
w=fixture();local inner,innerWhy,insideRead
w.onWrite=function()
    inner,innerWhy=w.store.write(payload(2));insideRead=w.store.read()
end
check("broker persistence: synchronous storage callback cannot reenter write",w.store.write(payload(1)) and inner==false and innerWhy=="BROKER_STORE_BUSY" and insideRead==nil and w.store.read().sequence==1)
w.onWrite=nil
local oldChecksum=T.checksum;T.checksum=function()return "0000000000000000"end
local collision=fixture();assert(collision.store.write(payload(1)))
changed=payload(1);changed.records.r1.name="different payload"
check("broker persistence: checksum collision never grants exact retry",not collision.store.write(changed))
T.checksum=oldChecksum
