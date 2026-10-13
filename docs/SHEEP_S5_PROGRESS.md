# Sheep S5: decisions, calibration constraints and first implementation

Date: 2026-10-13. Immutable starting point: `origin/dev` = `f9a6d9369cf66fcfeb441af3943c4c3e4cd9cbd0`, confirmed by fetch. Includes S3 (#53), S4 (#54) and dealer #55. Branch: `feat/sheep-s5-nutrition`; worktree: `rlrm-sheep5`.

The user authorized fact-based decisions, using the proposed recommendations when gameplay needs a compromise. No new D1–D9 confirmation is required. This is the first independently reviewable S5 change, **not completion of S5**. Sheep v2 remains OFF. No package was deployed, no savegame was changed, and no game test was performed.

## Decisions for the rest of S5

| ID | Decision | Evidence / constraint |
|---|---|---|
| D1 | Internal milk per dam, no sale, no fostering. Her own twins/triplets share one finite pool; no milk is created per lamb. | Recommendation A adopted. The old 2.1/3.0 kg/day and 20% DM anchors still need their original AHDB/NZ tables read; they remain candidates, not calibrated coefficients. Production, nursing and unused milk must reconcile after the dam's actual budget settles. |
| D2 | Normal weaning at 3 model months (90 days). | About 13 weeks, consistent with grass-system guidance. Transition on continuous age; never retain the cattle 6/7-month curves. |
| D3 | Orphans may wean from 2 months; use weight and established solid intake as readiness checks. | AHDB supports 8–9-week weaning with at least 250 g/day creep intake sustained for 3–4 days. The old ≥10 kg threshold still needs its original source checked. Age alone must not certify a starving orphan as ready. Define explicit fallback/reporting for a young orphan before activating pens. |
| D4 | Warn on separating a lamb still dependent on its dam; do not forbid transfer. | Approved gameplay choice. Covers moving the dam as well as the lamb. |
| D5 | Do not change litter size, seasonality or breed first-mating age in this batch. | S7. New sheep body condition must not silently inherit cattle fertility penalties. |
| D6 | Use production-system targets: lowland mating 3–3.5, lambing 3, weaning 2.5; upland 3 / 2.5 / 2; hill 2.5 / 2 / 2. | FAS original tables. These are husbandry targets, not hard reproduction gates. S0 growth group alone does not prove every breed's maternal management system. |
| D7 | 14-day adaptation is the approved game approximation. Initial total concentrate ceiling 50% may be retained as a game rule, with existing low-utilisation treatment. Require real roughage alongside ad-lib concentrates. | FAS's actual 50% guidance concerns **barley in the concentrate mix**, not all concentrate in total DM. Do not label the broader game cap as the original recommendation. Teagasc increases concentrates gradually and retains roughage. |
| D8 | Start calibration with 0.4 kg fresh creep/animal/model day, inside the approved 0.3–0.5 range. | A calibration candidate, not a measured biological ceiling. Young creep 18% CP; AHDB permits 15–16% after 8 weeks. Preserve the source's basis; no single “18%” value should be copied into every DM field. |
| D9 | Measure the real 300-sheep feeding path first; group only if the measured budget fails. | No current sheep feeding performance pass. This batch's A/B budget timing would not certify the pen planner. |

## Corrections that calibration must respect

1. FAS finishing-concentrate **15% CP is fresh weight**, equivalent to 16.67% of DM at 90% DM. It describes the concentrate component, not necessarily the whole ration. The code's feed CP is on a DM basis; quantify the whole mixed ration instead of changing feed composition to force a target.
2. The shipped SILAGE has DM 0.35 and density 0.45 kg/L. Therefore 0.5 kg fresh silage = **0.175 kg DM**, costing 0.1388889 game L/model day at resourceScale 0.125. Earlier 0.15 kg DM assumed different silage. Use the effective feed file, including modSettings overrides, when converting. Other roughages need their own equivalent; a percentage alone cannot guarantee an absolute roughage allowance.
3. FAS puts a ewe's one-point BCS change at 10–13% of live weight. The cattle reserveCapacityRatio 0.20 with BCS = 1+4r is only 5% of reference weight per point. Candidate sheep ratio 0.48 corresponds to 12% **at the model's reference weight**; this is a derived calibration hypothesis, not a proven conversion at every reserve index. It needs species-specific body config and an annual cycle test before use.
4. The dry 70 kg ewe maintenance example is 10 MJ/day, or about 0.4132 MJ/kg^0.75. The old 0.475 growing-lamb candidate concerns another physiological stage. Verify stage-specific coefficients rather than applying one trial to all ewes.
5. The v2 female curve already embodies female growth. Do not multiply it by femaleGrowth 0.76 again. Wether **development speed** 0.86 does not prove an exact 0.86 daily mass-gain ratio on a nonlinear curve; validate V6 on actual animals and rations.
6. No universal 3-month market-weight requirement for hill breeds: the existing male potential reaches its breed reference at 4.68–4.96 months. V1 applies to its stated lowland/terminal population. All 32 sex curves were audited with the real Lua curve evaluator; these potential crossing ages are not feeding-route outcomes.

## Implemented in this batch

`weightProfiles.animalType` accepts the same numeric physiology settings as the root, as independent validated tables. Missing values inherit the root for compatibility with older user XML; a bad type disables that type alone and exposes the reason. Root/cattle and proxy APIs preserve the same effective root table. Profile-local maleBirthFactor wins over the type; otherwise the type supplies its birth knot.

Every existing weight-physiology consumer now carries its animal/subtype/binding: genes, birth distributions and litter effects, birth fade, pregnancy mass, castration, appetite lag, milk reserve mobilization, underweight checks, migration, stage relaxation and state sanitization. Feed and dealer callers and newborn feed forecasting pass their existing species context too. Reports include a copy of effective settings; excluded goats report root compatibility settings.

The shipped sheep entry sets only the already-approved `castratedSpeed="0.86"`. The other inherited coefficients are **not sheep calibration** and the type remains `enabled="false"`, status `S5_CALIBRATION_OFF`. Body condition and feed settings still need their own species sections. This change does not make enabling sheep safe on its own.

## Verification

- Full suite: **3796/3796**, including 21 new settings checks. The first sandboxed run stopped because transaction fixtures write `/var/tmp`; the authorized run outside the sandbox completed.
- New tests also passed under Lua 5.1. Four isolated mutations reverting stage speed, gene/litter settings, profile birth fallback or budget settings to cattle defaults were detected.
- Frozen baseline A/B under Lua 5.1: **396 cases, 50,688 scalar comparisons, zero differences**, identical snapshot SHA256. Every 22 cattle profiles × 2 sexes × 3 metabolism genes × 3 stages runs 120 real shared-budget steps. This proves the covered numerical probe, not every engine interaction or sheep feeding gate.
- Static HB audit: the sheep stable and both pastures have food unload triggers without explicit fillTypes. That supports group-driven reception, but runtime group injection and unloading still require implementation and a game check.

Reproduce with an environment containing lupa:

```sh
python tests/run.py
python tests/sheep_s5_ab.py --out /tmp/sheep-s5-ab.json
python ../FS25_SheepBreeds_离线准备_2026-10-11/tools/audit_s5_inputs.py \
  --rlrm . --hb ../FS25_HofBergmann.zip --out /tmp/sheep-s5-input-audit.json
```

Evidence: `../FS25_SheepBreeds_离线准备_2026-10-11/s5-logs/` (`cattle-ab.json`, `input-audit.json`, `settings-validation.json`, `tests-full.log`). These local preparation artifacts are outside the RLRM git repository.

## Remaining activation gates

Implement and calibrate sheep feed and body configs; add silage/grain groups; build per-dam lactation and actual paid milk pools with orphan readiness and transfer warnings; add fat grade, meat factors and adjustment UI; extend console and W-DEBUG diagnostics. Verify primary breed/milk evidence, all R1–R4/V1–V10, maternal annual cycle, other-species A/B and 1/3/7/28-day periods. Open sheep v2 only after those gates pass. S3/S4 single-player short tests are still unperformed. When deploying, pair with EconomyTuner main `9a37551`.

## Primary sources read for this batch

- [FAS Keeping and Maintaining Ewe Condition](https://www.fas.scot/article/keeping-and-maintaining-ewe-condition/): BCS mass and maintenance example; 2024 table's upland lambing cell contains “2.54”, so the clean 2018 table is used for that target.
- [FAS Creep Feed To Aid Condition](https://www.fas.scot/article/creep-feed-to-aid-condition/): lowground/upland/hill target table.
- [FAS Pre-Mating Management Of The Flock](https://www.fas.scot/article/pre-mating-management-flock/): lowland versus hill mating targets.
- [FAS Finishing Lambs on Concentrates](https://www.fas.scot/article/finishing-lambs-on-concentrates/): CP fresh-weight basis and barley-specific transition advice.
- [AHDB Lambing ewe lambs](https://ahdb.org.uk/knowledge-library/lambing-ewe-lambs): creep protein by age and early-weaning solid-intake readiness. Its population is first-lambing ewes, not every adult-ewe flock.
- [Teagasc Finishing Store Lambs on All-Concentrate Diets](https://teagasc.ie/news--events/daily-archive/finishing-store-lambs-on-all-concentrate-diets/): gradual adaptation with retained roughage.
- [FAS Keeping Lambs Growing](https://www.fas.scot/article/keeping-lambs-growing/): weaning depends on grass, growth and ewe condition; eight-week early option in extreme years.

Original milk and ten outstanding breed tables from S1 remain unverified; no evidence grade was silently upgraded from search summaries.
