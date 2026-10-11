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

`RLHusbandryProfiles.checkAnimal` currently applies profiles and writes subtype filters;
it cannot be described as a pure quote/read callback. A shared read-only predicate should
evaluate the same rule without applying/logging/writing. Existing lifecycle application
remains responsible for changing profiles. Local engine API evidence is in
`Specializations/PlaceableHusbandryAnimals.md` and `Specializations/LivestockTrailer.md`;
existing actual movement validation is in `scripts/animals/shop/events/AnimalMoveEvent.lua`.

These providers are independent capability implementations, not evidence of installed-map,
third-party container, multiplayer or save-interruption acceptance. Runtime hookup,
durable identity allocation, listing UI and cross-save actual money/ownership recovery
remain separate gates before `CHANNEL_ENABLED` may change.
