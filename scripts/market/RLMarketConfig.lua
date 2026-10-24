-- Detached, whole-file market configuration. XML loading/path selection belongs to
-- the caller; this module never reads settings, clocks, animals, or published quotas.
RLMarketConfig = {}
local C = RLMarketConfig
C.VERSION = 1
C.SETTINGS_PATH = "modSettings/FS25_RealisticLivestockRM/livestockMarket.xml"
C.SCALARS = {"minSpreadRate", "minSpreadAbsolute", "maxHoldingMonths", "holdingMonths", "monthlyCost", "tradeCost", "fixedProfit", "profitRate", "commissionRate", "discountRate", "retailServiceFactor"}
local scalarSet = {}; for _, k in ipairs(C.SCALARS) do scalarSet[k] = true end
local ratios = {minSpreadRate = true, profitRate = true, commissionRate = true, discountRate = true}
local policies = {costModel = {fixedMonthlyCurve = true}, resaleModel = {productionRetail = true}, fallbackModel = {commodityWholesale = true}, profitModel = {fixedPlusRate = true}}
local purposes = {YOUNG_STOCK = true, STORE_STOCK = true, FINISHED_STOCK = true, BREEDING_FEMALE = true, BREEDING_MALE = true, CULL_STOCK = true}
local finite=RLPlain.finite
local function stringValue(x) return type(x) == "string" and x:match("%S") ~= nil end
local function integer(x, minimum) return finite(x) and x % 1 == 0 and x >= minimum end
local function requireValue(ok, reason) if not ok then error(reason, 0) end end
local function dense(list)
    if type(list) ~= "table" then return false end
    local count = 0
    for k in pairs(list) do if not integer(k, 1) or k > #list then return false end; count = count + 1 end
    return count == #list
end
local function plainCopy(v, seen)
    local t = type(v)
    requireValue(t == "table" or t == "string" or t == "number" or t == "boolean" or t == "nil", "INVALID_WIRE_VALUE")
    if t == "number" then requireValue(finite(v), "NON_FINITE") end
    if t ~= "table" then return v end
    requireValue(getmetatable(v) == nil and not seen[v], "INVALID_WIRE_TABLE")
    seen[v] = true
    local result = {}
    for k, item in pairs(v) do
        requireValue(type(k) == "string" or integer(k, 1), "INVALID_KEY")
        result[k] = plainCopy(item, seen)
    end
    seen[v] = nil
    return result
end
local function canonical(v)
    if type(v) ~= "table" then
        if type(v) == "number" then return "n" .. string.format("%.17g", v == 0 and 0 or v) end
        if type(v) == "string" then return "s" .. #v .. ":" .. v end
        return v and "b1" or "b0"
    end
    local keys = {}; for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) if type(a) ~= type(b) then return type(a) < type(b) end return a < b end)
    local parts = {"{"}
    for _, k in ipairs(keys) do parts[#parts + 1] = canonical(k) .. canonical(v[k]) end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end
local function scalars(values)
    requireValue(type(values) == "table", "INVALID_SCALARS")
    for key, value in pairs(values) do
        requireValue(scalarSet[key] and finite(value) and value >= 0, "INVALID_SCALAR:" .. tostring(key))
        if ratios[key] then requireValue(value <= 1, "INVALID_RATIO:" .. key) end
        if key == "holdingMonths" or key == "maxHoldingMonths" then requireValue(integer(value, 0) and value <= 120, "INVALID_HOLDING_MONTHS") end
    end
end
local balanceNumbers = {"revision", "capacityScale", "extraOrders", "maxTotalOrders", "maxPurposeGroupsPerSpecies", "growerAnyWeight", "growerSpecificWeight", "previousMonthRepeatFactor", "eliteConditionalChance", "maxEliteOrders"}
local balanceBooleans = {"extraRequireSpecific", "preferDistinctExtraSpecies", "quotaCarryOver", "publishedOrderInformDealerBid"}
local speciesNumbers = {"baseMin", "baseMax", "secondSlotChance", "maxOrders", "monthlyHeadCap", "perBreedHeadCap", "growerHeads", "finishedHeads", "replacementHeads", "sireHeads", "eliteSireHeads"}
local headKeys = {"monthlyHeadCap", "perBreedHeadCap", "growerHeads", "finishedHeads", "replacementHeads", "sireHeads", "eliteSireHeads"}
local function validateBalance(b)
    requireValue(type(b) == "table" and b.priceBasis == "CURRENT_MARKET" and b.quotaScope == "MARKET", "INVALID_BALANCE_BASIS")
    requireValue(b.rounding == "HALF_UP_MIN_ONE", "UNKNOWN_CAPACITY_ROUNDING")
    for _, key in ipairs(balanceNumbers) do requireValue(finite(b[key]) and b[key] >= 0, "INVALID_BALANCE:" .. key) end
    for _, key in ipairs(balanceBooleans) do requireValue(type(b[key]) == "boolean", "INVALID_BALANCE:" .. key) end
    requireValue(b.extraRequireSpecific and not b.quotaCarryOver and not b.publishedOrderInformDealerBid, "UNSUPPORTED_BALANCE_SWITCH")
    requireValue(b.capacityScale > 0 and integer(b.revision, 1), "INVALID_BALANCE_SCALE")
    for _, key in ipairs({"extraOrders", "maxTotalOrders", "maxPurposeGroupsPerSpecies", "maxEliteOrders"}) do requireValue(integer(b[key], 0), "INVALID_BALANCE:" .. key) end
    requireValue(b.maxTotalOrders > 0 and b.extraOrders <= b.maxTotalOrders and b.maxPurposeGroupsPerSpecies >= 1 and b.maxPurposeGroupsPerSpecies <= 2 and b.maxEliteOrders <= b.maxTotalOrders, "INVALID_BALANCE_LIMIT")
    requireValue(b.extraOrders == 2 and b.maxTotalOrders <= 7 and b.maxEliteOrders <= 1, "UNSUPPORTED_ORDER_LAYOUT")
    requireValue(b.growerAnyWeight + b.growerSpecificWeight > 0 and b.previousMonthRepeatFactor <= 1 and b.eliteConditionalChance <= 1, "INVALID_BALANCE_WEIGHT")
    requireValue(type(b.species) == "table" and next(b.species) ~= nil, "EMPTY_BALANCE_SPECIES")
    local baseTotal = 0
    b.scaledSpecies = {}
    for species, s in pairs(b.species) do
        requireValue((species == "COW" or species == "SHEEP" or species == "PIG") and type(s) == "table", "INVALID_BALANCE_SPECIES")
        for _, key in ipairs(speciesNumbers) do requireValue(finite(s[key]) and s[key] >= 0, "INVALID_SPECIES:" .. species .. "." .. key) end
        for _, key in ipairs({"baseMin", "baseMax", "maxOrders"}) do requireValue(integer(s[key], 1), "INVALID_SPECIES_COUNT") end
        requireValue(s.baseMax >= s.baseMin and s.baseMax - s.baseMin <= 1 and s.maxOrders >= s.baseMax and s.secondSlotChance <= 1 and (s.baseMax ~= s.baseMin or s.secondSlotChance == 0), "INVALID_BASE_SLOTS")
        local maxSpeciesOrders = species == "PIG" and 2 or 3
        local maxBase = species == "PIG" and 1 or 2
        requireValue(s.baseMin == 1 and s.baseMax <= maxBase and s.maxOrders <= maxSpeciesOrders, "UNSUPPORTED_SPECIES_LAYOUT")
        requireValue(dense(s.groupWeights) and #s.groupWeights == 3, "INVALID_GROUP_WEIGHTS")
        local sum = 0
        for i, weight in pairs(s.groupWeights) do requireValue(integer(i, 1) and i <= 3 and finite(weight) and weight >= 0, "INVALID_GROUP_WEIGHTS"); sum = sum + weight end
        requireValue(sum > 0, "EMPTY_GROUP_WEIGHTS")
        local scaled = {}
        for _, key in ipairs(headKeys) do
            requireValue(integer(s[key], 1), "INVALID_HEAD_COUNT:" .. key)
            local product = s[key] * b.capacityScale
            requireValue(finite(product), "INVALID_SCALED_CAPACITY")
            scaled[key] = math.max(1, math.floor(product + 0.5))
        end
        requireValue(s.perBreedHeadCap <= s.monthlyHeadCap, "BREED_CAP_EXCEEDS_SPECIES")
        for _, key in ipairs({"growerHeads", "finishedHeads", "replacementHeads", "sireHeads", "eliteSireHeads"}) do
            -- All stock head defaults must also be publishable as SPECIFIC.
            requireValue(s[key] <= s.perBreedHeadCap and scaled[key] <= scaled.perBreedHeadCap, "ORDER_EXCEEDS_BREED_CAP:" .. species .. "." .. key)
        end
        requireValue(s.maxOrders <= b.maxTotalOrders, "SPECIES_ORDERS_EXCEED_TOTAL")
        baseTotal = baseTotal + s.baseMin
        b.scaledSpecies[species] = scaled
    end
    requireValue(baseTotal + b.extraOrders <= b.maxTotalOrders, "BASE_AND_EXTRA_EXCEED_TOTAL")
end
local function validateRaw(raw)
    local v = plainCopy(raw, {})
    requireValue(type(v) == "table" and v.schemaVersion == C.VERSION, "UNSUPPORTED_SCHEMA_VERSION")
    v.revision = nil
    requireValue(v.mode == "legacy" or v.mode == "shadow" or v.mode == "market", "INVALID_MODE")
    requireValue(type(v.layers) == "table" and type(v.layers.types) == "table" and type(v.layers.breeds) == "table" and type(v.layers.subTypes) == "table", "INVALID_LAYERS")
    scalars(v.layers.root)
    for name, values in pairs(v.layers.types) do requireValue(stringValue(name), "INVALID_TYPE"); scalars(values) end
    for typeName, breeds in pairs(v.layers.breeds) do
        requireValue(v.layers.types[typeName] ~= nil and type(breeds) == "table", "UNKNOWN_BREED_TYPE")
        for name, values in pairs(breeds) do requireValue(stringValue(name), "INVALID_BREED"); scalars(values) end
    end
    for typeName, subTypes in pairs(v.layers.subTypes) do
        requireValue(v.layers.types[typeName] ~= nil and type(subTypes) == "table", "UNKNOWN_SUBTYPE_TYPE")
        for name, values in pairs(subTypes) do requireValue(stringValue(name), "INVALID_SUBTYPE"); scalars(values) end
    end
    requireValue(type(v.curves) == "table" and type(v.profiles) == "table" and type(v.rules) == "table" and type(v.templates) == "table", "INVALID_STRUCTURES")
    for id, curve in pairs(v.curves) do
        requireValue(stringValue(id), "INVALID_CURVE_ID")
        local ok, reason = RLMarketCurve.validate(curve); requireValue(ok, "CURVE:" .. id .. ":" .. tostring(reason))
    end
    for id, p in pairs(v.profiles) do
        requireValue(stringValue(id) and type(p) == "table", "INVALID_PROFILE")
        scalars(p.values)
        for _, key in ipairs({"monthlyCost", "tradeCost", "fixedProfit"}) do requireValue(p.values[key] ~= nil, "MISSING_PROFILE_SCALAR:" .. key) end
        for key, allowed in pairs(policies) do requireValue(allowed[p[key]] == true, "UNKNOWN_POLICY:" .. key) end
        requireValue(v.curves[p.liquidityCurve] ~= nil and v.curves[p.liquidityCurve].axis == "breedingScore", "UNKNOWN_LIQUIDITY_CURVE")
        requireValue(v.curves[p.seasonCurve] ~= nil and v.curves[p.seasonCurve].axis == "calendarMonth", "UNKNOWN_SEASON_CURVE")
        requireValue(p.values.holdingMonths ~= nil and v.layers.root.maxHoldingMonths ~= nil and p.values.holdingMonths <= v.layers.root.maxHoldingMonths, "HOLDING_EXCEEDS_MAX")
    end
    local rules = {}
    for id, rule in pairs(v.rules) do
        requireValue(stringValue(id) and type(rule) == "table" and integer(rule.priority, 0) and purposes[rule.purpose] and v.profiles[rule.profile] ~= nil, "INVALID_RULE")
        local specificity = 0
        for index, field in ipairs({"animalType", "breed", "subType"}) do if rule[field] ~= nil then requireValue(stringValue(rule[field]), "INVALID_RULE_MATCH"); specificity = specificity + 2 ^ (index - 1) end end
        requireValue((rule.breed == nil and rule.subType == nil) or stringValue(rule.animalType), "RULE_REQUIRES_SPECIES")
        requireValue(rule.animalType == nil or v.layers.types[rule.animalType] ~= nil, "UNKNOWN_RULE_TYPE")
        for _, other in ipairs(rules) do
            if other.rule.purpose == rule.purpose and other.rule.priority == rule.priority and other.specificity == specificity then
                local overlap = true
                for _, field in ipairs({"animalType", "breed", "subType"}) do if rule[field] ~= nil and other.rule[field] ~= nil and rule[field] ~= other.rule[field] then overlap = false end end
                requireValue(not overlap, "AMBIGUOUS_RULE:" .. id)
            end
        end
        rules[#rules + 1] = {rule = rule, specificity = specificity}
    end
    for id, t in pairs(v.templates) do
        requireValue(stringValue(id) and type(t) == "table", "INVALID_TEMPLATE")
        requireValue(t.purposeGroup == "GROWER" or t.purposeGroup == "FINISHED" or t.purposeGroup == "BREEDING", "INVALID_PURPOSE_GROUP")
        requireValue(t.breedScope == "ANY" or t.breedScope == "SPECIFIC", "INVALID_BREED_SCOPE")
        requireValue(t.breedScope ~= "ANY" or t.purposeGroup == "GROWER", "ANY_REQUIRES_GROWER")
        requireValue(dense(t.allowedProductionClasses) and #t.allowedProductionClasses > 0, "EMPTY_PRODUCTION_CLASSES")
        local seen = {}
        for _, class in ipairs(t.allowedProductionClasses) do requireValue((class == "DAIRY" or class == "BEEF" or class == "DUAL") and not seen[class], "INVALID_PRODUCTION_CLASS"); seen[class] = true end
        if t.breedScope == "SPECIFIC" then requireValue(dense(t.eligibleBreedIds) and #t.eligibleBreedIds > 0, "EMPTY_SPECIFIC")
        else requireValue(t.eligibleBreedIds == nil, "ANY_HAS_HIDDEN_BREEDS") end
        seen = {}
        for _, breed in ipairs(t.eligibleBreedIds or {}) do requireValue(stringValue(breed) and not seen[breed], "INVALID_TEMPLATE_BREED"); seen[breed] = true end
        requireValue(v.curves[t.seasonCurve] ~= nil and v.curves[t.seasonCurve].axis == "calendarMonth" and v.profiles[t.profile] ~= nil, "UNKNOWN_TEMPLATE_REFERENCE")
    end
    validateBalance(v.brokerBalance)
    for _, t in pairs(v.templates) do requireValue(v.brokerBalance.species[t.speciesKey] ~= nil, "UNKNOWN_TEMPLATE_SPECIES") end
    -- Full canonical content avoids hash collisions and is independent of Lua table order.
    v.revision = "market-config-v1:" .. canonical(v)
    return v
end
function C.validate(raw)
    local ok, result = pcall(validateRaw, raw)
    if not ok then return nil, tostring(result) end
    return result
end

function C.parse(xml)
    local function parse()
        requireValue(xml ~= nil, "MISSING_XML")
        local function str(path, attr) return xml:getString(path .. "#" .. attr) end
        local function number(path, attr)
            local s = str(path, attr); if s == nil then return nil end
            local n = tonumber(s); requireValue(finite(n), "INVALID_NUMBER:" .. path .. "#" .. attr); return n
        end
        local function boolean(path, attr)
            local s = str(path, attr); requireValue(s == "true" or s == "false", "INVALID_BOOLEAN:" .. attr); return s == "true"
        end
        local function values(path)
            local result = {}; for _, attr in ipairs(C.SCALARS) do result[attr] = number(path, attr) end; return result
        end
        local function words(s)
            if s == nil then return nil end
            local list = {}; for word in s:gmatch("%S+") do list[#list + 1] = word end; return list
        end
        local function insert(map, id, value)
            requireValue(stringValue(id) and map[id] == nil, "DUPLICATE_OR_MISSING_ID:" .. tostring(id)); map[id] = value
        end
        local root = "livestockMarket"
        local v = {schemaVersion = number(root, "schemaVersion"), mode = str(root, "mode"), layers = {root = values(root .. ".defaults"), types = {}, breeds = {}, subTypes = {}}, curves = {}, profiles = {}, rules = {}, templates = {}}
        xml:iterate(root .. ".animalType", function(_, path)
            local name = str(path, "name"); requireValue(stringValue(name), "MISSING_TYPE_NAME"); name = name:upper()
            insert(v.layers.types, name, values(path)); v.layers.breeds[name] = {}; v.layers.subTypes[name] = {}
            xml:iterate(path .. ".breed", function(_, child) local id = str(child, "name"); insert(v.layers.breeds[name], id and id:upper(), values(child)) end)
            xml:iterate(path .. ".subType", function(_, child) local id = str(child, "name"); insert(v.layers.subTypes[name], id and id:upper(), values(child)) end)
        end)
        xml:iterate(root .. ".curves.curve", function(_, path)
            local curve = {axis = str(path, "axis"), interpolation = str(path, "interpolation"), points = {}}
            xml:iterate(path .. ".point", function(_, child) curve.points[#curve.points + 1] = {x = number(child, "x"), value = number(child, "value")} end)
            insert(v.curves, str(path, "id"), curve)
        end)
        xml:iterate(root .. ".profiles.profile", function(_, path)
            local p = {values = values(path), liquidityCurve = str(path, "liquidityCurve"), seasonCurve = str(path, "seasonCurve")}
            for key in pairs(policies) do p[key] = str(path, key) end
            insert(v.profiles, str(path, "id"), p)
        end)
        xml:iterate(root .. ".rules.rule", function(_, path)
            local r = {priority = number(path, "priority")}
            for _, attr in ipairs({"animalType", "breed", "subType", "purpose", "profile"}) do r[attr] = str(path, attr) end
            insert(v.rules, str(path, "id"), r)
        end)
        xml:iterate(root .. ".templates.template", function(_, path)
            local t = {}
            for _, attr in ipairs({"speciesKey", "purposeGroup", "breedScope", "profile", "seasonCurve"}) do t[attr] = str(path, attr) end
            t.allowedProductionClasses = words(str(path, "allowedProductionClasses")); t.eligibleBreedIds = words(str(path, "eligibleBreedIds"))
            insert(v.templates, str(path, "id"), t)
        end)
        local path = root .. ".brokerBalance"
        local b = {priceBasis = str(path, "priceBasis"), quotaScope = str(path, "quotaScope"), rounding = str(path, "rounding"), species = {}}
        for _, attr in ipairs(balanceNumbers) do b[attr] = number(path, attr) end
        for _, attr in ipairs(balanceBooleans) do b[attr] = boolean(path, attr) end
        xml:iterate(path .. ".species", function(_, child)
            local s = {}; for _, attr in ipairs(speciesNumbers) do s[attr] = number(child, attr) end
            s.groupWeights = words(str(child, "groupWeights"))
            for i, value in ipairs(s.groupWeights or {}) do s.groupWeights[i] = tonumber(value); requireValue(s.groupWeights[i] ~= nil, "INVALID_GROUP_WEIGHTS") end
            insert(b.species, str(child, "key"), s)
        end)
        v.brokerBalance = b
        return validateRaw(v)
    end
    local ok, result = pcall(parse)
    if not ok then return nil, tostring(result) end
    return result
end
function C.reload(state, builtinXml, overrideXml)
    if type(state) ~= "table" or getmetatable(state) ~= nil then return nil, "INVALID_STATE" end
    local candidate, reason = C.parse(overrideXml ~= nil and overrideXml or builtinXml)
    if candidate == nil then return nil, reason end
    state.current = candidate
    return candidate
end
function C.resolve(config, typeName, breed, subType, attribute)
    if type(config) ~= "table" or type(config.layers) ~= "table" or not scalarSet[attribute] then return nil, "INVALID_LOOKUP" end
    local layers = config.layers
    typeName = type(typeName) == "string" and typeName:upper() or nil
    breed = type(breed) == "string" and breed:upper() or nil
    subType = type(subType) == "string" and subType:upper() or nil
    local values = layers.subTypes[typeName] and layers.subTypes[typeName][subType]
    if values and values[attribute] ~= nil then return values[attribute], "subType" end
    values = layers.breeds[typeName] and layers.breeds[typeName][breed]
    if values and values[attribute] ~= nil then return values[attribute], "breed" end
    values = layers.types[typeName]
    if values and values[attribute] ~= nil then return values[attribute], "type" end
    return layers.root[attribute], layers.root[attribute] ~= nil and "root" or nil
end
-- A validated configuration may select several purposes, but one profile per purpose.
function C.selectProfiles(config, subject)
    local selected, ranking = {}, {}
    for id, rule in pairs(config.rules) do
        local matches, specificity = true, 0
        for index, field in ipairs({"animalType", "breed", "subType"}) do
            if rule[field] ~= nil then
                specificity = specificity + 2 ^ (index - 1)
                if subject[field] ~= rule[field] then matches = false end
            end
        end
        local previous = ranking[rule.purpose]
        if matches and (previous == nil or rule.priority > previous.priority or (rule.priority == previous.priority and specificity > previous.specificity)) then
            selected[rule.purpose] = rule.profile
            ranking[rule.purpose] = {priority = rule.priority, specificity = specificity, ruleId = id}
        end
    end
    return selected, ranking
end
