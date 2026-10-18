-- DAM-LACTATING-FLAG-01 (2026-10-18): isLactating is the game's milk flag (cattle and goats in milk:
-- saleable milk, the cattle feed class, the mastitis prerequisite); a ewe or a sow is never set lactating
-- by a birth, and so never gives saleable milk. Whether a dam nurses young now is RLFeed.getNursingState /
-- Animal:getIsNursing: a ewe whose lambs on milk are with her (the milk her budget pays), a sow with her
-- unweaned litter (shown only: no sow milk is modelled). The monitor shows that for ewes and sows.

loadMod("tests/pigsim.lua")
loadMod("tests/sheepsim.lua")
loadAnimalSection("function Animal:getIsNursing", "function Animal:isCattleMilkOutput")
FeedSim.setMode(true)
SheepSim.enable(true)
PigSim.enable(true)

check("birth rule: only cattle and goats start the milk flag at birth (a ewe or sow never)",
    RLLactation.startsAtBirth(AnimalType.COW, "COW_ANGUS") and RLLactation.startsAtBirth(SheepSim.TYPE, "GOAT")
    and not RLLactation.startsAtBirth(SheepSim.TYPE, "SHEEP_LANDRACE") and not RLLactation.startsAtBirth(PigSim.TYPE, "PIG_LANDRACE"))

-- A ewe with her lamb on milk: nursing, not in milk.
local ewe = SheepSim.ewe("SHEEP_LANDRACE", "EW1", { monthsSinceLastBirth = 0 })
local lamb = SheepSim.lamb("SHEEP_LANDRACE", "EW1", "LB1")
local pen = SheepSim.makePen({ ewe, lamb }, {})
local nursing, kind = RLFeed.getNursingState(ewe)
check("ewe: with her lamb on milk she is nursing (NURSING), her milk flag stays false, no saleable milk factor",
    nursing == true and kind == "NURSING" and ewe.isLactating == false and ewe:getIsNursing() == true and ewe:getLactationFactor() == 0)
check("ewe: her feed class is LACTATING by her lambs, not by the flag", RLFeed.getRationClass(ewe) == "LACTATING")
pen.animals = { ewe }
ewe.clusterSystem = { owner = pen }
ewe.rlFeedNursingDams = nil
pen.rlFeedNursingDams = nil
check("ewe: her lamb taken away, she is not nursing", RLFeed.getNursingState(ewe) == false and ewe:getIsNursing() == false)

-- A sow with her litter under 28 days: suckling (shown), no milk made.
local sow = PigSim.grown("PIG_LANDRACE", 1, 18, { isParent = true, monthsSinceLastBirth = 0 })
local piglet = PigSim.grown("PIG_LANDRACE", 2, 0.3, { motherId = 1 })
local older = PigSim.grown("PIG_LANDRACE", 3, 2, { motherId = 1 })
local pigPen = PigSim.makePen({ sow, piglet }, {})
local sowNursing, sowKind = RLFeed.getNursingState(sow)
check("sow: with her unweaned litter she is shown nursing (SUCKLING), milk flag false, no milk factor",
    sowNursing == true and sowKind == "SUCKLING" and sow.isLactating == false and sow:getLactationFactor() == 0)
pigPen.animals = { sow, older }
for _, a in ipairs(pigPen.animals) do a.clusterSystem = { owner = pigPen } end
check("sow: with only weaned (2-month) pigs of hers, not nursing", RLFeed.getNursingState(sow) == false)

-- A cow in milk: the flag itself.
local cow = GrowthSim.makeAnimal("COW_ANGUS", { age = 40, isParent = true, isLactating = true, monthsSinceLastBirth = 2 })
local cowNursing, cowKind = RLFeed.getNursingState(cow)
check("cow: in milk is the flag (MILK)", cowNursing == true and cowKind == "MILK" and cow:getIsNursing() == true)
check("a ram or a maiden ewe is never nursing", RLFeed.getNursingState(SheepSim.grown("RAM_LANDRACE", "RM", 20)) == false
    and RLFeed.getNursingState(SheepSim.grown("SHEEP_LANDRACE", "MD", 14)) == false)

SheepSim.enable(false)
PigSim.enable(false)
FeedSim.setMode(false)
