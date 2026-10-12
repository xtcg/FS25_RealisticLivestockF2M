# Dealer runtime capability continuation

Checkpoint 2026-10-12, branch `feat/dealer-history-v2`.

Actual owned calving/maternal retirement is committed as `9fadf74`, with full regression
3464/3464. The fixed-selection Factory/OwnedAdmission batch passes full regression 3562/3562;
see `DEALER_D3_D4_IMPLEMENTATION.md` for the interfaces, test result and gates.
No full v2 runtime channel is enabled.

## Authoritative world inventory

The world adapter must enumerate all farms through
`mission.placeableSystem.placeables` and `mission.vehicleSystem.vehicles`, rather than a
farm-filtered shop UI. All loading/deletion registries must be complete and empty. Pen and
trailer objects need actual cluster systems and consistent animals/getClusters inventories.
The first implementation rejects nonempty add/remove queues; it must never call updateNow
to enumerate identities, because that constructs animals and assigns IDs.

Global identity scanning includes more than pen/trailer owners: `spec_rideable.cluster`
holds a ridden animal, and `animalSystem.animals`/`aiAnimals` hold legacy dealer domains.
Every actual pregnancy and supplied private encoded fetus must be examined. Ordinary
negative-age player fetuses may legitimately have no ID until birth and do not yet occupy
an individual key. Fixed-ID source fetuses have no calendar birthday yet; their source
birth service explicitly uses the dam's country, so that known service rule supplies their
identity country. Do not guess missing identity country for arbitrary world objects.
The identity key is `RLAnimalUtil.toKey(farmId, uniqueId, country)`; herd identity is distinct
from player-farm authorization. Existing private ownership is scanned once, with external
world identity conflicts rejected. Unproven cross-domain aliases must hold recovery.

Local primary reference entry points:

- `GDN_FS25_Reference/script/Placeables/PlaceableSystem.md`: world registration and loading/deletion arrays.
- `GDN_FS25_Reference/script/Vehicles/VehicleSystem.md`: world vehicles and pending load/delete arrays.
- `scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua`: animals/aiAnimals save domains.
- `scripts/animals/husbandry/cluster/RealisticLivestock_AnimalClusterSystem.lua`: mixed pending adds, delayed removals, getPendingDelta.
- `scripts/vehicles/specializations/Rideable.lua`: real ridden-animal cluster.
- `scripts/dealer/RLDealerSourceOwnership.lua`: actual/encoded pregnancy mapping.

## Authoritative capacity

The callback must check the complete batch from server SourceState: current subtype,
age/gender/castration, construction and pen rules, actual occupied/free/max slots, empty
pending queues and target membership in the complete world inventory. Trailers require
one animal type for the whole batch and agreement with any existing trailer type.
Capacity must count the whole batch once, rather than letting each animal see the same
free slot.

`RLHusbandryProfiles.checkAnimal` applies profiles and writes subtype filters. The new
`checkAnimalReadOnly` evaluates the shared predicate without applying profiles, logging
or populating rule/config/construction caches. Existing lifecycle application
remains responsible for changing profiles. Local engine API evidence is in
`Specializations/PlaceableHusbandryAnimals.md` and `Specializations/LivestockTrailer.md`;
existing actual movement validation is in `scripts/animals/shop/events/AnimalMoveEvent.lua`.

These providers are independent capability implementations, not evidence of installed-map,
third-party container, multiplayer or save-interruption acceptance. Runtime hookup,
durable identity allocation, listing UI and cross-save actual money/ownership recovery
remain separate gates before `CHANNEL_ENABLED` may change.

## Implemented dormant providers

`RLDealerWorld.new({isServer=true, mission=...})` provides `allOwners` and
`checkGlobalIdentities`. It requires the actual current server mission, holds on
loading/deletion/pending cluster queues, and scans public owners, ridden animals,
legacy stock and supplied private encoded ownership. It pins owner cluster and
registry references, ordered members and backlinks across callbacks. Fixed source
fetuses require the actual source-birth version and dam country rule; placeholders
including `0`, `0-0`, `1-1` are rejected. Focused verification: **71/71**. It also freezes scanned identities, pregnancy
members, rideable references and legacy registry members against late callback changes.

`RLDealerCapacity.new(ctx)` returns a read-only whole-batch predicate. It proves
current listing/source/subtype/physiology, complete authoritative owner inventory,
pen construction/profile/map rules, or trailer whole-batch type, plus actual
occupied/free/max slots. It rejects synchronous member/cluster/queue changes and
source ownership changes caused by getters. Focused verification: **38/38**,
including the real PurchaseAdapter/Source/Target/Money/Journal composition buying
two animals into exactly two remaining slots alongside an existing animal. All
four capacity callbacks in that composition run before transfer; the final money
debit occurs once. Engine container capacity methods in these tests are local GDN
stand-ins, not an installed-map acceptance run.

SourceFactory now rejects placeholder full identities before construction;
focused verification **43/43**. The identity allocation investigation is recorded
in `DEALER_IDENTITY_ALLOCATION_PROGRESS.md`: native formatting is not injective
and native counters are separated by type, so live conflict scanning does not
prove durable lifetime identity allocation. No allocator or runtime gate is enabled.

Verification checkpoint: complete regression **3673/3673** passed
(`/private/tmp/rlrm-dealer-world-capacity-final-tests.log`). The native missing-owner
Factory guard was completed after that run had loaded the Factory test file;
its final focused rerun passes **43/43**, and dependent OwnedAdmission passes
**56/56**. Final World and Capacity reruns pass **71/71** and **38/38**.
All **45** dealer/loader/changed bridge files parse in stock Lua 5.1;
`git diff --check` is clean. No installed-game acceptance is claimed.
