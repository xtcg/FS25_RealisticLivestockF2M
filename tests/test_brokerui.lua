loadMod("tests/brokerruntimefixture.lua")
TabbedMenuFrameElement={onFrameOpen=function() end,onFrameClose=function() end}
InputAction={MENU_BACK=1,MENU_EXTRA_1=2,MENU_ACCEPT=3,MENU_EXTRA_2=4}
FocusManager={setFocus=function() end}
g_i18n={getText=function(_,key) return key end,hasText=function() return true end,
    formatMoney=function(_,value) return tostring(value) end}
InfoDialog={show=function(text) InfoDialog.last=text end}
YesNoDialog={show=function(callback,target,text,_,yes,no,kind,yesSound,noSound,args)
    YesNoDialog.callback=callback;YesNoDialog.target=target;YesNoDialog.text=text;YesNoDialog.args=args
end}
local function answer(confirmed) YesNoDialog.callback(YesNoDialog.target,confirmed,YesNoDialog.args) end
RLBrokerGameBinding={canRecover=function() return RLBrokerGameBinding.recoverable==true end,
    recover=function() RLBrokerGameBinding.recovered=(RLBrokerGameBinding.recovered or 0)+1;return RLBrokerGameBinding.recoverResult~=false,RLBrokerGameBinding.recoverReason end}
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
answer(false)
check("broker UI: declining confirmation has no side effects",not f.pending and x.m.calls==0 and #x.s.system.animals==2)
f:onPickup();local pending=f.pending;f:onFrameClose();answer(true)
check("broker UI: late dialog after page close cannot transact",x.m.calls==0 and #x.s.system.animals==2)
f:onFrameOpen();f:onPickup();answer(true)
check("broker UI: confirm settles one animal and refreshes capacity",x.m.calls==1 and #x.s.system.animals==1 and f.orders[1].remaining.breed==3 and InfoDialog.last=="rl_broker_sold")
answer(true)
check("broker UI: repeated dialog callback cannot settle twice",x.m.calls==1)
x,f=setup();f:onPickup();RLBrokerRuntime.current=nil;answer(true)
check("broker UI: mission replacement cancels old pending confirmation",x.m.calls==0 and #x.s.system.animals==2)
x,f=setup();f:onPickup();x.m.time=16000;answer(true)
check("broker UI: expired confirmation reports failure without asset changes",x.m.calls==0 and #x.s.system.animals==2 and InfoDialog.last=="rl_broker_reason_BROKER_QUOTE_EXPIRED")
x,f=setup();f:onPickup();local old=YesNoDialog.args;answer(false)
f:onAnimalChanged(2);f:onPickup();local current=f.pending
YesNoDialog.callback(YesNoDialog.target,true,old)
check("broker UI: old dialog cannot settle or discard a newer animal quote",f.pending==current and x.m.calls==0 and #x.s.system.animals==2)
answer(true)
check("broker UI: newer quote still requires its own confirmation",x.m.calls==1 and #x.s.system.animals==1 and x.s.system.animals[1]==x.a)
x,f=setup();x.m.animalSystem.getAnimalTransportFee=function() return 4000 end;f:refresh()
check("broker UI: nonpositive pickup net explains rejection instead of eligible",not f.qualified and f.diagnosticsText.text=="rl_broker_reason_NONPOSITIVE_BROKER_NET")
x,f=setup();RLSettings={SETTINGS={brokerEnabled={default=2,state=1,values={false,true}}}};f:refresh()
check("broker UI: disabled switch is visible and hides settlement button",f.statusText.text=="rl_broker_reason_BROKER_DISABLED" and #f.menuButtonInfo==2 and x.m.calls==0)
RLBrokerRuntime.current=nil

-- Recovery button: only for a recoverable pause, always behind one confirmation.
x,f=setup()
local function hasRecover(frame) for _,b in ipairs(frame.menuButtonInfo) do if b.inputAction==InputAction.MENU_EXTRA_2 then return b end end end
check("broker UI: no recovery button for a healthy Broker",hasRecover(f)==nil)
RLBrokerGameBinding.recoverable=true;f:refresh()
local button=hasRecover(f)
check("broker UI: recovery button offered for a recoverable pause",button~=nil and button.text=="rl_broker_recover")
button.callback()
check("broker UI: recovery asks first and changes nothing before the answer",YesNoDialog.text=="rl_broker_recover_confirm" and RLBrokerGameBinding.recovered==nil)
answer(false)
check("broker UI: declining recovery does nothing",RLBrokerGameBinding.recovered==nil)
button.callback();local lateArgs=YesNoDialog.args;f:onFrameClose();answer(true)
check("broker UI: a late recovery answer after the page closed does nothing",RLBrokerGameBinding.recovered==nil)
f:onFrameOpen();button=hasRecover(f);button.callback();answer(true)
check("broker UI: confirmed recovery runs once and reports success",RLBrokerGameBinding.recovered==1 and InfoDialog.last=="rl_broker_recovered")
RLBrokerGameBinding.recoverResult=false;RLBrokerGameBinding.recoverReason="BROKER_RECOVERY_RELOAD_REQUIRED"
button=hasRecover(f);button.callback();answer(true)
check("broker UI: refused recovery shows its reason",InfoDialog.last=="rl_broker_reason_BROKER_RECOVERY_RELOAD_REQUIRED")
RLBrokerGameBinding.recoverable=nil
