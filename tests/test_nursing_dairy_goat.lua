-- Unified nursing, batch D (2026-10-22 design): dairy goats run the mode on their own GOAT sections, as
-- DAIRY_MILK dams - a doe's milk is her productivity gene x lactation x her budget; her kids drink their own
-- demand first and only the rest goes to the goat milk store. Sheep and goats share a pen without either
-- leaving the mode, each on its own values. Matrix cases D01, D04, G02 (dairy cattle: test_feed_dam).

loadMod("tests/sheepsim.lua")

FeedSim.setMode(true)
SheepSim.enable(true)
GrowthSim.setDaysPerPeriod(1)
local FILL = FeedSim.FILL
local function near(a, b, eps) return a ~= nil and b ~= nil and math.abs(a - b) <= (eps or 1e-9) end

-- Goat milk is sold in pallets (animals.xml GOAT output pallets GOATMILK): the curve as the game gives it.
FILL.GOATMILK = FILL.GOATMILK or 90
local names = {}
local baseName = g_fillTypeManager.getFillTypeNameByIndex
g_fillTypeManager.getFillTypeNameByIndex = function(m, i) if i == FILL.GOATMILK then return "GOATMILK" end return baseName(m, i) end
Animal.LACTATION_PALLET_FILL_TYPE_NAMES = Animal.LACTATION_PALLET_FILL_TYPE_NAMES or { GOATMILK = true, MILK = true, BUFFALOMILK = true }
Animal.isLactationPalletFillType = Animal.isLactationPalletFillType or function(i)
    local name = i ~= nil and g_fillTypeManager:getFillTypeNameByIndex(i) or nil
    return name ~= nil and Animal.LACTATION_PALLET_FILL_TYPE_NAMES[name] == true
end
local goatCurve = { { 0, 0 }, { 6, 0 }, { 6, 5 }, { 18, 25 } }
for _, name in ipairs({ "GOAT", "RAM_GOAT" }) do
    local _, sub = Economics.find(name)
    sub.output = { pallets = { fillType = FILL.GOATMILK, curve = { get = function(_, age) return Economics.curve(goatCurve, age) end } } }
end

local function doe(id, productivity, fields)
    local f = { age = 36, isParent = true, isLactating = true, monthsSinceLastBirth = 1 }
    for k, v in pairs(fields or {}) do f[k] = v end
    local d = SheepSim.identify((GrowthSim.makeAnimal("GOAT", f)), id)
    d.genetics.productivity = productivity or 1
    return d
end
local function kid(motherId, id, name) return SheepSim.lamb(name or "GOAT", motherId, id) end

--- One hour as the game runs it: each doe's milk at full feed recorded for her budget first
--- (Animal:updateOutput -> RLBodyCondition.applyMilk), then the pen's feeding.
local function hour(pen, stock)
    for _, a in ipairs(pen.animals) do
        if a.subType == "GOAT" and a.isLactating then
            local curve = Economics.curve(goatCurve, 60)
            local m = a.monthsSinceLastBirth or 0
            local lactation = m >= 10 and 0 or (m <= 3 and 0.8 + m / 6 or 0.8 + (11 - m) / 15)
            RLBodyCondition.applyMilk(a, curve * lactation * (a.genetics.productivity or 0), curve, 1)
        end
    end
    if stock ~= nil then FeedSim.keepStocked(stock)(pen) end
    FeedSim.hour(pen)
end
local STOCK = { DRYGRASS_WINDROW = 3000, GRASS_WINDROW = 3000 }

check("goat: covered on its own GOAT feed and body sections, as DAIRY_MILK",
    RLGrowth.covers(doe("X0")) and RLFeed.getConfig(doe("X1")) == RLFeedProfiles.getConfig().species.GOAT
    and RLFeed.getRearingMode(doe("X2")) == "DAIRY_MILK" and not RLFeed.pairsYoung(doe("X3")))


-- D01: kids first, the rest collectable ----------------------------------------------------------------

do
    local d = doe("D1", 1.4)
    local k1, k2 = kid("D1", "K1"), kid("D1", "K2", "RAM_GOAT")
    local pen = SheepSim.makePen({ d, k1, k2 }, STOCK)
    for _ = 1, 6 do hour(pen, STOCK) end
    local r = d.rlFeedIntake
    check(string.format("D01 kids first: a well-fed doe gives her kids their demand (%.3f / %.3f of it) and keeps %.3f L for the store",
        k1.rlNutrition.nursingCoverage or -1, k2.rlNutrition.nursingCoverage or -1, r.milkLiters),
        (k1.rlNutrition.nursingCoverage or 0) > 0.98 and (k2.rlNutrition.nursingCoverage or 0) > 0.98
        and (r.milkToCalves or 0) > 0 and r.milkLiters > 0)
    check("D01 conservation: what she paid = what her kids drank + what is collectable (nothing counted twice)",
        near(r.milkPaidLiters, (r.milkToCalves or 0) + r.milkLiters, 1e-9) and d.rlMilkPaid.litersPerHour >= 0)
    local perLiter = RLFeed.getMilkRealPerGameLiter(d) * RLFeed.getConfig(d).damMilk.dm
    check(string.format("D01 units: the liters to her kids are their real goat milk DM through her own bridge (%.6f vs %.6f)",
        (r.milkToCalves or 0) * perLiter, k1.rlFeedIntake.damMilkKg + k2.rlFeedIntake.damMilkKg),
        near((r.milkToCalves or 0) * perLiter, k1.rlFeedIntake.damMilkKg + k2.rlFeedIntake.damMilkKg, 1e-9))

    local low = doe("D2", 0.25)
    local l1, l2 = kid("D2", "K3"), kid("D2", "K4")
    local lowPen = SheepSim.makePen({ low, l1, l2 }, STOCK)
    for _ = 1, 6 do hour(lowPen, STOCK) end
    check(string.format("D01 short: a low-yield doe's twins share what she gives (%.3f / %.3f of their demand), nothing collectable",
        l1.rlNutrition.nursingCoverage or -1, l2.rlNutrition.nursingCoverage or -1),
        (l1.rlNutrition.nursingCoverage or 1) < 0.95 and near(l1.rlNutrition.nursingCoverage, l2.rlNutrition.nursingCoverage, 2e-3)
        and low.rlFeedIntake.milkLiters <= 1e-9)
end


-- G02: the milk gene sets the potential; feed sets what she gives --------------------------------------

do
    local function run(p, stock, hours)
        local d = doe("G" .. tostring(p) .. tostring(stock ~= nil), p)
        local pen = SheepSim.makePen({ d }, stock or {})
        for _ = 1, hours do hour(pen, stock) end
        return d.rlFeedIntake
    end
    local low, high = run(0.5, STOCK, 3), run(1.6, STOCK, 3)
    check(string.format("G02 fed: the milk gene raises her milk (%.3f -> %.3f L paid an hour)", low.milkPaidLiters, high.milkPaidLiters),
        high.milkPaidLiters > 1.5 * low.milkPaidLiters)
    local SHORT = { DRYGRASS_WINDROW = 6 }
    local lowS, highS = run(0.5, SHORT, 12), run(1.6, SHORT, 12)
    check(string.format("G02 short ration: no free milk from the gene - paid share of potential %.2f (gene 0.5) vs %.2f (gene 1.6)",
        lowS.milkPaidLiters / math.max(lowS.milkPotential, 1e-9), highS.milkPaidLiters / math.max(highS.milkPotential, 1e-9)),
        highS.milkPaidLiters / highS.milkPotential < lowS.milkPaidLiters / math.max(lowS.milkPotential, 1e-9) + 1e-9
        and highS.milkPaidLiters < highS.milkPotential)
    local buck = SheepSim.identify((GrowthSim.makeAnimal("RAM_GOAT", { age = 24 })), "B1")
    buck.genetics.productivity = 1.7
    check("G02 buck: a dairy buck carries the milk gene (he passes it on) and gives no milk",
        RLRearingPolicy.hasTrait(buck:getSubType(), "productivity") and RLFeed.getRationClass(buck) == "GROWING")
end


-- D04: sheep and goats in one pen ----------------------------------------------------------------------------

do
    local ewe = SheepSim.ewe("SHEEP_LANDRACE", "M1", { monthsSinceLastBirth = 0 })
    local lamb = SheepSim.lamb("SHEEP_LANDRACE", "M1", "ML")
    local d = doe("M2", 1.2)
    local k = kid("M2", "MK")
    local pen = SheepSim.makePen({ ewe, lamb, d, k }, STOCK)
    for _ = 1, 6 do hour(pen, STOCK) end
    check("D04 mixed pen: sheep and goats keep the pen in the mode, each on its own section",
        pen.spec_husbandryFood.rlFeedPen.active == true and RLFeed.getConfig(ewe) == RLFeedProfiles.getConfig().species.SHEEP
        and RLFeed.getConfig(d) == RLFeedProfiles.getConfig().species.GOAT)
    check(string.format("D04 ewe: pays her lamb's demand (%.3f), nothing saleable", ewe.rlNutrition.nursingCoverage or -1),
        (ewe.rlNutrition.nursingCoverage or 0) > 0.95 and ewe.rlFeedIntake.milkLiters == 0 and lamb.rlFeedIntake.damMilkKg > 0)
    check("D04 doe: her kid drinks first, the rest of her milk is collectable",
        (k.rlNutrition.nursingCoverage or 0) > 0.95 and d.rlFeedIntake.milkLiters > 0)
    local lambMilk = lamb.rlFeedIntake.damMilkKg
    check("D04 each dam's own milk: the lamb's milk at the ewe's ME, the kid's at the doe's (no shared pool)",
        lambMilk > 0 and k.rlFeedIntake.damMilkKg > 0 and RLFeedProfiles.getConfig().species.SHEEP.damMilk.me ~= RLFeedProfiles.getConfig().species.GOAT.damMilk.me)
end

-- Both nutrition-coverage ewes and dairy goats recover in the first step after zero.
for _, species in ipairs({"SHEEP", "GOAT"}) do
    local d = species == "GOAT" and doe("ZERO",1.2) or SheepSim.ewe("SHEEP_LANDRACE","ZERO",{monthsSinceLastBirth=0})
    local k = species == "GOAT" and kid("ZERO","ZERO-K") or SheepSim.lamb("SHEEP_LANDRACE","ZERO","ZERO-K")
    local pen = SheepSim.makePen({k,d},STOCK)
    hour(pen,STOCK)
    d.rlFeedLastMilk.share=0
    local first
    local function observe(kind,data) if kind=="STEP" and first==nil then first=data end end
    RLFeed.addObserver(observe);hour(pen,STOCK);RLFeed.removeObserver(observe)
    local got=0
    for _,e in ipairs(first.animals) do if e.animal==k then got=e.feed.damMilk and e.feed.damMilk.kg or 0 end end
    check(species.." zero recovery: paid milk reaches the young in the same step",
        #first.dams==1 and first.dams[1].paidKg>0 and got>0 and near(got,first.dams[1].allocatedKg))
end

SheepSim.enable(false)
