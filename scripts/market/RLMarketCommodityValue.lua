-- HARD reference values, independent of Dealer BID/ASK and old live-price floors.
RLMarketCommodityValue = {}
local V = RLMarketCommodityValue
function V.finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
function V.nonnegative(n) return V.finite(n) and n >= 0 end
function V.dense(list)
    if type(list) ~= "table" then return false end
    local count = 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #list then return false end
        count = count + 1
    end
    return count == #list
end
function V.evaluate(snapshot, input)
    if type(input) ~= "table" or input.currencyBasis ~= "HARD" then return nil, "MISSING_COMMODITY_REFERENCE" end
    local paths = {}
    if input.slaughter ~= nil and input.slaughter.available == true then
        if not V.finite(input.slaughter.net) or type(input.slaughter.basis)~="table" or input.slaughter.basis.moneyBasis~="HARD" then return nil, "INVALID_SLAUGHTER_REFERENCE" end
        paths[#paths + 1] = { purpose = "SLAUGHTER", referenceValue = math.max(0, input.slaughter.net) }
    end
    if input.rearing ~= nil then
        local r = input.rearing
        if not V.nonnegative(r.futureGross) or not V.nonnegative(r.remainingCost)
            or not V.nonnegative(r.discountRate) or not V.nonnegative(r.months) or r.months > 120 then
            return nil, "INVALID_REARING_REFERENCE"
        end
        paths[#paths + 1] = { purpose = "REARING", referenceValue = math.max(0,
            (r.futureGross - r.remainingCost) / (1 + r.discountRate) ^ (r.months / 12)) }
    end
    if #paths == 0 then return nil, "COMMODITY_UNSUPPORTED" end
    local value = 0
    for _, path in ipairs(paths) do value = math.max(value, path.referenceValue) end
    if not V.finite(value) then return nil, "REFERENCE_OVERFLOW" end
    return { referenceValue = value, paths = paths, currencyBasis = "HARD" }
end

-- Shared pure arithmetic only. Species modules supply their own event timing,
-- offspring economics and explicit parameters; no cattle defaults are inherited.
function V.score(genes, weights)
    if type(genes) ~= "table" or type(weights) ~= "table" then return nil, "MISSING_SELECTION_DATA" end
    local total, sum = 0, 0
    for gene, weight in pairs(weights) do
        if not V.nonnegative(weight) then return nil, "INVALID_SELECTION_WEIGHT" end
        if weight~=0 then
            if not V.nonnegative(genes[gene]) then return nil, "MISSING_SELECTION_TRAIT" end
            total, sum = total + genes[gene] * weight, sum + weight
        end
    end
    if sum <= 0 then return nil, "MISSING_SELECTION_WEIGHTS" end
    return total / sum
end
function V.inheritedMean(gene, mate, sd)
    if not V.nonnegative(gene) or not V.nonnegative(mate) or not V.nonnegative(sd) then return nil end
    local mean = (gene + mate) / 2
    local lo, hi = 0.25, 1.75
    if sd == 0 then return math.max(lo, math.min(hi, mean)) end
    local function cdf(x)
        local t = 1 / (1 + 0.2316419 * math.abs(x))
        local q = math.exp(-x * x / 2) / math.sqrt(2 * math.pi)
            * t * (0.319381530 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))))
        return x >= 0 and 1 - q or q
    end
    local a, b = (lo - mean) / sd, (hi - mean) / sd
    local phi = function(x) return math.exp(-x * x / 2) / math.sqrt(2 * math.pi) end
    return lo * cdf(a) + mean * (cdf(b) - cdf(a)) + sd * (phi(a) - phi(b)) + hi * (1 - cdf(b))
end
function V.weight(time, genes, p)
    local hazard = -math.log(1 - p.annualExitRisk) / 12 * math.exp(-p.healthExitSlope * (genes.health - 1))
    return math.exp(-(hazard + math.log(1 + p.discountRate) / 12) * time)
end
function V.parameters(snapshot, objective, input, species)
    if type(snapshot) ~= "table" or snapshot.speciesKey ~= species or type(input) ~= "table"
        or input.currencyBasis ~= "HARD" or type(input.params) ~= "table" then return nil, "PRODUCTION_UNSUPPORTED" end
    local p = input.params
    if input.costBasis ~= "NET_FLOWS_INCLUDE_ALL_PRODUCTION_COSTS" then return nil, "MISSING_PRODUCTION_COST_BASIS" end
    for _, name in ipairs({ "minBreedingAge", "exitAge", "gestationMonths", "recoveryMonths", "openMonths",
        "maxBirths", "annualExitRisk", "healthExitSlope", "discountRate", "inheritanceSD", "mateGene", "offspringBaseNet" }) do
        if not V.nonnegative(p[name]) then return nil, "MISSING_PRODUCTION_" .. name end
    end
    if p.gestationMonths <= 0 or p.exitAge > 240 or p.exitAge <= p.minBreedingAge or p.annualExitRisk >= 1
        or p.maxBirths > 100 or p.maxBirths % 1 ~= 0 or p.mateGene < 0.25 or p.mateGene > 1.75 then return nil, "INVALID_PRODUCTION_PARAMETERS" end
    if type(snapshot.genes) ~= "table" or type(snapshot.reproductive) ~= "table" or type(snapshot.traitCapabilities) ~= "table" then return nil, "MISSING_PRODUCTION_STATE" end
    if not V.nonnegative(snapshot.ageMonths) or not V.nonnegative(snapshot.genes and snapshot.genes.health)
        or not V.nonnegative(snapshot.genes and snapshot.genes.fertility) then return nil, "MISSING_PRODUCTION_GENES" end
    if snapshot.genes.fertility <= 0 then return nil, "INFERTILE" end
    if snapshot.castrated == true then return nil, "CASTRATED" end
    if snapshot.ageMonths >= p.exitAge then return nil, "PAST_BREEDING_LIFE" end
    if snapshot.castrated == nil or not snapshot.reproductive or (snapshot.gender == "female" and snapshot.reproductive.parity == nil) then return nil, "MISSING_REPRODUCTIVE_STATE" end
    local supported = false
    for _, role in ipairs(snapshot.supportedBreedingRoles or {}) do if role == objective then supported = true end end
    if not supported then return nil, "UNSUPPORTED_BREEDING_ROLE" end
    if not input.weights or not input.weights[objective] then return nil, "UNSUPPORTED_OBJECTIVE" end
    local score, why = V.score(snapshot.genes, input.weights[objective])
    if not score then return nil, why end
    if objective == "TERMINAL" and (input.weights[objective].productivity or 0) ~= 0 then return nil, "TERMINAL_PRODUCTIVITY_FORBIDDEN" end
    return p, score
end
function V.offspringDelta(genes, input, objective)
    local coefficients = input.offspringDeltaPerGene and input.offspringDeltaPerGene[objective]
    if type(coefficients) ~= "table" then return nil, "MISSING_OFFSPRING_REFERENCE" end
    local total = 0
    for gene, coefficient in pairs(coefficients) do
        if not V.finite(coefficient) then return nil, "INVALID_OFFSPRING_COEFFICIENT" end
        if coefficient~=0 then
            if not V.nonnegative(genes[gene]) then return nil, "MISSING_OFFSPRING_TRAIT" end
            if objective == "TERMINAL" and gene == "productivity" then return nil, "TERMINAL_PRODUCTIVITY_FORBIDDEN" end
            local inherited = V.inheritedMean(genes[gene], input.params.mateGene, input.params.inheritanceSD)
            local standard = V.inheritedMean(1, input.params.mateGene, input.params.inheritanceSD)
            total = total + (inherited - standard) * coefficient
        end
    end
    if not V.finite(total) then return nil, "REFERENCE_OVERFLOW" end
    return total
end
function V.result(reference, own, hered, score, detail)
    if not V.finite(reference) or not V.finite(own) or not V.finite(hered) then return nil, "REFERENCE_OVERFLOW" end
    return { referenceValue = math.max(0, reference), ownDelta = own, hereditaryDelta = hered,
        valuationScore = score, eligible = true, reasons = {}, breakdown = detail,
        currencyBasis = "HARD" }
end
-- Explicit data only; no pregnancy RNG, calf generation, money or animal updates.
function V.events(snapshot, input, genes)
    local p, r = input.params, snapshot.reproductive
    if r.pregnant == nil or r.lactating == nil then return nil, "MISSING_REPRODUCTIVE_STATE" end
    local remaining = math.max(0, p.maxBirths - r.parity)
    local first, existing = nil, false
    if r.pregnant then
        if not r.pregnancy or not V.nonnegative(r.pregnancy.duration) or not V.nonnegative(r.reproduction)
            or r.reproduction > 100 or not V.dense(r.pregnancy.pregnancies) or #r.pregnancy.pregnancies == 0 then return nil, "MISSING_PREGNANCY_DATA" end
        first = r.pregnancy.duration * (1 - r.reproduction / 100)
        existing = true
    else
        local recovery = 0
        if r.isParent then
            if not V.nonnegative(r.monthsSinceLastBirth) then return nil, "MISSING_RECOVERY_STATE" end
            recovery = math.max(0, p.recoveryMonths - r.monthsSinceLastBirth)
        end
        first = math.max(p.minBreedingAge - snapshot.ageMonths, recovery, 0) + p.openMonths / genes.fertility + p.gestationMonths
    end
    local events, t = {}, first
    for index = 1, math.max(remaining, existing and 1 or 0) do
        local isExisting = existing and index == 1
        if not isExisting and snapshot.ageMonths + t > p.exitAge then break end
        events[#events + 1] = { time = t, existing = isExisting }
        t = t + p.recoveryMonths + p.openMonths / genes.fertility + p.gestationMonths
    end
    return events
end
