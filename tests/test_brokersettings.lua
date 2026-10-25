-- Production setting definitions/codecs and both mouse entry paths. Only the
-- engine widget tree and GIANTS' continue syntax are adapted for stock Lua.
loadMod("tests/brokerruntimefixture.lua")
loadMod("scripts/gui/rlmenu/RLMenuTabPolicy.lua")
TabbedMenu={}
loadMod("scripts/gui/rlmenu/RLMenu.lua")
local file=assert(io.open(REPO.."scripts/core/RLSettings.lua"));local source=file:read("*a");file:close()
local function section(name)
    local first=assert(source:find("function RLSettings."..name.."(",1,true))
    local last=assert(source:find("\nend\n",first,true))
    return source:sub(first,last+4)
end
RLSettings={}
for _,name in ipairs({"onClickOpenBroker","onClickOpenMenu","initialize","applyChange"}) do assert(load(section(name)))() end
Animal=Animal or {};AnimalSystem={};DiseaseManager={};RLMessageAggregator={}
RealisticLivestock_PlaceableHusbandryFood={};RealisticLivestock_PlaceableHusbandryAnimals={}
RLMapCountry={VALUES={"default"}}
local first=assert(source:find("RLSettings.SETTINGS = {",1,true))
local last=assert(source:find("\n}\n",first,true))
assert(load(source:sub(first,last+2)))()
local enabled=RLSettings.SETTINGS.brokerEnabled
check("broker setting: enabled by default, persisted, administrator controlled",enabled.default==2 and enabled.values[2]==true and enabled.adminOnly and not enabled.ignore)
check("broker setting: demand opener is an action instead of persisted state",RLSettings.SETTINGS.brokerOrders.ignore and RLSettings.SETTINGS.brokerOrders.callback==RLSettings.onClickOpenBroker)

local shows=0
g_gui={getIsDialogVisible=function() return false end,showGui=function() shows=shows+1 end}
g_i18n={getText=function(_,key) return key end}
g_rlMenu={isOpen=false,openMode=RLMenu.MODE_FULL,pageSelector={setState=function(self,index) self.state=index end}}
RLSettings.onClickOpenBroker()
check("broker entry: native Settings mouse button selects visible contract page",shows==1 and g_rlMenu.restorePageIndex==9 and g_rlMenu.openedFromInGameMenu)
g_rlMenu.isOpen=true
RLSettings.SETTINGS.brokerOrders.callback()
check("broker entry: action inside open RLRM Settings selects live page",shows==1 and g_rlMenu.pageSelector.state==9)
check("broker entry: dealer/full hidden pages have correct visible indices",RLMenuTabPolicy.visiblePageIndex(10,"dealer")==5 and RLMenuTabPolicy.visiblePageIndex(9,"full")==nil)
g_gui.getIsDialogVisible=function() return true end
check("broker entry: active confirmation dialog cannot lose its owner",not RLMenu.openBrokerPage() and shows==1)
g_gui.getIsDialogVisible=function() return false end

local panel={elements={}}
local function row(kind,name,parent,children)
    local r={typeName=kind,name=name,elements=children or {},parent=parent}
    function r:setText(text) self.text=text end
    function r:applyProfile(profile) self.profile=profile end
    function r:delete()
        for i,child in ipairs(self.parent.elements) do if child==self then table.remove(self.parent.elements,i);break end end
    end
    function r:clone(target)
        local list={};for _,child in ipairs(self.elements) do list[#list+1]=row(child.typeName,child.name) end
        local clone=row(self.typeName,self.name,target,list);target.elements[#target.elements+1]=clone;return clone
    end
    return r
end
panel.elements={row("Text","sectionHeader",panel),row("Bitmap","nativeButtonRow",panel,{row("Button"),row("Text")})}
g_inGameMenu={pageSettings={gameSettingsLayout=panel}};g_server=nil
RLSettings.initialize()
local owned=panel.rlLivestockLauncherRows
check("broker entry: native pause menu has Settings and Contracts click launchers",#owned==3 and #panel.elements==5
    and owned[2].elements[1].onClickCallback==RLSettings.onClickOpenMenu
    and owned[3].elements[1].onClickCallback==RLSettings.onClickOpenBroker)
RLSettings.initialize()
check("broker entry: mission reinitialize does not duplicate launcher rows",#panel.elements==5 and #panel.rlLivestockLauncherRows==3)

local x=BrokerRuntimeFixture.setup()
local quote=assert(x.r:preview(x.req))
local before=RLMarketData.fingerprint(x.r.quota:export())
RLSettings.applyChange("brokerEnabled",1)
local result,why=x.r:confirm(quote)
check("broker setting: turning off rejects a quote already on screen",not result and why=="BROKER_DISABLED" and #x.s.system.animals==2 and x.m.calls==0)
check("broker setting: off pauses Broker while preserving quota and legacy trade",not x.r:ready() and x.r:preflight(x.req)~=nil
    and before==RLMarketData.fingerprint(x.r.quota:export()) and RLBrokerRuntime.mutationAllowed())
RLSettings.applyChange("brokerEnabled",2)
check("broker setting: turning on resumes existing state",x.r:ready() and before==RLMarketData.fingerprint(x.r.quota:export()))
x.r.assetRisk=true;x.r:block("RECOVERY_PROBE")
RLSettings.applyChange("brokerEnabled",1);RLSettings.applyChange("brokerEnabled",2)
check("broker setting: off/on cannot clear an uncertain transaction",not x.r:ready() and not RLBrokerRuntime.mutationAllowed() and x.r.reason=="RECOVERY_PROBE")

-- Wrap the codec's original outer loop in the equivalent stock-Lua conditional.
-- This preserves ignored-action behavior without replacing the codec itself.
local function codec(name,tail)
    local text=section(name)
    local n;text,n=text:gsub("if setting.ignore then continue end","if not setting.ignore then")
    assert(n==1)
    local at=assert(text:find(tail,1,true));text=text:sub(1,at-1).."\n\t\tend"..text:sub(at)
    assert(load(text))()
end
codec("readSettingStates","\n\tend\n\n\tRLSettings.migrateRetiredNutritionMode")
codec("writeSettingStates","\n\tend\n\n\tLog:debug")
RLSettings.migrateRetiredNutritionMode=function() end
RLSettings.SETTINGS={brokerEnabled=enabled,brokerOrders={ignore=true}}
local values={}
local xml={setInt=function(_,key,value) values[key]=value end,
    getInt=function(_,key,default) local value=values[key];if value==nil then return default end;return value end}
enabled.state=1;RLSettings.writeSettingStates(xml);enabled.state=nil
RLSettings.readSettingStates(xml,"rm_RlSettings")
check("broker setting: actual settings XML codec retains off after reload",not RLBrokerRuntime.isEnabled() and values['rm_RlSettings.brokerEnabled#value']==1 and values['rm_RlSettings.brokerOrders#value']==nil)
values={};enabled.state=nil;RLSettings.readSettingStates(xml,"rm_RlSettings")
check("broker setting: old saves without a switch start enabled",RLBrokerRuntime.isEnabled())
RLBrokerRuntime.current=nil
