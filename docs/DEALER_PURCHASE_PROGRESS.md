# D4-3 dormant dealer purchase coordinator

Status: independent core and fake-adapter fault tests implemented; **not integrated and not release-ready**.
`RLDealerPurchase` is deliberately not loaded by `main.lua` or called from `AnimalBuyEvent`.
The inherited event accepts animal payloads and remains an integration gate; passing dealer
operations into `RLTradeTransaction.begin` is not supported or attempted.

## Public interface and persisted identity

- `new()` creates a journal/lock store.
- `execute(store, request, principal, adapter)` accepts only server-resolved principal plus
  `{requestId, items={{saleId,revision},...}, destination, quoteCredential}`. Normalization
  sorts sale IDs and includes principal, exact revisions, destination and quote credential
  in a canonical fingerprint. Duplicate/sparse batches reject. Maximum batch is 1000.
- Identical request IDs/fingerprints replay the saved outcome without ownership or money
  effects; changed fingerprints conflict, including a different principal. Results are copies.
- `export(store)` returns plain journal data, excluding runtime locks and real-time clock.
  `import(data)` validates stage, identity, transfer IDs, context and final outcome and closes
  the gate for every unfinished transaction. Recovery locks are reconstructed.
- `recover(store, adapter)` consults authoritative receipts/ownership, completes compensation
  or recognizes a committed batch from a bound receipt, persists final outcomes and only then reopens the gate.
  An unknown result keeps the entire purchase subsystem closed.

`RLTradePersistence.check/canonical` is reused for strict plain data and fingerprints.
A fingerprint is not authentication or disk integrity. The eventual save adapter must wrap
this journal in the existing integrity-checked save/checkpoint mechanism and retain request
IDs for replay; no journal pruning/expiry or random request IDs is implemented here.

## Required ownership adapter contract

The adapter explicitly advertises `durableDealerOwnershipVersion = 1` and supplies all
functions below. This is a declared contract, **not proof that a real adapter satisfies it**.
Absent implementations fail with `ADAPTER_NOT_DURABLE` before any effect.
Functions are plain callbacks, not colon methods.

| Callback | Contract |
| --- | --- |
| `isServer()` | True only on authority. |
| `authorize(principal,destination)` | Resolve current connection/farm permission. Principal must come from authority, not the payload. |
| `monotonicMs()` | Finite, nonnegative monotonic real milliseconds, independent of game time. |
| `currentClock()` | Finite authoritative accumulated months; reads must not advance physiology or generation RNG. |
| `readListing(saleId)` | Detached plain `{saleId,recordRevision,state,...}` listing snapshot. |
| `validateListing(listing,context)` | Physiology is already current; validate model support, clinical/purpose eligibility, progression and expiry. No repair/redraw. |
| `validateQuote(listings,context)` | Authenticate binding to principal, complete batch, exact revisions, destination, server price, current clock and expiry. Never trust a client price. |
| `validateDestination(listings,context)` | Compatibility, construction, ownership and whole-batch capacity. |
| `validateFunds(listings,context)` | Whole-batch affordability including authoritative transport charge. |
| `prepare(listings,context)` | Pure, side-effect-free; return `{amount,transferIds,compensation,...}` with one unique stable transfer identity per sorted item and complete durable compensation evidence. |
| `checkpoint(snapshot)` | Persist the whole journal durably before returning true; false/exception means uncertain durability and closes the gate. |
| `apply(token,plan,context)` | Idempotent whole-batch ownership/money transaction with token-keyed durable receipts; return a bound complete receipt or `UNKNOWN`. Atomically revalidate all permissions/clock/revisions/quote/model/eligibility/destination/capacity/funds before effects. |
| `reconcile(token,plan,context)` | Inspect durable receipts plus actual source, target and money ownership. Recognize a fully committed batch or compensate every partial effect before returning `ROLLED_BACK`; otherwise `UNKNOWN`. Must work repeatedly after process interruption. |

Every terminal adapter result is a plain receipt
`{status="COMMITTED"|"ROLLED_BACK", token, amount, transferIds,
sourceComplete=true, targetComplete=true, moneyComplete=true}`.
The coordinator verifies exact token, amount and ordered transfer identities before accepting
or persisting it. Bare success strings, receipts for another batch and incomplete components
fail closed and trigger reconciliation. Import rechecks persisted receipt bindings. Stable
transfer identities cannot be shared by separate journal owners, including rolled-back ones.
These checks prevent accidental cross-transaction receipt acceptance; receipt flags remain an
adapter contract and do not prove engine durability.

Context contains normalized request, captured current months and stable token
`dealer:<requestId>`. The adapter must preserve full physiological state and actual animal
identities; a caller-provided animal or rebound dealer copy is never transfer authority.
Compensation must be token-scoped; restoring an entire old farm balance or entire pen
snapshot would destroy unrelated transactions. Money/target-capacity resources require
adapter-level atomic ownership/reservations in addition to the coordinator's sorted sale
locks. A real implementation must prove source/target/checkpoint/money ordering and recovery;
merely storing before-images or setting the capability flag is insufficient.

## Journal ordering and fail-closed behavior

The journal persists `PREPARED`, then persists `APPLYING`, then invokes ownership mutation.
Terminal `COMMITTED` or `ROLLED_BACK` plus result is persisted before runtime locks release.
Any ambiguous apply/compensation produces `RECOVERY_REQUIRED`, preserving locks and closing
new purchases. Checkpoint uncertainty also closes the gate, even if ownership already
committed; reload resolves using receipts and the last durable journal.

The five-second lock budget uses monotonic real time and is checked both before preparation
checkpointing and immediately before the first effect. An expired lock belonging to an
unfinished journal is never stolen; recovery owns it. Orphan runtime locks can expire.
Synchronous callback exceptions are contained, but `pcall` does not establish durability.

An adapter can report rollback only once every item is again source-owned, target insertion
has been undone and the token's money movement is compensated. A fully committed outcome
requires every item target-owned, every listing sold exactly once and exactly one debit.
During an unresolved interruption, listings/target animals must be hidden or quarantined by
recovery authority; this module alone cannot prevent other engine code from accessing them.

## Listing registry integration seam

`RLDealerListingRegistry.get(registry,saleId)` returns detached records. Its `reserve` requires
exact current physiology cursor `lastProgressedAtMonths`, revision and request ID and bumps revision;
`markSold` requires the reserved revision, owner, unexpired real-time lock and current clock.
An actual adapter must reserve the whole sorted batch under its durable ownership token,
track resulting revisions in its prepared operation/receipts, release every reservation on
rollback, and quarantine unresolved load-time reservations. Its `release`/`markSold` callbacks
alone do not supply atomic money or target ownership recovery. Do not loop single-record commits
while exposing a committed prefix. `lastUpdatedAtMonths` also changes on lock mutations and is
not the physiology cursor. Adapter real-time units must consistently be milliseconds. Never
timeout-release or steal a journal-owned reservation. Registry restoration currently
quarantines interrupted reservations with `TRANSACTION_RECOVERY_REQUIRED`; linking that
recovery lock to this journal is still required.

## Verification and remaining acceptance gates

Focused tests simulate an ownership/checkpoint adapter and check canonical replay/conflict,
permission/server/model/quote/capacity/funds/revision rejection, sorted lock contention,
two-client reentrant races, monotonic regression and timeout, full-batch compensation after
target/source/money faults, post-receipt exceptions, both possible failed-checkpoint outcomes,
restart reconciliation, persistent unknown ownership and corrupted journal rejection.
These establish coordinator behavior only. The fake compensation adapter operates an isolated
test world; it is not suitable for production/concurrent farm balances.

Still required: real integrity/checkpoint adapter; stable engine animal identity and full
state handoff; durable token-scoped target/source/money receipts and compensation;
whole-batch registry reservation/recovery integration; replacement authoritative request
protocol and server Event routing; multiplayer/game save interruption validation.
Until these gates pass, full-v2 dealer generation and purchases remain closed.

## Independent request/reply protocol batch

`RLDealerPurchaseProtocol.VERSION = 1` is independent of the global/configuration/listing
protocol. `RLDealerPurchaseEvent` is not loaded by `main.lua`; the existing purchase Event and
UI routing remain unchanged. Request fields are strictly whitelisted: request ID, items with
sale ID/revision, destination as a stable network reference string, and quote credential.
Animals, prices, principals, farms and extra fields reject before service dispatch. Revisions
use uint32; batch size is 1–1000; strings cap at 4096 bytes. Constructor/write validation and
read validation share the same schema. Malformed/truncated/version-unknown frames are dropped
with `errorReason` and never invoke authority; there is no trustworthy request ID for replying
to an undecodable frame. Engine framing/transport size behavior still needs game validation.

Replies carry the correlated request ID plus `COMMITTED` / `ROLLED_BACK` authoritative result
(amount and stable transfer IDs), or `REJECTED` and a stable error reason. Amounts serialize as
17-digit numeric text over the existing string stream API, preserving binary double precision
without introducing a new engine numeric API assumption. Client Events only consume server
replies; server Events accept only client requests. Service results for another request reject.

`RLDealerPurchaseEvent.getService()` returns `RLDealerPurchaseEvent.service`, nil by default.
Server service must implement plain callbacks `authorize(connection,destination)` and
`execute(connection,request)`. Authorization must resolve current trade permission and
destination farm ownership using the actual connection; execute must resolve authoritative
principal, destination, listing/quote/transaction adapters and return the coordinator result
or `nil, reason`. No service produces explicit `DEALER_V2_DISABLED`. Service/authorization
exceptions produce stable refusals. Client service may implement `onReply(reply)`; it cannot
execute a purchase through incoming replies. Actual UI/service registration, stable network
reference resolution and multiplayer transport testing remain parent integration gates.

Focused verification now includes 72 coordinator checks and 40 codec/Event checks, with
Lua 5.1 parsing of all five module/test files. Read/write/construct checks consume no RNG and
call no physiology or generation code. Receipt-binding and transfer-identity checks were
added during durability self-review; this does not change the explicit real-adapter gate.

After durable APPLYING checkpointing the coordinator rereads current clock, permission, every
listing/revision/state, eligibility/model, quote, capacity and funds before calling apply. A
change triggers authoritative reconciliation without effects. Apply still needs its own
atomic ownership fence: external source progression must skip journal-owned listings while
APPLYING, and cannot withdraw/quarantine/reset reservations behind a running transaction.
Unknown reconciliation retains journal locks/evidence; a revision failure never just unlocks
and resumes the old plan. Seven fault tests mutate each authority input during checkpointing.

## WAL ahead of the coordinated asset snapshot

Ordinary career save is asynchronous; constructing XML files or starting that save is not a
synchronous durable checkpoint. The real adapter needs a durable journal WAL and coordinated
asset-generation markers; the root integration owns that implementation. If WAL generation
is ahead of stock/placeables/vehicles/farms/career snapshot generation, load with
`RLDealerPurchase.import(data, {forceReconciliation=true})`. This preserves terminal stage,
result and bound receipt, marks every record `needsReconciliation` and closes purchases until
`recover` rechecks actual ownership for every token, including prior COMMITTED/ROLLED_BACK
records. A committed WAL alone cannot make a loaded old asset snapshot replay as committed.
The adapter can recognize the actual committed whole batch or fully compensate/confirm the
older source-owned state and record rollback; unknown ownership retains old receipt evidence,
recovery locks and the closed gate.

Multiple historical tokens can concern the same sale (rollback followed by another attempt),
so forced audits retain all recovery owners and release the shared lock only after every
token resolves. The adapter must reconcile against the actual loaded asset generation and
other token receipts without undoing another token's later valid transaction. Persisted
`needsReconciliation` survives an interrupted audit. Seven tests cover terminal evidence,
blocked replay, actual-owner recheck, older assets, ambiguity and overlapping audit owners.

## D4 authority quote core

`RLDealerQuote` is a separate volatile server registry with `new(serverEpoch)`,
`issue(store, {destination,items}, principal, adapter)` and
`validate(store, credential, {destination,items}, principal, adapter)`. Both issue and validate
return a detached authoritative quote or `nil, reason`. No persistence/export exists. The
server supplies a fresh epoch per load (maximum 256 bytes); never reuse an epoch after clearing
sequence state. Credentials bind that epoch and an exact monotonically issued sequence. The
registry does not rely on credential secrecy: current server-resolved principal, destination,
sorted IDs/revisions, eligibility, physiological cursor and recomputed prices must all match.

The adapter implements plain callbacks `isServer`, `authorize(principal,destination)`,
`currentClock`, `monotonicMs`, `readListing(saleId)`, `eligible(listing,context)`,
`computeBuyPrice(listing,context)` and `computeTransportFee(listing,context)`. The pricing
callback resolves the actual source animal by sale ID and calls unchanged
`RLAnimalBuyService.computeBuyPrice(serverAnimal)`. Transport uses the existing server animal
fee, with zero for a server-validated trailer destination. No callback may progress physiology,
replenish stock, allocate identities or consume generation RNG. Eligibility must include
current model support and purpose/clinical checks; authorization resolves actual permission
and farm ownership. The module rejects client amounts/prices/animals or other extra fields.

Listings must be LISTED, have exact revision and `lastProgressedAtMonths == currentClock`,
valid listed time and a future expiry. Reads are repeated after pricing and snapshots must
remain identical; authoritative clock is rechecked across these reads. Quote records bind
per-item server prices/fees, separate subtotal/transport fee, gross amount and current month
cursors. Validation recomputes every component, so equal-total offsetting price changes also
refuse. Quote issue and validation use a monotonic 15-second TTL, checked after callbacks;
month length/game speed never extend it. At most 256 active quotes are retained; expiry frees
capacity without changing source stock. Quotes survive repeated validation but not a server
reload. Already committed purchase replay uses the durable transaction result and does not
require an unexpired quote. The coordinator bridge test demonstrates this separation.

55 focused quote checks cover actual existing dealer-price computation, server fee aggregation,
canonical bindings, strict payload rejection, state/revision/expiry/cursor/model/permission
failures, changed markup/fees/item prices, both clocks, source mutation during reads/pricing,
reload, registry limits, generation-RNG prohibition and coordinator integration. These use
fake server listing/clock adapters and do not establish multiplayer transport behavior.

## Minimal UI integration seams (read-only review)

Current `RLMenuBuyFrame:onClickBuy` / `onClickBuySelected` compute a local displayed price and
confirm before a destination is selected. `startBuyFlow` / `onBuyDestinationSelected` select
the destination and optionally ask about a client-filtered valid subset. The final
`dispatchPendingBuy` has both exact subset and destination and is the smallest dispatch seam
for a gated v2 route. For that route, obtain a server quote for the final sorted IDs/revisions
and stable destination reference, show authoritative amount in the final confirmation, then
send only request ID, those IDs/revisions, destination reference and quote credential through
`RLDealerPurchaseEvent`. Retain staged selection while quote/request is pending; stale quote
refusal must request a new quote and reconfirm. Choosing destination before the first v2
confirmation avoids redundant local-price confirmation; legacy flow can retain its behavior.

`RLAnimalBuyService.buyAnimals` remains a legacy dispatch path: it sends Animal payloads and
negative client price/fee and its success callback locally calls `removeSaleAnimal`. Do not
route v2 listings through this function or invoke that local removal mirror after v2 success.
Use authoritative listing updates, correlate results by request ID, and reuse only request
watchdog/single-consume behavior. `RLAnimalEventRequest` currently correlates by Event class,
so the v2 service must filter exact request ID before publishing a reply; otherwise a late
reply from an expired request could settle a subsequent request of that class. Mixed
legacy/v2 selections must explicitly reject or use separately confirmed batches; a v2 refusal
cannot fall back to the old animal-payload Event.

New prerequisites for a real UI route: replicated sale ID/revision metadata on displayed rows,
a stable destination network-reference resolver with server farm ownership check, a dedicated
quote-request/reply transport (not supplied by the purchase-only Event), service registration,
server quote/transaction adapter and authoritative listing response refresh. Existing trailer
flow has its own destination/capacity filtering and must use the same final quote gate with
server-validated zero fee. Technical cursor/version details stay in diagnostics; the purchase
confirmation only needs selected animals, destination, subtotal/transport and useful refusal.

## Dormant quote RPC and correlated client orchestration

`RLDealerQuoteProtocol.VERSION = 1` and `RLDealerQuoteEvent` provide a separate quote RPC
route. Request: `{requestId,destination,items={{saleId,revision},...}}`; no animal, price, farm,
principal or credential is accepted. Public reply is correlated request ID plus QUOTED with
credential/subtotal/transportFee/amount/remaining `ttlMs`, or REJECTED with a stable reason.
The protocol caps counts/strings/revisions like the purchase protocol and uses exact 17-digit
text for authoritative monetary values. Private principal, cursors and model versions do not
cross the quote reply. Quote projection checks server quote principal/destination/items against
the authorized request. `RLDealerQuote` now reports remaining TTL after authority callbacks.

The quote Event is disabled until its injected service supplies plain callbacks
`authorize(connection,destination)`, `resolvePrincipal(connection)` and
`quote(request,principal,connection)`. The service's quote method can directly return
`RLDealerQuote.issue(store,{destination=request.destination,items=request.items},principal,adapter)`
or `nil, reason`. The client Event only calls optional `service.onReply(reply)`. Unknown
versions, malformed/truncated messages and wrong directions never invoke the quote service.
Root integration must load PurchaseProtocol before Quote/QuoteProtocol and the two Events;
this batch does not touch main or old UI.

`RLDealerClientRequest` is a pure injected client coordinator with
`new(freshClientEpoch, adapter)`, `begin(client,{destination,items})`,
`receiveQuote(client,reply)`, `receivePurchase(client,reply)`, `tick(client)` and `cancel(client)`.
The adapter supplies `monotonicMs`, `sendQuote(request)`, `confirm(publicQuote,respond)`,
`sendPurchase(request)` and optional `complete(result)`. Dispatch callbacks return true only
when dispatched. `confirm` displays the server amount and eventually invokes respond(true)
or respond(false); the purchase request carries the credential and no amount or animal.
Connect QuoteEvent.onReply to receiveQuote and PurchaseEvent.onReply to receivePurchase before
any generic message-center completion. Every callback verifies the exact request ID AND the
QUOTE/CONFIRM/PURCHASE phase. Old confirmations also capture the pending object identity.
A late response or confirmation cannot clear or mutate a newer request, and synchronous host
quote/confirm/purchase completion cannot resurrect pending state.

The adapter's mission update/timer calls tick for 15-second quote and 30-second purchase
watchdogs. Confirmation uses the server remaining-duration hint locally; network transit can
consume more TTL, so server validation remains final. Cancellation is allowed before purchase
dispatch; an already dispatched purchase cannot be presented as cancelled. A purchase timeout
or send exception is a client completion reason, **not evidence of rollback**. No local stock
or money mutation follows it. `client.lastPurchase` retains the exact immutable normalized
request for a future explicit idempotent retry/reconciliation route; never replace an uncertain
request's ID/credential to guess its outcome.

Focused tests: QuoteProtocol 30/30; QuoteEvent 15/15; ClientRequest 33/33. Tests include strict
payload and monetary framing, default disable, actual-connection principal resolution,
authorization failures, wrong-direction messages, service faults, old/duplicate/reordered
responses, old asynchronous confirmations, every phase timeout, exact-ID phase mismatch,
callback exceptions, no-RNG paths and fully synchronous host completion. The actual UI route
stays dormant until an authoritative replicated listing view supplies IDs/revisions and the
real quote/purchase services meet durable ownership gates.

## Actual mission money adapter: witnessed debit, incomplete inverse

`RLDealerMoneyAdapter` is a separate dormant live money adapter, not a T02 change. API:
`new({epoch,mission,farmManager,persistPrepared,persistCommitted})`,
`bind(store,farmId,token,positiveAmount)`, `apply(store,token)`, `observe(store,token)`,
`rollback(store,token)`, `export(store)` and `restore(data,newContext)`. Mission and farm manager
fall back to the actual globals. Money type is the registered `MoneyType.NEW_ANIMALS_COST`;
callers cannot supply an arbitrary debit category. The two persistence callbacks are mandatory
before binding effects. They must synchronously store a plain token receipt to the real WAL
and ultimately the coordinated snapshot; ordinary asynchronous career save is insufficient.

Binding reads the actual farm and captures farm/stats/finances/mission/manager/money-change
object identity, registered money type and money method identity. If the bindings were made
to the current globals, replacing the global mission/manager also invalidates them. Before
effects and after durable prepare, ownership and all witnesses are checked again. The receipt
is marked attempted before calling `mission:addMoney(-amount,farmId,NEW_ANIMALS_COST,true,true)`.
One token invokes the debit at most once, including reentrant money listeners and persistence
callbacks. A same-farm competing token is locked during the live call. A known successful
finished token does not debit again. Returned receipts are detached copies.

Witnesses include actual wallet, NEW_ANIMALS_COST finance, wrapped finance revision counter,
hero earnings/activity and HUD money-change accumulator. A normal return counts APPLIED only
when every observed delta follows the exact existing engine path and the force-show accumulator
is cleared. No-op returns, partial mutations, foreign money movement, owner changes or unreadable
fields become UNKNOWN. Any thrown call remains conservative: a completely unchanged witness
can be NOT_APPLIED, but an effect followed by a throw is UNKNOWN. Neither outcome ever blindly
retries the call. A failed/uncertain prepared checkpoint prevents the call; uncertain final
receipt persistence closes the gate even if the wallet changed. The adapter checks for foreign
mutation during final receipt persistence too. Hidden third-party side effects outside these
engine witnesses are not proven absent by readback.

The actual call ordering is retained in [the FS25 money fixture](../tests/fixtures/fs25_money.lua),
with v1.23.1 decompiled-file SHA256 provenance in its header:

1. FSBaseMission:addMoney resolves the farm and calls Farm:changeBalance.
2. Wallet changes first, then finance and its revision counter.
3. Positive changes also increase `moneyEarnedHeroAccum` when that hero stat is active.
4. Dirty/publication state and MONEY_CHANGED listeners run.
5. addMoneyChange updates HUD totals; force-show broadcasts and clears the accumulator.

This reveals a release blocker for compensation. A standard positive refund through the same
mission API can restore the wallet and matching finance value, but adds hero earnings, advances
the finance revision counter again and emits dirty/publication/HUD notifications. It is not a
complete inverse of the original debit. `rollback` therefore only attempts one positive refund
when the token's original debit is proven and every current owner/witness still matches that
debit. It persists intent first and reads the real refund path afterward, records separate
money/finance/statistics restoration flags, and returns **UNKNOWN / STATISTICS_NOT_INVERSE**
even when wallet and finance are restored. Repeating it never refunds again. Foreign/ambiguous
ownership never enters the refund call. The module never rewrites farm snapshots, hero stats or
other statistics directly to manufacture a complete rollback.

The real purchase adapter must not turn this UNKNOWN into a whole-batch ROLLED_BACK receipt or
set `moneyComplete=true` on that basis. Release requires verified compensation for operating
statistics as well as balances, with listener/HUD side effects accounted for separately. A
future strict compensation path would need engine-accurate same-owner/no-foreign-change proof
and demonstrated safe inverse operations for every affected field; this batch does not supply
or assume that proof.

`restore` validates plain receipt identity and all stored witnesses, retains original epoch
and historical status, and restores every token as UNKNOWN with a closed gate. Even a terminal
WAL receipt plus an identical current wallet is not proof that the debit belongs to the loaded
engine asset generation. There is deliberately no automatic post-load pay/refund or amount-only
reconciliation. A real same-generation engine receipt/coordinated snapshot proof is still
needed, and repeated restores keep the original evidence without inventing that proof.

52 focused checks use the real FS25 mission/farm/finance method excerpts plus stand-ins for
HUD, network, dirty flags and message publication. They cover registered debit arguments,
finance/hero/counter/HUD deltas, ordinary replay, token conflicts, malformed/funds/server gates,
persistence uncertainty, callback mutation, throw-before/after and partial engine steps, foreign
listeners, nested real money calls, farm/stats/global/method replacement, same-token and
same-farm reentrancy, counter wrap, refund non-inverse statistics, repeated restore and corrupt
witnesses. These are executable call-path evidence, not current installed-game, cross-asset
atomicity or multiplayer recovery certification.
