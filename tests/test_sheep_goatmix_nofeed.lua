-- SHEEP-GOATMIX-NOFEED-01: a sheep pen holding only the feeds RLFeed adds for sheep (silage, peas)
-- gets an animal the mode does not cover (a vanilla cluster; since the unified nursing design of 2026-10-22
-- a goat is covered on its own GOAT section and keeps the pen in the mode). The whole pen goes back to the old rules, and
-- the old rules never eat those feeds, so the pen has nothing to eat. The fallback stays; the pen
-- now says which feeds are not eaten and that its own feed is missing (pen rows, one log line per
-- change, one notification), and the feeding really gives nothing (food factor 0, stock kept).

loadMod("tests/sheepsim.lua")
-- The engine's food group consumption (AnimalFoodSystem.consumeFoodGroup, FS25 1.23); RLFeed puts
-- its guard on the added groups over it when it loads.
AnimalFoodSystem = { consumeFood = function() return 1 end }
function AnimalFoodSystem.consumeFoodGroup(_, foodGroup, amount, foodOwner, consumedFood)
    for _, fillTypeIndex in pairs(foodGroup.fillTypes) do
        local currentFillLevel = foodOwner:getAvailableFood(fillTypeIndex)
        if currentFillLevel ~= nil then
            local delta = math.min(amount, currentFillLevel)
            amount = math.max(amount - delta, 0)
            consumedFood[fillTypeIndex] = delta
            if delta > 0 then foodOwner:removeFood(delta, fillTypeIndex) end
            if amount == 0 then return amount end
        end
    end
    return amount
end
loadMod("scripts/feed/RLFeed.lua")

FeedSim.setMode(true)
SheepSim.enable(true)
GrowthSim.setDaysPerPeriod(1)

local Info = RLFeedInfoService
local FILL = FeedSim.FILL
local notifications = {}
FSBaseMission = { INGAME_NOTIFICATION_CRITICAL = 1, INGAME_NOTIFICATION_INFO = 4 }
g_currentMission.addIngameNotification = function(_, kind, text) notifications[#notifications + 1] = { kind = kind, text = text } end
g_currentMission.getIsClient = function() return true end
g_currentMission.getFarmId = function() return 1 end
local savedI18n = g_i18n
g_i18n = { getText = function(_, key) return key == "rl_feed_noBaseFeedAlert" and "%s|%s|%s" or key end, hasText = function() return true end }

-- The engine's PARALLEL feeding (AnimalFoodSystem.consumeFoodParallelly) over the guarded group
-- consumption: the old rules' food factor.
local function legacyFeeding(pen, amount)
    local factor, consumed = 0, {}
    for _, group in ipairs(SheepSim.food.groups) do
        local total = 0
        for _, index in ipairs(group.fillTypes) do total = total + (pen:getAvailableFood(index) or 0) end
        local want = amount * group.eatWeight
        local take = math.min(total, want)
        factor = factor + (take - AnimalFoodSystem.consumeFoodGroup(nil, group, take, pen, consumed)) / want * group.productionWeight
    end
    for index, liters in pairs(consumed) do if liters <= 0 then consumed[index] = nil end end
    return factor, consumed
end

local ewe = SheepSim.ewe("SHEEP_LANDRACE", "GM1")
local lamb = SheepSim.grown("SHEEP_LANDRACE", "GM2", 5)
local pen = SheepSim.makePen({ ewe, lamb }, { SILAGE = 400, PEA = 100 })
pen.getOwnerFarmId = function() return 1 end
for _, a in ipairs(pen.animals) do a.clusterSystem = { owner = pen } end

-- Pure sheep: the pen runs the mode and eats its silage; nothing to say.
RLFeed.beginFeeding(pen)
check("pure sheep pen runs the mode and has no fallback gap",
    pen.spec_husbandryFood.rlFeedPen.active == true and Info.checkFallbackFeed(pen, 1) == nil and #notifications == 0)

-- A goat joins: covered on its own section, the pen keeps the mode.
local doe = SheepSim.identify((GrowthSim.makeAnimal("GOAT", { age = 24 })), "GM4")
table.insert(pen.animals, doe)
doe.clusterSystem = { owner = pen }
check("a goat in the pen: covered by its own GOAT section, the pen keeps the mode", RLFeed.beginFeeding(pen) == true
    and RLFeed.getConfig(doe) == RLFeedProfiles.getConfig().species.GOAT)
table.remove(pen.animals)

-- An uncovered animal joins (a vanilla cluster): the pen falls back.
local goat = SheepSim.identify((GrowthSim.makeAnimal("SHEEP_LANDRACE", { age = 24 })), "GM3")
goat.isIndividual = false
table.insert(pen.animals, goat)
goat.clusterSystem = { owner = pen }
local active = RLFeed.beginFeeding(pen)
check("uncovered animal in the pen: the whole pen falls back (UNCOVERED_ANIMAL)", active == false and pen.spec_husbandryFood.rlFeedPen.reason == "UNCOVERED_ANIMAL")

local gap = Info.getFallbackFeedGap(pen)
check("fallback gap: silage and peas are the feeds not eaten, no base feed",
    gap ~= nil and gap.baseMissing == true and #gap.feeds == 2 and gap.titles:find("SILAGE", 1, true) ~= nil and gap.titles:find("PEA", 1, true) ~= nil
    and math.abs(gap.liters - 500) < 1e-9 and gap.baseLiters == 0)

local rows = Info.getPenInfoRows(pen)
local byKey = {}
for _, row in ipairs(rows) do byKey[row.titleKey] = row end
check("pen rows: the reason, the feeds not eaten and the missing base feed, as warnings",
    byKey.rl_feed_penMode ~= nil and byKey.rl_feed_penNotEaten ~= nil and byKey.rl_feed_penNotEaten.warning == true
    and byKey.rl_feed_penNotEaten.text == gap.titles and byKey.rl_feed_penNoBaseFeed ~= nil and byKey.rl_feed_penNoBaseFeed.warning == true)

-- The feeding is the old rules': nothing eaten, food factor 0, the stock stays for a later recovery.
local factor, consumed = legacyFeeding(pen, 10)
check("fallback feeding: food factor 0, silage and peas untouched",
    factor == 0 and next(consumed) == nil and pen:level("SILAGE") == 400 and pen:level("PEA") == 100)

local logged = #LOG
Info.checkFallbackFeed(pen, factor)
local warnings = {}
for i = logged + 1, #LOG do warnings[#warnings + 1] = LOG[i] end
check("log: one warning naming the reason and the feeds not eaten",
    #warnings == 1 and warnings[1]:find("UNCOVERED_ANIMAL", 1, true) ~= nil and warnings[1]:find("SILAGE", 1, true) ~= nil
    and warnings[1]:find("food factor 0.00", 1, true) ~= nil)
check("notification: once, critical, with the pen, the reason and the feeds",
    #notifications == 1 and notifications[1].kind == FSBaseMission.INGAME_NOTIFICATION_CRITICAL and notifications[1].text:find("SILAGE", 1, true) ~= nil)
for _ = 1, 5 do RLFeed.beginFeeding(pen); Info.checkFallbackFeed(pen, 0) end
check("the same state an hour later: no new log line, no new notification", #LOG == logged + 1 and #notifications == 1)

-- Base feed added: the hint changes to what is still not eaten, the pen eats the hay.
pen:add("DRYGRASS_WINDROW", 300)
RLFeed.beginFeeding(pen)
local gap2 = Info.checkFallbackFeed(pen, 1)
local rows2 = Info.getPenInfoRows(pen)
local warned, noBase = false, false
for _, row in ipairs(rows2) do
    if row.titleKey == "rl_feed_penNotEaten" then warned = row.warning == true end
    if row.titleKey == "rl_feed_penNoBaseFeed" then noBase = true end
end
local factor2 = legacyFeeding(pen, 10)
check("base feed added: still lists silage/peas, no longer a warning or a missing base feed; the hay is eaten",
    gap2 ~= nil and gap2.baseMissing == false and not warned and not noBase and factor2 > 0 and pen:level("SILAGE") == 400
    and #notifications == 1)

-- The uncovered animal leaves: the pen runs the mode again and the hint clears.
table.remove(pen.animals)
RLFeed.beginFeeding(pen)
check("uncovered animal gone: the pen runs the mode again, nothing to say", pen.spec_husbandryFood.rlFeedPen.active == true
    and Info.checkFallbackFeed(pen, 1) == nil and pen.spec_husbandryFood.rlFallbackFeedKey == nil)

while #LOG > logged do table.remove(LOG) end
g_i18n = savedI18n
