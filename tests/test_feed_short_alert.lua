-- A pen short of feed (2026-10-23 game test: a Legacy save's empty trough killed a herd at the first day
-- change at one day a month, unannounced). The rules stay as they are; the player is told once when the
-- hour's feed pays under RLFeed.FEED_SHORT_SHARE of the animals' demand (the planner plans from the stock,
-- so an empty trough plans nothing: the demand is each animal's budget's), again only after the pen was fed
-- (RLFeed.FEED_OK_SHARE) and runs short anew. Another farm's pen does not notify this player.

loadMod("tests/feedsim.lua")
FeedSim.setMode(true)
GrowthSim.setDaysPerPeriod(1)

FSBaseMission = FSBaseMission or {}
FSBaseMission.INGAME_NOTIFICATION_CRITICAL = FSBaseMission.INGAME_NOTIFICATION_CRITICAL or "CRITICAL"
local notices = {}
g_currentMission.getIsClient = function() return true end
g_currentMission.getFarmId = function() return 1 end
g_currentMission.addIngameNotification = function(_, kind, text) notices[#notices + 1] = { kind = kind, text = text } end
local Info = RLFeedInfoService
local i18n = g_i18n.getText
g_i18n.getText = function(self, key) if key == "rl_feed_shortAlert" then return "%s: %d%%" end return i18n(self, key) end

-- The rule ----------------------------------------------------------------------------------------
do
    local pen = { spec_husbandryFood = {}, getOwnerFarmId = function() return 1 end, getName = function() return "Barn" end }
    Info.notifyFeedShort(pen, 0.6)
    check("rule: 60% of the plan is not short", #notices == 0)
    Info.notifyFeedShort(pen, 0.2)
    check("rule: 20% is short: one critical notice with the pen and the share",
        #notices == 1 and notices[1].kind == FSBaseMission.INGAME_NOTIFICATION_CRITICAL
        and notices[1].text:find("Barn", 1, true) ~= nil and notices[1].text:find("20", 1, true) ~= nil)
    Info.notifyFeedShort(pen, 0)
    Info.notifyFeedShort(pen, 0.7)
    Info.notifyFeedShort(pen, 0.1)
    check("rule: still short (or half fed) is not told again", #notices == 1)
    Info.notifyFeedShort(pen, 0.95)
    Info.notifyFeedShort(pen, 0.3)
    check("rule: fed again, then short anew: a second notice", #notices == 2)
    Info.notifyFeedShort(pen, 0 / 0)
    check("rule: an undefined share does nothing", #notices == 2)
    pen.getOwnerFarmId = function() return 2 end
    Info.notifyFeedShort(pen, 0.95)
    Info.notifyFeedShort(pen, 0)
    check("rule: another farm's pen does not notify this player", #notices == 2)
end

-- In a pen's hour (RLFeed.endFeeding) -------------------------------------------------------------
do
    notices = {}
    local cow = (GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 }))
    local pen = FeedSim.makePen({ cow }, {}, { name = "Empty barn" })
    pen.getOwnerFarmId = function() return 1 end
    FeedSim.hour(pen)
    FeedSim.hour(pen)
    local h = pen.spec_husbandryFood.rlFeedLast or {}
    check("hour: an empty trough pays nothing of the demand", h.feedCoverage ~= nil and h.feedCoverage < 0.05)
    check("hour: an empty trough tells the player once", #notices == 1 and notices[1].text:find("Empty barn", 1, true) ~= nil)
    local fed = FeedSim.makePen({ (GrowthSim.makeAnimal("BULL_ANGUS", { age = 14 })) }, { FORAGE = 1e6, SILAGE = 1e6, DRYGRASS_WINDROW = 1e6 },
        { name = "Full barn" })
    fed.getOwnerFarmId = function() return 1 end
    FeedSim.hour(fed)
    FeedSim.hour(fed)
    check("hour: a stocked trough tells nothing", #notices == 1 and (fed.spec_husbandryFood.rlFeedLast.feedCoverage or 0) >= RLFeed.FEED_OK_SHARE)
end
