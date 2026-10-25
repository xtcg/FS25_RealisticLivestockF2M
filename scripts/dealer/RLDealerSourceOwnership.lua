-- Strict private source ownership codec. Separate from player XML and the candidate
-- physiology schema: real-born genes/identities are never filtered through preset ranges.
RLDealerSourceOwnership = { VERSION = 1 }
local O = RLDealerSourceOwnership
local finite=RLPlain.finite
local function id(x) return type(x) == "string" and x ~= "" and x ~= "-1" and #x <= 256 end
local copy=RLPlain.copy
local equal=RLPlain.equal
local function fail(reason, raw) return nil, { reason = reason, quarantine = raw } end
local function genes(g)
    if type(g) ~= "table" then return false end
    for _, key in ipairs({ "metabolism", "quality", "productivity", "fertility", "health" }) do
        -- productivity is absent for an animal without a milk gene (beef cattle: RLRearingPolicy).
        if (key ~= "productivity" or g[key] ~= nil) and (not finite(g[key]) or g[key] < 0) then return false end
    end
    return g.metabolism > 0
end
local dense=RLPlain.dense
local function calendar(d, birthday)
    return type(d) == "table" and finite(d.day) and d.day >= 1 and d.day <= 31 and d.day % 1 == 0
        and finite(d.month) and d.month >= 1 and d.month <= 12 and d.month % 1 == 0
        and finite(d.year) and d.year % 1 == 0
        and (not birthday or (finite(d.country) and d.country >= 1 and d.country % 1 == 0
            and finite(d.lastAgeMonth) and d.lastAgeMonth >= 1 and d.lastAgeMonth <= 12 and d.lastAgeMonth % 1 == 0))
end
local identityFields = { "uniqueId", "farmId", "birthday", "motherId", "fatherId", "children", "name", "marks",
    "variation", "isDead", "isSold", "deathEnabled", "impregnatedBy", "insemination", "monitor", "canBeSold" }
local physiologyFields = { "age", "health", "monthsSinceLastBirth", "birthCount", "gender", "breed", "isIndividual",
    "isParent", "isPregnant", "isLactating", "isCastrated", "reproduction", "weight", "targetWeight", "genetics",
    "rlGrowth", "bodyCondition", "rlFeedGain", "rlHealthCarry", "input", "output" }
local diseaseFields = { "state", "incubationTicksRemaining", "monthsElapsed", "treatmentMonthsRemaining",
    "immunityMonthsRemaining", "treatmentRunning", "isCarrier", "genes", "vaccinated" }
local function encodeDiseases(diseases)
    if not dense(diseases or {}) then return nil end
    local out = {}
    for _, disease in ipairs(diseases or {}) do
        if type(disease) ~= "table" then return nil end
        if disease.model ~= nil then
            if type(disease.model) ~= "table" or not id(disease.model.title) or Disease == nil then return nil end
            local d = { kind = "MODEL", version = Disease.RECORD_VERSION, title = disease.model.title }
            for _, key in ipairs(diseaseFields) do d[key] = disease[key] end
            out[#out + 1] = d
        else
            if RLTradePersistence.check(disease) ~= nil then return nil end
            out[#out + 1] = { kind = "PLAIN", record = copy(disease) }
        end
    end
    return out
end
local function encodeAnimal(animal, unborn)
    if type(animal) ~= "table" or type(animal.getSubType) ~= "function" or animal.rlHistoryReplay == true then return nil end
    local sub = animal:getSubType()
    if sub == nil then return nil end
    local out = { subType = sub.name, identity = {}, physiology = {}, diseases = encodeDiseases(animal.diseases), unborn = unborn == true }
    if out.diseases == nil then return nil end
    for _, key in ipairs(identityFields) do out.identity[key] = animal[key] end
    for _, key in ipairs(physiologyFields) do out.physiology[key] = animal[key] end
    if animal.pregnancy ~= nil then
        if unborn then return nil end
        out.pregnancy = { duration = animal.pregnancy.duration, expected = animal.pregnancy.expected, fetuses = {} }
        if not dense(animal.pregnancy.pregnancies) then return nil end
        for _, child in ipairs(animal.pregnancy.pregnancies) do
            local encoded = encodeAnimal(child, true)
            if encoded == nil then return nil end
            out.pregnancy.fetuses[#out.pregnancy.fetuses + 1] = encoded
        end
    end
    return out
end
local function actualBirth(data, animalId)
    for _, event in pairs(data.birthJournal) do
        if event.evidence == "OBSERVED_SOURCE_BIRTH" and type(event.result) == "table" and type(event.draws) == "table" then
            for _, child in ipairs(event.result.newborns or {}) do
                if child.uniqueId == animalId then
                    for _, draw in ipairs(event.draws) do if draw.uniqueId == animalId then return event, draw end end
                end
            end
        end
    end
end
local function pendingBirth(data, animalId)
    for _, event in pairs(data.birthJournal) do
        if event.damId == animalId and event.stage ~= "COMMITTED" then return event end
    end
end
local function validateAnimal(a, seen, data, legacyMilk)
    if type(a) ~= "table" or not id(a.subType) or type(a.identity) ~= "table" or type(a.physiology) ~= "table"
        or not id(a.identity.uniqueId) or not id(a.identity.farmId) or seen[a.identity.uniqueId]
        or type(a.unborn) ~= "boolean" or not dense(a.diseases) then return false, "SOURCE_OWNER_ANIMAL" end
    seen[a.identity.uniqueId] = true
    local p, identity = a.physiology, a.identity
    if not genes(p.genetics) or not finite(p.age) or not finite(p.health) or p.health < 0 or p.health > 100
        or not finite(p.weight) or p.weight <= 0 or type(p.gender) ~= "string" or not id(p.breed)
        or p.isIndividual ~= true then return false, "SOURCE_OWNER_PHYSIOLOGY" end
    if a.unborn then
        if p.age >= 0 or p.rlGrowth ~= nil or a.pregnancy ~= nil then return false, "SOURCE_OWNER_UNBORN" end
        return true
    end
    local g = p.rlGrowth
    if type(g) ~= "table" or g.version ~= RLGrowth.STATE_VERSION or not RLGrowth.isUsable(g) or g.source ~= "birth"
        or g.legacyAnchor ~= nil or g.anchorElapsedMonths ~= nil or g.weightKg ~= p.weight or not finite(g.ageMonths)
        or p.age ~= math.floor(g.ageMonths + 1e-10) or not finite(g.gravidKg or 0)
        or g.reserveMassKg >= p.weight - (g.gravidKg or 0) then return false, "SOURCE_OWNER_PHYSIOLOGY" end
    if not calendar(identity.birthday, true) then return false, "SOURCE_OWNER_BIRTHDAY" end
    if type(p.isPregnant) ~= "boolean" or p.isPregnant ~= (a.pregnancy ~= nil) then return false, "SOURCE_OWNER_PREGNANCY" end
    if a.sourceRecord ~= nil then
        local ok, reason = RLDealerSourceState.validate(a.sourceRecord, legacyMilk)
        if not ok then return false, reason end
        local record = a.sourceRecord.animal
        if record.subType ~= a.subType or not equal(record.genetics, p.genetics) or record.rlGrowth.birthWeightKg ~= g.birthWeightKg
            or record.rlGrowth.frameTargetKg ~= g.frameTargetKg then return false, "SOURCE_OWNER_PROVENANCE" end
        if not equal(record.rlGrowth, g) or record.weight ~= p.weight or record.birthCount ~= p.birthCount then
            local event = pendingBirth(data, identity.uniqueId)
            if event == nil or event.atAgeMonths ~= g.ageMonths then return false, "SOURCE_OWNER_RECORD" end
        end
    else
        local event, draw = actualBirth(data, identity.uniqueId)
        if event == nil or draw.weightKg ~= g.birthWeightKg or draw.subType ~= a.subType then return false, "SOURCE_OWNER_BIRTH_EVIDENCE" end
        local selected
        for _, child in ipairs(event.selected or {}) do if child.uniqueId == identity.uniqueId then selected = child end end
        local birthGenes = selected ~= nil and copy(selected.genetics) or nil
        -- Birth evidence is immutable; compare its effective genes after the rearing migration.
        if not legacyMilk and RLRearingPolicy ~= nil then RLRearingPolicy.normalizeNamed("COW", p.breed, birthGenes) end
        if selected == nil or not equal(birthGenes, p.genetics) or selected.farmId ~= identity.farmId then return false, "SOURCE_OWNER_PROVENANCE" end
    end
    if a.pregnancy ~= nil then
        if not finite(a.pregnancy.duration) or a.pregnancy.duration <= 0 or not calendar(a.pregnancy.expected, false)
            or not dense(a.pregnancy.fetuses) or #a.pregnancy.fetuses < 1 or #a.pregnancy.fetuses > 3
            or data.sireContexts[identity.uniqueId] == nil then return false, "SOURCE_OWNER_PREGNANCY" end
        for _, child in ipairs(a.pregnancy.fetuses) do
            if child.unborn ~= true or child.identity.farmId ~= identity.farmId then return false, "SOURCE_OWNER_UNBORN" end
            local ok, reason = validateAnimal(child, seen, data, legacyMilk); if not ok then return false, reason end
        end
    end
    return true
end
function O.validate(data, legacyMilk)
    if type(data) ~= "table" or RLTradePersistence.check(data) ~= nil or data.version ~= O.VERSION
        or not id(data.sourceId) or not finite(data.capacity) or data.capacity < 1 or data.capacity % 1 ~= 0
        or not dense(data.animals) or #data.animals > data.capacity or type(data.sireContexts) ~= "table"
        or type(data.birthJournal) ~= "table" or not dense(data.observedBirths) or type(data.quarantine) ~= "table" then
        return false, "SOURCE_OWNER_DATA"
    end
    for key, event in pairs(data.birthJournal) do
        if not id(key) or type(event) ~= "table" or event.eventId ~= key or event.version ~= RLDealerSourceReproduction.VERSION
            or event.sourceId ~= data.sourceId or not id(event.damId) or not finite(event.atAgeMonths)
            or not finite(event.cursorMonths) or not dense(event.selected) or type(event.sireContext) ~= "table"
            or (event.stage ~= "PREPARED" and event.stage ~= "COMMITTED" and event.stage ~= "QUARANTINED")
            or (event.stage == "COMMITTED" and (event.evidence ~= "OBSERVED_SOURCE_BIRTH" or type(event.result) ~= "table"
                or not dense(event.result.newborns) or not dense(event.draws) or #event.draws < 1 or #event.draws > 3)) then
            return false, "SOURCE_OWNER_JOURNAL"
        end
    end
    for damId, sire in pairs(data.sireContexts) do
        if not id(damId) or type(sire) ~= "table" or not id(sire.uniqueId) or not id(sire.farmId)
            or not id(sire.breed) or not genes(sire.genetics) then return false, "SOURCE_OWNER_SIRE" end
    end
    local seen = {}
    for _, animal in ipairs(data.animals) do
        local ok, reason = validateAnimal(animal, seen, data, legacyMilk); if not ok then return false, reason end
    end
    return true
end
function O.export(owner, recordsByAnimalId)
    if type(owner) ~= "table" or owner.version ~= RLDealerSourceReproduction.VERSION or #owner.pendingAdds ~= 0
        or type(recordsByAnimalId) ~= "table" then return fail("SOURCE_OWNER") end
    local data = { version = O.VERSION, sourceId = owner.rlDealerSourceId, capacity = owner.capacity,
        animals = {}, sireContexts = owner.sireContexts, birthJournal = owner.birthJournal,
        observedBirths = owner.observedBirths, quarantine = owner.quarantine }
    for _, animal in ipairs(owner.animals) do
        if animal.clusterSystem ~= owner.clusterSystem or owner.byId[animal.uniqueId] ~= animal then return fail("SOURCE_OWNER_OWNERSHIP") end
        local encoded = encodeAnimal(animal, false)
        if encoded == nil then return fail("SOURCE_OWNER_ANIMAL") end
        encoded.sourceRecord = recordsByAnimalId[animal.uniqueId]
        data.animals[#data.animals + 1] = encoded
    end
    local ok, reason = O.validate(data)
    if not ok then return fail(reason) end
    return copy(data)
end
local function resolveAll(data, resolver, diseaseResolver)
    local resolved, diseases = {}, {}
    local function visit(a)
        local sub, index = resolver(a.subType)
        index = index or (sub ~= nil and sub.subTypeIndex)
        if type(sub) ~= "table" or sub.name ~= a.subType or sub.breed ~= a.physiology.breed or sub.gender ~= a.physiology.gender
            or sub.typeIndex ~= AnimalType.COW or not RLGrowth.coversSubType(sub) or not finite(index) or index < 1 or index % 1 ~= 0 then
            return false, "SOURCE_OWNER_MISSING_SUBTYPE"
        end
        local p, g = a.physiology, a.physiology.rlGrowth
        if g ~= nil then
            local target = RLGrowth.getAdultReference(RLGrowth.getBinding(sub)) * RLGrowth.getGeneFactors(p.genetics.metabolism, sub)
            local curve = RLGrowth.buildCurve(RLGrowth.getBinding(sub), g.frameTargetKg, g.birthWeightKg)
            if math.abs(target - g.frameTargetKg) > 1e-8 or g.developmentMonths > curve.endMonth then return false, "SOURCE_OWNER_MODEL_STATE" end
        end
        local idKey = a.identity.uniqueId
        resolved[idKey], diseases[idKey] = { sub = sub, index = index }, {}
        for _, d in ipairs(a.diseases) do
            if d.kind == "PLAIN" and type(d.record) == "table" then diseases[idKey][#diseases[idKey] + 1] = copy(d.record)
            elseif d.kind == "MODEL" and Disease ~= nil and d.version == Disease.RECORD_VERSION and type(diseaseResolver) == "function" then
                local model = diseaseResolver(d.title)
                if model == nil or model.title ~= d.title then return false, "SOURCE_OWNER_MISSING_DISEASE" end
                if d.vaccinated ~= nil and type(d.vaccinated) ~= "boolean" then return false, "SOURCE_OWNER_DISEASE" end
                local restored = Disease.new(model)
                for _, key in ipairs(diseaseFields) do
                    -- Older ownership records predate vaccination; keep Disease.new's false default.
                    if key ~= "vaccinated" or d[key] ~= nil then restored[key] = d[key] end
                end
                local adherent = RLDiseaseRecord.isAdherent(restored, model, "COW")
                if not adherent then return false, "SOURCE_OWNER_DISEASE" end
                diseases[idKey][#diseases[idKey] + 1] = restored
            else return false, "SOURCE_OWNER_MISSING_DISEASE" end
        end
        for _, child in ipairs(a.pregnancy ~= nil and a.pregnancy.fetuses or {}) do
            local ok, reason = visit(child); if not ok then return false, reason end
        end
        return true
    end
    for _, animal in ipairs(data.animals) do local ok, reason = visit(animal); if not ok then return nil, reason end end
    return resolved, diseases
end
-- Missing mods/disease models preserve the whole raw owner in quarantine; no partial
-- animal construction, default-subtype fallback, migration or identity replacement occurs.
function O.restore(data, resolver, context)
    local ok, reason = O.validate(data)
    if not ok then return fail(reason, data) end
    if type(context) ~= "table" or context.isServer ~= true or type(resolver) ~= "function" then return fail("SOURCE_SERVER_ONLY", data) end
    local success, resolved, diseases = pcall(resolveAll, data, resolver, context.resolveDiseaseModel)
    if not success then return fail("SOURCE_OWNER_RESOLVE_ERROR", copy(data)) end
    if resolved == nil then return fail(diseases, copy(data)) end
    local function construct(encoded)
        local p, identity, binding = encoded.physiology, encoded.identity, resolved[encoded.identity.uniqueId]
        local animal = Animal.new({ age = -1, weight = p.weight, health = p.health, gender = p.gender,
            subTypeIndex = binding.index, genetics = copy(p.genetics), uniqueId = identity.uniqueId, farmId = identity.farmId })
        -- Verify the constructor did not silently choose a default subtype from a stale index.
        if animal:getSubType().name ~= encoded.subType then error("source subtype registry changed") end
        for _, key in ipairs(physiologyFields) do rawset(animal, key, copy(p[key])) end
        for _, key in ipairs(identityFields) do rawset(animal, key, copy(identity[key])) end
        animal.diseases = diseases[identity.uniqueId]
        animal.rlHistoryReplay, animal.rlGrowthDropped, animal.rlGrowthCurve, animal.rlGrowthPeek = nil, nil, nil, nil
        if encoded.pregnancy ~= nil then
            animal.pregnancy = { duration = encoded.pregnancy.duration, expected = copy(encoded.pregnancy.expected), pregnancies = {} }
            for _, child in ipairs(encoded.pregnancy.fetuses) do animal.pregnancy.pregnancies[#animal.pregnancy.pregnancies + 1] = construct(child) end
        end
        return animal
    end
    local constructed, animals = pcall(function()
        local out = {}; for _, encoded in ipairs(data.animals) do out[#out + 1] = construct(encoded) end; return out
    end)
    if not constructed then return fail("SOURCE_OWNER_CONSTRUCT_ERROR", copy(data)) end
    local owner, failure = RLDealerSourceReproduction.createOwner(data.sourceId, data.capacity, animals)
    if owner == nil then return nil, failure end
    owner.sireContexts, owner.birthJournal, owner.observedBirths, owner.quarantine = copy(data.sireContexts), copy(data.birthJournal), copy(data.observedBirths), copy(data.quarantine)
    local records = {}
    for _, encoded in ipairs(data.animals) do
        if encoded.sourceRecord ~= nil then records[encoded.identity.uniqueId] = copy(encoded.sourceRecord) end
        if encoded.sourceRecord ~= nil and not equal(encoded.sourceRecord.animal.rlGrowth, encoded.physiology.rlGrowth) then
            owner.quarantine[encoded.identity.uniqueId] = "SOURCE_BIRTH_UNCERTAIN"
        end
    end
    for _, event in pairs(owner.birthJournal) do
        if event.stage ~= "COMMITTED" then owner.quarantine[event.damId] = "SOURCE_BIRTH_UNCERTAIN" end
    end
    return owner, { recordsByAnimalId = records }
end
