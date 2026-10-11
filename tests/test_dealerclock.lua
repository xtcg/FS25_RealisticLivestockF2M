loadMod("scripts/dealer/RLDealerClock.lua")
local C = RLDealerClock
local c = assert(C.new())
check("dealer clock: actual 1/3/7 day segments accumulate monotonic months", C.advanceSegments(c, {
    { hours = 24, daysPerMonth = 1 }, { hours = 72, daysPerMonth = 3 }, { hours = 168, daysPerMonth = 7 } }) == 3)
local at, missed = C.checkpoint(c)
check("dealer clock: fastforward offers latest checkpoint once without expired batches", at == 3 and missed == 11 and C.checkpoint(c) == nil)
C.advanceHours(c, 5, 1)
check("dealer clock: replenishment waits for quarter-month checkpoint", C.checkpoint(c) == nil)
C.advanceHours(c, 1, 1)
check("dealer clock: exact checkpoint fires", C.checkpoint(c) == 3.25)
local before = c.months
check("dealer clock: invalid segment rolls back whole interval", not C.advanceSegments(c, {
    { hours = 12, daysPerMonth = 1 }, { hours = 12, daysPerMonth = 0 } }) and c.months == before)
check("dealer clock: invalid and reverse time rejected", not C.advanceHours(c, -1, 1) and not C.advanceHours(c, 0/0, 1) and not C.new(-1))
local saved = C.export(c); local restored = assert(C.restore(saved)); saved.months = 999
check("dealer clock: roundtrip persists consumed checkpoints independently", restored.months == before and C.checkpoint(restored) == nil)
check("dealer clock: future checkpoint corrupt save rejected", not C.restore({ version = 1, months = 1, lastCheckpoint = 5 }))

check("dealer clock: sparse or keyed segments cannot silently lose elapsed time", not C.advanceSegments(c,{[2]={hours=24,daysPerMonth=1}}) and not C.advanceSegments(c,{bogus={hours=24,daysPerMonth=1}}) and c.months == before)
