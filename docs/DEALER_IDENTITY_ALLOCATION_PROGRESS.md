# Dealer identity allocation continuation

Checkpoint 2026-10-12, branch `feat/dealer-history-v2`. Full v2 stays disabled.

## Local engine evidence

`RLAnimalUtil.toKey(farmId, uniqueId, country)` has no animal type component.
`RLAnimalUtil.padId` (scripts/utils/RLAnimalUtil.lua:161) maps raw 1 and raw
10001 to the same string `10001`. `generateUniqueId` (line 203) then computes
its check digit from the same herd and padded string: these raw values produce
the same complete individual ID in the same herd. Increasing the raw counter
is therefore insufficient proof of a new full identity.

`AnimalSystem:getNextAnimalIdForFarm` (scripts/animals/husbandry/
RealisticLivestock_AnimalSystem.lua:2194) increments a counter per animal type.
`_takeSaleAnimalId` (line 1666) and legacy AI creation (line 3236) also mutate
per-type counters. Two types in one herd/country can use the same raw value,
while the global identity key deliberately does not distinguish types.
Missing farm/type state may return 1; that fallback cannot authorize allocation.

The native country/herd counters load from and save to `rm_RlAnimalSystem.xml`
(lines 1154–1196 and 1283–1310). Dealer persistence currently requires checkpoint
participants `placeables`, `vehicles`, `farms` only (RLDealerPersistence.lua:9).
It does not yet prove atomic alignment of the native counter file with dealer
selection, source ownership and money. A counter increment is not a durable
allocation receipt.

`Animal:setUniqueId` (scripts/animal/RealisticLivestock_Animal.lua:468) routes
cluster-owned births to `farm.stats:getNextAnimalId(type)` and unattached sale
births to the AnimalSystem country/herd counter. FarmStats uses independent
cow/pig/sheep/horse/chicken or type-name counters and saves them with the herd
ID under farms statistics (scripts/farms/RealisticLivestock_FarmStats.lua:29–109).
A missing owner/farm instead writes identity `("1", "1")`; allocation must never
interpret that fallback as a new reserved identity.

Ordinary unborn player animals receive IDs at actual birth through
`child:setUniqueId()` / `child:setUniqueId(animal.farmId)`
(AnimalReproduction.lua:959–967). Private source birth instead preserves the
previously fixed fetus identity. Any allocation design must account for both
paths, rather than reserve adults only.

## Required next seam

A durable allocator must reserve complete `(farmId, uniqueId, country)` keys
for every adult and fixed fetus before publishing prepared selection. Its
request receipt must support exact retry without allocating again, and retain
consumed/reserved keys after death, sale, withdrawal and save/restore. Scanning
only current world/private objects, or reconstructing a maximum from live IDs,
cannot establish that an absent historical key was never consumed.

Native raw counters and formatted IDs need an explicit shared allocation domain
or proven exclusive source herd domain. A ledger confined to dealer generation
cannot prevent ordinary births or legacy sale/AI generation from colliding with
it. Resolve all allocation entry points and establish migration evidence before
changing runtime gates. Do not change legacy ID formatting as part of a dormant
provider patch; that affects existing animal references.

Cross-save recovery must distinguish reserved, admitted and consumed keys, bind
reservation receipts to fixed selection, and reject rollback/mismatched native
counter checkpoints. Unknown or interrupted writes must hold generation with
before/staged/current evidence. Existing Factory provenance is selection data,
not this durable reservation evidence.

The new World adapter proves current inventory conflicts only. It does not
claim lifetime uniqueness or install an allocator. The next implementation must
first establish ledger schema, checkpoint participants and ordinary-birth/legacy
allocation integration; installed-map and interrupted-save acceptance remain open.
