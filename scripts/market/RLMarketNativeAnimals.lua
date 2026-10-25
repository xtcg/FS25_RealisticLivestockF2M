-- Read-only native XML animal inventory. Never loads/constructs an Animal,
-- assigns IDs, flushes a ClusterSystem, or repairs an incomplete save.
-- SDK sources: PlaceableSystem.saveToXML -> Placeable.saveToXMLFile ->
-- PlaceableHusbandryAnimals.saveToXMLFile (".husbandryAnimals.clusters");
-- VehicleSystem.saveVehicleToXML -> Vehicle.saveToXMLFile -> LivestockTrailer
-- (".livestockTrailer"). RLRM ClusterSystem writes direct .animal(i), reads
-- legacy .RLAnimal(i). AnimalPersistence writes #farmId/#id/.birthday#country.
-- A semen straw keeps its sire as a record named animal directly under a
-- dewarData node (DewarData on a vehicle, DewarObjectStorageHook in object
-- storage): a pedigree record, never a live animal, counted apart.
RLMarketNativeAnimals={}
local N=RLMarketNativeAnimals
N.MAX_NODES=500000
N.MAX_DEPTH=48
local function need(ok,why)if not ok then error(why,0)end end
local text=RLPlain.text
local function integer(v,min)return type(v)=="number" and v==v and v>=min and v<2^52 and v%1==0 end
local function cp(v)return assert(RLMarketData.copy(v))end
local function fields(v,allowed)need(type(v)=="table","NATIVE_LAYOUT_TABLE_REQUIRED");for k in pairs(v)do need(allowed[k],"UNKNOWN_NATIVE_LAYOUT_FIELD")end end
local function array(v)
    need(type(v)=="table","NATIVE_ARRAY_REQUIRED")
    local n=0;for k in pairs(v)do n=n+1;need(integer(k,1) and k<=#v,"SPARSE_NATIVE_ARRAY")end
    need(n==#v,"SPARSE_NATIVE_ARRAY")
end
local function rawInteger(v,min)
    need(type(v)=="string" and v:match("^%d+$")~=nil,"NATIVE_INTEGER_REQUIRED")
    local n=tonumber(v);need(integer(n,min) and string.format('%.0f',n)==v,"NONCANONICAL_NATIVE_INTEGER");return n
end
local function key(herd,id,country)
    need(type(herd)=="string" and herd:match('^%d+$') and tonumber(herd)>0
        and type(id)=="string" and id:match('^%d+$') and tonumber(id)>0,"NATIVE_INDIVIDUAL_ID_REQUIRED")
    local c=rawInteger(country,1)
    return herd.." "..id.." "..string.format('%.0f',c)
end
local function tree(xml,root)
    need(type(xml)=="table" and type(xml.getNumOfChildren)=="function" and type(xml.getElementName)=="function"
        and type(xml.getString)=="function" and type(xml.hasProperty)=="function","NATIVE_XML_ENUMERATION_UNSUPPORTED")
    need(xml:hasProperty(root),"NATIVE_DOCUMENT_ROOT_MISSING")
    local all,count={},0
    local function walk(path,name,depth)
        count=count+1;need(count<=N.MAX_NODES and depth<=N.MAX_DEPTH,"NATIVE_XML_LIMIT")
        local node={path=path,name=name,children={}};all[path]=node
        local n=xml:getNumOfChildren(path);need(integer(n,0) and n<=N.MAX_NODES,"NATIVE_CHILD_COUNT_INVALID")
        local indices={}
        for i=0,n-1 do
            -- Same wildcard traversal used by FS25 XMLFile.iterateRecursively.
            local childName=xml:getElementName(path..".*("..i..")")
            need(text(childName) and childName:match('^[%a_][%w_%-]*$'),"NATIVE_NODE_NAME_UNSUPPORTED")
            local index=indices[childName]or 0;indices[childName]=index+1
            local child=walk(path.."."..childName.."("..index..")",childName,depth+1)
            node.children[#node.children+1]=child
        end
        return node
    end
    return walk(root,root,0),all
end
local function child(node,name)
    local found
    for _,v in ipairs(node.children)do if v.name==name then need(found==nil,"DUPLICATE_NATIVE_LAYOUT_NODE");found=v end end
    return found
end
function N.new(options)
    if type(options)~="table" or type(options.resolveContainer)~="function" or type(options.resolveSubtype)~="function"
        or (options.validateInventory~=nil and type(options.validateInventory)~="function")then return nil,"NATIVE_RESOLVERS_REQUIRED"end
    local resolveContainer,resolveSubtype,validateInventory=options.resolveContainer,options.resolveSubtype,options.validateInventory
    local busy=false
    return function(xml,role)
        if busy then return nil,"NATIVE_ANIMAL_INSPECTOR_BUSY"end
        busy=true
        local okay,value,diagnostics=pcall(function()
            need(role=="placeables" or role=="vehicles","NATIVE_ANIMAL_ROLE_UNSUPPORTED")
            local root,all=tree(xml,role)
            if role=="placeables"then need(xml:getString('placeables#version')=='1',"PLACEABLE_SAVE_VERSION_UNSUPPORTED")end
            local result,seen,headers,accepted={}, {},{},{}
            local rowName=role=="placeables" and "placeable" or "vehicle"
            local containers,individuals,strawRecords=0,0,0
            for _,row in ipairs(root.children)do
                need(row.name==rowName,"NATIVE_DOCUMENT_LAYOUT_UNSUPPORTED")
                local h={xmlKey=row.path,uniqueId=xml:getString(row.path..'#uniqueId'),filename=xml:getString(row.path..'#filename'),
                    farmId=xml:getString(row.path..'#farmId'),isPreplaced=xml:getString(row.path..'#isPreplaced'),isDeleted=xml:getString(row.path..'#isDeleted')}
                need(text(h.uniqueId) and not seen['container:'..h.uniqueId],"NATIVE_CONTAINER_UID_MISSING_OR_DUPLICATE")
                seen['container:'..h.uniqueId]=true;headers[#headers+1]=h
                local layout,reason=resolveContainer(role,cp(h));need(layout~=nil,reason or "NATIVE_CONTAINER_LAYOUT_UNSUPPORTED");layout=cp(layout)
                fields(layout,{kind=true,uniqueId=true,animalTypeIndices=true})
                need(layout.uniqueId==h.uniqueId,"NATIVE_CONTAINER_UID_MISMATCH")
                need(layout.kind=="PEN" or layout.kind=="TRAILER" or layout.kind=="NON_ANIMAL","NATIVE_CONTAINER_LAYOUT_UNSUPPORTED")
                need((layout.kind~="PEN" or role=="placeables") and (layout.kind~="TRAILER" or role=="vehicles"),"NATIVE_CONTAINER_ROLE_MISMATCH")
                local allowedTypes={}
                if layout.kind~="NON_ANIMAL"then
                    array(layout.animalTypeIndices);need(#layout.animalTypeIndices>0,"NATIVE_CONTAINER_TYPE_UNSUPPORTED")
                    for _,index in ipairs(layout.animalTypeIndices)do need(integer(index,1) and not allowedTypes[index],"INVALID_NATIVE_CONTAINER_TYPES");allowedTypes[index]=true end
                else need(layout.animalTypeIndices==nil,"NON_ANIMAL_LAYOUT_HAS_ANIMAL_TYPES")end
                local pen=child(row,'husbandryAnimals');local trailer=child(row,'livestockTrailer')
                local base
                if layout.kind=="PEN"then
                    need(trailer==nil,"NATIVE_CONTAINER_LAYOUT_MISMATCH")
                    if pen then base=child(pen,'clusters')end
                elseif layout.kind=="TRAILER"then need(pen==nil,"NATIVE_CONTAINER_LAYOUT_MISMATCH");base=trailer
                else need(pen==nil and trailer==nil,"NON_ANIMAL_HAS_NATIVE_ANIMAL_LAYOUT")end
                if pen then accepted[pen.path]=true end
                if trailer then accepted[trailer.path]=true end
                if base then
                    local containerType
                    for _,entry in ipairs(base.children)do
                        if entry.name=='animal' or entry.name=='RLAnimal'then
                            local format=entry.name=='animal' and 'CURRENT' or 'LEGACY_RL'
                            local amount=xml:getString(entry.path..'#numAnimals')
                            if amount==nil and format=='LEGACY_RL'then amount='1'end
                            need(rawInteger(amount,1)==1,"VANILLA_CLUSTER_OR_NONLIVE_ENTRY_UNSUPPORTED")
                            local rawSubtype=xml:getString(entry.path..'#subType');need(text(rawSubtype),"NATIVE_SUBTYPE_REQUIRED")
                            if format=='LEGACY_RL'then rawInteger(rawSubtype,1)end
                            local subtype,why=resolveSubtype(format,rawSubtype);need(subtype~=nil,why or "NATIVE_SUBTYPE_UNSUPPORTED");subtype=cp(subtype)
                            fields(subtype,{subTypeIndex=true,animalTypeIndex=true,subTypeName=true})
                            need(integer(subtype.subTypeIndex,1) and integer(subtype.animalTypeIndex,1) and text(subtype.subTypeName)
                                and (format~='CURRENT' or subtype.subTypeName==rawSubtype),"NATIVE_SUBTYPE_SCOPE_MISMATCH")
                            need(allowedTypes[subtype.animalTypeIndex] and (containerType==nil or containerType==subtype.animalTypeIndex),"NATIVE_MIXED_ANIMAL_TYPE_UNSUPPORTED")
                            containerType=subtype.animalTypeIndex
                            local birthday=child(entry,'birthday');need(birthday~=nil,"NATIVE_BIRTH_COUNTRY_REQUIRED")
                            local identity=key(xml:getString(entry.path..'#farmId'),xml:getString(entry.path..'#id'),xml:getString(birthday.path..'#country'))
                            need(not seen[identity],"DUPLICATE_NATIVE_ANIMAL_KEY");seen[identity]=true
                            result[#result+1]=identity;individuals=individuals+1;accepted[entry.path]=true
                        else error("NATIVE_CLUSTER_LAYOUT_UNSUPPORTED",0)end
                    end
                end
                containers=containers+1
            end
            -- Enumerate the complete parsed XML tree, including nodes that a
            -- known-path-only read would skip. Fetuses and pedigree children
            -- are not named animal/RLAnimal and never enter the live inventory.
            for path,node in pairs(all)do
                local lower=node.name:lower()
                if node.name=='animal' and not accepted[path] and path:match('%.dewarData%(%d+%)%.animal%(%d+%)$')
                    and xml:getString(path..'#numAnimals')==nil then
                    -- A straw's sire record (its genetics beside it): no live count. An
                    -- animal node nested below it is still checked on its own.
                    strawRecords=strawRecords+1
                elseif node.name=='animal' or node.name=='RLAnimal' or lower=='husbandryanimals' or lower=='livestocktrailer'then
                    need(accepted[path],"UNDECLARED_NATIVE_ANIMAL_LAYOUT")
                end
            end
            if validateInventory then need(validateInventory(role,cp(headers))==true,"NATIVE_WORLD_SAVE_COVERAGE_UNSUPPORTED")end
            table.sort(result)
            return result,{schemaVersion=1,role=role,containers=containers,individuals=individuals,strawRecords=strawRecords,source='NATIVE_XML_READ_ONLY'}
        end)
        busy=false
        if not okay then return nil,tostring(value)end
        return value,diagnostics
    end
end

-- Conservative default: persistent UID is matched against real saved-object
-- inventory, never guessed from filenames. An animal container is admitted only
-- when its writer is the exact stock specialization module (the module, not the
-- object's origin, decides the XML layout: a map's or mod's pen built on the stock
-- PlaceableHusbandryAnimals saves as any other). A mod specialization whose name
-- says it may hold animals, absent objects, nonpersistent animal containers and
-- ambiguous layouts are unsupported. Other mod objects are NON_ANIMAL.
function N.fromMission(mission,options)
    options=options or {}
    if type(mission)~='table' or type(mission.placeableSystem)~='table' or type(mission.placeableSystem.placeables)~='table'
        or type(mission.vehicleSystem)~='table' or type(mission.vehicleSystem.vehicles)~='table' or type(mission.animalSystem)~='table'
        or type(PlaceableHusbandryAnimals)~='table' or type(LivestockTrailer)~='table'then return nil,'NATIVE_MISSION_INVENTORY_UNSUPPORTED'end
    local system=mission.animalSystem
    for _,name in ipairs({'getSubTypeIndexByName','getSubTypeByIndex','getTypeByIndex'})do if type(system[name])~='function'then return nil,'NATIVE_SUBTYPE_REGISTRY_UNSUPPORTED'end end
    local function inventory(role)return role=='placeables' and mission.placeableSystem.placeables or mission.vehicleSystem.vehicles end
    local function objectLayout(object,role)
        need(type(object)=='table','NATIVE_UID_LAYOUT_UNSUPPORTED')
        array(object.specializationNames);array(object.specializations)
        need(#object.specializationNames==#object.specializations,'NATIVE_SPECIALIZATIONS_UNSUPPORTED')
        local names,pen,trailer={},false,false
        for index,name in ipairs(object.specializationNames)do
            need(text(name) and not names[name] and type(object.specializations[index])=='table','NATIVE_SPECIALIZATIONS_UNSUPPORTED');names[name]=true
            local modded=name:find('.',1,true)~=nil
            local base=(modded and name:match('[^%.]+$') or name):lower()
            local animalish=base:find('animal',1,true) or base:find('livestock',1,true) or base:find('rideable',1,true) or base:find('horse',1,true) or base:find('husbandry',1,true)
            if modded then
                -- A mod's own specialization: admitted only when nothing in its name says it stores animals.
                local trusted=animalish and type(options.trustedCompanion)=='function'
                    and options.trustedCompanion(name,object.specializations[index])==true
                need(not animalish or trusted,'NATIVE_ANIMAL_SPECIALIZATION_UNSUPPORTED')
            elseif name=='husbandryAnimals'then need(object.specializations[index]==PlaceableHusbandryAnimals,'NATIVE_PEN_WRITER_UNSUPPORTED');pen=true
            elseif name=='livestockTrailer'then need(object.specializations[index]==LivestockTrailer,'NATIVE_TRAILER_WRITER_UNSUPPORTED');trailer=true
            elseif animalish then
                -- Standard husbandry companion specializations are safe only
                -- in a proven husbandryAnimals container, checked below.
                need(name:sub(1,9)=='husbandry','NATIVE_ANIMAL_SPECIALIZATION_UNSUPPORTED')
            end
        end
        need(not (pen and trailer) and pen==(object.spec_husbandryAnimals~=nil) and trailer==(object.spec_livestockTrailer~=nil),'NATIVE_CONTAINER_SPEC_MISMATCH')
        for name in pairs(names)do if name:sub(1,9)=='husbandry'then need(pen,'NATIVE_HUSBANDRY_LAYOUT_UNSUPPORTED')end end
        if pen or trailer then
            need(type(object.getNeedsSaving)=='function' and object:getNeedsSaving()==true,'UNPERSISTED_NATIVE_ANIMAL_CONTAINER')
        end
        need(text(object.uniqueId) or (not pen and not trailer and type(object.getNeedsSaving)=='function'
            and object:getNeedsSaving()==false),'NATIVE_UID_LAYOUT_UNSUPPORTED')
        local layout={uniqueId=object.uniqueId,kind='NON_ANIMAL'}
        if pen then
            need(role=='placeables' and integer(object.spec_husbandryAnimals.animalTypeIndex,1),'NATIVE_PEN_TYPE_UNSUPPORTED')
            layout.kind='PEN';layout.animalTypeIndices={object.spec_husbandryAnimals.animalTypeIndex}
        elseif trailer then
            need(role=='vehicles' and type(object.spec_livestockTrailer.animalTypeIndexToPlaces)=='table','NATIVE_TRAILER_TYPES_UNSUPPORTED')
            layout.kind='TRAILER';layout.animalTypeIndices={}
            for index,place in pairs(object.spec_livestockTrailer.animalTypeIndexToPlaces)do
                need(integer(index,1) and type(place)=='table' and place.animalTypeIndex==index,'NATIVE_TRAILER_TYPES_UNSUPPORTED')
                layout.animalTypeIndices[#layout.animalTypeIndices+1]=index
            end
            need(#layout.animalTypeIndices>0,'NATIVE_TRAILER_TYPES_UNSUPPORTED');table.sort(layout.animalTypeIndices)
        end
        return layout
    end
    local function resolveContainer(role,header)
        local found
        for _,object in pairs(inventory(role))do if object.uniqueId==header.uniqueId then need(found==nil,'NATIVE_WORLD_DUPLICATE_CONTAINER_UID');found=object end end
        if header.isDeleted=='true' then
            need(found==nil,'DELETED_CONTAINER_STILL_IN_WORLD')
            -- Native preplaced-object tombstone. It holds no live container;
            -- N.new still rejects any undeclared animal node beneath it.
            return {uniqueId=header.uniqueId,kind='NON_ANIMAL'}
        end
        need(found~=nil,'NATIVE_WORLD_CONTAINER_MISSING')
        need(header.isDeleted==nil or header.isDeleted=='false','DELETED_NATIVE_CONTAINER_UNSUPPORTED')
        local layout=objectLayout(found,role)
        need(type(found.getOwnerFarmId)=='function','NATIVE_OWNER_UNSUPPORTED')
        need(rawInteger(header.farmId,0)==found:getOwnerFarmId(),'NATIVE_CONTAINER_OWNER_MISMATCH')
        return layout
    end
    return N.new({resolveContainer=resolveContainer,resolveSubtype=function(format,value)
        local index=format=='CURRENT' and system:getSubTypeIndexByName(value) or rawInteger(value,1)
        need(integer(index,1),'NATIVE_SUBTYPE_UNSUPPORTED')
        local subtype=system:getSubTypeByIndex(index)
        need(type(subtype)=='table' and subtype.subTypeIndex==index and integer(subtype.typeIndex,1) and text(subtype.name)
            and type(system:getTypeByIndex(subtype.typeIndex))=='table','NATIVE_SUBTYPE_REGISTRY_MISMATCH')
        return {subTypeIndex=index,animalTypeIndex=subtype.typeIndex,subTypeName=subtype.name}
    end,validateInventory=function(role,headers)
        local saved={};for _,h in ipairs(headers)do saved[h.uniqueId]=true end
        local seen={}
        for _,object in pairs(inventory(role))do
            local layout=objectLayout(object,role)
            if layout.uniqueId~=nil then
                need(not seen[layout.uniqueId],'NATIVE_WORLD_DUPLICATE_CONTAINER_UID');seen[layout.uniqueId]=true
            end
            if layout.kind~='NON_ANIMAL'then need(saved[layout.uniqueId],'NATIVE_ANIMAL_CONTAINER_ABSENT_FROM_SAVE')end
        end
        return true
    end})
end
