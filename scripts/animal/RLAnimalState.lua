-- Business state shared by transaction adapters. Engine display objects can
-- point back to the animal and are never physiology or durable identity.
RLAnimalState = {}
local A = RLAnimalState
local volatile={id=true,idFull=true,clusterSystem=true,isDirty=true,visualAnimal=true,visualAnimalIndex=true}
function A.isVolatile(key) return volatile[key]==true end
function A.capture(animal,options)
    options=options or {}
    local active={}
    local function visit(v,depth)
        local kind=type(v)
        if kind=="number" and (v~=v or math.abs(v)==math.huge) then error("NONFINITE_STATE",0) end
        if kind~="table" then
            if kind=="function" or kind=="userdata" or kind=="thread" then error("OPAQUE_STATE",0) end
            return v
        end
        if depth>24 or active[v] then error("CYCLIC_OR_DEEP_STATE",0) end
        active[v]=true
        local out={}
        for key,item in next,v do
            local ignored=depth==0 and (volatile[key] or (options.ignored and options.ignored[key]))
            local method=type(item)=="function" and (depth==0 or options.ignoreNestedMethods==true)
            if not ignored and not method then
                if type(key)~="string" and (type(key)~="number" or key~=key or math.abs(key)==math.huge or key%1~=0) then error("STATE_KEY",0) end
                out[key]=visit(item,depth+1)
            end
        end
        active[v]=nil;return out
    end
    if type(animal)~="table" then return nil,"ANIMAL_REQUIRED" end
    local okay,result=pcall(visit,animal,0)
    if not okay then return nil,tostring(result) end
    return result
end
