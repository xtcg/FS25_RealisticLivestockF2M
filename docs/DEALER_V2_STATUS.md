# Dealer v2: development status, T1-T6 (branch `feat/dealer-identity-t1`)

2026-10-14. Base: origin/dev `bbb4573` (PR #56) merged into the branch. Published as draft PR #58; not merged, packaged or deployed.
`RLDealerRuntime.CHANNEL_ENABLED` is false at every map load. **No line of this has run in the game.**

## What exists, by batch

| Batch | Code | Offline evidence |
|---|---|---|
| T1 identity ledger | `RLAnimalIdentity` (full-key ledger, batch reserve, states, domain proofs, migration report, export/import) | test_animalidentity (46) |
| T2 identity in the game | `RLAnimalIdentityRuntime` (OFF/SHADOW/ON), `...World` (contexts, scan), `...Persistence`, `...Checkpoint` (save markers, ledger file, unsaved-key journal, recovery); the 7 allocation entries; birth hold; console `rlIdentity*` | test_animalidentity_runtime / _checkpoint / _entries (80) |
| T3 stock | `RLDealerRng`, `RLDealerPlanner`, `RLDealerGeneration`, `RLDealerScheduler`, `RLDealerGameBinding` | test_dealergeneration (T3 part) |
| T4 purchase | `RLDealerAssembly`, `RLDealerService`, `RLDealerRuntime.enable/gate/onHour`, `RLDealerPurchase.lookup`, `RLDealerDestination.principal`, late-reply/UNCERTAIN client rule | test_dealerpurchaseadapter (SV-01, T4), test_dealerruntime, test_dealerclientrequest |
| T5 browsing | `RLDealerCatalog`, `RLDealerCatalogProtocol`, `RLDealerCatalogEvent`, `RLDealerSelection`, `RLDealerMessages`, l10n (17 languages) | test_dealergeneration (T5 part) |
| T6 evidence | `rlDealerV2*` singleplayer console route, `rlIdentityDump`, `tests/dealer_v2_analyzer.py` (+11 unit tests), `DEALER_V2_T6_TEST_CARDS.md` | analyzer tests; the cards are PENDING |

## Decisions that differ from the design documents

1. **Jobs are in memory.** A generation job runs inside one scheduler call (no frame boundary, so no save falls in the middle);
   what must survive - reserved keys, listing, admission proof - is in the ledger and the store. A job lost to a crash leaves reserved
   keys (blocked for ever) and no animal. The design's persisted `GenerationJob` is not built.
2. **Births have no persisted `pendingBirth`.** The hold happens before the engine touches the pregnancy (no draw, no parity change,
   no placeholder newborn); the pregnancy itself is the saved intent, and the litter's keys are reserved idempotently per
   mother/due date/litter size, so a retry - also after a reload - gets the same keys.
3. **Fetus keys are CONSUMED at admission**, not at birth: stricter (never reusable), and the factory already fixes them.
4. **The money-restore gap of the design is not on the checkpoint path.** `MoneyAdapter.restore` only runs on the WAL path;
   a normal save/reload builds a new money store and keeps terminal receipts as history (test SV-01). No `RLDealerSettlement` was needed.
5. **Unsaved-key journal is written hourly (dirty only), not before each allocation.** A crash between allocation and the next flush can
   let a key shown in the lost session be reused; no saved animal is ever affected.
6. **Evidence problems put the identity ledger in RECOVERY_REQUIRED and the old counters back in use** (the behaviour before this work),
   with an error line. It is not fail-closed for births, because holding every birth of a damaged save is worse.
7. **Retirement of withdrawn sources (EXPORTED after 2 months) is not implemented.** The retired-source archive only validates a dead
   mother with a birth proof; extending it was not attempted. The 3x source cap bounds the cost instead (`SOURCE_CAP`).
8. **No GUI.** Browsing and buying run through the console route and the protocol; no dialog XML was written (it could not be checked
   visually). Paging, snapshots, selection and messages are ready for one.
9. **Old rotation is not switched off for the species.** With the channel enabled the old dealer still sells cattle in its own screen;
   the "one mechanism per species" rule needs the GUI decision.

## Limits and open items (each is PENDING, not done)

- All G01-G10 test cards; multiplayer; other species (sheep S5 not finished); other maps/containers; third-party trailers.
- `MAX_RAW = 99999` is a conservative bound, not measured against the real XML/network/GUI limits of every consumer.
- Replay cost: about 0.1 s per candidate in the offline interpreter; the in-game budget is 1 place per game hour and has not been measured.
- `Animal.new` for the vanilla-cluster conversion path allocates after the birthday is known (ON only); the trailer rideable
  conversion forces the map country into `birthday.country` (ON only) so the key and the animal agree.
- The first dealer checkpoint needs one verified save after `rlDealerV2Enable` before purchases open.
- Shared-save-hook helper between Trade/Dealer/Identity was not extracted (three independent checkpoints).

## Code review (2026-10-14, `/code-review high` against origin/dev)

Nine findings, all fixed with a regression test each (suite 4099/4099 + 13 analyzer tests):
world.now frozen at enable (now refreshed per tick); a recovery with no ledger dropped on the next save (stub ledger carries it);
unresolved purchase handling in the client (new orders blocked, UNKNOWN_REQUEST settles as NOT_RECEIVED, clock fault is UNCERTAIN);
herds with used counters but no animal needed no acceptance (now they do); births with an unresolvable domain were held for ever
(now numbered as before, with a warning; only reservation failures hold); a consume failure after publication re-generated the place;
`enable` failing half way left the checkpoint armed (now armed last); re-activation re-imported every key (now only new ones);
the price memo dropped in-flight figures on overflow (two generations); two analyzer false FAILs.
Not covered by a test: the memo rotation itself.

## Independent PR review (2026-10-14)

Reviewed implementation `afc8f59`. Independently rerun: Lua 5.4 **4099/4099**, analyzer **13/13**. The default interpreter run was interrupted by sandbox access to `os.tmpname()`; a Lua 5.1 attempt stopped at the test-only `load(string)` call. These attempts are not business-test failures or proof of Lua 5.1 compatibility.

Three additional findings remain open; no code fixes were made in this review:

1. **P1 — recovery clear resumes a stale allocator.** Allocate raw 1 in ON; recovery falls back to native counters and creates live raw 2; `recoveryClear()` resumes the old ledger and assigns raw 2 again. Rescan/import live identities and reconcile native counter high-water marks before ON; preserve recovery on incomplete evidence.
2. **P2 — OFF/SHADOW reactivation ignores advanced counters of already VERIFIED domains.** Allocate raw 1 in ON, raw 2 in OFF, sell that animal, then activate with counter nextRaw=3: the next allocation is raw 2 again. Reconcile existing domains too, retaining the consumed range even for animals no longer present.
3. **P2 — order-status replies are not bound to an order.** After settling timed-out order A, let order B time out; a duplicate COMMITTED answer for A passed to `receiveOrderStatus` clears B and reports A's amount under B's ID. Carry and validate order ID / query correlation through the catalog protocol and client transition; stale or mismatched replies must leave B unresolved.

The first two were reproduced against the real runtime/ledger modules; the third against the real client state machine. Existing regression tests do not cover these sequences. Keep this PR draft until fixes and targeted regressions are reviewed. In-game acceptance remains PENDING.

### Fixes (2026-10-14)

1. **P1 fixed.** `RLAnimalIdentityCheckpoint.recoveryClear(scan)` now needs a complete world scan (the console passes `RLAnimalIdentityWorld.scan`). `RLAnimalIdentityRuntime.reconcile` works on a copy of the ledger. It imports every live key the ledger lacks. It then moves every domain past the native counters with `RLAnimalIdentity.raiseHighWater`: raws `1..high-1` are blocked through every alias, and the cursor goes to `high`. The copy is swapped in only when it validates. A missing or partial scan, or a failed reconciliation, keeps RECOVERY_REQUIRED with the ledger and the old counters unchanged. Regressions R9 (checkpoint): an animal born in recovery stays alive, another is sold, the clear is followed by save and reload, and the counters cross the 9999 alias boundary.
2. **P2 fixed.** `R.activate` reconciles the domains the ledger already held in the same way. `scan.herdNext` (new) carries a herd's highest counter of any species, so a herd with no animal left is still bounded. An uncovered herd that the ledger already holds as a verified domain needs no fresh acceptance. Regressions R8 (runtime): ON/OFF/ON and ON/SHADOW/ON with the animal sold, a different species counter, and a sale-farm domain.
3. **P2 fixed.** ORDER replies carry `orderId` (an optional field in the validator). The service echoes the order it was asked about. `RLDealerCatalogEvent` stamps the asked id on every ORDER answer, including the disabled, error and invalid-result answers. `RLDealerClientRequest.receiveOrderStatus` changes the client only for a reply whose `orderId` equals the unresolved order. A reply with no id gets `ORDER_ID_MISSING`. A reply for another order or another session gets `STALE_REPLY`. Regressions: R5 (client: A/B interleaving, duplicate, late ROLLED_BACK/UNKNOWN_REQUEST, missing id, other epoch) and R7 (event and service echo).

4. **P2 fixed (follow-up review).** Console order ids repeated after a restart. `orderSeq` lived only in memory, but the id used the persistent lineage, so `console-<lineage>-1` came back and the saved purchase record refused it with REQUEST_CONFLICT (G07). `RLIdentityConsole.nextOrderId` now builds `console-<session epoch>-<n>`. The epoch is the dealer's `parts.epoch`, made again at every `rlDealerV2Enable`. Without an epoch the order is refused (`NO_SESSION_EPOCH`). Regression R10 (purchase adapter) uses the real purchase coordinator: it buys, exports and imports the purchase records, starts a new session and epoch, and buys again. The test fails against `9bfb37f`.

Suite **4126/4126** (Lua 5.5 via lupa), analyzer **13/13**. The new tests fail or crash against the code before each fix. Known limit, unchanged: once a domain's counters cross raw 9999, raws 10001..19999 alias used raws, so the ledger refuses (SKIP_LIMIT) rather than hand out an alias. Still not run in game.
