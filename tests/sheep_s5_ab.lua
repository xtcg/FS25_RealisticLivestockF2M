-- Run unchanged against both the frozen dev tree and the candidate tree. This probes the
-- real adapters and shared budget for every cattle profile, sex, gene and physiological state.
loadMod("tests/growthsim.lua")
AB_ROWS = {}
local G, config = RLGrowth, RLGrowth.getConfig()
local names = {}
for name, profile in pairs(config.profiles) do
    if profile.typeName == "COW" then names[#names + 1] = name end
end
table.sort(names)
local function numeric(prefix, values, row)
    for key, value in pairs(values or {}) do
        if type(value) == "number" or type(value) == "boolean" or type(value) == "string" then
            row[prefix .. key] = value
        end
    end
end
for _, breed in ipairs(names) do
    for _, sex in ipairs({ "female", "male" }) do
        local name = "S5_AB_" .. breed .. "_" .. sex
        local knots = config.profiles[breed].knots[sex]
        GrowthSim.addSubType(name, breed, sex, knots[#knots][2])
        for _, gene in ipairs({ 0.25, 1, 1.75 }) do
            for _, stage in ipairs({ "young", "pregnant", "lactating" }) do
                local a = GrowthSim.makeAnimal(name, { age = stage == "young" and 2 or 36,
                    isCastrated = sex == "male" and stage ~= "young",
                    genetics = { metabolism = gene, productivity = 1, quality = 1, fertility = 1, health = 1 } })
                a.isParent = stage ~= "young" and sex == "female"
                a.isLactating = stage == "lactating" and sex == "female"
                a.monthsSinceLastBirth = a.isLactating and 0 or 12
                a.rlMilk = { potential = a.isLactating and 600 or 0, anchor = a.isLactating and 600 or 0,
                    lineAnchor = a.isLactating and 600 or 0 }
                if stage == "pregnant" and sex == "female" then
                    a.isPregnant, a.reproduction = true, 80
                    a.pregnancy = { pregnancies = { { getSubType = a.getSubType }, { getSubType = a.getSubType } } }
                end
                local row = { case = breed .. "/" .. sex .. "/" .. gene .. "/" .. stage }
                local drawn, z, mean = G.drawBirthWeight(a:getSubType(),
                    { litterSize = 2, firstBirth = false, metabolism = gene, dam = a }, function() return 0.6 end)
                row.drawn, row.z, row.mean = drawn, z, mean
                for step = 1, 120 do
                    local input = { intakeLiters = G.getReferenceIntake(a) * (stage == "young" and 1 or 0.7), milkShare = 1 }
                    local result, budget = G.advanceBudget(a, input, 1 / 120, step)
                    assert(result ~= nil, row.case)
                    if step == 1 or step == 120 then
                        numeric(step .. ".result.", result, row)
                        numeric(step .. ".input.", budget, row)
                    end
                end
                row.weight, row.target, row.request = a.weight, G.getAnimalTargetWeight(a), G.getReferenceIntake(a)
                row.underweight = G.getUnderweightThreshold(a)
                numeric("state.", a.rlGrowth, row)
                numeric("condition.", a.bodyCondition, row)
                AB_ROWS[#AB_ROWS + 1] = row
            end
        end
    end
end
assert(#AB_ROWS == 396, "expected 22 profiles x 2 sexes x 3 genes x 3 states")
