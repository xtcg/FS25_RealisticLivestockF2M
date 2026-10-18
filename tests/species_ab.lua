-- Every type but cattle on the shipped config (sheep v2 off), for an exact A/B against an earlier
-- tree (tests/species_ab.py): pigs, goats, horses, chickens and sheep of each subtype at three
-- ages, under the old and the real-equivalent nutrition mode, on a poor and a full food factor,
-- through AnimalHealth.updateHealth for two game days; and whether a pen of each runs the mode.
-- Uses only APIs both trees have.
loadMod("tests/feedsim.lua")

AB_ROWS = {}

local subs = {}
for _, sub in ipairs(Economics.subTypes) do
    if sub.typeName ~= "COW" then subs[#subs + 1] = sub end
end
table.sort(subs, function(a, b) return a.name < b.name end)

for _, mode in ipairs({ "legacy", "real" }) do
    FeedSim.setMode(mode == "real")
    for _, sub in ipairs(subs) do
        for _, age in ipairs({ 1, 6, 30 }) do
            for _, food in ipairs({ 0.3, 1.0 }) do
                GrowthSim.setDaysPerPeriod(1)
                local animal = GrowthSim.makeAnimal(sub.name, { age = age, isParent = age >= 30 and sub.gender == "female" })
                local pen = FeedSim.makePen({ animal })
                function pen:getAnimalTypeIndex() return sub.typeIndex end
                local case = table.concat({ mode, sub.name, age, food }, "/")
                local active, reason = RLFeed.evaluatePen(pen)
                AB_ROWS[#AB_ROWS + 1] = { case = case .. "/pen", active = active, reason = reason, covered = RLGrowth.covers(animal) }
                for hour = 1, 48 do
                    GrowthSim.advanceHour()
                    AnimalHealth.updateHealth(animal, food)
                    if hour % 12 == 0 then
                        AB_ROWS[#AB_ROWS + 1] = { case = case .. "/h" .. hour, weight = animal.weight, health = animal.health,
                            target = animal.targetWeight or -1, reserve = animal.bodyCondition ~= nil and animal.bodyCondition.reserve or -1,
                            growth = animal.rlGrowth ~= nil and animal.rlGrowth.developmentMonths or -1 }
                    end
                end
            end
        end
    end
end
FeedSim.setMode(false)
