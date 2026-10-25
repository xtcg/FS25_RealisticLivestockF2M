loadMod("tests/brokerruntimefixture.lua")
TabbedMenuFrameElement={onFrameOpen=function() end,onFrameClose=function() end}
InputAction={MENU_BACK=1,MENU_EXTRA_1=2,MENU_ACCEPT=3}
FocusManager={setFocus=function() end}
g_i18n={getText=function(_,key) return key end,hasText=function() return true end,
    formatMoney=function(_,value) return tostring(value) end}
InfoDialog={show=function(text) InfoDialog.last=text end}
YesNoDialog={show=function(callback,target,text) YesNoDialog.callback=callback;YesNoDialog.target=target;YesNoDialog.text=text end}
RLBrokerGameBinding={}
loadMod("scripts/gui/rlmenu/frames/RLMenuBrokerFrame.lua")
local F=RLMenuBrokerFrame
F.superClass=function() return TabbedMenuFrameElement end
local function widget()
    return {setText=function(self,value) self.text=value end,setTexts=function(self,value) self.texts=value end,
        setState=function(self,value) self.state=value end,setDisabled=function(self,value) self.disabled=value end}
end
local function setup()
    local x=BrokerRuntimeFixture.setup()
    local f=setmetatable({setMenuButtonInfoDirty=function() end},{__index=F})
    for _,name in ipairs({"orderSelector","animalSelector","statusText","orderText","conditionsText","priceText","diagnosticsText"}) do f[name]=widget() end
    f:initialize();f:onFrameOpen()
    return x,f
end
local x,f=setup()
check("broker UI: ready status, demand and eligible animal shown",f.statusText.text=="rl_broker_ready" and #f.orders==1 and #f.animals==2 and f.qualified)
check("broker UI: opening and changing selection never pays or removes",x.m.calls==0 and x.writes()==0 and #x.s.system.animals==2)
f:onPickup()
check("broker UI: pickup asks one explicit confirmation with bound server quote",f.pending and f.pending.quote.money.netToPlayer==987.5 and x.m.calls==0)
f:onConfirmed(false)
check("broker UI: declining confirmation has no side effects",not f.pending and x.m.calls==0 and #x.s.system.animals==2)
f:onPickup();local pending=f.pending;f:onFrameClose();f:onConfirmed(true)
check("broker UI: late dialog after page close cannot transact",x.m.calls==0 and #x.s.system.animals==2)
f:onFrameOpen();f:onPickup();f:onConfirmed(true)
check("broker UI: confirm settles one animal and refreshes capacity",x.m.calls==1 and #x.s.system.animals==1 and f.orders[1].remaining.breed==3 and InfoDialog.last=="rl_broker_sold")
f:onConfirmed(true)
check("broker UI: repeated dialog callback cannot settle twice",x.m.calls==1)
x,f=setup();f:onPickup();RLBrokerRuntime.current=nil;f:onConfirmed(true)
check("broker UI: mission replacement cancels old pending confirmation",x.m.calls==0 and #x.s.system.animals==2)
x,f=setup();f:onPickup();x.m.time=16000;f:onConfirmed(true)
check("broker UI: expired confirmation reports failure without asset changes",x.m.calls==0 and #x.s.system.animals==2 and InfoDialog.last=="rl_broker_reason_BROKER_QUOTE_EXPIRED")
RLBrokerRuntime.current=nil
