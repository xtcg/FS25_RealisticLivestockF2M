-- Dormant FS25 XMLFile adapter for RLBrokerPersistence.newStore. The engine
-- serializes XML again on read, so disk evidence is the complete logical XML
-- tree normalized to the portable codec, not its indentation/attribute order.
-- Never use io.open here: FS25 opens files for WRITE regardless of its mode.
RLBrokerNativeStorage={}
local N=RLBrokerNativeStorage
local ROOT="rlBrokerDocument"
N.MAX_BYTES=64*1024*1024
local function need(ok,why)if not ok then error(why,0)end end
local function space(c)return c==" " or c=="\t" or c=="\r" or c=="\n"end

-- Parse every serialized node/attribute. Reading only known XMLFile paths would
-- silently overlook extra nodes or attributes. This deliberately accepts no
-- DTDs, entities, comments, arbitrary processing instructions or text content.
-- Original lexical details already discarded by the native XML parser cannot
-- be recovered here; getAsString must serialize its complete parsed tree.
local function tree(raw)
    need(type(raw)=="string" and #raw<=N.MAX_BYTES,"INVALID_NATIVE_XML")
    local pos,size=1,#raw
    local function skip()
        local start=pos
        while pos<=size and space(raw:sub(pos,pos))do pos=pos+1 end
        return pos>start
    end
    local function attributes(allowed,terminators)
        local result={}
        while true do
            local separated=skip()
            for _,ending in ipairs(terminators)do
                if raw:sub(pos,pos+#ending-1)==ending then pos=pos+#ending;return result,ending end
            end
            need(separated,"NATIVE_XML_ATTRIBUTE_SEPARATOR")
            local a,b,name=raw:find("([%a_][%w_%.:%-]*)",pos)
            need(a==pos and allowed[name] and result[name]==nil,"NATIVE_XML_UNKNOWN_OR_DUPLICATE_ATTRIBUTE")
            pos=b+1;skip();need(raw:sub(pos,pos)=="=","NATIVE_XML_ATTRIBUTE_EQUALS");pos=pos+1;skip()
            local quote=raw:sub(pos,pos);need(quote=='"' or quote=="'","NATIVE_XML_ATTRIBUTE_QUOTE");pos=pos+1
            local finish=raw:find(quote,pos,true);need(finish~=nil,"NATIVE_XML_UNTERMINATED_ATTRIBUTE")
            local value=raw:sub(pos,finish-1)
            need(not value:find('[<>&"\']'),"NATIVE_XML_NONPORTABLE_ATTRIBUTE")
            result[name]=value;pos=finish+1
        end
    end
    local function open(name,allowed)
        local prefix="<"..name
        need(raw:sub(pos,pos+#prefix-1)==prefix,"NATIVE_XML_UNEXPECTED_NODE")
        pos=pos+#prefix
        return attributes(allowed,{"/>",">"})
    end
    local function close(name)
        local prefix="</"..name
        need(raw:sub(pos,pos+#prefix-1)==prefix,"NATIVE_XML_CLOSING_NODE")
        pos=pos+#prefix;skip();need(raw:sub(pos,pos)==">","NATIVE_XML_CLOSING_END");pos=pos+1
    end
    if raw:sub(1,3)=="\239\187\191"then pos=4 end
    skip()
    if raw:sub(pos,pos+4)=="<?xml"then
        pos=pos+5
        local declaration=attributes({version=true,encoding=true,standalone=true},{"?>"})
        need(declaration.version=="1.0" and (declaration.encoding==nil or declaration.encoding:lower()=="utf-8")
            and (declaration.standalone==nil or declaration.standalone=="yes" or declaration.standalone=="no"),"NATIVE_XML_DECLARATION")
        skip()
    end
    local header,ending=open(ROOT,{schema=true,length=true,digest=true})
    need(ending==">" and header.schema~=nil and header.length~=nil and header.digest~=nil,"NATIVE_XML_HEADER")
    local chunks={}
    while true do
        skip()
        if raw:sub(pos,pos+1)=="</"then close(ROOT);break end
        local chunk,finish=open("chunk",{index=true,length=true,digest=true,v=true})
        need(chunk.index~=nil and chunk.length~=nil and chunk.digest~=nil and chunk.v~=nil,"NATIVE_XML_CHUNK_FIELDS")
        if finish==">"then skip();close("chunk")end
        chunks[#chunks+1]=chunk
    end
    skip();need(pos>size,"NATIVE_XML_TRAILING_DATA")
    return header,chunks
end
local function portable(header,chunks)
    local parts={'<'..ROOT..' schema="'..header.schema..'" length="'..header.length..'" digest="'..header.digest..'">'}
    for _,c in ipairs(chunks)do
        parts[#parts+1]='<chunk index="'..c.index..'" length="'..c.length..'" digest="'..c.digest..'" v="'..c.v..'"/>'
    end
    parts[#parts+1]='</'..ROOT..'>'
    return table.concat(parts)
end
function N.normalizeNativeXML(raw,validator)
    local okay,value=pcall(function()
        local header,chunks=tree(raw)
        local document,why=RLBrokerPersistence.decode(portable(header,chunks),validator)
        need(document~=nil,why)
        return assert(RLBrokerPersistence.encode(document,validator))
    end)
    if not okay then return nil,tostring(value)end
    return value
end

-- Inject only these real engine API shapes for isolated tests. Defaults resolve
-- fileExists/XMLFile at construction; construction does not access any files.
-- A payload validator is mandatory for the WAL/CHECKPOINT/MONTHS documents;
-- STAGING documents use the codec's strict internal validator automatically.
function N.new(options)
    options=options or {}
    if type(options)~="table"then return nil,"NATIVE_XML_DEPENDENCIES_REQUIRED"end
    local exists=options.exists or fileExists
    local load=options.load or (XMLFile and XMLFile.loadIfExists)
    local create=options.create or (XMLFile and XMLFile.create)
    local validator=options.validatePayload
    if type(exists)~="function" or type(load)~="function" or type(create)~="function" or type(validator)~="function"then return nil,"NATIVE_XML_DEPENDENCIES_REQUIRED"end
    local busy=false
    local function operation(fn)
        if busy then return nil,"BROKER_NATIVE_STORAGE_BUSY"end
        busy=true
        local handle
        local function own(xml)handle=xml;return xml end
        local okay,value,why=pcall(fn,own)
        local deleted=true
        if handle~=nil then
            -- XMLFile.delete normally returns nil. False or an exception means
            -- cleanup is uncertain and cannot be hidden by a successful save.
            local cleanup,result=pcall(function()return handle:delete()end)
            deleted=cleanup and result~=false
        end
        busy=false
        if not deleted then return nil,"NATIVE_XML_DELETE_UNCERTAIN"end
        if not okay then return nil,"NATIVE_XML_OPERATION_FAILED:"..tostring(value)end
        return value,why
    end
    local api={}
    function api.read(path)
        return operation(function(own)
            need(type(path)=="string" and path:match("%S"),"INVALID_NATIVE_PATH")
            local present=exists(path)
            need(type(present)=="boolean","NATIVE_XML_EXISTENCE_UNCERTAIN")
            if not present then return nil,"NOT_FOUND"end
            local xml=own(load("rlBrokerNativeRead",path))
            need(xml~=nil,"NATIVE_XML_LOAD_FAILED")
            local canonical,why=N.normalizeNativeXML(xml:getAsString(),validator)
            need(canonical~=nil,why)
            return canonical
        end)
    end
    function api.write(path,canonical)
        local value,why=operation(function(own)
            need(type(path)=="string" and path:match("%S"),"INVALID_NATIVE_PATH")
            local document,invalid=RLBrokerPersistence.decode(canonical,validator)
            need(document~=nil,invalid)
            need(RLBrokerPersistence.encode(document,validator)==canonical,"NONCANONICAL_NATIVE_WRITE")
            local header,chunks=tree(canonical)
            local xml=own(create("rlBrokerNativeWrite",path,ROOT))
            need(xml~=nil,"NATIVE_XML_CREATE_FAILED")
            for _,key in ipairs({"schema","length","digest"})do xml:setString(ROOT.."#"..key,header[key])end
            for index,chunk in ipairs(chunks)do
                for _,key in ipairs({"index","length","digest","v"})do xml:setString(ROOT..".chunk("..(index-1)..")#"..key,chunk[key])end
            end
            need(xml:save()==true,"NATIVE_XML_SAVE_UNCERTAIN")
            return true
        end)
        return value==true,why
    end
    return api
end
