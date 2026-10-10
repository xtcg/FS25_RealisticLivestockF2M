-- Excerpts of the base game's money path, FS25 v1.23.1 (decompiled source):
--   dataS/scripts/FSBaseMission.lua   lines 1825-1845 (addMoneyChange), 1861-1877 (broadcastNotifications),
--                                     2020-2039 (addMoney)
--     sha256 106614ad996ad9d40968f627a670e0ed3947bd68434fb1b839e9ff1d651e93ca
--   dataS/scripts/farms/Farm.lua      lines 518-540 (changeBalance), 545-547 (getBalance)
--     sha256 e12a10374435c599a93af8caa412557bb00db9d42e8799af28c64cf363388753
--   dataS/scripts/farms/FarmStats.lua lines 253-263 (changeFinanceStats), 305-316 (addHeroStat)
--     sha256 72bec4e498ec3431a5d842ac5bec542e1e4bad1fa88874c45e14e8f0e49410ea
-- The bodies are copied as they are, with one change: the decompiler's goto labels in
-- Farm:changeBalance (a jump into the other branch, which stock Lua refuses) are written as the
-- one condition they encode. Nothing else is restructured; the order of the steps is the game's.
--
-- Stand-ins (no engine proof): the farm and its FarmStats tables (only the fields these functions
-- touch), raiseDirtyFlags, the HUD, broadcastEventToFarm and MoneyChangeEvent. g_messageCenter
-- and g_currentMission are the test's own.

FSBaseMissionMoney = {}

-- FSBaseMission.lua 1825-1845
function FSBaseMissionMoney.addMoneyChange(self, amount, farmId, moneyType, forceShow)
	if self:getIsServer() then
		if self.moneyChanges[moneyType.id] == nil then
			self.moneyChanges[moneyType.id] = {}
		end
		local changes = self.moneyChanges[moneyType.id]
		if changes[farmId] == nil then
			changes[farmId] = 0
		end
		changes[farmId] = changes[farmId] + amount
		if self:getFarmId() == farmId then
			self.hud:addMoneyChange(moneyType, amount)
		end
		if forceShow then
			self:broadcastNotifications(moneyType, farmId)
			return
		end
	else
		Logging.error("addMoneyChange() called on client")
		printCallstack()
	end
end

-- FSBaseMission.lua 1861-1877: sends the farm's HUD total and clears it
function FSBaseMissionMoney.broadcastNotifications(self, moneyType, farmId, text)
	if moneyType == nil then
		printCallstack()
	end
	local farms = self.moneyChanges[moneyType.id]
	local amount = farms and farms[farmId]
	if amount then
		self:broadcastEventToFarm(MoneyChangeEvent.new(amount, moneyType, farmId, text), farmId, false)
		if farmId == self:getFarmId() then
			if text ~= nil then
				text = g_i18n:getText(text)
			end
			self.hud:showMoneyChange(moneyType, text)
		end
		farms[farmId] = nil
	end
end

-- FSBaseMission.lua 2020-2039
function FSBaseMissionMoney.addMoney(self, amount, farmId, moneyType, addChange, forceShowChange)
	if self:getIsServer() then
		if farmId == 0 then
			printError("Error: Can\'t change money of spectator farm")
			printCallstack()
			return
		end
		local farm = g_farmManager:getFarmById(farmId)
		if farm == nil then
			return
		end
		farm:changeBalance(amount, moneyType)
		if addChange then
			self:addMoneyChange(amount, farmId, moneyType, forceShowChange)
			return
		end
	else
		printError("Error: FSBaseMission:addMoney is only allowed on a server")
		printCallstack()
	end
end

FarmMoney = {}

-- Farm.lua 518-540 (goto labels written as their condition)
function FarmMoney.changeBalance(self, amount, moneyType)
	self.money = self.money + amount
	local statistic = moneyType ~= nil and moneyType.statistic or nil
	self.stats:changeFinanceStats(amount, statistic)
	if amount > 0 then
		self.stats:addHeroStat("moneyEarned", amount)
	end
	if math.abs(self.lastMoneyPublished - self.money) >= 1
		or (g_currentMission.missionDynamicInfo.isMultiplayer and math.abs(self.lastMoneySent - self.money) >= 1) then
		self:raiseDirtyFlags(self.farmMoneyDirtyFlag)
		self.lastMoneyPublished = self.money
		g_messageCenter:publish(MessageType.MONEY_CHANGED, self.farmId, self.money)
	end
end

-- Farm.lua 545-547
function FarmMoney.getBalance(self)
	return self.money
end

FarmStatsMoney = {}

-- FarmStats.lua 253-263
function FarmStatsMoney.changeFinanceStats(self, amount, statType)
	if statType ~= nil and self.finances[statType] ~= nil then
		self.finances[statType] = self.finances[statType] + amount
		if g_currentMission:getIsServer() then
			self.financesVersionCounter = self.financesVersionCounter + 1
			if self.financesVersionCounter > 999999 then
				self.financesVersionCounter = 0
			end
		end
	end
end

-- FarmStats.lua 305-316 (addValueToHeroStat is a stand-in: hero stats are not loaded here)
function FarmStatsMoney.addHeroStat(self, statName, delta)
	if self.heroStats[statName] == nil then
		if statName == "missionCount" then
			self:addValueToHeroStat("completedMissions", delta)
		end
		return
	elseif statName == "moneyEarned" then
		self.moneyEarnedHeroAccum = self.moneyEarnedHeroAccum + delta
	else
		self:addValueToHeroStat(statName, delta)
	end
end

--- Stand-in farm with the fields the excerpts touch, FarmStats as FarmStats.new leaves them.
function FarmMoney.newFarm(farmId, money, statNames)
	local finances = {}
	for _, name in ipairs(statNames) do finances[name] = 0 end
	local stats = { finances = finances, heroStats = { moneyEarned = { accumValue = 0 } }, moneyEarnedHeroAccum = 0,
		financesVersionCounter = 0, changeFinanceStats = FarmStatsMoney.changeFinanceStats, addHeroStat = FarmStatsMoney.addHeroStat,
		addValueToHeroStat = function() end }
	return { farmId = farmId, money = money, stats = stats, lastMoneyPublished = money, lastMoneySent = money,
		farmMoneyDirtyFlag = 1, dirty = 0, changeBalance = FarmMoney.changeBalance, getBalance = FarmMoney.getBalance,
		raiseDirtyFlags = function(farm) farm.dirty = farm.dirty + 1 end }
end
