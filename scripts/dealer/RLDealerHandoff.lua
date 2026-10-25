-- D3-5 installation into a prepared real Animal. Authority/ownership remain transaction seams.
RLDealerHandoff = { VERSION = 1 }
local H = RLDealerHandoff
local finite=RLPlain.finite
local function fail(reason) return nil, { reason = reason } end
local function identity(value)
    return (type(value) == "string" and value ~= "" and value ~= "-1" and value ~= "0" and value ~= "0-0")
        or (finite(value) and value > 0 and value == math.floor(value))
end
local copy=RLPlain.copy
local equal=RLPlain.equal
-- Include fields whose source value may be nil: pairs(payload) would leave stale target state.
-- Registry indices, identity, birthday, clusterSystem and pregnancy are intentionally not here.
local installed = { "age", "breed", "gender", "isIndividual", "isCastrated", "genetics", "health", "isParent",
    "birthCount", "isPregnant", "reproduction", "diseases", "input", "output", "weight", "targetWeight",
    "rlGrowth", "bodyCondition", "rlFeedGain", "rlHealthCarry", "monthsSinceLastBirth", "isLactating" }
local cleared = { "sale", "rlHistoryReplay", "rlGrowthDropped", "rlGrowthCurve", "rlGrowthPeek",
    "rlFeedStepTick", "rlFeedStepOwner", "rlFeedLastMilk", "rlFeedIntake", "rlFeedPlanLiters", "rlMilkPaid",
    "rlNutrition", "rlMilk", "rlInfoRows" }
local function prepare(record, target, context)
    if type(context) ~= "table" or context.isServer ~= true then return fail("HANDOFF_SERVER_ONLY") end
    if type(target) ~= "table" or type(target.getSubType) ~= "function" or target.rlHistoryReplay == true
        or target.isDead == true or target.isSold == true or target.isIndividual ~= true
        or (target.numAnimals ~= nil and target.numAnimals ~= 1) then return fail("HANDOFF_TARGET") end
    if not identity(target.uniqueId) or not identity(target.farmId) then return fail("HANDOFF_IDENTITY") end
    -- A prepared calendar birthday must already be owned by the authoritative transaction.
    -- Animal.new's random birthday is not evidence of the historical birth date.
    local birthday = target.birthday
    if type(birthday) ~= "table" or not finite(birthday.day) or birthday.day < 1 or birthday.day > 31
        or birthday.day ~= math.floor(birthday.day) or not finite(birthday.month) or birthday.month < 1 or birthday.month > 12
        or birthday.month ~= math.floor(birthday.month) or not finite(birthday.year)
        or birthday.year ~= math.floor(birthday.year) or not finite(birthday.lastAgeMonth)
        or birthday.lastAgeMonth < 1 or birthday.lastAgeMonth > 12 or birthday.lastAgeMonth ~= math.floor(birthday.lastAgeMonth) then return fail("HANDOFF_BIRTHDAY") end
    local tick = context.completedLiveTick
    if tick ~= nil and (context.liveHourAlreadySettled ~= true or tick ~= RLBodyCondition.getTickId()) then
        return fail("HANDOFF_LIVE_HOUR")
    end
    local payload, failure = RLDealerSourceState.prepareHandoff(record, target, tick)
    if payload == nil then return nil, failure end
    if tick ~= nil and payload.bodyCondition == nil then return fail("HANDOFF_LIVE_HOUR") end
    local sub = target:getSubType()
    if sub.typeIndex ~= record.animal.animalTypeIndex or not RLGrowth.coversSubType(sub) then return fail("HANDOFF_SUBTYPE") end
    -- Check the current installed model as restore does, before any target write.
    local replay, restoreFailure = RLDealerSourceState.restore(record, function(name)
        if name == sub.name then return sub end
        local pregnancy = target.pregnancy
        for _, child in ipairs(pregnancy ~= nil and pregnancy.pregnancies or {}) do
            local childSub = child:getSubType()
            if childSub.name == name then return childSub end
        end
    end)
    if replay == nil then return nil, restoreFailure end
    if record.animal.isPregnant then
        for _, child in ipairs(target.pregnancy.pregnancies) do
            if not finite(child.age) or child.age >= 0 or child.rlHistoryReplay == true or not identity(child.uniqueId) then return fail("HANDOFF_OFFSPRING") end
        end
    end
    return payload
end

-- Validation and copying finish before the first write. No setter callbacks, RNG, identity
-- allocation, cluster mutation, production, dirty broadcast or save write occur in this step.
-- Raw assignment is intentional: existing Animal setters merely assign data, while modded
-- setters can mutate external systems before failing. Caller marks the cluster dirty at commit.
function H.install(record, target, context)
    local success, payload, failure = pcall(prepare, record, target, context)
    if not success then return fail("HANDOFF_PREPARE_ERROR") end
    if payload == nil then return nil, failure end
    local before, after, keys = {}, {}, {}
    local function stage(key, value)
        keys[#keys + 1] = key
        before[key], after[key] = rawget(target, key), value
    end
    for _, key in ipairs(installed) do stage(key, payload[key]) end
    for _, key in ipairs(cleared) do stage(key, nil) end
    stage("isDirty", true)
    local tick = context.completedLiveTick
    if tick ~= nil then
        -- Both live growth adapters must skip the explicitly settled hour. No historical
        -- interval is labelled as live; the caller proves real live settlement separately.
        after.rlFeedStepTick, after.rlFeedStepOwner = tick, nil
        after.bodyCondition.lastTick = tick
        after.rlMilkPaid = { tick = tick, litersPerHour = 0, deposited = true }
    end
    local expected = copy(after)
    for _, key in ipairs(keys) do rawset(target, key, after[key]) end
    return { version = H.VERSION, target = target, keys = keys, before = before, after = after, expected = expected,
        uniqueId = target.uniqueId, farmId = target.farmId, birthday = target.birthday,
        clusterSystem = target.clusterSystem, pregnancy = target.pregnancy,
        weightKg = target.weight, committed = false }
end

-- In-memory compensation only, before publication/attachment. Durable transaction recovery
-- must persist its own prepared identities and stage journal; this receipt is not a save format.
function H.rollback(receipt)
    if type(receipt) ~= "table" or receipt.version ~= H.VERSION or type(receipt.target) ~= "table"
        or receipt.committed ~= false or type(receipt.keys) ~= "table" or type(receipt.before) ~= "table"
        or type(receipt.after) ~= "table" or type(receipt.expected) ~= "table" then return false, "HANDOFF_RECEIPT" end
    local target = receipt.target
    if target.uniqueId ~= receipt.uniqueId or target.farmId ~= receipt.farmId or target.birthday ~= receipt.birthday
        or target.clusterSystem ~= receipt.clusterSystem or target.pregnancy ~= receipt.pregnancy then return false, "HANDOFF_OWNERSHIP" end
    for _, key in ipairs(receipt.keys) do if rawget(target, key) ~= receipt.after[key] or not equal(rawget(target, key), receipt.expected[key]) then return false, "HANDOFF_CHANGED" end end
    for _, key in ipairs(receipt.keys) do rawset(target, key, receipt.before[key]) end
    receipt.committed = true
    return true
end
