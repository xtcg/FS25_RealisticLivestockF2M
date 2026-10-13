--[[
    RLGrowth.lua
    The cattle weight model v2 in the game: which animals it covers, the state each carries, the
    continuous growth curve each grows on, birth weights, the hourly step (RLGrowthMath) and what
    the rest of the mod reads from it (price line, feed request, underweight).

    Coverage. Cattle (animal type COW) whose breed resolves to a profile in weightProfiles.xml
    (exactly or through a map's alias), and animal types the file binds to a profile as a stand-in
    (Hof Bergmann's MILKCOW on the Holstein female curve) wherever the game holds them as
    individual animals. The model needs the body condition feature (its energy settings, feed
    ledger and reserve display); with either switched off, every animal keeps the old rules.

    Curves. A profile's reference curve per sex runs through its knots (RLGrowthCurve) from the
    mean birth weight to the adult plateau. An animal's own curve is that curve x its size gene,
    with its actual birth weight replacing the mean and the difference faded out over the first
    birthFadeMonths. Births, shop stock, the growth itself, the feed request's body factor, the
    live price's weight-for-age and the underweight check all read this one curve.

    Two adult weights. The curve's plateau (frameTargetKg) is what the animal grows to. Its
    target weight (animal.targetWeight) stays the subtype's configured target x its size gene:
    the slaughter reference (target x maturity), the finishing reserve curve and the finish
    verdict are calibrated on it, and the design's arrival points sit on it (a Charolais pack bull
    is finished at 1050 x 0.75 = 787.5 kg, its curve passing 790 kg at 20 months, while it grows
    on to 1260 kg). For this mod's breeds the two are the same at average genes.

    Metabolism gene m (0.25..1.75), z = clamp((m - 1) / geneSpan, -1, 1), acts three ways, each
    bounded: adult size 1 + sizeGeneEffect x z, development speed 1 + speedGeneEffect x z,
    maintenance (and the feed it asks for) 1 + maintenanceGeneEffect x z. Birth weight
    1 + birthGeneEffect x (m - 1). Nothing multiplies the full gene in twice.

    State (animal.rlGrowth, saved and streamed with the animal, and sent to clients each hour):
        birthWeightKg (the actual draw), frameTargetKg (the curve's plateau), developmentMonths
        (how far along the curve its frame is), reserveMassKg (the reserve's mass inside the live
        weight), speedFactor and intakeFactor (stage factors in transition), weightKg (the live
        weight the state was last set for), ageMonths (a continuous age clock), legacyAnchor and
        anchorElapsedMonths (an old savegame's animal, below), feedAdapted (the concentrate share its
        rumen is adapted to) and feedShortDays (model days of maintenance shortfall built up), both
        real-equivalent nutrition (RLFeed), source ("birth", "generated",
        "derived", "resync", "stream"), lastTick (game hour of the last step), version.
    The body condition state (animal.bodyCondition) mirrors the reserve as its index r = R / K
    after every step, so BCS, finish score and their factors read it as before.

    Pregnancy and calving. A pregnant cow's live weight carries the calf, membranes and fluids
    (gravidKg, from her pregnancy's progress, settings gravid*): it is no part of her frame or
    reserve, the budget works on the weight without it, and when the pregnancy ends - a birth or a
    lost calf - the next step takes it off in one go. Calving is a drop of that mass, never of
    tissue. After it appetite lags behind milk (lactationMonths, getLactationFactor): she draws
    her reserve through early lactation and rebuilds it as intake catches up and milk declines.

    No other event changes the weight: weaning, castration, drying off, a move, a sale, a save
    and a load only change what later steps integrate. A weight changed by anything else (the old
    rules while the model was off, the console, another mod) is taken as it is: the next step
    splits it again at the animal's reserve index (RLGrowth.resync).

    An old savegame's animal keeps its weight exactly: its reserve index (the body condition's,
    else the neutral one) splits the weight into frame and reserve, and its development is where
    its curve has that frame. It grew on the old line, which is up to 20-30% above or below the
    new curve at some ages, so measured against the new curve its price, food request and
    underweight check would jump on load. Its legacy anchor (new curve / old line at its age when
    it was taken over) keeps all three exactly where the old rules had them, and fades out over
    migrationBlendMonths, after which it is measured against its curve like any other. Its food
    request's gene factor (m to 1 + 0.15 z), its target weight (the old 1 + 0.4 (m - 1) to the size
    gene) and its underweight threshold (the old minWeight rule to the curve's) move the same way.
    One that the change of model left behind its curve catches up during that time (its budget
    paying for it), so it is not counted stunted once the anchor is gone; growth lost for want of
    feed never catches up.

    Calves. In a rearing pen a calf's own milk and solid liters are valued separately (solid feed
    at RLCalfRearing.getSolidEnergyFactor). Anywhere else a calf's share of its pen's trough stands
    for its whole diet, suckling included, and is valued as any animal's.
]]

RLGrowth = {}

local Log = RmLogging.getLogger("RLRM")

RLGrowth.STATE_VERSION = 1

--- Weight differences below this are the float rounding of a save or a stream, not a change.
RLGrowth.RESYNC_TOLERANCE_KG = 0.01

--- The continuous age never runs a whole month ahead of the whole months.
RLGrowth.AGE_CLOCK_CAP = 0.999

--- A legacy anchor is kept within these bounds (a broken old weight line cannot blow it up);
--- every real breed and Hof Bergmann's MILKCOW fall well inside them.
RLGrowth.ANCHOR_MIN = 0.2
RLGrowth.ANCHOR_MAX = 5


-- =============================================================================
-- Config, coverage
-- =============================================================================

local bindingCache = setmetatable({}, { __mode = "k" })
local nominalCache = {}
local cacheConfig = nil

--- Forget cached bindings and curves (after the config is replaced).
function RLGrowth.resetCaches()
    bindingCache = setmetatable({}, { __mode = "k" })
    nominalCache = {}
    cacheConfig = nil
end


--- The caches belong to one config table: a replaced config (a reload) empties them.
local function checkCaches()
    local config = RLWeightProfiles.config
    if config ~= cacheConfig then
        bindingCache = setmetatable({}, { __mode = "k" })
        nominalCache = {}
        cacheConfig = config
    end
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


--- The profile and sex curve a subtype grows on (RLWeightProfiles.getCurveBinding). Cached per
--- subtype once its animal type is known; asked before the animal system can name the type, the
--- answer is not kept.
--- @param subType table|nil
--- @return table|nil binding
--- @return string resolution
function RLGrowth.getBinding(subType)
    if subType == nil then return nil, "UNRESOLVED" end
    checkCaches()
    local cached = bindingCache[subType]
    if cached == nil then
        local binding, resolution = RLWeightProfiles.getCurveBinding(subType)
        cached = { binding = binding, resolution = resolution }
        if RLBreedTraits.getTypeName(subType) ~= nil then bindingCache[subType] = cached end
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
--- gene itself (the old rule) for any other. An old savegame's animal starts at its old factor
--- and moves to the new one as its legacy anchor fades (getAnchorRemaining).
--- @param animal table
--- @return number
function RLGrowth.getIntakeGene(animal)
    local metabolism = animal.genetics ~= nil and animal.genetics.metabolism or 1
    if not RLGrowth.covers(animal) then return metabolism end
    local _, _, maintenance = RLGrowth.getGeneFactors(metabolism)
    return RLGrowth.blendLegacy(maintenance, metabolism, RLGrowth.getAnchorRemaining(animal, RLGrowth.peekState(animal)))
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
    checkCaches()
    local key = binding.profile .. "/" .. binding.sex
    local curve = nominalCache[key]
    if curve == nil then
        curve = RLGrowthCurve.new(RLGrowth.getReferenceKnots(binding))
        nominalCache[key] = curve
    end
    return curve
end


--- An animal's own knots: the reference knots x size, the birth knot replaced by its actual birth
--- weight and the difference faded out by fadeMonths, always rising (by MIN_RISE at least).
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
        if i > 1 then weight = math.max(weight, out[i - 1][2] + RLGrowthCurve.MIN_RISE) end
        out[i] = { knot[1], math.max(weight, RLGrowthCurve.MIN_RISE) }
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
--- transition, the legacy anchor's fade): the state's own clock, which every step moves on by the
--- months it covers, kept within the animal's whole months (an animal ages by its birthday on a
--- day change, after that day's first hour, so the period's clock alone would step back for an
--- hour). Whole months without a state. Comparisons with a curve at an age use the whole months,
--- as the old rules did.
--- @param animal table
--- @return number
function RLGrowth.getContinuousAge(animal)
    local age = animal.age or 0
    local state = animal.rlGrowth
    if state == nil or state.ageMonths == nil then return age end
    return math.min(math.max(state.ageMonths, age), age + RLGrowth.AGE_CLOCK_CAP)
end


--- Move the state's clock on by dtMonths, within the animal's whole months.
--- @param state table
--- @param age number Whole months
--- @param dtMonths number
function RLGrowth.advanceClock(state, age, dtMonths)
    local value = (state.ageMonths or age) + dtMonths
    state.ageMonths = math.min(math.max(value, age), age + RLGrowth.AGE_CLOCK_CAP)
end


-- =============================================================================
-- Old line, legacy anchor
-- =============================================================================

--- An old-rule individual target weight: the subtype's target moved by 0.4 x (m - 1). The live
--- price and the feed request were calibrated on the old line; they still read it, so an animal
--- on its curve costs and fetches what one on the old line did.
--- @param subType table
--- @param metabolism number|nil
--- @return number kg
function RLGrowth.getLegacyTarget(subType, metabolism)
    return RLBreedTraits.getGeneTarget(subType.targetWeight, metabolism)
end


--- Whether the subtype had an old full-feed line at all: a mature age and a target above its
--- minWeight (otherwise the old line is a constant and nothing was calibrated on it).
function RLGrowth.hasLegacyLine(subType, metabolism)
    return RLBreedTraits.getMatureAge(subType) > 0 and RLGrowth.getLegacyTarget(subType, metabolism) > (subType.minWeight or 0)
end


--- The old full-feed line of an animal of these genes at `age` (with its old-rule target); nil
--- for a subtype without one.
function RLGrowth.getLegacyLine(subType, gender, metabolism, age)
    if not RLGrowth.hasLegacyLine(subType, metabolism) then return nil end
    return RLBreedTraits.getGrownWeight(subType, gender, RLGrowth.getLegacyTarget(subType, metabolism), age, metabolism)
end


--- The old body factor of an animal on the old full-feed line at `age`: (line / expected)
--- before the exponent. 1 for a subtype without a growth line.
local function getLegacyBodyRatio(subType, gender, metabolism, age)
    local line = RLGrowth.getLegacyLine(subType, gender, metabolism, age)
    if line == nil then return 1 end
    local expected = RLBreedTraits.getExpectedWeight(subType, RLGrowth.getLegacyTarget(subType, metabolism), age)
    if expected <= 0 then return 1 end
    return line / expected
end


--- The legacy anchor of an animal taken over from the old rules at its age: its curve there over
--- the old line there (an animal on the old line then counts as on its curve), within
--- ANCHOR_MIN..ANCHOR_MAX; 1 where the old line has no weight.
--- @param animal table
--- @param curve table The animal's curve
--- @return number
function RLGrowth.getLegacyAnchor(animal, curve)
    local age = math.max(animal.age or 0, 0)
    local line = RLGrowth.getLegacyLine(animal:getSubType(), animal.gender, animal.genetics.metabolism, age)
    local reference = curve:value(age)
    if line == nil or line <= 0 or reference <= 0 then return 1 end
    return math.clamp(reference / line, RLGrowth.ANCHOR_MIN, RLGrowth.ANCHOR_MAX)
end


--- How much of an old savegame's animal's take-over is left: 1 when taken over, falling evenly
--- to 0 over migrationBlendMonths of the months its steps have covered since (anchorElapsedMonths,
--- its own clock: whole-month ageing on a birthday does not step it); 0 for an animal with no
--- legacy anchor.
--- @param animal table
--- @param state table|nil
--- @return number 0..1
function RLGrowth.getAnchorRemaining(animal, state)
    if state == nil or state.legacyAnchor == nil then return 0 end
    return math.clamp(1 - (state.anchorElapsedMonths or 0) / RLGrowth.getSettings().migrationBlendMonths, 0, 1)
end


--- An old savegame's animal's value moving from the old rules' to the model's as its take-over
--- fades: newValue x (oldValue / newValue) ^ remaining (geometric, so a ratio moves evenly); the
--- model's value when nothing is left or either value is not positive.
--- @param newValue number
--- @param oldValue number
--- @param remaining number 0..1 (getAnchorRemaining)
--- @return number
function RLGrowth.blendLegacy(newValue, oldValue, remaining)
    if remaining <= 0 or newValue <= 0 or oldValue <= 0 then return newValue end
    return newValue * (oldValue / newValue) ^ math.min(remaining, 1)
end


--- What is left of an animal's legacy anchor now: anchor ^ getAnchorRemaining, down to 1.
--- @param animal table
--- @param state table|nil
--- @return number
function RLGrowth.getAnchorFactor(animal, state)
    if state == nil or state.legacyAnchor == nil or state.legacyAnchor == 1 then return 1 end
    local remaining = RLGrowth.getAnchorRemaining(animal, state)
    if remaining <= 0 then return 1 end
    return state.legacyAnchor ^ remaining
end


--- How an animal's weight stands against its curve at its age (whole months): weight / curve x
--- what is left of its legacy anchor. 1 on its curve.
--- @param animal table A covered animal
--- @param weight number|nil Default its live weight
--- @return number
function RLGrowth.getShare(animal, weight)
    local curve = RLGrowth.getCurve(animal)
    local reference = curve ~= nil and curve:value(math.max(animal.age or 0, 0)) or 0
    if reference <= 0 then return 1 end
    return (weight or animal.weight or 0) / reference * RLGrowth.getAnchorFactor(animal, RLGrowth.peekState(animal))
end


-- =============================================================================
-- State
-- =============================================================================

--- Stage speed the development moves at: castratedSpeed for a steer, else 1.
function RLGrowth.getStageSpeed(animal)
    return animal.isCastrated and RLGrowth.getSettings().castratedSpeed or 1
end


--- A new state.
--- @param fields table
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
        legacyAnchor = fields.legacyAnchor,
        anchorElapsedMonths = fields.anchorElapsedMonths,
        feedAdapted = fields.feedAdapted,
        feedShortDays = fields.feedShortDays,
        gravidKg = fields.gravidKg,
        lactationMonths = fields.lactationMonths,
        source = fields.source or "derived",
        lastTick = fields.lastTick or -1,
    }
end


--- A copy of a state (clone, move): two animals never share one table.
function RLGrowth.copyState(state)
    return RLBodyCondition.copyState(state)
end


--- Mass of the calf or calves, membranes and fluids a pregnant animal carries now: the expected
--- birth weight of her calves (a litter's, a first calving's) x gravidTermRatio x the share of
--- her pregnancy ^ gravidExponent. 0 when not pregnant.
--- @param animal table
--- @return number kg
function RLGrowth.getGravidTarget(animal)
    local s = RLGrowth.getSettings()
    if s.gravidTermRatio <= 0 then return 0 end
    local progress, fetuses = RLBodyCondition.getPregnancy(animal)
    if progress <= 0 or fetuses <= 0 then return 0 end
    local child = animal.pregnancy.pregnancies[1]
    local childSubType = (child ~= nil and child.getSubType ~= nil) and child:getSubType() or animal:getSubType()
    local mean = RLGrowth.getBirthMeanFor(childSubType, { damBreed = animal.breed, litterSize = fetuses,
        firstBirth = not animal.isParent, dam = animal, metabolism = 1 })
    if mean == nil then return 0 end
    return mean * fetuses * s.gravidTermRatio * math.clamp(progress, 0, 1) ^ s.gravidExponent
end


--- The gravid mass inside the animal's live weight now: what its state last carried; for a state
--- that has none on record (an old savegame's pregnant cow) what her pregnancy has built, as her
--- weight is taken as it is.
--- @param animal table
--- @param state table|nil
--- @return number kg
function RLGrowth.getCarriedGravid(animal, state)
    if state ~= nil and state.gravidKg ~= nil then return math.min(state.gravidKg, animal.weight or 0) end
    return math.min(RLGrowth.getGravidTarget(animal), animal.weight or 0)
end


--- Months since the animal's last calving: its clock, else the game's whole months (and half
--- of one) when the clock is not running yet.
--- @param animal table
--- @param state table|nil
--- @return number
function RLGrowth.getLactationMonths(animal, state)
    if state ~= nil and state.lactationMonths ~= nil then return state.lactationMonths end
    return (animal.monthsSinceLastBirth or 12) + 0.5
end


--- Dry matter intake of a cow in early lactation against her full appetite: NRC 2001
--- 1 - exp(-rate x (weeks in milk + offset)), at a strength (lactationIntakeStrength for the
--- real-equivalent mode's appetite, lactationCapacityStrength for the old mode's credit per
--- liter eaten). 1 for an animal that is not lactating or whose milk is long established.
--- @param animal table
--- @param state table|nil
--- @param legacy boolean|nil The old nutrition mode's milder strength
--- @return number 0..1
function RLGrowth.getLactationFactor(animal, state, legacy)
    if not animal.isLactating then return 1 end
    local s = RLGrowth.getSettings()
    local strength = legacy and s.lactationCapacityStrength or s.lactationIntakeStrength
    if strength <= 0 then return 1 end
    local weeks = RLGrowth.getLactationMonths(animal, state) * s.lactationWeeksPerMonth
    local nrc = 1 - math.exp(-s.lactationIntakeRate * (weeks + s.lactationIntakeOffset))
    return 1 - strength * (1 - math.min(nrc, 1))
end


--- The state of an animal with a weight and no state: its weight kept exactly. A reserve index
--- (its body condition's, else the neutral initial one) splits the weight into frame and reserve;
--- its development is where its curve has that frame; adult weight and birth weight from its
--- genes. Read-only: nothing is stored.
--- @param animal table A covered animal
--- @param source string "derived" (taken over from the old rules: with a legacy anchor),
---        "generated" (its weight is its curve's) or "rederived" (its saved state was unusable: it
---        grew under the model, so no anchor either)
--- @return table state
function RLGrowth.deriveState(animal, source)
    local bc = RLBodyCondition.getConfig()
    local binding = RLGrowth.getBinding(animal:getSubType())
    local kappa = RLGrowth.getKappa()
    local reserve = animal.bodyCondition ~= nil and animal.bodyCondition.reserve or bc.initialReserve
    local frameTarget = RLGrowth.getFrameTarget(animal, binding)
    local birth = RLGrowth.getBirthWeight(animal, binding)
    local curve = RLGrowth.getCurve(animal)
    local gravid = math.min(RLGrowth.getGravidTarget(animal), animal.weight or 0)
    local frame, reserveKg = RLGrowthMath.split(math.max((animal.weight or 0) - gravid, 0), reserve, kappa)
    source = source or "derived"

    return RLGrowth.newState({
        birthWeightKg = birth,
        frameTargetKg = frameTarget,
        developmentMonths = RLGrowthMath.getDevelopment(curve, frame, kappa, bc.referenceReserve),
        reserveMassKg = reserveKg,
        speedFactor = RLGrowth.getStageSpeed(animal),
        intakeFactor = RLBodyCondition.getIntakeCapacity(animal),
        weightKg = animal.weight,
        gravidKg = gravid,
        lactationMonths = animal.isLactating and RLGrowth.getLactationMonths(animal, nil) or nil,
        legacyAnchor = source == "derived" and RLGrowth.getLegacyAnchor(animal, curve) or nil,
        anchorElapsedMonths = source == "derived" and 0 or nil,
        source = source,
    })
end


--- Take a weight something else changed as it is: split it again at the animal's reserve index
--- (its body condition's, which the old rules keep moving, else the state's own) and put its
--- development where its curve has that frame. Birth weight, adult weight, stage factors and a
--- legacy anchor stay.
--- @param animal table
--- @param state table
--- @return boolean changed
function RLGrowth.resync(animal, state)
    local weight = animal.weight or 0
    -- A state without the weight it was set for (written before weightKg existed) is taken as it
    -- was saved, with the weight it came with.
    if state.weightKg == nil then
        state.weightKg = weight
        return false
    end
    if math.abs(weight - state.weightKg) <= RLGrowth.RESYNC_TOLERANCE_KG then return false end
    local bc = RLBodyCondition.getConfig()
    local kappa = RLGrowth.getKappa()
    local gravid = RLGrowth.getCarriedGravid(animal, state)
    local reserve = animal.bodyCondition ~= nil and animal.bodyCondition.reserve or nil
    if reserve == nil then
        local frame = (state.weightKg or weight) - gravid - state.reserveMassKg
        reserve = frame > 0 and state.reserveMassKg / (frame * kappa) or bc.initialReserve
    end
    local frame, reserveKg = RLGrowthMath.split(math.max(weight - gravid, 0), reserve, kappa)
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
--- How an animal without a state is taken over: from the old rules, or again under the model
--- when the state it was saved with could not be used (Animal.new's rlGrowthDropped).
local function getDeriveSource(animal)
    return animal.rlGrowthDropped and "rederived" or "derived"
end


function RLGrowth.ensureState(animal)
    if animal.rlGrowth == nil then
        animal.rlGrowth = RLGrowth.deriveState(animal, getDeriveSource(animal))
        animal.rlGrowthPeek = nil
        Log:debug("RLGrowth: state derived for %s/%s weight=%.1f adult=%.1f development=%.2f reserve=%.1f kg anchor=%.3f",
            tostring(animal.farmId), tostring(animal.uniqueId), animal.weight or 0, animal.rlGrowth.frameTargetKg,
            animal.rlGrowth.developmentMonths, animal.rlGrowth.reserveMassKg, animal.rlGrowth.legacyAnchor or 1)
    end
    return animal.rlGrowth
end


--- The state to read: the saved one, else what the animal would be given (not stored as its
--- state; kept aside while its weight stays the same, so reading it again costs nothing).
function RLGrowth.peekState(animal)
    if animal.rlGrowth ~= nil then return animal.rlGrowth end
    local peek = animal.rlGrowthPeek
    local reserve = animal.bodyCondition ~= nil and animal.bodyCondition.reserve or nil
    if peek == nil or peek.weightKg ~= animal.weight or peek.peekAge ~= animal.age or peek.peekReserve ~= reserve then
        peek = RLGrowth.deriveState(animal, getDeriveSource(animal))
        peek.peekAge, peek.peekReserve = animal.age, reserve
        animal.rlGrowthPeek = peek
    end
    return peek
end


--- The state of an animal whose weight was set from its curve when it was created (dealer stock,
--- a new game's herds, a converted cluster): no legacy anchor, nothing to take over.
--- @param animal table
--- @return table
function RLGrowth.createGeneratedState(animal)
    local state = RLGrowth.deriveState(animal, "generated")
    state.ageMonths = math.max(animal.age or 0, 0)
    return state
end


--- Frame and reserve mass of an animal: its state's, else its weight split at its reserve index.
--- @param animal table
--- @return number frameKg
--- @return number reserveKg
function RLGrowth.getFrameAndReserve(animal)
    local state = animal.rlGrowth
    if state ~= nil then
        local body = (animal.weight or 0) - RLGrowth.getCarriedGravid(animal, state)
        local reserve = math.min(math.max(state.reserveMassKg or 0, 0), body)
        return body - reserve, reserve
    end
    local bc = RLBodyCondition.getConfig()
    local index = animal.bodyCondition ~= nil and animal.bodyCondition.reserve or bc.initialReserve
    local body = (animal.weight or 0) - math.min(RLGrowth.getGravidTarget(animal), animal.weight or 0)
    return RLGrowthMath.split(math.max(body, 0), index, RLGrowth.getKappa())
end


-- =============================================================================
-- Constructor, generated animals
-- =============================================================================

--- An animal's target weight under the model: the subtype's configured target x its size gene
--- (the slaughter reference and finishing are calibrated on it); nil when the model does not
--- cover the subtype (the old formula applies).
--- @param subType table|nil
--- @param genetics table
--- @return number|nil
function RLGrowth.getTargetWeight(subType, genetics)
    if subType == nil or genetics == nil or not RLGrowth.coversSubType(subType) then return nil end
    return (subType.targetWeight or 0) * (RLGrowth.getGeneFactors(genetics.metabolism))
end


--- The target weight a covered animal has now: the model's (getTargetWeight); an animal not yet
--- taken over from the old rules (no state) keeps the old rules' (subtype target moved by
--- 0.4 x (m - 1)), and one taken over moves from that to the model's as its legacy anchor fades,
--- so the slaughter reference, finishing and the slaughter-value floor do not jump on load.
--- @param animal table A covered animal
--- @return number kg
function RLGrowth.getAnimalTargetWeight(animal)
    local subType = animal:getSubType()
    local target = RLGrowth.getTargetWeight(subType, animal.genetics) or 0
    local legacy = RLGrowth.getLegacyTarget(subType, animal.genetics.metabolism)
    local state = animal.rlGrowth
    if state == nil then return legacy end
    return RLGrowth.blendLegacy(target, legacy, RLGrowth.getAnchorRemaining(animal, state))
end


--- Weight of an animal that appears with none of its own (dealer stock, a new game's herds, a
--- converted cluster): its curve at its age (mean birth weight x its birth gene), at the neutral
--- reserve. Deterministic: it draws no random number.
--- @param animal table A covered animal without a state
--- @return number kg
function RLGrowth.getNewAnimalWeight(animal)
    return RLGrowth.getCurve(animal):value(math.max(animal.age or 0, 0))
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
--- @param typeName string|nil A type with profiles of its own (sheep); cattle and proxy types read cattle breeds
--- @return number|nil
function RLGrowth.getBreedBirthMean(breed, sex, typeName)
    local name = RLWeightProfiles.resolveBreed(breed, typeName)
    local profile = name ~= nil and RLGrowth.getConfig().profiles[name] or nil
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
        local damMean = RLGrowth.getBreedBirthMean(damBreed, binding.sex, binding.typeName)
        local sireMean = RLGrowth.getBreedBirthMean(sireBreed, binding.sex, binding.typeName)
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
--- adult weight from its own genes.
--- @param child table
--- @param weight number kg
function RLGrowth.initBirth(child, weight)
    local subType = child:getSubType()
    local binding = RLGrowth.getBinding(subType)
    if binding == nil then return end
    local bc = RLBodyCondition.getConfig()
    local kappa = RLGrowth.getKappa()
    local frame, reserveKg = RLGrowthMath.split(weight, bc.initialReserve, kappa)
    child.weight = weight
    child.rlGrowth = nil
    local frameTarget = RLGrowth.getFrameTarget(child, binding)
    -- Development where its own curve has that frame: 0 when the initial reserve is the reference
    -- one (the default), a little on either side otherwise, so frame and development agree.
    local curve = RLGrowth.buildCurve(binding, frameTarget, weight)
    child.rlGrowth = RLGrowth.newState({
        birthWeightKg = weight,
        frameTargetKg = frameTarget,
        developmentMonths = RLGrowthMath.getDevelopment(curve, frame, kappa, bc.referenceReserve),
        reserveMassKg = reserveKg,
        speedFactor = RLGrowth.getStageSpeed(child),
        intakeFactor = RLBodyCondition.getIntakeCapacity(child),
        weightKg = weight,
        ageMonths = 0,
        source = "birth",
    })
    child.targetWeight = RLGrowth.getAnimalTargetWeight(child)
    child.rlGrowthCurve = nil
end


-- =============================================================================
-- Feed request, price, underweight
-- =============================================================================

--- Food request factor of a weight: (its share of its curve x what an animal on the old line ate
--- for its weight) ^ bodyWeightExponent, clamped as before. An animal on its curve asks for what
--- one on the old line did; heavier or lighter for its age, more or less by the same exponent.
--- @param animal table A covered animal
--- @param weight number kg
--- @return number
function RLGrowth.getBodyFeedFactor(animal, weight)
    if weight == nil then return 1 end
    local config = RLBreedTraits.getConfig()
    local age = math.max(animal.age or 0, 0)
    local ratio = RLGrowth.getShare(animal, weight) * getLegacyBodyRatio(animal:getSubType(), animal.gender,
        animal.genetics.metabolism, age)
    return math.clamp(ratio, config.minBodyRatio, config.maxBodyRatio) ^ config.bodyWeightExponent
end


--- Liters per period the animal requests on full feed at `weight` (RLBodyCondition.getRequestAt
--- with its intake gene and the body factor of that weight).
--- @param animal table
--- @param weight number
--- @param intakeGene number|nil Default the animal's
--- @param bodyFactor number|nil Default the animal's at `weight`
--- @return number
function RLGrowth.getRequestAt(animal, weight, intakeGene, bodyFactor)
    return RLBodyCondition.getRequestAt(animal, weight, intakeGene or RLGrowth.getIntakeGene(animal),
        bodyFactor or RLGrowth.getBodyFeedFactor(animal, weight))
end


--- What the animal requests on full feed at its frame with the reference reserve: a reserve above
--- or below it does not change what its kind and size ask for.
--- @param animal table
--- @return number liters per period
function RLGrowth.getReferenceIntake(animal)
    local frame = RLGrowth.getFrameAndReserve(animal)
    return RLGrowth.getRequestAt(animal, frame * (1 + RLBodyCondition.getConfig().referenceReserve * RLGrowth.getKappa()))
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
    local subType = animal:getSubType()
    local curve = RLGrowth.getNominalCurve(RLGrowth.getBinding(subType))
    local age = math.max(animal.age or 0, 0)
    local weight = curve:value(age)
    local kappa = RLGrowth.getKappa()
    local scale = 1 + bc.referenceReserve * kappa
    local gain = curve:slope(age)
    local growthNU = gain / scale * bc.growthNUPerKg + gain * (bc.referenceReserve * kappa / scale) * bc.depositNUPerKg
    local traits = RLBreedTraits.getConfig()
    local bodyFactor = math.clamp(getLegacyBodyRatio(subType, animal.gender, 1, age), traits.minBodyRatio,
        traits.maxBodyRatio) ^ traits.bodyWeightExponent
    return RLGrowth.getRequestAt(animal, weight, 1, bodyFactor), weight, growthNU
end


--- Weight the live price reads: the animal's share of its curve (getShare) put on the line the
--- prices were calibrated on (the price line where the breed has one, else the old full-feed
--- line), and the old-rule individual target the price formula measures it against.
--- @param animal table A covered animal
--- @param subType table
--- @return number weight
--- @return number legacyTarget
function RLGrowth.getPriceWeight(animal, subType)
    local age = math.max(animal.age or 0, 0)
    local metabolism = animal.genetics.metabolism
    local legacyTarget = RLGrowth.getLegacyTarget(subType, metabolism)
    local line = RLBreedTraits.getPriceLineWeight(subType, age) or RLGrowth.getLegacyLine(subType, animal.gender, metabolism, age)
    -- No line the price was calibrated on: the old price read the weight itself.
    if line == nil then return animal.weight, legacyTarget end
    return RLGrowth.getShare(animal) * line, legacyTarget
end


--- The old rules' underweight threshold: minWeight x (min(age, 1.5 x reproduction age) + 0.5) / 2.
--- @param subType table
--- @param age number
--- @return number kg
function RLGrowth.getLegacyUnderweight(subType, age)
    return (subType.minWeight or 0) * (math.min(age or 0, (subType.reproductionMinAgeMonth or 0) * 1.5) + 0.5) * 0.5
end


--- Below this weight an animal loses health: underweightRatio of its curve at its age. Growth
--- that fell behind does not catch up, so the ratio leaves room for a slow or once-underfed animal
--- and only a badly stunted one loses health. An old savegame's animal starts at the old rules'
--- threshold and moves to this one as its legacy anchor fades.
--- @param animal table A covered animal
--- @return number kg
function RLGrowth.getUnderweightThreshold(animal)
    local curve = RLGrowth.getCurve(animal)
    if curve == nil then return 0 end
    local age = math.max(animal.age or 0, 0)
    local threshold = RLGrowth.getSettings().underweightRatio * curve:value(age)
    local remaining = RLGrowth.getAnchorRemaining(animal, RLGrowth.peekState(animal))
    if remaining <= 0 then return threshold end
    return RLGrowth.blendLegacy(threshold, RLGrowth.getLegacyUnderweight(animal:getSubType(), age), remaining)
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
        -- Milk into the tank, or as milk cans from a pallet barn (Animal.isLactationPalletFillType):
        -- the one its pen takes (a pen with a milk store takes the tank milk), never both.
        local output = animal.output or {}
        local subType = animal:getSubType()
        local pallets = subType ~= nil and subType.output ~= nil and subType.output.pallets or nil
        local cans = 0
        if pallets ~= nil and Animal.isLactationPalletFillType ~= nil and Animal.isLactationPalletFillType(pallets.fillType) then
            cans = output.pallets or 0
        end
        local owner = animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil
        local perHour
        if owner ~= nil and owner.spec_husbandryMilk ~= nil then
            perHour = output.milk or 0
        elseif owner ~= nil and owner.spec_husbandryPallets ~= nil then
            perHour = cans
        else
            perHour = (output.milk or 0) > 0 and output.milk or cans
        end
        local perPeriod = math.max(perHour * 24, 0)
        return { potential = perPeriod, anchor = perPeriod, lineAnchor = perPeriod }
    end
    return { potential = 0, anchor = 0, lineAnchor = 0 }
end


--- An animal's milk now at full feed (game liters a month; its disease and lactation applied).
function RLGrowth.getMilkPotential(animal)
    return math.max(getMilk(animal).potential or 0, 0)
end


--- A disease's weight gain multiplier (1 without).
local function getDiseaseFactor(animal)
    if animal.getDiseaseMultipliers == nil then return 1 end
    local multipliers = animal:getDiseaseMultipliers("updateWeight")
    return multipliers ~= nil and multipliers.weightGain or 1
end


--- Most extra development speed (months per month) a taken-over animal catches up with.
RLGrowth.CATCH_UP_MAX = 1


--- Extra development speed of an old savegame's animal that grew on an old line below its new
--- curve: while its take-over fades, enough to close its lag behind its age by the time it is
--- gone (at most CATCH_UP_MAX), so it is not left behind its curve by the change of model. Its
--- budget pays for the growth like any other; underfed, it catches up less. 0 for any other
--- animal - growth that fell behind for want of feed never catches up.
--- @param animal table
--- @param state table
--- @return number months per month
function RLGrowth.getMigrationCatchUp(animal, state)
    if state.legacyAnchor == nil then return 0 end
    local remaining = RLGrowth.getAnchorRemaining(animal, state)
    if remaining <= 0 then return 0 end
    -- Lag behind its age on its curve: past the plateau month only what is left to the plateau.
    local curve = RLGrowth.getCurve(animal)
    local lag = math.min(RLGrowth.getContinuousAge(animal), curve.endMonth) - (state.developmentMonths or 0)
    if lag <= 0 then return 0 end
    return math.min(lag / (remaining * RLGrowth.getSettings().migrationBlendMonths), RLGrowth.CATCH_UP_MAX)
end


--- Share of her milk a cow may fund from her reserve: earlyMilkMobilizeShare at calving, falling
--- linearly to the body condition setting over earlyMilkMobilizeMonths; that setting afterwards.
--- @param animal table
--- @param state table|nil
--- @return number
function RLGrowth.getMilkMobilizeShare(animal, state)
    local base = RLBodyCondition.getConfig().milkMobilizeShare
    if not animal.isLactating then return base end
    local s = RLGrowth.getSettings()
    local early = math.max(1 - RLGrowth.getLactationMonths(animal, state) / s.earlyMilkMobilizeMonths, 0)
    return base + math.max(s.earlyMilkMobilizeShare - base, 0) * early
end


--- Build the step input (no state change).
--- @param animal table
--- @param state table
--- @param intakeLiters number Liters eaten per period (energy and digestion applied)
--- @param milkShare number Share of its full-feed milk the cow gives this hour (water; with no
---        ledger, the pen's food factor too, as the old milk rule deposits it)
--- @param dtMonths number
--- @param noReference boolean|nil Skip the request on full feed (ownReference 0): the
---        real-equivalent mode values the feed eaten, not liters against a request
--- @return table input
--- @return number ownReference Liters the animal itself requests on full feed
function RLGrowth.buildStepInput(animal, state, intakeLiters, milkShare, dtMonths, noReference)
    local bc = RLBodyCondition.getConfig()
    local s = RLGrowth.getSettings()
    local kappa = RLGrowth.getKappa()
    local _, speedGene, maintenanceGene = RLGrowth.getGeneFactors(animal.genetics.metabolism)
    local progress, fetuses = RLBodyCondition.getPregnancy(animal)
    local milk = getMilk(animal)
    -- The real-equivalent mode prices nothing by the request (noReference): it is not worked out.
    local ownReference = noReference and 0 or RLGrowth.getReferenceIntake(animal)
    local condition = animal.bodyCondition

    local input = {
        dtMonths = dtMonths,
        -- The budget works on the animal without the calf, membranes and fluids it carries.
        weight = animal.weight - RLGrowth.getCarriedGravid(animal, state),
        reserveKg = state.reserveMassKg,
        development = state.developmentMonths,
        curve = RLGrowth.getCurve(animal),
        kappa = kappa,
        frameFloorKg = s.frameFloorRatio * state.birthWeightKg / (1 + bc.referenceReserve * kappa),
        speed = speedGene * state.speedFactor + RLGrowth.getMigrationCatchUp(animal, state),
        diseaseFactor = getDiseaseFactor(animal),
        maintenanceFactor = maintenanceGene,
        potentialMilk = milk.potential * milkShare,
        isLactating = animal.isLactating and milk.potential > 0,
        pregnancyProgress = progress,
        numFetuses = fetuses,
        intakeLiters = intakeLiters,
        intakeCapacity = state.intakeFactor * RLGrowth.getLactationFactor(animal, state, true),
        reserveCeiling = RLBodyCondition.getReserveCeiling(animal),
        balanceEMA = condition ~= nil and condition.balanceEMA or 0,
        lossRateEMA = condition ~= nil and condition.lossRateEMA or 0,
        fixedPrice = bc.fixedFeedPrice == true,
        milkMobilizeShare = RLGrowth.getMilkMobilizeShare(animal, state),
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


--- The hour each pen last logged having no ledger (weak keys: a removed pen goes with it).
local lastNoLedger = setmetatable({}, { __mode = "k" })


--- The months-since-calving clock: it starts at a birth (the pregnancy that carried gravid mass
--- is over and the game has just reset monthsSinceLastBirth), else runs on from what the game
--- counts, and moves by the step's months.
function RLGrowth.advanceLactation(animal, state, dtMonths)
    local birth = (state.gravidKg or 0) > 0 and not animal.isPregnant and (animal.monthsSinceLastBirth or 1) == 0
    if birth then
        state.lactationMonths = 0
    elseif state.lactationMonths == nil then
        state.lactationMonths = RLGrowth.getLactationMonths(animal, nil)
    end
    state.lactationMonths = state.lactationMonths + dtMonths
end


--- What every step does before its budget: the stage factors move toward their targets, the age
--- clock and an old savegame's take-over fade move on by the step's months, the target weight
--- follows.
local function prepareStep(animal, state, dtMonths)
    state.speedFactor = relax(state.speedFactor, RLGrowth.getStageSpeed(animal), dtMonths)
    state.intakeFactor = relax(state.intakeFactor, RLBodyCondition.getIntakeCapacity(animal), dtMonths)
    RLGrowth.advanceClock(state, animal.age or 0, dtMonths)
    RLGrowth.advanceLactation(animal, state, dtMonths)
    if state.legacyAnchor ~= nil then state.anchorElapsedMonths = (state.anchorElapsedMonths or 0) + dtMonths end
    animal.targetWeight = RLGrowth.getAnimalTargetWeight(animal)
end


--- Put a step's result on the animal (false for a NaN result: nothing applied). The body
--- condition reads the reserve as its index r = R / K.
local function applyStepResult(animal, state, result, tick)
    if result.weight ~= result.weight or result.reserveKg ~= result.reserveKg or result.development ~= result.development then
        Log:warning("RLGrowth: step for %s/%s gave NaN, nothing applied", tostring(animal.farmId), tostring(animal.uniqueId))
        state.lastTick = tick
        return false
    end
    -- Back on the live weight: the gravid mass of her pregnancy now (0 once it has ended).
    local gravid = RLGrowth.getGravidTarget(animal)
    animal.weight = result.weight + gravid
    state.weightKg = animal.weight
    state.gravidKg = gravid
    state.reserveMassKg = result.reserveKg
    state.developmentMonths = result.development
    state.lastTick = tick
    local condition = RLBodyCondition.ensureState(animal, "growth")
    condition.reserve = math.clamp(result.reserve, 0, 1)
    condition.capacityKg = math.max(result.capacityKg, 1)
    condition.balanceEMA = result.balanceEMA
    condition.lossRateEMA = result.lossRateEMA
    return true
end


--- Run this hour's step for a covered animal. Called by the server from AnimalHealth.updateHealth
--- in place of every old weight rule. With its pen's feed ledger the animal eats its share of
--- what the pen ate and its milk is the budget's; without one (a pen with no trough, the first
--- hour after a load) it eats the pen's food factor of its request and the hour's milk is the
--- old rule's, which the budget then pays for. Either way the same budget, so there is no second
--- weight rule. An animal that took this hour's step already (moved in the same hour) is done.
--- An animal whose pen runs the real-equivalent nutrition mode is stepped by its pen instead
--- (RLGrowth.stepFeed, from RLFeed's model-time steps).
--- @param animal table
--- @param foodFactor number The pen's (or the rearing pen's own) food factor
--- @return boolean handled False: not covered or no game hour to count it in; the caller runs
---         the old rules
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
    local fromLedger = intakeSource == "ledger"
    if not fromLedger then
        local key = owner or lastNoLedger
        if lastNoLedger[key] ~= tick then
            lastNoLedger[key] = tick
            Log:debug("RLGrowth: no feed ledger this hour in %s (tick=%s), intake from the food factor %.2f",
                owner ~= nil and owner.getName ~= nil and owner:getName() or "?", tostring(tick), foodFactor or 0)
        end
    end

    local water = foodSpec ~= nil and foodSpec.rlWaterCoverage or nil
    local waterCoverage = (water ~= nil and water.tick == tick) and water.coverage or 1
    -- Without a ledger the milk store deposited this hour's milk by the old rule (scaled by the
    -- pen's food factor) before this step; the budget pays for that milk, not for more.
    local milkShare = fromLedger and waterCoverage or math.clamp(foodFactor or 0, 0, 1)

    prepareStep(animal, state, dtMonths)
    local input, ownReference = RLGrowth.buildStepInput(animal, state, intakeStep / dtMonths, milkShare, dtMonths)
    local result = RLGrowthMath.step(input, RLBodyCondition.getConfig())
    if not applyStepResult(animal, state, result, tick) then
        animal.rlMilkPaid = { tick = tick, litersPerHour = 0, deposited = false }
        return true
    end

    -- The body condition's lastTick marks an hour the budget's milk covers
    -- (RLBodyCondition.coversThisHour): only an hour with a ledger, so every store in an hour
    -- without one keeps the old milk rule, as the first one did.
    if fromLedger then animal.bodyCondition.lastTick = tick end
    RLBodyCondition.recordHour(animal, owner, tick, { allocated = allocated, intakeStep = intakeStep, dtMonths = dtMonths,
        ownReference = ownReference, result = result, waterCoverage = waterCoverage, paysMilk = fromLedger,
        intakeSource = intakeSource })
    return true
end


--- One model-time step of the real-equivalent nutrition mode (RLFeed): the animal's growth budget
--- on the ME it ate in it (feed), over dtMonths. Its pen runs these steps; the hour's milk and
--- records are put together by RLFeed.
--- @param animal table A covered animal
--- @param feed table What it ate in the step (RLFeed: me, kg, cp, proteinFactor, target, water)
--- @param dtMonths number
--- @param tick number The game hour
--- @return table|nil result The step's (nil: NaN, nothing applied)
--- @return table input The budget's input (its milk potential after protein and water)
--- @return number weightBefore
function RLGrowth.stepFeed(animal, feed, dtMonths, tick)
    local state = RLGrowth.ensureState(animal)
    RLGrowth.resync(animal, state)
    prepareStep(animal, state, dtMonths)
    local input = RLGrowth.buildStepInput(animal, state, 0, feed.water or 1, dtMonths, true)
    local cfg
    input, cfg = RLFeed.applyStepInput(animal, input, feed, dtMonths)
    local result = RLGrowthMath.step(input, cfg)
    local weightBefore = animal.weight
    if not applyStepResult(animal, state, result, tick) then return nil, input, weightBefore end
    animal.bodyCondition.lastTick = tick
    return result, input, weightBefore
end


--- Set the reserve index of a covered animal (console): the frame is kept, the reserve mass and
--- live weight move with it.
--- @param animal table
--- @param reserve number 0..1
function RLGrowth.setReserveIndex(animal, reserve)
    local state = RLGrowth.ensureState(animal)
    RLGrowth.resync(animal, state)
    local gravid = RLGrowth.getCarriedGravid(animal, state)
    local frame = math.max(animal.weight - gravid - state.reserveMassKg, 0)
    state.reserveMassKg = math.max(reserve, 0) * frame * RLGrowth.getKappa()
    animal.weight = frame + state.reserveMassKg + gravid
    state.weightKg = animal.weight
end


-- =============================================================================
-- Persistence and network
-- =============================================================================

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end


--- Read a saved state (nil when the animal has none or it is unusable; the animal then gets a
--- derived one, its weight kept - with no legacy anchor when it had a state, it grew under the
--- model).
--- @return table|nil state
--- @return boolean saved The animal was saved with a state (usable or not)
function RLGrowth.loadFromXMLFile(xmlFile, key)
    local base = key .. ".growth"
    local birth = xmlFile:getFloat(base .. "#birthWeightKg")
    if birth == nil then return nil, false end

    local version = xmlFile:getInt(base .. "#version", 1)
    if version > RLGrowth.STATE_VERSION then
        Log:warning("RLGrowth: %s has state version %d, newer than this mod's %d; dropped", base, version, RLGrowth.STATE_VERSION)
        return nil, true
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
        legacyAnchor = xmlFile:getFloat(base .. "#legacyAnchor"),
        anchorElapsedMonths = xmlFile:getFloat(base .. "#anchorElapsedMonths"),
        feedAdapted = xmlFile:getFloat(base .. "#feedAdapted"),
        feedShortDays = xmlFile:getFloat(base .. "#feedShortDays"),
        gravidKg = xmlFile:getFloat(base .. "#gravidKg"),
        lactationMonths = xmlFile:getFloat(base .. "#lactationMonths"),
        source = xmlFile:getString(base .. "#source", "derived"),
        lastTick = xmlFile:getInt(base .. "#lastTick", -1),
    })
    state.version = version

    if not RLGrowth.isUsable(state) then
        Log:warning("RLGrowth: %s has an unusable state; it is derived again from the weight", base)
        return nil, true
    end
    if state.legacyAnchor ~= nil then state.legacyAnchor = math.clamp(state.legacyAnchor, RLGrowth.ANCHOR_MIN, RLGrowth.ANCHOR_MAX) end
    return state, true
end


--- Bounds a received state's values are kept within, against the animal's own breed: its adult
--- and birth weight within these factors of the breed's (size and birth genes, a cross, a litter
--- and a thin dam all fall inside), its development within its curve, its stage factors within
--- what the settings can give.
RLGrowth.TRUSTED_ADULT = { 0.5, 2 }
RLGrowth.TRUSTED_BIRTH = { 0.2, 3 }
RLGrowth.TRUSTED_STAGE = { 0.05, 3 }


--- The server's own animal is the authority on its weight and its states: a copy built from a
--- client's payload (AnimalMoveEvent puts the payload into the target pen) takes them, legacy
--- anchor, clocks and the hour of its last step included, so a move neither drops a take-over
--- nor lets the animal step twice in one hour.
--- @param copy table The payload animal
--- @param live table The server's animal
function RLGrowth.takeLiveState(copy, live)
    if copy == nil or live == nil or copy == live then return end
    copy.weight = live.weight
    copy.targetWeight = live.targetWeight
    copy.bodyCondition = RLBodyCondition.copyState(live.bodyCondition)
    copy.rlGrowth = RLGrowth.copyState(live.rlGrowth)
    copy.rlGrowthDropped = live.rlGrowthDropped
    copy.rlGrowthCurve, copy.rlGrowthPeek = nil, nil
end


--- Keep a state that came from elsewhere (a stream; a client's with an animal it buys) within its
--- animal's breed: an adult or birth weight far off the breed's, a development past the curve,
--- a stage factor out of reach are pulled back, and a client's legacy anchor is dropped.
--- @param animal table
--- @param state table|nil
--- @param fromClient boolean|nil The state came from a client (read on the server)
--- @return table|nil state
function RLGrowth.sanitizeState(animal, state, fromClient)
    if state == nil then return state end
    -- A client never sends an old savegame's take-over (the dealer's animals have none; a moved
    -- animal takes the server's own state, takeLiveState): an anchor from one is not taken.
    -- Otherwise its clock stays within the blend.
    if fromClient then state.legacyAnchor, state.anchorElapsedMonths = nil, nil end
    if state.legacyAnchor ~= nil then
        state.anchorElapsedMonths = math.clamp(state.anchorElapsedMonths or 0, 0, RLGrowth.getSettings().migrationBlendMonths)
    end
    if animal == nil or animal.getSubType == nil then return state end
    local binding = RLGrowth.getBinding(animal:getSubType())
    if binding == nil then return state end
    local adult, birth = RLGrowth.getAdultReference(binding), RLGrowth.getBirthMean(binding)
    state.frameTargetKg = math.clamp(state.frameTargetKg, adult * RLGrowth.TRUSTED_ADULT[1], adult * RLGrowth.TRUSTED_ADULT[2])
    state.birthWeightKg = math.clamp(state.birthWeightKg, birth * RLGrowth.TRUSTED_BIRTH[1], birth * RLGrowth.TRUSTED_BIRTH[2])
    state.developmentMonths = math.min(state.developmentMonths, RLGrowth.getNominalCurve(binding).endMonth)
    state.speedFactor = math.clamp(state.speedFactor, RLGrowth.TRUSTED_STAGE[1], RLGrowth.TRUSTED_STAGE[2])
    state.intakeFactor = math.clamp(state.intakeFactor, RLGrowth.TRUSTED_STAGE[1], RLGrowth.TRUSTED_STAGE[2])
    if state.feedAdapted ~= nil then state.feedAdapted = math.clamp(state.feedAdapted, 0, 1) end
    return state
end


--- Whether a read state can be used: finite numbers, weights above 0, development, reserve and the
--- optional clocks not below 0, the stage factors above 0.
--- @param state table
--- @return boolean
function RLGrowth.isUsable(state)
    local function optional(value) return value == nil or (finite(value) and value >= 0) end
    return finite(state.birthWeightKg) and state.birthWeightKg > 0 and finite(state.frameTargetKg) and state.frameTargetKg > 0
        and finite(state.developmentMonths) and state.developmentMonths >= 0 and finite(state.reserveMassKg)
        and state.reserveMassKg >= 0 and finite(state.speedFactor) and state.speedFactor > 0 and finite(state.intakeFactor)
        and state.intakeFactor > 0 and optional(state.weightKg) and optional(state.ageMonths) and optional(state.anchorElapsedMonths)
        and (state.legacyAnchor == nil or (finite(state.legacyAnchor) and state.legacyAnchor > 0))
        and (state.feedAdapted == nil or (finite(state.feedAdapted) and state.feedAdapted >= 0 and state.feedAdapted <= 1))
        and optional(state.feedShortDays) and optional(state.gravidKg) and optional(state.lactationMonths)
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
    if state.legacyAnchor ~= nil then
        xmlFile:setFloat(base .. "#legacyAnchor", state.legacyAnchor)
        xmlFile:setFloat(base .. "#anchorElapsedMonths", state.anchorElapsedMonths or 0)
    end
    if state.feedAdapted ~= nil then xmlFile:setFloat(base .. "#feedAdapted", state.feedAdapted) end
    if state.feedShortDays ~= nil then xmlFile:setFloat(base .. "#feedShortDays", state.feedShortDays) end
    if state.gravidKg ~= nil then xmlFile:setFloat(base .. "#gravidKg", state.gravidKg) end
    if state.lactationMonths ~= nil then xmlFile:setFloat(base .. "#lactationMonths", state.lactationMonths) end
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
    streamWriteFloat32(streamId, state.ageMonths or -1)
    streamWriteFloat32(streamId, state.legacyAnchor or -1)
    streamWriteFloat32(streamId, state.anchorElapsedMonths or -1)
    streamWriteFloat32(streamId, state.feedAdapted or -1)
    streamWriteFloat32(streamId, state.feedShortDays or -1)
    streamWriteFloat32(streamId, state.gravidKg or -1)
    streamWriteFloat32(streamId, state.lactationMonths or -1)
end


--- Read a streamed state. Every value is checked as a saved one is (a state a client sends with
--- an animal it buys is not taken on trust): an unusable one is dropped and the animal gets a
--- state derived from its weight, a legacy anchor is kept within its bounds.
function RLGrowth.readStream(streamId)
    if not streamReadBool(streamId) then return nil end
    local function optional(value) return (finite(value) and value >= 0) and value or nil end
    local state = RLGrowth.newState({
        birthWeightKg = streamReadFloat32(streamId),
        frameTargetKg = streamReadFloat32(streamId),
        developmentMonths = streamReadFloat32(streamId),
        reserveMassKg = streamReadFloat32(streamId),
        speedFactor = streamReadFloat32(streamId),
        intakeFactor = streamReadFloat32(streamId),
        weightKg = optional(streamReadFloat32(streamId)),
        ageMonths = optional(streamReadFloat32(streamId)),
        legacyAnchor = optional(streamReadFloat32(streamId)),
        anchorElapsedMonths = optional(streamReadFloat32(streamId)),
        feedAdapted = optional(streamReadFloat32(streamId)),
        feedShortDays = optional(streamReadFloat32(streamId)),
        gravidKg = optional(streamReadFloat32(streamId)),
        lactationMonths = optional(streamReadFloat32(streamId)),
        source = "stream",
    })
    if not RLGrowth.isUsable(state) then return nil end
    if state.legacyAnchor ~= nil then state.legacyAnchor = math.clamp(state.legacyAnchor, RLGrowth.ANCHOR_MIN, RLGrowth.ANCHOR_MAX) end
    return state
end


-- =============================================================================
-- Report
-- =============================================================================

--- How many animals of each subtype the husbandries hold, as individuals and in vanilla clusters
--- (one pass over every pen).
--- @return table subTypeIndex -> { individuals, clusters }
function RLGrowth.countHeldAnimals()
    local counts = {}
    local mission = g_currentMission
    local placeables = mission ~= nil and mission.husbandrySystem ~= nil and mission.husbandrySystem.placeables or nil
    for _, placeable in pairs(placeables or {}) do
        local clusters = placeable.getClusters ~= nil and placeable:getClusters() or {}
        for _, cluster in ipairs(clusters) do
            local index = cluster.subTypeIndex or (cluster.getSubTypeIndex ~= nil and cluster:getSubTypeIndex()) or nil
            if index ~= nil then
                local count = counts[index] or { individuals = 0, clusters = 0 }
                counts[index] = count
                if cluster.isIndividual == true then
                    count.individuals = count.individuals + 1
                else
                    count.clusters = count.clusters + (cluster.numAnimals or 1)
                end
            end
        end
    end
    return counts
end


--- What the game offers the model for a subtype's animals: whether they are individual animals
--- here, whether the subtype file gives weights, whether they reproduce, and how many are loaded
--- as individuals and as vanilla clusters.
--- @param subType table
--- @param counts table|nil countHeldAnimals(), counted once for a whole report
--- @return table
function RLGrowth.describeCapability(subType, counts)
    counts = counts or RLGrowth.countHeldAnimals()
    local held = counts[subType.subTypeIndex] or { individuals = 0, clusters = 0 }
    local capability = {
        weightFields = subType.rlWeightFieldsGiven,
        reproduction = subType.supportsReproduction == true,
        individuals = held.individuals,
        clusters = held.clusters,
    }
    capability.adapter = capability.clusters > 0 and capability.individuals == 0 and "INACTIVE_VANILLA_CLUSTERS"
        or "INDIVIDUALS_ONLY"
    return capability
end


--- The curve a subtype's animals grow on (average genes): whether the model runs it, adult and
--- birth weight, the plateau month and the knots.
--- @param subType table
--- @param preview table|nil A binding to show instead of the subtype's own (a type switched off), never active
--- @return table|nil
function RLGrowth.describeCurve(subType, preview)
    local binding = preview or RLGrowth.getBinding(subType)
    if binding == nil then return nil end
    local knots = RLGrowth.getReferenceKnots(binding)
    local list = {}
    for _, knot in ipairs(knots) do list[#list + 1] = { knot[1], RLWeightProfiles.round(knot[2], 2) } end
    return {
        active = preview == nil and RLGrowth.isEnabled(),
        sex = binding.sex,
        adultKg = RLWeightProfiles.round(RLGrowth.getAdultReference(binding), 2),
        birthKg = RLWeightProfiles.round(RLGrowth.getBirthMean(binding), 3),
        plateauMonth = knots[#knots][1],
        configTargetWeight = subType.targetWeight,
        knots = list,
    }
end
