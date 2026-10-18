-- Exercise the production birth block, including survival and init, rather than
-- testing a separate routing helper that reproduction could accidentally bypass.
local f = assert(io.open(REPO .. "scripts/animal/AnimalReproduction.lua", "r"))
local source = f:read("*a")
f:close()
-- Compile the complete script too; replacing continue is for syntax validation only.
local compileOnly = source:gsub("%f[%a]continue%f[%A]", "break")
check("complete reproduction script has no integration conflict or syntax error", load(compileOnly) ~= nil)
local start = assert(source:find("        local genetics = child.genetics", 1, true))
local finish = assert(source:find("        child:setBirthday", start, true))
local block = source:sub(start, finish - 1):gsub("continue", "return child")
local runBirth = assert(load([[return function(child, animal, subType, sireBreed, firstBirth, litterSize)
    local i, childNum, animalsToSell, deadChildrenCount = 1, 1, 0, 0
    local childrenToRemove = {}
]] .. block .. [[
    return child
end]]))()

local function scenario(name, covered, dead, growthPresent)
    local growthDraws, fallbackDraws, initCalls, survivalZ, seenContext = 0, 0, 0
    local subtype = {breed = "ANGUS"}
    local child = {genetics = {metabolism = 1.2, health = 0.7}, getSubType = function() return subtype end}
    RLGrowth = growthPresent and {
        coversSubType = function(st) return covered and st == subtype end,
        drawBirthWeight = function(st, ctx)
            growthDraws, seenContext = growthDraws + 1, ctx
            return 37.25, -1.75, 45.15
        end,
        initBirth = function(c, weight)
            initCalls = initCalls + 1
            c.rlGrowth = {birthWeightKg = weight, weightKg = weight}
        end,
    } or nil
    RLBirthWeight = {
        draw = function(st, ctx)
            fallbackDraws, seenContext = fallbackDraws + 1, ctx
            return 2.1, -0.6, 2.3
        end,
        getSurvivalChance = function(st, health, z)
            survivalZ = z
            check(name .. " survival receives child's health", health == 0.7 and st == subtype)
            return 0.8
        end,
    }
    local oldRandom = math.random
    math.random = function() return dead and 0.9 or 0.1 end
    runBirth(child, {deathEnabled = true, breed = "HOLSTEIN"}, {breed = "HOLSTEIN"}, "ANGUS", true, 2)
    math.random = oldRandom
    local v2 = covered and growthPresent
    check(name .. " exactly one model draw", growthDraws == (v2 and 1 or 0) and fallbackDraws == (v2 and 0 or 1))
    check(name .. " survival uses the selected draw's z", survivalZ == (v2 and -1.75 or -0.6))
    check(name .. " context preserves cross, litter, first birth and genes", seenContext.damBreed == "HOLSTEIN"
        and seenContext.sireBreed == "ANGUS" and seenContext.litterSize == 2 and seenContext.firstBirth
        and seenContext.metabolism == 1.2)
    if dead then
        check(name .. " dead child has no growth initialisation", child.isDead == true and initCalls == 0 and child.rlGrowth == nil)
    else
        check(name .. " birth keeps the draw's weight", child.weight == (v2 and 37.25 or 2.1) and child.age == 0)
        check(name .. " v2 state keeps that same weight", initCalls == (v2 and 1 or 0)
            and (not v2 or child.rlGrowth.birthWeightKg == child.weight and child.rlGrowth.weightKg == child.weight))
    end
end
scenario("v2 survivor", true, false, true)
scenario("v2 death", true, true, true)
scenario("other animal", false, false, true)
scenario("v2 disabled", false, true, true)
scenario("legacy without RLGrowth", false, false, false)
