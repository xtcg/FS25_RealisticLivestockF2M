-- Regressions where upstream 1.4.1.0 and the fork change the same behaviour.
loadMod("tests/feedsim.lua")
loadMod("scripts/utils/RLAnimalDisplayHelper.lua")
loadMod("scripts/disease/RLDiseaseRates.lua")
loadAnimalSection("function Animal.formatAmountPerDay", "function Animal:showMonitorInfo")

do
    local calls = 0
    local sub = { healthThresholdFactor = 0.5, healthIncreaseHour = 10, healthDecreaseHour = 25 }
    local function health(gene, food)
        local a = { health = 90, genetics = { health = gene }, getSubType = function() return sub end,
            updateWeight = function() calls = calls + 1 end }
        AnimalHealth.updateHealthOnly(a, food)
        return a.health
    end
    check("upstream health: good genes slow starvation in the legacy path", health(1.75, 0) == 83 and health(0.25, 0) == 46)
    check("upstream health: good genes still speed recovery", health(1.75, 1) == 100 and health(0.25, 1) == 92)
    check("upstream health: health-only settlement never invokes legacy weight", calls == 0)

    local function nutritionHealth(gene, water)
        local a = GrowthSim.makeAnimal("BULL_ANGUS", { age = 18 })
        a.health, a.rlHealthCarry, a.genetics.health = 90, 0, gene
        local result = { supplyNU = 10, maintenanceNU = 10, pregnancyNU = 0, reserve = 0.5 }
        RLFeed.applyHealth(a, { water = water, cp = 1, kg = 1, dtDays = 1 }, result, 1 / 24)
        return a.health, a.rlHealthCarry
    end
    local good, goodCarry = nutritionHealth(1.75, 0)
    local poor, poorCarry = nutritionHealth(0.25, 0)
    check("upstream health: good genes also slow losses in real-equivalent nutrition",
        near(good + goodCarry, 83.75, 1e-9) and near(poor + poorCarry, 46.25, 1e-9))
    check("upstream health: real-equivalent recovery keeps its existing gene effect",
        nutritionHealth(1.75, 1) == 100 and nutritionHealth(0.25, 1) == 92)
end

do
    MathUtil = { round = function(n, precision)
        local scale = 10 ^ precision
        return math.floor(n * scale + 0.5) / scale
    end }
    for _, lang in ipairs({ "en", "cs", "ru" }) do
        local xml = assert(loadXMLFileFromDisk(REPO .. "translations/translation_" .. lang .. ".xml"))
        local label
        xml:iterate("l10n.texts.text", function(_, key)
            if xml:getString(key .. "#name") == "rl_ui_amountPerDay" then label = xml:getString(key .. "#text") end
        end)
        g_i18n = { getText = function() return label end,
            formatNumber = function(_, value, precision) return string.format("%." .. precision .. "f", value) end }
        check("upstream display " .. lang .. ": a 0.02 L/day fleece never reads as zero",
            RLAnimalDisplayHelper.formatAmountPerDay(0.02):find("0.02", 1, true) ~= nil)
        check("upstream display " .. lang .. ": 1.2 L/day keeps the fork's precision",
            RLAnimalDisplayHelper.formatAmountPerDay(1.2):find("1.2", 1, true) ~= nil)
        check("upstream display " .. lang .. ": compatibility wrapper uses the new string label",
            Animal.formatAmountPerDay(0.02 * 3 / 24, 3) == RLAnimalDisplayHelper.formatAmountPerDay(0.02))
    end
end

do
    local savedRandom = math.random
    for _, days in ipairs({ 1, 3, 28 }) do
        local a = { animalTypeIndex = AnimalType.COW, age = 210, genetics = { health = 1 }, numAnimals = 1,
            die = function(self) self.isDead = true end }
        local monthly = AnimalHealth.getOldAgeMonthlyDeathChance(a)
        local daily = 1 - (1 - monthly) ^ (1 / days)
        math.random = function() return daily + 1e-8 end
        local above = AnimalHealth.calculateOldAgeMonthlyAnimalDeaths(a, days)
        math.random = function() return daily - 1e-8 end
        local below = AnimalHealth.calculateOldAgeMonthlyAnimalDeaths(a, days)
        check("upstream mortality: actual old-age roll uses the converted daily threshold at " .. days .. " days/month",
            above == 0 and below == 1 and a.isDead)
    end
    math.random = savedRandom
end
