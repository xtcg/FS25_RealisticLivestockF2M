-- RLEppAge.lua
-- The age window a butcher or production point's animal input accepts.
--
-- Hof Bergmann's production and contract points clamp an animal input's maximumAge to 60 and
-- check it only when it is below 60 (PlaceableExtendedProductionPoint.applySource): the base
-- game caps age at 60, so a maximum of 60 means "no upper limit". RLRM animals keep ageing past
-- 60, so the same value must not turn old animals away.

RLEppAge = {}

RLEppAge.OPEN_MAX_AGE = 60


--- The window an animal input accepts.
---@param typeData table|nil animalsTypeData entry ({minimumAge?, maximumAge?})
---@return number minAge 0 when unset
---@return number|nil maxAge nil when the input has no upper limit
function RLEppAge.getWindow(typeData)
    local minAge = (typeData ~= nil and typeData.minimumAge) or 0
    local maxAge = typeData ~= nil and typeData.maximumAge or nil
    if maxAge ~= nil and maxAge >= RLEppAge.OPEN_MAX_AGE then maxAge = nil end
    return minAge, maxAge
end


--- Whether an age fits an animal input.
---@param age number|nil Months; nil counts as 0
---@param typeData table|nil animalsTypeData entry
---@return boolean ok
---@return string|nil reason "AGE_TOO_YOUNG" or "AGE_TOO_OLD" when refused
function RLEppAge.check(age, typeData)
    local minAge, maxAge = RLEppAge.getWindow(typeData)
    age = age or 0
    if age < minAge then return false, "AGE_TOO_YOUNG" end
    if maxAge ~= nil and age > maxAge then return false, "AGE_TOO_OLD" end
    return true
end


--- The window as logs print it: "6-24" or "6+".
---@return string
function RLEppAge.format(minAge, maxAge)
    if maxAge == nil then return string.format("%d+", minAge or 0) end
    return string.format("%d-%d", minAge or 0, maxAge)
end
