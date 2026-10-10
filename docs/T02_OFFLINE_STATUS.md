# R0-T02 offline preparation

Base: PR #31 `7af1b27dd9690286b9f4aa5a38e86b88a4f13a65`, built on dev `9be3881`.
Branch: `feat/contract-transaction` (batch 1); rebased onto PR #31 `6bbb74d` in `feat/contract-adapter`.

Batch 2 (PR #32, controlled live HB contract delivery): see [T02_BATCH2_STATUS.md](T02_BATCH2_STATUS.md).
Batch 3 (PR #33, player/herdsman live sales with money receipts, herdsman wage actions): see [T02_BATCH3_STATUS.md](T02_BATCH3_STATUS.md).
Batch 4 (PR #34, ledger saved with the savegame, checkpoint markers, load check and gate): see [T02_BATCH4_STATUS.md](T02_BATCH4_STATUS.md).
The "Not enabled or complete" section below describes batch 1 alone.

## Implemented and verified offline

- `RLContractPlan`: pure whole-batch capacity/fee/credit/cash planning. Order credit is
  consumed once across all animals and inputs, and all orders share the farm's wallet.
  Unknown/non-authoritative/ambiguous quotes, missing orders, inconsistent snapshots,
  duplicate identities, invalid amounts and insufficient resources refuse the batch.
  Capacity and budget tolerances cannot authorize a partial live-animal conversion.
- `RLContractPreview`: reads actual T01 quotes and aggregates the entire selection.
- `rlTradePlan <facility number> <uniqueId|pen:NAME> [farmId]`: read-only server/host
  shadow preview. Lists whole-batch fees, credit, cash, wallet and input demand/room.
  No delivery, money mutation, reservation, recipe alignment or animal initialization.
  A client receives NOT_AUTHORITATIVE; duplicate facility names/uniqueIds are refused.
  Unlike `rlTradeReport`, it never silently truncates a batch to 40 animals.
- `RLTradeTransaction`: adapter-driven offline coordinator with resource locks and
  request-fingerprint replay protection. Contract order: target then source; sale order:
  source then receipt-aware settlement. Every attempted mutation requires a verified
  inverse. Unknown settlement or failed compensation retains locks for reconciliation.
  Visual/notification failure after commit cannot retry economic work.
- Ledger schema export/import: completed transactions remain replay-only; unfinished
  transactions reload as NEEDS_RECONCILIATION and block new work pending asset checks.
  These are serializable records, **not** an integrated savegame journal.
- `tests/fixtures/hb_contract_delivery.lua`: exact excerpts of the supplied HB Beta2
  service helpers and delivery method, with source SHA256. The production arithmetic
  and mutation order are unchanged. Engine money/activation/visual calls are test stubs.

## Evidence

- PR #31 baseline independently rerun: 749/749.
- This branch: 845/845, including 96 new checks.
- Both new suites under Lua 5.1: 96/96. Test XML reading uses the Lua 5.1-compatible `*a`.
- Real HB function: with 20 credit and 30 cash, a requested input of 1 accepts 0.5,
  consumes both balances and mutates buffered/total-delivered fields plus activation.
- Real HB function: a money throw before mutation still consumes credit; a throw after
  mutation consumes cash and credit without adding input. Returning 0 alone cannot
  compensate these outcomes.
- Repeated shadow queries leave money, credit, input and activation unchanged.
- Coordinator fault adapters cover partial mutation, false returns, throws, verification
  failure, inverse failure, shared-resource reentrancy, replay and reload.
  They prove coordinator behavior, **not GIANTS source rollback capabilities**.

## Not enabled or complete

Existing game delivery/sale paths are unchanged. No live commit or rollback adapter
is installed, and the offline coordinator is not called by economic events. The
existing partial-acceptance defect therefore still needs the live T02 adapter work.

Remaining offline implementation:

1. Bind a certified HB target adapter: freeze order/recipe revision and account for
   feeCredit, order.fee, buffered, totalDelivered, totalDeliveredAmount, state and
   activation/visual effects. A money exception needs an actual receipt or reconciliation.
2. Bind source validation/removal/restoration to the real cluster system, including
   identity maps, pending queues, idFull/visual bookkeeping and partial remove failures.
3. Protect animal ownership/access/disease/age gates, order cancellation and recipe
   revision; shadow budget success is not authorization to trade.
4. Add controlled bridge versioning and historical order protection; quantity/fee
   policy changes remain separate. No change to existing meat, condition or fee policy.
5. Connect receipt-aware settlement to manual/AI sales and journal failures.
6. Integrate ledger and asset save/load under one verified save boundary. Fingerprints
   alone do not reconstruct an interrupted transaction; asset receipts and deltas must
   also be persisted. Separate log files do not prove crash atomicity.

## Later game acceptance

Load a test build in a copied HB Beta2 save. First run `rlTradeReport`, then
`rlTradePlan 1 pen:NAME FARM_ID` (replace facility number/name/farm). Compare the sum
against per-animal reports and check repeated queries leave assets unchanged. A
SHADOW_OK result confirms only budget/capacity calculation.

Actual delivery, rollback, source bookkeeping, save/reload and client synchronization
must be checked after the live adapters exist, separately in SP, host and dedicated
server. Do not label this branch complete T02 or game-accepted.
