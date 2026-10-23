-- The previous step may have paid exactly zero. Recovery uses this step's payment,
-- even with no predicted dam milk; trough top-ups still leave only the remaining room.
loadMod("tests/feedsim.lua")
FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(1)
local function identify(a,id) a.id=id; a.getIdentifiers=function(self) return self.id end; return a end
for _, breed in ipairs({"ANGUS", "HOLSTEIN"}) do
    for _, trough in ipairs({0, 0.1, 100000}) do
        local cow=identify((GrowthSim.makeAnimal("COW_"..breed,
            {age=48,isParent=true,isLactating=true,monthsSinceLastBirth=1})),"DAM")
        local calves={}
        for i=1,2 do calves[i]=identify(GrowthSim.newborn("BULL_"..breed,{motherId="DAM"}),"C"..i) end
        -- Young before mother also exercises the settlement ordering for zero predictions.
        local pen=FeedSim.makePen({calves[2],cow,calves[1]},{FORAGE=1e5})
        FeedSim.hour(pen)
        cow.rlFeedLastMilk.share=0
        pen:add("CALFMILK",trough)
        local first
        local function observe(kind,data) if kind=="STEP" and first==nil then first=data end end
        RLFeed.addObserver(observe)
        FeedSim.hour(pen)
        RLFeed.removeObserver(observe)
        local received,demand,room,paid,allocated=0,0,0,0,0
        local ratios={}
        for _,e in ipairs(first.animals) do
            if e.animal~=cow then
                local milk=e.feed.damMilk and e.feed.damMilk.kg or 0
                received=received+milk; demand=demand+(e.feed.nursingDemandKg or 0)
                local troughKg=0
                for name,fill in pairs(e.feed.byFill) do
                    if name=="CALFMILK" then troughKg=troughKg+fill.kg end
                end
                room=room+math.max(e.feed.nursingDemandKg-troughKg,0)
                ratios[#ratios+1]=milk/e.feed.nursingDemandKg
            end
        end
        for _,d in ipairs(first.dams) do paid=paid+d.paidKg; allocated=allocated+d.allocatedKg end
        local label=breed.." zero recovery, trough "..trough
        check(label..": mother settles in the first recovered step",#first.dams==1 and paid>0)
        check(label..": available milk reaches the young within their remaining room",
            math.abs(received-math.min(paid,room))<1e-8 and (trough>1 or received>0))
        check(label..": twins share a ratio and the payment closes",
            math.abs(ratios[1]-ratios[2])<1e-8 and math.abs(received-allocated)<1e-8 and received<=paid+1e-8)
    end
end
