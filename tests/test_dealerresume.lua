loadMod("tests/dealerreplaysim.lua")
local R, Sim = RLDealerReplay, DealerReplaySim
local seed = Sim.seed("HOLSTEIN", "female", 1)
local base = assert(R.run(seed, Sim.history(seed, 8.5), { daysPerMonth = 3 }))
local weight, reserve, steps = base.animal.weight, base.animal.rlGrowth.reserveMassKg, base.steps
local same = assert(R.resume(base, 8.5, { daysPerMonth = 3 }))
check("resume: same cursor is a detached zero-step snapshot", same.advancedSteps == 0 and same.steps == steps
    and same.animal ~= base.animal and same.animal.rlGrowth ~= base.animal.rlGrowth and same.animal.weight == weight)
local moved = assert(R.resume(base, 9.25, { daysPerMonth = 3 }))
local reference = assert(R.run(seed, Sim.history(seed, 9.25), { daysPerMonth = 3 }))
check("resume: ledger and physiology equal uninterrupted hourly reference", moved.advancedSteps == 54
    and moved.steps == reference.steps and moved.animal.weight == reference.animal.weight
    and moved.ledger.feedMe == reference.ledger.feedMe and moved.ledger.milkLiters == reference.ledger.milkLiters)
local rejected, why = R.resume(base, 8.25, { daysPerMonth = 3 })
check("resume: rewind never changes source", rejected == nil and why.reason == "SOURCE_INTERVAL"
    or rejected == nil and why.reason == "SOURCE_STATE")
rejected, why = R.resume(base, 8.75, { daysPerMonth = 0 })
check("resume: invalid calendar rejects without partially feeding original", rejected == nil and why.reason == "MONTH_LENGTH"
    and base.animal.weight == weight and base.animal.rlGrowth.reserveMassKg == reserve and base.steps == steps)
local history = Sim.history(seed, 20.25, "NORMAL_PRODUCTION", { { kind = "CONCEPTION", atMonths = 17.125, parity = 1 } })
local options = { daysPerMonth = 1, entry = { breedingWeightRatio = 0.55, profile = { minRecoveryMonth = 3 } },
    pregnancySubTypes = { [4] = { seed.subType } } }
local pregnant = assert(R.run(seed, history, options))
local mid = assert(R.resume(pregnant, 21.5, options))
check("resume: active pregnancy carries its selected physiology across increments", mid.animal.isPregnant
    and mid.animal.reproduction == 43.75 and mid.session.conceptionMonths == 17.125
    and mid.fetalSelections[4][1].subType == seed.subType.name and pregnant.animal.reproduction == 31.25)
local before = mid.animal.weight
rejected, why = R.resume(mid, 27.125, options)
check("resume: source calving requires normal offspring ownership before any integration", rejected == nil
    and why.reason == "SOURCE_CALVING_REQUIRED" and why.atMonths == 27.125
    and mid.animal.weight == before and mid.animal.isPregnant and mid.animal.birthCount == 0)
local old = base.steps; base.steps = math.huge
rejected, why = R.resume(base, 9, options); base.steps = old
check("resume: invalid step cursor fails closed", rejected == nil and why.reason == "SOURCE_STATE")
check("resume: malformed screening result refuses cleanly", not R.screen({ animal = {}, history = {} }))
