loadMod("tests/feedsim.lua")
local pen=FeedSim.makePen({}, {FORAGE=1000,DRYGRASS_WINDROW=1000})
function pen:getTotalFood()
    local total=0;for _,level in pairs(self.spec_husbandryFood.fillLevels)do total=total+level end;return total
end
local totalFood=pen:getTotalFood()
local I=RLFeedInfoService
local original=I.buildFeedRows
local builds=0
I.buildFeedRows=function(...)builds=builds+1;return original(...)end
local first=I.getFeedRows(pen)
check("feed cache: unchanged inputs reuse rows",I.getFeedRows(pen)==first and builds==1)
local fill=FeedSim.FILL
pen.spec_husbandryFood.fillLevels[fill.FORAGE]=900
pen.spec_husbandryFood.fillLevels[fill.DRYGRASS_WINDROW]=1100
local second=I.getFeedRows(pen)
local stock={};for _,row in ipairs(second)do stock[row.name]=row.stock end
check("feed cache: equal-total stock swap refreshes individual rows",pen:getTotalFood()==totalFood and second~=first and builds==2 and stock.FORAGE==900 and stock.DRYGRASS_WINDROW==1100)
local available=pen.getAvailableFood
pen.getAvailableFood=function(self,index)return (available(self,index) or 0)+(index==fill.DRYGRASS_WINDROW and 50 or 0)end
local third=I.getFeedRows(pen)
check("feed cache: meadow availability without trough change invalidates",third~=second and builds==3)
pen.spec_husbandryFood.capacity=(pen.spec_husbandryFood.capacity or 0)+1
local fourth=I.getFeedRows(pen)
check("feed cache: capacity change invalidates",fourth~=third and builds==4)
pen.spec_husbandryFood.rlFeedMonth={hours=1,byFill={}}
local fifth=I.getFeedRows(pen)
pen.spec_husbandryFood.rlFeedMonth.hours=2
check("feed cache: in-place month progress invalidates",I.getFeedRows(pen)~=fifth and builds==6)
local sixth=I.getFeedRows(pen)
check("feed cache: refreshed inputs are cached again",I.getFeedRows(pen)==sixth and builds==6)
