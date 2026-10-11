# D3-4/5 source cursor and strict handoff progress

Recorded 2026-10-11. Owner: source-state fork. Shared tree: `feat/dealer-history-v2`.
This module does not open the live v2 channel.

## Delivered API

`scripts/dealer/RLDealerSourceState.lua`, source schema version 1:

- `capture(replayResult, cursorMonths)` creates a fresh portable server-owned record. The
  authoritative continuous source clock is anchored by `birthOriginMonths = cursor - age`.
  No random draw, factory, migration, sanitizer, state backfill, or physiology is performed.
- `validate(record)` rejects unsupported schema/replay/template/recipe/growth versions,
  nonfinite numbers, executable/cyclic/metatable data, cursor disagreement, outside weight
  edits, derived/anchored states, live ticks, invalid genes, invalid feed mass/energy ledger,
  missing past-conception snapshots/fetal selections, pregnancy and parity disagreement,
  inconsistent body-condition reserve, or an inconsistent saved replay session.
- `restore(record, resolveSubType)` returns an independent detached replay result. The
  resolver must return the exact saved name/breed/sex/type with physical model coverage;
  missing breeds are refusals, never aliases/remaps. Rechecks the genetic frame and
  development bounds; selected fetal contexts rebuild physiological proxies only.
  Existing gravid mass must match the model within 0.001 kg. No births are drawn again.
- `advanceCursor(record, advancedReplayResult, cursorMonths)` accepts an already advanced
  result, requiring monotonic cursor and equal continuous animal-age advancement. Existing
  history, recipe, birth/frame values, genes, and all prior mating/fetal evidence stay
  immutable. A repeated cursor accepts only an equal checkpoint. Failed updates leave the
  prior record untouched. No restart-from-birth progression exists in this module.
- `prepareHandoff(record, targetAnimal, completedLiveTick?)` returns detached field data
  for an authoritative transaction; it does not mutate either side, allocate animal IDs,
  move stock, charge money, or commit. Live growth tick defaults to `-1`; it is assigned
  only when the caller explicitly establishes that live hour has already been completed.
  Historical milk never claims paid live milk: condition tick stays `-1`. Weight/reserve,
  development, feed adaptation, health carry, smoothed feed gain and lactation inputs copy
  exactly. Cached curves and the historical marker do not enter the target.

Records retain birth context in the original history, source/evidence, the chosen recipe
and its version, genes, physiological and health state, conception snapshots, selected
fetal subtype contexts, cumulative feed/milk and mass/energy ledger, step count, eligibility,
and replay session. Portable records are **server-owned persistence data**, not signed or
trusted client requests. The persistence layer is responsible for integrity/ownership.

Pregnant transfer requires the transaction to prepare real unborn animals first, with exact
selected subtype sequence, gestation duration, and stable unique IDs. Physiological proxies
from detached replay cannot become real offspring. The returned handoff payload deliberately
omits pregnancy ownership; the transaction retains its prepared `target.pregnancy`. No
fetal mass is added again. Unpregnant records reject a destination carrying pregnancy.

## Verification

Focused source tests cover strict round trips, independent ownership, data-only persistence,
corruption rejection, refused rewind/unadvanced cursor, idempotent checkpoint, exact handoff,
live-hour/milk tick separation, missing subtype, fetal contexts and unborn identity gates.

Integration with `RLDealerReplay.resume` disables the birth factory while advancing
8.5 to 9.25 months, confirms exactly 54 new hourly steps under three-day months, saves and
restores again, and compares mixed one-/three-day-month reference weight to <=0.001 kg.
The original history retains its 8.5-month sale event after source progression.

A 396-case matrix covers 22 physical profiles x both sexes x metabolism 0.25/1/1.75 x
one-/three-/seven-day months. Each run captures at 6.25 months, restores, resumes to 6.5,
advances the source cursor, restores and prepares handoff; compares against the complete
hourly reference and retains exact selected birth and genes. Synthetic pack/map subtypes
borrow the existing simulator's food/milk engine curves; this is not installed-map proof.

## Remaining live gates

A portable snapshot is not a game save adapter or atomic purchase. Source-controller game
clock ownership, installed-map exact subtype resolution, persistence integrity/quarantine,
real source-stock reproduction, real prepared unborn identities, destination installation,
transaction compensation/recovery, save interruption, network precision and multiplayer
race checks must be supplied by their respective layers. At source pregnancy term, detached
resume refuses rather than inventing a calving; normal source reproduction remains needed.
Full v2 remains closed. No existing player state migration or D2 legacy route is altered.

Final verification for this sub-batch: **30/30 focused checks pass**, including all 396
matrix cases; the matrix's maximum weight difference from the hourly reference is exactly
**0 kg**. Lua 5.1 parser accepts the module and its test file. `git diff --check` passes
for the owned paths. Main loader integration and the full shared regression are owned by
the coordinating fork; no commit was made by this fork.

## Actual Animal handoff installation adapter

`scripts/dealer/RLDealerHandoff.lua` provides `install(record, preparedTarget, context)` and
single-use in-memory `rollback(receipt)`. The target must be a real individual Animal with
stable identity and an already prepared birthday. The adapter rejects clients, detached
replay animals, missing identities/dates, subtype/model mismatches and incomplete real
unborn contexts before its first write. Exact physiology installs without calling migration,
new-animal construction, random genetics/birthday selection, or external setter callbacks.
Identity, local registry indices, birthday, cluster and pregnancy ownership, lineage, names,
marks and other presentation fields remain target-owned. The transaction publishes cluster
dirty state only at commit; installation sets the animal's own dirty flag.

The explicit whitelist includes nil-valued physiology so old target values cannot leak.
All historical, growth-curve, feed-step owner/time, feed-intake/plan, milk-paid/forecast,
nutrition and info caches are explicitly cleared. A repeated live growth tick alone does
not deduplicate `RLFeed.stepAnimal`; real feed uses `rlFeedStepTick/rlFeedStepOwner` instead.
For the ordinary historical purchase no current tick is assigned. An exceptional already
settled real live hour requires BOTH `completedLiveTick == current tick` and explicit
`liveHourAlreadySettled = true`; the adapter then marks growth and real-feed deduplication,
plus a settled zero-additional-milk record, so that hour cannot budget or deposit twice.
That explicit settlement path must never be inferred from historical/source month time.

Compensation restores exact previous field references before publication and refuses if
identity/ownership or installed physiology changed. The receipt is not durable recovery;
the authoritative transaction must journal its own prepared identity and state stages.

**19/19 handoff checks pass**, using the actual `Animal.new` constructor with a negative-age
shell, explicit selected genes/IDs and prepared birthday. Engine input/output surface hooks
are supplied by the simulator. Tests include exact installation, old-cache clearing,
refused mutation, pregnancy ownership, compensation conflict guards, and actual live-feed
progression: default historical handoff advances the first hour by 1/24 month, a settled
transfer skips its same hour, and the next hour advances normally.

Actual integration seams: construct the target without random/derived history; assign the
selected calendar birth date and stable animal/unborn identities in the prepared transaction;
validate destination and eligibility; invoke installation before attaching/publishing;
keep source and destination identities in durable stage records; mark cluster dirty only
at commit; use durable compensation on interruption. Installed-map/stream precision and
save-recovery evidence remain release gates.

## Actual source birth service and observed-state bridge

`scripts/dealer/RLDealerSourceReproduction.lua` owns a private source cluster/spec, never a
player pen or ordinary dealer pool. `createOwner` requires already prepared real animals;
`pinSire` retains the server's already selected sire context (including deceased/absent
sires). `execute` requires real unborn identities/farms/genes, exact physical subtype
coverage, sufficient private source capacity, valid term physiology and explicit durable
`persistPrepared`/`persistCommitted` callbacks. No identities, genes or fetus types are
selected by this service. An optional `expectedFetalContexts` preflight checks the exact
historical physical fetal contexts before any birth RNG.

`AnimalReproduction.SOURCE_BIRTH_VERSION = 1` and an optional seventh `sourceContext`
argument share the actual normal `reproduce` body. Nil context preserves existing normal
ownership behavior. The source mode validates server/private source ownership before
mutation, preserves preallocated unborn identities and source country, and bypasses player
sire lookup, player stats, sale pricing/pool insertion, broadcast, UI messages and player
death handling. Draws, survival, birth initialization, parity, lactation and maternal
mortality remain the normal reproduction code's sole responsibility. Source mode records
each actual weight/z/mean draw, including infants that die. The ordinary mode's inherited
negative `animalsToSell` accounting after infant mortality is left unchanged; source mode
keeps its explicit zero-sale contract.

PREPARED persistence precedes RNG; unknown prepare/birth/commit outcomes quarantine the
source and never reroll on retry. COMMITTED request replay returns the existing result.
Source capacity failure occurs before RNG/parity/mutation. Surviving real offspring remain
with the private source; pregnancy/gravid clears once while maternal tissue/reserve remain
unchanged. Dead offspring never queue; maternal mortality stays source-owned.

`RLDealerReplay.runToSourceBirth` permits only the exact known gestation-term endpoint.
Ordinary `resume` still refuses term/cross-term with `SOURCE_CALVING_REQUIRED`. The pending
endpoint has reproduction 100 and cannot pass ordinary SourceState capture. No epsilon
interval is dropped and no historical CALVING event is fabricated.

After the source controller installs the already integrated pending endpoint into its real
source dam and `execute` commits the actual birth, `captureObserved` consumes that pending
result, the same true source dam and its COMMITTED journal. It verifies exact term, parity,
maternal mass and selected fetal types, then appends a separate
`observedSourceEvents = { version = 1, events = ... }` field through strict `advanceCursor`.
Original MODEL_ASSUMED history, sale age and past mating snapshots remain immutable.
Observed events retain actual newborn identities/weights, normal draw evidence and maternal
mortality. `getSourceLifecycle` validates both ledgers; SourceState persistence and detached
resume then retain actual parity, cleared pregnancy, fresh lactation and continued feeding.
Observed deaths persist for diagnosis but reject handoff and further feeding.

Current observation schema permits the existing pregnancy's one actual post-sale calving.
It does not invent later source conceptions or newborn assumed histories. Future real
source conception and newborn-source enrollment need their own recorded contexts.

Focused source birth/bridge tests pass **22/22**, including surviving twins, infant and
maternal death, exact draw count, idempotence, insufficient capacity, prepare/commit save
fault quarantine, unauthorized shared entry, exact gestation endpoint, separate observed
persistence, postbirth save/restore + feeding, and rejection of forged evidence/newborn
mass. Together with existing birth-path and handoff suites this targeted run passes
**81/81**. Full source roundtrip matrix and coordinating full regression are recorded by
the coordinating fork. Tests execute the actual complete reproduction function; GIANTS
`continue` becomes `break` only for stock-Lua parsing, with equivalent semantics for the
one-child mortality path tested here. Surviving twins do not exercise that replacement.

Release remains closed: source-clock integration must stage real source physiology, persist
actual inventory and the durable birth journal together, preserve fetus preparation across
save/load, adopt newborns as source-owned states, and remove source mortality explicitly.
This service does not substitute callbacks for an implemented engine save adapter. Network,
installed-map, interruption recovery and multiplayer transaction evidence remain required.

Coordinator integration: `RLDealerSourceOwnership` now preserves true adult/unborn objects,
source herd IDs, pinned sires, disease model records and complete birth journals through
strict independent serialization (15 focused checks). `RLDealerOwnedStock` couples those
objects to historical source records and independent `OBSERVED_NEWBORN_REARING` child
records; this envelope is carried by the dealer checkpoint and optional WAL recovery
payload. Source-only physiological progression/publication explicitly rejects owned stores
until the complete calendar/birth controller is installed. The real source adapter now
supports exact batch detachment and conservative original-object compensation; reload of
an already removed batch remains a reconciliation gate. No source object is regenerated
from a receipt and no incomplete money compensation is accepted as a complete rollback.

Continuation after `5aa6fc0`: the owned calving controller now stages feeding to real
gestation terms, persists each PREPARED before normal birth RNG, refreshes maternal
observations and enrolls actual surviving children before COMMITTED, then feeds the
remaining calendar interval. Same-cursor dams are processed deterministically; intermediate
old cursors force recovery isolation. Unknown barriers preserve before/actual-stage/attempted
plain evidence and cannot redraw on retry. Explicit retired-source records keep dead maternal
identity and committed proof while active calves continue feeding. Whole checkpoint and
verified restore now retain retired ownership. The first full regression passes 3447/3447;
the implementation baseline records subsequent hour-segment boundary checks. No runtime
generation/calendar hook or full v2 release is enabled by this dormant composition.

Final 2026-10-12 verification: exact-term arrays of individual hourly segments on 1/3/7-day
calendars, early-by-one-hour refusal, zero elapsed no-op, transient purchase locks and
foreign callback mutations are covered. Birth continuation 40/40, owned rearing 25/25,
retirement 13/13; complete regression 3464/3464. All 39 dealer/loader files parse Lua 5.1.
Log: `/private/tmp/rlrm-dealer-owned-birth-verified-tests.log`.
