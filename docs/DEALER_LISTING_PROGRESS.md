# Dormant D4 listing and clock core

These modules are not loaded or connected to AnimalSystem, network, save XML or purchase events.
Full-v2 dealer generation remains closed. Their table snapshots are persistence payloads;
they do not independently provide durable writes or a complete atomic transaction.

## Clock adapter

`RLDealerClock.new(initialMonths)` creates the monotonic month clock. `advanceHours(clock,
hours, daysPerMonth)` and `advanceSegments(clock, segments)` consume explicit elapsed
segments with their actual calendar lengths. Segments must split when month length changes.
Invalid segments reject the whole call. No game time sampling occurs in reads.

`checkpoint(clock)` returns the latest crossed quarter-month and skipped checkpoint count
once. It deliberately does not enumerate old batches. The future adapter must progress and
withdraw current stock, fill only empty slots at that checkpoint, then durably save clock and
stock together. If this operation fails, restore both snapshots; checkpoint consumption alone
is not durable replenishment. `export/restore` retain the consumed checkpoint.

## Listing adapter

`new(namespace)` uses a caller-persisted save-unique namespace plus persisted sequence for
stable sale IDs; no RNG or game animal identity allocation occurs. `createDraft` consumes a
complete selected payload and lifetime class. `list` is the only DRAFT→LISTED operation.
Records have `recordRevision`, `listedAtMonths`, `expiresAtMonths`, `lastUpdatedAtMonths`
and `lastProgressedAtMonths`. The latter is distinct: a lock mutation must never skip growth.
One record owns `MONTH_CHECKPOINT` rotation only. Sold/withdrawn/quarantined records cannot
be relisted. Lifetime classes are UNWEANED 0.5, GROWING/STORE/REPLACEMENT 1,
BREEDING/PRODUCTION 2, SHORT_CYCLE 0.5 and HORSE 2 months. External buyer lambda is zero.

`progress(registry, saleId, nowMonths, advance, eligible)` passes a detached payload plus
previous physiology time to `advance`. That callback owns normal source-farm feed, health,
birthdays and reproduction, exactly once; it returns a complete replacement payload.
Failures quarantine without installing partial payloads. Eligibility is checked immediately,
and expiry or lost eligibility withdraws. Neither callback may mutate external objects;
this table-level rollback cannot compensate callback side effects. No generation occurs here.

`get` and `listRecords` return copies and never progress physiology or use RNG.
`reserve(..., expectedRevision, requestId, nowMonths, monotonicReal, timeout)` and
`markSold(..., requestId, reservedRevision, nowMonths, monotonicReal)` require physiology
current at the supplied month. The adapter must independently validate eligibility first.
Reservation increments revision; commit consumes that new revision. Real-time units must
match the caller timeout (the purchase coordinator uses milliseconds). `release` may release
pre-commit locks by owner or timeout. Once durable ownership work starts, the transaction
adapter must prevent timeout release/stealing until its journal resolves ownership.

## Purchase and recovery seam

The dormant `RLDealerPurchase` adapter can implement `readListing(saleId)` using `get`.
`validateListing` must reject `lastProgressedAtMonths ~= context.currentClock`, invalid
physiology/model, current ineligibility, expiry or unresolved ownership. Reads stay pure;
a scheduler advances source stock before purchase validation. The coordinator does not
reserve records itself: its durable `apply` adapter must atomically recheck all records,
permissions, quote, destination, capacity and funds; reserve the sorted whole batch; persist
journal and record revisions; prepare transfer ownership and compensate partial failures.
It must never commit only a prefix by looping over this registry's single-record methods.

`export` copies all listing data. `restore` validates schema and rotation, preserves identities
and quarantines saved RESERVED records as TRANSACTION_RECOVERY_REQUIRED, retaining the
saved lock in `recoveryLock`. A new process has a new monotonic clock epoch, so saved locks
are never auto-expired. Journal reconciliation must establish COMMITTED or compensated
ROLLED_BACK before a future recovery adapter can resolve these quarantined entries.
That game ownership recovery adapter is still missing; no unquarantine shortcut is provided.

`migrateStock` is explicitly stock-only, uses stable `stockKey` identities and explicit
classification callbacks, and stores migration version 1. VALID records are retained;
HARD_INVALID withdraws; unreliable/unknown/missing-mod/corrupt records retain raw stock in
quarantine. Classification does not recreate birth/history or remap breed. Failure of the
whole import leaves the registry unchanged; subsequent completed migrations do not reroll.
A VALID classification is adapter evidence, not proof supplied by this registry.

## Verification

Focused tests cover changing 1/3/7-day month lengths, quarter-month checkpoints and skipped
batches, identity/revision/lifetime rules, pure reads, detached failure rollback, immediate
withdrawal, real-time lock races/timeouts, saved reservation recovery quarantine, migration
idempotence/raw preservation and lock mutation versus physiology cursor. These are pure
module tests, not installed-game, network, offspring or durable ownership coverage.

## Dealer stock persistence document

`RLDealerPersistence` uses `rm_RlDealerStockCheckpoint.xml` with root
`rlDealerStockCheckpoint`, schema 1; it never calls the T02 ledger document writer or
changes its root/schema. It reuses only plain-data check, canonical serialization,
parse, percent encoding and checksum primitives. Snapshot and serialization limits
are independently bounded. There are no player animal migrations or pool generation calls.

`capture(meta, clock, listings, sourceRecords, purchaseExport, participantMarkers)`
creates a detached strict snapshot. The metadata contains `lineage` (DL prefix),
`generation`, `parentGeneration` (exactly generation - 1) and deterministic `checkpointId`.
Caller must export runtime purchase stores before capture; no functions/locks leak into data.
The snapshot contains clock, listing registry, source records, purchase journal and external
participant markers. `validateSnapshot` invokes the actual component validators, checks
source/listing/journal cursors and identities, and checks that a committed purchase refers
to SOLD listings owned by the same request. It does not establish actual game ownership.
Source subtype resolution is explicit: a resolver runs strict `SourceState.restore`; without
it the read result says `sourceResolution=NOT_CHECKED`. Unknown installed mods must use
the resolver and retain quarantine, never silently remap source physiology.

The only external participant roles are `placeables`, `vehicles` and `farms`, corresponding
to `placeables.xml`, `vehicles.xml` and `farms.xml`. Source dealer stock and its journal are
inside this checkpoint; player destination pens/trailers and money remain in their actual
engine save files. `marker(lineage,generation,participantData)` produces a marker containing
lineage/generation/checkpointId plus a content digest. `validateParticipants` requires the
complete exact role set, matching current lineage/generation/checkpoint and actual digests.
The adapter must read these markers from the participants' own saved files and verify their
content digests against actual canonical participant data. Passing copies of the checkpoint's
markers is only suitable for a unit fixture and provides no multi-file save evidence.

`writeDocument(xml,snapshot,actualParticipantMarkers)` validates everything before writing
and requires a fresh XML document (to avoid retained old chunks). It returns the document
digest. `commitMarker(snapshot,digest)` produces an external career commit marker that binds
the dealer document digest and the whole external participant marker set. This marker belongs
in `careerSavegame.xml`, written only after all participating save writes complete. The
checkpoint does not embed its own hash, avoiding a circular digest.

`readDocument(xml,actualParticipantMarkers,resolver,careerCommitMarker)` checks schema,
length, encoding, checksum, snapshot versions, strict component validation, complete external
participant markers and the career commit marker. Invalid/unknown data returns
`nil, reason, {state=QUARANTINED, scope=DEALER_STOCK_ONLY, raw=...}`; raw bounded header/chunks
are retained for recovery. A missing file never recreates or rerolls stock. Reserved listings
remain recovery quarantine; nonterminal purchase journals keep ownership recovery closed.
A mismatch isolates stock rather than touching player animals or repairing past physiology.

These APIs are a validation/persistence core, not a game save hook or an atomic save guarantee.
The root game adapter still must stage writes, manage generation allocation/lineage lifecycle,
verify participant content, publish the career marker at the end of the actual engine save,
and reconcile source/destination/money ownership if an interrupted save leaves a mixed set.
Tests use an in-memory XMLFile stand-in and synthetic participant data; they verify validation
rules and exact serialized stock continuity, not real disk durability, engine save ordering,
player pen/trailer ownership or money compensation.

## Engine checkpoint hooks

`RLDealerCheckpoint` provides protected hooks for the actual FS25 save method signatures.
Root integration must call `install()` after RLRM's own `FSCareerMissionInfo` append so
`onSaveEnd` follows `AnimalSystem:saveToXMLFile`. It prepends save begin, marks the real
placeables/vehicles/farms open XML documents using independent `rlDealerStockCheckpoint`
attributes, appends dealer document writing plus career commit publication, then appends
`SavegameController:onSaveComplete` for final disk verification. The career document is
filename-less during the pass; only the engine's later serialization writes its commit
marker to disk. `onSaveEnd` therefore leaves `WAITING_ENGINE`, with admission closed.

`reset(isServer,runtime)` creates the mission gate. The runtime supplies
`getSnapshot(meta,participantMarkers)`, `acceptLoaded(snapshot,restored)` and a physical
subtype `resolver` when source records exist. `setRuntime` is available for explicit staged
configuration. Default absent runtime or unarmed save paths write no dealer files/markers.
An empty checkpoint load becomes UNARMED, and explicit `arm(saveUniqueDLLineage)` permits
the first save but does not open admission. Only verified final engine completion or a
verified existing disk load reaches READY. Runtime rejection, unresolved source models,
interrupted ownership and corrupt/mixed files keep recovery closed. No automatic purchase
activation, ownership reconciliation or animal/money compensation occurs here.

The real storage implementation uses XMLFile create/load plus bounded binary reads of
`placeables.xml`, `vehicles.xml` and `farms.xml`. Their participant digests cover the exact
saved XML bytes, including generation markers; digests are kept in the separate dealer
document, avoiding self-referential file hashes. Final validation rereads every participant,
the dealer document and the engine-written career marker from the final save directory.
The generic persistence `marker(data)` helper hashes canonical fixture/data values; the
checkpoint hook hashes actual file bytes and verifies that same representation on load.
T02 roots, files and marker attributes remain independent.

Overlapping saves while WRITTEN is pending close recovery without allocating a newer
generation. Explicit late-generation completion cannot commit a newer pass; even an
untagged callback must match the current generation/document digest on actual final disk.
A hook exception is caught so the engine save continues, while the dealer gate remains
closed. Failed checkpoints cannot be laundered by subsequent saves or `arm` calls. The
runtime must freeze new dealer progression/transactions while admission is closed; a
partial runtime import must also be avoided by `acceptLoaded` implementation.

This asynchronous save process is **not** the synchronous durable checkpoint callback
required by `RLDealerPurchase`. It cannot be passed to that coordinator as proof that a
journal was durably written before an ownership side effect. The purchase adapter remains
closed until its dedicated ownership/durable-journal implementation is supplied.

Checkpoint tests exercise begin/snapshot, write, immediate readback, engine result, final
content changes, missing career publication, mixed generations, late/overlapping completion,
load/runtime refusal and protected exceptions. They also drive the hooks through checked-in
FS25 save-pass excerpts and RLRM's actual career append to verify method signatures and
source-save ordering. Storage and engine completion are explicit in-memory stand-ins; these
checks do not establish filesystem durability, async engine crash behavior, multiplayer
purchase safety or actual installed-map validation.

Terminal listing timestamps no longer pin a source animal that continues feeding after
withdrawal. LISTED/RESERVED require exact source physiology cursor equality; draft/withdrawn/
quarantine allow an older cursor, never a future one. SOLD records may retain a transaction
snapshot or refer to a source that has left the farm; game ownership remains the transaction
adapter's responsibility. A regression advances real SourceState physiology after withdrawal
and verifies the complete new stock document remains saveable.

`onMissionStarted(mission,evidence)` also accepts the existing animal identity-repair report.
If `evidence.identityRepairs > 0` and a dealer checkpoint exists, the verified document is
retained as quarantine evidence and the runtime import is not called: prior ownership
receipts cannot authorize repaired live identities. An empty new save remains UNARMED.

## Real pen/trailer target ownership adapter

`RLDealerTargetAdapter` owns only the target queue effect of an already authorized,
prepared batch. It does not own source animals, money, permission/capacity checks, pricing,
WAL writes or game-save durability. The main purchase adapter must coordinate those and
accept a receipt only after its whole ownership plan is verified.

`bind(destination, preparedRealAnimals, optionalAllOwners)` requires a server pen/trailer,
readable dense actual member lists, empty add/remove queues, complete unique business
identity (birth country, business herd `farmId`, `uniqueId`), detached real individual
objects with sale metadata already cleared, and unchanged target members. Business
`farmId` is the source herd identity and may be a six-digit string; it is never remapped
to `destination:getOwnerFarmId()`. The destination player farm index is independently
frozen and rechecked for ownership/permission integration. Snapshots retain all readable
business fields exactly, ignoring only engine IDs, cluster link and dirty flag. Cyclic,
opaque or excessive-depth state fails closed instead of being truncated.

`apply(binding)` calls `addPendingAddCluster` for each original prepared object, checks
that only its own exact queue entries exist, calls `updateNow`, and re-reads actual live
members, full identities, physiological snapshots, other animals and queues. A silent
successful `addAnimals` or `pcall` return never proves transfer. Partial/throwing flushes
return observed added/missing indices and keep reconciliation ownership with the caller.
The adapter does not call destination convenience `addAnimals` methods.

`observe(binding)` is pure and reports `known`, `added`, `missing`, `othersIntact`,
`fieldsIntact` and `queuesClean`. It refuses a replaced object with the same business
identity. `rollback` clears only exact queue entries previously claimed by this binding
and removes only its actual batch objects through the normal remove queue/flush. Unknown
foreign queues (including false values), changed unrelated animals, identity collisions
or listener callbacks stop compensation before an unsafe flush. No unrelated object is
removed or recreated. `verifyRestored` requires target batch absence, original detached
objects remaining unowned, unchanged other members and empty queues.

`exportBinding` returns plain immutable keys/business snapshots suitable for the WAL;
`rebind(destination, evidence, allOwners)` strictly validates that saved evidence and
reconstructs slots from full stable identity after load. Batch slots are in `binding.entries`
with `animal`, `key` and `snapshot`; missing partial-transfer slots have `animal=nil`.
Rebind requires an explicit complete pen/trailer owner inventory and never assumes a
missing destination object has disappeared from the world. `scanOwners(allOwners)` is a
pure helper that rejects duplicate identities within or across pens/trailers and reports
each unique owner/object. Caller inventory completeness remains a caller responsibility.
Optional allOwners passed during normal bind enables the same world checks on every later
observation/compensation. Without that inventory, regular bind proves only target-local
membership, so the main adapter must independently scan the world before accepting its
whole-batch ownership receipt. Rebound bindings always retain the complete inventory.

Tests use pen/trailer cluster stand-ins matching the real direct-individual queue branch.
They inject partial/silent additions, queue refusal, throwing flushes, foreign enqueue
listeners, unrelated field mutation, identical-ID impostors, unreadable lists and reload
objects. They also check cross-owner duplicates, source herd identity preservation and
refusal to declare rollback when an original object acquired another owner. These checks
cover queue/observation semantics, not actual engine visuals, network propagation,
capacity or funds, multiplayer races or durable transaction recovery.
