loadMod("scripts/gui/rlmenu/services/RLAnimalBuyService.lua")
loadMod("scripts/gui/rlmenu/frames/RLMenuBuyFrame.lua")
local asks,dialogs,notices={},0,0
RLDealerQualityResolver={getMarkup=function()return 1 end}
RLAnimalBuyService.computeBuyPrice=function(a)return asks[a.uniqueId]end
local function animal(id,fee)
    return {farmId="1",uniqueId=id,birthday={country=1},subTypeIndex=1,age=12,
        getTranportationFee=function()return fee end}
end
local a,b=animal("a",2),animal("b",3)
RLSelectionKey={build=function(f,id,c)return f.." "..id.." "..c end}
g_currentMission={getHasPlayerPermission=function()return true end}
g_i18n={getText=function(_,key)return key end,formatMoney=function(_,value)
    assert(type(value)=="number" and value==value and math.abs(value)<math.huge,"UI_FORMATTED_UNAVAILABLE_MONEY")
    return tostring(value)
end}
InfoDialog={show=function(text)assert(text=="rl_ui_priceUnavailable");notices=notices+1 end}
YesNoDialog={show=function()dialogs=dialogs+1 end}
local values={}
local function cell(key)return {setText=function(_,text)values[key]=text end}end
local frame=setmetatable({sortedTypes={1},items={{cluster=a},{cluster=b}},sectionOrder={"s"},
    itemsBySection={s={{cluster=a},{cluster=b}}},selectedAnimals={["1 a 1"]=true,["1 b 1"]=true},
    getSelectedCount=function()return 2 end,getSelectedAnimal=function()return a end,getTrailerDealerContext=function()return nil end,setMenuButtonInfoDirty=function()end,
    backButtonInfo={},filterButtonInfo={},cycleFilterButtonInfo={},selectButtonInfo={},selectAllButtonInfo={},buySelectedButtonInfo={},buyButtonInfo={},
    cartCountValue=cell("count"),cartPriceValue=cell("price"),cartFeeValue=cell("fee"),cartTotalValue=cell("total")},{__index=RLMenuBuyFrame})
asks.b=20
local price,fee,count=frame:computeCartTotals()
check("market buy UI: one unavailable ASK invalidates whole cart, retains selection count",price==nil and fee==nil and count==2)
frame:updateCartDisplay()
check("market buy UI: unavailable amounts display dash without fake zero money",values.count=="2" and values.price=="-" and values.fee=="-" and values.total=="-")
frame:updateButtonVisibility()
check("market buy UI: single and batch buttons disabled for unavailable selection",frame.buyButtonInfo.disabled and frame.buySelectedButtonInfo.disabled)
frame.pendingBuyPrice=999;frame:onClickBuy()
check("market buy UI: stale single click clears pending state and opens no confirmation",notices==1 and dialogs==0 and frame.pendingBuyPrice==nil and frame.pendingBuyAnimals==nil)
frame.pendingBuyPrice=999;frame:onClickBuySelected()
check("market buy UI: stale bulk click clears pending state and opens no confirmation",notices==2 and dialogs==0 and frame.pendingBuyPrice==nil)
asks.a=30
price,fee,count=frame:computeCartTotals()
check("market buy UI: available cart uses independent ASK sum and one fee per head",price==50 and fee==5 and count==2)
frame:updateCartDisplay();frame:updateButtonVisibility()
check("market buy UI: valid prices restore visible totals and purchase actions",values.price=="50" and values.fee=="5" and values.total=="55" and not frame.buyButtonInfo.disabled and not frame.buySelectedButtonInfo.disabled)
frame:onClickBuySelected()
check("market buy UI: valid batch confirms exactly displayed amounts",dialogs==1 and frame.pendingBuyPrice==50 and frame.pendingBuyFee==5 and #frame.pendingBuyAnimals==2)
frame.getTrailerDealerContext=function()return {}end
price,fee,count=frame:computeCartTotals();frame:onClickBuySelected()
check("market buy UI: trailer cart and confirmation omit external delivery leg",price==50 and fee==0 and frame.pendingBuyPrice==50 and frame.pendingBuyFee==0 and dialogs==2)
AnimalBuyEvent={BUY_ERROR_PRICE_UNAVAILABLE=9,BUY_ERROR_ANIMAL_NOT_SUPPORTED=4,getPenErrorCode=function()return nil end}
RLTrailerEndpointService={hasRoom=function(free,n)return free>n end}
asks.a=nil
local validations=0
local filtered=RLAnimalBuyService.filterBuyableAnimals({getNumOfFreeAnimalSlots=function()return 2 end},{a,b},1,function()
    validations=validations+1;return nil
end)
check("market buy UI: unavailable trailer item is rejected before numeric validation",#filtered.valid==1 and filtered.valid[1]==b and #filtered.rejected==1 and filtered.firstErrorCode==9 and validations==1)

-- The destination step sends the price the player confirmed when every animal fits (2026-10-24: a quote that
-- moved a unit while a dialog was open is charged as confirmed, AnimalBuyEvent.QUOTE_TOLERANCE); a partial
-- buy prices the valid subset and shows it in its confirmation.
do
    local sent, asked = nil, 0
    YesNoDialog={show=function()asked=asked+1 end}
    InfoDialog={show=function()end}
    g_currentMission.animalSystem={getSubTypeByIndex=function()return {typeIndex=1}end}
    local rejected={}
    RLAnimalMoveService={buildMoveValidationResult=function(animals)return {valid=animals,rejected=rejected}end}
    RLAnimalBuyService.computeBulkTotal=function(list)return 1065.3,90,1155.3,#list end
    RLAnimalBuyService.buildPartialConfirmationText=function()return "partial" end
    local f=setmetatable({dispatchPendingBuy=function(self)sent={self.pendingBuyPrice,self.pendingBuyFee}end},{__index=RLMenuBuyFrame})
    f.pendingBuyAnimals={a};f.pendingBuyPrice=1062.1;f.pendingBuyFee=90
    f:onBuyDestinationSelected({placeable={},name="pen"})
    check("confirmed price: all fit, the confirmed 1062.1 + 90 is sent, no second question",sent~=nil and sent[1]==1062.1 and sent[2]==90 and asked==0)
    rejected={{animal=b,reason="FULL"}}
    f.pendingBuyAnimals={a,b};f.pendingBuyPrice=2000;f.pendingBuyFee=180
    f:onBuyDestinationSelected({placeable={},name="pen"})
    check("confirmed price: some rejected, the valid subset is priced now and confirmed",asked==1 and f.pendingBuyPrice==1065.3)
end
