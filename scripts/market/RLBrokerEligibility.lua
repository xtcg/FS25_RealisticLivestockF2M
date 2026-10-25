-- Broker read-only qualification. All game/permission/owner/lock/quota facts are
-- explicit inputs; absent capabilities are UNKNOWN, never invented zero values.
RLBrokerEligibility = {}
local E = RLBrokerEligibility
local finite=RLPlain.finite
local function contains(list, value) for _, item in ipairs(list or {}) do if item == value then return true end end return false end
local function result() return {eligible = false, status = "UNKNOWN", checks = {}, failures = {}, unknowns = {}} end
local function record(out, code, status, actual, expected, capability)
    local check = {code = code, status = status, actual = actual, expected = expected, capability = capability}
    out.checks[#out.checks + 1] = check
    if status == "FAIL" then out.failures[#out.failures + 1] = check end
    if status == "UNKNOWN" then out.unknowns[#out.unknowns + 1] = check end
end
local function finish(out)
    out.eligible = #out.failures == 0 and #out.unknowns == 0
    out.status = #out.failures > 0 and "FAIL" or (#out.unknowns > 0 and "UNKNOWN" or "PASS")
    return out
end
local function gene(snapshot, name)
    local value = type(snapshot.genes) == "table" and snapshot.genes[name] or nil
    local caps = type(snapshot.traitCapabilities) == "table" and snapshot.traitCapabilities or {}
    if caps["gene_" .. name] ~= true or not finite(value) or value < 0.25 or value > 1.75 then return nil end
    return value
end
function E.selectionIndex(snapshot, idOrWeights)
    local out = result()
    local s = RLMarketData.copy(snapshot)
    local w = type(idOrWeights) == "string" and RLBrokerConditionPackage.indexWeights(idOrWeights) or RLMarketData.copy(idOrWeights)
    if type(s) ~= "table" or not RLBrokerConditionPackage.validateWeights(w) then record(out, "INVALID_INDEX_INPUT", "UNKNOWN"); return finish(out) end
    local total, complete = 0, true
    for _, key in ipairs({"quality", "productivity", "fertility", "health"}) do
        local weight = w[key] or 0
        if weight > 0 then
            local value = gene(s, key)
            if value == nil then complete = false; record(out, "GENE_" .. key, "UNKNOWN", nil, "0.25..1.75", "gene_" .. key)
            else total = total + weight * value; record(out, "GENE_" .. key, "PASS", value, weight) end
        end
    end
    if complete then out.value = total end
    return finish(out)
end
local capFor = {
    ["s.health"] = "health", ["s.weightKg"] = "weight", ["s.castrated"] = "castrated",
    ["s.production.finishScore"] = "finishScore", ["s.production.bcs"] = "bcs",
    ["s.production.fatClass"] = "fatClass", ["s.production.slaughterReferenceKg"] = "slaughterReference",
    ["s.reproductive.pregnant"] = "pregnancy", ["s.reproductive.lactating"] = "lactation", ["s.reproductive.parity"] = "parity",
}
local function read(snapshot, context, path)
    if path:sub(1, 2) == "f." then
        local name = path:sub(3)
        if not context.factCapabilities or context.factCapabilities[name] ~= true then return nil, "fact:" .. name end
        local value = context.facts and context.facts[name]
        return value, "fact:" .. name
    end
    local cap = capFor[path]
    if cap and (not snapshot.traitCapabilities or snapshot.traitCapabilities[cap] ~= true) then return nil, cap end
    local value = snapshot
    for segment in path:sub(3):gmatch("[^%.]+") do if type(value) ~= "table" then return nil, cap or path end; value = value[segment] end
    return value, cap or path
end
local function evaluate(snapshot, rules, context)
    local out = result()
    local s, sReason = RLMarketData.copy(snapshot)
    local c, cReason = RLMarketData.copy(context)
    local p, reason = RLBrokerConditionPackage.compile(rules)
    if s == nil or c == nil or p == nil then record(out, "INVALID_INPUT", "UNKNOWN", nil, reason or sReason or cReason); return finish(out) end
    out.packageRevision = p.revision
    local function bool(code, value)
        record(out, code, type(value) ~= "boolean" and "UNKNOWN" or (value and "PASS" or "FAIL"), value, true, code)
    end
    for _, key in ipairs({"permissionGranted", "ownershipVerified", "identityVerified", "unlocked", "orderOpen", "sourceSupported"}) do bool(key, c[key]) end
    record(out, "identityKey", type(s.identityKey) ~= "string" and "UNKNOWN" or (s.identityKey:match("%S") and "PASS" or "UNKNOWN"), s.identityKey, "stable full animal key", "identity")
    for _, level in ipairs({"order", "species", "breed"}) do
        local n = c.quota and c.quota[level]
        record(out, "quota." .. level, (not finite(n) or n < 0 or n % 1 ~= 0) and "UNKNOWN" or (n >= 1 and "PASS" or "FAIL"), n, ">=1", "quota:" .. level)
    end
    local trade = s.eligibility and s.eligibility.tradeAllowed
    if not s.traitCapabilities or s.traitCapabilities.tradeEligibility ~= true then trade = nil end
    bool("tradeAllowed", trade)
    local function match(code, actual, expected, accepted)
        record(out, code, actual == nil and "UNKNOWN" or (accepted and "PASS" or "FAIL"), actual, expected, code)
    end
    match("species", s.speciesKey, p.speciesKey, s.speciesKey == p.speciesKey)
    match("productionClass", s.productionClass, p.allowedProductionClasses, contains(p.allowedProductionClasses, s.productionClass))
    if p.breedScope == "SPECIFIC" then match("breed", s.breedId, p.requiredBreedId, s.breedId == p.requiredBreedId) end
    if p.purposeGroup == "BREEDING" then
        if not s.traitCapabilities or s.traitCapabilities.reproduction ~= true or type(s.supportedBreedingRoles) ~= "table" then record(out, "breedingRole", "UNKNOWN", nil, p.breedingObjective, "reproduction")
        else match("breedingRole", s.supportedBreedingRoles, p.breedingObjective, contains(s.supportedBreedingRoles, p.breedingObjective)) end
        if p.breedingObjective == "DAIRY" then
            local caps = s.traitCapabilities or {}
            for _, key in ipairs({"milkOutput", "milkProductivity"}) do record(out, key, caps[key] == true and "PASS" or "UNKNOWN", caps[key], true, key) end
        end
    end
    for index, condition in ipairs(p.conditions) do
        local value, capability = read(s, c, condition.field)
        local actual, passed = value, nil
        local op = condition.op
        if op == "eq" then if type(value) == type(condition.value) then passed = value == condition.value end
        elseif op == "set" then if type(value) == "string" then passed = contains(condition.values, value) end
        else
            if finite(value) then
                if op == "ratio" or op == "atLeast" or op == "atMost" then
                    local ref, refCap = read(s, c, condition.reference)
                    if not finite(ref) or ref < 0 or (op == "ratio" and ref == 0) then value = nil; capability = refCap
                    elseif op == "ratio" then value = value / ref
                    elseif op == "atLeast" then passed = value >= ref
                    else passed = value <= ref end
                end
                if finite(value) and (op == "range" or op == "ratio") then
                    passed = (condition.min == nil or value > condition.min or (value == condition.min and not condition.minExclusive))
                        and (condition.max == nil or value < condition.max or (value == condition.max and not condition.maxExclusive))
                    actual = value
                end
            end
        end
        record(out, "condition:" .. index .. ":" .. condition.field, passed == nil and "UNKNOWN" or (passed and "PASS" or "FAIL"), actual, condition, capability)
    end
    if p.genetics then
        local g = p.genetics
        local index = E.selectionIndex(s, g.weights)
        out.selectionIndex = index.value
        for _, check in ipairs(index.unknowns) do record(out, check.code, check.status, check.actual, check.expected, check.capability) end
        record(out, "selectionIndex", index.value == nil and "UNKNOWN" or (index.value >= g.indexMin and "PASS" or "FAIL"), index.value, g.indexMin, "geneticIndex")
        for _, key in ipairs({"quality", "productivity", "fertility", "health"}) do
            local minimum = g.geneMin[key]
            if minimum ~= nil then
                local value = gene(s, key)
                record(out, "geneMinimum:" .. key, value == nil and "UNKNOWN" or (value >= minimum and "PASS" or "FAIL"), value, minimum, "gene_" .. key)
            end
        end
    end
    return finish(out)
end
function E.evaluate(snapshot, rules, context)
    local ok, out = pcall(evaluate, snapshot, rules, context)
    if not ok then out = result(); record(out, "INVALID_INPUT", "UNKNOWN"); return finish(out) end
    return out
end
