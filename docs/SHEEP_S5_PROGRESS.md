# Sheep S5: nutrition, ewe milk, body condition and finishing (S5 + S5b)

Status 2026-10-14. Branch `feat/sheep-s5-nutrition` (worktree `rlrm-sheep5`), rebased on `origin/dev` `bbb4573` (S3 #53, S4 #54, dealer #55, breeding value #56). Decisions: [S5 checklist](../../FS25_SheepBreeds_离线准备_2026-10-11/S5_待设计与决策清单.md) D1–D9 and the [finishing design](../../FS25_SheepBreeds_离线准备_2026-10-11/sheep-finishing-design-v1.md) F-D1–F-D5, all approved by the user. The user asked on 2026-10-13 to develop from the checklist.

**Four states:** code committed — yes; in a run package — no; automated checks — pass (see Verification); game test — not done. **Sheep v2 stays OFF** (`weightProfiles.xml` SHEEP `enabled="false"`). After the second review (below) the calibration has 27 PASS, 8 FAIL and 8 UNVERIFIED items, and it exits with code 1. Nothing has been tried in game.

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
| Energy, AHDB Table 8 (late pregnancy, 40 cells) | **FAIL**: mean error 4.1%. Singles −2..−8%, twins −6..+0%, **triplets −3..+11%** (70 kg, 3 lambs, 3 weeks: 18.6 vs 16.7 MJ). A linear 0.55 a lamb overstates a third lamb |
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
6. **Table 8 triplets +8..+11%.** The pregnancy cost is linear in lambs (0.55 each), but AFRC's third lamb costs less than the second. Triplets can already happen: `xml/animals.xml` gives sheep `pregnancy average="2" max="3"`, and `AnimalReproduction.generateRandomOffspring` uses it. So this must be fixed before sheep v2 is enabled. The independent review proposes per-litter values fitted to or interpolated from Table 8 for single, twin and triplet ewes, with regression by litter, weight and week so the single and twin cells stay as they are. Not done yet.

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

## Game compromises added in S5 (four columns in the finishing design §4)

SHEEP-C09 to C17 are recorded in the finishing design §4 (2026-10-14 addendum): monthly milk steps; lean newborn reserve; growth cost by sex; AUTO finishing young females; goat pens stay on the old rules; creep gate; the notification comes the hour after a separation, not at the move; ewe milk composition is a proxy; the hill gap.

## Verification

- Full suite: 3973/3973 (`python tests/run.py`; log `s5-logs/review3-2026-10-15/tests-full.log`). The sheep files are `test_sheep_s5_config` (19 checks), `test_sheep_s5_nursing` (40), `test_sheep_s5_settings` (24), `test_sheep_s5_runtime` (51) and `test_sheep_s5_lifecycle` (16).
- A/B against `bbb4573` (run from `tests/`): `python sheep_s5_ab.py` (cattle legacy budget), `python feed_ab.py` (cattle real-equivalent mode), `python species_ab.py` (every other type). Each takes `--baseline bbb4573 --out …`. Results are in `s5-logs/review2-2026-10-14/`, with 0 unexpected differences.
- The five sheep test files also pass under Lua 5.1: 150 / 150 (`s5-logs/review3-2026-10-15/sheep-tests-lua51.txt`).
- Not done: game test, W-DEBUG/TestDiagnostics sheep scenario (separate mod), multiplayer.

## Before sheep v2 may be enabled

1. Decide the eight failures (above). They are not to be closed by widening tolerances.
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
