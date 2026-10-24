-- Real game data -> finite HARD reference inputs. Never getSellPrice/getQuote,
-- never initialize an animal or turn on growth/nutrition/dealer runtimes.
RLMarketValueAdapter = {}
local function curveData(curve, horizon)
    curve = curve and (curve.curve or curve)
    if type(curve) ~= "table" or type(curve.get) ~= "function" then return nil end
    local values = {}
    for age = 0, horizon do
        local value = curve:get(age)
        if not RLMarketCommodityValue.nonnegative(value) then return nil end
        values[age + 1] = value
    end
    return { firstAgeMonths = 0, stepMonths = 1, values = values }
end
local function capture(animal, snapshot, context, options)
    local valid, why = RLMarketSchema.validateSnapshot(snapshot)
    if not valid then return nil, why end
    if type(context) ~= "table" or type(context.referenceRevision) ~= "string" or context.referenceRevision == ""
        or context.priceRevision == nil then return nil, "MISSING_REFERENCE_REVISION" end
    local system = options.animalSystem or (g_currentMission and g_currentMission.animalSystem)
    if not system or not animal then return nil, "MISSING_ANIMAL_SYSTEM" end
    local sub = system:getSubTypeByIndex(animal.subTypeIndex)
    if not sub or sub.name ~= snapshot.subTypeName then return nil, "REFERENCE_SUBTYPE_MISMATCH" end
    local liveIdentity = animal.birthday and RLAnimalIdentity.keyString(animal.farmId, animal.uniqueId, animal.birthday.country)
    if liveIdentity ~= snapshot.identityKey then return nil, "REFERENCE_IDENTITY_MISMATCH" end
        local current, unavailable = RLMarketSnapshot.capture(animal, context, {
        animalSystem = system, dealerConfig = options.dealerConfig, supplemental = options.supplemental,
        diseasesEnabled = options.diseasesEnabled, fillTypeManager = options.fillTypeManager })
    if current == nil then return nil, unavailable end
    if current.stateRevision ~= snapshot.stateRevision then return nil, "REFERENCE_STATE_CHANGED" end
    local refs = { schemaVersion = 1, currencyBasis = "HARD", identityKey = snapshot.identityKey,
        stateRevision = snapshot.stateRevision, referenceRevision = context.referenceRevision, priceRevision = context.priceRevision, configRevision = context.configRevision,
        classRevision = snapshot.classRevision, traitMappingRevision = snapshot.traitMappingRevision,
        commodity = { currencyBasis = "HARD" }, facts = {}, missing = {} }
    local horizon = options.curveHorizonMonths or 120
    if not RLMarketCommodityValue.nonnegative(horizon) or horizon % 1 ~= 0 or horizon > 240 then return nil, "INVALID_CURVE_HORIZON" end
    -- The subtype's raw XML price curves are HARD; current engine selling points
    -- require explicit normalization through MarketMoney at the separate price seam.
    refs.facts.rawSellCurve = curveData(sub.sellPrice, horizon)
    refs.facts.rawBuyCurve = curveData(sub.buyPrice, horizon)
    refs.facts.outputCurves = {}
    for name, output in pairs(sub.output or {}) do
        local curve = curveData(output, horizon)
        if curve then refs.facts.outputCurves[name] = { fillType = output.fillType, curve = curve } end
    end
    refs.facts.reproductionMinAgeMonths = sub.reproductionMinAgeMonth
    refs.facts.gestationMonths = snapshot.reproductive.gestationMonths
    if options.slaughterRoute ~= nil then
        local slaughter, unavailable = RLMeatValue.getMarketBreakdown(animal, options.slaughterRoute)
        refs.commodity.slaughter = slaughter
        if not slaughter then refs.missing.slaughter = unavailable end
    else refs.missing.slaughter = "MISSING_SLAUGHTER_ROUTE" end
    if options.rearingReference ~= nil then
        if options.rearingReference.currencyBasis ~= "HARD" then return nil, "REARING_BASIS_REQUIRED" end
        refs.commodity.rearing = assert(RLMarketData.copy(options.rearingReference))
    end
    local supplied = options.productionBySpecies and options.productionBySpecies[snapshot.speciesKey]
    if supplied ~= nil and supplied.currencyBasis ~= "HARD" then return nil, "PRODUCTION_BASIS_REQUIRED" end
    refs.production = supplied ~= nil and assert(RLMarketData.copy(supplied)) or { currencyBasis = "HARD", params = {} }
    refs.production.currencyBasis = "HARD"
    local p = refs.production.params or {}; refs.production.params = p
    refs.missing.productionFields = {}
    if refs.production.costBasis == nil then refs.missing.productionFields[#refs.missing.productionFields + 1] = "costBasis" end
    for _, name in ipairs({ "exitAge", "recoveryMonths", "openMonths", "maxBirths", "annualExitRisk", "healthExitSlope",
        "discountRate", "mateGene", "offspringBaseNet" }) do
        if p[name] == nil then refs.missing.productionFields[#refs.missing.productionFields + 1] = name end
    end
    if snapshot.speciesKey == "PIG" or snapshot.speciesKey == "SHEEP" then
        for _, name in ipairs({ "expectedLitter", snapshot.speciesKey == "PIG" and "pigletSurvival" or "lambSurvival" }) do
            if p[name] == nil then refs.missing.productionFields[#refs.missing.productionFields + 1] = name end
        end
    end
    -- Only observed biological facts may fill gaps; no cattle root economic
    -- defaults or invented service herd/litter/exit/cost assumptions cross species.
    if p.minBreedingAge ~= nil and sub.reproductionMinAgeMonth ~= nil and p.minBreedingAge ~= sub.reproductionMinAgeMonth then return nil, "REFERENCE_BREEDING_AGE_CONFLICT" end
    if p.gestationMonths ~= nil and snapshot.reproductive.gestationMonths ~= nil and p.gestationMonths ~= snapshot.reproductive.gestationMonths then return nil, "REFERENCE_GESTATION_CONFLICT" end
    p.minBreedingAge = sub.reproductionMinAgeMonth
    p.gestationMonths = snapshot.reproductive.gestationMonths
    if p.inheritanceSD == nil and BreedingMath ~= nil then p.inheritanceSD = BreedingMath.SD_CONST end
    if snapshot.speciesKey == "SHEEP" then refs.production.calendarMonth = context.calendarMonth end
    if supplied == nil then refs.missing.production = "MISSING_SPECIES_ECONOMIC_PARAMETERS" end
    -- Optional explicit milk economics; the volume comes from the verified actual
    -- female output, never from productivity itself or a hard-coded cow curve.
    if snapshot.traitCapabilities.milkProductivity and refs.production.lactationNetByMonth == nil
        and options.milkPriceHard ~= nil and options.milkNetShare ~= nil and options.milkIncrementNetShare ~= nil then
        if not RLMarketCommodityValue.nonnegative(options.milkPriceHard) or not RLMarketCommodityValue.nonnegative(options.milkNetShare)
            or options.milkNetShare > 1 or not RLMarketCommodityValue.nonnegative(options.milkIncrementNetShare) or options.milkIncrementNetShare > 1 then return nil, "INVALID_MILK_ECONOMICS" end
        local female
        for _, other in pairs(system.subTypes or {}) do if other.name == snapshot.production.milkSourceSubType then female = other; break end end
        if female then
            local selected
            for _, output in pairs(female.output or {}) do if output.fillType == snapshot.production.milkFillType then selected = output; break end end
            local curve = selected and (selected.curve or selected)
            if curve and type(curve.get) == "function" and RLMilkParity and RLLactation then
                local volume = curve:get(RLMilkParity.MATURE_AGE_MONTHS)
                if not RLMarketCommodityValue.nonnegative(volume) then return nil, "INVALID_MILK_CURVE" end
                local scale = snapshot.speciesKey == "COW" and RLBreedTraits.get(female, "milkScale") or 1
                local collect = snapshot.speciesKey == "COW" and RLBreedTraits.getMilkCollect(female) or 1
                if not RLMarketCommodityValue.nonnegative(scale) or not RLMarketCommodityValue.nonnegative(collect) then return nil, "INVALID_MILK_SCALE" end
                volume = volume * scale * collect
                refs.facts.milkScale, refs.facts.milkCollect = scale, collect
                refs.production.lactationNetByMonth = {}
                refs.production.lactationIncrementNetByMonth = {}
                for month = 0, RLLactation.MONTHS - 1 do
                    refs.production.lactationNetByMonth[month + 1] = volume * RLLactation.getYieldFactor(month)
                        * options.milkPriceHard * options.milkNetShare
                    refs.production.lactationIncrementNetByMonth[month + 1] = volume * RLLactation.getYieldFactor(month)
                        * options.milkPriceHard * options.milkIncrementNetShare
                end
            end
        end
    end
    local detached, bad = RLMarketData.copy(refs)
    if not detached then return nil, bad end
    return detached
end
function RLMarketValueAdapter.capture(animal, snapshot, context, options)
    local ok, result, reason = pcall(capture, animal, snapshot, context, options or {})
    if not ok then return nil, "REFERENCE_CAPTURE_ERROR" end
    return result, reason
end
