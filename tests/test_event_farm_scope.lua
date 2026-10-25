loadMod("scripts/utils/RLPermissionHelper.lua")
local H=RLPermissionHelper
FarmManager={MAX_NUM_FARMS=16}
for _,id in ipairs({0,-1,1.5,17,math.huge,0/0,"7"}) do
    check("farm scope: invalid owner/requester rejected "..tostring(id),not H.authorize(true,id,id))
end
check("farm scope: permission is strict boolean",not H.authorize(1,7,7))
check("farm scope: same real farm accepted",H.authorize(true,7,7)==true)
check("farm scope: cross farm rejected",not H.authorize(true,7,8))
local names={"RLFilterCreateEvent","RLFilterUpdateEvent","RLFilterDeleteEvent",
    "RLHerdsmanRuleCreateEvent","RLHerdsmanRuleUpdateEvent","RLHerdsmanRuleDeleteEvent"}
for _,name in ipairs(names) do loadMod("scripts/events/"..name..".lua") end
local farm,permission,recordFarm=7,true,7
local broadcasts,applies=0,0
g_currentMission={userManager={getUniqueUserIdByConnection=function()return "user"end,
    getUserByConnection=function()return {nickname="tester"}end},getHasPlayerPermission=function()return permission end}
g_farmManager={getFarmForUniqueUserId=function(_,id)return id=="user" and {farmId=farm} or nil end}
g_server={broadcastEvent=function()broadcasts=broadcasts+1 end}
local function service()
    return {_rawGetById=function(_,id)if id=="existing"then return {id=id,farmId=recordFarm,version=1}end end,
        applyIncomingCreate=function()applies=applies+1 end,
        applyIncomingUpdate=function()applies=applies+1 end,
        applyIncomingDelete=function()applies=applies+1;return true end}
end
g_rlFilterService=service();g_rlHerdsmanRuleService=service();g_rlMenu=nil
local remote={getIsServer=function()return false end}
local function request(name,owner)
    local id=name:find("Create",1,true) and "new" or "existing"
    if name:find("Delete",1,true)then return _G[name].new(id)end
    return _G[name].new({id=id,farmId=owner,version=1,name="test"})
end
for _,name in ipairs(names) do
    farm,recordFarm,permission=7,7,true
    local before=broadcasts;request(name,7):run(remote)
    check("remote scope: permitted owner applies and rebroadcasts "..name,broadcasts==before+1 and applies==broadcasts)
    for _,bad in ipairs({0,1.5,8})do
        farm=bad;before=broadcasts;request(name,7):run(remote)
        check("remote scope: wrong or reserved sender has no side effects "..name..tostring(bad),broadcasts==before and applies==broadcasts)
    end
    for _,bad in ipairs({0,1.5})do
        farm,recordFarm=bad,bad;before=broadcasts;request(name,bad):run(remote)
        check("remote scope: equal invalid farms cannot authorize "..name..tostring(bad),broadcasts==before and applies==broadcasts)
    end
    farm,permission=7,false;before=broadcasts;request(name,7):run(remote)
    check("remote scope: permission denial has no side effects "..name,broadcasts==before and applies==broadcasts)
end
for _,name in ipairs({"RLFilterCreateEvent","RLFilterUpdateEvent","RLFilterDeleteEvent"})do
    farm,recordFarm,permission=nil,nil,true
    local before=broadcasts;request(name,nil):run(remote)
    check("remote scope: existing global filter policy retained "..name,broadcasts==before+1)
end
farm,permission=7,true
local _,_,_,_,first=H.authorizeConnection(remote,"tradeAnimals",7)
farm=8
local allowed,_,_,_,second=H.authorizeConnection(remote,"tradeAnimals",7)
check("farm scope: new request reads current farm rather than cached principal",first==7 and second==8 and not allowed)
g_currentMission=nil;g_farmManager=nil
check("farm scope: absent engine context fails closed",not H.authorizeConnection(remote,"tradeAnimals",7))
