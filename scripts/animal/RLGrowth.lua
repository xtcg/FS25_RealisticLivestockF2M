--[[
    RLGrowth.lua
    The cattle weight model v2 in the game: which animals it covers, the state each carries, the
    continuous growth curve each grows on, birth weights, the hourly step (RLGrowthMath) and what
    the rest of the mod reads from it (target weight, price line, feed request, underweight).

    Coverage. Cattle (animal type COW) whose breed resolves to a profile in weightProfiles.xml
    (exactly or through a map's alias), and animal types the file binds to a profile as a stand-in
    (Hof Bergmann's MILKCOW on the Holstein female curve) wherever the game holds them as
    individual animals. The model needs the body condition feature (its energy settings, feed
    ledger and reserve display); with either switched off, every animal keeps the old rules.

    Curves. A profile's reference curve per sex runs through its knots (RLGrowthCurve) from the
    mean birth weight to the adult plateau. An animal's own curve is that curve x its size gene,
    with its actual birth weight replacing the mean and the difference faded out over the first
    birthFadeMonths. Shop stock, births, the growth itself, the feed request's body factor, the
    live price's weight-for-age and the underweight check all read this one curve.

    Metabolism gene m (0.25..1.75), z = clamp((m - 1) / geneSpan, -1, 1), acts three ways, each
    bounded: adult size 1 + sizeGeneEffect x z, development speed 1 + speedGeneEffect x z,
    maintenance (and the feed it asks for) 1 + maintenanceGeneEffect x z. Birth weight
    1 + birthGeneEffect x (m - 1). Nothing multiplies the full gene in twice.

    State (animal.rlGrowth, saved and streamed with the animal):
        version, birthWeightKg (the actual draw), frameTargetKg (its adult weight on the curve),
        developmentMonths (how far along the curve its frame is), reserveMassKg (the reserve's
        mass inside the live weight), speedFactor and intakeFactor (stage factors in transition),
        weightKg (the live weight the state was last set for), ageMonths (a continuous age clock),
        source ("birth", "derived", "resync", "stream"), lastTick (game hour of the last step).
    A weight changed by anything else (the old rules while the model was off, the console,
    another mod) is taken as it is: the next step splits it again at the animal's reserve index
    and puts its development where its curve has that frame (RLGrowth.resync).
    The body condition state (animal.bodyCondition) mirrors the reserve as its index r = R / K
    after every step, so BCS, finish score and their factors read it as before.

    No event changes the weight: weaning, castration, calving, drying off, a move, a sale, a save
    and a load only change what later steps integrate. An animal from an old savegame keeps its
    weight exactly: its reserve index (the body condition's, else the neutral one) splits the
    weight into frame and reserve, and its development is where its curve has that frame.
]]

RLGrowth = {}

local Log = RmLogging.getLogger("RLRM")

RLGrowth.STATE_VERSION = 1


-- =============================================================================
-- Config, coverage
-- =============================================================================

local bindingCache = setmetatable({}, { __mode = "k" })
local nominalCache = {}

--- Forget cached bindings and curves (after the config is replaced).
function RLGrowth.resetCaches()
    bindingCache = setmetatable({}, { __mode = "k" })
    nominalCache = {}
end


function RLGrowth.getConfig()
    return RLWeightProfiles.getConfig()
end


function RLGrowth.getSettings()
    return RLGrowth.getConfig().settings
end


--- The model is on: switched on in weightProfiles.xml (and valid) and the body condition on.
function RLGrowth.isEnabled()
    if RLBreedTraits == nil or RLBodyCondition == nil then return false end
    return RLGrowth.getConfig().enabled == true and RLBodyCondition.isEnabled()
end


--- The profile and sex curve a subtype grows on (RLWeightProfiles.getCurveBinding), cached.
--- @param subType table|nil
--- @return table|nil binding
--- @return string resolution
function RLGrowth.getBinding(subType)
    if subType == nil then return nil, "UNRESOLVED" end
    local cached = bindingCache[subType]
    if cached == nil then
        local binding, resolution = RLWeightProfiles.getCurveBinding(subType)
        cached = { binding = binding, resolution = resolution }
        bindingCache[subType] = cached
    end
    return cached.binding, cached.resolution
end


--- Whether the model covers animals of this subtype.
function RLGrowth.coversSubType(subType)
    return RLGrowth.isEnabled() and RLGrowth.getBinding(subType) ~= nil
end


--- Whether the model covers this animal: an individual animal (not a vanilla cluster) with
--- genes, of a covered subtype.
--- @param animal table|nil
--- @return boolean
function RLGrowth.covers(animal)
    if animal == nil or animal.isIndividual ~= true or animal.genetics == nil or animal.getSubType == nil then return false end
    return RLGrowth.coversSubType(animal:getSubType())
end


-- =============================================================================
-- Genes, curves
-- =============================================================================

--- The metabolism gene's four effects.
--- @param metabolism number|nil
--- @return number size Adult size factor
--- @return number speed Development speed factor
--- @return number maintenance Maintenance and feed request factor
--- @return number birth Birth weight factor
function RLGrowth.getGeneFactors(metabolism)
    local s = RLGrowth.getSettings()
    local m = metabolism or 1
    local z = math.clamp((m - 1) / s.geneSpan, -1, 1)
    return 1 + s.sizeGeneEffect * z, 1 + s.speedGeneEffect * z, 1 + s.maintenanceGeneEffect * z,
        math.max(1 + s.birthGeneEffect * (m - 1), 0.5)
end


--- The feed request's gene factor: the maintenance factor for a covered animal, the metabolism
--- gene itself (the old rule) for any other.
--- @param animal table
--- @return number
function RLGrowth.getIntakeGene(animal)
    local metabolism = animal.genetics ~= nil and animal.genetics.metabolism or 1
    if not RLGrowth.covers(animal) then return metabolism end
    local _, _, maintenance = RLGrowth.getGeneFactors(metabolism)
    return maintenance
end


--- A profile's knots for the binding's sex, the birth knot (sex mean) first.
function RLGrowth.getReferenceKnots(binding)
    return RLGrowth.getConfig().profiles[binding.profile].knots[binding.sex]
end


--- Adult (plateau) weight of the binding's reference curve.
function RLGrowth.getAdultReference(binding)
    local knots = RLGrowth.getReferenceKnots(binding)
    return knots[#knots][2]
end


--- Mean birth weight of a single calf of the binding's sex from an average dam.
function RLGrowth.getBirthMean(binding)
    return RLGrowth.getReferenceKnots(binding)[1][2]
end


--- The reference curve of a binding (average genes, mean birth weight), cached.
--- @param binding table
--- @return table RLGrowthCurve
function RLGrowth.getNominalCurve(binding)
    local key = binding.profile .. "/" .. binding.sex
    local curve = nominalCache[key]
    if curve == nil then
        curve = RLGrowthCurve.new(RLGrowth.getReferenceKnots(binding))
        nominalCache[key] = curve
    end
    return curve
end


--- An animal's own knots: the reference knots x size, the birth knot replaced by its actual birth
--- weight and the difference faded out by fadeMonths, never decreasing.
--- @param knots table Reference knots
--- @param size number frame target / reference adult
--- @param birthKg number
--- @param fadeMonths number
--- @return table knots
function RLGrowth.buildKnots(knots, size, birthKg, fadeMonths)
    local out = {}
    local delta = birthKg - knots[1][2] * size
    for i, knot in ipairs(knots) do
        local weight = knot[2] * size + delta * RLGrowthCurve.fade(knot[1] / fadeMonths)
        if i > 1 then weight = math.max(weight, out[i - 1][2]) end
        out[i] = { knot[1], math.max(weight, 0) }
    end
    return out
end


--- The curve of an animal of this binding with this adult weight and birth weight.
--- @return table RLGrowthCurve
function RLGrowth.buildCurve(binding, frameTargetKg, birthWeightKg)
    local adult = RLGrowth.getAdultReference(binding)
    local size = adult > 0 and frameTargetKg / adult or 1
    return RLGrowthCurve.new(RLGrowth.buildKnots(RLGrowth.getReferenceKnots(binding), size, birthWeightKg,
        RLGrowth.getSettings().birthFadeMonths))
end


--- An animal's adult weight on its curve: its saved one, else the reference adult x its size gene.
function RLGrowth.getFrameTarget(animal, binding)
    local state = animal.rlGrowth
    if state ~= nil and state.frameTargetKg ~= nil then return state.frameTargetKg end
    local size = RLGrowth.getGeneFactors(animal.genetics.metabolism)
    return RLGrowth.getAdultReference(binding) * size
end


--- An animal's birth weight: its saved one, else the mean x its birth gene (an animal that came
--- with no record of its birth).
function RLGrowth.getBirthWeight(animal, binding)
    local state = animal.rlGrowth
    if state ~= nil and state.birthWeightKg ~= nil then return state.birthWeightKg end
    local _, _, _, birth = RLGrowth.getGeneFactors(animal.genetics.metabolism)
    return RLGrowth.getBirthMean(binding) * birth
end


--- The animal's own curve (cached on the animal while its adult and birth weight stay the same).
--- @param animal table A covered animal
--- @return table|nil curve
--- @return table|nil binding
function RLGrowth.getCurve(animal)
    local binding = RLGrowth.getBinding(animal:getSubType())
    if binding == nil then return nil, nil end
    local target = RLGrowth.getFrameTarget(animal, binding)
    local birth = RLGrowth.getBirthWeight(animal, binding)
    local cache = animal.rlGrowthCurve
    if cache ~= nil and cache.binding == binding and cache.target == target and cache.birth == birth then
        return cache.curve, binding
    end
    local curve = RLGrowth.buildCurve(binding, target, birth)
    animal.rlGrowthCurve = { binding = binding, target = target, birth = birth, curve = curve }
    return curve, binding
end


--- Reserve capacity per kg of frame (kappa).
function RLGrowth.getKappa()
    local bc = RLBodyCondition.getConfig()
    return RLGrowthMath.getKappa(bc.reserveCapacityRatio, bc.referenceReserve)
end


--- Age in months as a continuous number, for what changes smoothly with age (the calf's feed
--- transition): the state's own clock, which every step moves on by the months it covers, kept
--- within the animal's whole months (an animal ages by its birthday on a day change, after that
--- day's first hour, so the period's clock alone would step back for an hour). Whole months
--- without a state. Comparisons with a curve at an age use the whole months, as the old rules did.
--- @param animal table
--- @return number
function RLGrowth.getContinuousAge(animal)
    local age = animal.age or 0
    local state = animal.rlGrowth
    if state == nil or state.ageMonths == nil then return age end
    return math.min(math.max(state.ageMonths, age), age + RLGrowth.AGE_CLOCK_CAP)
end


--- The continuous age never runs a whole month ahead of the whole months.
RLGrowth.AGE_CLOCK_CAP = 0.999


--- Move the state's clock on by dtMonths, within the animal's whole months.
--- @param state table
--- @param age number Whole months
--- @param dtMonths number
function RLGrowth.advanceClock(state, age, dtMonths)
    local value = (state.ageMonths or age) + dtMonths
    state.ageMonths = math.min(math.max(value, age), age + RLGrowth.AGE_CLOCK_CAP)
end


-- =============================================================================
-- Constructor, generated animals
-- =============================================================================

--- An animal's target weight under the model: its saved adult weight, else the reference adult
--- x its size gene; nil when the model does not cover the subtype (the old formula applies).
--- @param subType table|nil
--- @param genetics table
--- @param state table|nil A saved state
--- @return number|nil
function RLGrowth.getConstructorTarget(subType, genetics, state)
    if subType == nil or genetics == nil or not RLGrowth.coversSubType(subType) then return nil end
    if state ~= nil and state.frameTargetKg ~= nil then return state.frameTargetKg end
    local binding = RLGrowth.getBinding(subType)
    return RLGrowth.getAdultReference(binding) * (RLGrowth.getGeneFactors(genetics.metabolism))
end


--- Weight of an animal that appears with none of its own (dealer stock, a new game's herds, a
--- converted cluster): its curve at its age (mean birth weight x its birth gene), at the neutral
--- reserve. Deterministic: it draws no random number.
--- @param subType table
--- @param genetics table
--- @param age number|nil Months
--- @return number kg
function RLGrowth.getNewAnimalWeight(subType, genetics, age)
    local binding = RLGrowth.getBinding(subType)
    local size, _, _, birth = RLGrowth.getGeneFactors(genetics.metabolism)
    local adult = RLGrowth.getAdultReference(binding)
    local curve = RLGrowth.buildCurve(binding, adult * size, RLGrowth.getBirthMean(binding) * birth)
    return curve:value(math.max(age or 0, 0))
end


-- =============================================================================
-- State
-- =============================================================================

--- Stage speed the development moves at: castratedSpeed for a steer, else 1.
function RLGrowth.getStageSpeed(animal)
    return animal.isCastrated and RLGrowth.getSettings().castratedSpeed or 1
end


--- A new state.
--- @param fields table birthWeightKg, frameTargetKg, developmentMonths, reserveMassKg, speedFactor, intakeFactor, source
--- @return table
function RLGrowth.newState(fields)
    return {
        version = RLGrowth.STATE_VERSION,
        birthWeightKg = fields.birthWeightKg,
        frameTargetKg = fields.frameTargetKg,
        developmentMonths = fields.developmentMonths or 0,
        reserveMassKg = fields.reserveMassKg or 0,
        speedFactor = fields.speedFactor or 1,
        intakeFactor = fields.intakeFactor or 1,
        weightKg = fields.weightKg,
        ageMonths = fields.ageMonths,
        source = fields.source or "derived",
        lastTick = fields.lastTick or -1,
    }
end


--- A copy of a state (clone, move): two animals never share one table.
function RLGrowth.copyState(state)
    if state == nil then return nil end
    local copy = {}
    for key, value in pairs(state) do copy[key] = value end
    return copy
end


--- The state an animal without one is given: its weight kept exactly. The reserve index of its
--- body condition (the neutral initial one when it has none) splits the weight into frame and
--- reserve; its development is where its curve has that frame; adult weight and birth weight
--- from its genes (its birth is not on record). Read-only: nothing is stored.
--- @param animal table A covered animal
--- @return table state
function RLGrowth.deriveState(animal)
    local bc = RLBodyCondition.getConfig()
    local binding = RLGrowth.getBinding(animal:getSubType())
    local kappa = RLGrowth.getKappa()
    local reserve = animal.bodyCondition ~= nil and animal.bodyCondition.reserve or bc.initialReserve
    local frameTarget = RLGrowth.getFrameTarget(animal, binding)
    local birth = RLGrowth.getBirthWeight(animal, binding)
    local curve = RLGrowth.buildCurve(binding, frameTarget, birth)
    local frame, reserveKg = RLGrowthMath.split(math.max(animal.weight or 0, 0), reserve, kappa)

    return RLGrowth.newState({
        birthWeightKg = birth,
        frameTargetKg = frameTarget,
        developmentMonths = RLGrowthMath.getDevelopment(curve, frame, kappa, bc.referenceReserve),
        reserveMassKg = reserveKg,
        speedFactor = RLGrowth.getStageSpeed(animal),
        intakeFactor = RLBodyCondition.getIntakeCapacity(animal),
        weightKg = animal.weight,
        source = "derived",
    })
end


--- Weight differences below this are the float rounding of a save or a stream, not a change.
RLGrowth.RESYNC_TOLERANCE_KG = 0.01


--- Take a weight something else changed as it is: split it again at the animal's reserve index
--- (its body condition's, which the old rules keep moving, else the state's own) and put its
--- development where its curve has that frame. Birth weight, adult weight and stage factors stay.
--- @param animal table
--- @param state table
--- @return boolean changed
function RLGrowth.resync(animal, state)
    local weight = animal.weight or 0
    if state.weightKg ~= nil and math.abs(weight - state.weightKg) <= RLGrowth.RESYNC_TOLERANCE_KG then return false end
    local bc = RLBodyCondition.getConfig()
    local kappa = RLGrowth.getKappa()
    local reserve = animal.bodyCondition ~= nil and animal.bodyCondition.reserve or nil
    if reserve == nil then
        local frame = (state.weightKg or weight) - state.reserveMassKg
        reserve = frame > 0 and state.reserveMassKg / (frame * kappa) or bc.initialReserve
    end
    local frame, reserveKg = RLGrowthMath.split(math.max(weight, 0), reserve, kappa)
    local curve = RLGrowth.getCurve(animal)
    state.reserveMassKg = reserveKg
    state.developmentMonths = RLGrowthMath.getDevelopment(curve, frame, kappa, bc.referenceReserve)
    Log:debug("RLGrowth: %s/%s weight changed outside the model (%s -> %.2f kg); split again at reserve %.3f, development %.2f",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(state.weightKg), weight, reserve, state.developmentMonths)
    state.weightKg = weight
    state.source = "resync"
    return true
end


--- The animal's state, derived and stored when it has none (server, from the step).
function RLGrowth.ensureState(animal)
    if animal.rlGrowth == nil then
        animal.rlGrowth = RLGrowth.deriveState(animal)
        animal.targetWeight = animal.rlGrowth.frameTargetKg
        Log:debug("RLGrowth: state derived for %s/%s weight=%.1f frame target=%.1f development=%.2f reserve=%.1f kg",
            tostring(animal.farmId), tostring(animal.uniqueId), animal.weight or 0, animal.rlGrowth.frameTargetKg,
            animal.rlGrowth.developmentMonths, animal.rlGrowth.reserveMassKg)
    end
    return animal.rlGrowth
end


--- The state to read: the saved one, else what the animal would be given (not stored).
function RLGrowth.peekState(animal)
    return animal.rlGrowth or RLGrowth.deriveState(animal)
end


-- =============================================================================
-- Birth
-- =============================================================================

--- Mean weight factor per calf of a litter.
function RLGrowth.getLitterFactor(size)
    local s = RLGrowth.getSettings()
    size = size or 1
    if size <= 1 then return 1 end
    if size == 2 then return s.litter2 end
    if size == 3 then return s.litter3 end
    return s.litter4
end


--- The dam's nutrition factor: from her body reserve, 1 at the reference reserve, between
--- damFactorMin and damFactorMax. 1 for a dam without a reserve on record: her weight against
--- a weight for age mixes frame, pregnancy and gut fill, so it is not read.
--- @param dam table|nil
--- @return number
function RLGrowth.getDamFactor(dam)
    local state = dam ~= nil and dam.bodyCondition or nil
    if state == nil or state.reserve == nil then return 1 end
    local s = RLGrowth.getSettings()
    local reference = RLBodyCondition.getConfig().referenceReserve
    return math.clamp(1 + s.damReserveEffect * (state.reserve - reference), s.damFactorMin, s.damFactorMax)
end


--- Mean birth weight of a breed's calf of a sex (nil when the breed has no profile).
--- @param breed string|nil
--- @param sex string
--- @return number|nil
function RLGrowth.getBreedBirthMean(breed, sex)
    if breed == nil then return nil end
    local config = RLGrowth.getConfig()
    local name = breed:upper()
    if config.profiles[name] == nil then
        local alias = config.aliases[name]
        name = alias ~= nil and alias.profile or nil
    end
    local profile = name ~= nil and config.profiles[name] or nil
    local knots = profile ~= nil and profile.knots[sex == "male" and "male" or "female"] or nil
    return knots ~= nil and knots[1][2] or nil
end


--- Mean birth weight of one calf of a birth.
--- @param childSubType table
--- @param ctx table { damBreed, sireBreed, litterSize, firstBirth, dam, metabolism }
--- @return number|nil kg; nil when the model does not cover the calf's subtype
function RLGrowth.getBirthMeanFor(childSubType, ctx)
    local binding = RLGrowth.getBinding(childSubType)
    if binding == nil then return nil end
    ctx = ctx or {}
    local s = RLGrowth.getSettings()
    local mean = RLGrowth.getBirthMean(binding)

    -- A cross within cattle: the mean of the dam's and the sire's breed for the calf's sex. Water
    -- buffalo never crosses with cattle.
    local damBreed, sireBreed = ctx.damBreed, ctx.sireBreed
    if damBreed ~= nil and sireBreed ~= nil and damBreed ~= sireBreed
        and (damBreed == "WATER_BUFFALO") == (sireBreed == "WATER_BUFFALO") then
        local damMean = RLGrowth.getBreedBirthMean(damBreed, binding.sex)
        local sireMean = RLGrowth.getBreedBirthMean(sireBreed, binding.sex)
        if damMean ~= nil and sireMean ~= nil then mean = (damMean + sireMean) / 2 end
    end

    mean = mean * RLGrowth.getLitterFactor(ctx.litterSize)
    if ctx.firstBirth then mean = mean * s.firstBirthFactor end
    mean = mean * RLGrowth.getDamFactor(ctx.dam)
    local _, _, _, birth = RLGrowth.getGeneFactors(ctx.metabolism)
    return math.max(mean * birth, 0)
end


--- A standard normal draw (Box-Muller), drawn again beyond birthTruncateSD (at most 20 times,
--- then clamped).
--- @param random function|nil Uniform (0,1) source, math.random by default
--- @return number z
function RLGrowth.drawZ(random)
    random = random or math.random
    local limit = RLGrowth.getSettings().birthTruncateSD
    local z = 0
    for _ = 1, 20 do
        local u1 = math.max(random(), 1e-12)
        z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * random())
        if math.abs(z) <= limit then return z end
    end
    return math.clamp(z, -limit, limit)
end


--- Draw one calf's birth weight.
--- @param childSubType table
--- @param ctx table See getBirthMeanFor
--- @param random function|nil
--- @return number|nil weight kg (nil when not covered)
--- @return number z Standard deviations from the mean
--- @return number mean kg
function RLGrowth.drawBirthWeight(childSubType, ctx, random)
    local mean = RLGrowth.getBirthMeanFor(childSubType, ctx)
    if mean == nil then return nil, 0, 0 end
    local z = RLGrowth.drawZ(random)
    return mean * (1 + RLGrowth.getSettings().birthWeightCV * z), z, mean
end


--- Set a newborn up: its weight is its birth weight, development 0, the neutral reserve, its
--- adult weight from its own genes. Its target weight follows.
--- @param child table
--- @param weight number kg
function RLGrowth.initBirth(child, weight)
    local binding = RLGrowth.getBinding(child:getSubType())
    if binding == nil then return end
    local bc = RLBodyCondition.getConfig()
    local frame, reserveKg = RLGrowthMath.split(weight, bc.initialReserve, RLGrowth.getKappa())
    local size = RLGrowth.getGeneFactors(child.genetics.metabolism)
    child.weight = weight
    child.rlGrowth = RLGrowth.newState({
        birthWeightKg = weight,
        frameTargetKg = RLGrowth.getAdultReference(binding) * size,
        developmentMonths = 0,
        reserveMassKg = reserveKg,
        speedFactor = RLGrowth.getStageSpeed(child),
        intakeFactor = RLBodyCondition.getIntakeCapacity(child),
        weightKg = weight,
        ageMonths = 0,
        source = "birth",
    })
    child.targetWeight = child.rlGrowth.frameTargetKg
    child.rlGrowthCurve = nil
end


-- =============================================================================
-- Feed request, price, underweight
-- =============================================================================

--- An old-rule individual target weight: the subtype's target moved by 0.4 x (m - 1). The live
--- price and the feed request were calibrated on the old line; they still read it, so an animal
--- on its curve costs and fetches what one on the old line did.
--- @param subType table
--- @param metabolism number|nil
--- @return number kg
function RLGrowth.getLegacyTarget(subType, metabolism)
    local target = subType.targetWeight or 0
    return target + ((target * (metabolism or 1)) - target) / 2.5
end


--- The old body factor of an animal on the old full-feed line at `age`: (line / expected)
--- before the exponent. 1 for a subtype without a growth line (no mature age).
local function getLegacyBodyRatio(subType, gender, metabolism, age)
    if RLBreedTraits.getMatureAge(subType) <= 0 then return 1 end
    local target = RLGrowth.getLegacyTarget(subType, metabolism)
    local expected = RLBreedTraits.getExpectedWeight(subType, target, age)
    if expected <= 0 then return 1 end
    return RLBreedTraits.getGrownWeight(subType, gender, target, age, metabolism) / expected
end


--- Food request factor of a weight: (weight / its curve at its age x what an animal on the old
--- line ate for its weight) ^ bodyWeightExponent, clamped as before. An animal on its curve asks
--- for what one on the old line did; heavier or lighter for its age, more or less by the same
--- exponent.
--- @param animal table A covered animal
--- @param weight number kg
--- @return number
function RLGrowth.getBodyFeedFactor(animal, weight)
    local config = RLBreedTraits.getConfig()
    local curve = RLGrowth.getCurve(animal)
    local age = math.max(animal.age or 0, 0)
    local reference = curve ~= nil and curve:value(age) or 0
    if reference <= 0 or weight == nil then return 1 end
    local subType = animal:getSubType()
    local ratio = weight / reference * getLegacyBodyRatio(subType, animal.gender, animal.genetics.metabolism, age)
    return math.clamp(ratio, config.minBodyRatio, config.maxBodyRatio) ^ config.bodyWeightExponent
end


--- Liters per period the animal requests on full feed at `weight` (its food curve, lactation,
--- pregnancy, its intake gene, the breed's feed trait and the body factor of that weight).
--- @param animal table
--- @param weight number
--- @param intakeGene number|nil Default the animal's
--- @param bodyFactor number|nil Default the animal's at `weight`
--- @return number
function RLGrowth.getRequestAt(animal, weight, intakeGene, bodyFactor)
    local subType = animal:getSubType()
    local food = subType.input ~= nil and subType.input.food or nil
    if food == nil then return 0 end
    local numPregnancies = (animal.pregnancy ~= nil and animal.pregnancy.pregnancies ~= nil) and #animal.pregnancy.pregnancies or 0
    local modifier = RLBreedTraits.get(subType, "feed") * (bodyFactor or RLGrowth.getBodyFeedFactor(animal, weight))
    local foodScale = RealisticLivestock_PlaceableHusbandryFood ~= nil and RealisticLivestock_PlaceableHusbandryFood.foodScale or 1
    return Animal._computeDailyFood(animal.age, animal.isLactating, animal.reproduction, numPregnancies,
        intakeGene or RLGrowth.getIntakeGene(animal), food:get(math.max(animal.age or 0, 0)), foodScale, modifier)
end


--- What the animal requests on full feed at its frame with the reference reserve: a reserve above
--- or below it does not change what its kind and size ask for.
--- @param animal table
--- @param state table|nil
--- @return number liters per period
function RLGrowth.getReferenceIntake(animal, state)
    state = state or RLGrowth.peekState(animal)
    local kappa = RLGrowth.getKappa()
    local frame = math.max((animal.weight or 0) - (state.reserveMassKg or 0), 0)
    return RLGrowth.getRequestAt(animal, frame * (1 + RLBodyCondition.getConfig().referenceReserve * kappa))
end


--- Under fixedFeedPrice: the reference a liter is priced by - an average animal of this subtype
--- (metabolism 1, mean birth weight) on its reference curve at this one's age, in this one's state
--- (lactating, pregnant). Its weight, the liters it requests and the energy its growth takes this
--- month. Nothing here moves with this animal's genes, reserve, castration, disease or needs.
--- @param animal table
--- @return number referenceLiters
--- @return number referenceWeight
--- @return number referenceGrowthNU per period
function RLGrowth.getSupplyReference(animal)
    local bc = RLBodyCondition.getConfig()
    local binding = RLGrowth.getBinding(animal:getSubType())
    local curve = RLGrowth.getNominalCurve(binding)
    local age = math.max(animal.age or 0, 0)
    local weight = curve:value(age)
    local kappa = RLGrowth.getKappa()
    local scale = 1 + bc.referenceReserve * kappa
    local gain = curve:slope(age)
    local growthNU = gain / scale * bc.growthNUPerKg + gain * (bc.referenceReserve * kappa / scale) * bc.depositNUPerKg
    local subType = animal:getSubType()
    local bodyFactor = math.clamp(getLegacyBodyRatio(subType, animal.gender, 1, age), RLBreedTraits.getConfig().minBodyRatio,
        RLBreedTraits.getConfig().maxBodyRatio) ^ RLBreedTraits.getConfig().bodyWeightExponent
    return RLGrowth.getRequestAt(animal, weight, 1, bodyFactor), weight, growthNU
end


--- Weight the live price reads: the animal's share of its curve at its age, put on the line the
--- prices were calibrated on (the price line where the breed has one, else the old full-feed
--- line), and the old-rule individual target the price formula measures it against.
--- @param animal table A covered animal
--- @param subType table
--- @return number weight
--- @return number legacyTarget
function RLGrowth.getPriceWeight(animal, subType)
    local curve = RLGrowth.getCurve(animal)
    local age = math.max(animal.age or 0, 0)
    local reference = curve ~= nil and curve:value(age) or 0
    local share = reference > 0 and animal.weight / reference or 1
    local metabolism = animal.genetics.metabolism
    local legacyTarget = RLGrowth.getLegacyTarget(subType, metabolism)
    local line
    if RLBreedTraits.getPriceModel(subType) ~= nil then
        line = RLBreedTraits.getPriceLineWeight(subType, age)
    else
        line = RLBreedTraits.getGrownWeight(subType, animal.gender, legacyTarget, age, metabolism)
    end
    return share * line, legacyTarget
end


--- Below this weight an animal loses health: underweightRatio of its curve at its age.
--- @param animal table A covered animal
--- @return number kg
function RLGrowth.getUnderweightThreshold(animal)
    local curve = RLGrowth.getCurve(animal)
    if curve == nil then return 0 end
    return RLGrowth.getSettings().underweightRatio * curve:value(math.max(animal.age or 0, 0))
end


-- =============================================================================
-- Hourly step
-- =============================================================================

--- Milk at full feed the budget pays for: a cow's (RLBodyCondition.applyMilk); for a bound type
--- (MILKCOW) its own milk output, read only - its store keeps the old rules.
local function getMilk(animal)
    local milk = animal.rlMilk
    if milk ~= nil then return milk end
    if animal.animalTypeIndex ~= nil and AnimalType ~= nil and animal.animalTypeIndex ~= AnimalType.COW then
        local perPeriod = math.max((animal.output ~= nil and animal.output.milk or 0) * 24, 0)
        return { potential = perPeriod, anchor = perPeriod, lineAnchor = perPeriod }
    end
    return { potential = 0, anchor = 0, lineAnchor = 0 }
end


--- Fetuses and progress of a pregnancy.
local function getPregnancy(animal)
    if not animal.isPregnant or animal.pregnancy == nil or animal.pregnancy.pregnancies == nil then return 0, 0 end
    return (animal.reproduction or 0) / 100, #animal.pregnancy.pregnancies
end


--- A disease's weight gain multiplier (1 without).
local function getDiseaseFactor(animal)
    if animal.getDiseaseMultipliers == nil then return 1 end
    local multipliers = animal:getDiseaseMultipliers("updateWeight")
    return multipliers ~= nil and multipliers.weightGain or 1
end


--- Build the step input (no state change).
--- @param animal table
--- @param state table
--- @param intakeLiters number Liters eaten per period (energy and digestion applied)
--- @param waterCoverage number
--- @param dtMonths number
--- @return table input
--- @return number ownReference Liters the animal itself requests on full feed
function RLGrowth.buildStepInput(animal, state, intakeLiters, waterCoverage, dtMonths)
    local bc = RLBodyCondition.getConfig()
    local s = RLGrowth.getSettings()
    local curve = RLGrowth.getCurve(animal)
    local kappa = RLGrowth.getKappa()
    local _, speedGene, maintenanceGene = RLGrowth.getGeneFactors(animal.genetics.metabolism)
    local progress, fetuses = getPregnancy(animal)
    local milk = getMilk(animal)
    local ownReference = RLGrowth.getReferenceIntake(animal, state)
    local condition = animal.bodyCondition

    local input = {
        dtMonths = dtMonths,
        weight = animal.weight,
        reserveKg = state.reserveMassKg,
        development = state.developmentMonths,
        curve = curve,
        kappa = kappa,
        frameFloorKg = s.frameFloorRatio * state.birthWeightKg / (1 + bc.referenceReserve * kappa),
        speed = speedGene * state.speedFactor,
        diseaseFactor = getDiseaseFactor(animal),
        maintenanceFactor = maintenanceGene,
        potentialMilk = milk.potential * waterCoverage,
        isLactating = animal.isLactating and milk.potential > 0,
        pregnancyProgress = progress,
        numFetuses = fetuses,
        intakeLiters = intakeLiters,
        intakeCapacity = state.intakeFactor,
        reserveCeiling = RLBodyCondition.getReserveCeiling(animal),
        balanceEMA = condition ~= nil and condition.balanceEMA or 0,
        lossRateEMA = condition ~= nil and condition.lossRateEMA or 0,
        fixedPrice = bc.fixedFeedPrice == true,
    }

    if input.fixedPrice then
        input.referenceLiters, input.referenceWeight, input.referenceGrowthNU = RLGrowth.getSupplyReference(animal)
        input.anchorMilk = milk.lineAnchor or 0
    else
        input.referenceLiters = ownReference
        input.anchorMilk = milk.anchor or 0
    end

    return input, ownReference
end


--- Liters of full ration the animal ate this hour: its share of its pen's feed ledger, or with
--- no ledger, the pen's food factor (forage digestion applied) of its request.
--- @return number litersThisStep
--- @return number allocatedLiters
--- @return string source "ledger" or "foodFactor"
local function getIntake(animal, supply, foodSpec, foodFactor)
    local environment = g_currentMission.environment
    local request = (animal:getInput("food") or 0) * (environment.timeAdjustment or 1)
    if supply ~= nil and request > 0 then
        local intake, allocated = RLBodyCondition.getAllocatedIntake(animal, supply)
        return intake, allocated, "ledger"
    end
    local eaten = math.max(foodFactor or 0, 0) * request
    local shares = foodSpec ~= nil and foodSpec.rlForageShares or nil
    return eaten * RLBreedTraits.getForageEfficiency(animal:getSubType(), shares), eaten, "foodFactor"
end


--- Move a stage factor toward its target over transitionMonths (about 95% in that time).
local function relax(value, target, dtMonths)
    if value == nil then return target end
    local alpha = 1 - math.exp(-3 * dtMonths / RLGrowth.getSettings().transitionMonths)
    return value + (target - value) * alpha
end


local lastNoLedger = {}

--- Run this hour's step for a covered animal. Called by the server from AnimalHealth.updateHealth
--- in place of every old weight rule. With its pen's feed ledger the animal eats its share of
--- what the pen ate; without one (a pen with no trough, the first hour after a load) it eats the
--- pen's food factor of its request. Either way the same budget, so there is no second weight
--- rule. An animal that took this hour's step already (moved in the same hour) is done.
--- @param animal table
--- @param foodFactor number The pen's (or the rearing pen's own) food factor
--- @return boolean handled False: not covered, the caller runs the old rules
function RLGrowth.step(animal, foodFactor)
    if animal == nil or animal.isDead or not RLGrowth.covers(animal) then return false end
    local tick = RLBodyCondition.getTickId()
    if tick == nil then return false end

    local state = RLGrowth.ensureState(animal)
    if state.lastTick == tick then return true end
    RLGrowth.resync(animal, state)

    local environment = g_currentMission.environment
    local dtMonths = RLWeightMath.getHourMonths(environment.daysPerPeriod)
    local supply, owner, foodSpec = RLBodyCondition.getLedger(animal, tick)
    local intakeStep, allocated, intakeSource = getIntake(animal, supply, foodSpec, foodFactor)
    if intakeSource ~= "ledger" then
        local key = owner ~= nil and tostring(owner) or "?"
        if lastNoLedger[key] ~= tick then
            lastNoLedger[key] = tick
            Log:debug("RLGrowth: no feed ledger this hour in %s (tick=%s), intake from the food factor %.2f",
                owner ~= nil and owner.getName ~= nil and owner:getName() or "?", tostring(tick), foodFactor or 0)
        end
    end

    local water = foodSpec ~= nil and foodSpec.rlWaterCoverage or nil
    local waterCoverage = (water ~= nil and water.tick == tick) and water.coverage or 1

    state.speedFactor = relax(state.speedFactor, RLGrowth.getStageSpeed(animal), dtMonths)
    state.intakeFactor = relax(state.intakeFactor, RLBodyCondition.getIntakeCapacity(animal), dtMonths)
    RLGrowth.advanceClock(state, animal.age or 0, dtMonths)

    local input, ownReference = RLGrowth.buildStepInput(animal, state, intakeStep / dtMonths, waterCoverage, dtMonths)
    local result = RLGrowthMath.step(input, RLBodyCondition.getConfig())

    if result.weight ~= result.weight or result.reserveKg ~= result.reserveKg or result.development ~= result.development then
        Log:warning("RLGrowth: step for %s/%s gave NaN, nothing applied this hour", tostring(animal.farmId), tostring(animal.uniqueId))
        state.lastTick = tick
        animal.rlMilkPaid = { tick = tick, litersPerHour = 0, deposited = false }
        return true
    end

    animal.weight = result.weight
    state.weightKg = result.weight
    state.reserveMassKg = result.reserveKg
    state.developmentMonths = result.development
    state.lastTick = tick

    -- The body condition reads the reserve as its index r = R / K.
    local condition = RLBodyCondition.ensureState(animal, "growth")
    condition.reserve = math.clamp(result.reserve, 0, 1)
    condition.capacityKg = math.max(result.capacityKg, 1)
    condition.balanceEMA = result.balanceEMA
    condition.lossRateEMA = result.lossRateEMA
    condition.lastTick = tick

    local potentialPerHour = animal.rlMilk ~= nil and animal.rlMilk.potential / 24 or 0
    local milkShare = result.milkFraction * waterCoverage
    animal.rlMilkPaid = { tick = tick, litersPerHour = potentialPerHour * milkShare, deposited = false }

    animal.rlNutrition = {
        tick = tick,
        allocatedLiters = allocated,
        intakeRatio = ownReference > 0 and (intakeStep / dtMonths) / ownReference or 0,
        coverage = result.coverage,
        milkShare = potentialPerHour > 0 and milkShare or nil,
        growthFraction = result.growthFraction,
        intakeSource = intakeSource,
    }

    if owner ~= nil then owner.rlBodyConditionStepped = tick end
    return true
end


--- Set the reserve index of a covered animal (console): the frame is kept, the reserve mass and
--- live weight move with it.
--- @param animal table
--- @param reserve number 0..1
function RLGrowth.setReserveIndex(animal, reserve)
    local state = RLGrowth.ensureState(animal)
    RLGrowth.resync(animal, state)
    local frame = math.max(animal.weight - state.reserveMassKg, 0)
    state.reserveMassKg = math.max(reserve, 0) * frame * RLGrowth.getKappa()
    animal.weight = frame + state.reserveMassKg
    state.weightKg = animal.weight
end


-- =============================================================================
-- Persistence and network
-- =============================================================================

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end


--- Read a saved state (nil when the animal has none or it is unusable; the animal then gets a
--- derived one, its weight kept).
function RLGrowth.loadFromXMLFile(xmlFile, key)
    local base = key .. ".growth"
    local birth = xmlFile:getFloat(base .. "#birthWeightKg")
    if birth == nil then return nil end

    local version = xmlFile:getInt(base .. "#version", 1)
    if version > RLGrowth.STATE_VERSION then
        Log:warning("RLGrowth: %s has state version %d, newer than this mod's %d; dropped", base, version, RLGrowth.STATE_VERSION)
        return nil
    end

    local state = RLGrowth.newState({
        birthWeightKg = birth,
        frameTargetKg = xmlFile:getFloat(base .. "#frameTargetKg"),
        developmentMonths = xmlFile:getFloat(base .. "#developmentMonths", 0),
        reserveMassKg = xmlFile:getFloat(base .. "#reserveMassKg", 0),
        speedFactor = xmlFile:getFloat(base .. "#speedFactor", 1),
        intakeFactor = xmlFile:getFloat(base .. "#intakeFactor", 1),
        weightKg = xmlFile:getFloat(base .. "#weightKg"),
        ageMonths = xmlFile:getFloat(base .. "#ageMonths"),
        source = xmlFile:getString(base .. "#source", "derived"),
        lastTick = xmlFile:getInt(base .. "#lastTick", -1),
    })
    state.version = version

    if not (finite(state.birthWeightKg) and state.birthWeightKg > 0 and finite(state.frameTargetKg) and state.frameTargetKg > 0
        and finite(state.developmentMonths) and state.developmentMonths >= 0 and finite(state.reserveMassKg)
        and state.reserveMassKg >= 0 and finite(state.speedFactor) and finite(state.intakeFactor)) then
        Log:warning("RLGrowth: %s has an unusable state; it is derived again from the weight", base)
        return nil
    end
    return state
end


function RLGrowth.saveToXMLFile(state, xmlFile, key)
    if state == nil then return end
    local base = key .. ".growth"
    xmlFile:setInt(base .. "#version", state.version or RLGrowth.STATE_VERSION)
    xmlFile:setFloat(base .. "#birthWeightKg", state.birthWeightKg)
    xmlFile:setFloat(base .. "#frameTargetKg", state.frameTargetKg)
    xmlFile:setFloat(base .. "#developmentMonths", state.developmentMonths)
    xmlFile:setFloat(base .. "#reserveMassKg", state.reserveMassKg)
    xmlFile:setFloat(base .. "#speedFactor", state.speedFactor or 1)
    xmlFile:setFloat(base .. "#intakeFactor", state.intakeFactor or 1)
    if state.weightKg ~= nil then xmlFile:setFloat(base .. "#weightKg", state.weightKg) end
    if state.ageMonths ~= nil then xmlFile:setFloat(base .. "#ageMonths", state.ageMonths) end
    xmlFile:setString(base .. "#source", state.source or "derived")
    xmlFile:setInt(base .. "#lastTick", state.lastTick or -1)
end


--- Write a state to a stream: a presence flag, then the fields. Order must match readStream.
function RLGrowth.writeStream(state, streamId)
    streamWriteBool(streamId, state ~= nil)
    if state == nil then return end
    streamWriteFloat32(streamId, state.birthWeightKg)
    streamWriteFloat32(streamId, state.frameTargetKg)
    streamWriteFloat32(streamId, state.developmentMonths)
    streamWriteFloat32(streamId, state.reserveMassKg)
    streamWriteFloat32(streamId, state.speedFactor or 1)
    streamWriteFloat32(streamId, state.intakeFactor or 1)
    streamWriteFloat32(streamId, state.weightKg or -1)
end


function RLGrowth.readStream(streamId)
    if not streamReadBool(streamId) then return nil end
    return RLGrowth.newState({
        birthWeightKg = streamReadFloat32(streamId),
        frameTargetKg = streamReadFloat32(streamId),
        developmentMonths = streamReadFloat32(streamId),
        reserveMassKg = streamReadFloat32(streamId),
        speedFactor = streamReadFloat32(streamId),
        intakeFactor = streamReadFloat32(streamId),
        weightKg = (function(value) return value >= 0 and value or nil end)(streamReadFloat32(streamId)),
        source = "stream",
    })
end


-- =============================================================================
-- Report
-- =============================================================================

--- What the game offers the model for a subtype's animals: whether they are individual animals
--- here, whether the subtype file gives weights, whether they reproduce, and how many are loaded
--- as individuals and as vanilla clusters.
--- @param subType table
--- @return table
function RLGrowth.describeCapability(subType)
    local capability = {
        weightFields = subType.rlWeightFieldsGiven,
        reproduction = subType.supportsReproduction == true,
        individuals = 0,
        clusters = 0,
    }
    local mission = g_currentMission
    local placeables = mission ~= nil and mission.husbandrySystem ~= nil and mission.husbandrySystem.placeables or nil
    for _, placeable in pairs(placeables or {}) do
        local clusters = placeable.getClusters ~= nil and placeable:getClusters() or {}
        for _, cluster in ipairs(clusters) do
            local index = cluster.subTypeIndex or (cluster.getSubTypeIndex ~= nil and cluster:getSubTypeIndex()) or nil
            if index == subType.subTypeIndex then
                if cluster.isIndividual == true then
                    capability.individuals = capability.individuals + 1
                else
                    capability.clusters = capability.clusters + (cluster.numAnimals or 1)
                end
            end
        end
    end
    capability.adapter = capability.clusters > 0 and capability.individuals == 0 and "INACTIVE_VANILLA_CLUSTERS"
        or "INDIVIDUALS_ONLY"
    return capability
end


--- The curve a subtype's animals grow on (average genes): whether the model runs it, adult and
--- birth weight, the plateau month and the knots.
--- @param subType table
--- @return table|nil
function RLGrowth.describeCurve(subType)
    local binding = RLGrowth.getBinding(subType)
    if binding == nil then return nil end
    local knots = RLGrowth.getReferenceKnots(binding)
    local list = {}
    for _, knot in ipairs(knots) do list[#list + 1] = { knot[1], RLWeightProfiles.round(knot[2], 2) } end
    return {
        active = RLGrowth.isEnabled(),
        sex = binding.sex,
        adultKg = RLWeightProfiles.round(RLGrowth.getAdultReference(binding), 2),
        birthKg = RLWeightProfiles.round(RLGrowth.getBirthMean(binding), 3),
        plateauMonth = knots[#knots][1],
        configTargetWeight = subType.targetWeight,
        knots = list,
    }
end
