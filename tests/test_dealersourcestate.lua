loadMod("tests/dealerreplaysim.lua")
loadMod("scripts/dealer/RLDealerSourceState.lua")
local S, R, Sim = RLDealerSourceState, RLDealerReplay, DealerReplaySim
local seed = Sim.seed("HOLSTEIN", "female", 1)
local history = Sim.history(seed, 8.5)
local result = assert(R.run(seed, history, { daysPerMonth = 1 }))
local record = assert(S.capture(result, 100.25))
local function clone(t) if type(t) ~= "table" then return t end; local c = {}; for k,v in pairs(t) do c[k] = clone(v) end; return c end
local function resolver(name) local _, sub = Economics.find(name); return sub end
check("source: record pins continuous source clock to birth-origin animal age", S.validate(record)
    and near(record.birthOriginMonths, 91.75, 1e-10) and record.animal.rlGrowth.lastTick == nil)
local originalWeight = record.animal.weight
result.animal.genetics.metabolism = 0.25
result.animal.rlGrowth.weightKg = 999
check("source: capture never shares caller physiology, genetics or history", record.animal.weight == originalWeight
    and record.animal.rlGrowth.weightKg == originalWeight and record.animal.genetics.metabolism == 1)
local random, ensure, sanitize = math.random, RLGrowth.ensureState, RLGrowth.sanitizeState
math.random = function() error("no redraw") end
RLGrowth.ensureState = function() error("no migration") end
RLGrowth.sanitizeState = function() error("no repair") end
local restored = assert(S.restore(record, resolver))
math.random, RLGrowth.ensureState, RLGrowth.sanitizeState = random, ensure, sanitize
check("source: strict restore preserves exact kg and adaptation without migration or redraw",
    restored.animal.weight == originalWeight and restored.animal.rlGrowth.reserveMassKg == record.animal.rlGrowth.reserveMassKg
    and restored.animal.rlGrowth.feedAdapted == record.animal.rlGrowth.feedAdapted and restored.animal.rlHistoryReplay == true)
restored.animal.rlGrowth.reserveMassKg = 0
check("source: restored state and persisted record have independent ownership", record.animal.rlGrowth.reserveMassKg > 0)
local target = { getSubType = function() return seed.subType end, uniqueId = 42 }
local payload = assert(S.prepareHandoff(record, target))
check("handoff: exact mass survives prepared transfer and historical ticks never claim live hours",
    payload.weight == originalWeight and payload.rlGrowth.weightKg == originalWeight and payload.rlGrowth.lastTick == -1
    and payload.bodyCondition.lastTick == -1 and payload.rlHistoryReplay == nil and target.weight == nil and target.uniqueId == 42)
local completed = assert(S.prepareHandoff(record, target, 77))
check("handoff: explicit completed live tick only deduplicates growth, not historical milk",
    completed.rlGrowth.lastTick == 77 and completed.bodyCondition.lastTick == -1)
local bad, failure
for _, patch in ipairs({
    function(x) x.version = 999 end,
    function(x) x.recipe.version = 999 end,
    function(x) x.animal.rlGrowth.source = "derived" end,
    function(x) x.animal.rlGrowth.legacyAnchor = 500 end,
    function(x) x.animal.weight = x.animal.weight + 0.0005 end,
    function(x) x.cursorMonths = x.cursorMonths + 0.01 end,
    function(x) x.animal.genetics.health = 0 / 0 end,
    function(x) x.animal.rlGrowth.feedAdapted = 1.1 end,
    function(x) x.animal.bodyCondition.reserve = 0 end,
}) do
    local changed = clone(record); patch(changed)
    local ok = S.validate(changed)
    check("source: corruption rejects without changing original record", not ok and record.animal.weight == originalWeight)
end
local cyclic = clone(record); cyclic.extra = cyclic
check("source: cycles and executable payloads fail closed before copying", not S.validate(cyclic))
local executable = clone(record); executable.extra = function() end
check("source: persistence records contain data only", not S.validate(executable))
bad, failure = S.restore(record, function() return nil end)
check("source: missing subtype remains a recoverable refusal without remapping", bad == nil and failure.reason == "SOURCE_SUBTYPE")
bad, failure = S.advanceCursor(record, assert(S.restore(record, resolver)), 99)
check("cursor: time rewind rejects atomically", bad == nil and failure.reason == "SOURCE_CURSOR_REWIND" and record.cursorMonths == 100.25)
bad, failure = S.advanceCursor(record, assert(S.restore(record, resolver)), 100.5)
check("cursor: clock cannot move without equal physiology advancement", bad == nil and failure.reason == "SOURCE_CURSOR_DELTA")
local repeatResult = assert(S.restore(record, resolver))
local same = assert(S.advanceCursor(record, repeatResult, record.cursorMonths))
check("cursor: idempotent checkpoint retains exact birth origin and mass", same.cursorMonths == record.cursorMonths and same.animal.weight == originalWeight)
local entry = { breedingWeightRatio = 0.55, profile = { minRecoveryMonth = 3 } }
local pregnantHistory = Sim.history(seed, 20.25, "NORMAL_PRODUCTION", { { kind = "CONCEPTION", atMonths = 17.125, parity = 1 } })
local pregnant = assert(R.run(seed, pregnantHistory, { daysPerMonth = 1, entry = entry, pregnancySubTypes = { [4] = { seed.subType } } }))
local mother = assert(S.capture(pregnant, 200))
local restoredMother = assert(S.restore(mother, resolver))
check("source: selected fetal physiology persists independently of unborn identities",
    restoredMother.animal.isPregnant and restoredMother.animal.rlGrowth.gravidKg == mother.animal.rlGrowth.gravidKg
    and restoredMother.fetalSelections[4][1].subType == seed.subType.name)
bad, failure = S.prepareHandoff(mother, target)
check("handoff: pregnancy cannot transfer physiological proxies as real offspring", bad == nil and failure.reason == "HANDOFF_OFFSPRING")
target.pregnancy = { duration = 10, pregnancies = { { uniqueId = 88, getSubType = function() return seed.subType end } } }
local damPayload = assert(S.prepareHandoff(mother, target))
check("handoff: prepared real offspring stay transaction-owned and carried mass never doubles",
    damPayload.weight == mother.animal.weight and damPayload.rlGrowth.gravidKg == mother.animal.rlGrowth.gravidKg
    and damPayload.pregnancy == nil and target.pregnancy.pregnancies[1].uniqueId == 88)
local absent = clone(mother); absent.conceptionSnapshots[4] = nil
check("source: past mating evidence cannot be discarded on save", not S.validate(absent))
-- Real incremental advancement, followed by save/restore, is equivalent to the hourly
-- reference. The birth factory is disabled during resume to catch hidden full replays.
local base = assert(S.restore(record, resolver))
local birthFactory = RLGrowth.createBirthState
RLGrowth.createBirthState = function() error("incremental progression may not restart birth") end
local continued = assert(R.resume(base, 9.25, { daysPerMonth = 3 }))
RLGrowth.createBirthState = birthFactory
local progressed = assert(S.advanceCursor(record, continued, record.cursorMonths + 0.75))
local final = assert(S.restore(progressed, resolver))
local reference = assert(R.run(seed, Sim.history(seed, 9.25), { daysPerMonth = { 1,1,1,1,1,1,1,1,3,3 } }))
check("cursor: resume only integrates new hours and preserves exact birth-origin cursor",
    continued.advancedSteps == 54 and progressed.birthOriginMonths == record.birthOriginMonths
    and progressed.history.saleAgeMonths == 8.5 and final.state.health == 100 and final.state.birthCount == 0)
check("source: incremental save/restore equals mixed-month hourly reference below handoff tolerance",
    math.abs(final.animal.weight - reference.animal.weight) <= S.HANDOFF_TOLERANCE_KG
    and math.abs(final.animal.rlGrowth.reserveMassKg - reference.animal.rlGrowth.reserveMassKg) <= S.HANDOFF_TOLERANCE_KG)
local changedOrigin = clone(continued); changedOrigin.history.events[1].context.damBreed = "edited"
bad, failure = S.advanceCursor(record, changedOrigin, record.cursorMonths + 0.75)
check("cursor: advancing physiology cannot rewrite immutable birth/history provenance", bad == nil and failure.reason == "SOURCE_PROVENANCE")
local badSession = clone(record); badSession.session.timeMonths = badSession.ageMonths + 0.25
check("source: saved replay session cannot disagree with authoritative physiology cursor", not S.validate(badSession))
local profiles, matrixPass, matrixCount, maxDifference = {}, true, 0, 0
-- Cattle profiles only (the file also holds SHEEP:<breed> curves since sheep S4; the dealer is cattle-only).
for name, profile in pairs(RLGrowth.getConfig().profiles) do
    if profile.typeName == nil or profile.typeName == "COW" then profiles[#profiles + 1] = name end
end
table.sort(profiles)
for _, profile in ipairs(profiles) do
    for _, sex in ipairs({ "female", "male" }) do
        for _, gene in ipairs({ 0.25, 1, 1.75 }) do
            for _, days in ipairs({ 1, 3, 7 }) do
                local probe = Sim.seed(profile, sex, gene)
                local first = assert(R.run(probe, Sim.history(probe, 6.25), { daysPerMonth = days }))
                local saved = assert(S.capture(first, 100))
                local moved = assert(R.resume(assert(S.restore(saved, resolver)), 6.5, { daysPerMonth = days }))
                local checkpoint = assert(S.advanceCursor(saved, moved, 100.25))
                local loaded = assert(S.restore(checkpoint, resolver))
                local full = assert(R.run(probe, Sim.history(probe, 6.5), { daysPerMonth = days }))
                local destination = { getSubType = function() return probe.subType end }
                local transfer = assert(S.prepareHandoff(checkpoint, destination))
                local difference = math.abs(loaded.animal.weight - full.animal.weight)
                maxDifference = math.max(maxDifference, difference)
                matrixCount = matrixCount + 1
                matrixPass = matrixPass and difference <= 0.001 and transfer.weight == loaded.animal.weight
                    and transfer.rlGrowth.reserveMassKg == loaded.animal.rlGrowth.reserveMassKg
                    and checkpoint.animal.genetics.metabolism == gene and checkpoint.history.events[1].weightKg == first.state.birthWeightKg
            end
        end
    end
end
check("source: 22 breeds x sexes x gene extremes x 1/3/7-day save/resume/handoff matrix (max kg=" .. maxDifference .. ")",
    matrixCount == 396 and matrixPass)
