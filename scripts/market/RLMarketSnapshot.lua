-- Read-only adapter over real animal fields and documented pure accessors.
-- Never calls sell-price, canBeSold, birth-count recovery, growth initialization,
-- update/step, disease treatment, or any state-producing animal method.
RLMarketSnapshot = {}
local finite=RLPlain.finite
local function field(out, key, value, caps, capability)
    if value ~= nil then out[key] = value end
    if caps then caps[capability or key] = value ~= nil end
end
local function scalarFields(source)
    local result = {}
    for k, v in pairs(source or {}) do
        if type(k) == "string" and (type(v) == "number" or type(v) == "boolean" or type(v) == "string") then result[k] = v end
    end
    return result
end
local function capture(animal, context, deps)
    if type(animal) ~= "table" or type(context) ~= "table" then return nil, "INVALID_CAPTURE_INPUT" end
    local system = deps.animalSystem or (g_currentMission and g_currentMission.animalSystem)
    if system == nil or type(system.getSubTypeByIndex) ~= "function" then return nil, "NO_ANIMAL_SYSTEM" end
    local sub = system:getSubTypeByIndex(animal.subTypeIndex)
    if sub == nil then return nil, "UNRESOLVED_SUBTYPE" end
    local animalType = system:getTypeByIndex(sub.typeIndex)
    if animalType == nil then return nil, "UNRESOLVED_ANIMAL_TYPE" end
    local descriptor, reason = RLMarketSpecies.resolve(sub, animalType.name, {
        dealerConfig = deps.dealerConfig, supplemental = deps.supplemental,
        classRevision = context.classRevision, traitMappingRevision = context.traitMappingRevision })
    if descriptor == nil then return nil, reason end
    local country = animal.birthday and animal.birthday.country
    local farm, unique = animal.farmId, animal.uniqueId
    local function keyPart(v)
        return (type(v) == "string" or finite(v)) and tostring(v) ~= "-1" and tostring(v):match("^%S+$") ~= nil
    end
    if not keyPart(farm) or not keyPart(unique) or not finite(country) or country < 0 or country % 1 ~= 0 then
        return nil, "INCOMPLETE_IDENTITY"
    end
    if RLAnimalIdentity == nil then return nil, "NO_IDENTITY_ADAPTER" end
    local snap = descriptor
    snap.schemaVersion = 1
    snap.identityKey = RLAnimalIdentity.keyString(farm, unique, country)
    snap.identity = { farmId = tostring(farm), uniqueId = tostring(unique), country = country }
    snap.gender = animal.gender
    if animal.age == nil then return nil, "NO_AGE" end
    snap.ageMonths = RLGrowth ~= nil and RLGrowth.getContinuousAge(animal) or animal.age
    snap.wholeAgeMonths = animal.age
    snap.traitCapabilities = {}
    local caps = snap.traitCapabilities
    field(snap, "weightKg", animal.weight, caps, "weight")
    field(snap, "targetWeightKg", animal.targetWeight, caps, "targetWeight")
    field(snap, "health", animal.health, caps)
    field(snap, "castrated", animal.isCastrated, caps)
    snap.genes = animal.genetics ~= nil and assert(RLMarketData.copy(animal.genetics)) or nil
    for _, gene in ipairs({ "quality", "productivity", "fertility", "health", "metabolism" }) do
        caps["gene_" .. gene] = snap.genes ~= nil and snap.genes[gene] ~= nil
    end
    caps.meatQuality = caps.gene_quality
    snap.reproductive = {}
    field(snap.reproductive, "pregnant", animal.isPregnant, caps, "pregnancy")
    field(snap.reproductive, "lactating", animal.isLactating, caps, "lactation")
    field(snap.reproductive, "parity", animal.birthCount, caps, "parity")
    field(snap.reproductive, "monthsSinceLastBirth", animal.monthsSinceLastBirth)
    field(snap.reproductive, "reproduction", animal.reproduction)
    field(snap.reproductive, "isParent", animal.isParent)
    if animal.pregnancy ~= nil then
        -- Includes fetus genetics, expected date and gestation duration; these are
        -- saved data, not Animal objects. Unknown executable payloads fail closed.
        snap.reproductive.pregnancy = assert(RLMarketData.copy(animal.pregnancy))
    end
    snap.diseases = animal.diseases ~= nil and {} or nil
    caps.diseaseState = snap.diseases ~= nil
    local symptoms = false
    for _, disease in ipairs(animal.diseases or {}) do
        local record = scalarFields(disease)
        if disease.model ~= nil then record.model = scalarFields(disease.model) end
        snap.diseases[#snap.diseases + 1] = record
        if RLDiseaseStatus ~= nil then symptoms = symptoms or RLDiseaseStatus.isDiseased(disease)
        elseif disease.state == "INFECTIOUS" then symptoms = true end
    end
    -- Order of disease objects is not economic state; equal multisets have the
    -- same fingerprint. Counters/severity/definition scalars remain included.
    table.sort(snap.diseases or {}, function(a, b) return assert(RLMarketData.fingerprint(a)) < assert(RLMarketData.fingerprint(b)) end)
    local diseaseEnabled = deps.diseasesEnabled
    if diseaseEnabled == nil and g_diseaseManager ~= nil then diseaseEnabled = g_diseaseManager.diseasesEnabled end
    snap.diseasesEnabled = diseaseEnabled
    snap.production = {}
    if animal.bodyCondition ~= nil then snap.bodyCondition = assert(RLMarketData.copy(animal.bodyCondition)) end
    if animal.rlGrowth ~= nil then snap.growthState = assert(RLMarketData.copy(animal.rlGrowth)) end
    -- Never synthesize a neutral reserve when the saved state is missing.
    if animal.bodyCondition ~= nil and finite(animal.bodyCondition.reserve) and RLBodyCondition ~= nil
        and RLBodyCondition.isEligible(animal) then
        snap.production.finishScore = RLBodyCondition.getFinishScore(animal)
        snap.production.bcs = RLBodyCondition.getBCS(animal)
        snap.production.fatClass = RLBodyCondition.getFatClass(animal)
    end
    caps.finishScore = snap.production.finishScore ~= nil
    caps.bcs = snap.production.bcs ~= nil
    caps.fatClass = snap.production.fatClass ~= nil
    caps.stage = false
    if AnimalMoveEvent ~= nil and AnimalMoveEvent.getCarcassReferenceWeight ~= nil
        and finite(animal.targetWeight) and animal.targetWeight > 0 then
        local meat = AnimalMoveEvent.getMeatPerHead(animalType.name)
        if meat ~= nil then snap.production.slaughterReferenceKg = AnimalMoveEvent.getCarcassReferenceWeight(animal, nil, animal.subTypeIndex) end
    end
    caps.slaughterReference = snap.production.slaughterReferenceKg ~= nil
    -- Production output is a real subtype curve, including a same-breed female
    -- counterpart for males. Sheep productivity alone never becomes milk genetics.
    local manager = deps.fillTypeManager or g_fillTypeManager
    local function fillName(index)
        if manager == nil then return nil end
        if manager.getFillTypeNameByIndex ~= nil then return manager:getFillTypeNameByIndex(index) end
        -- Some engine/test adapters expose only the reverse lookup.
        if manager.getFillTypeIndexByName ~= nil then
            for _, name in ipairs({ "MILK", "BUFFALOMILK", "GOATMILK", "SHEEPMILK", "WOOL", "SHEEPWOOL_SHEARED", "BULLSPERM" }) do
                if manager:getFillTypeIndexByName(name) == index then return name end
            end
        end
    end
    local milkNames = { MILK = true, BUFFALOMILK = true, GOATMILK = true, SHEEPMILK = true }
    local function outputOf(s, names)
        local chosen, chosenKey
        for key, output in pairs(s.output or {}) do
            if RLAnimalOutput.curve(output) ~= nil and output.fillType ~= nil then
                local name = fillName(output.fillType)
                local order = name ~= nil and name .. ":" .. tostring(key) or nil
                if name ~= nil and names[name] and (chosenKey == nil or order < chosenKey) then
                    chosen, chosenKey = output, order
                end
            end
        end
        return chosen
    end
    local function sameCurve(a, b)
        if a == b then return true end
        -- Identical engine AnimCurve methods plus identical stored keyframes prove
        -- equality. Different opaque closures cannot prove equal curves, even if
        -- a handful of sampled ages happen to agree.
        if a.fillType ~= b.fillType then return false end
        a, b = a.curve or a, b.curve or b
        if a == b then return true end
        if a.get ~= b.get then return false end
        local function stored(curve)
            local values = {}
            for key, item in pairs(curve) do
                if type(item) ~= "function" then values[key] = item end
            end
            return RLMarketData.fingerprint(values)
        end
        local aKey, bKey = stored(a), stored(b)
        return aKey ~= nil and aKey == bKey
    end
    local milk = animal.gender == "female" and outputOf(sub, milkNames) or nil
    local milkSub = milk ~= nil and sub or nil
    local milkConflict = false
    if milkSub == nil then
        local candidates = {}
        for _, other in pairs(system.subTypes or {}) do
            if other.typeIndex == sub.typeIndex and other.breed == sub.breed and other.gender == "female" then
                local candidate = outputOf(other, milkNames)
                if candidate ~= nil then candidates[#candidates + 1] = { sub = other, curve = candidate } end
            end
        end
        table.sort(candidates, function(a, b)
            if a.sub.name ~= b.sub.name then return a.sub.name < b.sub.name end
            return tostring(a.curve.fillType) < tostring(b.curve.fillType)
        end)
        for _, candidate in ipairs(candidates) do
            if milk == nil then milkSub, milk = candidate.sub, candidate.curve
            elseif not sameCurve(milk, candidate.curve) then milkConflict = true end
        end
    end
    if milkConflict then
        milkSub, milk = nil, nil
        snap.capabilityReasons = { milk = "AMBIGUOUS_MILK_CURVE" }
    end
    caps.milkOutput = milkSub ~= nil
    caps.milkProductivity = caps.milkOutput and caps.gene_productivity
    caps.woolOutput = outputOf(sub, { WOOL = true, SHEEPWOOL_SHEARED = true }) ~= nil
    caps.woolProductivity = caps.woolOutput and caps.gene_productivity
    if milkSub ~= nil then
        snap.production.milkSourceSubType = milkSub.name
        snap.production.milkFillType = milk.fillType
    end
    snap.supportedBreedingRoles = {}
    local reproductionSub = sub
    if animal.gender == "male" then
        reproductionSub = nil
        for _, other in pairs(system.subTypes or {}) do
            if other.typeIndex == sub.typeIndex and other.breed == sub.breed and other.gender == "female"
                and finite(other.reproductionDurationMonth) and other.reproductionDurationMonth > 0
                and (reproductionSub == nil or other.name < reproductionSub.name) then reproductionSub = other end
        end
    end
    local hasReproduction = finite(sub.reproductionMinAgeMonth) and reproductionSub ~= nil
        and finite(reproductionSub.reproductionDurationMonth) and reproductionSub.reproductionDurationMonth > 0
    caps.reproduction = hasReproduction
    if hasReproduction then
        snap.reproductive.gestationMonths = reproductionSub.reproductionDurationMonth
        snap.reproductive.reproductionSourceSubType = reproductionSub.name
    end
    if hasReproduction and caps.gene_fertility and caps.gene_health then
        if caps.milkProductivity and (snap.productionClass == "DAIRY" or snap.productionClass == "DUAL") then
            snap.supportedBreedingRoles[#snap.supportedBreedingRoles + 1] = "DAIRY"
        end
        if caps.meatQuality then snap.supportedBreedingRoles[#snap.supportedBreedingRoles + 1] = "TERMINAL" end
        snap.supportedBreedingRoles[#snap.supportedBreedingRoles + 1] = "MATERNAL"
    end
    snap.eligibility = {}
    if type(animal.isDead) == "boolean" and caps.diseaseState and type(diseaseEnabled) == "boolean" then
        snap.eligibility.tradeAllowed = not animal.isDead and animal.canBeSold ~= false and not (diseaseEnabled and symptoms)
    end
    caps.tradeEligibility = snap.eligibility.tradeAllowed ~= nil
    snap.isDead, snap.canBeSold = animal.isDead, animal.canBeSold
    snap.stateRevision = assert(RLMarketData.fingerprint(snap))
    local valid, failure = RLMarketSchema.validateSnapshot(snap)
    if not valid then return nil, failure end
    return snap
end
function RLMarketSnapshot.capture(animal, context, deps)
    local ok, result, reason = pcall(capture, animal, context, deps or {})
    if not ok then return nil, "SNAPSHOT_CAPTURE_ERROR" end
    return result, reason
end
