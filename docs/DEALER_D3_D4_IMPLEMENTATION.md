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
