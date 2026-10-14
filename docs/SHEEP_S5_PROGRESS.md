# Sheep S5: nutrition, ewe milk, body condition and finishing (S5 + S5b)

Status 2026-10-14. Branch `feat/sheep-s5-nutrition` (worktree `rlrm-sheep5`), rebased on `origin/dev` `bbb4573` (S3 #53, S4 #54, dealer #55, breeding value #56). Decisions: [S5 checklist](../../FS25_SheepBreeds_离线准备_2026-10-11/S5_待设计与决策清单.md) D1–D9 and the [finishing design](../../FS25_SheepBreeds_离线准备_2026-10-11/sheep-finishing-design-v1.md) F-D1–F-D5, all approved by the user. The user asked on 2026-10-13 to develop from the checklist.

**Four states:** code committed — yes; in a run package — no; automated checks — pass (see Verification); game test — not done. **Sheep v2 stays OFF** (`weightProfiles.xml` SHEEP `enabled="false"`): seven calibration checks fail (after the 2026-10-14 review, below) and nothing has been tried in game.

## What the code does

| Part | Implementation |
|---|---|
| Species config | `scripts/animal/RLSpecies.lua` picks a config's `<species name="SHEEP">` section for an animal, pen, subtype or type name; cattle, goats (`excludeBreeds="GOAT"`) and every other type read the root, the same table as before. `feedProfiles.xml` and `bodyCondition.xml` each have a SHEEP section; the body section is sent to clients with the rest of the config. |
| Coverage | `weightProfiles.xml` SHEEP `nutrition="REAL"`: sheep are on v2 only while the real-equivalent nutrition model runs and both species sections are valid (`RLGrowth.speciesNutritionReady`). Under the old model they keep the old rules. A sheep is stepped only by its pen's mode: in a pen that does not run it this hour (a goat in it, no trough) it takes the old weight rule, never the budget on the old feeding (`RLGrowth.needsRealNutrition`, declined by `RLGrowth.step`). `RLBodyCondition.isCoveredType` covers sheep only where v2 does. Sheep body condition starts at birth (`calfLegacyUntilAgeMonth 0`). |
| Feed | `RLFeed.registerSpeciesFeeds` adds SILAGE and the grains and PEA as SHEEP groups, marked `rlSpecies`. The old rules never eat them, and a trough accepts them only while its pen eats them (`RLFeed.isSpeciesFeedOpen`): the mode on, the sheep curves on, and no uncovered animal (a goat) in the pen. |
| Ewe milk (D1, D4) | No rearing pen and no trough milk. A ewe nurses while her lambs on milk are in her pen (`RLFeed.getNursingDams` returns the dams and the suckled count). Her milk is the AHDB Table 28 row for her system (lowland / hill by breed) and the number she suckles (single, twin; three or more share the twin row), as a step per month of the youngest lamb's age (`RLFeed.getDamMilk`). Her budget pays it (8.3 MJ ME a kg) with the early-lactation reserve rule on her lambs' age; her lambs share one pool; nothing is stored, sold or given to another ewe's lamb (`milkCollect` 0). |
| Weaning (D2, D3) | Nursing curves by age: milk ends at 3 months; solids and their worth rise to 1 by then. An orphan has no milk at all; from 2 months, once it has eaten at least 0.22 kg DM of concentrate a day for 3.5 model days in a row (AHDB: 250 g of creep a head a day for 3-4 days; `rlGrowth.creepDays`, saved and streamed; grass does not count; a step below starts the count again; once reached it is kept), it is weaned early. Younger, its pen stays in the mode and it lives on what it eats (no SUCKLING_CALF fallback, no milk made for it). `RLFeed.countUnnursed` drives one notification when lambs on milk are away from their ewe (`rl_feed_lambNoDam`). |
| Creep (D8) | A lamb at foot eats at most 0.35 kg DM of concentrate a day (about 0.4 kg fresh): planner limit `CREEP`. |
| Adaptation (D7) | 14 days to 90% concentrate; an unadapted lamb may take up to 50% of its DM as concentrate. This is a game rule: FAS's 50% is barley within the concentrate mix. |
| Physiology | Lamb maintenance 0.475 MJ/kg^0.75 to 6 months, moving to the ewe's 0.37 by 12 months. Growth cost 33 MJ ME per kg of frame at 40 kg, linear in weight (exponent 1.0, floor 14). By sex: rams x0.80, wethers x1.00, ewe lambs x1.25. Newborn lambs start lean (reserve 0.25, fat class 2). |
| Body condition, fat (S5b) | Reserve capacity 0.48 (one BCS point = 12% of reference weight), reference BCS 3. Lambs under 12 months show EUROP fat classes 1/2/3L/3H/4L/4H/5; grown sheep show BCS. The finishing target applies to ram lambs, wethers (x + 0.09) and ewe lambs (x + 0.18); from 12 months (`youngUntilMonth`) a maiden ewe keeps the heifer's rules (ceiling 0.55) and shows BCS. A ewe lamb is read against her breed ram's market weight. The meat factor is set per class (3L 1.00, 3H 0.99, 4L 0.97, 4H 0.955, 5 0.90, 1 0.95). Verdict: ready at the market weight from class 2, over-fat from 4L. Under AUTO, lambs of both sexes under 12 months eat freely. Sheep BCS never changes conception in this batch (`fertilityEffect 0`, D5). |
| Display, diagnostics | Pen info rows for ewes and lambs. The menus' feed rows, ration preview and forecast work on sheep pens. `rlFeed*`, `rlBc*` and `rlPen*` reports include sheep pens; the pen report adds each lamb's milk cap, early weaning and fat class. All 17 languages have the new keys (de and Chinese translated, the others English, as before). |

## Calibration (`python tests/sheepcalib.py`)

The results are in `../FS25_SheepBreeds_离线准备_2026-10-11/s5-logs/calibration-2026-10-14.{txt,json}`. They come from the real modules at a 1-day month; the month-length checks also run at 7 and 28 days.

| Gate | Result |
|---|---|
| V1 R1 early single ram lamb, 2.8–3.3 months to its market weight | Landrace 3.04, Suffolk 3.08, Swiss Mountain 3.25 PASS; **Texel 3.33 FAIL** (the window edge; the breed's own S4 potential is 2.9) |
| V1 creep feed conversion | Reported both ways, because the source does not say which (checklist): 0.6–0.7 kg per kg of all gain, 5.9–6.9 per kg of gain above grass alone (candidate 2–4) |
| V2 R2 milk and grass, flock mix weighted by lambs (lowland 30% of ewes with singles = 17.6% of lambs, hill 70% = 53.8%) | Landrace 5.03, Texel 5.43 PASS. **Hill FAIL**: Steinschaf 6.56, Black Welsh 6.41, Blackface 6.13 (window 5.1–5.5 ± 0.5) |
| V3 R3 grass allowance + 0.25 / 0.5 kg barley | 1.66x, 2.03x grass alone PASS (Teagasc 1.63x / 1.99x) |
| V4 R4 housed store ram lamb | Feed conversion 10.3 kg per kg carcass PASS. **ADG 300 g FAIL** (220–280; intake 1.48 kg DM = Teagasc's) |
| V5 over-fat | Past the reference on ad lib feed: 4L / 4H, meat 0.970 / 0.955 PASS |
| V6 ram : wether : ewe lamb ADG | 1 : 0.88 : 0.76 PASS |
| V7 typical lamb | 3L meat factor exactly 1 (`test_sheep_s5_config`, `test_sheep_s5_nursing`) PASS |
| Ewe year (one ewe, lowland twins on grass, lambs leave at 3 months, mated at 7, housed on silage the last 2 months of pregnancy) against the checklist's D6 | **Weaning 2.30 FAIL** (≥ 2.5); **mating 2.98 FAIL** (3.0–3.5: a dry ewe's target is the reference reserve, BCS 3.0); lambing 2.92 PASS (3 ± 0.25) |
| Late pregnancy alone (twins from BCS 3) | Silage 2.95, silage and barley 2.97 PASS. Energy reported, not judged: 20.1 MJ a day (AHDB Table 8's 18.3 MJ is a 70 kg ewe). Hay alone 2.75 (INFO) |
| V8 month length | Same route at 1 / 7 / 28-day months within 0.8%; the pool closes every step to 1e-9 PASS |
| V9 cattle and other species | A/B against dev `bbb4573`: 396 legacy-budget cases (50,688 values) and 640 real-mode cases (suckler, dairy, bulls, shortage, rearing; 1- and 7-day months): 0 differences PASS |
| V10 300 sheep | 100 ewes with twins, 28-day month: 13 ms a game hour PASS |

### Why the failures stay open

1. **Hill lambs.** The ewe's milk uses AFRC's hill rows, which describe hill ewes on hill grazing. The game's cut grass is a mid-quality pasture (GRASS_WINDROW, ME 9.7 MJ/kg DM, shared with cattle), not spring grazing at 11–12. The checklist forbids changing feed composition to meet a target. Options: accept the gap; give hill breeds the lowland row on lowland feed; or revisit the C-grade target.
2. **R4 ADG +7%.** At Teagasc's intake the model gives 300 g a day, close to AFRC's equations. Teagasc's lambs grew less (248 g). Raising the cost of gain would push R1 out of its window.
3. **Texel R1 3.33.** This is the breed's own S4 potential (2.9 months) plus the same milk/creep lag as the other breeds.
4. **Ewe weaning BCS 2.30.** Twins on grass take her from 3.0 to 2.3 in three months; FAS's lowland target is 2.5. Options: accept; feed the ewe concentrate in early lactation (a management choice, the target AUTO does not take); revisit the mobilisation rule.
5. **Ewe mating BCS 2.98.** A dry ewe on GROW returns to the reference reserve (BCS 3.0) and no further; FAS's lowland band is 3–3.5. Options: accept 3.0 as the band's floor; raise the sheep reference reserve; give dry ewes a flushing target.

## Review 2026-10-14 (PR #57 at `b8b07c6`)

| Finding | Fix |
|---|---|
| P1 a sheep in a mixed pen (out of the mode) still ran the v2 budget on the old feeding | `RLGrowth.step` declines types that need the real-equivalent mode (`RLGrowth.needsRealNutrition`); such a sheep takes the old weight rule that hour. `covers` is unchanged (profile coverage and running eligibility apart, no recursion in the pen gate). Test: a lamb with a goat for 6 hours keeps its development, age clock and last step; the test fails without the fix |
| P1 early weaning took the first reading as the average and counted grass | `creepDays`: model days in a row at 0.22 kg DM of concentrate a day, 3.5 needed, kept once reached. Settings renamed `readyCreepKgDMPerDay` / `readyDays` (unreleased branch: no savegame to migrate) |
| P2 flock weighting used ewe shares as lamb shares | Weighted by lambs (see V2); matches the review's recomputation |
| P2 the ewe cycle passed on relaxed thresholds | D6 restored (weaning ≥ 2.5, mating 3.0–3.5, lambing 3 ± 0.25) on one ewe through a whole year; two new FAILs |
| P2 a grown maiden ewe still read the ewe lamb's finishing target | Body condition `youngUntilMonth="12"` (SHEEP): from 12 months no fat class, no finishing target, heifer ceiling |

Formula notes taken from the review: ewe milk DM 19% / ME 25 MJ/kg DM remain a proxy (implied ME/GE about 94.75% against Šebek's GE, no separate source); 8.3 MJ/kg is an approximation for Table 29's diets; lamb maintenance 0.475 is a candidate between the paper's 0.482 / 0.466; growth cost 33, the sex factors and the fat class map are calibration design, not verified physiology.

Re-run: calibration 16 PASS / 7 FAIL (`s5-logs/review-2026-10-14/calibration.{txt,json}`); cattle A/B 0 differences (396 legacy-budget, 640 real-mode); sheep tests under Lua 5.1 19 / 40 / 24; full suite 3906/3906 in about 3 minutes (`s5-logs/review-2026-10-14/tests-full.log`; redirected to a file, Python buffers its output, so use `python -u` to watch it live).

## Game compromises added in S5 (four columns in the finishing design §4)

SHEEP-C09 to C17 are recorded in the finishing design §4 (2026-10-14 addendum): monthly milk steps; lean newborn reserve; growth cost by sex; AUTO finishing young females; goat pens stay on the old rules; creep gate; the notification comes the hour after a separation, not at the move; ewe milk composition is a proxy; the hill gap.

## Verification

- Full suite: see the 2026-10-14 review below for the current run (`python tests/run.py`). The new files are `test_sheep_s5_config` (19 checks), `test_sheep_s5_nursing` (40) and `test_sheep_s5_settings` (24).
- Cattle A/B: `python tests/sheep_s5_ab.py --baseline bbb4573 --out …` (legacy budget, Lua 5.1) and `python tests/feed_ab.py --baseline bbb4573 --out …` (real-equivalent mode); both show 0 differences.
- The three sheep test files also pass under Lua 5.1 (19 / 40 / 24).
- Not done: game test, W-DEBUG/TestDiagnostics sheep scenario (separate mod), multiplayer.

## Before sheep v2 may be enabled

1. Decide the seven open gates (above).
2. Dealer: sheep listings under v2 (dealerStock SHEEP is still LEGACY_WEIGHT) — not wired.
3. In-game short test (single player): an R1 group and an R4 group; check fat classes, the notification, butcher meat, saving and loading, troughs accepting silage and grain, and that a goat pen stays on the old rules.
4. S7 (reproduction: BCS effects, litter size, seasonality) is untouched.
5. Pair with EconomyTuner main `9a37551` when deploying.

## Sources read for this batch

- [AHDB Feeding the ewe (older edition, AFRC 1993 tables)](https://projectblue.blob.core.windows.net/media/Default/Imported%20Publication%20Docs/Feeding-the-ewe-1.pdf), read in full text this time:
  - Table 2: intake as % of body weight;
  - Table 4: maintenance about 12% of body weight in MJ, 1 BCS ≈ 10% of body weight;
  - Table 8: pregnancy ME by litter;
  - Table 28: milk;
  - Table 29: ME per kg of milk, and the effect of weight loss and gain;
  - p50: 6.5 MJ of ME from milk per twin lamb at six weeks; weaning at 12 weeks with a 30 kg target.
- [Šebek & Everts 1993, Prediction of gross energy content of ewe milk](https://www.cambridge.org/core/journals/animal-science/article/abs/prediction-of-gross-energy-content-of-ewe-milk/D2A5EE8C6BC3A42D0CE6853818545917): the GE equation and composition ranges.
- Sex effect on the energy of gain: the ARC 0.85 / 1.15 factors were **not** found for sheep (they appear in cattle equations). A Brazilian Texel-cross study reports female NEg about 26% above intact males (seen only in a search summary; the original was not opened). The factors 0.80 / 1.00 / 1.25 are calibrated to the trial ADG ratio and registered as SHEEP-C11.
