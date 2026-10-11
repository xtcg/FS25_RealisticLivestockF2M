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
| Historical generation | **Missing**; `createGeneratedState` derives from current weight | D3-2/3 required |
| Dealer feeding and authoritative cursor | **Missing** | D3-4 and D4 clock required |
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

D3-2: pure monthly-age event history from D2 reproduction plans. Store source, versioned
feeding template and traceability independently. Include selected birth/context, actual
weaning rules, conception/calving and continuous sale age. UNSPECIFIED is model-assumed
history. Validate each historical conception against age, curve-frame target (not legacy
price target), development and reserve. Genetics screening precedes expensive replay;
create unborn offspring only after major candidate screening.

D3-3: hourly reference replay through the shared budget; reject failures. Replace old
random-weight generation only for verified cattle. No ±15%, duplicate sex/gene factors,
legacy anchors or post-hoc derived histories. Screen reserve mass fraction at the specified
5–11% with a separately calibrated calf rule. Validate optimizations against the hourly
reference to ≤0.1 kg; cache only pure profile data.

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
