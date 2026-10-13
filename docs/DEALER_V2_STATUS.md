# Dealer v2: development status, T1-T6 (branch `feat/dealer-identity-t1`)

2026-10-14. Base: origin/dev `bbb4573` (PR #56) merged into the branch. Nothing is pushed, merged, packaged or deployed.
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
