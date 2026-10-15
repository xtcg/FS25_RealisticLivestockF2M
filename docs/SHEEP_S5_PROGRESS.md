# Sheep S5: nutrition, ewe milk, body condition and finishing (S5 + S5b)

Status 2026-10-14. Branch `feat/sheep-s5-nutrition` (worktree `rlrm-sheep5`), rebased on `origin/dev` `bbb4573` (S3 #53, S4 #54, dealer #55, breeding value #56). Decisions: [S5 checklist](../../FS25_SheepBreeds_离线准备_2026-10-11/S5_待设计与决策清单.md) D1–D9 and the [finishing design](../../FS25_SheepBreeds_离线准备_2026-10-11/sheep-finishing-design-v1.md) F-D1–F-D5, all approved by the user. The user asked on 2026-10-13 to develop from the checklist.

**Four states:** code committed — yes; in a run package — no; automated checks — pass (see Verification); game test — not done. **Sheep v2 stays OFF** (`weightProfiles.xml` SHEEP `enabled="false"`). After the calibration rebuild (2026-10-15, four batches, below) the calibration has 54 PASS, 11 FAIL and 11 UNVERIFIED items in four report parts (after the 2026-10-16 review), and it exits with code 1. Part 1 keeps the 7 original failures. No production parameter changed in the rebuild. Nothing has been tried in game.

## What the code does

| Part | Implementation |
|---|---|
| Species config | `scripts/animal/RLSpecies.lua` picks a config's `<species name="SHEEP">` section for an animal, pen, subtype or type name; cattle, goats (`excludeBreeds="GOAT"`) and every other type read the root, the same table as before. `feedProfiles.xml` and `bodyCondition.xml` each have a SHEEP section; the body section is sent to clients with the rest of the config. |
| Coverage | `weightProfiles.xml` SHEEP `nutrition="REAL"`: sheep are on v2 only while the real-equivalent nutrition model runs and both species sections are valid (`RLGrowth.speciesNutritionReady`). Under the old model they keep the old rules. Profile coverage (`RLGrowth.covers`) and the run in an hour are separate. A sheep is stepped only by its pen's mode (`RLFeed.runsFor`). In a pen that does not run the mode this hour (a goat in it, no trough, an error) it takes the old weight rule with its state kept, never the budget on the old feeding (`RLGrowth.needsRealNutrition`, declined by `RLGrowth.step`). The next step in the mode splits the weight it left again (`RLGrowth.resync`). Each hour is settled once, also across a move within the hour: a sheep a pen in the mode already stepped takes nothing more in a pen out of it (`RLGrowth.isSettledThisHour`); one that took the old rule is not stepped again by a pen in the mode (`rlLegacyHourTick`). `RLBodyCondition.isCoveredType` covers sheep only where v2 does. Sheep body condition starts at birth (`calfLegacyUntilAgeMonth 0`). |
| Feed | `RLFeed.registerSpeciesFeeds` adds SILAGE and the grains and PEA as SHEEP groups, marked `rlSpecies`. The old rules never eat them, and a trough accepts them only while its pen eats them (`RLFeed.isSpeciesFeedOpen`): the mode on, the sheep curves on, and no uncovered animal (a goat) in the pen. |
| Ewe milk (D1, D4) | No rearing pen and no trough milk. A ewe nurses while her lambs on milk are in her pen (`RLFeed.getNursingDams` returns the dams and the suckled count). Her milk is the AHDB Table 28 row for her system (lowland / hill by breed) and the number she suckles (single, twin; three or more share the twin row), as a step per month of the youngest lamb's age (`RLFeed.getDamMilk`). Her budget pays it (8.3 MJ ME a kg) with the early-lactation reserve rule on her lambs' age; her lambs share one pool; nothing is stored, sold or given to another ewe's lamb (`milkCollect` 0). |
| Weaning (D2, D3) | Nursing curves by age: milk ends at 3 months; solids and their worth rise to 1 by then. An orphan has no milk at all. From 2 months it is weaned early once it has eaten at least 250 g of concentrate a day as fed for 3.5 model days in a row (AHDB: 250 g of creep a head a day for 3-4 days; `readyCreepKgPerDay` 0.25, `readyDays` 3.5). What it actually took from the trough counts, its DM turned back into fresh weight by each feed's own DM. Grass does not count, and any step below the threshold starts the count again (`rlGrowth.creepDays`). Once weaned early the state keeps it (`rlGrowth.weanedEarly`, saved and streamed). A later shortage leaves the lamb underfed, not back on milk, and a lamb put back with its ewe does not suckle again: she does not count it, and makes no milk for it. Younger than 2 months, its pen stays in the mode and it lives on what it eats (no SUCKLING_CALF fallback, no milk made for it). `RLFeed.countUnnursed` drives one notification when lambs on milk are away from their ewe (`rl_feed_lambNoDam`). |
| Creep (D8) | A lamb at foot eats at most 0.35 kg DM of concentrate a day (about 0.4 kg fresh): planner limit `CREEP`. |
| Adaptation (D7) | 14 days to 90% concentrate; an unadapted lamb may take up to 50% of its DM as concentrate. This is a game rule: FAS's 50% is barley within the concentrate mix. |
| Physiology | Lamb maintenance 0.475 MJ/kg^0.75 to 6 months, moving to the ewe's 0.37 by 12 months. Growth cost 33 MJ ME per kg of frame at 40 kg, linear in weight (exponent 1.0, floor 14). By sex: rams x0.80, wethers x1.00, ewe lambs x1.25. Newborn lambs start lean (reserve 0.25, fat class 2). |
| Body condition, fat (S5b) | Reserve capacity 0.48 (one BCS point = 12% of the reference weight, not of any current weight), reference BCS 3. The reserve index is a model state, not a body fat percentage. Young stock (never a parent, continuous age under `youngUntilMonth` 12: `RLBodyCondition.isYoungStock`) show EUROP fat classes 1/2/3L/3H/4L/4H/5; grown sheep show BCS. The finishing target applies to ram lambs, wethers (x + 0.09) and ewe lambs (x + 0.18). One rule says what a ewe lamb is (`RLBodyCondition.isFinishingYoungFemale`: female, never lambed, continuous age under 12). It is read by the finishing target, her market reference (her breed ram's market weight), the reserve ceiling, the verdict and AUTO's FINISH. The feed physiology's separate `autoFinishYoungUntilMonth` is gone. From 12 months a maiden ewe is a ewe hogg: BCS shown, no target, no femaleFinishShift, her reserve capped at the section's `heiferReserveCeiling` 0.55 (BCS 3.2; a cap, not a target). A ewe that has lambed is capped at `cowReserveCeiling` 0.80. Crossing either boundary moves neither weight nor reserve; it changes only what later steps aim for and what is shown. The meat factor is set per class (3L 1.00, 3H 0.99, 4L 0.97, 4H 0.955, 5 0.90, 1 0.95). Verdict: ready at the market weight from class 2, over-fat from 4L. Under AUTO, lambs of both sexes under 12 months eat freely. Sheep BCS never changes conception in this batch (`fertilityEffect 0`, D5). |
| Display, diagnostics | Pen info rows for ewes and lambs. The menus' feed rows, ration preview and forecast work on sheep pens. `rlFeed*`, `rlBc*` and `rlPen*` reports include sheep pens; the pen report adds each lamb's milk cap, early weaning and fat class. All 17 languages have the new keys (de and Chinese translated, the others English, as before). |

## Calibration (`python tests/sheepcalib.py`)

The results are in `../FS25_SheepBreeds_离线准备_2026-10-11/s5-logs/review2-2026-10-14/calibration.{txt,json}`, from the real modules at a 1-day month. The month-length checks also run at 3, 7 and 28 days. Every item is **PASS** or **FAIL** against a stated target, or **UNVERIFIED** when there is no independent reference or it was not run (never counted as a pass). The script exits with 1 when anything fails.

Run: `python tests/sheepcalib.py --json out.json --ab cattle-legacy=… --ab cattle-real=… --ab species=…`. **27 PASS, 8 FAIL, 8 UNVERIFIED; exit code 1.**

| Item | Result |
|---|---|
| V1 R1 early single ram lamb, 2.8–3.3 months to its market weight | Landrace 3.04, Suffolk 3.08, Swiss Mountain 3.25 PASS; **Texel 3.33 FAIL** |
| V1 creep feed conversion | **UNVERIFIED** ×4 (the source's denominator is not settled): 0.57–0.69 kg per kg of all gain, 5.9–6.9 per kg of gain over grass alone (candidate 2–4) |
| V2 R2 milk and grass, ram lambs | Results by litter: Landrace single 3.62 / twin 5.33, Texel 3.96 / 5.75, Steinschaf 6.08 / 7.12, Black Welsh 5.62 / 7.33, Blackface 5.92 / 6.38 months. The flock mean is a supplement on an assumed n (lambs reared a ewe), weighted by lambs: singles (2 − n) / n, twins 2(n − 1) / n. The assumptions are lowland n = 1.7 (17.6% singles; S0 evidence has only Teagasc Belclare crosses weaning 1.65–1.70) and hill n = 1.3 (53.8% singles; no source). Landrace 5.03, Texel 5.43 PASS; **hill FAIL**: Steinschaf 6.56, Black Welsh 6.41, Blackface 6.13 (5.1–5.5 ± 0.5) |
| V3 R3 grass allowance + 0.25 / 0.5 kg barley | 1.66x / 2.03x grass alone PASS (Teagasc 1.63x / 1.99x) |
| V4 R4 housed store ram lamb | Concentrate per kg carcass 10.3 PASS; **ADG 300 g FAIL** (220–280) |
| V5 over-fat | 4L / 4H, meat 0.970 / 0.955 PASS |
| V6 ram : wether : ewe lamb ADG | 1 : 0.88 : 0.76, **UNVERIFIED**: the sex growth costs were calibrated on this ratio (SHEEP-C11). Taken apart on R4: without the sex growth costs 1 : 0.99 : 0.97; without the fat offsets 1 : 0.86 : 0.75; the ewe lamb on the ram's curve 1 : 0.88 : 0.76 (her curve does not bind on R4: energy does); without all three 1 : 0.97 : 1.00. The ratio comes from the sex growth costs alone |
| Milk pool (Table 28) | Potential = Table 28 × 30 days each month, exactly: lowland single 63.0 / 51.0 / 31.5 kg, twins 90.0 / 67.5 / 45.0, hill twins 57.0 / 48.0 / 33.0 PASS. The lambs never take more than the ewe paid PASS. Paid (= taken) on grass, twins: 87.5 / 57.1 / 35.9 kg (lowland), 52.5 / 39.0 / 26.2 (hill) |
| Ewe year, one Landrace ewe from mating to the next mating (twins; the last two months of pregnancy housed on silage; lambs leave at 3 months; never rebuilt or reset) | Start at BCS 3.00 (setup, not judged). Lambing 2.92 PASS (3 ± 0.25); **weaning 2.29 FAIL** (≥ 2.5); **next mating 2.98 FAIL** (3.0–3.5). Monthly table below |
| Energy, AHDB Table 8 (late pregnancy, 40 cells) | 2026-10-14: **FAIL**, triplets −3..+11% (a linear 0.55 a lamb overstated the third lamb). 2026-10-15, with the third lamb at 0.50: PASS, all cells −8..+2% (see the triplet section below) |
| Energy, AHDB Table 29 (lactation, 18 cells) | PASS: +2..+6% (maintenance + 8.3 × milk − 35 × loss); the model's describeAnimal equals that sum exactly (a 70 kg ewe nursing twins, 33.854 MJ) PASS |
| V8 month length | 1 vs 3 / 7 / 28 days within 0.8% PASS |
| V9 A/B against dev `bbb4573` | Cattle legacy budget 396 cases / 50,688 values, 0 differences PASS. Cattle real mode 640 cases, 0 differences PASS. Pigs, goats, horses, chickens and sheep on the shipped config (v2 off), every subtype × ages 1/6/30 × food 0.3/1.0 × both modes: 2,040 cases / 11,424 values, 0 unexpected differences PASS. 60 expected: a SHEEP-type pen now reports `UNCOVERED_ANIMAL` instead of `NOT_CATTLE`, inactive either way |
| V10 300 sheep | 13.4 ms a game hour PASS |
| Ewe milk DM / ME / CP | **UNVERIFIED** (PROXY; sensitivity below) |
| Growth cost 33 | **UNVERIFIED** beyond R1 / R4 (matrix below has no reference) |
| Game test | **UNVERIFIED** (not done) |

Ewe year by month (1-day month; requirement = maintenance + pregnancy + milk at full feed, mid-month; intake is what she ate, not a requirement):

| Month | BCS | Weight kg | Gravid kg | Ate kg DM/d | Ate MJ/d | Milk potential / paid / lambs took kg/d | Requirement MJ/d |
|---|---|---|---|---|---|---|---|
| 0 mating | 3.00 | 88.0 | 0 | | | | |
| 1–3 grass | 3.00 | 88.2 → 92.5 | 0.2 → 4.5 | 1.10 | 10.6 | – | 10.6 |
| 4 silage | 3.00 | 98.7 | 10.7 | 1.41 | 13.7 | – | 13.6 |
| 5 silage, lambing | 2.92 | 108.1 | 20.9 | 1.92 | 18.6 | – | 19.4 |
| 6 grass, twins | 2.43 | 82.0 | 0 | 2.89 | 28.0 | 3.00 / 2.86 / 2.86 | 35.2 |
| 7 | 2.31 | 80.7 | 0 | 2.48 | 24.0 | 2.25 / 1.87 / 1.87 | 28.7 |
| 8 weaning | 2.29 | 80.5 | 0 | 2.03 | 19.6 | 1.50 / 1.19 / 1.19 | 22.4 |
| 9–12 dry, grass | 2.61 → 2.98 | 83.9 → 87.8 | 0 | 1.64 → 1.16 | 15.9 → 11.2 | – | 10.1 → 10.6 |

At 88 kg (lambs excluded) she is past Table 8's 80 kg. One week before lambing she needs 20.8 MJ (Table 8 at 80 kg, twins: 20.2). In her first month of milk she needs 35.2 MJ at 3.0 kg (Table 29 at 80 kg: 33.9). Both are reported, not judged, because they are extrapolated.

Sensitivity (one value at a time; R2 Landrace twin ram / R1 Landrace single ram, months to market weight; R4 ram ADG):

| Value | R2 twin | R1 single | R4 |
|---|---|---|---|
| shipped | 5.33 | 3.04 | 300 g |
| milk ME/GE 0.85 / 0.90 / 1.00 (shipped 0.9475) | 5.79 / 5.54 / 5.12 | 3.17 / 3.08 / 2.96 | 300 g |
| milk DM 0.17 / 0.21 (same ME a kg as drunk) | 5.33 / 5.29 | 3.00 / 3.04 | 300 g |
| milk CP 0.24 / 0.32 | 5.33 / 5.33 | 3.08 / 3.04 | 300 g |
| lamb maintenance 0.466 / 0.482 | 5.21 / 5.42 | 3.00 / 3.04 | 303 / 298 g |
| growth cost 30 / 36 | 5.04 / 5.67 | 2.92 / 3.17 | 311 / 289 g |

Milk ME (the unsourced ME/GE) and the growth cost move the routes most; milk DM and CP hardly matter.

Growth cost beyond R4 (reported, no trial data): store ram lambs, 60 days, ad lib concentrate / silage + 0.5 kg barley. Landrace and Suffolk 297–308 / 225–242 g, Texel 290–292 / 225–232 g, Blackface 177–189 / 159–175 g, from 25 and 40 kg.

### Why the failures stay open

None of them is closed by widening a tolerance or fitting a parameter (user rule 2026-10-14: parameters follow real-world sources; gates are validation).

1. **Hill lambs (V2).** The ewe's milk uses AFRC's hill rows, which describe hill ewes on hill grazing. The game's cut grass is a mid-quality pasture (GRASS_WINDROW, ME 9.7 MJ/kg DM, shared with cattle), not spring grazing at 11–12. The flock mean also rests on an assumed hill n of 1.3. Options: accept the gap; give hill breeds the lowland row on lowland feed; or revisit the C-grade target.
2. **R4 ADG +7%.** At Teagasc's intake the model gives 300 g a day, close to AFRC's equations. Teagasc's lambs grew less (248 g).
3. **Texel R1 3.33.** The breed's own S4 potential is 2.9 months, plus the same milk/creep lag as the other breeds.
4. **Ewe weaning BCS 2.29.** Twins on grass take her from 2.92 to 2.29 in three months; she pays 95%, 83% and 79% of her Table 28 milk. FAS's lowland target is 2.5.
5. **Ewe mating BCS 2.98.** A dry ewe on GROW returns to the reference reserve (BCS 3.0) and no further. Per the user's rule, no flushing or dry-ewe target is added; the gate is reported, not met.
6. **Table 8 triplets (closed 2026-10-15).** The cost was linear in lambs, and triplets can already happen (`xml/animals.xml` sheep `pregnancy average="2" max="3"`). Fixed with a third-lamb factor taken from the table's own 70 kg row and checked on the held-out 80 kg row and on new in-between points (below).

The ewe BCS gates (4, 5) remain a nutrition assessment, not a fertility gate, and no dry-ewe or flushing mechanism is added. The 3–3.5 mating band is the scenario's target; FAS's mating targets are 3.5 lowland, 3 upland and 2.5 hill. One feeding plan that misses the target does not prove the model wrong. A run with adjusted feeding is still needed to tell a diet shortfall from a model bias.

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

## Review 2 2026-10-14 (PR #57 at `4be7034`)

Three commits, in the review's order: run gate and weaning state (`3fafeb4`), life stages and regression tests (`b52f541`), calibration script, sources and reports (this commit).

| Finding | Change | Verification |
|---|---|---|
| 1. A sheep in a mixed pen could still run v2 | Profile coverage (`covers`) and the hour's run (`RLFeed.runsFor`) stay apart; no pen evaluation inside `covers`. A sheep out of the mode takes the old weight rule with its state kept, and the next step in the mode resyncs. New: each hour is settled once when a sheep moves within the hour, in either direction (`RLGrowth.isSettledThisHour`, `rlLegacyHourTick`) | `test_sheep_s5_runtime`: pure → goat → pure (budget path each hour, state kept, the first step back `resync`, largest hourly weight change 0.27 kg, never both in one hour); same-hour moves both ways; no trough, invalid config, mode off, each then back |
| 2. Orphan weaned too early | Days in a row at 250 g a day **as fed**, each feed's DM back to fresh weight (0.222 kg DM of barley = 0.247 kg fresh does not count). From 2 months, at 3.5 days, a saved weaned state (`weanedEarly`). A later shortage leaves the lamb underfed; back with its ewe it does not suckle | One 0.25-day step is not enough; 13 steps (3.25 days) are not, the 14th is; grass alone never; an interruption restarts; save/load and stream keep the count and the state; 1 / 3 / 7 / 28-day months wean after 3.75 / 3.75 / 3.57 / 3.53 model days (3.5 to the hour) |
| 3. Flock weighting | By lambs: singles (2 − n) / n, twins 2(n − 1) / n; checked at n = 1 and 2 and summing to 1. Single and twin results are reported first; the flock mean is a supplement on assumed n (1.7 / 1.3, no source) | Regenerated (above) |
| 4. Ewe cycle | D6 kept (weaning ≥ 2.5, mating 3–3.5, lambing 3 ± 0.25). One ewe from mating through pregnancy, lambing, lactation and weaning to the next mating, never rebuilt or reset. The record holds weight, BCS, gravid mass, intake, milk potential, milk paid and lamb take. Energy is judged on its own, against Tables 8 and 29 | Weaning 2.29 and mating 2.98 FAIL; Table 8 FAIL (triplets); Table 29 PASS |
| 5. Grown maiden ewes finished as ewe lambs | One rule (`isFinishingYoungFemale`, continuous age) for the target, reference, ceiling, verdict, AUTO and fat class; a ewe hogg reads `heiferReserveCeiling` without +0.18 | `test_sheep_s5_lifecycle`: 11.99 / 12 / 24 months; the clock at 11.999 with whole months 11; first lambing at 20 and at 11.5 months; an hourly run across 12 months (+0.078 kg the hour before and the hour of crossing; reserve above the hogg ceiling not cut) |
| Script | `judge()` returns PASS / FAIL / UNVERIFIED and a summary; exit code 1 on any failure. Creep FCR, V6, milk proxies, growth cost beyond R4 and the game test are UNVERIFIED. The 3-day month was added; V9 reads the three A/B results (new `tests/species_ab.py` for every other type) | `calibration.txt`, exit 1 |

### Parameters and their standing

| Parameter | Standing | Check |
|---|---|---|
| Table 28 milk (`lactation` rows) | Sourced: a ewe's monthly mean, kg a day, months 1–3. Kept as a monthly step | Potential integrates to the table exactly; potential, paid and taken are reported apart |
| Milk cost 8.3 MJ/kg | Approximation of Table 29 (11.5 MJ/kg DM housed diets), not a cross-diet constant | Table 29, 18 cells +2..+6% |
| Ewe maintenance 0.37, pregnancy 0.55 a lamb | Model approximations | Table 8, 40 cells: singles and twins −8..+0%, triplets up to +11% (FAIL) |
| Ewe milk DM 19%, ME 25 MJ/kg DM, CP 28% DM | PROXY. GE from Šebek & Everts; ME/GE 0.9475 assumed, not derived from Šebek | Sensitivity only; not a verified anchor |
| Lamb maintenance 0.475 | A candidate between the trial's 0.466 and 0.482. Using it to 6 months and moving to 0.37 by 12 is a model assumption (XML comment no longer says 0.45) | Sensitivity: ±0.1 months on R2 |
| Growth cost 33, sex factors 0.80 / 1.00 / 1.25 | Calibration values (R1 / R4 and the trial ADG ratio) | V6 UNVERIFIED and taken apart; breed/weight/diet matrix without reference |
| BCS 12% of reference weight a point; reserve index; EUROP map and meat factors | BCS–weight relation sourced (FAS 10–13%, AHDB ≈10%). The reserve index is not body fat. The fat class map and meat factors are game design | – |

## Independent review 2026-10-15 (PR #57 at `3169507`)

`s5-logs/independent-review-2026-10-15/REVIEW.md` found two P2 edge cases. Both are fixed here, with tests that fail without the fix; the reviewer's figures reproduce exactly.

| Finding | Change | Verification |
|---|---|---|
| Switching the mode or the species config within an hour could settle a sheep twice: the "already settled" check read the current coverage, and the old-rule path for an uncovered sheep left no mark | Both marks no longer depend on the mode, config or pen. `RLGrowth.isSettledThisHour` reads the hour mark a pen in the mode set (`rlFeedStepTick`). `RLGrowth.markLegacyHour` marks every old-weight-rule hour of a sheep, covered or not (`AnimalHealth.updateHealth`). Several sub-steps in one pen settlement still run | `test_sheep_s5_runtime`: the mode and the config, each switched off after a step (no old rule, no health on top) and on after the old rule (no step, no health, nothing taken from the trough), then the next hour normal |
| Creep days survived a gap: 3.25 days, then 10 model days grass-only in a mixed pen, then one 0.25-day step weaned the lamb | The count needs its previous step in the mode within the steps' spacing (`RLFeed.isFresh` on the state's `lastTick`, which only steps in the mode move; saved with the state). Otherwise it restarts. A lamb already weaned stays weaned | Gaps from a goat, no trough, the mode off and the config invalid each restart the count (2.5 → 1.25 days, not weaned). A save from 8 hours before restarts it. No time lost across a save, a move between two pens in the mode, or a 28-day month (a step every 6 hours, weaned after 14 steps) |

Re-run (`s5-logs/review3-2026-10-15/`): full suite 3973/3973; Lua 5.1 sheep tests 150 / 150; A/B against `bbb4573` 396 / 640 / 2,040 cases, 0 unexpected differences; calibration unchanged, 27 PASS, 8 FAIL, 8 UNVERIFIED (exit 1).

## Triplet pregnancy energy and the BCS feeding control (2026-10-15)

The user asked for both before the next review. Evidence is in `s5-logs/review4-2026-10-15/`: full suite 3976/3976, Lua 5.1 sheep tests 153/153, A/B against `bbb4573` 396 / 640 / 2,040 cases with 0 unexpected differences (cattle count every fetus at 1, bit-identical). Calibration: **32 PASS, 7 FAIL, 8 UNVERIFIED** (exit 1). Only the energy items changed; every other result is identical to `review3`.

### Triplets (Table 8)

Triplets are possible now (`animals.xml` sheep `pregnancy average="2" max="3"`). The pregnancy cost was linear in lambs (0.55 x maintenance each). Now the third lamb, and any further one, counts at the feed physiology's `pregnancyThirdLambFactor` 0.50 (`RLGrowthMath.getPregnancyLoad`). The first two lambs are unchanged.

The value comes from Table 8 itself, not from the model's error. In the 70 kg row the triplet − twin increment is 0.47–0.52 of the twin − single one at 7/5/3/1 weeks (mean 0.50). The 80 kg row (0.48–0.55) was held out. It is a species-only setting (cattle count every fetus at 1, and the root config's fingerprint is unchanged).

| Check | Before | Now |
|---|---|---|
| Table 8, 40 cells | FAIL (triplets −3..+11%) | PASS. Singles −8..−2%, twins −6..+1%, triplets −7..+2%; mean 3.1% |
| Singles and twins | – | Bit-identical to before (32 cells) PASS |
| Held out: 80 kg triplets | +8..+11% at 5/3/1 weeks | −7%, +0%, +1%, −3% PASS |
| New points between the table's (55/65/75 kg × 6/4/2 weeks; triplets at 75 kg; table interpolated) | triplets +3%, +10%, +10% | 21 points within −6..+1%; triplets −3%, +1%, −1% PASS |
| Through the pregnancy (70 kg, every 1%) | – | Never falling, never negative, triplets ≥ twins ≥ single, largest 1% step 0.31 MJ PASS |

Maintenance and pregnancy are reported apart: at 70 kg, maintenance is 8.95 MJ and pregnancy at 1 week is 4.35 / 8.70 / 10.88 MJ for 1 / 2 / 3 lambs. The second and third lambs' increments are reported against the table's, at 70 and 80 kg. The model's second-lamb increment is 0.15–0.51 MJ above the table's at 5/3/1 weeks and 0.3 MJ below at 7 weeks: the linear ramp from 60% of the pregnancy is steeper than AFRC's curve. This is within the tolerance and left as it is (singles and twins unchanged).

### BCS feeding control (cause diagnosis, not gates)

The baseline year and its two D6 failures stay as they were. Three adjusted years run on the same code and the same ewe. Their plans and the diagnosis rule were written into `tests/sheepcalib.lua` / `sheepcalib.py` before the first run and were not changed after it:

- **L, lactation supplement.** AHDB Table 32 (a 70 kg ewe rearing twins at three weeks) gets 1 kg of an 18% CP compound a day where grass is short. Here that is 0.5 kg barley + 0.5 kg peas a day in the trough for the first two months of lactation, with grass ad lib.
- **R, recovery free intake.** From weaning to mating the pen's target is FINISH on the same grass. AUTO grows a dry ewe back to the reference reserve (BCS 3) and no further.
- **L+R**: both.

The rule: a control explains a failure only if it meets the D6 target while the lambs' weaning weight and the milk paid stay within 2% of the baseline.

| Plan | Lambing / weaning / mating BCS | Lambs at weaning (ADG) | Milk paid / Table 28 potential | Concentrate, ewe / lambs, kg a day |
|---|---|---|---|---|
| Baseline | 2.92 / 2.29 / 2.98 | 26.5 kg (220 g) | 177.6 / 202.5 kg | 0 / 0 |
| L | 2.92 / 2.30 / 2.98 | 28.0 kg (238 g) | 179.9 / 202.5 | 0.75 / 0.25 |
| R | 2.92 / 2.29 / 3.66 | 26.5 kg (220 g) | 177.6 / 202.5 | 0 / 0 |
| L+R | 2.92 / 2.30 / 3.68 | 28.0 kg (238 g) | 179.9 / 202.5 | 0.75 / 0.25 |

By the rule, **neither failure is explained; both stay open**. What the records show:

- **Weaning 2.29.** In the first month of milk the ewe needs 35.2 MJ. She eats 28.0 MJ on grass and 29.2 MJ with the supplement: the concentrate mostly replaced grass, because her intake is fill-limited at about 3.3% of live weight. The lambs took a quarter of the trough as creep and gained 1.5 kg more. Her condition barely moved. AHDB's own Table 32 ration also leaves a deficit (30.0 against 33.4 MJ, losing 200 g a day). So the loss comes from appetite against twin milk, not from too little feed. Whether the loss is too large (0.63 BCS from lambing, against AHDB's expected 0.5) is not settled by this control. Part of it is the 88 kg Landrace ewe giving the full Table 28 lowland twin row.
- **Mating 2.98.** Free intake from weaning raises her from 2.29 to 3.66 in four months: the energy model can rebuild condition, and overshoots the 3–3.5 band. The baseline's 2.98 is AUTO's GROW rule, which aims a dry ewe at the reference reserve (BCS 3.0) and no further, not a lack of energy. The band lies between the two management settings the game has. Whether AUTO's dry-ewe target should be BCS 3.0 is a game rule to decide. No fertility, flushing or dry-ewe mechanism was added, and no further plan was tried after seeing these results.

## Review 2026-10-16 (PR #57 at `7389878`)

Evidence is in `s5-logs/review6-2026-10-16/`. Results: full suite 3988/3988; Lua 5.1 sheep tests 165 / 165; A/B against `bbb4573` 396 / 640 / 2,040 cases, 0 unexpected differences; calibration 54 PASS, 11 FAIL, 11 UNVERIFIED (exit 1; part 1 keeps its 7 failures).

| Finding | Change | Verification |
|---|---|---|
| P2: a one-hour creep gap still weaned early. `RLFeed.isFresh` allows a step one hour late, so 2.5 days, one grass-only hour (1.25 d) off the mode, then creep reached 3.5 days | Every hour a sheep takes the old weight rule now resets an unweaned lamb's creep days (`RLGrowth.markLegacyHour`: a pen out of the mode, no trough, the mode off, an invalid config). A lamb already weaned stays weaned. `isFresh` stays for a save from before | One-hour gaps for a goat, no trough, the mode off and an invalid config restart the count (2.5 → 1.25 d, not weaned). Without the fix all four fail (3.5 d, weaned) |
| P2: a lamb's fresh intake left out its dam's milk, while DM and ME included it | Fresh weight is split into trough, dam milk as drunk (milk DM / `damMilk.dm`) and total; DM and ME are not counted twice | Intensified lactation, month 1: 0.311 + 1.477 = 1.787 kg a day (DM 0.420). Only the reported fresh weights changed (plus last-digit noise in two ledger sums); growth and feed use are unaffected |
| R4 study control: the age (7 months) is an assumption | Castrates at 5 / 6 / 7 months on both diets, reported only | Game diet 264 / 269 / 278 g, FCR × 0.491 12.70 / 12.49 / 12.12; recipe 239 / 244 / 253 g, 13.20 / 12.97 / 12.53. The earlier mismatch with the user's 0.087 trial (12.72) is the age: their trial was at 5 months. 7 months stays an assumption and is not taken as closer to the trial |
| Convergence: add finer steps | 0.03125 and 0.015625-day groups cover every R1 and R2 lamb. The 0.05-day requirement is applied to the finest pair; the 0.125 / 0.0625 pair stays as judged (FAIL for R2) | Finest pair: R1 worst 0.006 d, R2 worst 0.025 d (Black Welsh twin), both PASS. Successive differences halve (first order) |

## Calibration rebuild (2026-10-15, four batches; production parameters unchanged)

Evidence is in `s5-logs/review5-2026-10-15/`:
- full suite 3983/3983;
- Lua 5.1 sheep tests 160 / 160 (new `test_sheep_s5_metrics`, 7 checks);
- A/B against `bbb4573`: 396 / 640 / 2,040 cases, 0 unexpected differences;
- calibration 52 PASS, 11 FAIL, 11 UNVERIFIED (exit 1).

The expected values below came from the user's isolated trial runs. They were used to check the implementation, not as factual targets.

### Batch 1: one way to measure time, energy and FCR

- **Files.** `tests/sheepcalib.lua` is now the library (`raiseWithDam`, `storeLambs`, `eweYear`). `tests/sheepcalib_scenarios.lua` holds the inputs and the groups. `tests/sheepcalib_metrics.lua` holds the measurements. `tests/sheepcalib.py` runs each group in a Lua state of its own and keeps the old metrics beside the new ones. `RLFeed.lua` needed no change: the STEP events already carry what is measured.
- **Identical trajectories.** The history runs first, in its old order, on the same code paths. Every value it had before is identical, with two exceptions: the removed monthly "intake − mid-month need" balance, and R3's ADG, which now divides by the 42.5 model days actually run instead of the nominal 42.
- **Crossing record.** Each lamb carries `elapsedModelDays`, `lastBelow`, `firstAtOrAbove`, `crossingEstimateDays` (linear between them, an estimate only) and `ageAtRefGameHour` (the old hour-end months). A verdict uses the step interval. Only an interval across a bound falls back to the finer steps' estimate, and only when those two agree within 0.05 d; otherwise the item is "numerical resolution unresolved" (UNVERIFIED). No verdict needed the fallback.
- **Texel.** The first sub-step at or above market weight is at 99.0 model days; the interpolated estimate is 98.78 / 98.79 / 98.80 at 0.25 / 0.125 / 0.0625-day steps. The new model-time V1 check passes (84–99 d). The old hour-end check (100 d = 3.33 months) stays FAIL in part 1.
- **Convergence.** For R1 (about 3 months) the two finer steps agree within 0.026 d: PASS. For R2 (4–7 months) they differ by up to 0.112 d: **FAIL** on the 0.05 d engineering precision. The difference halves with the step (ratio 1.99–2.02): first-order integration error growing with route length. At the production 0.25-day step the Landrace twin lamb is 0.45 d (0.3%) short of the extrapolated limit. The production step stays 0.25 d.
- **R4.** ADG is now the gain over the model days actually run. The 54-day study scenario runs at a 5-day month: 216 hours of 0.25 d, exactly 54.00 d.
- **Energy.** The budget's own per-step ledger (supply, demand, paid, unmet, deposit, mobilised, catabolism, lost) is summed by month, and closes to within 4e-15 of supply on all 96 tracked animals. Month-length check on model time: at 1 / 3 / 7 / 28-day months the R1 Landrace twin ram lamb crosses at 107.65 d and weighs 37.72 kg at 3 months, identical at every month length.

### Batch 2: management with the game's feeds (no milk, grass or intake change)

| Scenario | Result | Expected |
|---|---|---|
| Hill lambs on clover (CLOVER_WINDROW in place of grass; n = 1.3 assumed, singles 0.5385, twins 0.4615) | Flock mean (game-hour end) Steinschaf 5.45, Black Welsh 5.11, Blackface 5.29 months; all three PASS the original window. Grass alone stays FAIL (6.1–6.6) | 5.45 / 5.11 / 5.29 |
| Ewe, intensified lactation (grass, barley, peas topped up for 90 days) | Weaning BCS 2.60 PASS. Lambs 33.8 kg at weaning vs 26.5; milk paid 197.1 vs 177.6 kg of 202.5. Month 1 of milk: ME 31.6 MJ eaten (baseline 28.0) on the same 2.9 kg DM, unmet demand 0 (baseline 1.1 MJ a day) | about 2.60 |
| Ewe, controlled recovery (FINISH from weaning; MAINTAIN once BCS ≥ 3.25 = reserve 0.5625, a scenario's player switch) | Next mating BCS 3.256 PASS; switched at month 10.9. Lambs and milk as the baseline | about 3.256 |
| Both | Weaning 2.60, mating 3.25, lambs and milk as the intensified run; all PASS | |

The 98% guard on lambs at weaning and milk paid passes in every control. These results support a management explanation of the two baseline BCS failures (an energy-dense diet in lactation; a recovery target above AUTO's BCS 3.0). They do not independently verify the energy model, and the baseline failures stay in part 1. AUTO still aims a dry ewe at BCS 3.0. The 3.25 switch exists only in the scenario. A maiden ewe keeps her BCS 3.2 ceiling.

### Batch 3: R4 rebuilt beside the original; candidate parameters

- **Study-design control.** Suffolk (breed proxy for Suffolk-cross), castrates, 39 kg, 54 model days, age 7 months (an assumption). Two diets:
  - **game diet**: silage, barley and peas ad lib;
  - **study recipe proxy**: barley ad lib, peas at most 0.5 kg and silage 0.5 kg fresh a head a day, about 16% CP. Keady 2016 summarises Keady and Hanrahan 2014/2015: 160 g CP/kg concentrate, ad lib within 10 days, 0.5 kg fresh high-value silage, about 1.5 kg concentrate a day.

| Castrates | ADG | DM a day | Concentrate a day | FCR live x 0.49 / x 0.491 (proxies) | FCR on game saleable meat |
|---|---|---|---|---|---|
| game diet | 278 g | 1.63 kg | 1.66 kg | 12.14 / 12.12 | 15.91 |
| study recipe | 253 g | 1.51 kg | 1.56 kg | 12.55 / 12.53 | 16.42 |

  Ram and ewe lambs under the same conditions (reported only): rams 316 / 288 g, ewe lambs 239 / 217 g. The summary's 248 g, 1.5 kg and 10.7 are not yet traced to the castrate / 39 kg / 54-day treatment, so the matched check is UNVERIFIED. The original R4 (Landrace, 32 kg, three sexes, 60.0 d) is unchanged: ram 300 g, FCR 10.27 / 10.25, meat 13.19; its V4 ADG gate stays FAIL.

- **Candidates.** Each runs in its own Lua state against a fresh `candidate:base`:

| Candidate | Study castrates, game diet | Study castrates, recipe | R4 ram | Texel R1 crossing |
|---|---|---|---|---|
| base | 278 g / 1.63 kg / 12.12 | 253 g / 1.51 / 12.53 | 300 g / 10.27 | 98.78 d |
| growth cost 30 | 293 / 1.64 / 11.57 | 267 / 1.52 / 11.97 | 311 / 9.99 | 97.08 |
| growth cost 36 | 263 / 1.62 / 12.73 | 240 / 1.50 / 13.17 | 289 / 10.60 | 101.23 |
| growing intake 0.087 | 255 / 1.53 / 12.39 | 232 / 1.42 / 12.83 | 278 / 10.33 | 101.87 |

  Growing intake 0.087 worsens FCR (12.12 → 12.39 on the game diet) while ADG comes closer to 248 g, as the user's trial found (their 12.72 → 13.02). The absolute FCR differs from that trial, so the two scenario set-ups are not identical. Ewe reserve deposit 100 MJ/kg (grown parous ewes only, planner and settlement alike) gives weaning / mating BCS of 2.28 / 2.92 (baseline 2.29 / 2.98) and 2.57 / 2.99 under intensified lactation. Under controlled recovery the ewe no longer reaches 3.25 by mating (2.95). **No candidate is adopted**: the conditions are not matched to a traced reference. Production keeps 33, 0.092, 50 and 35.

### Batch 4: the report, regression and the game test

- `sheepcalib.py` reports four parts: 1 history (the original baseline and earlier results, every old FAIL kept); 2 checks matched to a reference (energy tables, model-time V1/V2, convergence, month length, ledger, the R4 study); 3 management controls; 4 unmatched sources, proxies, candidates and what the game has not verified. Each part carries its own PASS / FAIL / UNVERIFIED counts: 25/7/5, 16/4/1, 10/0/0, 1/0/5.
- A production guard checks 16 kept values in the shipped XML, all equal: third lamb 0.50, lamb maintenance 0.475, lactation intake 0.050 / 0.50 / 0.018, reserve capacity 0.48, AUTO reference 0.50, growth 33 and 0.80 / 1.00 / 1.25, growing intake 0.092, adaptation 14, deposit 50, mobilise 35, sheep v2 `false`.
- The triplet energy checks still pass: 40 cells, 21 interpolated points, every 1% of the pregnancy. V10 is 13 ms against the 60 ms threshold.
- An observer that fails is now an error in the calibration (in the game it is only a warning).
- Game short test: the card is `docs/SHEEP_S5_GAME_TEST.md` (feed supply, ewe and lamb allocation, weaning, mixed-pen fallback, save and load, BCS recovery by hand, 300 sheep). **Not done**; it is UNVERIFIED in part 4.

## Game compromises added in S5 (four columns in the finishing design §4)

SHEEP-C09 to C17 are recorded in the finishing design §4 (2026-10-14 addendum): monthly milk steps; lean newborn reserve; growth cost by sex; AUTO finishing young females; goat pens stay on the old rules; creep gate; the notification comes the hour after a separation, not at the move; ewe milk composition is a proxy; the hill gap.

## Verification

- Full suite: 3988/3988 (`python tests/run.py`; log `s5-logs/review6-2026-10-16/tests-full.log`). The sheep files are `test_sheep_s5_config` (19 checks), `test_sheep_s5_nursing` (40), `test_sheep_s5_settings` (24), `test_sheep_s5_runtime` (55), `test_sheep_s5_lifecycle` (19) and `test_sheep_s5_metrics` (8).
- A/B against `bbb4573` (run from `tests/`): `python sheep_s5_ab.py` (cattle legacy budget), `python feed_ab.py` (cattle real-equivalent mode), `python species_ab.py` (every other type). Each takes `--baseline bbb4573 --out …`. Results are in `s5-logs/review2-2026-10-14/`, with 0 unexpected differences.
- The six sheep test files also pass under Lua 5.1: 165 / 165 (`s5-logs/review6-2026-10-16/sheep-tests-lua51.txt`).
- Not done: game test, W-DEBUG/TestDiagnostics sheep scenario (separate mod), multiplayer.

## Before sheep v2 may be enabled

1. Decide the seven failures (above). They are not to be closed by widening tolerances. The feeding control (below) leaves both BCS failures open, and records what drives each.
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
