-- Shared fixture plumbing only. Feed groups, diets, animal constructors and
-- scientific measurements remain explicit in pigsim/sheepsim.
SpeciesSimSupport = {}
function SpeciesSimSupport.typeIndex(subTypes,typeName)
    for _,sub in ipairs(subTypes) do if sub.typeName==typeName then return sub.typeIndex end end
end
function SpeciesSimSupport.foodGroup(fill,title,weight,names)
    local types={}
    for _,name in ipairs(names) do
        assert(fill[name]~=nil,"Unknown fixture fill type: "..name)
        types[#types+1]=fill[name]
    end
    return {title=title,productionWeight=weight,eatWeight=1,fillTypes=types}
end
