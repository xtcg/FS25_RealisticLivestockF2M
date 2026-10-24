--[[
    Dealer v2 T3: the selection step of one stock animal. Everything random is drawn here, once, from the
    job's own stream (RLDealerRng), and the result is plain data. Nothing is drawn later: the history
    replay, the identity reservation and the factory consume this table, so a retry of the same attempt
    yields the same animal and a new attempt (a new stream) a new one.

    It follows AnimalSystem:_tryCreateSaleAnimal for cattle covered by xml/dealerStock.xml - subtype by
    breed share, purpose by weight, source, age, birth and pregnancy history, source farm, genetics (the
    shared bell draw, reshaped to the dealer quality preset), health - and adds what the old dealer
    never needed: the birth weight the history starts from, the fetuses of a pregnant dam (subtype and
    genetics by the same rules as AnimalReproduction.createPregnancy, drawn here instead of at birth)
    and the sire's identity data.

    world = {
      config            RLDealerStockPolicy.getConfig()
      typeName, typeIndex
      subTypes          { {index, name, breed, gender}, ... } buyable subtypes of the type
      getSubType(index) the subtype object
      getSaleAgeContext(subType) -> ctx for RLDealerStockPolicy
      pickSourceFarm(rng) -> { countryIndex, farm } or nil
      drawGenetics(rng, subType) -> genetics  (already reshaped to the quality preset; only the genes the
                                               subtype has: RLRearingPolicy)
      now = { day, month, year, daysPerMonth }
    }
]]

-- 2: beef stock draws and inherits no milk gene (RLRearingPolicy), so its random stream differs from 1.
-- 3: a breed without breeding rules offers no parent or pregnant stock (breedableCandidates).
RLDealerPlanner = { VERSION = 3 }
local P = RLDealerPlanner

local copy=RLPlain.copy


local function templateFor(entry, plan)
    if plan.isParent or plan.isPregnant then return "NORMAL_PRODUCTION" end
    if entry.slow then return "MODERATE_SLOW_REARING" end
    return "NORMAL_REARING"
end


-- The fetuses of a pregnant dam: gender, subtype and genetics by AnimalReproduction.createPregnancy's rules.
local function selectFetuses(world, rng, dam, sire, childNum)
    local out = {}
    local hasMale, hasFemale = false, false
    for i = 1, childNum do
        local gender = rng.random() >= 0.5 and "male" or "female"
        local subTypeIndex
        if sire.subTypeIndex ~= nil and rng.random() >= 0.5 then
            subTypeIndex = sire.subTypeIndex + (gender == "male" and 0 or -1)
        else
            subTypeIndex = dam.subTypeIndex + (gender == "male" and 1 or 0)
        end
        local sub = world.getSubType(subTypeIndex)
        if sub == nil or sub.gender ~= gender or sub.typeIndex ~= world.typeIndex then
            local fallback
            for _, candidate in ipairs(world.subTypes) do
                if candidate.gender == gender then
                    fallback = fallback or candidate.index
                    if candidate.breed == dam.breed then fallback = candidate.index break end
                end
            end
            if fallback == nil then return nil, "FETAL_SUBTYPE" end
            subTypeIndex, sub = fallback, world.getSubType(fallback)
        end
        local g = dam.genetics
        local function inherit(a, b) return BreedingMath.breedOffspring(a, b, { sd = BreedingMath.SD_CONST }) end
        local child = {
            subType = sub.name, subTypeIndex = subTypeIndex, breed = sub.breed, sex = gender,
            genetics = {
                metabolism = inherit(g.metabolism, sire.genetics.metabolism),
                quality = inherit(g.quality, sire.genetics.quality),
                health = inherit(g.health, sire.genetics.health),
                fertility = 0,
                -- Only a young of a subtype with the gene inherits it, from the parents that have it.
                productivity = RLRearingPolicy ~= nil and RLRearingPolicy.inheritProductivity(sub, g.productivity, sire.genetics.productivity, inherit)
                    or (RLRearingPolicy == nil and g.productivity ~= nil and inherit(g.productivity, sire.genetics.productivity or 1)) or nil,
            },
        }
        if rng.random() > 0.001 then child.genetics.fertility = inherit(g.fertility, sire.genetics.fertility) end
        out[i] = child
        if gender == "male" then hasMale = true else hasFemale = true end
    end
    if hasMale and hasFemale then
        for _, child in ipairs(out) do
            if child.sex == "female" and rng.random() >= 0.03 then child.genetics.fertility = 0 end
        end
    end
    return out
end


-- The replay validates every past conception against the breed's rules (RLDealerReplay.getBreedingRules),
-- which only a breed with breedingWeightRatio has. Without them a parent or pregnant animal can never
-- pass: purposes that always need one are dropped, optional ones keep their young, open animals.
local function breedableCandidates(entry, candidates)
    local ratio = entry.breedingWeightRatio
    if type(ratio) == "number" and ratio == ratio and ratio > 0 and ratio <= 1 then return candidates end
    local out = {}
    for _, candidate in ipairs(candidates) do
        local purpose = candidate.purpose
        if purpose.parent ~= "always" and purpose.pregnant ~= "always" then
            if purpose.parent == "optional" or purpose.pregnant == "optional" then
                local open = copy(purpose)
                if open.parent == "optional" then open.parent = "never" end
                if open.pregnant == "optional" then open.pregnant = "never" end
                candidate = { purpose = open, segments = candidate.segments, lo = candidate.lo, hi = candidate.hi }
            end
            out[#out + 1] = candidate
        end
    end
    return out
end


--- One selection, or nil and why. `rng` is the job's stream.
function P.plan(world, rng)
    local subTypeIndex = RLDealerStockPolicy.pickSubType(world.config, world.subTypes, world.typeName, rng.random)
    if subTypeIndex == nil then return nil, "NO_SUBTYPE" end
    local subType = world.getSubType(subTypeIndex)
    local entry = RLDealerStockPolicy.getEntry(world.config, subType, world.typeName)
    if entry.status ~= RLDealerStockPolicy.COVERED then return nil, "NOT_COVERED" end
    local ctx = world.getSaleAgeContext(subType)

    local candidate = RLDealerStockPolicy.pickCandidate(breedableCandidates(entry, RLDealerStockPolicy.getCandidates(entry, subType, ctx)), rng.random)
    if candidate == nil then return nil, "NO_PURPOSE" end
    local purpose = candidate.purpose
    local source = RLDealerStockPolicy.pickSource(RLDealerStockPolicy.getSources(entry, purpose, subType.gender), rng.random)
    if source == nil then return nil, "NO_SOURCE" end
    local age = RLDealerStockPolicy.pickAge(candidate, rng.random)
    local plan, reason = RLDealerStockPolicy.planReproduction(purpose, entry, subType, age, rng.random)
    if plan == nil then return nil, reason end

    local farm = world.pickSourceFarm(rng)
    if farm == nil then return nil, "NO_FARM" end

    local genetics = world.drawGenetics(rng, subType)
    local name
    if rng.random() >= 0.85 and world.randomName ~= nil then name = world.randomName(subType.gender, rng) end
    local health = RLDealerStockPolicy.drawHealth(entry, rng.random)

    -- The first birth weight the history starts from: the normal draw of the growth model, on this stream.
    local birthContext = { damBreed = subType.breed, litterSize = 1, firstBirth = true, metabolism = genetics.metabolism }
    local weight, z, mean
    RLDealerRng.with(rng, function()
        if RLGrowth ~= nil and RLGrowth.coversSubType(subType) then
            weight, z, mean = RLGrowth.drawBirthWeight(subType, birthContext)
        end
    end)
    if weight == nil then return nil, "NO_BIRTH_WEIGHT" end

    local selection = {
        version = P.VERSION, typeName = world.typeName, subType = subType.name, subTypeIndex = subTypeIndex,
        breed = subType.breed, gender = subType.gender,
        purpose = purpose.id, source = source.id, ageMonths = age, reproduction = copy(plan),
        template = templateFor(entry, plan), genetics = copy(genetics), health = health, name = name,
        farm = { countryIndex = farm.countryIndex, farmId = tostring(farm.farm.id), quality = farm.farm.quality },
        birth = { weightKg = weight, z = z, meanKg = mean, context = birthContext },
        weaningMonth = RLDealerStockPolicy.getWeaningMonth(entry, ctx),
        daysPerMonth = world.now.daysPerMonth, plannedAt = copy(world.now),
        ageContext = copy(ctx),
    }

    if plan.isPregnant then
        local childNum = 1
        if world.generateOffspring ~= nil then childNum = world.generateOffspring(subType, genetics, rng, age) end
        if type(childNum) ~= "number" or childNum < 1 or childNum > 3 then return nil, "NO_OFFSPRING" end
        -- The sire is a dealer-side bull of the same breed: an external identity with its own genetics.
        local sireSub
        for _, candidate in ipairs(world.subTypes) do
            if candidate.gender == "male" and candidate.breed == subType.breed then sireSub = candidate break end
        end
        if sireSub == nil then return nil, "NO_SIRE" end
        local sireGenetics = world.drawGenetics(rng, world.getSubType ~= nil and world.getSubType(sireSub.index) or nil)
        local sire = { breed = subType.breed, subType = sireSub.name, subTypeIndex = sireSub.index, genetics = copy(sireGenetics) }
        local fetuses, why = RLDealerRng.with(rng, function()
            return selectFetuses(world, rng, { subTypeIndex = subTypeIndex, breed = subType.breed, genetics = genetics }, sire, childNum)
        end)
        if fetuses == nil then return nil, why end
        selection.sire, selection.fetuses = sire, fetuses
        -- Gestation as the dam's subtype has it (the 1% longer/shorter roll of the game is not part of stock).
        selection.pregnancy = { duration = plan.duration, progressMonths = plan.pregnancyMonths }
    end
    return selection
end


--- The history, seed and replay options the selection stands for. Deterministic, draws nothing.
function P.build(selection, world)
    local subType = world.getSubType(selection.subTypeIndex)
    if subType == nil or subType.name ~= selection.subType then return nil, "SUBTYPE_CHANGED" end
    local entry = RLDealerStockPolicy.getEntry(world.config, subType, selection.typeName)
    local purpose = RLDealerStockPolicy.findPurpose(entry, selection.gender, selection.purpose)
    local source = RLDealerStockPolicy.findSource(entry, selection.source)
    if purpose == nil or source == nil then return nil, "CONFIG_CHANGED" end
    local history, why = RLDealerHistory.build(selection.reproduction, entry, subType, source, purpose, {
        saleAgeMonths = selection.ageMonths, selectedBirthWeightKg = selection.birth.weightKg,
        birthContext = copy(selection.birth.context), templateId = selection.template, weaningMonth = selection.weaningMonth })
    if history == nil then return nil, why end
    local seed = { subType = subType, subTypeIndex = selection.subTypeIndex, geneticsScreened = true,
        genetics = copy(selection.genetics), health = selection.health }
    local options = { daysPerMonth = selection.daysPerMonth, entry = entry }
    -- Every conception of the history carries gravid mass in the replay. Past ones are physical proxies
    -- (one calf of the dam's own subtype, as the old dealer's history had); the current one, when the
    -- animal is pregnant, is the selected litter.
    local conceptions = {}
    for i, event in ipairs(history.events) do if event.kind == "CONCEPTION" then conceptions[#conceptions + 1] = i end end
    if #conceptions > 0 then
        options.pregnancySubTypes = {}
        for n, eventIndex in ipairs(conceptions) do
            if selection.fetuses ~= nil and n == #conceptions then
                local physical = {}
                for i, f in ipairs(selection.fetuses) do physical[i] = world.getSubType(f.subTypeIndex) end
                options.pregnancySubTypes[eventIndex] = physical
            else
                options.pregnancySubTypes[eventIndex] = { subType }
            end
        end
    end
    return { seed = seed, history = history, entry = entry, purpose = purpose, options = options, context = copy(selection.ageContext) }
end
