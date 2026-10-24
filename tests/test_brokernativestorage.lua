loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/market/RLBrokerPersistence.lua")
loadMod("scripts/market/RLBrokerNativeStorage.lua")
local N,P,T=RLBrokerNativeStorage,RLBrokerPersistence,RLTradePersistence
local function validator(p)
    if type(p)~="table" or p.schemaVersion~=1 or p.kind~="BROKER_TRANSACTIONS" or type(p.sequence)~="number" or type(p.records)~="table"then return false end
    for k in pairs(p)do if k~="schemaVersion" and k~="kind" and k~="sequence" and k~="records"then return false end end
    return true
end
local function payload(sequence)
    return {schemaVersion=1,kind="BROKER_TRANSACTIONS",sequence=sequence,records={old={state="UNKNOWN",monthId="OLD:1",animalKey="1 2 3",memo="中文 <>&\"'\n retained space",resources={"animal:1 2 3","quota:OLD:1"}}}}
end
local function envelope(sequence)
    return {schemaVersion=1,kind="WAL",lineage="L",generation=1,checkpointId="C1",sequence=sequence,payload=payload(sequence)}
end
local canonical=assert(P.encode(envelope(1),validator))
local function formatted(raw)
    return '\239\187\191<?xml version="1.0" encoding="utf-8" standalone="no" ?>\n'..raw
        :gsub('<rlBrokerDocument schema="([^"]+)" length="([^"]+)" digest="([^"]+)">',function(s,l,d)return '<rlBrokerDocument digest="'..d..'"\n length="'..l..'" schema="'..s..'">\n  'end)
        :gsub('<chunk index="([^"]+)" length="([^"]+)" digest="([^"]+)" v="([^"]*)"/>',function(i,l,d,v)return '<chunk v="'..v..'" digest="'..d..'" index="'..i..'" length="'..l..'"></chunk>\n'end)
end
check("native XML: native formatting normalizes to exact portable evidence",N.normalizeNativeXML(formatted(canonical),validator)==canonical)
check("native XML: single quoted attributes preserve the same logical document",N.normalizeNativeXML(canonical:gsub('"',"'"),validator)==canonical)
local corruptions={
    {"extra root attribute",function(v)return v:gsub('<rlBrokerDocument ','<rlBrokerDocument other="1" ',1)end},
    {"extra chunk attribute",function(v)return v:gsub('<chunk ','<chunk other="1" ',1)end},
    {"duplicate root attribute",function(v)return v:gsub('<rlBrokerDocument ','<rlBrokerDocument schema="1" ',1)end},
    {"duplicate chunk attribute",function(v)return v:gsub('<chunk ','<chunk index="0" ',1)end},
    {"unknown sibling",function(v)return v:gsub('</rlBrokerDocument>','<other/></rlBrokerDocument>')end},
    {"unknown nested node",function(v)return v:gsub('/>','><other/></chunk>',1)end},
    {"duplicate chunk",function(v)local c=v:match('(<chunk.-/>)');return v:gsub('</rlBrokerDocument>',function()return c..'</rlBrokerDocument>'end)end},
    {"missing chunk",function(v)return v:gsub('<chunk.-/>','',1)end},
    {"unknown root",function(v)return v:gsub('rlBrokerDocument','other')end},
    {"trailing root",function(v)return v..'<other/>'end},
    {"text content",function(v)return v:gsub('</rlBrokerDocument>','text</rlBrokerDocument>')end},
    {"comment",function(v)return '<!-- hidden -->'..v end},
    {"DTD",function(v)return '<!DOCTYPE rlBrokerDocument []>'..v end},
    {"processing instruction",function(v)return '<?other value="1"?>'..v end},
    {"unknown declaration field",function(v)return '<?xml version="1.0" other="1"?>'..v end},
    {"unknown schema",function(v)return v:gsub('schema="1"','schema="2"',1)end},
    {"bad chunk length",function(v)return v:gsub('<chunk index="0" length="%d+"','<chunk index="0" length="1"',1)end},
    {"bad checksum",function(v)return v:gsub('digest="%x+"','digest="0000000000000000"',1)end},
    {"attribute separator",function(v)return v:gsub('schema="1" length','schema="1"length',1)end},
}
for _,row in ipairs(corruptions)do check("native XML: rejects "..row[1],N.normalizeNativeXML(row[2](canonical),validator)==nil)end
local huge=envelope(1);huge.payload.records.old.memo=string.rep("中文 space\n",4000)
local chunked=assert(P.encode(huge,validator))
check("native XML: chunked Unicode and control payload survives serializer",N.normalizeNativeXML(formatted(chunked),validator)==chunked)
local swapped=chunked:gsub('index="0"','index="999"',1)
check("native XML: out of order chunk rejected",N.normalizeNativeXML(formatted(swapped),validator)==nil)

local function fixture()
    local w={files={},saves=0,creates=0,deletes=0,fault=nil}
    local function fault(name)if w.fault==name then error(name)end end
    local function callback(name)if w.callback then w.callback(name)end end
    local options={validatePayload=validator}
    function options.exists(path)callback("exists");fault("exists");return w.files[path]~=nil end
    function options.load(_,path)
        callback("load");fault("load")
        if w.fault=="load_nil"then return nil end
        if w.files[path]==nil then return nil end
        return {getAsString=function()callback("getAsString");fault("getAsString");return w.files[path]end,
            delete=function()w.deletes=w.deletes+1;callback("delete");fault("delete");if w.fault=="delete_false"then return false end end}
    end
    function options.create(_,path,root)
        callback("create");fault("create");assert(root=="rlBrokerDocument");w.creates=w.creates+1
        if w.fault=="create_nil"then return nil end
        local values={}
        return {setString=function(_,key,value)callback("setString");fault("setString");values[key]=value end,
            save=function()
                callback("save");fault("save");w.saves=w.saves+1
                local parts={'<rlBrokerDocument schema="'..values[root..'#schema']..'" length="'..values[root..'#length']..'" digest="'..values[root..'#digest']..'">'}
                local i=0
                while values[root..'.chunk('..i..')#v']do
                    local prefix=root..'.chunk('..i..')#'
                    parts[#parts+1]='<chunk index="'..values[prefix..'index']..'" length="'..values[prefix..'length']..'" digest="'..values[prefix..'digest']..'" v="'..values[prefix..'v']..'"/>';i=i+1
                end
                parts[#parts+1]='</rlBrokerDocument>'
                if w.failSave==w.saves then return false end
                w.files[path]=formatted(table.concat(parts))
                if w.afterSave then w.afterSave(path,w.saves)end
                return w.fault~="save_false"
            end,
            delete=function()w.deletes=w.deletes+1;callback("delete");fault("delete");if w.fault=="delete_false"then return false end end}
    end
    w.native=assert(N.new(options));w.options=options
    w.storeOptions={path="broker.xml",kind="WAL",lineage="L",generation=1,checkpointId="C1",validatePayload=validator}
    w.store=assert(P.newStore(w.native,w.storeOptions))
    return w
end
local w=fixture();local absent,why=w.native.read("broker.xml")
check("native storage: only explicit missing path is NOT_FOUND",absent==nil and why=="NOT_FOUND")
assert(w.native.write("broker.xml",canonical))
check("native storage: fresh XMLFile native write and actual reload roundtrip",w.native.read("broker.xml")==canonical and w.files['broker.xml']~=canonical and w.creates==1 and w.deletes==2)
w.files['broker.xml']='not XML'
absent,why=w.native.read('broker.xml')
check("native storage: existing invalid document is IO uncertainty not missing",absent==nil and why~="NOT_FOUND")
for _,name in ipairs({"exists","load","load_nil","getAsString","delete","delete_false"})do
    local bad=fixture();bad.files['broker.xml']=formatted(canonical);bad.fault=name
    local value,reason=bad.native.read('broker.xml')
    check("native storage: explicit failed read "..name,value==nil and type(reason)=="string" and reason~="NOT_FOUND")
end
for _,name in ipairs({"create","create_nil","setString","save","save_false","delete","delete_false"})do
    local bad=fixture();bad.fault=name
    local value,reason=bad.native.write('broker.xml',canonical)
    check("native storage: explicit failed write "..name,value==false and type(reason)=="string")
end
w=fixture();local badWrite=canonical:gsub('<rlBrokerDocument ','<rlBrokerDocument extra="1" ',1)
check("native storage: invalid outgoing data never creates a file",not w.native.write('broker.xml',badWrite) and w.creates==0)
w=fixture();assert(w.store.write(payload(1)))
check("native store: three barriers tolerate real serializer formatting",w.saves==3 and w.store.read().records.old.memo==payload(1).records.old.memo)
check("native store: same-sequence exact retry avoids native rewrite",w.store.write(payload(1)) and w.saves==3)
local changed=payload(1);changed.records.old.memo='different'
check("native store: same-sequence different document rejected",not w.store.write(changed) and w.saves==3)
for stage=1,3 do
    local bad=fixture();assert(bad.store.write(payload(1)));local old=bad.files['broker.xml'];bad.failSave=bad.saves+stage
    local accepted=bad.store.write(payload(2))
    check("native store: failed write barrier "..stage.." closes delivery",not accepted and bad.store.status().state=='RECOVERY_REQUIRED' and (stage~=1 or bad.files['broker.xml']==old))
    local reloaded=assert(P.newStore(bad.native,bad.storeOptions));local current=reloaded.read()
    check("native store: failed barrier "..stage.." retains coherent old or blocks mixed slots",stage==1 and current~=nil and current.sequence==1 or stage~=1 and current==nil)
end
w=fixture();assert(w.store.write(payload(1)));assert(w.store.write(payload(2)))
check("native store: completed staging reload preserves previous evidence",assert(P.newStore(w.native,w.storeOptions)).read().sequence==2 and assert(P.decode(assert(w.native.read('broker.xml.staging')))).payload.previous==assert(P.encode(envelope(1),validator)))
w=fixture();assert(w.store.write(payload(1)));w.afterSave=function(path)if path=='broker.xml.staging'then w.files[path]=w.files[path]:gsub('</rlBrokerDocument>','<extra/></rlBrokerDocument>')end end
check("native store: reread detects additional persisted XML nodes",not w.store.write(payload(2)) and w.store.status().state=='RECOVERY_REQUIRED')
w=fixture();w.files['broker.xml']=formatted(canonical);w.fault='delete'
local deleted,deleteReason=w.native.read('broker.xml')
check("native storage: cleanup failure explicitly overrides successful read",deleted==nil and deleteReason=='NATIVE_XML_DELETE_UNCERTAIN')
w=fixture();local callbacks,rejected=0,0
w.callback=function()
    callbacks=callbacks+1
    local value,reason=w.native.read('elsewhere.xml');local written,writeReason=w.native.write('elsewhere.xml',canonical)
    if value==nil and reason=='BROKER_NATIVE_STORAGE_BUSY' and written==false and writeReason=='BROKER_NATIVE_STORAGE_BUSY'then rejected=rejected+1 end
end
check("native storage: all callbacks including cleanup refuse reentry",w.store.write(payload(1)) and callbacks>0 and callbacks==rejected and w.files['elsewhere.xml']==nil)
for stage=1,3 do
    for _,faultName in ipairs({"load","getAsString","delete"})do
        local bad=fixture();assert(bad.store.write(payload(1)));local at=bad.saves+stage
        bad.afterSave=function(_,count)if count==at then bad.fault=faultName end end
        check("native store: barrier "..stage.." "..faultName.." uncertainty preserves recovery",not bad.store.write(payload(2)) and bad.store.status().state=='RECOVERY_REQUIRED' and bad.store.status().evidence~=nil)
    end
end
w=fixture();assert(w.store.write(payload(1)));local oldMain=w.files['broker.xml'];w.fault='save_false'
check("native store: false save after actual disk change never authorizes write",not w.store.write(payload(2)) and w.files['broker.xml']==oldMain)
w.fault=nil
check("native store: actually written STAGED despite false save blocks reload",assert(P.newStore(w.native,w.storeOptions)).read()==nil)
w=fixture();assert(w.store.write(payload(1)))
local future={path='broker.xml',kind='WAL',lineage='L',generation=2,checkpointId='C2',validatePayload=validator}
check("native store: normalized valid XML still cannot cross save generation",assert(P.newStore(w.native,future)).read()==nil)

-- Exercise default dependency lookup using the actual XMLFile API signatures;
-- no runtime hook or filesystem is needed to select the native defaults.
local savedXML,savedExists=XMLFile,fileExists
w=fixture();local names={}
XMLFile={create=function(objectName,path,root)names.create=objectName;return w.options.create(objectName,path,root)end,
    loadIfExists=function(objectName,path)names.load=objectName;return w.options.load(objectName,path)end}
fileExists=w.options.exists
local defaults=assert(N.new({validatePayload=validator}))
check("native storage: default XMLFile.create/loadIfExists and fileExists compose",defaults.write('default.xml',canonical) and defaults.read('default.xml')==canonical and names.create=='rlBrokerNativeWrite' and names.load=='rlBrokerNativeRead')
XMLFile,fileExists=savedXML,savedExists
check("native storage: invalid factory options rejected without side effects",N.new(false)==nil and N.new(1)==nil and N.new('invalid')==nil)
local noXML,noExists=XMLFile,fileExists;XMLFile,fileExists=nil,nil
check("native storage: absent native dependencies reject nil/default options",N.new(nil)==nil and N.new({})==nil)
XMLFile,fileExists=noXML,noExists
