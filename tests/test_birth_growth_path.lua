loadMod("tests/growthsim.lua")
loadMod("scripts/animal/RLBirthWeight.lua")
local f = assert(io.open(REPO .. "scripts/animal/AnimalReproduction.lua", "r"))
local source = f:read("*a")
f:close()
local start = assert(source:find("        local genetics = child.genetics", 1, true))
local finish = assert(source:find("        child:setBirthday", start, true))
local block = source:sub(start, finish - 1):gsub("continue", "return child")
local runBirth = assert(load([[return function(child, animal, subType)
    local sireBreed, firstBirth, litterSize = "ANGUS", true, 2
    local i, childNum, animalsToSell, deadChildrenCount = 1, 1, 0, 0
    local childrenToRemove = {}
]] .. block .. [[
    return child
end]]))()

for _, name in ipairs({"COW_HOLSTEIN", "PIG_LANDRACE"}) do
    local child, subtype = GrowthSim.makeAnimal(name)
    local dam, damSubtype = GrowthSim.makeAnimal("COW_HOLSTEIN", {age = 36, deathEnabled = true})
    local growthDraw, fallbackDraw, init = RLGrowth.drawBirthWeight, RLBirthWeight.draw, RLGrowth.initBirth
    local survival, random = RLBirthWeight.getSurvivalChance, math.random
    local growthCalls, fallbackCalls, initialisations, randomCalls, usedWeight, usedZ, survivalZ = 0, 0, 0, 0
    RLGrowth.drawBirthWeight = function(...)
        growthCalls = growthCalls + 1
        local w, z, mean = growthDraw(...)
        usedWeight, usedZ = w, z
        return w, z, mean
    end
    RLBirthWeight.draw = function(...)
        fallbackCalls = fallbackCalls + 1
        local w, z, mean = fallbackDraw(...)
        usedWeight, usedZ = w, z
        return w, z, mean
    end
    RLGrowth.initBirth = function(c, w) initialisations = initialisations + 1; return init(c, w) end
    RLBirthWeight.getSurvivalChance = function(st, health, z)
        survivalZ = z
        return survival(st, health, z)
    end
    math.random = function()
        randomCalls = randomCalls + 1
        if randomCalls == 1 then return math.exp(-1.5^2 / 2) end
        if randomCalls == 2 then return 0.5 end
        return 0.1
    end
    runBirth(child, dam, damSubtype)
    RLGrowth.drawBirthWeight, RLBirthWeight.draw, RLGrowth.initBirth = growthDraw, fallbackDraw, init
    RLBirthWeight.getSurvivalChance, math.random = survival, random
    local v2 = RLGrowth.coversSubType(subtype)
    check(name .. ": exactly two normal-draw uniforms and one survival roll", randomCalls == 3)
    check(name .. ": actual selected model draws once", growthCalls == (v2 and 1 or 0) and fallbackCalls == (v2 and 0 or 1))
    check(name .. ": actual survival receives that draw's z", near(usedZ, -1.5, 1e-9) and usedZ == survivalZ)
    check(name .. ": actual child keeps that draw's weight", child.weight == usedWeight and not child.isDead)
    check(name .. ": actual growth initialisation runs only for v2", initialisations == (v2 and 1 or 0))
    if v2 then
        check(name .. ": actual v2 saved birth and live state match the survival draw",
            child.rlGrowth.source == "birth" and child.rlGrowth.birthWeightKg == usedWeight and child.rlGrowth.weightKg == usedWeight)
    end
end
