-- One engine hook boundary for native save observers. Checkpoints retain their
-- own guards, generations, file formats and recovery authority. Registration
-- order matches nested Utils wrappers: before hooks reverse, after hooks forward.
RLNativeSaveHooks = {}
local H=RLNativeSaveHooks
local points={
    {class="FSCareerMissionInfo",method="saveToXMLFile",before="begin",after="finish"},
    {class="PlaceableSystem",method="saveToXML",before="placeables"},
    {class="VehicleSystem",method="saveToXML",before="vehicles"},
    {class="Farm",method="saveToXMLFile",after="farms"},
    {class="SavegameController",method="onSaveComplete",after="complete"},
}
local phases={begin=true,finish=true,placeables=true,vehicles=true,farms=true,complete=true}
function H.new(environment)
    local env=environment or _G
    local owners,callbacks,bindings={},{},{}
    local dispatching=0
    for phase in pairs(phases) do callbacks[phase]={} end
    local function dispatch(phase,reverse,...)
        -- A listener registered during a save starts with the next occurrence.
        local current={}
        for i,fn in ipairs(callbacks[phase]) do current[i]=fn end
        dispatching=dispatching+1
        local args={n=select("#",...),...}
        local unpackArgs=unpack or table.unpack
        local okay,reason=pcall(function()
            if reverse then for i=#current,1,-1 do current[i](unpackArgs(args,1,args.n)) end
            else for i=1,#current do current[i](unpackArgs(args,1,args.n)) end end
        end)
        dispatching=dispatching-1
        if not okay then error(reason,0) end
    end
    local function bind()
        for index,point in ipairs(points) do
            local class=env[point.class]
            if bindings[index]==nil and type(class)=="table" and type(class[point.method])=="function" then
                local utils=env.Utils
                if type(utils)~="table" or type(utils.prependedFunction)~="function" or type(utils.appendedFunction)~="function" then return false,"NATIVE_SAVE_UTILS_REQUIRED" end
                local wrapped=class[point.method]
                if point.before then
                    local phase=point.before
                    wrapped=utils.prependedFunction(wrapped,function(...)dispatch(phase,true,...)end)
                end
                if point.after then
                    local phase=point.after
                    wrapped=utils.appendedFunction(wrapped,function(...)dispatch(phase,false,...)end)
                end
                class[point.method]=wrapped;bindings[index]=true
            end
        end
        return true
    end
    local api={}
    function api.install(owner,listeners)
        if dispatching>0 then return false,"SAVE_HOOK_REGISTRATION_DURING_CALLBACK" end
        if type(owner)~="table" or type(listeners)~="table" then return false,"SAVE_HOOK_OWNER_REQUIRED" end
        for phase,fn in pairs(listeners) do
            if not phases[phase] or type(fn)~="function" then return false,"INVALID_SAVE_HOOK_LISTENER" end
        end
        if not owners[owner] then
            owners[owner]=true
            for phase,fn in pairs(listeners) do callbacks[phase][#callbacks[phase]+1]=fn end
        end
        return bind()
    end
    return api
end
function H.install(owner,listeners)
    if H.instance==nil then H.instance=H.new() end
    return H.instance.install(owner,listeners)
end
