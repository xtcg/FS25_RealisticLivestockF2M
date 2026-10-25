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

MarketSaveFixture={new=fixture,seed=seed,history=history}
