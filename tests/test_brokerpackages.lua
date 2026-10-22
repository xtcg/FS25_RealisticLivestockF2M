loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLBrokerConditionPackage.lua")
local P = RLBrokerConditionPackage
local kinds = {"cattleWeaned", "cattleStore", "cattleFinished", "cattleReplacement", "cattlePregnant", "cattleLactating", "cattleSire", "pigGrower", "pigFinished", "pigReplacement", "pigSire", "lambGrower", "lambFinished", "eweReplacement", "ramSire"}
local function options(kind)
    local species = kind:sub(1, 3) == "pig" and "PIG" or (kind:sub(1, 6) == "cattle" and "COW" or "SHEEP")
    return {allowedProductionClasses = kind == "cattleLactating" and {"DAIRY"} or {"BEEF"}, requiredBreedId = species .. ":TEST", breedingObjective = "MATERNAL", finishingStages = {"FINISHING"}, breedingStages = {"BREEDING_READY"}, indexWeights = {fertility = 0.6, health = 0.4}}
end
local function raw(kind)
    local o = options(kind)
    if kind == "cattleWeaned" or kind == "cattleStore" or kind == "pigGrower" or kind == "lambGrower" then o.requiredBreedId = nil end
    return assert(P.candidate(kind, o))
end
for _, kind in ipairs(kinds) do
    local p, reason = P.compile(raw(kind))
    check("packages: executable candidate " .. kind, p ~= nil and p.candidate == true and reason == nil)
    if p then
        check("packages: stable recompile " .. kind, assert(P.compile(p)).revision == p.revision)
        local altered = assert(RLMarketData.copy(p)); altered.conditions[#altered.conditions + 1] = {field = "f.finished", op = "appropriateBodyCondition"}
        check("packages: no textual condition " .. kind, P.compile(altered) == nil)
    end
end
local function bad(name, kind, mutate)
    local p = raw(kind); mutate(p)
    local result, reason = P.compile(p)
    check("packages: " .. name, result == nil and type(reason) == "string")
end
bad("unknown field rejected", "cattleStore", function(p) p.conditions[1].field = "s.guiVerdict" end)
bad("unknown root condition text rejected", "cattleStore", function(p) p.bodyCondition = "适宜" end)
bad("range contradiction rejected", "cattleStore", function(p) p.conditions[1].min = 30; p.conditions[1].max = 20 end)
bad("same bound exclusive range rejected", "cattleStore", function(p) p.conditions[1].min = 20; p.conditions[1].max = 20; p.conditions[1].maxExclusive = true end)
bad("separate contradictory age ranges rejected", "cattleStore", function(p) p.conditions[#p.conditions + 1] = {field = "s.ageMonths", op = "range", min = 40} end)
bad("male cannot be pregnant", "cattleSire", function(p) p.conditions[#p.conditions + 1] = {field = "s.reproductive.pregnant", op = "eq", value = true} end)
bad("zero parity cannot lactate", "cattleLactating", function(p) p.conditions[#p.conditions + 1] = {field = "s.reproductive.parity", op = "eq", value = 0} end)
bad("grower cannot be finished", "cattleStore", function(p) p.conditions[#p.conditions + 1] = {field = "f.finished", op = "eq", value = true} end)
bad("only grower permits ANY", "cattleFinished", function(p) p.breedScope = "ANY"; p.requiredBreedId = nil end)
bad("ANY cannot hide a breed key", "cattleStore", function(p) p.requiredBreedId = "COW:ANGUS" end)
bad("commodity cannot claim elite tier", "cattleStore", function(p) p.tier = "elite" end)
bad("commodity cannot claim unknown tier", "cattleFinished", function(p) p.tier = "arbitrary" end)
bad("fixed lactation package cannot claim elite tier", "cattleLactating", function(p) p.tier = "elite" end)
bad("SPECIFIC must have breed", "cattleSire", function(p) p.requiredBreedId = nil end)
bad("SPECIFIC breed namespace must match species", "cattleSire", function(p) p.requiredBreedId = "PIG:TEST" end)
bad("SPECIFIC breed suffix cannot be empty", "cattleSire", function(p) p.requiredBreedId = "COW:" end)
bad("SPECIFIC breed cannot contain whitespace", "cattleSire", function(p) p.requiredBreedId = "COW: ANGUS" end)
bad("SPECIFIC breed cannot contain extra delimiter", "cattleSire", function(p) p.requiredBreedId = "COW:ANGUS:OTHER" end)
bad("lactating beef class cannot bypass public dairy restriction", "cattleLactating", function(p) p.allowedProductionClasses = {"BEEF"} end)
bad("empty classes rejected", "cattleStore", function(p) p.allowedProductionClasses = {} end)
bad("unknown target rejected", "cattleSire", function(p) p.breedingObjective = "GENERAL" end)
bad("zero weighted gene minimum rejected", "cattleSire", function(p) p.genetics.geneMin.productivity = 1 end)
bad("wrong objective index rejected", "cattleSire", function(p) p.genetics.indexId = "cattle.dairy" end)
bad("removed dairy index cannot substitute fertility-heavy weights", "cattleSire", function(p)
    p.breedingObjective = "DAIRY"; p.genetics.indexId = nil
    p.genetics.weights = {quality = 0.01, productivity = 0.01, fertility = 0.97, health = 0.01}
    p.genetics.geneMin = {productivity = 1.15, fertility = 1, health = 0.90}
end)
for _, family in ipairs({{kind = "cattleSire", prefix = "cattle"}, {kind = "ramSire", prefix = "sheep"}}) do
    for _, objective in ipairs({"DAIRY", "TERMINAL", "MATERNAL"}) do
        local o = options(family.kind); o.breedingObjective = objective
        local rawIndex = assert(P.candidate(family.kind, o)); rawIndex.genetics.weights = P.indexWeights(family.prefix .. "." .. objective:lower()); rawIndex.genetics.indexId = nil
        check("packages: fixed objective ID cannot be removed " .. family.prefix .. "." .. objective, P.compile(rawIndex) == nil)
    end
end
bad("index weights not sum one rejected", "pigSire", function(p) p.genetics.weights = {fertility = 0.5, health = 0.4} end)
bad("pig cannot borrow cattle index", "pigSire", function(p) p.genetics.indexId = "cattle.maternal" end)
bad("missing package predicates rejected", "cattleFinished", function(p) table.remove(p.conditions) end)
bad("store upper ratio cannot relax to .95", "cattleStore", function(p) for _, c in ipairs(p.conditions) do if c.op == "ratio" then c.max = 0.95 end end end)
bad("store finish65 cannot become inclusive", "cattleStore", function(p) for _, c in ipairs(p.conditions) do if c.field == "s.production.finishScore" then c.maxExclusive = false end end end)
bad("finished95 cannot relax", "cattleFinished", function(p) for _, c in ipairs(p.conditions) do if c.reference == "s.production.slaughterReferenceKg" then c.min = 0.8 end end end)
bad("pregnancy cannot require current remating", "cattlePregnant", function(p) p.conditions[#p.conditions + 1] = {field = "f.currentBreedingReady", op = "eq", value = true} end)
bad("lactation retains dedicated .95 fertility", "cattleLactating", function(p) p.genetics.geneMin.fertility = 1 end)
bad("bad fat class rejected", "lambFinished", function(p) for _, c in ipairs(p.conditions) do if c.field == "s.production.fatClass" then c.values = {"4H"} end end end)
bad("sire cannot lower main gene minimum", "cattleSire", function(p) p.genetics.geneMin.fertility = 1 end)
bad("nonfinite threshold rejected", "cattleStore", function(p) p.conditions[1].min = math.huge end)
bad("health minimum cannot relax", "cattleSire", function(p) for _, c in ipairs(p.conditions) do if c.field == "s.health" then c.min = 80 end end end)
bad("female gene minima cannot be removed", "cattleReplacement", function(p) p.genetics.geneMin = {} end)
bad("lactation cannot extend to seventh month", "cattleLactating", function(p) for _, c in ipairs(p.conditions) do if c.field == "s.reproductive.monthsSinceLastBirth" then c.maxExclusive = false end end end)
bad("BCS upper bound cannot be omitted", "ramSire", function(p) for _, c in ipairs(p.conditions) do if c.field == "s.production.bcs" then c.max = nil end end end)
bad("unused predicate payload rejected", "cattleStore", function(p) p.conditions[1].value = "适宜" end)
local p = raw("cattleStore"); local reordered = assert(RLMarketData.copy(p))
local reversed = {}; for i = #reordered.conditions, 1, -1 do reversed[#reversed + 1] = reordered.conditions[i] end; reordered.conditions = reversed
check("packages: AND predicate order does not change revision", assert(P.compile(p)).revision == assert(P.compile(reordered)).revision)
for _, id in ipairs({"cattle.dairy", "cattle.terminal", "cattle.maternal", "sheep.dairy", "sheep.terminal", "sheep.maternal"}) do
    check("packages: index weights sum one " .. id, P.validateWeights(P.indexWeights(id)))
end
local noStages = options("pigFinished"); noStages.finishingStages = nil
check("packages: pig needs explicit real finishing stage vocabulary", P.compile(assert(P.candidate("pigFinished", noStages))) == nil)
local noPigWeights = options("pigSire"); noPigWeights.indexWeights = nil
check("packages: pig needs dedicated approved index input", P.compile(assert(P.candidate("pigSire", noPigWeights))) == nil)
local before = assert(RLMarketData.fingerprint(p)); assert(P.compile(p))
check("packages: compilation never mutates input", before == RLMarketData.fingerprint(p))
