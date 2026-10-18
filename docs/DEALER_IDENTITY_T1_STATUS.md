# Dealer v2 T1: identity ledger (pure service)

2026-10-13, branch `feat/dealer-identity-t1` (worktree `rlrm-identity`), from origin/dev `f9a6d93`.
Design: `FS25_交易系统v2_细化设计_2026-10-13.md` §5, §11 T1, §12 ID-01..04.
D1-D7 of that design were taken as adopted when development was requested; they were not re-confirmed one by one.

## What T1 adds

`scripts/animal/RLAnimalIdentity.lua` (sourced from main.lua, **no caller**): a ledger of full keys
`(farmId, uniqueId, country)` per domain country+herd. Dormant: no birth, sale, AI or dealer path uses it,
`RLDealerRuntime.CHANNEL_ENABLED` is still false, no save file is written, no game behaviour changes.

- `reserveBatch(ledger, requestId, plan, {isOccupied})`: adults and fixed fetuses in one all-or-nothing batch;
  candidates run up from the domain cursor, a candidate whose FULL key is taken (ledger, blocked historical
  range, caller veto, same batch) is skipped (MAX_SKIPS 2000); raws never exceed MAX_RAW 99999.
  Same requestId + same plan returns the same keys (`replayed`), another plan is `REQUEST_MISMATCH`.
- States RESERVED -> MATERIALIZED (`bindMaterialization`, fixed selection digest) -> CONSUMED (`consume`),
  or BURNED (`burn`). No state releases a key. `burnUnsaved` imports keys of an unsaved session as BURNED (D3).
- Domain proofs: `EXCLUSIVE_NEW`, `COUNTER_HISTORY` (blocks the FULL keys of raws 1..next-1, including the
  padId aliases), `MIGRATION_POINT` (weaker, needs `userAccepted = true`). No proof = `LEGACY_HISTORY_UNPROVEN`,
  `reserveBatch` refuses it.
- `migrationReport(records, counters, opts)` + `applyMigration`: reports duplicates, placeholders (`1 1`),
  country-less records, ids the formatter cannot have made, counters below a live key, shared raws across
  species; proves a domain only from caller evidence (`exclusive`, `counterNeverRegressed`), never from the scan.
- `probeLegacy`: read-only shadow check of a key the old code produced.
- `export` / `import`: canonical text + digest (damage / mixed generation detection, not a proof of any action),
  structural validation on import.

`I.preimages` mirrors `RLAnimalUtil.padId` (raw 1..9999 ~ 10001..19999, raw 0 ~ 10000). The test checks it
against the real formatter for every raw 0..99999, so a formatter change fails the test.

## Evidence

- tests/test_animalidentity.lua: 39 checks; full suite 3814/3814 (baseline dev 3775).
- Uses the real `RLAnimalUtil.generateUniqueId` (file loaded with the Giants `::number` cast removed).
- Mutations caught: alias-blind blocked check, ledger-blind candidate check, key release on burn, non-idempotent retry.
- Lua 5.1 parser accepts the module and test; `git diff --check` clean.
- Not tested: any game run. No entry point is connected.

## Open for T2 (not decided here)

- MAX_RAW 99999 and the native XML/network limits for ids: freeze against the real entries before any wiring.
- Ledger file `rm_RlAnimalIdentityLedger.xml` (chunked XML like RLDealerJournal), save participant, native
  counter file `rm_RlAnimalSystem.xml` alignment, identity log shared with the purchase WAL.
- Entry points: FarmStats births, AnimalSystem counters, `_takeSaleAnimalId`, legacy AI bulls, fixed fetuses;
  safe suspension when a birth cannot get a key.
- The ledger holds one table entry per key: compaction (equivalent ranges) is needed before long lineages.
