-- Calves on milk without milk (real-equivalent mode, a calf rearing pen): the rules stay as they
-- are - a newborn with no milk weakens and may die - and the player is told. Each hour the server
-- marks a calf that drank under half its planned milk, and a pen's state: NONE (a calf short, the
-- trough's milk does not cover the plan), LOW (milk for under a quarter month) or OK. The pen's
-- info box shows a warning row, the calf's info its limit, the ration dialog a warning, and the
-- player's own farm gets one notification per change to NONE or LOW. Nutrition does not change.

loadMod("tests/feedsim.lua")

local config = RLFeed.getConfig()
local Info = RLFeedInfoService

FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(1)

FSBaseMission = FSBaseMission or {}
FSBaseMission.INGAME_NOTIFICATION_CRITICAL = FSBaseMission.INGAME_NOTIFICATION_CRITICAL or "CRITICAL"
FSBaseMission.INGAME_NOTIFICATION_INFO = FSBaseMission.INGAME_NOTIFICATION_INFO or "INFO"
local notices = {}
g_currentMission.getIsClient = function() return true end
g_currentMission.getFarmId = function() return 1 end
g_currentMission.addIngameNotification = function(_, kind, text) notices[#notices + 1] = { kind = kind, text = text } end

local function rearingPen(stock, name)
    local c = GrowthSim.newborn("BULL_HOLSTEIN")
    local pen = FeedSim.makePen({ c }, stock, { rearing = true, name = name })
    pen.getOwnerFarmId = function() return 1 end
    return pen, c
end


-- The rule ----------------------------------------------------------------------------------------

do
    local A = RLFeed.getCalfMilkAlert
    check("rule: no calf on milk, no alert", A({ { milkPlanKg = 0, milkDrunkKg = 0 } }, 0, 0) == nil)
    local none = A({ { milkPlanKg = 1, milkDrunkKg = 0 }, { milkPlanKg = 1, milkDrunkKg = 1 } }, 0, 0)
    check("rule: a calf short and no milk in the trough: NONE, 2 calves, 1 short",
        none.state == "NONE" and none.calves == 2 and none.short == 1 and none.monthsLeft == nil)
    check("rule: all drank, milk for a month: OK", A({ { milkPlanKg = 1, milkDrunkKg = 0.9 } }, 100, 100).state == "OK")
    local low = A({ { milkPlanKg = 1, milkDrunkKg = 1 } }, 10, 100)
    check("rule: all drank, milk for 0.1 month: LOW", low.state == "LOW" and math.abs(low.monthsLeft - 0.1) < 1e-12)
    check("rule: half its milk is not short, under half is", not RLFeed.isMilkShort(1, 0.5) and RLFeed.isMilkShort(1, 0.49))
end


-- A rearing pen without milk ------------------------------------------------------------------------

do
    notices = {}
    local pen, c = rearingPen({ FORAGE = 1e5 }, "Igloo")
    FeedSim.hour(pen)
    local alert = Info.getCalfMilkAlert(pen)
    check("pen: a newborn on TMR alone in a rearing pen - NONE, 1 calf short",
        alert ~= nil and alert.state == "NONE" and alert.calves == 1 and alert.short == 1)
    check("calf: it shows 'no calf milk' as what holds its ration",
        c.rlFeedIntake.milkShort == true and Info.getMainLimit(Info.getAnimalInfo(c)) == "NO_CALF_MILK")
    local row
    for _, r in ipairs(Info.getPenInfoRows(pen)) do if r.titleKey == "rl_feed_penCalfMilk" then row = r end end
    check("pen: its info box has the warning row", row ~= nil and row.warning == true)
    check("notice: one critical notice for the player's farm", #notices == 1 and notices[1].kind == FSBaseMission.INGAME_NOTIFICATION_CRITICAL)
    FeedSim.hour(pen)
    check("notice: an hour still without milk does not repeat it", #notices == 1)

    pen:add("CALFMILK", 1e4)
    FeedSim.hour(pen)
    check("refill: with milk the pen is OK, the calf drinks, no row and no notice",
        Info.getCalfMilkAlert(pen).state == "OK" and not c.rlFeedIntake.milkShort and #notices == 1)
    local hasRow = false
    for _, r in ipairs(Info.getPenInfoRows(pen)) do if r.titleKey == "rl_feed_penCalfMilk" then hasRow = true end end
    check("refill: the warning row is gone", not hasRow)
    pen.spec_husbandryFood.fillLevels[FeedSim.FILL.CALFMILK] = 0
    FeedSim.hour(pen)
    check("again: out of milk once more, a new notice", #notices == 2 and Info.getCalfMilkAlert(pen).state == "NONE")

    pen.getOwnerFarmId = function() return 2 end
    pen.spec_husbandryFood.rlCalfMilkNotified = "OK"
    FeedSim.hour(pen)
    check("farm: another farm's pen does not notify this player", #notices == 2)
end


-- Milk running low, plenty of milk, other pens ------------------------------------------------------

do
    notices = {}
    local pen = rearingPen({ FORAGE = 1e5, CALFMILK = 1e4 })
    FeedSim.hour(pen)
    check("plenty: OK, no notice", Info.getCalfMilkAlert(pen).state == "OK" and #notices == 0)
    local planned = pen.spec_husbandryFood.rlFeedLast.plannedPerMonth.CALFMILK
    pen.spec_husbandryFood.fillLevels[FeedSim.FILL.CALFMILK] = 0.1 * planned
    FeedSim.hour(pen)
    local alert = Info.getCalfMilkAlert(pen)
    check(string.format("low: milk for %.2f months - LOW, one info notice", alert.monthsLeft or -1),
        alert.state == "LOW" and #notices == 1 and notices[1].kind == FSBaseMission.INGAME_NOTIFICATION_INFO)

    local cow = (GrowthSim.makeAnimal("COW_HOLSTEIN", { age = 48, isParent = true, isLactating = true, monthsSinceLastBirth = 1 }))
    cow.getIdentifiers = function() return "DAM" end
    local calf = GrowthSim.newborn("BULL_HOLSTEIN", { motherId = "DAM" })
    calf.getIdentifiers = function() return "CALF" end
    local ordinary = FeedSim.makePen({ cow, calf }, { FORAGE = 1e5 })
    FeedSim.hour(ordinary)
    check("ordinary pen: a calf at its dam is not a rearing pen's alert", Info.getCalfMilkAlert(ordinary) == nil)

    FeedSim.setMode(false)
    local legacy = rearingPen({ FORAGE = 1e5 })
    FeedSim.hour(legacy)
    check("old rules: no alert", Info.getCalfMilkAlert(legacy) == nil)
    FeedSim.setMode(true)
end


-- Ration dialog, clients ------------------------------------------------------------------------------

do
    local pen = rearingPen({ FORAGE = 1e5 })
    FeedSim.hour(pen)
    local preview = Info.previewRation(pen, RLFeed.getRation(pen))
    check("dialog: the preview counts the calf the plan cannot give its milk", preview ~= nil and preview.calvesWithoutMilk == 1)
    local fed = rearingPen({ FORAGE = 1e5, CALFMILK = 1e4 })
    FeedSim.hour(fed)
    check("dialog: none with milk in the trough", Info.previewRation(fed, RLFeed.getRation(fed)).calvesWithoutMilk == 0)

    local stream, readAt = {}, 0
    local function w(_, v) stream[#stream + 1] = v end
    local function r() readAt = readAt + 1; return stream[readAt] end
    streamWriteBool, streamWriteFloat32, streamWriteString, streamWriteUInt8, streamWriteUInt16 = w, w, w, w, w
    streamReadBool, streamReadFloat32, streamReadString, streamReadUInt8, streamReadUInt16 = r, r, r, r, r
    local c = pen.animals[1]
    RLFeed.writePenStream(pen, 1)
    RLFeed.writeAnimalStream(c, 1)
    RLFeed.writePenStream(fed, 1)
    local data, animalData, fedData = RLFeed.readPenStream(1), RLFeed.readAnimalStream(1), RLFeed.readPenStream(1)
    check("network: the pen's alert and the calf's milk shortage reach clients",
        readAt == #stream and data.calfMilk ~= nil and data.calfMilk.state == "NONE" and data.calfMilk.short == 1
        and animalData.milkShort == true and fedData.calfMilk.state == "OK")
    local saved = g_server
    g_server = nil
    notices = {}
    local clientPen = rearingPen({})
    RLFeed.applyPenStream(clientPen, data)
    RLFeed.applyPenStream(clientPen, data)
    g_server = saved
    check("network: a client tells its player once from the pen's summary", #notices == 1)
end
