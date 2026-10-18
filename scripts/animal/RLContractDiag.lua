--[[
    T02 contract diagnostics for test runs. While rlTradeTxMode is SHADOW or TEST, every animal move
    the server handles into a contract slaughterhouse leaves one-line JSON records in log.txt
    (tag RLCT), so a test case can be judged from the log rather than from copied numbers:

        CT_REQUEST  requestId, mode, farm, source (kind, id, name), target, the requested identities
        CT_SCOPE    what the request may change, read before (BEFORE) and after (AFTER): the farm's
                    money and production cost statistic, the farm's orders at the target, the
                    source's members, queues and visual count, and the T02 ledger (locks, records)
        CT_REFUSED  a refusal before any transaction began: stage MOVE_VALIDATE, PEN_RULES,
                    FREE_SLOTS or T02_PREPARE, the reason and the error code sent to the client
        CT_RESULT   a transaction's end: txId, state, reason, stages, plan, error code sent
        CT_TARGET   its target receipt (order fields, money, statistic before and after)
        CT_SOURCE   its source receipt (removed, restored)
        CT_SHADOW   in SHADOW, what TEST would have done (the old path then runs as before)

    Numbers are written with 17 significant digits, so an analyzer can redo HB's arithmetic exactly.
    Keys are sorted, so the same state always gives the same line. Everything here reads; each read
    is protected and a failed read becomes an error field, never a stopped or changed delivery.
    OFF writes nothing.

    RLContractDiag.preview(request) is the read-only gate check for test tools: the move's own
    per-animal checks (in AnimalMoveEvent:run's order) and RLContractTrade.prepare without locks,
    returned as plain data. Trade permission is only checked when the request carries a connection.
]]

RLContractDiag = {}

local Log = RmLogging.getLogger("RLRM")

RLContractDiag.TAG = "RLCT"
RLContractDiag.SCHEMA = 1

--- Longest line written to log.txt; a longer record is replaced by a LINE_TOO_LONG marker (the
--- engine's log cuts long lines, and a cut JSON line would read as a different record).
RLContractDiag.MAX_LINE = 3800

--- Members listed per source; the count and the batch's own keys are always complete.
RLContractDiag.MAX_MEMBERS = 40

RLContractDiag.sequence = 0


local function encode(value, out)
    local kind = type(value)
    if kind == "nil" then
        out[#out + 1] = "null"
    elseif kind == "boolean" then
        out[#out + 1] = value and "true" or "false"
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            out[#out + 1] = '"' .. tostring(value) .. '"'
        elseif value == math.floor(value) and math.abs(value) < 2 ^ 53 then
            out[#out + 1] = string.format("%d", value)
        else
            out[#out + 1] = string.format("%.17g", value)
        end
    elseif kind == "string" then
        out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(c)
            if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
            return string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif kind == "table" then
        if #value > 0 or next(value) == nil then
            out[#out + 1] = "["
            for i, item in ipairs(value) do
                if i > 1 then out[#out + 1] = "," end
                encode(item, out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for key in pairs(value) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, key in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                encode(key, out)
                out[#out + 1] = ":"
                local item = value[key]
                if item == nil then item = value[tonumber(key)] end
                encode(item, out)
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = '"' .. tostring(value) .. '"'
    end
end


--- @param value any
--- @return string json
function RLContractDiag.encode(value)
    local out = {}
    encode(value, out)
    return table.concat(out)
end


--- Write one record.
--- @param kind string CT_REQUEST, CT_SCOPE, ...
--- @param data table Fields; kind and schema are added
--- @return string line
function RLContractDiag.emit(kind, data)
    data.kind, data.schema = kind, RLContractDiag.SCHEMA
    local line = RLContractDiag.TAG .. " " .. RLContractDiag.encode(data)
    if #line > RLContractDiag.MAX_LINE then
        line = RLContractDiag.TAG .. " " .. RLContractDiag.encode({ kind = "LINE_TOO_LONG", schema = RLContractDiag.SCHEMA,
            record = kind, length = #line, requestId = data.requestId, txId = data.txId })
        Log:warning("%s", line)
    else
        Log:info("%s", line)
    end
    return line
end


local function fillTypeName(index)
    local manager = g_fillTypeManager
    local name = manager ~= nil and manager.getFillTypeNameByIndex ~= nil and manager:getFillTypeNameByIndex(index) or nil
    return name or tostring(index)
end


local function objectId(object)
    if object == nil then return nil end
    if object.uniqueId ~= nil then return tostring(object.uniqueId) end
    local owner = object.owningPlaceable
    if owner ~= nil and owner.uniqueId ~= nil then return tostring(owner.uniqueId) end
    return nil
end


local function objectName(object)
    if object == nil or object.getName == nil then return nil end
    local ok, name = pcall(object.getName, object)
    return ok and name or nil
end


local function sourceKind(source)
    if source == nil then return nil end
    if source.spec_husbandryAnimals ~= nil then return "PEN" end
    if source.spec_livestockTrailer ~= nil then return "TRAILER" end
    return "OTHER"
end


local function countKeys(t)
    local n = 0
    for _ in pairs(type(t) == "table" and t or {}) do n = n + 1 end
    return n
end


--- The identity keys of a request's animals; a bad entry is named, never skipped.
local function requestKeys(animals)
    local keys = {}
    for i, animal in ipairs(type(animals) == "table" and animals or {}) do
        keys[i] = RLTradeSourceAdapter.identityKey(animal) or ("BAD:" .. i)
    end
    return keys
end


--- The source's visual animal count (pen) or used trailer slots, nil when not readable.
local function visualCount(source)
    local spec = source.spec_husbandryAnimals
    if spec ~= nil then
        local husbandry = spec.clusterHusbandry
        return husbandry ~= nil and husbandry.visualAnimalCount or nil
    end
    local trailer = source.spec_livestockTrailer
    if trailer ~= nil and type(trailer.animalTypeIndexToPlaces) == "table" then
        local used = 0
        for _, place in pairs(trailer.animalTypeIndexToPlaces) do used = used + (place.usedSlots or 0) end
        return used
    end
    return nil
end


--- What a request may change, read now. Plain data; a failed part is listed in errors.
--- @param request table {farmId, source, target}
--- @return table scope
function RLContractDiag.readScope(request)
    local scope, errors = {}, {}
    local function try(name, fn)
        local ok, err = pcall(fn)
        if not ok then errors[#errors + 1] = name .. ":" .. tostring(err) end
    end
    local farmId = request.farmId

    try("wallet", function()
        scope.money = g_currentMission:getMoney(farmId)
        local farm = g_farmManager:getFarmById(farmId)
        local stats = farm ~= nil and farm.stats or nil
        local statistic = MoneyType.PRODUCTION_COSTS.statistic
        scope.productionCosts = stats.finances[statistic]
        scope.financeVersion = stats.financesVersionCounter
    end)

    try("orders", function()
        local spec = request.target.spec_contractProductionService
        local orders = {}
        for _, order in pairs(spec.orders) do
            if order.farmId == farmId then
                local inputs, outputs = {}, {}
                for fillType, input in pairs(order.inputs or {}) do
                    inputs[fillTypeName(fillType)] = { buffered = input.buffered, totalDelivered = input.totalDelivered }
                end
                for fillType, output in pairs(order.outputs or {}) do outputs[fillTypeName(fillType)] = output.ready end
                orders[#orders + 1] = { id = order.id, recipeId = order.recipeId, state = order.state,
                    feeCredit = order.feeCredit, fee = order.fee, totalDeliveredAmount = order.totalDeliveredAmount,
                    processedBatches = order.processedBatches, inputs = inputs, ready = outputs }
            end
        end
        table.sort(orders, function(a, b) return tostring(a.id) < tostring(b.id) end)
        scope.orders = orders
    end)

    try("source", function()
        local source = request.source
        local clusterSystem = source:getClusterSystem()
        local members = {}
        for _, animal in ipairs(clusterSystem:getClusters()) do
            members[#members + 1] = RLTradeSourceAdapter.identityKey(animal) or "NO_IDENTITY"
        end
        table.sort(members)
        local listed = {}
        for i = 1, math.min(#members, RLContractDiag.MAX_MEMBERS) do listed[i] = members[i] end
        scope.source = { kind = sourceKind(source), id = objectId(source), members = listed, count = #members,
            membersTruncated = #members > RLContractDiag.MAX_MEMBERS or nil,
            queueAdd = countKeys(clusterSystem.clustersToAdd), queueRemove = countKeys(clusterSystem.clustersToRemove),
            visual = visualCount(source) }
    end)

    try("ledger", function()
        local store = RLContractTrade.store
        scope.ledger = { locks = countKeys(store.locks), records = countKeys(store.records),
            recoveryRequired = store.recoveryRequired == true }
    end)

    if #errors > 0 then scope.errors = errors end
    return scope
end


--- Flat key -> value view of a scope, for the changed list.
local function flatten(value, prefix, out)
    if type(value) ~= "table" then
        out[prefix] = value
        return out
    end
    if #value > 0 and type(value[1]) ~= "table" then
        out[prefix] = table.concat(value, ",")
        return out
    end
    for key, item in pairs(value) do
        -- list entries by their id (an order), so a reordered list is not a change
        local name = type(key) == "number" and type(item) == "table" and item.id ~= nil and ("#" .. tostring(item.id)) or tostring(key)
        flatten(item, prefix == "" and name or (prefix .. "/" .. name), out)
    end
    return out
end


--- Scope keys whose value differs between two scopes.
--- @return table changed Sorted keys
function RLContractDiag.changed(before, after)
    local a, b = flatten(before or {}, "", {}), flatten(after or {}, "", {})
    local changed = {}
    for key, value in pairs(a) do if b[key] ~= value then changed[#changed + 1] = key end end
    for key in pairs(b) do if a[key] == nil then changed[#changed + 1] = key end end
    table.sort(changed)
    return changed
end


--- Start recording a move request, when it goes to a contract slaughterhouse and T02 is not OFF.
--- @param event table The AnimalMoveEvent (sourceObject, targetObject, animals, moveType)
--- @param farmId number
--- @return table|nil diag Pass to refused/finish/shadow; nil records nothing
function RLContractDiag.open(event, farmId)
    local ok, diag = pcall(function()
        if RLContractTrade == nil or RLContractTrade.getMode() == RLContractTrade.MODE_OFF then return nil end
        if event.targetObject == nil or not AnimalMoveEvent._isWeighedContractTarget(event.targetObject, farmId) then return nil end
        RLContractDiag.sequence = RLContractDiag.sequence + 1
        local request = { farmId = farmId, source = event.sourceObject, target = event.targetObject }
        local diag = { requestId = "rq" .. RLContractDiag.sequence, request = request, mode = RLContractTrade.getMode() }
        local keys = requestKeys(event.animals)
        RLContractDiag.emit("CT_REQUEST", { requestId = diag.requestId, mode = diag.mode, farmId = farmId,
            moveType = event.moveType, keys = keys, count = #keys,
            source = { kind = sourceKind(event.sourceObject), id = objectId(event.sourceObject), name = objectName(event.sourceObject) },
            target = { id = objectId(event.targetObject), name = objectName(event.targetObject) } })
        diag.before = RLContractDiag.readScope(request)
        RLContractDiag.emit("CT_SCOPE", { requestId = diag.requestId, at = "BEFORE", scope = diag.before })
        return diag
    end)
    if not ok then
        Log:warning("RLContractDiag.open failed: %s", tostring(diag))
        return nil
    end
    return diag
end


local function emitAfter(diag, txId)
    local after = RLContractDiag.readScope(diag.request)
    RLContractDiag.emit("CT_SCOPE", { requestId = diag.requestId, txId = txId, at = "AFTER", scope = after,
        changed = RLContractDiag.changed(diag.before, after) })
end


--- A refusal before any transaction began.
--- @param stage string MOVE_VALIDATE, PEN_RULES, FREE_SLOTS or T02_PREPARE
--- @param errorCode number The code sent to the client
--- @param reason string|nil
function RLContractDiag.refused(diag, stage, errorCode, reason)
    if diag == nil then return end
    local ok, err = pcall(function()
        RLContractDiag.emit("CT_REFUSED", { requestId = diag.requestId, mode = diag.mode, stage = stage,
            errorCode = errorCode, reason = reason })
        emitAfter(diag, nil)
    end)
    if not ok then Log:warning("RLContractDiag.refused failed: %s", tostring(err)) end
end


local TARGET_FIELDS = { "stage", "orderId", "recipeId", "amount", "applied", "callOk", "accepted", "error", "applyError",
    "before", "after", "moneyBefore", "moneyAfter", "financeBefore", "financeAfter", "expected", "paymentStatus",
    "verified", "verifyError", "rollbackError", "refundAttempted", "refundStatus", "refunded", "moneyRefund",
    "financeRefund", "explained", "rolledBack", "visualError" }

local SOURCE_FIELDS = { "stage", "kind", "keys", "removed", "restored", "applied", "verified", "error", "verifyError",
    "rollbackError", "rolledBack" }

local function pick(receipt, fields)
    local out = {}
    for _, field in ipairs(fields) do out[field] = receipt[field] end
    return out
end


--- A TEST transaction's end (or its refusal before start).
--- @param record table|nil From RLContractTrade.execute
--- @param reason string|nil Refusal before start
--- @param errorCode number The code sent to the client
function RLContractDiag.finish(diag, record, reason, errorCode)
    if diag == nil then return end
    if record == nil then return RLContractDiag.refused(diag, "T02_PREPARE", errorCode, reason) end
    local ok, err = pcall(function()
        local txId = record.id
        local receipt = RLContractTrade.receipts[txId] or {}
        RLContractDiag.emit("CT_RESULT", { requestId = diag.requestId, txId = txId, state = record.state, reason = record.reason,
            history = record.history, errorCode = errorCode, keys = receipt.keys, amount = receipt.amount,
            fillType = receipt.fillType ~= nil and fillTypeName(receipt.fillType) or nil, plan = receipt.plan,
            fingerprint = receipt.fingerprint, preflightError = receipt.preflightError, receiptError = receipt.receiptError,
            resources = record.resources })
        if receipt.target ~= nil then
            RLContractDiag.emit("CT_TARGET", { requestId = diag.requestId, txId = txId, receipt = pick(receipt.target, TARGET_FIELDS) })
        end
        if receipt.source ~= nil then
            RLContractDiag.emit("CT_SOURCE", { requestId = diag.requestId, txId = txId, receipt = pick(receipt.source, SOURCE_FIELDS) })
        end
        emitAfter(diag, txId)
    end)
    if not ok then Log:warning("RLContractDiag.finish failed: %s", tostring(err)) end
end


--- SHADOW: what TEST would have done; the old path runs after this.
--- @param context table|nil From RLContractTrade.shadow
--- @param reason string|nil
function RLContractDiag.shadow(diag, context, reason)
    if diag == nil then return end
    local ok, err = pcall(function()
        local data = { requestId = diag.requestId, verdict = context ~= nil and "WOULD_DELIVER" or "WOULD_REFUSE", reason = reason }
        if context ~= nil then
            data.keys, data.amount, data.orderId = context.keys, context.amount, context.targetBinding.orderId
            data.plan = { fee = context.plan.fee, creditUse = context.plan.creditUse, cashDue = context.plan.cashDue }
        end
        RLContractDiag.emit("CT_SHADOW", data)
    end)
    if not ok then Log:warning("RLContractDiag.shadow failed: %s", tostring(err)) end
end


--- The server's gate for a request, read only: the move's own per-animal checks in
--- AnimalMoveEvent:run's order, then RLContractTrade.prepare without locks.
--- @param request table {farmId, source, target, animals (live animals), connection?}
--- @return table result {stage = READY|MOVE_VALIDATE|PEN_RULES|FREE_SLOTS|T02_PREPARE, errorCode, reason,
---   mode, freeSlots, amount, plan, entries, order, keys}
function RLContractDiag.preview(request)
    local result = { mode = RLContractTrade.getMode(), permissionChecked = request.connection ~= nil,
        keys = requestKeys(request.animals) }
    local source, target, farmId = request.source, request.target, request.farmId

    local first = request.animals ~= nil and request.animals[1] or nil
    if first ~= nil and target ~= nil then
        result.freeSlots = AnimalMoveEvent._getTargetFreeSlots(target, farmId, first.subTypeIndex)
    end

    local validated = 0
    for _, animal in ipairs(request.animals or {}) do
        local code = AnimalMoveEvent.validate(source, target, farmId, animal.subTypeIndex)
        if code ~= nil then
            result.stage, result.errorCode = "MOVE_VALIDATE", code
            return result
        end
        local penOk, penReason = true, nil
        if RLHusbandryProfiles ~= nil then penOk, penReason = RLHusbandryProfiles.checkAnimal(target, animal) end
        if not penOk then
            result.stage, result.errorCode, result.reason = "PEN_RULES", AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED, penReason
            return result
        end
        validated = validated + 1
        local needed = AnimalMoveEvent._isWeighedTarget(target, farmId, animal.subTypeIndex) and 1 or validated
        if AnimalMoveEvent._getTargetFreeSlots(target, farmId, animal.subTypeIndex) < needed then
            result.stage, result.errorCode = "FREE_SLOTS", AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE
            return result
        end
    end

    local context, reason = RLContractTrade.prepare(request, true)
    if context == nil then
        result.stage, result.reason = "T02_PREPARE", reason
        result.errorCode = RLContractTrade.toMoveErrorCode(nil, reason)
        return result
    end
    result.stage = "READY"
    result.amount = context.amount
    result.fillType = fillTypeName(context.fillType)
    result.plan = { fee = context.plan.fee, creditUse = context.plan.creditUse, cashDue = context.plan.cashDue,
        moneyBefore = context.plan.moneyBefore, moneyAfter = context.plan.moneyAfter }
    result.entries = {}
    for i, entry in ipairs(context.plan.entries) do
        result.entries[i] = { key = entry.key, amount = entry.amount, fee = entry.fee }
    end
    local binding = context.targetBinding
    result.order = { id = binding.orderId, recipeId = binding.recipeId, feeCredit = binding.order.feeCredit,
        feePerBatch = binding.recipe.feePerBatch, inputPerBatch = binding.recipeInput.amount }
    result.expected = { fee = binding.expected.fee, creditUse = binding.expected.creditUse, cash = binding.expected.cash }
    return result
end
