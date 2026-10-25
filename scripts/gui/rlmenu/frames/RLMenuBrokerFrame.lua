-- Local UI for the single-player pickup scope. All money/eligibility comes
-- from the server assembly; only an explicit single-head confirmation mutates.
RLMenuBrokerFrame = {}
local F=RLMenuBrokerFrame
local mt=Class(F,TabbedMenuFrameElement)
local directory=g_currentModDirectory
local function tr(key) return g_i18n:getText("rl_broker_"..key) end
local function money(value) return g_i18n:formatMoney(value,2,true,true) end
local function reason(code)
    local key="rl_broker_reason_"..tostring(code):gsub("[^%w_]","_")
    if g_i18n:hasText(key) then return g_i18n:getText(key) end
    return tr("unavailable").." ("..tostring(code)..")"
end
local function set(element,text) if element then element:setText(text or "") end end
function F.new()
    local self=F:superClass().new(nil,mt)
    self.name="RLMenuBrokerFrame"
    self.hasCustomMenuButtons=true
    self.menuButtonInfo={{inputAction=InputAction.MENU_BACK}}
    return self
end
function F.setupGui()
    g_gui:loadGui(Utils.getFilename("gui/rlmenu/brokerFrame.xml",directory),"RLMenuBrokerFrame",F.new(),true)
end
function F:initialize() self.orders,self.animals={},{};self.serial=0 end
function F:onFrameOpen()
    F:superClass().onFrameOpen(self)
    self.isFrameOpen=true;self.serial=(self.serial or 0)+1
    self:refresh()
    FocusManager:setFocus(self.orderSelector)
end
function F:onFrameClose()
    self.isFrameOpen=false;self.serial=(self.serial or 0)+1;self.pending=nil
    F:superClass().onFrameClose(self)
end
function F:refresh()
    self.runtime=RLBrokerRuntime.current
    local r=self.runtime
    self.orders=r and r:listOrders() or {}
    self.animals=r and r:listAnimals() or {}
    self.orders=self.orders or {}
    local orderTexts,animalTexts={},{}
    for i,o in ipairs(self.orders) do
        orderTexts[i]=string.format(tr("order_name"),o.quantityTotal)
    end
    for i,a in ipairs(self.animals) do
        animalTexts[i]=string.format("%s — %.1f / %.1f kg",a.label,a.ageMonths,a.weightKg or 0)
    end
    self.orderIndex=math.min(self.orderIndex or 1,math.max(1,#self.orders))
    self.animalIndex=math.min(self.animalIndex or 1,math.max(1,#self.animals))
    self.orderSelector:setTexts(#orderTexts>0 and orderTexts or {tr("no_orders")})
    self.animalSelector:setTexts(#animalTexts>0 and animalTexts or {tr("no_animals")})
    self.orderSelector:setState(self.orderIndex,false)
    self.animalSelector:setState(self.animalIndex,false)
    self.orderSelector:setDisabled(#self.orders==0)
    self.animalSelector:setDisabled(#self.animals==0)
    self:showSelection()
end
function F:onOrderChanged(state) self.orderIndex=state;self:showSelection() end
function F:onAnimalChanged(state) self.animalIndex=state;self:showSelection() end
function F:request()
    local o,a=self.orders[self.orderIndex],self.animals[self.animalIndex]
    if not o or not a then return nil end
    return {orderId=o.orderId,animalKey=a.animalKey,sourceRef=a.sourceRef,transportMode="PICKUP"}
end
function F:showSelection()
    self.pending=nil;self.qualified=false
    local r,o=self.runtime,self.orders[self.orderIndex]
    set(self.conditionsText,tr("conditions"))
    set(self.priceText,"");set(self.diagnosticsText,"")
    local state
    if r then
        state=r.reason
        if not state and not RLBrokerRuntime.isEnabled() then state="BROKER_DISABLED" end
        if not state and r.state~="READY" then state=r.state end
    else state=RLBrokerGameBinding.disabledReason or "BROKER_INITIALIZING" end
    set(self.statusText,state and reason(state) or tr("ready"))
    if o then
        local q=o.remaining or {}
        local e=r.mission.environment
        local remainingDays=(e.daysPerPeriod or 1)-(e.currentDayInPeriod or 1)+1
        set(self.orderText,string.format(tr("capacity"),q.order or 0,q.species or 0,q.breed or 0).."\n"..
            string.format(tr("expires"),remainingDays))
    else set(self.orderText,tr("no_orders")) end
    local req=self:request()
    if req and r then
        local detail,why=r:preflight(req)
        if detail then
            local lines={}
            for _,check in ipairs(detail.eligibility.checks) do
                if check.status~="PASS" then
                    local field=check.code:match("^condition:%d+:(.*)$") or check.code
                    local key="rl_broker_check_"..field:gsub("[^%w_]","_")
                    local label=g_i18n:hasText(key) and g_i18n:getText(key) or field
                    local actual=check.actual
                    if type(actual)=="boolean" then actual=actual and tr("yes") or tr("no") end
                    if type(actual)=="table" then actual=nil end
                    lines[#lines+1]=label..": "..(check.status=="UNKNOWN" and tr("unknown") or tr("rejected"))..
                        (actual~=nil and " ("..tostring(actual)..")" or "")
                end
            end
            self.qualified=detail.eligibility.eligible and detail.price and detail.price.pickupAvailable==true
            local diagnostic=detail.price and (detail.price.pickupAvailable and tr("eligible") or reason("NONPOSITIVE_BROKER_NET"))
                or reason(detail.priceReason)
            set(self.diagnosticsText,#lines>0 and table.concat(lines,"\n") or diagnostic)
            if detail.price then
                local p=detail.price
                set(self.priceText,string.format(tr("price"),money(p.pickup.bodyAmount),money(p.pickup.totalFees-p.pickupFee),
                    money(p.pickupFee),money(p.pickup.netToPlayer)).."\n"..tr("conservative"))
            end
        else set(self.diagnosticsText,reason(why)) end
    end
    self.menuButtonInfo={{inputAction=InputAction.MENU_BACK},
        {inputAction=InputAction.MENU_EXTRA_1,text=tr("refresh"),callback=function() self:refresh() end}}
    if RLBrokerGameBinding.canRecover() then
        self.menuButtonInfo[#self.menuButtonInfo+1]={inputAction=InputAction.MENU_EXTRA_2,text=tr("recover"),callback=function() self:onRecover() end}
    end
    if self.qualified and r:ready() then
        self.menuButtonInfo[#self.menuButtonInfo+1]={inputAction=InputAction.MENU_ACCEPT,text=tr("pickup"),callback=function() self:onPickup() end}
    end
    self:setMenuButtonInfoDirty()
end
function F:onPickup()
    if not self.isFrameOpen or self.pending or not self.runtime then return end
    local req=self:request();if not req then return end
    local quote,why=self.runtime:preview(req)
    if not quote then InfoDialog.show(reason(why));self:refresh();return end
    self.pending={quote=quote,runtime=self.runtime,serial=self.serial}
    local a=self.animals[self.animalIndex]
    YesNoDialog.show(self.onConfirmed,self,string.format(tr("confirm"),a.label,money(quote.money.netToPlayer)),tr("title"),
        nil,nil,nil,nil,nil,self.pending)
end
function F:onRecover()
    if not self.isFrameOpen or self.pending or not RLBrokerGameBinding.canRecover() then return end
    YesNoDialog.show(self.onRecoverConfirmed,self,tr("recover_confirm"),tr("title"),nil,nil,nil,nil,nil,self.serial)
end
function F:onRecoverConfirmed(confirmed,serial)
    if not confirmed or not self.isFrameOpen or serial~=self.serial then return end
    local ok,why=RLBrokerGameBinding.recover()
    InfoDialog.show(ok and tr("recovered") or reason(why))
    self:refresh()
end
function F:onConfirmed(confirmed,pending)
    if not pending or self.pending~=pending then return end
    self.pending=nil
    if not confirmed or not self.isFrameOpen or pending.serial~=self.serial
        or pending.runtime~=RLBrokerRuntime.current then return end
    local result,why=pending.runtime:confirm(pending.quote)
    if result and result.status=="COMMITTED" then InfoDialog.show(tr("sold"))
    else InfoDialog.show(reason(result and result.reason or why)) end
    self:refresh()
end
