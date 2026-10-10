-- Exact excerpts of the base game's AnimalClusterSystem, FS25 v1.23.1
-- dataS/scripts/animals/husbandry/cluster/AnimalClusterSystem.lua lines 7-18 (new) and 90-117
-- (queue and flush) (sha256 25704e87597e3250b3d8e61c212d744ee4023b60dd535210d3ea6fb149bf089f,
-- decompiled source), and Utils.overwrittenFunction / appendedFunction from
-- dataS/scripts/utils/Utils.lua lines 400-408 and 386-392. RLRM overrides new/addCluster/
-- removeCluster/updateClusters/updateIdMapping/getClusters/... (scripts/animals/husbandry/
-- cluster/RealisticLivestock_AnimalClusterSystem.lua) but not the queue and flush calls the
-- source adapter uses. With these exact wrappers RLRM's static new(superFunc, isServer, ...)
-- override receives its arguments shifted, so a live cluster system's isServer holds the base
-- new function, as in the game - the adapter must not rely on it being true.
Utils = Utils or {}
function Utils.overwrittenFunction(oldFunc, newFunc)
	return oldFunc == nil and function(self, ...)
		-- upvalues: (copy) newFunc
		return newFunc(self, nil, ...)
	end or function(self, ...)
		-- upvalues: (copy) newFunc, (copy) oldFunc
		return newFunc(self, oldFunc, ...)
	end
end
function Utils.appendedFunction(oldFunc, newFunc)
	return oldFunc ~= nil and function(...)
		-- upvalues: (copy) oldFunc, (copy) newFunc
		oldFunc(...)
		newFunc(...)
	end or newFunc
end
AnimalClusterSystem = AnimalClusterSystem or {}
local AnimalClusterSystem_mt = Class(AnimalClusterSystem)
function AnimalClusterSystem.new(isServer, owner, customMt)
	-- upvalues: (copy) AnimalClusterSystem_mt
	local self = setmetatable({}, customMt or AnimalClusterSystem_mt)
	self.isServer = isServer
	self.owner = owner
	self.clusters = {}
	self.idToIndex = {}
	self.clustersToAdd = {}
	self.clustersToRemove = {}
	self.needsUpdate = false
	return self
end
function AnimalClusterSystem:updateNow()
	if self.needsUpdate then
		self:updateClusters()
		self.needsUpdate = false
	end
end
function AnimalClusterSystem:updateIdMapping()
	self.idToIndex = {}
	for index, cluster in ipairs(self.clusters) do
		self.idToIndex[cluster.id] = index
	end
end
function AnimalClusterSystem:setDirty()
	self.needsUpdate = true
	self.owner:raiseActive()
end
function AnimalClusterSystem:addPendingAddCluster(cluster)
	assert(self.isServer, "AnimalClusterSystem:addPendingAddCluster is a server function")
	self.clustersToAdd[cluster] = true
	self.clustersToRemove[cluster] = nil
	self:setDirty()
end
function AnimalClusterSystem:addPendingRemoveCluster(cluster)
	assert(self.isServer, "AnimalClusterSystem:addPendingRemoveCluster is a server function")
	self.clustersToRemove[cluster] = true
	self.clustersToAdd[cluster] = nil
	self:setDirty()
end
