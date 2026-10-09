-- FS25 money/finance excerpts for contract tests. Method table names renamed only.
-- changeBalance is the exact money/finance/hero-stat prefix, closed before dirty flags
-- and MONEY_CHANGED publishing: those remain engine stand-ins, not tested engine proof.
-- Farm.lua source SHA256: e12a10374435c599a93af8caa412557bb00db9d42e8799af28c64cf363388753
-- FarmStats.lua source SHA256: 72bec4e498ec3431a5d842ac5bec542e1e4bad1fa88874c45e14e8f0e49410ea
ContractTestFarm = {}
ContractTestFarmStats = {}
function ContractTestFarm:changeBalance(amount, moneyType)
	self.money = self.money + amount
	local statistic = moneyType ~= nil and moneyType.statistic or nil
	self.stats:changeFinanceStats(amount, statistic)
	if amount > 0 then
		self.stats:addHeroStat("moneyEarned", amount)
	end
end

function ContractTestFarmStats:changeFinanceStats(amount, statType)
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
