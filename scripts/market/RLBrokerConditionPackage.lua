-- Candidate Broker packages. Compilation proves executable structure, never real
-- model reachability (U51), price calibration, or permission to publish an order.
RLBrokerConditionPackage = {}
local P = RLBrokerConditionPackage
local finite=RLPlain.finite
local text=RLPlain.text
local function requireValue(ok, reason) if not ok then error(reason, 0) end end
local fields = {
    ["s.ageMonths"] = "number", ["s.health"] = "number", ["s.weightKg"] = "number",
    ["s.gender"] = "string", ["s.castrated"] = "boolean",
    ["s.production.finishScore"] = "number", ["s.production.bcs"] = "number",
    ["s.production.fatClass"] = "string", ["s.production.slaughterReferenceKg"] = "number",
    ["s.reproductive.pregnant"] = "boolean", ["s.reproductive.lactating"] = "boolean",
    ["s.reproductive.parity"] = "number", ["s.reproductive.monthsSinceLastBirth"] = "number",
    ["s.reproductive.isParent"] = "boolean",
    ["f.weaned"] = "boolean", ["f.developmentReady"] = "boolean",
    ["f.finished"] = "boolean", ["f.currentBreedingReady"] = "boolean",
    ["f.breedingStock"] = "boolean", ["f.slaughterBasisAvailable"] = "boolean",
    ["f.minimumPurchaseKg"] = "number", ["f.ageReferenceKg"] = "number",
    ["f.standardFinishKg"] = "number", ["f.breedingMinimumWeightKg"] = "number",
    ["f.actualMinimumAgeMonths"] = "number", ["f.useExitAgeMonths"] = "number",
    ["f.remainingUseMonths"] = "number", ["f.pregnancyProgress"] = "number",
    ["f.finishingStage"] = "string", ["f.breedingStage"] = "string",
}
local genes = {quality = true, productivity = true, fertility = true, health = true}
local weights = {
    ["cattle.dairy"] = {quality = 0, productivity = 0.4, fertility = 0.3, health = 0.3},
    ["cattle.terminal"] = {quality = 0.7, productivity = 0, fertility = 0.2, health = 0.1},
    ["cattle.maternal"] = {quality = 0.2, productivity = 0, fertility = 0.5, health = 0.3},
    ["sheep.dairy"] = {quality = 0, productivity = 0.45, fertility = 0.3, health = 0.25},
    ["sheep.terminal"] = {quality = 0.65, productivity = 0, fertility = 0.25, health = 0.1},
    ["sheep.maternal"] = {quality = 0.15, productivity = 0, fertility = 0.55, health = 0.3},
}
local kindSpecies,kindGroup,bounds,kinds={},{},{},{}
for _,package in ipairs(RLSpeciesCatalog.packages()) do
    local b=package.bounds
    kindSpecies[package.kind],kindGroup[package.kind],bounds[package.kind]=package.species,package.group,b
    kinds[package.kind]={package.species,package.group,b[1],package.defaultMaxAge or b[2],b[3]}
end
function P.indexWeights(id) return weights[id] and RLMarketData.copy(weights[id]) or nil end
function P.validateWeights(w)
    if type(w) ~= "table" or getmetatable(w) ~= nil then return false end
    local sum = 0
    for gene, weight in pairs(w) do if not genes[gene] or not finite(weight) or weight < 0 then return false end; sum = sum + weight end
    return finite(sum) and math.abs(sum - 1) <= 1e-12
end
local dense=RLPlain.dense
local function compile(raw)
    local p, reason = RLMarketData.copy(raw); requireValue(p ~= nil, reason)
    requireValue(p.schemaVersion == 1 and text(p.id) and p.candidate == true, "INVALID_PACKAGE_HEADER")
    p.revision = nil
    local allowed = {schemaVersion = true, id = true, candidate = true, speciesKey = true, purposeGroup = true, kind = true, tier = true, allowedProductionClasses = true, breedScope = true, requiredBreedId = true, breedingObjective = true, genetics = true, conditions = true}
    for key in pairs(p) do requireValue(allowed[key], "UNKNOWN_PACKAGE_FIELD:" .. tostring(key)) end
    requireValue(p.speciesKey == "COW" or p.speciesKey == "SHEEP" or p.speciesKey == "PIG", "UNSUPPORTED_PACKAGE_SPECIES")
    requireValue(kindSpecies[p.kind] == p.speciesKey, "INVALID_PACKAGE_KIND")
    requireValue(p.purposeGroup == "GROWER" or p.purposeGroup == "FINISHED" or p.purposeGroup == "BREEDING", "INVALID_PURPOSE_GROUP")
    requireValue(p.purposeGroup == kindGroup[p.kind], "KIND_GROUP_MISMATCH")
    if p.purposeGroup~="BREEDING" or p.kind=="cattleLactating" then
        requireValue(p.tier=="standard","INVALID_COMMODITY_OR_LACTATION_TIER")
    end
    requireValue(p.breedScope == "ANY" or p.breedScope == "SPECIFIC", "INVALID_BREED_SCOPE")
    requireValue(p.breedScope ~= "ANY" or p.purposeGroup == "GROWER", "ANY_REQUIRES_GROWER")
    requireValue((p.breedScope == "SPECIFIC" and text(p.requiredBreedId)) or (p.breedScope == "ANY" and p.requiredBreedId == nil), "INVALID_REQUIRED_BREED")
    if p.breedScope == "SPECIFIC" then
        local species, breed = p.requiredBreedId:match("^([^:]+):([^:]+)$")
        requireValue(species == p.speciesKey and text(breed) and not breed:find("[%s%c]"), "INVALID_CANONICAL_BREED")
    end
    requireValue(dense(p.allowedProductionClasses) and #p.allowedProductionClasses > 0, "EMPTY_CLASSES")
    local seen = {}
    for _, class in ipairs(p.allowedProductionClasses) do requireValue((class == "DAIRY" or class == "BEEF" or class == "DUAL") and not seen[class], "INVALID_CLASS"); seen[class] = true end
    if p.kind == "cattleLactating" then requireValue(not seen.BEEF, "LACTATION_REQUIRES_DAIRY_OR_DUAL_CLASS") end
    requireValue(dense(p.conditions) and #p.conditions > 0, "EMPTY_CONDITIONS")
    local constraints = {}
    for _, condition in ipairs(p.conditions) do
        requireValue(type(condition) == "table" and fields[condition.field] ~= nil, "UNKNOWN_PREDICATE_FIELD")
        local c = condition
        local allowedCondition = {field = true, op = true, value = true, min = true, max = true, minExclusive = true, maxExclusive = true, reference = true, values = true}
        for key in pairs(c) do requireValue(allowedCondition[key], "UNKNOWN_PREDICATE_ATTRIBUTE") end
        requireValue((c.op == "eq" or c.value == nil) and (c.op == "set" or c.values == nil), "UNUSED_PREDICATE_ATTRIBUTE")
        requireValue((c.op == "ratio" or c.op == "atLeast" or c.op == "atMost" or c.reference == nil), "UNUSED_REFERENCE")
        requireValue((c.op == "range" or c.op == "ratio") or (c.min == nil and c.max == nil and c.minExclusive == nil and c.maxExclusive == nil), "UNUSED_RANGE")
        if c.op == "range" or c.op == "ratio" then
            requireValue(fields[c.field] == "number" and (c.min ~= nil or c.max ~= nil), "INVALID_RANGE")
            requireValue((c.min == nil or finite(c.min)) and (c.max == nil or finite(c.max)) and (c.min == nil or c.max == nil or c.min <= c.max), "EMPTY_RANGE")
            requireValue((c.minExclusive == nil or type(c.minExclusive) == "boolean") and (c.maxExclusive == nil or type(c.maxExclusive) == "boolean"), "INVALID_RANGE_BOUNDARY")
            if c.min ~= nil and c.max ~= nil and c.min == c.max then requireValue(not c.minExclusive and not c.maxExclusive, "EMPTY_RANGE") end
            if c.op == "ratio" then requireValue(fields[c.reference] == "number", "INVALID_REFERENCE") end
        elseif c.op == "eq" then
            requireValue(type(c.value) == fields[c.field], "INVALID_EQUALITY")
            if c.field == "s.gender" then requireValue(c.value == "male" or c.value == "female", "INVALID_GENDER") end
        elseif c.op == "set" then
            requireValue(fields[c.field] == "string" and dense(c.values) and #c.values > 0, "INVALID_SET")
            local set = {}; for _, value in ipairs(c.values) do requireValue(text(value) and not set[value], "INVALID_SET"); set[value] = true end
        elseif c.op == "atLeast" or c.op == "atMost" then requireValue(fields[c.field] == "number" and fields[c.reference] == "number", "INVALID_REFERENCE")
        else requireValue(false, "UNKNOWN_PREDICATE") end
        if c.op == "eq" or c.op == "range" then
            local list = constraints[c.field] or {}; constraints[c.field] = list; list[#list + 1] = c
        end
    end
    for _, list in pairs(constraints) do
        local eq, low, high, lowExclusive, highExclusive = nil, -math.huge, math.huge, false, false
        for _, c in ipairs(list) do
            if c.op == "eq" then requireValue(eq == nil or eq == c.value, "CONTRADICTORY_EQUALITY"); eq = c.value
            else
                if c.min ~= nil and c.min >= low then lowExclusive = c.minExclusive or (c.min == low and lowExclusive); low = c.min end
                if c.max ~= nil and c.max <= high then highExclusive = c.maxExclusive or (c.max == high and highExclusive); high = c.max end
            end
        end
        requireValue(low < high or (low == high and not lowExclusive and not highExclusive), "CONTRADICTORY_RANGE")
        if type(eq) == "number" then requireValue((eq > low or (eq == low and not lowExclusive)) and (eq < high or (eq == high and not highExclusive)), "CONTRADICTORY_EQUALITY_RANGE") end
    end
    local function eq(field) for _, c in ipairs(p.conditions) do if c.field == field and c.op == "eq" then return c.value end end end
    local function parityZero() for _, c in ipairs(p.conditions) do if c.field == "s.reproductive.parity" and ((c.op == "eq" and c.value == 0) or (c.op == "range" and c.max == 0)) then return true end end end
    local function condition(field, op, reference)
        for _, c in ipairs(p.conditions) do if c.field == field and c.op == op and (reference == nil or c.reference == reference) then return c end end
    end
    local function required(field, op, reference)
        local c = condition(field, op, reference); requireValue(c ~= nil, "MISSING_REQUIRED_PREDICATE:" .. field); return c
    end
    local function window(field, low, high, op, reference)
        local c = required(field, op or "range", reference)
        requireValue((low == nil or (c.min ~= nil and c.min >= low)) and (high == nil or (c.max ~= nil and c.max <= high)), "PACKAGE_WINDOW_RELAXED:" .. field)
        return c
    end
    local age, health = required("s.ageMonths", "range"), required("s.health", "range")
    local bound = bounds[p.kind]
    requireValue(age.min ~= nil and age.min >= bound[1] and age.max ~= nil and age.max <= bound[2] and health.min ~= nil and health.min >= bound[3], "AGE_OR_HEALTH_THRESHOLD_RELAXED")
    required("s.ageMonths", "atLeast", "f.actualMinimumAgeMonths")
    required("s.weightKg", "atLeast", "f.minimumPurchaseKg")
    if p.kind ~= "cattlePregnant" then requireValue(eq("s.reproductive.pregnant") == false, "MISSING_NONPREGNANT_CONDITION") end
    if p.kind ~= "cattlePregnant" and p.kind ~= "cattleLactating" then requireValue(eq("s.reproductive.lactating") == false, "MISSING_NONLACTATING_CONDITION") end
    if p.purposeGroup == "GROWER" then requireValue(eq("f.weaned") == true and eq("f.developmentReady") == true and eq("f.finished") == false, "INCOMPLETE_GROWER_PACKAGE") end
    if p.purposeGroup == "FINISHED" then requireValue(eq("f.slaughterBasisAvailable") == true, "MISSING_SLAUGHTER_BASIS") end
    if p.kind == "cattleStore" then
        requireValue(eq("s.gender") == "male", "STORE_REQUIRES_MALE_PACKAGE")
        local ratio = required("s.weightKg", "ratio", "s.production.slaughterReferenceKg")
        local finish = required("s.production.finishScore", "range")
        requireValue(ratio.min ~= nil and ratio.min >= 0.55 and ratio.max ~= nil and ratio.max <= 0.80 and finish.max ~= nil and (finish.max < 65 or (finish.max == 65 and finish.maxExclusive)), "STORE_WINDOW_RELAXED")
    elseif p.kind == "cattleWeaned" then window("s.weightKg", 0.75, 1.20, "ratio", "f.ageReferenceKg")
    elseif p.kind == "cattleFinished" then
        window("s.weightKg", 0.85, 1.20, "ratio", "f.standardFinishKg")
        local ratio = required("s.weightKg", "ratio", "s.production.slaughterReferenceKg")
        requireValue(ratio.min ~= nil and ratio.min >= 0.95, "FINISHED_INDIVIDUAL_REFERENCE_RELAXED")
        window("s.production.finishScore", 65, 80)
    elseif p.kind == "pigGrower" then window("s.weightKg", 0.20, 0.75, "ratio", "f.standardFinishKg"); requireValue(eq("f.breedingStock") == false, "GROWER_IS_BREEDING_STOCK")
    elseif p.kind == "pigFinished" then window("s.weightKg", 0.90, 1.15, "ratio", "f.standardFinishKg"); required("f.finishingStage", "set"); requireValue(parityZero(), "FINISHED_REQUIRES_ZERO_PARITY")
    elseif p.kind == "lambGrower" then window("s.weightKg", 0.45, 0.85, "ratio", "f.standardFinishKg")
    elseif p.kind == "lambFinished" then
        window("s.weightKg", 0.85, 1.15, "ratio", "f.standardFinishKg"); requireValue(parityZero(), "FINISHED_REQUIRES_ZERO_PARITY")
        local allowedFat = {["2"] = true, ["3L"] = true, ["3H"] = true}
        for _, class in ipairs(required("s.production.fatClass", "set").values) do requireValue(allowedFat[class], "INVALID_LAMB_FAT_CLASS") end
    end
    requireValue(not (eq("s.gender") == "male" and (eq("s.reproductive.pregnant") == true or eq("s.reproductive.lactating") == true)), "MALE_REPRODUCTIVE_CONTRADICTION")
    requireValue(not (parityZero() and eq("s.reproductive.lactating") == true), "LACTATION_REQUIRES_PARITY")
    requireValue(not (p.purposeGroup == "GROWER" and eq("f.finished") == true), "GROWER_CANNOT_BE_FINISHED")
    if p.purposeGroup == "BREEDING" then
        requireValue(p.breedingObjective == "DAIRY" or p.breedingObjective == "TERMINAL" or p.breedingObjective == "MATERNAL", "INVALID_BREEDING_OBJECTIVE")
        local g = p.genetics
        requireValue(type(g) == "table" and finite(g.indexMin) and g.indexMin >= 0.25 and g.indexMin <= 1.75, "INVALID_GENETICS")
        for key in pairs(g) do requireValue(key == "indexMin" or key == "indexId" or key == "weights" or key == "geneMin", "UNKNOWN_GENETICS_FIELD") end
        local prefix = p.speciesKey == "COW" and "cattle" or p.speciesKey == "SHEEP" and "sheep" or "pig"
        local resolved
        if p.speciesKey == "PIG" then
            requireValue(g.indexId == nil, "PIG_REQUIRES_EXPLICIT_INDEX_WEIGHTS")
            resolved = g.weights
        else
            requireValue(g.indexId == prefix .. "." .. p.breedingObjective:lower(), "INDEX_OBJECTIVE_MISMATCH")
            resolved = P.indexWeights(g.indexId)
        end
        requireValue(P.validateWeights(resolved), "INVALID_INDEX_WEIGHTS")
        if g.indexId ~= nil and g.weights ~= nil then requireValue(RLMarketData.fingerprint(g.weights) == RLMarketData.fingerprint(resolved), "CONFLICTING_INDEX_WEIGHTS") end
        requireValue(type(g.geneMin) == "table", "MISSING_GENE_MINIMA")
        for gene, value in pairs(g.geneMin) do requireValue(genes[gene] and (resolved[gene] or 0) > 0 and finite(value) and value >= 0.25 and value <= 1.75, "INVALID_GENE_MINIMUM") end
        g.weights = resolved
        required("s.ageMonths", "atMost", "f.useExitAgeMonths"); required("s.weightKg", "atLeast", "f.breedingMinimumWeightKg")
        if p.speciesKey == "PIG" then required("f.breedingStage", "set") else window("s.production.bcs", p.kind == "ramSire" and 3 or 2.5, 3.5) end
        local sire = p.kind == "cattleSire" or p.kind == "pigSire" or p.kind == "ramSire"
        if sire then
            requireValue(eq("s.gender") == "male" and eq("s.castrated") == false and eq("f.currentBreedingReady") == true, "INCOMPLETE_SIRE_PACKAGE")
            window("f.remainingUseMonths", p.speciesKey == "COW" and 24 or 12)
            local tiers = {standard = {1.20, 1.15, 1, 0.90}, quality = {1.35, 1.30, 1.05, 1}, elite = {1.50, 1.45, 1.15, 1.10}}
            local tier = tiers[p.tier]; requireValue(tier ~= nil, "UNKNOWN_TIER")
            local main = p.breedingObjective == "DAIRY" and "productivity" or p.breedingObjective == "TERMINAL" and "quality" or "fertility"
            requireValue(g.indexMin >= tier[1] and (g.geneMin[main] or 0) >= tier[2] and (g.geneMin.fertility or 0) >= tier[3] and (g.geneMin.health or 0) >= tier[4], "SIRE_GENETIC_THRESHOLDS_RELAXED")
        else
            requireValue(eq("s.gender") == "female", "FEMALE_PACKAGE_REQUIRES_FEMALE")
            if p.kind == "cattlePregnant" then
                requireValue(eq("s.reproductive.pregnant") == true and condition("f.currentBreedingReady", "eq") == nil, "PREGNANCY_NOT_CURRENT_REBREEDING")
                window("f.pregnancyProgress", 0.20, 0.70); window("s.reproductive.parity", 0, 4)
            elseif p.kind == "cattleLactating" then
                requireValue(p.breedingObjective == "DAIRY" and eq("s.reproductive.lactating") == true and eq("s.reproductive.isParent") == true, "INCOMPLETE_LACTATION_PACKAGE")
                local lactation = window("s.reproductive.monthsSinceLastBirth", 0, 6)
                requireValue(lactation.max < 6 or lactation.maxExclusive, "LACTATION_MONTH7_NOT_ALLOWED")
                window("s.reproductive.parity", 1, 4)
                requireValue(g.indexMin >= 1.10 and (g.geneMin.productivity or 0) >= 1.15 and g.geneMin.fertility == 0.95 and (g.geneMin.health or 0) >= 0.90, "INVALID_LACTATION_GENETICS")
            else requireValue(parityZero() and eq("f.developmentReady") == true, "INCOMPLETE_REPLACEMENT_PACKAGE") end
            if p.kind ~= "cattleLactating" then
                requireValue(p.tier == "standard" or p.tier == "quality", "UNKNOWN_TIER")
                local quality = p.tier == "quality"
                requireValue(g.indexMin >= (quality and 1.20 or 1.05) and (g.geneMin.fertility or 0) >= (quality and 1.10 or 1) and (g.geneMin.health or 0) >= (quality and 1 or 0.90), "FEMALE_GENETIC_THRESHOLDS_RELAXED")
                if p.breedingObjective == "DAIRY" then requireValue((g.geneMin.productivity or 0) >= (quality and 1.20 or 1.05), "FEMALE_MILK_GENE_RELAXED") end
            end
        end
    else requireValue(p.genetics == nil and p.breedingObjective == nil, "COMMODITY_CANNOT_INHERIT_BREEDING_GENETICS") end
    table.sort(p.conditions, function(a, b) return assert(RLMarketData.fingerprint(a)) < assert(RLMarketData.fingerprint(b)) end)
    p.revision = assert(RLMarketData.fingerprint(p))
    return p
end
function P.compile(raw)
    local ok, result = pcall(compile, raw)
    if not ok then return nil, tostring(result) end
    return result
end

function P.candidate(kind, options)
    local spec = kinds[kind]; if spec == nil then return nil, "UNKNOWN_PACKAGE_KIND" end
    local o, failure = RLMarketData.copy(options or {})
    if o == nil or type(o) ~= "table" then return nil, failure or "INVALID_OPTIONS" end
    local p = {schemaVersion = 1, candidate = true, id = o.id or kind, kind = kind, tier = o.tier or "standard", speciesKey = spec[1], purposeGroup = spec[2], allowedProductionClasses = o.allowedProductionClasses, breedScope = o.breedScope or (spec[2] == "GROWER" and "ANY" or "SPECIFIC"), requiredBreedId = o.requiredBreedId, conditions = {}}
    local function add(field, op, a, b, exclusive)
        local c = {field = field, op = op}
        if op == "range" then c.min, c.max, c.maxExclusive = a, b, exclusive
        elseif op == "ratio" then c.reference, c.min, c.max = a, b[1], b[2]
        elseif op == "set" then c.values = a
        elseif op == "atLeast" or op == "atMost" then c.reference = a
        else c.value = a end
        p.conditions[#p.conditions + 1] = c
    end
    local maxAge = spec[4]
    if o.slowMaturing and kind == "cattleStore" then maxAge = 26 end
    if o.slowMaturing and kind == "cattleFinished" then maxAge = 36 end
    add("s.ageMonths", "range", spec[3], maxAge); add("s.health", "range", spec[5])
    add("s.ageMonths", "atLeast", "f.actualMinimumAgeMonths")
    add("s.weightKg", "atLeast", "f.minimumPurchaseKg")
    if spec[2] == "GROWER" then
        add("f.weaned", "eq", true); add("f.developmentReady", "eq", true); add("f.finished", "eq", false)
    end
    if kind ~= "cattlePregnant" then add("s.reproductive.pregnant", "eq", false) end
    if kind ~= "cattleLactating" and kind ~= "cattlePregnant" then add("s.reproductive.lactating", "eq", false) end
    if kind == "cattleWeaned" then add("s.weightKg", "ratio", "f.ageReferenceKg", {0.75, 1.20}) end
    if kind == "cattleStore" then
        add("s.gender", "eq", "male"); add("s.weightKg", "ratio", "s.production.slaughterReferenceKg", {0.55, 0.80}); add("s.production.finishScore", "range", 0, 65, true)
    end
    if kind == "cattleFinished" then
        add("s.weightKg", "ratio", "f.standardFinishKg", {0.85, 1.20}); add("s.weightKg", "ratio", "s.production.slaughterReferenceKg", {0.95, nil}); add("s.production.finishScore", "range", 65, 80)
    end
    if kind == "pigGrower" then add("s.weightKg", "ratio", "f.standardFinishKg", {0.20, 0.75}); add("f.breedingStock", "eq", false) end
    if kind == "pigFinished" then
        add("s.weightKg", "ratio", "f.standardFinishKg", {0.90, 1.15}); add("f.finishingStage", "set", o.finishingStages); add("s.reproductive.parity", "eq", 0)
    end
    if kind == "lambGrower" then add("s.weightKg", "ratio", "f.standardFinishKg", {0.45, 0.85}) end
    if kind == "lambFinished" then
        add("s.weightKg", "ratio", "f.standardFinishKg", {0.85, 1.15}); add("s.production.fatClass", "set", {"2", "3L", "3H"}); add("s.reproductive.parity", "eq", 0)
    end
    if spec[2] == "FINISHED" then add("f.slaughterBasisAvailable", "eq", true) end
    if spec[2] == "BREEDING" then
        p.breedingObjective = o.breedingObjective
        add("s.ageMonths", "atMost", "f.useExitAgeMonths")
        add("s.weightKg", "atLeast", "f.breedingMinimumWeightKg")
        if spec[1] == "PIG" then add("f.breedingStage", "set", o.breedingStages)
        else add("s.production.bcs", "range", kind == "ramSire" and 3 or 2.5, 3.5) end
        local sire = kind == "cattleSire" or kind == "pigSire" or kind == "ramSire"
        local tier = o.tier or "standard"
        if sire then
            add("s.gender", "eq", "male"); add("s.castrated", "eq", false); add("f.currentBreedingReady", "eq", true)
            add("f.remainingUseMonths", "range", spec[1] == "COW" and 24 or 12)
            local tiers = {standard = {1.20, 1.15, 1, 0.90}, quality = {1.35, 1.30, 1.05, 1}, elite = {1.50, 1.45, 1.15, 1.10}}
            local g = tiers[tier]; if g == nil then return nil, "UNKNOWN_TIER" end
            local main = o.breedingObjective == "DAIRY" and "productivity" or o.breedingObjective == "TERMINAL" and "quality" or "fertility"
            p.genetics = {indexMin = g[1], geneMin = {fertility = g[3], health = g[4]}}
            p.genetics.geneMin[main] = math.max(p.genetics.geneMin[main] or 0, g[2])
        else
            add("s.gender", "eq", "female")
            if kind == "cattlePregnant" then add("s.reproductive.pregnant", "eq", true); add("f.pregnancyProgress", "range", 0.20, 0.70); add("s.reproductive.parity", "range", 0, 4)
            elseif kind == "cattleLactating" then
                add("s.reproductive.lactating", "eq", true); add("s.reproductive.isParent", "eq", true); add("s.reproductive.parity", "range", 1, 4)
                -- Existing counter is zero at birth: displayed lactation months 1–6 = [0,6).
                add("s.reproductive.monthsSinceLastBirth", "range", 0, 6, true)
            else add("s.reproductive.parity", "eq", 0); add("f.developmentReady", "eq", true) end
            if kind == "cattleLactating" then
                p.breedingObjective = "DAIRY"; p.genetics = {indexMin = 1.10, geneMin = {productivity = 1.15, fertility = 0.95, health = 0.90}}
            else
                if tier ~= "standard" and tier ~= "quality" then return nil, "UNKNOWN_TIER" end
                local quality = tier == "quality"
                p.genetics = {indexMin = quality and 1.20 or 1.05, geneMin = {fertility = quality and 1.10 or 1, health = quality and 1 or 0.90}}
                if o.breedingObjective == "DAIRY" then p.genetics.geneMin.productivity = quality and 1.20 or 1.05 end
            end
        end
        local member=RLSpeciesCatalog.get(spec[1])
        local prefix=member and member.indexPrefix
        if prefix and p.breedingObjective then p.genetics.indexId = prefix .. "." .. p.breedingObjective:lower() else p.genetics.weights = o.indexWeights end
    end
    return p
end
