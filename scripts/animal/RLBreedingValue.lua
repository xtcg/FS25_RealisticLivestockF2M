--[[
    Live value of cattle against standard genes (PRICE-BREED-03).

    Animal:getSellPrice asks this module for every animal of the COW type while xml/breedingValue.xml
    is enabled. It changes the live price only: the dealer's offers and asks (x the dealer-quality
    markup on top, unchanged), the herdsman's trades and the payouts taken as a share of the live
    value. Carcass yield, the farm butcher, slaughterhouses, contracts and meat prices never read it.

        curve     = Animal:getCurvePrice without the fixed +15% castrated / lactating, +25% pregnant;
                    a cow's at meat gene 1 (her meat gene is priced once, through her meat value)
        meat      = RLMeatValue.getSlaughterValue (disease applied), the live floor as before
        body      = a cow's meat - the same at meat gene 1 (M_actual - M0)
        meatRoute = max(meat, curve) for a bull or steer; meat for a cow; a heifer too young for
                    the butcher also min(her curve, her breed's bull curve for her): fattening
        standard  = curve + alphaNormal x (PV0(state) - PV0(open, dry))      genes all 1
        own       = PV(own genes) - PV0(state)
        hered     = PV(own genes + offspring) - PV(own genes)
        cow       = standard + body - alphaNormal x (own- + hered-) + alphaOwn x rhoOwn x own+
                             + alphaHered x rhoHered x E(q) x hered+
        bull      = curve + alphaHered x rhoHered x E(q) x (own + hered)+, his offspring gain x
                    sireCapture x his qualification (sireQualificationAtBirth rising to 1 at
                    breeding age)
        price     = clamp(that, meatRoute, max(meatRoute, standard + body + (own + hered)+))

    Castrated and infertile (fertility 0) animals, and bulls out of breeding age, get the meat
    route only. PV is a reference cash flow in game money over the animal's remaining breeding
    life, at one fixed end for every gene world: milk at the best station's annual mean price,
    calves at the breed's newborn curve price, offspring meat gene at the annual mean meat price.
    Exits follow the health gene, open months the fertility gene (the game's conception odds),
    milk the productivity gene. A calf already on the way is the same in every world. Offspring
    genes are the mean of the clamped inheritance with a standard mate (BreedingMath.SD_CONST).
    Metabolism and meat quality act through the curve and meat prices (the body), not here.
]]

RLBreedingValue = {}

local Log = RmLogging.getLogger("RLRM")

RLBreedingValue.CONFIG_FILE = "breedingValue.xml"
RLBreedingValue.ATTRIBUTES = {
    "enabled", "alphaNormal", "alphaOwn", "alphaHered", "rhoOwn", "rhoHered",
    "excellenceThreshold", "excellenceTop", "excellenceK",
    "discountRate", "annualExitRisk", "healthExitSlope",
    "referenceOpenMonths", "minOpenMonths", "maxOpenMonths", "postpartumWaitMonth",
    "femaleBirthSlots", "breedingExitAgeMonth", "dairyShare",
    "milkNetShare", "milkIncrementShare", "offspringCapture", "sonSlaughterAgeMonth",
    "sireFemalesPerSeason", "sireSeasons", "sireConception", "sireExitAgeMonth",
    "sireCaptureDairy", "sireCaptureBeef", "sireQualificationAtBirth", "sonSaleAgeMonth",
    "cowMateGene", "cowCurveScale", "cowCurveScaleFromMonth", "cowCurveScaleFullMonth", "beefCalfSaleAgeMonth", "beefCalfNetShare", "maternalMilkEffect", "fertilityExitShare", "fertilityExitSlope",
    "exitReplacementDairy", "exitReplacementBeef",
    "wDairyProductivity", "wDairyFertility", "wDairyHealth",
    "wTerminalQuality", "wTerminalFertility", "wTerminalHealth",
    "wMaternalQuality", "wMaternalFertility", "wMaternalHealth",
}

--- Used where the file sets nothing (and with no file at all).
RLBreedingValue.DEFAULTS = {
    enabled = 1, alphaNormal = 0.60, alphaOwn = 0.35, alphaHered = 0.65, rhoOwn = 0.85, rhoHered = 0.85,
    excellenceThreshold = 1.10, excellenceTop = 1.75, excellenceK = 5,
    discountRate = 0.10, annualExitRisk = 0.14, healthExitSlope = 0.35,
    referenceOpenMonths = 1.5, minOpenMonths = 0.5, maxOpenMonths = 8, postpartumWaitMonth = 3,
    femaleBirthSlots = 4, breedingExitAgeMonth = 96, dairyShare = 0.5,
    milkNetShare = 0.25, milkIncrementShare = 0.40, offspringCapture = 0.60, sonSlaughterAgeMonth = 20,
    sireFemalesPerSeason = 24, sireSeasons = 3, sireConception = 0.90, sireExitAgeMonth = 132,
    sireCaptureDairy = 0.15, sireCaptureBeef = 0.85, sireQualificationAtBirth = 0.50, sonSaleAgeMonth = 12,
    cowMateGene = 1.35, cowCurveScale = 1, cowCurveScaleFromMonth = 24, cowCurveScaleFullMonth = 36,
    beefCalfSaleAgeMonth = 8, beefCalfNetShare = 0.55, maternalMilkEffect = 0.10,
    fertilityExitShare = 0.35, fertilityExitSlope = 0.60, exitReplacementDairy = 0.50, exitReplacementBeef = 0.75,
    wDairyProductivity = 0.40, wDairyFertility = 0.30, wDairyHealth = 0.30,
    wTerminalQuality = 0.70, wTerminalFertility = 0.20, wTerminalHealth = 0.10,
    wMaternalQuality = 0.45, wMaternalFertility = 0.35, wMaternalHealth = 0.20,
}

--- How long a quote is reused, in ms of g_time: getSellPrice runs for every row of the animal screens.
RLBreedingValue.QUOTE_CACHE_MS = 2000

local quoteCache = setmetatable({}, { __mode = "k" })
local counterpartCache = {}

local GENE_MIN, GENE_MAX = 0.25, 1.75
local STANDARD = { productivity = 1, fertility = 1, health = 1, quality = 1 }


-- =============================================================================
-- Config
-- =============================================================================

--- @param xmlFile table|nil
--- @return table config {layers}
function RLBreedingValue.parseConfig(xmlFile)
    return { layers = RLBreedTraits.parseLayers(xmlFile, "breedingValue", RLBreedingValue.ATTRIBUTES) }
end


function RLBreedingValue.getConfig()
    if RLBreedingValue.config == nil then
        RLBreedingValue.config = RLBreedTraits.loadConfig(RLBreedingValue.CONFIG_FILE, "breedingValue", RLBreedingValue.parseConfig)
    end
    return RLBreedingValue.config
end


--- All parameters for a subtype, each from its most specific layer.
--- @param subType table|nil
--- @return table
function RLBreedingValue.getParams(subType)
    local layers = RLBreedingValue.getConfig().layers
    local params = {}
    for _, attr in ipairs(RLBreedingValue.ATTRIBUTES) do
        params[attr] = RLBreedTraits.resolve(layers, subType, attr, RLBreedingValue.DEFAULTS[attr])
    end
    return params
end


--- Clear the config, quote and lookup caches (tests, and after a config or price change).
function RLBreedingValue.reset()
    RLBreedingValue.config = nil
    quoteCache = setmetatable({}, { __mode = "k" })
    counterpartCache = {}
end


-- =============================================================================
-- Pure arithmetic
-- =============================================================================

--- Excellence curve: 0 up to the threshold, convex to 1 at the top.
--- E = (exp(k x) - 1 - k x) / (exp(k) - 1 - k), x = clamp((q - threshold) / (top - threshold), 0, 1)
--- @param q number Genetic score
--- @param params table
--- @return number
function RLBreedingValue.excellence(q, params)
    local span = params.excellenceTop - params.excellenceThreshold
    if q == nil or q ~= q or span <= 0 then return 0 end
    local x = math.min(1, math.max(0, (q - params.excellenceThreshold) / span))
    local k = params.excellenceK
    if k <= 0 then return x end
    return (math.exp(k * x) - 1 - k * x) / (math.exp(k) - 1 - k)
end


local function cdf(z) return 0.5 * (1 + BreedingMath.erf(z / math.sqrt(2))) end
local function pdf(z) return math.exp(-0.5 * z * z) / math.sqrt(2 * math.pi) end


--- Mean offspring gene: the mid-parent value with normal spread sd, clamped to 0.25-1.75 as
--- BreedingMath.breedOffspring draws it.
--- @param parent number
--- @param mate number|nil Defaults to the standard 1
--- @param sd number|nil Defaults to BreedingMath.SD_CONST
--- @return number
function RLBreedingValue.inheritedMean(parent, mate, sd)
    local mu = 0.5 * ((parent or 1) + (mate or 1))
    sd = sd or BreedingMath.SD_CONST
    local a, b = (GENE_MIN - mu) / sd, (GENE_MAX - mu) / sd
    return GENE_MIN * cdf(a) + mu * (cdf(b) - cdf(a)) + sd * (pdf(a) - pdf(b)) + GENE_MAX * (1 - cdf(b))
end


--- The weighted genetic score the excellence curve reads: dairy weights mixed by dairyShare with
--- the beef ones (terminal for a bull, maternal for a cow).
--- @param genes table {productivity, fertility, health, quality}
--- @param params table
--- @param gender string
--- @return number
function RLBreedingValue.getScore(genes, params, gender)
    local p, f, h, q = genes.productivity or 1, genes.fertility or 1, genes.health or 1, genes.quality or 1
    local dairy = params.wDairyProductivity * p + params.wDairyFertility * f + params.wDairyHealth * h
    local dairyWeight = params.wDairyProductivity + params.wDairyFertility + params.wDairyHealth
    local beef, beefWeight
    if gender == "male" then
        beef = params.wTerminalQuality * q + params.wTerminalFertility * f + params.wTerminalHealth * h
        beefWeight = params.wTerminalQuality + params.wTerminalFertility + params.wTerminalHealth
    else
        beef = params.wMaternalQuality * q + params.wMaternalFertility * f + params.wMaternalHealth * h
        beefWeight = params.wMaternalQuality + params.wMaternalFertility + params.wMaternalHealth
    end
    local s = math.clamp(params.dairyShare, 0, 1)
    return s * dairy / math.max(dairyWeight, 1e-9) + (1 - s) * beef / math.max(beefWeight, 1e-9)
end


--- Months open after the wait: referenceOpenMonths scaled by the game's conception odds
--- ((1 - f/2) / (f/2), the natural roll) against fertility 1's, within min..maxOpenMonths.
--- @param fertility number
--- @param params table
--- @return number
function RLBreedingValue.getOpenMonths(fertility, params)
    local p = math.clamp((fertility or 1) / 2, 1e-3, 1)
    local odds = (1 - p) / p
    return math.clamp(params.referenceOpenMonths * odds, params.minOpenMonths, params.maxOpenMonths)
end


--- Survival x discount weight at t months. Exits are fertilityExitShare failures to get in calf
--- (or pass as a sire), moved by the fertility gene, and the rest health, moved by the health gene.
local function getHazard(ctx, genes)
    local params = ctx.params
    local zh = ((genes.health or 1) - 1) / 0.75
    local zf = ((genes.fertility or 1) - 1) / 0.75
    local risk = math.clamp(params.annualExitRisk, 0, 0.99)
    local share = math.clamp(params.fertilityExitShare, 0, 1)
    return -math.log(1 - risk) / 12 * ((1 - share) * math.exp(-params.healthExitSlope * zh)
        + share * math.exp(-params.fertilityExitSlope * zf))
end


local function weigher(ctx, genes)
    local hazard = getHazard(ctx, genes)
    local discount = math.log(1 + ctx.params.discountRate) / 12
    return function(t) return math.exp(-(hazard + discount) * t) end
end


--- Reference cash flow of a cow from now: the rest of the present lactation, then a calf and a
--- lactation per calving, every gestation + wait + open months, up to femaleBirthSlots calvings
--- and breedingExitAgeMonth. Nothing after `horizon` months counts (nil: no limit).
---
--- ctx: {params, gestation, milkPerMonth (L at the mature curve point), milkPrice, calfValue}
--- state: {age, parity (calvings so far), lactationMonth|nil, calvingIn|nil, litter, breedingIn, waitIn}
--- @return number pv
--- @return table births {weight, existing} per calving counted (weight = survival x discount x calves)
--- @return number lastEnd Months to the end of the last lactation counted
function RLBreedingValue.femalePV(ctx, genes, state, horizon)
    local params = ctx.params
    local w = weigher(ctx, genes)
    local open = RLBreedingValue.getOpenMonths(genes.fertility, params)
    local share = math.clamp(params.dairyShare, 0, 1)
    local perLiter = ctx.milkPrice * share
        * (params.milkNetShare + ((genes.productivity or 1) - 1) * params.milkIncrementShare)
    local months = RLLactation.MONTHS

    local pv, births, lastEnd = 0, {}, 0

    local function lactation(start, fromMonth, parity)
        local level = RLMilkParity.getFactor(RLMilkParity.getParity(parity))
        for m = fromMonth, months - 1 do
            local t = start + (m - fromMonth) + 0.5
            if horizon ~= nil and t > horizon then break end
            pv = pv + w(t) * ctx.milkPerMonth * RLLactation.getYieldFactor(m) * level * perLiter
        end
        lastEnd = math.max(lastEnd, start + months - fromMonth)
    end

    if state.lactationMonth ~= nil and perLiter ~= 0 then lactation(0, state.lactationMonth, state.parity) end

    local t
    if state.calvingIn ~= nil then
        t = state.calvingIn
    else
        t = math.max(state.breedingIn or 0, state.waitIn or 0) + open + ctx.gestation
    end

    local parity, litter = state.parity or 0, state.litter or 1
    while #births < params.femaleBirthSlots and (horizon == nil or t <= horizon) do
        -- A calf already on the way is born whatever the exit age; later calvings must fit before it.
        local existing = #births == 0 and state.calvingIn ~= nil
        if not existing and state.age + t > params.breedingExitAgeMonth then break end
        parity = parity + 1
        local weight = w(t) * litter
        -- A suckler calf's weaning weight follows its dam's milk (productivity), her beef share only.
        pv = pv + weight * ctx.calfValue * (1 + (1 - share) * params.maternalMilkEffect * ((genes.productivity or 1) - 1))
        births[#births + 1] = { weight = weight, existing = existing }
        if perLiter ~= 0 then lactation(t, 0, parity) else lastEnd = math.max(lastEnd, t) end
        t = t + params.postpartumWaitMonth + open + ctx.gestation
        litter = 1
    end

    -- An early exit (an infertile or sick cow culled) costs her replacement's premium over her
    -- cull value, at the rate she leaves until the end of the valuation.
    local T = horizon or lastEnd
    local hazard = getHazard(ctx, genes)
    local rate = hazard + math.log(1 + params.discountRate) / 12
    if rate > 0 and (ctx.replacementPremium or 0) > 0 then
        pv = pv - ctx.replacementPremium * hazard / rate * (1 - math.exp(-rate * T))
    end

    return pv, births, lastEnd
end


--- A heifer calf at birth, for the daughter's own flows.
local function newbornState(ctx)
    return { age = 0, parity = 0, breedingIn = ctx.minAge or 0, litter = 1 }
end


--- Coefficients of the genetic score on each gene (getScore is linear in them).
local function scoreWeights(params, gender)
    local wd = params.wDairyProductivity + params.wDairyFertility + params.wDairyHealth
    local s = math.clamp(params.dairyShare, 0, 1)
    local q, f, h, wb
    if gender == "male" then
        q, f, h = params.wTerminalQuality, params.wTerminalFertility, params.wTerminalHealth
    else
        q, f, h = params.wMaternalQuality, params.wMaternalFertility, params.wMaternalHealth
    end
    wb = math.max(q + f + h, 1e-9)
    wd = math.max(wd, 1e-9)
    return {
        productivity = s * params.wDairyProductivity / wd,
        fertility = s * params.wDairyFertility / wd + (1 - s) * f / wb,
        health = s * params.wDairyHealth / wd + (1 - s) * h / wb,
        quality = (1 - s) * q / wb,
    }
end


-- Gauss-Hermite nodes and weights for E[f(Z)], Z standard normal (5 points).
local GH = { { 0, 0.533333 }, { 1.355626, 0.222076 }, { -1.355626, 0.222076 }, { 2.856970, 0.011257 }, { -2.856970, 0.011257 } }


--- The excellence an offspring of these mean genes can be expected to reach: E(score) over the
--- spread of each gene around its mean (BreedingMath.SD_CONST, genes independent). An animal whose
--- genes are already drawn (a calf on the way) has no spread.
--- @return number
function RLBreedingValue.expectedExcellence(genes, params, gender, known)
    local mean = RLBreedingValue.getScore(genes, params, gender)
    if known then return RLBreedingValue.excellence(mean, params) end
    local c, sum = scoreWeights(params, gender), 0
    for _, weight in pairs(c) do sum = sum + weight * weight end
    local sd = BreedingMath.SD_CONST * math.sqrt(sum)
    local total = 0
    for _, node in ipairs(GH) do
        local score = math.clamp(mean + sd * node[1], GENE_MIN, GENE_MAX)
        total = total + node[2] * RLBreedingValue.excellence(score, params)
    end
    return total
end


--- Share of a bull's offspring gain his buyer counts on: bought semen of the same merit competes,
--- in dairy herds (mostly AI) far more than in suckler herds (mostly served by a bull).
function RLBreedingValue.getSireCapture(params)
    local s = math.clamp(params.dairyShare, 0, 1)
    return s * params.sireCaptureDairy + (1 - s) * params.sireCaptureBeef
end


--- A bull's offspring gain over a standard bull's from `age` on: his own herd's calves over his
--- remaining seasons (survival by his health gene) x the gain per calf x sireCapture x the chance he
--- proves out as a sire. depth 1 is a son's: his calves get no seedstock channel of their own.
--- @return number gain
--- @return number calves
--- @return number qualification
function RLBreedingValue.sireGain(ctx, genes, age, depth)
    local params = ctx.params
    local perCalf = RLBreedingValue.offspringDelta(ctx, RLBreedingValue.inheritedGenes(genes), nil, depth)
    local w = weigher(ctx, genes)
    local first = math.max(ctx.minAge - age, 0)
    local calves = 0
    for season = 0, params.sireSeasons - 1 do
        local start = first + 12 * season
        if age + start >= params.sireExitAgeMonth then break end
        calves = calves + params.sireFemalesPerSeason * params.sireConception * w(start + ctx.gestation)
    end
    local grown = ctx.minAge > 0 and math.min(age / ctx.minAge, 1) or 1
    local qualification = params.sireQualificationAtBirth + (1 - params.sireQualificationAtBirth) * grown
    return calves * perCalf * RLBreedingValue.getSireCapture(params) * qualification, calves, qualification
end


--- What an offspring with these genes is worth over a standard one, at its birth, x offspringCapture:
---   daughter  her own reference cash flow over a standard heifer's (and half of a beef heifer's meat)
---   son       his meat, and (depth 0) what he fetches as a breeding bull at sonSaleAgeMonth: the
---             sire premium for his genes' expected excellence (the seedstock channel), counted on
---             his calves' cash flows, never on their sale prices.
--- @param ctx table As femalePV, plus {minAge, meatPerQuality}
--- @param genes table Mean genes (or the drawn genes when known)
--- @param gender string|nil nil: an expected calf, half each
--- @param depth number|nil 0 (default) or 1
--- @param known boolean|nil The genes are drawn already (a calf on the way)
--- @return number
function RLBreedingValue.offspringDelta(ctx, genes, gender, depth, known)
    local params = ctx.params
    depth = depth or 0
    local capture = params.offspringCapture
    local discount = math.log(1 + params.discountRate) / 12
    local meat = (ctx.meatPerQuality or 0) * ((genes.quality or 1) - 1)
        * math.exp(-discount * params.sonSlaughterAgeMonth)

    local function daughter()
        local base, _, horizon = RLBreedingValue.femalePV(ctx, STANDARD, newbornState(ctx), nil)
        local own = RLBreedingValue.femalePV(ctx, genes, newbornState(ctx), horizon)
        return own - base + (1 - math.clamp(params.dairyShare, 0, 1)) * 0.5 * meat
    end

    local function son()
        if depth > 0 then return meat end
        local excellence = RLBreedingValue.expectedExcellence(genes, params, "male", known)
        if excellence <= 0 then return meat end
        local gain = RLBreedingValue.sireGain(ctx, genes, params.sonSaleAgeMonth, depth + 1)
        local breeding = params.alphaHered * params.rhoHered * excellence * math.max(gain, 0)
            * math.exp(-discount * params.sonSaleAgeMonth)
        -- Sold as a bull or as beef, whichever pays: not both.
        return math.max(meat, breeding)
    end

    local value
    if gender == "female" then value = daughter()
    elseif gender == "male" then value = son()
    else value = 0.5 * daughter() + 0.5 * son() end
    return capture * value
end


--- The mean genes of a calf of this parent and a mate of gene `mate` (default the standard 1).
--- @param genes table
--- @param mate number|nil
--- @return table
function RLBreedingValue.inheritedGenes(genes, mate)
    return {
        productivity = RLBreedingValue.inheritedMean(genes.productivity or 1, mate),
        fertility = RLBreedingValue.inheritedMean(genes.fertility or 1, mate),
        health = RLBreedingValue.inheritedMean(genes.health or 1, mate),
        quality = RLBreedingValue.inheritedMean(genes.quality or 1, mate),
    }
end


--- The formula of PRICE-BREED-03 over prepared values.
--- @param input table {role "cow"|"sire", curve, meatRoute, stateValue, bodyDifference, deltaOwn,
---   deltaHered, excellence}
--- @param params table
--- @return table quote
function RLBreedingValue.combine(input, params)
    local standard = input.curve + params.alphaNormal * (input.stateValue or 0)
    local body = input.bodyDifference or 0
    local own, hered = input.deltaOwn or 0, input.deltaHered or 0
    local ownPremium, heredPremium, loss = 0, 0, 0
    if input.role == "sire" then
        -- A bull's own genes act through his calves; a poor one is simply not a breeding bull.
        heredPremium = params.alphaHered * params.rhoHered * input.excellence * math.max(own + hered, 0)
    else
        ownPremium = params.alphaOwn * params.rhoOwn * math.max(own, 0)
        heredPremium = params.alphaHered * params.rhoHered * input.excellence * math.max(hered, 0)
        loss = params.alphaNormal * (math.max(-own, 0) + math.max(-hered, 0))
    end
    local raw = standard + body - loss + ownPremium + heredPremium
    -- A good trait cannot hide a loss elsewhere: never more than the whole route's PV gain.
    local ceiling = math.max(input.meatRoute, standard + body + math.max(own + hered, 0))
    local price = math.min(math.max(input.meatRoute, raw), ceiling)
    return {
        status = "VALUED", role = input.role, price = price, curve = input.curve, meatRoute = input.meatRoute,
        stateValue = input.stateValue or 0, standard = standard, bodyDifference = body, deltaOwn = own, deltaHered = hered,
        excellence = input.excellence, ownPremium = ownPremium, heredPremium = heredPremium, loss = loss,
        raw = raw, ceiling = ceiling, floorAdjustment = math.max(input.meatRoute - raw, 0),
        ceilingAdjustment = math.max(math.max(input.meatRoute, raw) - ceiling, 0),
    }
end


-- =============================================================================
-- Game adapter
-- =============================================================================

--- Whether the animal is priced here: an animal of the COW type, config enabled.
--- @param animal table
--- @param subType table|nil
--- @return boolean
function RLBreedingValue.covers(animal, subType)
    if AnimalType == nil or animal == nil or animal.animalTypeIndex ~= AnimalType.COW or animal.genetics == nil then return false end
    subType = subType or (animal.getSubType ~= nil and animal:getSubType() or nil)
    if subType == nil or subType.sellPrice == nil then return false end
    return RLBreedTraits.resolve(RLBreedingValue.getConfig().layers, subType, "enabled", RLBreedingValue.DEFAULTS.enabled) > 0
end


--- The subtype of the same type and breed with the other sex, or nil.
--- @param subType table
--- @param gender string "male" or "female"
--- @return table|nil
function RLBreedingValue.getCounterpart(subType, gender)
    if subType.gender == gender then return subType end
    local key = tostring(subType.name) .. ":" .. gender
    local cached = counterpartCache[key]
    if cached ~= nil then return cached or nil end
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    local found = false
    if animalSystem ~= nil and subType.breed ~= nil then
        for _, other in pairs(animalSystem.subTypes or {}) do
            if other.typeIndex == subType.typeIndex and other.breed == subType.breed and other.gender == gender
                and other.sellPrice ~= nil then
                found = other
                break
            end
        end
    end
    counterpartCache[key] = found
    return found or nil
end


--- The subtype's tank or can milk output: its value at the mature age (L per month) and fill type.
local function getMilkOutput(subType)
    for fillType, output in pairs(subType.output or {}) do
        local isMilk = (fillType == "milk" and not (Animal.isSemenFillType ~= nil and Animal.isSemenFillType(output.fillType)))
            or (fillType == "pallets" and Animal.isCowMilkPalletFillType ~= nil and Animal.isCowMilkPalletFillType(output.fillType))
        if isMilk then
            local age = RLMilkParity.MATURE_AGE_MONTHS
            local value = output.curve ~= nil and output.curve:get(age) or output:get(age)
            return value or 0, output.fillType
        end
    end
    return 0, nil
end


--- Meat value per unit of the meat gene for a typical offspring: meat per head x carcass factor x
--- qualitySwing x (annual mean meat price - cutting fee per kg).
local function getMeatPerQuality(subType)
    if AnimalMoveEvent == nil or AnimalMoveEvent.getCarcassConfig == nil or RLMeatValue == nil then return 0 end
    local typeName = RLBreedTraits.getTypeName(subType)
    local meatPerHead = typeName ~= nil and AnimalMoveEvent.getMeatPerHead(typeName) or nil
    local fillType = typeName ~= nil and RLMeatValue.getMeatFillType(typeName) or nil
    if meatPerHead == nil or fillType == nil then return 0 end
    local layers = AnimalMoveEvent.getCarcassConfig().layers
    local carcass = RLBreedTraits.resolve(layers, subType, "carcassFactor", 1)
    local swing = RLBreedTraits.resolve(layers, subType, "qualitySwing", 0)
    local perKg = RLBreedTraits.resolve(layers, subType, "processingFeePerKg", 0) * RLLivestockPrices.getMultiplier()
    return meatPerHead * carcass * swing * math.max(RLMeatValue.getAnnualMeanPrice(fillType) - perKg, 0)
end


--- What a calving yields besides milk: a dairy calf is sold young (the mean newborn curve price of
--- the breed); a suckler calf is weaned and sold at beefCalfSaleAgeMonth (the mean curve price then,
--- x beefCalfNetShare for its own and its dam's costs to weaning, discounted to the calving).
--- Mixed by dairyShare.
local function getCalfValue(subType, params)
    local function mean(age)
        local total, count = 0, 0
        for _, gender in ipairs({ "female", "male" }) do
            local other = RLBreedingValue.getCounterpart(subType, gender)
            if other ~= nil then total, count = total + other.sellPrice:get(age), count + 1 end
        end
        if count == 0 then return subType.sellPrice:get(age) * RLLivestockPrices.getMultiplier() end
        return total / count * RLLivestockPrices.getMultiplier()
    end
    local s = math.clamp(params.dairyShare, 0, 1)
    local age = params.beefCalfSaleAgeMonth
    local weaned = mean(age) * params.beefCalfNetShare * math.exp(-math.log(1 + params.discountRate) * age / 12)
    return s * mean(0) + (1 - s) * weaned
end


--- What replacing a culled cow costs over her cull value: the in-calf premium over cull of the
--- calibration (exitReplacementDairy / exitReplacementBeef, mixed by dairyShare) x a typical cow's
--- cull value (typical meat x annual mean price, less the slaughter fees, as RLMeatValue's floor).
local function getReplacementPremium(subType, params)
    if AnimalMoveEvent == nil or AnimalMoveEvent.getCarcassConfig == nil or RLMeatValue == nil then return 0 end
    local typeName = RLBreedTraits.getTypeName(subType)
    local meatPerHead = typeName ~= nil and AnimalMoveEvent.getMeatPerHead(typeName) or nil
    local fillType = typeName ~= nil and RLMeatValue.getMeatFillType(typeName) or nil
    if meatPerHead == nil or fillType == nil then return 0 end
    local layers = AnimalMoveEvent.getCarcassConfig().layers
    local kg = meatPerHead * RLBreedTraits.resolve(layers, subType, "carcassFactor", 1)
    local fee = (RLBreedTraits.resolve(layers, subType, "slaughterFee", 0)
        + RLBreedTraits.resolve(layers, subType, "processingFeePerKg", 0) * kg) * RLLivestockPrices.getMultiplier()
    local cull = math.max(kg * RLMeatValue.getAnnualMeanPrice(fillType) - fee, 0)
        / (1 + RLBreedTraits.resolve(layers, subType, "maxSlaughterMargin", 0))
        * RLBreedTraits.resolve(layers, subType, "cullFloorFactor", 1)
    local s = math.clamp(params.dairyShare, 0, 1)
    return cull * (s * params.exitReplacementDairy + (1 - s) * params.exitReplacementBeef)
end


--- Context of the reference cash flow for a subtype.
--- @param subType table
--- @return table ctx
function RLBreedingValue.buildContext(subType)
    local params = RLBreedingValue.getParams(subType)
    local female = RLBreedingValue.getCounterpart(subType, "female") or subType
    local milkPerMonth, milkFillType = getMilkOutput(female)
    local milkPrice = 0
    if milkFillType ~= nil and RLMeatValue ~= nil then milkPrice = RLMeatValue.getAnnualMeanPrice(milkFillType) end
    milkPerMonth = milkPerMonth * RLBreedTraits.get(female, "milkScale")
    return {
        params = params,
        gestation = female.reproductionDurationMonth or 10,
        minAge = female.reproductionMinAgeMonth or 12,
        milkPerMonth = milkPerMonth,
        milkPrice = milkPrice,
        calfValue = getCalfValue(subType, params),
        meatPerQuality = getMeatPerQuality(subType),
        replacementPremium = getReplacementPremium(subType, params),
    }
end


--- A view of the animal with meat gene 1 and everything else its own (M0 of the design).
--- @param animal table
--- @return table
function RLBreedingValue.withStandardMeatGene(animal)
    local genetics = setmetatable({ quality = 1 }, { __index = animal.genetics })
    return setmetatable({ genetics = genetics }, { __index = animal })
end


--- The factor on a cow's curve price at `age` months: 1 up to cowCurveScaleFromMonth, cowCurveScale
--- from cowCurveScaleFullMonth, smoothstep between.
--- @return number
function RLBreedingValue.getCowCurveScale(params, age)
    local from, full = params.cowCurveScaleFromMonth, params.cowCurveScaleFullMonth
    local t = full > from and math.clamp((age - from) / (full - from), 0, 1) or (age >= full and 1 or 0)
    return 1 + (params.cowCurveScale - 1) * t * t * (3 - 2 * t)
end


local function genesOf(animal)
    local g = animal.genetics
    return { productivity = g.productivity or 1, fertility = g.fertility or 1, health = g.health or 1, quality = g.quality or 1 }
end


local function applyDiseases(animal, value)
    for _, disease in pairs(animal.diseases or {}) do value = disease:modifyValue(value) end
    return value
end


--- The cow's present state for femalePV, and the open, dry state of the same age it is measured against.
local function femaleStates(animal, ctx)
    local age = math.max(animal.age or 0, 0)
    local parity = animal.resolveBirthCount ~= nil and animal:resolveBirthCount() or 0
    local breedingIn = math.max(ctx.minAge - age, 0)
    local reference = { age = age, parity = parity, breedingIn = breedingIn, litter = 1 }

    local state = { age = age, parity = parity, breedingIn = breedingIn, litter = 1 }
    local msb = animal.monthsSinceLastBirth
    if animal.isParent and msb ~= nil then
        state.waitIn = math.max(ctx.params.postpartumWaitMonth - msb, 0)
        if animal.isLactating and RLLactation.isWithin(msb) then state.lactationMonth = math.floor(msb) end
    end
    if animal.isPregnant and animal.pregnancy ~= nil then
        local duration = animal.pregnancy.duration or ctx.gestation
        state.calvingIn = math.max(duration * (1 - (animal.reproduction or 0) / 100), 0)
        local fetuses = animal.pregnancy.pregnancies
        state.litter = fetuses ~= nil and #fetuses > 0 and #fetuses or 1
    end
    return state, reference
end


--- The genes of the calves on the way are known: their worth over standard calves, at their birth.
local function fetusValue(animal, ctx, weight)
    local fetuses = animal.isPregnant and animal.pregnancy ~= nil and animal.pregnancy.pregnancies or nil
    if fetuses == nil or #fetuses == 0 then return 0 end
    local total = 0
    for _, fetus in ipairs(fetuses) do
        if fetus.genetics ~= nil then
            total = total + RLBreedingValue.offspringDelta(ctx, genesOf(fetus), fetus.gender, 0, true)
        end
    end
    return total * weight / #fetuses
end


local function quoteCow(animal, subType, ctx, curve, meatRoute, body)
    local genes = genesOf(animal)
    local state, reference = femaleStates(animal, ctx)

    local pv0, births0, horizon = RLBreedingValue.femalePV(ctx, STANDARD, state, nil)
    local refPv = RLBreedingValue.femalePV(ctx, STANDARD, reference, nil)
    local pvP, births = RLBreedingValue.femalePV(ctx, genes, state, horizon)

    local stateValue = pv0 - refPv
    if births0[1] ~= nil and births0[1].existing then stateValue = stateValue + fetusValue(animal, ctx, births0[1].weight) end

    -- Offspring not yet conceived inherit from her and the bull or semen her buyer uses
    -- (cowMateGene, the same in every world): over the same mate's calves of a standard cow.
    local mate = ctx.params.cowMateGene
    local perCalf = RLBreedingValue.offspringDelta(ctx, RLBreedingValue.inheritedGenes(genes, mate), nil)
        - (mate ~= 1 and RLBreedingValue.offspringDelta(ctx, RLBreedingValue.inheritedGenes(STANDARD, mate), nil) or 0)
    local future = 0
    for _, birth in ipairs(births) do
        if not birth.existing then future = future + birth.weight end
    end

    local score = RLBreedingValue.getScore(genes, ctx.params, "female")
    local quote = RLBreedingValue.combine({
        role = "cow", curve = curve, meatRoute = meatRoute, stateValue = stateValue, bodyDifference = body,
        deltaOwn = pvP - pv0, deltaHered = future * perCalf,
        excellence = RLBreedingValue.excellence(score, ctx.params),
    }, ctx.params)
    quote.score, quote.pv0, quote.pvP, quote.births = score, pv0, pvP, #births
    return quote
end


local function quoteSire(animal, subType, ctx, curve, meatRoute)
    local params = ctx.params
    local genes = genesOf(animal)
    local gain, calves, qualification = RLBreedingValue.sireGain(ctx, genes, math.max(animal.age or 0, 0), 0)
    local score = RLBreedingValue.getScore(genes, params, "male")
    local quote = RLBreedingValue.combine({
        role = "sire", curve = curve, meatRoute = meatRoute, stateValue = 0,
        deltaOwn = 0, deltaHered = gain,
        excellence = RLBreedingValue.excellence(score, params),
    }, params)
    quote.score, quote.calves, quote.qualification = score, calves, qualification
    return quote
end


local function meatOnly(status, curve, meatRoute)
    return {
        status = status, price = meatRoute, curve = curve, meatRoute = meatRoute, stateValue = 0,
        standard = meatRoute, deltaOwn = 0, deltaHered = 0, excellence = 0,
        ownPremium = 0, heredPremium = 0, loss = 0, ceiling = meatRoute,
    }
end


--- The live value of a covered animal and how it was reached.
--- @param animal table
--- @param subType table|nil
--- @return table quote {status, price, curve, meatRoute, standard, stateValue, deltaOwn, deltaHered,
---   score, excellence, ownPremium, heredPremium, loss, ceiling, ...}
function RLBreedingValue.getQuote(animal, subType)
    subType = subType or animal:getSubType()
    local now = g_time
    -- Reused only for the same animal in the same state: a castration, calving or weigh-in prices anew.
    local key = string.format("%s|%s|%s|%s|%s|%s|%s|%s|%s|%s", tostring(subType.name), tostring(animal.age),
        tostring(animal.weight), tostring(animal.health), tostring(animal.isCastrated), tostring(animal.isPregnant),
        tostring(animal.isLactating), tostring(animal.reproduction), tostring(animal.monthsSinceLastBirth),
        tostring(animal.diseases ~= nil and #animal.diseases or 0))
    local cached = quoteCache[animal]
    if cached ~= nil and now ~= nil and cached.key == key and now - cached.time < RLBreedingValue.QUOTE_CACHE_MS then
        return cached.quote
    end

    local meat = RLMeatValue ~= nil and RLMeatValue.getSlaughterValue(animal) or 0
    if meat > 0 then meat = applyDiseases(animal, meat) end

    local quote, curve
    if animal.gender == "male" then
        curve = animal:getCurvePrice(subType, false)
        local meatRoute = math.max(meat, curve)
        local params = RLBreedingValue.getParams(subType)
        if animal.isCastrated then
            quote = meatOnly("MEAT_ONLY_CASTRATED", curve, meatRoute)
        elseif (animal.genetics.fertility or 1) <= 0 then
            quote = meatOnly("MEAT_ONLY_INFERTILE", curve, meatRoute)
        elseif (animal.age or 0) >= params.sireExitAgeMonth then
            quote = meatOnly("MEAT_ONLY_PAST_BREEDING", curve, meatRoute)
        else
            local ctx = RLBreedingValue.buildContext(subType)
            quote = quoteSire(animal, subType, ctx, curve, meatRoute)
            local premium = quote.price - curve
            if premium > 0 then quote.price = curve + applyDiseases(animal, premium) end
            quote.price = math.max(quote.price, meatRoute)
        end
    else
        -- Her meat gene is priced once, by what it adds to her meat (M_actual - M0), not by the curve.
        -- A grown cow's curve is scaled to the market (cowCurveScale, eased in from
        -- cowCurveScaleFromMonth to cowCurveScaleFullMonth); heifers keep theirs.
        local params = RLBreedingValue.getParams(subType)
        curve = animal:getCurvePrice(subType, false, nil, 1) * RLBreedingValue.getCowCurveScale(params, animal.age or 0)
        local body = 0
        if meat > 0 and RLMeatValue ~= nil then
            local standardMeat = RLMeatValue.getSlaughterValue(RLBreedingValue.withStandardMeatGene(animal))
            body = meat - applyDiseases(animal, standardMeat)
        end
        local meatRoute = meat
        if meat <= 0 and not animal.isParent then
            -- Too young for the butcher: a calf can still be fattened, at the lower of her own
            -- curve and her breed's bull curve for her.
            local own = animal:getCurvePrice(subType, false)
            local bull = RLBreedingValue.getCounterpart(subType, "male")
            meatRoute = bull ~= nil and math.min(own, animal:getCurvePrice(bull, false, "male")) or own
        end
        if (animal.genetics.fertility or 1) <= 0 then
            quote = meatOnly(animal.isPregnant and "REPRO_STATE_CONFLICT" or "MEAT_ONLY_INFERTILE", curve, meatRoute)
        else
            local ctx = RLBreedingValue.buildContext(subType)
            quote = quoteCow(animal, subType, ctx, curve, meatRoute, body)
            local premium = quote.price - curve
            if premium > 0 then quote.price = math.max(curve + applyDiseases(animal, premium), meatRoute) end
        end
    end
    quote.meat = meat

    if now ~= nil then quoteCache[animal] = { time = now, key = key, quote = quote } end
    return quote
end


Log:debug("RLBreedingValue loaded")
