# Dealer D3/D4 implementation baseline

Recorded 2026-10-11. Working branch: `feat/dealer-history-v2`.
Working tree: `/Users/xtcg/Workspace/fs25/rlrm-dealer-v2`.

## Immutable starting points

These are local refs observed at coding start, not a claim that a remote was fetched.

| Input | Actual SHA |
| --- | --- |
| D2 integration / feat/dealer-history | `4a299a73fefd120f8fd8fe7e109d51a84f3001be` |
| Weight core | `a4b150d53b12586ee38af3966007d47aba69eaba` |
| Weight state / rlrm-weight | `709366271df998cd89d1c53cb8c9605de2172c6c` |
| Local birth repair branch | `05818641792f9ad29bbe52e5e26a42f4ac19d453` |
| Remote-tracking birth repair | `75a9c5ebf323308579e5d67a20218b202a01bf15` |
| Local dev | `b892c92de9551d4a48e834df83d2bd464f733c3f` |
| Remote-tracking dev; chosen integration base | `479e885caa2639513356ad415daa744731272bdd` |

D2 is already an ancestor of the chosen dev. The base also contains the weight state,
reviewed birth integration and subsequent feed/gravid/lactation changes. No cherry-picks
from the older core/state branches are needed. Capability checks below, rather than names
or ancestry alone, are the dependency evidence.

## Capability evidence and remaining gates

| Capability | Implementation on integration base | Executable evidence |
| --- | --- | --- |
| Unified birth draw and curves | `RLGrowth.drawBirthWeight`, `RLGrowthCurve`, `RLWeightProfiles` | `test_growth`, `test_weightprofiles`, `test_birth_growth_path` |
| Individual W / B_i / reserve kg / development / intake state | `RLGrowth.newState`, `RLGrowthMath` | `test_growth`, `test_gravid_lactation` |
| Normal player budgets | `RLGrowth.step`, `stepFeed`, `RLFeed.applyStepInput` | `test_growth`, `test_feed`, feed regressions |
| Copy/save/load/stream | `RLGrowth.copyState`, XML and stream adapters, `takeLiveState` | `test_growth`, persistence tests |
| Pregnancy offspring become real v2 newborns | `AnimalReproduction.reproduce` draws once, uses the same z for survival and weight for `initBirth` | `test_birth_growth_path`, `test_birth_path` |
| Historical generation | D3-2 history and D3-3 detached hourly replay/evaluator delivered; **not wired to live generation** | `test_dealerhistory`, `test_dealerreplay`; D3-4/D4 gates remain |
| Dealer feeding and authoritative cursor | Detached source inventory, strict incremental resume and monthly clock delivered; live calendar hook pending | `test_dealerresume`, `test_dealersourcestate`, `test_dealersourcefarm` |
| Authoritative purchase handoff | **Missing**; purchase event still receives animals | D4-3 required |

The inherited regression suite passed 2677/2677 checks after the initial extraction.
The final suite, including the new tests, passed 2689/2689. Both changed/new Lua
files parse as unmodified Lua 5.1. A separate A/B run against immutable base
`479e885` exercised 22 breeds × 2 sexes × 3 genes × 1/3/7-day months over two
months (396 scenarios); weight, reserve, development and age had exactly zero difference.
New factory/input/integrator tests cover 22 physical profiles × 2 sexes × metabolism
0.25/1/1.75, no redraw, separate state tables, invalid birth weights, unknown cattle,
player/explicit-budget equivalence and invalid intervals. This is **not** evidence that
all purposes are historically reachable, or that D3/D4 are ready to release.

## D3-1 delivered interfaces

Interfaces remain on `RLGrowth`, avoiding new global wrappers and load-order dependencies:

- `createBirthState(child, selectedWeight)`: pure factory consuming the normal draw;
  returns a fresh state or a rejection reason. No migration anchor or random draw.
  The birth context must describe a newborn, as in the normal reproduction path.
- `initBirth`: normal births apply the same factory. The reproduction sampler and
  survival decision remain the unique owners of the birth draw.
- `buildBudgetInput(animal, state, supply, dtMonths)`: common physiology plus the
  existing real-feed energy/protein rules. Legacy supply uses energy-adjusted liters
  per month; real-feed supply uses actual ME eaten over the interval.
- `advanceBudget(animal, supply, dtMonths, tick)`: shared preparation, input builder,
  integrator and application. Both player adapters now use it. Invalid time intervals
  reject before mutation. It returns result/input/weight-before/reference; it does not
  own event dispatch, reproduction, disease, age birthday changes or deduplication.

The existing player migration fallback remains available inside the budget adapter.
Historical callers must explicitly use a birth state, validate every step and reject
failed candidates. They must never recover a historical failure with `ensureState`,
`deriveState`, weight clamping or reserve backfill.

## Existing clock and lifecycle ownership (before D3/D4)

| Entry | Current responsibilities | Integration constraint |
| --- | --- | --- |
| `AnimalSystem:onHourChanged` | Dealer eligibility, two-day/genetic rotation and replenishment/broadcast | No existing dealer growth call; keep old rotation until month lifecycle takes ownership |
| `AnimalSystem:onDayChanged` | Dealer `Animal:onDayChanged`, separate disease progression and infection | Daily callback clears `reserved`; replace this before transaction locks are introduced |
| `Animal:onDayChanged` | Birthday age increment, `AnimalReproduction.processDaily`, daily mortality | Do not duplicate these in a new feeding loop |
| `AnimalSystem:onPeriodChanged` / `Animal:onPeriodChanged` | Per-animal period reset | Not the birthday age authority |
| Player `AnimalHealth.updateHealth` | Calls growth hourly in legacy nutrition mode | `lastTick` prevents repeating the same player hour |
| Player `RLFeed` model windows | Real-feed integration, nutrition/health/adaptation and paid milk | `stepFeed` alone is not the entire feeding/health lifecycle |

`RLGrowth.advanceClock` caps the continuous age relative to `animal.age`. Historical
integration must split at whole-month boundaries as well as weaning, conception and
calving, maintaining whole-month age and fresh milk inputs. Passing a multi-month dt
alone loses time. A historical tick must not masquerade as a completed live game hour
when it is transferred to a player.

Live weight on the base already includes `gravidKg`. Preserve this ledger; do not add
another fetus mass. Milk must continue through the existing lactation rule. Distinguish
`reserveMassKg / weightKg` from body condition's `reserve = R / capacityKg`.

## Next reviewable batches and acceptance contract

### D3-2 delivered: assumed history and historical mating gates

`RLDealerHistory` is loaded after the D2 policy, with no live generation call yet.
`build(plan, entry, subType, source, purpose, ctx)` consumes a selected D2 plan,
selected birth weight/context, explicit template id, resolved weaning month and continuous
sale age. It expands prior conceptions/calvings backwards using the configured gestation
and recovery cycle, checks sex/reproduction/purpose/source consistency, and rejects invalid
timelines. It draws no RNG and creates no unborn offspring. Selected values and contexts
are copied, never redrawn. This schedule is one feasible model assumption, not evidence
of actual source-farm events; even RECORDED source labels retain `MODEL_ASSUMED` evidence.
UNSPECIFIED retains its separate UNKNOWN traceability.

History schema version and feeding-template version are independently recorded. The three
template identities are NORMAL_REARING, MODERATE_SLOW_REARING and NORMAL_PRODUCTION.
`feedingAt` exposes continuous PRE_WEANING / WEANING / WEANED stages, the same
`age - weaningMonth` transition coordinate as calf rearing, parity, time since calving and
pregnancy age. These are **uncalibrated feeding descriptors**, not executable rations or
validated energy budgets. D3-3 must resolve their healthy feeding recipes through the real
feed/shared budget and calibrate normal/slow supply; no weight or gene multipliers are
introduced here. `boundaries` includes whole-month birthdays, weaning transitions,
conceptions, calvings and fractional sale time for replay splitting.

`validateConception` requires an exact pre-conception snapshot and explicit breed rules:
minimum age, minimum W / frameTargetKg, minimum development months and reserve mass fraction
bounds. It never reads the legacy price target; gravid mass must be zero. Missing/invalid
rules or snapshots fail closed. `validateMatings` checks every historical conception, with
the failing event index; sale-time qualification cannot replace a failed past mating.
There are no default universal breeding thresholds. D3-3 must combine breed/engine minimum
ages with calibrated breed-specific rules, record snapshots while replaying from the
shared birth factory, and screen genetics before replay or unborn-offspring creation.

Verification: 21 focused checks cover D2 minimum/maximum plans (19 feasible cases over
23–47 months), two previous births plus current pregnancy, recovery conflicts, source and
template separation, copied birth context, male slow rearing without RNG, weaning boundaries,
and separate historical weight/development/reserve failures. Final full suite passes
2710/2710 checks (log: `/private/tmp/rlrm-dealer-d3-2-tests.log`). Lua 5.1 parsing passes
for the module, loader and test file; `git diff --check` passes.
The v2 generation channel remains closed; D3-3 replay, breeding-rule/feeding calibration,
D3-4 progression and D4 purchase/recovery are still required.

### D3-3 delivered: hourly reference replay and dormant candidate evaluation

`RLDealerReplay.run(seed, history, options)` constructs a detached animal from a physical
cattle subtype, screened genetics and the selected birth value via `createBirthState`.
It allocates no identities or real unborn offspring, consumes no RNG, and changes no live
pen, source stock, global clock, money, configuration or listing. Each replay is independent.
Unknown cattle, non-COW stand-ins (including HB MILKCOW), missing health/milk rules,
incompatible weaning rules and unscreened/affected genetics reject explicitly.

`RLGrowth.advanceHistoricalBudget` shares the player preparation, budget input builder,
integrator and result application, but requires a detached birth-origin state with matching
weight, current version and no live tick/legacy anchor. It never calls growth migration,
resync, derivation or sanitisation. Historical continuous age is exact; live age still uses
its existing 0.999 cap. Steps split on the actual month's hourly grid, birthdays, weaning,
conceptions, calvings, lactation transitions and fractional sale time. Each interval uses
the supplied month length, including changes between months. Failed steps/health or
mass/energy ledger errors reject the whole detached candidate; no repair or weight clamp.

Feed is planned with `RLFeed.describeAnimal` and the unchanged pure ration planner, using
existing feed profiles. The same real-feed budget, protein limitation, appetite, calf
allowances, rumen adaptation and health/underweight rules apply. Milk uses the existing
parity and lactation rules. Conception is validated before pregnancy starts. Caller-selected
physical fetal subtypes (at most three) supply the live model's existing pregnancy-mass rule;
cattle/buffalo crossings reject. These are physiological proxies, not unborn animals.
Calving removes carried gravid mass once, preserves tissue/reserve, resets lactation and
increments parity. Chosen fetal contexts are retained separately for traceability.

`getBreedingRules` requires an explicit breed `breedingWeightRatio`: W / **frameTargetKg**,
minimum engine/breed age, and development at the individual reference curve's phase for
that ratio. Reserve fraction bounds are 5–11%. The development gate prevents reserve alone
from qualifying a heifer. Only HOLSTEIN and SWISS_BROWN currently have an explicit ratio in
D2 config. Other breeds' breeding products stay gaps, including historically pregnant/parent
plans; no dairy threshold is silently supplied for beef or buffalo. Experimental rule
overrides on `run` are ignored by `evaluate`.

`evaluate` combines replay, reserve screening and D2 purpose/source/age/clinical eligibility,
replacing only the D2 legacy-price-target weight check with the v2 readiness gate. Its result
is `VERIFIED_CANDIDATE`, not a live sale animal or a purchase payload. Milk-fed/weaning cattle
remain closed (`CALF_RESERVE_UNCALIBRATED`). Existing dealer generation still uses D2 and
LEGACY_WEIGHT until progression, transport and purchase/recovery gates are implemented.
The detached `rlHistoryReplay` marker must never be installed on a live player animal.

Recipe version 1: NORMAL_REARING / NORMAL_PRODUCTION use a GROW ration of FORAGE,
PEA/MAIZE and CALFMILK through the planner's physical limits. MODERATE_SLOW_REARING uses
the same feeds with a 95% physical DM offer ceiling; feed energy/protein values are unchanged,
and supply is never manufactured from a budget deficit. The first hay/15% peas candidate
was rejected: health and reserve passed but development lagged normal by 3.08–7.23 months
at 12.5 months. The final slow candidate's lag is -0.00065–0.29837 months (a few cases are
numerically 0.0125 kg heavier); it need not make every animal grow more slowly when its
physical allowance already covers its needs.

Numerical evidence is retained in `DEALER_D3_3_PROBE_SUMMARY.json`, reproducible with
`python tests/dealer_replay_report.py /private/tmp/dealer-d3-3-calibration.json`:

- Two recipes × 22 physical profiles × two sexes × genes 0.25/1/1.75 × 1/3/7-day months:
  792/792 complete at 12.5 months and pass reserve screening; minimum health 100.
- Reserve mass fractions 0.09–0.107844. Maximum energy error 2.85e-14 and mass error 1.55e-13.
- 26 focused checks include a 132-case birth replay matrix, changing month lengths,
  fractional conception/calving, past-mating failure, missing physiology/fetal contexts,
  invalid supply/state rejection, candidate readiness and template tampering.
- Live-growth A/B against immutable D3-2 `fec8ce1` over 396 scenarios (22 profiles ×
  two sexes × three genes × 1/3/7-day months, two months each): weight, reserve,
  development and age differences are exactly zero.

The probes borrow base engine food/milk curves for synthetic pack/map subtypes. They establish
physical-model behavior, **not** installed-map, offspring selection or transaction coverage.
Templates remain marked uncalibrated for release; the numeric candidate recipes are not farm
measurements or a blanket breeding approval. No replay optimisation or cross-candidate state
cache is introduced. Future optimisations must match this hourly reference to ≤0.1 kg.
Final full suite passes **2736/2736** checks
(`/private/tmp/rlrm-dealer-d3-3-tests.log`). All five new/changed Lua files parse as Lua 5.1;
`git diff --check` passes. Live integration and release gates remain D3-4/5 and D4 below.

D3-4/5: source-farm feeding, cursor persistence, state handoff, rejection diagnostics and
configuration gates. Verify 22 breeds, both sexes, gene extremes and applicable purposes;
reject a plan whose past mating failed even if current weight qualifies. Non-cattle retain
D2 and LEGACY_WEIGHT; HB special types keep explicit compatibility paths; unknown cattle
remain gaps. A rearing source does not prove v2 coverage.

D4-1/2: a separate listing registry with stable saleId and
DRAFT → LISTED → RESERVED → SOLD / LISTED → WITHDRAWN plus quarantine. This is distinct
from the existing `RLDealerSaleRegistry` configuration-override registry. Save
listedAtMonths/lastUpdatedAtMonths/expiresAtMonths/recordRevision. Accumulate monotonic
months using each interval's actual month length. Check empty slots every 0.25 months;
fast-forward must not replay all expired batches. Lifetimes: unweaned cattle 0.5,
growing/store/replacement cattle 1, breeding/production cattle 2, short-cycle pig/bird/rabbit
0.5, horse 2 months. External buyer lambda stays 0. Eligibility withdrawal is immediate
after progression and before purchase, replenishment only at the next checkpoint; no
purpose relisting. One record uses exactly one rotation mechanism. Stock calving uses the
normal reproduction path once; dam and offspring remain with the source farm.

D4-3: server-only batch transaction using requestId + saleIds + revisions + destination +
quote credential. Validate permissions, duplicates, sorted locks, current physiology,
eligibility/model/destination/capacity/funds, quote freshness, prepared transfer and
compensation before commit. Batch all-or-nothing. Replays return the existing result;
short-lock timeout uses monotonic real time. Reuse checkpoint/recovery mechanisms only
after verifying dealer-specific ownership and compensation. `RLTradeTransaction.begin`
currently accepts only CONTRACT/SALE; it cannot simply be passed a dealer operation.
`RLTradePersistence` supplies canonical serialization/integrity, not proof of ownership
or an automatically atomic dealer purchase. Persist stages and stable identities for
save-interruption recovery; pcall and in-memory locks alone are insufficient.

D4-4: stock-only migration classifies valid, hard-invalid, unreliable-v2 and
missing-mod/unknown/corrupt records. Retain recoverable quarantine data; never redraw an
old birth/history or silently remap a breed. Persist migration version for idempotence;
first load only migrates, does not reroll the pool. Player migration belongs to weight
code. Keep configuration, listing schema, weight, protocol and template versions separate.

D4-5: multiplayer and UI show purpose/source/parity/weaning/production and useful refusal
reasons; technical model versions stay in diagnostics. Reads/quotes/pages never advance
physiology or consume generation RNG. Verify two-client races, replay, stale quotes,
capacity/funds failures, target/money/checkpoint fault injection, save recovery and missing
mods. State continuity through listing/purchase/transfer/save/network must meet ≤0.001 kg.
Test 1/3/7-day months and changing month length mid-run. Game validation must include
normal cattle, aliases, buffalo, pregnant dams, multiplayer purchase and save recovery.

Full-v2 dealer generation remains closed until history, listing progression, compatible
state transport and authoritative purchase/recovery are all ready. This batch retains
D2's LEGACY_WEIGHT declaration and existing configuration/protocol versions. No new price
model; long-term growth/economics balance remains D5.

## Continuation checkpoint: D3-4/5 and D4 core integration

The user explicitly authorized uninterrupted implementation and parallel development.
The primary agent owns integration, main/core hooks and this baseline; source-state,
listing/checkpoint and purchase/protocol agents own their named modules and progress files.
Further work continues after this checkpoint; these are internal interfaces, not a release.

`RLDealerReplay.resume` clones the existing physiological ledger and integrates only the
new interval. It never invokes the birth factory, repeats old feeding or changes the assumed
history. It carries cumulative feed/milk/error ledgers, pre-conception snapshots and selected
fetal contexts. Ordinary resume rejects a source birth before any integration with
`SOURCE_CALVING_REQUIRED`; actual source reproduction is a separate required owner.

`RLDealerSourceState` validates portable snapshots, exact model/birth/genetics provenance,
continuous source cursor and immutable birth origin. Restore resolves installed subtypes
without repair/remap/redraw. `RLDealerSourceFarm` stages all sources and actual-calendar
segments together; a failed source, missing subtype, bad calendar or due birth leaves all
sources and the authoritative clock unchanged. It does not delete a source when its listing
is withdrawn. `RLDealerHandoff` installs into a prepared real Animal while preserving its
identity, birthday, cluster and real unborn identities, explicitly clearing historical and
hour caches. Its rollback receipt is in-memory preparation compensation, not durable proof.
An explicitly settled live hour requires both growth and real-feed/milk deduplication;
historical time never supplies that evidence.

`RLDealerClock` accumulates each segment's actual month length and requests at most the latest
quarter-month replenishment. `RLDealerListingRegistry` owns stable identities, fixed-purpose
lifetimes, revisions, separate physiological and lock timestamps, monotonic real-time leases,
withdrawal/quarantine and stock-only idempotent migration. Restored reservations retain
recovery ownership rather than trusting a previous process's monotonic clock.

Evidence: 30 source-state checks include a 396-case save→restore→incremental growth→handoff
matrix (22 profiles × sexes × gene extremes × 1/3/7-day months), maximum weight difference
exactly 0 kg. Handoff tests exercise real Animal and player feed update paths; first live-hour
growth advances exactly once. Incremental pregnancy, no-op, rollback, mixed-calendar source
inventory, lifecycle/clock and corruption checks pass. The intermediate full suite passed
**2978/2978** (`/private/tmp/rlrm-dealer-d3-4-tests.log`); new work remains subject to another
integration run. Lua 5.1 parsing passes for integrated source/lifecycle modules.

Next integration work is recorded in `DEALER_SOURCE_STATE_PROGRESS.md`,
`DEALER_LISTING_PROGRESS.md` and `DEALER_PURCHASE_PROGRESS.md`: source-owned real births,
checkpoint game hooks, dealer ownership adapter, protocol/quote/UI wiring and game validation.
The purchase journal is separate from T02 CONTRACT/SALE. Normal career saves complete
asynchronously and cannot satisfy a synchronous transaction checkpoint by assertion.
Independent journal stages plus coordinated stock/placeables/vehicles/farms/career evidence
must reconcile ownership; a journal ahead of saved assets requires rechecking even terminal
records. Full v2 remains closed, non-cattle retain D2 and the price model remains unchanged.

### D4 integrated dormant server core

The source/lifecycle baseline is committed as `e91246c`. The next integrated core includes:

- `RLDealerStockService`: verified candidate publication and fixed-purpose lifetimes;
  source feeding before current eligibility; withdrawn sources keep growing; transactions
  block source mutation; reads do not progress or regenerate anything.
- `RLDealerPurchase`: sorted batch locks, idempotent requests, durable PREPARED/APPLYING
  boundaries, pre-effect authority revalidation and bound terminal receipts. A receipt
  must match token, amount, transfer IDs and complete source/target/money evidence.
- Independent purchase and quote protocols/events, volatile server quotes and a client
  QUOTE→CONFIRM→PURCHASE helper. Only stable IDs/revisions/destination/credential cross
  the purchase request. Server amounts are confirmed after quote; late responses and
  confirmation callbacks cannot settle a different request. These endpoints remain disabled.
- `RLDealerPersistence`, `RLDealerCheckpoint` and `RLDealerJournal`: independent stock
  document, synchronous WAL readback barrier and actual engine save hooks. Participant
  markers and byte digests come from placeables/vehicles/farms; career commit binds the
  dealer snapshot and that external set. READY requires final disk readback after engine
  completion, not merely the synchronous XML construction pass. Identity repair, mixed
  generations, corrupt files, failed hooks and overlapping saves close the gate.
- `RLDealerRuntime`: reset and load hooks wired into map lifecycle; no automatic arming,
  generation, source progression, asset mutation or money recovery. Existing saved evidence
  is resolved by subtype name and checked; a WAL differing from the coordinated asset
  snapshot forces ownership reconciliation even for terminal records.

The full suite with the integrated loader/map hooks passed **3188/3188** checks
(`/private/tmp/rlrm-dealer-d4-core-tests.log`). This includes mock faults and checked-in
FS25 save-pass excerpts; it is not an installed-game multiplayer/save-recovery run.
The actual target cluster and money adapters, real source identity persistence, newborn
feeding, full ownership coordination and UI listing route remain work in progress.
Ordinary `addMoney` refund also changes positive-income statistics; a balance-only refund
cannot be accepted as complete business compensation. No release flag bypasses that gate.

### D3-5 real source births and D4 ownership evidence

The dormant core is committed as `fd4882c`. The subsequent batch adds actual source
ownership without enrolling those objects in the legacy dealer pool or opening v2:

- `RLDealerSourceReproduction` calls the ordinary reproduction sampler through an
  explicit private-source context. PREPARED precedes RNG, true fetal identities survive,
  and COMMITTED records retain actual draws, newborn survival and maternal mortality.
  Unknown outcomes quarantine; retries never redraw. A separate observed ledger bridges
  exact gestation term back into continued maternal growth without changing assumed history.
- `RLDealerSourceOwnership` persists real animals, unborn identities, pinned sire contexts,
  disease records and the birth journal independently of ordinary player animal XML.
  Real newborn genes, including fertility zero and values outside candidate preset bounds,
  survive without candidate filtering. Restore resolves exact current subtype/model names
  and constructs negative-age shells without RNG, migration or physiology repair.
- `RLDealerObservedGrowth` keeps true newborn rearing separate from MODEL_ASSUMED history.
  It validates committed birth weight/draw/identity evidence, advances actual calendar
  segments through shared hourly feed/growth, and retains an independent cursor. Further
  parent/pregnancy states require a recorded reproductive controller, not invented events.
- `RLDealerOwnedStock` couples every historical source record to one real private-owner
  animal; every real child requires its own observed growth record. Duplicate adult/fetal
  identities, unbound assets, unequal records, changed calf rules, future birth cursors and
  missing models reject restoration. The dealer checkpoint now carries this complete
  envelope. Data-only validation explicitly cannot authorize real ownership; engine load
  passes server and disease-model resolution context and keeps restored owner cycles intact.
- `RLDealerSourceAdapter` detaches an exact frozen source batch once. Compensation restores
  only unchanged original detached objects and original inventory order; foreign target
  ownership or mutations block rollback. After restart, a removed batch requires actual
  asset reconciliation instead of reconstruction from its receipt.
- `RLDealerDestination` distinguishes ephemeral network references, persistent target IDs,
  player farm permission scope and source herd IDs. `RLDealerTargetAdapter` observes actual
  pen/trailer queues and world ownership before declaring transfer or compensation.
  `RLDealerMoneyAdapter` uses actual mission/farm/statistics call-path witnesses, persists
  debit/refund intent and reports unknown compensation when ordinary refunds are not an
  inverse of statistics. Restored money receipts never authorize an automatic debit/refund.
- The synchronous WAL optionally binds the complete source ownership and money receipt
  evidence alongside purchase stages. Runtime compares ownership as well as purchase
  records against the independently coordinated game checkpoint; equal purchase records
  cannot hide divergent inventory. Both snapshots remain available for reconciliation.

Focused integrated ownership/source-transfer/WAL checks pass **36/36**; source birth/bridge
**22/22**, ownership codec **15/15**, observed newborn growth **18/18**, target transfer
**38/38**, money **52/52**, destination **10/10**. All **36** dealer/loader files parse as
standard Lua 5.1. Core reproduction retains inherited GIANTS `continue` syntax; its actual
function is exercised by the documented fixture transformation, not claimed to parse
unmodified in stock Lua. An intermediate full run passed **3335/3335**; the final expanded
run passed **3357/3357** (`/private/tmp/rlrm-dealer-real-source-tests.log`), including the
396-case source-state roundtrip matrix. These remain fixture-based checks; installed-game
multiplayer and interrupted-save acceptance have not been completed.

Next implementation gates: atomic owned-source calendar progression including pending
birth persistence and child adoption; full purchase adapter composing source/target/money
and durable stage evidence; authoritative listing-view/UI route; same-generation money
reconciliation and proven compensation; installed-map and multiplayer/save interruption
validation. Pure StockService publication/progression now explicitly refuse stores with
real owners so no path silently updates only detached physiology. Complete v2 stays closed.

### D4 composed purchase adapter (after `7083006`)

`RLDealerPurchaseAdapter` now composes the actual private source, real Animal handoff,
target queue and mission money adapters under `RLDealerPurchase.execute`. Construction
requires authoritative connection/destination permissions, a complete pen/trailer owner
inventory, server quotes, capacity and eligibility callbacks, current subtype/disease
resolution and a synchronous whole-evidence persistence barrier. It registers no endpoint
and cannot replace previously loaded money evidence with a fresh payment epoch.

Preparation serializes and restores only the selected real source animals through the
ownership codec and then installs the shared physiological handoff. It never calls the
ordinary `Animal:clone` (which shares pregnancy) or a nonnegative-age/random-birthday
constructor. Actual unborn identities, genes and pregnancy objects transfer without a
new draw; prepared target pregnancies are independent copies. Full source inventory,
target snapshots, destination save identity, exact money witnesses and pre-reservation
listings are retained as plain compensation evidence.

The apply path requires the coordinator's durable APPLYING record, revalidates authority,
identity, quote, price, clock, source records, eligibility, capacity, real-time locks and
full-world ownership, and persists own listing reservations before asset effects. It
detaches exact original sources, observes actual target attachment, then debits once.
Callbacks at reservation, target flush and money boundaries cannot silently invalidate
that evidence: fences run again before debit and final commit. SOLD and source-record
removal occur only after complete source/target/money observations. Reentrant effects are
refused. Terminal PREPARED/APPLYING/receipt storage uncertainty closes both stock and
purchase recovery ownership instead of replaying an uncertain effect.

Before a debit, exact target/source compensation can produce ROLLED_BACK. A proven
no-effect money throw can also compensate. `RLDealerMoneyAdapter.cancel` durably marks
unused/no-effect tokens CANCELLED and releases their money lock without permitting a
later debit under the same token. After a real/ambiguous debit, this adapter does not
fabricate a complete refund: it retains actual paid assets under RECOVERY_REQUIRED.

Focused composed-path checks pass **25/25**, including same-request replay, pregnant
batch transfer with fertility-zero/outlier fetal genes, partial/silent target writes,
money throw-before/after, failed initial/post-debit/terminal barriers, callback permission,
capacity, clock, price and funds changes, recycled network references, reentrancy and
cancelled receipt restoration. The fixture uses actual Animal construction/handoff,
source and target adapters, the checked-in FS25 mission/farm money path, and the full
WAL codec/write/readback barrier; target queue, world enumeration and storage filesystem
remain stand-ins. All **37** dealer/loader files parse in standard Lua 5.1.
The complete regression passes **3382/3382**
(`/private/tmp/rlrm-dealer-purchase-adapter-tests.log`).

This is a dormant server composition, not a release: authoritative engine capacity/world
enumeration and eligible listing-view/UI wiring still need runtime installation. A
coordinated checkpoint does not yet rehydrate the money adapter's proof of completed
payments, so restart with purchase WAL evidence remains a reconciliation gate. Ordinary
player pregnancy XML and later births have different unborn identity semantics; purchased
pregnant-dam save/load and normal subsequent offspring need explicit acceptance evidence.
Owned source calendar/birth/newborn progression, complete cross-save ownership recovery,
installed-map aliases and multiplayer/save interruptions remain required. No release flag
or unused server capability declaration bypasses these gates.

### Owned source rearing continuation (after `c7e891d`)

`RLDealerOwnedProgress.advance` now stages historical source feeding and actual observed
calf rearing together, using each supplied segment's real month length. It restores new
private-owner objects without RNG/migration, advances source records and every child
cursor, installs exact physiological fields while preserving real identity, pregnancy
and model-backed disease objects, and progresses listing eligibility/withdrawal. It
publishes the entire farm/owner/listing set only after a complete evidence barrier and
rechecking the original inventory. No known storage error publishes half an inventory;
unknown storage or callback mutation retains before/staged evidence and closes recovery.
The source-update fence also blocks purchase entry during source progression.

Real child cursors use the shared source clock's segment-by-segment arithmetic, with only
sub-1e-8 floating-point roundoff normalized. Mixed 1/3/7-day segments match persisted split
continuation exactly. Zero elapsed time neither rebuilds owners nor writes storage;
invalid calendars still reject. Withdrawn offers retain both real mothers and calves.
Source/purchase reservations and unfinished purchase journals prevent progression.

Twenty focused progression checks pass, including 1/3/7-day calendars, full owned
roundtrip, both source and child cursor advancement, no RNG/migration, partial calendar
failure, storage uncertainty, callback mutation, replay refusal after uncertainty, due
birth gating, withdrawal and concurrent transaction fences. Observed child validation
now also requires exact selected genes and an actual calendar birth date (20 checks).
Owned inventory compares every persisted physiological field, including health/carry,
instead of accepting equal growth mass alone (38 integrated ownership checks).
All 38 dealer/loader files parse in standard Lua 5.1.
The complete regression passes **3406/3406**
(`/private/tmp/rlrm-dealer-owned-progress-tests.log`).

The real calving boundary remains deliberately explicit: an update reaching gestation
term returns SOURCE_CALVING_REQUIRED before publishing any elapsed source time. Next is
the controller that stages all inventory to that boundary, persists PREPARED before the
ordinary birth sampler, refreshes the maternal observed record and adopts actual children
before COMMITTED, then resumes the remaining calendar interval. The standalone sampler,
ownership codec and newborn integrator already exist; their callbacks alone do not count
as a completed production birth pipeline. Runtime clock/generation installation and the
previous D4 recovery/UI/game acceptance gates remain outstanding.

Birth-controller design checkpoint: simultaneous due dams cannot all be installed as
pending endpoints before the first PREPARED write, because the ownership codec correctly
refuses an unjournaled physiological jump. Stage other due dams at their prior recorded
state until their own persisted PREPARED transition, or introduce an explicit multi-dam
prepare/apply boundary. COMMITTED callbacks must refresh maternal SourceState through
captureObserved and enroll surviving actual children before exporting the owner. Maternal
mortality also needs a retired source-record/identity mapping: deleting the source record
while retaining the dead real mother would make the strict owned inventory unbound, while
retaining her as an active fed source would block subsequent feeding. Retain actual dead
identity and committed mortality evidence; withdraw offers and remove her from active
feeding explicitly. Never discard a dead mother or fabricate a newborn assumed history.

### Actual owned calving continuation (after `5aa6fc0`)

`RLDealerOwnedBirth.advance` now consumes real calendar segments across known pregnancy
terms. It restores the complete private inventory without RNG, checks the aggregate full
litters against owner capacity, and requires server-supplied actual birth dates and stable
event IDs. At each exact due cursor it feeds other mothers and existing calves, then
processes simultaneous dams in sorted source-ID order. Other due dams retain their prior
recorded bodies until their own PREPARED transition; a whole-inventory evidence barrier
precedes each call to the normal reproduction sampler. COMMITTED updates maternal observed
SourceState and enrolls every actual surviving calf before persisting the entire inventory.
The remaining calendar interval feeds both generations through shared growth code.

Any attempted barrier followed by an uncertain write, callback mutation or subsequent
failure closes the original stock. Before state, actual staged objects/journals and the
last attempted plain snapshot are retained in `sourceBirthEvidence`; no retry re-rolls a
birth. Same-cursor partial commits retain the first calf when the second mother fails.
Lagging physiological cursors now mark the owned envelope as recovery-required even if
the preceding individual birth journal is COMMITTED. A verified interrupted envelope can
retain its exact real objects in a closed store, rather than dropping evidence through
ordinary SourceFarm's stricter equal-cursor admission gate.

`retiredSources` preserves maternal mortality records, exact owned dead identity and the
matching COMMITTED birth proof. `OwnedStock.stageRetirement` stages only metadata and
withdraws offers; it never discards actual objects or mutates the input stock. Dead mothers
leave active source feeding, while actual living calves continue from the shared cursor.
Historical state, death cursor, selected newborn/draw evidence and maternal physiology must
all agree. Retirement survives owned rearing, coordinated checkpoints, verified restoration,
purchase evidence and runtime WAL comparison. Existing envelopes without this optional
field remain byte-compatible. Retained dead objects still count toward conservative private
owner capacity; disposal/reuse is not inferred from a mortality result.

The first complete regression passes **3447/3447**
(`/private/tmp/rlrm-dealer-owned-birth-tests.log`), including **28** new controller checks and
**13** retirement checks. Subsequent boundary review identified accumulated hour-segment
roundoff near exact term; final boundary verification is recorded below. Tests load the
complete normal reproduction function and actual birth-weight sampler; engine world,
storage and calendar callbacks remain fixtures. The test-only GIANTS `continue` translation
is equivalent on the exercised one-child mortality or dead-last-twin paths.

The new controller is loaded but remains dormant: runtime source generation/calendar hooks,
authoritative listing UI, cross-save actual asset/payment reconciliation and installed-game
pregnant-purchase/multiplayer acceptance are still required. `CHANNEL_ENABLED` stays false.

Next admission checkpoint: the legacy `_tryCreateSaleAnimal` must not be reused as a v2
entity factory. It constructs the mother at a positive age (generated physiology/random
birthday), and `createSalePregnancy` selects offspring again, including implicit genetics
RNG inside its unborn constructor. It does not allocate stable unborn IDs or pin a full
sire context. The next owned admission service must instead accept an already evaluated
historical candidate, fixed adult identity/calendar/disease metadata, fixed real fetal
IDs/subtypes/genes and sire, plus durable request/identity-allocation evidence. All actual
objects use explicit genes/weight and negative-age constructors before shared handoff.
The full owned snapshot and listing publication must pass one persistence barrier; no
failed admission may allocate new IDs or reconstruct a differently sampled pregnancy.

Final boundary/concurrency verification, 2026-10-12: the controller uses the request's
starting cursor plus accumulated calendar deltas, aligning only sub-1e-10 roundoff to a
known term already reached by the complete requested interval. It does not feed to
term-minus-epsilon or fabricate a birth before the supplied interval reaches term.
Arrays of 165/495/1155 individual one-hour segments on 1/3/7-day calendars now calve once
with newborn age exactly zero; removing the final hour leaves pregnancy intact with no
birth draws. Zero elapsed updates preserve real object references and perform no writes.
Transient purchase locks are fenced even before a durable purchase record exists. Both
owned rearing and birth continuation include transient locks in their original-state
fingerprint and hold foreign callback mutations before the first attempted write, retaining
the changed original state for reconciliation.

Final focused checks pass **43/43** for birth continuation, **25/25** for owned rearing and
**13/13** for retirement. All **39** dealer/loader files parse in standard Lua 5.1.
The complete regression passes **3464/3464**
(`/private/tmp/rlrm-dealer-owned-birth-verified-tests.log`). This supersedes the initial
3447/3447 and intermediate 3454/3454 runs above. Full v2 remains closed.

### Fixed selection materialization and owned admission (after `9fadf74`)

`SourceFactory.materialize(candidate, prepared, ctx)` assembles already evaluated history
and fixed selection data into real private objects. The strict prepared envelope contains
request/selection IDs, source owner/capacity, adult herd ID/individual ID/calendar/death
rule/portable disease metadata, and any already selected true fetal identities, subtypes,
genes, expected date and pinned sire. Explicit genes, mass and negative-age constructors
avoid the legacy generator's birthday, weight, pregnancy and hidden genetics redraws.
Shared handoff installs the exact historical state; live tick sentinels are normalized on
the detached real object without modifying the immutable source record. Resolver callbacks
cannot replace the selection supplied at entry. Unknown country codes or subtype bindings
reject before construction. Fetal fertility zero and inherited genes outside candidate
screening bounds remain real selected genes.

The factory does not allocate IDs, save, attach to an engine inventory or publish listings.
Selection provenance is data, not proof that identity allocation was durable. Model-backed
Disease instances are currently rejected explicitly instead of losing model/metatable state;
exact portable carrier records are supported. A future generator must provide authoritative
calendar and identity-allocation context and support actual model disease selection or keep
that candidate path closed. No legacy `createSalePregnancy` is called here.

`StockService.newOwned` creates an empty typed private inventory without converting an
existing historical-only stock. `OwnedAdmission.admit(store, sourceId, candidate, prepared,
ctx)` stages source physiology, real ownership and a listing together. Same-owner admission
merges encoded objects while preserving previous identities, children, birth journals,
pinned sires and retired records; private capacity conservatively includes all actual unborn
offspring. The restored actual staged ownership, rather than a pre-restore approximation,
is persisted. Required world-identity scanning runs before and after the whole-stock barrier.
Snapshots include transaction locks, money evidence and source-update fences; unknown saves,
changed barrier payloads, changed inputs or foreign original-state mutations close recovery
without publishing partial stock. Before/staged/current evidence remains available.

Listing provenance retains the complete original prepared selection and source record.
Exact same-request replay returns the original listing, including SOLD/WITHDRAWN records,
without materialization, identity scans or another write. Matching uses the original admission
cursor so subsequent source feeding does not turn a valid retry into a different birth origin.
A changed proof or reused source/request identity rejects rather than assigning another ID.
This service remains dormant until actual server allocation, source generation, world scanning,
durable runtime save wiring and existing D4 acceptance/recovery gates are installed.

Fixed-selection verification passes **38/38** for the factory and **56/56** for admission,
including an actual full path from empty owned stock through fixed pregnant admission,
normal birth sampling, remaining newborn feeding and exact owned save/restore. The original
complete admission proof survives withdrawal and an after-birth same-request retry still
returns its original sale ID. The world scan and storage callbacks in this integration are
fixtures; birth, growth, handoff and ownership code are the production implementations.

The rearing/birth controllers now also freeze their complete barrier payload and reject a
callback that changes it while returning success. Original before/staged/attempted evidence
remains untouched; birth PREPARED-payload changes cannot reach RNG. Focused checks now pass
**42/42** for birth and **27/27** for rearing. All **41** dealer/loader files in this batch
parse in standard Lua 5.1. Complete regression: **3562/3562**
(`/private/tmp/rlrm-dealer-owned-admission-tests.log`).
The next runtime-provider work is recorded in `DEALER_RUNTIME_CAPABILITIES_PROGRESS.md`.


## 2026-10-12: dormant world and whole-batch capacity providers

`RLDealerWorld` reads the actual current server mission, complete placeable/vehicle
registries, public pen/trailer clusters, ridden animals and legacy stock, together
with supplied private ownership. Busy/unreadable loading and cluster queues hold
without flushing. Owner/registry/member/identity/fetus/rideable/legacy references
are rechecked after callbacks, including same-count replacements and late identity
changes. Fixed private fetus country uses the pinned real source-birth rule.

`RLDealerCapacity` proves complete-batch destination space from current owned
source physiology and listing state. Pen construction, profiles and map rules
share a read-only predicate; the legacy apply path remains responsible for normal
cache/filter changes. Trailer batch/resident types and actual count/max/free slot
interfaces must agree. Source snapshot and destination membership changes reject.
Factory now rejects placeholder full identity `1-1` and the native missing-owner
`farmId="1", uniqueId="1"` combination for adults, fetuses and pinned sires before construction.

Focused checks: World **71/71**, Capacity **38/38**, Factory **43/43**.
The capacity integration uses actual PurchaseAdapter/Source/Target/Money/Journal
code and transfers two animals into exactly two remaining slots alongside one
resident, debiting money once. All four capacity checks occur before transfer.
Container engine method stand-ins do not constitute installed-map acceptance.

Both providers are loaded but remain dormant: no generation/UI hook or full v2
channel is enabled. `DEALER_RUNTIME_CAPABILITIES_PROGRESS.md` records capabilities;
`DEALER_IDENTITY_ALLOCATION_PROGRESS.md` records the next allocation gate. The
native ID formatter has collisions and counters are per type, so current-world
conflict scanning cannot prove lifetime uniqueness. A durable complete-key ledger,
ordinary birth/legacy allocation coordination and native counter save alignment
remain required before generation can publish prepared selections.

Verification checkpoint: complete regression **3673/3673** passed
(`/private/tmp/rlrm-dealer-world-capacity-final-tests.log`). The native missing-owner
Factory guard was completed after that run had loaded the Factory test file;
its final focused rerun passes **43/43**, and dependent OwnedAdmission passes
**56/56**. Final World and Capacity reruns pass **71/71** and **38/38**.
All **45** dealer/loader/changed bridge files parse in stock Lua 5.1;
`git diff --check` is clean. No installed-game acceptance is claimed.
