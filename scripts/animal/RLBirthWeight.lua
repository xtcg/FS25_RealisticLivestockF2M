--[[
    RLBirthWeight.lua
    Birth weight of newborns, from the birth traits in xml/breedTraits.xml.

    A breed's mean birth weight is birthWeightRatio x the target weight of the breed's female
    (a Holstein calf is 6.2% of a 680 kg cow), or birthFemaleKg where the file sets the mean
    directly (pigs: a piglet's weight does not follow the sow's size), x maleBirthFactor for a
    male. So birth weight follows the file, and each configured subtype's minWeight - where its growth,
    expected weight for age and newly generated animals start - is set to that mean at load.

    One birth's mean is then adjusted for:
      - litter size: litter2 / litter3 / litter4 (4 and more) per young, or for pigs
        1 - litterStep x (litter - litterBase), clamped to litterMin..litterMax
      - the dam's first birth: firstBirthFactor
      - the dam's condition: (weight / expected weight for her age) ^ 0.5, clamped 0.85..1.05
      - a cross: the mean of the dam's and the sire's breed for the young's sex
      - the young's metabolism gene: 1 + 0.05 x (metabolism - 1)

    The weight is drawn from a normal distribution around that mean with the type's
    birthWeightCV, truncated at 2.5 standard deviations.

    Subtypes with no birthWeightRatio (the map's ducks, geese, alpacas, pets) keep their
    minWeight as the mean and get the same spread.
]]

RLBirthWeight = {}

local Log = RmLogging.getLogger("RLRM")

--- Defaults for attributes no layer of breedTraits.xml sets.
RLBirthWeight.DEFAULTS = {
    maleBirthFactor = 1,
    birthWeightCV = 0.10,
    firstBirthFactor = 1,
    litter2 = 1,
    litter3 = 1,
    litter4 = 1,
    litterStep = 0,
    litterMin = 0,
    litterMax = 10,
    birthSurvivalBase = 0.97,
    birthHealthEffect = 0.20,
    birthLowWeightSD = 1.5,
    birthLowWeightPenalty = 0.10,
    birthHighWeightSD = 2.0,
    birthHighWeightPenalty = 0,
}

--- Draws further out than this many standard deviations are redrawn.
RLBirthWeight.TRUNCATE_SD = 2.5

--- The dam's condition: (weight / expected) ^ exponent, clamped.
RLBirthWeight.DAM_CONDITION_EXPONENT = 0.5
RLBirthWeight.DAM_CONDITION_MIN = 0.85
RLBirthWeight.DAM_CONDITION_MAX = 1.05

--- Share of the metabolism gene's distance from 1 that moves the mean.
RLBirthWeight.METABOLISM_EFFECT = 0.05


local function getLayers()
    return RLBreedTraits.getConfig().layers
end


--- A birth attribute for a subtype, from breedTraits.xml or DEFAULTS.
--- @param subType table|nil
--- @param attr string
--- @return number|nil
function RLBirthWeight.get(subType, attr)
    return RLBreedTraits.resolve(getLayers(), subType, attr, RLBirthWeight.DEFAULTS[attr])
end


--- The subtype of `breed` and `gender` in an animal type, or nil.
function RLBirthWeight.findSubType(typeIndex, breed, gender)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if animalSystem == nil or breed == nil then return nil end
    local animalType = animalSystem:getTypeByIndex(typeIndex)
    if animalType == nil or animalType.subTypes == nil then return nil end

    for _, subTypeIndex in pairs(animalType.subTypes) do
        local subType = animalSystem:getSubTypeByIndex(subTypeIndex)
        if subType ~= nil and subType.breed == breed and subType.gender == gender then return subType end
    end
    return nil
end


--- Target weight of the breed's female, or the subtype's own when the breed has none.
function RLBirthWeight.getFemaleTarget(subType)
    if subType.gender ~= "male" then return subType.targetWeight end
    local female = RLBirthWeight.findSubType(subType.typeIndex, subType.breed, "female")
    return (female ~= nil and female.targetWeight) or subType.targetWeight
end


--- Mean birth weight of a single young of this subtype from an average dam. Uses the
--- configured birthFemaleKg, else the configured ratio; the `configMinWeight` recorded at load
--- otherwise, and the live minWeight as the last resort.
--- @param subType table
--- @return number kg
--- @return boolean configured Whether birthFemaleKg or birthWeightRatio set it
function RLBirthWeight.getBreedMean(subType)
    local direct = RLBreedTraits.resolve(getLayers(), subType, "birthFemaleKg", nil)
    if direct ~= nil and direct > 0 then
        if subType.gender == "male" then direct = direct * RLBirthWeight.get(subType, "maleBirthFactor") end
        return direct, true
    end
    local ratio = RLBreedTraits.resolve(getLayers(), subType, "birthWeightRatio", nil)
    local femaleTarget = RLBirthWeight.getFemaleTarget(subType)
    if ratio ~= nil and ratio > 0 and femaleTarget ~= nil and femaleTarget > 0 then
        local mean = ratio * femaleTarget
        if subType.gender == "male" then mean = mean * RLBirthWeight.get(subType, "maleBirthFactor") end
        return mean, true
    end
    return subType.configMinWeight or subType.minWeight or 0, false
end


--- Mean weight factor per young for a litter of `size`.
function RLBirthWeight.getLitterFactor(subType, size)
    size = size or 1
    local base = RLBirthWeight.get(subType, "litterBase")
    if base ~= nil then
        local factor = 1 - RLBirthWeight.get(subType, "litterStep") * (size - base)
        return math.clamp(factor, RLBirthWeight.get(subType, "litterMin"), RLBirthWeight.get(subType, "litterMax"))
    end
    if size <= 1 then return 1 end
    if size == 2 then return RLBirthWeight.get(subType, "litter2") end
    if size == 3 then return RLBirthWeight.get(subType, "litter3") end
    return RLBirthWeight.get(subType, "litter4")
end


--- The dam's condition factor: a thin dam has lighter young.
--- @param dam table Animal with weight, targetWeight, age and getSubType
function RLBirthWeight.getDamConditionFactor(dam)
    if dam == nil or dam.weight == nil or dam.targetWeight == nil or dam.getSubType == nil then return 1 end
    local subType = dam:getSubType()
    if subType == nil then return 1 end
    local expected = RLBreedTraits.getExpectedWeight(subType, dam.targetWeight, dam.age)
    if expected == nil or expected <= 0 then return 1 end
    return math.clamp((dam.weight / expected) ^ RLBirthWeight.DAM_CONDITION_EXPONENT,
        RLBirthWeight.DAM_CONDITION_MIN, RLBirthWeight.DAM_CONDITION_MAX)
end


--- Mean birth weight for one young of a birth.
--- @param childSubType table
--- @param ctx table { dam = Animal|nil, damBreed = string|nil, sireBreed = string|nil,
---                    litterSize = number, firstBirth = boolean, metabolism = number|nil }
--- @return number kg
function RLBirthWeight.getMean(childSubType, ctx)
    ctx = ctx or {}
    local mean = RLBirthWeight.getBreedMean(childSubType)

    -- A cross: mean of the dam's and the sire's breed for the young's sex.
    local damBreed, sireBreed = ctx.damBreed, ctx.sireBreed
    if damBreed ~= nil and sireBreed ~= nil and damBreed ~= sireBreed then
        local damSide = RLBirthWeight.findSubType(childSubType.typeIndex, damBreed, childSubType.gender)
        local sireSide = RLBirthWeight.findSubType(childSubType.typeIndex, sireBreed, childSubType.gender)
        if damSide ~= nil and sireSide ~= nil then
            mean = (RLBirthWeight.getBreedMean(damSide) + RLBirthWeight.getBreedMean(sireSide)) / 2
        end
    end

    mean = mean * RLBirthWeight.getLitterFactor(childSubType, ctx.litterSize)
    if ctx.firstBirth then mean = mean * RLBirthWeight.get(childSubType, "firstBirthFactor") end
    mean = mean * RLBirthWeight.getDamConditionFactor(ctx.dam)
    if ctx.metabolism ~= nil then
        mean = mean * (1 + RLBirthWeight.METABOLISM_EFFECT * (ctx.metabolism - 1))
    end

    return math.max(mean, 0)
end


--- A standard normal draw (Box-Muller), redrawn beyond TRUNCATE_SD.
--- @param random function|nil Uniform (0,1) source, math.random by default
--- @return number z
function RLBirthWeight.drawZ(random)
    random = random or math.random
    local limit = RLBirthWeight.TRUNCATE_SD
    local z = 0
    for _ = 1, 20 do
        local u1 = math.max(random(), 1e-12)
        z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * random())
        if math.abs(z) <= limit then return z end
    end
    return math.clamp(z, -limit, limit)
end


--- Draw one young's birth weight.
--- @return number weight kg
--- @return number z Standard deviations from the mean
--- @return number mean kg
function RLBirthWeight.draw(childSubType, ctx, random)
    local mean = RLBirthWeight.getMean(childSubType, ctx)
    local cv = RLBirthWeight.get(childSubType, "birthWeightCV")
    local z = RLBirthWeight.drawZ(random)
    return math.max(mean * (1 + cv * z), mean * 0.05), z, mean
end


--- Chance a young survives its birth. The species/breed/subtype supplies a baseline plus
--- asymmetric low- and high-weight risk. Health genetics are deliberately a modest modifier,
--- not the baseline itself: healthEffect 0.20 makes a gene of 0.5/1.5 change survival by -/+10%.
--- High-weight penalty is zero for species such as pigs where larger newborns are not treated
--- as dystocia risk by this simplified model.
--- @param subType table|nil Child subtype used for layered breedTraits lookup
--- @param health number|nil Health gene, 1 = average
--- @param z number Standard deviations of birth weight from this birth's mean
--- @return number 0..1
function RLBirthWeight.getSurvivalChance(subType, health, z)
    health = health or 1
    z = z or 0

    local base = RLBirthWeight.get(subType, "birthSurvivalBase")
    local healthEffect = RLBirthWeight.get(subType, "birthHealthEffect")
    local lowSD = RLBirthWeight.get(subType, "birthLowWeightSD")
    local lowPenalty = RLBirthWeight.get(subType, "birthLowWeightPenalty")
    local highSD = RLBirthWeight.get(subType, "birthHighWeightSD")
    local highPenalty = RLBirthWeight.get(subType, "birthHighWeightPenalty")

    local weightFactor = 1
    if lowSD ~= nil and lowPenalty ~= nil and z < -lowSD then
        weightFactor = weightFactor * math.max(0, 1 - lowPenalty * ((-z) - lowSD))
    end
    if highSD ~= nil and highPenalty ~= nil and highPenalty > 0 and z > highSD then
        weightFactor = weightFactor * math.max(0, 1 - highPenalty * (z - highSD))
    end

    local healthFactor = math.max(0, 1 + healthEffect * (health - 1))
    return math.clamp(base * healthFactor * weightFactor, 0, 1)
end


--- Set each configured subtype's minWeight to its breed mean birth weight, so growth and the
--- expected weight for age start where newborns do. Runs after all subtypes are loaded; the
--- file's own value is kept as configMinWeight.
--- @param animalSystem table
--- @return number changed
function RLBirthWeight.syncMinWeights(animalSystem)
    local changed = 0
    for _, subType in ipairs(animalSystem.subTypes or {}) do
        if subType.configMinWeight == nil then subType.configMinWeight = subType.minWeight end
        local mean, configured = RLBirthWeight.getBreedMean(subType)
        if configured and mean > 0 then
            if subType.minWeight ~= mean then
                Log:debug("RLBirthWeight.syncMinWeights: %s minWeight %s -> %.3f", tostring(subType.name),
                    tostring(subType.minWeight), mean)
                changed = changed + 1
            end
            subType.minWeight = mean
        end
    end
    Log:info("RLBirthWeight.syncMinWeights: %d subtype(s) set to their breed birth weight", changed)
    return changed
end


Log:debug("RLBirthWeight: loaded")
