loadMod("tests/brokerdemandfixture.lua")
loadMod("scripts/animal/RLTradePersistence.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/animal/RLAnimalIdentityPersistence.lua")
local utilFile=assert(io.open(REPO..'scripts/utils/RLAnimalUtil.lua','r'));local utilSource=utilFile:read('*a');utilFile:close()
assert(load((utilSource:gsub('::number','')),'real identity formatter'))()
for _,name in ipairs({"RLMarketResourceLock","RLBrokerQuota","RLBrokerTransaction","RLAnimalAcquisition","RLBrokerPersistence","RLBrokerNativeStorage","RLMarketCheckpoint","RLMarketSaveAdapter"})do loadMod("scripts/market/"..name..".lua")end
local A,C,D,T=RLMarketSaveAdapter,RLMarketCheckpoint,RLMarketData,RLTradePersistence
local function cp(v)return assert(D.copy(v))end
local seed='adapter-seed'
local catalog=BrokerDemandFixture.catalog();catalog.entries={catalog.entries[1]}
local month=assert(RLBrokerDemand.generate(seed,10,'g1',BrokerDemandFixture.balance(),catalog))
local history={schemaVersion=1,kind='BROKER_MONTH_HISTORY',seedFingerprint=D.fingerprint(seed),currentAbsoluteMonth=10,months={['10']=month}}
history.revision=assert(D.fingerprint(history))
local function serialize(doc)
    local out={'<?xml version="1.0" encoding="utf-8"?>\n'}
    local function element(name,key)
        out[#out+1]='<'..name
        local attrs={};for attr in pairs(doc.nodes[key]or{})do attrs[#attrs+1]=attr end;table.sort(attrs)
        for _,attr in ipairs(attrs)do out[#out+1]=' '..attr..'="'..doc.nodes[key][attr]..'"'end
        local children=doc.children[key]or{}
        if #children==0 then out[#out+1]='/>';return end
        out[#out+1]='>\n'
        for _,child in ipairs(children)do element(child.name,child.key);out[#out+1]='\n'end
        out[#out+1]='</'..name..'>'
    end
    element(doc.root,doc.root);return table.concat(out)
end
local function fixture()
    local w={files={},deletes=0,saves=0,removeSaves=0,freezes=0,releases=0}
    local function callbacks(name)if w.callback then w.callback(name)end;if w.fault==name then error(name)end end
    local function handle(path,doc)
        local x={doc=cp(doc)}
        function x:getString(key)callbacks('getString');local node,attr=key:match('^(.-)#(.+)$');return (self.doc.nodes[node]or{})[attr]end
        function x:setString(key,value)
            callbacks('setString');local node,attr=key:match('^(.-)#(.+)$')
            if not self.doc.nodes[node]then
                self.doc.nodes[node]={};local parent,name,index=node:match('^(.-)%.([^%.%(]+)%((%d+)%)$')
                if parent==nil then parent,name=node:match('^(.-)%.([^%.]+)$');index='0'end
                assert(parent and name)
                self.doc.children[parent]=self.doc.children[parent]or{}
                self.doc.children[parent][tonumber(index)+1]={name=name,key=node}
            end
            self.doc.nodes[node][attr]=value
        end
        function x:getAsString()callbacks('getAsString');return serialize(self.doc)end
        function x:getNumOfChildren(root)return #(self.doc.children[root]or{})end
        function x:getElementName(key)local root,i=key:match('^(.-)%.%*%((%d+)%)$');return self.doc.children[root][tonumber(i)+1].name end
        function x:iterate(path,fn)
            local root,name=path:match('^(.-)%.([^%.]+)$')
            for i,child in ipairs(self.doc.children[root]or{})do if child.name==name then fn(i,child.key)end end
        end
        function x:removeProperty(key)
            callbacks('removeProperty');if w.fault=='removeNoop'then return end
            local node,attr=key:match('^(.-)#(.+)$');self.doc.nodes[node][attr]=nil;self.removed=true
        end
        function x:save()
            callbacks('save');w.saves=w.saves+1;if self.removed then w.removeSaves=w.removeSaves+1 end
            w.files[path]=cp(self.doc);return w.fault~='saveFalse'
        end
        function x:delete()callbacks('delete');w.deletes=w.deletes+1 end
        return x
    end
    w.io={exists=function(path)callbacks('exists');return w.files[path]~=nil end,
        load=function(_,path)callbacks('load');if w.files[path]then return handle(path,w.files[path])end end,
        create=function(_,path,root)callbacks('create');return handle(path,{root=root,nodes={[root]={}},children={}})end}
    w.options={directory='test-save',lineage='Lmarket',monthSeedFingerprint=D.fingerprint(seed),allowTestCatalog=true,io=w.io,
        attributeNames=function(xml,root)local list={};for name in pairs(xml.doc.nodes[root])do list[#list+1]=name end;return list end,
        inspectAnimals=function(xml,role)
            callbacks('inspectAnimals');local list={}
            for _,child in ipairs(xml.doc.children[role]or{})do if child.name=='animal'then list[#list+1]=assert(xml:getString(child.key..'#identityKey'))end end
            return list
        end}
    w.scope={lineage='Lmarket',generation=1,checkpointId='save-cp1',sharedSaveId='engine-save1',sequence=0}
    w.payloads={identity=assert(RLAnimalIdentity.export(assert(RLAnimalIdentity.new('Lidentity')))),
        acquisition=RLAnimalAcquisition.new():export(),broker={schemaVersion=1,kind='BROKER_TRANSACTIONS',serverEpoch='e1',sequence=0,records={},quota=RLBrokerQuota.new():export()},months=cp(history)}
    local identityLedger=assert(RLAnimalIdentity.import(w.payloads.identity));identityLedger.generation=100;w.payloads.identity=assert(RLAnimalIdentity.export(identityLedger))
    for _,role in ipairs({'placeables','vehicles','farms'})do
        local root=role;local doc={root=root,nodes={[root]={native='preserved'}},children={}}
        if role~='farms'then
            local key=role..'.animal(0)';doc.children[role]={{name='animal',key=key}}
            doc.nodes[key]={identityKey=role=='placeables'and'1 101 1'or'1 102 1',pregnancy='full-native-saved-state'}
        end
        w.files['test-save/'..role..'.xml']=doc
    end
    w.files['test-save/careerSavegame.xml']={root='careerSavegame',nodes={careerSavegame={native='career-data'}},children={}}
    w.adapter=assert(A.new(w.options))
    local hooks={};for _,name in ipairs({'transactions','sources','identity'})do hooks[name]={freeze=function()w.freezes=w.freezes+1;return true end,release=function()w.releases=w.releases+1;return true end}end
    w.checkpoint=assert(C.new(w.adapter.storage,w.adapter.contracts,hooks));w.hooks=hooks
    function w.start()
        assert(w.adapter.begin(w.scope));assert(w.checkpoint.begin(w.scope.sharedSaveId,{lineage=w.scope.lineage,generation=w.scope.generation,checkpointId=w.scope.checkpointId,sequence=w.scope.sequence}))
        for _,role in ipairs({'placeables','vehicles','farms'})do
            local path='test-save/'..role..'.xml';local xml=assert(w.io.load('save',path))
            xml:setString(role..'#'..A.IDENTITY_MARKER,w.payloads.identity.lineage..':'..w.payloads.identity.generation)
            assert(w.adapter.markNative(w.scope.sharedSaveId,role,xml));assert(xml:save());xml:delete()
            assert(w.checkpoint.markParticipant(w.scope.sharedSaveId,role))
        end
        assert(w.checkpoint.markParticipant(w.scope.sharedSaveId,'animals'))
        local identityXML=assert(w.io.create('identity-owner','test-save/'..RLAnimalIdentityPersistence.FILENAME,RLAnimalIdentityPersistence.ROOT))
        local systemXML=assert(w.io.create('identity-system','test-save/rm_RlAnimalSystem.xml','rm_RlAnimalSystem'))
        systemXML:setString('rm_RlAnimalSystem#'..A.IDENTITY_MARKER,w.payloads.identity.lineage..':'..w.payloads.identity.generation)
        systemXML:setString('rm_RlAnimalSystem#counters','complete-actual-saved-counter-data')
        assert(w.adapter.markIdentitySystem(w.scope.sharedSaveId,systemXML));assert(systemXML:save());systemXML:delete()
        local ownerData={schema=RLAnimalIdentityPersistence.SCHEMA,lineage=w.payloads.identity.lineage,generation=w.payloads.identity.generation,mode='ON',ledger=w.payloads.identity,participants={placeables=true,vehicles=true,farms=true,animalSystem=true}}
        if w.changeOwner then w.changeOwner(ownerData)end
        assert(RLAnimalIdentityPersistence.writeLedger(identityXML,ownerData))
        assert(w.adapter.markIdentityOwner(w.scope.sharedSaveId,identityXML));assert(identityXML:save());identityXML:delete()
        w.files['test-save/careerSavegame.xml'].nodes.careerSavegame[A.IDENTITY_MARKER]=w.payloads.identity.lineage..':'..w.payloads.identity.generation
        for _,role in ipairs({'identity','acquisition','broker','months'})do assert(w.adapter.writePayload(w.scope.sharedSaveId,role,w.payloads[role]));assert(w.checkpoint.markParticipant(w.scope.sharedSaveId,role))end
    end
    return w
end
local w=fixture()
check('save adapter: construction creates no files or active services',w.saves==0 and w.adapter.allowEngineSave and w.checkpoint.status().state=='DORMANT')
w.start();local proof=assert(w.checkpoint.finish(w.scope.sharedSaveId))
check('save adapter: actual native handles plus real payload validators complete proof',w.checkpoint.status().allowNewTransactions and proof.references.acquisition.schemaVersion==2 and proof.references.broker.payloadDigest~=nil)
check('save adapter: animal role is logical manifest of both real files',w.adapter.contracts.participants.animals.path==A.ANIMALS_PATH and w.files['test-save/animals.xml']==nil and proof.participants.animals.length>0)
check('save adapter: career body removal never saved to disk',w.removeSaves==0 and w.files['test-save/careerSavegame.xml'].nodes.careerSavegame[A.CAREER_MARKER]~=nil)
check('save adapter: native unrelated saved content retained',w.files['test-save/careerSavegame.xml'].nodes.careerSavegame.native=='career-data' and w.files['test-save/placeables.xml'].nodes['placeables.animal(0)'].pregnancy=='full-native-saved-state')
local restored=assert(w.checkpoint.brokerRestoreProof(w.payloads.broker,proof))
check('save adapter: common proof binds complete actual broker payload',restored.documentFingerprint==D.fingerprint(w.payloads.broker))
local reload=assert(A.new(w.options));local loaded=assert(C.new(reload.storage,reload.contracts,w.hooks)).load()
check('save adapter: fresh adapter rereads same native files and both portable slots',loaded~=nil and D.fingerprint(loaded)==D.fingerprint(proof))
assert(w.adapter.endScope(w.scope.sharedSaveId));w.scope.generation=2;w.scope.checkpointId='save-cp2';w.scope.sharedSaveId='engine-save2';w.start()
local second=assert(w.checkpoint.finish(w.scope.sharedSaveId))
check('save adapter: archive streams advance generation without confusing engine cohort',second.generation==2 and second.sharedSaveId=='engine-save2' and second.sequence==0)

local unsupported=fixture();unsupported.options.inspectAnimals=nil
check('save adapter: absent real native animal inspector is explicitly unsupported',A.new(unsupported.options)==nil)
w=fixture();w.options.inspectAnimals=function()return {payloadValidated=true}end;w.adapter=assert(A.new(w.options));w.checkpoint=assert(C.new(w.adapter.storage,w.adapter.contracts,w.hooks));w.start()
check('save adapter: payloadValidated bool cannot prove native animals',w.checkpoint.finish(w.scope.sharedSaveId)==nil and not w.checkpoint.status().allowNewTransactions)
for _,role in ipairs({'placeables','vehicles','farms'})do
    local bad=fixture();bad.start()
    local key=role..'#'..A.NATIVE_MARKER;local xml=assert(bad.io.load('edit','test-save/'..role..'.xml'))
    local marker=assert(T.parse(assert(T.decodeText(xml:getString(key)))));marker.sharedSaveId='another-save'
    xml:setString(key,T.encodeText(T.canonical(marker)));assert(xml:save());xml:delete()
    check('save adapter: equal generation cannot hide foreign shared save '..role,bad.checkpoint.finish(bad.scope.sharedSaveId)==nil)
end
w=fixture();w.start();w.files['test-save/vehicles.xml'].nodes['vehicles.animal(0)'].identityKey='1 101 1'
check('save adapter: full-key duplicates across actual files reject manifest',w.checkpoint.finish(w.scope.sharedSaveId)==nil)
w=fixture();w.start();local manifest=assert(w.adapter.storage.read(A.ANIMALS_PATH));w.files['test-save/vehicles.xml'].nodes['vehicles.animal(0)'].pregnancy='changed while same keys'
check('save adapter: unchanged animal keys cannot hide changed actual saved contents',manifest~=w.adapter.storage.read(A.ANIMALS_PATH))
w=fixture();w.start();proof=assert(w.checkpoint.finish(w.scope.sharedSaveId));w.files['test-save/placeables.xml'].nodes['placeables.animal(0)'].pregnancy='later edit'
reload=assert(A.new(w.options))
check('save adapter: old career proof rejects native full-content edits',assert(C.new(reload.storage,reload.contracts,w.hooks)).load()==nil)
for _,role in ipairs({'identity','acquisition','broker','months'})do
    local bad=fixture();assert(bad.adapter.begin(bad.scope));local payload=cp(bad.payloads[role])
    if role=='identity'then payload.digest='invalid'elseif role=='acquisition'then payload.extra=true elseif role=='broker'then payload.sequence=3 else payload.revision='invalid'end
    check('save adapter: real '..role..' validator runs before creating archive',not bad.adapter.writePayload(bad.scope.sharedSaveId,role,payload) and bad.files[bad.adapter.contracts.participants[role].path]==nil)
end
w=fixture();w.start();local path=w.adapter.contracts.participants.broker.path..'.staging';w.files[path]=nil
check('save adapter: missing broker completion slot cannot be marked validated',w.checkpoint.finish(w.scope.sharedSaveId)==nil)
w=fixture();w.start();w.files['test-save/rm_RlAnimalIdentityJournal.pending.xml']={root='unknown',nodes={unknown={}},children={}}
check('save adapter: unexplained external identity journal closes broker admission',w.checkpoint.finish(w.scope.sharedSaveId)==nil and w.checkpoint.status().allowEngineSave)
for _,fault in ipairs({'removeNoop','removeProperty','delete','saveFalse'})do
    local bad=fixture();bad.start();bad.fault=fault
    check('save adapter: native career '..fault..' uncertainty cannot open gate',bad.checkpoint.finish(bad.scope.sharedSaveId)==nil and not bad.checkpoint.status().allowNewTransactions and bad.checkpoint.status().allowEngineSave)
end
w=fixture();w.start();w.files['test-save/careerSavegame.xml'].nodes.careerSavegame.rlMarketForeignProof='mixed'
check('save adapter: unknown mixed career proof is not stripped or ignored',w.checkpoint.finish(w.scope.sharedSaveId)==nil)
w=fixture();w.start();w.files['test-save/careerSavegame.xml'].nodes.careerSavegame[A.CAREER_MARKER]='invalid'
check('save adapter: malformed prior career evidence cannot be overwritten',w.checkpoint.finish(w.scope.sharedSaveId)==nil and w.files['test-save/careerSavegame.xml'].nodes.careerSavegame[A.CAREER_MARKER]=='invalid')
w=fixture();w.start();local nested=0;w.callback=function()
    local value,reason=w.adapter.begin(w.scope);if value==nil and reason=='MARKET_SAVE_ADAPTER_BUSY'then nested=nested+1 end
end
check('save adapter: native and cleanup callbacks cannot reenter shared scope',w.checkpoint.finish(w.scope.sharedSaveId)~=nil and nested>0)
w=fixture();local forged={path='elsewhere.xml',schemaVersion=1}
check('save adapter: no caller-supplied marker replaces actual storage read',w.adapter.storage.inspectParticipant('placeables','forged',forged)==nil and w.adapter.storage.read('elsewhere.xml')==nil)
w=fixture();assert(w.adapter.begin(w.scope));local xml=assert(w.io.load('callback','test-save/placeables.xml'))
assert(w.adapter.markNative(w.scope.sharedSaveId,'placeables',xml))
check('save adapter: duplicate native callbacks cannot restamp a cohort',not w.adapter.markNative(w.scope.sharedSaveId,'placeables',xml))
xml:delete()
w=fixture();w.options.extraJournalPaths={};w.adapter=assert(A.new(w.options));w.checkpoint=assert(C.new(w.adapter.storage,w.adapter.contracts,w.hooks));w.start()
w.files['test-save/rm_RlAnimalIdentityJournal.xml']={root='identityJournal',nodes={identityJournal={}},children={}}
check('save adapter: empty optional journal list cannot suppress identity evidence',w.checkpoint.finish(w.scope.sharedSaveId)==nil)
w=fixture();w.start();w.files['test-save/careerSavegame.xml'].children.careerSavegame={{name='rlMarketForeign',key='careerSavegame.rlMarketForeign(0)'}};w.files['test-save/careerSavegame.xml'].nodes['careerSavegame.rlMarketForeign(0)']={}
check('save adapter: unknown native market proof child cannot disappear in body normalization',w.checkpoint.finish(w.scope.sharedSaveId)==nil)
w=fixture();assert(w.adapter.begin(w.scope));local altered=cp(w.payloads.months);altered.months['10'].orders[1].quantityTotal=999;altered.months['10'].revision=nil;altered.months['10'].revision=D.fingerprint(altered.months['10']);altered.revision=nil;altered.revision=D.fingerprint(altered)
check('save adapter: recomputed history hashes cannot hide invalid real order quota',not w.adapter.writePayload(w.scope.sharedSaveId,'months',altered))
w=fixture();assert(w.adapter.begin(w.scope));local invented=cp(w.payloads.months);invented.payloadValidated=true
check('save adapter: saved payloadValidated assertion is not a month validation shortcut',not w.adapter.writePayload(w.scope.sharedSaveId,'months',invented))
w=fixture();w.options.allowTestCatalog=false;w.adapter=assert(A.new(w.options));assert(w.adapter.begin(w.scope))
check('save adapter: uncalibrated test-only months do not pass production validator',not w.adapter.writePayload(w.scope.sharedSaveId,'months',w.payloads.months))
check('save adapter: invalid factory shapes fail without file writes',A.new(nil)==nil and A.new(17)==nil)
w=fixture();w.options.extraJournalPaths=17
check('save adapter: invalid nested journal configuration is a factory error',A.new(w.options)==nil and w.saves==0)
w=fixture();w.start();local savedRaw=assert(w.adapter.storage.read('test-save/placeables.xml'))
local invalidContract={path='test-save/placeables.xml',schemaVersion=1,executable=function()end}
check('save adapter: fingerprint-invalid contract never equals actual native contract',w.adapter.storage.inspectParticipant('placeables',savedRaw,invalidContract)==nil)

local function allocatedFixture()
    local world=fixture();local identity=assert(RLAnimalIdentity.new('Lidentity'))
    assert(RLAnimalIdentity.registerDomain(identity,1,'1',{kind='EXCLUSIVE_NEW',startRaw=1}))
    local reserved=assert(RLAnimalIdentity.reserveBatch(identity,'new-actual-keys',{country=1,farmId='1',items={{role='adult',type='COW'},{role='fetus',type='COW'}}}))
    assert(RLAnimalIdentity.bindMaterialization(identity,'new-actual-keys','real-selection'))
    assert(RLAnimalIdentity.consume(identity,reserved.keys[1].key))
    local journal={lineage=identity.lineage,generation=99,sequence=identity.writerSequence,keys={reserved.keys[1].key,reserved.keys[2].key}}
    identity.generation=100;world.payloads.identity=assert(RLAnimalIdentity.export(identity))
    function world.writeJournal(filename,data)
        local xml=assert(world.io.create('identity-journal','test-save/'..filename,RLAnimalIdentityPersistence.JOURNAL_ROOT))
        assert(RLAnimalIdentityPersistence.writeJournal(xml,data));assert(xml:save());xml:delete()
    end
    return world,journal
end
local oldJournal
w,oldJournal=allocatedFixture();w.writeJournal(RLAnimalIdentityPersistence.JOURNAL_FILENAME,oldJournal);w.writeJournal(RLAnimalIdentityPersistence.JOURNAL_PENDING_FILENAME,oldJournal)
w.start();proof=assert(w.checkpoint.finish(w.scope.sharedSaveId))
check('save adapter: actual allocation then full identity save absorbs retained main and pending',w.checkpoint.status().allowNewTransactions and w.files['test-save/'..RLAnimalIdentityPersistence.JOURNAL_FILENAME]~=nil and w.files['test-save/'..RLAnimalIdentityPersistence.JOURNAL_PENDING_FILENAME]~=nil)
check('save adapter: both actual absorbed identity logs reference common saved ledger',#assert(w.adapter.storage.journals())==6)
reload=assert(A.new(w.options))
check('save adapter: independent identity generation100 and old journal99 verify against market generation1',assert(C.new(reload.storage,reload.contracts,w.hooks)).load()~=nil)
for _,kind in ipairs({'SAME_GENERATION','FUTURE','SEQUENCE','KEY_NOT_ABSORBED','OTHER_LINEAGE','PENDING_DIFFERENT','PENDING_ONLY'})do
    local bad,journal=allocatedFixture();local pending=cp(journal)
    if kind=='SAME_GENERATION'then journal.generation=100 elseif kind=='FUTURE'then journal.generation=101 elseif kind=='SEQUENCE'then journal.sequence=bad.payloads.identity.writerSequence+1
    elseif kind=='KEY_NOT_ABSORBED'then journal.keys={'1 19999 1'} elseif kind=='OTHER_LINEAGE'then journal.lineage='Lother'
    elseif kind=='PENDING_DIFFERENT'then pending.keys={journal.keys[1]}end
    if kind~='PENDING_ONLY'then bad.writeJournal(RLAnimalIdentityPersistence.JOURNAL_FILENAME,journal)end
    if kind=='PENDING_DIFFERENT'or kind=='PENDING_ONLY'then bad.writeJournal(RLAnimalIdentityPersistence.JOURNAL_PENDING_FILENAME,pending)end
    local started=pcall(bad.start)
    check('save adapter: real journal '..kind..' never releases broker gate',not started and bad.checkpoint.finish(bad.scope.sharedSaveId)==nil and not bad.checkpoint.status().allowNewTransactions and bad.checkpoint.status().allowEngineSave)
end
w=fixture();w.start();w.files['test-save/'..RLAnimalIdentityPersistence.FILENAME].nodes[RLAnimalIdentityPersistence.ROOT][A.NATIVE_MARKER]=nil
check('save adapter: independent owner metadata without common marker is insufficient',w.checkpoint.finish(w.scope.sharedSaveId)==nil)
w=fixture();assert(w.adapter.begin(w.scope));local missingOwner,ownerReason=w.adapter.writePayload(w.scope.sharedSaveId,'identity',w.payloads.identity)
check('save adapter: absent real identity owner is an explicit evidence capability gap',missingOwner==nil and ownerReason=='IDENTITY_OWNER_EVIDENCE_REQUIRED')
for _,kind in ipairs({'OWNER_GENERATION','COUNTER_GENERATION','COUNTER_SHARED','COUNTER_BODY','COUNTER_MISSING','CAREER_IDENTITY_GENERATION'})do
    local bad=fixture();bad.start();local path='test-save/rm_RlAnimalSystem.xml';local root='rm_RlAnimalSystem'
    if kind=='OWNER_GENERATION'then bad.files['test-save/placeables.xml'].nodes.placeables[A.IDENTITY_MARKER]='Lidentity:99'
    elseif kind=='COUNTER_GENERATION'then bad.files[path].nodes[root][A.IDENTITY_MARKER]='Lidentity:99'
    elseif kind=='COUNTER_SHARED'then bad.files[path].nodes[root][A.NATIVE_MARKER]=nil
    elseif kind=='COUNTER_BODY'then bad.files[path].nodes[root].counters='changed after common snapshot'
    elseif kind=='CAREER_IDENTITY_GENERATION'then bad.files['test-save/careerSavegame.xml'].nodes.careerSavegame[A.IDENTITY_MARKER]='Lidentity:99'
    else bad.files[path]=nil end
    check('save adapter: identity owner complete cohort rejects '..kind,bad.checkpoint.finish(bad.scope.sharedSaveId)==nil)
end
for _,kind in ipairs({'RECOVERY_STUB','FUTURE_OWNER_SCHEMA'})do
    local bad=fixture();bad.changeOwner=function(data)if kind=='RECOVERY_STUB'then data.recovery='LEDGER_NOT_EXPORTED'else data.schema=2 end end
    check('save adapter: original identity '..kind..' cannot masquerade as complete evidence',not pcall(bad.start) and not bad.checkpoint.status().allowNewTransactions)
end
w=fixture();w.start()
local oldNative=assert(w.adapter.storage.read('test-save/placeables.xml'))
w.files['test-save/placeables.xml'].nodes['placeables.animal(0)'].pregnancy='fresh real read'
local newNative=assert(w.adapter.storage.read('test-save/placeables.xml'))
check('save adapter: latest native read revokes inspection of prior raw XML',oldNative~=newNative and w.adapter.storage.inspectParticipant('placeables',oldNative,w.adapter.contracts.participants.placeables)==nil and w.adapter.storage.inspectParticipant('placeables',newNative,w.adapter.contracts.participants.placeables)~=nil)
w=fixture();w.start();local oldCareer=assert(w.adapter.storage.read('test-save/careerSavegame.xml'));proof=assert(w.checkpoint.finish(w.scope.sharedSaveId))
local newCareer=assert(w.adapter.storage.read('test-save/careerSavegame.xml'))
check('save adapter: new career read revokes both old proof and old body access',oldCareer~=newCareer and w.adapter.storage.inspectCareer(oldCareer)==nil and w.adapter.storage.careerBody(oldCareer)==nil and w.adapter.storage.inspectCareer(newCareer)~=nil and w.adapter.storage.careerBody(newCareer)~=nil)
w=fixture();local previousRaw;local previousOther={}
for generation=1,3 do
    w.scope.generation=generation;w.scope.checkpointId='cache-checkpoint:'..generation;w.scope.sharedSaveId='cache-save:'..generation
    w.start();local currentRaw=assert(w.adapter.storage.read('test-save/placeables.xml'));local previousRefused=previousRaw==nil or w.adapter.storage.inspectParticipant('placeables',previousRaw,w.adapter.contracts.participants.placeables)==nil
    local currentOther={}
    for _,role in ipairs({'animals','identity','acquisition','broker','months'})do
        currentOther[role]=assert(w.adapter.storage.read(w.adapter.contracts.participants[role].path))
        if previousOther[role]then previousRefused=previousRefused and w.adapter.storage.inspectParticipant(role,previousOther[role],w.adapter.contracts.participants[role])==nil end
    end
    local saved=assert(w.checkpoint.finish(w.scope.sharedSaveId));local reread=assert(w.checkpoint.load())
    check('save adapter: single-slot caches preserve finish/load/body across generation '..generation,previousRefused and saved.generation==generation and D.fingerprint(saved)==D.fingerprint(reread))
    previousRaw=currentRaw;previousOther=currentOther;assert(w.adapter.endScope(w.scope.sharedSaveId))
end
