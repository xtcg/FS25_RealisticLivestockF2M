-- Static membership, not runtime admission. Models and map capabilities still
-- need their own evidence before pricing, physiology or settlement can run.
RLSpeciesCatalog = {}
local C = RLSpeciesCatalog
local members = {
    {key="COW", engineType="COW", configKey="COW", weightType="COW", milk="SUBTYPE_OUTPUT", marketModel="RLMarketCattleValue", indexPrefix="cattle"},
    {key="PIG", engineType="PIG", configKey="PIG", weightType="PIG", milk="NURSING_ONLY", marketModel="RLMarketPigValue"},
    {key="SHEEP", engineType="SHEEP", configKey="SHEEP", weightType="SHEEP", milk="VERIFIED_OUTPUT", marketModel="RLMarketSheepValue", indexPrefix="sheep"},
    {key="GOAT", engineType="SHEEP", configKey="GOAT", weightType="SHEEP", marketBreed="GOAT", nutritionUse="DAIRY_GOAT", milk="SUBTYPE_OUTPUT"},
    {key="MILKCOW", engineType="MILKCOW", configKey="MILKCOW", weightType="COW", weightBinding="HOLSTEIN", milk="MAP_MANAGED", market=false},
}
local packages = {
    {kind="cattleWeaned", species="COW", group="GROWER", bounds={4,10,80}},
    {kind="cattleStore", species="COW", group="GROWER", bounds={8,26,80}, defaultMaxAge=20},
    {kind="cattleFinished", species="COW", group="FINISHED", bounds={14,36,85}, defaultMaxAge=30},
    {kind="cattleReplacement", species="COW", group="BREEDING", bounds={12,30,90}},
    {kind="cattlePregnant", species="COW", group="BREEDING", bounds={18,72,90}},
    {kind="cattleLactating", species="COW", group="BREEDING", bounds={24,72,90}},
    {kind="cattleSire", species="COW", group="BREEDING", bounds={14,48,95}},
    {kind="pigGrower", species="PIG", group="GROWER", bounds={1,4,85}},
    {kind="pigFinished", species="PIG", group="FINISHED", bounds={4,10,85}},
    {kind="pigReplacement", species="PIG", group="BREEDING", bounds={6,10,90}},
    {kind="pigSire", species="PIG", group="BREEDING", bounds={8,24,95}},
    {kind="lambGrower", species="SHEEP", group="GROWER", bounds={3,8,80}},
    {kind="lambFinished", species="SHEEP", group="FINISHED", bounds={3,12,85}},
    {kind="eweReplacement", species="SHEEP", group="BREEDING", bounds={7,18,90}},
    {kind="ramSire", species="SHEEP", group="BREEDING", bounds={8,36,95}},
}
local byKey = {}
for _,member in ipairs(members) do byKey[member.key]=member end
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,item in pairs(v) do out[k]=copy(item) end;return out
end
function C.members() return copy(members) end
function C.get(key) return copy(byKey[key]) end
function C.packages() return copy(packages) end
function C.marketMembers()
    local out={}
    for _,member in ipairs(members) do if member.marketModel then out[#out+1]=copy(member) end end
    return out
end
function C.marketKey(typeName,breed)
    for _,member in ipairs(members) do
        if member.engineType==typeName and member.marketBreed==breed then return member.key end
    end
    return typeName
end
function C.configKey(typeName,use)
    for _,member in ipairs(members) do
        if member.engineType==typeName and member.nutritionUse~=nil and member.nutritionUse==use then return member.configKey end
    end
    return typeName
end
